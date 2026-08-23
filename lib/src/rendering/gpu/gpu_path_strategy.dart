/// Cost- and capability-based selection between GPU path rasterizers.
///
/// The renderer has several valid answers for a path. Treating one as a global
/// backend choice leaves performance on the table: a rectangle should remain
/// analytic even on a compute-capable device, a cached icon should remain in
/// the mask atlas, while a deforming SVG may justify compute or stencil. This
/// file makes that per-draw policy explicit and testable without a GPU.
library;

import '../renderer.dart';

/// The concrete strategy selected for one path draw.
enum GpuPathStrategy {
  /// Closed-form fragment coverage for rectangles and similar primitives.
  analyticPrimitive,

  /// CPU analytic scanlines cached in a dense alpha8 atlas.
  coverageAtlas,

  /// CPU coverage compressed into partial strips and solid fill runs.
  sparseStrips,

  /// CPU-flattened/tessellated geometry retained in vertex buffers.
  tessellatedMesh,

  /// GPU stencil winding accumulation followed by a cover pass.
  stencilThenCover,

  /// GPU tile binning and coverage through compute shaders.
  computeTiles,
}

/// Maps a per-draw strategy onto the public renderer-family metadata.
extension GpuPathStrategyMetadata on GpuPathStrategy {
  RasterizationApproach get rasterizationApproach => switch (this) {
        GpuPathStrategy.analyticPrimitive ||
        GpuPathStrategy.coverageAtlas =>
          RasterizationApproach.analyticCoverageAtlas,
        GpuPathStrategy.sparseStrips =>
          RasterizationApproach.sparseStripsHybrid,
        GpuPathStrategy.tessellatedMesh =>
          RasterizationApproach.tessellatedMeshes,
        GpuPathStrategy.stencilThenCover =>
          RasterizationApproach.stencilThenCover,
        GpuPathStrategy.computeTiles => RasterizationApproach.computeTiles,
      };
}

/// What the current render device and target can execute.
final class GpuPathStrategyCapabilities {
  const GpuPathStrategyCapabilities({
    this.analyticPrimitives = true,
    this.coverageAtlas = true,
    this.sparseStrips = false,
    this.tessellation = false,
    this.stencil = false,
    this.compute = false,
  });

  final bool analyticPrimitives;
  final bool coverageAtlas;
  final bool sparseStrips;
  final bool tessellation;
  final bool stencil;
  final bool compute;

  bool get hasGeneralPathStrategy =>
      coverageAtlas || sparseStrips || tessellation || stencil || compute;
}

/// Facts about one draw that materially change its cheapest representation.
final class GpuPathWorkload {
  const GpuPathWorkload({
    required this.pixelWidth,
    required this.pixelHeight,
    required this.segmentCount,
    this.isAnalyticPrimitive = false,
    this.denseMaskCacheHit = false,
    this.geometryStable = false,
    this.hasSelfIntersections = false,
    this.tessellationEligible = false,
    this.sparseEncodedBytes,
    this.sparseUploadBytes,
    this.sparseInstanceBytes,
    this.sparseEstimatedDrawCalls,
    this.sparseAtlasPageCount,
  });

  final int pixelWidth;
  final int pixelHeight;
  final int segmentCount;

  /// The draw can be evaluated exactly by a primitive fragment shader.
  final bool isAnalyticPrimitive;

  /// A dense mask already exists, so this draw has no raster/upload cost.
  final bool denseMaskCacheHit;

  /// Geometry is expected to survive several frames unchanged.
  final bool geometryStable;

  /// Conservative hint: simple tessellation is risky, stencil/coverage is not.
  final bool hasSelfIntersections;

  /// The CPU tessellator accepted the path's topology and verb contract.
  ///
  /// This is distinct from [hasSelfIntersections]: the conservative
  /// tessellator also refuses holes, multiple/open contours and paths that
  /// exceed the configured curve-flattening budget. The default is false:
  /// callers must opt in from `CpuPathTessellator.inspect` or equivalent
  /// evidence before a retained mesh can be selected.
  final bool tessellationEligible;

  /// Measured output of the sparse encoder, when it has already run or a cache
  /// has its previous size. Null means its cost is unknown.
  final int? sparseEncodedBytes;

  /// Alpha texture bytes submitted by the sparse plan. Together with
  /// [sparseInstanceBytes], this is a more useful GPU transfer estimate than
  /// the source encoding alone.
  final int? sparseUploadBytes;

  /// Instance and batch bytes submitted by the sparse plan.
  final int? sparseInstanceBytes;

  /// Estimated ordered draws after material and alpha-page splitting.
  final int? sparseEstimatedDrawCalls;

  /// Number of alpha8 atlas pages touched by this draw.
  final int? sparseAtlasPageCount;

  int get denseMaskBytes => pixelWidth * pixelHeight;

  int? get sparseTransferBytes {
    final upload = sparseUploadBytes;
    final instances = sparseInstanceBytes;
    if (upload != null && instances != null) return upload + instances;
    return sparseEncodedBytes;
  }

