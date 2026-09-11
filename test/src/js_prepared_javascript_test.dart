import 'package:qjs/qjs.dart';
import 'package:test/test.dart';

void main() {
  group('JSPreparedJavaScript', () {
    late JSRuntime rt;

    setUp(() {
      rt = JSRuntime.create();
    });

    tearDown(() {
      rt.release();
    });

    test('prepare and evaluate successfully', () {
      final prep = rt.prepareJavaScript('1 + 2', sourceUrl: 'test.js');
      final result = rt.evaluatePreparedJavaScript(prep);
      expect(result.isNumber, isTrue);
      expect(result.asNumber, equals(3));
      prep.release();
    });

    test('evaluate prepared script multiple times', () {
      final prep = rt.prepareJavaScript(
        'globalThis.count = (globalThis.count || 0) + 1;',
      );

      rt.evaluatePreparedJavaScript(prep);
      expect(rt.global['count'].asNumber, equals(1));

      rt.evaluatePreparedJavaScript(prep);
      expect(rt.global['count'].asNumber, equals(2));

      prep.release();
    });

    test('prepare script with syntax error throws', () {
      expect(
        () => rt.prepareJavaScript('invalid syntax here'),
        throwsA(anyOf(isA<JSException>(), isA<JSNativeException>())),
      );
    });

    test('access after manual release throws StateError', () {
      final prep = rt.prepareJavaScript('1 + 2')..release();
      expect(
        () => rt.evaluatePreparedJavaScript(prep),
        throwsStateError,
      );
    });

    test('double release is no-op', () {
      final prep = rt.prepareJavaScript('1 + 1')..release();
      // A second release should not throw
      expect(prep.release, returnsNormally);
    });
  });
}
