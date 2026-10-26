import 'dart:async';

import 'package:qjs/qjs.dart';
import 'package:test/test.dart';

/// Serves [sources] by canonical name and records every call.
class _MapLoader implements JSModuleLoader {
  _MapLoader(this.sources);

  final Map<String, JSModuleSource Function(JSRuntime rt)> sources;
  final List<(String, String)> resolved = [];
  final List<(String, JSImportType)> loaded = [];

  @override
  String resolve(JSRuntime rt, String specifier, String referrer) {
    resolved.add((specifier, referrer));
    return specifier;
  }

  @override
  JSModuleSource load(JSRuntime rt, String name, JSImportType type) {
    loaded.add((name, type));
    final source = sources[name];
    if (source == null) {
      throw JSException(JSError.referenceError(rt, 'no module $name'));
    }
    return source(rt);
  }
}

Matcher _throwsJS(String message) => throwsA(
  isA<JSException>().having(
    (e) => e.value.asObject['message'].asDartString,
    'message',
    contains(message),
  ),
);

void main() {
  late JSRuntime rt;

  setUp(() {
    rt = JSRuntime.create();
  });

  tearDown(() {
    rt.release();
  });

  group('without a loader', () {
    test('evaluates a module without imports', () {
      final ns = rt.evaluateModuleSync(
        'export const a = 1; export default "d";',
      );
      expect(ns['a'].asNumber, 1);
      expect(ns['default'].asDartString, 'd');
    });

    test('fails every import', () {
      expect(
        () => rt.evaluateModuleSync('import "a.js";'),
        _throwsJS("could not load module 'a.js'"),
      );
      expect(() => rt.importModuleSync('a.js'), throwsA(isA<JSException>()));
    });

    test('evaluateModule reports errors through the future', () async {
      await expectLater(
        rt.evaluateModule('export const = ;'),
        throwsA(isA<JSException>()),
      );
      await expectLater(rt.importModule('a.js'), throwsA(isA<JSException>()));
    });

    test('sets import.meta.url to the name', () {
      final ns = rt.evaluateModuleSync(
        'export const url = import.meta.url;',
        name: '/app/main.js',
      );
      expect(ns['url'].asDartString, '/app/main.js');
    });
  });

  group('loader', () {
    test('compiles code modules and passes the referrer', () {
      final loader = _MapLoader({
        'a.js': (_) =>
            const .code('import { b } from "b.js"; export const a = b + 1;'),
        'b.js': (_) => const .code('export const b = 41;'),
      });
      rt.moduleLoader = loader;

      expect(rt.importModuleSync('a.js')['a'].asNumber, 42);
      expect(loader.resolved, [('a.js', ''), ('b.js', 'a.js')]);
    });

    test('loads a module once', () {
      final loader = _MapLoader({
        'counter.js': (_) => const .code(
          'globalThis.count = (globalThis.count ?? 0) + 1; export {};',
        ),
      });
      rt.moduleLoader = loader;

      rt.importModuleSync('counter.js');
      rt.evaluateModuleSync('import "counter.js";');
      rt.evaluateJavascript('import("counter.js")');
      expect(rt.global['count'].asNumber, 1);
      expect(loader.loaded, [('counter.js', JSImportType.javascript)]);
    });

    test('builds host modules from exports', () {
      rt.moduleLoader = _MapLoader({
        'host': (rt) => .exports({
          'add': JSFunction.createFromHostFunction(
            rt,
            (rt, _, args) => .number(rt, args[0].asNumber + args[1].asNumber),
          ).asValue,
          'default': .string(rt, 'host default'),
        }),
      });

      final ns = rt.evaluateModuleSync('''
        import * as all from 'host';
        import name, { add } from 'host';
        export const sum = add(2, 3);
        export const keys = Object.keys(all).sort().join();
        export { name };
      ''');
      expect(ns['sum'].asNumber, 5);
      expect(ns['keys'].asDartString, 'add,default');
      expect(ns['name'].asDartString, 'host default');
    });

    test('fails on an import the host module does not export', () {
      rt.moduleLoader = _MapLoader({
        'host': (rt) => .exports({'a': .number(rt, 1)}),
      });
      expect(
        () => rt.evaluateModuleSync('import { b } from "host";'),
        throwsA(isA<JSException>()),
      );
    });

    test('passes the import type and builds json and text modules', () {
      final loader = _MapLoader({
        'data.json': (_) => const .json('{"answer": 42}'),
        'notes.txt': (_) => const .text('hello'),
      });
      rt.moduleLoader = loader;

      final ns = rt.evaluateModuleSync('''
        import data from 'data.json' with { type: 'json' };
        import notes from 'notes.txt' with { type: 'text' };
        export const answer = data.answer;
        export { notes };
      ''');
      expect(ns['answer'].asNumber, 42);
      expect(ns['notes'].asDartString, 'hello');
      expect(loader.loaded, [
        ('data.json', JSImportType.json),
        ('notes.txt', JSImportType.text),
      ]);
    });

    test('rejects unknown import attributes and types', () {
      rt.moduleLoader = _MapLoader({});
      expect(
        () => rt.evaluateModuleSync('import x from "a" with { type: "css" };'),
        _throwsJS("unsupported import type 'css'"),
      );
      expect(
        () => rt.evaluateModuleSync('import x from "a" with { mode: "x" };'),
        throwsA(
          isA<JSException>()
              .having(
                (e) => e.value.asObject['name'].asDartString,
                'name',
                'SyntaxError',
              )
              .having(
                (e) => e.value.asObject['message'].asDartString,
                'message',
                "import attribute 'mode' is not supported",
              ),
        ),
      );
    });

    test('surfaces errors thrown by the loader', () {
      rt.moduleLoader = _MapLoader({
        'bad.js': (_) => throw StateError('disk on fire'),
      });
      expect(
        () => rt.importModuleSync('missing.js'),
        _throwsJS('no module missing.js'),
      );
      expect(() => rt.importModuleSync('bad.js'), _throwsJS('disk on fire'));
    });

    test('surfaces syntax errors and module exceptions', () {
      rt.moduleLoader = _MapLoader({
        'syntax.js': (_) => const .code('export const = ;'),
        'throws.js': (_) => const .code('throw new Error("module failed");'),
      });
      expect(
        () => rt.importModuleSync('syntax.js'),
        throwsA(isA<JSException>()),
      );
      expect(
        () => rt.importModuleSync('throws.js'),
        _throwsJS('module failed'),
      );
    });

    test('retries a module that failed to load', () {
      final sources = <String, JSModuleSource Function(JSRuntime)>{
        'main.js': (_) => const .code('export { b } from "b.js";'),
      };
      rt.moduleLoader = _MapLoader(sources);
      expect(() => rt.importModuleSync('main.js'), _throwsJS('no module b.js'));

      sources['b.js'] = (_) => const .code('export const b = 2;');
      expect(rt.importModuleSync('main.js')['b'].asNumber, 2);
    });

    test('supports cyclic imports', () {
      rt.moduleLoader = _MapLoader({
        'a.js': (_) => const .code('''
          import { b } from "b.js";
          export const a = "a";
          export const fromB = () => b;
        '''),
        'b.js': (_) => const .code('''
          import { a } from "a.js";
          export const b = "b";
          export const fromA = () => a;
        '''),
      });
      final ns = rt.evaluateModuleSync('''
        import { fromB } from 'a.js';
        import { fromA } from 'b.js';
        export const both = fromA() + fromB();
      ''');
      expect(ns['both'].asDartString, 'ab');
    });

    test('supports dynamic import', () {
      rt.moduleLoader = _MapLoader({
        'lazy.js': (_) => const .code('export const value = "lazy";'),
      });
      rt.evaluateJavascript(
        'import("lazy.js").then((m) => { globalThis.value = m.value; })',
      );
      expect(rt.global['value'].asDartString, 'lazy');
    });

    test('refuses to evaluate modules from the loader', () {
      late Object error;
      rt.moduleLoader = _MapLoader({
        'nested.js': (rt) {
          try {
            rt.evaluateModuleSync('export {};');
          } catch (e) {
            error = e;
          }
          return const .code('export {};');
        },
      });
      rt.importModuleSync('nested.js');
      expect(error, isA<StateError>());
    });

    test('can be removed', () {
      rt.moduleLoader = _MapLoader({
        'a.js': (_) => const .code('export {};'),
      });
      rt.moduleLoader = null;
      expect(
        () => rt.importModuleSync('a.js'),
        _throwsJS("could not load module 'a.js'"),
      );
    });

    test('is interrupted by a deadline', () {
      rt.moduleLoader = _MapLoader({
        'loop.js': (_) => const .code('while (true) {}'),
      });
      rt.setDeadline(const Duration(milliseconds: 50));
      expect(() => rt.importModuleSync('loop.js'), _throwsJS('interrupted'));
    });
  });

  group('top-level await', () {
    late Completer<String> completer;

    setUp(() {
      completer = Completer();
      rt.global['fetchValue'] = JSFunction.createFromHostFunction(
        rt,
        (rt, _, _) => JSPromise.fromAsyncFunction(
          rt,
          () async => .string(rt, await completer.future),
        ),
      ).asValue;
      rt.moduleLoader = _MapLoader({
        'tla.js': (_) => const .code(
          'export const value = await fetchValue();',
        ),
      });
    });

    test('evaluateModuleSync settles without waiting on the host', () {
      final ns = rt.evaluateModuleSync(
        'export const value = await Promise.resolve(1);',
      );
      expect(ns['value'].asNumber, 1);
    });

    test('importModuleSync throws a StateError while still waiting', () {
      expect(() => rt.importModuleSync('tla.js'), throwsStateError);
    });

    test('importModule waits for the host', () async {
      final future = rt.importModule('tla.js');
      completer.complete('ready');
      expect((await future)['value'].asDartString, 'ready');
    });

    test('evaluateModule reports rejections', () async {
      final future = rt.evaluateModule(
        'await fetchValue(); throw new Error("after await");',
      );
      completer.complete('ready');
      await expectLater(future, _throwsJS('after await'));
    });
  });

  group('onUnhandledRejection', () {
    late List<(String, bool)> events;

    setUp(() {
      events = [];
      rt.onUnhandledRejection = (promise, reason, isHandled) {
        events.add((reason.asObject['message'].asDartString, isHandled));
      };
    });

    test('ignores the rejection of a failing module', () {
      expect(
        () => rt.evaluateModuleSync('throw new Error("module failed");'),
        _throwsJS('module failed'),
      );
      expect(events, isEmpty);
    });

    test('still reports rejections made by the module', () {
      rt.evaluateModuleSync('Promise.reject(new Error("inside")); export {};');
      expect(events, [('inside', false)]);
    });

    test('ignores rejections handled while the module evaluates', () {
      rt.evaluateModuleSync('''
        const p = Promise.reject(new Error("handled"));
        p.catch(() => {});
      ''');
      expect(events, isEmpty);
    });
  });
}
