library;

import 'dart:ffi';
import 'dart:io';

import '../ffi/native_memory.dart';
import 'message_box_types.dart';
import 'shell_types.dart';

Future<bool> show({
  required String title,
  required String message,
  required MessageBoxKind kind,
  required int ownerWindowHandle,
}) async {
  if (Platform.isWindows) {
    return _windowsShow(
      title: title,
      message: message,
      kind: kind,
      ownerWindowHandle: ownerWindowHandle,
    );
  }
  if (Platform.isMacOS) {
    return _macShow(title: title, message: message, kind: kind);
  }
  if (Platform.isLinux) {
    return linuxShow(title: title, message: message, kind: kind);
  }
  throw MessageBoxException(
    platform: Platform.operatingSystem,
    reason: 'no native message-box backend exists for this operating system',
  );
}

/// The seam a test injects a fake process runner through, so the zenity /
/// kdialog fallback chain is checkable without a desktop.
typedef MessageBoxProcessRunner = Future<ProcessResult> Function(
  String executable,
  List<String> arguments,
);

Future<ProcessResult> _runProcess(
  String executable,
  List<String> arguments,
) =>
    Process.run(executable, arguments);

/// Linux: zenity first, then kdialog. Both exit 0 for the affirmative
/// button and 1 for cancel; anything else is a real failure of that helper,
/// and the next one is tried so a broken zenity does not mask a working
/// kdialog.
Future<bool> linuxShow({
  required String title,
  required String message,
  required MessageBoxKind kind,
  MessageBoxProcessRunner run = _runProcess,
}) async {
  final List<String> failures = <String>[];
  for (final ShellCommand command
      in linuxMessageBoxCommands(kind, title: title, message: message)) {
    try {
      final ProcessResult result =
          await run(command.executable, command.arguments);
      if (result.exitCode == 0) return true;
      if (result.exitCode == 1) return false;
      failures.add('${command.executable} exited ${result.exitCode}');
    } on ProcessException {
      failures.add('${command.executable} is not installed');
    }
  }
  throw MessageBoxException(
    platform: 'linux',
    reason: 'no dialog helper succeeded: ${failures.join('; ')}',
  );
}

/// macOS: osascript. A cancelled `display dialog` makes osascript exit
/// non-zero with "User canceled" on stderr, which is the `false` answer, not
/// a failure.
Future<bool> _macShow({
  required String title,
  required String message,
  required MessageBoxKind kind,
  MessageBoxProcessRunner run = _runProcess,
}) async {
  final ProcessResult result;
  try {
    result = await run(
      '/usr/bin/osascript',
      <String>[
        '-e',
        macMessageBoxScript(kind, title: title, message: message),
      ],
    );
  } on ProcessException catch (error) {
    throw MessageBoxException(
      platform: 'macos',
      reason: 'osascript could not be run: ${error.message}',
    );
  }
  if (result.exitCode == 0) return true;
  if ('${result.stderr}'.toLowerCase().contains('user canceled')) {
    return false;
  }
  throw MessageBoxException(
    platform: 'macos',
    errorCode: result.exitCode,
    reason: '${result.stderr}'.trim(),
  );
}

// ---------------------------------------------------------------------------
// Windows: MessageBoxW. Synchronous by nature - the call returns when the
// user answers - and wrapped in a future by the port's contract.
// ---------------------------------------------------------------------------

typedef _MessageBoxWNative = Int32 Function(
  IntPtr ownerWindow,
  Pointer<Uint16> text,
  Pointer<Uint16> caption,
  Uint32 style,
);
typedef _MessageBoxWDart = int Function(
  int ownerWindow,
  Pointer<Uint16> text,
  Pointer<Uint16> caption,
  int style,
);

_MessageBoxWDart? _messageBox;

Future<bool> _windowsShow({
  required String title,
  required String message,
  required MessageBoxKind kind,
  required int ownerWindowHandle,
}) async {
  final _MessageBoxWDart showBox;
  try {
    showBox = _messageBox ??= DynamicLibrary.open('user32.dll')
        .lookupFunction<_MessageBoxWNative, _MessageBoxWDart>('MessageBoxW');
  } on Object catch (error) {
    throw MessageBoxException(
      platform: 'windows',
      reason: 'user32.dll could not be loaded: $error',
    );
  }
  final int answer = using((NativeArena arena) {
    return showBox(
      ownerWindowHandle,
      arena.allocateUtf16(message),
      arena.allocateUtf16(title),
      windowsMessageBoxStyle(kind),
    );
  });
  if (answer == 0) {
    throw const MessageBoxException(
      platform: 'windows',
      errorCode: 0,
      reason: 'MessageBoxW returned 0, which means it could not be shown',
    );
  }
  return answer == windowsMessageBoxOk;
}
