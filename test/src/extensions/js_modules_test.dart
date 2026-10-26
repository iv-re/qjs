import 'package:qjs/qjs.dart';
import 'package:test/test.dart';

Matcher _throwsJS(String message) => throwsA(
  isA<JSException>().having(
    (e) => e.value.asObject['message'].asDartString,
    'message',
    contains(message),
  ),
);

void main() {
  late JSRuntime rt;
  late JSModules modules;
  late Map<String, String> app;
  late List<String> reads;

  setUp(() {
    rt = JSRuntime.create();
    reads = [];
    app = {};
    modules = JSModules()
      ..mount('/app', (path) {
        reads.add(path);
        return app[path];
      });
    rt.moduleLoader = modules;
  });

  tearDown(() {
    rt.release();
  });

  group('mount', () {
    test('serves paths relative to the mount point', () {
      app['main.js'] = 'export { a } from "./lib/a.js";';
      app['lib/a.js'] = 'export const a = import.meta.url;';

      expect(
        rt.importModuleSync('/app/main.js')['a'].asDartString,
        '/app/lib/a.js',
      );
      expect(reads, ['main.js', 'lib/a.js']);
    });

    test('resolves .. across mounts but never above the root', () {
      final vendor = {'b.js': 'export const b = "vendor";'};
      modules.mount('/vendor', (path) => vendor[path]);
      app['main.js'] = 'export { b } from "../vendor/b.js";';
      app['escape.js'] = 'import "../../../etc/c.js";';

      expect(rt.importModuleSync('/app/main.js')['b'].asDartString, 'vendor');
      expect(
        () => rt.importModuleSync('/app/escape.js'),
        _throwsJS(
          "Cannot find module '/etc/c.js' imported from '/app/escape.js'",
        ),
      );
    });

    test('picks the longest prefix on a segment boundary', () {
      final nested = {'x.js': 'export const from = "nested";'};
      modules.mount('/app/nested/', (path) => nested[path]);
      app['x.js'] = 'export const from = "app";';

      expect(
        rt.importModuleSync('/app/nested/x.js')['from'].asDartString,
        'nested',
      );
      expect(rt.importModuleSync('/app/x.js')['from'].asDartString, 'app');
      expect(
        () => rt.importModuleSync('/apple/x.js'),
        _throwsJS("Cannot find module '/apple/x.js'"),
      );
    });

    test('does not add extensions', () {
      app['a.js'] = 'export {};';
      expect(
        () => rt.importModuleSync('/app/a'),
        _throwsJS("Cannot find module '/app/a'"),
      );
    });

    test('loads json and text files', () {
      app['config.json'] = '{"debug": true}';
      app['README.md'] = '# Hi';
      app['main.js'] = '''
        import config from './config.json' with { type: 'json' };
        import readme from './README.md' with { type: 'text' };
        export const result = [config.debug, readme].join();
      ''';
      expect(
        rt.importModuleSync('/app/main.js')['result'].asDartString,
        'true,# Hi',
      );
    });

    test('compiles .json files imported without a type as JavaScript', () {
      app['config.json'] = '{"debug": true}';
      expect(
        () => rt.importModuleSync('/app/config.json'),
        throwsA(
          isA<JSException>().having(
            (e) => e.value.asObject['name'].asDartString,
            'name',
            'SyntaxError',
          ),
        ),
      );
    });

    test('resolves script imports against the root', () {
      app['lazy.js'] = 'export const value = 1;';
      rt.evaluateJavascript(
        'import("./app/lazy.js").then((m) => { globalThis.value = m.value; })',
      );
      expect(rt.global['value'].asNumber, 1);
    });

    test('rejects prefixes that are not absolute', () {
      expect(() => modules.mount('app', (_) => null), throwsArgumentError);
    });
  });

  group('host', () {
    test('serves bare specifiers with lazily built exports', () {
      var built = 0;
      modules.host('alloy', (rt) {
        built++;
        return {
          'version': .string(rt, '1.0.0'),
          'greet': JSFunction.createFromHostFunction(
            rt,
            (rt, _, args) => .string(rt, 'hi ${args.first.asDartString}'),
          ).asValue,
        };
      });
      expect(built, 0);

      app['main.js'] = '''
        import * as alloy from 'alloy';
        export const result = alloy.greet(alloy.version);
      ''';
      expect(
        rt.importModuleSync('/app/main.js')['result'].asDartString,
        'hi 1.0.0',
      );
      rt.importModuleSync('alloy');
      expect(built, 1);
    });

    test('wraps host functions in a JavaScript class', () {
      modules
        ..host(
          'alloy',
          (rt) => {
            'create': JSFunction.createFromHostFunction(
              rt,
              (rt, _, args) => .string(rt, 'window:${args.first.asDartString}'),
            ).asValue,
          },
        )
        ..alias('window', '/app/window.js');
      app['window.js'] = '''
        import * as alloy from 'alloy';
        export class Window {
          #handle;
          constructor(title) { this.#handle = alloy.create(title); }
          get handle() { return this.#handle; }
        }
      ''';

      final ns = rt.evaluateModuleSync('''
        import { Window } from 'window';
        class MyWindow extends Window {}
        const w = new MyWindow('Hello');
        export const result = [w instanceof Window, w.handle].join();
      ''');
      expect(ns['result'].asDartString, 'true,window:Hello');
    });

    test('cannot be imported as json or text', () {
      modules.host('alloy', (rt) => {});
      expect(
        () => rt.evaluateModuleSync(
          'import x from "alloy" with { type: "json" };',
        ),
        _throwsJS("Host module 'alloy' cannot be imported as json"),
      );
    });

    test('reports unknown bare specifiers', () {
      app['main.js'] = 'import "nope";';
      expect(
        () => rt.importModuleSync('/app/main.js'),
        _throwsJS("Cannot find module 'nope' imported from '/app/main.js'"),
      );
    });

    test('rejects names that are paths or aliases', () {
      modules.alias('taken', '/app/x.js');
      expect(() => modules.host('./x', (_) => {}), throwsArgumentError);
      expect(() => modules.host('taken', (_) => {}), throwsArgumentError);
    });
  });

  group('alias', () {
    test('maps exact and prefix specifiers', () {
      final vendor = {'utils/index.js': 'export default "utils";'};
      modules
        ..mount('/vendor', (path) => vendor[path])
        ..alias('utils', '/vendor/utils/index.js')
        ..alias('@ui/', '/app/ui/')
        ..host('alloy', (rt) => {'name': .string(rt, 'alloy')})
        ..alias('net', 'alloy');
      app['ui/button.js'] = 'export default "button";';

      final ns = rt.evaluateModuleSync('''
        import utils from 'utils';
        import button from '@ui/button.js';
        import { name } from 'net';
        export const result = [utils, button, name].join();
      ''');
      expect(ns['result'].asDartString, 'utils,button,alloy');
    });

    test('shares one module between a specifier and its target', () {
      app['counter.js'] =
          'globalThis.count = (globalThis.count ?? 0) + 1; export {};';
      modules.alias('counter', '/app/counter.js');
      rt.evaluateModuleSync('import "counter"; import "/app/counter.js";');
      expect(rt.global['count'].asNumber, 1);
    });

    test('rejects invalid aliases', () {
      modules.host('alloy', (rt) => {});
      expect(() => modules.alias('alloy', '/x.js'), throwsArgumentError);
      expect(() => modules.alias('./x', '/x.js'), throwsArgumentError);
      expect(() => modules.alias('x', './x.js'), throwsArgumentError);
      expect(() => modules.alias('@ui/', '/app/ui'), throwsArgumentError);
    });
  });

  test('works in several runtimes', () {
    app['main.js'] = 'export const value = 1;';
    final other = JSRuntime.create()..moduleLoader = modules;
    addTearDown(other.release);

    expect(rt.importModuleSync('/app/main.js')['value'].asNumber, 1);
    expect(other.importModuleSync('/app/main.js')['value'].asNumber, 1);
  });
}
