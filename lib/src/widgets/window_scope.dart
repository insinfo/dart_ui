/// What a widget may ask of the window it is in.
library;

import '../platform/native_window.dart';
import 'widget.dart';

/// The window a widget is in, as the operations an application needs from
/// it - close, minimize, retitle, change the pointer - on every platform.
///
/// An "Exit" menu item is `WindowScope.of(context)?.close()`: the same path
/// as the close button, so the last window still ends the application and a
/// window with a modal dialog still refuses.
abstract interface class WindowController {
  /// Asks the window to close, exactly as its close button does.
  void close();

  /// Minimizes the window where the platform has that notion.
  void minimize();

  /// Replaces the title bar text.
  void setTitle(String title);

  /// Changes the pointer shape while it is over this window.
  void setCursor(SystemCursor cursor);
}

/// Provides the [WindowController] of the window the subtree is in.
final class WindowScope extends InheritedWidget {
  const WindowScope({
    super.key,
    required this.controller,
    required super.child,
  });

  final WindowController controller;

  /// The window [context] is in, or null outside an application window -
  /// in a test that builds widgets with no window, for instance.
  static WindowController? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<WindowScope>()?.controller;

  @override
  bool updateShouldNotify(WindowScope oldWidget) =>
      !identical(controller, oldWidget.controller);
}
