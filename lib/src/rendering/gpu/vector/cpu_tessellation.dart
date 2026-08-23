/// Backend-neutral CPU tessellation for retained GPU meshes.
///
/// This is the deliberately narrow first implementation of approach B. It
/// accepts one closed, simple contour and triangulates it with ear clipping.
/// Quadratic and cubic curves are flattened explicitly in local space before
/// polygon validation. The tolerance is therefore retained in the cache key:
/// moving or scaling a mesh does not rebuild it, while asking for a finer
/// local approximation does. Multiple contours (and therefore holes), open
/// contours, and self-intersections are rejected by name.
///
/// The result contains only float32 XY vertices and uint32 triangle indices.
/// That contract maps directly to OpenGL, D3D, Metal, Vulkan, and WebGPU
/// vertex/index buffers; no backend object or FFI allocation leaks into the
/// tessellator or its cache key.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import '../../../geometry/path.dart';
import '../../../geometry/rect.dart';
import '../../path/fill_rule.dart';

/// A reason a [Path] cannot enter the conservative retained-mesh route.
enum TessellationRejection {
  segmentLimitExceeded,
  multipleContoursUnsupported,
  openContourUnsupported,
  nonFiniteCoordinate,
  selfIntersection,
  degenerateContour,
  numericalDegeneracy,
}

/// Named refusal instead of a partial or visually incorrect mesh.
final class TessellationUnsupportedError extends UnsupportedError {
  TessellationUnsupportedError(this.rejection, String detail)
      : super('${rejection.name}: $detail');

  final TessellationRejection rejection;
}

/// Stable content key for a retained mesh.
///
/// [Path] equality is content-based. The mesh stays in local coordinates, so
/// a per-draw transform is intentionally absent: moving or scaling an object
/// must reuse its VBO and update only a transform uniform. The fill rule and
/// flattening tolerance are present because curve approximation affects the
/// retained topology.
final class TessellatedPathCacheKey {
  const TessellatedPathCacheKey(
    this.path, {
    required this.fillRule,
    required this.flattenTolerance,
  });

  final Path path;
  final FillRule fillRule;
  final double flattenTolerance;

  @override
  bool operator ==(Object other) =>
      other is TessellatedPathCacheKey &&
      other.path == path &&
      other.fillRule == fillRule &&
      other.flattenTolerance == flattenTolerance;

  @override
  int get hashCode => Object.hash(path, fillRule, flattenTolerance);
}

/// Build-time and upload metrics for one retained mesh.
final class CpuTessellationMetrics {
  const CpuTessellationMetrics({
    required this.sourceVerbCount,
    required this.sourcePointCount,
    required this.sourceCurveCount,
    required this.flattenedSegmentCount,
    required this.vertexCount,
    required this.triangleCount,
    required this.removedVertexCount,
    required this.signedArea,
    required this.isConvex,
  });

  final int sourceVerbCount;
  final int sourcePointCount;

  /// Quadratic plus cubic verbs in the source path.
  final int sourceCurveCount;

  /// Closed polygon edges after curve flattening and before simplification.
  final int flattenedSegmentCount;
  final int vertexCount;
  final int triangleCount;

  /// Consecutive duplicate and redundant collinear points omitted safely.
  final int removedVertexCount;

  /// Area in retained local coordinates. Positive means the emitted triangle
  /// indices use the tessellator's canonical winding.
  final double signedArea;

  final bool isConvex;

  int get vertexBytes => vertexCount * 2 * Float32List.bytesPerElement;
  int get indexBytes => triangleCount * 3 * Uint32List.bytesPerElement;
  int get retainedBytes => vertexBytes + indexBytes;
}

/// An immutable, backend-neutral retained triangle mesh.
final class TessellatedPathMesh {
  const TessellatedPathMesh({
    required this.cacheKey,
    required this.vertices,
    required this.indices,
    required this.bounds,
    required this.metrics,
  });

  final TessellatedPathCacheKey cacheKey;

