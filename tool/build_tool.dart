import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

void main(List<String> args) async {
  final runner = CommandRunner<void>('qjs_build', 'QuickJS Dart build tool')
    ..addCommand(BuildCommand())
    ..addCommand(HashCommand())
    ..addCommand(CollectCommand())
    ..addCommand(ListCommand())
    ..addCommand(TrimCommand());

  try {
    await runner.run(args);
  } catch (e) {
    stderr.writeln(e);
    exit(1);
  }
}

class BuildConfig {
  BuildConfig({required this.name, required this.options});

  final String name;
  final Map<String, dynamic> options;

  String get targetOs => options['target_os'] as String;
  String get targetCpu => options['target_cpu'] as String;
  bool get iosUseSimulator => options['ios_use_simulator'] as bool? ?? false;

  static List<BuildConfig> loadAll() {
    final configFile = File('tool/build_config.json');
    if (!configFile.existsSync()) return [];
    final json = configFile.readAsStringSync();
    final configData = jsonDecode(json) as Map<String, dynamic>;
    return configData.entries
        .map(
          (e) => BuildConfig(
            name: e.key,
            options: e.value as Map<String, dynamic>,
          ),
        )
        .toList();
  }

  static List<BuildConfig> loadLocal() {
    return loadAll().where((config) {
      if (config.targetOs == 'android') return true;
      if (Platform.isMacOS) {
        return config.targetOs == 'macos' || config.targetOs == 'ios';
      }
      if (Platform.isWindows) return config.targetOs == 'windows';
      if (Platform.isLinux) return config.targetOs == 'linux';
      return false;
    }).toList();
  }
}

class BuildCommand extends Command<void> {
  BuildCommand() {
    argParser
      ..addOption(
        'config',
        abbr: 'c',
        help: 'Config name from build_config.json',
        allowed: BuildConfig.loadAll().map((e) => e.name),
      )
      ..addOption(
        'jobs',
        abbr: 'j',
        help: 'Number of parallel build jobs',
        defaultsTo: '4',
      )
      ..addOption(
        'ndk',
        help: 'Path to Android NDK',
      )
      ..addFlag(
        'verbose',
        abbr: 'v',
        help: 'Enable verbose output',
        negatable: false,
      );
  }

  @override
  final String name = 'build';

  @override
  final String description = 'Build QuickJS for a specific configuration.';

  @override
  Future<void> run() async {
    final results = argResults;
    final configName = results?['config'] as String?;
    if (configName == null) {
      stdout.writeln('Available configurations:');
      for (final c in BuildConfig.loadLocal()) {
        stdout.writeln('  - ${c.name}');
      }
      throw UsageException('Option --config is required.', usage);
    }

    final allConfigs = BuildConfig.loadAll();
    final config = allConfigs.firstWhere((e) => e.name == configName);

    final buildDir = 'build_${config.name}';
    final extraFlags = <String>[];

    if (config.targetOs == 'macos') {
      final arch = config.targetCpu == 'x64' ? 'x86_64' : 'arm64';
      extraFlags.add('-DCMAKE_OSX_ARCHITECTURES=$arch');
    }

    if (config.targetOs == 'ios') {
      final arch = config.targetCpu == 'x64' ? 'x86_64' : 'arm64';
      final sdkName = config.iosUseSimulator ? 'iphonesimulator' : 'iphoneos';
      final sdkPath = Process.runSync('xcrun', [
        '--sdk',
        sdkName,
        '--show-sdk-path',
      ]).stdout.toString().trim();

      extraFlags.addAll([
        '-DCMAKE_SYSTEM_NAME=iOS',
        '-DCMAKE_OSX_SYSROOT=$sdkPath',
        '-DCMAKE_OSX_ARCHITECTURES=$arch',
      ]);
    }

    if (config.targetOs == 'android') {
      final ndkPath =
          results?['ndk'] as String? ??
          Platform.environment['ANDROID_NDK'] ??
          Platform.environment['ANDROID_NDK_HOME'] ??
          Platform.environment['ANDROID_NDK_ROOT'] ??
          _detectLocalNdk();

      if (ndkPath == null || !Directory(ndkPath).existsSync()) {
        throw Exception(
          'Android NDK path not found. Please set ANDROID_NDK environment '
          'variable or pass --ndk option.',
        );
      }

      final abi = switch (config.targetCpu) {
        'arm64' => 'arm64-v8a',
        'arm' => 'armeabi-v7a',
        'x64' => 'x86_64',
        'x86' => 'x86',
        _ => throw Exception('Unsupported target CPU: ${config.targetCpu}'),
      };

      final ndkCMake = p.join(
        ndkPath,
        'build',
        'cmake',
        'android.toolchain.cmake',
      );

      if (!File(ndkCMake).existsSync()) {
        throw Exception('CMake toolchain file not found in NDK at: $ndkCMake');
      }

      extraFlags.addAll([
        '-DCMAKE_TOOLCHAIN_FILE=$ndkCMake',
        '-DANDROID_ABI=$abi',
        '-DANDROID_PLATFORM=android-24',
        '-DANDROID_PIE=ON',
      ]);
    }

    if (config.targetOs == 'windows' && config.targetCpu == 'arm64') {
      extraFlags
        ..add('-A')
        ..add('ARM64');
    }

    if (config.targetOs == 'linux' &&
        config.targetCpu == 'arm64' &&
        Platform.isLinux) {
      final hostArch =
          Process.runSync('uname', ['-m']).stdout.toString().trim();
      if (hostArch != 'aarch64') {
        stdout.writeln('--- Cross-compiling for Linux ARM64 ---');
        extraFlags
          ..add('-DCMAKE_C_COMPILER=aarch64-linux-gnu-gcc')
          ..add('-DCMAKE_SYSTEM_NAME=Linux')
          ..add('-DCMAKE_SYSTEM_PROCESSOR=aarch64');
      }
    }

    stdout.writeln('--- Configuring ${config.name} ---');
    final configureProcess = await Process.start('cmake', [
      '-B',
      buildDir,
      '-DCMAKE_BUILD_TYPE=Release',
      ...extraFlags,
    ]);

    configureProcess.stdout.transform(utf8.decoder).listen(stdout.write);
    configureProcess.stderr.transform(utf8.decoder).listen(stderr.write);

    if (await configureProcess.exitCode != 0) {
      throw Exception('CMake configuration failed');
    }

    stdout.writeln('--- Building ${config.name} ---');
    final jobs = results?['jobs'] as String? ?? '4';
    final verbose = results?['verbose'] as bool? ?? false;

    final buildProcess = await Process.start('cmake', [
      '--build',
      buildDir,
      '--config',
      'Release',
      '-j',
      jobs,
      if (verbose) '-v',
    ]);

    buildProcess.stdout.transform(utf8.decoder).listen(stdout.write);
    buildProcess.stderr.transform(utf8.decoder).listen(stderr.write);

    if (await buildProcess.exitCode != 0) throw Exception('Build failed');

    stdout.writeln('--- Successfully built ${config.name} ---');
  }
}

