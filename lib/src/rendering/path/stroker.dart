/// The path stroker: a centreline and a pen width in, a fillable outline out.
///
/// `Path` documents that stroking is deliberately absent from it, that a
/// stroke is a *different path* - the outline of the pen's sweep - and that
/// producing it needs offset curves and joins. This is that file. What comes
/// out is an ordinary [Path], so nothing downstream learns a new concept: the
/// scanline filler is untouched, and a stroked shape composites through
/// exactly the coverage pass a filled one does.
///
/// ## The two sides of a join are not symmetric
///
/// On the outside of a turn the two offset edges leave a gap, and the join
/// style fills it. On the inside they *cross*, and the correct outline is the
/// two edges trimmed back to where they meet - which this computes directly,
/// because the meeting point of two offset lines has the same one-line closed
/// form as the miter point on the other side. Trimming is emitted as a detour
/// to that point rather than by shortening the edge that was already written,
/// so the outline carries a spur back along each edge. Between two straight
/// edges that spur is two collinear runs in opposite directions and cancels
/// exactly in the coverage accumulation; between curved ones it runs along the
/// endpoint tangent instead and encloses a sliver that goes as the square of
/// the trim. Both cost two points at a corner, and both mean no lookahead
/// anywhere in the walk.
///
/// The trim is exact only while the meeting point still lies on both edges. A
/// segment shorter than the trim it would need keeps its bevel, and the two
/// edges are left crossing - which is safe for the same reason the rest of the
/// inner side is: see below.
///
/// ## The outline must be filled non-zero
///
/// This is a contract, not a preference:
///
///   * **The untrimmed inner side of a join crosses itself**, and the small
///     loop that leaves has to add to the stroke rather than cancel out of it.
///     This is the case the fill rule exists for, and it is why the trim above
///     is an improvement to the outline rather than a correctness requirement.
///   * **A closed contour becomes two contours**, the outer offset and the
///     inner offset wound against it, so the ring between them fills and the
///     hole inside does not.
///   * **A centreline that crosses itself** produces an outline that crosses
///     itself, and the two passes over the crossing must add up to a covered
///     region rather than cancel.
///   * **A contour that doubles back on itself** is traced twice, once by each
///     side, so its winding number is two. Under even-odd it would vanish
///     entirely.
///
/// ## What is approximated, and by how much
///
/// Offsetting a straight segment is exact. Offsetting a Bezier is not - the
/// true offset of a cubic is not a cubic, at any degree - so each curve is
/// subdivided and each piece is replaced by a cubic that matches the true
/// offset at both endpoints, in both endpoint tangent directions, and at the
/// parameter midpoint. Five constraints on the two free scalars (the lengths
/// of the two control legs), solved as one 2x2 system per piece.
///
/// The subdivision criterion is the **turning angle of the piece**, not a
/// measured error. That choice is worth stating plainly because the obvious
/// alternative - evaluate both curves at the same parameter and compare - is
/// wrong in a way that is easy to miss: the offset curve and the source curve
/// do not share a parameterisation, so `|O(t) - C(t)| - r` is nonzero even for
/// a perfect offset, and using it as an error signal subdivides good pieces
/// until it hits the depth cap. Turning angle has no such flaw and has a
/// closed-form budget: a piece that turns by `d` is approximated with a radial
/// error of about `2.7e-4 * R * (d / 90 degrees)^6`, the same law that gives
/// `PathBuilder.addOval`'s quarter arcs their 0.027%, where `R` is the scale of
/// the offset curve's radius. Inverting it for [kDefaultStrokeTolerance] is one
/// sixth root, and the sixth power makes the result almost insensitive to how
/// roughly `R` is estimated.
///
/// ## Known limitation: no global self-intersection cleanup
///
/// The outline is built from local decisions and nothing afterwards looks at
/// it as a whole. Where the centreline's radius of curvature drops below half
/// the stroke width, the inner offset of that curve genuinely self-intersects:
/// it cusps and then loops. Nothing removes that loop. The non-zero rule
/// absorbs it wherever the loop winds with the stroke, which covers the cases
/// the tests exercise, but a loop wound against the stroke inside a bend
/// tighter than the pen can leave a small hole there. The fix is a boolean
/// pass over the finished outline, which is larger than everything in this
/// file and is not here. It is bounded: the artefact can only appear inside
/// such a bend, never elsewhere.
///
/// Dashing is also absent. A dasher splits the centreline before it reaches a
/// stroker and does not change any of this arithmetic, so it belongs in its
/// own file next to this one.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import '../../geometry/path.dart';

/// How an open contour's ends are finished.
enum StrokeCap {
  /// Stops at the endpoint. A dot - a contour with no length - draws nothing.
  butt,

  /// A semicircle of radius `width / 2` beyond the endpoint. A dot draws a
  /// filled circle, which is what makes a single tap or a lone `moveTo`
  /// visible.
  round,

  /// Extends by `width / 2` and squares off, so the end is a rectangle. A dot
  /// draws an axis-aligned square: with no segment there is no direction to
  /// align the square to, and picking the axes is the only answer that does
  /// not depend on invisible state.
  square,
}