  /// Interleaved float32 `x, y` pairs.
  final Float32List vertices;

  /// Three uint32 vertex indices per triangle, with canonical positive area.
  final Uint32List indices;

  final Rect bounds;
  final CpuTessellationMetrics metrics;

  int get vertexCount => vertices.length ~/ 2;
  int get triangleCount => indices.length ~/ 3;
}

/// Retains local meshes by path content, fill rule, and flattening tolerance.
///
/// There is intentionally no transform argument: translation, scale, and
/// rotation belong in a per-draw GPU uniform and reuse the same VBO. A caller
/// that needs a different local approximation asks with a different
/// [flattenTolerance], which necessarily produces a different key.
final class CpuTessellatedPathCache {
  CpuTessellatedPathCache({
    CpuPathTessellator tessellator = const CpuPathTessellator(),
  }) : _tessellator = tessellator;

  final CpuPathTessellator _tessellator;
  final Map<TessellatedPathCacheKey, TessellatedPathMesh> _meshes =
      <TessellatedPathCacheKey, TessellatedPathMesh>{};

  int hitCount = 0;
  int missCount = 0;

  int get length => _meshes.length;

  int get retainedBytes {
    var total = 0;
    for (final mesh in _meshes.values) {
      total += mesh.metrics.retainedBytes;
    }
    return total;
  }

  TessellatedPathMesh resolve(
    Path path, {
    FillRule fillRule = FillRule.nonZero,
    double flattenTolerance = kDefaultFlattenTolerance,
  }) {
    final key = TessellatedPathCacheKey(
      path,
      fillRule: fillRule,
      flattenTolerance: flattenTolerance,
    );
    final cached = _meshes[key];
    if (cached != null) {
      hitCount++;
      return cached;
    }
    final mesh = _tessellator.tessellate(
      path,
      fillRule: fillRule,
      flattenTolerance: flattenTolerance,
    );
    _meshes[mesh.cacheKey] = mesh;
    missCount++;
    return mesh;
  }

  void clear() {
    _meshes.clear();
    hitCount = 0;
    missCount = 0;
  }
}

/// Eligibility result that can be computed before allocating GPU buffers.
final class CpuTessellationEligibility {
  const CpuTessellationEligibility._({
    required this.isEligible,
    required this.segmentCount,
    required this.hasSelfIntersections,
    this.rejection,
  });

  final bool isEligible;
  final int segmentCount;
  final bool hasSelfIntersections;
  final TessellationRejection? rejection;
}

/// Flattens and ear-clips simple paths into retained triangle meshes.
final class CpuPathTessellator {
  const CpuPathTessellator({
    this.maxFlattenedSegments = kDefaultMaxTessellationSegments,
  }) : assert(maxFlattenedSegments > 0);

  /// Hard per-path limit. Flattening refuses instead of silently clamping a
  /// curve or allocating an attacker-controlled number of points.
  final int maxFlattenedSegments;

  /// Classifies the exact same input contract [tessellate] enforces.
  ///
  /// This is the seam for `GpuPathStrategySelector`: [segmentCount] and
  /// [hasSelfIntersections] can be copied into its workload, and
  /// [isEligible] gates whether `tessellatedMesh` is advertised at all.
  CpuTessellationEligibility inspect(
    Path path, {
    double flattenTolerance = kDefaultFlattenTolerance,
  }) {
    try {
      _validateOptions(flattenTolerance);
      final _Polygon polygon = _readPolygon(
        path,
        flattenTolerance: flattenTolerance,
        maxFlattenedSegments: maxFlattenedSegments,
      );
      if (polygon.points.isEmpty) {
        return const CpuTessellationEligibility._(
          isEligible: true,
          segmentCount: 0,
          hasSelfIntersections: false,
        );
      }
      final bool intersects = _hasSelfIntersection(polygon.points);
      if (intersects) {
        return CpuTessellationEligibility._(
          isEligible: false,
          segmentCount: polygon.points.length,
          hasSelfIntersections: true,
          rejection: TessellationRejection.selfIntersection,
        );
      }
      if (_signedDoubleArea(polygon.points).abs() <= polygon.epsilon) {
        return CpuTessellationEligibility._(
          isEligible: false,
          segmentCount: polygon.points.length,
          hasSelfIntersections: false,
          rejection: TessellationRejection.degenerateContour,
        );
      }
      return CpuTessellationEligibility._(
        isEligible: true,
        segmentCount: polygon.points.length,
        hasSelfIntersections: false,
      );
    } on TessellationUnsupportedError catch (error) {
      return CpuTessellationEligibility._(
        isEligible: false,
        segmentCount: 0,
        hasSelfIntersections:
            error.rejection == TessellationRejection.selfIntersection,
        rejection: error.rejection,
      );
    }
  }

