/// The scene a GPU flatten stage consumes: curves, not segments.
///
/// ## Why this exists next to `ComputeTileScene`
///
/// `ComputeTileScene` takes a [Path] and hands the GPU **line segments**: it
/// calls `Path.flattenTo` on the CPU, closes contours, drops zero-length edges
/// and computes bounds, all before a device is involved. Everything downstream
/// of that - tile binning, per-tile segment lists, backdrops, the coverage
/// shader - consumes the result. Measured on this machine, that CPU half costs
/// roughly 580-640 microseconds per frame for one rounded panel
/// (`doc/architecture/ACELERACAO_GPU_VETORIAL.md`), and it is the part of
/// approach D that a Vello-style pipeline runs on the GPU.
///
/// This file is the input side of moving it. It encodes a path as the **curve
/// stream** it already is - one record per `lineTo`/`quadraticTo`/`cubicTo`,
/// plus one per contour close - and leaves subdivision entirely undone. The
/// per-path affine transform travels as data rather than being applied here,
/// because applying it is `O(control points)` of exactly the arithmetic the
/// flatten kernel is already doing.
///
/// What the encoder still does on the CPU is a per-*contour* decision and not a
/// per-*point* one: whether an open contour needs an explicit closing line. See
/// [ComputeCurveScene.appendPath].
///
/// ## The flatten specification, fixed here and implemented twice
///
/// The spec below is what `ComputeFlattenReference` computes in Dart and what
/// `compute_flatten_shader.dart` computes in HLSL. It is stated here because
/// the two implementations must agree about it exactly, and neither file is a
/// better place to define something both of them obey.
///
/// **Segment count.** Identical to `Path`'s, which is what keeps a path
/// flattened on the GPU visually identical to the same path flattened on the
/// CPU rather than merely similar:
///
///   * a line is one segment;
///   * a quadratic uses `dev = |p0 - 2 p1 + p2|` and `n = segments(dev / (4 t))`;
///   * a cubic uses `dev = max(|p0 - 2 p1 + p2|, |p1 - 2 p2 + p3|)` and
///     `n = segments(3 dev / (4 t))`;
///   * `segments(r) = clamp(ceil(sqrt(r)), 1, kMaxSegmentsPerCurve)`, and
///     `r <= 0` or a non-finite `r` are the two ends of that clamp.
///
/// All of it in **device space**: the transform is applied to the control
/// points before the count is chosen, so a magnified path gets more segments
/// instead of a faceted outline. That is `Path.flattenTo`'s rule and the reason
/// [kDefaultFlattenTolerance] is a quarter of a *device* pixel.
///
/// **Segment positions - and the one deliberate difference.** `Path.flattenTo`
/// walks a curve by forward differences: it holds an accumulator and adds a
/// constant-ish increment `n - 1` times. That is the right shape for one CPU
/// thread and the wrong shape for a GPU, where the whole point is that segment
/// `j` is computed by a thread that has never seen segment `j - 1`. So this
/// spec **evaluates the Bezier directly** at `t = j / n`:
///
///   * segment `j` runs from `B(j / n)` to `B((j + 1) / n)`;
///   * segment `0` starts at `p0` exactly and segment `n - 1` ends at the
///     curve's real end point exactly, so a closed contour still closes;
///   * adjacent segments meet exactly, because both threads evaluate `B(t)`
///     for the same `t` with the same instruction sequence and floating point
///     is deterministic. A crack between two subsegments would leak winding
///     through the outline, so this is a correctness property and not a
///     tidiness one.
///
/// Direct evaluation is also *more* accurate than forward differences, which
/// accumulate rounding over `n` steps; `compute_flatten_reference_test.dart`
/// measures the deviation of both from the true curve rather than asserting
/// that claim.
///
/// **Zero-length segments are kept.** `ComputeTileScene`'s CPU sink drops an
/// edge whose endpoints coincide. Dropping them on the GPU is a stream
/// compaction - a second scan and a scatter - and it buys nothing for
/// correctness: the crossing test that consumes a segment is
/// `y0 <= y && y1 > y` (or its mirror), which is false for every `y` when
/// `y0 == y1`, so a degenerate edge contributes to no sample's winding. It
/// costs a slot in a tile's segment list and nothing else.
/// `compute_flatten_reference_test.dart` asserts the coverage equality rather
/// than leaving the argument on paper.
library;

