/// Cost- and capability-based selection between GPU path rasterizers.
///
/// The renderer has several valid answers for a path. Treating one as a global
/// backend choice leaves performance on the table: a rectangle should remain
/// analytic even on a compute-capable device, a cached icon should remain in
/// the mask atlas, while a deforming SVG may justify compute or stencil. This
/// file makes that per-draw policy explicit and testable without a GPU.
library;

import '../../graphics/content_hint.dart';
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
    this.denseMaskLikelyCacheable = false,
    this.geometryStable = false,
    this.hasSelfIntersections = false,
    this.tessellationEligible = false,
    this.sparseEncodedBytes,
    this.sparseUploadBytes,
    this.sparseInstanceBytes,
    this.sparseEstimatedDrawCalls,
    this.sparseAtlasPageCount,
    this.tileCrossings,
  });

  final int pixelWidth;
  final int pixelHeight;
  final int segmentCount;

  /// The draw can be evaluated exactly by a primitive fragment shader.
  final bool isAnalyticPrimitive;

  /// A dense mask already exists, so this draw has no raster/upload cost.
  final bool denseMaskCacheHit;

  /// The dense atlas *would* be caching this draw by now, had an experimental
  /// route not been taking it.
  ///
  /// Distinct from [denseMaskCacheHit], and the distinction is the whole
  /// point: a promoted draw never reaches the atlas, so its mask is never
  /// resident and the cache-hit branch can never fire for it. Without this,
  /// the moment a route starts winning a draw it also guarantees the cheaper
  /// route stays expensive, and the comparison it wins is against a cost it
  /// created. See `gpu_path_repetition.dart`.
  final bool denseMaskLikelyCacheable;

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

  /// (segment, 4x4 tile) pairs the sparse rasteriser has to visit.
  ///
  /// The variable the sparse route's cost is actually proportional to, and it
  /// is **not** the segment count: a star of 62 long edges was measured
  /// costing more than a spirograph of 721 short ones, because each of its
  /// edges crosses the whole surface. See [GpuPathStrategySelector].
  ///
  /// Null when the backend has not measured it. Those callers keep the older
  /// transfer-bytes rule, which is documented on the selector as superseded.
  final int? tileCrossings;

  /// This workload as the application's advice about the subtree describes
  /// it.
  ///
  /// **The whole contract of a hint lives in this method, so it is short on
  /// purpose.** Exactly two fields can move, and both are *cost estimates*:
  ///
  ///   * [geometryStable] - will this shape be the same next frame;
  ///   * [denseMaskLikelyCacheable] - would the atlas be caching it by now.
  ///
  /// Nothing else is touched. A hint cannot set [tessellationEligible] (the
  /// tessellator decides that by inspecting the path, and a wrong answer draws
  /// a wrong shape), cannot clear [hasSelfIntersections], cannot change the
  /// measured sparse costs or [tileCrossings], and - because this takes no
  /// capabilities anywhere near it - cannot enable a route the device did not
  /// report. A wrong hint therefore selects a route that is legal, correct and
  /// slower, which is the promise `content_hint.dart` makes.
  ///
  /// [denseMaskCacheHit] is deliberately left alone even though it looks like
  /// a cost fact: it is a *measurement* of the atlas, and overriding it would
  /// make the selector believe in a resident mask that does not exist - or
  /// throw away one that does.
  ///
  /// It lives on the workload rather than beside the policy that used to own
  /// it because the copy has to enumerate every field of this class: a new
  /// cost fact added here and forgotten there would be silently dropped by
  /// every hinted draw, and only a method inside the class fails to compile
  /// when that happens.
  ///
  /// Returns `this` when the hint says nothing or says nothing new, so the
  /// seam costs one comparison and no allocation on the overwhelmingly common
  /// path.
  GpuPathWorkload withContentHint(ContentHint hint) {
    switch (hint.motion) {
      case ContentMotionHint.unspecified:
        return this;
      case ContentMotionHint.staticContent:
        // Both facts, because `staticContent` declares that geometry **and
        // transform** repeat - see `ContentMotionHint.staticContent`. The
        // atlas keys on device space, so it is the transform half that makes
        // the mask cacheable, and a declaration that moved only
        // `geometryStable` would leave the first frame of a static subtree
        // exactly where it was: judged fresh, promoted to a route that never
        // populates the atlas, and therefore still not cached on the second
        // frame either.
        //
        // The cost of being wrong here is the shape of every cost in this
        // file: a moving subtree declared static goes to the atlas, misses,
        // and re-rasterises - one frame's work, never a different picture.
        if (geometryStable && denseMaskLikelyCacheable) return this;
        return _withCostFacts(
          geometryStable: true,
          denseMaskLikelyCacheable: true,
        );
      case ContentMotionHint.animating:
        // The coverage itself is new every frame, so no cache can hit and
        // nothing about this shape repeats.
        if (!geometryStable && !denseMaskLikelyCacheable) return this;
        return _withCostFacts(
          geometryStable: false,
          denseMaskLikelyCacheable: false,
        );
      case ContentMotionHint.transforming:
        // The interesting one, and the reason it is not a synonym for
        // `animating`. Local geometry repeats and only the matrix moves, so a
        // retained mesh - keyed on local coordinates - survives every frame,
        // while a dense mask - keyed on device coordinates - misses every
        // frame. Stable **and** uncacheable is exactly that pair of facts, and
        // no single boolean could have said it.
        if (geometryStable && !denseMaskLikelyCacheable) return this;
        return _withCostFacts(
          geometryStable: true,
          denseMaskLikelyCacheable: false,
        );
    }
  }

  GpuPathWorkload _withCostFacts({
    required bool geometryStable,
    required bool denseMaskLikelyCacheable,
  }) =>
      GpuPathWorkload(
        pixelWidth: pixelWidth,
        pixelHeight: pixelHeight,
        segmentCount: segmentCount,
        isAnalyticPrimitive: isAnalyticPrimitive,
        denseMaskCacheHit: denseMaskCacheHit,
        denseMaskLikelyCacheable: denseMaskLikelyCacheable,
        geometryStable: geometryStable,
        hasSelfIntersections: hasSelfIntersections,
        tessellationEligible: tessellationEligible,
        sparseEncodedBytes: sparseEncodedBytes,
        sparseUploadBytes: sparseUploadBytes,
        sparseInstanceBytes: sparseInstanceBytes,
        sparseEstimatedDrawCalls: sparseEstimatedDrawCalls,
        sparseAtlasPageCount: sparseAtlasPageCount,
        tileCrossings: tileCrossings,
      );

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

