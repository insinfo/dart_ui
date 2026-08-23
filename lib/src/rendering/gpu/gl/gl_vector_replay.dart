/// Wires ordered vector replay to a GL target, one description for both.
///
/// `GlOffscreenTarget` and `GlWindowTarget` build the same six objects - a
/// command stream, a recorder, planning telemetry, a capability probe, a
/// stencil probe and a per-frame cache - and they must build them the *same*
/// way or the window will promote draws the test target does not. That is the
/// failure mode this file removes: a golden test that passes on an offscreen
/// FBO while the screen takes a different route through the renderer.
///
/// ## Capabilities are answered per pass, not per device
///
/// The question "may this draw use stencil-then-cover?" has no device-wide
/// answer. The same context has a default framebuffer that may or may not
/// carry stencil, an offscreen target this backend creates with stencil8 when
/// approach C is enabled, and pooled layer targets that are colour-only. So
/// [GlVectorReplay.capabilities] reads `GpuRenderPass.attachments` - the
/// descriptor field `gpu_layer_stack.dart` now carries - and reports what the
/// framebuffer the draw is *actually* going into can do.
///
/// The consequence worth stating: a path promoted to approach C on the surface
/// falls back to the dense coverage atlas inside a `saveLayer`, silently and
/// correctly, because the layer's target has no stencil buffer. That is a
/// difference in cost, never in pixels - the dense route is the parity route.
///
/// ## The stencil query is cached per frame, per framebuffer
///
/// Stencil bits and sample count come from the driver, and asking costs a
/// framebuffer bind, a completeness check and several `glGet` calls. Asking
/// once per *draw* would put that on the hot path of every path in the frame;
/// asking once per process would be wrong the moment a layer pass began. Once
/// per frame per framebuffer name is the granularity that is both cheap and
/// true: attachments do not change while a frame is being recorded, and
/// [GlVectorReplay.beginFrame] drops the cache when one ends.
library;

import '../../replay/display_list_player.dart';
import '../gpu_gradient.dart';
import '../gpu_layer_stack.dart';
import '../gpu_path_planning.dart';
import '../gpu_path_repetition.dart';
import '../gpu_path_strategy.dart';
import '../gpu_vector_command_stream.dart';
import '../vector/stencil_cover_draw_plan.dart';
import 'gl_vector_path_recorder.dart';

/// Asks the driver what framebuffer [framebuffer] carries, or null if it
/// cannot be asked. Never throws: a failed query is a refusal to promote.
typedef GlStencilCapabilityQuery = StencilCoverCapabilities? Function(
  int framebuffer,
);

/// Samples asked of a layer target that gets any at all.
///
/// Four rather than the sixteen the surface takes, and the difference is
/// deliberate. A frame has one surface and can have many layers, all of them
/// resident until it ends, so a layer's multisampled colour and stencil are
/// multiplied by the layer count: at `samples * 5` bytes per pixel, sixteen
/// samples on eight 512x512 layers is 168 MiB against the pool's 256 MiB
/// budget, while four is 42 MiB. Four is also the minimum approach C needs to
/// be selected at all, so this is the cheapest allocation that unblocks it.
const int kGlLayerSampleCount = 4;

/// Layers smaller than this on either axis are allocated colour-only.
///
/// 128 px is the size below which the strategy selector would not promote a
/// path anyway: `stencilMinimumDenseMaskBytes` is 16 KiB, which a shape has to
/// be about 128x128 to reach, and a shape cannot be larger than the layer that
/// clips it. Allocating stencil and samples under that threshold buys a
/// capability nothing can use, and an interface opens far more badges, chips
/// and icons than it opens full panels.
const int kGlLayerAttachmentMinimumSize = 128;

/// What a layer of this size should be allocated with on OpenGL.
///
/// The policy `GpuLayerStack` calls, factored out so the offscreen target and
/// the window target cannot drift - the same reason [GlVectorReplay] exists.
/// Colour-only whenever approach C is off, so a default build allocates
/// exactly what it always did.
GpuPassAttachments glLayerAttachmentsFor({
  required int width,
  required int height,
  required bool stencilCoverEnabled,
}) {
  if (!stencilCoverEnabled) return GpuPassAttachments.colorOnly;
  if (width < kGlLayerAttachmentMinimumSize ||
      height < kGlLayerAttachmentMinimumSize) {
    return GpuPassAttachments.colorOnly;
  }
  return const GpuPassAttachments(
    stencilBits: 8,
    sampleCount: kGlLayerSampleCount,
  );
}

/// The ordered-replay objects one GL target owns for a frame.
final class GlVectorReplay {
  GlVectorReplay._({
    required this.stream,
    required this.recorder,
    required this.telemetry,
    required this.layers,
    required this.sparseEnabled,
    required this.stencilEnabled,
    required this.tessellationEnabled,
    required this.gradientCache,
    required this.repetition,
    required GlStencilCapabilityQuery queryStencil,
    required int Function() surfaceFramebuffer,
  })  : _queryStencil = queryStencil,
        _surfaceFramebuffer = surfaceFramebuffer;