/// How the outer side of a corner is filled in.
enum StrokeJoin {
  /// Extends both offset edges to their intersection, unless that point is
  /// further from the corner than [StrokeStyle.miterLimit] allows, in which
  /// case this behaves as [bevel].
  miter,

  /// A circular arc of radius `width / 2` centred on the corner.
  round,

  /// A straight line between the two offset points.
  bevel,
}

/// The pen: a width plus what to do at ends and corners.
final class StrokeStyle {
  const StrokeStyle({
    required this.width,
    this.cap = StrokeCap.butt,
    this.join = StrokeJoin.miter,
    this.miterLimit = 4.0,
  });

  /// Total width of the stroke, centred on the path. A width that is not
  /// positive and finite strokes to nothing rather than throwing - it is
  /// routinely the result of an animation passing through zero or of a scale
  /// that collapsed, and neither is a programming error the frame can react
  /// to.
  final double width;

  final StrokeCap cap;

  final StrokeJoin join;

  /// The largest ratio of miter length to stroke width that still draws a
  /// miter.
  ///
  /// A corner of interior angle `theta` needs a miter `1 / sin(theta / 2)`
  /// times the half width, which runs to infinity as the corner closes. The
  /// limit is what keeps a nearly doubled-back contour from growing a spike
  /// hundreds of pixels long out of a 2 px line - the single most visible
  /// stroker bug there is. Values below 1 are unsatisfiable (the ratio is
  /// never less than 1) and are treated as 1, which bevels every corner.
  final double miterLimit;

  @override
  bool operator ==(Object other) =>
      other is StrokeStyle &&
      other.width == width &&
      other.cap == cap &&
      other.join == join &&
      other.miterLimit == miterLimit;

  @override
  int get hashCode => Object.hash(width, cap, join, miterLimit);

  @override
  String toString() => 'StrokeStyle(width: $width, cap: $cap, join: $join, '
      'miterLimit: $miterLimit)';
}

/// Maximum deviation between the emitted outline and the true offset of the
/// centreline.
///
/// Well under `kDefaultFlattenTolerance`, and for a reason: this outline is
/// flattened again by whoever fills it, and the two errors add. Spending a
/// tenth of a pixel here leaves the quarter-pixel flattening budget intact
/// instead of turning it into a third of a pixel that nobody accounted for.
const double kDefaultStrokeTolerance = 0.1;

/// Converts centrelines into outlines, reusing its buffers across calls.
///
/// One instance kept alive, like `ScanlineFiller`: the segment buffer and the
/// output builder grow to the largest path they have seen and are then reused,
/// so a UI stroking the same shapes every frame stops allocating. [
/// bufferGrowths] is the observable proof.
///
/// Not re-entrant. [stroke] walks with instance state, so one instance cannot
/// be shared between two strokes in progress - which nothing asynchronous can
/// cause here, because [stroke] does not yield.
final class PathStroker {
  PathStroker();

  /// Recursion cap for one source curve.
  ///
  /// A documented limit rather than a safety net, in the spirit of
  /// `kMaxSegmentsPerCurve`: past 4096 pieces the tolerance is no longer
  /// honoured. Only a curve with a genuine cusp reaches it, and there the
  /// pieces are already far below a pixel.
  static const int _maxCurveDepth = 12;

  /// Radial error of a cubic approximation to a 90-degree circular arc, as a
  /// fraction of the radius. `PathBuilder.addOval` pays the same 0.027%.
  static const double _quarterArcError = 2.7e-4;

  /// Eight doubles per segment: a cubic's four control points. A line is
  /// stored as a cubic whose interior points are its thirds, so that tangents
  /// and evaluation have no second case - the memory is four points either
  /// way once the buffer is a flat array.
  static const int _segmentStride = 8;

  Float64List _segments = Float64List(64 * _segmentStride);

  /// 1 where the segment came in as a straight line, whose offset is an exact
  /// translation and must not go anywhere near the curve machinery.
  Uint8List _segmentIsLine = Uint8List(64);

  int _segmentCount = 0;
  int _growths = 0;

  final PathBuilder _builder = PathBuilder();

  double _radius = 0;
  double _tolerance = kDefaultStrokeTolerance;
  StrokeCap _cap = StrokeCap.butt;
  StrokeJoin _join = StrokeJoin.miter;
  double _miterLimit = 4;

  /// Where the outline currently is, and whether a contour is open in
  /// [_builder]. Tracked here rather than read back from the builder because
  /// `PathBuilder.lineTo` after a `close` reopens at the *previous contour's*
  /// start, which is right for a drawing API and wrong for a generator that
  /// starts every contour explicitly.
  bool _contourOpen = false;
  double _currentX = 0;
  double _currentY = 0;

  // The segment being offset, unpacked from [_segments] and already reversed
  // if the side being walked needs it.
  double _p0x = 0;
  double _p0y = 0;
  double _p1x = 0;
  double _p1y = 0;
  double _p2x = 0;
  double _p2y = 0;
  double _p3x = 0;
  double _p3y = 0;
  bool _isLine = false;

  /// Unit tangents at the ends of the loaded segment.
  double _startTangentX = 0;
  double _startTangentY = 0;
  double _endTangentX = 0;
  double _endTangentY = 0;

