/// Immutable 2D paths, stored as a verb stream plus a point stream.
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
///   * **Conics and arcs.** [PathBuilder.addOval] and
///     [PathBuilder.addRoundedRect] approximate their quarter arcs with
///     cubics using the usual `kappa` constant; the radial error is about
///     0.027% of the radius - a hundredth of a pixel at a 40 px radius, which
///     is why it is acceptable and why it is written down. A true conic
///     (rational quadratic) section would be exact and needs a fourth verb
///     plus a weight stream; nothing here blocks adding it.
///   * **Point-in-path testing.** The filler answers coverage; hit testing
///     against a path needs the same winding walk against a single point and
///     belongs next to it, not here.
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
import 'transform2d.dart';

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

/// An immutable path in one coordinate space.
///
/// Built through [PathBuilder]. The two backing arrays are never handed out,
/// so an instance genuinely cannot change after [PathBuilder.build] returns -
/// which is what makes it safe to intern (see [hashCode]) and to share
/// between a transformed copy and its original.
final class Path {
  const Path._(this._verbs, this._points, this.bounds, this._hash);

  /// A path with no contours. Fills to nothing and bounds to [Rect.zero].
  static final Path empty = PathBuilder().build();

  /// One rectangle, wound clockwise in a y-down space.
  factory Path.rect(Rect rect) => (PathBuilder()..addRect(rect)).build();

  /// One ellipse inscribed in [rect], wound clockwise in a y-down space.
  factory Path.oval(Rect rect) => (PathBuilder()..addOval(rect)).build();

  final Uint8List _verbs;

  /// Interleaved `x, y` pairs, indexed by the running total of
  /// [pointsPerVerb] over the verbs before it.
  final Float32List _points;

  /// Cached because it is asked for once per draw and never changes.
  ///
  /// **Tight, not control-point bounds.** The extrema of each quadratic and
  /// cubic are solved per axis when the path is built - a linear and a
  /// quadratic root respectively, a handful of flops per curve, paid once.
  /// Control-point bounds would have been cheaper still and are what most
  /// implementations settle for, but they overstate a curved shape by up to a
  /// third of its size, and this rectangle is what decides whether a path is
  /// culled and how much of the surface a damage region covers. Paying for
  /// tightness once at build time is worth it when the alternative is
  /// repainting pixels no shape ever reaches.
  final Rect bounds;

  /// Computed once at build time; see [hashCode].
  final int _hash;

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

  /// This path mapped through [transform].
  ///
  /// The verb stream is shared with the original rather than copied: it is
  /// immutable and private, so the only thing two paths could disagree about
  /// is their points. Bounds are recomputed from the transformed geometry
  /// instead of transformed as a rectangle, because the bounding box of a
  /// rotated bounding box is strictly larger than the bounding box of the
  /// rotated shape, and the whole point of [bounds] is that it is tight.
  Path transform(Transform2D transform) {
    if (transform.isIdentity) return this;
    final points = Float32List(_points.length);
    for (var i = 0; i < _points.length; i += 2) {
      final x = _points[i];
      final y = _points[i + 1];
      points[i] = transform.a * x + transform.c * y + transform.tx;
      points[i + 1] = transform.b * x + transform.d * y + transform.ty;
    }
    return Path._(
      _verbs,
      points,
      _boundsOf(_verbs, points),
      _hashOf(_verbs, points),
    );
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

    var p = 0;
    var cx = 0.0;
    var cy = 0.0;
    for (var v = 0; v < _verbs.length; v++) {
      switch (_verbs[v]) {
        case verbMoveTo:
          final x = _points[p * 2];
          final y = _points[p * 2 + 1];
          p += 1;
          cx = a * x + c * y + tx;
          cy = b * x + d * y + ty;
          sink.moveTo(cx, cy);
        case verbLineTo:
          final x = _points[p * 2];
          final y = _points[p * 2 + 1];
          p += 1;
          cx = a * x + c * y + tx;
          cy = b * x + d * y + ty;
          sink.lineTo(cx, cy);
        case verbQuadraticTo:
          final x1 = _points[p * 2];
          final y1 = _points[p * 2 + 1];
          final x2 = _points[p * 2 + 2];
          final y2 = _points[p * 2 + 3];
          p += 2;
          final ax = a * x1 + c * y1 + tx;
          final ay = b * x1 + d * y1 + ty;
          final ex = a * x2 + c * y2 + tx;
          final ey = b * x2 + d * y2 + ty;
          _flattenQuadratic(sink, cx, cy, ax, ay, ex, ey, tol);
          cx = ex;
          cy = ey;
        case verbCubicTo:
          final x1 = _points[p * 2];
          final y1 = _points[p * 2 + 1];
          final x2 = _points[p * 2 + 2];
          final y2 = _points[p * 2 + 3];
          final x3 = _points[p * 2 + 4];
          final y3 = _points[p * 2 + 5];
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
  /// it has an id - and this type satisfies it by being immutable rather than
  /// by asking its callers to be careful.
  ///
  /// The comparison is O(verbs + points), which is why [hashCode] is
  /// precomputed: the map answers from the hash on nearly every lookup and
  /// only walks the arrays when two paths land in the same bucket.
  ///
  /// A path holding NaN coordinates is not equal to itself, exactly as the
  /// underlying doubles are not. It therefore interns as a new resource every
  /// time; that is a symptom of the NaN, not of the interning.
  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! Path) return false;
    if (other._hash != _hash) return false;
    if (other._verbs.length != _verbs.length) return false;
    if (other._points.length != _points.length) return false;
    for (var i = 0; i < _verbs.length; i++) {
      if (other._verbs[i] != _verbs[i]) return false;
    }
    for (var i = 0; i < _points.length; i++) {
      if (other._points[i] != _points[i]) return false;
    }
    return true;
  }

  /// Computed once when the path is built, then stored. See [operator ==].
  @override
  int get hashCode => _hash;

  @override
  String toString() => 'Path(${_verbs.length} verbs, $pointCount points, '
      '$bounds)';

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

  /// Adds [rect] with corners rounded by [radiusX] and [radiusY].
  ///
  /// Radii are clamped to half the corresponding side, so an over-large
  /// radius degrades to a stadium rather than producing a self-crossing
  /// outline. A radius of zero on either axis adds a plain rectangle. The
  /// corners are cubic approximations of quarter ellipses; see the library
  /// comment for the error.
  void addRoundedRect(Rect rect, double radiusX, double radiusY) {
    final halfWidth = rect.width / 2;
    final halfHeight = rect.height / 2;
    var rx = radiusX < halfWidth ? radiusX : halfWidth;
    var ry = radiusY < halfHeight ? radiusY : halfHeight;
    if (!(rx > 0) || !(ry > 0)) {
      addRect(rect);
      return;
    }
    if (rx < 0) rx = 0;
    if (ry < 0) ry = 0;
    final kx = rx * _kappa;
    final ky = ry * _kappa;
    final l = rect.left;
    final t = rect.top;
    final r = rect.right;
    final b = rect.bottom;

    moveTo(l + rx, t);
    lineTo(r - rx, t);
    cubicTo(r - rx + kx, t, r, t + ry - ky, r, t + ry);
    lineTo(r, b - ry);
    cubicTo(r, b - ry + ky, r - rx + kx, b, r - rx, b);
    lineTo(l + rx, b);
    cubicTo(l + rx - kx, b, l, b - ry + ky, l, b - ry);
    lineTo(l, t + ry);
    cubicTo(l, t + ry - ky, l + rx - kx, t, l + rx, t);
    close();
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
