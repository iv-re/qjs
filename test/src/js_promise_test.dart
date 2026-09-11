import 'dart:async';

import 'package:qjs/qjs.dart';
import 'package:test/test.dart';

void main() {
  group('JSPromise', () {
    late JSRuntime rt;

    setUp(() {
      rt = JSRuntime.create();
    });

    tearDown(() {
      rt.release();
    });

    test('withResolvers', () async {
      _installSetImmediate(rt);

      final (promise, resolve, _) = JSPromise.withResolvers(rt);

      rt.global['p'] = promise;
      rt.evaluateJavascript('p.then(v => { globalThis.result = v; })');

      resolve([JSValue.number(rt, 123)]);

      await Future<void>.delayed(const Duration(milliseconds: 50));

      rt.evaluateJavascript('globalThis.result');
    });

    test('fromAsyncFunction', () async {
      final promise = JSPromise.fromAsyncFunction(rt, () async {
        await Future<void>.delayed(const Duration(milliseconds: 10));
        return JSValue.number(rt, 42);
      });

      rt.global['p'] = promise;
      rt.evaluateJavascript('p.then(v => { globalThis.asyncResult = v; })');

      _installSetImmediate(rt);

      await Future<void>.delayed(const Duration(milliseconds: 50));
      final result = rt.evaluateJavascript('globalThis.asyncResult');
      expect(result.asNumber, equals(42));
    });

    test('fromAsyncFunction error handling', () async {
      final promise = JSPromise.fromAsyncFunction(rt, () async {
        throw JSException(JSValue.string(rt, 'custom error'));
      });

      rt.global['p'] = promise;
      rt.evaluateJavascript('p.catch(e => { globalThis.errorResult = e; })');

      _installSetImmediate(rt);

      await Future<void>.delayed(const Duration(milliseconds: 50));
      final result = rt.evaluateJavascript('globalThis.errorResult');
      expect(result.asDartString, equals('custom error'));
    });

    test('fromAsyncFunction generic Dart error rejection', () async {
      final promise = JSPromise.fromAsyncFunction(rt, () async {
        throw StateError('some dart error');
      });

      rt.global['p'] = promise;
      rt.evaluateJavascript(
        'p.catch(e => { globalThis.genericErr = e.message; })',
      );

      _installSetImmediate(rt);

      await Future<void>.delayed(const Duration(milliseconds: 50));
      final errMsg = rt.evaluateJavascript('globalThis.genericErr');
      expect(errMsg.asDartString, contains('some dart error'));
    });
  });
}

void _installSetImmediate(JSRuntime rt) {
  final setImmediate = JSFunction.createFromHostFunction(rt, (
    rt,
    thisValue,
    args,
  ) {
    final callback = args[0].asObject.asFunction.retain();
    scheduleMicrotask(() {
      try {
        callback([]);
      } finally {
        callback.jsPointer.release();
      }
    });
    return JSValue.undefined(rt);
  });
  rt.global['setImmediate'] = setImmediate.asValue;
}
