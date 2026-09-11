import 'package:qjs/qjs.dart';
import 'package:test/test.dart';

class MockHostObject extends JSHostObject {
  final Map<String, JSValue> _data = {};
  bool isReleased = false;
  bool throwGenericKeys = false;

  @override
  JSValue get(JSRuntime rt, JSPropNameId name) {
    if (name.string == 'throwError') {
      throw JSException(JSError.create(rt, 'error from mock get'));
    }
    if (name.string == 'throwGenericGet') {
      throw StateError('generic get error');
    }
    return _data[name.string] ?? JSValue.undefined(rt);
  }

  @override
  void set(JSRuntime rt, JSPropNameId name, JSValue value) {
    if (name.string == 'throwError') {
      throw JSException(JSError.create(rt, 'error from mock set'));
    }
    if (name.string == 'throwGenericSet') {
      throw StateError('generic set error');
    }
    _data[name.string] = value.retain();
  }

  @override
  List<JSPropNameId> getPropertyNames(JSRuntime rt) {
    if (throwGenericKeys) {
      throw StateError('generic keys error');
    }
    return _data.keys.map((k) => JSPropNameId.fromString(rt, k)).toList();
  }

  @override
  void release() {
    isReleased = true;
  }
}

void main() {
  group('JSObject', () {
    late JSRuntime rt;

    setUp(() {
      rt = JSRuntime.create();
    });

    tearDown(() {
      rt.release();
    });

    test('create and basic properties', () {
      final obj = JSObject.create(rt);
      obj['a'] = JSValue.number(rt, 1);
      obj['b'] = JSValue.string(rt, 's');

      expect(obj['a'].asNumber, equals(1));
      expect(obj['b'].asDartString, equals('s'));
      expect(obj['c'].isUndefined, isTrue);
    });

    test('hasProperty', () {
      final obj = JSObject.create(rt);
      obj['a'] = JSValue.number(rt, 1);
      expect(obj.hasProperty('a'), isTrue);
      expect(obj.hasProperty('b'), isFalse);
    });

    test('getPropertyNames', () {
      final obj = JSObject.create(rt);
      obj['a'] = JSValue.number(rt, 1);
      obj['b'] = JSValue.number(rt, 2);

      final namesArr = obj.getPropertyNames();
      final names = List.generate(
        namesArr.length,
        (i) => namesArr[i].asDartString,
      );

      expect(names, containsAll(['a', 'b']));
    });

    test('defineProperty', () {
      final obj = JSObject.create(rt)
        ..defineProperty(
          'readOnly',
          value: JSValue.number(rt, 42),
          writable: false,
          configurable: true,
        );

      expect(obj['readOnly'].asNumber, equals(42));

      // Try to overwrite in JS
      rt.global['obj'] = obj.asValue;
      rt.evaluateJavascript('obj.readOnly = 100;');
      expect(obj['readOnly'].asNumber, equals(42));
    });

    test('host object', () {
      final hostObj = MockHostObject();
      final obj = JSObject.createFromHostObject(rt, hostObj);

      obj['x'] = JSValue.number(rt, 10);
      expect(obj['x'].asNumber, equals(10));
      expect(hostObj._data['x']?.asNumber, equals(10));

      hostObj._data['y'] = JSValue.string(rt, 'hello');
      expect(obj['y'].asDartString, equals('hello'));
    });

    test('native state', () {
      final obj = JSObject.create(rt);
      final state = {'id': 123};
      obj.setNativeState(state);

      expect(obj.getNativeState(), equals(state));

      // Native state should not be visible as a string property in JS
      rt.global['obj'] = obj.asValue;
      expect(
        rt.evaluateJavascript('obj.__native_state__').isUndefined,
        isTrue,
      );
      final propNames = rt
          .evaluateJavascript('Object.getOwnPropertyNames(obj)')
          .asArray;
      expect(propNames.length, equals(0));
    });

    test('defineProperty with accessors', () {
      final obj = JSObject.create(rt);
      var value = 0;
      rt.global['obj'] = obj.asValue;

      obj.defineProperty(
        'prop',
        get: JSFunction.createFromHostFunction(rt, (rt, thisValue, args) {
          return JSValue.number(rt, value.toDouble());
        }),
        set: JSFunction.createFromHostFunction(rt, (rt, thisValue, args) {
          value = args[0].asNumber.toInt();
          return JSValue.undefined(rt);
        }),
      );

      rt.evaluateJavascript('obj.prop = 42', sourceUrl: 'test.js');
      expect(value, equals(42));
      expect(rt.evaluateJavascript('obj.prop').asNumber, equals(42));
    });

    test('instanceOf', () {
      rt.evaluateJavascript('globalThis.MyClass = class {}');
      final myClass = rt.global['MyClass'].asObject.asFunction;
      final inst = rt.evaluateJavascript('new MyClass()').asObject;

      expect(inst.instanceOf(myClass), isTrue);

      final other = JSObject.create(rt);
      expect(other.instanceOf(myClass), isFalse);
    });

    test('strictEquals', () {
      final obj1 = JSObject.create(rt);
      final obj2 = JSObject.create(rt);

      expect(obj1.strictEquals(obj1), isTrue);
      expect(obj1.strictEquals(obj2), isFalse);
    });

    test('getPropertyNames', () {
      final obj = JSObject.create(rt);
      obj['a'] = JSValue.number(rt, 1);
      obj['b'] = JSValue.number(rt, 2);

      final names = obj.getPropertyNames();
      expect(names.length, equals(2));
      // JS order is usually guaranteed for string keys
      expect(names[0].asDartString, equals('a'));
      expect(names[1].asDartString, equals('b'));
    });

    test('access by PropId', () {
      final obj = JSObject.create(rt);
      final pid = JSPropNameId.fromString(rt, 'test');

      obj.setPropertyFromPropNameId(pid, JSValue.number(rt, 123));
      expect(obj.hasPropertyFromPropNameId(pid), isTrue);
      expect(obj.getPropertyFromPropNameId(pid).asNumber, equals(123));
    });

    test('seal, freeze, preventExtensions via global', () {
      final obj = JSObject.create(rt);
      rt.global['o'] = obj.asValue;

      obj.preventExtensions();
      expect(
        rt.evaluateJavascript('Object.isExtensible(o)').asBoolean,
        isFalse,
      );

      obj.seal();
      expect(rt.evaluateJavascript('Object.isSealed(o)').asBoolean, isTrue);

      obj.freeze();
      expect(rt.evaluateJavascript('Object.isFrozen(o)').asBoolean, isTrue);
    });

    test('setPrototypeOf and getPrototypeOf', () {
      final parent = JSObject.create(rt);
      parent['inheritedVal'] = JSValue.number(rt, 42);

      final child = JSObject.create(rt)..setPrototypeOf(parent.asValue);

      // Verify inheritance
      expect(child['inheritedVal'].asNumber, equals(42));

      // Verify getPrototypeOf returns the parent object
      final proto = child.getPrototypeOf();
      expect(proto.asObject.strictEquals(parent), isTrue);
    });

    test('propagate JSException from host object to JS', () {
      final hostObj = MockHostObject();
      final obj = JSObject.createFromHostObject(rt, hostObj);
      rt.global['h'] = obj.asValue;

      final result = rt.evaluateJavascript('''
        try {
          h.throwError;
          "no error";
        } catch (e) {
          e.message;
        }
      ''');
      expect(result.asDartString, equals('error from mock get'));

      final setResult = rt.evaluateJavascript('''
        try {
          h.throwError = 1;
          "no error";
        } catch (e) {
          e.message;
        }
      ''');
      expect(setResult.asDartString, equals('error from mock set'));
    });

    test('host object release', () async {
      final hostObj = MockHostObject();
      {
        final rt2 = JSRuntime.create();
        JSObject.createFromHostObject(rt2, hostObj);
        rt2.release();
      }

      // Wait for release callback
      await Future<void>.delayed(.zero);

      expect(hostObj.isReleased, isTrue);
    });
    test('propagate generic Dart exceptions from host object to JS', () {
      final hostObj = MockHostObject();
      final obj = JSObject.createFromHostObject(rt, hostObj);
      rt.global['h'] = obj.asValue;

      // test get
      final getRes = rt.evaluateJavascript('''
        try {
          h.throwGenericGet;
          "no error";
        } catch (e) {
          e.toString();
        }
      ''');
      expect(getRes.asDartString, contains('generic get error'));

      // test set
      final setRes = rt.evaluateJavascript('''
        try {
          h.throwGenericSet = 1;
          "no error";
        } catch (e) {
          e.toString();
        }
      ''');
      expect(setRes.asDartString, contains('generic set error'));

      // test getPropertyNames
      hostObj.throwGenericKeys = true;
      final keysRes = rt.evaluateJavascript('''
        try {
          Object.keys(h);
          "no error";
        } catch (e) {
          e.toString();
        }
      ''');
      expect(keysRes.asDartString, contains('generic keys error'));
    });

    test('JSObject.retain', () {
      final obj = JSObject.create(rt);
      final cloned = obj.retain();
      expect(obj.strictEquals(cloned), isTrue);
    });

    test('defineProperty checks descriptor assert', () {
      final obj = JSObject.create(rt);
      expect(
        () => obj.defineProperty(
          'bad',
          value: JSValue.number(rt, 1),
          get: JSFunction.createFromHostFunction(
            rt,
            (rt, thisValue, args) => JSValue.undefined(rt),
          ),
        ),
        throwsA(isA<AssertionError>()),
      );
    });

    test('getNativeState returns null when not set', () {
      final obj = JSObject.create(rt);
      expect(obj.getNativeState(), isNull);
    });

    test('access after manual release throws StateError', () {
      final obj = JSObject.create(rt);
      obj.jsPointer.release();
      expect(obj.jsPointer.isReleased, isTrue);
      expect(() => obj.isFunction, throwsStateError);
      expect(() => obj['key'], throwsStateError);
    });
  });
}
