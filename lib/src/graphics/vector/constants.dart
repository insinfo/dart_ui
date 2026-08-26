import '../../geometry/offset.dart';
import '../../geometry/rect.dart';

/// Measurement units supported by vector documents.
enum DocUnit {
  /// Millimetres.
  mm('mm', 2.834645669291339),

  /// Centimetres.
  cm('cm', 28.34645669291339),

  /// Inches.
  inch('in', 72.0),

  /// Points (1/72 inch) — internal coordinate unit.
  pt('pt', 1.0),

  /// Pixels (at 96 dpi).
  px('px', 0.75);

  const DocUnit(this.label, this.toPoints);

  /// Human-readable label.
  final String label;

  /// Multiplication factor to convert one unit into points.
  final double toPoints;
}

/// Convert [value] from [unit] into points.
double toPoints(double value, DocUnit unit) => value * unit.toPoints;

/// Convert [value] from points into [unit].
double fromPoints(double value, DocUnit unit) => value / unit.toPoints;

/// Convenience for millimetres → points (the most common conversion).
double mmToPt(double mm) => mm * DocUnit.mm.toPoints;

/// Convenience for points → millimetres.
double ptToMm(double pt) => pt / DocUnit.mm.toPoints;

enum PageOrientation { portrait, landscape }

/// A named, standard page size.
class PageSize {
  const PageSize(this.name, this.width, this.height);
  final String name;
  final double width; // points
  final double height; // points

  /// Returns the dimensions in the requested [orientation].
  (double, double) inOrientation(PageOrientation orientation) {
    if (orientation == PageOrientation.landscape) return (height, width);
    return (width, height);
  }

  @override
  String toString() => 'PageSize($name, ${width}x$height pt)';
}

/// Predefined page sizes.
abstract final class PageFormats {
  static const a0 = PageSize('A0', 2383.937, 3370.394);
  static const a1 = PageSize('A1', 1683.780, 2383.937);
  static const a2 = PageSize('A2', 1190.551, 1683.780);
  static const a3 = PageSize('A3', 841.890, 1190.551);
  static const a4 = PageSize('A4', 595.276, 841.890);
  static const a5 = PageSize('A5', 419.528, 595.276);
  static const a6 = PageSize('A6', 297.638, 419.528);
  static const b4 = PageSize('B4', 708.661, 1000.630);
  static const b5 = PageSize('B5', 498.898, 708.661);
  static const letter = PageSize('Letter', 612.0, 792.0);
  static const legal = PageSize('Legal', 612.0, 1008.0);
  static const tabloid = PageSize('Tabloid', 792.0, 1224.0);
  static const executive = PageSize('Executive', 521.86, 756.0);

  static const List<PageSize> all = [
    a0,
    a1,
    a2,
    a3,
    a4,
    a5,
    a6,
    b4,
    b5,
    letter,
    legal,
    tabloid,
    executive,
  ];

  /// Look up by name (case-insensitive).
  static PageSize? byName(String name) {
    final lower = name.toLowerCase();
    for (final f in all) {
      if (f.name.toLowerCase() == lower) return f;
    }
    return null;
  }
}

// ---------------------------------------------------------------------------
// Document origin
// ---------------------------------------------------------------------------

/// Where (0, 0) lives in the document coordinate system.
enum DocOrigin {
  /// Lower-left corner (PostScript convention).
  lowerLeft,

  /// Lower-right corner.
  lowerRight,

  /// Upper-left corner (screen convention).
  upperLeft,

  /// Center of the page.
  center,
}

// ---------------------------------------------------------------------------
// Fill
// ---------------------------------------------------------------------------

/// How a filled region is determined when sub-paths cross.
enum FillRule {
  evenOdd,
  nonZero,
}

/// The kind of fill content.
enum FillType {
  /// No fill.
  none,

  /// Solid colour.
  solid,

  /// Linear gradient.
  linearGradient,

  /// Radial gradient.
  radialGradient,

  /// Conical (sweep) gradient.
  conicalGradient,

  /// Bitmap/vector pattern tile.
  pattern,
}

// ---------------------------------------------------------------------------
// Stroke
// ---------------------------------------------------------------------------

/// Line cap style.
enum LineCap { butt, round, square }

/// Line join style.
enum LineJoin { miter, round, bevel }

// ---------------------------------------------------------------------------
// Arc / circle types
// ---------------------------------------------------------------------------

