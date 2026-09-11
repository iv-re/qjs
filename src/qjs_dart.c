#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include "qjs_dart.h"
#include "quickjs.h"

#include <pthread.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define MAX_STACK_ARGS 8

typedef union QJSValueOrAtom {
  JSValue val;
  JSAtom atom;
} QJSValueOrAtom;

struct QJSABIManagedPointerImpl {
  struct QJSABIManagedPointer base;
  struct QJSABIRuntime *rt;
  QJSValueOrAtom u;
  bool is_atom;
  struct QJSABIManagedPointerImpl *prev;
  struct QJSABIManagedPointerImpl *next;
};

struct QJSABIPreparedJavaScript {
  struct QJSABIRuntime *rt;
  JSValue func_obj;
  struct QJSABIPreparedJavaScript *prev;
  struct QJSABIPreparedJavaScript *next;
};

typedef struct QJSPendingFree {
  QJSValueOrAtom u;
  bool is_atom;
  struct QJSPendingFree *next;
} QJSPendingFree;

struct QJSABIRuntime {
  JSRuntime *rt;
  JSContext *ctx;
  JSValue last_js_error;
  char *last_native_exception;
  JSClassID host_object_class_id;
  JSClassID native_state_class_id;
  JSClassID host_function_class_id;
  struct QJSABIManagedPointerImpl *pointers_head;
  struct QJSABIPreparedJavaScript *prepared_head;
  pthread_mutex_t free_mutex;
  QJSPendingFree * volatile pending_frees;
  void *temp_string_buf;
  JSAtom native_state_atom;
  bool microtask_queue;
  bool is_released;
};

static void drain_jobs_if_needed(struct QJSABIRuntime *rt) {
  if (rt && !rt->microtask_queue && rt->rt) {
    JSContext *pctx;
    while (JS_ExecutePendingJob(rt->rt, &pctx) > 0);
  }
}

static inline void flush_pending_frees(struct QJSABIRuntime *rt) {
  if (!rt || !rt->ctx || rt->is_released || !rt->pending_frees) return;

  pthread_mutex_lock(&rt->free_mutex);
  QJSPendingFree *curr = rt->pending_frees;
  rt->pending_frees = NULL;
  pthread_mutex_unlock(&rt->free_mutex);

  while (curr) {
    QJSPendingFree *next = curr->next;
    if (curr->is_atom) {
      JS_FreeAtom(rt->ctx, curr->u.atom);
    } else {
      JS_FreeValue(rt->ctx, curr->u.val);
    }
    free(curr);
    curr = next;
  }
}

static void managed_pointer_invalidate(struct QJSABIManagedPointer *self) {
  if (!self) return;
  struct QJSABIManagedPointerImpl *impl = (struct QJSABIManagedPointerImpl *)self;
  struct QJSABIRuntime *rt = impl->rt;
  if (rt) {
    pthread_mutex_lock(&rt->free_mutex);
    if (!rt->is_released) {
      if (impl->prev) {
        impl->prev->next = impl->next;
      } else if (rt->pointers_head == impl) {
        rt->pointers_head = impl->next;
      }
      if (impl->next) {
        impl->next->prev = impl->prev;
      }
      impl->prev = NULL;
      impl->next = NULL;

      QJSPendingFree *pf = (QJSPendingFree *)malloc(sizeof(QJSPendingFree));
      if (pf) {
        pf->u = impl->u;
        pf->is_atom = impl->is_atom;
        pf->next = rt->pending_frees;
        rt->pending_frees = pf;
      }
    }
    pthread_mutex_unlock(&rt->free_mutex);
    impl->rt = NULL;
  }
  free(impl);
}

static const struct QJSABIManagedPointerVTable g_managed_vtable = {
  managed_pointer_invalidate
};

static struct QJSABIManagedPointerImpl *create_managed(
  struct QJSABIRuntime *rt,
  JSValue val,
  JSAtom atom,
  bool is_atom
) {
  if (rt) flush_pending_frees(rt);
  struct QJSABIManagedPointerImpl *impl =
    (struct QJSABIManagedPointerImpl *)malloc(sizeof(struct QJSABIManagedPointerImpl));
  if (!impl) return NULL;
  impl->base.vtable = &g_managed_vtable;
  impl->rt = rt;
  if (is_atom) {
    impl->u.atom = atom;
  } else {
    impl->u.val = val;
  }
  impl->is_atom = is_atom;
  if (rt) {
    pthread_mutex_lock(&rt->free_mutex);
    impl->prev = NULL;
    impl->next = rt->pointers_head;
    if (rt->pointers_head) rt->pointers_head->prev = impl;
    rt->pointers_head = impl;
    pthread_mutex_unlock(&rt->free_mutex);
  } else {
    impl->prev = NULL;
    impl->next = NULL;
  }
  return impl;
}

#define create_managed_pointer(rt, val) create_managed((rt), (val), 0, false)
#define create_managed_atom(rt, atom) create_managed((rt), JS_UNDEFINED, (atom), true)

static inline uintptr_t make_error_ptr(enum QJSABIErrorCode err) {
  return ((uintptr_t)err << 2) | 1;
}

static inline bool is_error_ptr(uintptr_t ptr) {
  return (ptr & 1) != 0;
}

static inline enum QJSABIErrorCode get_error_from_ptr(uintptr_t ptr) {
  return (enum QJSABIErrorCode)(ptr >> 2);
}

static inline JSValue get_js_value(struct QJSABIManagedPointer *p) {
  if (!p) return JS_UNDEFINED;
  return ((struct QJSABIManagedPointerImpl *)p)->u.val;
}

static inline JSAtom get_js_atom(struct QJSABIManagedPointer *p) {
  if (!p) return 0;
  struct QJSABIManagedPointerImpl *impl = (struct QJSABIManagedPointerImpl *)p;
  return impl->is_atom ? impl->u.atom : JS_ValueToAtom(impl->rt->ctx, impl->u.val);
}

static void record_js_exception(struct QJSABIRuntime *rt) {
  JSValue exc = JS_GetException(rt->ctx);
  if (!JS_IsUndefined(rt->last_js_error)) {
    JS_FreeValue(rt->ctx, rt->last_js_error);
  }
  rt->last_js_error = exc;
}

static struct QJSABIValue return_js_error_val(struct QJSABIRuntime *rt) {
  record_js_exception(rt);
  struct QJSABIValue err;
  memset(&err, 0, sizeof(err));
  err.kind = QJSABIValueKindError;
  err.data.error = QJSABIErrorCodeJSError;
  return err;
}

static uintptr_t return_ptr_or_error(struct QJSABIRuntime *rt, JSValue val) {
  if (JS_IsException(val)) {
    record_js_exception(rt);
    return make_error_ptr(QJSABIErrorCodeJSError);
  }
  return (uintptr_t)create_managed_pointer(rt, val);
}

static uintptr_t return_void_or_error(struct QJSABIRuntime *rt, int ret) {
  if (ret < 0) {
    record_js_exception(rt);
    return make_error_ptr(QJSABIErrorCodeJSError);
  }
  return 0;
}

