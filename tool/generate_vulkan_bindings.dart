// ignore_for_file: avoid_print

/// Generates `lib/src/rendering/gpu/vulkan/vulkan_ffi.g.dart` with `ffigen`,
/// from the official Khronos headers at a pinned commit.
///
/// Section 2.1 of the roadmap authorises `ffigen` and section 11.4 says what a
/// binding package has to carry: a generator config, the header version, a
/// reproducible script, the list of manual overrides, and symbol, size, offset
/// and call tests. This file is the third of those, and it exists because the
/// other two are worthless without it - a config nobody can run and a version
/// number nobody can check against are decoration.
///
/// ## Why the headers are downloaded rather than committed
///
/// `Vulkan-Headers` is about eight megabytes and none of it is this project's
/// code. What matters is not having the bytes in the tree, it is being able to
/// get *exactly the same bytes* again, which [kHeadersCommit] fixes: a commit
/// hash is a stronger pin than a version string, because a tag can move.
///
/// The checkout lands in `.dart_tool/`, which is already in `.gitignore`.
///
/// ## Why the generated file is committed
///
/// Because CI has no `libclang` and neither does most of the world. The same
/// argument the Unicode tables make: the generator is how the file is
/// *derived*, not how it is *built*. `--verify-existing` is what keeps the two
/// honest - it regenerates into a temporary file and compares, so a hand-edit
/// of the generated file fails the gate instead of quietly becoming the truth.
///
/// ## Usage
///
/// ```
/// dart run tool/generate_vulkan_bindings.dart
/// dart run tool/generate_vulkan_bindings.dart --verify-existing
/// dart run tool/generate_vulkan_bindings.dart --llvm 'D:\LLVM'
/// ```
///
/// `ffigen` is not a dependency of `pubspec.yaml` - it is a build-time tool,
/// not a runtime one, and this package's whole point is that it has no runtime
/// dependency beyond `meta`. Install it once with
/// `dart pub global activate ffigen`; this script runs it with
/// `dart pub global run`.
library;

import 'dart:io';

/// The `Vulkan-Headers` commit these bindings were generated from.
///
/// Pinned as a hash and not as a tag. `v1.4.360` is what that commit is called
/// today, and a tag is a mutable reference: the guarantee this file needs is
/// "the same bytes", which only the hash gives.
const String kHeadersCommit = '0b7f383797fa7be53ae28213e001ae60668ee511';

/// The human-readable name of [kHeadersCommit], for the file header.
const String kHeadersVersion = 'v1.4.360';

/// `VK_HEADER_VERSION` as that commit's `vulkan_core.h` defines it.
///
/// Checked against the checked-out file before anything is generated, so a
/// commit hash that has been edited to point somewhere else fails here rather
/// than producing bindings labelled with a version they do not match.
const int kVkHeaderVersion = 360;

const String kRepository = 'https://github.com/KhronosGroup/Vulkan-Headers.git';

const String kOutputPath = 'lib/src/rendering/gpu/vulkan/vulkan_ffi.g.dart';

const String kConfigTemplatePath = 'tool/ffigen_vulkan.yaml';

const String kCheckoutDirectory = '.dart_tool/vulkan_headers';

