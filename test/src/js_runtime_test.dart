import 'package:qjs/qjs.dart';
import 'package:test/test.dart';

void main() {
  group('JSRuntime', () {
    late JSRuntime rt;

    setUp(() {
      rt = JSRuntime.create();
    });

    tearDown(() {
      rt.release();
    });

    test('create and release', () {
      // setUp and tearDown handle this
    });

    test('evaluateJavascript returns value', () {
      final result = rt.evaluateJavascript('1 + 1');
      expect(result.isNumber, isTrue);
      expect(result.asNumber, equals(2));
    });

    test('evaluateJavascript sets sourceUrl', () {
      try {
        rt.evaluateJavascript(
          'throw new Error("test")',
          sourceUrl: 'my_script.js',
        );
        fail('Should have thrown JSException');
      } on JSException catch (e) {
        expect(e.value.isObject, isTrue);
        final error = e.value.asObject;
        expect(error['stack'].asDartString, contains('my_script.js'));
      }
    });

    test('global object is accessible', () {
      final global = rt.global;
      expect(global.asValue.isObject, isTrue);

      rt.evaluateJavascript('var x = 42;');
      expect(rt.global['x'].asNumber, equals(42));
    });

    test('drainMicrotasks', () {
      final rtMicro = JSRuntime.create(
        const JSRuntimeConfig(microtaskQueue: true),
      );
      try {
        rtMicro.evaluateJavascript('''
          var result = [];
          Promise.resolve().then(() => {
            result.push(1);
          });
        ''');
        expect(
          rtMicro.evaluateJavascript('result.length').asNumber,
          equals(0),
        );

        final didDrain = rtMicro.drainMicrotasks();
        expect(didDrain, isTrue);

        expect(rtMicro.evaluateJavascript('result[0]').asNumber, equals(1));
      } finally {
        rtMicro.release();
      }
    });

    test('evaluateJavascript with syntax error', () {
      expect(
        () => rt.evaluateJavascript('invalid syntax'),
        throwsA(anyOf(isA<JSException>(), isA<JSNativeException>())),
      );
    });

    test('memoize cache logic', () {
      var builderCalled = 0;
      final val1 = rt.memoize('my_key', () {
        builderCalled++;
        return JSValue.number(rt, 42);
      });
      final val2 = rt.memoize('my_key', () {
        builderCalled++;
        return JSValue.number(rt, 100);
      });

      expect(builderCalled, equals(1));
      expect(val1.asNumber, equals(42));
      expect(val2.asNumber, equals(42));
    });

    test('drainMicrotasks returns true when not configured/empty', () {
      // rt is created without microtaskQueue config.
      expect(rt.drainMicrotasks(), isTrue);
    });

    test('multiple release does not throw', () {
      final tempRt = JSRuntime.create();
      expect(tempRt.release, returnsNormally);
      expect(tempRt.release, returnsNormally);
    });
  });
}
