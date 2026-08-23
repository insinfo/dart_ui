/// Builds strategy-selector input from real geometry and measured plans.
library;

import '../../geometry/path.dart';
import '../../geometry/rect.dart';
import '../../geometry/transform2d.dart';
import 'gpu_path_strategy.dart';
import 'vector/cpu_tessellation.dart';
import 'vector/sparse_strip_draw_plan.dart';

/// The one construction path for [GpuPathWorkload] in production code.
///
/// Segment count, self-intersection and tessellation eligibility all come
/// from the same [CpuPathTessellator.inspect] result. Sparse costs come from
/// one immutable [SparseStripPlanMetrics] snapshot. This prevents a caller
/// from combining, for example, an eligible flag from one path with the
/// segment count or upload bytes of another hand-written estimate.
final class GpuPathWorkloadBuilder {
  const GpuPathWorkloadBuilder({
    this.tessellator = const CpuPathTessellator(),
  });

  final CpuPathTessellator tessellator;

  /// Builds a workload using either [bounds] or explicit pixel dimensions.
  ///
  /// [bounds] is expected in the target's pixel coordinate space. When it is
  /// omitted, [Path.bounds] is mapped through [localToTarget]. Callers that
  /// pass already-transformed bounds must still pass the transform when it is
  /// not axis preserving, because it also decides whether a rectangle can use
  /// the analytic pipeline.
  /// [clip] intersects bounds before outward pixel rounding. Explicit
  /// dimensions are useful when raster planning already computed the exact
  /// allocation size and must be supplied as a pair.
  GpuPathWorkload build(
    Path path, {
    Rect? bounds,
    Rect? clip,
    int? pixelWidth,
    int? pixelHeight,
    bool geometryStable = false,
    bool denseMaskCacheHit = false,
    bool denseMaskLikelyCacheable = false,
    SparseStripPlanMetrics? sparseMetrics,
    int? tileCrossings,
    double flattenTolerance = kDefaultFlattenTolerance,
    Transform2D localToTarget = Transform2D.identity,
  }) {
    final hasWidth = pixelWidth != null;
    final hasHeight = pixelHeight != null;
    if (hasWidth != hasHeight) {
      throw ArgumentError(
        'pixelWidth and pixelHeight must be supplied together',
      );
    }
    if (hasWidth && (bounds != null || clip != null)) {
      throw ArgumentError(
        'explicit dimensions cannot be combined with bounds or clip',
      );
    }

    final int width;
    final int height;
    if (hasWidth) {
      width = pixelWidth;
      height = pixelHeight!;
    } else {
      final sourceBounds = bounds ?? localToTarget.transformRect(path.bounds);
      final visible =
          clip == null ? sourceBounds : sourceBounds.intersect(clip);
      if (visible.isEmpty ||
          !visible.left.isFinite ||
          !visible.top.isFinite ||
          !visible.right.isFinite ||
          !visible.bottom.isFinite) {
        throw ArgumentError.value(
          visible,
          'bounds',
          'visible path bounds must be finite and non-empty',
        );
      }
      width = visible.right.ceil() - visible.left.floor();
      height = visible.bottom.ceil() - visible.top.floor();
    }

    final eligibility = tessellator.inspect(
      path,
      flattenTolerance: flattenTolerance,
    );
    final sparse = sparseMetrics;
    final workload = GpuPathWorkload(
      pixelWidth: width,
      pixelHeight: height,
      segmentCount: eligibility.segmentCount,
      isAnalyticPrimitive: _isAxisAlignedRectangle(path) &&
          _preservesAxisAlignment(localToTarget),
      denseMaskCacheHit: denseMaskCacheHit,
      denseMaskLikelyCacheable: denseMaskLikelyCacheable,
      tileCrossings: tileCrossings,
      geometryStable: geometryStable,
      hasSelfIntersections: eligibility.hasSelfIntersections,
      tessellationEligible: eligibility.isEligible,
      sparseEncodedBytes: sparse?.sourceEncodedBytes,
      sparseUploadBytes: sparse?.alphaUploadBytes,
      sparseInstanceBytes: sparse?.instanceBufferBytes,
      sparseEstimatedDrawCalls: sparse?.estimatedDrawCallCount,
      sparseAtlasPageCount: sparse?.atlasPageCount,
    );
    workload.validate();
    return workload;
  }
}

bool _preservesAxisAlignment(Transform2D transform) {
  if (!transform.a.isFinite ||
      !transform.b.isFinite ||
      !transform.c.isFinite ||
      !transform.d.isFinite ||
      !transform.tx.isFinite ||
      !transform.ty.isFinite) {
    return false;
  }
  return (transform.b == 0 && transform.c == 0) ||
      (transform.a == 0 && transform.d == 0);
}

bool _isAxisAlignedRectangle(Path path) {
  if (path.verbCount != 5 || path.pointCount != 4) return false;
  if (path.verbAt(0) != verbMoveTo ||
      path.verbAt(1) != verbLineTo ||
      path.verbAt(2) != verbLineTo ||
      path.verbAt(3) != verbLineTo ||
      path.verbAt(4) != verbClose) {
    return false;
  }

  final x0 = path.pointX(0);
  final y0 = path.pointY(0);
  final x1 = path.pointX(1);
  final y1 = path.pointY(1);
  final x2 = path.pointX(2);
  final y2 = path.pointY(2);
  final x3 = path.pointX(3);
  final y3 = path.pointY(3);
  if (!x0.isFinite ||
      !y0.isFinite ||
      !x1.isFinite ||
      !y1.isFinite ||
      !x2.isFinite ||
      !y2.isFinite ||
      !x3.isFinite ||
      !y3.isFinite) {
    return false;
  }
  final axisAligned = (x0 == x1 && y1 == y2 && x2 == x3 && y3 == y0) ||
      (y0 == y1 && x1 == x2 && y2 == y3 && x3 == x0);
  if (!axisAligned) return false;
  return path.bounds.width > 0 && path.bounds.height > 0;
}
