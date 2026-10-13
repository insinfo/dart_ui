/// Native desktop packaging for dart_ui applications.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'macos_embedded_bundle.dart';
import 'pe_subsystem.dart';

export 'macos_embedded_bundle.dart'
    show MacosAppBackend, MacosEmbeddedToolchain;

enum DesktopHostPlatform { windows, linux, macos }

typedef DartExeCompiler = Future<void> Function(
  String entrypoint,
  String outputPath,
);

/// Runs a platform tool - `codesign`, `sips`, `iconutil`, `xcrun` - and
/// answers what it said. A seam so the bundle steps can be tested without
/// the tools, and so a test can see exactly which commands a build ran.
typedef ToolRunner = Future<ProcessResult> Function(
  String executable,
  List<String> arguments,
);

final class ApplicationBuildRequest {
  const ApplicationBuildRequest({
    required this.entrypoint,
    this.outputPath,
    this.appName,
    this.bundleIdentifier,
    this.version = '1.0.0',
    this.windowsConsole = false,
    this.embed = const <String>[],
    this.embedFrameworkFonts = true,
    this.iconPath,
    this.codesignIdentity = '-',
    this.hardenedRuntime = false,
    this.entitlementsPath,
    this.minimumSystemVersion = '11.0',
    this.infoPlist = const <String, String>{},
    this.notaryProfile,
    this.macosBackend = MacosAppBackend.nativeHost,
    this.macosEmbeddedToolchain,
  });

  final String entrypoint;
  final String? outputPath;
  final String? appName;
  final String? bundleIdentifier;
  final String version;

  /// Keeps the console subsystem on Windows for command-line diagnostics.
  final bool windowsConsole;

  /// Files and folders of the application compiled into the executable,
  /// read back with `EmbeddedAssets.bytes` under their path relative to the
  /// working directory (`assets/logo.png`).
  final List<String> embed;

  /// Whether dart_ui's own fonts - the interface face and the icon fonts -
  /// are compiled in, so nothing has to sit beside the executable.
  final bool embedFrameworkFonts;

  /// A square PNG - 1024 pixels is what the largest macOS size wants - made
  /// into the application's icon: an `.icns` in a macOS bundle, a PNG named
  /// by `Icon=` beside a Linux launcher. Windows' icon resource is not
  /// written yet.
  final String? iconPath;

  /// What `codesign -s` signs a macOS bundle with: a Developer ID identity
  /// for distribution, or `-` - the default - for an ad-hoc signature, which
  /// is enough to run on the machine that built it and to keep the bundle
  /// sealed. Null leaves the bundle unsigned.
  final String? codesignIdentity;

  /// Signs with the hardened runtime (`--options runtime`), which
  /// notarization requires.
  final bool hardenedRuntime;

  /// An entitlements plist for both executables in the bundle - the AppKit
  /// host is the one that touches the camera or the microphone.
  final String? entitlementsPath;

  /// `LSMinimumSystemVersion`.
  final String minimumSystemVersion;

  /// More string keys for `Info.plist`, such as the usage descriptions
  /// (`NSMicrophoneUsageDescription`) a permission prompt shows.
  final Map<String, String> infoPlist;

  /// A `notarytool` keychain profile (`xcrun notarytool store-credentials`):
  /// when set, the signed bundle is submitted, waited for and stapled.
  /// Needs a Developer ID identity and [hardenedRuntime].
  final String? notaryProfile;

  /// What a macOS bundle runs: the native AppKit host beside a
  /// `dart compile exe` program (the default), or the Dart runtime built
  /// with the main-thread patch as the executable, AppKit in its process
  /// (`macos_embedded_bundle.dart`).
  final MacosAppBackend macosBackend;

  /// The patched runtime, its `gen_snapshot` and a host `dart` of the same
  /// tag, for [MacosAppBackend.embedded]. Null reads them from the
  /// environment ([MacosEmbeddedToolchain.resolve]).
  final MacosEmbeddedToolchain? macosEmbeddedToolchain;
}

final class ApplicationBuildResult {
  const ApplicationBuildResult({
    required this.platform,
    required this.primaryArtifact,
    this.launcherArtifact,
  });

