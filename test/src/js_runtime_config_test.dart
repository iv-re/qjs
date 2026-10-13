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

    test('hardened config disables every function constructor', () {
      final rt = JSRuntime.create(const JSRuntimeConfig.hardened());
      addTearDown(rt.release);

      String run(String code) {
        try {
          rt.evaluateJavascript(code);
          return 'ok';
        } on JSException catch (e) {
          return e.value.asObject['message'].asDartString;
        }
      }

      const disabled = 'Function constructor is disabled';
      expect(run('Function("return 1")()'), disabled);
      expect(run('new Function("return 1")()'), disabled);
      expect(run('(function () {}).constructor("return 1")()'), disabled);
      expect(run('(async function () {}).constructor("return 1")'), disabled);
      expect(run('(function* () {}).constructor("yield 1")'), disabled);
      expect(run('(async function* () {}).constructor("yield 1")'), disabled);
      expect(run('Reflect.construct(Function, ["return 1"])'), disabled);
      expect(run('new (class extends Function {})("return 1")'), disabled);

      bool check(String code) => rt.evaluateJavascript(code).asBoolean;
      expect(check('(function () {}) instanceof Function'), isTrue);
      expect(check('(() => 1) instanceof Function'), isTrue);
      expect(check('(function () {}).constructor === Function'), isTrue);
      expect(rt.evaluateJavascript('(async () => 42)(), 7').asNumber, 7);
      expect(
        rt
            .evaluateJavascript(
              '[...(function* () { yield 1; yield 2 })()].length',
            )
            .asNumber,
        2,
      );
    });

    test('enabled eval keeps function constructors working', () {
      final rt = JSRuntime.create(const JSRuntimeConfig(enableEval: true));
      addTearDown(rt.release);
      expect(rt.evaluateJavascript('Function("return 40 + 2")()').asNumber, 42);
      expect(
        rt
            .evaluateJavascript(
              'typeof (async function () {}).constructor("return 1")',
            )
            .asDartString,
        'function',
      );
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
