/// 2D paths, stored as a verb stream plus a point stream.
///
/// The storage is the same decision the display list made and for the same
/// reason (section 6.5): a path is walked far more often than it is built -
/// once per frame per draw, and again by the filler for every scanline it
/// touches - so it is two typed arrays and an index, not a `List<PathCommand>`
/// of one object per segment. A hundred-segment icon costs two allocations
/// here and a hundred and one there, and the walk of the object list chases a
/// pointer per segment while this one is linear memory.
///
/// ## What is here and what is not
///
/// Lines, quadratic and cubic Beziers, and the three closed shapes a UI draws
/// constantly (rectangle, rounded rectangle, oval). Deliberately absent, and
/// absent in a way a caller finds by name rather than by a wrong picture:
///
///   * **Stroking.** There is no `PathBuilder.stroke`, no cap or join, and no
///     dashing. A stroke is a *different path* - the outline of the pen's
///     sweep - and computing it needs offset curves, joins and a self-
///     intersection cleanup pass that is larger than everything in this file.
///     Until that exists, a stroked shape is described by building its
///     outline explicitly.
///   * **Conics and arcs as verbs.** [PathBuilder.addOval],
///     [PathBuilder.addRoundedRect] and Flutter's [Path.arcTo] family
///     approximate their arcs with cubics of at most a quarter turn; the
///     radial error is about 0.027% of the radius - a hundredth of a pixel at
///     a 40 px radius, which is why it is acceptable and why it is written
///     down. A true conic (rational quadratic) section would be exact and
///     needs a fourth verb plus a weight stream; nothing here blocks adding
///     it.
///
/// Point-in-path testing ([Path.contains]) flattens the path and counts
/// crossings; it is for hit testing, not for anything per pixel.
///
/// ## Coordinates are float32
///
/// Points are stored in a [Float32List], like the display list's coordinate
/// stream. That caps precision at about seven decimal digits, which is far
/// more than a device pixel needs and is what keeps a large path in cache.
/// A path built at float64 precision and read back is therefore not always
/// bit-identical to what was written - which matters only for equality, and
/// is why equality compares the *stored* values.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'offset.dart';
import 'rect.dart';
import 'rrect.dart';
import 'transform2d.dart';

/// How the inside of a [Path] is decided: Flutter's `PathFillType`.
///
/// The same two rules as [FillRule], under Flutter's name, carried by the
/// path itself as Flutter carries it.
enum PathFillType {
  /// Inside where the winding number is not zero.
  nonZero,

  /// Inside where a ray crosses the outline an odd number of times.
  evenOdd,
}

/// Starts a new contour at the following point.
const int verbMoveTo = 0;

/// A straight segment from the current point to the following point.
const int verbLineTo = 1;

/// A quadratic Bezier: one control point then the end point.
const int verbQuadraticTo = 2;

/// A cubic Bezier: two control points then the end point.
const int verbCubicTo = 3;

/// Closes the current contour back to its starting point. Consumes no points.
const int verbClose = 4;

/// How many points [verb] consumes from the point stream.
int pointsPerVerb(int verb) => switch (verb) {
      verbMoveTo || verbLineTo => 1,
      verbQuadraticTo => 2,
      verbCubicTo => 3,
      verbClose => 0,
      _ => throw ArgumentError.value(verb, 'verb', 'not a path verb'),
    };

/// Maximum deviation, in the units the path is flattened into, between a
/// curve and the polyline that replaces it.
///
/// A quarter of a pixel. The unit matters: [Path.flattenTo] applies the
/// caller's transform to the control points *before* choosing a segment
/// count, so this is a quarter of a **device** pixel no matter how the path is
/// scaled - a path magnified ten times gets more segments rather than a
/// visibly faceted outline. A quarter pixel is below what the coverage
/// computation can express as a difference in alpha on all but the flattest
/// curves, and halving it doubles the segment count for no visible gain.
const double kDefaultFlattenTolerance = 0.25;

/// Upper bound on the segments one curve is flattened into.
///
/// A documented limit, not a safety net: a curve whose control points are
/// millions of pixels apart would otherwise ask for millions of segments and
/// stall the frame. Past this count the tolerance is no longer honoured, and
/// the deviation grows as the square of how far past it the curve is.
const int kMaxSegmentsPerCurve = 1024;

/// Receives a path that has been reduced to straight segments.
///
/// The flattening entry point takes a sink rather than returning a list so
/// that the scanline filler can turn curves straight into its own edge buffer
/// without a polyline existing in between. [Path.flatten] is that sink plus a
/// buffer, for callers who want the value.
abstract interface class PolylineSink {
  /// Starts a new contour at ([x], [y]).
  void moveTo(double x, double y);

  /// Extends the current contour to ([x], [y]).
  void lineTo(double x, double y);

  /// Closes the current contour back to its start point.
  void close();
}

/// A path in one coordinate space.
///
/// Two ways to build one, and they produce the same type:
///
///   * [PathBuilder], then [PathBuilder.build] - the framework's own route,
///     which never allocates per segment and hands back a path nobody else
///     holds;
///   * Flutter's: `Path()` and then [moveTo], [lineTo], [cubicTo], [arcTo],
///     [addRRect]... on the path itself. That is what a `CustomPainter` or a
///     `CustomClipper<Path>` written for Flutter does, and it works unchanged.
///
/// ## Mutable, with copy-on-write storage
///
/// The verb and point arrays are never written in place. An edit goes into a
/// private [PathBuilder] seeded from the current contents, and the next read
/// copies that builder out into fresh arrays. So a path returned by
/// [transform] or [shift], which shares its original's arrays, can never be
/// changed through the original - and a path someone keeps editing costs one
/// copy per *read after an edit*, not one per segment.
///
/// ## Equality is by content, and a mutable path must not change once used
///
/// `DisplayList.addPath` interns by `==` and [hashCode], which here compare
/// verbs, points and [fillType]. A path that is edited *after* it was handed
/// to a display list would change the picture already recorded and corrupt
/// the intern table, so `Canvas.drawPath` and the clip widgets record a
/// [Path.from] copy - the snapshot Flutter's own `drawPath` takes - and code
/// that calls `DisplayList.addPath` directly must not edit the path
/// afterwards. [Path.empty] is shared by everyone and refuses edits with a
/// [StateError].
///
/// ## Differences from Flutter
///
///   * [transform] takes a [Transform2D] or a 16-element column-major matrix
///     (`Matrix4.storage`); only the 2D affine part of the latter is used.
///   * [conicTo] is approximated by one cubic per call; exact for weight 1
///     and within a fraction of a percent for circular-arc weights.
///   * `combine`, `computeMetrics` and `addRSuperellipse` do not exist.
///   * [getBounds] is tight (curve extrema), not the control-point box.
final class Path {
  /// An empty path, ready to be edited - Flutter's `Path()`.
  Path() : this._(_noVerbs, _noPoints, Rect.zero, null);

  Path._(this._verbStore, this._pointStore, this._boundsCache, this._hashCache);

  /// A copy of [source] that can be edited without affecting it.
  factory Path.from(Path source) {
    final Path copy = Path._(
        source._verbs, source._points, source._boundsCache, source._hashCache);
    copy._fillType = source._fillType;
    return copy;
  }

  static final Uint8List _noVerbs = Uint8List(0);
  static final Float32List _noPoints = Float32List(0);

  /// A path with no contours. Fills to nothing and bounds to [Rect.zero].
  ///
  /// Shared, so it refuses edits: call `Path()` for one of your own.
  static final Path empty = PathBuilder().build().._frozen = true;

  /// One rectangle, wound clockwise in a y-down space.
  factory Path.rect(Rect rect) => (PathBuilder()..addRect(rect)).build();

  /// One ellipse inscribed in [rect], wound clockwise in a y-down space.
  factory Path.oval(Rect rect) => (PathBuilder()..addOval(rect)).build();

