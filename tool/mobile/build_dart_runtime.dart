/// Builds the Dart runtime and the cross `gen_snapshot` for a mobile target,
/// from the Dart SDK's own sources (ADR 0010).
///
/// ```
/// dart run tool/mobile/build_dart_runtime.dart --checkout /path/dart-sdk-src \
///     --target android-arm64 [--fetch]
/// ```
///
/// Targets: `android-arm64`, `android-x64`, `ios-arm64`, `ios-simulator-arm64`.
///
/// `--fetch` writes a `.gclient` for the tag in [sdkTag] with the Android and
/// iOS dependencies and runs `gclient sync` (depot_tools on `PATH`). The
/// checkout is about 13 GB; a build takes minutes.
///
/// What comes out, under `<checkout>/sdk/xcodebuild/<config>` on macOS or
/// `out/<config>` on Linux:
///
///   * `exe.stripped/dartaotruntime` - the runtime, built for the target;
///   * `clang_<host>/gen_snapshot` - runs here and emits code for the target.
///
/// On macOS the host tools link against the newest SDK in the Command Line
/// Tools that the SDK's bundled `ld64.lld` reads: macOS 27's `.tbd` stubs name
/// an `arm64e.x1-macos` target that lld 3.13.5 rejects ("unknown target").
/// `--mac-sdk` overrides the choice.
///
/// Never the Flutter engine: these are the Dart SDK's own build targets.
library;

import 'dart:ffi';
import 'dart:io';

/// The tag the runtime is built from. It must equal the SDK that compiles
/// the kernel (`runtimeVersion` in `tool/android/build_apk.dart`).
const String sdkTag = '3.13.5';

const Map<String, ({String os, String arch, String config})> _targets =
    <String, ({String os, String arch, String config})>{
  'android-arm64': (
    os: 'android',
    arch: 'arm64',
    config: 'ProductAndroidARM64'
  ),
  'android-x64': (os: 'android', arch: 'x64', config: 'ProductAndroidX64'),
  'ios-arm64': (os: 'ios', arch: 'arm64', config: 'ProductIosARM64'),
  'ios-simulator-arm64': (
    os: 'ios_simulator',
    arch: 'arm64',
    config: 'ProductIosSimARM64'
  ),
};

Future<void> main(List<String> arguments) async {
  String? checkout = Platform.environment['DART_UI_DART_SDK_SRC'];
  final List<String> targets = <String>[];
  String? macSdk;
  var fetch = false;
  for (var i = 0; i < arguments.length; i++) {
    switch (arguments[i]) {
      case '--checkout':
        checkout = arguments[++i];
      case '--target':
        targets.add(arguments[++i]);
      case '--mac-sdk':
        macSdk = arguments[++i];
      case '--fetch':
        fetch = true;
      default:
        _fail('unexpected argument ${arguments[i]}');
    }
  }
  if (checkout == null || targets.isEmpty) {
    _fail('usage: build_dart_runtime.dart --checkout DIR --target '
        '${_targets.keys.join('|')} [--fetch] [--mac-sdk PATH]');
  }
  for (final String target in targets) {
    if (!_targets.containsKey(target)) _fail('unknown target $target');
  }
  if (fetch) await _fetch(checkout);
  final String sdk = '$checkout/sdk';
  if (!File('$sdk/tools/build.py').existsSync()) {
    _fail('no Dart SDK checkout at $sdk (use --fetch)');
  }
  macSdk ??= Platform.isMacOS ? _pickMacSdk() : null;
  for (final String name in targets) {
    final ({String os, String arch, String config}) target = _targets[name]!;
    final String out =
        '$sdk/${Platform.isMacOS ? 'xcodebuild' : 'out'}/${target.config}';
    await _run(
        'python3',
        <String>[
          'tools/build.py',
          '--no-rbe',
          '-m',
          'product',
          '-a',
          target.arch,
          '--os',
          target.os,
          if (macSdk != null) ...<String>[
            '--gn-args',
            'mac_sdk_path="$macSdk"'
          ],
          'dartaotruntime',
        ],
        workingDirectory: sdk);
    final String hostToolchain =
        'clang_${Abi.current() == Abi.macosArm64 || Abi.current() == Abi.linuxArm64 ? 'arm64' : 'x64'}';
    await _run('$sdk/buildtools/ninja/ninja',
        <String>['-C', out, '$hostToolchain/gen_snapshot']);
    stdout
      ..writeln('$name:')
      ..writeln('  runtime:      $out/exe.stripped/dartaotruntime')
      ..writeln('  gen_snapshot: $out/$hostToolchain/gen_snapshot');
  }
}

String? _pickMacSdk() {
  final Directory sdks = Directory('/Library/Developer/CommandLineTools/SDKs');
  if (!sdks.existsSync()) return null;
  final List<String> versioned = sdks
      .listSync()
      .map((FileSystemEntity e) => e.path.split('/').last)
      .where((String n) => RegExp(r'^MacOSX\d+\.\d+\.sdk$').hasMatch(n))
      .toList();
  // The newest one whose stubs do not name the arm64e.x1 target.
  versioned.sort((String a, String b) => _version(b).compareTo(_version(a)));
  for (final String name in versioned) {
    final File stub = File('${sdks.path}/$name/usr/lib/libSystem.tbd');
    if (stub.existsSync() && !stub.readAsStringSync().contains('arm64e.x1')) {
      return '${sdks.path}/$name';
    }
  }
  return null;
}

double _version(String sdkName) =>
    double.tryParse(sdkName
        .replaceAll(RegExp(r'[^0-9.]'), '')
        .replaceFirst(RegExp(r'\.$'), '')) ??
    0;

Future<void> _fetch(String checkout) async {
  Directory(checkout).createSync(recursive: true);
  File('$checkout/.gclient').writeAsStringSync('''
solutions = [
  {
    "name": "sdk",
    "url": "https://dart.googlesource.com/sdk.git@refs/tags/$sdkTag",
    "deps_file": "DEPS",
    "managed": False,
    "custom_deps": {},
    "custom_vars": {"download_android_deps": True},
  },
]
target_os = ["android", "ios"]
''');
  await _run('gclient', <String>['sync', '--no-history', '--shallow'],
      workingDirectory: checkout);
}

Future<void> _run(String executable, List<String> arguments,
    {String? workingDirectory}) async {
  stdout.writeln('> $executable ${arguments.join(' ')}');
  final Process process = await Process.start(executable, arguments,
      workingDirectory: workingDirectory, mode: ProcessStartMode.inheritStdio);
  final int code = await process.exitCode;
  if (code != 0) _fail('$executable exited $code');
}

Never _fail(String message) {
  stderr.writeln('build_dart_runtime: $message');
  exit(1);
}
