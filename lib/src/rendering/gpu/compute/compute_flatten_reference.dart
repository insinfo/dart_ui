/// The CPU oracle for the GPU flatten stage.
///
/// The specification it implements is stated once, in
/// `compute_curve_scene.dart`. This file computes it in Dart and
/// `compute_flatten_shader.dart` computes it in HLSL; a parity test that
/// compares them is only meaningful because both obey a definition neither of
/// them owns.
///
/// ## Why the arithmetic is deliberately float32 and not float64
///
/// Every other CPU oracle in this renderer computes in Dart's native float64
/// and states the resulting deviation from the shader as a tolerance -
/// `ComputeTileCpuReference` does exactly that, and the coverage parity test
/// records "one flipped subsample" as the bound. That works there because the
/// output is a *coverage byte*: a float64/float32 disagreement moves at most
/// one subsample and the answer is still a number in the same array slot.
///
/// It does not work here, because the first thing this stage produces is a
/// **segment count**, and a count feeds a prefix sum that fixes where every
/// later segment lands. A single curve counted as 9 on one side and 10 on the
/// other does not shift a pixel; it shifts every subsequent segment in the
/// buffer by four floats and makes the comparison meaningless rather than
/// approximate.
///
/// So this file rounds to float32 after every operation, through [_f], which is
/// exact: for `+`, `-`, `*`, `/` and `sqrt` over float32 operands, computing in
/// float64 and rounding once to float32 gives the correctly rounded float32
/// result, because 53 >= 2 * 24 + 2. What remains between this and the shader
/// is not precision but **association** - a compiler is free to contract
/// `a * b + c` into one operation - which is why the parity test measures the
/// coordinate deviation rather than asserting zero, and why
/// [segmentCountMargin] exists to say how far each curve is from the count
/// boundary where association could change an integer.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import '../../../geometry/path.dart';
import '../../../geometry/transform2d.dart';
import 'compute_curve_scene.dart';

final Float32List _rounding = Float32List(1);

/// [value] rounded to the nearest float32, which is what the shader stores.
double _f(double value) {
  _rounding[0] = value;
  return _rounding[0];
}

/// Flattens a [ComputeCurveUpload] the way the GPU stage is specified to.
final class ComputeFlattenReference {
  ComputeFlattenReference(this.upload);

  final ComputeCurveUpload upload;

  int get curveCount => upload.curveCount;

  Uint32List? _counts;
  Uint32List? _offsets;
  Float32List? _segments;

  /// `n` for [curve]: how many line segments it flattens into.
  int segmentCount(int curve) => counts[curve];

  /// One entry per curve.
  Uint32List get counts {
    final Uint32List? cached = _counts;
    if (cached != null) return cached;
    final Uint32List result = Uint32List(curveCount);
    for (var curve = 0; curve < curveCount; curve++) {
      result[curve] = _countOf(curve);
    }
    return _counts = result;
  }

  /// Exclusive prefix sum of [counts], with the grand total appended.
  ///
  /// `curveCount + 1` entries, so `offsets[i + 1] - offsets[i]` is the count of
  /// curve `i` for every `i` and the total needs no special case.
  Uint32List get offsets {
    final Uint32List? cached = _offsets;
    if (cached != null) return cached;
    final Uint32List source = counts;
    final Uint32List result = Uint32List(curveCount + 1);
    var running = 0;
    for (var curve = 0; curve < curveCount; curve++) {
      result[curve] = running;
      running += source[curve];
    }
    result[curveCount] = running;
    return _offsets = result;
  }

  int get totalSegments => offsets[curveCount];

  /// `x0, y0, x1, y1` per segment, in device space, in curve order.
  Float32List get segments {
    final Float32List? cached = _segments;
    if (cached != null) return cached;
    final Uint32List starts = offsets;
    final Float32List result = Float32List(totalSegments * 4);
    for (var curve = 0; curve < curveCount; curve++) {
      final int n = counts[curve];
      final int base = starts[curve] * 4;
      for (var j = 0; j < n; j++) {
        final ComputeFlattenPoint start = evaluateAt(curve, j, n);
        final ComputeFlattenPoint end = evaluateAt(curve, j + 1, n);
        result[base + j * 4 + 0] = start.x;
        result[base + j * 4 + 1] = start.y;
        result[base + j * 4 + 2] = end.x;
        result[base + j * 4 + 3] = end.y;
      }
    }
    return _segments = result;
  }

