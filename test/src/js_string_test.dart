import 'package:qjs/qjs.dart';
import 'package:test/test.dart';

void main() {
  group('JSString', () {
    late JSRuntime rt;

    setUp(() {
      rt = JSRuntime.create();
    });

    tearDown(() {
      rt.release();
    });

    test('create from string and back', () {
      final jsStr = JSString.fromString(rt, 'hello');
      expect(jsStr.string, equals('hello'));
    });

    test('unicode string', () {
      final jsStr = JSString.fromString(rt, 'Привет, мир! 😊');
      expect(jsStr.string, equals('Привет, мир! 😊'));
    });

    test('clone and release', () {
      final jsStr = JSString.fromString(rt, 'test');
      final cloned = jsStr.retain();

      expect(jsStr.string, equals('test'));
      expect(cloned.string, equals('test'));
    });

    test('strictEquals', () {
      final s1 = JSString.fromString(rt, 'a');
      final s2 = JSString.fromString(rt, 'a');
      final s3 = JSString.fromString(rt, 'b');

      expect(s1.strictEquals(s2), isTrue);
      expect(s1.strictEquals(s3), isFalse);
    });

    test('unmanaged string (attachFinalizer: false)', () {
      final jsStr = JSString.fromString(
        rt,
        'unmanaged',
        attachFinalizer: false,
      );
      expect(jsStr.string, equals('unmanaged'));
      // Manual release of unmanaged pointer
      jsStr.jsPointer.release();
    });

    test('string with control characters and null byte truncation', () {
      final jsStr = JSString.fromString(rt, 'hello\n\t\x00world');
      expect(jsStr.string, equals('hello\n\t'));
    });
  });
}
