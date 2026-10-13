/// The `.app` of the fourth macOS backend, `appkitEmbedded`: the bundle's
/// executable is the Dart AOT runtime built from the Dart SDK's sources with
/// `tool/mobile/dart_sdk_patches/3.13.5-macos.patch`, and the program is a
/// Mach-O snapshot in `Contents/Frameworks/App.framework` - the iOS layout of
/// ADR 0010, as a macOS framework.
///
/// ```
/// X.app/Contents/
///   Info.plist                      CFBundleExecutable = X, no LSUIElement
///   MacOS/X                         the patched dartaotruntime
///   Frameworks/App.framework/
///     App -> Versions/Current/App   what the runtime opens with dlopen
///     Resources -> Versions/Current/Resources
///     Versions/Current -> A
///     Versions/A/App                gen_snapshot --snapshot_kind=app-aot-macho-dylib
///     Versions/A/Resources/Info.plist
///   Resources/AppIcon.icns          with --icon
/// ```
///
/// The runtime finds `../Frameworks/App.framework/App` beside its own
/// executable when it is started with no snapshot argument - by Finder, by
/// `open`, or by running `Contents/MacOS/X` directly - and then runs the main
/// isolate on the main thread. Pure description here; the steps that run
/// tools are in `application_builder.dart`.
library;

import 'dart:io';

/// Which macOS backend a built `.app` runs.
enum MacosAppBackend {
  /// `dart compile exe` and the native AppKit host beside it - the default.
  nativeHost,

  /// The patched Dart runtime as the executable, AppKit in its process.
  embedded;

  /// `--macos-backend=` values: `host`/`native-host`, `embedded`.
  static MacosAppBackend parse(String value) => switch (value) {
        'host' || 'native-host' || 'nativeHost' => nativeHost,
        'embedded' || 'appkit-embedded' || 'appkitEmbedded' => embedded,
        _ => throw FormatException(
            'unknown macOS backend "$value"; use native-host or embedded'),
      };
}

/// The Dart SDK tag the embedded runtime is built from. The kernel, the
/// snapshot and the runtime must all be this version.
const String macosEmbeddedSdkTag = '3.13.5';

/// The `tools/build.py` configuration of the macOS arm64 runtime.
const String macosEmbeddedBuildConfig = 'ProductARM64';

/// The symbol the patched runtime exports and a stock one lacks.
const String macosEmbeddedRuntimeSymbol = '_Dart_DartUiMainThreadLoop';

/// The three programs a build needs, all from [macosEmbeddedSdkTag].
final class MacosEmbeddedToolchain {
  const MacosEmbeddedToolchain({
    required this.runtime,
    required this.genSnapshot,
    required this.hostDart,
  });

  /// The patched `dartaotruntime`, the bundle's executable.
  final String runtime;

  /// `gen_snapshot` from the same build.
  final String genSnapshot;

  /// A stock `dart` of the same tag, whose `gen_kernel_aot` and platform
  /// dill compile the kernel.
  final String hostDart;

  /// The host SDK's root.
  String get sdk => File(hostDart).absolute.parent.parent.path;

  String get genKernel => '$sdk/bin/snapshots/gen_kernel_aot.dart.snapshot';
  String get platformDill => '$sdk/lib/_internal/vm_platform_product.dill';
  String get kernelRuntime => '$sdk/bin/dartaotruntime';

  /// The build output a checkout's `tools/build.py` writes on macOS.
  static String buildDirectory(String checkout) =>
      '$checkout/sdk/xcodebuild/$macosEmbeddedBuildConfig';

  /// From the environment: `DART_UI_MACOS_EMBEDDED_OUT` (a build directory)
  /// or `DART_UI_DART_SDK_SRC` (a checkout), and `DART_UI_MACOS_DART` or
  /// `DART_UI_IOS_DART` for the host `dart`. [checkout] and [dart] win over
  /// the environment. Null when no build directory is named.
  static MacosEmbeddedToolchain? resolve(
    Map<String, String> environment, {
    String? checkout,
    String? buildDirectory,
    String? dart,
  }) {
    final String? out = buildDirectory ??
        (checkout == null
            ? null
            : MacosEmbeddedToolchain.buildDirectory(checkout)) ??
        environment['DART_UI_MACOS_EMBEDDED_OUT'] ??
        switch (environment['DART_UI_DART_SDK_SRC']) {
          final String source => MacosEmbeddedToolchain.buildDirectory(source),
          null => null,
        };
    if (out == null) return null;
    return MacosEmbeddedToolchain(
      runtime: '$out/exe.stripped/dartaotruntime',
      genSnapshot: '$out/exe.stripped/gen_snapshot',
      hostDart: dart ??
          environment['DART_UI_MACOS_DART'] ??
          environment['DART_UI_IOS_DART'] ??
          'dart',
    );
  }

  /// What is missing on disk, in words; empty when the toolchain is whole.
  List<String> missing() => <String>[
        for (final (String what, String path) in <(String, String)>[
          ('patched runtime', runtime),
          ('gen_snapshot', genSnapshot),
          ('gen_kernel_aot snapshot', genKernel),
          ('vm platform dill', platformDill),
        ])
          if (!File(path).existsSync()) '$what: $path',
      ];

