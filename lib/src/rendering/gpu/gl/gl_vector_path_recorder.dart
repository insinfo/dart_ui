/// Backend-neutral planning adapter for the opt-in OpenGL vector executors.
///
/// This file performs CPU preparation only. It never calls GL: accepted work
/// is retained in [GpuVectorCommandStream] and executed later by the device in
/// the exact dense/vector pass order.
library;

import '../../../geometry/offset.dart';
import '../../../geometry/path.dart' show Path, kDefaultFlattenTolerance;
import '../../../geometry/rect.dart';
import '../../../geometry/transform2d.dart';
import '../../../graphics/gradient.dart';
import '../../path/fill_rule.dart';
import '../../replay/display_list_player.dart';
import '../gpu_gradient.dart';
import '../gpu_layer_stack.dart';
import '../gpu_path_dispatch.dart';
import '../gpu_path_strategy.dart';
import '../gpu_pipeline.dart';
import '../gpu_vector_command_stream.dart';
import '../vector/cpu_tessellation.dart';
import '../vector/native_strip_rasterizer.dart';
import '../vector/sparse_strip_draw_plan.dart';
import '../vector/sparse_strips.dart';
import '../vector/stencil_cover_draw_plan.dart';
import '../vector/vector_plan_cache.dart';

sealed class GlVectorPathPayload {
  const GlVectorPathPayload();

  GpuPathStrategy get strategy;
}

/// A gradient ramp and the per-draw transforms that address it.
///
/// Resolved at record time rather than at submission, and the reason is the
/// same one that makes the whole recorder transactional: if the ramp cannot be
/// uploaded or the shader transform is singular, the draw has to be refused
/// *before* a command enters the ordered stream. A submitter that discovered
/// it at draw time would already have issued every earlier command in the
/// frame and would have nowhere to fall back to.
final class GlResolvedGradient {
  const GlResolvedGradient(this.binding, this.parameters);

  final GpuGradientBinding binding;
  final GpuGradientShaderParameters parameters;
}

final class GlSparsePathPayload extends GlVectorPathPayload {
  const GlSparsePathPayload(this.plan, {this.gradient});

  final SparseStripDrawPlan plan;

  /// Null for a solid material; the resolved ramp for a gradient paint.
  final GlResolvedGradient? gradient;

  @override
  GpuPathStrategy get strategy => GpuPathStrategy.sparseStrips;
}

final class GlTessellatedPathPayload extends GlVectorPathPayload {
  const GlTessellatedPathPayload({
    required this.mesh,
    required this.localToTarget,
    required this.clip,
  });

  final TessellatedPathMesh mesh;
  final Transform2D localToTarget;
  final Rect clip;

  @override
  GpuPathStrategy get strategy => GpuPathStrategy.tessellatedMesh;
}

final class GlStencilPathPayload extends GlVectorPathPayload {
  const GlStencilPathPayload(this.plan);

  final StencilCoverDrawPlan plan;

  @override
  GpuPathStrategy get strategy => GpuPathStrategy.stencilThenCover;
}

/// Converts selector candidates into complete retained GL payloads.
final class GlVectorPathRecorder implements GpuPathCommandRecorder {
  GlVectorPathRecorder({
    required this.stream,
    NativeStripRasterizer? sparseGenerator,
    CpuTessellatedPathCache? tessellationCache,
    VectorPlanCache<SparseStripDrawPlan>? sparsePlanCache,
    this.gradientCache,
    this.stencilCapabilities,
    this.stencilCapabilitiesProbe,
    this.flattenTolerance = kDefaultFlattenTolerance,
    this.sparseAtlasWidth = 1024,
    this.sparseAtlasHeight = 1024,
    this.stencilMaxTrianglesPerDraw = 65536,
    this.allowStencilInLayers = false,
  })  : _sparseGenerator = sparseGenerator ?? NativeStripRasterizer(),
        _tessellationCache = tessellationCache ?? CpuTessellatedPathCache(),
        sparsePlanCache =
            sparsePlanCache ?? VectorPlanCache<SparseStripDrawPlan>() {
    if (!flattenTolerance.isFinite || flattenTolerance <= 0) {
      throw ArgumentError.value(
        flattenTolerance,
        'flattenTolerance',
        'must be finite and positive',
      );
    }
    if (sparseAtlasWidth <= 0 || sparseAtlasHeight <= 0) {
      throw ArgumentError('sparse atlas dimensions must be positive');
    }
    if (stencilMaxTrianglesPerDraw <= 0) {
      throw ArgumentError.value(
        stencilMaxTrianglesPerDraw,
        'stencilMaxTrianglesPerDraw',
        'must be positive',
      );
    }
  }

