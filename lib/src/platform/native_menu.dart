/// Menus the operating system draws: the macOS menu bar at the top of the
/// screen.
///
/// The framework draws its own menus everywhere (`MenuBar`), identical on
/// every platform. This is the other choice a Mac application has - the
/// system's own bar, which a Mac user expects and which takes no room in the
/// window. A backend that can show one implements [NativeMenuBarWindow];
/// `PlatformMenuBar` is the widget that picks between the two.
library;

import 'input_events.dart';

/// One entry of a native menu: a submenu, an item or a separator.
sealed class NativeMenuEntry {
  const NativeMenuEntry();
}

/// A menu with a title - a top-level menu of the bar, or a submenu.
final class NativeMenu extends NativeMenuEntry {
  const NativeMenu(this.label, this.children);

  final String label;
  final List<NativeMenuEntry> children;
}

/// An item the user chooses; [id] is what comes back when they do.
final class NativeMenuItem extends NativeMenuEntry {
  const NativeMenuItem({
    required this.id,
    required this.label,
    this.enabled = true,
    this.checked = false,
    this.key,
    this.modifiers = const <KeyModifier>{},
  });

  final int id;
  final String label;
  final bool enabled;
  final bool checked;

  /// The logical key of the item's shortcut (`KeyEvent.logicalKey`), shown
  /// next to the item; null for none. The presses themselves keep reaching
  /// the window as key events, so a shortcut works the same with either menu
  /// bar.
  final int? key;

  /// The modifiers held with [key] - the real keys, Command being
  /// [KeyModifier.meta].
  final Set<KeyModifier> modifiers;
}

/// A line between groups of items.
final class NativeMenuSeparator extends NativeMenuEntry {
  const NativeMenuSeparator();
}

/// A window that can put menus in the system's menu bar.
///
/// A capability, tested for with a pattern: only the macOS backend has one.
/// Everywhere else the application draws its menu bar in the window.
abstract interface class NativeMenuBarWindow {
  /// Puts [menus] in the system menu bar while this window is the active one,
  /// next to the menus every application has there (the application menu,
  /// Window). [onSelected] gets the [NativeMenuItem.id] of the item the user
  /// chooses. Null takes the menus out again.
  ///
  /// Cheap to call with the same menus: unchanged menus are not sent again.
  void setNativeMenuBar(
    List<NativeMenu>? menus,
    void Function(int id) onSelected,
  );
}
