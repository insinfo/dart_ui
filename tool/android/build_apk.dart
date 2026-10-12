/// Builds an APK that runs a dart_ui application on Android.
///
/// ```
/// dart run tool/android/build_apk.dart <entrypoint.dart> [options]
///   --out build/android/app.apk
///   --package dev.dartui.app
///   --label "dart_ui"
///   --abi arm64-v8a --abi x86_64
///   --install          adb install -r the result
///   --run              and start it
/// ```
///
/// What goes in (see `lib/src/backends/android/android_backend.dart` for why
/// the shape is a host activity plus a VM process):
///
///   * the host activity, `lib/src/backends/android/host/`, compiled with
///     `javac` and `d8` - no Gradle, no Android Studio;
///   * the application as a kernel (`.dill`), compiled here by a Dart SDK of
///     **exactly** the runtime's version, because a VM refuses a kernel from
///     another one;
///   * the Dart VM for each ABI, from Termux's `dart` package: it is built for
///     Android and links only bionic (libc, libdl, libm, liblog), so it runs
///     in any app process. There is no official Dart SDK for Android.
///
/// Both binaries go under `lib/<abi>/` named `lib*.so`, so the package
/// manager extracts them into the native-library directory - the one place an
/// app may execute files from.
///
/// Environment: `ANDROID_HOME` (platform 35 and build-tools), `JAVA_HOME`
/// (JDK 17), `DART_UI_ANDROID_DART` (the `dart` of the matching SDK; default
/// `dart` on PATH), `DART_UI_ANDROID_RUNTIME_CACHE` (where the Termux
/// packages are kept; default `build/android/runtime`).
library;

import 'dart:io';

/// The runtime this tool packages. Changing it means a matching
/// `DART_UI_ANDROID_DART`.
const String runtimeVersion = '3.13.5';

const Map<String, String> _termuxArch = <String, String>{
  'arm64-v8a': 'aarch64',
  'x86_64': 'x86_64',
};

Future<void> main(List<String> arguments) async {
  final _Options options;
  try {
    options = _Options.parse(arguments);
  } on FormatException catch (error) {
    stderr.writeln(error.message);
    exitCode = 64;
    return;
  }
  try {
    await _Build(options).run();
  } on _BuildError catch (error) {
    stderr.writeln('build_apk: ${error.message}');
    exitCode = 1;
  }
}

final class _Options {
  _Options({
    required this.entrypoint,
    required this.out,
    required this.packageName,
    required this.label,
    required this.abis,
    required this.install,
    required this.run,
  });

  factory _Options.parse(List<String> arguments) {
    String? entrypoint;
    var out = 'build/android/app.apk';
    var packageName = 'dev.dartui.app';
    var label = 'dart_ui';
    final List<String> abis = <String>[];
    var install = false;
    var run = false;
    for (var i = 0; i < arguments.length; i++) {
      final String argument = arguments[i];
      String value() {
        if (i + 1 >= arguments.length) {
          throw FormatException('$argument needs a value');
        }
        return arguments[++i];
      }

      switch (argument) {
        case '--out':
          out = value();
        case '--package':
          packageName = value();
        case '--label':
          label = value();
        case '--abi':
          abis.add(value());
        case '--install':
          install = true;
        case '--run':
          install = true;
          run = true;
        default:
          if (argument.startsWith('-') || entrypoint != null) {
            throw FormatException('unexpected argument $argument');
          }
          entrypoint = argument;
      }
    }
    if (entrypoint == null) {
      throw const FormatException(
          'usage: dart run tool/android/build_apk.dart <entrypoint.dart> '
          '[--out app.apk] [--package id] [--abi arm64-v8a] [--install|--run]');
    }
    for (final String abi in abis) {
      if (!_termuxArch.containsKey(abi)) {
        throw FormatException('unsupported ABI $abi; one of '
            '${_termuxArch.keys.join(', ')}');
      }
    }
    return _Options(
      entrypoint: entrypoint,
      out: out,
      packageName: packageName,
      label: label,
      abis: abis.isEmpty ? <String>['arm64-v8a'] : abis,
      install: install,
      run: run,
    );
  }

  final String entrypoint;
  final String out;
  final String packageName;
  final String label;
  final List<String> abis;
  final bool install;
  final bool run;
}

final class _BuildError implements Exception {
  _BuildError(this.message);
  final String message;
}

final class _Build {
  _Build(this.options);

