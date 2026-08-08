/// How this backend reports failure.
///
/// The rule from section 6.6, applied to Win32 specifically: a failed call
/// names the function *and* its `GetLastError`. "CreateWindowEx failed" is
/// unactionable; "CreateWindowExW failed, GetLastError=1407 (0x57F,
/// ERROR_CANNOT_FIND_WND_CLASS)" tells the reader the class registration is
/// the bug, not the window creation.
library;

import '../../foundation/diagnostics.dart';

/// Builds the diagnostic for a native call that reported failure.
///
/// [lastError] must be read immediately after the failing call: almost any
/// intervening Win32 call overwrites the thread's last-error value, which is
/// why the callers here capture it on the line after the call and not later.
BackendDiagnostic win32CallFailed(
  String function,
  int lastError, {
  DiagnosticKind kind = DiagnosticKind.connectionFailed,
  String? context,
}) {
  final hex = lastError.toRadixString(16).toUpperCase();
  final name = win32ErrorName(lastError);
  return BackendDiagnostic(
    kind: kind,
    message:
        context == null ? '$function failed' : '$function failed: $context',
    detail: name == null
        ? 'GetLastError=$lastError (0x$hex)'
        : 'GetLastError=$lastError (0x$hex, $name)',
  );
}

/// The handful of error codes this backend can actually provoke, spelled out.
///
/// Not a full table on purpose: a partial table that is right beats a
/// generated one that goes stale, and the numeric code is always printed
/// anyway, so an unknown code loses nothing.
String? win32ErrorName(int code) => switch (code) {
      0 => 'ERROR_SUCCESS',
      5 => 'ERROR_ACCESS_DENIED',
      6 => 'ERROR_INVALID_HANDLE',
      8 => 'ERROR_NOT_ENOUGH_MEMORY',
      87 => 'ERROR_INVALID_PARAMETER',
      120 => 'ERROR_CALL_NOT_IMPLEMENTED',
      1400 => 'ERROR_INVALID_WINDOW_HANDLE',
      1401 => 'ERROR_INVALID_MENU_HANDLE',
      1404 => 'ERROR_INVALID_HOOK_HANDLE',
      1407 => 'ERROR_CANNOT_FIND_WND_CLASS',
      1410 => 'ERROR_CLASS_ALREADY_EXISTS',
      1412 => 'ERROR_CLASS_HAS_WINDOWS',
      1413 => 'ERROR_INVALID_INDEX',
      1421 => 'ERROR_RESOURCE_TYPE_NOT_FOUND',
      _ => null,
    };

/// Raised when a Win32 call the backend depends on failed.
///
/// An [Error] rather than an [Exception] because every site that throws one is
/// a place where the platform contract was not met - there is no `catch` that
/// could sensibly retry, only a bug report, and the diagnostic is what goes
/// into it.
final class Win32Failure extends Error {
  Win32Failure(this.diagnostic);

  final BackendDiagnostic diagnostic;

  @override
  String toString() => 'Win32Failure: $diagnostic';
}

/// A Dart exception that escaped a message handler.
///
/// See the WndProc policy in `win32_window_class.dart`: the exception cannot
/// be allowed to unwind through the native frame, so it is captured here,
/// carrying enough context to identify the message that produced it.
final class Win32HandlerFault {
  Win32HandlerFault({
    required this.hwnd,
    required this.message,
    required this.wParam,
    required this.lParam,
    required this.error,
    required this.stackTrace,
  });

  final int hwnd;

  /// The `WM_*` value, in hex in [toString] because that is how the message
  /// is spelled everywhere else.
  final int message;

  final int wParam;
  final int lParam;
  final Object error;
  final StackTrace stackTrace;

  BackendDiagnostic get diagnostic => BackendDiagnostic(
        kind: DiagnosticKind.note,
        message: 'exception in WndProc for message '
            '0x${message.toRadixString(16)}',
        detail: '$error',
      );

  @override
  String toString() => 'Win32HandlerFault(hwnd: 0x${hwnd.toRadixString(16)}, '
      'msg: 0x${message.toRadixString(16)}, wParam: $wParam, '
      'lParam: $lParam): $error\n$stackTrace';
}