  /// Builds the wiring, or returns null when no experimental executor is on.
  ///
  /// Null is the established renderer: the target keeps `GlRenderDevice.submit`
  /// with its dense batch loop, and not one object here is allocated. That is
  /// deliberate - the ordered submitter is a different code path through the
  /// device, and a build with every flag off must not walk it.
  static GlVectorReplay? create({
    required GpuLayerStack layers,
    required bool sparseEnabled,
    required bool stencilEnabled,
    required bool tessellationEnabled,
    required GlStencilCapabilityQuery queryStencil,
    required int Function() surfaceFramebuffer,
    GpuGradientCache? gradientCache,
  }) {
    if (!sparseEnabled && !stencilEnabled && !tessellationEnabled) return null;
    final stream =
        GpuVectorCommandStream<ReplayPaint, GlVectorPathPayload>(layers);
    late final GlVectorReplay wiring;
    // Only the sparse executor consumes the gradient contract, so a cache
    // handed to a device without it would upload ramps nothing can sample.
    final GpuGradientCache? cache = sparseEnabled ? gradientCache : null;
    final recorder = GlVectorPathRecorder(
      stream: stream,
      gradientCache: cache,
      stencilCapabilitiesProbe: () => wiring._stencilCapabilities(),
    );
    wiring = GlVectorReplay._(
      stream: stream,
      recorder: recorder,
      telemetry: GpuPathPlanningTelemetry(
        capabilitiesProbe: (GpuPathDrawTraits traits) =>
            wiring.capabilities(traits),
        // Display-list paths are immutable. Their transform may animate but
        // remains a uniform, so a tessellated mesh stays retainable.
        stabilityProbe: (_) => true,
        // The guard against this wiring starving the dense atlas it competes
        // with: a draw that has repeated is one the atlas would be caching,
        // and no encoding beats a cached quad. See `gpu_path_repetition.dart`.
        repetitionProbe: (path, localToTarget, clip, fillRule) =>
            wiring.repetition.observe(
          GpuPathRepetitionKey(
            path,
            // Device space, not target space: the dense atlas keys its masks
            // by the transform and clip the *sink* hands it, so this has to
            // ask the same question the atlas would have been answering.
            transform: localToTarget,
            clip: clip,
            fillRule: fillRule,
          ),
        ),
        // Sparse is only preferred once its encoding has been measured, and
        // the recorder keeps the plan it measured so the promoted draw does
        // not rasterise the same path twice.
        sparseMetricsProbe: sparseEnabled ? recorder.probeSparseMetrics : null,
        // The variable the cost rule turns on. Reported straight after the
        // metrics probe, so it describes the encode that probe performed.
        crossingsProbe: sparseEnabled ? () => recorder.lastTileCrossings : null,
      ),
      layers: layers,
      sparseEnabled: sparseEnabled,
      stencilEnabled: stencilEnabled,
      tessellationEnabled: tessellationEnabled,
      gradientCache: cache,
      repetition: GpuPathRepetitionTracker(),
      queryStencil: queryStencil,
      surfaceFramebuffer: surfaceFramebuffer,
    );
    return wiring;
  }

  final GpuVectorCommandStream<ReplayPaint, GlVectorPathPayload> stream;
  final GlVectorPathRecorder recorder;
  final GpuPathPlanningTelemetry telemetry;
  final GpuLayerStack layers;

  final bool sparseEnabled;
  final bool stencilEnabled;
  final bool tessellationEnabled;

  /// Where a gradient paint's ramp becomes a resident RGBA8 texture, or null
  /// when this device has no executor that can sample one. The cache is owned
  /// by the wiring and released with it, so a device loss - which rebuilds the
  /// wiring - cannot leave a binding pointing at a freed texture name.
  final GpuGradientCache? gradientCache;

  /// How often each draw has come back, which decides whether the dense atlas
  /// would already be caching it.
  final GpuPathRepetitionTracker repetition;

  final GlStencilCapabilityQuery _queryStencil;
  final int Function() _surfaceFramebuffer;

  /// Framebuffer name -> answer, valid for the frame being recorded.
  final Map<int, StencilCoverCapabilities?> _stencilCache =
      <int, StencilCoverCapabilities?>{};

  /// Starts a frame alongside the layer stack's own.
  void beginFrame() {
    stream.resetForFrame();
    _stencilCache.clear();
    repetition.beginFrame();
  }

