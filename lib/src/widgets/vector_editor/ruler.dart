/// Horizontal and vertical interactive measurement rulers.
///
/// A ruler shows the *document*, so it is given the same `zoom` and `pan` the
/// canvas is given and nothing else: no ruler ever computes a scale of its own,
/// which is the only way the tick under a shape's left edge can be trusted.
library;

import '../../geometry/offset.dart';
import '../../geometry/rect.dart';
import '../../geometry/size.dart';
import '../../graphics/color.dart';
import '../../graphics/display_list.dart';
import '../../graphics/display_list_geometry.dart';
import '../../graphics/vector/constants.dart';
import '../../layout/render_box.dart';
import '../../rendering/text/font_registry.dart';
import '../../rendering/text/text_painter.dart';
import '../../text/typeface.dart';
import '../element.dart';
import '../theme.dart';
import '../widget.dart';

/// How a ruler is painted, in tokens.
///
/// Two tick colours rather than one, because a ruler with a single tick colour
/// is a picket fence: the minor ticks are five times as numerous as the major
/// ones, and drawing them all at full strength buries the numbers they are
/// there to subdivide. Major ticks are [ThemeData.borderStrong] - a graphic
/// mark with meaning, which is the 3:1 contrast class - and the minors drop to
/// [ThemeData.border].
final class RulerColors {
  const RulerColors({
    required this.background,
    required this.border,
    required this.tick,
    required this.minorTick,
    required this.label,
    required this.cursor,
  });

  factory RulerColors.fromTheme(ThemeData theme) => RulerColors(
        background: theme.surfaceAlternate,
        border: theme.border,
        tick: theme.borderStrong,
        minorTick: theme.border,
        label: theme.foregroundSecondary,
        cursor: theme.accent,
      );

  final Color background;
  final Color border;

  /// A labelled tick.
  final Color tick;

  /// The four unlabelled ticks between two labelled ones.
  final Color minorTick;

  final Color label;
  final Color cursor;
}

/// Interactive ruler widget.
final class RulerWidget extends RenderObjectWidget {
  const RulerWidget({
    super.key,
    this.isVertical = false,
    this.zoom = 1.0,
    this.pan = 0.0,
    this.unit = DocUnit.mm,
    this.cursorPosition,
    this.rulerThickness = 18.0,
    this.colors,
    this.labelSize,
  });

  final bool isVertical;

  /// Device pixels per document point.
  final double zoom;

  /// Where document zero sits along this axis, in device pixels, measured from
  /// the ruler's own leading edge.
  final double pan;

  final DocUnit unit;

  /// The cursor along this axis, in **device pixels** from the leading edge.
  final double? cursorPosition;

  final double rulerThickness;

  final RulerColors? colors;

  /// The pixel size the numbers are drawn at, or null for the theme's
  /// [TextTheme.labelSmall] - the role the design system gives to captions and
  /// metadata, which is what a ruler number is.
  final double? labelSize;

  @override
  RenderObjectElement createElement() => RenderObjectElement(this);

  @override
  RenderRuler createRenderObject(BuildContext context) => RenderRuler(
        isVertical: isVertical,
        zoom: zoom,
        pan: pan,
        unit: unit,
        cursorPosition: cursorPosition,
        rulerThickness: rulerThickness,
        colors: colors ?? RulerColors.fromTheme(Theme.of(context)),
        labelSize: labelSize ?? _labelSizeOf(context),
      );

  @override
  void updateRenderObject(
      BuildContext context, covariant RenderRuler renderObject) {
    renderObject
      ..isVertical = isVertical
      ..zoom = zoom
      ..pan = pan
      ..unit = unit
      ..cursorPosition = cursorPosition
      ..rulerThickness = rulerThickness
      ..colors = colors ?? RulerColors.fromTheme(Theme.of(context))
      ..labelSize = labelSize ?? _labelSizeOf(context);
  }

  static double _labelSizeOf(BuildContext context) =>
      Theme.of(context).textTheme.labelSmall.fontSize ??
      Theme.of(context).fontSize;
}

/// Render object that paints ticks, numbers, and tracking marker on a ruler.
final class RenderRuler extends RenderBox {
  RenderRuler({
    required bool isVertical,
    required double zoom,
    required double pan,
    required DocUnit unit,
    required double? cursorPosition,
    required double rulerThickness,
    required RulerColors colors,
    required double labelSize,
  })  : _isVertical = isVertical,
        _zoom = zoom,
        _pan = pan,
        _unit = unit,
        _cursorPosition = cursorPosition,
        _rulerThickness = rulerThickness,
        _colors = colors,
        _labelSize = labelSize;