  Uint8List _verbStore;

  /// Interleaved `x, y` pairs, indexed by the running total of
  /// [pointsPerVerb] over the verbs before it.
  Float32List _pointStore;

  /// The builder an edit goes into; see the class comment.
  PathBuilder? _editor;

  /// Whether [_editor] holds edits the stored arrays do not have yet.
  bool _dirty = false;

  bool _frozen = false;

  Rect? _boundsCache;

  int? _hashCache;

  PathFillType _fillType = PathFillType.nonZero;

  Uint8List get _verbs {
    if (_dirty) _flush();
    return _verbStore;
  }

  Float32List get _points {
    if (_dirty) _flush();
    return _pointStore;
  }

  void _flush() {
    final PathBuilder editor = _editor!;
    _verbStore = Uint8List(editor._verbCount)
      ..setRange(0, editor._verbCount, editor._verbs);
    _pointStore = Float32List(editor._floatCount)
      ..setRange(0, editor._floatCount, editor._points);
    _dirty = false;
  }

  /// The builder an edit is written to, seeded from the current contents on
  /// the first edit and kept for the ones after it.
  PathBuilder _edit() {
    if (_frozen) {
      throw StateError(
          'Path.empty is shared by every caller and cannot be edited; '
          'create a path of your own with Path()');
    }
    final PathBuilder editor =
        _editor ??= PathBuilder().._seed(_verbStore, _pointStore);
    _dirty = true;
    _boundsCache = null;
    _hashCache = null;
    return editor;
  }

  /// How the inside of this path is decided when it is filled or clipped.
  ///
  /// The display list carries the fill rule on the *paint*, so this is read
  /// by `Canvas.drawPath` and the clip widgets, which copy it there. Code that
  /// calls `DisplayList.drawPath` directly chooses the rule on `addPaint`.
  PathFillType get fillType => _fillType;

  set fillType(PathFillType value) {
    if (value == _fillType) return;
    if (_frozen) _edit();
    _fillType = value;
    _hashCache = null;
  }

  /// Cached because it is asked for once per draw and changes only on edit.
  ///
  /// **Tight, not control-point bounds.** The extrema of each quadratic and
  /// cubic are solved per axis - a linear and a quadratic root respectively,
  /// a handful of flops per curve, paid once per edit. Control-point bounds
  /// would have been cheaper still and are what most implementations settle
  /// for, but they overstate a curved shape by up to a third of its size, and
  /// this rectangle is what decides whether a path is culled and how much of
  /// the surface a damage region covers.
  Rect get bounds => _boundsCache ??= _boundsOf(_verbs, _points);

  /// Flutter's name for [bounds].
  Rect getBounds() => bounds;

  /// Number of verbs. Zero for an empty path.
  int get verbCount => _verbs.length;

  /// Number of points across all verbs.
  int get pointCount => _points.length >> 1;

  bool get isEmpty => _verbs.isEmpty;

  int verbAt(int index) => _verbs[index];

  /// The x of the point at [index], counting points and not verbs.
  double pointX(int index) => _points[index * 2];

  double pointY(int index) => _points[index * 2 + 1];

  /// Allocates. For callers and tests that want a value; the walk in
  /// [flattenTo] reads [pointX] and [pointY] instead.
  Offset pointAt(int index) =>
      Offset(_points[index * 2], _points[index * 2 + 1]);

  /// This path mapped through [matrix]: a [Transform2D], or Flutter's
  /// 16-element column-major `Matrix4` storage, of which the 2D affine part
  /// (`[0] [1] [4] [5] [12] [13]`) is used.
  ///
  /// The verb stream is shared with the original rather than copied: it is
  /// never written in place, so the only thing two paths could disagree about
  /// is their points. Bounds are recomputed from the transformed geometry
  /// instead of transformed as a rectangle, because the bounding box of a
  /// rotated bounding box is strictly larger than the bounding box of the
  /// rotated shape, and the whole point of [bounds] is that it is tight.
  Path transform(Object matrix) {
    final Transform2D transform = _affineOf(matrix);
    if (transform.isIdentity) {
      // The framework's own callers pass a Transform2D and rely on getting
      // the same instance back for free. A Flutter caller passes a matrix and
      // may edit the result, which must then not be this path.
      return matrix is Transform2D ? this : Path.from(this);
    }
    final Uint8List verbs = _verbs;
    final Float32List source = _points;
    final points = Float32List(source.length);
    for (var i = 0; i < source.length; i += 2) {
      final x = source[i];
      final y = source[i + 1];
      points[i] = transform.a * x + transform.c * y + transform.tx;
      points[i + 1] = transform.b * x + transform.d * y + transform.ty;
    }
    return Path._(verbs, points, null, null).._fillType = _fillType;
  }

  /// This path translated by [offset].
  Path shift(Offset offset) =>
      transform(Transform2D.translation(offset.dx, offset.dy));

  static Transform2D _affineOf(Object matrix) {
    if (matrix is Transform2D) return matrix;
    if (matrix is List<double> && matrix.length == 16) {
      return Transform2D(
          matrix[0], matrix[1], matrix[4], matrix[5], matrix[12], matrix[13]);
    }
    throw ArgumentError.value(matrix, 'matrix',
        'must be a Transform2D or a 16-element column-major 4x4 matrix');
  }

  // -------------------------------------------------------------------------
  // Flutter's editing API
  // -------------------------------------------------------------------------

  /// The point the next segment starts from.
  Offset get _current =>
      _editor?._currentPoint ?? _endOf(_verbStore, _pointStore);

  static Offset _endOf(Uint8List verbs, Float32List points) {
    final PathBuilder probe = PathBuilder().._seed(verbs, points);
    return probe._currentPoint;
  }

  /// Starts a new contour at ([x], [y]).
  void moveTo(double x, double y) => _edit().moveTo(x, y);

  /// Starts a new contour offset by ([dx], [dy]) from the current point.
  void relativeMoveTo(double dx, double dy) {
    final Offset at = _current;
    _edit().moveTo(at.dx + dx, at.dy + dy);
  }

  /// A straight segment from the current point to ([x], [y]).
  void lineTo(double x, double y) => _edit().lineTo(x, y);

  void relativeLineTo(double dx, double dy) {
    final Offset at = _current;
    _edit().lineTo(at.dx + dx, at.dy + dy);
  }

  /// A quadratic Bezier through control point ([x1], [y1]) to ([x2], [y2]).
  void quadraticBezierTo(double x1, double y1, double x2, double y2) =>
      _edit().quadraticBezierTo(x1, y1, x2, y2);

  void relativeQuadraticBezierTo(double x1, double y1, double x2, double y2) {
    final Offset at = _current;
    _edit().quadraticBezierTo(at.dx + x1, at.dy + y1, at.dx + x2, at.dy + y2);
  }

  /// A cubic Bezier with two control points.
  void cubicTo(
    double x1,
    double y1,
    double x2,
    double y2,
    double x3,
    double y3,
  ) =>
      _edit().cubicTo(x1, y1, x2, y2, x3, y3);

  void relativeCubicTo(
    double x1,
    double y1,
    double x2,
    double y2,
    double x3,
    double y3,
  ) {
    final Offset at = _current;
    _edit().cubicTo(
        at.dx + x1, at.dy + y1, at.dx + x2, at.dy + y2, at.dx + x3, at.dy + y3);
  }

  /// A conic section of weight [w]. Weight 1 is exactly a quadratic; any
  /// other weight is approximated by one cubic (see the class comment).
  void conicTo(double x1, double y1, double x2, double y2, double w) {
    final Offset at = _current;
    _conic(at.dx, at.dy, x1, y1, x2, y2, w);
  }

  void relativeConicTo(double x1, double y1, double x2, double y2, double w) {
    final Offset at = _current;
    _conic(at.dx, at.dy, at.dx + x1, at.dy + y1, at.dx + x2, at.dy + y2, w);
  }