static uintptr_t return_bool_or_error(struct QJSABIRuntime *rt, int ret) {
  if (ret < 0) {
    record_js_exception(rt);
    return make_error_ptr(QJSABIErrorCodeJSError);
  }
  return (uintptr_t)(ret != 0 ? 4 : 0);
}

static struct QJSABIValue to_qjs_abi_value(struct QJSABIRuntime *rt, JSValue val) {
  struct QJSABIValue res;
  memset(&res, 0, sizeof(res));

  int tag = JS_VALUE_GET_NORM_TAG(val);
  switch (tag) {
    case JS_TAG_UNDEFINED:
      res.kind = QJSABIValueKindUndefined;
      break;
    case JS_TAG_NULL:
      res.kind = QJSABIValueKindNull;
      break;
    case JS_TAG_BOOL:
      res.kind = QJSABIValueKindBoolean;
      res.data.boolean = (JS_VALUE_GET_BOOL(val) != 0);
      break;
    case JS_TAG_INT:
      res.kind = QJSABIValueKindNumber;
      res.data.number = (double)JS_VALUE_GET_INT(val);
      break;
    case JS_TAG_FLOAT64:
      res.kind = QJSABIValueKindNumber;
      res.data.number = JS_VALUE_GET_FLOAT64(val);
      break;
    case JS_TAG_STRING:
    case JS_TAG_STRING_ROPE:
      res.kind = QJSABIValueKindString;
      res.data.pointer = (struct QJSABIManagedPointer *)create_managed_pointer(rt, val);
      break;
    case JS_TAG_SYMBOL:
      res.kind = QJSABIValueKindSymbol;
      res.data.pointer = (struct QJSABIManagedPointer *)create_managed_pointer(rt, val);
      break;
    case JS_TAG_BIG_INT:
    case JS_TAG_SHORT_BIG_INT:
      res.kind = QJSABIValueKindBigInt;
      res.data.pointer = (struct QJSABIManagedPointer *)create_managed_pointer(rt, val);
      break;
    case JS_TAG_OBJECT:
    case JS_TAG_FUNCTION_BYTECODE:
    case JS_TAG_MODULE:
      res.kind = QJSABIValueKindObject;
      res.data.pointer = (struct QJSABIManagedPointer *)create_managed_pointer(rt, val);
      break;
    case JS_TAG_EXCEPTION:
      res.kind = QJSABIValueKindError;
      res.data.error = QJSABIErrorCodeJSError;
      break;
    default:
      res.kind = QJSABIValueKindUndefined;
      break;
  }
  return res;
}

static struct QJSABIValueOrError return_val_or_error(struct QJSABIRuntime *rt, JSValue val) {
  struct QJSABIValueOrError res;
  if (JS_IsException(val)) {
    res.value = return_js_error_val(rt);
  } else {
    res.value = to_qjs_abi_value(rt, val);
  }
  return res;
}

static JSValue from_qjs_abi_value(struct QJSABIRuntime *rt, const struct QJSABIValue *val) {
  if (!val) return JS_UNDEFINED;
  switch (val->kind) {
    case QJSABIValueKindUndefined:
      return JS_UNDEFINED;
    case QJSABIValueKindNull:
      return JS_NULL;
    case QJSABIValueKindBoolean:
      return JS_NewBool(rt->ctx, val->data.boolean);
    case QJSABIValueKindNumber:
      return JS_NewFloat64(rt->ctx, val->data.number);
    case QJSABIValueKindString:
    case QJSABIValueKindSymbol:
    case QJSABIValueKindBigInt:
    case QJSABIValueKindObject:
      return val->data.pointer ? JS_DupValue(rt->ctx, get_js_value(val->data.pointer)) : JS_UNDEFINED;
    default:
      return JS_UNDEFINED;
  }
}

static inline void release_value(struct QJSABIValue *val) {
  if (!val) return;
  if ((val->kind & QJS_ABI_POINTER_MASK) && val->data.pointer) {
    qjs_pointer_release(val->data.pointer);
    val->data.pointer = NULL;
  }
}

static inline void *get_opaque_safe(JSValueConst obj) {
  JSClassID cid = 0;
  return JS_GetAnyOpaque(obj, &cid);
}

// Host Object implementation

typedef struct QJSHostObjectBridge {
  void *user_data;
  struct QJSABIRuntime *rt;
  QJSABIHostObjectGet get_cb;
  QJSABIHostObjectSet set_cb;
  QJSABIHostObjectGetOwnKeys get_own_keys_cb;
  QJSABIHostObjectRelease release_cb;
} QJSHostObjectBridge;

static void host_object_finalizer(JSRuntime *rt, JSValueConst val) {
  (void)rt;
  QJSHostObjectBridge *bridge = (QJSHostObjectBridge *)get_opaque_safe(val);
  if (bridge) {
    if (bridge->release_cb) bridge->release_cb(bridge->user_data);
    free(bridge);
  }
}

static void raise_abi_error(struct QJSABIRuntime *rt, JSContext *ctx, int errorCode) {
  if (errorCode == QJSABIErrorCodeJSError) {
    JSValue err = rt->last_js_error;
    rt->last_js_error = JS_UNDEFINED;
    if (!JS_IsUndefined(err)) {
      JS_Throw(ctx, err);
    } else {
      JS_ThrowPlainError(ctx, "JavaScript error");
    }
  } else {
    const char *msg = rt->last_native_exception;
    if (msg) {
      JS_ThrowPlainError(ctx, "%s", msg);
      free(rt->last_native_exception);
      rt->last_native_exception = NULL;
    } else {
      JS_ThrowPlainError(ctx, "<unknown native exception>");
    }
  }
}

static JSValue host_object_get_property(
  JSContext *ctx,
  JSValueConst obj,
  JSAtom atom,
  JSValueConst receiver
) {
  (void)ctx; (void)receiver;
  QJSHostObjectBridge *bridge = (QJSHostObjectBridge *)get_opaque_safe(obj);
  if (bridge && bridge->get_cb) {
    struct QJSABIPropNameID propNameId = {
      .pointer = (struct QJSABIManagedPointer *)create_managed_atom(bridge->rt, JS_DupAtom(bridge->rt->ctx, atom))
    };
    struct QJSABIValueOrError res = bridge->get_cb(bridge->user_data, bridge->rt, propNameId);
    qjs_pointer_release(propNameId.pointer);
    if (res.value.kind == QJSABIValueKindError) {
      raise_abi_error(bridge->rt, ctx, res.value.data.error);
      return JS_EXCEPTION;
    }
    JSValue out = from_qjs_abi_value(bridge->rt, &res.value);
    release_value(&res.value);
    return out;
  }
  return JS_UNDEFINED;
}

