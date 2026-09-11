import 'package:qjs/qjs.dart';
import 'package:test/test.dart';

void main() {
  group('JSPointer', () {
    late JSRuntime rt;

    setUp(() {
      rt = JSRuntime.create();
    });

    tearDown(() {
      rt.release();
    });

    test('lifecycle with attachFinalizer = true', () {
      final obj = JSObject.create(rt);
      final ptr = obj.jsPointer;

      expect(ptr.attachFinalizer, isTrue);
      expect(ptr.isReleased, isFalse);

      ptr.release();
      expect(ptr.isReleased, isTrue);
      expect(() => ptr.handle, throwsStateError);

      // Multiple releases should be safe and a no-op
      expect(ptr.release, returnsNormally);
    });

    test('lifecycle with attachFinalizer = false', () {
      // JSString.fromString has attachFinalizer option
      final jsStr = JSString.fromString(
        rt,
        'test',
        attachFinalizer: false,
      );
      final ptr = jsStr.jsPointer;

      expect(ptr.attachFinalizer, isFalse);
      expect(ptr.isReleased, isFalse);

      ptr.release();
      expect(ptr.isReleased, isTrue);
    });

    test('detachFinalizer', () {
      final obj = JSObject.create(rt);
      final ptr = obj.jsPointer;
      expect(ptr.detachFinalizer, returnsNormally);
      ptr.release();
    });
  });
}