  void _conic(double x0, double y0, double x1, double y1, double x2, double y2,
      double w) {
    if (!(w > 0) || !w.isFinite) {
      // Weight 0 is a straight line; an infinite weight degenerates to the
      // two legs through the control point.
      if (w.isInfinite) {
        _edit()
          ..lineTo(x1, y1)
          ..lineTo(x2, y2);
      } else {
        _edit().lineTo(x2, y2);
      }
      return;
    }
    if (w == 1) {
      _edit().quadraticBezierTo(x1, y1, x2, y2);
      return;
    }
    final double k = 4 * w / (3 * (1 + w));
    _edit().cubicTo(
      x0 + (x1 - x0) * k,
      y0 + (y1 - y0) * k,
      x2 + (x1 - x2) * k,
      y2 + (y1 - y2) * k,
      x2,
      y2,
    );
  }

  /// An elliptical arc on the oval inscribed in [rect], from [startAngle]
  /// sweeping [sweepAngle] radians (positive is clockwise, y-down).
  ///
  /// With [forceMoveTo] the arc starts a new contour; otherwise a straight
  /// segment joins the current point to the arc's start.
  void arcTo(
    Rect rect,
    double startAngle,
    double sweepAngle,
    bool forceMoveTo,
  ) {
    final PathBuilder editor = _edit();
    final double rx = rect.width / 2;
    final double ry = rect.height / 2;
    final double cx = rect.left + rx;
    final double cy = rect.top + ry;
    final double sx = cx + rx * math.cos(startAngle);
    final double sy = cy + ry * math.sin(startAngle);
    if (forceMoveTo || editor._verbCount == 0) {
      editor.moveTo(sx, sy);
    } else {
      editor.lineTo(sx, sy);
    }
    _arcSegments(editor, cx, cy, rx, ry, 0, startAngle, sweepAngle);
  }

  /// An arc to [arcEnd], SVG-style: the ellipse of [radius] rotated by
  /// [rotation] degrees, choosing the [largeArc] and [clockwise] solution.
  void arcToPoint(
    Offset arcEnd, {
    Radius radius = Radius.zero,
    double rotation = 0.0,
    bool largeArc = false,
    bool clockwise = true,
  }) {
    final Offset start = _current;
    _svgArc(start, arcEnd, radius, rotation, largeArc, clockwise);
  }

  void relativeArcToPoint(
    Offset arcEndDelta, {
    Radius radius = Radius.zero,
    double rotation = 0.0,
    bool largeArc = false,
    bool clockwise = true,
  }) {
    final Offset start = _current;
    _svgArc(start, start + arcEndDelta, radius, rotation, largeArc, clockwise);
  }

  /// The endpoint-to-centre conversion of SVG 1.1, appendix F.6.5.
  void _svgArc(Offset from, Offset to, Radius radius, double rotationDegrees,
      bool largeArc, bool clockwise) {
    final PathBuilder editor = _edit();
    var rx = radius.x.abs();
    var ry = radius.y.abs();
    if (from == to) return;
    if (rx == 0 || ry == 0 || !rx.isFinite || !ry.isFinite) {
      editor.lineTo(to.dx, to.dy);
      return;
    }
    final double phi = rotationDegrees * math.pi / 180;
    final double cosPhi = math.cos(phi);
    final double sinPhi = math.sin(phi);
    final double dx2 = (from.dx - to.dx) / 2;
    final double dy2 = (from.dy - to.dy) / 2;
    final double x1p = cosPhi * dx2 + sinPhi * dy2;
    final double y1p = -sinPhi * dx2 + cosPhi * dy2;
    final double lambda = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry);
    if (lambda > 1) {
      final double s = math.sqrt(lambda);
      rx *= s;
      ry *= s;
    }
    final double num =
        rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p;
    final double den = rx * rx * y1p * y1p + ry * ry * x1p * x1p;
    var coef = den == 0 ? 0.0 : math.sqrt(math.max(0, num / den));
    if (largeArc == clockwise) coef = -coef;
    final double cxp = coef * rx * y1p / ry;
    final double cyp = -coef * ry * x1p / rx;
    final double cx = cosPhi * cxp - sinPhi * cyp + (from.dx + to.dx) / 2;
    final double cy = sinPhi * cxp + cosPhi * cyp + (from.dy + to.dy) / 2;
    double angle(double ux, double uy, double vx, double vy) {
      final double a = math.atan2(ux * vy - uy * vx, ux * vx + uy * vy);
      return a;
    }