  TessellatedPathMesh tessellate(
    Path path, {
    FillRule fillRule = FillRule.nonZero,
    double flattenTolerance = kDefaultFlattenTolerance,
  }) {
    _validateOptions(flattenTolerance);
    final TessellatedPathCacheKey key = TessellatedPathCacheKey(
      path,
      fillRule: fillRule,
      flattenTolerance: flattenTolerance,
    );
    final _Polygon polygon = _readPolygon(
      path,
      flattenTolerance: flattenTolerance,
      maxFlattenedSegments: maxFlattenedSegments,
    );
    final List<_Point> points = polygon.points;

    if (points.isEmpty) {
      return TessellatedPathMesh(
        cacheKey: key,
        vertices: Float32List(0),
        indices: Uint32List(0),
        bounds: Rect.zero,
        metrics: CpuTessellationMetrics(
          sourceVerbCount: path.verbCount,
          sourcePointCount: path.pointCount,
          sourceCurveCount: polygon.sourceCurveCount,
          flattenedSegmentCount: polygon.flattenedSegmentCount,
          vertexCount: 0,
          triangleCount: 0,
          removedVertexCount: 0,
          signedArea: 0,
          isConvex: true,
        ),
      );
    }

    if (_hasSelfIntersection(points)) {
      throw TessellationUnsupportedError(
        TessellationRejection.selfIntersection,
        'ear clipping is defined here only for a simple polygon',
      );
    }

    final double doubleArea = _signedDoubleArea(points);
    if (doubleArea.abs() <= polygon.epsilon) {
      throw TessellationUnsupportedError(
        TessellationRejection.degenerateContour,
        'the contour has zero or numerically insignificant area',
      );
    }

    final bool convex = _isConvex(points, polygon.epsilon);
    final List<int> order = <int>[
      if (doubleArea > 0)
        for (var i = 0; i < points.length; i++) i
      else
        for (var i = points.length - 1; i >= 0; i--) i,
    ];
    final List<int> triangles = _earClip(points, order, polygon.epsilon);
    final Float32List vertices = Float32List(points.length * 2);
    for (var i = 0; i < points.length; i++) {
      vertices[i * 2] = points[i].x;
      vertices[i * 2 + 1] = points[i].y;
    }
    final Uint32List indices = Uint32List.fromList(triangles);
    final Rect bounds = _bounds(points);
    final double area = doubleArea.abs() * 0.5;
    return TessellatedPathMesh(
      cacheKey: key,
      vertices: vertices,
      indices: indices,
      bounds: bounds,
      metrics: CpuTessellationMetrics(
        sourceVerbCount: path.verbCount,
        sourcePointCount: path.pointCount,
        sourceCurveCount: polygon.sourceCurveCount,
        flattenedSegmentCount: polygon.flattenedSegmentCount,
        vertexCount: points.length,
        triangleCount: triangles.length ~/ 3,
        removedVertexCount: polygon.rawPointCount - points.length,
        signedArea: area,
        isConvex: convex,
      ),
    );
  }

