/// The command bar's button: an icon, maybe a label, maybe a chevron - flat
/// until the pointer is over it, as in Windows 11.
library;

import 'package:dart_ui/dart_ui.dart';

/// A flat button that runs [command] through [registry], or calls [onTap].
class BarButton extends StatelessWidget {
  const BarButton({
    super.key,
    required this.icon,
    this.registry,
    this.command,
    this.params = const <String, Object?>{},
    this.label,
    this.tooltip,
    this.onTap,
    this.chevron = false,
    this.selected = false,
    this.iconColor,
    this.iconSize,
    this.compact = false,
  });

  final IconData icon;
  final CommandRegistry? registry;
  final String? command;
  final Map<String, Object?> params;

  /// Shown after the icon - "New", "Sort", "View".
  final String? label;
  final String? tooltip;
  final void Function()? onTap;

  /// A small chevron after the label: the button opens a menu.
  final bool chevron;
  final bool selected;
  final Color? iconColor;

  /// The glyph's size; null for the theme's.
  final double? iconSize;

  /// Tighter padding, for a button inside another control.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final CommandRegistry? commands = registry;
    final String? id = command;
    final bool enabled = onTap != null ||
        (commands != null &&
            id != null &&
            (commands[id]?.isEnabledWith(CommandArgs(params)) ?? false));
    final bool checked = selected ||
        (commands != null &&
            id != null &&
            (commands[id]?.isCheckedWith(CommandArgs(params)) ?? false));
    final String tip = tooltip ??
        (commands != null && id != null
            ? CommandIconButton.tooltipOf(commands, id, params: params)
            : label ?? '');
    final Color foreground =
        enabled ? theme.foreground : theme.disabledForeground;
    final Widget body = HoverBuilder(
      builder: (BuildContext context, bool hovered) => GestureDetector(
        behavior: GestureHitTestBehavior.opaque,
        onTap: !enabled ? null : onTap ?? () => commands!.execute(id!, params),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: checked
                ? theme.pressedSurface
                : hovered && enabled
                    ? theme.hoverSurface
                    : null,
            radius: theme.cornerRadius,
          ),
          child: Padding(
            padding: EdgeInsets.symmetric(
                horizontal: compact ? 6 : (label == null ? 10 : 8),
                vertical: compact ? 4 : 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: <Widget>[
                Icon(icon,
                    size: iconSize,
                    color: enabled
                        ? iconColor ?? theme.foreground
                        : theme.disabledForeground),
                if (label != null) ...<Widget>[
                  const SizedBox(width: 6),
                  // Files' command labels are a size under body text.
                  Text(label!,
                      style: theme.textTheme.bodyMedium.copyWith(fontSize: 12),
                      color: foreground),
                ],
                if (chevron) ...<Widget>[
                  const SizedBox(width: 6),
                  Icon(PhosphorIcons.caretDown,
                      size: theme.iconSize - 4, color: foreground),
                ],
              ],
            ),
          ),
        ),
      ),
    );
    return tip.isEmpty ? body : Tooltip(message: tip, child: body);
  }
}

/// A [BarButton] that opens [menu] below it.
class MenuBarButton extends StatelessWidget {
  const MenuBarButton({
    super.key,
    required this.icon,
    required this.menu,
    this.label,
    this.tooltip,
    this.chevron,
    this.enabled = true,
    this.iconSize,
  });

  final IconData icon;
  final List<Widget> Function() menu;

  /// Off greys the button out and keeps its menu shut - New where nothing
  /// can be made, as on Home or in search results.
  final bool enabled;
  final String? label;
  final String? tooltip;

  /// Whether a small chevron says the button opens a menu; by default when
  /// it has a label.
  final bool? chevron;

  /// The glyph's size; null for the theme's.
  final double? iconSize;

  @override
  Widget build(BuildContext context) => MenuAnchor(
        menuChildren: menu(),
        builder: (BuildContext context, MenuController controller, _) =>
            BarButton(
          icon: icon,
          iconSize: iconSize,
          label: label,
          tooltip: tooltip ?? label,
          chevron: chevron ?? label != null,
          selected: controller.isOpen,
          onTap: enabled
              ? () => controller.isOpen ? controller.close() : controller.open()
              : null,
        ),
      );
}
