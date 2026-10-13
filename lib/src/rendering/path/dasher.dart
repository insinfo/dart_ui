/// Dashing: a path cut into the pieces a dash pattern keeps.
///
/// A dashed stroke is not a different pen, it is the same pen run over less
/// path. So dashing is a path-to-path step that happens before the stroker,
/// and everything the stroker does - caps on every dash, joins inside a dash
/// that turns a corner - follows without either file knowing about the
/// other.
///
/// Curves stay curves. A dash that ends partway along a cubic ends on a
/// sub-cubic cut out of it by de Casteljau, at the parameter where the arc
/// length reaches the dash's end; the arc length comes from a table sampled
/// along the curve. Cutting the curve into lines first would hand the
/// stroker facets, and a round-capped dotted circle would come out a
/// polygon of dots.
///
/// The pattern runs on across segments and around corners, as SVG's does:
/// a dash that reaches a vertex continues past it in the same piece, so the
/// stroker draws the corner as a join, not as two caps.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import '../../geometry/path.dart';

/// Above this many dashes the pattern is too fine to see and the path is
/// stroked solid instead: a 0.01 px pattern on a long path would otherwise
/// cost millions of pieces to draw what a solid line already shows.
const int kMaxDashPieces = 100000;

/// [path] with only the stretches [intervals] keeps - dash, gap, dash, gap,
/// starting [offset] into the pattern.
///
/// [intervals] must have an even length and a positive sum, which
/// `StrokeExtras.of` guarantees; anything else, or a pattern that would cut
/// more than [kMaxDashPieces] pieces, returns [path] unchanged. A dash of
/// length zero is kept as a lone point, which a round or square cap draws as
/// a dot.
Path dashPath(Path path, List<double> intervals, {double offset = 0}) {
  if (intervals.isEmpty || intervals.length.isOdd) return path;
  var total = 0.0;
  for (final double d in intervals) {
    if (!d.isFinite || d < 0) return path;
    total += d;
  }
  if (total <= 0 || !offset.isFinite) return path;
  final _Dasher dasher = _Dasher(intervals, total, offset);
  try {
    dasher.run(path);
  } on _TooManyPieces {
    return path;
  }
  return dasher.out.build();
}

final class _TooManyPieces implements Exception {}

final class _Dasher {
  _Dasher(this.intervals, this.total, this.offset) {
    _restart();
  }

  final List<double> intervals;
  final double total;
  final double offset;
  final PathBuilder out = PathBuilder();

  int _index = 0;
  double _remaining = 0;
  bool _penDown = false;
  int _pieces = 0;

  /// The pattern from [offset] in: which interval, and how much of it is
  /// left. Every contour starts the pattern afresh, as SVG's does.
  void _restart() {
    var at = offset % total;
    if (at < 0) at += total;
    _index = 0;
    // Only while there is offset left to consume: at zero the first
    // interval starts here even when it is a zero-length dash - a dot.
    while (at > 0 && at >= intervals[_index]) {
      at -= intervals[_index];
      _index = (_index + 1) % intervals.length;
    }
    _remaining = intervals[_index] - at;
    _penDown = false;
  }

  bool get _on => _index.isEven;

  void _advance() {
    _index = (_index + 1) % intervals.length;
    _remaining = intervals[_index];
    if (!_on) _penDown = false;
  }

  void _count() {
    if (++_pieces > kMaxDashPieces) throw _TooManyPieces();
  }

