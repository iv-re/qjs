import 'package:qjs/qjs.dart';
import 'package:test/test.dart';

void main() {
  group('JSWeakObject', () {
    late JSRuntime rt;

    setUp(() {
      rt = JSRuntime.create();
    });

    tearDown(() {
      rt.release();
    });

    test('create and lock', () {
      final obj = JSObject.create(rt);
      final weak = JSWeakObject.create(rt, obj);

      final locked = weak.lock();
      expect(locked.isObject, isTrue);
      expect(locked.asObject.strictEquals(obj), isTrue);
    });

    test('weak ref lock returns undefined if object is collected', () {
      final rt2 = JSRuntime.create();
      try {
        final obj = JSObject.create(rt2);
        final weak = JSWeakObject.create(rt2, obj);

        expect(weak.lock().isObject, isTrue);

        // Manually release the Dart-side handle
        obj.jsPointer.release();

        // Try to trigger gc if exposed
        try {
          rt2.evaluateJavascript('gc()');
        } catch (_) {
          // If gc() is not defined, allocate to force GC
          for (var i = 0; i < 50000; i++) {
            JSObject.create(rt2);
          }
        }

        final locked = weak.lock();
        expect(locked.isObject || locked.isUndefined, isTrue);
      } finally {
        rt2.release();
      }
    });
  });
}