  void _validateOptions(double flattenTolerance) {
    if (!flattenTolerance.isFinite || flattenTolerance <= 0) {
      throw ArgumentError.value(
        flattenTolerance,
        'flattenTolerance',
        'must be finite and positive',
      );
    }
    if (maxFlattenedSegments <= 0) {
      throw ArgumentError.value(
        maxFlattenedSegments,
        'maxFlattenedSegments',
        'must be positive',
      );
    }
  }
}

/// Default retained-mesh complexity budget for one path.
const int kDefaultMaxTessellationSegments = 65536;

final class _Point {
  const _Point(this.x, this.y);

  final double x;
  final double y;
}

final class _Polygon {
  const _Polygon(
    this.points,
    this.rawPointCount,
    this.epsilon,
    this.sourceCurveCount,
    this.flattenedSegmentCount,
  );

  final List<_Point> points;
  final int rawPointCount;
  final double epsilon;
  final int sourceCurveCount;
  final int flattenedSegmentCount;
}

_Polygon _readPolygon(
  Path path, {
  required double flattenTolerance,
  required int maxFlattenedSegments,
}) {
  if (path.isEmpty) return const _Polygon(<_Point>[], 0, 0, 0, 0);

  var sourceCurveCount = 0;
  for (var point = 0; point < path.pointCount; point++) {
    _readPoint(path, point);
  }
  for (var verb = 0; verb < path.verbCount; verb++) {
    final value = path.verbAt(verb);
    if (value == verbQuadraticTo || value == verbCubicTo) {
      sourceCurveCount++;
    }
  }
  if (sourceCurveCount > 0) {
    _preflightFlattening(
      path,
      flattenTolerance: flattenTolerance,
      maxFlattenedSegments: maxFlattenedSegments,
    );
    final sink = _TessellationPolylineSink(maxFlattenedSegments);
    path.flattenTo(sink, tolerance: flattenTolerance);
    return sink.build(sourceCurveCount);
  }

  final List<_Point> raw = <_Point>[];
  var pointIndex = 0;
  var contourCount = 0;
  var closed = false;
  for (var verbIndex = 0; verbIndex < path.verbCount; verbIndex++) {
    final int verb = path.verbAt(verbIndex);
    switch (verb) {
      case verbMoveTo:
        contourCount++;
        if (contourCount > 1) {
          throw TessellationUnsupportedError(
            TessellationRejection.multipleContoursUnsupported,
            'holes and disjoint contours need contour classification',
          );
        }
        raw.add(_readPoint(path, pointIndex++));
      case verbLineTo:
        raw.add(_readPoint(path, pointIndex++));
      case verbQuadraticTo || verbCubicTo:
        throw StateError('curve count and verb walk disagreed');
      case verbClose:
        closed = true;
    }
  }
  if (!closed) {
    throw TessellationUnsupportedError(
      TessellationRejection.openContourUnsupported,
      'the retained-mesh prototype requires an explicit close verb',
    );
  }

  final int rawCount = raw.length;
  if (rawCount > maxFlattenedSegments) {
    throw TessellationUnsupportedError(
      TessellationRejection.segmentLimitExceeded,
      '$rawCount closed-contour segments exceed the configured limit of '
      '$maxFlattenedSegments',
    );
  }
  final double scale = _coordinateScale(raw);
  final double epsilon = scale * scale * 1e-12;
  final List<_Point> points = _simplify(raw, epsilon);
  if (points.length < 3) {
    throw TessellationUnsupportedError(
      TessellationRejection.degenerateContour,
      'fewer than three distinct non-collinear vertices remain',
    );
  }
  return _Polygon(points, rawCount, epsilon, 0, rawCount);
}

