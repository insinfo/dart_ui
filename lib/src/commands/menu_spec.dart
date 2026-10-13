/// Menus described by command id: data, with no widget in it.
///
/// Where a command appears is a separate decision from what it does - the
/// way VS Code keeps a menu registry apart from its command registry - so a
/// menu bar, a context menu, an automation client listing the menus and a
/// parity count all read the same description. Turning one into widgets is
/// `MenuBuilder`'s job, in the widget layer.
library;

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
///
/// [id] names it for whatever draws it - an icon lookup, a test - since a
/// submenu runs no command of its own.
final class SubmenuSpec extends MenuSpecEntry {
  const SubmenuSpec(this.label, this.children, {this.id});

  final String label;
  final List<MenuSpecEntry> children;
  final String? id;
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

/// Every command row under [menus], depth first, with its path and its
/// state in [registry].
List<MenuRow> flattenMenus(
  CommandRegistry registry,
  List<MenuSpecEntry> menus,
) {
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
                    : guardCommandState(
                        () => command.labelWith(args), command.label)),
            command: entry.command,
            registered: command != null,
            enabled: command != null &&
                guardCommandState(() => command.isEnabledWith(args), false),
            checked: command == null
                ? null
                : guardCommandState(() => command.isCheckedWith(args), null),
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
T guardCommandState<T>(T Function() read, T fallback) {
  try {
    return read();
  } on Object {
    return fallback;
  }
}
