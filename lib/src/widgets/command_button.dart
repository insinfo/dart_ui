/// A toolbar button that is a command: what it is called, its shortcut,
/// whether it can run, why not, and whether it is on all come from the
/// [CommandRegistry], so a property bar cannot disagree with the menus.
library;

import '../commands/command.dart';
import '../commands/command_registry.dart';
import '../commands/menu_spec.dart' show guardCommandState;
import '../graphics/color.dart';
import '../layout/box_constraints.dart';
import '../layout/edge_insets.dart';
import 'basic.dart';
import 'gesture_detector.dart';
import 'icon.dart';
import 'icon_button.dart';
import 'proxy.dart';
import 'theme.dart';
import 'tooltip.dart';
import 'widget.dart';

/// An [IconButton] that runs [command] through [registry].
///
/// The tooltip is the command's label and shortcut when it can run, and
/// its label and the reason when it cannot - a greyed-out button that says
/// why, never one that silently does nothing. A toggle shows as selected
/// while it is on.
final class CommandIconButton extends StatelessWidget {
  const CommandIconButton({
    super.key,
    required this.registry,
    required this.command,
    required this.icon,
    this.params = const <String, Object?>{},
    this.label,
    this.iconSize = 14,
    this.padding = const EdgeInsets.all(4),
    this.minSize = 22,
  });

  final CommandRegistry registry;
  final String command;
  final IconData icon;

  /// What the button runs the command with.
  final Map<String, Object?> params;

  /// Replaces the command's own label in the tooltip.
  final String? label;

  final double iconSize;
  final EdgeInsets padding;
  final double minSize;

  /// The tooltip [CommandIconButton] shows for [command] with [params].
  static String tooltipOf(CommandRegistry registry, String command,
      {Map<String, Object?> params = const <String, Object?>{},
      String? label}) {
    final CommandSpec? spec = registry[command];
    if (spec == null) return label ?? command;
    final CommandArgs args = CommandArgs(params);
    final String name =
        label ?? guardCommandState(() => spec.labelWith(args), spec.label);
    final String? reason =
        guardCommandState(() => spec.disabledReasonWith(args), null);
    final bool enabled =
        guardCommandState(() => spec.isEnabledWith(args), false);
    if (!enabled) return reason == null ? name : '$name - $reason';
    final String? keys = spec.shortcut?.label();
    return keys == null ? name : '$name ($keys)';
  }

  @override
  Widget build(BuildContext context) {
    final CommandSpec? spec = registry[command];
    final CommandArgs args = CommandArgs(params);
    final bool enabled = spec != null &&
        guardCommandState(() => spec.isEnabledWith(args), false);
    final bool checked = spec != null &&
        (guardCommandState(() => spec.isCheckedWith(args), null) ?? false);
    return IconButton(
      icon: Icon(icon),
      iconSize: iconSize,
      isSelected: checked,
      padding: padding,
      constraints: BoxConstraints(minWidth: minSize, minHeight: minSize),
      tooltip: tooltipOf(registry, command, params: params, label: label),
      onPressed: enabled ? () => registry.execute(command, params) : null,
    );
  }
}

/// A text chip that runs [command] through [registry] - one of a set of
/// choices (a line cap, a fill rule) where a word says more than an icon.
///
/// Selected while the command reports itself checked with [params]; greyed
/// and inert, with the reason in its tooltip, while it cannot run.
final class CommandChip extends StatelessWidget {
  const CommandChip({
    super.key,
    required this.registry,
    required this.command,
    required this.label,
    this.params = const <String, Object?>{},
  });

  final CommandRegistry registry;
  final String command;
  final String label;
  final Map<String, Object?> params;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final CommandSpec? spec = registry[command];
    final CommandArgs args = CommandArgs(params);
    final bool enabled = spec != null &&
        guardCommandState(() => spec.isEnabledWith(args), false);
    final bool selected = spec != null &&
        (guardCommandState(() => spec.isCheckedWith(args), null) ?? false);
    final Color text = !enabled
        ? theme.disabledForeground
        : selected
            ? theme.accent
            : theme.foregroundSecondary;
    return Tooltip(
      message: CommandIconButton.tooltipOf(registry, command,
          params: params, label: label),
      child: GestureDetector(
        onTap: enabled ? () => registry.execute(command, params) : null,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: selected && enabled ? theme.accentSubtle : null,
              border: BoxBorder(
                color: selected && enabled ? theme.accent : theme.border,
                width: 1,
              ),
              radius: theme.cornerRadiusSmall,
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              child:
                  Text(label, style: theme.textTheme.labelSmall, color: text),
            ),
          ),
        ),
      ),
    );
  }
}
