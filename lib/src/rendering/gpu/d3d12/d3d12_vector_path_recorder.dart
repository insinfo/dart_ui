/// Backend-neutral planning adapter for the opt-in Direct3D 12 vector
/// executors.
///
/// CPU preparation only. Nothing here calls Direct3D: an accepted draw is
/// retained as an ordered command and executed later, in the exact dense/vector
/// order the display list had. That separation is what
/// `gpu_path_dispatch.dart` requires, and it is the reason a refusal costs
/// nothing: the sink continues through the coverage atlas as if the recorder
/// had never been consulted.
///
/// ## Why this keeps its own command list instead of using
/// [GpuVectorCommandStream]
///
/// That class interleaves dense ranges with vector commands *per render pass*,
/// which is what a backend with pooled layer targets needs. This device has
/// none: it passes no `GpuLayerStack` to its sink and refuses by name a
/// `saveLayer` that would need an offscreen pass - see the scope section of
/// `d3d12_device.dart`. With one pass there is nothing for a pass stream to
/// order, and adopting it would mean inventing a layer stack for this backend
/// before it has layers. The ordering rule is the same and is enforced here:
/// batch indices are monotonic, and every command names the first dense batch
/// that must execute after it.
///
/// When this device grows a layer pool, this list becomes a
/// [GpuVectorCommandStream] and the ordered walk moves with it.
///
/// ## What is refused, by name
///
/// **Gradients.** The sparse executor takes a `GpuGradientBinding` and
/// `GpuGradientShaderParameters`, and a replay paint carries neither; building
/// them needs a resident LUT, which is a device resource this planning-only
/// file must not touch. The dense atlas draws the gradient correctly today, so
/// refusing is strictly better than deferring the failure to submission.
///
/// **Aliased fills.** Sparse coverage *is* analytic antialiasing. Using it for
/// `antiAlias: false` would silently soften an edge the display list asked to
/// be hard.
///
/// **A compute plan the executor could not dispatch.** Approach D is now
/// promoted for real: the tile shader writes coverage into a storage texture
/// and a composite quad draws it, so `executedStrategy: computeTiles` names a
/// route that really produced the pixels. What is still refused is a plan that
/// cannot be dispatched - an encoding that rejected the geometry, a scene empty
/// after clipping, or a target whose size was never declared - and every such
/// refusal is counted in [computeTileRefusalCount], so a route that silently
/// never runs stays visible instead of being assumed to work.
///
/// ## Approach D antialiases by supersampling, and that is a visible change
///
/// The dense atlas and the sparse route both take coverage from
/// `ScanlineFiller`, which is exact pixel area. The tile shader samples a
/// `sampleGrid * sampleGrid` grid. Promoting a draw to D therefore changes its
/// edge pixels, by up to about one subsample. That is why [computeSampleGrid]
/// is a constructor parameter with a stated default rather than a constant
/// buried in the shader, and why the difference is measured against the CPU
/// renderer rather than declared harmless.
library;

import '../../../geometry/path.dart' show Path, kDefaultFlattenTolerance;
import '../../../geometry/rect.dart';
import '../../../geometry/transform2d.dart';
import '../../path/fill_rule.dart';
import '../../replay/display_list_player.dart';
import '../gpu_path_dispatch.dart';
import '../gpu_path_strategy.dart';
import '../gpu_pipeline.dart';
import '../vector/compute_tile_scene.dart';
import '../vector/sparse_strip_draw_plan.dart';
import '../vector/sparse_strips.dart';
import '../vector/vector_plan_cache.dart';
import 'd3d12_compute_tile_shader.dart';
import 'd3d12_sparse_executor.dart';

/// One retained vector command, in display-list order.
sealed class D3d12VectorPathCommand {
  const D3d12VectorPathCommand({
    required this.batchIndex,
    required this.material,
  });

  /// The first dense batch that must execute *after* this command.
  ///
  /// The sink closes the open batch before calling the recorder, so this is
  /// exactly the boundary and not an approximation of one.
  final int batchIndex;

  final SparseD3d12Material material;

  GpuPathStrategy get strategy;
}

/// CPU coverage compressed into strips, drawn by the sparse pipeline.
final class D3d12SparsePathCommand extends D3d12VectorPathCommand {
  const D3d12SparsePathCommand({
    required super.batchIndex,
    required super.material,
    required this.plan,
  });

  final SparseStripDrawPlan plan;

  @override
  GpuPathStrategy get strategy => GpuPathStrategy.sparseStrips;
}

