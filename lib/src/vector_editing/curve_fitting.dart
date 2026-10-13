/// Fitting Béziers to a hand-drawn stroke: what turns the Freehand tool's
/// trail of pointer positions into a curve of a few nodes.
///
/// Philip Schneider's algorithm ("An Algorithm for Automatically Fitting
/// Digitized Curves", Graphics Gems, 1990): one cubic by least squares over
/// the chord-length parameters, refined by Newton-Raphson reparameterisation
/// while it is close; split at the worst point and fitted again on each side
/// when it is not. The halves share a tangent at the split, so the node
/// there is smooth.
///
/// A stroke that turns sharply is cut at its corners first and each stretch
/// is fitted alone, so a corner stays a cusp rather than being rounded off.
library;

import 'dart:math' as math;

import '../geometry/offset.dart';
import '../graphics/vector/constants.dart';
import '../graphics/vector/primitives.dart';

/// The fitting.
abstract final class CurveFitting {
  /// How sharp a turn, in degrees, is a corner.
  static const double cornerDegrees = 70;

  /// Cubic segments through [points], none further than [error] from the
  /// stroke, starting at `points.first`. Nodes where two fitted halves meet
  /// are smooth; corners are cusps.
  static List<CurvePoint> fit(List<Offset> points, double error) {
    final List<Offset> stroke = _distinct(points);
    if (stroke.length < 2) return <CurvePoint>[];
    final List<CurvePoint> out = <CurvePoint>[];
    final List<int> corners = _corners(stroke, error);
    for (var i = 0; i + 1 < corners.length; i++) {
      final List<Offset> stretch =
          stroke.sublist(corners[i], corners[i + 1] + 1);
      // Each stretch ends on a cusp: a corner, or the stroke's end.
      _Fitter(stretch, error, out).run();
    }
    return out;
  }

  static List<Offset> _distinct(List<Offset> points) {
    final List<Offset> out = <Offset>[];
    for (final Offset point in points) {
      if (out.isEmpty || (point - out.last).distance > 1e-9) out.add(point);
    }
    return out;
  }

  /// Indices of the stroke's ends and of the corners between them.
  ///
  /// The turn at a point is measured between the chords to the points a
  /// short arc length before and after it - long enough that the jitter of
  /// a hand does not read as a corner, short enough that a real corner is
  /// not averaged away.
  static List<int> _corners(List<Offset> stroke, double error) {
    final int n = stroke.length;
    final List<double> arc = List<double>.filled(n, 0);
    for (var i = 1; i < n; i++) {
      arc[i] = arc[i - 1] + (stroke[i] - stroke[i - 1]).distance;
    }
    final double reach = math.max(error * 3, arc.last / 50);
    const double threshold = cornerDegrees * math.pi / 180;
    final List<double> turn = List<double>.filled(n, 0);
    var back = 0;
    var ahead = 0;
    for (var i = 1; i < n - 1; i++) {
      while (back < i && arc[i] - arc[back + 1] >= reach) {
        back++;
      }
      if (ahead < i) ahead = i;
      while (ahead < n - 1 && arc[ahead] - arc[i] < reach) {
        ahead++;
      }
      if (arc[i] - arc[back] < reach * .5 || arc[ahead] - arc[i] < reach * .5) {
        continue;
      }
      final Offset into = stroke[i] - stroke[back];
      final Offset out = stroke[ahead] - stroke[i];
      final double angle =
          (math.atan2(out.dy, out.dx) - math.atan2(into.dy, into.dx)).abs();
      turn[i] = angle > math.pi ? 2 * math.pi - angle : angle;
    }
    final List<int> corners = <int>[0];
    for (var i = 1; i < n - 1; i++) {
      if (turn[i] < threshold) continue;
      // The sharpest point of a run of sharp ones.
      if (turn[i] < turn[i - 1] || turn[i] < turn[i + 1]) continue;
      if (turn[i] == turn[i - 1] && corners.last == i - 1) continue;
      if (arc[i] - arc[corners.last] < reach) continue;
      corners.add(i);
    }
    if (corners.length > 1 && arc.last - arc[corners.last] < reach) {
      corners.removeLast();
    }
    corners.add(n - 1);
    return corners;
  }
}

final class _Fitter {
  _Fitter(this.points, this.error, this.out);

  final List<Offset> points;
  final double error;
  final List<CurvePoint> out;

  void run() {
    final int last = points.length - 1;
    _fitCubic(0, last, _unit(points[1] - points[0]),
        _unit(points[last - 1] - points[last]));
  }

  static Offset _unit(Offset v) {
    final double length = v.distance;
    return length == 0 ? Offset.zero : v / length;
  }

  void _emit(List<Offset> bezier, {required bool smoothEnd}) {
    out.add(CurvePoint(bezier[1], bezier[2], bezier[3],
        smoothEnd ? NodeType.smooth : NodeType.cusp));
  }