Future<void> main(List<String> arguments) async {
  final _Options options;
  try {
    options = _Options.parse(arguments);
  } on FormatException catch (error) {
    stderr.writeln(error.message);
    stderr.writeln('usage: dart run tool/generate_vulkan_bindings.dart '
        '[--verify-existing] [--llvm <directory>]');
    exitCode = 2;
    return;
  }

  final String llvm = options.llvm ?? _findLlvm() ?? '';
  if (llvm.isEmpty) {
    stderr.writeln(
      'no libclang: ffigen needs an LLVM installation and none was found.\n'
      'Set DART_UI_LLVM_PATH, or pass --llvm <directory>, where the directory '
      'is the one containing bin/libclang.dll (Windows), lib/libclang.so '
      '(Linux) or lib/libclang.dylib (macOS).\n'
      'Searched: ${_llvmCandidates().join(', ')}',
    );
    exitCode = 1;
    return;
  }

  final Directory checkout = Directory(kCheckoutDirectory);
  await _fetchHeaders(checkout);
  final String include = '${checkout.absolute.path}${Platform.pathSeparator}'
      'include';
  _assertHeaderVersion(include);

  final File output = File(options.verifyExisting
      ? '${Directory.systemTemp.path}${Platform.pathSeparator}'
          'vulkan_ffi.verify.dart'
      : kOutputPath);

  final File config = File('${Directory.systemTemp.path}'
      '${Platform.pathSeparator}ffigen_vulkan.resolved.yaml');
  config.writeAsStringSync(File(kConfigTemplatePath)
      .readAsStringSync()
      .replaceAll('@OUTPUT@', _yamlPath(output.absolute.path))
      .replaceAll('@LLVM@', _yamlPath(llvm))
      .replaceAll('@HEADERS@', _yamlPath(include)));

  print('ffigen: $kHeadersVersion (VK_HEADER_VERSION $kVkHeaderVersion) '
      '-> ${output.path}');
  final ProcessResult run = Process.runSync(
    Platform.resolvedExecutable,
    <String>['pub', 'global', 'run', 'ffigen', '--config', config.path],
    stdoutEncoding: systemEncoding,
    stderrEncoding: systemEncoding,
  );
  if (run.exitCode != 0) {
    stderr
      ..writeln(run.stdout)
      ..writeln(run.stderr);
    stderr.writeln('ffigen failed. If it printed "Input Headers: []" and '
        'produced an empty file, the paths in the resolved config were not '
        'absolute Windows paths; see ${config.path}');
    exitCode = 1;
    return;
  }
  if (!output.existsSync() || output.lengthSync() < 1024) {
    stderr.writeln('ffigen reported success and produced no bindings; the '
        'resolved config is at ${config.path}');
    exitCode = 1;
    return;
  }

  _rewriteHeader(output);
  _format(output);

  if (!options.verifyExisting) {
    print('wrote ${output.path} '
        '(${output.readAsLinesSync().length} lines)');
    return;
  }

  final File committed = File(kOutputPath);
  if (!committed.existsSync()) {
    stderr.writeln('${committed.path} does not exist; run without '
        '--verify-existing first');
    exitCode = 1;
    return;
  }
  if (committed.readAsStringSync() != output.readAsStringSync()) {
    stderr.writeln(
      '${committed.path} is not what this tool generates from '
      '$kHeadersVersion. Either it was hand-edited - which the file forbids '
      'at the top - or it was generated from a different header commit. '
      'Re-run without --verify-existing and commit the result.',
    );
    exitCode = 1;
    return;
  }
  print('${committed.path} matches $kHeadersVersion');
}

final class _Options {
  const _Options(this.verifyExisting, this.llvm);

  final bool verifyExisting;
  final String? llvm;

  static _Options parse(List<String> arguments) {
    var verify = false;
    String? llvm = Platform.environment['DART_UI_LLVM_PATH'];
    for (var i = 0; i < arguments.length; i++) {
      switch (arguments[i]) {
        case '--verify-existing':
          verify = true;
        case '--llvm':
          if (i + 1 >= arguments.length) {
            throw const FormatException('--llvm needs a directory');
          }
          llvm = arguments[++i];
        default:
          throw FormatException('unknown option ${arguments[i]}');
      }
    }
    return _Options(verify, llvm);
  }
}

/// Directories that have held an LLVM on a machine this has run on.
///
/// A list rather than one path because `ffigen`'s only hard requirement is a
/// `libclang` shared library, and every platform puts it somewhere else. The
/// environment variable is checked first so a machine with two LLVMs can say
/// which.
List<String> _llvmCandidates() {
  if (Platform.isWindows) {
    return const <String>[
      r'C:\Program Files\LLVM',
      r'D:\EuroOfficeNative\LLVM',
      r'C:\Program Files (x86)\LLVM',
    ];
  }
  if (Platform.isMacOS) {
    return const <String>[
      '/opt/homebrew/opt/llvm',
      '/usr/local/opt/llvm',
      '/Library/Developer/CommandLineTools/usr',
    ];
  }
  return const <String>['/usr/lib/llvm-18', '/usr/lib/llvm-17', '/usr/lib'];
}

String? _findLlvm() {
  for (final String candidate in _llvmCandidates()) {
    if (Directory(candidate).existsSync()) return candidate;
  }
  return null;
}