  /// What the pass currently being recorded into can execute for a draw whose
  /// paint is (or is not) antialiased.
  ///
  /// Three rules, each of which is an attachment or a coverage fact rather
  /// than a preference. The dense atlas is always available, which is why
  /// every refusal here is a decision about cost and never about correctness.
  ///
  ///   * **Sparse strips** carry analytic coverage in an alpha8 atlas, so they
  ///     are the antialiased route and only that. Encoding an aliased fill
  ///     through them would add a fringe the display list did not ask for.
  ///   * **Tessellation** hands the rasteriser triangles and nothing else.
  ///     With no fringe in its shader, an antialiased fill is only correct on
  ///     a multisampled pass - which is the sample count from the descriptor
  ///     doing the work it was added for. Aliased fills are correct anywhere.
  ///   * **Stencil-then-cover** needs a stencil buffer to accumulate winding
  ///     into *and* at least four samples - `StencilCoverRequirements.forDraw`
  ///     demands the samples for an antialiased draw, and this backend demands
  ///     them for an aliased one too. That second half is not caution, it is a
  ///     measurement: a filled path in this renderer is analytically
  ///     antialiased on every other route, because the CPU rasteriser, the
  ///     dense atlas and the sparse encoder all take their coverage from one
  ///     `ScanlineFiller` and none of them consults the paint's `antiAlias`
  ///     flag for a path. A single-sample cover pass produces a binary edge
  ///     instead, and the same scene differs by 144 levels over 572 boundary
  ///     pixels. Promoting into that would be a visibly different picture
  ///     chosen for speed, which is the one thing a selector may not do.
  GpuPathStrategyCapabilities capabilities(GpuPathDrawTraits traits) {
    final GpuPassAttachments attachments = layers.currentPass.attachments;
    if (traits.hasGradient) return _gradientCapabilities();
    return GpuPathStrategyCapabilities(
      sparseStrips: sparseEnabled && traits.antiAlias,
      tessellation: tessellationEnabled &&
          (!traits.antiAlias || attachments.isMultisampled),
      stencil: stencilEnabled &&
          attachments.hasStencil &&
          attachments.sampleCount >= _minimumStencilSampleCount,
    );
  }

  /// The capabilities of a gradient draw, where the usual fallback is absent.
  ///
  /// Every other draw in this renderer can end up on the dense coverage atlas,
  /// which is why every refusal above is a decision about cost. A gradient
  /// cannot: the atlas stores one alpha per texel and the shader modulates it
  /// by a single vertex colour, so routing a gradient there would paint a flat
  /// fill. Approaches B and C have the same problem - both hand the rasteriser
  /// geometry and a solid material.
  ///
  /// So this reports the sparse route or *nothing at all*. Nothing at all
  /// makes the selector raise `UnsupportedError`, the planning telemetry
  /// contains it, and `GpuRasterSink` turns the missing promotion into a
  /// refusal that names the backend. A gradient is drawn correctly or it is
  /// refused out loud; it is never quietly flattened to its fallback colour.
  ///
  /// Antialiasing does not gate this one. The sparse encoder is the analytic
  /// route and a filled path is analytically antialiased here whatever the
  /// paint says, so an aliased gradient path is the same picture either way -
  /// and the alternative is not a different route, it is no route.
  GpuPathStrategyCapabilities _gradientCapabilities() {
    final bool sparse = sparseEnabled && gradientCache != null;
    return GpuPathStrategyCapabilities(
      analyticPrimitives: false,
      coverageAtlas: false,
      sparseStrips: sparse,
    );
  }

  /// Releases what this wiring retains.
  ///
  /// Called when the target that owns it is disposed or rebuilt after a device
  /// loss. The gradient ramps are GPU textures: after a loss their handles are
  /// already invalid and the cache skips them, which is the same seam the
  /// image and atlas paths use.
  ///
  /// The plan cache holds no GPU resources at all - only CPU encodings - so a
  /// device loss does not *require* dropping it. It is dropped anyway, because
  /// this wiring is rebuilt whole on recovery and a cache left behind would be
  /// arenas nothing can reach.
  void dispose() {
    gradientCache?.clear();
    recorder.sparsePlanCache.clear();
    repetition.clear();
  }

  /// Four: the sample count at which a cover pass's edge stops being binary,
  /// and the count `StencilCoverRequirements.forDraw` requires for an
  /// antialiased draw.
  static const int _minimumStencilSampleCount = 4;

  StencilCoverCapabilities? _stencilCapabilities() {
    if (!stencilEnabled) return null;
    final GpuRenderPass pass = layers.currentPass;
    if (!pass.attachments.hasStencil) return null;
    final int framebuffer = pass.target?.id ?? _surfaceFramebuffer();
    if (_stencilCache.containsKey(framebuffer)) {
      return _stencilCache[framebuffer];
    }
    StencilCoverCapabilities? capabilities;
    try {
      capabilities = _queryStencil(framebuffer);
    } catch (_) {
      // A driver that refuses the query refuses the promotion. The dense
      // atlas draws this path, so there is nothing to report as an error.
      capabilities = null;
    }
    _stencilCache[framebuffer] = capabilities;
    return capabilities;
  }
}
