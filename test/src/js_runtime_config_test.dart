// ignore_for_file: avoid_redundant_argument_values

import 'package:qjs/qjs.dart';
import 'package:test/test.dart';

void main() {
  group('JSRuntimeConfig', () {
    test('hardened config disables eval and proxy', () {
      const config = JSRuntimeConfig.hardened();
      final rt = JSRuntime.create(config);
      try {
        // eval should fail and throw an exception
        expect(
          () => rt.evaluateJavascript('eval("1 + 1")'),
          throwsA(anything),
        );

        // Proxy should be undefined
        final proxyVal = rt.evaluateJavascript('typeof Proxy');
        expect(proxyVal.asDartString, equals('undefined'));
      } finally {
        rt.release();
      }
    });

    test('custom config enables eval and proxy', () {
      const config = JSRuntimeConfig(
        enableEval: true,
        es6Proxy: true,
      );
      final rt = JSRuntime.create(config);
      try {
        // eval should succeed
        final res = rt.evaluateJavascript('eval("1 + 2")');
        expect(res.asNumber, equals(3.0));

        // Proxy should be available
        final proxyVal = rt.evaluateJavascript('typeof Proxy');
        expect(proxyVal.asDartString, equals('function'));
      } finally {
        rt.release();
      }
    });

    test('memoryLimit enforces heap restriction', () {
      // 256 KB memory limit
      const config = JSRuntimeConfig(memoryLimit: 256 * 1024);
      final rt = JSRuntime.create(config);
      try {
        expect(
          () => rt.evaluateJavascript('new Uint8Array(10 * 1024 * 1024)'),
          throwsA(anything),
        );
      } finally {
        rt.release();
      }
    });

    test('maxStackSize restricts recursive call depth', () {
      // 32 KB stack
      const config = JSRuntimeConfig(maxStackSize: 32 * 1024);
      final rt = JSRuntime.create(config);
      try {
        expect(
          () => rt.evaluateJavascript(
            'function recurse() { recurse(); } recurse();',
          ),
          throwsA(anything),
        );
      } finally {
        rt.release();
      }
    });
  });
}