/// Computes the exact segment counts [Path.flattenTo] will request before it
/// emits any points.
///
/// Path's general raster flattening route clamps each curve at
/// [kMaxSegmentsPerCurve] so a frame cannot stall. A retained mesh must not
/// silently accept that degraded tolerance: it refuses before calling the
/// shared flattener when either the per-curve clamp or this tessellator's
/// per-path budget would be crossed.
void _preflightFlattening(
  Path path, {
  required double flattenTolerance,
  required int maxFlattenedSegments,
}) {
  var point = 0;
  var currentX = 0.0;
  var currentY = 0.0;
  var total = 0;
  for (var verbIndex = 0; verbIndex < path.verbCount; verbIndex++) {
    switch (path.verbAt(verbIndex)) {
      case verbMoveTo:
        currentX = path.pointX(point);
        currentY = path.pointY(point++);
      case verbLineTo:
        currentX = path.pointX(point);
        currentY = path.pointY(point++);
        total++;
      case verbQuadraticTo:
        final controlX = path.pointX(point);
        final controlY = path.pointY(point);
        final endX = path.pointX(point + 1);
        final endY = path.pointY(point + 1);
        point += 2;
        final ddx = currentX - 2 * controlX + endX;
        final ddy = currentY - 2 * controlY + endY;
        final deviation = math.sqrt(ddx * ddx + ddy * ddy);
        total += _checkedCurveSegments(
          deviation / (4 * flattenTolerance),
          maxFlattenedSegments,
        );
        currentX = endX;
        currentY = endY;
      case verbCubicTo:
        final control1X = path.pointX(point);
        final control1Y = path.pointY(point);
        final control2X = path.pointX(point + 1);
        final control2Y = path.pointY(point + 1);
        final endX = path.pointX(point + 2);
        final endY = path.pointY(point + 2);
        point += 3;
        final d0x = currentX - 2 * control1X + control2X;
        final d0y = currentY - 2 * control1Y + control2Y;
        final d1x = control1X - 2 * control2X + endX;
        final d1y = control1Y - 2 * control2Y + endY;
        final magnitude0 = d0x * d0x + d0y * d0y;
        final magnitude1 = d1x * d1x + d1y * d1y;
        final deviation =
            math.sqrt(magnitude0 > magnitude1 ? magnitude0 : magnitude1);
        total += _checkedCurveSegments(
          3 * deviation / (4 * flattenTolerance),
          maxFlattenedSegments,
        );
        currentX = endX;
        currentY = endY;
      case verbClose:
        total++;
    }
    if (total > maxFlattenedSegments) {
      throw TessellationUnsupportedError(
        TessellationRejection.segmentLimitExceeded,
        'flattening needs $total segments, above the configured per-path '
        'limit of $maxFlattenedSegments',
      );
    }
  }
}

int _checkedCurveSegments(double ratio, int maxFlattenedSegments) {
  if (!(ratio > 0)) return 1;
  if (!ratio.isFinite) {
    throw TessellationUnsupportedError(
      TessellationRejection.segmentLimitExceeded,
      'the requested tolerance produces an unbounded curve segment count',
    );
  }
  final root = math.sqrt(ratio);
  final curveLimit = math.min(kMaxSegmentsPerCurve, maxFlattenedSegments);
  if (root > curveLimit) {
    throw TessellationUnsupportedError(
      TessellationRejection.segmentLimitExceeded,
      'one curve needs more than $curveLimit segments; refusing instead of '
      'silently clamping the requested local-space tolerance',
    );
  }
  final count = root.ceil();
  return count < 1 ? 1 : count;
}

/// Receives [Path.flattenTo] directly, enforcing the retained-mesh budget
/// while points are produced rather than after an oversized list exists.
final class _TessellationPolylineSink implements PolylineSink {
  _TessellationPolylineSink(this.maxSegments);

  final int maxSegments;
  final List<_Point> _points = <_Point>[];
  var _contourCount = 0;
  var _segmentCount = 0;
  var _closed = false;

  @override
  void moveTo(double x, double y) {
    _contourCount++;
    if (_contourCount > 1) {
      throw TessellationUnsupportedError(
        TessellationRejection.multipleContoursUnsupported,
        'holes and disjoint contours need contour classification',
      );
    }
    _addPoint(x, y);
  }

  @override
  void lineTo(double x, double y) {
    _addSegment();
    _addPoint(x, y);
  }

  @override
  void close() {
    _closed = true;
    _addSegment();
  }

