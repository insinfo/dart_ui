/// An application's menu bar, described once and shown either in the window
/// (the framework's [MenuBar]) or in the operating system's own bar - the
/// one at the top of a Mac's screen.
library;

import '../graphics/color.dart';
import '../layout/edge_insets.dart';
import '../platform/editing_convention.dart';
import '../platform/input_events.dart';
import '../platform/native_menu.dart';
import 'actions.dart';
import 'basic.dart';
import 'context_menu_area.dart';
import 'icon.dart';
import 'menu_anchor.dart';
import 'phosphor_icons.dart';
import 'theme.dart';
import 'widget.dart';
import 'window_scope.dart';

/// One entry of a [PlatformMenuBar] menu: a submenu, an item or a divider.
sealed class PlatformMenuEntry {
  const PlatformMenuEntry();
}

/// A menu of the bar, or a submenu inside one.
final class PlatformMenu extends PlatformMenuEntry {
  const PlatformMenu({
    required this.label,
    required this.children,
    this.icon,
    this.controller,
  });

  final String label;
  final List<PlatformMenuEntry> children;

  /// Drawn before the label in the in-window menu; the system bar has none.
  final IconData? icon;

  /// Opens and closes the in-window menu from code - a screenshot tool, a
  /// test. Unused while the menu is in the system bar.
  final MenuController? controller;
}

/// A command in a menu. **A null [onSelected] disables it.**
final class PlatformMenuItem extends PlatformMenuEntry {
  const PlatformMenuItem({
    required this.label,
    required this.onSelected,
    this.shortcut,
    this.icon,
    this.checked,
  });

  final String label;
  final void Function()? onSelected;

  /// Shown next to the item in the platform's notation. Showing is all the
  /// menu does with it: binding the key is the application's (a
  /// `CallbackShortcuts` around the window), so the key works whichever bar
  /// is showing.
  final KeyGesture? shortcut;

  /// Drawn before the label in the in-window menu.
  final IconData? icon;

  /// Non-null for a toggle: true shows a check mark.
  final bool? checked;
}

/// A line between groups of items.
final class PlatformMenuDivider extends PlatformMenuEntry {
  const PlatformMenuDivider();
}

/// The application's menus, in the system menu bar where there is one and
/// the application wants it, and in the window otherwise.
///
/// Put it where an in-window bar belongs - normally the top of the window's
/// column. With [native] true on a platform that has a system bar (macOS),
/// the menus go there and this widget takes no room; everywhere else, or
/// with [native] false, it is a [MenuBar] of [height] on [color]. The same
/// [menus] describe both, so an application offers the choice with one
/// boolean.
///
/// [menus] are read again on every build, so what is enabled and checked
/// stays current in either bar.
final class PlatformMenuBar extends StatefulWidget {
  const PlatformMenuBar({
    super.key,
    required this.menus,
    this.native = true,
    this.height,
    this.color,
    this.f10Activates = true,
  });

  final List<PlatformMenu> menus;

  /// Whether to use the system menu bar where there is one.
  final bool native;

  /// The in-window bar's height; null for its natural height.
  final double? height;

  /// The in-window bar's background; null for the theme's alternate surface.
  final Color? color;

  /// Whether a bare F10 gives the in-window bar the keyboard; see
  /// [MenuBar.f10Activates].
  final bool f10Activates;

  /// Whether [context]'s window can show menus in the system bar - what an
  /// application asks before offering the choice.
  static bool hasNativeMenuBar(BuildContext context) =>
      WindowScope.of(context)?.hasNativeMenuBar ?? false;