  final _Options options;
  final Map<String, String> env = Platform.environment;
  late final Directory work = Directory('${File(options.out).parent.path}/'
      '${_basename(options.out)}.work');
  late final String androidHome = _require('ANDROID_HOME');
  late final String javaHome = _require('JAVA_HOME');
  late final String buildTools = _latest('$androidHome/build-tools');
  late final String androidJar =
      '$androidHome/platforms/android-35/android.jar';
  final String hostDir = 'lib/src/backends/android/host';

  Future<void> run() async {
    if (!File(androidJar).existsSync()) {
      throw _BuildError('missing $androidJar - install "platforms;android-35"');
    }
    if (work.existsSync()) work.deleteSync(recursive: true);
    work.createSync(recursive: true);
    final String kernel = await _compileKernel();
    final Map<String, String> runtimes = <String, String>{
      for (final String abi in options.abis) abi: await _runtime(abi),
    };
    final String dex = await _compileHost();
    final String apk = await _package(kernel, runtimes, dex);
    stdout.writeln('APK: $apk');
    if (options.install) await _install(apk);
  }

  // -------------------------------------------------------------------------

  Future<String> _compileKernel() async {
    final String dart = env['DART_UI_ANDROID_DART'] ?? 'dart';
    final ProcessResult version =
        await Process.run(dart, <String>['--version']);
    final String banner = '${version.stdout}${version.stderr}';
    if (!banner.contains('Dart SDK version: $runtimeVersion ')) {
      throw _BuildError('the runtime is Dart $runtimeVersion and the kernel '
          'must come from the same SDK; $dart is "${banner.trim()}". '
          'Point DART_UI_ANDROID_DART at a $runtimeVersion SDK.');
    }
    final String kernel = '${work.path}/app.dill';
    await _exec(dart, <String>[
      'compile',
      'kernel',
      options.entrypoint,
      '-o',
      kernel,
    ]);
    return kernel;
  }

  /// The Termux VM for [abi], downloaded once into the cache.
  Future<String> _runtime(String abi) async {
    final String arch = _termuxArch[abi]!;
    final Directory cache = Directory(
        env['DART_UI_ANDROID_RUNTIME_CACHE'] ?? 'build/android/runtime');
    final Directory root = Directory('${cache.path}/$runtimeVersion-$arch');
    final File vm = File('${root.path}/dartvm');
    if (vm.existsSync()) return vm.path;
    root.createSync(recursive: true);
    final String deb = '${root.path}/dart.deb';
    final String url = 'https://packages.termux.dev/apt/termux-main/pool/main/'
        'd/dart/dart_${runtimeVersion}_$arch.deb';
    stdout.writeln('downloading $url');
    await _exec('curl', <String>['-fsSL', '-o', deb, url]);
    // A .deb is an ar archive. macOS's ar rejects its GNU member names and
    // its bsdtar reads it directly; on Linux, ar does.
    if (Platform.isMacOS) {
      await _exec('tar', <String>['-xf', 'dart.deb'],
          workingDirectory: root.path);
    } else {
      await _exec('ar', <String>['x', 'dart.deb'], workingDirectory: root.path);
    }
    final String data = Directory(root.path)
        .listSync()
        .map((FileSystemEntity e) => e.path)
        .firstWhere((String p) => _basename(p).startsWith('data.tar'),
            orElse: () => throw _BuildError('no data.tar in $url'));
    await _exec('tar', <String>[
      '-xf',
      data,
      '-C',
      root.path,
      './data/data/com.termux/files/usr/lib/dart-sdk/bin/dartvm',
    ]);
    File('${root.path}/data/data/com.termux/files/usr/lib/dart-sdk/bin/dartvm')
        .renameSync(vm.path);
    return vm.path;
  }

  Future<String> _compileHost() async {
    final Directory classes = Directory('${work.path}/classes')..createSync();
    final List<String> sources = Directory('$hostDir/java')
        .listSync(recursive: true)
        .whereType<File>()
        .map((File f) => f.path)
        .where((String p) => p.endsWith('.java'))
        .toList();
    await _exec('$javaHome/bin/javac', <String>[
      '--release',
      '11',
      '-classpath',
      androidJar,
      '-d',
      classes.path,
      ...sources,
    ]);
    final List<String> classFiles = classes
        .listSync(recursive: true)
        .whereType<File>()
        .map((File f) => f.path)
        .where((String p) => p.endsWith('.class'))
        .toList();
    final Directory dex = Directory('${work.path}/dex')..createSync();
    await _exec('$buildTools/d8', <String>[
      '--release',
      '--min-api',
      '26',
      '--lib',
      androidJar,
      '--output',
      dex.path,
      ...classFiles,
    ]);
    return '${dex.path}/classes.dex';
  }

