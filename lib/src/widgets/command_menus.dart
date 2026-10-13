/// Menu descriptions (`SubmenuSpec`, `CommandItem`) turned into the menus a
/// [PlatformMenuBar] or a [ContextMenuArea] shows.
library;

import '../commands/command.dart';
import '../commands/command_registry.dart';
import '../commands/menu_spec.dart';
import 'icon.dart' show IconData;
import 'menu_anchor.dart' show MenuController;
import 'platform_menu_bar.dart';
import 'widget.dart' show Widget;

/// Builds menus from descriptions against one [registry].
///
/// Icons are presentation, so they are not part of a command: [iconOf]
/// gives the icon for a command id, or for a submenu's [SubmenuSpec.id].
final class MenuBuilder {
  const MenuBuilder(this.registry, {this.iconOf});

  final CommandRegistry registry;
  final IconData? Function(String id)? iconOf;

  /// The bar: one [PlatformMenu] per top-level [SubmenuSpec].
  List<PlatformMenu> bar(
    List<SubmenuSpec> menus, {
    List<MenuController> controllers = const <MenuController>[],
  }) =>
      <PlatformMenu>[
        for (var i = 0; i < menus.length; i++)
          PlatformMenu(
            label: menus[i].label,
            icon: _icon(menus[i].id),
            controller: i < controllers.length ? controllers[i] : null,
            children: entries(menus[i].children),
          ),
      ];

  /// [children] as menu entries - for a context menu, or one menu's rows.
  List<PlatformMenuEntry> entries(List<MenuSpecEntry> children) =>
      <PlatformMenuEntry>[
        for (final MenuSpecEntry entry in children) _entry(entry),
      ];

  /// [children] as framework menu widgets, for a right-click menu.
  List<Widget> widgets(List<MenuSpecEntry> children) =>
      PlatformMenuBar.menuWidgets(entries(children));

  /// Every command row under [menus]; see [flattenMenus].
  List<MenuRow> flatten(List<MenuSpecEntry> menus) =>
      flattenMenus(registry, menus);

  IconData? _icon(String? id) => id == null ? null : iconOf?.call(id);

  PlatformMenuEntry _entry(MenuSpecEntry entry) {
    switch (entry) {
      case MenuSeparator():
        return const PlatformMenuDivider();
      case SubmenuSpec():
        return PlatformMenu(
          label: entry.label,
          icon: _icon(entry.id),
          children: entries(entry.children),
        );
      case CommandItem():
        final CommandSpec? command = registry[entry.command];
        if (command == null) {
          return PlatformMenuItem(
            label: entry.label ?? entry.command,
            onSelected: null,
          );
        }
        final CommandArgs args = CommandArgs(entry.params);
        final bool enabled =
            guardCommandState(() => command.isEnabledWith(args), false);
        return PlatformMenuItem(
          label: entry.label ??
              guardCommandState(() => command.labelWith(args), command.label),
          icon: _icon(entry.command),
          shortcut: command.shortcut,
          checked: entry.checkable
              ? guardCommandState(() => command.isCheckedWith(args), null)
              : null,
          onSelected: enabled
              ? () => registry.execute(entry.command, entry.params)
              : null,
        );
    }
  }
}