  void _addPoint(double x, double y) {
    if (!x.isFinite || !y.isFinite) {
      throw TessellationUnsupportedError(
        TessellationRejection.nonFiniteCoordinate,
        'curve flattening produced a non-finite local coordinate',
      );
    }
    _points.add(_Point(x, y));
  }

  void _addSegment() {
    _segmentCount++;
    if (_segmentCount > maxSegments) {
      throw TessellationUnsupportedError(
        TessellationRejection.segmentLimitExceeded,
        'flattening needs more than the configured $maxSegments segments',
      );
    }
  }

  _Polygon build(int sourceCurveCount) {
    if (!_closed) {
      throw TessellationUnsupportedError(
        TessellationRejection.openContourUnsupported,
        'the retained-mesh prototype requires an explicit close verb',
      );
    }
    final rawCount = _points.length;
    final scale = _coordinateScale(_points);
    final epsilon = scale * scale * 1e-12;
    final points = _simplify(_points, epsilon);
    if (points.length < 3) {
      throw TessellationUnsupportedError(
        TessellationRejection.degenerateContour,
        'fewer than three distinct non-collinear vertices remain',
      );
    }
    return _Polygon(
      points,
      rawCount,
      epsilon,
      sourceCurveCount,
      _segmentCount,
    );
  }
}

_Point _readPoint(Path path, int index) {
  final double x = path.pointX(index);
  final double y = path.pointY(index);
  if (!x.isFinite || !y.isFinite) {
    throw TessellationUnsupportedError(
      TessellationRejection.nonFiniteCoordinate,
      'the local contour contains a non-finite coordinate',
    );
  }
  return _Point(x, y);
}

double _coordinateScale(List<_Point> points) {
  var scale = 1.0;
  for (final _Point point in points) {
    if (point.x.abs() > scale) scale = point.x.abs();
    if (point.y.abs() > scale) scale = point.y.abs();
  }
  return scale;
}

List<_Point> _simplify(List<_Point> raw, double epsilon) {
  final List<_Point> points = <_Point>[];
  for (final _Point point in raw) {
    if (points.isEmpty || !_samePoint(points.last, point, epsilon)) {
      points.add(point);
    }
  }
  if (points.length > 1 && _samePoint(points.first, points.last, epsilon)) {
    points.removeLast();
  }

  var changed = true;
  while (changed && points.length >= 3) {
    changed = false;
    for (var i = 0; i < points.length; i++) {
      final _Point before = points[(i - 1 + points.length) % points.length];
      final _Point current = points[i];
      final _Point after = points[(i + 1) % points.length];
      if (_cross(before, current, after).abs() <= epsilon &&
          _between(before, current, after, epsilon)) {
        points.removeAt(i);
        changed = true;
        break;
      }
    }
  }
  return points;
}

bool _samePoint(_Point a, _Point b, double epsilon) {
  final double dx = a.x - b.x;
  final double dy = a.y - b.y;
  return dx * dx + dy * dy <= epsilon;
}

bool _between(_Point a, _Point b, _Point c, double epsilon) =>
    (b.x - a.x) * (b.x - c.x) + (b.y - a.y) * (b.y - c.y) <= epsilon;

double _cross(_Point a, _Point b, _Point c) =>
    (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x);

double _signedDoubleArea(List<_Point> points) {
  var area = 0.0;
  for (var i = 0; i < points.length; i++) {
    final _Point a = points[i];
    final _Point b = points[(i + 1) % points.length];
    area += a.x * b.y - b.x * a.y;
  }
  return area;
}

bool _hasSelfIntersection(List<_Point> points) {
  final int count = points.length;
  for (var a = 0; a < count; a++) {
    final int aNext = (a + 1) % count;
    for (var b = a + 1; b < count; b++) {
      final int bNext = (b + 1) % count;
      if (a == b || aNext == b || bNext == a) continue;
      if (_segmentsIntersect(
          points[a], points[aNext], points[b], points[bNext])) {
        return true;
      }
    }
  }
  return false;
}