static int host_object_set_property(
  JSContext *ctx,
  JSValueConst obj,
  JSAtom atom,
  JSValueConst value,
  JSValueConst receiver,
  int flags
) {
  (void)ctx; (void)receiver; (void)flags;
  QJSHostObjectBridge *bridge = (QJSHostObjectBridge *)get_opaque_safe(obj);
  if (bridge && bridge->set_cb) {
    struct QJSABIPropNameID propNameId = {
      .pointer = (struct QJSABIManagedPointer *)create_managed_atom(bridge->rt, JS_DupAtom(bridge->rt->ctx, atom))
    };
    struct QJSABIValue abiVal = to_qjs_abi_value(bridge->rt, JS_DupValue(bridge->rt->ctx, value));
    struct QJSABIVoidOrError res = bridge->set_cb(bridge->user_data, bridge->rt, propNameId, &abiVal);
    qjs_pointer_release(propNameId.pointer);
    release_value(&abiVal);
    if (is_error_ptr(res.void_or_error)) {
      raise_abi_error(bridge->rt, ctx, (int)get_error_from_ptr(res.void_or_error));
      return -1;
    }
    return 1;
  }
  return 0;
}

static int host_object_has_property(JSContext *ctx, JSValueConst obj, JSAtom atom) {
  (void)ctx;
  QJSHostObjectBridge *bridge = (QJSHostObjectBridge *)get_opaque_safe(obj);
  if (bridge && bridge->get_own_keys_cb) {
    struct QJSABIPropNameIDListPtrOrError keysRes = bridge->get_own_keys_cb(bridge->user_data, bridge->rt);
    if (!is_error_ptr(keysRes.ptr_or_error)) {
      struct QJSABIPropNameIDList *list = (struct QJSABIPropNameIDList *)keysRes.ptr_or_error;
      if (list) {
        int found = 0;
        for (size_t i = 0; i < list->size; i++) {
          if (get_js_atom(list->props[i].pointer) == atom) {
            found = 1;
            break;
          }
        }
        if (list->vtable && list->vtable->release) list->vtable->release(list);
        return found;
      }
    }
  }
  return 0;
}

static int host_object_get_own_property_names(
  JSContext *ctx,
  JSPropertyEnum **ptab,
  uint32_t *plen,
  JSValueConst obj
) {
  QJSHostObjectBridge *bridge = (QJSHostObjectBridge *)get_opaque_safe(obj);
  if (bridge && bridge->get_own_keys_cb) {
    struct QJSABIPropNameIDListPtrOrError keysRes = bridge->get_own_keys_cb(bridge->user_data, bridge->rt);
    if (is_error_ptr(keysRes.ptr_or_error)) {
      raise_abi_error(bridge->rt, ctx, (int)get_error_from_ptr(keysRes.ptr_or_error));
      *ptab = NULL;
      *plen = 0;
      return -1;
    }
    struct QJSABIPropNameIDList *list = (struct QJSABIPropNameIDList *)keysRes.ptr_or_error;
    if (list) {
      JSPropertyEnum *tab = (JSPropertyEnum *)js_malloc(ctx, sizeof(JSPropertyEnum) * (list->size > 0 ? list->size : 1));
      for (size_t i = 0; i < list->size; i++) {
        tab[i].is_enumerable = true;
        tab[i].atom = JS_DupAtom(ctx, get_js_atom(list->props[i].pointer));
      }
      *ptab = tab;
      *plen = (uint32_t)list->size;
      if (list->vtable && list->vtable->release) list->vtable->release(list);
      return 0;
    }
  }
  *ptab = NULL;
  *plen = 0;
  return 0;
}

static const JSClassExoticMethods g_host_object_exotic = {
  .get_property = host_object_get_property,
  .set_property = host_object_set_property,
  .has_property = host_object_has_property,
  .get_own_property_names = host_object_get_own_property_names,
};

// Native State

typedef struct QJSNativeStateBridge {
  void *user_data;
  QJSABINativeStateRelease release_cb;
} QJSNativeStateBridge;

static void native_state_finalizer(JSRuntime *rt, JSValueConst val) {
  (void)rt;
  QJSNativeStateBridge *b = (QJSNativeStateBridge *)get_opaque_safe(val);
  if (b) {
    if (b->release_cb) b->release_cb(b->user_data);
    free(b);
  }
}

// Host Function

typedef struct QJSHostFunctionBridge {
  void *user_data;
  struct QJSABIRuntime *rt;
  QJSABIHostFunctionCall call_cb;
  QJSABIHostFunctionRelease release_cb;
} QJSHostFunctionBridge;


static void host_function_finalizer(JSRuntime *rt, JSValueConst val) {
  (void)rt;
  QJSHostFunctionBridge *b = (QJSHostFunctionBridge *)get_opaque_safe(val);
  if (b) {
    if (b->release_cb) b->release_cb(b->user_data);
    free(b);
  }
}

static JSValue host_function_call(
  JSContext *ctx,
  JSValueConst this_val,
  int argc,
  JSValueConst *argv,
  int magic,
  JSValue *func_data
) {
  (void)magic;
  QJSHostFunctionBridge *b = (QJSHostFunctionBridge *)get_opaque_safe(func_data[0]);
  if (!b || !b->call_cb) return JS_UNDEFINED;

  struct QJSABIValue this_arg = to_qjs_abi_value(b->rt, JS_DupValue(b->rt->ctx, this_val));
  struct QJSABIValue stack_args[MAX_STACK_ARGS];
  struct QJSABIValue *args = (argc <= MAX_STACK_ARGS)
    ? stack_args
    : (struct QJSABIValue *)calloc(argc, sizeof(struct QJSABIValue));

  for (int i = 0; i < argc; i++) {
    args[i] = to_qjs_abi_value(b->rt, JS_DupValue(b->rt->ctx, argv[i]));
  }

  struct QJSABIValueOrError res = b->call_cb(b->user_data, b->rt, &this_arg, args, argc);

  for (int i = 0; i < argc; i++) release_value(&args[i]);
  if (args != stack_args) free(args);
  release_value(&this_arg);

  if (res.value.kind == QJSABIValueKindError) {
    raise_abi_error(b->rt, ctx, res.value.data.error);
    return JS_EXCEPTION;
  }
  JSValue out = from_qjs_abi_value(b->rt, &res.value);
  release_value(&res.value);
  return out;
}

// Runtime lifecycle & execution

static JSValue js_disabled_eval(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
  (void)this_val; (void)argc; (void)argv;
  return JS_ThrowTypeError(ctx, "eval is disabled");
}

struct QJSABIRuntime *qjs_runtime_create(struct QJSABIRuntimeConfig config) {
  struct QJSABIRuntime *rt = (struct QJSABIRuntime *)calloc(1, sizeof(struct QJSABIRuntime));
  if (!rt) return NULL;

  rt->rt = JS_NewRuntime();
  if (!rt->rt) { free(rt); return NULL; }

  if (config.memory_limit > 0) {
    JS_SetMemoryLimit(rt->rt, config.memory_limit);
  }
  if (config.max_stack_size > 0) {
    JS_SetMaxStackSize(rt->rt, config.max_stack_size);
  }
  if (config.gc_threshold > 0) {
    JS_SetGCThreshold(rt->rt, config.gc_threshold);
  }

