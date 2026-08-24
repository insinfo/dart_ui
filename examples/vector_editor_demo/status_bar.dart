/// The status bar - sK1's `statusbar.py`, in its left-to-right order.
///
/// Fields: cursor coordinates, zoom, snapping, page, the free-text message, and
/// the fill/outline monitor at the right.
library;

import 'package:dart_ui/dart_ui.dart';

import 'editor_model.dart';
import 'metrics.dart';

/// The bottom status bar.
class EditorStatusBar extends StatelessWidget {
  const EditorStatusBar({super.key, required this.model});

  final EditorModel model;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      height: ChromeMetrics.statusBarHeight,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: theme.surfaceAlternate,
          border: BoxBorder(color: theme.border, width: 1),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: Spacing.sm),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: <Widget>[
              _Section(
                icon: PhosphorIcons.cursor,
                text: _coordinates,
                width: 152,
                tooltip: 'Pointer position',
              ),
              _Section(
                icon: PhosphorIcons.magnifyingGlass,
                text: _zoom,
                width: 76,
                tooltip: 'Zoom level',
              ),
              _Section(
                icon: PhosphorIcons.gridFour,
                text: model.snapToGrid ? 'Snap' : 'No snap',
                width: 76,
                tooltip: 'Snapping to grid',
              ),
              _Section(
                icon: PhosphorIcons.fileText,
                text: _page,
                width: 116,
                tooltip: 'Current page',
              ),
              _Section(
                icon: PhosphorIcons.selection,
                text: _selection,
                width: 168,
                tooltip: 'Selection',
              ),
              Expanded(
                child: Text(
                  model.status,
                  // The status bar is the design system's own example of
                  // `labelSmall`: "legendas, barra de status, metadados". It
                  // was a bare 11, which happens to be the same number at a
                  // 13 px base and stops being so the moment the base moves.
                  style: theme.textTheme.labelSmall,
                  color: theme.foregroundSecondary,
                ),
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

  String get _zoom => model.hasDocument
      ? '${(model.active.zoom * 100).round()}%'
      : '--';

  String get _page {
    if (!model.hasDocument) return 'No page';
    final page = model.active.page;
    return '${page.name} (${page.pageFormat.name})';
  }

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
            Icon(icon,
                size: theme.iconSize, color: theme.foregroundSecondary),
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
    final fill = model.currentFill;
    final stroke = model.currentStroke;
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