  /// How far [curve]'s `sqrt(ratio)` is from the integer that `ceil` snaps it
  /// to, in units of that integer.
  ///
  /// The number that says whether an exact count comparison against the shader
  /// is a fair test or a coin flip. A margin of `1e-3` means association inside
  /// the shader would have to change `sqrt(ratio)` by a part in a thousand to
  /// move the count - four orders of magnitude beyond float32's `6e-8` - so an
  /// observed disagreement would be a real defect. A margin near zero means the
  /// curve sits on the boundary and either count is defensible.
  ///
  /// Returns [double.infinity] for the two clamped ends, where no boundary is
  /// in play at all.
  double segmentCountMargin(int curve) {
    final double ratio = _ratioOf(curve);
    if (!(ratio > 0) || !ratio.isFinite) return double.infinity;
    final double root = _f(math.sqrt(ratio));
    final double ceiling = root.ceilToDouble();
    if (ceiling >= kMaxSegmentsPerCurve) return double.infinity;
    if (ceiling <= 1) return double.infinity;
    return (ceiling - root).abs() / ceiling;
  }

  /// The device-space point at parameter `index / total` on [curve].
  ///
  /// Endpoints are the encoded ones rather than an evaluation at `t = 0` or
  /// `t = 1`: the two agree mathematically and can differ in the last bit, and
  /// a closed contour that closes to within one bit is a contour with a crack
  /// in it.
  ComputeFlattenPoint evaluateAt(int curve, int index, int total) {
    final int kind = upload.curves[curve * kComputeCurveHeaderStride];
    final int path = upload.curves[curve * kComputeCurveHeaderStride + 1];
    final int base = curve * kComputeCurvePointStride;
    final Float32List points = upload.curvePoints;
    final ComputeFlattenPoint p0 =
        _transform(path, points[base + 0], points[base + 1]);
    final ComputeFlattenPoint p3 =
        _transform(path, points[base + 6], points[base + 7]);
    if (index <= 0) return p0;
    if (index >= total) return p3;
    if (kind == kComputeCurveKindLine) return p3;

    final double t = _f(index / total);
    final double u = _f(1.0 - t);
    final ComputeFlattenPoint p1 =
        _transform(path, points[base + 2], points[base + 3]);
    if (kind == kComputeCurveKindQuadratic) {
      final ComputeFlattenPoint p2 =
          _transform(path, points[base + 4], points[base + 5]);
      final double uu = _f(u * u);
      final double ut2 = _f(_f(2.0 * u) * t);
      final double tt = _f(t * t);
      return ComputeFlattenPoint(
        _f(_f(_f(uu * p0.x) + _f(ut2 * p1.x)) + _f(tt * p2.x)),
        _f(_f(_f(uu * p0.y) + _f(ut2 * p1.y)) + _f(tt * p2.y)),
      );
    }
    final ComputeFlattenPoint p2 =
        _transform(path, points[base + 4], points[base + 5]);
    final double uu = _f(u * u);
    final double uuu = _f(uu * u);
    final double tt = _f(t * t);
    final double ttt = _f(tt * t);
    final double uut3 = _f(_f(3.0 * uu) * t);
    final double utt3 = _f(_f(3.0 * u) * tt);
    return ComputeFlattenPoint(
      _f(_f(_f(_f(uuu * p0.x) + _f(uut3 * p1.x)) + _f(utt3 * p2.x)) +
          _f(ttt * p3.x)),
      _f(_f(_f(_f(uuu * p0.y) + _f(uut3 * p1.y)) + _f(utt3 * p2.y)) +
          _f(ttt * p3.y)),
    );
  }