  rt->ctx = JS_NewContext(rt->rt);
  if (!rt->ctx) { JS_FreeRuntime(rt->rt); free(rt); return NULL; }

  JS_AddIntrinsicBigInt(rt->ctx);
  rt->last_js_error = JS_UNDEFINED;

  JSValue ns_sym = JS_NewSymbol(rt->ctx, "native_state", false);
  rt->native_state_atom = JS_ValueToAtom(rt->ctx, ns_sym);
  JS_FreeValue(rt->ctx, ns_sym);

  JSValue global = JS_GetGlobalObject(rt->ctx);

  if (!config.enable_eval) {
    JS_SetPropertyStr(rt->ctx, global, "eval", JS_NewCFunction(rt->ctx, js_disabled_eval, "eval", 1));
  }
  if (!config.es6_proxy) {
    JSAtom proxy_atom = JS_NewAtom(rt->ctx, "Proxy");
    JS_DeleteProperty(rt->ctx, global, proxy_atom, 0);
    JS_FreeAtom(rt->ctx, proxy_atom);
  }
  JS_FreeValue(rt->ctx, global);

  JS_NewClassID(rt->rt, &rt->host_object_class_id);
  JSClassDef host_class_def = {
    .class_name = "HostObject",
    .finalizer = host_object_finalizer,
    .exotic = (JSClassExoticMethods *)&g_host_object_exotic,
  };
  JS_NewClass(rt->rt, rt->host_object_class_id, &host_class_def);

  JS_NewClassID(rt->rt, &rt->native_state_class_id);
  JSClassDef state_class_def = {
    .class_name = "NativeState",
    .finalizer = native_state_finalizer,
  };
  JS_NewClass(rt->rt, rt->native_state_class_id, &state_class_def);

  JS_NewClassID(rt->rt, &rt->host_function_class_id);
  JSClassDef func_class_def = {
    .class_name = "HostFunctionData",
    .finalizer = host_function_finalizer,
  };
  JS_NewClass(rt->rt, rt->host_function_class_id, &func_class_def);

  pthread_mutex_init(&rt->free_mutex, NULL);
  rt->pending_frees = NULL;
  rt->microtask_queue = config.microtask_queue;
  return rt;
}

void qjs_runtime_release(struct QJSABIRuntime *rt) {
  if (!rt) return;

  pthread_mutex_lock(&rt->free_mutex);
  if (rt->is_released) {
    pthread_mutex_unlock(&rt->free_mutex);
    return;
  }
  rt->is_released = true;

  struct QJSABIManagedPointerImpl *curr = rt->pointers_head;
  while (curr) {
    struct QJSABIManagedPointerImpl *next = curr->next;
    if (rt->ctx) {
      if (curr->is_atom) {
        JS_FreeAtom(rt->ctx, curr->u.atom);
      } else {
        JS_FreeValue(rt->ctx, curr->u.val);
      }
    }
    curr->rt = NULL;
    curr->prev = NULL;
    curr->next = NULL;
    curr = next;
  }
  rt->pointers_head = NULL;

  QJSPendingFree *pfree = rt->pending_frees;
  rt->pending_frees = NULL;
  while (pfree) {
    QJSPendingFree *pnext = pfree->next;
    if (rt->ctx) {
      if (pfree->is_atom) {
        JS_FreeAtom(rt->ctx, pfree->u.atom);
      } else {
        JS_FreeValue(rt->ctx, pfree->u.val);
      }
    }
    free(pfree);
    pfree = pnext;
  }
  pthread_mutex_unlock(&rt->free_mutex);

  struct QJSABIPreparedJavaScript *pcurr = rt->prepared_head;
  while (pcurr) {
    struct QJSABIPreparedJavaScript *pnext = pcurr->next;
    if (rt->ctx) {
      JS_FreeValue(rt->ctx, pcurr->func_obj);
    }
    pcurr->rt = NULL;
    pcurr->prev = NULL;
    pcurr->next = NULL;
    pcurr = pnext;
  }
  rt->prepared_head = NULL;

  if (!JS_IsUndefined(rt->last_js_error)) {
    JS_FreeValue(rt->ctx, rt->last_js_error);
    rt->last_js_error = JS_UNDEFINED;
  }
  free(rt->last_native_exception);
  rt->last_native_exception = NULL;

  if (rt->temp_string_buf) {
    if (rt->ctx) JS_FreeCStringUTF16(rt->ctx, (const uint16_t *)rt->temp_string_buf);
    rt->temp_string_buf = NULL;
  }
  if (rt->native_state_atom != JS_ATOM_NULL) {
    if (rt->ctx) JS_FreeAtom(rt->ctx, rt->native_state_atom);
    rt->native_state_atom = JS_ATOM_NULL;
  }
  if (rt->ctx) {
    JS_FreeContext(rt->ctx);
    rt->ctx = NULL;
  }
  if (rt->rt) {
    JS_FreeRuntime(rt->rt);
    rt->rt = NULL;
  }
  pthread_mutex_destroy(&rt->free_mutex);
  free(rt);
}

void qjs_runtime_release_from_finalizer(struct QJSABIRuntime *rt) {
  qjs_runtime_release(rt);
}

struct QJSABIObject qjs_runtime_get_global_object(struct QJSABIRuntime *rt) {
  struct QJSABIObject res = {
    .pointer = (struct QJSABIManagedPointer *)create_managed_pointer(rt, JS_GetGlobalObject(rt->ctx))
  };
  return res;
}

struct QJSABIValue qjs_evaluate_javascript(
  struct QJSABIRuntime *rt,
  const uint8_t *script,
  size_t script_len,
  const char *source_url
) {
  JSValue val = JS_Eval(rt->ctx, (const char *)script, script_len, source_url ? source_url : "<eval>", JS_EVAL_TYPE_GLOBAL);
  if (JS_IsException(val)) return return_js_error_val(rt);
  drain_jobs_if_needed(rt);
  return to_qjs_abi_value(rt, val);
}

struct QJSABIPreparedJavaScriptOrError qjs_runtime_prepared_javascript_create(
  struct QJSABIRuntime *rt,
  const uint8_t *utf8_source,
  size_t source_length,
  const char *source_url
) {
  JSValue func_obj = JS_Eval(
    rt->ctx,
    (const char *)utf8_source,
    source_length,
    source_url ? source_url : "<eval>",
    JS_EVAL_TYPE_GLOBAL | JS_EVAL_FLAG_COMPILE_ONLY
  );

  struct QJSABIPreparedJavaScriptOrError res;
  if (JS_IsException(func_obj)) {
    record_js_exception(rt);
    res.ptr_or_error = make_error_ptr(QJSABIErrorCodeJSError);
    return res;
  }

  struct QJSABIPreparedJavaScript *prep =
    (struct QJSABIPreparedJavaScript *)malloc(sizeof(struct QJSABIPreparedJavaScript));
  prep->rt = rt;
  prep->func_obj = func_obj;
  prep->prev = NULL;
  prep->next = rt->prepared_head;
  if (rt->prepared_head) rt->prepared_head->prev = prep;
  rt->prepared_head = prep;
  res.ptr_or_error = (uintptr_t)prep;
  return res;
}

