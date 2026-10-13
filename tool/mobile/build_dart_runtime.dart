/// Builds the Dart runtime and the cross `gen_snapshot` for a mobile target,
/// from the Dart SDK's own sources (ADR 0010).
///
/// ```
/// dart run tool/mobile/build_dart_runtime.dart --checkout /path/dart-sdk-src \
///     --target android-arm64 [--fetch]
/// ```
///
/// Targets: `android-arm64`, `android-x64`, `ios-arm64`, `ios-simulator-arm64`,
/// and `macos-arm64` - the runtime of the embedded macOS backend
/// (`appkitEmbedded`, `tool/macos/build_app.dart`), whose `gen_snapshot` is a
/// host tool of the same build (`exe.stripped/gen_snapshot`).
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
/// `tool/mobile/dart_sdk_patches/<tag>-*.patch` is applied to the checkout
/// first, in name order (once; an applied patch is skipped). The macOS patch
/// goes on top of the iOS one: the same main-thread mode under
/// `DART_HOST_OS_MACOS`, on when the runtime is a `.app`'s executable.
///
/// The SDK's `find_sdk.py` wants a full Xcode; with only the Command Line
/// Tools selected, `DEVELOPER_DIR` is pointed at the first Xcode found
/// (`/Applications/Xcode.app`, or one beside the checkout). For iOS it makes the runtime an
/// app: the main isolate's messages run on the main thread from the main run
/// loop, the snapshot is found in the bundle, and `UIApplicationMain` runs
/// with the delegate class the Dart code registered (see the patch).
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
  'macos-arm64': (os: 'host', arch: 'arm64', config: 'ProductARM64'),
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
  await _applyPatches(sdk);
  macSdk ??= Platform.isMacOS ? _pickMacSdk() : null;
  final Map<String, String> environment = <String, String>{
    if (Platform.isMacOS)
      if (_developerDirectory(checkout) case final String developer)
        'DEVELOPER_DIR': developer,
  };
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
          if (target.os != 'host') ...<String>['--os', target.os],
          if (macSdk != null) ...<String>[
            '--gn-args',
            'mac_sdk_path="$macSdk"'
          ],
          'dartaotruntime',
        ],
        workingDirectory: sdk,
        environment: environment);
    final String hostToolchain =
        'clang_${Abi.current() == Abi.macosArm64 || Abi.current() == Abi.linuxArm64 ? 'arm64' : 'x64'}';
    // For macOS the target is the host: gen_snapshot is the build's own.
    final String genSnapshot =
        target.os == 'host' ? 'gen_snapshot' : '$hostToolchain/gen_snapshot';
    await _run('$sdk/buildtools/ninja/ninja', <String>['-C', out, genSnapshot],
        environment: environment);
    stdout
      ..writeln('$name:')
      ..writeln('  runtime:      $out/exe.stripped/dartaotruntime')
      ..writeln('  gen_snapshot: $out/$genSnapshot');
  }
}

Future<void> _applyPatches(String sdk) async {
  final String here = File(Platform.script.toFilePath()).parent.path;
  final Directory patches = Directory('$here/dart_sdk_patches');
  if (!patches.existsSync()) return;
  final List<File> ordered = patches
      .listSync()
      .whereType<File>()
      .where((File f) => f.path.split('/').last.startsWith('$sdkTag-'))
      .toList()
    // In name order: a later patch may build on an earlier one's lines.
    ..sort((File a, File b) => a.path.compareTo(b.path));
  // A patch built on an earlier one no longer reverses alone once the later
  // one is on top, so "already applied" is read from the end: the last patch
  // that reverses cleanly, and everything before it, is in the tree.
  var applied = 0;
  for (var index = ordered.length - 1; index >= 0; index--) {
    final ProcessResult reverses = await Process.run('git',
        <String>['apply', '--reverse', '--check', ordered[index].absolute.path],
        workingDirectory: sdk);
    if (reverses.exitCode == 0) {
      applied = index + 1;
      break;
    }
  }
  for (final File patch in ordered.skip(applied)) {
    await _run('git', <String>['apply', patch.absolute.path],
        workingDirectory: sdk);
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

/// `DEVELOPER_DIR` for the SDK's `find_sdk.py`, which refuses the Command
/// Line Tools: the caller's when set, else the first Xcode found.
String? _developerDirectory(String checkout) {
  final String? set = Platform.environment['DEVELOPER_DIR'];
  if (set != null) return set;
  final ProcessResult selected =
      Process.runSync('xcode-select', <String>['-p']);
  final String path = '${selected.stdout}'.trim();
  if (selected.exitCode == 0 && !path.contains('CommandLineTools')) {
    return null;
  }
  for (final String xcode in <String>[
    '/Applications/Xcode.app',
    '${Directory(checkout).absolute.parent.path}/Xcode.app',
  ]) {
    final String developer = '$xcode/Contents/Developer';
    if (Directory(developer).existsSync()) return developer;
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
    {String? workingDirectory, Map<String, String>? environment}) async {
  stdout.writeln('> $executable ${arguments.join(' ')}');
  final Process process = await Process.start(executable, arguments,
      workingDirectory: workingDirectory,
      environment: environment,
      mode: ProcessStartMode.inheritStdio);
  final int code = await process.exitCode;
  if (code != 0) _fail('$executable exited $code');
}

Never _fail(String message) {
  stderr.writeln('build_dart_runtime: $message');
  exit(1);
}