  final GpuVectorCommandStream<ReplayPaint, GlVectorPathPayload> stream;

  /// Where coverage comes from.
  ///
  /// [NativeStripRasterizer], not `SparseStripGenerator`: the latter ran
  /// `ScanlineFiller` and re-encoded its spans, which meant the sparse route
  /// paid the dense route's rasterisation *plus* a packing pass and could
  /// never be cheaper on the CPU. This one computes coverage from the geometry
  /// directly. The two are drop-in equivalents - same call, same
  /// [StripBuffer] - and a parity suite pins them together.
  final NativeStripRasterizer _sparseGenerator;
  final CpuTessellatedPathCache _tessellationCache;

  /// Where a gradient paint's ramp becomes a resident texture.
  ///
  /// Null means this recorder cannot draw a gradient, and it refuses one by
  /// returning false. Only the sparse route consumes a gradient - B and C hand
  /// the rasteriser geometry and a solid material - so a gradient paint that
  /// arrives with any other candidate strategy is refused as well.
  final GpuGradientCache? gradientCache;

  /// A fixed answer, for a caller that has exactly one target.
  final StencilCoverCapabilities? stencilCapabilities;

  /// The stencil features of the framebuffer the *current pass* binds.
  ///
  /// Preferred over [stencilCapabilities] when present, and the reason
  /// approach C can be selected automatically: the surface may carry stencil
  /// while a pooled layer target does not, and the answer for one is a wrong
  /// picture for the other. Returning null means "this pass cannot execute
  /// stencil", which is a refusal and not an error.
  final StencilCoverCapabilities? Function()? stencilCapabilitiesProbe;

  final double flattenTolerance;
  final int sparseAtlasWidth;
  final int sparseAtlasHeight;
  final int stencilMaxTrianglesPerDraw;

  /// Retained for callers that pin a fixed [stencilCapabilities]. With
  /// [stencilCapabilitiesProbe] wired, the pass's own attachments decide and
  /// this flag is not consulted: a layer target that really has stencil is
  /// allowed, one that does not is refused whatever this says.
  final bool allowStencilInLayers;

  /// (segment, tile) crossings of the most recent sparse encode.
  ///
  /// The variable the selector's cost rule turns on - see
  /// `GpuPathStrategySelector.sparseCrossingCostInDensePixels`. Null when the
  /// last encode produced nothing, or when a cache hit meant no encode
  /// happened and the count belongs to whatever ran before; the retained plan
  /// carries the count that was measured with it so a hit reports that.
  int? lastTileCrossings;

  int acceptedCount = 0;
  int refusalCount = 0;
  int failureCount = 0;
  Object? lastError;

