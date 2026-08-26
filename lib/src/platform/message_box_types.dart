/// The shared vocabulary of [NativeMessageBox], plus the command and style
/// planning that is pure string work.
library;

import 'shell_types.dart';

/// What a native message box is for. The kind picks the icon, the sound and
/// - for [confirm] - the second button.
enum MessageBoxKind {
  info,
  warning,
  error,

  /// A question with an affirmative and a cancel button. The only kind whose
  /// answer can be `false`.
  confirm,
}

/// A message box that could not be shown at all - as opposed to one the user
/// dismissed, which is a normal answer.
final class MessageBoxException implements Exception {
  const MessageBoxException({
    required this.reason,
    this.platform,
    this.errorCode,
  });

  final String reason;
  final String? platform;
  final int? errorCode;

  @override
  String toString() => 'MessageBoxException: could not show'
      '${platform == null ? '' : ' on $platform'}'
      '${errorCode == null ? '' : ' (code $errorCode)'} - $reason';
}

/// The `MessageBoxW` style flags for [kind]: `MB_OK` or `MB_OKCANCEL` plus
/// the matching `MB_ICON*`.
///
/// ABI constants from winuser.h, combined here so the mapping is a testable
/// value instead of an inline expression next to an FFI call.
int windowsMessageBoxStyle(MessageBoxKind kind) => switch (kind) {
      MessageBoxKind.info => 0x00000040, // MB_OK | MB_ICONINFORMATION
      MessageBoxKind.warning => 0x00000030, // MB_OK | MB_ICONWARNING
      MessageBoxKind.error => 0x00000010, // MB_OK | MB_ICONERROR
      // MB_OKCANCEL | MB_ICONQUESTION
      MessageBoxKind.confirm => 0x00000021,
    };

/// `IDOK`: the affirmative answer `MessageBoxW` returns.
const int windowsMessageBoxOk = 1;

/// The Linux dialog commands to try, in preference order.
///
/// zenity (GTK) and kdialog (Qt) are the two dialog helpers desktops
/// actually ship; which one exists tells us which desktop this is. Both exit
/// 0 for the affirmative button, 1 for cancel.
List<ShellCommand> linuxMessageBoxCommands(
  MessageBoxKind kind, {
  required String title,
  required String message,
}) {
  final String zenityKind = switch (kind) {
    MessageBoxKind.info => '--info',
    MessageBoxKind.warning => '--warning',
    MessageBoxKind.error => '--error',
    MessageBoxKind.confirm => '--question',
  };
  final String kdialogKind = switch (kind) {
    MessageBoxKind.info => '--msgbox',
    MessageBoxKind.warning => '--sorry',
    MessageBoxKind.error => '--error',
    MessageBoxKind.confirm => '--yesno',
  };
  return <ShellCommand>[
    ShellCommand(
      executable: 'zenity',
      arguments: <String>[zenityKind, '--title=$title', '--text=$message'],
    ),
    ShellCommand(
      executable: 'kdialog',
      arguments: <String>['--title', title, kdialogKind, message],
    ),
  ];
}

/// Escapes [value] for interpolation inside a double-quoted AppleScript
/// string literal. Backslash first, then the quote, or the escape itself
/// would be re-escaped.
String escapeAppleScriptString(String value) =>
    value.replaceAll(r'\', r'\\').replaceAll('"', r'\"');

/// The AppleScript program for one dialog of [kind].
///
/// `display dialog` rather than `display alert` because only the former
/// takes an icon by name and custom buttons in one grammar. A cancelled
/// dialog makes osascript exit non-zero, which the caller maps to `false`.
String macMessageBoxScript(
  MessageBoxKind kind, {
  required String title,
  required String message,
}) {
  final String safeTitle = escapeAppleScriptString(title);
  final String safeMessage = escapeAppleScriptString(message);
  final String icon = switch (kind) {
    MessageBoxKind.info => 'note',
    MessageBoxKind.warning => 'caution',
    MessageBoxKind.error => 'stop',
    MessageBoxKind.confirm => 'note',
  };
  final String buttons =
      kind == MessageBoxKind.confirm ? '{"Cancel", "OK"}' : '{"OK"}';
  return 'display dialog "$safeMessage" with title "$safeTitle" '
      'buttons $buttons default button "OK" with icon $icon';
}
