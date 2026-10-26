#ifndef QJS_DART_H
#define QJS_DART_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

struct QJSABIRuntime;
struct QJSABIManagedPointer;

struct QJSABIManagedPointerVTable {
  void (*invalidate)(struct QJSABIManagedPointer *self);
};

struct QJSABIManagedPointer {
  const struct QJSABIManagedPointerVTable *vtable;
};

enum QJSABIErrorCode {
  QJSABIErrorCodeNativeException,
  QJSABIErrorCodeJSError,
};

#define DECLARE_QJS_ABI_POINTER_TYPE(name) \
  struct QJSABI##name {                    \
    struct QJSABIManagedPointer *pointer;  \
  };                                          \
  struct QJSABI##name##OrError {           \
    uintptr_t ptr_or_error;                   \
  };

DECLARE_QJS_ABI_POINTER_TYPE(Object)
DECLARE_QJS_ABI_POINTER_TYPE(Array)
DECLARE_QJS_ABI_POINTER_TYPE(String)
DECLARE_QJS_ABI_POINTER_TYPE(BigInt)
DECLARE_QJS_ABI_POINTER_TYPE(Symbol)
DECLARE_QJS_ABI_POINTER_TYPE(Function)
DECLARE_QJS_ABI_POINTER_TYPE(ArrayBuffer)
DECLARE_QJS_ABI_POINTER_TYPE(PropNameID)

#undef DECLARE_QJS_ABI_POINTER_TYPE

struct QJSABIVoidOrError {
  uintptr_t void_or_error;
};

struct QJSABIBoolOrError {
  uintptr_t bool_or_error;
};

struct QJSABIUint8PtrOrError {
  bool is_error;
  union {
    uint8_t *val;
    uint16_t error;
  } data;
};

struct QJSABISizeTOrError {
  bool is_error;
  union {
    size_t val;
    uint16_t error;
  } data;
};

struct QJSABIPropNameIDListPtrOrError {
  uintptr_t ptr_or_error;
};

#define QJS_ABI_POINTER_MASK (1u << (sizeof(unsigned int) * 8u - 1u))

enum QJSABIValueKind {
  QJSABIValueKindUndefined = 0,
  QJSABIValueKindNull = 1,
  QJSABIValueKindBoolean = 2,
  QJSABIValueKindError = 3,
  QJSABIValueKindNumber = 4,
  QJSABIValueKindSymbol = 5 | QJS_ABI_POINTER_MASK,
  QJSABIValueKindBigInt = 6 | QJS_ABI_POINTER_MASK,
  QJSABIValueKindString = 7 | QJS_ABI_POINTER_MASK,
  QJSABIValueKindObject = 9 | QJS_ABI_POINTER_MASK,
};

struct QJSABIValue {
  enum QJSABIValueKind kind;
  union {
    bool boolean;
    double number;
    struct QJSABIManagedPointer *pointer;
    enum QJSABIErrorCode error;
  } data;
};

struct QJSABIValueOrError {
  struct QJSABIValue value;
};

struct QJSABIPropNameIDList;

struct QJSABIPropNameIDListVTable {
  void (*release)(struct QJSABIPropNameIDList *);
};

struct QJSABIPropNameIDList {
  const struct QJSABIPropNameIDListVTable *vtable;
  const struct QJSABIPropNameID *props;
  size_t size;
};

