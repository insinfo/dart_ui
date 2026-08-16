/// Native desktop packaging for dart_ui applications.
library;

import 'dart:io';

import 'pe_subsystem.dart';

enum DesktopHostPlatform { windows, linux, macos }

typedef DartExeCompiler = Future<void> Function(
  String entrypoint,
  String outputPath,
);

final class ApplicationBuildRequest {
  const ApplicationBuildRequest({
    required this.entrypoint,
    this.outputPath,
    this.appName,
    this.bundleIdentifier,
    this.version = '1.0.0',
    this.windowsConsole = false,
  });

  final String entrypoint;
  final String? outputPath;
  final String? appName;
  final String? bundleIdentifier;
  final String version;

  /// Keeps the console subsystem on Windows for command-line diagnostics.
  final bool windowsConsole;
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
  })  : platform = platform ?? _currentPlatform(),
        _compiler = compiler,
        _output = output ?? stdout;

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

  Future<ApplicationBuildResult> _buildWindows(
    ApplicationBuildRequest request,
    String executableName,
  ) async {
    var outputPath = request.outputPath ?? 'build/$executableName.exe';
    if (!outputPath.toLowerCase().endsWith('.exe')) {
      outputPath = '$outputPath.exe';
    }
    await _compile(request.entrypoint, outputPath);
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
    await _compile(request.entrypoint, outputPath);

    final String absoluteExecutable = File(outputPath).absolute.path;
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
    await _compile(request.entrypoint, executablePath);

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
      '  <key>NSHighResolutionCapable</key>\n'
      '  <true/>\n'
      '</dict>\n'
      '</plist>\n',
      flush: true,
    );
    _output
        .writeln('Application bundle: ${Directory(bundlePath).absolute.path}');
    return ApplicationBuildResult(
      platform: platform,
      primaryArtifact: Directory(bundlePath).absolute.path,
    );
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
