/// Backend-neutral planning adapter for the opt-in Vulkan sparse-strip
/// executor.
///
/// CPU preparation only. Nothing here calls Vulkan: an accepted draw is
/// retained as an ordered command and executed later, in the exact dense/vector
/// order the display list had. That separation is what `gpu_path_dispatch.dart`
/// requires, and it is the reason a refusal costs nothing - the sink continues
/// through the coverage atlas as if the recorder had never been consulted.
///
/// This is `d3d12_vector_path_recorder.dart` with one strategy instead of two.
/// The Vulkan backend builds no compute pipeline, so approach D has no route
/// here and is refused by name rather than offered and then dropped; when a
/// compute path arrives, a second command subclass is where it goes.
///
/// ## What is refused, by name
///
/// **Gradients.** The sparse executor takes a `GpuGradientBinding` and
/// `GpuGradientShaderParameters`, and a replay paint carries neither; building
/// them needs a resident LUT, which is a device resource this planning-only
/// file must not touch. The dense atlas draws nothing of the kind - it would
/// flatten the ramp - so this is *not* the same as saying the Vulkan shader
/// cannot do gradients: `vulkan_sparse_strips.dart` has the module and
/// `vulkan_sparse_parity_test.dart` measures it against the CPU. What is
/// missing is the plumbing that resolves a paint's gradient to a cached LUT
/// during replay, and that is one seam, in the sink, shared by every backend.
/// Refusing here keeps the refusal honest instead of deferring it to
/// submission after dense work has already drawn.
///
/// **Aliased fills.** Sparse coverage *is* analytic antialiasing. Using it for
/// `antiAlias: false` would silently soften an edge the display list asked to
/// be hard.
///
/// **A command out of batch order.** A vector command drawing before dense
/// work that preceded it in the display list would reorder compositing, and on
/// an opaque scene it would look almost right.
library;

import '../../../geometry/path.dart' show Path, kDefaultFlattenTolerance;
import '../../../geometry/rect.dart';
import '../../../geometry/transform2d.dart';
import '../../path/fill_rule.dart';
import '../../replay/display_list_player.dart';
import '../gpu_path_dispatch.dart';
import '../gpu_path_strategy.dart';
import '../gpu_pipeline.dart';
import '../vector/sparse_strip_draw_plan.dart';
import '../vector/sparse_strips.dart';
import '../vector/vector_plan_cache.dart';
import 'vulkan_sparse_executor.dart';

/// One retained vector command, in display-list order.
final class VulkanSparsePathCommand {
  const VulkanSparsePathCommand({
    required this.batchIndex,
    required this.material,
    required this.plan,
  });

  /// The first dense batch that must execute *after* this command.
  ///
  /// The sink closes the open batch before calling the recorder, so this is
  /// exactly the boundary and not an approximation of one.
  final int batchIndex;

  final SparseVulkanMaterial material;
  final SparseStripDrawPlan plan;

  GpuPathStrategy get strategy => GpuPathStrategy.sparseStrips;
}

/// Converts selector candidates into complete retained Vulkan commands.
final class VulkanVectorPathRecorder implements GpuPathCommandRecorder {
  VulkanVectorPathRecorder({
    SparseStripGenerator? sparseGenerator,
    this.flattenTolerance = kDefaultFlattenTolerance,
    this.sparseAtlasWidth = 1024,
    this.sparseAtlasHeight = 1024,
    int planCacheCapacity = 64,
  })  : _sparseGenerator = sparseGenerator ?? SparseStripGenerator(),
        sparsePlanCache =
            VectorPlanCache<SparseStripDrawPlan>(capacity: planCacheCapacity) {
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
  }

  final SparseStripGenerator _sparseGenerator;
  final double flattenTolerance;
  final int sparseAtlasWidth;
  final int sparseAtlasHeight;

  /// Retained sparse encodings, keyed by geometry, transform, clip and rule.
  ///
  /// The dense atlas keeps its masks; without this the sparse route would pay
  /// its full analytic coverage rasterisation on every frame even for a shape
  /// that had not moved. See `vector_plan_cache.dart`.
  final VectorPlanCache<SparseStripDrawPlan> sparsePlanCache;

  final List<VulkanSparsePathCommand> _commands = <VulkanSparsePathCommand>[];

  int acceptedCount = 0;
  int refusalCount = 0;
  int failureCount = 0;
  Object? lastError;

  int get commandCount => _commands.length;

  VulkanSparsePathCommand commandAt(int index) {
    if (index < 0 || index >= _commands.length) {
      throw RangeError.index(index, _commands, 'index');
    }
    return _commands[index];
  }

  /// Forgets the frame's commands. The generator's arenas and the plan cache
  /// are retained.
  void resetForFrame() => _commands.clear();

  /// Sparse encodings measured for the selector and not yet consumed.
  ///
  /// The selector only prefers sparse strips after it has *measured* the
  /// encoding, and measuring means running the encoder. Doing it again in
  /// [_buildSparse] would rasterise every promoted path twice - the exact CPU
  /// cost sparse strips exist to reduce - so the probe keeps what it built and
  /// the builder reuses it when the request that arrives is the one that was
  /// measured. Any other request discards it: an encoding is valid only for the
  /// geometry, clip, transform and rule it came from.
  SparseStripDrawPlan? _measuredPlan;
  Path? _measuredPath;
  Transform2D? _measuredTransform;
  Rect? _measuredClip;
  FillRule? _measuredRule;

