import '../../geometry/offset.dart';
import '../../graphics/color.dart';
import 'constants.dart';

// ---------------------------------------------------------------------------
// Gradient stop
// ---------------------------------------------------------------------------

/// A single stop in a gradient fill.
class GradientColorStop {
  const GradientColorStop(this.offset, this.color);

  /// Position along the gradient ramp, 0.0 → 1.0.
  final double offset;

  /// The colour at this position.
  final Color color;

  GradientColorStop copyWith({double? offset, Color? color}) =>
      GradientColorStop(offset ?? this.offset, color ?? this.color);

  @override
  String toString() => 'GradientColorStop($offset, $color)';
}

// ---------------------------------------------------------------------------
// Fill descriptor
// ---------------------------------------------------------------------------

/// Describes how the interior of a shape is painted.
class FillDescriptor {
  const FillDescriptor({
    this.fillType = FillType.none,
    this.fillRule = FillRule.evenOdd,
    this.color = const Color(0xFF000000),
    this.gradientStops = const [],
    this.gradientStart = Offset.zero,
    this.gradientEnd = const Offset(1, 0),
    this.gradientCenter = const Offset(0.5, 0.5),
    this.gradientRadius = 0.5,
    this.patternId,
  });

  /// Creates a solid fill with the given [color].
  const FillDescriptor.solid(this.color)
      : fillType = FillType.solid,
        fillRule = FillRule.evenOdd,
        gradientStops = const [],
        gradientStart = Offset.zero,
        gradientEnd = const Offset(1, 0),
        gradientCenter = const Offset(0.5, 0.5),
        gradientRadius = 0.5,
        patternId = null;

  /// No fill.
  static const FillDescriptor none = FillDescriptor();

  final FillType fillType;
  final FillRule fillRule;

  // Solid
  final Color color;

  // Gradient
  final List<GradientColorStop> gradientStops;
  final Offset gradientStart;
  final Offset gradientEnd;
  final Offset gradientCenter;
  final double gradientRadius;

  // Pattern
  final String? patternId;

  bool get isNone => fillType == FillType.none;
  bool get isSolid => fillType == FillType.solid;
  bool get isGradient =>
      fillType == FillType.linearGradient ||
      fillType == FillType.radialGradient ||
      fillType == FillType.conicalGradient;

  FillDescriptor copyWith({
    FillType? fillType,
    FillRule? fillRule,
    Color? color,
    List<GradientColorStop>? gradientStops,
    Offset? gradientStart,
    Offset? gradientEnd,
    Offset? gradientCenter,
    double? gradientRadius,
    String? patternId,
  }) =>
      FillDescriptor(
        fillType: fillType ?? this.fillType,
        fillRule: fillRule ?? this.fillRule,
        color: color ?? this.color,
        gradientStops: gradientStops ?? this.gradientStops,
        gradientStart: gradientStart ?? this.gradientStart,
        gradientEnd: gradientEnd ?? this.gradientEnd,
        gradientCenter: gradientCenter ?? this.gradientCenter,
        gradientRadius: gradientRadius ?? this.gradientRadius,
        patternId: patternId ?? this.patternId,
      );

  @override
  String toString() {
    switch (fillType) {
      case FillType.none:
        return 'FillDescriptor.none';
      case FillType.solid:
        return 'FillDescriptor.solid($color)';
      default:
        return 'FillDescriptor($fillType, ${gradientStops.length} stops)';
    }
  }
}

// ---------------------------------------------------------------------------
// Stroke descriptor
// ---------------------------------------------------------------------------

/// Describes how the outline of a shape is painted.
class StrokeDescriptor {
  const StrokeDescriptor({
    this.color = const Color(0xFF000000),
    this.width = 1.0,
    this.cap = LineCap.butt,
    this.join = LineJoin.miter,
    this.miterLimit = 4.0,
    this.dashPattern = const [],
    this.dashOffset = 0.0,
    this.scalableStroke = false,
    this.startArrow,
    this.endArrow,
  });

  /// No stroke.
  static const StrokeDescriptor none = StrokeDescriptor(width: 0.0);

  final Color color;
  final double width;
  final LineCap cap;
  final LineJoin join;
  final double miterLimit;
  final List<double> dashPattern;
  final double dashOffset;