    final double theta1 = angle(1, 0, (x1p - cxp) / rx, (y1p - cyp) / ry);
    var delta = angle((x1p - cxp) / rx, (y1p - cyp) / ry, (-x1p - cxp) / rx,
        (-y1p - cyp) / ry);
    if (clockwise && delta < 0) delta += 2 * math.pi;
    if (!clockwise && delta > 0) delta -= 2 * math.pi;
    _arcSegments(editor, cx, cy, rx, ry, phi, theta1, delta);
    // Land exactly on the requested end point, whatever rounding did.
    editor._replaceLastPoint(to.dx, to.dy);
  }

  /// Appends cubic segments for an elliptical arc, at most a quarter turn
  /// each - the usual bound that keeps the radial error under 0.03%.
  static void _arcSegments(PathBuilder editor, double cx, double cy, double rx,
      double ry, double phi, double start, double sweep) {
    if (sweep == 0 || !sweep.isFinite) return;
    final int segments = (sweep.abs() / (math.pi / 2)).ceil().clamp(1, 64);
    final double step = sweep / segments;
    final double k = 4 / 3 * math.tan(step / 4);
    final double cosPhi = math.cos(phi);
    final double sinPhi = math.sin(phi);
    double px(double ex, double ey) => cx + cosPhi * ex - sinPhi * ey;
    double py(double ex, double ey) => cy + sinPhi * ex + cosPhi * ey;
    var a0 = start;
    for (var i = 0; i < segments; i++) {
      final double a1 = a0 + step;
      final double c0 = math.cos(a0), s0 = math.sin(a0);
      final double c1 = math.cos(a1), s1 = math.sin(a1);
      final double e1x = rx * (c0 - k * s0), e1y = ry * (s0 + k * c0);
      final double e2x = rx * (c1 + k * s1), e2y = ry * (s1 - k * c1);
      final double e3x = rx * c1, e3y = ry * s1;
      editor.cubicTo(px(e1x, e1y), py(e1x, e1y), px(e2x, e2y), py(e2x, e2y),
          px(e3x, e3y), py(e3x, e3y));
      a0 = a1;
    }
  }

  /// Adds [rect] as a closed contour.
  void addRect(Rect rect) => _edit().addRect(rect);

  /// Adds the oval inscribed in [oval] as a closed contour.
  void addOval(Rect oval) => _edit().addOval(oval);

  /// Adds an arc of the oval inscribed in [oval] as a new open contour.
  void addArc(Rect oval, double startAngle, double sweepAngle) =>
      arcTo(oval, startAngle, sweepAngle, true);

  /// Adds the polygon through [points], closed if [close] is true.
  void addPolygon(List<Offset> points, bool close) {
    if (points.isEmpty) return;
    final PathBuilder editor = _edit();
    editor.moveTo(points.first.dx, points.first.dy);
    for (var i = 1; i < points.length; i++) {
      editor.lineTo(points[i].dx, points[i].dy);
    }
    if (close) editor.close();
  }

  /// Adds [rrect] as a closed contour. Radii that overrun a side are scaled
  /// down together, by the rule [RRect.scaleRadii] states.
  void addRRect(RRect rrect) => _edit().addRoundedRectPerCorner(
        rrect.outerRect,
        topLeftX: rrect.tlRadiusX,
        topLeftY: rrect.tlRadiusY,
        topRightX: rrect.trRadiusX,
        topRightY: rrect.trRadiusY,
        bottomRightX: rrect.brRadiusX,
        bottomRightY: rrect.brRadiusY,
        bottomLeftX: rrect.blRadiusX,
        bottomLeftY: rrect.blRadiusY,
      );

  /// Adds the contours of [path], shifted by [offset] (and first mapped
  /// through [matrix4] when given), as new contours.
  void addPath(Path path, Offset offset, {List<double>? matrix4}) =>
      _append(path, offset, matrix4, connect: false);

  /// Like [addPath], but the first contour of [path] continues the current
  /// one: its opening move becomes a line.
  void extendWithPath(Path path, Offset offset, {List<double>? matrix4}) =>
      _append(path, offset, matrix4, connect: true);

  void _append(Path path, Offset offset, List<double>? matrix4,
      {required bool connect}) {
    Path source = path;
    if (matrix4 != null) source = source.transform(matrix4);
    if (offset != Offset.zero) source = source.shift(offset);
    final Uint8List verbs = source._verbs;
    final Float32List pts = source._points;
    final PathBuilder editor = _edit();
    var p = 0;
    var first = true;
    for (var v = 0; v < verbs.length; v++) {
      switch (verbs[v]) {
        case verbMoveTo:
          if (first && connect && editor._verbCount > 0) {
            editor.lineTo(pts[p * 2], pts[p * 2 + 1]);
          } else {
            editor.moveTo(pts[p * 2], pts[p * 2 + 1]);
          }
          p += 1;
        case verbLineTo:
          editor.lineTo(pts[p * 2], pts[p * 2 + 1]);
          p += 1;
        case verbQuadraticTo:
          editor.quadraticBezierTo(
              pts[p * 2], pts[p * 2 + 1], pts[p * 2 + 2], pts[p * 2 + 3]);
          p += 2;
        case verbCubicTo:
          editor.cubicTo(pts[p * 2], pts[p * 2 + 1], pts[p * 2 + 2],
              pts[p * 2 + 3], pts[p * 2 + 4], pts[p * 2 + 5]);
          p += 3;
        case verbClose:
          editor.close();
      }
      first = false;
    }
  }

  /// Closes the contour in progress back to its first point.
  void close() => _edit().close();

  /// Removes every contour and returns [fillType] to
  /// [PathFillType.nonZero]: the state of a new `Path()`, as in Flutter.
  void reset() {
    _edit().reset();
    _fillType = PathFillType.nonZero;
  }

  /// Whether [point] is inside this path under [fillType].
  ///
  /// The path is flattened to a hundredth of a unit and the crossings of a
  /// horizontal ray are counted, so the answer on the outline itself is
  /// whichever side rounding puts it on. Open contours are closed implicitly,
  /// exactly as filling does.
  bool contains(Offset point) {
    if (isEmpty) return false;
    final Rect b = bounds;
    if (point.dx < b.left ||
        point.dx > b.right ||
        point.dy < b.top ||
        point.dy > b.bottom) {
      return false;
    }
    final FlattenedPath flat = flatten(0.01);
    final double x = point.dx;
    final double y = point.dy;
    var winding = 0;
    var crossings = 0;
    for (var c = 0; c < flat.contourCount; c++) {
      final int start = flat.contourStarts[c];
      final int end = c + 1 < flat.contourCount
          ? flat.contourStarts[c + 1]
          : flat.pointCount;
      if (end - start < 2) continue;
      for (var i = start; i < end; i++) {
        final int j = i + 1 < end ? i + 1 : start;
        final double x0 = flat.pointX(i), y0 = flat.pointY(i);
        final double x1 = flat.pointX(j), y1 = flat.pointY(j);
        if ((y0 <= y) == (y1 <= y)) continue;
        final double xAt = x0 + (y - y0) * (x1 - x0) / (y1 - y0);
        if (xAt > x) {
          crossings++;
          winding += y1 > y0 ? 1 : -1;
        }
      }
    }
    return _fillType == PathFillType.evenOdd ? crossings.isOdd : winding != 0;
  }

  /// Replaces every curve with straight segments and reports the result to
  /// [sink].
  ///
  /// [transform] is applied to the control points *before* subdivision. That
  /// is exact - an affine map of a Bezier's control points is the Bezier of
  /// the mapped curve - and it is what lets [tolerance] mean device pixels
  /// rather than "pixels before whatever scale the caller applies later". It
  /// also means the filler never allocates a transformed copy of the path.
  ///
  /// ## Why a segment count and not recursive subdivision
  ///
  /// Recursive halving until a flatness test passes is the usual answer. It
  /// adapts to the curve, but it needs a stack (heap-allocated, or a fixed
  /// depth that silently caps quality), it evaluates the flatness test at
  /// every node, and it produces segments in an order that says nothing about
  /// how many are coming.
  ///
  /// The count is instead derived up front from the curve's second
  /// derivative. Sampling a curve uniformly with `n` segments deviates from it
  /// by at most `max|B''| / (8 n^2)`, and `max|B''|` is a constant for a
  /// quadratic and the larger of two differences for a cubic - so `n` follows
  /// directly from [tolerance] with one square root and no iteration. The
  /// points are then produced by forward differencing: two additions per
  /// coordinate per point for a quadratic, three for a cubic, no
  /// multiplications and no per-point evaluation of the basis.
  ///
  /// The cost of the choice is that a curve with a tight bend in one half is
  /// subdivided as finely along its straight half. That is the trade taken -
  /// the bound is honoured everywhere, the loop has no branches, and the
  /// worst case is a few extra segments on an S-curve.
  ///
  /// Accumulated rounding is kept out of the geometry by emitting the true end
  /// point as the last segment rather than the accumulator's value, so a
  /// closed contour closes exactly.
  void flattenTo(
    PolylineSink sink, {
    double tolerance = kDefaultFlattenTolerance,
    Transform2D transform = Transform2D.identity,
  }) {
    final tol = tolerance > 0 ? tolerance : kDefaultFlattenTolerance;
    final a = transform.a;
    final b = transform.b;
    final c = transform.c;
    final d = transform.d;
    final tx = transform.tx;
    final ty = transform.ty;

    final Uint8List verbs = _verbs;
    final Float32List points = _points;
    var p = 0;
    var cx = 0.0;
    var cy = 0.0;
    for (var v = 0; v < verbs.length; v++) {
      switch (verbs[v]) {
        case verbMoveTo:
          final x = points[p * 2];
          final y = points[p * 2 + 1];
          p += 1;
          cx = a * x + c * y + tx;
          cy = b * x + d * y + ty;
          sink.moveTo(cx, cy);
        case verbLineTo:
          final x = points[p * 2];
          final y = points[p * 2 + 1];
          p += 1;
          cx = a * x + c * y + tx;
          cy = b * x + d * y + ty;
          sink.lineTo(cx, cy);
        case verbQuadraticTo:
          final x1 = points[p * 2];
          final y1 = points[p * 2 + 1];
          final x2 = points[p * 2 + 2];
          final y2 = points[p * 2 + 3];
          p += 2;
          final ax = a * x1 + c * y1 + tx;
          final ay = b * x1 + d * y1 + ty;
          final ex = a * x2 + c * y2 + tx;
          final ey = b * x2 + d * y2 + ty;
          _flattenQuadratic(sink, cx, cy, ax, ay, ex, ey, tol);
          cx = ex;
          cy = ey;
        case verbCubicTo:
          final x1 = points[p * 2];
          final y1 = points[p * 2 + 1];
          final x2 = points[p * 2 + 2];
          final y2 = points[p * 2 + 3];
          final x3 = points[p * 2 + 4];
          final y3 = points[p * 2 + 5];
          p += 3;
          final c1x = a * x1 + c * y1 + tx;
          final c1y = b * x1 + d * y1 + ty;
          final c2x = a * x2 + c * y2 + tx;
          final c2y = b * x2 + d * y2 + ty;
          final ex = a * x3 + c * y3 + tx;
          final ey = b * x3 + d * y3 + ty;
          _flattenCubic(sink, cx, cy, c1x, c1y, c2x, c2y, ex, ey, tol);
          cx = ex;
          cy = ey;
        case verbClose:
          sink.close();
      }
    }
  }

  /// [flattenTo] collected into buffers.
  ///
  /// Allocates three typed arrays sized to the result, so this is the API for
  /// callers that want to keep the polyline - hit testing, debugging, a
  /// golden test. Anything running per frame should implement [PolylineSink]
  /// over a buffer it owns and call [flattenTo].
  FlattenedPath flatten(
    double tolerance, {
    Transform2D transform = Transform2D.identity,
  }) {
    final collector = _PolylineCollector();
    flattenTo(collector, tolerance: tolerance, transform: transform);
    return collector.build();
  }

  /// Content equality, not identity.
  ///
  /// This is what `DisplayList.addPath` interns on: it looks the resource up
  /// in a `Map<Object, int>`, so a path that defines `==` and [hashCode] over
  /// its contents is deduplicated by content, and a UI that rebuilds the same
  /// icon geometry every frame contributes one entry to the resource table
  /// instead of one per draw. The encoder's documentation states the
  /// condition that comes with opting in - the resource must not change after
  /// it has an id. A path built by [PathBuilder] satisfies it because nobody
  /// else holds it; a path edited with Flutter's API is copied with
  /// [Path.from] by everything in the framework that records one (see the
  /// class comment).
  ///
  /// The comparison is O(verbs + points), which is why [hashCode] is cached:
  /// the map answers from the hash on nearly every lookup and only walks the
  /// arrays when two paths land in the same bucket.
  ///
  /// A path holding NaN coordinates is not equal to itself, exactly as the
  /// underlying doubles are not. It therefore interns as a new resource every
  /// time; that is a symptom of the NaN, not of the interning.
  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! Path) return false;
    if (other._fillType != _fillType) return false;
    if (other.hashCode != hashCode) return false;
    final Uint8List verbs = _verbs;
    final Float32List points = _points;
    final Uint8List otherVerbs = other._verbs;
    final Float32List otherPoints = other._points;
    if (otherVerbs.length != verbs.length) return false;
    if (otherPoints.length != points.length) return false;
    for (var i = 0; i < verbs.length; i++) {
      if (otherVerbs[i] != verbs[i]) return false;
    }
    for (var i = 0; i < points.length; i++) {
      if (otherPoints[i] != points[i]) return false;
    }
    return true;
  }

  /// Computed on first use after an edit, then stored. See [operator ==].
  @override
  int get hashCode => _hashCache ??= _hashOf(_verbs, _points) ^ _fillType.index;

  @override
  String toString() => 'Path(${_verbs.length} verbs, $pointCount points, '
      '$bounds${_fillType == PathFillType.evenOdd ? ', evenOdd' : ''})';

  static int _hashOf(Uint8List verbs, Float32List points) {
    var hash = 0x1a2b3c;
    for (var i = 0; i < verbs.length; i++) {
      hash = 0x3fffffff & (hash * 31 + verbs[i]);
    }
    for (var i = 0; i < points.length; i++) {
      final value = points[i];
      // -0.0 has to hash like 0.0, because `==` says the two are the same
      // point. Without this a path built with a negated zero would miss its
      // twin in the resource table and intern twice.
      hash = 0x3fffffff & (hash * 31 + (value == 0 ? 0 : value.hashCode));
    }
    return hash;
  }

  /// Tight bounds; see [bounds] for why tight.
  static Rect _boundsOf(Uint8List verbs, Float32List points) {
    if (points.isEmpty) return Rect.zero;
    var minX = double.infinity;
    var minY = double.infinity;
    var maxX = double.negativeInfinity;
    var maxY = double.negativeInfinity;
    var cx = 0.0;
    var cy = 0.0;
    var p = 0;

    // Written as one flat loop with repeated min/max lines rather than a
    // helper taking a point, because a closure or an Offset per control point
    // is exactly the per-vertex allocation section 6.5 rules out of the paths
    // that run per frame - and transform() runs this per frame.
    for (var v = 0; v < verbs.length; v++) {
      switch (verbs[v]) {
        case verbMoveTo || verbLineTo:
          cx = points[p * 2];
          cy = points[p * 2 + 1];
          p += 1;
          if (cx < minX) minX = cx;
          if (cx > maxX) maxX = cx;
          if (cy < minY) minY = cy;
          if (cy > maxY) maxY = cy;
        case verbQuadraticTo:
          final x1 = points[p * 2];
          final y1 = points[p * 2 + 1];
          final x2 = points[p * 2 + 2];
          final y2 = points[p * 2 + 3];
          p += 2;
          final loX = _quadraticMin(cx, x1, x2);
          final hiX = _quadraticMax(cx, x1, x2);
          final loY = _quadraticMin(cy, y1, y2);
          final hiY = _quadraticMax(cy, y1, y2);
          if (loX < minX) minX = loX;
          if (hiX > maxX) maxX = hiX;
          if (loY < minY) minY = loY;
          if (hiY > maxY) maxY = hiY;
          cx = x2;
          cy = y2;
        case verbCubicTo:
          final x1 = points[p * 2];
          final y1 = points[p * 2 + 1];
          final x2 = points[p * 2 + 2];
          final y2 = points[p * 2 + 3];
          final x3 = points[p * 2 + 4];
          final y3 = points[p * 2 + 5];
          p += 3;
          final loX = _cubicMin(cx, x1, x2, x3);
          final hiX = _cubicMax(cx, x1, x2, x3);
          final loY = _cubicMin(cy, y1, y2, y3);
          final hiY = _cubicMax(cy, y1, y2, y3);
          if (loX < minX) minX = loX;
          if (hiX > maxX) maxX = hiX;
          if (loY < minY) minY = loY;
          if (hiY > maxY) maxY = hiY;
          cx = x3;
          cy = y3;
      }
    }
    if (minX > maxX || minY > maxY) return Rect.zero;
    return Rect.fromLTRB(minX, minY, maxX, maxY);
  }
}