  /// Where the last side walk finished on the centreline, and the direction it
  /// left in. This is what a cap is built from.
  double _sideEndX = 0;
  double _sideEndY = 0;
  double _sideEndTangentX = 0;
  double _sideEndTangentY = 0;

  /// How many times a backing buffer has been reallocated since construction.
  /// Across steady-state frames this must stop increasing.
  int get bufferGrowths => _growths + _builder.bufferGrowths;

  /// The outline of [path] stroked with [style], to be filled with
  /// `FillRule.nonZero`.
  ///
  /// [tolerance] is the maximum distance between the outline returned and the
  /// true offset of the centreline, in the path's own units. It is not a
  /// device-pixel budget the way `Path.flattenTo`'s is: a stroke is applied
  /// before any transform, because scaling an outline scales its width, which
  /// is the whole point of stroking in local space. A caller that wants a
  /// width in device pixels strokes a transformed path.
  ///
  /// A width that is not positive and finite returns `Path.empty`; see
  /// [StrokeStyle.width].
  Path stroke(
    Path path,
    StrokeStyle style, {
    double tolerance = kDefaultStrokeTolerance,
  }) {
    final width = style.width;
    if (!(width > 0) || !width.isFinite) return Path.empty;

    _radius = width / 2;
    _cap = style.cap;
    _join = style.join;
    _miterLimit = style.miterLimit >= 1 ? style.miterLimit : 1.0;
    _tolerance = tolerance > 0 && tolerance.isFinite
        ? tolerance
        : kDefaultStrokeTolerance;
    _builder.reset();
    _contourOpen = false;
    _segmentCount = 0;

    _walk(path);
    return _builder.build();
  }

  /// Splits the verb stream into contours and strokes each as it ends.
  ///
  /// Contours are stroked one at a time rather than collected first, so the
  /// segment buffer only ever holds the longest single contour.
  void _walk(Path path) {
    var point = 0;
    var currentX = 0.0;
    var currentY = 0.0;
    var startX = 0.0;
    var startY = 0.0;
    var inContour = false;

    for (var v = 0; v < path.verbCount; v++) {
      switch (path.verbAt(v)) {
        case verbMoveTo:
          final x = path.pointX(point);
          final y = path.pointY(point);
          point += 1;
          if (inContour) _strokeContour(startX, startY, closed: false);
          _segmentCount = 0;
          startX = x;
          startY = y;
          currentX = x;
          currentY = y;
          inContour = true;
        case verbLineTo:
          final x = path.pointX(point);
          final y = path.pointY(point);
          point += 1;
          if (!inContour) {
            startX = currentX;
            startY = currentY;
            inContour = true;
          }
          _pushLine(currentX, currentY, x, y);
          currentX = x;
          currentY = y;
        case verbQuadraticTo:
          final cx = path.pointX(point);
          final cy = path.pointY(point);
          final x = path.pointX(point + 1);
          final y = path.pointY(point + 1);
          point += 2;
          if (!inContour) {
            startX = currentX;
            startY = currentY;
            inContour = true;
          }
          // Degree elevation is exact, so a quadratic loses nothing by being
          // stored as a cubic - and everything after this point has one curve
          // case instead of two.
          _pushCurve(
            currentX,
            currentY,
            currentX + 2 * (cx - currentX) / 3,
            currentY + 2 * (cy - currentY) / 3,
            x + 2 * (cx - x) / 3,
            y + 2 * (cy - y) / 3,
            x,
            y,
          );
          currentX = x;
          currentY = y;
        case verbCubicTo:
          final x1 = path.pointX(point);
          final y1 = path.pointY(point);
          final x2 = path.pointX(point + 1);
          final y2 = path.pointY(point + 1);
          final x3 = path.pointX(point + 2);
          final y3 = path.pointY(point + 2);
          point += 3;
          if (!inContour) {
            startX = currentX;
            startY = currentY;
            inContour = true;
          }
          _pushCurve(currentX, currentY, x1, y1, x2, y2, x3, y3);
          currentX = x3;
          currentY = y3;
        case verbClose:
          if (!inContour) continue;
          // The closing segment is explicit here. A filler can close a contour
          // by implication because it only needs the winding; a stroker has to
          // put a join and an offset edge on it like any other segment.
          _pushLine(currentX, currentY, startX, startY);
          _strokeContour(startX, startY, closed: true);
          _segmentCount = 0;
          currentX = startX;
          currentY = startY;
          inContour = false;
      }
    }
    if (inContour) _strokeContour(startX, startY, closed: false);
    _segmentCount = 0;
  }

  /// Emits the outline of the contour currently in the segment buffer.
  void _strokeContour(double startX, double startY, {required bool closed}) {
    if (_segmentCount == 0) {
      // Every point of the contour was the same point: a lone `moveTo`, or a
      // `lineTo` that went nowhere. There is no direction anywhere in it, so
      // the cap decides the whole shape.
      _emitDot(startX, startY);
      return;
    }

    if (closed) {
      _emitSide(reversed: false, closed: true);
      _emitSide(reversed: true, closed: true);
      return;
    }

    // Each cap is placed from the side walk's own last segment rather than
    // from the contour's, so a segment the walk skipped cannot leave the cap
    // hanging at a point the outline never reached.
    if (!_emitSide(reversed: false, closed: false)) return;
    _emitCap(_sideEndX, _sideEndY, _sideEndTangentX, _sideEndTangentY);
    if (_emitSide(reversed: true, closed: false)) {
      _emitCap(_sideEndX, _sideEndY, _sideEndTangentX, _sideEndTangentY);
    }
    _builder.close();
    _contourOpen = false;
  }