  /// If true, the stroke width scales with the object's transform.
  final bool scalableStroke;

  /// Arrow marker index for the start of open paths.
  final int? startArrow;

  /// Arrow marker index for the end of open paths.
  final int? endArrow;

  bool get isNone => width <= 0.0;

  StrokeDescriptor copyWith({
    Color? color,
    double? width,
    LineCap? cap,
    LineJoin? join,
    double? miterLimit,
    List<double>? dashPattern,
    double? dashOffset,
    bool? scalableStroke,
    int? startArrow,
    int? endArrow,
  }) =>
      StrokeDescriptor(
        color: color ?? this.color,
        width: width ?? this.width,
        cap: cap ?? this.cap,
        join: join ?? this.join,
        miterLimit: miterLimit ?? this.miterLimit,
        dashPattern: dashPattern ?? this.dashPattern,
        dashOffset: dashOffset ?? this.dashOffset,
        scalableStroke: scalableStroke ?? this.scalableStroke,
        startArrow: startArrow ?? this.startArrow,
        endArrow: endArrow ?? this.endArrow,
      );

  @override
  String toString() =>
      isNone ? 'StrokeDescriptor.none' : 'StrokeDescriptor($color, w=$width)';
}

// ---------------------------------------------------------------------------
// Text style
// ---------------------------------------------------------------------------

/// Text formatting properties for [VectorText] objects.
class TextStyleDescriptor {
  const TextStyleDescriptor({
    this.fontFamily = 'Sans',
    this.fontSize = 12.0,
    this.bold = false,
    this.italic = false,
    this.alignment = TextAlign.left,
    this.lineSpacing = 1.2,
    this.wordSpacing = 0.0,
    this.charSpacing = 0.0,
  });

  final String fontFamily;
  final double fontSize;
  final bool bold;
  final bool italic;
  final TextAlign alignment;
  final double lineSpacing;
  final double wordSpacing;
  final double charSpacing;

  TextStyleDescriptor copyWith({
    String? fontFamily,
    double? fontSize,
    bool? bold,
    bool? italic,
    TextAlign? alignment,
    double? lineSpacing,
    double? wordSpacing,
    double? charSpacing,
  }) =>
      TextStyleDescriptor(
        fontFamily: fontFamily ?? this.fontFamily,
        fontSize: fontSize ?? this.fontSize,
        bold: bold ?? this.bold,
        italic: italic ?? this.italic,
        alignment: alignment ?? this.alignment,
        lineSpacing: lineSpacing ?? this.lineSpacing,
        wordSpacing: wordSpacing ?? this.wordSpacing,
        charSpacing: charSpacing ?? this.charSpacing,
      );

  @override
  String toString() =>
      'TextStyleDescriptor($fontFamily ${fontSize}pt${bold ? " bold" : ""}${italic ? " italic" : ""})';
}

// ---------------------------------------------------------------------------
// Composite style
// ---------------------------------------------------------------------------

/// Bundles fill, stroke, and text style for a vector object.
///
/// Mirrors the SK2 four-element style list `[fill, stroke, text_style, extras]`.
class VectorStyle {
  const VectorStyle({
    this.fill = FillDescriptor.none,
    this.stroke = StrokeDescriptor.none,
    this.textStyle = const TextStyleDescriptor(),
  });

  /// Default style: no fill, no stroke.
  static const VectorStyle empty = VectorStyle();

  /// A useful default: black fill, no stroke.
  static const VectorStyle defaultFill = VectorStyle(
    fill: FillDescriptor.solid(Color(0xFF000000)),
  );

  /// A useful default: no fill, black 1pt stroke.
  static const VectorStyle defaultStroke = VectorStyle(
    stroke: StrokeDescriptor(),
  );

  final FillDescriptor fill;
  final StrokeDescriptor stroke;
  final TextStyleDescriptor textStyle;

  VectorStyle copyWith({
    FillDescriptor? fill,
    StrokeDescriptor? stroke,
    TextStyleDescriptor? textStyle,
  }) =>
      VectorStyle(
        fill: fill ?? this.fill,
        stroke: stroke ?? this.stroke,
        textStyle: textStyle ?? this.textStyle,
      );

  @override
  String toString() => 'VectorStyle(fill=$fill, stroke=$stroke)';
}