struct QJSABIValueOrError qjs_runtime_prepared_javascript_evaluate(
  struct QJSABIRuntime *rt,
  struct QJSABIPreparedJavaScript *prepared
) {
  if (!prepared) {
    struct QJSABIValueOrError res;
    res.value.kind = QJSABIValueKindError;
    res.value.data.error = QJSABIErrorCodeNativeException;
    return res;
  }
  JSValue result = JS_EvalFunction(rt->ctx, JS_DupValue(rt->ctx, prepared->func_obj));
  drain_jobs_if_needed(rt);
  return return_val_or_error(rt, result);
}

void qjs_preparedjavascript_release(struct QJSABIPreparedJavaScript *prepared) {
  if (!prepared) return;
  struct QJSABIRuntime *rt = prepared->rt;
  if (rt) {
    if (prepared->prev) {
      prepared->prev->next = prepared->next;
    } else if (rt->prepared_head == prepared) {
      rt->prepared_head = prepared->next;
    }
    if (prepared->next) {
      prepared->next->prev = prepared->prev;
    }
    prepared->prev = NULL;
    prepared->next = NULL;
    if (rt->ctx) JS_FreeValue(rt->ctx, prepared->func_obj);
    prepared->rt = NULL;
  }
  free(prepared);
}

bool qjs_runtime_drain_microtasks(struct QJSABIRuntime *rt, int max_microtasks_hint) {
  JSContext *pctx;
  int count = 0;
  while (max_microtasks_hint < 0 || count < max_microtasks_hint) {
    int err = JS_ExecutePendingJob(rt->rt, &pctx);
    if (err <= 0) return err >= 0;
    count++;
  }
  return true;
}

struct QJSABIValueOrError qjs_value_create_from_json_utf8(
  struct QJSABIRuntime *rt,
  const uint8_t *json_bytes,
  size_t length
) {
  return return_val_or_error(rt, JS_ParseJSON(rt->ctx, (const char *)json_bytes, length, "<json>"));
}

uint64_t qjs_value_get_unique_id(struct QJSABIRuntime *rt, struct QJSABIValue val) {
  (void)rt;
  if ((val.kind & QJS_ABI_POINTER_MASK) && val.data.pointer) {
    return (uint64_t)(uintptr_t)JS_VALUE_GET_PTR(get_js_value(val.data.pointer));
  }
  return (uint64_t)val.kind ^ (uint64_t)val.data.number;
}

struct QJSABIValueOrError qjs_object_from_id(struct QJSABIRuntime *rt, uint64_t id) {
  struct QJSABIManagedPointerImpl *curr = rt->pointers_head;
  while (curr) {
    if (!curr->is_atom && JS_VALUE_GET_TAG(curr->u.val) == JS_TAG_OBJECT &&
        (uint64_t)(uintptr_t)JS_VALUE_GET_PTR(curr->u.val) == id) {
      struct QJSABIValueOrError res = {
        .value = to_qjs_abi_value(rt, JS_DupValue(rt->ctx, curr->u.val))
      };
      return res;
    }
    curr = curr->next;
  }
  struct QJSABIValueOrError res = { .value = to_qjs_abi_value(rt, JS_NULL) };
  return res;
}

// Runtime error handling

void qjs_runtime_set_js_error_value(struct QJSABIRuntime *rt, struct QJSABIValue error_value) {
  if (!JS_IsUndefined(rt->last_js_error)) JS_FreeValue(rt->ctx, rt->last_js_error);
  rt->last_js_error = from_qjs_abi_value(rt, &error_value);
}

void qjs_runtime_set_native_exception_message(struct QJSABIRuntime *rt, const char *message) {
  free(rt->last_native_exception);
  rt->last_native_exception = message ? strdup(message) : NULL;
}

struct QJSABIValue qjs_runtime_get_and_clear_js_error_value(struct QJSABIRuntime *rt) {
  JSValue err = rt->last_js_error;
  rt->last_js_error = JS_UNDEFINED;
  return to_qjs_abi_value(rt, err);
}

char *qjs_runtime_get_and_clear_native_exception_message(struct QJSABIRuntime *rt) {
  char *msg = rt->last_native_exception;
  rt->last_native_exception = NULL;
  return msg;
}

// Memory management

void qjs_pointer_release(struct QJSABIManagedPointer *ptr) {
  if (ptr && ptr->vtable && ptr->vtable->invalidate) {
    ptr->vtable->invalidate(ptr);
  }
}

void qjs_pointer_release_safe(struct QJSABIManagedPointer *ptr) {
  qjs_pointer_release(ptr);
}

void qjs_register_pointer(struct QJSABIRuntime *rt, struct QJSABIManagedPointer *ptr) {
  (void)rt; (void)ptr;
}

struct QJSABIManagedPointer *qjs_managed_pointer_clone(
  struct QJSABIRuntime *rt,
  struct QJSABIManagedPointer *ptr
) {
  if (!ptr) return NULL;
  struct QJSABIManagedPointerImpl *impl = (struct QJSABIManagedPointerImpl *)ptr;
  if (impl->is_atom) {
    return (struct QJSABIManagedPointer *)create_managed_atom(rt, JS_DupAtom(rt->ctx, impl->u.atom));
  } else {
    return (struct QJSABIManagedPointer *)create_managed_pointer(rt, JS_DupValue(rt->ctx, impl->u.val));
  }
}

bool qjs_managed_pointer_strict_equals(
  struct QJSABIRuntime *rt,
  struct QJSABIManagedPointer *a,
  struct QJSABIManagedPointer *b
) {
  if (a == b) return true;
  if (!a || !b) return false;
  struct QJSABIManagedPointerImpl *implA = (struct QJSABIManagedPointerImpl *)a;
  struct QJSABIManagedPointerImpl *implB = (struct QJSABIManagedPointerImpl *)b;
  if (implA->is_atom || implB->is_atom) {
    return get_js_atom(a) == get_js_atom(b);
  }
  return JS_IsStrictEqual(rt->ctx, implA->u.val, implB->u.val) != 0;
}

// Objects

struct QJSABIObjectOrError qjs_object_create(struct QJSABIRuntime *rt) {
  struct QJSABIObjectOrError res = { .ptr_or_error = return_ptr_or_error(rt, JS_NewObject(rt->ctx)) };
  return res;
}

struct QJSABIValue qjs_object_get_property_from_value(
  struct QJSABIRuntime *rt,
  struct QJSABIObject obj,
  struct QJSABIValue key
) {
  JSValue key_val = from_qjs_abi_value(rt, &key);
  JSAtom atom = JS_ValueToAtom(rt->ctx, key_val);
  JS_FreeValue(rt->ctx, key_val);

  JSValue res = JS_GetProperty(rt->ctx, get_js_value(obj.pointer), atom);
  JS_FreeAtom(rt->ctx, atom);
  if (JS_IsException(res)) return return_js_error_val(rt);
  return to_qjs_abi_value(rt, res);
}

