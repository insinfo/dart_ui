/// The operating system's own modal message box.
///
/// This is the dialog for the moments the framework's widgets cannot serve:
/// before a window exists, after rendering has failed, or when the message
/// is "this application is about to exit". Everything in between - styled
/// dialogs, theming, custom buttons - belongs to the widget layer, which can
/// draw them itself; this port is deliberately four kinds, two buttons and a
/// string, because that is the intersection the three desktops agree on.
///
/// The call blocks its answer, not the process: the future completes when
/// the user dismisses the dialog. On the web and other stub targets it
/// throws [MessageBoxException] - a browser `alert()` would be a lie about
/// what it looks like and cannot express a native title bar anyway.
library;

import 'message_box_platform_stub.dart'
    if (dart.library.io) 'message_box_platform_io.dart' as platform;
import 'message_box_types.dart';

export 'message_box_types.dart';

/// One native modal dialog, shown by the platform.
abstract final class NativeMessageBox {
  /// Shows a message box and answers how it was dismissed.
  ///
  /// Returns true for the affirmative button. For [MessageBoxKind.confirm]
  /// false means the user chose Cancel; for the other kinds the only button
  /// is OK, so the answer is always true.
  ///
  /// Throws [MessageBoxException] when no dialog could be shown at all - a
  /// Linux with neither zenity nor kdialog, a stub target.
  static Future<bool> show({
    required String title,
    required String message,
    MessageBoxKind kind = MessageBoxKind.info,
    int ownerWindowHandle = 0,
  }) =>
      platform.show(
        title: title,
        message: message,
        kind: kind,
        ownerWindowHandle: ownerWindowHandle,
      );
}
