/// Wires ordered vector replay to a Direct3D 11 target, one description for
/// both the window and the offscreen target.
///
/// `gl_vector_replay.dart` and `gl_vector_path_recorder.dart` are the model,
/// merged into one file here because this backend has two routes where OpenGL
/// has three: there is no sparse-strip executor on Direct3D 11, so there is no
/// encoder to measure, no plan cache to key, no gradient ramp to upload and no
/// crossings probe to report. What is left is small enough that splitting it
/// would put the capability rules and the payload builders that must agree with
/// them in different files - which is precisely the drift
/// `GlVectorPathRecorder._buildTessellated` documents as the failure it was
/// written to stop.
///
/// ## Capabilities are answered per pass, not per device
///
/// The question "may this draw use stencil-then-cover?" has no device-wide
/// answer here either. A window's swap-chain back buffer is single-sample and
/// carries no depth-stencil view; an offscreen readback texture is the same;
/// only a pooled layer target that [d3d11LayerAttachmentsFor] chose to allocate
/// with four samples and a `D24S8` view can execute approach C. So
/// [D3d11VectorReplay.capabilities] reads `GpuRenderPass.attachments` - what
/// the framebuffer the draw is *actually* going into carries - and the
/// consequence is the one GL states: a path that would take approach C on a
/// large layer falls back to the dense coverage atlas on the surface, silently
/// and correctly, because the surface has no stencil. That is a difference in
/// cost, never in pixels; the dense route is the parity route.
///
/// ## Why no driver query, where OpenGL needs one
///
/// `GlVectorReplay` caches a `StencilCoverCapabilities` per framebuffer per
/// frame, because GL can only learn a framebuffer's stencil bits and sample
/// count by binding it and asking the driver - several `glGet` calls and a
/// completeness check, on the hot path of every path in the frame.
///
/// Direct3D 11 never has to ask. Every target here is created by this backend
/// from a descriptor it wrote, so the attachments are known at allocation time
/// and travel on the pass in [GpuPassAttachments]. [d3d11StencilCapabilities]
/// is therefore a pure function of the pass, with no cache to invalidate and no
/// sticky driver error to poison the next unrelated call.
library;

import '../../../geometry/path.dart' show kDefaultFlattenTolerance;
import '../../../geometry/rect.dart';
import '../../../geometry/transform2d.dart';
import '../../replay/display_list_player.dart';
import '../gpu_layer_stack.dart';
import '../gpu_path_dispatch.dart';
import '../gpu_path_planning.dart';
import '../gpu_path_repetition.dart';
import '../gpu_path_strategy.dart';
import '../gpu_pipeline.dart';
import '../gpu_vector_command_stream.dart';
import '../vector/cpu_tessellation.dart';
import '../vector/stencil_cover_draw_plan.dart';

/// Samples asked of a Direct3D 11 layer target that gets any at all.
///
/// Four, for the reason `kGlLayerSampleCount` gives and one this API adds. A
/// frame has one surface and can have many layers, all resident until it ends,
/// so a layer's multisampled colour is multiplied by the layer count - and on
/// this backend a multisampled layer costs *more* than on GL, because the
/// colour cannot be sampled while it is multisampled: the pool allocates the
/// four-sample colour, a `D24S8` of the same size, **and** the single-sample
/// texture the composite quad reads after `ResolveSubresource`. Four is also
/// the minimum `StencilCoverRequirements.forDraw` accepts for an antialiased
/// draw, so it is the cheapest allocation that unblocks approach C at all.
const int kD3d11LayerSampleCount = 4;

/// Layers smaller than this on either axis are allocated colour-only.
///
/// 128 px is the size below which the selector would not promote a path
/// anyway: `stencilMinimumDenseMaskBytes` is 16 KiB, which a shape has to be
/// about 128x128 to reach, and a shape cannot be larger than the layer that
/// clips it. Allocating stencil and samples under that threshold buys a
/// capability nothing can use, and an interface opens far more badges, chips
/// and icons than it opens full panels.
const int kD3d11LayerAttachmentMinimumSize = 128;

