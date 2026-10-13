/// Boolean operations on outlines: what CorelDRAW's Weld, Trim and Intersect
/// do to the shapes they are given, with no widget in them.
///
/// The curves stay curves. Paper.js's approach, in four steps:
///
///  1. **Intersections.** Every segment against every other, by recursive
///     subdivision of their control-point hulls until both pieces are flat
///     enough to meet as lines. Two segments lying on each other (two
///     rectangles sharing an edge, a circle welded to its copy) would make
///     that recursion explode, so a coincident stretch is found first, from
///     where each segment's ends fall on the other.
///  2. **Splitting.** Each segment is cut at its intersections, de Casteljau's
///     way, into pieces that cross nothing. Every end point goes through one
///     vertex pool, so pieces that meet share the same [Offset].
///  3. **Classifying.** A piece is part of the result's outline exactly when
///     the result is inside on one side of it and outside on the other. Both
///     sides are tested a hair off the piece's middle, with an exact winding
///     number against the cubic segments (no flattening, whose chord error
///     would be larger than the hair). A kept piece is turned so the result
///     is on its left; two coincident kept pieces are one.
///  4. **Chaining.** Kept pieces are joined end to start into closed
///     contours, and pieces cut from the same segment that both survived are
///     joined back into it, so a weld adds no node where nothing meets.
///
/// Every contour of the result is wound the same way round its inside, so it
/// fills correctly under either [FillRule]. Open paths count as closed by a
/// straight line, as they do when filled.
library;

import 'dart:math' as math;

import '../geometry/offset.dart';
import '../graphics/vector/constants.dart';
import '../graphics/vector/primitives.dart';

/// Which region of two outlines a [PathBoolean] keeps.
enum PathBooleanOperation {
  /// In either: CorelDRAW's Weld.
  union,

  /// In both: Intersect.
  intersect,

  /// In the first and not the second: Trim, with the second as the trimmer.
  difference,

  /// In exactly one.
  exclude,
}

/// The boolean operations.
abstract final class PathBoolean {
  /// The outline of the region [operation] keeps of [a] and [b], each filled
  /// by its own rule. Empty when that region is.
  static List<VectorPath> apply(
    List<VectorPath> a,
    List<VectorPath> b,
    PathBooleanOperation operation, {
    FillRule ruleA = FillRule.nonZero,
    FillRule ruleB = FillRule.nonZero,
  }) =>
      _Boolean(a, b, operation, ruleA, ruleB).run();

  /// Every outline in [shapes] welded into one.
  static List<VectorPath> unionAll(Iterable<List<VectorPath>> shapes) {
    List<VectorPath>? result;
    for (final List<VectorPath> shape in shapes) {
      result = result == null
          ? _Boolean(shape, const <VectorPath>[], PathBooleanOperation.union,
                  FillRule.nonZero, FillRule.nonZero)
              .run()
          : apply(result, shape, PathBooleanOperation.union);
    }
    return result ?? <VectorPath>[];
  }

  /// The signed winding number of [path]'s outlines around [point]: what
  /// decides inside and outside, exact on curves.
  static int winding(List<VectorPath> paths, Offset point) {
    var total = 0;
    for (final List<_Segment> contour in _contours(paths, 0, 0)) {
      total += _winding(contour, point);
    }
    return total;
  }
}

/// One cubic segment; a straight one keeps its controls on its chord and
/// says so, so it comes back out as a line.
final class _Segment {
  _Segment(this.p0, this.p1, this.p2, this.p3,
      {required this.line, required this.shape});

  _Segment.straight(Offset from, Offset to, {required this.shape})
      : p0 = from,
        p1 = Offset.lerp(from, to, 1 / 3),
        p2 = Offset.lerp(from, to, 2 / 3),
        p3 = to,
        line = true;

  final Offset p0;
  final Offset p1;
  final Offset p2;
  final Offset p3;
  final bool line;

  /// 0 for the first operand, 1 for the second.
  final int shape;

  Offset at(double t) {
    final double u = 1 - t;
    final double a = u * u * u;
    final double b = 3 * u * u * t;
    final double c = 3 * u * t * t;
    final double d = t * t * t;
    return Offset(
      a * p0.dx + b * p1.dx + c * p2.dx + d * p3.dx,
      a * p0.dy + b * p1.dy + c * p2.dy + d * p3.dy,
    );
  }

