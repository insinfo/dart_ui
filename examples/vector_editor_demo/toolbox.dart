/// The vertical tool box down the left edge, and the tools it offers.
library;

import 'package:dart_ui/dart_ui.dart';

import 'metrics.dart';

/// One entry in the tool box.
class ToolEntry {
  const ToolEntry({
    required this.mode,
    required this.icon,
    required this.label,
    this.shortcut,
  });

  final ToolMode mode;
  final IconData icon;
  final String label;
  final String? shortcut;

  String get tooltip => shortcut == null ? label : '$label ($shortcut)';
}

/// The tools, in sK1's `tools.py` order. `null` is a divider.
const List<ToolEntry?> kToolEntries = <ToolEntry?>[
  ToolEntry(
    mode: ToolMode.select,
    icon: PhosphorIcons.cursor,
    label: 'Selection mode',
    shortcut: 'Esc',
  ),
  ToolEntry(
    mode: ToolMode.shaper,
    icon: PhosphorIcons.penNib,
    label: 'Edit nodes',
    shortcut: 'Space',
  ),
  ToolEntry(
    mode: ToolMode.zoom,
    icon: PhosphorIcons.magnifyingGlass,
    label: 'Zoom mode',
    shortcut: 'F2',
  ),
  ToolEntry(
    mode: ToolMode.fleur,
    icon: PhosphorIcons.hand,
    label: 'Pan mode',
  ),
  null,
  ToolEntry(
    mode: ToolMode.curve,
    icon: PhosphorIcons.bezierCurve,
    label: 'Create curve',
  ),
  ToolEntry(
    mode: ToolMode.rectangle,
    icon: PhosphorIcons.square,
    label: 'Create rectangle',
  ),
  ToolEntry(
    mode: ToolMode.circle,
    icon: PhosphorIcons.circle,
    label: 'Create ellipse',
  ),
  ToolEntry(
    mode: ToolMode.polygon,
    icon: PhosphorIcons.polygon,
    label: 'Create polygon',
  ),
  ToolEntry(
    mode: ToolMode.text,
    icon: PhosphorIcons.textT,
    label: 'Create text',
    shortcut: 'F8',
  ),
];

/// The vertical tool palette.
class Toolbox extends StatelessWidget {
  const Toolbox({
    super.key,
    required this.activeTool,
    required this.onToolSelected,
    required this.fill,
    required this.stroke,
    this.onToolDoubleTapped,
  });

  final ToolMode activeTool;
  final void Function(ToolMode tool) onToolSelected;

  /// A second click on a tool's own icon.
  ///
  /// CorelDRAW and sK1 both bind double-clicking the pick tool to Select All,
  /// and it is the fastest route to it there is: the pointer is already in the
  /// tool box, and the alternative is Ctrl+A or two levels of menu.
  final void Function(ToolMode tool)? onToolDoubleTapped;

  /// The fill and outline indicator sK1 puts at the foot of the tool box.
  final FillDescriptor fill;
  final StrokeDescriptor stroke;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      width: ChromeMetrics.toolboxWidth,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: theme.surfaceAlternate,
          border: BoxBorder(color: theme.border, width: 1),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: <Widget>[
            const SizedBox(height: Spacing.xs),
            for (final entry in kToolEntries)
              if (entry == null)
                _ToolDivider(color: theme.border)
              else
                _ToolButton(
                  entry: entry,
                  selected: entry.mode == activeTool,
                  onTap: () => onToolSelected(entry.mode),
                  onDoubleTap: onToolDoubleTapped == null
                      ? null
                      : () => onToolDoubleTapped!(entry.mode),
                ),
            const Spacer(),
            _ColorIndicator(fill: fill, stroke: stroke),
            const SizedBox(height: Spacing.sm),
          ],
        ),
      ),
    );
  }
}

class _ToolButton extends StatelessWidget {
  const _ToolButton({
    required this.entry,
    required this.selected,
    required this.onTap,
    this.onDoubleTap,
  });

  final ToolEntry entry;
  final bool selected;
  final void Function() onTap;
  final void Function()? onDoubleTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Tooltip(
      message: entry.tooltip,
      child: GestureDetector(
        behavior: GestureHitTestBehavior.opaque,
        onTap: onTap,
        onDoubleTap:
            onDoubleTap == null ? null : (TapDetails _) => onDoubleTap!(),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 1),
          child: SizedBox(
            // An explicit box, because a tool button is a target: without it
            // the icon's own ink is the only clickable part.
            width: ChromeMetrics.toolboxButtonSize,
            height: ChromeMetrics.toolboxButtonSize,
            child: DecoratedBox(
              decoration: BoxDecoration(
                // A *wash* of the accent behind a glyph in the accent, not a
                // filled accent button. The design system is explicit about
                // this one: filling a selected toolbar button with `accent`
                // turns a tool palette into a column of primary buttons, and
                // "this tool is active" is a mark, not a call to action.
                color: selected ? theme.accentSubtle : null,
                radius: theme.cornerRadiusSmall,
              ),
              child: Center(
                child: Icon(
                  entry.icon,
                  size: ChromeMetrics.toolboxIconSize,
                  color: selected ? theme.accent : theme.foreground,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ToolDivider extends StatelessWidget {
  const _ToolDivider({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(
            horizontal: Spacing.sm, vertical: Spacing.xs),
        child: SizedBox(
          height: 1,
          width: ChromeMetrics.toolboxWidth - Spacing.sm * 2,
          child: ColoredBox(color: color),
        ),
      );
}

/// The two overlapping swatches sK1 shows at the bottom of the tool box.
class _ColorIndicator extends StatelessWidget {
  const _ColorIndicator({required this.fill, required this.stroke});

  final FillDescriptor fill;
  final StrokeDescriptor stroke;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Tooltip(
      message: 'Current fill and outline',
      child: SizedBox(
        width: ChromeMetrics.toolboxIconSize + Spacing.sm,
        height: ChromeMetrics.toolboxIconSize + Spacing.sm,
        child: Stack(
          children: <Widget>[
            Positioned(
              left: 0,
              top: 0,
              width: ChromeMetrics.toolboxIconSize,
              height: ChromeMetrics.toolboxIconSize,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: fill.isNone ? theme.surfaceAlternate : fill.color,
                  border: BoxBorder(color: theme.borderStrong, width: 1),
                  radius: theme.cornerRadiusSmall,
                ),
              ),
            ),
            Positioned(
              left: Spacing.sm,
              top: Spacing.sm,
              width: ChromeMetrics.toolboxIconSize,
              height: ChromeMetrics.toolboxIconSize,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: stroke.isNone || stroke.width <= 0
                      ? theme.surfaceAlternate
                      : stroke.color,
                  border: BoxBorder(color: theme.borderStrong, width: 1),
                  radius: theme.cornerRadiusSmall,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