class HashCommand extends Command<void> {
  HashCommand() {
    argParser.addFlag(
      'verify',
      help: 'Check if current hash matches state',
      negatable: false,
    );
  }

  @override
  final String name = 'hash';

  @override
  final String description = 'Generate or verify the qjs_hash.';

  @override
  void run() {
    final workspaceRoot = Directory.current.path;
    final expectedHash = _generateHash(workspaceRoot);

    if (argResults?['verify'] as bool? ?? false) {
      final hashFile = File('qjs_hash');
      if (!hashFile.existsSync()) throw Exception('qjs_hash file missing');
      final actualHash = hashFile.readAsStringSync().trim();
      if (expectedHash != actualHash) {
        throw Exception(
          'qjs_hash is out of date! Expected: $expectedHash, '
          'Got: $actualHash',
        );
      }
      stdout.writeln('qjs_hash is up to date.');
    } else {
      File('qjs_hash').writeAsStringSync(expectedHash);
      stdout.writeln('Generated qjs_hash: $expectedHash');
    }
  }

  String _generateHash(String root) {
    String gitHash(String obj) {
      final res = Process.runSync(
        'git',
        ['rev-parse', obj],
        workingDirectory: root,
      );
      return res.exitCode == 0 ? (res.stdout as String).trim() : 'unknown';
    }

    final combined =
        '${gitHash('HEAD:quickjs')}'
        '${gitHash('HEAD:src')}'
        '${gitHash('HEAD:CMakeLists.txt')}';

    return sha1.convert(utf8.encode(combined)).toString();
  }
}

class CollectCommand extends Command<void> {
  @override
  final String name = 'collect';

  @override
  final String description =
      'Collect all built binaries and update prebuilt_hashes.json.';

  @override
  Future<void> run() async {
    final configs = BuildConfig.loadAll();
    final hashes = <String, String>{};

    final releaseAssetsDir = Directory('release_assets');
    if (releaseAssetsDir.existsSync()) {
      releaseAssetsDir.deleteSync(recursive: true);
    }
    releaseAssetsDir.createSync();

    for (final config in configs) {
      final buildDir = Directory('build_${config.name}');
      if (!buildDir.existsSync()) continue;

      final libName = getLibName(config.targetOs);
      var libFile = File(p.join(buildDir.path, libName));

      if (!libFile.existsSync()) {
        libFile = File(p.join(buildDir.path, 'Release', libName));
      }

      if (libFile.existsSync()) {
        final bytes = await libFile.readAsBytes();
        final hash = sha256.convert(bytes).toString();
        final assetName = '${config.name}_$libName';
        hashes[assetName] = hash;
        await libFile.copy(p.join(releaseAssetsDir.path, assetName));
        stdout.writeln('Collected: $assetName');
      }
    }

    final hashesFile = File('prebuilt_hashes.json');
    const encoder = JsonEncoder.withIndent('  ');
    hashesFile.writeAsStringSync('${encoder.convert(hashes)}\n');

    stdout.writeln(
      'Updated prebuilt_hashes.json with ${hashes.length} entries.',
    );
  }
}

