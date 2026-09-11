import 'package:qjs/qjs.dart';

void main() {
  final rt = JSRuntime.create();

  // Evaluate expressions
  final result = rt.evaluateJavascript('2 + 2');
  print(result.asNumber); // 4.0

  // Pass variables via the global object
  rt.global['name'] = JSValue.string(rt, 'Dart');
  final greeting = rt.evaluateJavascript(r'`Hello, ${name}!`');
  print(greeting.asDartString); // Hello, Dart!

  // Call JavaScript functions
  final add = rt.evaluateJavascript('(a, b) => a + b').asObject.asFunction;
  final sum = add([JSValue.number(rt, 10), JSValue.number(rt, 25)]);
  print(sum.asNumber); // 35.0

  rt.release();
}