  Offset tangent(double t) {
    final double u = 1 - t;
    return (p1 - p0) * (3 * u * u) +
        (p2 - p1) * (6 * u * t) +
        (p3 - p2) * (3 * t * t);
  }

  /// The piece between [t0] and [t1], with its ends replaced by [from] and
  /// [to] when given - the vertex pool's copies of the same points.
  _Segment sub(double t0, double t1, {Offset? from, Offset? to}) {
    final Offset start = from ?? at(t0);
    final Offset end = to ?? at(t1);
    if (line) return _Segment.straight(start, end, shape: shape);
    // The derivative scaled to the sub-interval gives the controls directly.
    final double span = t1 - t0;
    return _Segment(
      start,
      start + tangent(t0) * (span / 3),
      end - tangent(t1) * (span / 3),
      end,
      line: false,
      shape: shape,
    );
  }

  _Segment get reversed => _Segment(p3, p2, p1, p0, line: line, shape: shape);

  double get minX => math.min(math.min(p0.dx, p1.dx), math.min(p2.dx, p3.dx));
  double get maxX => math.max(math.max(p0.dx, p1.dx), math.max(p2.dx, p3.dx));
  double get minY => math.min(math.min(p0.dy, p1.dy), math.min(p2.dy, p3.dy));
  double get maxY => math.max(math.max(p0.dy, p1.dy), math.max(p2.dy, p3.dy));

  /// Whether the controls lie within [tolerance] of the chord.
  bool isFlat(double tolerance) {
    if (line) return true;
    final Offset chord = p3 - p0;
    final double length = chord.distance;
    if (length < tolerance) {
      return (p1 - p0).distance < tolerance && (p2 - p0).distance < tolerance;
    }
    double off(Offset p) =>
        ((p.dx - p0.dx) * chord.dy - (p.dy - p0.dy) * chord.dx).abs() / length;
    return off(p1) < tolerance && off(p2) < tolerance;
  }
}

/// A piece of a split segment, and where it came from.
final class _Piece {
  _Piece(this.segment, this.source, this.t0, this.t1);

  _Segment segment;
  final int source;
  final double t0;
  final double t1;
  bool reversed = false;

  Offset get start => segment.p0;
  Offset get end => segment.p3;
}

/// Points within a tolerance of each other become one.
final class _VertexPool {
  _VertexPool(this.tolerance) : _cell = tolerance * 4;

  final double tolerance;
  final double _cell;
  final Map<int, List<Offset>> _grid = <int, List<Offset>>{};

  int _key(int x, int y) => (x & 0x3FFFFFFF) * 0x40000000 + (y & 0x3FFFFFFF);

  Offset snap(Offset point) {
    final int cx = (point.dx / _cell).floor();
    final int cy = (point.dy / _cell).floor();
    for (var dx = -1; dx <= 1; dx++) {
      for (var dy = -1; dy <= 1; dy++) {
        final List<Offset>? bucket = _grid[_key(cx + dx, cy + dy)];
        if (bucket == null) continue;
        for (final Offset known in bucket) {
          if ((known - point).distance <= tolerance) return known;
        }
      }
    }
    (_grid[_key(cx, cy)] ??= <Offset>[]).add(point);
    return point;
  }
}

/// [paths] as closed contours of segments, the open ones closed by a line.
List<List<_Segment>> _contours(
    List<VectorPath> paths, int shape, double tolerance) {
  final List<List<_Segment>> contours = <List<_Segment>>[];
  for (final VectorPath path in paths) {
    final List<_Segment> segments = <_Segment>[];
    Offset from = path.start;
    for (final Object point in path.points) {
      if (point is CurvePoint) {
        final _Segment segment = _Segment(
            from, point.control1, point.control2, point.endpoint,
            line: false, shape: shape);
        if (!_degenerate(segment, tolerance)) segments.add(segment);
        from = point.endpoint;
      } else if (point is Offset) {
        if ((point - from).distance > tolerance) {
          segments.add(_Segment.straight(from, point, shape: shape));
        }
        from = point;
      }
    }
    if (segments.isEmpty) continue;
    if ((from - path.start).distance > tolerance) {
      segments.add(_Segment.straight(from, path.start, shape: shape));
    }
    contours.add(segments);
  }
  return contours;
}