  /// The device-space point at parameter [t] on [curve], in float64.
  ///
  /// The *true* curve, as far as a test is concerned: no float32 rounding and
  /// no subdivision. `compute_flatten_reference_test.dart` uses it to measure
  /// how far the flattened polyline strays from the shape it replaces, which is
  /// the only check that says the specification is right rather than merely
  /// self-consistent.
  (double, double) evaluateExact(int curve, double t) {
    final int kind = upload.curves[curve * kComputeCurveHeaderStride];
    final int path = upload.curves[curve * kComputeCurveHeaderStride + 1];
    final int base = curve * kComputeCurvePointStride;
    final Float32List points = upload.curvePoints;
    final ComputeFlattenPoint p0 =
        _transformExact(path, points[base + 0], points[base + 1]);
    final ComputeFlattenPoint p1 =
        _transformExact(path, points[base + 2], points[base + 3]);
    final ComputeFlattenPoint p2 =
        _transformExact(path, points[base + 4], points[base + 5]);
    final ComputeFlattenPoint p3 =
        _transformExact(path, points[base + 6], points[base + 7]);
    final double u = 1.0 - t;
    return switch (kind) {
      kComputeCurveKindLine => (
          u * p0.x + t * p3.x,
          u * p0.y + t * p3.y,
        ),
      kComputeCurveKindQuadratic => (
          u * u * p0.x + 2 * u * t * p1.x + t * t * p2.x,
          u * u * p0.y + 2 * u * t * p1.y + t * t * p2.y,
        ),
      _ => (
          u * u * u * p0.x +
              3 * u * u * t * p1.x +
              3 * u * t * t * p2.x +
              t * t * t * p3.x,
          u * u * u * p0.y +
              3 * u * u * t * p1.y +
              3 * u * t * t * p2.y +
              t * t * t * p3.y,
        ),
    };
  }

  int _countOf(int curve) {
    final int kind = upload.curves[curve * kComputeCurveHeaderStride];
    if (kind == kComputeCurveKindLine) return 1;
    return _segmentsForRatio(_ratioOf(curve));
  }

  /// The `ratio` whose square root the count is the ceiling of.
  double _ratioOf(int curve) {
    final int kind = upload.curves[curve * kComputeCurveHeaderStride];
    if (kind == kComputeCurveKindLine) return 0;
    final int path = upload.curves[curve * kComputeCurveHeaderStride + 1];
    final int base = curve * kComputeCurvePointStride;
    final Float32List points = upload.curvePoints;
    final double tolerance =
        upload.transforms[path * kComputeCurveTransformStride + 6];
    final ComputeFlattenPoint p0 =
        _transform(path, points[base + 0], points[base + 1]);
    final ComputeFlattenPoint p1 =
        _transform(path, points[base + 2], points[base + 3]);
    final ComputeFlattenPoint p2 =
        _transform(path, points[base + 4], points[base + 5]);
    if (kind == kComputeCurveKindQuadratic) {
      final double ddx = _second(p0.x, p1.x, p2.x);
      final double ddy = _second(p0.y, p1.y, p2.y);
      final double deviation = _f(math.sqrt(_f(_f(ddx * ddx) + _f(ddy * ddy))));
      return _f(deviation / _f(4.0 * _f(tolerance)));
    }
    final ComputeFlattenPoint p3 =
        _transform(path, points[base + 6], points[base + 7]);
    final double d0x = _second(p0.x, p1.x, p2.x);
    final double d0y = _second(p0.y, p1.y, p2.y);
    final double d1x = _second(p1.x, p2.x, p3.x);
    final double d1y = _second(p1.y, p2.y, p3.y);
    final double m0 = _f(_f(d0x * d0x) + _f(d0y * d0y));
    final double m1 = _f(_f(d1x * d1x) + _f(d1y * d1y));
    final double deviation = _f(math.sqrt(m0 > m1 ? m0 : m1));
    return _f(_f(3.0 * deviation) / _f(4.0 * _f(tolerance)));
  }

  /// `a - 2 b + c`, the second difference of a control polygon.
  static double _second(double a, double b, double c) =>
      _f(_f(a - _f(2.0 * b)) + c);

  static int _segmentsForRatio(double ratio) {
    if (!(ratio > 0)) return 1;
    if (!ratio.isFinite) return kMaxSegmentsPerCurve;
    final int n = _f(math.sqrt(ratio)).ceil();
    if (n < 1) return 1;
    return n > kMaxSegmentsPerCurve ? kMaxSegmentsPerCurve : n;
  }

  ComputeFlattenPoint _transform(int path, double x, double y) {
    final int base = path * kComputeCurveTransformStride;
    final Float32List m = upload.transforms;
    return ComputeFlattenPoint(
      _f(_f(_f(m[base + 0] * x) + _f(m[base + 2] * y)) + m[base + 4]),
      _f(_f(_f(m[base + 1] * x) + _f(m[base + 3] * y)) + m[base + 5]),
    );
  }

