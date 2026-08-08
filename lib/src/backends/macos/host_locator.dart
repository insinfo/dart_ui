/// Finding the native AppKit host at runtime.
///
/// ADR 0001 makes the host a *separate executable*, which means this backend
/// has a dependency that `pub get` cannot satisfy. Baking an absolute path
/// would work on exactly one machine, so the location is resolved in a fixed
/// order and every step of that search is reportable - a probe that says
/// "host not found" without saying where it looked is the same unhelpful bool
/// `diagnostics.dart` was written to abolish.
///
/// Resolution order, first hit wins:
///
///   1. [MacosHostLocator.resolve]'s `explicitPath` - what the embedder passed
///      in `MacosBackendOptions.hostBinaryPath`. An application that ships the
///      host inside its bundle knows the path and should not be searched for.
///   2. `DART_UI_MACOS_HOST` - absolute path to the compiled binary. This is
///      the CI knob and the one to set when debugging a locally built host.
///   3. `DART_UI_MACOS_HOST_DIR` - a directory containing [hostBinaryName].
///   4. The directory of the running executable. Covers `dart compile exe`
///      output shipped next to its host.
///   5. `<package root>/lib/src/backends/macos/native/build/<binary>`, where
///      the package root comes from `.dart_tool/package_config.json`. This is
///      the development path: `native/build_host.sh` puts the binary exactly
///      there.
///   6. Any directory on `PATH`.
///
/// The `.m` source is located the same way (`DART_UI_MACOS_HOST_SOURCE`, then
/// the package root) so that a missing binary can be reported together with
/// the exact `clang` line that would produce it.
library;

import 'dart:convert';
import 'dart:io';

import '../../foundation/diagnostics.dart';

/// Name of the compiled host executable. Also the basename `build_host.sh`
/// writes, and changing one without the other is the obvious way to break
/// step 5 above.
const String hostBinaryName = 'dart_ui_macos_host';

/// Name of the Objective-C source shipped with the package.
const String hostSourceName = 'dart_ui_macos_host.m';

/// Path of the source relative to the package root.
const String hostSourceRelativePath =
    'lib/src/backends/macos/native/$hostSourceName';

/// Where [hostSourceRelativePath]'s build step is expected to put its output.
const String hostBinaryRelativePath =
    'lib/src/backends/macos/native/build/$hostBinaryName';

/// Environment variable holding an absolute path to the compiled host.
const String hostBinaryEnvironmentVariable = 'DART_UI_MACOS_HOST';

/// Environment variable holding a directory that contains the compiled host.
const String hostDirectoryEnvironmentVariable = 'DART_UI_MACOS_HOST_DIR';

/// Environment variable holding an absolute path to the `.m` source.
const String hostSourceEnvironmentVariable = 'DART_UI_MACOS_HOST_SOURCE';

/// How a host binary was found, or why it was not.
final class MacosHostLocation {
  const MacosHostLocation({
    required this.binaryPath,
    required this.sourcePath,
    required this.origin,
    required this.searched,
    required this.diagnostics,
  });

  /// Absolute path of an existing, executable file, or null.
  final String? binaryPath;

  /// Absolute path of the `.m`, when it could be found. Useful even when
  /// [binaryPath] is null: it is what the operator has to compile.
  final String? sourcePath;

  /// Which rule in the resolution order produced [binaryPath].
  final String? origin;

  /// Every candidate that was tried, in order. This is the part that makes a
  /// failure actionable.
  final List<String> searched;

  final List<BackendDiagnostic> diagnostics;

  bool get found => binaryPath != null;

  /// The command that would produce the binary, for a diagnostic's detail.
  ///
  /// `-fobjc-arc` and the three frameworks are exactly what the measured CI
  /// build uses; a host compiled without ARC leaks every `NSString` it parses.
  String buildCommandHint() {
    final source = sourcePath ?? '<$hostSourceRelativePath>';
    return 'clang -fobjc-arc -Wall -Wextra '
        '-framework Cocoa -framework IOSurface -framework QuartzCore '
        '"$source" -o "<output>/$hostBinaryName"';
  }
}

/// Resolves the host executable without ever hard-coding a path.
final class MacosHostLocator {
  const MacosHostLocator._();

