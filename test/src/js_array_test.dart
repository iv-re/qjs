import 'package:qjs/qjs.dart';
import 'package:test/test.dart';

void main() {
  group('JSArray', () {
    late JSRuntime rt;

    setUp(() {
      rt = JSRuntime.create();
    });

    tearDown(() {
      rt.release();
    });

    test('create and length', () {
      final arr = JSArray.create(rt, 5);
      expect(arr.length, equals(5));
    });

    test('indexed access', () {
      final arr = JSArray.create(rt, 2);
      arr[0] = JSValue.number(rt, 10);
      arr[1] = JSValue.string(rt, 'test');

      expect(arr[0].asNumber, equals(10));
      expect(arr[1].asDartString, equals('test'));
    });

    test('add', () {
      final arr = JSArray.create(rt)
        ..add(JSValue.number(rt, 1))
        ..add(JSValue.number(rt, 2));

      expect(arr.length, equals(2));
      expect(arr[0].asNumber, equals(1));
      expect(arr[1].asNumber, equals(2));
    });

    test('is array check', () {
      final arr = JSArray.create(rt);
      expect(arr.asValue.isArray, isTrue);

      final obj = JSObject.create(rt);
      expect(obj.asValue.isArray, isFalse);
    });

    test('add and clone', () {
      final array = JSArray.create(rt)
        ..add(JSValue.number(rt, 1))
        ..add(JSValue.number(rt, 2));

      expect(array.length, equals(2));
      expect(array[1].asNumber, equals(2));

      final cloned = array.retain();
      expect(cloned.length, equals(2));
      expect(cloned[0].asNumber, equals(1));
    });

    test('length setter resize', () {
      final arr = JSArray.create(rt, 3);
      expect(arr.length, equals(3));

      arr.length = 1;
      expect(arr.length, equals(1));

      arr.length = 5;
      expect(arr.length, equals(5));
      expect(arr[4].isUndefined, isTrue);
    });

    test('asList live view basics', () {
      final arr = JSArray.create(rt);
      final list = arr.asList;

      expect(list.length, equals(0));
      list
        ..add(JSValue.number(rt, 1.5))
        ..add(JSValue.string(rt, 'hello'));

      expect(list.length, equals(2));
      expect(arr.length, equals(2));
      expect(list[0].asNumber, equals(1.5));
      expect(list[1].asDartString, equals('hello'));

      list[0] = JSValue.number(rt, 2.5);
      expect(arr[0].asNumber, equals(2.5));

      list.length = 1;
      expect(list.length, equals(1));
      expect(arr.length, equals(1));
    });

    test('asList live view advanced mutations', () {
      final arr = JSArray.create(rt);
      final list = arr.asList
        ..addAll([
          JSValue.number(rt, 10),
          JSValue.number(rt, 20),
          JSValue.number(rt, 30),
        ]);
      expect(list.length, equals(3));
      expect(list[0].asNumber, equals(10));
      expect(list[2].asNumber, equals(30));

      final last = list.removeLast();
      expect(last.asNumber, equals(30));
      expect(list.length, equals(2));

      list.insert(1, JSValue.number(rt, 15));
      expect(list.length, equals(3));
      expect(list[0].asNumber, equals(10));
      expect(list[1].asNumber, equals(15));
      expect(list[2].asNumber, equals(20));

      final removed = list.removeAt(1);
      expect(removed.asNumber, equals(15));
      expect(list.length, equals(2));
      expect(list[0].asNumber, equals(10));
      expect(list[1].asNumber, equals(20));

      list.clear();
      expect(list.length, equals(0));
      expect(arr.length, equals(0));
    });

    test('asList out of bounds and invalid mutations', () {
      final arr = JSArray.create(rt);
      final list = arr.asList;

      // removeLast on empty list
      expect(list.removeLast, throwsStateError);

      // removeAt out of bounds
      expect(() => list.removeAt(0), throwsRangeError);
      expect(() => list.removeAt(-1), throwsRangeError);

      // insert out of bounds
      expect(() => list.insert(1, JSValue.number(rt, 1)), throwsRangeError);
      expect(() => list.insert(-1, JSValue.number(rt, 1)), throwsRangeError);

      // operator [] and []= negative or invalid indices behavior
      expect(arr[-1].isUndefined, isTrue);
      expect(arr[100].isUndefined, isTrue);

      expect(() => arr[-1] = JSValue.number(rt, 1), returnsNormally);
      expect(() => arr[100] = JSValue.number(rt, 1), returnsNormally);
      expect(arr[100].asNumber, equals(1));
    });
  });
}