  /// Sparse encodings retained by content, transform, clip and rule.
  ///
  /// ## Two different savings, and the second one is the larger
  ///
  /// The obvious one is across frames: a static path re-encoded its analytic
  /// coverage from scratch every frame, which is the cost sparse strips exist
  /// to reduce, paid over and over. `vector_plan_cache.dart` explains that
  /// case and the Direct3D 12 measurements for it.
  ///
  /// The one specific to this recorder is *within* a frame. The selector will
  /// not prefer sparse until it has seen what the encoding costs, and finding
  /// that out means running the encoder - so [probeSparseMetrics] rasterises
  /// **every** candidate path, including the ones the selector then sends to
  /// the dense atlas or to approach B. Retaining the probe's result means a
  /// promoted draw does not encode twice, and it means the *rejected* draws
  /// pay their measurement once per frame rather than once per lookup.
  ///
  /// This replaces a single-entry memo that only covered the probe/record
  /// pair. It is strictly wider - the memo could not survive a second path
  /// being measured in between, and could never survive a frame boundary.
  ///
  /// The key holds a *target-space* transform and clip rather than the device
  /// ones the request carries. That is the space the encoding is actually
  /// built in, so two draws of one shape at the same device position inside
  /// differently placed layers key apart, as they must.
  ///
  /// `variant` stays zero: the only other input to the encoding is the atlas
  /// page size, which is fixed for the life of this recorder and therefore
  /// cannot differ between two entries of its own cache.
  final VectorPlanCache<SparseStripDrawPlan> sparsePlanCache;

  /// Crossing counts for retained plans. An `Expando` so it cannot keep a plan
  /// alive past the cache's own eviction.
  final Expando<int> _crossingsByPlan = Expando<int>('sparse tile crossings');

  /// Measures the sparse encoding of one candidate draw for the selector.
  ///
  /// Wired as `GpuPathPlanningTelemetry.sparseMetricsProbe`. It performs CPU
  /// work and no GL work, and its result is only a cost: refusing here - by
  /// returning null - leaves the draw on whatever the selector chooses next,
  /// which is the dense atlas. Arguments are in the same device space the sink
  /// hands the telemetry, and are converted to target space exactly as
  /// [tryRecord] converts them, so the plan measured is the plan submitted.
  SparseStripPlanMetrics? probeSparseMetrics(
    Path path,
    Transform2D localToTarget,
    Rect clip,
    FillRule fillRule,
  ) {
    try {
      final SparseStripDrawPlan? plan =
          _sparsePlan(path, localToTarget, clip, fillRule);
      return plan?.metrics;
    } catch (error) {
      failureCount++;
      lastError = error;
      return null;
    }
  }

  /// The retained encoding for one draw, from the cache or freshly built.
  ///
  /// The single place sparse coverage is rasterised, so the probe and the
  /// commit cannot disagree about what was encoded - and so that a hit counts
  /// once wherever it came from. Null means there is nothing to draw: an empty
  /// strip buffer, or a plan the atlas refused. Neither is retained, because
  /// `VectorPlanCache` holds objects and "nothing" is not one; both are cheap
  /// to rediscover and neither is a shape a frame draws repeatedly.
  SparseStripDrawPlan? _sparsePlan(
    Path path,
    Transform2D localToTarget,
    Rect clip,
    FillRule fillRule,
  ) {
    final (Transform2D transform, Rect targetClip) =
        _targetSpace(localToTarget, clip);
    final VectorPlanCacheKey key = VectorPlanCacheKey(
      path,
      transform: transform,
      clip: targetClip,
      fillRule: fillRule,
      flattenTolerance: flattenTolerance,
    );
    final SparseStripDrawPlan? cached = sparsePlanCache.lookup(key);
    if (cached != null) {
      lastTileCrossings = _crossingsByPlan[cached];
      return cached;
    }

    final StripBuffer strips = _sparseGenerator.fill(
      path,
      targetClip,
      rule: fillRule,
      transform: transform,
      tolerance: flattenTolerance,
    );
    if (strips.quadCount == 0) return null;
    final SparseStripDrawPlan plan = SparseStripDrawPlan(
      atlasWidth: sparseAtlasWidth,
      atlasHeight: sparseAtlasHeight,
    );
    // A retained plan is never `reset()` afterwards: the executor only reads
    // it, and rewinding one that a later frame will hand over again would
    // submit an empty draw. That is the contract with `SparseGlExecutor`.
    if (plan.append(strips, materialIndex: 0) < 0) return null;
    lastTileCrossings = _sparseGenerator.tileCount;
    // Retained beside the plan, not inside it: the plan type is shared with
    // backends whose encoders count nothing, and a cache hit still has to be
    // able to report the count the encode was measured with.
    _crossingsByPlan[plan] = _sparseGenerator.tileCount;
    sparsePlanCache.store(key, plan);
    return plan;
  }