/// Four: the sample count at which a cover pass's edge stops being binary, and
/// the count `StencilCoverRequirements.forDraw` demands for an antialiased
/// draw.
const int kD3d11MinimumStencilSampleCount = 4;

/// What a layer of this size should be allocated with on Direct3D 11.
///
/// The policy `GpuLayerStack` calls, factored out so the offscreen target and
/// the window target cannot drift - the same reason [D3d11VectorReplay] exists.
/// Colour-only whenever approach C is off, so a default build allocates exactly
/// what it always did and pays neither the resolve nor the depth-stencil plane.
GpuPassAttachments d3d11LayerAttachmentsFor({
  required int width,
  required int height,
  required bool stencilCoverEnabled,
}) {
  if (!stencilCoverEnabled) return GpuPassAttachments.colorOnly;
  if (width < kD3d11LayerAttachmentMinimumSize ||
      height < kD3d11LayerAttachmentMinimumSize) {
    return GpuPassAttachments.colorOnly;
  }
  return const GpuPassAttachments(
    stencilBits: 8,
    sampleCount: kD3d11LayerSampleCount,
  );
}

/// What a pass carrying [attachments] can execute for approach C, or null.
///
/// Null means "this pass cannot run a stencil pass", which is a refusal and not
/// an error: the dense atlas draws the path instead.
///
/// The four booleans are all true and they are not optimism. Direct3D 11
/// guarantees separate front/back stencil operations (`FrontFace` and
/// `BackFace` are distinct members of `D3D11_DEPTH_STENCIL_DESC`), wrapping
/// increment and decrement (`INCR`/`DECR`, distinct from the saturating
/// `INCR_SAT`/`DECR_SAT`) and `INVERT`, on every feature level this backend
/// will open a device at. `scissoredClear` is true because the clear here is a
/// scissored quad draw with `REPLACE` rather than `ClearDepthStencilView`,
/// which takes no rectangle - see `d3d11_vector_executors.dart`, difference 2.
StencilCoverCapabilities? d3d11StencilCapabilities(
  GpuPassAttachments attachments,
) {
  if (!attachments.hasStencil) return null;
  return StencilCoverCapabilities(
    stencilBits: attachments.stencilBits,
    sampleCount: attachments.sampleCount,
    separateFrontBackOperations: true,
    wrapOperations: true,
    invertOperation: true,
    scissoredClear: true,
  );
}

/// A complete, retained command for one promoted draw.
sealed class D3d11VectorPathPayload {
  const D3d11VectorPathPayload();

  GpuPathStrategy get strategy;
}

final class D3d11TessellatedPathPayload extends D3d11VectorPathPayload {
  const D3d11TessellatedPathPayload({
    required this.mesh,
    required this.localToTarget,
    required this.clip,
  });

  final TessellatedPathMesh mesh;

  /// Kept in **local** coordinates with the matrix beside it, which is the
  /// whole point of approach B: `ContentMotionHint.transforming` declares a
  /// subtree whose geometry repeats while its matrix moves, and a mesh keyed on
  /// local coordinates survives every frame of that while a device-space mask
  /// misses every one.
  final Transform2D localToTarget;
  final Rect clip;

  @override
  GpuPathStrategy get strategy => GpuPathStrategy.tessellatedMesh;
}

final class D3d11StencilPathPayload extends D3d11VectorPathPayload {
  const D3d11StencilPathPayload(this.plan, this.capabilities);

  final StencilCoverDrawPlan plan;

  /// The attachments the plan was built against, captured at record time.
  ///
  /// Carried on the payload rather than re-derived at submission because the
  /// plan's `append` already validated the fill rule's requirements against
  /// exactly these, and a submission that re-asked a different pass would
  /// either refuse a legal draw or - worse - accept one whose winding needs
  /// more bits than the target has.
  final StencilCoverCapabilities capabilities;

  @override
  GpuPathStrategy get strategy => GpuPathStrategy.stencilThenCover;
}