bool _degenerate(_Segment s, double tolerance) =>
    (s.p0 - s.p3).distance <= tolerance &&
    (s.p1 - s.p0).distance <= tolerance &&
    (s.p2 - s.p0).distance <= tolerance;

/// The winding number of [contour] around [point], counting crossings of a
/// ray to the right with each y-monotone stretch of each segment, half-open
/// in y so a ray through a vertex counts it once.
int _winding(List<_Segment> contour, Offset point) {
  var winding = 0;
  for (final _Segment s in contour) {
    if (point.dy < s.minY || point.dy > s.maxY || s.maxX < point.dx) continue;
    // Where dy/dt is zero: the y extremes that split the segment into
    // monotone stretches.
    final double a = -s.p0.dy + 3 * s.p1.dy - 3 * s.p2.dy + s.p3.dy;
    final double b = 2 * (s.p0.dy - 2 * s.p1.dy + s.p2.dy);
    final double c = s.p1.dy - s.p0.dy;
    final List<double> cuts = <double>[0];
    for (final double t in _quadraticRoots(a, b, c)) {
      if (t > 1e-12 && t < 1 - 1e-12) cuts.add(t);
    }
    cuts
      ..sort()
      ..add(1);
    for (var i = 0; i + 1 < cuts.length; i++) {
      double lo = cuts[i];
      double hi = cuts[i + 1];
      final double ya = s.at(lo).dy;
      final double yb = s.at(hi).dy;
      if (ya == yb) continue;
      final int direction = yb > ya ? 1 : -1;
      final double low = math.min(ya, yb);
      final double high = math.max(ya, yb);
      if (point.dy < low || point.dy >= high) continue;
      // Bisection on the monotone stretch for y(t) = point.dy.
      for (var step = 0; step < 52; step++) {
        final double mid = (lo + hi) / 2;
        final double y = s.at(mid).dy;
        if ((y < point.dy) == (direction > 0)) {
          lo = mid;
        } else {
          hi = mid;
        }
      }
      if (s.at((lo + hi) / 2).dx > point.dx) winding += direction;
    }
  }
  return winding;
}

List<double> _quadraticRoots(double a, double b, double c) {
  if (a.abs() < 1e-12) {
    if (b.abs() < 1e-12) return const <double>[];
    return <double>[-c / b];
  }
  final double discriminant = b * b - 4 * a * c;
  if (discriminant < 0) return const <double>[];
  final double root = math.sqrt(discriminant);
  return <double>[(-b + root) / (2 * a), (-b - root) / (2 * a)];
}

final class _Boolean {
  _Boolean(this.a, this.b, this.operation, this.ruleA, this.ruleB);

  final List<VectorPath> a;
  final List<VectorPath> b;
  final PathBooleanOperation operation;
  final FillRule ruleA;
  final FillRule ruleB;

  late final double _tolerance;
  late final double _hair;
  late final List<List<_Segment>> _shapeA;
  late final List<List<_Segment>> _shapeB;

  List<VectorPath> run() {
    final double scale = _scale();
    if (scale == 0) return <VectorPath>[];
    _tolerance = scale * 1e-7;
    _hair = scale * 1e-5;
    _shapeA = _contours(a, 0, _tolerance);
    _shapeB = _contours(b, 1, _tolerance);
    final List<_Segment> segments = <_Segment>[
      for (final List<_Segment> contour in _shapeA) ...contour,
      for (final List<_Segment> contour in _shapeB) ...contour,
    ];
    if (segments.isEmpty) return <VectorPath>[];
    final List<_Piece> pieces = _split(segments);
    final List<_Piece> kept = _classify(pieces);
    return _chain(kept, segments);
  }

  double _scale() {
    double minX = double.infinity, minY = double.infinity;
    double maxX = -double.infinity, maxY = -double.infinity;
    void add(Offset p) {
      minX = math.min(minX, p.dx);
      minY = math.min(minY, p.dy);
      maxX = math.max(maxX, p.dx);
      maxY = math.max(maxY, p.dy);
    }

    for (final VectorPath path in <VectorPath>[...a, ...b]) {
      add(path.start);
      for (final Object point in path.points) {
        if (point is CurvePoint) {
          add(point.control1);
          add(point.control2);
          add(point.endpoint);
        } else if (point is Offset) {
          add(point);
        }
      }
    }
    if (minX == double.infinity) return 0;
    return math.max(math.max(maxX - minX, maxY - minY), 1e-9);
  }