  final DesktopHostPlatform platform;
  final String primaryArtifact;
  final String? launcherArtifact;
}

final class ApplicationBuildException implements Exception {
  const ApplicationBuildException(this.message);

  final String message;

  @override
  String toString() => 'ApplicationBuildException: $message';
}

/// Compiles on the current host and creates its native GUI launch artifact.
///
/// `dart compile exe` does not cross-compile. A Windows artifact must be built
/// on Windows, a Linux artifact on Linux, and a macOS bundle on macOS.
final class DesktopApplicationBuilder {
  DesktopApplicationBuilder({
    DesktopHostPlatform? platform,
    DartExeCompiler? compiler,
    StringSink? output,
    String? Function()? macosHost,
    ToolRunner? tools,
  })  : platform = platform ?? _currentPlatform(),
        _tools = tools ?? _runTool,
        _compiler = compiler,
        _macosHost = macosHost ?? (() => null),
        _output = output ?? stdout;

  /// Where the compiled AppKit host is, for the bundle to carry it. Given
  /// by `bin/dart_ui.dart`: tooling imports no runtime layer, the backend
  /// that knows where the host lives included.
  final String? Function() _macosHost;
  final ToolRunner _tools;

  final DesktopHostPlatform platform;
  final DartExeCompiler? _compiler;
  final StringSink _output;

  Future<ApplicationBuildResult> build(
    ApplicationBuildRequest request,
  ) async {
    final File entrypoint = File(request.entrypoint);
    if (!entrypoint.existsSync()) {
      throw ApplicationBuildException(
        'entrypoint does not exist: ${request.entrypoint}',
      );
    }
    final String sourceName = _baseNameWithoutExtension(entrypoint.path);
    final String appName = _validatedAppName(request.appName ?? sourceName);
    final String executableName = _executableName(sourceName);
    _validateVersion(request.version);

    return switch (platform) {
      DesktopHostPlatform.windows => _buildWindows(
          request,
          executableName,
        ),
      DesktopHostPlatform.linux => _buildLinux(
          request,
          appName,
          executableName,
        ),
      DesktopHostPlatform.macos => _buildMacos(
          request,
          appName,
          executableName,
        ),
    };
  }

  // --- embedding ----------------------------------------------------------------