  /// [entries] as framework menu widgets, for a [MenuAnchor], a
  /// [SubmenuButton] or a [ContextMenuArea] - so a context menu can share
  /// the bar's commands.
  static List<Widget> menuWidgets(List<PlatformMenuEntry> entries) {
    // A column of labels lines up only if every row has the same lead: when
    // one row has an icon or a check, the others get an empty one.
    final bool lead = entries.any(
      (PlatformMenuEntry entry) => switch (entry) {
        PlatformMenu(:final IconData? icon) => icon != null,
        PlatformMenuItem(:final IconData? icon, :final bool? checked) =>
          icon != null || checked != null,
        PlatformMenuDivider() => false,
      },
    );
    Widget? leading(IconData? icon, bool? checked) => checked == true
        ? const Icon(PhosphorIcons.check, size: 14)
        : icon != null && checked == null
            ? Icon(icon, size: 14)
            : lead
                ? const SizedBox(width: 14)
                : null;
    return <Widget>[
      for (final PlatformMenuEntry entry in entries)
        switch (entry) {
          PlatformMenu() => SubmenuButton(
              controller: entry.controller,
              leadingIcon: leading(entry.icon, null),
              menuChildren: menuWidgets(entry.children),
              child: Text(entry.label),
            ),
          PlatformMenuItem() => MenuItemButton(
              leadingIcon: leading(entry.icon, entry.checked),
              shortcut: entry.shortcut?.label(),
              onPressed: entry.onSelected,
              child: Text(entry.label),
            ),
          PlatformMenuDivider() => const MenuDivider(),
        },
    ];
  }

  @override
  State<PlatformMenuBar> createState() => _PlatformMenuBarState();
}

final class _PlatformMenuBarState extends State<PlatformMenuBar> {
  WindowController? _window;

  /// What each item id sent to the system bar runs, from the latest build.
  final Map<int, void Function()> _actions = <int, void Function()>{};
  int _lastId = 0;

  /// Whether the system bar is showing these menus now.
  bool _installed = false;

  bool get _useNative => widget.native && (_window?.hasNativeMenuBar ?? false);

  @override
  void dispose() {
    _uninstall();
    super.dispose();
  }

  void _sync() {
    final WindowController? window = _window;
    if (window == null || !_useNative) {
      _uninstall();
      return;
    }
    _actions.clear();
    _lastId = 0;
    final List<NativeMenu> menus = <NativeMenu>[
      for (final PlatformMenu menu in widget.menus) _native(menu) as NativeMenu,
    ];
    window.setNativeMenuBar(menus, _selected);
    _installed = true;
  }

  void _uninstall() {
    if (!_installed) return;
    _installed = false;
    _actions.clear();
    _window?.setNativeMenuBar(null, _selected);
  }

  void _selected(int id) => _actions[id]?.call();

  NativeMenuEntry _native(PlatformMenuEntry entry) {
    switch (entry) {
      case PlatformMenu():
        return NativeMenu(entry.label, <NativeMenuEntry>[
          for (final PlatformMenuEntry child in entry.children) _native(child),
        ]);
      case PlatformMenuItem():
        final int id = ++_lastId;
        final void Function()? action = entry.onSelected;
        if (action != null) _actions[id] = action;
        final KeyGesture? shortcut =
            entry.shortcut?.resolved(EditingConvention.mac);
        return NativeMenuItem(
          id: id,
          label: entry.label,
          enabled: action != null,
          checked: entry.checked ?? false,
          key: shortcut?.logicalKey,
          modifiers: <KeyModifier>{
            if (shortcut?.shift ?? false) KeyModifier.shift,
            if (shortcut?.control ?? false) KeyModifier.control,
            if (shortcut?.alt ?? false) KeyModifier.alt,
            if (shortcut?.meta ?? false) KeyModifier.meta,
          },
        );
      case PlatformMenuDivider():
        return const NativeMenuSeparator();
    }
  }

  @override
  Widget build(BuildContext context) {
    // Synced from build, the one hook that runs both when the menus change
    // and when the window does. Cheap when nothing changed: the window does
    // not send menus it already shows.
    final WindowController? window = WindowScope.of(context);
    if (!identical(window, _window)) {
      _uninstall();
      _window = window;
    }
    _sync();
    if (_useNative) return const SizedBox();
    final ThemeData theme = Theme.of(context);
    final Widget bar = ColoredBox(
      color: widget.color ?? theme.surfaceAlternate,
      child: MenuBar(
        f10Activates: widget.f10Activates,
        children: <Widget>[
          for (final PlatformMenu menu in widget.menus)
            SubmenuButton(
              controller: menu.controller,
              menuChildren: PlatformMenuBar.menuWidgets(menu.children),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: Text(menu.label),
              ),
            ),
        ],
      ),
    );
    final double? height = widget.height;
    return height == null ? bar : SizedBox(height: height, child: bar);
  }
}
