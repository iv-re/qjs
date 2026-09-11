import 'package:logging/logging.dart';
import 'package:qjs/qjs.dart';
import 'package:test/test.dart';

void main() {
  group('JSConsole', () {
    late JSRuntime rt;
    late List<LogRecord> logs;
    late Logger logger;

    setUp(() {
      hierarchicalLoggingEnabled = true;
      rt = JSRuntime.create();
      logs = [];
      logger = Logger('test')..level = Level.ALL;
      logger.onRecord.listen(logs.add);
      JSConsole.install(rt, logger: logger);
    });

    tearDown(() {
      rt.release();
    });

    test('console methods are installed', () {
      final jsConsole = rt.global['console'];
      expect(jsConsole.isObject, isTrue);
      expect(jsConsole.asObject['log'].isObject, isTrue);
      expect(jsConsole.asObject['info'].isObject, isTrue);
      expect(jsConsole.asObject['warn'].isObject, isTrue);
      expect(jsConsole.asObject['error'].isObject, isTrue);
      expect(jsConsole.asObject['debug'].isObject, isTrue);
    });

    test('forwards log level', () {
      rt.evaluateJavascript('console.log("hello")');
      expect(logs.last.level, equals(Level.INFO));
      expect(logs.last.message, equals('hello'));

      rt.evaluateJavascript('console.warn("warning")');
      expect(logs.last.level, equals(Level.WARNING));
      expect(logs.last.message, equals('warning'));

      rt.evaluateJavascript('console.error("error")');
      expect(logs.last.level, equals(Level.SEVERE));
      expect(logs.last.message, equals('error'));

      rt.evaluateJavascript('console.debug("debug")');
      expect(logs.last.level, equals(Level.FINE));
      expect(logs.last.message, equals('debug'));
    });

    test('joins multiple arguments with spaces', () {
      rt.evaluateJavascript('console.log("a", 1, true, {x: 1})');
      expect(logs.last.message, equals('a 1 true [object Object]'));
    });

    test('console object is frozen and properties are read-only', () {
      rt.evaluateJavascript('console.log = 42;');
      expect(
        rt.evaluateJavascript('typeof console.log').asDartString,
        equals('function'),
      );
    });

    test('logs empty string when no arguments are provided', () {
      rt.evaluateJavascript('console.log()');
      expect(logs.last.message, equals(''));
    });

    test('handles exceptions in string conversion gracefully', () {
      expect(
        () => rt.evaluateJavascript('''
          console.log({
            toString: () => { throw new Error("custom toString error"); }
          });
        '''),
        throwsA(anyOf(isA<JSException>(), isA<JSNativeException>())),
      );
    });
  });
}
