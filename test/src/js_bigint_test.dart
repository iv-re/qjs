import 'package:qjs/qjs.dart';
import 'package:test/test.dart';

void main() {
  group('JSBigInt', () {
    late JSRuntime rt;

    setUp(() {
      rt = JSRuntime.create();
    });

    tearDown(() {
      rt.release();
    });

    test('create and convert', () {
      final bi = JSBigInt.fromInt(rt, 123456789);
      expect(bi.isInt(), isTrue);
      expect(bi.asInt(), equals(123456789));
      expect(bi.toRadixString(), equals('123456789'));

      final large = BigInt.parse('123456789012345678901234567890');
      final bi2 = JSBigInt.fromBigInt(rt, large);
      expect(bi2.isInt(), isFalse);
      expect(bi2.toBigInt(), equals(large));
    });

    test('strictEquals', () {
      final bi1 = JSBigInt.fromInt(rt, 100);
      final bi2 = JSBigInt.fromInt(rt, 100);
      final bi3 = JSBigInt.fromInt(rt, 200);

      expect(bi1.strictEquals(bi2), isTrue);
      expect(bi1.strictEquals(bi3), isFalse);
    });

    test('asInt throws on large BigInt', () {
      final large = BigInt.parse('99999999999999999999999999999');
      final bi = JSBigInt.fromBigInt(rt, large);
      expect(bi.isInt(), isFalse);
      expect(bi.asInt, throwsStateError);
    });

    test('toRadixString with non-10 radix', () {
      final bi = JSBigInt.fromInt(rt, 255);
      expect(bi.toRadixString(radix: 16), equals('ff'));
      expect(bi.toRadixString(radix: 2), equals('11111111'));
    });

    test('retain BigInt', () {
      final bi = JSBigInt.fromInt(rt, 42);
      final cloned = bi.retain();
      expect(bi.strictEquals(cloned), isTrue);
    });

    test('fromBigInt with negative value', () {
      final bi = JSBigInt.fromBigInt(rt, BigInt.from(-100));
      expect(bi.isInt(), isTrue);
      expect(bi.asInt(), equals(-100));
    });
  });
}