  /// Runs the search described in the library documentation.
  ///
  /// Synchronous because `WindowingBackend.probe()` is, and because every step
  /// is a `stat`: the whole search costs less than the process spawn it
  /// precedes.
  static MacosHostLocation resolve({
    String? explicitPath,
    Map<String, String>? environment,
  }) {
    final env = environment ?? Platform.environment;
    final searched = <String>[];
    final diagnostics = <BackendDiagnostic>[];
    final source = _resolveSource(env, searched);

    String? accepted;
    String? origin;

    void consider(String? candidate, String label) {
      if (accepted != null || candidate == null || candidate.isEmpty) return;
      final path = _absolute(candidate);
      searched.add('$label: $path');
      final status = _statusOf(path);
      if (status == _CandidateStatus.executable) {
        accepted = path;
        origin = label;
        return;
      }
      // A path that exists but cannot be executed is a different problem from
      // one that is absent, and the fix differs too (chmod versus build).
      if (status == _CandidateStatus.notExecutable) {
        diagnostics.add(
          BackendDiagnostic(
            kind: DiagnosticKind.permissionDenied,
            message: 'macOS host is present but not executable',
            detail: '$label: $path',
          ),
        );
      }
    }

    consider(explicitPath, 'option hostBinaryPath');
    consider(env[hostBinaryEnvironmentVariable], hostBinaryEnvironmentVariable);
    final directory = env[hostDirectoryEnvironmentVariable];
    if (directory != null && directory.isNotEmpty) {
      consider(
        _join(directory, hostBinaryName),
        hostDirectoryEnvironmentVariable,
      );
    }
    consider(
      _join(_dirname(Platform.resolvedExecutable), hostBinaryName),
      'next to the running executable',
    );
    final packageRoot = _packageRoot();
    if (packageRoot != null) {
      consider(
        _join(packageRoot, hostBinaryRelativePath),
        'package build directory',
      );
    }
    if (accepted == null) {
      for (final entry in _pathEntries(env)) {
        consider(_join(entry, hostBinaryName), 'PATH');
        if (accepted != null) break;
      }
    }

    if (accepted == null) {
      diagnostics.add(
        BackendDiagnostic(
          kind: DiagnosticKind.missingLibrary,
          message: 'macOS AppKit host binary not found: $hostBinaryName',
          detail: 'searched ${searched.length} location(s); build it with '
              '${MacosHostLocation(
            binaryPath: null,
            sourcePath: source,
            origin: null,
            searched: const <String>[],
            diagnostics: const <BackendDiagnostic>[],
          ).buildCommandHint()}',
        ),
      );
    }

    return MacosHostLocation(
      binaryPath: accepted,
      sourcePath: source,
      origin: origin,
      searched: searched,
      diagnostics: diagnostics,
    );
  }

  static String? _resolveSource(
      Map<String, String> env, List<String> searched) {
    final explicit = env[hostSourceEnvironmentVariable];
    if (explicit != null && explicit.isNotEmpty) {
      final path = _absolute(explicit);
      searched.add('$hostSourceEnvironmentVariable: $path');
      if (File(path).existsSync()) return path;
    }
    final root = _packageRoot();
    if (root == null) return null;
    final path = _join(root, hostSourceRelativePath);
    searched.add('package source: $path');
    return File(path).existsSync() ? path : null;
  }

  /// The root of this package, from `.dart_tool/package_config.json`.
  ///
  /// Read rather than resolved through `Isolate.resolvePackageUri` because
  /// that is asynchronous and `probe()` is not. Falls back to walking up from
  /// the current directory looking for the source itself, which is what covers
  /// running a compiled binary from inside a checkout - there is no
  /// `package_config.json` in that case, but the tree is still there.
  static String? _packageRoot() {
    final configured = _packageRootFromConfig();
    if (configured != null) return configured;

    var directory = Directory.current.absolute.path;
    for (var depth = 0; depth < 8; depth++) {
      if (File(_join(directory, hostSourceRelativePath)).existsSync()) {
        return directory;
      }
      final parent = _dirname(directory);
      if (parent == directory) break;
      directory = parent;
    }
    return null;
  }

  static String? _packageRootFromConfig() {
    var directory = Directory.current.absolute.path;
    for (var depth = 0; depth < 8; depth++) {
      final config = File(_join(directory, '.dart_tool/package_config.json'));
      if (config.existsSync()) {
        final root = _readPackageRoot(config);
        if (root != null) return root;
      }
      final parent = _dirname(directory);
      if (parent == directory) break;
      directory = parent;
    }
    return null;
  }

  static String? _readPackageRoot(File config) {
    try {
      final decoded = jsonDecode(config.readAsStringSync());
      if (decoded is! Map<String, dynamic>) return null;
      final packages = decoded['packages'];
      if (packages is! List) return null;
      for (final package in packages) {
        if (package is! Map<String, dynamic>) continue;
        if (package['name'] != 'dart_ui') continue;
        final rootUri = package['rootUri'];
        if (rootUri is! String) return null;
        // rootUri is relative to the .dart_tool directory the file lives in,
        // which is the one rule about this format that is easy to get wrong.
        final base = Uri.directory(_dirname(config.absolute.path));
        final resolved = base.resolve(rootUri);
        if (!resolved.isScheme('file')) return null;
        return _stripTrailingSeparator(resolved.toFilePath());
      }
    } on Object {
      // A malformed package_config is not this backend's problem to report;
      // the next resolution step still has a chance.
      return null;
    }
    return null;
  }

  static Iterable<String> _pathEntries(Map<String, String> env) {
    final path = env['PATH'];
    if (path == null || path.isEmpty) return const <String>[];
    return path
        .split(Platform.isWindows ? ';' : ':')
        .where((e) => e.isNotEmpty);
  }

  static _CandidateStatus _statusOf(String path) {
    final stat = FileStat.statSync(path);
    if (stat.type != FileSystemEntityType.file) {
      return _CandidateStatus.absent;
    }
    // Any of the three execute bits: the host is normally 0755, but a binary
    // restored from an archive can land 0644 and that failure should name
    // itself rather than surface as errno 13 from Process.start.
    return (stat.mode & 0x49) != 0
        ? _CandidateStatus.executable
        : _CandidateStatus.notExecutable;
  }

  static String _absolute(String path) {
    if (path.startsWith('/')) return path;
    if (Platform.isWindows && path.length > 2 && path[1] == ':') return path;
    return _join(Directory.current.absolute.path, path);
  }

  static String _join(String directory, String name) {
    final base = _stripTrailingSeparator(directory);
    return '$base${Platform.pathSeparator}$name';
  }

  static String _dirname(String path) {
    final stripped = _stripTrailingSeparator(path);
    var cut = -1;
    for (var index = stripped.length - 1; index >= 0; index--) {
      final char = stripped[index];
      if (char == '/' || char == r'\') {
        cut = index;
        break;
      }
    }
    if (cut <= 0) return stripped.isEmpty ? path : stripped;
    return stripped.substring(0, cut);
  }

  static String _stripTrailingSeparator(String path) {
    var end = path.length;
    while (end > 1 && (path[end - 1] == '/' || path[end - 1] == r'\')) {
      end--;
    }
    return path.substring(0, end);
  }
}

enum _CandidateStatus { absent, notExecutable, executable }
