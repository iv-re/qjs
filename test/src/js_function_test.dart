import 'package:qjs/qjs.dart';
import 'package:test/test.dart';

void main() {
  group('JSFunction', () {
    late JSRuntime rt;

    setUp(() {
      rt = JSRuntime.create();
    });

    tearDown(() {
      rt.release();
    });

    test('call JS function from Dart', () {
      final fnValue = rt.evaluateJavascript('(a, b) => a + b');
      expect(fnValue.isObject, isTrue);

      final fn = fnValue.asObject.asFunction;
      final result = fn([
        JSValue.number(rt, 10),
        JSValue.number(rt, 20),
      ]);

      expect(result.asNumber, equals(30));
    });

    test('call host function from JS', () {
      final hostFn = JSFunction.createFromHostFunction(rt, (
        rt,
        thisValue,
        args,
      ) {
        final sum = args.fold<double>(0, (prev, curr) => prev + curr.asNumber);
        return JSValue.number(rt, sum);
      });

      rt.global['sum'] = hostFn.asValue;

      final result = rt.evaluateJavascript('sum(1, 2, 3)');
      expect(result.asNumber, equals(6));
    });

    test('call as constructor', () {
      rt.evaluateJavascript('function Point(x, y) { this.x = x; this.y = y; }');
      final pointCtor = rt.global['Point'].asObject.asFunction;

      final point = pointCtor.callAsConstructor([
        JSValue.number(rt, 1),
        JSValue.number(rt, 2),
      ]);

      expect(point.isObject, isTrue);
      final obj = point.asObject;
      expect(obj['x'].asNumber, equals(1));
      expect(obj['y'].asNumber, equals(2));
    });

    test('host function exception handling', () {
      final hostFn = JSFunction.createFromHostFunction(rt, (
        rt,
        thisValue,
        args,
      ) {
        throw JSException(JSError.typeError(rt, 'custom error').value);
      });

      rt.global['fail'] = hostFn.asValue;

      expect(
        () => rt.evaluateJavascript('fail()'),
        throwsA(isA<JSException>()),
      );
    });

    test('host function name and length', () {
      final fn = JSFunction.createFromHostFunction(
        rt,
        (rt, thisValue, args) => JSValue.undefined(rt),
        name: 'myFunction',
        length: 3,
      );

      rt.global['myFn'] = fn.asValue;
      expect(
        rt.evaluateJavascript('myFn.name').asDartString,
        equals('myFunction'),
      );
      expect(rt.evaluateJavascript('myFn.length').asNumber, equals(3));
    });

    test('host function thisValue', () {
      final obj = JSObject.create(rt);
      late JSValue receivedThis;

      JSFunction.createFromHostFunction(rt, (rt, thisValue, args) {
        receivedThis = thisValue.retain();
        return JSValue.undefined(rt);
      }).call([], obj.asValue);

      expect(receivedThis.asObject.strictEquals(obj), isTrue);
    });

    test('propagate JSException from host function to JS', () {
      final fn = JSFunction.createFromHostFunction(rt, (rt, thisValue, args) {
        throw JSException(JSError.create(rt, 'error from dart'));
      });
      rt.global['throwFn'] = fn.asValue;

      final result = rt.evaluateJavascript('''
        try {
          throwFn();
          "no error";
        } catch (e) {
          e.message;
        }
      ''');
      expect(result.asDartString, equals('error from dart'));
    });

    test('propagate generic exception from host function to JS', () {
      final fn = JSFunction.createFromHostFunction(rt, (rt, thisValue, args) {
        throw StateError('dart state error');
      });
      rt.global['throwFn'] = fn.asValue;

      final result = rt.evaluateJavascript('''
        try {
          throwFn();
          "no error";
        } catch (e) {
          e.toString();
        }
      ''');
      // Generic Dart exceptions are wrapped in native exception message
      expect(result.asDartString, contains('dart state error'));
    });

    test('call with no args uses empty list', () {
      final fn = JSFunction.createFromHostFunction(
        rt,
        (rt, thisValue, args) => JSValue.number(rt, args.length.toDouble()),
      );
      final result = fn.call();
      expect(result.asNumber, equals(0));
    });

    test('JSFunction.retain', () {
      final fn = JSFunction.createFromHostFunction(
        rt,
        (rt, thisValue, args) => JSValue.undefined(rt),
      );
      final cloned = fn.retain();
      expect(fn.asValue.strictEquals(cloned.asValue), isTrue);
    });

    test('host function JSNativeException propagation', () {
      final fn = JSFunction.createFromHostFunction(rt, (rt, thisValue, args) {
        throw JSNativeException('native error message');
      });
      rt.global['nativeFail'] = fn.asValue;

      final result = rt.evaluateJavascript('''
        try {
          nativeFail();
          "no error";
        } catch (e) {
          e.toString();
        }
      ''');
      expect(result.asDartString, contains('native error message'));
    });
  });
}
