import 'package:qjs/qjs.dart';
import 'package:test/test.dart';

void main() {
  group('JSTimers', () {
    late JSRuntime rt;
    late JSTimers timers;

    setUp(() {
      rt = JSRuntime.create();
      timers = JSTimers.install(rt);
    });

    tearDown(() {
      timers.release();
      rt.release();
    });

    test('setTimeout executes after delay', () async {
      rt.evaluateJavascript('var x = 0; setTimeout(() => x = 42, 10);');
      expect(rt.global['x'].asNumber, equals(0));

      await timers.resolved;
      expect(rt.global['x'].asNumber, equals(42));
    });

    test('setInterval executes multiple times', () async {
      rt.evaluateJavascript('''
        var count = 0;
        var id = setInterval(() => {
          count++;
          if (count === 3) clearInterval(id);
        }, 10);
      ''');

      await timers.resolved;
      expect(rt.global['count'].asNumber, equals(3));
    });

    test('setImmediate executes quickly', () async {
      rt.evaluateJavascript('var x = 0; setImmediate(() => x = 1);');
      expect(rt.global['x'].asNumber, equals(0));

      await timers.resolved;
      expect(rt.global['x'].asNumber, equals(1));
    });

    test('clearTimeout cancels timer', () async {
      rt.evaluateJavascript('''
        var x = 0;
        var id = setTimeout(() => x = 1, 50);
        clearTimeout(id);
      ''');

      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(rt.global['x'].asNumber, equals(0));
    });

    test('hasPendingTimers reflects state', () async {
      expect(timers.hasPendingTimers, isFalse);

      rt.evaluateJavascript('setTimeout(() => {}, 100);');
      expect(timers.hasPendingTimers, isTrue);

      await timers.resolved;
      expect(timers.hasPendingTimers, isFalse);
    });

    test('passes arguments to callback', () async {
      rt.evaluateJavascript('''
        var result = "";
        setTimeout((a, b) => result = a + b, 10, "foo", "bar");
      ''');

      await timers.resolved;
      expect(rt.global['result'].asDartString, equals('foobar'));
    });

    test('setTimeout throws when callback is not a function', () {
      expect(
        () => rt.evaluateJavascript('setTimeout(42, 10)'),
        throwsA(anyOf(isA<JSException>(), isA<JSNativeException>())),
      );
    });

    test('clearTimeout with invalid inputs is a no-op', () {
      expect(
        () => rt.evaluateJavascript('clearTimeout("invalid_id")'),
        returnsNormally,
      );
      expect(
        () => rt.evaluateJavascript('clearTimeout(null)'),
        returnsNormally,
      );
    });

    test('setTimeout defaults to 0ms when duration is omitted', () async {
      rt.evaluateJavascript('var x = 0; setTimeout(() => x = 99);');
      await timers.resolved;
      expect(rt.global['x'].asNumber, equals(99));
    });
  });
}