  /// Walks the contour once, emitting the offset that lies to the left of the
  /// direction of travel.
  ///
  /// Both sides of a stroke come out of this one walk: the right-hand side is
  /// the left-hand side of the reversed contour, so [reversed] is the entire
  /// difference between them. That is not just less code - it is what
  /// guarantees the two sides of a segment are offset by identical arithmetic
  /// and therefore stay exactly `width` apart.
  bool _emitSide({required bool reversed, required bool closed}) {
    var hasPrevious = false;
    var previousTangentX = 0.0;
    var previousTangentY = 0.0;
    var previousLength = 0.0;
    var firstTangentX = 0.0;
    var firstTangentY = 0.0;
    var firstPivotX = 0.0;
    var firstPivotY = 0.0;
    var firstLength = 0.0;

    for (var i = 0; i < _segmentCount; i++) {
      _loadSegment(reversed ? _segmentCount - 1 - i : i, reversed: reversed);
      if (!_computeTangents()) continue;

      final startX = _startTangentX;
      final startY = _startTangentY;
      final endX = _endTangentX;
      final endY = _endTangentY;
      final pivotX = _p0x;
      final pivotY = _p0y;
      final offsetX = pivotX + startY * _radius;
      final offsetY = pivotY - startX * _radius;
      final length = math.sqrt(
        (_p3x - pivotX) * (_p3x - pivotX) + (_p3y - pivotY) * (_p3y - pivotY),
      );

      if (!hasPrevious) {
        firstTangentX = startX;
        firstTangentY = startY;
        firstPivotX = pivotX;
        firstPivotY = pivotY;
        firstLength = length;
        _lineTo(offsetX, offsetY);
        hasPrevious = true;
      } else {
        _emitJoin(
          pivotX,
          pivotY,
          previousTangentX,
          previousTangentY,
          startX,
          startY,
          offsetX,
          offsetY,
          previousLength,
          length,
        );
      }

      _emitSegmentOffset();
      previousTangentX = endX;
      previousTangentY = endY;
      previousLength = length;
      _sideEndX = _p3x;
      _sideEndY = _p3y;
      _sideEndTangentX = endX;
      _sideEndTangentY = endY;
    }

    if (!hasPrevious) return false;
    if (!closed) return true;

    _emitJoin(
      firstPivotX,
      firstPivotY,
      previousTangentX,
      previousTangentY,
      firstTangentX,
      firstTangentY,
      firstPivotX + firstTangentY * _radius,
      firstPivotY - firstTangentX * _radius,
      previousLength,
      firstLength,
    );
    _builder.close();
    _contourOpen = false;
    return true;
  }

  /// The offset of the loaded segment, from its already-emitted start point.
  void _emitSegmentOffset() {
    if (_isLine) {
      // Exact: a translated segment. Deriving it from the start tangent rather
      // than from the end one keeps a line's two offset endpoints on a single
      // parallel even when the stored thirds have rounded.
      _lineTo(
        _p3x + _startTangentY * _radius,
        _p3y - _startTangentX * _radius,
      );
      return;
    }
    _offsetCubic(_p0x, _p0y, _p1x, _p1y, _p2x, _p2y, _p3x, _p3y, 0);
  }