  void run(Path path) {
    var point = 0;
    var x = 0.0;
    var y = 0.0;
    var startX = 0.0;
    var startY = 0.0;
    var open = false;
    for (var v = 0; v < path.verbCount; v++) {
      switch (path.verbAt(v)) {
        case verbMoveTo:
          x = path.pointX(point);
          y = path.pointY(point);
          point += 1;
          startX = x;
          startY = y;
          open = true;
          _restart();
        case verbLineTo:
          final double nx = path.pointX(point);
          final double ny = path.pointY(point);
          point += 1;
          _line(x, y, nx, ny);
          x = nx;
          y = ny;
        case verbQuadraticTo:
          final double cx = path.pointX(point);
          final double cy = path.pointY(point);
          final double nx = path.pointX(point + 1);
          final double ny = path.pointY(point + 1);
          point += 2;
          // Elevated to a cubic, exactly: one curve case.
          _cubic(x, y, x + 2 * (cx - x) / 3, y + 2 * (cy - y) / 3,
              nx + 2 * (cx - nx) / 3, ny + 2 * (cy - ny) / 3, nx, ny);
          x = nx;
          y = ny;
        case verbCubicTo:
          final double c1x = path.pointX(point);
          final double c1y = path.pointY(point);
          final double c2x = path.pointX(point + 1);
          final double c2y = path.pointY(point + 1);
          final double nx = path.pointX(point + 2);
          final double ny = path.pointY(point + 2);
          point += 3;
          _cubic(x, y, c1x, c1y, c2x, c2y, nx, ny);
          x = nx;
          y = ny;
        case verbClose:
          // The closing edge is dashed like any other; the contour itself
          // is not closed, because the pieces are open dashes.
          if (open && (x != startX || y != startY)) {
            _line(x, y, startX, startY);
          }
          x = startX;
          y = startY;
          open = false;
      }
    }
  }

  /// Emits the kept part of a segment whose position at arc length `s` is
  /// [at] and whose sub-segment between two lengths [piece] draws.
  void _walk(
    double length,
    (double, double) Function(double s) at,
    void Function(double s0, double s1) piece,
  ) {
    var s = 0.0;
    while (true) {
      final double step = math.min(_remaining, length - s);
      if (_on) {
        if (!_penDown) {
          final (double px, double py) = at(s);
          _count();
          out.moveTo(px, py);
          _penDown = true;
          if (step <= 0 && _remaining <= 0) {
            // A zero-length dash: the lone point is the dot.
            out.lineTo(px, py);
          }
        }
        if (step > 0) piece(s, s + step);
      }
      s += step;
      _remaining -= step;
      if (_remaining <= 1e-12) {
        _advance();
        // A run of zero-length intervals must still move on.
        var guard = intervals.length;
        while (_remaining <= 0 && guard-- > 0) {
          if (_on) {
            final (double px, double py) = at(s);
            _count();
            out
              ..moveTo(px, py)
              ..lineTo(px, py);
          }
          _advance();
        }
      }
      if (s >= length - 1e-12) return;
    }
  }

  void _line(double x0, double y0, double x1, double y1) {
    final double dx = x1 - x0;
    final double dy = y1 - y0;
    final double length = math.sqrt(dx * dx + dy * dy);
    if (length == 0) return;
    _walk(
      length,
      (double s) => (x0 + dx * s / length, y0 + dy * s / length),
      (double s0, double s1) =>
          out.lineTo(x0 + dx * s1 / length, y0 + dy * s1 / length),
    );
  }

  void _cubic(double x0, double y0, double x1, double y1, double x2, double y2,
      double x3, double y3) {
    final _ArcTable table = _ArcTable(x0, y0, x1, y1, x2, y2, x3, y3);
    if (table.length == 0) return;
    _walk(
      table.length,
      (double s) => _point(table.tAt(s), x0, y0, x1, y1, x2, y2, x3, y3),
      (double s0, double s1) {
        final double t0 = table.tAt(s0);
        final double t1 = table.tAt(s1);
        final Float64List c = _subCubic(t0, t1, x0, y0, x1, y1, x2, y2, x3, y3);
        out.cubicTo(c[2], c[3], c[4], c[5], c[6], c[7]);
      },
    );
  }
}

(double, double) _point(double t, double x0, double y0, double x1, double y1,
    double x2, double y2, double x3, double y3) {
  final double u = 1 - t;
  final double a = u * u * u;
  final double b = 3 * u * u * t;
  final double c = 3 * u * t * t;
  final double d = t * t * t;
  return (
    a * x0 + b * x1 + c * x2 + d * x3,
    a * y0 + b * y1 + c * y2 + d * y3,
  );
}