  ComputeFlattenPoint _transformExact(int path, double x, double y) {
    final int base = path * kComputeCurveTransformStride;
    final Float32List m = upload.transforms;
    return ComputeFlattenPoint(
      m[base + 0] * x + m[base + 2] * y + m[base + 4],
      m[base + 1] * x + m[base + 3] * y + m[base + 5],
    );
  }
}

/// A device-space point.
///
/// A named type rather than a record because [ComputeFlattenReference.
/// evaluateAt] is the shape a parity test walks segment by segment, and
/// `point.x` reads better there than `point.$1`.
final class ComputeFlattenPoint {
  const ComputeFlattenPoint(this.x, this.y);
  final double x;
  final double y;
}

/// Ray-crossing coverage over a raw `x0, y0, x1, y1` segment array.
///
/// Deliberately *not* a method of either flatten implementation: its whole
/// purpose is to be applied unchanged to two different segment sets - one the
/// GPU produced and one `Path.flatten` produced - so that a difference in the
/// picture is attributable to the segments and to nothing else. It is the same
/// crossing rule and the same quantisation `ComputeTileCpuReference` uses, over
/// a flat array instead of a plan.
Uint8List coverageOfSegments(
  Float32List segments, {
  required int width,
  required int height,
  bool evenOdd = false,
  int sampleGrid = 4,
}) {
  if (sampleGrid <= 0 || sampleGrid > 16) {
    throw RangeError.range(sampleGrid, 1, 16, 'sampleGrid');
  }
  final Uint8List result = Uint8List(width * height);
  final int count = segments.length ~/ 4;
  final int samples = sampleGrid * sampleGrid;
  for (var pixelY = 0; pixelY < height; pixelY++) {
    for (var pixelX = 0; pixelX < width; pixelX++) {
      var covered = 0;
      for (var sampleY = 0; sampleY < sampleGrid; sampleY++) {
        final double y = pixelY + (sampleY + 0.5) / sampleGrid;
        for (var sampleX = 0; sampleX < sampleGrid; sampleX++) {
          final double x = pixelX + (sampleX + 0.5) / sampleGrid;
          var winding = 0;
          var parity = false;
          for (var segment = 0; segment < count; segment++) {
            final double x0 = segments[segment * 4 + 0];
            final double y0 = segments[segment * 4 + 1];
            final double x1 = segments[segment * 4 + 2];
            final double y1 = segments[segment * 4 + 3];
            final bool upward = y0 <= y && y1 > y;
            final bool downward = y1 <= y && y0 > y;
            if (!upward && !downward) continue;
            final double crossingX = x0 + (y - y0) * (x1 - x0) / (y1 - y0);
            if (crossingX <= x) continue;
            parity = !parity;
            winding += upward ? 1 : -1;
          }
          if (evenOdd ? parity : winding != 0) covered++;
        }
      }
      result[pixelY * width + pixelX] =
          (covered * 255 + samples ~/ 2) ~/ samples;
    }
  }
  return result;
}

/// `Path.flatten`, re-expressed as the same `x0, y0, x1, y1` array the flatten
/// stage produces, so the two can be rasterised by [coverageOfSegments] and
/// compared.
///
/// Contours are closed and degenerate edges are kept, matching the GPU stage;
/// `ComputeTileScene`'s sink drops the degenerate ones, which changes the
/// buffer but - see `compute_curve_scene.dart` - not the picture.
Float32List flattenOnCpu(
  Path path, {
  double tolerance = kDefaultFlattenTolerance,
  Transform2D transform = Transform2D.identity,
}) {
  final FlattenedPath flattened = path.flatten(tolerance, transform: transform);
  final List<double> values = <double>[];
  for (var contour = 0; contour < flattened.contourCount; contour++) {
    final int start = flattened.contourStarts[contour];
    final int end = flattened.contourStarts[contour + 1];
    if (end - start < 2) continue;
    for (var point = start; point + 1 < end; point++) {
      values
        ..add(flattened.pointX(point))
        ..add(flattened.pointY(point))
        ..add(flattened.pointX(point + 1))
        ..add(flattened.pointY(point + 1));
    }
    final double lastX = flattened.pointX(end - 1);
    final double lastY = flattened.pointY(end - 1);
    final double firstX = flattened.pointX(start);
    final double firstY = flattened.pointY(start);
    if (lastX != firstX || lastY != firstY) {
      values
        ..add(lastX)
        ..add(lastY)
        ..add(firstX)
        ..add(firstY);
    }
  }
  return Float32List.fromList(values);
}
