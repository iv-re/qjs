import 'dart:typed_data';

import 'package:qjs/qjs.dart';
import 'package:test/test.dart';

void main() {
  group('JSValue', () {
    late JSRuntime rt;

    setUp(() {
      rt = JSRuntime.create();
    });

    tearDown(() {
      rt.release();
    });

    test('number', () {
      final v = JSValue.number(rt, 42.5);
      expect(v.isNumber, isTrue);
      expect(v.asNumber, equals(42.5));
      expect(v.isString, isFalse);
    });

    test('string', () {
      final v = JSValue.string(rt, 'hello');
      expect(v.isString, isTrue);
      expect(v.asDartString, equals('hello'));
      expect(v.asDartString, equals('hello'));
      expect(v.isNumber, isFalse);
    });

    test('boolean', () {
      final vTrue = JSValue.boolean(rt, true);
      expect(vTrue.isBoolean, isTrue);
      expect(vTrue.asBoolean, isTrue);

      final vFalse = JSValue.boolean(rt, false);
      expect(vFalse.isBoolean, isTrue);
      expect(vFalse.asBoolean, isFalse);
    });

    test('null and undefined', () {
      final vNull = JSValue.null_(rt);
      expect(vNull.isNull, isTrue);
      expect(vNull.isUndefined, isFalse);

      final vUndefined = JSValue.undefined(rt);
      expect(vUndefined.isUndefined, isTrue);
      expect(vUndefined.isNull, isFalse);
    });

    test('type checking', () {
      expect(rt.evaluateJavascript('1').isNumber, isTrue);
      expect(rt.evaluateJavascript('"s"').isString, isTrue);
      expect(rt.evaluateJavascript('true').isBoolean, isTrue);
      expect(rt.evaluateJavascript('null').isNull, isTrue);
      expect(rt.evaluateJavascript('undefined').isUndefined, isTrue);
      expect(rt.evaluateJavascript('({})').isObject, isTrue);
      expect(rt.evaluateJavascript('Symbol()').isSymbol, isTrue);
      expect(rt.evaluateJavascript('1n').isBigInt, isTrue);
    });

    test('strictEquals', () {
      final n1 = JSValue.number(rt, 1);
      final n2 = JSValue.number(rt, 1);
      final n3 = JSValue.number(rt, 2);

      expect(n1.strictEquals(n2), isTrue);
      expect(n1.strictEquals(n3), isFalse);

      final s1 = JSValue.string(rt, 'test');
      final s2 = JSValue.string(rt, 'test');
      expect(s1.strictEquals(s2), isTrue);
      expect(s1.strictEquals(n1), isFalse);
    });

    test('type getter', () {
      expect(JSValue.undefined(rt).type, equals(JSValueType.undefined));
      expect(JSValue.null_(rt).type, equals(JSValueType.null_));
      expect(JSValue.boolean(rt, true).type, equals(JSValueType.boolean));
      expect(JSValue.number(rt, 1).type, equals(JSValueType.number));
      expect(JSValue.string(rt, 's').type, equals(JSValueType.string));
      expect(JSObject.create(rt).asValue.type, equals(JSValueType.object));
    });

    test('clone', () {
      final s = JSValue.string(rt, 'original');
      final s2 = s.retain();
      expect(s.strictEquals(s2), isTrue);
    });

    test('access after manual release throws StateError', () {
      final vStr = JSValue.string(rt, 'test')..release();
      expect(() => vStr.asDartString, throwsStateError);

      final vObj = JSObject.create(rt).asValue..release();
      expect(() => vObj.asObject.isFunction, throwsStateError);
      expect(() => vObj.isArray, throwsStateError);
    });

    test('asFunction variants', () {
      final fnVal = rt.evaluateJavascript('(function() {})');
      expect(fnVal.asFunctionOrNull, isNotNull);
      expect(fnVal.asFunctionUnsafe, isA<JSFunction>());

      final notFn = JSValue.number(rt, 1);
      expect(notFn.asFunctionOrNull, isNull);
    });

    test('fromJsonUtf8', () {
      final bytes = Uint8List.fromList('{"a": 1, "b": [true]}'.codeUnits);
      final val = JSValue.fromJsonUtf8(rt, bytes);
      expect(val.isObject, isTrue);
      expect(val.asObject['a'].asNumber, equals(1));
      expect(val.asObject['b'].asArray[0].asBoolean, isTrue);
    });

    test('uniqueId and JSObject.fromId', () {
      final obj1 = JSObject.create(rt);
      final obj2 = JSObject.create(rt);
      final id1 = obj1.asValue.uniqueId;
      final id2 = obj2.asValue.uniqueId;
      expect(id1, isNot(equals(0)));
      expect(id1, isNot(equals(id2)));

      final retrieved1 = JSObject.fromId(rt, id1);
      expect(retrieved1, isNotNull);
      expect(retrieved1!.strictEquals(obj1), isTrue);

      final retrievedNone = JSObject.fromId(rt, 999999);
      expect(retrievedNone, isNull);
    });

    test('mismatched type cast throws StateError', () {
      final vNum = JSValue.number(rt, 1);
      final vStr = JSValue.string(rt, 'abc');
      final vObj = JSObject.create(rt).asValue;
      final vBool = JSValue.boolean(rt, true);

      expect(() => vNum.asBoolean, throwsStateError);
      expect(() => vNum.asString, throwsStateError);
      expect(() => vNum.asDartString, throwsStateError);
      expect(() => vNum.asObject, throwsStateError);
      expect(() => vNum.asSymbol, throwsStateError);
      expect(() => vNum.asBigInt, throwsStateError);
      expect(() => vNum.asArray, throwsStateError);
      expect(() => vNum.asArrayBuffer, throwsStateError);

      expect(() => vStr.asNumber, throwsStateError);
      expect(() => vObj.asNumber, throwsStateError);
      expect(() => vBool.asNumber, throwsStateError);
    });

    test('strictEquals other types', () {
      final sym1 = JSSymbol.create(rt, 'a');
      final sym2 = JSSymbol.create(rt, 'a');
      final vSym1 = JSValue.fromSymbol(sym1);
      final vSym2 = JSValue.fromSymbol(sym2);
      expect(vSym1.strictEquals(vSym2), isFalse);
      expect(vSym1.strictEquals(vSym1), isTrue);

      final bi1 = JSBigInt.fromInt(rt, 100);
      final bi2 = JSBigInt.fromInt(rt, 200);
      final vBi1 = JSValue.fromBigInt(bi1);
      final vBi2 = JSValue.fromBigInt(bi2);
      expect(vBi1.strictEquals(vBi2), isFalse);
      expect(vBi1.strictEquals(vBi1), isTrue);
    });

    test('fromJsonUtf8 with invalid JSON throws exception', () {
      final bytes = Uint8List.fromList('{invalid_json}'.codeUnits);
      expect(() => JSValue.fromJsonUtf8(rt, bytes), throwsA(anything));
    });

    test('isArray and isArrayBuffer on non-objects', () {
      final vNum = JSValue.number(rt, 123);
      expect(vNum.isArray, isFalse);
      expect(vNum.isArrayBuffer, isFalse);
    });

    test('retain other types', () {
      final sym = JSSymbol.create(rt, 'test');
      final vSym = JSValue.fromSymbol(sym);
      final vSymCloned = vSym.retain();
      expect(vSymCloned.isSymbol, isTrue);

      final bi = JSBigInt.fromInt(rt, 5);
      final vBi = JSValue.fromBigInt(bi);
      final vBiCloned = vBi.retain();
      expect(vBiCloned.isBigInt, isTrue);

      final vNull = JSValue.null_(rt);
      final vNullCloned = vNull.retain();
      expect(vNullCloned.isNull, isTrue);

      final vUndef = JSValue.undefined(rt);
      final vUndefCloned = vUndef.retain();
      expect(vUndefCloned.isUndefined, isTrue);
    });
  });
}