  @override
  bool tryRecord(GpuPathDispatchRequest request) {
    try {
      // Validate the blend before allocating an encoding. Executors use the
      // same mapping, so accepting an unsupported mode here would defer a
      // deterministic refusal until submission, after dense work has drawn.
      gpuBlendForMode(request.paint.blendMode);
      // Only the sparse route has a gradient material. A gradient paint that
      // reached any other candidate is refused here rather than recorded and
      // drawn as its unused fallback colour.
      if (request.paint.gradient != null &&
          request.candidateStrategy != GpuPathStrategy.sparseStrips) {
        return _refuse();
      }
      final (Transform2D localToTarget, Rect targetClip) =
          _targetSpace(request.localToTarget, request.clip);

      final GlVectorPathPayload? payload = switch (request.candidateStrategy) {
        GpuPathStrategy.sparseStrips => _buildSparse(
            request,
            localToTarget: localToTarget,
            targetClip: targetClip,
          ),
        GpuPathStrategy.tessellatedMesh => _buildTessellated(
            request,
            localToTarget: localToTarget,
            targetClip: targetClip,
          ),
        GpuPathStrategy.stencilThenCover => _buildStencil(
            request,
            localToTarget: localToTarget,
            targetClip: targetClip,
          ),
        GpuPathStrategy.analyticPrimitive ||
        GpuPathStrategy.coverageAtlas ||
        GpuPathStrategy.computeTiles =>
          null,
      };
      if (payload == null || payload.strategy != request.candidateStrategy) {
        return _refuse();
      }

      // Commit last. Every builder above uses private/local arenas, so no
      // rejected candidate can leave a partial command in the ordered stream.
      stream.recordVector(
        batchIndex: request.batchIndex,
        clip: request.clip,
        material: request.paint,
        payload: payload,
      );
      acceptedCount++;
      lastError = null;
      return true;
    } catch (error) {
      failureCount++;
      refusalCount++;
      lastError = error;
      return false;
    }
  }

  GlVectorPathPayload? _buildSparse(
    GpuPathDispatchRequest request, {
    required Transform2D localToTarget,
    required Rect targetClip,
  }) {
    // Sparse coverage is analytic AA. Using it for an aliased *solid* fill
    // would change the display-list contract, so that stays refused. A
    // gradient is the stated exception and the reason is that it has no other
    // route at all: the dense atlas cannot draw one, so the choice is this or
    // a refusal, and a filled path is analytically antialiased on every route
    // in this renderer anyway.
    final bool isGradient = request.paint.gradient != null;
    if (!request.paint.antiAlias && !isGradient) return null;

    final GlResolvedGradient? gradient =
        isGradient ? _resolveGradient(request) : null;
    if (isGradient && gradient == null) return null;

    // Normally a cache hit: the selector only prefers sparse after the probe
    // has measured this exact encoding, and the probe retained what it built.
    final SparseStripDrawPlan? plan = _sparsePlan(
      request.path,
      request.localToTarget,
      request.clip,
      request.fillRule,
    );
    if (plan == null) return null;
    return GlSparsePathPayload(plan, gradient: gradient);
  }

