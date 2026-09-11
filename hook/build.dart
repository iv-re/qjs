import 'dart:convert';
import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:convert/convert.dart';
import 'package:crypto/crypto.dart';
import 'package:hooks/hooks.dart';
import 'package:native_toolchain_c/native_toolchain_c.dart';

void main(List<String> args) async {
  await build(args, (input, output) async {
    if (!input.config.buildCodeAssets) return;

    final configuration = _tryGetConfiguration(input);
    final dylibName = _getLibName(input.config.code.targetOS);

    if (configuration != null) {
      final localBuildDir = input.packageRoot.resolve('build_$configuration/');
      var localLib = File.fromUri(localBuildDir.resolve(dylibName));
      if (!localLib.existsSync()) {
        localLib = File.fromUri(localBuildDir.resolve('Release/$dylibName'));
      }

      if (localLib.existsSync()) {
        output.assets.code.add(
          CodeAsset(
            package: input.packageName,
            name: '${input.packageName}.dart',
            linkMode: DynamicLoadingBundled(),
            file: localLib.uri,
          ),
        );
        return;
      }

      // Try prebuilt download if available
      final prebuiltUri = await _tryDownloadPrebuiltBinary(
        input: input,
        configuration: configuration,
        dylibName: dylibName,
      );
      if (prebuiltUri != null) {
        output.assets.code.add(
          CodeAsset(
            package: input.packageName,
            name: '${input.packageName}.dart',
            linkMode: DynamicLoadingBundled(),
            file: prebuiltUri,
          ),
        );
        return;
      }
    }

    // Fallback: compile on the fly with native_toolchain_c
    final cbuilder = CBuilder.library(
      name: input.packageName,
      assetName: '${input.packageName}.dart',
      sources: [
        'quickjs/dtoa.c',
        'quickjs/libregexp.c',
        'quickjs/libunicode.c',
        'quickjs/quickjs.c',
        'src/qjs_dart.c',
      ],
      includes: [
        'quickjs',
        'src',
      ],
      defines: {
        '_GNU_SOURCE': '1',
        'CONFIG_VERSION': '"0.16.2"',
        'QUICKJS_NG_BUILD': '1',
        'NDEBUG': '1',
      },
      flags: [
        '-O3',
        '-fomit-frame-pointer',
      ],
    );
    await cbuilder.run(
      input: input,
      output: output,
    );
  });
}

const _releaseBaseUrl = 'https://github.com/iv-re/qjs/releases/download';

Future<Uri?> _tryDownloadPrebuiltBinary({
  required BuildInput input,
  required String configuration,
  required String dylibName,
}) async {
  try {
    final hashFile = File.fromUri(input.packageRoot.resolve('qjs_hash'));
    final hashesFile = File.fromUri(
      input.packageRoot.resolve('prebuilt_hashes.json'),
    );
    if (!hashFile.existsSync() || !hashesFile.existsSync()) return null;

    final hash = hashFile.readAsStringSync().trim();
    if (hash.isEmpty) return null;

    final hashes =
        jsonDecode(hashesFile.readAsStringSync()) as Map<String, dynamic>;
    final downloadFileName = '${configuration}_$dylibName';
    final expectedSha256 = hashes[downloadFileName] as String?;
    if (expectedSha256 == null) return null;

    final cacheDir = Directory.fromUri(
      input.outputDirectoryShared.resolve('prebuilt_cache/$hash/'),
    );
    await cacheDir.create(recursive: true);

    final cachedFile = File.fromUri(cacheDir.uri.resolve(dylibName));
    if (cachedFile.existsSync()) return cachedFile.uri;

    final downloadUrl = Uri.parse(
      '$_releaseBaseUrl/qjs_$hash/$downloadFileName',
    );
    final tmpFile = File.fromUri(cacheDir.uri.resolve('$dylibName.tmp'));
    final client = HttpClient();

    try {
      final request = await client
          .getUrl(downloadUrl)
          .timeout(const Duration(seconds: 15));
      final response = await request.close();
      if (response.statusCode != 200) return null;

      final digestSink = AccumulatorSink<Digest>();
      final hashSink = sha256.startChunkedConversion(digestSink);
      final fileSink = tmpFile.openWrite();

      await for (final chunk in response) {
        hashSink.add(chunk);
        fileSink.add(chunk);
      }
      hashSink.close();
      await fileSink.flush();
      await fileSink.close();

      final downloadedHash = digestSink.events.single.toString();
      if (downloadedHash != expectedSha256) {
        await tmpFile.delete();
        return null;
      }
      await tmpFile.rename(cachedFile.path);
      return cachedFile.uri;
    } finally {
      client.close();
    }
  } catch (_) {
    return null;
  }
}

String? _tryGetConfiguration(BuildInput input) {
  final code = input.config.code;
  final platform = switch (code.targetOS) {
    .macOS => 'macos',
    .windows => 'windows',
    .linux => 'linux',
    .android => 'android',
    .iOS => code.iOS.targetSdk == IOSSdk.iPhoneSimulator
        ? 'ios_sim'
        : 'ios',
    _ => null,
  };
  if (platform == null) return null;

  final arch = switch (code.targetArchitecture) {
    .x64 => 'x64',
    .arm64 => 'arm64',
    .arm => 'arm',
    .ia32 => 'x86',
    _ => null,
  };
  if (arch == null) return null;

  return '${platform}_$arch';
}

String _getLibName(OS os) => switch (os) {
  .macOS || .iOS => 'libqjs_dart.dylib',
  .windows => 'qjs_dart.dll',
  _ => 'libqjs_dart.so',
};
