import 'package:qjs/qjs.dart';
import 'package:test/test.dart';

void main() {
  group('JSError', () {
    late JSRuntime rt;

    setUp(() {
      rt = JSRuntime.create();
    });

    tearDown(() {
      rt.release();
    });

    test('create errors', () {
      final err = JSError.create(rt, 'msg');
      expect(err.isObject, isTrue);
      expect(err.asObject['message'].asDartString, equals('msg'));

      final typeErr = JSError.typeError(rt, 'type msg');
      rt.global['typeErr'] = typeErr;
      expect(
        rt.evaluateJavascript('typeErr instanceof TypeError').asBoolean,
        isTrue,
      );

      final rangeErr = JSError.rangeError(rt, 'range msg');
      rt.global['rangeErr'] = rangeErr;
      expect(
        rt.evaluateJavascript('rangeErr instanceof RangeError').asBoolean,
        isTrue,
      );

      final refErr = JSError.referenceError(rt, 'ref msg');
      rt.global['refErr'] = refErr;
      expect(
        rt.evaluateJavascript('refErr instanceof ReferenceError').asBoolean,
        isTrue,
      );

      final syntaxErr = JSError.syntaxError(rt, 'syntax msg');
      rt.global['syntaxErr'] = syntaxErr;
      expect(
        rt.evaluateJavascript('syntaxErr instanceof SyntaxError').asBoolean,
        isTrue,
      );

      final uriErr = JSError.uriError(rt, 'uri msg');
      rt.global['uriErr'] = uriErr;
      expect(
        rt.evaluateJavascript('uriErr instanceof URIError').asBoolean,
        isTrue,
      );
    });

    test('JSException toString', () {
      final err = JSError.create(rt, 'failure');
      final ex = JSException(err);
      expect(ex.toString(), contains('JSException: failure'));
    });

    test('catch error from JS', () {
      expect(
        () => rt.evaluateJavascript('throw new TypeError("bad type")'),
        throwsA(
          isA<JSException>().having(
            (e) => e.value.asObject['message'].asDartString,
            'message',
            'bad type',
          ),
        ),
      );
    });

    test('JSException.toString with string value', () {
      final ex = JSException(JSValue.string(rt, 'thrown string'));
      expect(ex.toString(), equals('JSException: thrown string'));
    });

    test('JSException.toString with non-string primitive', () {
      final ex = JSException(JSValue.number(rt, 42));
      expect(ex.toString(), contains('JSException:'));
    });

    test('JSException.toString with object without message', () {
      final obj = JSObject.create(rt).asValue;
      final ex = JSException(obj);
      expect(ex.toString(), contains('JSException: [object]'));
    });

    test('JSNativeException toString', () {
      final ex = JSNativeException('native failure');
      expect(ex.toString(), equals('JSNativeException: native failure'));
    });

    test('JSError.retain keeps same object', () {
      final err = JSError.create(rt, 'original');
      final cloned = err.retain();
      expect(
        err.asObject['message'].asDartString,
        equals(cloned.asObject['message'].asDartString),
      );
    });
  });
}