#ifdef __cplusplus
extern "C" {
#endif

// Callback typedefs

typedef struct QJSABIValueOrError (*QJSABIHostFunctionCall)(
  void *user_data,
  struct QJSABIRuntime *rt,
  const struct QJSABIValue *this_arg,
  const struct QJSABIValue *args,
  size_t arg_count
);

typedef void (*QJSABIHostFunctionRelease)(void *user_data);

typedef struct QJSABIValueOrError (*QJSABIHostObjectGet)(
  void *user_data,
  struct QJSABIRuntime *rt,
  struct QJSABIPropNameID name
);

typedef struct QJSABIVoidOrError (*QJSABIHostObjectSet)(
  void *user_data,
  struct QJSABIRuntime *rt,
  struct QJSABIPropNameID name,
  const struct QJSABIValue *value
);

typedef struct QJSABIPropNameIDListPtrOrError (*QJSABIHostObjectGetOwnKeys)(
  void *user_data,
  struct QJSABIRuntime *rt
);

// Whether the object owns the property `name`.
typedef struct QJSABIBoolOrError (*QJSABIHostObjectHas)(
  void *user_data,
  struct QJSABIRuntime *rt,
  struct QJSABIPropNameID name
);

typedef void (*QJSABIHostObjectRelease)(void *user_data);

typedef void (*QJSABIMutableBufferRelease)(void *user_data);

typedef void (*QJSABINativeStateRelease)(void *user_data);

// Receives owned references to `promise` and `reason`.
typedef void (*QJSABIPromiseRejectionTracker)(
  struct QJSABIRuntime *rt,
  struct QJSABIValue promise,
  struct QJSABIValue reason,
  bool is_handled
);

// The `type` import attribute: `import x from 'a.json' with { type: 'json' }`.
enum QJSABIImportType {
  QJSABIImportTypeJavaScript = 0,
  QJSABIImportTypeJSON = 1,
  QJSABIImportTypeText = 2,
};

// Returns the canonical name (a string) of `specifier` imported from
// `referrer`, the name of the importing module or script.
typedef struct QJSABIValueOrError (*QJSABIModuleResolve)(
  struct QJSABIRuntime *rt,
  const char *specifier,
  const char *referrer
);

// Returns the module with the canonical `name`: a string is compiled as its
// source, and an object becomes a module exporting its own enumerable
// properties. Called once per name and import type.
typedef struct QJSABIValueOrError (*QJSABIModuleLoad)(
  struct QJSABIRuntime *rt,
  const char *name,
  enum QJSABIImportType type
);

// Mirrors JSPromiseStateEnum.
enum QJSABIPromiseState {
  QJSABIPromiseStateNotAPromise = -1,
  QJSABIPromiseStatePending = 0,
  QJSABIPromiseStateFulfilled = 1,
  QJSABIPromiseStateRejected = 2,
};

// Mirrors JSMemoryUsage.
struct QJSABIMemoryUsage {
  int64_t malloc_size, malloc_limit, memory_used_size;
  int64_t malloc_count;
  int64_t memory_used_count;
  int64_t atom_count, atom_size;
  int64_t str_count, str_size;
  int64_t obj_count, obj_size;
  int64_t prop_count, prop_size;
  int64_t shape_count, shape_size;
  int64_t js_func_count, js_func_size, js_func_code_size;
  int64_t js_func_pc2line_count, js_func_pc2line_size;
  int64_t c_func_count, array_count;
  int64_t fast_array_count, fast_array_elements;
  int64_t binary_object_count, binary_object_size;
};

struct QJSABIRuntimeConfig {
  bool enable_eval;
  bool es6_proxy;
  bool microtask_queue;
  size_t memory_limit;
  size_t max_stack_size;
  size_t gc_threshold;
};

struct QJSABIPreparedJavaScript;

struct QJSABIPreparedJavaScriptOrError {
  uintptr_t ptr_or_error;
};

struct QJSABIStringData {
  bool is_ascii;
  const void *data;
  size_t length;
};

// Runtime

struct QJSABIPreparedJavaScriptOrError
qjs_runtime_prepared_javascript_create(
  struct QJSABIRuntime *rt,
  const uint8_t *utf8_source,
  size_t source_length,
  const char *source_url
);

struct QJSABIValueOrError
qjs_runtime_prepared_javascript_evaluate(
  struct QJSABIRuntime *rt,
  struct QJSABIPreparedJavaScript *prepared
);

void qjs_preparedjavascript_release(
  struct QJSABIPreparedJavaScript *prepared
);

uint64_t qjs_value_get_unique_id(
  struct QJSABIRuntime *rt,
  struct QJSABIValue val
);

struct QJSABIValueOrError qjs_object_from_id(
  struct QJSABIRuntime *rt,
  uint64_t id
);

// Returns false and records the error if a job fails; the remaining jobs
// stay queued.
bool qjs_runtime_drain_microtasks(
  struct QJSABIRuntime *rt,
  int max_microtasks_hint
);

struct QJSABIValueOrError qjs_value_create_from_json_utf8(
  struct QJSABIRuntime *rt,
  const uint8_t *json_bytes,
  size_t length
);

struct QJSABIStringData qjs_string_get_data(
  struct QJSABIRuntime *rt,
  struct QJSABIString str
);

struct QJSABIStringData qjs_propnameid_get_data(
  struct QJSABIRuntime *rt,
  struct QJSABIPropNameID prop
);

struct QJSABIValueOrError qjs_array_value_get_at_index(
  struct QJSABIRuntime *rt,
  struct QJSABIArray arr,
  size_t index
);

struct QJSABIVoidOrError qjs_array_value_set_at_index(
  struct QJSABIRuntime *rt,
  struct QJSABIArray arr,
  size_t index,
  struct QJSABIValue value
);

struct QJSABIRuntime *qjs_runtime_create(
  struct QJSABIRuntimeConfig config
);

// Frees memory returned by this library (e.g. strings). Callers must not
// use their own allocator: on Windows it may not share the C runtime's heap.
void qjs_free(void *ptr);

void qjs_runtime_release(struct QJSABIRuntime *rt);

// Sandbox controls

// Interrupts JS execution once `timeout_us` microseconds have passed. The
// deadline stays in effect until cleared or replaced, so every later
// execution is interrupted immediately once it has passed.
void qjs_runtime_set_deadline(struct QJSABIRuntime *rt, uint64_t timeout_us);
void qjs_runtime_clear_deadline(struct QJSABIRuntime *rt);

// Unique id of a live runtime, for qjs_runtime_request_interrupt.
uint64_t qjs_runtime_get_id(struct QJSABIRuntime *rt);

// Interrupts the running JS execution, or the next one if none is running.
// Safe to call from any thread, and with a runtime that has already been
// released: returns false if `rt` with this `id` is no longer alive.
bool qjs_runtime_request_interrupt(struct QJSABIRuntime *rt, uint64_t id);

struct QJSABIMemoryUsage qjs_runtime_get_memory_usage(struct QJSABIRuntime *rt);

// Pass NULL to remove the tracker.
void qjs_runtime_set_promise_rejection_tracker(
  struct QJSABIRuntime *rt,
  QJSABIPromiseRejectionTracker tracker
);

void qjs_runtime_run_gc(struct QJSABIRuntime *rt);

// Modules

// Pass NULL for both to disable imports, which is the default.
void qjs_runtime_set_module_loader(
  struct QJSABIRuntime *rt,
  QJSABIModuleResolve resolve,
  QJSABIModuleLoad load
);

// Evaluates `source` as a module named `name` and returns its namespace.
// The promise of its evaluation, already marked as handled, is stored in
// `out_promise`: a module with top-level await may still be evaluating.
struct QJSABIValueOrError qjs_runtime_evaluate_module(
  struct QJSABIRuntime *rt,
  const uint8_t *utf8_source,
  size_t source_length,
  const char *name,
  struct QJSABIValue *out_promise
);

// Promises

enum QJSABIPromiseState qjs_promise_get_state(
  struct QJSABIRuntime *rt,
  struct QJSABIObject promise
);

struct QJSABIValue qjs_promise_get_result(
  struct QJSABIRuntime *rt,
  struct QJSABIObject promise
);

// Unlike calling `promise.then`, never runs a `then` overridden by scripts.
struct QJSABIVoidOrError qjs_promise_then(
  struct QJSABIRuntime *rt,
  struct QJSABIObject promise,
  struct QJSABIFunction on_fulfilled,
  struct QJSABIFunction on_rejected
);

struct QJSABIObject qjs_runtime_get_global_object(
  struct QJSABIRuntime *rt
);

struct QJSABIValue qjs_evaluate_javascript(
  struct QJSABIRuntime *rt,
  const uint8_t *script,
  size_t script_len,
  const char *source_url
);

// Runtime error handling

void qjs_runtime_set_js_error_value(
  struct QJSABIRuntime *rt,
  struct QJSABIValue error_value
);

void qjs_runtime_set_native_exception_message(
  struct QJSABIRuntime *rt,
  const char *message
);

struct QJSABIValue qjs_runtime_get_and_clear_js_error_value(
  struct QJSABIRuntime *rt
);

char *qjs_runtime_get_and_clear_native_exception_message(
  struct QJSABIRuntime *rt
);

// Memory

void qjs_pointer_release(struct QJSABIManagedPointer *ptr);
void qjs_pointer_release_safe(struct QJSABIManagedPointer *ptr);

void qjs_register_pointer(
  struct QJSABIRuntime *rt,
  struct QJSABIManagedPointer *ptr
);

struct QJSABIManagedPointer *qjs_managed_pointer_clone(
  struct QJSABIRuntime *rt,
  struct QJSABIManagedPointer *ptr
);

bool qjs_managed_pointer_strict_equals(
  struct QJSABIRuntime *rt,
  struct QJSABIManagedPointer *a,
  struct QJSABIManagedPointer *b
);

// Objects

struct QJSABIObjectOrError qjs_object_create(struct QJSABIRuntime *rt);

struct QJSABIValue qjs_object_get_property_from_value(
  struct QJSABIRuntime *rt,
  struct QJSABIObject obj,
  struct QJSABIValue key
);

struct QJSABIVoidOrError qjs_object_set_property_from_value(
  struct QJSABIRuntime *rt,
  struct QJSABIObject obj,
  struct QJSABIValue key,
  struct QJSABIValue value
);

struct QJSABIBoolOrError qjs_object_has_property_from_value(
  struct QJSABIRuntime *rt,
  struct QJSABIObject obj,
  struct QJSABIValue key
);

struct QJSABIValue qjs_object_get_property_from_propnameid(
  struct QJSABIRuntime *rt,
  struct QJSABIObject obj,
  struct QJSABIPropNameID name
);

struct QJSABIVoidOrError qjs_object_set_property_from_propnameid(
  struct QJSABIRuntime *rt,
  struct QJSABIObject obj,
  struct QJSABIPropNameID name,
  struct QJSABIValue value
);

struct QJSABIBoolOrError qjs_object_has_property_from_propnameid(
  struct QJSABIRuntime *rt,
  struct QJSABIObject obj,
  struct QJSABIPropNameID name
);

struct QJSABIArrayOrError qjs_object_get_property_names(
  struct QJSABIRuntime *rt,
  struct QJSABIObject obj
);

bool qjs_object_is_function(
  struct QJSABIRuntime *rt,
  struct QJSABIObject obj
);

bool qjs_object_is_array(
  struct QJSABIRuntime *rt,
  struct QJSABIObject obj
);

bool qjs_object_is_arraybuffer(
  struct QJSABIRuntime *rt,
  struct QJSABIObject obj
);

struct QJSABIBoolOrError qjs_instance_of(
  struct QJSABIRuntime *rt,
  struct QJSABIObject obj,
  struct QJSABIFunction ctor
);

// Host objects

struct QJSABIObjectOrError qjs_object_create_from_host_object(
  struct QJSABIRuntime *rt,
  void *user_data,
  QJSABIHostObjectGet get_cb,
  QJSABIHostObjectSet set_cb,
  QJSABIHostObjectGetOwnKeys get_own_keys_cb,
  QJSABIHostObjectHas has_cb,
  QJSABIHostObjectRelease release_cb
);

// Native state

struct QJSABIVoidOrError qjs_object_set_native_state(
  struct QJSABIRuntime *rt,
  struct QJSABIObject obj,
  void *user_data,
  QJSABINativeStateRelease release_cb
);

void *qjs_object_get_native_state_data(
  struct QJSABIRuntime *rt,
  struct QJSABIObject obj
);

// Functions

struct QJSABIValue qjs_function_call(
  struct QJSABIRuntime *rt,
  struct QJSABIFunction fn,
  struct QJSABIValue js_this,
  struct QJSABIValue *args,
  size_t arg_count
);

struct QJSABIValue qjs_function_call_as_constructor(
  struct QJSABIRuntime *rt,
  struct QJSABIFunction fn,
  struct QJSABIValue *args,
  size_t arg_count
);

struct QJSABIFunctionOrError qjs_function_create_from_host(
  struct QJSABIRuntime *rt,
  struct QJSABIPropNameID name,
  unsigned int length,
  void *user_data,
  QJSABIHostFunctionCall call_cb,
  QJSABIHostFunctionRelease release_cb
);

// Strings

struct QJSABIStringOrError qjs_create_string_from_utf8(
  struct QJSABIRuntime *rt,
  const char *str
);

char *qjs_string_to_utf8(
  struct QJSABIRuntime *rt,
  struct QJSABIString str
);

// PropNameIDs

struct QJSABIPropNameIDOrError qjs_propnameid_create_from_string(
  struct QJSABIRuntime *rt,
  struct QJSABIString str
);

struct QJSABIPropNameIDOrError qjs_propnameid_create_from_symbol(
  struct QJSABIRuntime *rt,
  struct QJSABISymbol sym
);

char *qjs_propnameid_to_utf8(
  struct QJSABIRuntime *rt,
  struct QJSABIPropNameID name
);

struct QJSABIPropNameID qjs_propnameid_clone(
  struct QJSABIRuntime *rt,
  struct QJSABIPropNameID name
);

bool qjs_propnameid_equals(
  struct QJSABIRuntime *rt,
  struct QJSABIPropNameID a,
  struct QJSABIPropNameID b
);

struct QJSABIPropNameIDList *qjs_propnameid_list_create(
  const struct QJSABIPropNameID *props,
  size_t size
);

// BigInts

struct QJSABIBigIntOrError qjs_bigint_create_from_int64(
  struct QJSABIRuntime *rt,
  int64_t value
);

bool qjs_bigint_is_int64(
  struct QJSABIRuntime *rt,
  struct QJSABIBigInt bi
);

int64_t qjs_bigint_as_int64(
  struct QJSABIRuntime *rt,
  struct QJSABIBigInt bi
);

// Arrays

struct QJSABIArrayOrError qjs_array_create(
  struct QJSABIRuntime *rt,
  size_t length
);

size_t qjs_array_get_length(
  struct QJSABIRuntime *rt,
  struct QJSABIArray arr
);

// ArrayBuffers

struct QJSABIArrayBufferOrError qjs_arraybuffer_create_from_external_data(
  struct QJSABIRuntime *rt,
  uint8_t *data,
  size_t size,
  void *user_data,
  QJSABIMutableBufferRelease release_cb
);

struct QJSABIUint8PtrOrError qjs_arraybuffer_get_data(
  struct QJSABIRuntime *rt,
  struct QJSABIArrayBuffer ab
);

struct QJSABISizeTOrError qjs_arraybuffer_get_size(
  struct QJSABIRuntime *rt,
  struct QJSABIArrayBuffer ab
);

#ifdef __cplusplus
}
#endif

#endif