  // --- 1 and 2: intersections and splitting --------------------------------

  List<_Piece> _split(List<_Segment> segments) {
    final _VertexPool pool = _VertexPool(_tolerance * 10);
    // Each segment's ends first, so a crossing at a node lands on it.
    final List<Offset> starts = <Offset>[
      for (final _Segment s in segments) pool.snap(s.p0)
    ];
    final List<Offset> ends = <Offset>[
      for (final _Segment s in segments) pool.snap(s.p3)
    ];
    final List<List<(double, Offset)>> cuts = <List<(double, Offset)>>[
      for (var i = 0; i < segments.length; i++) <(double, Offset)>[]
    ];
    final double slack = _tolerance * 10;
    for (var i = 0; i < segments.length; i++) {
      final _Segment si = segments[i];
      for (var j = i + 1; j < segments.length; j++) {
        final _Segment sj = segments[j];
        if (si.maxX + slack < sj.minX ||
            sj.maxX + slack < si.minX ||
            si.maxY + slack < sj.minY ||
            sj.maxY + slack < si.minY) {
          continue;
        }
        for (final (double ti, double tj) in _intersections(si, sj)) {
          final Offset point = pool.snap(si.at(ti));
          cuts[i].add((ti, point));
          cuts[j].add((tj, point));
        }
      }
    }
    final List<_Piece> pieces = <_Piece>[];
    for (var i = 0; i < segments.length; i++) {
      final _Segment s = segments[i];
      final List<(double, Offset)> at = cuts[i]
        ..sort((x, y) => x.$1.compareTo(y.$1));
      var t0 = 0.0;
      Offset from = starts[i];
      for (final (double t, Offset point) in at) {
        // A cut at a node is no cut, and two hits on one point are one.
        if (identical(point, from) || point == from) continue;
        if (point == ends[i]) continue;
        if (t <= t0) continue;
        _addPiece(pieces, s, i, t0, t, from, point);
        t0 = t;
        from = point;
      }
      _addPiece(pieces, s, i, t0, 1, from, ends[i]);
    }
    return pieces;
  }

  void _addPiece(List<_Piece> pieces, _Segment s, int source, double t0,
      double t1, Offset from, Offset to) {
    if (from == to && (s.line || t1 - t0 < 1e-9)) return;
    pieces.add(_Piece(s.sub(t0, t1, from: from, to: to), source, t0, t1));
  }

  /// The parameters where [a] and [b] meet, a coincident stretch counting
  /// as its two ends.
  List<(double, double)> _intersections(_Segment a, _Segment b) {
    final List<(double, double)>? overlap = _overlap(a, b);
    if (overlap != null) return overlap;
    final List<(double, double)> hits = <(double, double)>[];
    _subdivide(a, 0, 1, b, 0, 1, hits, 0);
    // A crossing found from several neighbouring sub-pieces is one.
    hits.sort((x, y) => x.$1.compareTo(y.$1));
    final List<(double, double)> unique = <(double, double)>[];
    for (final (double, double) hit in hits) {
      if (unique.isNotEmpty &&
          (a.at(unique.last.$1) - a.at(hit.$1)).distance < _tolerance * 10) {
        continue;
      }
      unique.add(hit);
    }
    return unique;
  }

  void _subdivide(_Segment a, double a0, double a1, _Segment b, double b0,
      double b1, List<(double, double)> hits, int depth) {
    final _Segment pa = a0 == 0 && a1 == 1 ? a : a.sub(a0, a1);
    final _Segment pb = b0 == 0 && b1 == 1 ? b : b.sub(b0, b1);
    final double slack = _tolerance;
    if (pa.maxX + slack < pb.minX ||
        pb.maxX + slack < pa.minX ||
        pa.maxY + slack < pb.minY ||
        pb.maxY + slack < pa.minY) {
      return;
    }
    if (hits.length > 32) return;
    if (depth > 40 || (pa.isFlat(_tolerance) && pb.isFlat(_tolerance))) {
      final (double, double)? hit = _lineHit(pa.p0, pa.p3, pb.p0, pb.p3);
      if (hit != null) {
        hits.add((a0 + hit.$1 * (a1 - a0), b0 + hit.$2 * (b1 - b0)));
      }
      return;
    }
    final double am = (a0 + a1) / 2;
    final double bm = (b0 + b1) / 2;
    _subdivide(a, a0, am, b, b0, bm, hits, depth + 1);
    _subdivide(a, a0, am, b, bm, b1, hits, depth + 1);
    _subdivide(a, am, a1, b, b0, bm, hits, depth + 1);
    _subdivide(a, am, a1, b, bm, b1, hits, depth + 1);
  }

