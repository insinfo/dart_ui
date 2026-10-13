/// Builds a macOS `.app` that runs on the fourth macOS backend,
/// `appkitEmbedded`: the executable is the Dart AOT runtime compiled from the
/// Dart SDK's sources with `tool/mobile/dart_sdk_patches/3.13.5-macos.patch`,
/// the program a Mach-O snapshot in `Contents/Frameworks/App.framework`, and
/// AppKit runs in that one process with Dart as the guest of its run loop
/// (`doc/MACOS_TRES_BACKENDS.md`, backend 4).
///
/// ```
/// dart run tool/macos/build_app.dart <entrypoint.dart> [options]
///   -o, --out build/X.app       the bundle (default build/<entry>.app)
///   --name NAME                 display name
///   --identifier ID             bundle identifier
///   --icon PNG                  square PNG made into AppIcon.icns
///   --embed PATH                files compiled into the program (repeatable)
///   --no-embed-fonts            leave dart_ui's fonts out
///   --checkout DIR              Dart SDK checkout (DART_UI_DART_SDK_SRC)
///   --dart PATH                 a stock Dart 3.13.5 `dart` for the kernel
///   --no-build-runtime          fail instead of building a missing runtime
///   --sign IDENTITY|-           codesign identity (default -, ad hoc)
///   --run                       open the bundle when built
/// ```
///
/// The runtime is built when it is missing or does not export the patch's
/// symbol, by `tool/mobile/build_dart_runtime.dart --target macos-arm64`
/// (minutes; the checkout must exist - see that tool's `--fetch`). Without
/// `--checkout` the checkout is `DART_UI_DART_SDK_SRC`, else a
/// `dart-sdk-src` beside this repository's parent folder. Without `--dart`
/// the kernel compiler is `DART_UI_MACOS_DART`, `DART_UI_IOS_DART`, the
/// running `dart` when it is 3.13.5, or `DartSDKs/3.13.5-macos` beside the
/// checkout.
///
/// Same as `dart run dart_ui build --macos-backend=embedded`, plus finding
/// and building the toolchain. No Xcode project, no Flutter.
library;

import 'dart:io';

import 'package:dart_ui/src/tooling/application_builder.dart';
import 'package:dart_ui/src/tooling/macos_embedded_bundle.dart';

Future<void> main(List<String> arguments) async {
  String? entrypoint;
  String? out;
  String? name;
  String? identifier;
  String? icon;
  String? checkout = Platform.environment['DART_UI_DART_SDK_SRC'];
  String? dart;
  String? sign = '-';
  var buildRuntime = true;
  var run = false;
  var embedFonts = true;
  final List<String> embed = <String>[];
  for (var i = 0; i < arguments.length; i++) {
    final String argument = arguments[i];
    String value() {
      if (i + 1 >= arguments.length) _fail('$argument needs a value');
      return arguments[++i];
    }

    switch (argument) {
      case '-o' || '--out':
        out = value();
      case '--name':
        name = value();
      case '--identifier':
        identifier = value();
      case '--icon':
        icon = value();
      case '--embed':
        embed.add(value());
      case '--no-embed-fonts':
        embedFonts = false;
      case '--checkout':
        checkout = value();
      case '--dart':
        dart = value();
      case '--no-build-runtime':
        buildRuntime = false;
      case '--sign':
        sign = value();
      case '--no-sign':
        sign = null;
      case '--run':
        run = true;
      default:
        if (argument.startsWith('-') || entrypoint != null) {
          _fail('unexpected argument $argument');
        }
        entrypoint = argument;
    }
  }
  if (entrypoint == null) {
    _fail('usage: build_app.dart <entrypoint.dart> [-o X.app] [--name N] '
        '[--identifier ID] [--icon PNG] [--checkout DIR] [--dart PATH] '
        '[--sign ID|-] [--run]');
  }
  if (!Platform.isMacOS) _fail('a macOS bundle is built on macOS');

  checkout ??= _siblingCheckout();
  if (checkout == null) {
    _fail('no Dart SDK checkout: pass --checkout or set DART_UI_DART_SDK_SRC '
        '(tool/mobile/build_dart_runtime.dart --fetch makes one)');
  }
  final String hostDart = dart ??
      await _hostDart(checkout) ??
      _fail('no Dart $macosEmbeddedSdkTag for the kernel: pass --dart or set '
          'DART_UI_MACOS_DART');
  MacosEmbeddedToolchain toolchain = MacosEmbeddedToolchain.resolve(
      Platform.environment,
      checkout: checkout,
      dart: hostDart)!;
  if (!await _runtimeIsPatched(toolchain, checkout)) {
    if (!buildRuntime) {
      _fail('the patched runtime is missing or stale: ${toolchain.runtime}');
    }
    stdout.writeln('Building the patched Dart runtime for macOS arm64 '
        '(minutes the first time)...');
    final Process build = await Process.start(
      Platform.resolvedExecutable,
      <String>[
        'run',
        'tool/mobile/build_dart_runtime.dart',
        '--checkout',
        checkout,
        '--target',
        'macos-arm64',
      ],
      mode: ProcessStartMode.inheritStdio,
    );
    if (await build.exitCode != 0) _fail('the runtime build failed');
    toolchain = MacosEmbeddedToolchain.resolve(Platform.environment,
        checkout: checkout, dart: hostDart)!;
    if (!await _runtimeIsPatched(toolchain, checkout)) {
      _fail('the built runtime does not export $macosEmbeddedRuntimeSymbol; '
          'is tool/mobile/dart_sdk_patches/$macosEmbeddedSdkTag-macos.patch '
          'applied?');
    }
  }

  try {
    final ApplicationBuildResult result =
        await DesktopApplicationBuilder().build(ApplicationBuildRequest(
      entrypoint: entrypoint,
      outputPath: out,
      appName: name,
      bundleIdentifier: identifier,
      iconPath: icon,
      embed: embed,
      embedFrameworkFonts: embedFonts,
      codesignIdentity: sign,
      macosBackend: MacosAppBackend.embedded,
      macosEmbeddedToolchain: toolchain,
    ));
    stdout.writeln('app: ${result.primaryArtifact}');
    if (run) {
      await Process.run('open', <String>[result.primaryArtifact]);
    }
  } on ApplicationBuildException catch (error) {
    _fail(error.message);
  }
}