  /// Uploads (or reuses) the paint's ramp and builds its shader parameters.
  ///
  /// Null is a refusal the caller turns into a fall-through, and there are
  /// three ways to get one, each of which would otherwise become a wrong
  /// picture or a crash mid-frame:
  ///
  ///   * no cache - this device has no executor that samples a ramp;
  ///   * a singular shader transform, which cannot map a target pixel back to
  ///     gradient-local space, so there is no parameter to look up;
  ///   * a scalar that stops being finite when narrowed to float32, which
  ///     `GpuGradientShaderParameters` refuses rather than letting a finite
  ///     Dart double arrive at the shader as `Inf`.
  ///
  /// The ramp is addressed in **target** space, so the layer origin is folded
  /// into both matrices here. Without it a gradient inside a `saveLayer` would
  /// be evaluated at device coordinates while its pixels were written at
  /// layer-local ones, and the ramp would slide by the layer's position.
  GlResolvedGradient? _resolveGradient(GpuPathDispatchRequest request) {
    final GpuGradientCache? cache = gradientCache;
    if (cache == null) return null;
    final Gradient? gradient = request.paint.gradient;
    if (gradient == null) return null;
    try {
      final GpuGradientShaderParameters parameters =
          GpuGradientShaderParameters.fromPaint(
        request.paint,
        targetOriginInDevice: Offset(
          stream.layers.originX,
          stream.layers.originY,
        ),
      );
      final GpuGradientBinding binding = cache.resolve(gradient);
      return GlResolvedGradient(binding, parameters);
    } catch (error) {
      // Recorded rather than swallowed: the sink turns the missing promotion
      // into an error that names the backend, and this is what says why.
      failureCount++;
      lastError = error;
      return null;
    }
  }

  GlVectorPathPayload? _buildTessellated(
    GpuPathDispatchRequest request, {
    required Transform2D localToTarget,
    required Rect targetClip,
  }) {
    // The current B shader has no analytic fringe. MSAA-aware promotion can
    // relax this once sample count becomes part of the pass descriptor.
    if (request.paint.antiAlias) return null;
    final mesh = _tessellationCache.resolve(
      request.path,
      fillRule: request.fillRule,
      flattenTolerance: flattenTolerance,
    );
    if (mesh.indices.isEmpty) return null;
    return GlTessellatedPathPayload(
      mesh: mesh,
      localToTarget: localToTarget,
      clip: targetClip,
    );
  }

  GlVectorPathPayload? _buildStencil(
    GpuPathDispatchRequest request, {
    required Transform2D localToTarget,
    required Rect targetClip,
  }) {
    // The pass's own attachments first: an executor asked to accumulate
    // winding into a framebuffer with no stencil buffer draws the cover quad
    // unmasked, which is a filled bounding box where a shape was asked for.
    final GpuRenderPass pass = stream.layers.currentPass;
    if (!pass.attachments.hasStencil) return null;
    final StencilCoverCapabilities? capabilities =
        stencilCapabilitiesProbe?.call() ?? stencilCapabilities;
    if (capabilities == null) return null;
    if (stencilCapabilitiesProbe == null &&
        !allowStencilInLayers &&
        pass.target != null) {
      return null;
    }
    final plan = StencilCoverDrawPlan(
      maxTrianglesPerDraw: stencilMaxTrianglesPerDraw,
    );
    final draw = plan.append(
      request.path,
      clip: targetClip,
      materialIndex: 0,
      fillRule: request.fillRule,
      capabilities: capabilities,
      antiAlias: request.paint.antiAlias,
      transform: localToTarget,
      flattenTolerance: flattenTolerance,
    );
    if (draw < 0) return null;
    return GlStencilPathPayload(plan);
  }

  bool _refuse() {
    refusalCount++;
    return false;
  }

  /// Moves a device-space transform and clip into the current pass's target
  /// space: the layer origin subtracted, then clamped to the target's size.
  ///
  /// One implementation, used by both the measuring probe and the recorder, so
  /// the coverage that decided the strategy is the coverage that gets drawn.
  (Transform2D, Rect) _targetSpace(Transform2D localToTarget, Rect clip) {
    final double originX = stream.layers.originX;
    final double originY = stream.layers.originY;
    return (
      Transform2D.translation(-originX, -originY).multiply(localToTarget),
      Rect.fromLTRB(
        clip.left - originX,
        clip.top - originY,
        clip.right - originX,
        clip.bottom - originY,
      ).intersect(
        Rect.fromLTRB(
          0,
          0,
          stream.layers.targetWidth.toDouble(),
          stream.layers.targetHeight.toDouble(),
        ),
      ),
    );
  }
}