/// The result of [Path.flatten]: contours of straight segments.
final class FlattenedPath {
  const FlattenedPath._(this.points, this.contourStarts, this.contourClosed);

  /// Interleaved `x, y` pairs for every contour, back to back.
  final Float32List points;

  /// Point index where each contour starts, with one extra entry at the end
  /// holding the total point count - so contour `i` spans
  /// `contourStarts[i] .. contourStarts[i + 1]`.
  final Int32List contourStarts;

  /// 1 where the contour was explicitly closed, 0 where it was left open.
  ///
  /// Reported rather than normalised because a filler closes every contour
  /// implicitly while a future stroker must not: an open contour gets end
  /// caps, a closed one gets a join.
  final Uint8List contourClosed;

  int get contourCount => contourClosed.length;

  int get pointCount => points.length >> 1;

  double pointX(int index) => points[index * 2];

  double pointY(int index) => points[index * 2 + 1];

  Offset pointAt(int index) => Offset(points[index * 2], points[index * 2 + 1]);
}

/// Accumulates path commands, then freezes them into a [Path].
///
/// Mutable and reusable: [reset] keeps the buffers, so a caller that rebuilds
/// geometry every frame stops allocating once its shapes reach their steady
/// size. [build] copies, so the builder can keep going afterwards without the
/// path it already handed out changing underneath its owner.
final class PathBuilder {
  PathBuilder();

  Uint8List _verbs = Uint8List(16);
  Float32List _points = Float32List(32);
  int _verbCount = 0;

  /// Number of *floats* used in [_points], i.e. twice the point count.
  int _floatCount = 0;

  /// Start of the contour in progress, for [close] and for the implicit
  /// move that follows it.
  double _startX = 0;
  double _startY = 0;

