/// The status bar - sK1's `statusbar.py`, in its left-to-right order.
///
/// Fields: cursor coordinates, zoom, snapping, page, the free-text message, and
/// the fill/outline monitor at the right.
library;

import 'package:dart_ui/dart_ui.dart';

import '../engine/editor_model.dart';
import 'metrics.dart';

/// The bottom status bar.
class EditorStatusBar extends StatelessWidget {
  const EditorStatusBar({super.key, required this.model});

  final EditorModel model;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      height: ChromeMetrics.of(Theme.of(context)).statusBarHeight,
      child: DecoratedBox(
        decoration: BoxDecoration(color: theme.surfaceBase),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: Spacing.sm),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: <Widget>[
              // What the next gesture would do, Graphite-style: the gesture
              // in a key cap, the action after it. Clipped, so a narrow
              // window loses hints rather than the readouts on the right.
              Expanded(
                child: ClipRect(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: <Widget>[
                      for (final (gesture, action) in model.hints) ...<Widget>[
                        _KeyCap(gesture),
                        const SizedBox(width: 4),
                        Text(
                          action,
                          style: theme.textTheme.labelSmall,
                          color: theme.foregroundSecondary,
                        ),
                        const SizedBox(width: 12),
                      ],
                      Expanded(
                        child: Text(
                          model.status,
                          style: theme.textTheme.labelSmall,
                          color: theme.disabledForeground,
                          maxLines: 1,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              _Section(
                icon: PhosphorIcons.selection,
                text: _selection,
                width: 150,
                tooltip: 'Selection',
              ),
              ValueListenableBuilder<Offset?>(
                valueListenable: model.pointer,
                builder: (BuildContext context, Offset? _, Widget? __) =>
                    _Section(
                  icon: PhosphorIcons.cursor,
                  text: _coordinates,
                  width: 140,
                  tooltip: 'Pointer position',
                ),
              ),
              _Section(
                icon: PhosphorIcons.magnifyingGlass,
                text: _zoom,
                width: 64,
                tooltip: 'Zoom level',
              ),
              _ColorMonitor(model: model),
            ],
          ),
        ),
      ),
    );
  }

  String get _coordinates {
    final cursor = model.cursor;
    if (cursor == null) return 'No coords';
    final unit = model.units;
    return '${fromPoints(cursor.dx, unit).toStringAsFixed(1)}, '
        '${fromPoints(cursor.dy, unit).toStringAsFixed(1)} ${unit.label}';
  }

  String get _zoom =>
      model.hasDocument ? '${(model.active.zoom * 100).round()}%' : '--';

  String get _selection {
    if (!model.hasDocument) return 'No document';
    final count = model.selection.count;
    if (count == 0) return 'No selection';
    final bounds = model.selection.selectionBounds;
    final unit = model.units;
    return '${fromPoints(bounds.width, unit).toStringAsFixed(0)} x '
        '${fromPoints(bounds.height, unit).toStringAsFixed(0)} ${unit.label}'
        '${count > 1 ? '  ($count objects)' : ''}';
  }
}

/// A gesture or key, drawn as a key cap.
class _KeyCap extends StatelessWidget {
  const _KeyCap(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.surfaceAlternate,
        border: BoxBorder(color: theme.border, width: 1),
        radius: 3,
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
        child: Text(
          label,
          style: theme.textTheme.labelSmall,
          color: theme.foreground,
        ),
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({
    required this.icon,
    required this.text,
    required this.width,
    required this.tooltip,
  });

  final IconData icon;
  final String text;
  final double width;
  final String tooltip;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Tooltip(
      message: tooltip,
      child: SizedBox(
        // A fixed width per section, so the message field does not slide left
        // and right as the coordinates gain and lose a digit.
        width: width,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: <Widget>[
            Icon(icon, size: theme.iconSize, color: theme.foregroundSecondary),
            const SizedBox(width: Spacing.xs),
            Expanded(
              child: Text(
                text,
                style: theme.textTheme.labelSmall,
                color: theme.foreground,
              ),
            ),
            SizedBox(
              width: 1,
              height: theme.iconSize,
              child: ColoredBox(color: theme.borderSubtle),
            ),
            const SizedBox(width: Spacing.sm),
          ],
        ),
      ),
    );
  }
}

/// The fill and outline swatches sK1 puts at the right of the status bar.
class _ColorMonitor extends StatelessWidget {
  const _ColorMonitor({required this.model});

  final EditorModel model;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fill = model.shownFill;
    final stroke = model.shownStroke;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: <Widget>[
        Text(
          'Fill:',
          style: theme.textTheme.labelSmall,
          color: theme.foregroundSecondary,
        ),
        const SizedBox(width: Spacing.xs),
        _Swatch(color: fill.isNone ? null : fill.color),
        const SizedBox(width: Spacing.md),
        Text(
          'Outline:',
          style: theme.textTheme.labelSmall,
          color: theme.foregroundSecondary,
        ),
        const SizedBox(width: Spacing.xs),
        _Swatch(
          color: stroke.isNone || stroke.width <= 0 ? null : stroke.color,
        ),
      ],
    );
  }
}

/// The fill or outline monitor's own chip.
///
/// One icon size square with the small radius, which is what the design system
/// gives a swatch: "check box, chip, swatch, botão de ícone". It was a 14 px
/// hard-cornered box with a 9 px red `x` in it - three numbers and a colour
/// that came from nowhere.
class _Swatch extends StatelessWidget {
  const _Swatch({required this.color});

  final Color? color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      width: theme.iconSize,
      height: theme.iconSize,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: color ?? theme.surfaceAlternate,
          border: BoxBorder(color: theme.borderStrong, width: 1),
          radius: theme.cornerRadiusSmall,
        ),
        child: color == null
            ? Center(
                child: Text(
                  'x',
                  style: theme.textTheme.labelSmall,
                  color: theme.colorScheme.error,
                ),
              )
            : null,
      ),
    );
  }
}