  /// Fills the gap where two segments meet.
  ///
  /// ([pivotX], [pivotY]) is the shared centreline point, the tangents are the
  /// unit directions in and out of it, and ([toX], [toY]) is where the next
  /// segment's offset starts. The current point is the previous segment's
  /// offset end.
  ///
  /// [inLength] and [outLength] are how much edge the two segments have to
  /// give, which only the inner trim consults. They are chord lengths even for
  /// a curve, which understates the offset edge and so only ever declines a
  /// trim that would have been valid.
  void _emitJoin(
    double pivotX,
    double pivotY,
    double inX,
    double inY,
    double outX,
    double outY,
    double toX,
    double toY,
    double inLength,
    double outLength,
  ) {
    // A left normal is the tangent turned by a quarter turn, so the angle from
    // one offset point to the next is the angle from one tangent to the next:
    // this cross product is the sine of the turn and its sign says which side
    // of the corner opened up.
    final cross = inX * outY - inY * outX;
    final dot = inX * outX + inY * outY;

    if (cross == 0 && dot >= 0) {
      // Straight through: nothing to fill in and nothing to trim. Worth its
      // own branch because both cases below divide by a bisector that is at
      // its least informative here.
      _lineTo(toX, toY);
      return;
    }

    // Half the turn, as `2 cos^2` of it. Where the two offset edges meet is
    // `pivot + radius * (n0 + n1) / bisector` - the miter point on the outside
    // of the turn, and the point the edges have to be trimmed back to on the
    // inside - so one formula and one degeneracy test serve both sides. It is
    // evaluated only after whichever guard rules the division out.
    final bisector = 1 + dot;

    if (cross < 0) {
      // The inside of the turn. The trim is valid only while the meeting point
      // is still on both edges: it sits `radius * tan(half the turn)` back
      // from each edge's end, and a segment shorter than that has already
      // carried its offset past the crossing, where a detour to the meeting
      // point would add area outside the stroke rather than remove area
      // inside it. That case is left crossing, which the non-zero rule fills
      // as a union anyway - the trim tightens the outline, it does not rescue
      // it.
      if (bisector > 0) {
        final trim = _radius * math.sqrt((1 - dot) / bisector);
        if (trim <= inLength && trim <= outLength) {
          _lineTo(
            pivotX + (inY + outY) * (_radius / bisector),
            pivotY - (inX + outX) * (_radius / bisector),
          );
        }
      }
      _lineTo(toX, toY);
      return;
    }

    switch (_join) {
      case StrokeJoin.bevel:
        _lineTo(toX, toY);
      case StrokeJoin.round:
        // atan2 of (sine, cosine) of the turn: positive here by construction,
        // and exactly pi for a contour that doubles back, where the two
        // offsets sit on opposite sides of the pivot and the join is a half
        // circle around it.
        _arcTo(pivotX, pivotY, toX, toY, math.atan2(cross, dot));
      case StrokeJoin.miter:
        // The miter ratio is 1 / cos(turn / 2), and `1 + dot` is already
        // 2 cos^2(turn / 2), so the limit test is two multiplications and no
        // trigonometry. It is also the guard on the meeting point: a corner
        // approaching a full reversal drives the bisector to zero, and the
        // limit rejects it long before the division does anything strange.
        if (bisector <= 0 || bisector * _miterLimit * _miterLimit < 2) {
          _lineTo(toX, toY);
          return;
        }
        _lineTo(
          pivotX + (inY + outY) * (_radius / bisector),
          pivotY - (inX + outX) * (_radius / bisector),
        );
        _lineTo(toX, toY);
    }
  }

  /// Finishes an open end at ([x], [y]), where [tangentX]/[tangentY] points
  /// out of the contour.
  void _emitCap(double x, double y, double tangentX, double tangentY) {
    final normalX = tangentY * _radius;
    final normalY = -tangentX * _radius;
    final toX = x - normalX;
    final toY = y - normalY;

    switch (_cap) {
      case StrokeCap.butt:
        _lineTo(toX, toY);
      case StrokeCap.square:
        final extendX = tangentX * _radius;
        final extendY = tangentY * _radius;
        _lineTo(x + normalX + extendX, y + normalY + extendY);
        _lineTo(toX + extendX, toY + extendY);
        _lineTo(toX, toY);
      case StrokeCap.round:
        // Half a turn, in the direction that bulges away from the contour:
        // the left normal, the outward tangent and the right normal are a
        // quarter turn apart in that order, so the sweep is positive.
        _arcTo(x, y, toX, toY, math.pi);
    }
  }

  /// The whole shape of a contour that has no length.
  void _emitDot(double x, double y) {
    switch (_cap) {
      case StrokeCap.butt:
        return;
      case StrokeCap.round:
        _contourOpen = false;
        _moveTo(x + _radius, y);
        _arcTo(x, y, x + _radius, y, 2 * math.pi);
        _builder.close();
        _contourOpen = false;
      case StrokeCap.square:
        _contourOpen = false;
        _moveTo(x - _radius, y - _radius);
        _lineTo(x + _radius, y - _radius);
        _lineTo(x + _radius, y + _radius);
        _lineTo(x - _radius, y + _radius);
        _builder.close();
        _contourOpen = false;
    }
  }

