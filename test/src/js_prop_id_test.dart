import 'package:qjs/qjs.dart';
import 'package:test/test.dart';

void main() {
  group('JSPropNameId', () {
    late JSRuntime rt;

    setUp(() {
      rt = JSRuntime.create();
    });

    tearDown(() {
      rt.release();
    });

    test('create from string and symbol', () {
      final pid1 = JSPropNameId.fromString(rt, 'prop');
      expect(pid1.string, equals('prop'));

      final sym = JSSymbol.create(rt, 'sym');
      final pid2 = JSPropNameId.fromSymbol(rt, sym);
      expect(pid2.string, contains('sym'));
    });

    test('unicode propId', () {
      final pid = JSPropNameId.fromString(rt, 'Привет');
      expect(pid.string, equals('Привет'));
    });

    test('equals', () {
      final pid1 = JSPropNameId.fromString(rt, 'a');
      final pid2 = JSPropNameId.fromString(rt, 'a');
      final pid3 = JSPropNameId.fromString(rt, 'b');

      expect(pid1.equals(pid2), isTrue);
      expect(pid1.equals(pid3), isFalse);
    });

    test('clone', () {
      final pid = JSPropNameId.fromString(rt, 'test');
      final cloned = pid.retain();
      expect(cloned.equals(pid), isTrue);
      expect(cloned.string, equals('test'));
    });

    test('fromABI round-trip via host object', () {
      String? capturedName;
      final hostObj = _CapturingHostObject(
        onGet: (rt, name) {
          capturedName = name.string;
          return JSValue.undefined(rt);
        },
      );
      final obj = JSObject.createFromHostObject(rt, hostObj);
      rt.global['o'] = obj.asValue;
      rt.evaluateJavascript('o.myPropName');
      expect(capturedName, equals('myPropName'));
    });

    test('empty string propId', () {
      final pid = JSPropNameId.fromString(rt, '');
      expect(pid.string, equals(''));
    });
  });
}

class _CapturingHostObject extends JSHostObject {
  _CapturingHostObject({required this.onGet});

  final JSValue Function(JSRuntime rt, JSPropNameId name) onGet;

  @override
  JSValue get(JSRuntime rt, JSPropNameId name) => onGet(rt, name);

  @override
  void set(JSRuntime rt, JSPropNameId name, JSValue value) {}

  @override
  List<JSPropNameId> getPropertyNames(JSRuntime rt) => [];

  @override
  void release() {}
}