  /// True when the next segment has to open a contour first: at the very
  /// beginning, and after every [close].
  bool _needsMove = true;

  /// How many times a backing buffer has been reallocated. The observable
  /// proof that reuse works, in the same spirit as `DisplayList.bufferGrowths`.
  int _growths = 0;

  int get bufferGrowths => _growths;

  int get verbCount => _verbCount;

  int get pointCount => _floatCount >> 1;

  /// Drops the contents and keeps the buffers.
  void reset() {
    _verbCount = 0;
    _floatCount = 0;
    _startX = 0;
    _startY = 0;
    _needsMove = true;
  }

  void moveTo(double x, double y) {
    _pushVerb(verbMoveTo);
    _pushPoint(x, y);
    _startX = x;
    _startY = y;
    _needsMove = false;
  }

  /// A segment to ([x], [y]).
  ///
  /// A segment with no contour open starts one. Before any [moveTo] that is
  /// the origin, and after a [close] it is the point the closed contour
  /// started at - the rule every mainstream path API follows, and the one
  /// that makes "close, then keep drawing" mean what it looks like.
  void lineTo(double x, double y) {
    _openContour();
    _pushVerb(verbLineTo);
    _pushPoint(x, y);
  }

  void quadraticBezierTo(double x1, double y1, double x2, double y2) {
    _openContour();
    _pushVerb(verbQuadraticTo);
    _pushPoint(x1, y1);
    _pushPoint(x2, y2);
  }

  void cubicTo(
    double x1,
    double y1,
    double x2,
    double y2,
    double x3,
    double y3,
  ) {
    _openContour();
    _pushVerb(verbCubicTo);
    _pushPoint(x1, y1);
    _pushPoint(x2, y2);
    _pushPoint(x3, y3);
  }

  /// Closes the contour in progress.
  ///
  /// A close with nothing open is dropped instead of emitting a verb, so that
  /// a caller looping over shapes and closing defensively does not litter the
  /// stream with contours of one point.
  void close() {
    if (_needsMove) return;
    _pushVerb(verbClose);
    _needsMove = true;
  }

  /// Adds [rect] as its own closed contour, wound clockwise in a y-down
  /// space.
  ///
  /// Winding direction is not cosmetic: two shapes added in the same
  /// direction overlap to a winding number of 2, which the non-zero rule
  /// fills solid and the even-odd rule punches a hole in. Every shape here
  /// winds the same way so that "same direction" is the default and a hole is
  /// something a caller asks for.
  void addRect(Rect rect) {
    moveTo(rect.left, rect.top);
    lineTo(rect.right, rect.top);
    lineTo(rect.right, rect.bottom);
    lineTo(rect.left, rect.bottom);
    close();
  }

  /// Adds [rect] with every corner rounded by [radiusX] and [radiusY].
  ///
  /// The uniform case of [addRoundedRectPerCorner], which is where the
  /// clamping rule and the corner geometry are documented. It forwards rather
  /// than duplicating the emission, so the two can never drift apart - a test
  /// asserts the two produce the identical path.
  void addRoundedRect(Rect rect, double radiusX, double radiusY) =>
      addRoundedRectPerCorner(
        rect,
        topLeftX: radiusX,
        topLeftY: radiusY,
        topRightX: radiusX,
        topRightY: radiusY,
        bottomRightX: radiusX,
        bottomRightY: radiusY,
        bottomLeftX: radiusX,
        bottomLeftY: radiusY,
      );

  /// Adds [rect] with each corner rounded independently.
  ///
  /// Eight values, because real shapes need them: a tab is rounded on top
  /// only, the first row of a grouped list on its top two corners, a chat
  /// bubble on three. The parameter order matches the display list's
  /// `opDrawRRect` radii - top-left, top-right, bottom-right, bottom-left,
  /// x before y - so a caller replaying that opcode can hand them over
  /// without reordering, and [addRoundedRectRadii] does exactly that.
  ///
  /// Named doubles rather than a radii value type: this runs per rounded
  /// rectangle per frame from the replay path, and an object per draw is what
  /// section 6.5 rules out. Eight names also make a transposed pair a compile
  /// error at most call sites instead of a shape that is subtly wrong.
  ///
  /// ## A corner is rounded only when both its radii are positive
  ///
  /// A corner with a zero (or negative, or NaN) radius on either axis is
  /// emitted as a plain right angle - a `lineTo` into the corner - and not as
  /// a curve of zero extent. The explicit branch matters: a degenerate cubic
  /// would still cost three control points, would still be flattened, and
  /// would put two coincident points where the filler expects an edge. This
  /// also means a rectangle with every radius zero produces exactly the verb
  /// stream [addRect] produces.
  ///
  /// ## Overrunning radii scale together, by one factor
  ///
  /// Two radii sharing an edge can ask for more than the edge has: 40 and 40
  /// on a 50-wide top edge. The rule here is CSS's (Backgrounds and Borders,
  /// "overlapping curves"): compute `edge length / sum of the two radii on it`
  /// for all four edges, take the smallest of those and 1, and multiply **all
  /// eight** radii by that single factor.
  ///
  /// One global factor rather than fixing each edge on its own, for two
  /// reasons. The corner is shared: the top edge and the left edge both end
  /// at the top-left corner, and if the top edge shrank that corner's x radius
  /// while the left edge left its y radius alone, the quarter ellipse would
  /// change shape rather than size - the outline stays continuous but its
  /// curvature jumps where the two curves meet, which reads as a kink. And the
  /// proportions the caller asked for are information: scaling everything by
  /// one factor keeps a shape with a big radius on one corner and a small one
  /// on another looking like that shape, merely smaller, instead of
  /// flattening the big corner toward the small one.
  ///
  /// A non-finite radius is treated as the larger of the rectangle's sides
  /// before the rule is applied, so "as round as possible" is expressible and
  /// lands on the same shape a very large finite radius would.
  void addRoundedRectPerCorner(
    Rect rect, {
    required double topLeftX,
    required double topLeftY,
    required double topRightX,
    required double topRightY,
    required double bottomRightX,
    required double bottomRightY,
    required double bottomLeftX,
    required double bottomLeftY,
  }) {
    final width = rect.width;
    final height = rect.height;
    if (!(width > 0) || !(height > 0)) {
      // An empty or inverted rectangle has no corners to round. Rect does not
      // normalise an inverted rectangle and neither does this: it is passed
      // through so that whatever produced it is still visible downstream.
      addRect(rect);
      return;
    }

    final limit = width > height ? width : height;
    var tlx = _sanitizeRadius(topLeftX, limit);
    var tly = _sanitizeRadius(topLeftY, limit);
    var trx = _sanitizeRadius(topRightX, limit);
    var try_ = _sanitizeRadius(topRightY, limit);
    var brx = _sanitizeRadius(bottomRightX, limit);
    var bry = _sanitizeRadius(bottomRightY, limit);
    var blx = _sanitizeRadius(bottomLeftX, limit);
    var bly = _sanitizeRadius(bottomLeftY, limit);

    // Square a corner whose other axis is zero *before* the overrun rule, so
    // that a corner that will be a right angle anyway does not consume any of
    // the edge it sits on and shrink the corner opposite it.
    if (tlx == 0 || tly == 0) {
      tlx = 0;
      tly = 0;
    }
    if (trx == 0 || try_ == 0) {
      trx = 0;
      try_ = 0;
    }
    if (brx == 0 || bry == 0) {
      brx = 0;
      bry = 0;
    }
    if (blx == 0 || bly == 0) {
      blx = 0;
      bly = 0;
    }

    var scale = 1.0;
    scale = _edgeScale(scale, width, tlx + trx);
    scale = _edgeScale(scale, width, blx + brx);
    scale = _edgeScale(scale, height, tly + bly);
    scale = _edgeScale(scale, height, try_ + bry);
    if (scale < 1) {
      tlx *= scale;
      tly *= scale;
      trx *= scale;
      try_ *= scale;
      brx *= scale;
      bry *= scale;
      blx *= scale;
      bly *= scale;
    }

    final l = rect.left;
    final t = rect.top;
    final r = rect.right;
    final b = rect.bottom;

    moveTo(l + tlx, t);

    lineTo(r - trx, t);
    if (trx > 0) {
      cubicTo(
        r - trx + trx * _kappa,
        t,
        r,
        t + try_ - try_ * _kappa,
        r,
        t + try_,
      );
    }

    lineTo(r, b - bry);
    if (brx > 0) {
      cubicTo(
        r,
        b - bry + bry * _kappa,
        r - brx + brx * _kappa,
        b,
        r - brx,
        b,
      );
    }

    lineTo(l + blx, b);
    if (blx > 0) {
      cubicTo(
        l + blx - blx * _kappa,
        b,
        l,
        b - bly + bly * _kappa,
        l,
        b - bly,
      );
    }

    // The last edge is the one that can be redundant: with a square top-left
    // corner it would run to (l, t), which is where the contour started and
    // where close() returns anyway. Skipping it is what makes an all-square
    // rounded rectangle byte-identical to addRect instead of carrying a
    // zero-length segment.
    if (tly > 0) {
      lineTo(l, t + tly);
      cubicTo(
        l,
        t + tly - tly * _kappa,
        l + tlx - tlx * _kappa,
        t,
        l + tlx,
        t,
      );
    }
    close();
  }