  /// The tick spacings a ruler is willing to use, in whole units.
  ///
  /// Fixed rather than computed so that zooming walks a stable ladder: a ruler
  /// that solved for "about 60 pixels" would relabel itself on every pixel of
  /// zoom, and the numbers would flicker between 7 and 8.
  static const List<double> _steps = <double>[
    0.01,
    0.02,
    0.05,
    0.1,
    0.2,
    0.5,
    1,
    2,
    5,
    10,
    20,
    50,
    100,
    200,
    500,
    1000,
    2000,
    5000,
  ];

  /// The smallest gap, in device pixels, a labelled tick may have.
  ///
  /// A vertical ruler needs more, because its numbers are stacked one character
  /// under the next: "150" is three rows tall there and one column wide on the
  /// horizontal ruler, so the same gap would have the labels running into each
  /// other on one axis and swimming in space on the other.
  static const double _minimumLabelGap = 56.0;
  static const double _minimumVerticalLabelGap = 78.0;

  /// How much of the ruler's thickness a tick takes.
  ///
  /// A major tick that ran the whole thickness - which is what this drew - is
  /// a picket fence with the numbers written over the pickets. Both grow from
  /// the *inner* edge, the one the canvas is on, so the run of tick ends is a
  /// straight line against the document and the numbers have the outer half of
  /// the band to themselves.
  static const double _majorTickFraction = 0.45;
  static const double _minorTickFraction = 0.22;

  static final TextPainter _painter = TextPainter();

  bool _isVertical;
  set isVertical(bool value) {
    if (_isVertical == value) return;
    _isVertical = value;
    markNeedsLayout();
  }

  double _zoom;
  set zoom(double value) {
    if (_zoom == value) return;
    _zoom = value;
    markNeedsPaint();
  }

  double _pan;
  set pan(double value) {
    if (_pan == value) return;
    _pan = value;
    markNeedsPaint();
  }

  DocUnit _unit;
  set unit(DocUnit value) {
    if (_unit == value) return;
    _unit = value;
    markNeedsPaint();
  }

  double? _cursorPosition;
  set cursorPosition(double? value) {
    if (_cursorPosition == value) return;
    _cursorPosition = value;
    markNeedsPaint();
  }

  double _rulerThickness;
  set rulerThickness(double value) {
    if (_rulerThickness == value) return;
    _rulerThickness = value;
    markNeedsLayout();
  }

  RulerColors _colors;
  set colors(RulerColors value) {
    if (identical(_colors, value)) return;
    _colors = value;
    markNeedsPaint();
  }

  double _labelSize;
  set labelSize(double value) {
    if (_labelSize == value) return;
    _labelSize = value;
    markNeedsPaint();
  }

  /// The unit step this ruler labels at the current zoom.
  double get labelStep {
    final pixelsPerUnit = _unit.toPoints * (_zoom == 0 ? 1 : _zoom);
    final gap =
        _isVertical ? _minimumVerticalLabelGap : _minimumLabelGap;
    for (final step in _steps) {
      if (step * pixelsPerUnit >= gap) return step;
    }
    return _steps.last;
  }

  @override
  void performLayout() {
    if (_isVertical) {
      size = Size(
        _rulerThickness,
        constraints.hasBoundedHeight
            ? constraints.maxHeight
            : constraints.minHeight,
      );
    } else {
      size = Size(
        constraints.hasBoundedWidth
            ? constraints.maxWidth
            : constraints.minWidth,
        _rulerThickness,
      );
    }
  }