/// Converts selector candidates into complete retained Direct3D 11 payloads.
///
/// CPU preparation only. It never calls Direct3D: an accepted draw is retained
/// in [GpuVectorCommandStream] and executed later by the device in the exact
/// dense/vector pass order. Issuing a native call from here would draw before
/// an earlier dense batch, or into the wrong `saveLayer` target.
final class D3d11VectorPathRecorder implements GpuPathCommandRecorder {
  D3d11VectorPathRecorder({
    required this.stream,
    required this.stencilCapabilitiesProbe,
    CpuTessellatedPathCache? tessellationCache,
    this.flattenTolerance = kDefaultFlattenTolerance,
    this.stencilMaxTrianglesPerDraw = 65536,
  }) : tessellationCache = tessellationCache ?? CpuTessellatedPathCache() {
    if (!flattenTolerance.isFinite || flattenTolerance <= 0) {
      throw ArgumentError.value(
        flattenTolerance,
        'flattenTolerance',
        'must be finite and positive',
      );
    }
    if (stencilMaxTrianglesPerDraw <= 0) {
      throw ArgumentError.value(
        stencilMaxTrianglesPerDraw,
        'stencilMaxTrianglesPerDraw',
        'must be positive',
      );
    }
  }

  final GpuVectorCommandStream<ReplayPaint, D3d11VectorPathPayload> stream;

  /// The stencil features of the framebuffer the *current pass* binds, or null.
  final StencilCoverCapabilities? Function() stencilCapabilitiesProbe;

  /// Retained local meshes for approach B, keyed by content, fill rule and
  /// flattening tolerance.
  ///
  /// Public because its budget and eviction counters are the diagnostic that
  /// says whether the route is a fast path or a treadmill, and because the
  /// wiring that owns this recorder drops it when the device is lost.
  final CpuTessellatedPathCache tessellationCache;

  final double flattenTolerance;
  final int stencilMaxTrianglesPerDraw;

  int acceptedCount = 0;
  int refusalCount = 0;
  int failureCount = 0;
  Object? lastError;