struct QJSABIVoidOrError qjs_object_set_property_from_value(
  struct QJSABIRuntime *rt,
  struct QJSABIObject obj,
  struct QJSABIValue key,
  struct QJSABIValue value
) {
  JSValue key_val = from_qjs_abi_value(rt, &key);
  JSAtom atom = JS_ValueToAtom(rt->ctx, key_val);
  JS_FreeValue(rt->ctx, key_val);

  int ret = JS_SetProperty(rt->ctx, get_js_value(obj.pointer), atom, from_qjs_abi_value(rt, &value));
  JS_FreeAtom(rt->ctx, atom);
  struct QJSABIVoidOrError res = { .void_or_error = return_void_or_error(rt, ret) };
  return res;
}

struct QJSABIBoolOrError qjs_object_has_property_from_value(
  struct QJSABIRuntime *rt,
  struct QJSABIObject obj,
  struct QJSABIValue key
) {
  JSValue key_val = from_qjs_abi_value(rt, &key);
  JSAtom atom = JS_ValueToAtom(rt->ctx, key_val);
  JS_FreeValue(rt->ctx, key_val);

  int ret = JS_HasProperty(rt->ctx, get_js_value(obj.pointer), atom);
  JS_FreeAtom(rt->ctx, atom);
  struct QJSABIBoolOrError res = { .bool_or_error = return_bool_or_error(rt, ret) };
  return res;
}

struct QJSABIValue qjs_object_get_property_from_propnameid(
  struct QJSABIRuntime *rt,
  struct QJSABIObject obj,
  struct QJSABIPropNameID name
) {
  JSValue res = JS_GetProperty(rt->ctx, get_js_value(obj.pointer), get_js_atom(name.pointer));
  if (JS_IsException(res)) return return_js_error_val(rt);
  return to_qjs_abi_value(rt, res);
}

struct QJSABIVoidOrError qjs_object_set_property_from_propnameid(
  struct QJSABIRuntime *rt,
  struct QJSABIObject obj,
  struct QJSABIPropNameID name,
  struct QJSABIValue value
) {
  int ret = JS_SetProperty(rt->ctx, get_js_value(obj.pointer), get_js_atom(name.pointer), from_qjs_abi_value(rt, &value));
  struct QJSABIVoidOrError res = { .void_or_error = return_void_or_error(rt, ret) };
  return res;
}

struct QJSABIBoolOrError qjs_object_has_property_from_propnameid(
  struct QJSABIRuntime *rt,
  struct QJSABIObject obj,
  struct QJSABIPropNameID name
) {
  int ret = JS_HasProperty(rt->ctx, get_js_value(obj.pointer), get_js_atom(name.pointer));
  struct QJSABIBoolOrError res = { .bool_or_error = return_bool_or_error(rt, ret) };
  return res;
}

struct QJSABIArrayOrError qjs_object_get_property_names(
  struct QJSABIRuntime *rt,
  struct QJSABIObject obj
) {
  JSPropertyEnum *tab;
  uint32_t len;
  int ret = JS_GetOwnPropertyNames(
    rt->ctx,
    &tab,
    &len,
    get_js_value(obj.pointer),
    JS_GPN_STRING_MASK | JS_GPN_SYMBOL_MASK | JS_GPN_ENUM_ONLY
  );

  struct QJSABIArrayOrError res;
  if (ret < 0) {
    record_js_exception(rt);
    res.ptr_or_error = make_error_ptr(QJSABIErrorCodeJSError);
    return res;
  }

  JSValue arr = JS_NewArray(rt->ctx);
  for (uint32_t i = 0; i < len; i++) {
    JSValue propVal = JS_AtomToValue(rt->ctx, tab[i].atom);
    JS_SetPropertyUint32(rt->ctx, arr, i, propVal);
    JS_FreeAtom(rt->ctx, tab[i].atom);
  }
  js_free(rt->ctx, tab);

  res.ptr_or_error = (uintptr_t)create_managed_pointer(rt, arr);
  return res;
}

bool qjs_object_is_function(struct QJSABIRuntime *rt, struct QJSABIObject obj) {
  return JS_IsFunction(rt->ctx, get_js_value(obj.pointer)) != 0;
}

bool qjs_object_is_array(struct QJSABIRuntime *rt, struct QJSABIObject obj) {
  (void)rt;
  return JS_IsArray(get_js_value(obj.pointer)) != 0;
}

bool qjs_object_is_arraybuffer(struct QJSABIRuntime *rt, struct QJSABIObject obj) {
  size_t size;
  return JS_GetArrayBuffer(rt->ctx, &size, get_js_value(obj.pointer)) != NULL;
}

struct QJSABIBoolOrError qjs_instance_of(
  struct QJSABIRuntime *rt,
  struct QJSABIObject obj,
  struct QJSABIFunction ctor
) {
  int ret = JS_IsInstanceOf(rt->ctx, get_js_value(obj.pointer), get_js_value(ctor.pointer));
  struct QJSABIBoolOrError res = { .bool_or_error = return_bool_or_error(rt, ret) };
  return res;
}

// Host objects

struct QJSABIObjectOrError qjs_object_create_from_host_object(
  struct QJSABIRuntime *rt,
  void *user_data,
  QJSABIHostObjectGet get_cb,
  QJSABIHostObjectSet set_cb,
  QJSABIHostObjectGetOwnKeys get_own_keys_cb,
  QJSABIHostObjectRelease release_cb
) {
  JSValue obj = JS_NewObjectClass(rt->ctx, rt->host_object_class_id);
  struct QJSABIObjectOrError res;
  if (JS_IsException(obj)) {
    res.ptr_or_error = make_error_ptr(QJSABIErrorCodeJSError);
    return res;
  }

  QJSHostObjectBridge *bridge = (QJSHostObjectBridge *)malloc(sizeof(QJSHostObjectBridge));
  bridge->user_data = user_data;
  bridge->rt = rt;
  bridge->get_cb = get_cb;
  bridge->set_cb = set_cb;
  bridge->get_own_keys_cb = get_own_keys_cb;
  bridge->release_cb = release_cb;

  JS_SetOpaque(obj, bridge);
  res.ptr_or_error = (uintptr_t)create_managed_pointer(rt, obj);
  return res;
}

// Native state

struct QJSABIVoidOrError qjs_object_set_native_state(
  struct QJSABIRuntime *rt,
  struct QJSABIObject obj,
  void *user_data,
  QJSABINativeStateRelease release_cb
) {
  QJSNativeStateBridge *b = (QJSNativeStateBridge *)malloc(sizeof(QJSNativeStateBridge));
  if (!b) {
    if (release_cb) release_cb(user_data);
    struct QJSABIVoidOrError res = { .void_or_error = make_error_ptr(QJSABIErrorCodeNativeException) };
    return res;
  }
  b->user_data = user_data;
  b->release_cb = release_cb;

  JSValue ns_obj = JS_NewObjectClass(rt->ctx, rt->native_state_class_id);
  JS_SetOpaque(ns_obj, b);
  JS_DefinePropertyValue(rt->ctx, get_js_value(obj.pointer), rt->native_state_atom, ns_obj, 0);

  struct QJSABIVoidOrError res = { .void_or_error = 0 };
  return res;
}