class ListCommand extends Command<void> {
  ListCommand() {
    argParser.addFlag('local', help: 'Only local platforms', negatable: false);
  }

  @override
  final String name = 'list';
  @override
  final String description = 'List configurations.';

  @override
  void run() {
    final results = argResults;
    final configs = (results?['local'] as bool? ?? false)
        ? BuildConfig.loadLocal()
        : BuildConfig.loadAll();

    for (final c in configs) {
      stdout.writeln('${c.name} (${c.targetOs}/${c.targetCpu})');
    }
  }
}

class TrimCommand extends Command<void> {
  @override
  final String name = 'trim';

  @override
  final String description = 'Remove ALL artifacts except the final binary.';

  @override
  Future<void> run() async {
    final configs = BuildConfig.loadAll();
    for (final config in configs) {
      final buildDir = Directory('build_${config.name}');
      if (!buildDir.existsSync()) continue;
      await _trimDirectory(config, buildDir);
    }
    stdout.writeln('--- Aggressive trim complete ---');
  }

  Future<void> _trimDirectory(BuildConfig config, Directory dir) async {
    final libName = getLibName(config.targetOs);
    File? libFile;

    final possiblePaths = [
      p.join(dir.path, libName),
      p.join(dir.path, 'Release', libName),
    ];

    for (final path in possiblePaths) {
      final file = File(path);
      if (file.existsSync()) {
        libFile = file;
        break;
      }
    }

    if (libFile == null) {
      stdout.writeln(
        '!!! Warning: Binary not found in ${dir.path}, skipping trim.',
      );
      return;
    }

    final bytes = await libFile.readAsBytes();

    stdout.writeln('--- Wiping ${dir.path} ---');
    try {
      dir.deleteSync(recursive: true);
    } catch (e) {
      stdout.writeln('!!! Could not delete ${dir.path} entirely: $e');
    }

    dir.createSync(recursive: true);
    final finalFile = File(p.join(dir.path, libName));
    await finalFile.writeAsBytes(bytes);
    stdout.writeln('--- Trimmed to 1 file: ${finalFile.path} ---');
  }
}

String getLibName(String os) {
  return switch (os) {
    'macos' || 'ios' => 'libqjs_dart.dylib',
    'windows' => 'qjs_dart.dll',
    _ => 'libqjs_dart.so',
  };
}

String? _detectLocalNdk() {
  final home =
      Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
  if (home == null) return null;

  if (Platform.isMacOS) {
    final ndkDir = Directory(p.join(home, 'Library/Android/sdk/ndk'));
    if (ndkDir.existsSync()) {
      final versions = ndkDir.listSync().whereType<Directory>().toList();
      if (versions.isNotEmpty) {
        versions.sort(
          (a, b) => p.basename(b.path).compareTo(p.basename(a.path)),
        );
        return versions.first.path;
      }
    }
    final bundleDir = Directory(p.join(home, 'Library/Android/sdk/ndk-bundle'));
    if (bundleDir.existsSync()) return bundleDir.path;
  } else if (Platform.isLinux) {
    final ndkDir = Directory(p.join(home, 'Android/Sdk/ndk'));
    if (ndkDir.existsSync()) {
      final versions = ndkDir.listSync().whereType<Directory>().toList();
      if (versions.isNotEmpty) {
        versions.sort(
          (a, b) => p.basename(b.path).compareTo(p.basename(a.path)),
        );
        return versions.first.path;
      }
    }
    final bundleDir = Directory(p.join(home, 'Android/Sdk/ndk-bundle'));
    if (bundleDir.existsSync()) return bundleDir.path;
  } else if (Platform.isWindows) {
    final localApp = Platform.environment['LOCALAPPDATA'];
    if (localApp != null) {
      final ndkDir = Directory(p.join(localApp, 'Android', 'Sdk', 'ndk'));
      if (ndkDir.existsSync()) {
        final versions = ndkDir.listSync().whereType<Directory>().toList();
        if (versions.isNotEmpty) {
          versions.sort(
            (a, b) => p.basename(b.path).compareTo(p.basename(a.path)),
          );
          return versions.first.path;
        }
      }
      final bundleDir = Directory(
        p.join(localApp, 'Android', 'Sdk', 'ndk-bundle'),
      );
      if (bundleDir.existsSync()) return bundleDir.path;
    }
  }
  return null;
}