  /// One cubic that approximates the offset of the given cubic, subdividing
  /// until the turning-angle budget is met.
  ///
  /// The construction: offset both endpoints along their normals, keep both
  /// endpoint tangent directions, and solve the two control-leg lengths so the
  /// result passes through the true offset of the source's parameter midpoint.
  /// Endpoints and tangents are matched exactly, so consecutive pieces meet
  /// without a kink no matter how the subdivision falls.
  void _offsetCubic(
    double x0,
    double y0,
    double x1,
    double y1,
    double x2,
    double y2,
    double x3,
    double y3,
    int depth,
  ) {
    // de Casteljau at one half, needed for the midpoint constraint and again
    // for the halves if this piece is subdivided.
    final ax = (x0 + x1) * 0.5;
    final ay = (y0 + y1) * 0.5;
    final bx = (x1 + x2) * 0.5;
    final by = (y1 + y2) * 0.5;
    final cx = (x2 + x3) * 0.5;
    final cy = (y2 + y3) * 0.5;
    final dx = (ax + bx) * 0.5;
    final dy = (ay + by) * 0.5;
    final ex = (bx + cx) * 0.5;
    final ey = (by + cy) * 0.5;
    final midX = (dx + ex) * 0.5;
    final midY = (dy + ey) * 0.5;

    final leg0x = x1 - x0;
    final leg0y = y1 - y0;
    final leg1x = x2 - x1;
    final leg1y = y2 - y1;
    final leg2x = x3 - x2;
    final leg2y = y3 - y2;
    final chordX = x3 - x0;
    final chordY = y3 - y0;

    final m0 = leg0x * leg0x + leg0y * leg0y;
    final m1 = leg1x * leg1x + leg1y * leg1y;
    final m2 = leg2x * leg2x + leg2y * leg2y;
    final chord2 = chordX * chordX + chordY * chordY;
    var scale2 = m0;
    if (m1 > scale2) scale2 = m1;
    if (m2 > scale2) scale2 = m2;
    if (chord2 > scale2) scale2 = chord2;
    if (!(scale2 > 0)) return;

    // Relative, because "is this control point on top of that one" has to mean
    // the same thing for an icon 10 units across and a map 10 million units
    // across. A leg below this is treated as absent rather than normalised,
    // which is what keeps a repeated control point from producing a direction
    // out of rounding noise.
    final minLeg2 = scale2 * 1e-12;

    var startX = leg0x;
    var startY = leg0y;
    if (m0 <= minLeg2) {
      startX = x2 - x0;
      startY = y2 - y0;
      if (startX * startX + startY * startY <= minLeg2) {
        startX = chordX;
        startY = chordY;
      }
    }
    var endX = leg2x;
    var endY = leg2y;
    if (m2 <= minLeg2) {
      endX = x3 - x1;
      endY = y3 - y1;
      if (endX * endX + endY * endY <= minLeg2) {
        endX = chordX;
        endY = chordY;
      }
    }
    final startLength = math.sqrt(startX * startX + startY * startY);
    final endLength = math.sqrt(endX * endX + endY * endY);
    if (!(startLength > 0) || !(endLength > 0)) return;
    startX /= startLength;
    startY /= startLength;
    endX /= endLength;
    endY /= endLength;

    final q0x = x0 + startY * _radius;
    final q0y = y0 - startX * _radius;
    final q3x = x3 + endY * _radius;
    final q3y = y3 - endX * _radius;

    var split = _turning(
          leg0x,
          leg0y,
          leg1x,
          leg1y,
          leg2x,
          leg2y,
          minLeg2,
        ) >
        _turnBudget(m0, m1, m2);

    // The true offset at the midpoint. The derivative there is proportional to
    // the difference of the last de Casteljau pair; it vanishes only at a cusp,
    // where there is no normal to offset along and the only honest answer is a
    // smaller piece.
    final midTangentX = ex - dx;
    final midTangentY = ey - dy;
    final midLength =
        math.sqrt(midTangentX * midTangentX + midTangentY * midTangentY);
    var a = 0.0;
    var b = 0.0;
    if (!(midLength > 0)) {
      split = true;
    } else {
      final offsetMidX = midX + (midTangentY / midLength) * _radius;
      final offsetMidY = midY - (midTangentX / midLength) * _radius;

      // 3a * T0 - 3b * T1 = 8 M - 4 (Q0 + Q3), one 2x2 solve by Cramer's rule.
      final vx = 8 * offsetMidX - 4 * (q0x + q3x);
      final vy = 8 * offsetMidY - 4 * (q0y + q3y);
      final ux = 3 * startX;
      final uy = 3 * startY;
      final wx = -3 * endX;
      final wy = -3 * endY;
      final determinant = ux * wy - uy * wx;
      final offsetChord = math.sqrt(
        (q3x - q0x) * (q3x - q0x) + (q3y - q0y) * (q3y - q0y),
      );
      if (determinant.abs() > 1e-9) {
        a = (vx * wy - vy * wx) / determinant;
        b = (ux * vy - uy * vx) / determinant;
      } else {
        // Parallel endpoint tangents: either a straight piece, where thirds of
        // the chord are exact, or an S whose turning budget has already asked
        // for a split.
        a = offsetChord / 3;
        b = a;
      }
      // A leg that points backwards or overshoots folds the piece into a loop
      // the source never had. Both are symptoms of a piece that is too large,
      // so they ask for the same remedy.
      final limit = 4 * offsetChord + 4 * _radius;
      if (!(a > 0) || !(b > 0) || a > limit || b > limit) {
        split = true;
        a = offsetChord / 3;
        b = a;
      }
    }

    if (split && depth < _maxCurveDepth) {
      _offsetCubic(x0, y0, ax, ay, dx, dy, midX, midY, depth + 1);
      _offsetCubic(midX, midY, ex, ey, cx, cy, x3, y3, depth + 1);
      return;
    }

    _cubicTo(
      q0x + startX * a,
      q0y + startY * a,
      q3x - endX * b,
      q3y - endY * b,
      q3x,
      q3y,
    );
  }

  /// Total turning of a control polygon, in radians.
  ///
  /// The polygon's turning bounds the curve's, which is what makes this a safe
  /// criterion where the angle between the two endpoint tangents is not: an
  /// S-shaped piece can return to its original direction while sweeping a long
  /// way in between, and only the intermediate leg reveals it.
  static double _turning(
    double leg0x,
    double leg0y,
    double leg1x,
    double leg1y,
    double leg2x,
    double leg2y,
    double minLeg2,
  ) {
    final have0 = leg0x * leg0x + leg0y * leg0y > minLeg2;
    final have1 = leg1x * leg1x + leg1y * leg1y > minLeg2;
    final have2 = leg2x * leg2x + leg2y * leg2y > minLeg2;
    var total = 0.0;
    if (have0 && have1) total += _angleBetween(leg0x, leg0y, leg1x, leg1y);
    if (have1 && have2) total += _angleBetween(leg1x, leg1y, leg2x, leg2y);
    // A cubic with a doubled middle control point still turns; skipping the
    // absent leg rather than the whole measurement is what stops that shape
    // from claiming it runs straight.
    if (have0 && !have1 && have2) {
      total += _angleBetween(leg0x, leg0y, leg2x, leg2y);
    }
    return total;
  }