  /// Fits points [first]..[last]; [tHat1] leaves the first along the
  /// stroke, [tHat2] leaves the last back into it.
  void _fitCubic(int first, int last, Offset tHat1, Offset tHat2,
      {bool smoothEnd = false}) {
    final double errorSquared = error * error;
    if (last - first == 1) {
      final double distance = (points[last] - points[first]).distance / 3;
      _emit(<Offset>[
        points[first],
        points[first] + tHat1 * distance,
        points[last] + tHat2 * distance,
        points[last],
      ], smoothEnd: smoothEnd);
      return;
    }
    List<double> u = _chordLength(first, last);
    var split = (first + last) ~/ 2;
    var previous = double.infinity;
    // Paper.js's rule rather than the paper's: reparameterise while it
    // helps, not only once the fit is already close. Chord-length
    // parameters are far off for a stroke drawn at uneven speed, and the
    // first fit of a curve that one cubic describes exactly can miss by
    // more than the paper's 4x threshold.
    for (var i = 0; i < 20; i++) {
      final List<Offset> bezier = _generate(first, last, u, tHat1, tHat2);
      final (double maxError, int worst) = _maxError(first, last, bezier, u);
      if (maxError < errorSquared) {
        _emit(bezier, smoothEnd: smoothEnd);
        return;
      }
      split = worst;
      if (maxError >= previous) break;
      previous = maxError;
      u = _reparameterize(first, last, u, bezier);
    }
    final Offset centre = _unit(points[split - 1] - points[split + 1]);
    _fitCubic(first, split, tHat1, centre, smoothEnd: true);
    _fitCubic(split, last, -centre, tHat2, smoothEnd: smoothEnd);
  }

  List<double> _chordLength(int first, int last) {
    final List<double> u = <double>[0];
    for (var i = first + 1; i <= last; i++) {
      u.add(u.last + (points[i] - points[i - 1]).distance);
    }
    final double total = u.last;
    return <double>[for (final double d in u) total == 0 ? 0 : d / total];
  }

  /// The least-squares cubic with the given end tangents (the two
  /// distances along them are the unknowns).
  List<Offset> _generate(
      int first, int last, List<double> u, Offset tHat1, Offset tHat2) {
    final Offset p0 = points[first];
    final Offset p3 = points[last];
    double c00 = 0, c01 = 0, c11 = 0, x0 = 0, x1 = 0;
    for (var i = 0; i < u.length; i++) {
      final double t = u[i];
      final double s = 1 - t;
      final double b0 = s * s * s;
      final double b1 = 3 * t * s * s;
      final double b2 = 3 * t * t * s;
      final double b3 = t * t * t;
      final Offset a1 = tHat1 * b1;
      final Offset a2 = tHat2 * b2;
      c00 += _dot(a1, a1);
      c01 += _dot(a1, a2);
      c11 += _dot(a2, a2);
      final Offset tmp = points[first + i] - (p0 * (b0 + b1) + p3 * (b2 + b3));
      x0 += _dot(a1, tmp);
      x1 += _dot(a2, tmp);
    }
    final double det = c00 * c11 - c01 * c01;
    double alpha1 = 0;
    double alpha2 = 0;
    if (det.abs() > 1e-12) {
      alpha1 = (x0 * c11 - x1 * c01) / det;
      alpha2 = (c00 * x1 - c01 * x0) / det;
    }
    final double segment = (p3 - p0).distance;
    final double floor = segment * 1e-6;
    if (alpha1 < floor || alpha2 < floor) {
      // Degenerate or wildly wrong: Wu and Barsky's heuristic.
      alpha1 = alpha2 = segment / 3;
    }
    return <Offset>[p0, p0 + tHat1 * alpha1, p3 + tHat2 * alpha2, p3];
  }

  static double _dot(Offset a, Offset b) => a.dx * b.dx + a.dy * b.dy;

  static Offset _at(List<Offset> b, double t) {
    final double s = 1 - t;
    return b[0] * (s * s * s) +
        b[1] * (3 * s * s * t) +
        b[2] * (3 * s * t * t) +
        b[3] * (t * t * t);
  }

  (double, int) _maxError(
      int first, int last, List<Offset> bezier, List<double> u) {
    var split = (last - first + 1) ~/ 2 + first;
    var worst = 0.0;
    for (var i = first + 1; i < last; i++) {
      final double d = (_at(bezier, u[i - first]) - points[i]).distanceSquared;
      if (d >= worst) {
        worst = d;
        split = i;
      }
    }
    return (worst, split);
  }

  /// One Newton-Raphson step per point towards its nearest parameter.
  List<double> _reparameterize(
      int first, int last, List<double> u, List<Offset> b) {
    final List<Offset> d1 = <Offset>[
      for (var i = 0; i < 3; i++) (b[i + 1] - b[i]) * 3
    ];
    final List<Offset> d2 = <Offset>[
      for (var i = 0; i < 2; i++) (d1[i + 1] - d1[i]) * 2
    ];
    return <double>[
      for (var i = first; i <= last; i++)
        () {
          final double t = u[i - first];
          final double s = 1 - t;
          final Offset q = _at(b, t);
          final Offset q1 =
              d1[0] * (s * s) + d1[1] * (2 * s * t) + d1[2] * (t * t);
          final Offset q2 = d2[0] * s + d2[1] * t;
          final Offset diff = q - points[i];
          final double numerator = _dot(diff, q1);
          final double denominator = _dot(q1, q1) + _dot(diff, q2);
          if (denominator.abs() < 1e-12) return t;
          return (t - numerator / denominator).clamp(0.0, 1.0);
        }(),
    ];
  }
}