import 'dart:typed_data';

import '../../../geometry/path.dart';
import '../../../geometry/transform2d.dart';

/// A straight line from `p0` to `p3`. `p1` and `p2` are unread.
const int kComputeCurveKindLine = 0;

/// A quadratic Bezier through `p0`, `p1`, `p2`. `p3` is unread.
const int kComputeCurveKindQuadratic = 1;

/// A cubic Bezier through `p0`, `p1`, `p2`, `p3`.
const int kComputeCurveKindCubic = 2;

/// `kind, path, reserved, reserved` per curve, as one `uint4`.
const int kComputeCurveHeaderStride = 4;

/// `x0, y0, x1, y1, x2, y2, x3, y3` per curve, as two `float4`s.
const int kComputeCurvePointStride = 8;

/// `a, b, c, d, tx, ty, tolerance, reserved` per path, as two `float4`s.
const int kComputeCurveTransformStride = 8;

/// `firstCurve, curveCount` per path.
const int kComputeCurvePathStride = 2;

const int _maxUint32 = 0xFFFFFFFF;

/// Why encoding refused a path.
enum ComputeCurveRejection {
  nonFiniteGeometry,
  curveLimitExceeded,
  pathLimitExceeded,
}

final class ComputeCurveError extends StateError {
  ComputeCurveError(this.rejection, String detail)
      : super('${rejection.name}: $detail');

  final ComputeCurveRejection rejection;
}

/// An ordered set of paths encoded as curves, with their transforms.
///
/// Append-only and cheap: the cost is proportional to the path's control
/// points, with no subdivision, no bounds pass and no per-point transform.
final class ComputeCurveScene {
  ComputeCurveScene({
    this.maxCurves = 1 << 22,
    this.maxPaths = 1 << 16,
  }) {
    _checkLimit(maxCurves, 'maxCurves');
    _checkLimit(maxPaths, 'maxPaths');
  }

  final int maxCurves;
  final int maxPaths;

  final List<int> _headers = <int>[];
  final List<double> _points = <double>[];
  final List<double> _transforms = <double>[];
  final List<int> _paths = <int>[];

  int get curveCount => _headers.length ~/ kComputeCurveHeaderStride;
  int get pathCount => _paths.length ~/ kComputeCurvePathStride;
  bool get isEmpty => curveCount == 0;

  /// The curve index range of [path], as `firstCurve` and `curveCount`.
  int pathFirstCurve(int path) => _paths[_pathBase(path) + 0];
  int pathCurveCount(int path) => _paths[_pathBase(path) + 1];

  int curveKind(int curve) => _headers[curve * kComputeCurveHeaderStride + 0];

  int curvePath(int curve) => _headers[curve * kComputeCurveHeaderStride + 1];

  /// One of the eight source-space coordinates of [curve], `0 <= field < 8`.
  double curvePoint(int curve, int field) {
    if (field < 0 || field >= kComputeCurvePointStride) {
      throw RangeError.range(field, 0, kComputeCurvePointStride - 1, 'field');
    }
    return _points[curve * kComputeCurvePointStride + field];
  }

  Transform2D pathTransform(int path) {
    final int base = path * kComputeCurveTransformStride;
    return Transform2D(
      _transforms[base + 0],
      _transforms[base + 1],
      _transforms[base + 2],
      _transforms[base + 3],
      _transforms[base + 4],
      _transforms[base + 5],
    );
  }

  double pathTolerance(int path) =>
      _transforms[path * kComputeCurveTransformStride + 6];