/// The cubic between parameters [t0] and [t1] of the given one, as eight
/// coordinates: start, two controls, end.
Float64List _subCubic(double t0, double t1, double x0, double y0, double x1,
    double y1, double x2, double y2, double x3, double y3) {
  // Split at t1, keep the left part; split that at t0 / t1, keep the right.
  Float64List left(double t, Float64List p) {
    double lerp(double a, double b) => a + (b - a) * t;
    final double ax = lerp(p[0], p[2]), ay = lerp(p[1], p[3]);
    final double bx = lerp(p[2], p[4]), by = lerp(p[3], p[5]);
    final double cx = lerp(p[4], p[6]), cy = lerp(p[5], p[7]);
    final double dx = lerp(ax, bx), dy = lerp(ay, by);
    final double ex = lerp(bx, cx), ey = lerp(by, cy);
    final double fx = lerp(dx, ex), fy = lerp(dy, ey);
    return Float64List.fromList(<double>[p[0], p[1], ax, ay, dx, dy, fx, fy]);
  }

  Float64List right(double t, Float64List p) {
    double lerp(double a, double b) => a + (b - a) * t;
    final double ax = lerp(p[0], p[2]), ay = lerp(p[1], p[3]);
    final double bx = lerp(p[2], p[4]), by = lerp(p[3], p[5]);
    final double cx = lerp(p[4], p[6]), cy = lerp(p[5], p[7]);
    final double dx = lerp(ax, bx), dy = lerp(ay, by);
    final double ex = lerp(bx, cx), ey = lerp(by, cy);
    final double fx = lerp(dx, ex), fy = lerp(dy, ey);
    return Float64List.fromList(<double>[fx, fy, ex, ey, cx, cy, p[6], p[7]]);
  }

  final Float64List whole =
      Float64List.fromList(<double>[x0, y0, x1, y1, x2, y2, x3, y3]);
  final Float64List head = t1 >= 1 ? whole : left(t1, whole);
  if (t0 <= 0) return head;
  return right(t1 <= 0 ? 0 : t0 / t1, head);
}

/// Arc length along a cubic, sampled: length at evenly spaced parameters,
/// read back the other way by interpolating between samples.
final class _ArcTable {
  _ArcTable(double x0, double y0, double x1, double y1, double x2, double y2,
      double x3, double y3) {
    // More samples for a longer control polygon: about one per two units,
    // between 16 and 256, which keeps a dash's end within a small fraction
    // of a unit of where it belongs at any size the curve is drawn.
    final double hull =
        _dist(x0, y0, x1, y1) + _dist(x1, y1, x2, y2) + _dist(x2, y2, x3, y3);
    final int n = (hull / 2).ceil().clamp(16, 256);
    _lengths = Float64List(n + 1);
    var (double px, double py) = (x0, y0);
    var sum = 0.0;
    for (var i = 1; i <= n; i++) {
      final (double qx, double qy) =
          _point(i / n, x0, y0, x1, y1, x2, y2, x3, y3);
      sum += _dist(px, py, qx, qy);
      _lengths[i] = sum;
      px = qx;
      py = qy;
    }
    length = sum;
  }

  late final Float64List _lengths;
  late final double length;

  static double _dist(double ax, double ay, double bx, double by) {
    final double dx = bx - ax;
    final double dy = by - ay;
    return math.sqrt(dx * dx + dy * dy);
  }

  /// The parameter at arc length [s].
  double tAt(double s) {
    if (s <= 0) return 0;
    if (s >= length) return 1;
    var lo = 0;
    var hi = _lengths.length - 1;
    while (hi - lo > 1) {
      final int mid = (lo + hi) >> 1;
      if (_lengths[mid] < s) {
        lo = mid;
      } else {
        hi = mid;
      }
    }
    final double span = _lengths[hi] - _lengths[lo];
    final double f = span <= 0 ? 0 : (s - _lengths[lo]) / span;
    return (lo + f) / (_lengths.length - 1);
  }
}
