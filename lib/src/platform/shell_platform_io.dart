library;

import 'dart:ffi';
import 'dart:io';

import '../ffi/native_memory.dart';
import 'shell_types.dart';

/// Runs one external command to completion. The seam a test injects a fake
/// through, so that "which command, with which arguments" is checkable
/// without a desktop launching anything.
typedef ShellProcessRunner = Future<ProcessResult> Function(
  String executable,
  List<String> arguments,
);

Future<ProcessResult> _runProcess(
  String executable,
  List<String> arguments,
) =>
    Process.run(executable, arguments);

Future<void> openUrl(String url) async {
  final Uri parsed = parseLaunchableUrl(url);
  final String target = parsed.toString();
  if (Platform.isWindows) {
    _windowsShellExecute(operation: 'openUrl', file: target);
    return;
  }
  if (Platform.isMacOS) {
    await runFirstAvailable(
      'openUrl',
      <ShellCommand>[macOpenCommand(target)],
    );
    return;
  }
  if (Platform.isLinux) {
    await runFirstAvailable('openUrl', linuxOpenCommands(target));
    return;
  }
  throw ShellException(
    operation: 'openUrl',
    platform: Platform.operatingSystem,
    reason: 'no shell backend exists for this operating system',
  );
}

Future<void> openPath(String path) async {
  _requireExisting('openPath', path);
  if (Platform.isWindows) {
    _windowsShellExecute(operation: 'openPath', file: path);
    return;
  }
  if (Platform.isMacOS) {
    await runFirstAvailable(
      'openPath',
      <ShellCommand>[macOpenCommand(path)],
    );
    return;
  }
  if (Platform.isLinux) {
    await runFirstAvailable('openPath', linuxOpenCommands(path));
    return;
  }
  throw ShellException(
    operation: 'openPath',
    platform: Platform.operatingSystem,
    reason: 'no shell backend exists for this operating system',
  );
}

Future<void> revealInFileManager(String path) async {
  _requireExisting('revealInFileManager', path);
  if (Platform.isWindows) {
    _windowsShellExecute(
      operation: 'revealInFileManager',
      file: 'explorer.exe',
      parameters: windowsRevealParameters(path),
    );
    return;
  }
  if (Platform.isMacOS) {
    await runFirstAvailable(
      'revealInFileManager',
      <ShellCommand>[macRevealCommand(path)],
    );
    return;
  }
  if (Platform.isLinux) {
    await runFirstAvailable(
      'revealInFileManager',
      linuxRevealCommands(path.replaceAll(r'\', '/')),
    );
    return;
  }
  throw ShellException(
    operation: 'revealInFileManager',
    platform: Platform.operatingSystem,
    reason: 'no shell backend exists for this operating system',
  );
}

void _requireExisting(String operation, String path) {
  if (FileSystemEntity.typeSync(path) == FileSystemEntityType.notFound) {
    throw ShellException(
      operation: operation,
      platform: Platform.operatingSystem,
      reason: 'the path does not exist: $path',
    );
  }
}

/// Tries each of [commands] until one runs and exits 0.
///
/// A command that is not installed ([ProcessException]) or that exits
/// non-zero moves on to the next candidate; when every candidate has been
/// tried the failure names all of them, so "nothing opened" arrives with the
/// list of launchers the machine was missing instead of arriving silently.
Future<void> runFirstAvailable(
  String operation,
  List<ShellCommand> commands, {
  ShellProcessRunner run = _runProcess,
}) async {
  final List<String> failures = <String>[];
  for (final ShellCommand command in commands) {
    try {
      final ProcessResult result =
          await run(command.executable, command.arguments);
      if (result.exitCode == 0) return;
      failures.add('${command.executable} exited ${result.exitCode}');
    } on ProcessException {
      failures.add('${command.executable} is not installed');
    }
  }
  throw ShellException(
    operation: operation,
    platform: Platform.operatingSystem,
    reason: 'no launcher succeeded: ${failures.join('; ')}',
  );
}

// ---------------------------------------------------------------------------
// Windows: ShellExecuteW, the API behind double-clicking. It resolves the
// association itself, so URLs, documents and folders all go through the one
// entry point.
// ---------------------------------------------------------------------------

typedef _ShellExecuteWNative = IntPtr Function(
  IntPtr ownerWindow,
  Pointer<Uint16> operation,
  Pointer<Uint16> file,
  Pointer<Uint16> parameters,
  Pointer<Uint16> directory,
  Int32 showCommand,
);
typedef _ShellExecuteWDart = int Function(
  int ownerWindow,
  Pointer<Uint16> operation,
  Pointer<Uint16> file,
  Pointer<Uint16> parameters,
  Pointer<Uint16> directory,
  int showCommand,
);

const int _swShowNormal = 1;

_ShellExecuteWDart? _shellExecute;

void _windowsShellExecute({
  required String operation,
  required String file,
  String? parameters,
}) {
  final _ShellExecuteWDart execute;
  try {
    execute = _shellExecute ??= DynamicLibrary.open('shell32.dll')
        .lookupFunction<_ShellExecuteWNative, _ShellExecuteWDart>(
            'ShellExecuteW');
  } on Object catch (error) {
    throw ShellException(
      operation: operation,
      platform: 'windows',
      reason: 'shell32.dll could not be loaded: $error',
    );
  }
  final int result = using((NativeArena arena) {
    return execute(
      0,
      arena.allocateUtf16('open'),
      arena.allocateUtf16(file),
      parameters == null ? nullptr : arena.allocateUtf16(parameters),
      nullptr,
      _swShowNormal,
    );
  });
  // The documented contract: values greater than 32 are success, the rest
  // are SE_ERR_* codes (2 = file not found, 8 = out of memory, 31 = no
  // association, ...).
  if (result <= 32) {
    throw ShellException(
      operation: operation,
      platform: 'windows',
      errorCode: result,
      reason: 'ShellExecuteW refused the request'
          '${result == 31 ? ' (no application is associated)' : ''}',
    );
  }
}