  /// Appends [path]'s curves, returning its index, or -1 when it has none.
  ///
  /// ## Contours are closed here, and that is a per-contour cost
  ///
  /// Filling treats an open contour as closed, so the closing edge has to exist
  /// somewhere. It is emitted here as an ordinary line curve rather than left
  /// for the kernel, because the kernel is indexed by curve and a closing edge
  /// belongs to a *contour*: finding it on the GPU would mean a thread walking
  /// backwards to a `moveTo` it has no index for. Emitting it costs one record
  /// per contour and no subdivision.
  ///
  /// The rule differs from `ComputeTileScene`'s sink in one measurable way. The
  /// sink knows, after flattening, whether the contour produced a non-degenerate
  /// edge, and skips the closing edge when it did not. Here that is not known
  /// yet, so a contour with at least one curve verb gets a closing line even if
  /// every one of its curves collapses to a point. The extra edge is
  /// zero-length in exactly that case, and a zero-length edge crosses no scan
  /// line - see the library comment.
  int appendPath(
    Path path, {
    Transform2D transform = Transform2D.identity,
    double flattenTolerance = kDefaultFlattenTolerance,
  }) {
    if (!flattenTolerance.isFinite || flattenTolerance <= 0) {
      throw ArgumentError.value(
        flattenTolerance,
        'flattenTolerance',
        'must be finite and > 0',
      );
    }
    for (final double value in <double>[
      transform.a,
      transform.b,
      transform.c,
      transform.d,
      transform.tx,
      transform.ty,
    ]) {
      if (!value.isFinite) {
        throw ComputeCurveError(
          ComputeCurveRejection.nonFiniteGeometry,
          'the path transform contains a non-finite coefficient',
        );
      }
    }
    for (var point = 0; point < path.pointCount; point++) {
      if (!path.pointX(point).isFinite || !path.pointY(point).isFinite) {
        throw ComputeCurveError(
          ComputeCurveRejection.nonFiniteGeometry,
          'the source path contains a non-finite float32 coordinate',
        );
      }
    }
    if (pathCount >= maxPaths) {
      throw ComputeCurveError(
        ComputeCurveRejection.pathLimitExceeded,
        'the scene exceeds its configured limit of $maxPaths paths',
      );
    }

    // Encoded into scratch first so a refusal - a curve limit - leaves the
    // scene untouched, the way `ComputeTileScene.appendEncoding` does.
    final List<int> headers = <int>[];
    final List<double> points = <double>[];
    final int path0 = pathCount;

    var index = 0;
    var startX = 0.0;
    var startY = 0.0;
    var currentX = 0.0;
    var currentY = 0.0;
    var open = false;
    var contourHasCurve = false;

    void emit(
      int kind,
      double x0,
      double y0,
      double x1,
      double y1,
      double x2,
      double y2,
      double x3,
      double y3,
    ) {
      headers
        ..add(kind)
        ..add(path0)
        ..add(0)
        ..add(0);
      points
        ..add(x0)
        ..add(y0)
        ..add(x1)
        ..add(y1)
        ..add(x2)
        ..add(y2)
        ..add(x3)
        ..add(y3);
    }

    void closeContour() {
      if (!open) return;
      if (contourHasCurve && (currentX != startX || currentY != startY)) {
        emit(
          kComputeCurveKindLine,
          currentX,
          currentY,
          currentX,
          currentY,
          startX,
          startY,
          startX,
          startY,
        );
      }
      open = false;
      contourHasCurve = false;
    }

    for (var verb = 0; verb < path.verbCount; verb++) {
      switch (path.verbAt(verb)) {
        case verbMoveTo:
          closeContour();
          startX = currentX = path.pointX(index);
          startY = currentY = path.pointY(index);
          index += 1;
          open = true;
        case verbLineTo:
          final double x = path.pointX(index);
          final double y = path.pointY(index);
          index += 1;
          if (!open) {
            startX = currentX = x;
            startY = currentY = y;
            open = true;
            continue;
          }
          emit(kComputeCurveKindLine, currentX, currentY, currentX, currentY, x,
              y, x, y);
          contourHasCurve = true;
          currentX = x;
          currentY = y;
        case verbQuadraticTo:
          final double x1 = path.pointX(index);
          final double y1 = path.pointY(index);
          final double x2 = path.pointX(index + 1);
          final double y2 = path.pointY(index + 1);
          index += 2;
          emit(kComputeCurveKindQuadratic, currentX, currentY, x1, y1, x2, y2,
              x2, y2);
          contourHasCurve = true;
          open = true;
          currentX = x2;
          currentY = y2;
        case verbCubicTo:
          final double x1 = path.pointX(index);
          final double y1 = path.pointY(index);
          final double x2 = path.pointX(index + 1);
          final double y2 = path.pointY(index + 1);
          final double x3 = path.pointX(index + 2);
          final double y3 = path.pointY(index + 2);
          index += 3;
          emit(kComputeCurveKindCubic, currentX, currentY, x1, y1, x2, y2, x3,
              y3);
          contourHasCurve = true;
          open = true;
          currentX = x3;
          currentY = y3;
        case verbClose:
          closeContour();
      }
    }
    closeContour();

    final int added = headers.length ~/ kComputeCurveHeaderStride;
    if (added == 0) return -1;
    if (added > maxCurves - curveCount) {
      throw ComputeCurveError(
        ComputeCurveRejection.curveLimitExceeded,
        'the scene exceeds its configured limit of $maxCurves curves',
      );
    }

    final int firstCurve = curveCount;
    _headers.addAll(headers);
    _points.addAll(points);
    _paths
      ..add(firstCurve)
      ..add(added);
    _transforms
      ..add(transform.a)
      ..add(transform.b)
      ..add(transform.c)
      ..add(transform.d)
      ..add(transform.tx)
      ..add(transform.ty)
      ..add(flattenTolerance)
      ..add(0);
    return path0;
  }