  /// Where segment p0-p1 meets q0-q1, as parameters on each, ends included.
  (double, double)? _lineHit(Offset p0, Offset p1, Offset q0, Offset q1) {
    final Offset r = p1 - p0;
    final Offset s = q1 - q0;
    final double denominator = r.dx * s.dy - r.dy * s.dx;
    if (denominator.abs() < 1e-18) return null;
    final Offset qp = q0 - p0;
    final double t = (qp.dx * s.dy - qp.dy * s.dx) / denominator;
    final double u = (qp.dx * r.dy - qp.dy * r.dx) / denominator;
    const double e = 1e-9;
    if (t < -e || t > 1 + e || u < -e || u > 1 + e) return null;
    return (t.clamp(0.0, 1.0), u.clamp(0.0, 1.0));
  }

  /// When [a] and [b] lie on each other for a stretch, its two ends as
  /// parameters on both; otherwise null.
  List<(double, double)>? _overlap(_Segment a, _Segment b) {
    final double near = _tolerance * 10;
    final List<(double, double)> ends = <(double, double)>[];
    void tryPoint(Offset point, _Segment onto, double own, bool ownIsA) {
      final double t = _closest(onto, point);
      if ((onto.at(t) - point).distance > near) return;
      ends.add(ownIsA ? (own, t) : (t, own));
    }

    tryPoint(b.p0, a, 0, false);
    tryPoint(b.p3, a, 1, false);
    tryPoint(a.p0, b, 0, true);
    tryPoint(a.p3, b, 1, true);
    if (ends.length < 2) return null;
    ends.sort((x, y) => x.$1.compareTo(y.$1));
    final (double, double) first = ends.first;
    final (double, double) last = ends.last;
    if ((a.at(first.$1) - a.at(last.$1)).distance < near) return null;
    // Two curves through the same two points are not coincident unless
    // they agree between them too.
    for (final double f in const <double>[.25, .5, .75]) {
      final Offset point = a.at(first.$1 + (last.$1 - first.$1) * f);
      if ((b.at(_closest(b, point)) - point).distance > near) return null;
    }
    return <(double, double)>[first, last];
  }

  /// The parameter of the point of [s] nearest [point].
  double _closest(_Segment s, Offset point) {
    if (s.line) {
      final Offset d = s.p3 - s.p0;
      final double length = d.distanceSquared;
      if (length == 0) return 0;
      final Offset v = point - s.p0;
      return ((v.dx * d.dx + v.dy * d.dy) / length).clamp(0.0, 1.0);
    }
    var best = 0.0;
    var bestDistance = double.infinity;
    const int samples = 32;
    for (var i = 0; i <= samples; i++) {
      final double t = i / samples;
      final double d = (s.at(t) - point).distanceSquared;
      if (d < bestDistance) {
        bestDistance = d;
        best = t;
      }
    }
    var lo = math.max(0.0, best - 1 / samples);
    var hi = math.min(1.0, best + 1 / samples);
    for (var step = 0; step < 60; step++) {
      final double m1 = lo + (hi - lo) / 3;
      final double m2 = hi - (hi - lo) / 3;
      if ((s.at(m1) - point).distanceSquared <
          (s.at(m2) - point).distanceSquared) {
        hi = m2;
      } else {
        lo = m1;
      }
    }
    return (lo + hi) / 2;
  }

  // --- 3: classifying -------------------------------------------------------

  bool _inside(List<List<_Segment>> shape, FillRule rule, Offset point) {
    var winding = 0;
    for (final List<_Segment> contour in shape) {
      winding += _winding(contour, point);
    }
    return rule == FillRule.evenOdd ? winding.isOdd : winding != 0;
  }

  bool _result(Offset point) {
    final bool inA = _inside(_shapeA, ruleA, point);
    final bool inB = _inside(_shapeB, ruleB, point);
    return switch (operation) {
      PathBooleanOperation.union => inA || inB,
      PathBooleanOperation.intersect => inA && inB,
      PathBooleanOperation.difference => inA && !inB,
      PathBooleanOperation.exclude => inA != inB,
    };
  }

