/// What a widget may ask of the window it is in.
library;

import '../geometry/offset.dart';
import '../geometry/size.dart';
import '../platform/native_menu.dart';
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

  /// [local] (a position in this window, logical pixels) on the screen.
  Offset toScreen(Offset local);

  /// The title bar this window gave away - opened with
  /// `WindowTitleBar.hidden` on a platform that could - or null for a window
  /// with its title bar. `WindowDragArea` is the widget over it.
  HiddenTitleBarWindow? get hiddenTitleBar;

  /// Whether this window can put menus in the operating system's menu bar -
  /// the macOS one. See [setNativeMenuBar].
  bool get hasNativeMenuBar;

  /// Puts [menus] in the operating system's menu bar while this window is
  /// the active one; [onSelected] gets the id of the item chosen. Null takes
  /// them out. Does nothing where [hasNativeMenuBar] is false. `PlatformMenuBar`
  /// is the widget over this.
  void setNativeMenuBar(
    List<NativeMenu>? menus,
    void Function(int id) onSelected,
  );

  /// Opens a window that belongs to this one - a floating panel, a tool
  /// palette - showing [child], on every platform.
  ///
  /// It stays with this window (closing this one closes it) and is
  /// non-modal. [position] is in screen coordinates; null lets the platform
  /// place it. [onClosed] runs once when it goes away, whoever closed it.
  /// [child] is a new widget tree: wrap it in the same [Theme] the panel
  /// would have had here, and rebuild it from shared state with a listener.
  Future<ChildWindow> openChildWindow({
    required Widget child,
    String? title,
    Size size = const Size(320, 480),
    Offset? position,
    void Function()? onClosed,
  });
}

/// A window opened with [WindowController.openChildWindow].
abstract interface class ChildWindow {
  bool get isOpen;

  /// Closes it; [WindowController.openChildWindow]'s `onClosed` then runs.
  void close();

  void setTitle(String title);
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