  /// The unsigned angle between two directions, from a cross and a dot so
  /// that it stays accurate where a `acos` of a normalised dot loses its
  /// precision - near zero, which is where every well-behaved piece sits.
  static double _angleBetween(double ax, double ay, double bx, double by) =>
      math.atan2((ax * by - ay * bx).abs(), ax * bx + ay * by);

  /// How far one piece may turn before it is subdivided.
  ///
  /// Inverts the quarter-arc error law for [_tolerance]. The radius that error
  /// is proportional to is the offset curve's, estimated as the pen radius
  /// plus half the control polygon's length - crude, and it does not matter:
  /// the law is a sixth power, so being wrong about the radius by a factor of
  /// two moves the answer by a tenth.
  double _turnBudget(double m0, double m1, double m2) {
    final radius =
        _radius + 0.5 * (math.sqrt(m0) + math.sqrt(m1) + math.sqrt(m2));
    final error = _quarterArcError * radius;
    if (!(error > _tolerance)) return math.pi / 2;
    final budget = (math.pi / 2) * math.pow(_tolerance / error, 1 / 6);
    // Never below about six degrees: past that the pieces are shorter than the
    // error they are chasing and the depth cap is the real limit anyway.
    return budget < math.pi / 32 ? math.pi / 32 : budget;
  }

  /// A circular arc of radius [_radius] about ([centreX], [centreY]) from the
  /// current point, sweeping [sweep] radians and landing exactly on
  /// ([toX], [toY]).
  ///
  /// The endpoint is passed in rather than computed from the angle so that a
  /// join's arc ends on the same coordinates the next segment's offset starts
  /// from; a point one ulp away would leave a hairline crack that the filler
  /// renders as a lighter pixel.
  void _arcTo(
    double centreX,
    double centreY,
    double toX,
    double toY,
    double sweep,
  ) {
    final pieces = _arcPieces(sweep.abs());
    final delta = sweep / pieces;
    // The control leg of a cubic arc: 4/3 tan(quarter of the sweep), which is
    // the usual kappa when the sweep is a right angle. Signed with the sweep,
    // so a clockwise arc gets legs pointing the other way for free.
    final leg = _radius * 4 / 3 * math.tan(delta / 4);
    var angle = math.atan2(_currentY - centreY, _currentX - centreX);

    for (var i = 0; i < pieces; i++) {
      final next = angle + delta;
      final last = i == pieces - 1;
      final endX = last ? toX : centreX + _radius * math.cos(next);
      final endY = last ? toY : centreY + _radius * math.sin(next);
      _cubicTo(
        _currentX - leg * math.sin(angle),
        _currentY + leg * math.cos(angle),
        endX + leg * math.sin(next),
        endY - leg * math.cos(next),
        endX,
        endY,
      );
      angle = next;
    }
  }

  /// Cubics needed to hold an arc of [sweep] radians inside [_tolerance],
  /// inverting the same error law as [_turnBudget].
  int _arcPieces(double sweep) {
    final error = _quarterArcError * _radius;
    var budget = math.pi / 2;
    if (error > _tolerance) {
      budget = (math.pi / 2) * math.pow(_tolerance / error, 1 / 6);
      if (budget < math.pi / 64) budget = math.pi / 64;
    }
    final pieces = (sweep / budget).ceil();
    if (pieces < 1) return 1;
    return pieces > 128 ? 128 : pieces;
  }

  void _moveTo(double x, double y) {
    _builder.moveTo(x, y);
    _currentX = x;
    _currentY = y;
    _contourOpen = true;
  }

  void _lineTo(double x, double y) {
    if (!_contourOpen) {
      _moveTo(x, y);
      return;
    }
    // Exact comparison, and it is enough: the point a cap ends on and the one
    // the returning side starts from are computed by the identical expression,
    // so they are bit-identical and this drops the duplicate. Anything further
    // apart than that is geometry, not noise.
    if (x == _currentX && y == _currentY) return;
    _builder.lineTo(x, y);
    _currentX = x;
    _currentY = y;
  }

  void _cubicTo(
    double x1,
    double y1,
    double x2,
    double y2,
    double x3,
    double y3,
  ) {
    if (!_contourOpen) _moveTo(x1, y1);
    _builder.cubicTo(x1, y1, x2, y2, x3, y3);
    _currentX = x3;
    _currentY = y3;
  }

