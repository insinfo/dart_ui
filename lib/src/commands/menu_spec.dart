/// Menus described by command id, turned into whatever shows them.
library;

import '../widgets/icon.dart' show IconData;
import '../widgets/menu_anchor.dart' show MenuController;
import '../widgets/platform_menu_bar.dart';
import 'command.dart';
import 'command_registry.dart';

/// One entry of a menu description.
sealed class MenuSpecEntry {
  const MenuSpecEntry();
}

/// A row that runs [command], with [params] when it takes any.
///
/// A command that is not registered still shows, disabled - the honest
/// answer for a feature that is planned and not done, and what lets a parity
/// count tell the two apart. [label] overrides the command's own label, and
/// names the row when there is no command yet.
final class CommandItem extends MenuSpecEntry {
  const CommandItem(
    this.command, {
    this.params = const <String, Object?>{},
    this.label,
    this.checkable = true,
  });

  final String command;
  final Map<String, Object?> params;
  final String? label;

  /// False shows a toggle command as a plain action: "Align and
  /// Distribute..." under Arrange opens the panel, while the same command
  /// under Window shows whether it is open.
  final bool checkable;
}

/// A line between groups.
final class MenuSeparator extends MenuSpecEntry {
  const MenuSeparator();
}

/// A menu of the bar, or a submenu.
final class SubmenuSpec extends MenuSpecEntry {
  const SubmenuSpec(this.label, this.children, {this.icon});

  final String label;
  final List<MenuSpecEntry> children;
  final IconData? icon;
}

/// One row of a flattened menu: where it is, what it runs, and its state.
final class MenuRow {
  const MenuRow({
    required this.path,
    required this.label,
    required this.command,
    required this.registered,
    required this.enabled,
    this.checked,
    this.shortcut,
  });

  /// The labels of the menus above it, top first.
  final List<String> path;
  final String label;
  final String command;

  /// Whether [command] exists in the registry - implemented at all.
  final bool registered;
  final bool enabled;
  final bool? checked;
  final String? shortcut;

  Map<String, Object?> toJson() => <String, Object?>{
        'path': path,
        'label': label,
        'command': command,
        'registered': registered,
        'enabled': enabled,
        if (checked != null) 'checked': checked,
        if (shortcut != null) 'shortcut': shortcut,
      };
}

/// Turns menu descriptions into the menus a [PlatformMenuBar], a
/// [ContextMenuArea] or an automation client uses, against one registry.
final class MenuBuilder {
  const MenuBuilder(this.registry);

  final CommandRegistry registry;

  /// The bar: one [PlatformMenu] per top-level [SubmenuSpec].
  List<PlatformMenu> bar(
    List<SubmenuSpec> menus, {
    List<MenuController> controllers = const <MenuController>[],
  }) =>
      <PlatformMenu>[
        for (var i = 0; i < menus.length; i++)
          PlatformMenu(
            label: menus[i].label,
            icon: menus[i].icon,
            controller: i < controllers.length ? controllers[i] : null,
            children: entries(menus[i].children),
          ),
      ];

  /// [children] as menu entries - for a context menu, or one menu's rows.
  List<PlatformMenuEntry> entries(List<MenuSpecEntry> children) =>
      <PlatformMenuEntry>[
        for (final MenuSpecEntry entry in children) _entry(entry),
      ];

  PlatformMenuEntry _entry(MenuSpecEntry entry) {
    switch (entry) {
      case MenuSeparator():
        return const PlatformMenuDivider();
      case SubmenuSpec():
        return PlatformMenu(
          label: entry.label,
          icon: entry.icon,
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
        final bool enabled = _guard(() => command.isEnabledWith(args), false);
        return PlatformMenuItem(
          label: entry.label ??
              _guard(() => command.labelWith(args), command.label),
          icon: command.icon,
          shortcut: command.shortcut,
          checked: entry.checkable
              ? _guard(() => command.isCheckedWith(args), null)
              : null,
          onSelected: enabled
              ? () => registry.execute(entry.command, entry.params)
              : null,
        );
    }
  }

  /// Every command row under [menus], depth first, with its path.
  List<MenuRow> flatten(List<MenuSpecEntry> menus) {
    final List<MenuRow> rows = <MenuRow>[];
    void walk(List<MenuSpecEntry> entries, List<String> path) {
      for (final MenuSpecEntry entry in entries) {
        switch (entry) {
          case MenuSeparator():
            break;
          case SubmenuSpec():
            walk(entry.children, <String>[...path, entry.label]);
          case CommandItem():
            final CommandSpec? command = registry[entry.command];
            final CommandArgs args = CommandArgs(entry.params);
            rows.add(MenuRow(
              path: path,
              label: entry.label ??
                  (command == null
                      ? entry.command
                      : _guard(() => command.labelWith(args), command.label)),
              command: entry.command,
              registered: command != null,
              enabled: command != null &&
                  _guard(() => command.isEnabledWith(args), false),
              checked: command == null
                  ? null
                  : _guard(() => command.isCheckedWith(args), null),
              shortcut: command?.shortcut?.label(),
            ));
        }
      }
    }

    walk(menus, const <String>[]);
    return rows;
  }

  /// A state getter that throws reads as [fallback]: a menu must build even
  /// when one command's `enabled` has a bug.
  static T _guard<T>(T Function() read, T fallback) {
    try {
      return read();
    } on Object {
      return fallback;
    }
  }
}
