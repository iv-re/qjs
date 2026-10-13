import 'dart:async';
import 'dart:isolate';

import 'package:qjs/qjs.dart';
import 'package:test/test.dart';

Matcher get _throwsInterrupted => throwsA(
  isA<JSException>().having(
    (e) => e.value.asObject['message'].asDartString,
    'message',
    'interrupted',
  ),
);

void main() {
  late JSRuntime rt;

  setUp(() {
    rt = JSRuntime.create();
  });

  tearDown(() {
    rt.release();
  });

  group('deadline', () {
    test('interrupts an infinite loop', () {
      rt.setDeadline(const Duration(milliseconds: 50));
      final sw = Stopwatch()..start();
      expect(
        () => rt.evaluateJavascript('while (true) {}'),
        _throwsInterrupted,
      );
      expect(sw.elapsed, lessThan(const Duration(seconds: 5)));
    });

    test('cannot be caught by the script', () {
      rt.setDeadline(const Duration(milliseconds: 50));
      expect(
        () => rt.evaluateJavascript(
          'try { while (true) {} } catch (e) { "caught" }',
        ),
        _throwsInterrupted,
      );
    });

    test('stays in effect until cleared', () {
      rt.setDeadline(const Duration(milliseconds: 50));
      expect(
        () => rt.evaluateJavascript('while (true) {}'),
        _throwsInterrupted,
      );
      expect(
        () => rt.evaluateJavascript('for (let i = 0; i < 1e6; i++) {}'),
        _throwsInterrupted,
      );

      rt.clearDeadline();
      expect(rt.evaluateJavascript('1 + 1').asNumber, 2);
    });

    test('does not affect code that finishes in time', () {
      rt.setDeadline(const Duration(seconds: 30));
      expect(
        rt
            .evaluateJavascript(
              'let s = 0; for (let i = 0; i < 1e5; i++) s++; s',
            )
            .asNumber,
        1e5,
      );
    });
  });

  group('interrupt in microtasks', () {
    test('is thrown from the call that ran them', () {
      rt.setDeadline(const Duration(milliseconds: 50));
      expect(
        () => rt.evaluateJavascript(
          '(async () => { await null; while (true) {} })(); "sync part done"',
        ),
        _throwsInterrupted,
      );
    });

    test('is thrown from drainMicrotasks', () {
      final queued = JSRuntime.create(
        const JSRuntimeConfig(microtaskQueue: true),
      );
      addTearDown(queued.release);

      queued.evaluateJavascript(
        '(async () => { await null; while (true) {} })()',
      );
      queued.setDeadline(const Duration(milliseconds: 50));
      expect(queued.drainMicrotasks, _throwsInterrupted);

      queued.clearDeadline();
      expect(queued.drainMicrotasks(), isTrue);
    });

    test('after awaiting a host call goes to onMicrotaskError', () async {
      final errors = Completer<JSException>();
      rt
        ..onMicrotaskError = errors.complete
        ..global['tool'] = JSFunction.createFromHostFunction(rt, (rt, _, _) {
          return JSPromise.fromAsyncFunction(rt, () async {
            await Future<void>.delayed(const Duration(milliseconds: 20));
            return JSValue.number(rt, 1);
          });
        }).asValue
        ..setDeadline(const Duration(milliseconds: 300));

      rt.evaluateJavascript(
        '(async () => { await tool(); while (true) {} })(); undefined',
      );
      final error = await errors.future.timeout(const Duration(seconds: 5));
      expect(error.value.asObject['message'].asDartString, 'interrupted');
    });
  });

  group('requestInterrupt', () {
    test('interrupts from another isolate', () async {
      final handle = rt.interruptHandle;
      await Isolate.spawn((JSInterruptHandle handle) async {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        handle.requestInterrupt();
      }, handle);

      // Safety net so a broken implementation fails instead of hanging.
      rt.setDeadline(const Duration(seconds: 10));
      final sw = Stopwatch()..start();
      expect(
        () => rt.evaluateJavascript('while (true) {}'),
        _throwsInterrupted,
      );
      expect(sw.elapsed, lessThan(const Duration(seconds: 5)));
    });

    test('interrupts only once', () {
      rt.requestInterrupt();
      expect(
        () => rt.evaluateJavascript('while (true) {}'),
        _throwsInterrupted,
      );
      expect(
        rt.evaluateJavascript('for (let i = 0; i < 1e5; i++) {} 42').asNumber,
        42,
      );
    });

    test('returns false after the runtime is released', () {
      final other = JSRuntime.create();
      final handle = other.interruptHandle;
      expect(handle.requestInterrupt(), isTrue);
      other.release();
      expect(handle.requestInterrupt(), isFalse);
    });
  });

  group('memoryUsage', () {
    test('reports allocations and the configured limit', () {
      final limited = JSRuntime.create(
        const JSRuntimeConfig(memoryLimit: 16 * 1024 * 1024),
      );
      addTearDown(limited.release);

      final before = limited.memoryUsage;
      expect(before.mallocLimit, 16 * 1024 * 1024);
      expect(before.mallocSize, greaterThan(0));

      limited.evaluateJavascript(
        'globalThis.big = Array.from({ length: 10000 }, (_, i) => ({ i }))',
      );
      final after = limited.memoryUsage;
      expect(after.mallocSize, greaterThan(before.mallocSize));
      expect(after.objectCount, greaterThan(before.objectCount + 10000 - 1));
    });
  });

  group('runGC', () {
    test('collects unreachable cycles', () {
      // A high threshold keeps the automatic GC from running first.
      final noAutoGC = JSRuntime.create(
        const JSRuntimeConfig(gcThreshold: 1 << 30),
      );
      addTearDown(noAutoGC.release);

      noAutoGC.evaluateJavascript('''
        for (let i = 0; i < 1000; i++) {
          const a = {};
          const b = { a };
          a.b = b;
        }
      ''');
      final before = noAutoGC.memoryUsage.objectCount;
      noAutoGC.runGC();
      expect(
        noAutoGC.memoryUsage.objectCount,
        lessThanOrEqualTo(before - 2000),
      );
    });
  });

  group('onUnhandledRejection', () {
    test('reports rejections and later handling', () {
      final events = <(String, bool)>[];
      rt.onUnhandledRejection = (promise, reason, isHandled) {
        expect(promise.isObject, isTrue);
        events.add((reason.asObject['message'].asDartString, isHandled));
      };

      rt.evaluateJavascript('globalThis.p = Promise.reject(new Error("boom"))');
      expect(events, [('boom', false)]);

      rt.evaluateJavascript('p.catch(() => {})');
      expect(events, [('boom', false), ('boom', true)]);
    });

    test('reports rejections from async host functions', () async {
      final reasons = <String>[];
      rt.onUnhandledRejection = (promise, reason, isHandled) {
        if (!isHandled) reasons.add(reason.asObject['message'].asDartString);
      };
      rt.global['tool'] = JSFunction.createFromHostFunction(rt, (rt, _, _) {
        return JSPromise.fromAsyncFunction(rt, () async {
          throw JSException(JSError.create(rt, 'tool failed'));
        });
      }).asValue;

      rt.evaluateJavascript('tool(); undefined');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      rt.drainMicrotasks();
      expect(reasons, contains('tool failed'));
    });

    test('stops reporting when set to null', () {
      var calls = 0;
      rt.onUnhandledRejection = (_, _, _) => calls++;
      rt.onUnhandledRejection = null;
      rt.evaluateJavascript('Promise.reject(1)');
      expect(calls, 0);
    });

    test('values outlive the callback', () {
      JSValue? saved;
      rt.onUnhandledRejection = (promise, reason, isHandled) {
        saved = reason;
      };
      rt.evaluateJavascript('Promise.reject({ code: 7 })');
      expect(saved!.asObject['code'].asNumber, 7);
    });
  });
}