  /// [addRoundedRectPerCorner] reading its eight radii from [radii] starting
  /// at [offset], in the display list's `opDrawRRect` order.
  ///
  /// The one place that order is written down as code. A replay path holding
  /// the opcode's `Float32List` calls this instead of unpacking eight values
  /// at the call site, which is where a transposition would otherwise happen
  /// and would look like a rendering bug rather than an indexing one.
  void addRoundedRectRadii(Rect rect, Float32List radii, [int offset = 0]) {
    if (offset < 0 || offset + 8 > radii.length) {
      throw RangeError.range(
        offset,
        0,
        radii.length - 8,
        'offset',
        'a rounded rectangle needs eight radii',
      );
    }
    addRoundedRectPerCorner(
      rect,
      topLeftX: radii[offset],
      topLeftY: radii[offset + 1],
      topRightX: radii[offset + 2],
      topRightY: radii[offset + 3],
      bottomRightX: radii[offset + 4],
      bottomRightY: radii[offset + 5],
      bottomLeftX: radii[offset + 6],
      bottomLeftY: radii[offset + 7],
    );
  }

  /// Adds the ellipse inscribed in [rect] as four cubics, wound clockwise in
  /// a y-down space.
  void addOval(Rect rect) {
    final rx = rect.width / 2;
    final ry = rect.height / 2;
    if (!(rx > 0) || !(ry > 0)) {
      addRect(rect);
      return;
    }
    final cx = rect.left + rx;
    final cy = rect.top + ry;
    final kx = rx * _kappa;
    final ky = ry * _kappa;
    final l = rect.left;
    final t = rect.top;
    final r = rect.right;
    final b = rect.bottom;

    moveTo(cx, t);
    cubicTo(cx + kx, t, r, cy - ky, r, cy);
    cubicTo(r, cy + ky, cx + kx, b, cx, b);
    cubicTo(cx - kx, b, l, cy + ky, l, cy);
    cubicTo(l, cy - ky, cx - kx, t, cx, t);
    close();
  }

  /// Freezes the current contents into an immutable [Path].
  ///
  /// The arrays are copied to exactly the used length. Copying is what lets
  /// the builder stay alive and keep growing without mutating a path that has
  /// already been interned in a display list.
  Path build() {
    final verbs = Uint8List(_verbCount)..setRange(0, _verbCount, _verbs);
    final points = Float32List(_floatCount)..setRange(0, _floatCount, _points);
    return Path._(
      verbs,
      points,
      Path._boundsOf(verbs, points),
      Path._hashOf(verbs, points),
    );
  }

  /// Replaces the contents with [verbs] and [points] and recovers the
  /// contour state from them, so that editing can continue where they end.
  void _seed(Uint8List verbs, Float32List points) {
    reset();
    var p = 0;
    for (var v = 0; v < verbs.length; v++) {
      final int verb = verbs[v];
      _pushVerb(verb);
      final int count = pointsPerVerb(verb);
      for (var i = 0; i < count; i++) {
        _pushPoint(points[(p + i) * 2], points[(p + i) * 2 + 1]);
      }
      if (verb == verbMoveTo) {
        _startX = points[p * 2];
        _startY = points[p * 2 + 1];
        _needsMove = false;
      } else if (verb == verbClose) {
        _needsMove = true;
      }
      p += count;
    }
  }

  /// Where the next segment starts: the last end point, or the start of the
  /// contour a [close] just ended, or the origin before anything was added.
  Offset get _currentPoint {
    if (_needsMove || _floatCount == 0) return Offset(_startX, _startY);
    return Offset(_points[_floatCount - 2], _points[_floatCount - 1]);
  }

  void _replaceLastPoint(double x, double y) {
    if (_floatCount < 2) return;
    _points[_floatCount - 2] = x;
    _points[_floatCount - 1] = y;
  }

  void _openContour() {
    if (_needsMove) moveTo(_startX, _startY);
  }

  void _pushVerb(int verb) {
    if (_verbCount == _verbs.length) {
      final grown = Uint8List(_verbs.length * 2)
        ..setRange(0, _verbs.length, _verbs);
      _verbs = grown;
      _growths++;
    }
    _verbs[_verbCount++] = verb;
  }

  void _pushPoint(double x, double y) {
    if (_floatCount + 2 > _points.length) {
      final grown = Float32List(_points.length * 2)
        ..setRange(0, _points.length, _points);
      _points = grown;
      _growths++;
    }
    _points[_floatCount++] = x;
    _points[_floatCount++] = y;
  }
}

/// The circle constant for a cubic quarter arc: `4/3 * (sqrt(2) - 1)`.
const double _kappa = 0.5522847498307933;

/// A corner radius reduced to a usable number.
///
/// Negative and NaN become zero - a corner nobody can draw is a right angle,
/// which is the one interpretation that cannot look like a mistake. Infinity
/// becomes [limit], the rectangle's longer side, so that "round it as much as
/// possible" survives into the overrun rule instead of dividing by infinity
/// and collapsing every corner back to square.
double _sanitizeRadius(double radius, double limit) {
  if (!(radius > 0)) return 0;
  return radius.isFinite ? radius : limit;
}

/// The overrun factor for one edge, folded into the smallest seen so far.
double _edgeScale(double scale, double length, double sum) {
  if (sum <= length) return scale;
  final factor = length / sum;
  return factor < scale ? factor : scale;
}

/// [PolylineSink] that grows plain lists, behind [Path.flatten].
final class _PolylineCollector implements PolylineSink {
  final List<double> _points = <double>[];
  final List<int> _starts = <int>[];
  final List<int> _closed = <int>[];

  @override
  void moveTo(double x, double y) {
    _starts.add(_points.length >> 1);
    _closed.add(0);
    _points
      ..add(x)
      ..add(y);
  }

  @override
  void lineTo(double x, double y) {
    _points
      ..add(x)
      ..add(y);
  }

  @override
  void close() {
    if (_closed.isNotEmpty) _closed[_closed.length - 1] = 1;
  }

  FlattenedPath build() {
    final starts = Int32List(_starts.length + 1);
    for (var i = 0; i < _starts.length; i++) {
      starts[i] = _starts[i];
    }
    starts[_starts.length] = _points.length >> 1;
    return FlattenedPath._(
      Float32List.fromList(_points),
      starts,
      Uint8List.fromList(_closed),
    );
  }
}