void *qjs_object_get_native_state_data(struct QJSABIRuntime *rt, struct QJSABIObject obj) {
  JSValue ns_obj = JS_GetProperty(rt->ctx, get_js_value(obj.pointer), rt->native_state_atom);
  if (JS_IsException(ns_obj) || JS_IsUndefined(ns_obj)) return NULL;
  QJSNativeStateBridge *b = (QJSNativeStateBridge *)JS_GetOpaque(ns_obj, rt->native_state_class_id);
  JS_FreeValue(rt->ctx, ns_obj);
  return b ? b->user_data : NULL;
}

// Functions

struct QJSABIValue qjs_function_call(
  struct QJSABIRuntime *rt,
  struct QJSABIFunction fn,
  struct QJSABIValue js_this,
  struct QJSABIValue *args,
  size_t arg_count
) {
  JSValue this_val = from_qjs_abi_value(rt, &js_this);
  JSValue stack_args[MAX_STACK_ARGS];
  JSValue *js_args = (arg_count <= MAX_STACK_ARGS)
    ? stack_args
    : (JSValue *)calloc(arg_count, sizeof(JSValue));

  for (size_t i = 0; i < arg_count; i++) {
    js_args[i] = from_qjs_abi_value(rt, &args[i]);
  }

  JSValue res = JS_Call(rt->ctx, get_js_value(fn.pointer), this_val, (int)arg_count, js_args);

  JS_FreeValue(rt->ctx, this_val);
  for (size_t i = 0; i < arg_count; i++) JS_FreeValue(rt->ctx, js_args[i]);
  if (js_args != stack_args) free(js_args);

  if (JS_IsException(res)) return return_js_error_val(rt);
  drain_jobs_if_needed(rt);
  return to_qjs_abi_value(rt, res);
}

struct QJSABIValue qjs_function_call_as_constructor(
  struct QJSABIRuntime *rt,
  struct QJSABIFunction fn,
  struct QJSABIValue *args,
  size_t arg_count
) {
  JSValue stack_args[MAX_STACK_ARGS];
  JSValue *js_args = (arg_count <= MAX_STACK_ARGS)
    ? stack_args
    : (JSValue *)calloc(arg_count, sizeof(JSValue));

  for (size_t i = 0; i < arg_count; i++) {
    js_args[i] = from_qjs_abi_value(rt, &args[i]);
  }

  JSValue res = JS_CallConstructor(rt->ctx, get_js_value(fn.pointer), (int)arg_count, js_args);

  for (size_t i = 0; i < arg_count; i++) JS_FreeValue(rt->ctx, js_args[i]);
  if (js_args != stack_args) free(js_args);

  if (JS_IsException(res)) return return_js_error_val(rt);
  drain_jobs_if_needed(rt);
  return to_qjs_abi_value(rt, res);
}

struct QJSABIFunctionOrError qjs_function_create_from_host(
  struct QJSABIRuntime *rt,
  struct QJSABIPropNameID name,
  unsigned int length,
  void *user_data,
  QJSABIHostFunctionCall call_cb,
  QJSABIHostFunctionRelease release_cb
) {
  QJSHostFunctionBridge *b = (QJSHostFunctionBridge *)malloc(sizeof(QJSHostFunctionBridge));
  b->user_data = user_data;
  b->rt = rt;
  b->call_cb = call_cb;
  b->release_cb = release_cb;

  JSValue data_obj = JS_NewObjectClass(rt->ctx, rt->host_function_class_id);
  JS_SetOpaque(data_obj, b);

  JSValue fn = JS_NewCFunctionData(rt->ctx, host_function_call, (int)length, 0, 1, &data_obj);
  JS_FreeValue(rt->ctx, data_obj);

  JSAtom name_atom = get_js_atom(name.pointer);
  if (name_atom != 0) {
    const char *name_str = JS_AtomToCString(rt->ctx, name_atom);
    if (name_str) {
      JS_DefinePropertyValueStr(rt->ctx, fn, "name", JS_NewString(rt->ctx, name_str), JS_PROP_CONFIGURABLE);
      JS_FreeCString(rt->ctx, name_str);
    }
  }

  struct QJSABIFunctionOrError res = { .ptr_or_error = (uintptr_t)create_managed_pointer(rt, fn) };
  return res;
}

// Strings

struct QJSABIStringOrError qjs_create_string_from_utf8(struct QJSABIRuntime *rt, const char *str) {
  struct QJSABIStringOrError res = { .ptr_or_error = return_ptr_or_error(rt, JS_NewString(rt->ctx, str)) };
  return res;
}

char *qjs_string_to_utf8(struct QJSABIRuntime *rt, struct QJSABIString str) {
  const char *cstr = JS_ToCString(rt->ctx, get_js_value(str.pointer));
  if (!cstr) return NULL;
  char *res = strdup(cstr);
  JS_FreeCString(rt->ctx, cstr);
  return res;
}

static struct QJSABIStringData get_utf16_string_data(struct QJSABIRuntime *rt, JSValue val) {
  if (rt->temp_string_buf) {
    JS_FreeCStringUTF16(rt->ctx, (const uint16_t *)rt->temp_string_buf);
    rt->temp_string_buf = NULL;
  }
  size_t len = 0;
  const uint16_t *ptr = JS_ToCStringLenUTF16(rt->ctx, &len, val);
  rt->temp_string_buf = (void *)ptr;

  struct QJSABIStringData res = {
    .is_ascii = false,
    .data = ptr,
    .length = len
  };
  return res;
}

struct QJSABIStringData qjs_string_get_data(struct QJSABIRuntime *rt, struct QJSABIString str) {
  return get_utf16_string_data(rt, get_js_value(str.pointer));
}

// PropNameIDs

struct QJSABIPropNameIDOrError qjs_propnameid_create_from_string(
  struct QJSABIRuntime *rt,
  struct QJSABIString str
) {
  struct QJSABIPropNameIDOrError res = {
    .ptr_or_error = (uintptr_t)create_managed_atom(rt, JS_ValueToAtom(rt->ctx, get_js_value(str.pointer)))
  };
  return res;
}

struct QJSABIPropNameIDOrError qjs_propnameid_create_from_symbol(
  struct QJSABIRuntime *rt,
  struct QJSABISymbol sym
) {
  struct QJSABIPropNameIDOrError res = {
    .ptr_or_error = (uintptr_t)create_managed_atom(rt, JS_ValueToAtom(rt->ctx, get_js_value(sym.pointer)))
  };
  return res;
}

char *qjs_propnameid_to_utf8(struct QJSABIRuntime *rt, struct QJSABIPropNameID name) {
  const char *str = JS_AtomToCString(rt->ctx, get_js_atom(name.pointer));
  if (!str) return NULL;
  char *res = strdup(str);
  JS_FreeCString(rt->ctx, str);
  return res;
}