/// Default exchange rate between a sparse tile crossing and dense pixels.
///
/// See [GpuPathStrategySelector.sparseCrossingCostInDensePixels] for what the
/// number means, how it was measured, and why it is a property of the machine
/// rather than a threshold to tune.
const double kDefaultSparseCrossingCostInDensePixels = 50;

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
    this.stencilMinimumDenseMaskBytes = 16384,
    this.sparseCrossingCostInDensePixels =
        kDefaultSparseCrossingCostInDensePixels,
  })  : assert(computeSegmentThreshold >= 0),
        assert(sparseCrossingCostInDensePixels > 0),
        assert(sparseMaximumDenseRatio >= 0),
        assert(sparseMaximumDenseRatio <= 1),
        assert(sparseMaximumDrawCalls > 0),
        assert(sparseMaximumAtlasPages > 0),
        assert(tessellationSegmentLimit >= 0),
        assert(stencilMinimumDenseMaskBytes >= 0);

  final int computeSegmentThreshold;
  final double sparseMaximumDenseRatio;
  final int sparseMaximumDrawCalls;
  final int sparseMaximumAtlasPages;
  final int tessellationSegmentLimit;

  /// How many pixels of dense rasterisation one sparse tile crossing costs.
  ///
  /// ## What this number is, and why it is not a tuning knob
  ///
  /// The two routes do not differ in *how much* work they do but in what the
  /// work is proportional to, and each has one dominant unit cost:
  ///
  ///   * the dense atlas costs **area**, and its cost per pixel is a
  ///     `fillRange` - memset speed - plus the scanline sweep's per-edge
  ///     bookkeeping;
  ///   * the sparse rasteriser costs **tile crossings**, and its cost per
  ///     crossing is roughly 240 scalar operations: sixteen pixels of analytic
  ///     trapezoid area, with no SIMD, because Dart has none.
  ///
  /// So one route is cheaper exactly when `crossings * thisNumber < area`, and
  /// `thisNumber` is the exchange rate between the two units. It is a physical
  /// quantity that can be re-derived by measurement rather than a threshold to
  /// be tuned until the tests pass.
  ///
  /// ## Where 83 came from, and when it stops being true
  ///
  /// Measured on the machine this was developed on - an Intel UHD integrated
  /// GPU, Dart AOT - by timing four scenes at 256x256 with
  /// `test/rendering/gpu/vector/strip_rasterizer_cost_test.dart`:
  ///
  ///     scene         crossings   crossings/pixel   sparse vs dense
  ///     panel               288           0.0044    2.5x faster
  ///     icons              1740           0.0266    a tie, within noise
  ///     spirograph         4152           0.0634    ~1.4x slower
  ///     star               4646           0.0709    ~1.7x slower
  ///
  /// The crossover therefore sits between 0.0266 and 0.0634 crossings per
  /// pixel. 1/50 = 0.020 is placed *below* the tie rather than inside the gap,
  /// because a draw should only leave the parity route when the gain is clear:
  /// at `icons` the two are within run-to-run noise of each other, and there
  /// is nothing to win there and correctness habits to lose.
  ///
  /// The earlier value of 83 was derived before the per-crossing loop was
  /// tightened (the carried pixel edge and the skipped scanlines), which moved
  /// the crossover by a factor of two. That is the sense in which this is a
  /// measured quantity rather than a threshold: it changed because the *cost*
  /// changed, and the table above is what has to be re-taken when it does.
  ///
  /// **It is a property of this CPU and this GPU and must be re-measured on
  /// another.** A machine with SIMD available to Dart, a faster memory
  /// subsystem, or a discrete GPU where uploads actually cost something would
  /// move it - possibly by a lot, since the whole reason the dense route wins
  /// on edge-dense scenes is that a shared-memory upload is nearly free. The
  /// cost test prints the four numbers above, so re-deriving it is one command.
  final double sparseCrossingCostInDensePixels;

  /// Dense mask area, in bytes, above which a stencil-capable pass is
  /// preferred to rasterising and uploading a new mask.
  ///
  /// The trade this number expresses: the dense atlas costs a CPU scanline
  /// fill plus an alpha8 upload proportional to the shape's **area**, while
  /// stencil-then-cover costs a fan of triangles proportional to its
  /// **perimeter** and two extra passes over its bounds. The passes are a
  /// fixed cost, so below some area the mask is simply cheaper, and above it
  /// the upload dominates. 16 KiB is a 128x128 shape - about the size at which
  /// the upload stops being noise on the Intel UHD this was measured against.
  ///
  /// It only ever applies when the pass reports a stencil attachment, so a
  /// device or target without one is unaffected by the value. A cached mask
  /// still wins outright: that branch runs first and costs nothing at all.
  final int stencilMinimumDenseMaskBytes;

  /// The strategy for one draw.
  ///
  /// ## Where [hint] enters, and the precedence it does not get
  ///
  /// [hint] is what the application declared about the subtree this draw is
  /// in - `ContentHintScope` in the widget tree, carried beside the op stream
  /// and delivered at the sink boundary. It exists because the one thing the
  /// facts below cannot contain is what happens *next*: a card that has been
  /// still for twenty-six frames and a card one frame into a pinch-zoom
  /// present identical evidence and want opposite answers. The repetition
  /// model in `gpu_path_repetition.dart` infers that from history, which
  /// answers a frame late and cannot tell "stopped" from "about to move
  /// again".
  ///
  /// **It is advice, and the ordering here is what makes that true.** The
  /// hint is applied to the *cost* facts only, by
  /// [GpuPathWorkload.withContentHint], and the two branches it could
  /// plausibly have wanted to override run against facts it cannot move:
  ///
  ///   1. an analytic primitive stays analytic. Closed-form shader coverage
  ///      is exact and cheaper than everything below it, and no declaration
  ///      about motion changes either half of that;
  ///   2. a **resident** mask still wins. `denseMaskCacheHit` is a
  ///      measurement of the atlas, not a prediction, and a mask that is
  ///      already there costs one quad and no transfer however the subtree is
  ///      moving. An `animating` hint that threw it away would be the one
  ///      case where a wrong hint cost more than the frame it was meant to
  ///      save.
  ///
  /// Everything after that - the repetition gate, the
  /// `crossings < k * area` rule, the tessellation and stencil gates - reads
  /// the adjusted workload, and the measured terms of the cost rule are
  /// untouched: a hinted draw still has to *win* on crossings against area to
  /// be promoted to sparse. So a wrong hint moves a draw between routes that
  /// were already legal for it and can only cost frame time.
  GpuPathStrategyDecision select(
    GpuPathWorkload workload,
    GpuPathStrategyCapabilities capabilities, {
    ContentHint hint = ContentHint.none,
  }) {
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

    // Only here, and only onto the two cost estimates. Above this line are
    // the two facts a hint is not allowed to overrule; below it, everything
    // reads `workload`, which is now what the application said it is.
    workload = workload.withContentHint(hint);

    // A draw that has repeated belongs to the atlas, and this has to come
    // before *every* experimental route rather than being priced against each.
    //
    // The reason is that the branch above can never fire for a draw one of
    // them has taken: a promoted draw never reaches the atlas, so its mask is
    // never resident, so `denseMaskCacheHit` stays false for ever. Whichever
    // route wins a repeated draw thereby guarantees the cheaper route stays
    // expensive, and then wins the comparison against a cost it created. It
    // was measured doing exactly that - 1.141 ms against the atlas's 0.865 ms
    // on a static panel, while the atlas sat at one rasterisation and 25 hits.
    //
    // There is also no threshold that could express this correctly: the atlas
    // costs a quad and no transfer at all on a repeat, and no encoding is
    // smaller than zero. See `gpu_path_repetition.dart`.
    if (workload.denseMaskLikelyCacheable && capabilities.coverageAtlas) {
      return const GpuPathStrategyDecision(
        GpuPathStrategy.coverageAtlas,
        'this draw has repeated, so the dense atlas would already be caching '
        'it; a resident mask costs one quad and no transfer',
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

    // Sparse strips, decided by the work each route does rather than by the
    // bytes it moves.
    //
    // The transfer-bytes rule this replaces was measured and found to be the
    // wrong variable: sparse moved a hundred times fewer bytes than the dense
    // atlas on every scene and still lost, because on a shared-memory GPU the
    // upload was never the bottleneck. What decides is how much *work* each
    // route does - area for the atlas, tile crossings for the strips - and
    // [sparseCrossingCostInDensePixels] is the exchange rate between them.
    final int? crossings = workload.tileCrossings;
    if (capabilities.sparseStrips && crossings != null) {
      final int drawCount = workload.sparseEstimatedDrawCalls ?? 0;
      final int pageCount = workload.sparseAtlasPageCount ?? 0;
      final double sparseCost = crossings * sparseCrossingCostInDensePixels;
      final int denseCost = workload.denseMaskBytes;
      // The draw and page ceilings survive from the older rule and are not
      // about cost: they bound how badly one draw can fragment a frame's
      // submission, which no amount of cheapness would make acceptable.
      if (sparseCost < denseCost &&
          drawCount <= sparseMaximumDrawCalls &&
          pageCount <= sparseMaximumAtlasPages) {
        return GpuPathStrategyDecision(
          GpuPathStrategy.sparseStrips,
          '$crossings tile crossings cost about '
          '${sparseCost.round()} dense pixels against $denseCost in the '
          'atlas ($drawCount draws, $pageCount pages)',
        );
      }
    } else if (capabilities.sparseStrips) {
      // No crossing count: this backend has not measured the variable that
      // decides, so it keeps the superseded transfer-bytes rule rather than
      // silently losing the route. Direct3D 12 is in this position; its own
      // measurements are its to redo. See [GpuPathWorkload.tileCrossings].
      final int? sparseBytes = workload.sparseTransferBytes;
      if (sparseBytes != null) {
        final int maximum =
            (workload.denseMaskBytes * sparseMaximumDenseRatio).floor();
        final int drawCount = workload.sparseEstimatedDrawCalls ?? 0;
        final int pageCount = workload.sparseAtlasPageCount ?? 0;
        if (sparseBytes <= maximum &&
            drawCount <= sparseMaximumDrawCalls &&
            pageCount <= sparseMaximumAtlasPages) {
          return GpuPathStrategyDecision(
            GpuPathStrategy.sparseStrips,
            'sparse transfer is $sparseBytes bytes versus '
            '${workload.denseMaskBytes} dense bytes '
            '($drawCount draws, $pageCount pages) - superseded rule, this '
            'backend reports no tile crossings',
          );
        }
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

    // Before the dense fallback, and only where the pass really has stencil:
    // a mask this large is a CPU rasterisation and an area-proportional upload
    // that stencil-then-cover replaces with perimeter-proportional geometry.
    // See [stencilMinimumDenseMaskBytes] for the trade and why a cached mask
    // (handled far above) still wins.
    if (capabilities.stencil &&
        !workload.denseMaskCacheHit &&
        workload.denseMaskBytes >= stencilMinimumDenseMaskBytes) {
      return GpuPathStrategyDecision(
        GpuPathStrategy.stencilThenCover,
        'an uncached ${workload.denseMaskBytes}-byte dense mask is at or over '
        'the $stencilMinimumDenseMaskBytes-byte stencil threshold',
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