/// A binned scene the tile shader rasterises and a composite quad draws.
final class D3d12ComputeTilePathCommand extends D3d12VectorPathCommand {
  const D3d12ComputeTilePathCommand({
    required super.batchIndex,
    required super.material,
    required this.plan,
    required this.sampleGrid,
  });

  final ComputeTilePlan plan;

  /// The supersampling grid this command's coverage was planned for. Carried on
  /// the command rather than read from the executor at submission, so a plan
  /// measured at one grid can never be dispatched at another.
  final int sampleGrid;

  @override
  GpuPathStrategy get strategy => GpuPathStrategy.computeTiles;
}

/// Converts selector candidates into complete retained Direct3D 12 commands.
final class D3d12VectorPathRecorder implements GpuPathCommandRecorder {
  D3d12VectorPathRecorder({
    SparseStripGenerator? sparseGenerator,
    this.flattenTolerance = kDefaultFlattenTolerance,
    this.sparseAtlasWidth = 1024,
    this.sparseAtlasHeight = 1024,
    this.computeTileSize = 16,
    this.computeSampleGrid = 4,
    int planCacheCapacity = 64,
  })  : _sparseGenerator = sparseGenerator ?? SparseStripGenerator(),
        sparsePlanCache =
            VectorPlanCache<SparseStripDrawPlan>(capacity: planCacheCapacity),
        computePlanCache =
            VectorPlanCache<ComputeTilePlan>(capacity: planCacheCapacity) {
    if (computeTileSize <= 0 ||
        computeTileSize > kD3d12ComputeTileMaxTileSize) {
      throw ArgumentError.value(
        computeTileSize,
        'computeTileSize',
        'must be 1..$kD3d12ComputeTileMaxTileSize, the thread group edge',
      );
    }
    if (computeSampleGrid <= 0 || computeSampleGrid > 16) {
      throw ArgumentError.value(
        computeSampleGrid,
        'computeSampleGrid',
        'must be 1..16, the range the CPU oracle accepts',
      );
    }
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

  /// The tile edge every compute plan is built with. One thread group covers
  /// [kD3d12ComputeTileMaxTileSize] pixels, so a larger tile cannot dispatch.
  final int computeTileSize;

  /// Subsamples per axis for approach D's coverage. Four means sixteen samples
  /// and a worst case of about sixteen levels against exact area - see the
  /// library comment.
  final int computeSampleGrid;

  /// Retained sparse encodings, keyed by geometry, transform, clip and rule.
  ///
  /// The dense atlas keeps its masks; without this the sparse route paid its
  /// full analytic coverage rasterisation on every frame even for a shape that
  /// had not moved. See `vector_plan_cache.dart`.
  final VectorPlanCache<SparseStripDrawPlan> sparsePlanCache;

  /// Retained compute plans - flattened segments, tile bins and backdrops.
  ///
  /// Keyed additionally by the surface size and tile size, because a plan bins
  /// over a grid anchored at the target's origin and one built for another
  /// grid names tiles that do not exist.
  final VectorPlanCache<ComputeTilePlan> computePlanCache;

  int _targetWidth = 0;
  int _targetHeight = 0;

  /// Declares the pixel size of the target being recorded into.
  ///
  /// Approach D bins over a fixed grid anchored at the target's origin, so a
  /// plan has to know how large the target is; the sparse route does not. The
  /// backend calls this once per frame, because a resize between frames changes
  /// the grid and a plan built for the old one would bin against tiles that no
  /// longer exist.
  void setTargetSize(int width, int height) {
    _targetWidth = width;
    _targetHeight = height;
  }

  final List<D3d12VectorPathCommand> _commands = <D3d12VectorPathCommand>[];

  int acceptedCount = 0;
  int refusalCount = 0;
  int failureCount = 0;

  /// Compute candidates this recorder sent back to the dense atlas because
  /// their plan could not be dispatched. Counted separately so a route that
  /// silently never runs stays visible.
  int computeTileRefusalCount = 0;

  Object? lastError;

  int get commandCount => _commands.length;

  D3d12VectorPathCommand commandAt(int index) {
    if (index < 0 || index >= _commands.length) {
      throw RangeError.index(index, _commands, 'index');
    }
    return _commands[index];
  }

  /// Forgets the frame's commands. The generator's arenas are retained.
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
      // A plan the cache already holds answers the selector's cost question
      // without rasterising anything, which is the point: the probe runs on
      // every antialiased path draw, promoted or not.
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
      // refuse for reasons it cannot see - a gradient paint, an out-of-order
      // batch index - and a cache entry for a draw that never ran would be a
      // measurement retained as if it were a result. `_buildSparse` stores it
      // at the moment the command is committed.
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
      final GpuPathStrategy candidate = request.candidateStrategy;
      if (candidate != GpuPathStrategy.sparseStrips &&
          candidate != GpuPathStrategy.computeTiles) {
        return _refuse();
      }
      // Validate the blend before building an encoding. The executors use the
      // same mapping, so accepting an unsupported mode here would defer a
      // deterministic refusal until submission, after dense work has drawn.
      gpuBlendForMode(request.paint.blendMode);
      if (request.paint.gradient != null) return _refuse();
      if (!request.paint.antiAlias) return _refuse();
      if (_commands.isNotEmpty &&
          request.batchIndex < _commands.last.batchIndex) {
        // Out of order would mean a vector command drawing before dense work
        // that preceded it in the display list. Refusing keeps the picture
        // right; accepting would reorder compositing.
        return _refuse();
      }

      final SparseD3d12Material material = _materialFor(request.paint);
      final D3d12VectorPathCommand? command =
          candidate == GpuPathStrategy.computeTiles
              ? _buildComputeTiles(request, material)
              : _buildSparseCommand(request, material);
      if (command == null) return _refuse();

      // Commit last. Everything above works in local or private arenas, so no
      // rejected candidate can leave a partial command behind.
      _commands.add(command);
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

  D3d12VectorPathCommand? _buildSparseCommand(
    GpuPathDispatchRequest request,
    SparseD3d12Material material,
  ) {
    final SparseStripDrawPlan? plan = _buildSparse(request);
    if (plan == null) return null;
    return D3d12SparsePathCommand(
      batchIndex: request.batchIndex,
      material: material,
      plan: plan,
    );
  }

  /// Flattens and bins one path into a single-draw [ComputeTilePlan].
  ///
  /// One plan per draw, and one draw per plan. That is not the shape a batching
  /// compute renderer would eventually want - the point of a tile scene is that
  /// many draws share one binning pass - but it is the shape the ordered replay
  /// has: the sink hands the recorder one path at a time and a command has to
  /// be complete when [tryRecord] returns. Merging consecutive promoted draws
  /// into one plan is a real optimisation and a separate change, because it
  /// also has to prove that nothing dense was recorded between them.
  D3d12VectorPathCommand? _buildComputeTiles(
    GpuPathDispatchRequest request,
    SparseD3d12Material material,
  ) {
    if (_targetWidth <= 0 || _targetHeight <= 0) {
      // No target size was declared, so a tile grid cannot be built. Refusing
      // beats binning against a guessed surface.
      computeTileRefusalCount++;
      return null;
    }
    final VectorPlanCacheKey key = VectorPlanCacheKey(
      request.path,
      transform: request.localToTarget,
      clip: request.clip,
      fillRule: request.fillRule,
      flattenTolerance: flattenTolerance,
      // The grid a plan was binned against is part of what makes it reusable.
      // Packed rather than three fields because the key is compared on every
      // promoted draw and a wider record costs more than a shift.
      variant: (_targetWidth << 21) ^ (_targetHeight << 5) ^ computeTileSize,
    );
    final ComputeTilePlan? cached = computePlanCache.lookup(key);
    if (cached != null) {
      return D3d12ComputeTilePathCommand(
        batchIndex: request.batchIndex,
        material: material,
        plan: cached,
        sampleGrid: computeSampleGrid,
      );
    }

    final ComputeTileScene scene = ComputeTileScene();
    final int draw = scene.appendPath(
      request.path,
      clip: request.clip,
      materialIndex: 0,
      fillRule: request.fillRule,
      transform: request.localToTarget,
      flattenTolerance: flattenTolerance,
    );
    if (draw < 0) {
      computeTileRefusalCount++;
      return null;
    }
    final ComputeTilePlan plan = scene.build(
      width: _targetWidth,
      height: _targetHeight,
      tileSize: computeTileSize,
    );
    if (plan.commandCount == 0) {
      computeTileRefusalCount++;
      return null;
    }
    // Retained only once it is known to be dispatchable, so a refused plan is
    // never handed back as a hit.
    computePlanCache.store(key, plan);
    return D3d12ComputeTilePathCommand(
      batchIndex: request.batchIndex,
      material: material,
      plan: plan,
      sampleGrid: computeSampleGrid,
    );
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
      // Retain it now that the draw is being committed. Without this the
      // common case - measured by the probe, then promoted - would never
      // populate the cache and a static scene would re-encode for ever.
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
  /// whole contract between this cache and `SparseD3d12Executor`.
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
  static SparseD3d12Material _materialFor(ReplayPaint paint) {
    final double alpha = ((paint.argbColor >> 24) & 0xFF) / 255.0;
    return SparseD3d12Material(
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