struct QJSABIPropNameID qjs_propnameid_clone(struct QJSABIRuntime *rt, struct QJSABIPropNameID name) {
  struct QJSABIPropNameID res = {
    .pointer = (struct QJSABIManagedPointer *)create_managed_atom(rt, JS_DupAtom(rt->ctx, get_js_atom(name.pointer)))
  };
  return res;
}

bool qjs_propnameid_equals(
  struct QJSABIRuntime *rt,
  struct QJSABIPropNameID a,
  struct QJSABIPropNameID b
) {
  (void)rt;
  return get_js_atom(a.pointer) == get_js_atom(b.pointer);
}

struct QJSABIStringData qjs_propnameid_get_data(
  struct QJSABIRuntime *rt,
  struct QJSABIPropNameID prop
) {
  JSValue str = JS_AtomToString(rt->ctx, get_js_atom(prop.pointer));
  struct QJSABIStringData res = get_utf16_string_data(rt, str);
  JS_FreeValue(rt->ctx, str);
  return res;
}

static void prop_name_id_list_release(struct QJSABIPropNameIDList *list) {
  if (!list) return;
  for (size_t i = 0; i < list->size; i++) {
    qjs_pointer_release(list->props[i].pointer);
  }
  free((void *)list->props);
  free(list);
}

static const struct QJSABIPropNameIDListVTable g_prop_list_vtable = {
  prop_name_id_list_release
};

struct QJSABIPropNameIDList *qjs_propnameid_list_create(
  const struct QJSABIPropNameID *props,
  size_t size
) {
  struct QJSABIPropNameIDList *list =
    (struct QJSABIPropNameIDList *)malloc(sizeof(struct QJSABIPropNameIDList));
  list->vtable = &g_prop_list_vtable;
  list->size = size;
  list->props = props;
  return list;
}

// BigInts

struct QJSABIBigIntOrError qjs_bigint_create_from_int64(struct QJSABIRuntime *rt, int64_t value) {
  struct QJSABIBigIntOrError res = {
    .ptr_or_error = return_ptr_or_error(rt, JS_NewBigInt64(rt->ctx, value))
  };
  return res;
}

bool qjs_bigint_is_int64(struct QJSABIRuntime *rt, struct QJSABIBigInt bi) {
  JSValue val = get_js_value(bi.pointer);
  int64_t v = 0;
  if (JS_ToBigInt64(rt->ctx, &v, val) != 0) return false;
  JSValue check = JS_NewBigInt64(rt->ctx, v);
  bool eq = JS_IsStrictEqual(rt->ctx, val, check);
  JS_FreeValue(rt->ctx, check);
  return eq;
}

int64_t qjs_bigint_as_int64(struct QJSABIRuntime *rt, struct QJSABIBigInt bi) {
  int64_t v = 0;
  JS_ToBigInt64(rt->ctx, &v, get_js_value(bi.pointer));
  return v;
}

// Arrays

struct QJSABIArrayOrError qjs_array_create(struct QJSABIRuntime *rt, size_t length) {
  JSValue arr = JS_NewArray(rt->ctx);
  if (length > 0) {
    JS_SetPropertyStr(rt->ctx, arr, "length", JS_NewInt32(rt->ctx, (int32_t)length));
  }
  struct QJSABIArrayOrError res = { .ptr_or_error = return_ptr_or_error(rt, arr) };
  return res;
}

size_t qjs_array_get_length(struct QJSABIRuntime *rt, struct QJSABIArray arr) {
  JSValue lenVal = JS_GetPropertyStr(rt->ctx, get_js_value(arr.pointer), "length");
  uint32_t len = 0;
  JS_ToUint32(rt->ctx, &len, lenVal);
  JS_FreeValue(rt->ctx, lenVal);
  return (size_t)len;
}

struct QJSABIValueOrError qjs_array_value_get_at_index(
  struct QJSABIRuntime *rt,
  struct QJSABIArray arr,
  size_t index
) {
  struct QJSABIValueOrError res = {
    .value = to_qjs_abi_value(rt, JS_GetPropertyUint32(rt->ctx, get_js_value(arr.pointer), (uint32_t)index))
  };
  return res;
}

struct QJSABIVoidOrError qjs_array_value_set_at_index(
  struct QJSABIRuntime *rt,
  struct QJSABIArray arr,
  size_t index,
  struct QJSABIValue value
) {
  int ret = JS_SetPropertyUint32(rt->ctx, get_js_value(arr.pointer), (uint32_t)index, from_qjs_abi_value(rt, &value));
  struct QJSABIVoidOrError res = { .void_or_error = return_void_or_error(rt, ret) };
  return res;
}

// ArrayBuffers

typedef struct QJSArrayBufferBridge {
  void *user_data;
  QJSABIMutableBufferRelease release_cb;
} QJSArrayBufferBridge;

static void *array_buffer_realloc_cb(JSRuntime *rt, void *opaque, void *ptr, size_t size) {
  (void)rt; (void)ptr;
  if (size == 0) {
    QJSArrayBufferBridge *b = (QJSArrayBufferBridge *)opaque;
    if (b) {
      if (b->release_cb) b->release_cb(b->user_data);
      free(b);
    }
  }
  return NULL;
}

struct QJSABIArrayBufferOrError qjs_arraybuffer_create_from_external_data(
  struct QJSABIRuntime *rt,
  uint8_t *data,
  size_t size,
  void *user_data,
  QJSABIMutableBufferRelease release_cb
) {
  QJSArrayBufferBridge *b = (QJSArrayBufferBridge *)malloc(sizeof(QJSArrayBufferBridge));
  if (!b) {
    if (release_cb) release_cb(user_data);
    struct QJSABIArrayBufferOrError res = { .ptr_or_error = make_error_ptr(QJSABIErrorCodeNativeException) };
    return res;
  }
  b->user_data = user_data;
  b->release_cb = release_cb;

  JSValue ab = JS_NewArrayBuffer(rt->ctx, data, size, size, array_buffer_realloc_cb, b, false);
  if (JS_IsException(ab)) {
    if (b->release_cb) b->release_cb(b->user_data);
    free(b);
  }
  struct QJSABIArrayBufferOrError res = { .ptr_or_error = return_ptr_or_error(rt, ab) };
  return res;
}

struct QJSABIUint8PtrOrError qjs_arraybuffer_get_data(
  struct QJSABIRuntime *rt,
  struct QJSABIArrayBuffer ab
) {
  size_t size;
  uint8_t *ptr = JS_GetArrayBuffer(rt->ctx, &size, get_js_value(ab.pointer));
  struct QJSABIUint8PtrOrError res = { .is_error = (ptr == NULL), .data.val = ptr };
  return res;
}

struct QJSABISizeTOrError qjs_arraybuffer_get_size(
  struct QJSABIRuntime *rt,
  struct QJSABIArrayBuffer ab
) {
  size_t size = 0;
  uint8_t *ptr = JS_GetArrayBuffer(rt->ctx, &size, get_js_value(ab.pointer));
  struct QJSABISizeTOrError res = { .is_error = (ptr == NULL), .data.val = size };
  return res;
}