  /// The program to compile: [ApplicationBuildRequest.entrypoint] itself,
  /// or - when anything is embedded - a generated one that registers the
  /// embedded resources and then runs it.
  String _entrypointFor(ApplicationBuildRequest request) {
    final Map<String, File> files = <String, File>{};
    if (request.embedFrameworkFonts) {
      final Directory? fonts = _frameworkFonts();
      if (fonts == null) {
        throw const ApplicationBuildException(
            "dart_ui's fonts were not found to embed; pass --no-embed-fonts "
            'to build without them');
      }
      for (final FileSystemEntity entity in fonts.listSync()) {
        if (entity is! File) continue;
        final String name = entity.uri.pathSegments.last;
        // Roboto is a compatibility face nothing installs by default.
        if (name.startsWith('Roboto')) continue;
        if (name.endsWith('.ttf') || name.endsWith('.txt')) {
          files['dart_ui/fonts/$name'] = entity;
        }
      }
    }
    final String root = Directory.current.absolute.path;
    for (final String path in request.embed) {
      final FileSystemEntityType type = FileSystemEntity.typeSync(path);
      final Iterable<File> found = switch (type) {
        FileSystemEntityType.file => <File>[File(path)],
        FileSystemEntityType.directory =>
          Directory(path).listSync(recursive: true).whereType<File>(),
        _ => throw ApplicationBuildException('nothing to embed at $path'),
      };
      for (final File file in found) {
        files[_assetKey(file.absolute.path, root)] = file;
      }
    }
    if (files.isEmpty) return request.entrypoint;

    final String name = _baseNameWithoutExtension(request.entrypoint);
    final Directory work = Directory('.dart_tool/dart_ui_build/$name')
      ..createSync(recursive: true);
    final StringBuffer assets = StringBuffer()
      ..writeln('// GENERATED by `dart_ui build` - do not edit or commit.')
      ..writeln()
      ..writeln("import 'package:dart_ui/assets.dart';")
      ..writeln()
      ..writeln('const Map<String, String> _assets = <String, String>{');
    var bytes = 0;
    for (final String key in files.keys.toList()..sort()) {
      final List<int> data = files[key]!.readAsBytesSync();
      bytes += data.length;
      assets.writeln(
          "  '${key.replaceAll("'", r"\'")}': r'${base64Encode(data)}',");
    }
    assets
      ..writeln('};')
      ..writeln()
      ..writeln('void registerEmbeddedAssets() =>')
      ..writeln('    EmbeddedAssets.registerBase64(_assets);');
    File('${work.path}/assets.g.dart').writeAsStringSync(assets.toString());

    final File entry = File(request.entrypoint).absolute;
    final bool takesArguments =
        !RegExp(r'\bmain\s*\(\s*\)').hasMatch(entry.readAsStringSync());
    File('${work.path}/main.dart').writeAsStringSync(
      '// GENERATED by `dart_ui build` - do not edit or commit.\n\n'
      "import 'assets.g.dart';\n"
      "import '${entry.uri}' as app;\n\n"
      'Future<void> main(List<String> arguments) async {\n'
      '  registerEmbeddedAssets();\n'
      '  await Future<void>.sync(() => '
      '${takesArguments ? 'app.main(arguments)' : 'app.main()'});\n'
      '}\n',
    );
    _output.writeln('Embedded ${files.length} files '
        '(${(bytes / (1 << 20)).toStringAsFixed(1)} MB)');
    return '${work.path}/main.dart';
  }

  /// [path]'s key: relative to [root], with `/` separators.
  static String _assetKey(String path, String root) {
    final String relative =
        path.startsWith(root) ? path.substring(root.length + 1) : path;
    return relative.replaceAll(r'\', '/');
  }

  /// dart_ui's `assets/fonts`, from the running program's package config.
  static Directory? _frameworkFonts() {
    try {
      final Uri? library = Isolate.resolvePackageUriSync(
          Uri.parse('package:dart_ui/dart_ui.dart'));
      if (library == null || library.scheme != 'file') return null;
      final Directory fonts = Directory(
          '${File(library.toFilePath()).parent.parent.path}/assets/fonts');
      return fonts.existsSync() ? fonts : null;
    } on Object {
      return null;
    }
  }

  Future<ApplicationBuildResult> _buildWindows(
    ApplicationBuildRequest request,
    String executableName,
  ) async {
    var outputPath = request.outputPath ?? 'build/$executableName.exe';
    if (!outputPath.toLowerCase().endsWith('.exe')) {
      outputPath = '$outputPath.exe';
    }
    await _compile(_entrypointFor(request), outputPath);
    if (!request.windowsConsole) {
      PeSubsystemEditor.setSubsystem(outputPath, PeSubsystem.windowsGui);
      _output.writeln('PE subsystem: Windows GUI (console disabled)');
    }
    return ApplicationBuildResult(
      platform: platform,
      primaryArtifact: File(outputPath).absolute.path,
    );
  }

  Future<ApplicationBuildResult> _buildLinux(
    ApplicationBuildRequest request,
    String appName,
    String executableName,
  ) async {
    final String outputPath = request.outputPath ?? 'build/$executableName';
    await _compile(_entrypointFor(request), outputPath);

    final String absoluteExecutable = File(outputPath).absolute.path;
    String? iconLine;
    if (request.iconPath case final String icon) {
      if (!File(icon).existsSync()) {
        throw ApplicationBuildException('icon does not exist: $icon');
      }
      final String target = '$outputPath.png';
      File(icon).copySync(target);
      iconLine = 'Icon=${_desktopString(File(target).absolute.path)}\n';
    }
    final String desktopPath = '$outputPath.desktop';
    final File desktopFile = File(desktopPath);
    desktopFile.parent.createSync(recursive: true);
    desktopFile.writeAsStringSync(
      '[Desktop Entry]\n'
      'Version=1.5\n'
      'Type=Application\n'
      'Name=${_desktopString(appName)}\n'
      'Exec=${_desktopExec(absoluteExecutable)}\n'
      'Terminal=false\n'
      '${iconLine ?? ''}'
      'StartupNotify=true\n'
      'Categories=Utility;\n',
      flush: true,
    );
    _output.writeln('Desktop entry: ${desktopFile.absolute.path}');
    return ApplicationBuildResult(
      platform: platform,
      primaryArtifact: absoluteExecutable,
      launcherArtifact: desktopFile.absolute.path,
    );
  }

  Future<ApplicationBuildResult> _buildMacos(
    ApplicationBuildRequest request,
    String appName,
    String executableName,
  ) async {
    if (request.macosBackend == MacosAppBackend.embedded) {
      return _buildMacosEmbedded(request, appName, executableName);
    }
    final String identifier = request.bundleIdentifier ??
        'dev.dartui.${_bundleIdentifierPart(executableName)}';
    _validateBundleIdentifier(identifier);
    var bundlePath = request.outputPath ?? 'build/$executableName.app';
    if (!bundlePath.toLowerCase().endsWith('.app')) {
      bundlePath = '$bundlePath.app';
    }
    final Directory macosDirectory = Directory('$bundlePath/Contents/MacOS');
    final Directory resourcesDirectory =
        Directory('$bundlePath/Contents/Resources');
    macosDirectory.createSync(recursive: true);
    resourcesDirectory.createSync(recursive: true);
    final String executablePath = '${macosDirectory.path}/$executableName';
    await _compile(_entrypointFor(request), executablePath);

    // The AppKit host is an executable of its own (ADR 0001); the runtime
    // looks for it beside the program first, so inside Contents/MacOS the
    // bundle carries everything it needs.
    final String? host = _macosHost();
    if (host == null) {
      _output.writeln('warning: the macOS host is not built, so the bundle '
          'will not open on its own; run '
          'lib/src/backends/macos/native/build_host.sh and build again');
    } else {
      final String name = File(host).uri.pathSegments.last;
      final String target = '${macosDirectory.path}/$name';
      File(host).copySync(target);
      if (!Platform.isWindows) {
        await Process.run('chmod', <String>['+x', target]);
      }
      _output.writeln('macOS host: $name');
    }

    String? iconFile;
    if (request.iconPath case final String icon) {
      iconFile = await _macosIcon(icon, resourcesDirectory.path);
    }

    final File plist = File('$bundlePath/Contents/Info.plist');
    plist.writeAsStringSync(
      '<?xml version="1.0" encoding="UTF-8"?>\n'
      '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" '
      '"http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
      '<plist version="1.0">\n'
      '<dict>\n'
      '  <key>CFBundleDevelopmentRegion</key>\n'
      '  <string>en</string>\n'
      '  <key>CFBundleDisplayName</key>\n'
      '  <string>${_xml(appName)}</string>\n'
      '  <key>CFBundleExecutable</key>\n'
      '  <string>${_xml(executableName)}</string>\n'
      '  <key>CFBundleIdentifier</key>\n'
      '  <string>${_xml(identifier)}</string>\n'
      '  <key>CFBundleInfoDictionaryVersion</key>\n'
      '  <string>6.0</string>\n'
      '  <key>CFBundleName</key>\n'
      '  <string>${_xml(appName)}</string>\n'
      '  <key>CFBundlePackageType</key>\n'
      '  <string>APPL</string>\n'
      '  <key>CFBundleShortVersionString</key>\n'
      '  <string>${_xml(request.version)}</string>\n'
      '  <key>CFBundleVersion</key>\n'
      '  <string>${_xml(request.version)}</string>\n'
      '${iconFile == null ? '' : '  <key>CFBundleIconFile</key>\n'
          '  <string>${_xml(iconFile)}</string>\n'}'
      // Two processes run from this bundle: the Dart program, which
      // LaunchServices starts, and the AppKit host it spawns. Both would
      // get a Dock icon. LSUIElement keeps the program - which never draws -
      // out of the Dock, and the host promotes itself back to a regular
      // application with setActivationPolicy, so the app shows exactly once.
      '  <key>LSUIElement</key>\n'
      '  <true/>\n'
      '  <key>LSMinimumSystemVersion</key>\n'
      '  <string>${_xml(request.minimumSystemVersion)}</string>\n'
      '  <key>NSHighResolutionCapable</key>\n'
      '  <true/>\n'
      '${<String>[
        for (final MapEntry<String, String> entry in request.infoPlist.entries)
          '  <key>${_xml(entry.key)}</key>\n'
              '  <string>${_xml(entry.value)}</string>\n',
      ].join()}'
      '</dict>\n'
      '</plist>\n',
      flush: true,
    );
    if (request.codesignIdentity case final String identity) {
      await _codesign(request, identity, bundlePath, <String>[
        if (host != null)
          '${macosDirectory.path}/${File(host).uri.pathSegments.last}',
      ]);
      if (request.notaryProfile case final String profile) {
        await _notarize(bundlePath, profile);
      }
    } else if (request.notaryProfile != null) {
      throw const ApplicationBuildException(
          'notarization needs a signed bundle; pass --sign with a Developer '
          'ID identity');
    }
    _output
        .writeln('Application bundle: ${Directory(bundlePath).absolute.path}');
    return ApplicationBuildResult(
      platform: platform,
      primaryArtifact: Directory(bundlePath).absolute.path,
    );
  }

  /// The `appkitEmbedded` bundle: kernel by the host SDK's `gen_kernel_aot`,
  /// Mach-O snapshot by the patched build's `gen_snapshot`, the runtime as
  /// the executable. See `macos_embedded_bundle.dart` for the layout.
  Future<ApplicationBuildResult> _buildMacosEmbedded(
    ApplicationBuildRequest request,
    String appName,
    String executableName,
  ) async {
    final String identifier = request.bundleIdentifier ??
        'dev.dartui.${_bundleIdentifierPart(executableName)}';
    _validateBundleIdentifier(identifier);
    var bundlePath = request.outputPath ?? 'build/$executableName.app';
    if (!bundlePath.toLowerCase().endsWith('.app')) {
      bundlePath = '$bundlePath.app';
    }
    final MacosEmbeddedToolchain? toolchain = request.macosEmbeddedToolchain ??
        MacosEmbeddedToolchain.resolve(Platform.environment);
    if (toolchain == null) {
      throw const ApplicationBuildException(
          'the embedded macOS backend needs the Dart runtime built with the '
          'main-thread patch: set DART_UI_DART_SDK_SRC to the Dart SDK '
          'checkout (tool/mobile/build_dart_runtime.dart --target '
          'macos-arm64), or use tool/macos/build_app.dart, which builds it');
    }
    final List<String> missing = toolchain.missing();
    if (missing.isNotEmpty) {
      throw ApplicationBuildException(
          'the embedded macOS toolchain is incomplete:\n  '
          '${missing.join('\n  ')}');
    }
    final String entrypoint = _entrypointFor(request);
    final String? packages = findPackageConfig(request.entrypoint);
    if (packages == null) {
      throw ApplicationBuildException(
          'no .dart_tool/package_config.json above ${request.entrypoint}; '
          'run dart pub get in its package');
    }
    final Directory work = Directory('$bundlePath.work');
    if (work.existsSync()) work.deleteSync(recursive: true);
    work.createSync(recursive: true);
    final String kernel = '${work.path}/app.dill';
    final String snapshot = '${work.path}/App';
    _output.writeln('Compiling $entrypoint (AOT, Dart $macosEmbeddedSdkTag)');
    await _tool(
        toolchain.kernelRuntime,
        toolchain.kernelArguments(
            entrypoint: entrypoint, packages: packages, output: kernel));
    await _tool(toolchain.genSnapshot,
        toolchain.snapshotArguments(kernel: kernel, output: snapshot));

    final MacosEmbeddedBundleLayout layout =
        MacosEmbeddedBundleLayout(bundlePath, executableName)..create();
    File(toolchain.runtime).copySync(layout.executable);
    await _tool('chmod', <String>['755', layout.executable]);
    File(snapshot).copySync(layout.snapshot);
    File(layout.frameworkInfoPlist).writeAsStringSync(
        macosEmbeddedFrameworkInfoPlist(
            identifier: identifier,
            version: request.version,
            minimumSystemVersion: request.minimumSystemVersion));
    String? iconFile;
    if (request.iconPath case final String icon) {
      iconFile = await _macosIcon(icon, layout.resources);
    }
    File(layout.infoPlist).writeAsStringSync(
      macosEmbeddedInfoPlist(
        appName: appName,
        executableName: executableName,
        identifier: identifier,
        version: request.version,
        minimumSystemVersion: request.minimumSystemVersion,
        iconFile: iconFile,
        extra: request.infoPlist,
      ),
      flush: true,
    );
    work.deleteSync(recursive: true);
    if (request.codesignIdentity case final String identity) {
      await _codesign(request, identity, bundlePath, <String>[
        layout.framework,
      ]);
      if (request.notaryProfile case final String profile) {
        await _notarize(bundlePath, profile);
      }
    } else if (request.notaryProfile != null) {
      throw const ApplicationBuildException(
          'notarization needs a signed bundle; pass --sign with a Developer '
          'ID identity');
    }
    _output.writeln('Application bundle (embedded runtime): '
        '${Directory(bundlePath).absolute.path}');
    return ApplicationBuildResult(
      platform: platform,
      primaryArtifact: Directory(bundlePath).absolute.path,
    );
  }

  /// [png] as `AppIcon.icns` in [resources]: every size an iconset holds,
  /// scaled by `sips`, packed by `iconutil`. Returns the file's name.
  Future<String> _macosIcon(String png, String resources) async {
    if (!File(png).existsSync()) {
      throw ApplicationBuildException('icon does not exist: $png');
    }
    final Directory iconset =
        Directory('${Directory.systemTemp.path}/dart_ui_icon_$pid.iconset');
    if (iconset.existsSync()) iconset.deleteSync(recursive: true);
    iconset.createSync(recursive: true);
    try {
      for (final (String name, int pixels) in macosIconsetSizes) {
        await _tool('sips', <String>[
          '-z',
          '$pixels',
          '$pixels',
          png,
          '--out',
          '${iconset.path}/$name',
        ]);
      }
      await _tool('iconutil', <String>[
        '-c',
        'icns',
        iconset.path,
        '-o',
        '$resources/AppIcon.icns',
      ]);
    } finally {
      if (iconset.existsSync()) iconset.deleteSync(recursive: true);
    }
    _output.writeln('Icon: AppIcon.icns');
    return 'AppIcon';
  }

  /// Signs [nested] executables, then the bundle - inside out, which is the
  /// order `codesign` requires, since sealing the bundle hashes what is in
  /// it - and verifies the result strictly.
  Future<void> _codesign(
    ApplicationBuildRequest request,
    String identity,
    String bundlePath,
    List<String> nested,
  ) async {
    final List<String> options = <String>[
      '--force',
      '--sign',
      identity,
      // A secure timestamp needs Apple's server, and an ad-hoc signature
      // cannot carry one.
      if (identity != '-') '--timestamp',
      if (request.hardenedRuntime) ...<String>['--options', 'runtime'],
      if (request.entitlementsPath case final String entitlements) ...<String>[
        '--entitlements',
        entitlements
      ],
    ];
    for (final String path in nested) {
      await _tool('codesign', <String>[...options, path]);
    }
    await _tool('codesign', <String>[...options, bundlePath]);
    await _tool('codesign',
        <String>['--verify', '--deep', '--strict', '--verbose=2', bundlePath]);
    _output.writeln(identity == '-'
        ? 'Signed ad hoc (runs on this machine; distribute with a '
            'Developer ID identity)'
        : 'Signed: $identity');
  }

  /// Submits the bundle to Apple's notary service, waits, and staples the
  /// ticket so Gatekeeper accepts it offline.
  Future<void> _notarize(String bundlePath, String profile) async {
    final String zip = '$bundlePath.zip';
    await _tool('ditto', <String>['-c', '-k', '--keepParent', bundlePath, zip]);
    try {
      await _tool('xcrun', <String>[
        'notarytool',
        'submit',
        zip,
        '--keychain-profile',
        profile,
        '--wait',
      ]);
    } finally {
      final File archive = File(zip);
      if (archive.existsSync()) archive.deleteSync();
    }
    await _tool('xcrun', <String>['stapler', 'staple', bundlePath]);
    _output.writeln('Notarized and stapled');
  }

  Future<ProcessResult> _tool(String executable, List<String> arguments) async {
    final ProcessResult result = await _tools(executable, arguments);
    if (result.exitCode != 0) {
      throw ApplicationBuildException(
        '$executable ${arguments.join(' ')} failed with exit code '
        '${result.exitCode}:\n${result.stderr}${result.stdout}',
      );
    }
    return result;
  }

  Future<void> _compile(String entrypoint, String outputPath) async {
    final File outputFile = File(outputPath);
    outputFile.parent.createSync(recursive: true);
    _output.writeln('Compiling $entrypoint -> ${outputFile.path}');
    final DartExeCompiler? compiler = _compiler;
    if (compiler != null) {
      await compiler(entrypoint, outputPath);
      return;
    }
    final ProcessResult result = await Process.run(
      'dart',
      <String>['compile', 'exe', entrypoint, '-o', outputPath],
      runInShell: Platform.isWindows,
    );
    if (result.stdout case final String text when text.isNotEmpty) {
      _output.write(text);
    }
    if (result.exitCode != 0) {
      throw ApplicationBuildException(
        'dart compile exe failed with exit code ${result.exitCode}:\n'
        '${result.stderr}',
      );
    }
  }
}