  Future<String> _package(
      String kernel, Map<String, String> runtimes, String dex) async {
    final String unsigned = '${work.path}/unsigned.apk';
    await _exec('$buildTools/aapt2', <String>[
      'link',
      '-o',
      unsigned,
      '--manifest',
      '$hostDir/AndroidManifest.xml',
      '-I',
      androidJar,
      '--min-sdk-version',
      '26',
      // 34, not 35: 35 forces edge-to-edge, and the framework has no notion
      // of system-bar insets yet.
      '--target-sdk-version',
      '34',
      '--version-code',
      '1',
      '--version-name',
      '1.0',
      '--rename-manifest-package',
      options.packageName,
    ]);
    // The rest goes in with `zip`, paths relative to a staging root, so the
    // entries are exactly classes.dex and lib/<abi>/lib*.so.
    final Directory stage = Directory('${work.path}/stage')..createSync();
    File(dex).copySync('${stage.path}/classes.dex');
    for (final MapEntry<String, String> runtime in runtimes.entries) {
      final Directory lib = Directory('${stage.path}/lib/${runtime.key}')
        ..createSync(recursive: true);
      File(runtime.value).copySync('${lib.path}/libdartvm.so');
      File(kernel).copySync('${lib.path}/libdartui_app.so');
    }
    await _exec('zip', <String>['-q', '-r', File(unsigned).absolute.path, '.'],
        workingDirectory: stage.path);
    final String aligned = '${work.path}/aligned.apk';
    await _exec(
        '$buildTools/zipalign', <String>['-f', '-p', '4', unsigned, aligned]);
    final String keystore = await _debugKeystore();
    final File out = File(options.out)..parent.createSync(recursive: true);
    await _exec('$buildTools/apksigner', <String>[
      'sign',
      '--ks',
      keystore,
      '--ks-pass',
      'pass:android',
      '--key-pass',
      'pass:android',
      '--ks-key-alias',
      'androiddebugkey',
      '--out',
      out.path,
      aligned,
    ]);
    return out.path;
  }

  Future<String> _debugKeystore() async {
    final File keystore = File('build/android/debug.keystore');
    if (keystore.existsSync()) return keystore.path;
    keystore.parent.createSync(recursive: true);
    await _exec('$javaHome/bin/keytool', <String>[
      '-genkeypair',
      '-keystore',
      keystore.path,
      '-storepass',
      'android',
      '-keypass',
      'android',
      '-alias',
      'androiddebugkey',
      '-keyalg',
      'RSA',
      '-keysize',
      '2048',
      '-validity',
      '10000',
      '-dname',
      'CN=dart_ui debug',
    ]);
    return keystore.path;
  }

  Future<void> _install(String apk) async {
    final String adb = '$androidHome/platform-tools/adb';
    await _exec(adb, <String>['install', '-r', apk]);
    if (options.run) {
      await _exec(adb, <String>[
        'shell',
        'am',
        'start',
        '-n',
        '${options.packageName}/dev.dartui.host.DartUiActivity',
      ]);
    }
  }

  // -------------------------------------------------------------------------

  String _require(String name) {
    final String? value = env[name];
    if (value == null || value.isEmpty) throw _BuildError('$name is not set');
    return value;
  }

  String _latest(String directory) {
    final List<String> versions = Directory(directory)
        .listSync()
        .whereType<Directory>()
        .map((Directory d) => d.path)
        .toList()
      ..sort();
    if (versions.isEmpty) throw _BuildError('no build-tools in $directory');
    return versions.last;
  }

  Future<void> _exec(String executable, List<String> arguments,
      {String? workingDirectory}) async {
    final ProcessResult result = await Process.run(executable, arguments,
        workingDirectory: workingDirectory);
    if (result.exitCode != 0) {
      throw _BuildError('$executable ${arguments.take(3).join(' ')}... '
          'exited ${result.exitCode}\n${result.stdout}${result.stderr}');
    }
  }
}

String _basename(String path) => path.split(Platform.pathSeparator).last;