  /// Measures the sparse encoding of one candidate draw for the selector.
  ///
  /// Wired as `GpuPathPlanningTelemetry.sparseMetricsProbe`. CPU work only, and
  /// its result is only a cost: returning null leaves the draw on whatever the
  /// selector chooses next, which is the dense atlas.
  SparseStripPlanMetrics? probeSparseMetrics(
    Path path,
    Transform2D localToTarget,
    Rect clip,
    FillRule fillRule,
  ) {
    _measuredPlan = null;
    try {
      final SparseStripDrawPlan? cached = sparsePlanCache
          .lookup(_sparseKey(path, localToTarget, clip, fillRule));
      final SparseStripDrawPlan? plan =
          cached ?? _encodeSparse(path, localToTarget, clip, fillRule);
      if (plan == null) return null;
      _measuredPlan = plan;
      _measuredPath = path;
      _measuredTransform = localToTarget;
      _measuredClip = clip;
      _measuredRule = fillRule;
      // Not stored here: the probe runs for draws the recorder may still
      // refuse for reasons it cannot see, and a cache entry for a draw that
      // never ran would be a measurement retained as if it were a result.
      return plan.metrics;
    } catch (error) {
      failureCount++;
      lastError = error;
      return null;
    }
  }

  @override
  bool tryRecord(GpuPathDispatchRequest request) {
    try {
      if (request.candidateStrategy != GpuPathStrategy.sparseStrips) {
        return _refuse();
      }
      // Validate the blend before building an encoding. The executor uses the
      // same mapping, so accepting an unsupported mode here would defer a
      // deterministic refusal until submission, after dense work has drawn.
      gpuBlendForMode(request.paint.blendMode);
      if (request.paint.gradient != null) return _refuse();
      if (!request.paint.antiAlias) return _refuse();
      if (_commands.isNotEmpty &&
          request.batchIndex < _commands.last.batchIndex) {
        return _refuse();
      }

      final SparseStripDrawPlan? plan = _buildSparse(request);
      if (plan == null) return _refuse();

      // Commit last. Everything above works in local or private arenas, so no
      // rejected candidate can leave a partial command behind.
      _commands.add(VulkanSparsePathCommand(
        batchIndex: request.batchIndex,
        material: _materialFor(request.paint),
        plan: plan,
      ));
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

  SparseStripDrawPlan? _buildSparse(GpuPathDispatchRequest request) {
    final VectorPlanCacheKey key = _sparseKey(
      request.path,
      request.localToTarget,
      request.clip,
      request.fillRule,
    );
    final SparseStripDrawPlan? measured = _measuredPlan;
    if (measured != null &&
        identical(_measuredPath, request.path) &&
        _measuredTransform == request.localToTarget &&
        _measuredClip == request.clip &&
        _measuredRule == request.fillRule) {
      _measuredPlan = null;
      // Retained now that the draw is being committed. Without this the common
      // case - measured by the probe, then promoted - would never populate the
      // cache and a static scene would re-encode for ever.
      sparsePlanCache.store(key, measured);
      return measured;
    }

    final SparseStripDrawPlan? cached = sparsePlanCache.lookup(key);
    if (cached != null) return cached;

    final SparseStripDrawPlan? plan = _encodeSparse(
      request.path,
      request.localToTarget,
      request.clip,
      request.fillRule,
    );
    if (plan == null) return null;
    sparsePlanCache.store(key, plan);
    return plan;
  }

  VectorPlanCacheKey _sparseKey(
    Path path,
    Transform2D transform,
    Rect clip,
    FillRule fillRule,
  ) =>
      VectorPlanCacheKey(
        path,
        transform: transform,
        clip: clip,
        fillRule: fillRule,
        flattenTolerance: flattenTolerance,
      );

  /// Rasterises analytic coverage and packs it, or null when there is none.
  ///
  /// A plan retained here is never `reset()`: the executor only reads it, and a
  /// cached plan that somebody rewound would submit an empty frame. That is the
  /// whole contract between this cache and [SparseVulkanExecutor].
  SparseStripDrawPlan? _encodeSparse(
    Path path,
    Transform2D transform,
    Rect clip,
    FillRule fillRule,
  ) {
    final StripBuffer strips = _sparseGenerator.fill(
      path,
      clip,
      rule: fillRule,
      transform: transform,
      tolerance: flattenTolerance,
    );
    if (strips.quadCount == 0) return null;
    final SparseStripDrawPlan plan = SparseStripDrawPlan(
      atlasWidth: sparseAtlasWidth,
      atlasHeight: sparseAtlasHeight,
    );
    if (plan.append(strips, materialIndex: 0) < 0) return null;
    return plan;
  }

  /// The premultiplied material one sparse batch draws with.
  ///
  /// Premultiplied here rather than in the shader, exactly as the dense route
  /// premultiplies before it writes a vertex colour, so both routes hand the
  /// blend unit the same numbers.
  static SparseVulkanMaterial _materialFor(ReplayPaint paint) {
    final double alpha = ((paint.argbColor >> 24) & 0xFF) / 255.0;
    return SparseVulkanMaterial(
      red: ((paint.argbColor >> 16) & 0xFF) / 255.0 * alpha,
      green: ((paint.argbColor >> 8) & 0xFF) / 255.0 * alpha,
      blue: (paint.argbColor & 0xFF) / 255.0 * alpha,
      alpha: alpha,
      blendMode: paint.blendMode,
    );
  }

  bool _refuse() {
    refusalCount++;
    return false;
  }
}
