import 'dart:io';

import 'package:ffigen/ffigen.dart';
import 'package:logging/logging.dart';

FfiGenerator getConfig(Uri packageRoot) {
  return FfiGenerator(
    input: Input(
      entryPoints: [packageRoot.resolve('src/qjs_dart.h')],
      compilerOptions: [
        ...defaultCompilerOpts(Logger('ffigen')),
        '-D_GNU_SOURCE',
      ],
    ),
    output: Output(
      dart: DartOutput(path: packageRoot.resolve('lib/qjs.g.dart')),
      style: const NativeExternalBindings(
        assetId: 'package:qjs/qjs.dart',
      ),
    ),
    visitors: [
      Visitor(
        func: (node) {
          node.isIncluded = node.name.startsWith('qjs_');
        },
        struct: (node) {
          node.isIncluded = node.name.startsWith('QJS');
        },
        union: (node) {
          node.isIncluded = node.name.startsWith('QJS');
        },
        enumClass: (node) {
          if (node.name.startsWith('QJS')) {
            node.isIncluded = true;
            node.silenceWarning = true;
          }
        },
        typealias: (node) {
          node.isIncluded = node.name.startsWith('QJS') ? .always : .never;
        },
        global: (node) {
          node.isIncluded = node.name.startsWith('QJS');
        },
        macroConstant: (node) {
          node.isIncluded = node.name.startsWith('QJS');
        },
        unnamedEnumConstant: (node) {
          node.isIncluded = node.name.startsWith('QJS');
        },
      ),
    ],
  );
}

void main() async {
  await getConfig(Platform.script.resolve('../')).generate();
}
