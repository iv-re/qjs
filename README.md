# qjs

[![pub package](https://img.shields.io/pub/v/qjs.svg)](https://pub.dev/packages/qjs)

QuickJS bindings for Dart.

---

## Quick Start

```dart
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
```

---

## Runtime & Configuration

### JSRuntime

`JSRuntime` manages an isolated JavaScript execution context and its native memory.

```dart
// Default configuration
final rt = JSRuntime.create();

// Custom configuration (e.g. sandbox memory limit of 64 MB and 512 KB stack)
final customRt = JSRuntime.create(const JSRuntimeConfig(
  memoryLimit: 64 * 1024 * 1024,
  maxStackSize: 512 * 1024,
  microtaskQueue: true,
));

// Hardened sandbox profile (disables eval/Proxy, limits memory to 64 MB)
final sandboxRt = JSRuntime.create(const JSRuntimeConfig.hardened());

customRt.release();
sandboxRt.release();
```

### JSRuntimeConfig

| Option | Type | Default | Description |
|:-------|:-----|:--------|:------------|
| `enableEval` | `bool` | `true` | Allows dynamic code evaluation via `eval()` and `new Function()` |
| `es6Proxy` | `bool` | `true` | Enables ES6 `Proxy` support in global scope |
| `microtaskQueue` | `bool` | `false` | Manages an explicit microtask queue (for `Promise.then` resolution) |
| `memoryLimit` | `int` | `0` | Maximum heap memory in bytes allocated by runtime (`0` = unlimited) |
| `maxStackSize` | `int` | `0` | Maximum system stack size in bytes allocated for execution (`0` = default) |
| `gcThreshold` | `int` | `0` | Memory allocation threshold in bytes before automatic GC triggers (`0` = default) |

`JSRuntimeConfig.hardened()` disables `eval` and `Proxy`, and restricts `memoryLimit` to 64 MB and `maxStackSize` to 512 KB.

---

## Code Evaluation

### evaluateJavascript

Executes JavaScript source code. Provide `sourceUrl` to get meaningful stack traces when exceptions occur:

```dart
final result = rt.evaluateJavascript(
  '''
  function fib(n) {
    if (n <= 1) return n;
    return fib(n - 1) + fib(n - 2);
  }
  fib(10);
  ''',
  sourceUrl: 'math.js',
);

print(result.asNumber); // 55.0
```

### Prepared JavaScript (Bytecode Preparation)

Pre-compiles source code into bytecode to execute repeatedly without re-parsing overhead:

```dart
final script = rt.prepareJavaScript(
  'globalThis.counter = (globalThis.counter || 0) + 1;',
  sourceUrl: 'counter.js',
);

rt.evaluatePreparedJavaScript(script);
rt.evaluatePreparedJavaScript(script);

print(rt.global['counter'].asNumber); // 2.0

// Explicitly free compiled bytecode
script.release();
```

---

## JavaScript Values

`JSValue` is a handle to a native JavaScript value.

### Type Checks and Conversions

| Type Check | Getter | Returns |
|:-----------|:-------|:--------|
| `val.isNumber` | `val.asNumber` | `double` |
| `val.isString` | `val.asDartString` | `String` |
| `val.isBoolean` | `val.asBoolean` | `bool` |
| `val.isNull` | — | `val.isNull == true` |
| `val.isUndefined` | — | `val.isUndefined == true` |
| `val.isObject` | `val.asObject` | `JSObject` |
| `val.isArray` | `val.asArray` | `JSArray` |
| `val.isArrayBuffer` | `val.asArrayBuffer` | `JSArrayBuffer` |
| `val.isBigInt` | `val.asBigInt` | `JSBigInt` |
| `val.isSymbol` | `val.asSymbol` | `JSSymbol` |
| `val.asObject.isFunction` | `val.asObject.asFunction` | `JSFunction` |


```dart
final numVal = JSValue.number(rt, 42);
final strVal = JSValue.string(rt, 'foo');
final boolVal = JSValue.boolean(rt, true);
final nullVal = JSValue.null_(rt);
final undefVal = JSValue.undefined(rt);

// Strict equality (===)
print(numVal.strictEquals(JSValue.number(rt, 42))); // true
print(numVal.strictEquals(strVal));                 // false
```

---

## Objects & Properties

### JSObject

Create and manipulate JavaScript objects:

```dart
final user = JSObject.create(rt);

// Index operator read/write
user['id'] = JSValue.number(rt, 1001);
user['name'] = JSValue.string(rt, 'Alice');

// Check properties
if (user.hasProperty('name')) {
  print(user['name'].asDartString); // Alice
}

// Enumerate property names
final names = user.getPropertyNames(); // JSArray
for (var i = 0; i < names.length; i++) {
  print(names[i].asDartString);
}
```

### Property Descriptors & Accessors

```dart
final obj = JSObject.create(rt);

// Read-only property
obj.defineProperty(
  'version',
  value: JSValue.string(rt, '1.0.0'),
  writable: false,
  enumerable: true,
  configurable: false,
);

// Getter & Setter backed by Dart
var internalState = 0;
obj.defineProperty(
  'count',
  get: JSFunction.createFromHostFunction(rt, (rt, thisValue, args) {
    return JSValue.number(rt, internalState.toDouble());
  }),
  set: JSFunction.createFromHostFunction(rt, (rt, thisValue, args) {
    internalState = args[0].asNumber.toInt();
    return JSValue.undefined(rt);
  }),
);
```

### Object Freezing & Integrity

```dart
final config = JSObject.create(rt)..['env'] = JSValue.string(rt, 'production');

config.preventExtensions(); // Disallow adding new properties
config.seal();              // Disallow adding/deleting properties
config.freeze();            // Make completely immutable
```

### Custom Host Objects

Implement `JSHostObject` to handle property accesses dynamically in Dart:

```dart
class StorageHostObject extends JSHostObject {
  final Map<String, JSValue> _storage = {};

  @override
  JSValue get(JSRuntime rt, JSPropNameId name) {
    return _storage[name.string] ?? JSValue.undefined(rt);
  }

  @override
  void set(JSRuntime rt, JSPropNameId name, JSValue value) {
    _storage[name.string] = value.retain();
  }

  @override
  List<JSPropNameId> getPropertyNames(JSRuntime rt) {
    return _storage.keys.map((k) => JSPropNameId.fromString(rt, k)).toList();
  }
}

final hostObj = JSObject.createFromHostObject(rt, StorageHostObject());
rt.global['storage'] = hostObj.asValue;
```

---

## Arrays & Buffers

### JSArray

```dart
final array = JSArray.create(rt)
  ..add(JSValue.number(rt, 10))
  ..add(JSValue.number(rt, 20));

print(array.length); // 2
print(array[0].asNumber); // 10.0

// Zero-copy live Dart List view (modifications sync both ways)
final List<JSValue> list = array.asList;
list.add(JSValue.number(rt, 30));
print(array.length); // 3
```

### JSArrayBuffer

`JSArrayBuffer` provides direct, zero-copy access to binary memory via `Uint8List`:

```dart
// Create a new 1 KB buffer
final buffer = JSArrayBuffer.create(rt, 1024);
buffer.data[0] = 0xAA;
buffer.data[1] = 0xBB;

// Create from existing Uint8List
final data = Uint8List.fromList([1, 2, 3, 4]);
final fromBytes = JSArrayBuffer.fromBytes(rt, data);

// Zero-copy read/write from JavaScript
rt.global['buf'] = buffer.asValue;
rt.evaluateJavascript('''
  const view = new Uint8Array(buf);
  view[2] = 0xCC;
''');

print(buffer.data[2]); // 204 (0xCC)
```

---

## Functions & Host Interop

### Calling JavaScript Functions from Dart

```dart
final multiply = rt.evaluateJavascript('(a, b) => a * b').asObject.asFunction;

// Direct invocation
final product = multiply([
  JSValue.number(rt, 6),
  JSValue.number(rt, 7),
]);
print(product.asNumber); // 42.0

// Constructor invocation (new Point(x, y))
final pointCtor = rt.evaluateJavascript(
  'function Point(x, y) { this.x = x; this.y = y; } Point;'
).asObject.asFunction;

final point = pointCtor.callAsConstructor([
  JSValue.number(rt, 5),
  JSValue.number(rt, 10),
]).asObject;

print(point['x'].asNumber); // 5.0
```

### Registering Dart Functions in JavaScript

```dart
final hostLog = JSFunction.createFromHostFunction(
  rt,
  (rt, thisValue, args) {
    final message = args.map((a) => a.isString ? a.asDartString : a.asNumber).join(' ');
    print('[Host] $message');
    return JSValue.undefined(rt);
  },
  name: 'nativeLog',
  length: 1,
);

rt.global['nativeLog'] = hostLog.asValue;
rt.evaluateJavascript('nativeLog("Item count:", 42);'); // [Host] Item count: 42
```

---

## Async & Promises

### JSPromise.fromAsyncFunction

Bridge Dart `Future` calls directly into JavaScript `Promise`:

```dart
final fetchData = JSFunction.createFromHostFunction(rt, (rt, thisValue, args) {
  return JSPromise.fromAsyncFunction(rt, () async {
    // Perform async Dart operation
    await Future<void>.delayed(const Duration(milliseconds: 100));
    return JSValue.string(rt, 'Response payload');
  });
});

rt.global['fetchData'] = fetchData.asValue;

rt.evaluateJavascript('''
  async function run() {
    const data = await fetchData();
    globalThis.result = data;
  }
  run();
''');
```

### JSPromise.withResolvers

Creates a promise along with separate `resolve` and `reject` functions (`Promise.withResolvers()`):

```dart
final (promise, resolve, reject) = JSPromise.withResolvers(rt);

rt.global['pendingPromise'] = promise;

// Resolve manually from Dart
resolve([JSValue.string(rt, 'Resolved from Dart!')]);
```

### Microtask Queue

When `microtaskQueue: true` is configured, drain pending promises explicitly:

```dart
final rt = JSRuntime.create(const JSRuntimeConfig(microtaskQueue: true));

rt.evaluateJavascript('''
  Promise.resolve().then(() => { globalThis.resolved = true; });
''');

// Process pending microtasks
rt.drainMicrotasks();
print(rt.global['resolved'].asBoolean); // true

rt.release();
```

---

## Extensions

### Console Logging (JSConsole)

Bridges JavaScript `console.log`, `info`, `warn`, `error`, and `debug` to `package:logging`:

```dart
import 'package:logging/logging.dart';
import 'package:qjs/qjs.dart';

final logger = Logger('QuickJS');
logger.onRecord.listen((rec) => print('[${rec.level.name}] ${rec.message}'));

final rt = JSRuntime.create();
JSConsole.install(rt, logger: logger);

rt.evaluateJavascript('console.warn("Watch out:", 404);');
// Output: [WARNING] Watch out: 404
```

### Timers (JSTimers)

Installs standard timer APIs (`setTimeout`, `setInterval`, `clearTimeout`, `clearInterval`, `setImmediate`):

```dart
final rt = JSRuntime.create();
final timers = JSTimers.install(rt);

rt.evaluateJavascript('''
  setTimeout(() => {
    globalThis.executed = true;
  }, 50);
''');

// Await until all scheduled timers resolve
await timers.resolved;
print(rt.global['executed'].asBoolean); // true

timers.release();
rt.release();
```

---

## Error Handling

### Catching Errors from JavaScript

When JavaScript code throws, Dart receives a `JSException`:

```dart
try {
  rt.evaluateJavascript('throw new TypeError("Invalid configuration");');
} on JSException catch (e) {
  print('Caught JS error: ${e.message}');
  print('Stack trace:\n${e.stack}');
  print('Error value: ${e.value}');
} on JSNativeException catch (e) {
  print('Engine internal exception: ${e.message}');
}
```

### Creating Standard Errors in Dart

```dart
final typeError = JSError.typeError(rt, 'Expected a string');
final rangeError = JSError.rangeError(rt, 'Index out of bounds');
final syntaxError = JSError.syntaxError(rt, 'Unexpected token');

// Throw into JS from host functions
throw JSException(typeError);
```

---

## Memory Management

### Finalizers & Reference Counting

* **Automatic Cleanup**: Every `JSValue`, `JSObject`, `JSArray`, and `JSPreparedJavaScript` registers with Dart's `NativeFinalizer`. When a Dart handle is garbage collected, the underlying native reference count is decremented automatically.
* **Explicit Release**: Call `rt.release()` when finished with a runtime to free all associated memory, global objects, and native contexts deterministically.
* **Retaining Handles**: Use `value.retain()` to increment the native reference count when sharing handles across asynchronous boundaries.

### Weak References (JSWeakObject)

Hold references to JavaScript objects without preventing garbage collection:

```dart
final obj = JSObject.create(rt);
final weakRef = JSWeakObject.create(rt, obj);

// Lock weak reference to obtain strong handle
final strongVal = weakRef.lock();
if (!strongVal.isUndefined) {
  print('Object is still alive');
}
```