/// Segments needed so that `bound / n^2 <= tolerance`, given `ratio` is
/// `bound / tolerance`.
int _segmentCount(double ratio) {
  if (!(ratio > 0)) return 1;
  if (!ratio.isFinite) return kMaxSegmentsPerCurve;
  final n = math.sqrt(ratio).ceil();
  if (n < 1) return 1;
  return n > kMaxSegmentsPerCurve ? kMaxSegmentsPerCurve : n;
}

/// Uniform sampling of a quadratic by forward differences.
///
/// `B''` is the constant `2 * (p0 - 2 p1 + p2)`, so the deviation of `n`
/// uniform segments is at most `|p0 - 2 p1 + p2| / (4 n^2)`; that inverts to
/// the segment count directly.
void _flattenQuadratic(
  PolylineSink sink,
  double x0,
  double y0,
  double x1,
  double y1,
  double x2,
  double y2,
  double tolerance,
) {
  final ddx = x0 - 2 * x1 + x2;
  final ddy = y0 - 2 * y1 + y2;
  final deviation = math.sqrt(ddx * ddx + ddy * ddy);
  final n = _segmentCount(deviation / (4 * tolerance));
  if (n <= 1) {
    sink.lineTo(x2, y2);
    return;
  }

  final h = 1.0 / n;
  final hh = h * h;
  // B(t) = ddx * t^2 + 2 (p1 - p0) t + p0, so the first and second forward
  // differences are constant in the second and zero in the third.
  var fx = x0;
  var fy = y0;
  var dfx = ddx * hh + 2 * (x1 - x0) * h;
  var dfy = ddy * hh + 2 * (y1 - y0) * h;
  final ddfx = 2 * ddx * hh;
  final ddfy = 2 * ddy * hh;
  for (var i = 1; i < n; i++) {
    fx += dfx;
    fy += dfy;
    dfx += ddfx;
    dfy += ddfy;
    sink.lineTo(fx, fy);
  }
  // The accumulator is close to the end point but not on it; emit the real
  // one so a closed contour closes exactly.
  sink.lineTo(x2, y2);
}

/// Uniform sampling of a cubic by forward differences.
///
/// `B''` is linear in `t`, so it is bounded by six times the larger of the
/// two second differences of the control polygon; the deviation of `n`
/// uniform segments is then at most `3 * bound / (4 n^2)`.
void _flattenCubic(
  PolylineSink sink,
  double x0,
  double y0,
  double x1,
  double y1,
  double x2,
  double y2,
  double x3,
  double y3,
  double tolerance,
) {
  final d0x = x0 - 2 * x1 + x2;
  final d0y = y0 - 2 * y1 + y2;
  final d1x = x1 - 2 * x2 + x3;
  final d1y = y1 - 2 * y2 + y3;
  final m0 = d0x * d0x + d0y * d0y;
  final m1 = d1x * d1x + d1y * d1y;
  final deviation = math.sqrt(m0 > m1 ? m0 : m1);
  final n = _segmentCount(3 * deviation / (4 * tolerance));
  if (n <= 1) {
    sink.lineTo(x3, y3);
    return;
  }

  // Monomial form: a t^3 + b t^2 + c t + d.
  final ax = -x0 + 3 * x1 - 3 * x2 + x3;
  final ay = -y0 + 3 * y1 - 3 * y2 + y3;
  final bx = 3 * (x0 - 2 * x1 + x2);
  final by = 3 * (y0 - 2 * y1 + y2);
  final cx = 3 * (x1 - x0);
  final cy = 3 * (y1 - y0);

  final h = 1.0 / n;
  final hh = h * h;
  final hhh = hh * h;
  var fx = x0;
  var fy = y0;
  var dfx = ax * hhh + bx * hh + cx * h;
  var dfy = ay * hhh + by * hh + cy * h;
  var ddfx = 6 * ax * hhh + 2 * bx * hh;
  var ddfy = 6 * ay * hhh + 2 * by * hh;
  final dddfx = 6 * ax * hhh;
  final dddfy = 6 * ay * hhh;
  for (var i = 1; i < n; i++) {
    fx += dfx;
    fy += dfy;
    dfx += ddfx;
    dfy += ddfy;
    ddfx += dddfx;
    ddfy += dddfy;
    sink.lineTo(fx, fy);
  }
  sink.lineTo(x3, y3);
}

/// Value of a quadratic Bezier's coordinate at [t].
double _evalQuadratic(double p0, double p1, double p2, double t) {
  final u = 1.0 - t;
  return u * u * p0 + 2 * u * t * p1 + t * t * p2;
}

/// Value of a cubic Bezier's coordinate at [t].
double _evalCubic(double p0, double p1, double p2, double p3, double t) {
  final u = 1.0 - t;
  return u * u * u * p0 +
      3 * u * u * t * p1 +
      3 * u * t * t * p2 +
      t * t * t * p3;
}

/// The parameter where a quadratic coordinate turns, or a value outside
/// `(0, 1)` when it does not turn inside the segment.
double _quadraticTurn(double p0, double p1, double p2) {
  final denominator = p0 - 2 * p1 + p2;
  if (denominator == 0) return -1;
  return (p0 - p1) / denominator;
}

double _quadraticMin(double p0, double p1, double p2) {
  var lo = p0 < p2 ? p0 : p2;
  final t = _quadraticTurn(p0, p1, p2);
  if (t > 0 && t < 1) {
    final value = _evalQuadratic(p0, p1, p2, t);
    if (value < lo) lo = value;
  }
  return lo;
}

double _quadraticMax(double p0, double p1, double p2) {
  var hi = p0 > p2 ? p0 : p2;
  final t = _quadraticTurn(p0, p1, p2);
  if (t > 0 && t < 1) {
    final value = _evalQuadratic(p0, p1, p2, t);
    if (value > hi) hi = value;
  }
  return hi;
}

/// The two parameters where a cubic coordinate can turn, written into
/// [_cubicRoots]; returns how many are inside `(0, 1)`.
///
/// A shared scratch array rather than a returned list: this runs per curve per
/// path build and per transform, which section 6.5 keeps free of allocation.
/// It is not re-entrant, which is fine - nothing here is asynchronous and the
/// roots are consumed immediately.
final Float64List _cubicRoots = Float64List(2);

int _cubicTurns(double p0, double p1, double p2, double p3) {
  // B'(t) / 3 = A t^2 + B t + C over the control polygon's differences.
  final e0 = p1 - p0;
  final e1 = p2 - p1;
  final e2 = p3 - p2;
  final a = e0 - 2 * e1 + e2;
  final b = 2 * (e1 - e0);
  final c = e0;

  var count = 0;
  if (a == 0) {
    if (b == 0) return 0;
    final t = -c / b;
    if (t > 0 && t < 1) _cubicRoots[count++] = t;
    return count;
  }
  final discriminant = b * b - 4 * a * c;
  if (discriminant < 0) return 0;
  final root = math.sqrt(discriminant);
  final t0 = (-b - root) / (2 * a);
  final t1 = (-b + root) / (2 * a);
  if (t0 > 0 && t0 < 1) _cubicRoots[count++] = t0;
  if (t1 > 0 && t1 < 1) _cubicRoots[count++] = t1;
  return count;
}

double _cubicMin(double p0, double p1, double p2, double p3) {
  var lo = p0 < p3 ? p0 : p3;
  final count = _cubicTurns(p0, p1, p2, p3);
  for (var i = 0; i < count; i++) {
    final value = _evalCubic(p0, p1, p2, p3, _cubicRoots[i]);
    if (value < lo) lo = value;
  }
  return lo;
}

double _cubicMax(double p0, double p1, double p2, double p3) {
  var hi = p0 > p3 ? p0 : p3;
  final count = _cubicTurns(p0, p1, p2, p3);
  for (var i = 0; i < count; i++) {
    final value = _evalCubic(p0, p1, p2, p3, _cubicRoots[i]);
    if (value > hi) hi = value;
  }
  return hi;
}