/// The files of a macOS iconset and their pixel sizes: each point size at
/// 1x and 2x, which is what `iconutil` expects to find.
const List<(String, int)> macosIconsetSizes = <(String, int)>[
  ('icon_16x16.png', 16),
  ('icon_16x16@2x.png', 32),
  ('icon_32x32.png', 32),
  ('icon_32x32@2x.png', 64),
  ('icon_128x128.png', 128),
  ('icon_128x128@2x.png', 256),
  ('icon_256x256.png', 256),
  ('icon_256x256@2x.png', 512),
  ('icon_512x512.png', 512),
  ('icon_512x512@2x.png', 1024),
];

Future<ProcessResult> _runTool(String executable, List<String> arguments) =>
    Process.run(executable, arguments);

DesktopHostPlatform _currentPlatform() {
  if (Platform.isWindows) return DesktopHostPlatform.windows;
  if (Platform.isLinux) return DesktopHostPlatform.linux;
  if (Platform.isMacOS) return DesktopHostPlatform.macos;
  throw ApplicationBuildException(
    'desktop application builds are supported on Windows, Linux and macOS; '
    'current host: ${Platform.operatingSystem}',
  );
}

String _baseNameWithoutExtension(String path) {
  final String name = File(path).uri.pathSegments.last;
  final int dot = name.lastIndexOf('.');
  return dot <= 0 ? name : name.substring(0, dot);
}

