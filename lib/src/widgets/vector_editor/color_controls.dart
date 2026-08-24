/// Color palette swatches and color selection controls.
library;

import '../../gestures/tap.dart';
import '../../graphics/color.dart';
import '../../layout/edge_insets.dart';
import '../../layout/render_flex.dart';
import '../../platform/input_events.dart';
import '../basic.dart';
import '../controls.dart' show Tooltip;
import '../gesture_detector.dart';
import '../proxy.dart';
import '../theme.dart';
import '../widget.dart';

/// Predefined standard palette colours (classic CorelDRAW default palette).
const List<Color> kStandardPalette = [
  Color(0xFF000000), // Black
  Color(0xFF424242), // Dark Grey
  Color(0xFF757575), // Grey
  Color(0xFFBDBDBD), // Light Grey
  Color(0xFFEEEEEE), // Very Light Grey
  Color(0xFFFFFFFF), // White
  Color(0xFFD32F2F), // Red
  Color(0xFFE91E63), // Pink
  Color(0xFF9C27B0), // Purple
  Color(0xFF673AB7), // Deep Purple
  Color(0xFF3F51B5), // Indigo
  Color(0xFF2196F3), // Blue
  Color(0xFF03A9F4), // Light Blue
  Color(0xFF00BCD4), // Cyan
  Color(0xFF009688), // Teal
  Color(0xFF4CAF50), // Green
  Color(0xFF8BC34A), // Light Green
  Color(0xFFCDDC39), // Lime
  Color(0xFFFFEB3B), // Yellow
  Color(0xFFFFC107), // Amber
  Color(0xFFFF9800), // Orange
  Color(0xFFFF5722), // Deep Orange
  Color(0xFF795548), // Brown
];

/// Horizontal swatch palette bar widget placed at the bottom of the editor.
///
/// The two buttons are the two a real editor binds: **left-click fills, right
/// click strokes**. sK1 does exactly this, and so does CorelDRAW; a palette
/// that only filled would make setting an outline colour a trip through a
/// dialog.
class ColorPaletteBar extends StatelessWidget {
  const ColorPaletteBar({
    super.key,
    this.palette = kStandardPalette,
    this.onColorSelected,
    this.onStrokeColorSelected,
    this.swatchSize = 20.0,
    this.height,
  });

  final List<Color> palette;

  /// Left click: apply as fill. `null` colour means "no fill".
  final void Function(Color? color)? onColorSelected;

  /// Right click: apply as stroke. `null` colour means "no stroke".
  final void Function(Color? color)? onStrokeColorSelected;

  final double swatchSize;

  /// Overall bar height; defaults to the swatch plus padding.
  final double? height;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.surfaceAlternate,
        border: BoxBorder(color: theme.border, width: 1),
      ),
      child: SizedBox(
        height: height ?? swatchSize + 8,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: <Widget>[
              _ColorSwatch(
                color: null,
                size: swatchSize,
                tooltip: 'Empty pattern - click to clear the fill, '
                    'right-click to clear the outline',
                onFill: () => onColorSelected?.call(null),
                onStroke: () => onStrokeColorSelected?.call(null),
              ),
              const SizedBox(width: 6),
              for (final color in palette)
                _ColorSwatch(
                  color: color,
                  size: swatchSize,
                  tooltip: _describe(color),
                  onFill: () => onColorSelected?.call(color),
                  onStroke: () => onStrokeColorSelected?.call(color),
                ),
            ],
          ),
        ),
      ),
    );
  }

  static String _describe(Color color) {
    final hex = color.value.toRadixString(16).padLeft(8, '0').substring(2);
    return '#${hex.toUpperCase()} - click to fill, right-click to outline';
  }
}

class _ColorSwatch extends StatelessWidget {
  const _ColorSwatch({
    required this.color,
    required this.size,
    required this.tooltip,
    this.onFill,
    this.onStroke,
  });

  /// `null` is the "no colour" cell.
  final Color? color;
  final double size;
  final String tooltip;
  final void Function()? onFill;
  final void Function()? onStroke;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final swatch = color;
    return Tooltip(
      message: tooltip,
      child: GestureDetector(
        behavior: GestureHitTestBehavior.opaque,
        onTapUp: (TapDetails details) {
          if (details.button == PointerButton.secondary) {
            onStroke?.call();
          } else {
            onFill?.call();
          }
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 1),
          child: SizedBox(
            width: size,
            height: size,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: swatch ?? const Color(0xFFFFFFFF),
                border: BoxBorder(color: theme.border, width: 1),
              ),
              child: swatch == null
                  ? const Center(
                      child: Text('x', color: Color(0xFFD32F2F), fontSize: 11),
                    )
                  : null,
            ),
          ),
        ),
      ),
    );
  }
}