/// Whether [toolchain]'s runtime exists, exports the patch's symbol, was
/// built after the patched sources last changed, and the macOS patch is in
/// [checkout].
Future<bool> _runtimeIsPatched(
    MacosEmbeddedToolchain toolchain, String checkout) async {
  final File runtime = File(toolchain.runtime);
  if (!runtime.existsSync() || !File(toolchain.genSnapshot).existsSync()) {
    return false;
  }
  final ProcessResult symbols =
      await Process.run('nm', <String>['-gU', runtime.path]);
  if (!'${symbols.stdout}'.contains(macosEmbeddedRuntimeSymbol)) return false;
  final File patch =
      File('tool/mobile/dart_sdk_patches/$macosEmbeddedSdkTag-macos.patch');
  if (patch.existsSync()) {
    final ProcessResult applied = await Process.run(
        'git', <String>['apply', '--reverse', '--check', patch.absolute.path],
        workingDirectory: '$checkout/sdk');
    if (applied.exitCode != 0) return false;
  }
  final DateTime built = runtime.lastModifiedSync();
  for (final String source in <String>['main.cc', 'main_impl.cc']) {
    final File file = File('$checkout/sdk/runtime/bin/$source');
    if (file.existsSync() && file.lastModifiedSync().isAfter(built)) {
      return false;
    }
  }
  return true;
}

/// `dart-sdk-src` beside the folder that holds this repository, the layout
/// the mobile tools were developed with.
String? _siblingCheckout() {
  Directory directory = Directory.current.absolute;
  for (var depth = 0; depth < 3; depth++) {
    final Directory candidate =
        Directory('${directory.parent.path}/dart-sdk-src');
    if (File('${candidate.path}/sdk/tools/build.py').existsSync()) {
      return candidate.path;
    }
    directory = directory.parent;
  }
  return null;
}

/// A stock `dart` of [macosEmbeddedSdkTag].
Future<String?> _hostDart(String checkout) async {
  final Map<String, String> env = Platform.environment;
  final List<String> candidates = <String>[
    if (env['DART_UI_MACOS_DART'] case final String dart) dart,
    if (env['DART_UI_IOS_DART'] case final String dart) dart,
    Platform.resolvedExecutable,
    '${Directory(checkout).absolute.parent.path}/DartSDKs/'
        '$macosEmbeddedSdkTag-macos/dart-sdk/bin/dart',
  ];
  for (final String candidate in candidates) {
    if (!File(candidate).existsSync()) continue;
    final ProcessResult version =
        await Process.run(candidate, <String>['--version']);
    if ('${version.stdout}${version.stderr}'
        .contains('Dart SDK version: $macosEmbeddedSdkTag ')) {
      return candidate;
    }
  }
  return null;
}

Never _fail(String message) {
  stderr.writeln('build_app: $message');
  exit(1);
}
