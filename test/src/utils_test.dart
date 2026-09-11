import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:qjs/qjs.g.dart';
import 'package:qjs/src/utils.dart';
import 'package:test/test.dart';

void main() {
  group('Utils (QJSABIStringDataExt)', () {
    test('toDartString handles nullptr or empty string', () {
      final struct = Struct.create<QJSABIStringData>()
        ..data = nullptr
        ..length = 0
        ..is_ascii = true;

      expect(struct.toDartString(), equals(''));
    });

    test('toDartString converts ASCII data correctly', () {
      const text = 'hello';
      final nativeBytes = text.toNativeUtf8();
      try {
        final struct = Struct.create<QJSABIStringData>()
          ..data = nativeBytes.cast()
          ..length = text.length
          ..is_ascii = true;

        expect(struct.toDartString(), equals('hello'));
      } finally {
        malloc.free(nativeBytes);
      }
    });

    test('toDartString converts UTF-16 data correctly', () {
      const text = 'Привет';
      // UTF-16 bytes in Dart are 16-bit code units
      final units = text.codeUnits;
      final nativePtr = malloc<Uint16>(units.length);
      final nativeList = nativePtr.asTypedList(units.length);
      for (var i = 0; i < units.length; i++) {
        nativeList[i] = units[i];
      }

      try {
        final struct = Struct.create<QJSABIStringData>()
          ..data = nativePtr.cast()
          ..length = units.length
          ..is_ascii = false;

        expect(struct.toDartString(), equals('Привет'));
      } finally {
        malloc.free(nativePtr);
      }
    });
  });
}