  void validate() {
    if (pixelWidth <= 0 || pixelHeight <= 0) {
      throw ArgumentError(
        'path workload dimensions must be positive; '
        'got ${pixelWidth}x$pixelHeight',
      );
    }
    if (segmentCount < 0) {
      throw ArgumentError.value(
        segmentCount,
        'segmentCount',
        'must be non-negative',
      );
    }
    final sparseBytes = sparseEncodedBytes;
    if (sparseBytes != null && sparseBytes < 0) {
      throw ArgumentError.value(
        sparseBytes,
        'sparseEncodedBytes',
        'must be non-negative',
      );
    }
    for (final (name, value) in <(String, int?)>[
      ('sparseUploadBytes', sparseUploadBytes),
      ('sparseInstanceBytes', sparseInstanceBytes),
      ('sparseEstimatedDrawCalls', sparseEstimatedDrawCalls),
      ('sparseAtlasPageCount', sparseAtlasPageCount),
    ]) {
      if (value != null && value < 0) {
        throw ArgumentError.value(value, name, 'must be non-negative');
      }
    }
  }
}

/// A selected strategy plus the policy reason suitable for diagnostics.
final class GpuPathStrategyDecision {
  const GpuPathStrategyDecision(this.strategy, this.reason);

  final GpuPathStrategy strategy;
  final String reason;

  @override
  String toString() => '${strategy.name}: $reason';
}

/// Deterministic policy for choosing a path strategy.
///
/// Thresholds are constructor parameters so benchmarks can tune them without
/// changing callers, and tests can pin every boundary. The policy never claims
/// a capability the device did not report.
final class GpuPathStrategySelector {
  const GpuPathStrategySelector({
    this.computeSegmentThreshold = 512,
    this.sparseMaximumDenseRatio = 0.5,
    this.sparseMaximumDrawCalls = 64,
    this.sparseMaximumAtlasPages = 8,
    this.tessellationSegmentLimit = 4096,
  })  : assert(computeSegmentThreshold >= 0),
        assert(sparseMaximumDenseRatio >= 0),
        assert(sparseMaximumDenseRatio <= 1),
        assert(sparseMaximumDrawCalls > 0),
        assert(sparseMaximumAtlasPages > 0),
        assert(tessellationSegmentLimit >= 0);

  final int computeSegmentThreshold;
  final double sparseMaximumDenseRatio;
  final int sparseMaximumDrawCalls;
  final int sparseMaximumAtlasPages;
  final int tessellationSegmentLimit;

  GpuPathStrategyDecision select(
    GpuPathWorkload workload,
    GpuPathStrategyCapabilities capabilities,
  ) {
    workload.validate();

    if (workload.isAnalyticPrimitive && capabilities.analyticPrimitives) {
      return const GpuPathStrategyDecision(
        GpuPathStrategy.analyticPrimitive,
        'closed-form shader coverage is cheaper than path rasterization',
      );
    }

    if (workload.denseMaskCacheHit && capabilities.coverageAtlas) {
      return const GpuPathStrategyDecision(
        GpuPathStrategy.coverageAtlas,
        'the exact dense mask is already resident in the atlas',
      );
    }

    final isDynamic = !workload.geometryStable;
    if (isDynamic &&
        capabilities.compute &&
        workload.segmentCount >= computeSegmentThreshold) {
      return GpuPathStrategyDecision(
        GpuPathStrategy.computeTiles,
        'dynamic path has ${workload.segmentCount} segments, at or above the '
        'compute threshold $computeSegmentThreshold',
      );
    }

    final sparseBytes = workload.sparseTransferBytes;
    if (capabilities.sparseStrips && sparseBytes != null) {
      final maximum =
          (workload.denseMaskBytes * sparseMaximumDenseRatio).floor();
      final drawCount = workload.sparseEstimatedDrawCalls ?? 0;
      final pageCount = workload.sparseAtlasPageCount ?? 0;
      if (sparseBytes <= maximum &&
          drawCount <= sparseMaximumDrawCalls &&
          pageCount <= sparseMaximumAtlasPages) {
        return GpuPathStrategyDecision(
          GpuPathStrategy.sparseStrips,
          'sparse transfer is $sparseBytes bytes versus '
          '${workload.denseMaskBytes} dense bytes '
          '($drawCount draws, $pageCount pages)',
        );
      }
    }

    if (workload.geometryStable &&
        workload.tessellationEligible &&
        !workload.hasSelfIntersections &&
        capabilities.tessellation &&
        workload.segmentCount <= tessellationSegmentLimit) {
      return const GpuPathStrategyDecision(
        GpuPathStrategy.tessellatedMesh,
        'stable non-self-intersecting geometry can retain one mesh',
      );
    }

    if (isDynamic && capabilities.stencil) {
      return const GpuPathStrategyDecision(
        GpuPathStrategy.stencilThenCover,
        'dynamic arbitrary path avoids a CPU mask upload through stencil',
      );
    }

    if (capabilities.coverageAtlas) {
      return const GpuPathStrategyDecision(
        GpuPathStrategy.coverageAtlas,
        'dense analytic coverage is the universal parity-preserving fallback',
      );
    }
    if (capabilities.sparseStrips) {
      return const GpuPathStrategyDecision(
        GpuPathStrategy.sparseStrips,
        'sparse strips are the available vertex/fragment general-path route',
      );
    }
    if (capabilities.stencil) {
      return const GpuPathStrategyDecision(
        GpuPathStrategy.stencilThenCover,
        'stencil is the available arbitrary-path route',
      );
    }
    if (capabilities.tessellation &&
        workload.tessellationEligible &&
        !workload.hasSelfIntersections) {
      return const GpuPathStrategyDecision(
        GpuPathStrategy.tessellatedMesh,
        'tessellation is the available safe route for this geometry',
      );
    }
    if (capabilities.compute) {
      return const GpuPathStrategyDecision(
        GpuPathStrategy.computeTiles,
        'compute is the only available general-path route',
      );
    }
    throw UnsupportedError(
      'the device exposes no safe strategy for this path workload',
    );
  }
}
