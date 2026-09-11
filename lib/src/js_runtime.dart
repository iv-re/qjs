import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:meta/meta.dart';
import 'package:qjs/qjs.g.dart';
import 'package:qjs/src/js_error.dart';
import 'package:qjs/src/js_object.dart';
import 'package:qjs/src/js_pointer.dart';
import 'package:qjs/src/js_prepared_javascript.dart';
import 'package:qjs/src/js_runtime_config.dart';
import 'package:qjs/src/js_value.dart';

typedef _QJSRuntimeReleaseFn =
    NativeFunction<Void Function(Pointer<QJSABIRuntime>)>;

final Map<int, WeakReference<JSRuntime>> _runtimesRegistry = {};

class JSRuntime implements Finalizable {
  factory JSRuntime(Pointer<QJSABIRuntime> ptr) {
    final cached = _runtimesRegistry[ptr.address]?.target;
    if (cached != null) return cached;

    final rt = JSRuntime._(ptr);
    _runtimesRegistry[ptr.address] = WeakReference(rt);
    return rt;
  }

  JSRuntime._(this.ptr);

  JSRuntime.create([
    JSRuntimeConfig config = const JSRuntimeConfig.hardened(),
  ]) : ptr = _createRuntime(config) {
    _finalizer.attach(this, ptr.cast(), detach: this, externalSize: 512);
    _runtimesRegistry[ptr.address] = WeakReference(this);
  }

  static Pointer<QJSABIRuntime> _createRuntime(JSRuntimeConfig config) {
    final struct = Struct.create<QJSABIRuntimeConfig>()
      ..enable_eval = config.enableEval
      ..es6_proxy = config.es6Proxy
      ..microtask_queue = config.microtaskQueue
      ..memory_limit = config.memoryLimit
      ..max_stack_size = config.maxStackSize
      ..gc_threshold = config.gcThreshold;
    return qjs_runtime_create(struct);
  }

  static NativeFinalizer _createFinalizer() {
    final ptr = Native.addressOf<_QJSRuntimeReleaseFn>(
      qjs_runtime_release_from_finalizer,
    );

    return NativeFinalizer(ptr.cast());
  }

  static final NativeFinalizer _finalizer = _createFinalizer();

  @internal
  final Pointer<QJSABIRuntime> ptr;
  bool _released = false;

  bool get isReleased => _released;

  final Map<String, Object> _memoizedCache = {};

  JSObject? _globalThis;

  JSObject get global {
    return _globalThis ??= JSObject(
      JSPointer(
        this,
        qjs_runtime_get_global_object(ptr).pointer,
      ),
    );
  }

  @internal
  T memoize<T>(String key, T Function() builder) {
    final cached = _memoizedCache[key];
    if (cached != null) return cached as T;

    final value = builder();
    _memoizedCache[key] = value as Object;
    return value;
  }

  JSValue evaluateJavascript(
    String script, {
    String sourceUrl = 'script.js',
  }) => using((arena) {
    final nativeScript = script.toNativeUtf8(allocator: arena);
    final nativeSource = sourceUrl.toNativeUtf8(allocator: arena);

    final result = qjs_evaluate_javascript(
      ptr,
      nativeScript.cast(),
      nativeScript.length,
      nativeSource.cast(),
    );

    return JSValue.fromABI(this, result);
  });

  /// Prepares JavaScript source code for execution.
  JSPreparedJavaScript prepareJavaScript(
    String source, {
    String sourceUrl = 'script.js',
  }) => using((arena) {
    final nativeSourceUrl = sourceUrl.toNativeUtf8(allocator: arena);
    final nativeSource = source.toNativeUtf8(allocator: arena);
    final res = qjs_runtime_prepared_javascript_create(
      ptr,
      nativeSource.cast(),
      nativeSource.length,
      nativeSourceUrl.cast(),
    );
    return JSPreparedJavaScript(unwrapPtr(res.ptr_or_error));
  });

  /// Evaluates prepared JavaScript bytecode.
  JSValue evaluatePreparedJavaScript(JSPreparedJavaScript prepared) {
    final result = qjs_runtime_prepared_javascript_evaluate(
      ptr,
      prepared.ptr,
    );
    return JSValue.fromABI(this, result.value);
  }

  /// Drains the microtask queue.
  bool drainMicrotasks({int maxMicrotasksHint = -1}) {
    return qjs_runtime_drain_microtasks(ptr, maxMicrotasksHint);
  }

  JSValue getAndClearJSErrorValue() {
    return JSValue.fromABI(
      this,
      qjs_runtime_get_and_clear_js_error_value(ptr),
    );
  }

  String getAndClearNativeExceptionMessage() {
    final ptr = qjs_runtime_get_and_clear_native_exception_message(this.ptr);
    if (ptr == nullptr) return '';

    try {
      return ptr.cast<Utf8>().toDartString();
    } finally {
      malloc.free(ptr);
    }
  }

  Pointer<T> unwrapPtr<T extends NativeType>(int ptrOrError) {
    if ((ptrOrError & 1) != 0) {
      handleErrorCode(ptrOrError >> 2);
    }
    return Pointer.fromAddress(ptrOrError);
  }

  Pointer<QJSABIManagedPointer> unwrapManagedPtr(int ptrOrError) {
    return unwrapPtr<QJSABIManagedPointer>(ptrOrError);
  }

  bool unwrapBool(int boolOrError) {
    unwrapVoid(boolOrError);
    return (boolOrError >> 2) != 0;
  }

  void unwrapVoid(int ptrOrError) {
    if ((ptrOrError & 1) != 0) {
      handleErrorCode(ptrOrError >> 2);
    }
  }

  void handleErrorCode(int errorCode) {
    if (errorCode == QJSABIErrorCode.QJSABIErrorCodeNativeException.value) {
      throw JSNativeException(getAndClearNativeExceptionMessage());
    } else {
      throw JSException(getAndClearJSErrorValue());
    }
  }

  void setJSErrorValue(JSValue value) {
    qjs_runtime_set_js_error_value(ptr, value.ptr);
  }

  void setNativeExceptionMessage(String message) => using((arena) {
    final nativeMsg = message.toNativeUtf8(allocator: arena);
    qjs_runtime_set_native_exception_message(ptr, nativeMsg.cast());
  });

  void release() {
    if (_released) return;
    _memoizedCache.clear();
    _finalizer.detach(this);
    _runtimesRegistry.remove(ptr.address);
    qjs_runtime_release(ptr);
    _released = true;
  }
}