  /// The three read-only buffers a flatten kernel binds, exact-sized.
  ComputeCurveUpload upload() => ComputeCurveUpload(
        curves: Uint32List.fromList(_headers),
        curvePoints: Float32List.fromList(_points),
        transforms: Float32List.fromList(_transforms),
        paths: Uint32List.fromList(_paths),
        curveCount: curveCount,
        pathCount: pathCount,
      );

  int _pathBase(int path) {
    if (path < 0 || path >= pathCount) {
      throw RangeError.range(path, 0, pathCount - 1, 'path');
    }
    return path * kComputeCurvePathStride;
  }

  static void _checkLimit(int value, String name) {
    if (value <= 0 || value > _maxUint32) {
      throw RangeError.range(value, 1, _maxUint32, name);
    }
  }
}

/// The curve stream as typed arrays, uploaded verbatim.
///
/// Verbatim in the same sense `ComputeTileSceneUpload` means it: every array is
/// exact-sized, already `uint32` or `float32`, and already in a stride a
/// `StructuredBuffer` can declare.
final class ComputeCurveUpload {
  const ComputeCurveUpload({
    required this.curves,
    required this.curvePoints,
    required this.transforms,
    required this.paths,
    required this.curveCount,
    required this.pathCount,
  });

  /// `kind, path, 0, 0` per curve. Bound as `StructuredBuffer<uint4>`.
  final Uint32List curves;

  /// Source-space control points, eight per curve, as two `float4`s.
  final Float32List curvePoints;

  /// `a, b, c, d` then `tx, ty, tolerance, 0` per path, as two `float4`s.
  final Float32List transforms;

  /// `firstCurve, curveCount` per path. Unread by the flatten kernels; a
  /// consumer that groups segments back into paths needs it.
  final Uint32List paths;

  final int curveCount;
  final int pathCount;

  int get uploadBytes =>
      curves.lengthInBytes +
      curvePoints.lengthInBytes +
      transforms.lengthInBytes +
      paths.lengthInBytes;
}
