import 'package:qjs/qjs.dart';
import 'package:test/test.dart';

void main() {
  group('JSSymbol', () {
    late JSRuntime rt;

    setUp(() {
      rt = JSRuntime.create();
    });

    tearDown(() {
      rt.release();
    });

    test('create and properties', () {
      final sym = JSSymbol.create(rt, 'mySymbol');
      expect(sym.getDescription(), contains('mySymbol'));
    });

    test('uniqueness and strictEquals', () {
      final sym1 = JSSymbol.create(rt, 'a');
      final sym2 = JSSymbol.create(rt, 'a');

      expect(sym1.strictEquals(sym2), isFalse); // Symbols are unique in JS
      expect(sym1.strictEquals(sym1), isTrue);
    });

    test('create without description', () {
      final sym = JSSymbol.create(rt);
      expect(sym.getDescription(), equals('Symbol()'));
    });

    test('JSSymbol.retain', () {
      final sym = JSSymbol.create(rt, 'retainTest');
      final cloned = sym.retain();
      expect(sym.strictEquals(cloned), isTrue);
      expect(cloned.getDescription(), contains('retainTest'));
    });

    test('JSSymbol as property key on JSObject', () {
      final sym = JSSymbol.create(rt, 'secret');
      final propId = JSPropNameId.fromSymbol(rt, sym);
      final obj = JSObject.create(rt)
        ..setPropertyFromPropNameId(propId, JSValue.number(rt, 123));

      expect(
        obj.getPropertyFromPropNameId(propId).asNumber,
        equals(123),
      );
    });
  });
}