/// Type of arc for circle/ellipse primitives.
enum ArcType {
  /// Open arc (no connecting line back to centre).
  arc,

  /// Chord: straight line connecting the endpoints.
  chord,

  /// Pie slice (lines from endpoints to centre).
  pieslice,
}

// ---------------------------------------------------------------------------
// Curve node markers
// ---------------------------------------------------------------------------

/// Smoothness constraint at a Bézier node.
enum NodeType {
  /// No constraint; handles are independent.
  cusp,

  /// Handles are collinear (smooth transition).
  smooth,

  /// Handles are collinear and equal length.
  symmetrical,
}

/// Whether a path is open or closed.
enum PathClosure { opened, closed }

// ---------------------------------------------------------------------------
// Text alignment
// ---------------------------------------------------------------------------

/// Horizontal text alignment.
enum TextAlign { left, center, right, justify }

// ---------------------------------------------------------------------------
// Z-order placement
// ---------------------------------------------------------------------------

/// Where a new object is placed relative to an existing one.
enum Placement { before, after }

/// Vertical ordering.
enum ZOrder { lower, upper }

// ---------------------------------------------------------------------------
// Stub geometry constants (matching sk2const defaults)
// ---------------------------------------------------------------------------

/// A unit-trafo `[1, 0, 0, 1, 0, 0]` as a `List<double>`.
const List<double> kNormalTrafo = [1.0, 0.0, 0.0, 1.0, 0.0, 0.0];

/// Default empty style list `[[], [], [], []]`.
const List<List<Object>> kEmptyStyle = [[], [], [], []];

/// A stub rectangle `[0, 0, 1, 1]`.
const List<double> kStubRect = [0.0, 0.0, 1.0, 1.0];

/// Default corners for a rectangle: `[0.0, 0.0, 0.0, 0.0]`.
const List<double> kCorners = [0.0, 0.0, 0.0, 0.0];

/// Default text-block width (−1 means "artistic" / single-line).
const double kTextBlockWidth = -1.0;

/// Default polygon corner count.
const int kDefaultPolygonNum = 5;

/// Standard stub path (a unit line from origin to (1,0)).
final List<List<Object>> kStubPaths = [
  [
    const Offset(0, 0),
    [const Offset(1, 0)],
    PathClosure.opened,
  ],
];

// ---------------------------------------------------------------------------
// Default colours
// ---------------------------------------------------------------------------

/// Default page background (white).
const List<double> kDefaultPageBg = [1.0, 1.0, 1.0];

/// Default desktop background (light grey).
const List<double> kDefaultDesktopBg = [0.83, 0.83, 0.83];

/// Default layer colour (blue, used in contour view).
const int kDefaultLayerColor = 0xFF0000FF;

/// Default guide colour (cyan).
const int kDefaultGuideColor = 0xFF00FFFF;

/// Default grid colour (light grey).
const int kDefaultGridColor = 0xFFCCCCCC;

// ---------------------------------------------------------------------------
// Page format helper
// ---------------------------------------------------------------------------

/// A complete page format descriptor.
class PageFormat {
  const PageFormat({
    required this.size,
    this.orientation = PageOrientation.portrait,
  });

  /// Creates the default page format (A4 portrait).
  const PageFormat.a4Portrait()
      : size = PageFormats.a4,
        orientation = PageOrientation.portrait;

  /// Creates A4 landscape.
  const PageFormat.a4Landscape()
      : size = PageFormats.a4,
        orientation = PageOrientation.landscape;

  /// Creates Letter portrait.
  const PageFormat.letterPortrait()
      : size = PageFormats.letter,
        orientation = PageOrientation.portrait;

  final PageSize size;
  final PageOrientation orientation;

  /// Name of the page format.
  String get name => size.name;

  /// Effective width in points.
  double get width {
    final (w, _) = size.inOrientation(orientation);
    return w;
  }

  /// Effective height in points.
  double get height {
    final (_, h) = size.inOrientation(orientation);
    return h;
  }

  /// Bounding rect starting at origin.
  Rect get rect => Rect.fromLTWH(0, 0, width, height);

  PageFormat copyWith({PageSize? size, PageOrientation? orientation}) =>
      PageFormat(
        size: size ?? this.size,
        orientation: orientation ?? this.orientation,
      );

  @override
  String toString() =>
      'PageFormat(${size.name}, $orientation, ${width.toStringAsFixed(1)}×${height.toStringAsFixed(1)} pt)';
}