String _validatedAppName(String name) {
  final String trimmed = name.trim();
  if (trimmed.isEmpty || trimmed.contains(RegExp(r'[\r\n\u0000]'))) {
    throw const ApplicationBuildException(
      'application name must be non-empty and single-line',
    );
  }
  return trimmed;
}

String _executableName(String source) {
  final String safe = source.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
  if (safe.isEmpty || safe == '.' || safe == '..') return 'dart_ui_app';
  return safe;
}

String _bundleIdentifierPart(String value) => value
    .toLowerCase()
    .replaceAll('_', '-')
    .replaceAll(RegExp(r'[^a-z0-9-]'), '-');

void _validateBundleIdentifier(String identifier) {
  if (!RegExp(r'^[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+$').hasMatch(identifier)) {
    throw ApplicationBuildException(
      'invalid bundle identifier "$identifier"; use reverse-DNS form, for '
      'example com.example.my-app',
    );
  }
}

void _validateVersion(String version) {
  if (!RegExp(r'^\d+(?:\.\d+){0,2}$').hasMatch(version)) {
    throw ApplicationBuildException(
      'invalid version "$version"; expected one to three numeric components',
    );
  }
}

String _desktopString(String value) => value
    .replaceAll(r'\', r'\\')
    .replaceAll('\n', r'\n')
    .replaceAll('\r', r'\r')
    .replaceAll('\t', r'\t');

String _desktopExec(String path) {
  final String escaped = path
      .replaceAll(r'\', r'\\')
      .replaceAll('`', r'\`')
      .replaceAll(r'$', r'\$')
      .replaceAll('%', '%%')
      .replaceAll('"', r'\"');
  return '"$escaped"';
}

String _xml(String value) => value
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&apos;');