  @override
  void paint(DisplayList list, Offset offset) {
    final bgRect = Rect.fromLTWH(offset.dx, offset.dy, size.width, size.height);
    list.drawRectangle(
      bgRect,
      list.addPaint(colorArgb: _colors.background.value),
    );

    final borderPaint = list.addPaint(colorArgb: _colors.border.value);
    if (_isVertical) {
      list.drawRect(offset.dx + size.width - 1, offset.dy, offset.dx + size.width,
          offset.dy + size.height, borderPaint);
    } else {
      list.drawRect(offset.dx, offset.dy + size.height - 1,
          offset.dx + size.width, offset.dy + size.height, borderPaint);
    }

    final zoom = _zoom == 0 ? 1.0 : _zoom;
    final pixelsPerUnit = _unit.toPoints * zoom;
    if (pixelsPerUnit <= 0 || !pixelsPerUnit.isFinite) return;

    final major = labelStep;
    final minor = major / 5;
    final extent = _isVertical ? size.height : size.width;
    final tickPaint = list.addPaint(colorArgb: _colors.tick.value);
    final minorTickPaint = list.addPaint(colorArgb: _colors.minorTick.value);
    final labelPaint = list.addPaint(
      colorArgb: _colors.label.value,
      antiAlias: true,
    );
    final ScaledTypeface? face = FontRegistry.instance.uiFont(_labelSize);

    // Ticks grow from the inner edge - the one against the canvas - so their
    // ends line up with the document and the numbers keep the outer half.
    final double thickness = _isVertical ? size.width : size.height;
    final double majorLength = thickness * _majorTickFraction;
    final double minorLength = thickness * _minorTickFraction;

    // Walk in units, not pixels: the first labelled tick is the first multiple
    // of `major` at or before the left edge of the viewport.
    final firstUnit = ((-_pan / pixelsPerUnit) / minor).floor() * minor;
    final count = (extent / (minor * pixelsPerUnit)).ceil() + 2;
    // A ruler that has been panned a long way from the origin would otherwise
    // spin through millions of ticks; the clamp keeps one bad zoom from
    // freezing the window.
    final safeCount = count.clamp(0, 4000);

    for (var i = 0; i < safeCount; i++) {
      final unitValue = firstUnit + i * minor;
      final pixel = _pan + unitValue * pixelsPerUnit;
      if (pixel < -1 || pixel > extent + 1) continue;

      // Floating point makes "is this a multiple of major" a tolerance test.
      final isMajor = (unitValue / major - (unitValue / major).roundToDouble())
              .abs() <
          1e-6;
      final length = isMajor ? majorLength : minorLength;
      final paint = isMajor ? tickPaint : minorTickPaint;

      if (_isVertical) {
        list.drawRect(
          offset.dx + size.width - length,
          offset.dy + pixel,
          offset.dx + size.width,
          offset.dy + pixel + 1,
          paint,
        );
      } else {
        list.drawRect(
          offset.dx + pixel,
          offset.dy + size.height - length,
          offset.dx + pixel + 1,
          offset.dy + size.height,
          paint,
        );
      }

      if (!isMajor || face == null) continue;
      final label = _formatLabel(unitValue, major);
      // The baseline that puts the number's cap height against the outer edge
      // of the band, computed from the face rather than guessed: a hard-coded
      // baseline is only right for one font size, and the size now comes from
      // the theme.
      final double baseline = face.ascent + 1;
      if (_isVertical) {
        // A vertical ruler cannot rotate its text - the CPU rasterizer refuses
        // rotated glyph runs - so the number is stacked digit under digit,
        // which is also what several CAD rulers do.
        final double advance = (face.ascent + face.descent).roundToDouble();
        var y = offset.dy + pixel + 1;
        for (final char in label.split('')) {
          if (y > offset.dy + size.height - advance) break;
          _painter.paint(
            list,
            char,
            face,
            Offset(offset.dx + 2, y + baseline),
            labelPaint,
          );
          y += advance;
        }
      } else {
        _painter.paint(
          list,
          label,
          face,
          Offset(offset.dx + pixel + 3, offset.dy + baseline),
          labelPaint,
        );
      }
    }

    final cursor = _cursorPosition;
    if (cursor != null && cursor >= 0 && cursor <= extent) {
      final markerPaint = list.addPaint(colorArgb: _colors.cursor.value);
      if (_isVertical) {
        list.drawRect(offset.dx, offset.dy + cursor, offset.dx + size.width,
            offset.dy + cursor + 1.5, markerPaint);
      } else {
        list.drawRect(offset.dx + cursor, offset.dy, offset.dx + cursor + 1.5,
            offset.dy + size.height, markerPaint);
      }
    }
  }

  /// Formats [value] with just enough decimals for [step] to be distinguishable.
  static String _formatLabel(double value, double step) {
    final shown = value.abs() < 1e-9 ? 0.0 : value;
    if (step >= 1) return shown.round().toString();
    if (step >= 0.1) return shown.toStringAsFixed(1);
    return shown.toStringAsFixed(2);
  }
}