bool _segmentsIntersect(_Point a, _Point b, _Point c, _Point d) {
  final double scale = _coordinateScale(<_Point>[a, b, c, d]);
  final double epsilon = scale * scale * 1e-12;
  final double abC = _cross(a, b, c);
  final double abD = _cross(a, b, d);
  final double cdA = _cross(c, d, a);
  final double cdB = _cross(c, d, b);
  if (((abC > epsilon && abD < -epsilon) ||
          (abC < -epsilon && abD > epsilon)) &&
      ((cdA > epsilon && cdB < -epsilon) ||
          (cdA < -epsilon && cdB > epsilon))) {
    return true;
  }
  return (abC.abs() <= epsilon && _onSegment(a, c, b, epsilon)) ||
      (abD.abs() <= epsilon && _onSegment(a, d, b, epsilon)) ||
      (cdA.abs() <= epsilon && _onSegment(c, a, d, epsilon)) ||
      (cdB.abs() <= epsilon && _onSegment(c, b, d, epsilon));
}

bool _onSegment(_Point a, _Point p, _Point b, double epsilon) =>
    p.x >= (a.x < b.x ? a.x : b.x) - epsilon &&
    p.x <= (a.x > b.x ? a.x : b.x) + epsilon &&
    p.y >= (a.y < b.y ? a.y : b.y) - epsilon &&
    p.y <= (a.y > b.y ? a.y : b.y) + epsilon;

bool _isConvex(List<_Point> points, double epsilon) {
  var sign = 0;
  for (var i = 0; i < points.length; i++) {
    final double cross = _cross(
      points[i],
      points[(i + 1) % points.length],
      points[(i + 2) % points.length],
    );
    if (cross.abs() <= epsilon) continue;
    final int nextSign = cross > 0 ? 1 : -1;
    if (sign != 0 && sign != nextSign) return false;
    sign = nextSign;
  }
  return true;
}

List<int> _earClip(List<_Point> points, List<int> order, double epsilon) {
  final List<int> remaining = List<int>.of(order);
  final List<int> triangles = <int>[];
  while (remaining.length > 3) {
    var clipped = false;
    for (var cursor = 0; cursor < remaining.length; cursor++) {
      final int previous =
          remaining[(cursor - 1 + remaining.length) % remaining.length];
      final int current = remaining[cursor];
      final int next = remaining[(cursor + 1) % remaining.length];
      if (_cross(points[previous], points[current], points[next]) <= epsilon) {
        continue;
      }

      var containsVertex = false;
      for (final int candidate in remaining) {
        if (candidate == previous ||
            candidate == current ||
            candidate == next) {
          continue;
        }
        if (_insideTriangle(
          points[candidate],
          points[previous],
          points[current],
          points[next],
          epsilon,
        )) {
          containsVertex = true;
          break;
        }
      }
      if (containsVertex) continue;

      triangles.addAll(<int>[previous, current, next]);
      remaining.removeAt(cursor);
      clipped = true;
      break;
    }
    if (!clipped) {
      throw TessellationUnsupportedError(
        TessellationRejection.numericalDegeneracy,
        'ear clipping made no progress; use coverage, stencil, or compute',
      );
    }
  }
  triangles.addAll(remaining);
  return triangles;
}

bool _insideTriangle(
  _Point point,
  _Point a,
  _Point b,
  _Point c,
  double epsilon,
) =>
    _cross(a, b, point) >= -epsilon &&
    _cross(b, c, point) >= -epsilon &&
    _cross(c, a, point) >= -epsilon;

Rect _bounds(List<_Point> points) {
  var left = points.first.x;
  var top = points.first.y;
  var right = left;
  var bottom = top;
  for (var i = 1; i < points.length; i++) {
    final _Point point = points[i];
    if (point.x < left) left = point.x;
    if (point.x > right) right = point.x;
    if (point.y < top) top = point.y;
    if (point.y > bottom) bottom = point.y;
  }
  return Rect.fromLTRB(left, top, right, bottom);
}