  @override
  bool tryRecord(GpuPathDispatchRequest request) {
    try {
      // Validated before any arena is allocated. Both executors use this same
      // mapping, so accepting an unsupported blend here would defer a
      // deterministic refusal until submission - after dense work had drawn.
      gpuBlendForMode(request.paint.blendMode);
      // Neither route has a gradient material: both hand the rasteriser
      // geometry and one solid colour. A gradient paint that reached either
      // candidate is refused here rather than drawn as its unused fallback
      // colour, and `D3d11VectorReplay._gradientCapabilities` makes sure the
      // selector never proposes one.
      if (request.paint.gradient != null) return _refuse();

      final (Transform2D localToTarget, Rect targetClip) =
          _targetSpace(request.localToTarget, request.clip);

      final D3d11VectorPathPayload? payload =
          switch (request.candidateStrategy) {
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
        GpuPathStrategy.sparseStrips ||
        GpuPathStrategy.computeTiles =>
          null,
      };
      if (payload == null || payload.strategy != request.candidateStrategy) {
        return _refuse();
      }

      // Commit last. Both builders above work in private arenas, so a rejected
      // candidate cannot leave a partial command in the ordered stream.
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

  D3d11VectorPathPayload? _buildTessellated(
    GpuPathDispatchRequest request, {
    required Transform2D localToTarget,
    required Rect targetClip,
  }) {
    // Deliberately the same predicate `D3d11VectorReplay.capabilities`
    // reports. The two disagreeing is not a wrong picture but something harder
    // to find: a route the selector keeps choosing and this method silently
    // refuses, so every antialiased draw on a multisampled target pays for a
    // promotion it never receives and lands back on the dense atlas one
    // refusal later.
    if (request.paint.antiAlias &&
        !stream.layers.currentPass.attachments.isMultisampled) {
      return null;
    }
    final TessellatedPathMesh mesh = tessellationCache.resolve(
      request.path,
      fillRule: request.fillRule,
      flattenTolerance: flattenTolerance,
    );
    if (mesh.indices.isEmpty) return null;
    return D3d11TessellatedPathPayload(
      mesh: mesh,
      localToTarget: localToTarget,
      clip: targetClip,
    );
  }

  D3d11VectorPathPayload? _buildStencil(
    GpuPathDispatchRequest request, {
    required Transform2D localToTarget,
    required Rect targetClip,
  }) {
    // The pass's own attachments first: an executor asked to accumulate
    // winding into a target with no depth-stencil view would draw the cover
    // quad unmasked, which is a filled bounding box where a shape was asked
    // for.
    final GpuRenderPass pass = stream.layers.currentPass;
    if (!pass.attachments.hasStencil) return null;
    final StencilCoverCapabilities? capabilities = stencilCapabilitiesProbe();
    if (capabilities == null) return null;
    final plan = StencilCoverDrawPlan(
      maxTrianglesPerDraw: stencilMaxTrianglesPerDraw,
    );
    final int draw = plan.append(
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
    return D3d11StencilPathPayload(plan, capabilities);
  }

  bool _refuse() {
    refusalCount++;
    return false;
  }

  /// Moves a device-space transform and clip into the current pass's target
  /// space: the layer origin subtracted, then clamped to the target's size.
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

/// The ordered-replay objects one Direct3D 11 target owns for a frame.
final class D3d11VectorReplay {
  D3d11VectorReplay._({
    required this.stream,
    required this.recorder,
    required this.telemetry,
    required this.layers,
    required this.stencilEnabled,
    required this.tessellationEnabled,
    required this.repetition,
  });

  /// Builds the wiring, or returns null when neither executor is on.
  ///
  /// Null is the established renderer: the target keeps `D3d11RenderDevice
  /// .submit` with its dense batch loop and not one object here is allocated.
  /// That is deliberate - the ordered submitter is a different code path
  /// through the device, and a build with both flags off must not walk it.
  static D3d11VectorReplay? create({
    required GpuLayerStack layers,
    required bool stencilEnabled,
    required bool tessellationEnabled,
  }) {
    if (!stencilEnabled && !tessellationEnabled) return null;
    final stream =
        GpuVectorCommandStream<ReplayPaint, D3d11VectorPathPayload>(layers);
    late final D3d11VectorReplay wiring;
    final recorder = D3d11VectorPathRecorder(
      stream: stream,
      stencilCapabilitiesProbe: () => wiring.stencilEnabled
          ? d3d11StencilCapabilities(layers.currentPass.attachments)
          : null,
    );
    wiring = D3d11VectorReplay._(
      stream: stream,
      recorder: recorder,
      telemetry: GpuPathPlanningTelemetry(
        capabilitiesProbe: (GpuPathDrawTraits traits) =>
            wiring.capabilities(traits),
        // Display-list paths are immutable. Their transform may animate but
        // remains a constant-buffer register, so a tessellated mesh stays
        // retainable.
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
        // No sparse metrics and no crossings probe: this backend has no sparse
        // executor, so `capabilities.sparseStrips` is always false and the
        // selector never reaches the branch that would read them.
      ),
      layers: layers,
      stencilEnabled: stencilEnabled,
      tessellationEnabled: tessellationEnabled,
      repetition: GpuPathRepetitionTracker(),
    );
    return wiring;
  }

  final GpuVectorCommandStream<ReplayPaint, D3d11VectorPathPayload> stream;
  final D3d11VectorPathRecorder recorder;
  final GpuPathPlanningTelemetry telemetry;
  final GpuLayerStack layers;

  final bool stencilEnabled;
  final bool tessellationEnabled;

  /// How often each draw has come back, which decides whether the dense atlas
  /// would already be caching it.
  final GpuPathRepetitionTracker repetition;

  /// Starts a frame alongside the layer stack's own.
  void beginFrame() {
    stream.resetForFrame();
    repetition.beginFrame();
  }

  /// What the pass currently being recorded into can execute for a draw whose
  /// paint is (or is not) antialiased.
  ///
  /// Three rules, each an attachment or a coverage fact rather than a
  /// preference. The dense atlas is always available, which is why every
  /// refusal here is a decision about cost and never about correctness.
  ///
  ///   * **Sparse strips** are never reported. This backend has no encoder and
  ///     no executor for them; saying otherwise would make the selector prefer
  ///     a route the recorder would refuse a moment later, and every such draw
  ///     would pay the selection and land on the atlas anyway.
  ///   * **Tessellation** hands the rasteriser triangles and nothing else.
  ///     With no fringe in its pixel shader, an antialiased fill is only
  ///     correct on a multisampled pass - which is the sample count from the
  ///     pass descriptor doing the work it was added for. Aliased fills are
  ///     correct anywhere.
  ///   * **Stencil-then-cover** needs a depth-stencil view to accumulate
  ///     winding into *and* at least four samples.
  ///     `StencilCoverRequirements.forDraw` demands the samples for an
  ///     antialiased draw, and this backend demands them for an aliased one
  ///     too. That second half is not caution, it is the measurement GL
  ///     records: a filled path in this renderer is analytically antialiased
  ///     on every other route, because the CPU rasteriser and the dense atlas
  ///     both take their coverage from one `ScanlineFiller` and neither
  ///     consults the paint's `antiAlias` flag for a path. A single-sample
  ///     cover pass produces a binary edge instead, and promoting into that
  ///     would be a visibly different picture chosen for speed - the one thing
  ///     a selector may not do.
  GpuPathStrategyCapabilities capabilities(GpuPathDrawTraits traits) {
    final GpuPassAttachments attachments = layers.currentPass.attachments;
    if (traits.hasGradient) return _gradientCapabilities();
    return GpuPathStrategyCapabilities(
      // Stated rather than left to the default, because it is now a claim
      // about a shader that exists: `d3d11_shaders.dart` decodes a corner
      // radius out of the solid pipeline's unused texture coordinate and
      // computes the coverage from the field. It needs no second program, no
      // attachment and no sample count - which is why it is the one capability
      // here with no condition attached, and why the two below both have one.
      analyticPrimitives: true,
      tessellation: tessellationEnabled &&
          (!traits.antiAlias || attachments.isMultisampled),
      stencil: stencilEnabled &&
          attachments.hasStencil &&
          attachments.sampleCount >= kD3d11MinimumStencilSampleCount,
    );
  }

  /// The capabilities of a gradient draw, where the usual fallback is absent.
  ///
  /// Every other draw in this renderer can end up on the dense coverage atlas,
  /// which is why every refusal above is a decision about cost. A gradient
  /// cannot: the atlas stores one alpha per texel and the shader modulates it
  /// by a single vertex colour, so routing a gradient there would paint a flat
  /// fill. Approaches B and C have the same problem - both hand the rasteriser
  /// geometry and a solid material - and this backend has no sparse route to
  /// fall back to.
  ///
  /// So this reports **nothing at all**, which is what the selector needs to
  /// raise `UnsupportedError`. The planning telemetry contains it and
  /// `GpuRasterSink` turns the missing promotion into a refusal that names the
  /// backend and says a gradient cannot be flattened to its fallback colour.
  /// That is exactly the behaviour a Direct3D 11 device already had before
  /// these routes existed, reached by a shorter path.
  GpuPathStrategyCapabilities _gradientCapabilities() =>
      const GpuPathStrategyCapabilities(
        // False even now that the backend has the shader, and for exactly the
        // reason the coverage atlas is false beside it: the analytic quad
        // modulates one vertex colour by a coverage it computed, and a ramp is
        // not a colour. Promoting a gradient into it would paint a flat fill -
        // the wrong picture this whole method exists to refuse. `GpuRasterSink`
        // refuses a gradient rounded rectangle a second time on its own, in
        // `fillDeviceRRect`, so the two agree even on a device with no vector
        // wiring at all and therefore no call to this method.
        analyticPrimitives: false,
        coverageAtlas: false,
      );

  /// Releases what this wiring retains.
  ///
  /// The mesh cache holds no GPU resources at all - only CPU tessellations - so
  /// a device loss does not *require* dropping it. It is dropped anyway,
  /// because this wiring is rebuilt whole on recovery and a cache left behind
  /// would be meshes nothing can reach. Its GPU counterpart, the executor's
  /// buffer inventory, is dropped by the device.
  void dispose() {
    recorder.tessellationCache.clear();
    repetition.clear();
  }
}