  List<_Piece> _classify(List<_Piece> pieces) {
    final List<_Piece> kept = <_Piece>[];
    final Map<(Offset, Offset), List<_Piece>> byEnds =
        <(Offset, Offset), List<_Piece>>{};
    for (final _Piece piece in pieces) {
      final _Segment s = piece.segment;
      final Offset middle = s.at(.5);
      Offset direction = s.tangent(.5);
      if (direction.distance < 1e-12) direction = s.p3 - s.p0;
      final double length = direction.distance;
      if (length < 1e-12) continue;
      final Offset normal =
          Offset(-direction.dy / length, direction.dx / length) * _hair;
      final bool left = _result(middle + normal);
      final bool right = _result(middle - normal);
      if (left == right) continue;
      if (!left) {
        piece
          ..segment = s.reversed
          ..reversed = true;
      }
      // The same stretch kept twice - two shapes sharing an edge, both
      // with the result on the same side - is drawn once.
      final List<_Piece> twins =
          byEnds[(piece.start, piece.end)] ??= <_Piece>[];
      final Offset at = piece.segment.at(.5);
      if (twins.any((_Piece other) =>
          (other.segment.at(.5) - at).distance < _tolerance * 100)) {
        continue;
      }
      twins.add(piece);
      kept.add(piece);
    }
    return kept;
  }

  // --- 4: chaining ----------------------------------------------------------

  List<VectorPath> _chain(List<_Piece> kept, List<_Segment> segments) {
    final Map<Offset, List<int>> leaving = <Offset, List<int>>{};
    for (var i = 0; i < kept.length; i++) {
      (leaving[kept[i].start] ??= <int>[]).add(i);
    }
    final List<bool> used = List<bool>.filled(kept.length, false);
    final List<VectorPath> result = <VectorPath>[];
    for (var first = 0; first < kept.length; first++) {
      if (used[first]) continue;
      final List<_Piece> contour = <_Piece>[kept[first]];
      used[first] = true;
      Offset at = kept[first].end;
      final Offset origin = kept[first].start;
      while (at != origin) {
        final List<int>? next = leaving[at];
        int? pick;
        if (next != null) {
          for (final int i in next) {
            if (!used[i]) {
              pick = i;
              break;
            }
          }
        }
        if (pick == null) break;
        used[pick] = true;
        contour.add(kept[pick]);
        at = kept[pick].end;
      }
      final List<_Segment> merged = _merge(contour, segments);
      if (merged.isEmpty) continue;
      result.add(VectorPath(
        start: merged.first.p0,
        points: <Object>[
          for (final _Segment s in merged)
            s.line ? s.p3 : CurvePoint(s.p1, s.p2, s.p3),
          // An outline that did not come back round (only on input the
          // tolerance could not reconcile) is closed by a line.
          if (merged.last.p3 != merged.first.p0) merged.first.p0,
        ],
        closure: PathClosure.closed,
      ));
    }
    return result;
  }

  /// [contour]'s pieces, with neighbours cut from the same segment - a cut
  /// whose other side was dropped - joined back into one.
  List<_Segment> _merge(List<_Piece> contour, List<_Segment> segments) {
    final List<_Segment> out = <_Segment>[];
    var i = 0;
    while (i < contour.length) {
      final _Piece piece = contour[i];
      var t0 = piece.t0;
      var t1 = piece.t1;
      final Offset from = piece.start;
      Offset to = piece.end;
      var j = i + 1;
      while (j < contour.length) {
        final _Piece next = contour[j];
        if (next.source != piece.source || next.reversed != piece.reversed) {
          break;
        }
        if (!piece.reversed && next.t0 == t1) {
          t1 = next.t1;
        } else if (piece.reversed && next.t1 == t0) {
          t0 = next.t0;
        } else {
          break;
        }
        to = next.end;
        j++;
      }
      if (j == i + 1) {
        out.add(piece.segment);
      } else {
        final _Segment whole = piece.reversed
            ? segments[piece.source].sub(t0, t1, from: to, to: from).reversed
            : segments[piece.source].sub(t0, t1, from: from, to: to);
        out.add(whole);
      }
      i = j;
    }
    return out;
  }
}