  /// `gen_kernel_aot`'s arguments: a product AOT kernel for macOS.
  List<String> kernelArguments({
    required String entrypoint,
    required String packages,
    required String output,
  }) =>
      <String>[
        genKernel,
        '--platform',
        platformDill,
        '--aot',
        '--tfa',
        '--target-os',
        'macos',
        '-Ddart.vm.product=true',
        '--packages',
        packages,
        '-o',
        output,
        entrypoint,
      ];

  /// `gen_snapshot`'s arguments: the program as a Mach-O dylib, which the
  /// runtime opens with `dlopen` and `codesign` signs like any framework.
  List<String> snapshotArguments({
    required String kernel,
    required String output,
  }) =>
      <String>[
        '--snapshot_kind=app-aot-macho-dylib',
        '--macho=$output',
        '--strip',
        kernel,
      ];
}

/// Where everything goes in an embedded `.app`.
final class MacosEmbeddedBundleLayout {
  const MacosEmbeddedBundleLayout(this.bundlePath, this.executableName);

  final String bundlePath;
  final String executableName;

  /// Where the runtime looks, relative to its own directory (the patch's
  /// `MacRunBundle`).
  static const String snapshotFromExecutable =
      '../Frameworks/App.framework/App';

  String get contents => '$bundlePath/Contents';
  String get infoPlist => '$contents/Info.plist';
  String get macos => '$contents/MacOS';
  String get executable => '$macos/$executableName';
  String get resources => '$contents/Resources';
  String get frameworks => '$contents/Frameworks';
  String get framework => '$frameworks/App.framework';
  String get frameworkVersion => '$framework/Versions/A';
  String get snapshot => '$frameworkVersion/App';
  String get frameworkInfoPlist => '$frameworkVersion/Resources/Info.plist';

  /// The framework's symbolic links - link, then target relative to it -
  /// the versioned layout `codesign` expects of a macOS framework.
  List<(String, String)> get frameworkLinks => <(String, String)>[
        ('$framework/Versions/Current', 'A'),
        ('$framework/App', 'Versions/Current/App'),
        ('$framework/Resources', 'Versions/Current/Resources'),
      ];

  /// Creates the directories and the framework's links; files come after.
  void create() {
    final Directory bundle = Directory(bundlePath);
    if (bundle.existsSync()) bundle.deleteSync(recursive: true);
    for (final String directory in <String>[
      macos,
      resources,
      '$frameworkVersion/Resources',
    ]) {
      Directory(directory).createSync(recursive: true);
    }
    for (final (String link, String target) in frameworkLinks) {
      Link(link).createSync(target);
    }
  }
}

/// The application's `Info.plist`.
///
/// Unlike the native-host bundle there is no `LSUIElement`: the executable
/// is the one process, and it is the application the Dock shows.
String macosEmbeddedInfoPlist({
  required String appName,
  required String executableName,
  required String identifier,
  required String version,
  required String minimumSystemVersion,
  String? iconFile,
  Map<String, String> extra = const <String, String>{},
}) =>
    _plist(<String, Object>{
      'CFBundleDevelopmentRegion': 'en',
      'CFBundleDisplayName': appName,
      'CFBundleExecutable': executableName,
      'CFBundleIdentifier': identifier,
      'CFBundleInfoDictionaryVersion': '6.0',
      'CFBundleName': appName,
      'CFBundlePackageType': 'APPL',
      'CFBundleShortVersionString': version,
      'CFBundleVersion': version,
      if (iconFile != null) 'CFBundleIconFile': iconFile,
      'LSMinimumSystemVersion': minimumSystemVersion,
      'NSHighResolutionCapable': true,
      'NSPrincipalClass': 'NSApplication',
      ...extra,
    });

/// The snapshot framework's `Info.plist`.
String macosEmbeddedFrameworkInfoPlist({
  required String identifier,
  required String version,
  required String minimumSystemVersion,
}) =>
    _plist(<String, Object>{
      'CFBundleDevelopmentRegion': 'en',
      'CFBundleExecutable': 'App',
      'CFBundleIdentifier': '$identifier.app',
      'CFBundleInfoDictionaryVersion': '6.0',
      'CFBundleName': 'App',
      'CFBundlePackageType': 'FMWK',
      'CFBundleShortVersionString': version,
      'CFBundleVersion': version,
      'LSMinimumSystemVersion': minimumSystemVersion,
    });

/// The `package_config.json` that resolves [entrypoint]'s imports: the
/// nearest `.dart_tool/package_config.json` above it.
String? findPackageConfig(String entrypoint) {
  Directory directory = File(entrypoint).absolute.parent;
  while (true) {
    final File config =
        File('${directory.path}/.dart_tool/package_config.json');
    if (config.existsSync()) return config.path;
    final Directory parent = directory.parent;
    if (parent.path == directory.path) return null;
    directory = parent;
  }
}

String _plist(Map<String, Object> values) {
  final StringBuffer out = StringBuffer()
    ..writeln('<?xml version="1.0" encoding="UTF-8"?>')
    ..writeln('<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" '
        '"http://www.apple.com/DTDs/PropertyList-1.0.dtd">')
    ..writeln('<plist version="1.0">')
    ..writeln('<dict>');
  for (final MapEntry<String, Object> entry in values.entries) {
    out.writeln('  <key>${_xml(entry.key)}</key>');
    final Object value = entry.value;
    out.writeln(value is bool
        ? '  <${value ? 'true' : 'false'}/>'
        : '  <string>${_xml('$value')}</string>');
  }
  out
    ..writeln('</dict>')
    ..writeln('</plist>');
  return out.toString();
}

String _xml(String value) => value
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&apos;');