  /// Unpacks segment [index], reversing it when the right-hand side is being
  /// walked. Reversal is a swap of the control points, and it flips the left
  /// normal onto the other side of the segment, which is why one offset
  /// routine serves both sides.
  void _loadSegment(int index, {required bool reversed}) {
    final base = index * _segmentStride;
    if (reversed) {
      _p0x = _segments[base + 6];
      _p0y = _segments[base + 7];
      _p1x = _segments[base + 4];
      _p1y = _segments[base + 5];
      _p2x = _segments[base + 2];
      _p2y = _segments[base + 3];
      _p3x = _segments[base];
      _p3y = _segments[base + 1];
    } else {
      _p0x = _segments[base];
      _p0y = _segments[base + 1];
      _p1x = _segments[base + 2];
      _p1y = _segments[base + 3];
      _p2x = _segments[base + 4];
      _p2y = _segments[base + 5];
      _p3x = _segments[base + 6];
      _p3y = _segments[base + 7];
    }
    _isLine = _segmentIsLine[index] != 0;
  }

  /// Unit tangents at both ends of the loaded segment, false when it has no
  /// direction at all.
  ///
  /// The fallback chain is the guard against the degenerate control points
  /// real paths are full of - a cubic whose first control point sits on its
  /// start point is how every "curve out of a corner" is drawn. Without it the
  /// first difference is zero, the normal is zero over zero, and the outline
  /// fills with NaN.
  bool _computeTangents() {
    final leg0x = _p1x - _p0x;
    final leg0y = _p1y - _p0y;
    final leg1x = _p2x - _p1x;
    final leg1y = _p2y - _p1y;
    final leg2x = _p3x - _p2x;
    final leg2y = _p3y - _p2y;
    final chordX = _p3x - _p0x;
    final chordY = _p3y - _p0y;

    final m0 = leg0x * leg0x + leg0y * leg0y;
    final m1 = leg1x * leg1x + leg1y * leg1y;
    final m2 = leg2x * leg2x + leg2y * leg2y;
    final chord2 = chordX * chordX + chordY * chordY;
    var scale2 = m0;
    if (m1 > scale2) scale2 = m1;
    if (m2 > scale2) scale2 = m2;
    if (chord2 > scale2) scale2 = chord2;
    if (!(scale2 > 0)) return false;
    final minLeg2 = scale2 * 1e-12;

    var startX = leg0x;
    var startY = leg0y;
    if (m0 <= minLeg2) {
      startX = _p2x - _p0x;
      startY = _p2y - _p0y;
      if (startX * startX + startY * startY <= minLeg2) {
        startX = chordX;
        startY = chordY;
      }
    }
    var endX = leg2x;
    var endY = leg2y;
    if (m2 <= minLeg2) {
      endX = _p3x - _p1x;
      endY = _p3y - _p1y;
      if (endX * endX + endY * endY <= minLeg2) {
        endX = chordX;
        endY = chordY;
      }
    }

    final startLength = math.sqrt(startX * startX + startY * startY);
    final endLength = math.sqrt(endX * endX + endY * endY);
    if (!(startLength > 0) || !(endLength > 0)) return false;
    _startTangentX = startX / startLength;
    _startTangentY = startY / startLength;
    _endTangentX = endX / endLength;
    _endTangentY = endY / endLength;
    return true;
  }

  /// Appends a straight segment, dropping it if it goes nowhere.
  ///
  /// The drop is the fix for repeated identical points, which paths built by
  /// loops are full of. A zero-length segment has no direction, so keeping it
  /// would either divide by zero computing its normal or - worse - contribute
  /// an arbitrary one and put a spurious join in the middle of a straight run.
  void _pushLine(double x0, double y0, double x1, double y1) {
    if (x0 == x1 && y0 == y1) return;
    final dx = (x1 - x0) / 3;
    final dy = (y1 - y0) / 3;
    _push(true, x0, y0, x0 + dx, y0 + dy, x1 - dx, y1 - dy, x1, y1);
  }

  /// Appends a cubic, or the line it really is when every control point sits
  /// on the same spot.
  void _pushCurve(
    double x0,
    double y0,
    double x1,
    double y1,
    double x2,
    double y2,
    double x3,
    double y3,
  ) {
    if (x0 == x1 && x0 == x2 && x0 == x3 && y0 == y1 && y0 == y2 && y0 == y3) {
      return;
    }
    _push(false, x0, y0, x1, y1, x2, y2, x3, y3);
  }

  void _push(
    bool isLine,
    double x0,
    double y0,
    double x1,
    double y1,
    double x2,
    double y2,
    double x3,
    double y3,
  ) {
    if (_segmentCount == _segmentIsLine.length) _growSegments();
    final base = _segmentCount * _segmentStride;
    _segments[base] = x0;
    _segments[base + 1] = y0;
    _segments[base + 2] = x1;
    _segments[base + 3] = y1;
    _segments[base + 4] = x2;
    _segments[base + 5] = y2;
    _segments[base + 6] = x3;
    _segments[base + 7] = y3;
    _segmentIsLine[_segmentCount] = isLine ? 1 : 0;
    _segmentCount++;
  }

  void _growSegments() {
    final grown = _segmentIsLine.length * 2;
    _segments = Float64List(grown * _segmentStride)
      ..setRange(0, _segments.length, _segments);
    _segmentIsLine = Uint8List(grown)
      ..setRange(0, _segmentIsLine.length, _segmentIsLine);
    _growths++;
  }
}