/// Clones `Vulkan-Headers` at [kHeadersCommit], or refreshes an existing
/// checkout to it.
///
/// `--depth 1` on a single commit: the whole history is forty megabytes and
/// none of it is wanted. A checkout that is already at the right commit costs
/// one `git rev-parse`.
Future<void> _fetchHeaders(Directory checkout) async {
  if (checkout.existsSync()) {
    final ProcessResult head = Process.runSync(
        'git', <String>['-C', checkout.path, 'rev-parse', 'HEAD'],
        stdoutEncoding: systemEncoding);
    if (head.exitCode == 0 &&
        (head.stdout as String).trim() == kHeadersCommit) {
      return;
    }
  } else {
    checkout.createSync(recursive: true);
    _git(<String>['-C', checkout.path, 'init', '--quiet']);
    _git(<String>['-C', checkout.path, 'remote', 'add', 'origin', kRepository]);
  }
  print('fetching $kRepository at $kHeadersCommit');
  _git(<String>[
    '-C',
    checkout.path,
    'fetch',
    '--depth',
    '1',
    '--quiet',
    'origin',
    kHeadersCommit,
  ]);
  _git(<String>[
    '-C',
    checkout.path,
    'checkout',
    '--quiet',
    '--force',
    kHeadersCommit,
  ]);
}

void _git(List<String> arguments) {
  final ProcessResult result = Process.runSync('git', arguments,
      stdoutEncoding: systemEncoding, stderrEncoding: systemEncoding);
  if (result.exitCode != 0) {
    throw StateError('git ${arguments.join(' ')} failed:\n${result.stderr}');
  }
}

/// Fails unless the checked-out header really declares [kVkHeaderVersion].
///
/// The one check that makes the constants at the top of this file mean
/// something. Without it, "generated from v1.4.360" is a sentence in a comment.
void _assertHeaderVersion(String include) {
  final File core = File('$include${Platform.pathSeparator}vulkan'
      '${Platform.pathSeparator}vulkan_core.h');
  if (!core.existsSync()) {
    throw StateError('no vulkan_core.h under $include');
  }
  final RegExp pattern = RegExp(r'#define\s+VK_HEADER_VERSION\s+(\d+)');
  for (final String line in core.readAsLinesSync()) {
    final RegExpMatch? match = pattern.firstMatch(line);
    if (match == null) continue;
    final int found = int.parse(match.group(1)!);
    if (found != kVkHeaderVersion) {
      throw StateError('$kHeadersCommit declares VK_HEADER_VERSION $found, '
          'not the $kVkHeaderVersion this tool records');
    }
    return;
  }
  throw StateError('no VK_HEADER_VERSION in ${core.path}');
}

/// Replaces ffigen's four-line banner with one that records the provenance.
///
/// ffigen writes "AUTO GENERATED FILE, DO NOT EDIT" and stops there, which
/// leaves the reader knowing the file is generated and not knowing *from
/// what*. Section 11.4 wants the version and the commit in the artefact, not
/// only in the tool.
void _rewriteHeader(File output) {
  final String body = output.readAsStringSync();
  final int firstImport = body.indexOf('import ');
  if (firstImport < 0) throw StateError('${output.path} has no import');
  output.writeAsStringSync('''
// GENERATED FILE - DO NOT EDIT.
//
// Vulkan structures and enumerants for `lib/src/rendering/gpu/vulkan/`,
// produced by `package:ffigen` from the official Khronos headers.
//
//   source:  $kRepository
//   version: $kHeadersVersion
//   commit:  $kHeadersCommit
//   header:  VK_HEADER_VERSION $kVkHeaderVersion
//   config:  $kConfigTemplatePath
//   command: dart run tool/generate_vulkan_bindings.dart
//
// The subset generated, and the list of APIs deliberately ignored, is in the
// config. Commands are **not** generated - see `vulkan_bindings.dart` - and
// neither are the four macros `vulkan_constants.dart` carries by hand; both
// are recorded as manual overrides in the config's header comment.
//
// `dart run tool/generate_vulkan_bindings.dart --verify-existing` fails if
// this file is not exactly what the pinned commit produces, so a hand edit
// here is caught rather than inherited.
//
// ignore_for_file: type=lint
${body.substring(firstImport)}''');
}

void _format(File output) {
  final ProcessResult result = Process.runSync(
    Platform.resolvedExecutable,
    <String>['format', '--line-length', '80', output.path],
    stdoutEncoding: systemEncoding,
    stderrEncoding: systemEncoding,
  );
  if (result.exitCode != 0) {
    throw StateError('dart format failed on ${output.path}:\n'
        '${result.stderr}');
  }
}

/// A path as a single-quoted YAML scalar.
///
/// Windows paths contain backslashes, and a backslash inside a *double*-quoted
/// YAML scalar is an escape: `'C:\vulkan'` is a path and `"C:\vulkan"` is a
/// parse error waiting for the first `\t`. Single quotes in YAML are literal
/// apart from `''`, which is what this doubles.
String _yamlPath(String path) => path.replaceAll("'", "''");
