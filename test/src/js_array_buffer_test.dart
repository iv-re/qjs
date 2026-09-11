import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:qjs/qjs.dart';
import 'package:test/test.dart';

void main() {
  group('JSArrayBuffer', () {
    late JSRuntime rt;

    setUp(() {
      rt = JSRuntime.create();
    });

    tearDown(() {
      rt.release();
    });

    test('create with size', () {
      final ab = JSArrayBuffer.create(rt, 16);

      expect(ab.byteLength, equals(16));
      expect(ab.data, isA<Uint8List>());
      expect(ab.data.every((b) => b == 0), isTrue);

      ab.data[5] = 42;
      expect(ab.data[5], equals(42));

      ab.data.fillRange(0, 16, 0xFF);
      expect(ab.data[0], equals(0xFF));
      expect(ab.data[15], equals(0xFF));
    });

    test('fromBytes copies data', () {
      final bytes = Uint8List.fromList([10, 20, 30, 40]);
      final ab = JSArrayBuffer.fromBytes(rt, bytes);

      expect(ab.byteLength, equals(4));
      expect(ab.data[0], equals(10));
      expect(ab.data[1], equals(20));
      expect(ab.data[2], equals(30));
      expect(ab.data[3], equals(40));
    });

    test('fromBytes JS interaction', () {
      final bytes = Uint8List.fromList([10, 20, 30, 40]);
      final ab = JSArrayBuffer.fromBytes(rt, bytes);

      rt.global['ab'] = ab.asValue;
      final sum = rt.evaluateJavascript('''
        var view = new Uint8Array(ab);
        var s = view[0] + view[1] + view[2] + view[3];
        view[0] = 100;
        s;
      ''');

      expect(sum.asNumber, equals(100));
      expect(ab.data[0], equals(100));
    });

    test('create JS interaction', () {
      final ab = JSArrayBuffer.create(rt, 4);
      ab.data.setAll(0, [10, 20, 30, 40]);

      rt.global['ab'] = ab.asValue;
      final result = rt.evaluateJavascript('''
        var view = new Uint8Array(ab);
        view[0] + view[1] + view[2] + view[3];
      ''');

      expect(result.asNumber, equals(100));
    });

    test('from external data (fromPointer)', () async {
      const size = 16;
      final ptr = malloc<Uint8>(size);
      for (var i = 0; i < size; i++) {
        ptr[i] = i;
      }

      var released = false;
      final ab = JSArrayBuffer.fromPointer(
        rt,
        ptr,
        size,
        onRelease: () {
          malloc.free(ptr);
          released = true;
        },
      );

      expect(ab.byteLength, equals(size));
      expect(ab.data[5], equals(5));

      // Use in JS
      rt.global['ab'] = ab.asValue;
      final result = rt.evaluateJavascript('new Uint8Array(ab)[10]');
      expect(result.asNumber, equals(10));

      // Release runtime, should trigger onRelease
      rt.release();

      // Wait for release callback
      await Future<void>.delayed(.zero);

      expect(released, isTrue);

      // Re-create rt for next tests since we released it manually
      rt = JSRuntime.create();
    });

    test('onRelease callback', () async {
      var released = false;
      final data = malloc<Uint8>(10);

      {
        final rt2 = JSRuntime.create();
        JSArrayBuffer.fromPointer(
          rt2,
          data,
          10,
          onRelease: () {
            released = true;
            malloc.free(data);
          },
        );
        rt2.release();
      }

      // Wait for release callback
      await Future<void>.delayed(.zero);

      expect(released, isTrue);
    });

    test('direct modification of ArrayBuffer created in JS', () {
      rt.evaluateJavascript('''
        var myAb = new ArrayBuffer(10);
        var view = new Uint8Array(myAb);
        for (var i = 0; i < 10; i++) {
          view[i] = i * 2;
        }
      ''');

      final abValue = rt.global['myAb'];
      expect(abValue.isArrayBuffer, isTrue);
      final ab = abValue.asArrayBuffer;

      expect(ab.byteLength, equals(10));
      expect(ab.data, isA<Uint8List>());
      for (var i = 0; i < 10; i++) {
        expect(ab.data[i], equals(i * 2));
      }

      ab.data[0] = 123;
      ab.data[5] = 255;

      final result = rt.evaluateJavascript('''
        var view = new Uint8Array(myAb);
        [view[0], view[5]];
      ''');

      expect(result.isArray, isTrue);
      final resultArray = result.asArray;
      expect(resultArray[0].asNumber, equals(123));
      expect(resultArray[1].asNumber, equals(255));
    });

    test('fromPointer with null callback', () {
      final ptr = malloc<Uint8>(5);
      final ab = JSArrayBuffer.fromPointer(rt, ptr, 5);
      expect(ab.byteLength, equals(5));
      // Manual free is required because we passed null onRelease
      malloc.free(ptr);
    });

    test('retain ArrayBuffer', () {
      final ab = JSArrayBuffer.create(rt, 10);
      final cloned = ab.retain();
      expect(cloned.byteLength, equals(10));
      expect(cloned.asValue.strictEquals(ab.asValue), isTrue);
    });
  });
}
