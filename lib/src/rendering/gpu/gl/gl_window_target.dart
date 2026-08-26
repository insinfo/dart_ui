/// The GL target that puts pixels on a screen.
///
/// [GlOffscreenTarget] renders into a framebuffer object and calls
/// `glReadPixels` on every present. Its own header says section 23 of the
/// roadmap forbids that for a production backend ("backend GPU não deve fazer
/// readback por frame"), and it is right: a readback stalls the pipeline until
/// the GPU has finished, copies a whole surface across the bus, and then hands
/// it to the window system to copy again. What it buys is a [Framebuffer] a
/// golden test can compare, which is worth the cost in a test and nothing at
/// all on a screen.
///
/// This target does the other thing. It binds framebuffer 0 - the default
/// framebuffer, which for a context created on a window is that window's back
/// buffer - draws into it, and swaps. The pixels never leave the GPU. There is
/// deliberately no way to read them back from here: `GlRenderDevice._readPixels`
/// stayed private to `gl_backend.dart` precisely so this class cannot grow the
/// habit by accident.
///
/// ## The generation contract, and why it is checked twice
///
/// `lib/src/foundation/lifecycle.dart` explains the rule: native code goes on
/// delivering work for surfaces that have already moved, and "is it still
/// valid?" cannot be answered by a null check. A window resizes on the window
/// system's schedule. Between the moment a frame is recorded and the moment it
/// is swapped, the back buffer may have become a different size - which means
/// the geometry in the batcher is for a viewport that no longer exists, and
/// swapping it shows a stretched or torn frame.
///
/// So [generation] folds three counters into one number: this target's own
/// resizes, the device's loss count, and - the one that matters - the window's
/// [GenerationToken], shared through [GlWindowSurfaceDescriptor.generation].
/// [present] compares it against the frame's on entry *and* again immediately
/// before the swap, because everything in between yields to the event loop and
/// a resize is exactly the thing that arrives while a frame is being drawn.
/// A mismatch is [PresentStatus.stale], which the roadmap defines as normal:
/// dropping one frame during a resize is what a correct renderer does.
///
/// ## What this target cannot give a caller, and how it now says so
///
/// A windowed GPU target genuinely has no CPU-visible pixels: they are in a
/// back buffer the driver owns, and reading them back per frame is the thing
/// section 23 forbids. [Frame.framebuffer] used to be non-nullable, so this
/// class carried a 1x1 placeholder framebuffer that nothing ever read and that
/// only this comment stopped anyone from mistaking for the window's contents.
///
/// That placeholder is gone. `Frame` now stores the framebuffer nullably and
/// exposes [Frame.cpuPixels] for callers that handle "there are none", keeping
/// [Frame.framebuffer] as a non-null accessor that raises a named failure
/// instead of handing back one meaningless pixel. This target passes no
/// framebuffer at all. Nothing in the draw path is affected: [beginFrame] takes
/// its damage rectangle from the descriptor's pixel size, and
/// [renderDisplayList] takes its device bounds from the same place.
library;

import 'dart:async';
import 'dart:typed_data';

import '../../../foundation/diagnostics.dart';
import '../../../foundation/lifecycle.dart';
import '../../../geometry/rect.dart';
import '../../../geometry/transform2d.dart';
import '../../../graphics/display_list.dart';
import '../../../graphics/display_list_reader.dart';
import '../../framebuffer.dart';
import '../../present_mode.dart';
import '../../renderer.dart';
import '../../replay/display_list_player.dart';
import '../gpu_batcher.dart';
import '../gpu_glyph_atlas.dart';
import '../gpu_gradient.dart';
import '../gpu_layer_stack.dart';
import '../gpu_mask_atlas.dart';
import '../gpu_path_strategy.dart';
import '../gpu_raster_sink.dart';
import '../gpu_recovery.dart';
import '../gpu_texture.dart';
import '../gpu_vector_command_stream.dart';
import '../gpu_vector_submission_cursor.dart';
import '../vector/sparse_strip_draw_plan.dart';
import '../vector/stencil_cover_draw_plan.dart';
import '../vector/vector_plan_cache.dart';
import 'gl_backend.dart';
import 'gl_bindings.dart';
import 'gl_framebuffer_pool.dart';
import 'gl_present_pacer.dart';
import 'gl_surface_descriptor.dart';
import 'gl_vector_path_recorder.dart';
import 'gl_vector_replay.dart';

/// A render target backed by a window's back buffer.
final class GlWindowTarget
    with DisposableMixin
    implements DisplayListRenderTarget, GlRecoverableTarget, PresentPacer {
  /// Wraps [surface] for [device].
  ///
  /// The constructor is public - unlike [GlOffscreenTarget]'s - because this
  /// class is in a different library from the device that builds it and Dart
  /// has no "visible to my package only" between the two. `createTarget` is
  /// still the way to get one; calling this directly with a device whose
  /// context was not created on [GlWindowSurfaceDescriptor.nativeHandle] is a
  /// caller error this class cannot detect, because the handle is an opaque
  /// integer here on purpose (see `gl_surface_descriptor.dart`).
  ///
  /// Takes no ownership of the window or of the [GlSwapChain]. Disposing this
  /// target releases the textures it uploaded and nothing else: the window
  /// outlives its targets, which is the split `renderer.dart` describes
  /// between a target and the surface it draws into.
  GlWindowTarget(this._device, GlWindowSurfaceDescriptor surface)
      : _surface = surface,
        _observedWindowGeneration = surface.generation.current {
    _maskAtlas = GpuMaskAtlas();
    _glyphAtlas = GpuGlyphAtlas();
    _fonts = GlFontResolver();
    _images = GlImageCache(_device);
    _buildAtlasObjects();
    _device.registerTarget(this);
  }

  /// Creates the atlas textures and everything downstream of their ids.
  ///
  /// Shared by the constructor and by [_repopulateAtlasObjects], for the reason
  /// `gl_backend.dart` gives for its copy: the sink holds the mask and glyph
  /// texture ids as final fields, so a recovery has to rebuild the sink rather
  /// than the textures alone, and a rebuild that drifted from the constructor
  /// would draw a frame that is subtly wrong instead of one that fails.
  void _buildAtlasObjects() {
    _maskTexture = _device.createTexture(
      width: _maskAtlas.width,
      height: _maskAtlas.height,
      format: GpuTextureFormat.alpha8,
      // One texel per pixel by construction, so nearest reproduces the CPU
      // rasteriser's coverage byte exactly and linear would blur it.
      filter: GpuTextureFilter.nearest,
    );
    // Text is wired here exactly as it is on the offscreen target, and that
    // symmetry is the point: a window is where text is actually read, so a
    // backend whose *test* target drew glyphs and whose *window* target
    // refused them would pass every golden test and show a blank panel on
    // screen. One atlas per target rather than one per device, matching the
    // mask atlas: an atlas is written during a frame and recycled mid-frame
    // when it fills, and two targets sharing one would recycle each other's
    // texels out from under quads already in a vertex buffer.
    _glyphTexture = _device.createTexture(
      width: _glyphAtlas.width,
      height: _glyphAtlas.height,
      format: GpuTextureFormat.alpha8,
      // Nearest: a glyph quad is placed on whole pixels so that one texel is
      // one pixel, and a linear tap would resample coverage already on grid.
      filter: GpuTextureFilter.nearest,
    );
    // Layers cost the same here as on the offscreen target and are wired the
    // same way: a pool of framebuffer objects, a device-independent stack, and
    // one flush hook shared by both atlases. Without them a `saveLayer` with
    // an opacity would be refused by name - which is correct, and is not the
    // same thing as being drawable.
    _layerPool = GlFramebufferPool(
      factory: GlDeviceFramebufferFactory(
        gl: _device.api,
        scratchNames: _device.scratchNames,
        makeCurrent: _device.makeCurrentOrLose,
        onError: (String what) => _device.state.markLost(
          BackendDiagnostic(
            kind: DiagnosticKind.surfaceCreationFailed,
            message: 'a layer target could not be created',
            detail: what,
          ),
        ),
      ),
    );
    _layers = GpuLayerStack(
      allocator: _layerPool,
      backendName: GlRendererBackend.backendName,
      // Stencil and samples for a layer big enough that a promoted draw
      // inside it could pay for them. See `GpuLayerStack.layerAttachmentPolicy`
      // for why the answer cannot be derived from the layer's contents, and
      // `glLayerAttachmentsFor` for the size threshold.
      layerAttachmentPolicy: (int width, int height) => glLayerAttachmentsFor(
        width: width,
        height: height,
        stencilCoverEnabled: _device.experimentalStencilCoverEnabled,
      ),
    );
    // The same wiring the offscreen target builds, from the same description,
    // so a golden test and the screen take the same route through the
    // renderer. See `gl_vector_replay.dart`.
    final GlVectorReplay? vector = GlVectorReplay.create(
      layers: _layers,
      sparseEnabled: _device.experimentalSparseStripsEnabled,
      stencilEnabled: _device.experimentalStencilCoverEnabled,
      tessellationEnabled: _device.experimentalCpuTessellationEnabled,
      queryStencil: (int framebuffer) => _device.queryStencilCoverCapabilities(
          surfaceFramebuffer: framebuffer),
      // A window renders into the default framebuffer, whose attachments came
      // from the pixel format the context was created with - this backend
      // never creates it and so can only ask.
      surfaceFramebuffer: () => 0,
      // Rebuilt with the wiring, so a device loss cannot leave a gradient
      // binding pointing at a texture name the driver already freed.
      gradientCache: GpuGradientCache(allocator: _device),
    );
    _vector = vector;
    _vectorStream = vector?.stream;
    _vectorRecorder = vector?.recorder;
    _sink = GpuRasterSink(
      batcher: _batcher,
      backendName: GlRendererBackend.backendName,
      maskAtlas: _maskAtlas,
      maskTextureId: _maskTexture.id,
      imageResolver: _images,
      glyphAtlas: _glyphAtlas,
      glyphTextureId: _glyphTexture.id,
      fontResolver: _fonts,
      layerStack: _layers,
      onAtlasFlush: _flushAtlases,
      pathPlanningTelemetry: vector?.telemetry,
      pathCommandRecorder: vector?.recorder,
    );
    _player = DisplayListPlayer(_sink);
  }

  final GlRenderDevice _device;
  final GpuBatcher _batcher = GpuBatcher();

  late final GpuMaskAtlas _maskAtlas;
  late final GpuGlyphAtlas _glyphAtlas;
  late final GlFontResolver _fonts;
  late final GlImageCache _images;

  // Not final: a device loss destroys all six and a recovery rebuilds them.
  late GlTexture _maskTexture;
  late GlTexture _glyphTexture;
  late GlFramebufferPool _layerPool;
  late GpuLayerStack _layers;
  late GpuRasterSink _sink;
  late DisplayListPlayer _player;
  GlVectorReplay? _vector;
  GpuVectorCommandStream<ReplayPaint, GlVectorPathPayload>? _vectorStream;
  GlVectorPathRecorder? _vectorRecorder;
  final GpuVectorSubmissionCursor _vectorCursor = GpuVectorSubmissionCursor();

  // -------------------------------------------------------------------
  // Device-loss recovery
  // -------------------------------------------------------------------

  /// Step 5's inventory for this target.
  ///
  /// Shorter than [GlOffscreenTarget]'s by exactly one entry, and the missing
  /// one is the point: an offscreen target owns its colour texture and its
  /// framebuffer object, and a window target owns neither. Framebuffer 0 is the
  /// *window's* back buffer; the driver reallocates it when the context is
  /// restored and nothing on this side creates or destroys it. A recovery that
  /// tried to recreate it would be recreating the window.
  @override
  Iterable<GpuRecoverableResource> recoverableResources() sync* {
    yield CallbackGpuResource.fixed(
      resourceName: 'opengl window atlases '
          '(mask ${_maskAtlas.width}x${_maskAtlas.height}, glyph '
          '${_glyphAtlas.width}x${_glyphAtlas.height})',
      recovery: GpuResourceRecovery.rebuilt,
      onDiscard: _discardAtlasObjects,
      onRepopulate: _repopulateAtlasObjects,
    );
    yield* _images.recoverableResources();
  }

  void _discardAtlasObjects() {
    // The frame in flight goes with the device: its batches name textures the
    // driver has freed, so it must never be submitted after the recovery.
    _batcher.beginFrame();
    _submittedBatches = 0;
    _pendingClear = null;
    _layers.endFrame();
    _layerPool.discardAfterDeviceLoss();
    // The gradient ramps go with the context. `clear` skips handles that
    // are already invalid, so this frees what survived and forgets the
    // rest; the rebuild below installs a fresh cache either way.
    _vector?.dispose();
    _device
      ..releaseTexture(_maskTexture)
      ..releaseTexture(_glyphTexture);
    // Both atlases are caches that outlive a frame, so both have to be told
    // their texels are gone. The mask atlas is the one that is easy to miss:
    // its `beginFrame` deliberately *keeps* every cached mask, so a static
    // rounded rectangle drawn before the loss would be found resident,
    // re-batched against a texture that was never re-uploaded, and drawn as
    // nothing at all - a frame that differs from the pre-loss one by exactly
    // the shapes the cache was working for.
    _maskAtlas.recycle();
    _glyphAtlas.clear();
  }

  BackendDiagnostic? _repopulateAtlasObjects() {
    try {
      _buildAtlasObjects();
    } on UnsupportedCapabilityError catch (error) {
      return BackendDiagnostic(
        kind: DiagnosticKind.incompatibleDevice,
        message: 'the recovered GL device refused an atlas texture',
        detail: '$error',
      );
    }
    return _device.lastError;
  }

  /// How many batches of the current frame have already been drawn. See
  /// [GpuRasterSink.onAtlasFlush]: a batch drawn twice blends twice.
  int _submittedBatches = 0;

  /// Where layers get their offscreen targets. Exposed for a memory report and
  /// for a test that asserts the same layer drawn on ten frames created one
  /// framebuffer; reuse is invisible from the pixels.
  GlFramebufferPool get layerPool => _layerPool;

  /// The glyph coverage this target keeps between frames, for the same kind of
  /// question [layerPool] answers: whether a static screen stopped rasterising
  /// after its first frame, and whether a full atlas was recycled mid-frame.
  GpuGlyphAtlas get glyphAtlas => _glyphAtlas;

  /// `glTexSubImage2D` calls this target has made for glyph coverage. A frame
  /// that redraws the same text must not increase it.
  int get glyphUploadCount => _glyphUploadCount;
  int _glyphUploadCount = 0;

  int get experimentalVectorCommandCount =>
      _vectorStream?.vectorCommandCount ?? 0;
  int get experimentalVectorAcceptedCount =>
      _vectorRecorder?.acceptedCount ?? 0;

  /// The strategy that owned the last observed path's pixels, and the one the
  /// selector proposed for it. See `gl_backend.dart` for why both are exposed.
  GpuPathStrategy? get lastExecutedPathStrategy =>
      _vector?.telemetry.lastEvent?.executedStrategy;
  GpuPathStrategy? get lastCandidatePathStrategy =>
      _vector?.telemetry.lastEvent?.candidate.strategy;

  /// The sparse encodings this target retains between draws and frames.
  ///
  /// Exposed for the question pixels cannot answer: whether the second frame
  /// of a static scene rasterised its coverage again. A cache that missed
  /// every time draws an identical picture and spends the frame budget doing
  /// it - see `vector_plan_cache.dart`.
  VectorPlanCache<SparseStripDrawPlan>? get sparsePlanCache =>
      _vector?.recorder.sparsePlanCache;

  GlWindowSurfaceDescriptor _surface;
  int? _pendingClear;

  /// Bumped by [resize] and by device loss. Folded into [generation] with the
  /// window's own counter rather than replacing it: the two invalidate for
  /// different reasons and either one alone would miss the other's.
  int _generation = 0;

  /// The loss count [generation] already accounts for, so a device lost twice
  /// bumps the generation twice and no more.
  int _observedLossCount = 0;

  /// The window generation the descriptor was last reconciled against.
  ///
  /// A window that resizes without anybody calling [resize] - which is the
  /// normal case, because the resize event and the frame loop are different
  /// code paths - invalidates the token. Frames are then rejected until the
  /// owner calls [resize] with the new size, which is the right behaviour:
  /// this class must not guess the new size, it has no way to ask the window.
  int _observedWindowGeneration;

  /// The textures this target uploaded for drawn images.
  GlImageCache get images => _images;

  GpuBatcher get batcher => _batcher;

  /// How the back buffer reaches the screen. Exposed so an owner can set the
  /// swap interval without holding the platform object separately.
  GlSwapChain get swapChain => _surface.swapChain;

  /// This window's presentation pacing, as a [PresentPacer].
  ///
  /// The typed answer to "how should frames reach the display", where
  /// [swapChain] is the untyped one. `PresentMode` existed as a contract with
  /// no implementation at all until this getter: nothing outside
  /// `present_mode.dart` implemented [PresentPacer], so an application asking
  /// for a mode had nowhere to ask. `GlSwapChainPresentPacer` turns
  /// [GlSwapChain.setSwapInterval] into that answer for every GL window -
  /// WGL, GLX and EGL alike - and refuses [PresentMode.mailbox] by name
  /// because no swap-interval API can express it.
  ///
  /// Built once and kept, because the pacer remembers what is in force: a
  /// fresh instance per call would report [PresentMode.fifo] as the applied
  /// mode in a refusal even after the owner had moved the window to
  /// [PresentMode.immediate].
  ///
  /// Type-tested for exactly as `present_mode.dart` documents:
  ///
  /// ```dart
  /// if (target case final PresentPacer pacer) { ... }
  /// ```
  ///
  /// so this class *implements* [PresentPacer] as well as exposing it, and an
  /// owner holding a bare `RenderTarget` needs no cast to a GL type.
  late final GlSwapChainPresentPacer presentPacer = GlSwapChainPresentPacer(
    _surface.swapChain,
    surfaceDescription: 'the OpenGL window back buffer '
        '(${_surface.pixelWidth}x${_surface.pixelHeight})',
  );

  @override
  Set<PresentMode> get supportedPresentModes =>
      presentPacer.supportedPresentModes;

  @override
  PresentMode get presentMode => presentPacer.presentMode;

  @override
  PresentModeOutcome requestPresentMode(PresentMode mode) =>
      presentPacer.requestPresentMode(mode);

  @override
  bool awaitVerticalBlank() => presentPacer.awaitVerticalBlank();

  @override
  GlWindowSurfaceDescriptor get surface => _surface;

  @override
  int get generation {
    final losses = _device.state.lossCount;
    if (losses != _observedLossCount) {
      _observedLossCount = losses;
      _generation++;
    }
    return _generation + _surface.generation.current;
  }

  /// Whether the window has been invalidated since this target last agreed
  /// with it.
  ///
  /// True means every frame will be rejected until [resize] is called with the
  /// window's current size. Exposed so an owner can distinguish "my frames are
  /// being dropped because I have not reconciled the resize" from "my frames
  /// are being dropped because the device is gone", which produce the same
  /// [PresentStatus] and have completely different fixes.
  bool get needsResize =>
      _surface.generation.current != _observedWindowGeneration;

  /// The attachments of the window's default framebuffer, asked once.
  ///
  /// This backend does not create framebuffer 0 - the pixel format the context
  /// was made with did - so the only honest way to know whether it carries
  /// stencil is to ask the driver. The answer cannot change while the context
  /// lives, so it is cached; a lost device rebuilds this target and the next
  /// frame asks again.
  ///
  /// Colour-only when approach C is off, because the query lives on the
  /// stencil-cover driver and a target with no stencil executor has nothing to
  /// do with the answer. A driver that refuses the query is also read as
  /// colour-only: that is a refusal to promote, and the dense atlas draws
  /// every path either way.
  GpuPassAttachments _defaultFramebufferAttachments() {
    final GpuPassAttachments? cached = _surfaceAttachments;
    if (cached != null) return cached;
    if (!_device.experimentalStencilCoverEnabled) {
      return _surfaceAttachments = GpuPassAttachments.colorOnly;
    }
    try {
      final StencilCoverCapabilities capabilities =
          _device.queryStencilCoverCapabilities();
      return _surfaceAttachments = GpuPassAttachments(
        stencilBits: capabilities.stencilBits,
        sampleCount: capabilities.sampleCount,
      );
    } catch (_) {
      return _surfaceAttachments = GpuPassAttachments.colorOnly;
    }
  }

  GpuPassAttachments? _surfaceAttachments;

  @override
  Frame beginFrame(FrameRequest request) {
    throwIfDisposed();
    _batcher.beginFrame();
    _maskAtlas.beginFrame();
    // Keeps every glyph and advances the counter its LRU compares against; a
    // target that forgot it would leave every plot pinned to the frame in
    // progress and report the atlas permanently full.
    _glyphAtlas.beginFrame();
    _layers.beginFrame(
      surfaceWidth: _surface.pixelWidth,
      surfaceHeight: _surface.pixelHeight,
      surfaceAttachments: _defaultFramebufferAttachments(),
    );
    _vector?.beginFrame();
    _vectorCursor.reset();
    _submittedBatches = 0;
    _pendingClear = request.clearColor;
    return Frame(
      target: this,
      // No framebuffer, and that is the truth rather than an omission: the
      // pixels are in the window's back buffer and never come back across the
      // bus. See the library comment.
      damage: request.damage ?? _surfaceRect,
      generation: generation,
    );
  }

  /// Draws the recorded batches into the window's back buffer and swaps it.
  ///
  /// Never calls `glReadPixels`. The failure modes, in the order they are
  /// checked, each producing a named [PresentResult] rather than a throw:
  ///
  ///   1. the device is already lost - retrying is pointless, the caller must
  ///      build a new device;
  ///   2. the frame is from a previous generation - a resize landed, drop it;
  ///   3. the context will not go current - that is device loss arriving now;
  ///   4. the window went away between the draw and the swap;
  ///   5. the swap itself failed.
  @override
  Future<PresentResult> present(Frame frame) async {
    throwIfDisposed();
    final blocked = _device.state.blockedPresent();
    if (blocked != null) return blocked;
    if (frame.generation != generation) return _stale('before it was drawn');

    // Binding a framebuffer through a context that is not current writes into
    // whichever context *is*, which on a shared-GPU machine is another
    // application's. So the result is checked before anything is bound.
    if (!_device.makeCurrentOrLose()) {
      return _device.state.blockedPresent() ??
          const PresentResult(
            status: PresentStatus.deviceLost,
            diagnostic: BackendDiagnostic(
              kind: DiagnosticKind.connectionFailed,
              message: 'the GL context could not be made current to present',
            ),
          );
    }

    // Framebuffer 0 is the window's back buffer for a context created on that
    // window. Bound explicitly and not assumed, because the same device may
    // have rendered an offscreen target into an FBO a moment ago and left it
    // bound - GL's binding is context state, not target state.
    _device.api.bindFramebuffer(glFramebuffer, 0);

    _uploadMaskAtlas();
    _uploadGlyphAtlas();

    final int? clear = _pendingClear;
    _pendingClear = null;
    final vectorStream = _vectorStream;
    final bool drawn;
    if (vectorStream == null) {
      drawn = _device.submit(
        _batcher,
        _surface.pixelWidth,
        _surface.pixelHeight,
        clear,
        layers: _layers,
        // Framebuffer 0 is this target's surface, and submit rebinds it after
        // every layer pass so the swap below finds the back buffer bound.
        firstBatch: _submittedBatches,
      );
    } else {
      vectorStream.finish(totalBatchCount: _batcher.batchCount);
      drawn = _device.submitOrderedPaths(
        _batcher,
        vectorStream,
        _vectorCursor,
        _surface.pixelWidth,
        _surface.pixelHeight,
        clear,
      );
    }
    _submittedBatches = _batcher.batchCount;
    // After the draws and never before: until they are issued, the composite
    // quads are still going to sample those layer textures.
    _layers.endFrame();
    if (!drawn) {
      return _device.state.blockedPresent() ??
          const PresentResult(
            status: PresentStatus.deviceLost,
            diagnostic: BackendDiagnostic(
              kind: DiagnosticKind.connectionFailed,
              message: 'the device was lost while the frame was being drawn',
            ),
          );
    }

    // Checked again, and this is not belt and braces. Everything above yields:
    // the mask upload and the draw are the longest part of a frame, and a
    // resize arriving during them is the common case rather than the exotic
    // one. Swapping now would put a frame drawn for the old viewport into a
    // back buffer the driver has already reallocated.
    if (frame.generation != generation) {
      return _stale('after it was drawn and before the swap');
    }

    if (!_surface.swapChain.isPresentable) {
      return PresentResult(
        status: PresentStatus.failed,
        diagnostic: BackendDiagnostic(
          kind: DiagnosticKind.surfaceCreationFailed,
          message: 'the window is gone, so its back buffer cannot be swapped',
          detail: 'surface: $_surface',
        ),
      );
    }

    if (!_surface.swapChain.swapBuffers()) {
      return PresentResult(
        status: PresentStatus.failed,
        diagnostic: BackendDiagnostic(
          kind: DiagnosticKind.surfaceCreationFailed,
          message: 'the window system refused to swap the back buffer',
          detail: 'surface: $_surface; the frame was drawn and is lost. A '
              'window destroyed between the draw and the swap is the usual '
              'cause',
        ),
      );
    }

    final lost = _device.state.blockedPresent();
    if (lost != null) return lost;
    return const PresentResult(status: PresentStatus.presented);
  }

  /// Reconciles this target with a window that is now [pixelWidth] x
  /// [pixelHeight] physical pixels at [scale].
  ///
  /// Three things happen and the order matters. The generation is bumped
  /// first, so any frame already in flight is rejected even if the swap chain
  /// then fails to reconfigure. The descriptor is replaced second, so the next
  /// `glViewport` is for the new size. The swap chain is told last, because on
  /// WGL it has nothing to do and on EGL it may need to rebuild the surface -
  /// and if it fails, the target is already in a state where every frame is
  /// refused rather than one where frames are drawn at the wrong size.
  ///
  /// A no-op when nothing changed *and* the window has not invalidated itself.
  /// That second condition is why this is not the usual early return: a window
  /// that was resized away and back to the same size still bumped its token,
  /// and skipping the reconcile would leave [needsResize] true forever.
  ///
  /// A reconfigure failure marks the device lost rather than throwing. There
  /// is no useful recovery: a swap chain that cannot be brought to the
  /// window's size will not produce a correct frame, and pretending otherwise
  /// is how a renderer ends up showing a stretched surface.
  @override
  void resize(int pixelWidth, int pixelHeight, double scale) {
    throwIfDisposed();
    if (pixelWidth == _surface.pixelWidth &&
        pixelHeight == _surface.pixelHeight &&
        scale == _surface.scale &&
        !needsResize) {
      return;
    }
    if (pixelWidth <= 0 || pixelHeight <= 0) {
      throw ArgumentError('a window surface must have a positive size, got '
          '${pixelWidth}x$pixelHeight');
    }

    _generation++;
    _surface = _surface.resized(
      pixelWidth: pixelWidth,
      pixelHeight: pixelHeight,
      scale: scale,
    );
    _observedWindowGeneration = _surface.generation.current;

    final failure = _surface.swapChain.reconfigure(
      pixelWidth: pixelWidth,
      pixelHeight: pixelHeight,
    );
    if (failure != null) _device.state.markLost(failure);
  }

  /// Rasterises [list] into the window and presents it.
  ///
  /// Mirrors [GlOffscreenTarget.renderDisplayList] argument for argument, so a
  /// caller - or a test - can swap one target for the other and compare what
  /// happened, which is the only way to check that the windowed path draws the
  /// same geometry as the path the golden tests cover.
  @override
  Future<PresentResult> renderDisplayList(
    DisplayList list, {
    int? clearColor,
    Transform2D deviceTransform = Transform2D.identity,
  }) async {
    final frame = beginFrame(FrameRequest(clearColor: clearColor));
    // One resource table, walked by the player and read by the sink's font
    // resolver, so the two cannot disagree about which face an id names.
    final resources = DisplayListResources(list);
    _fonts.bind(resources);
    _player.play(
      DisplayListReader(list),
      resources,
      deviceBounds: _surfaceRect,
      deviceTransform: deviceTransform,
      // Same seam as `GlOffscreenTarget.renderDisplayList`: the window and a
      // golden test have to make the same decisions, so both hand the player
      // the list's hint table.
      contentHints: list.contentHints,
    );
    return present(frame);
  }

  Rect get _surfaceRect => Rect.fromLTWH(
        0,
        0,
        _surface.pixelWidth.toDouble(),
        _surface.pixelHeight.toDouble(),
      );

  /// One upload for everything the frame's masks wrote, over whole rows.
  void _uploadMaskAtlas() {
    if (!_maskAtlas.isDirty) return;
    final top = _maskAtlas.dirtyTop;
    final height = _maskAtlas.dirtyBottom - top;
    _device.uploadRegion(
      _maskTexture,
      x: 0,
      y: top,
      width: _maskAtlas.width,
      height: height,
      pixels: Uint8List.sublistView(
        _maskAtlas.pixels,
        top * _maskAtlas.width,
      ),
      bytesPerRow: _maskAtlas.width,
    );
    _maskAtlas.markUploaded();
  }

  /// Sends the plots this frame wrote glyphs into, and nothing else.
  ///
  /// One `glTexSubImage2D` per dirty plot, so a window redrawing the same
  /// label sixty times a second uploads nothing at all after the first frame -
  /// which is the entire reason the glyph atlas survives [beginFrame] while
  /// the mask atlas does not.
  ///
  /// Orientation: an atlas is *uploaded*, not rendered into, so `uYFlip` and
  /// its two constants do not apply - they invert the projection of a pass
  /// whose output is sampled later. `glTexSubImage2D` puts the first row it is
  /// given at texture row `y`, and the staging image is top-down, so atlas row
  /// `y` is texture coordinate `y / height`, which is what the sink computes
  /// for the *top* edge of a glyph quad. See `gl_backend.dart`'s copy of this
  /// method for the long form of the argument.
  void _uploadGlyphAtlas() {
    if (!_glyphAtlas.isDirty) return;
    final int width = _glyphAtlas.width;
    _glyphAtlas.forEachDirtyRegion((int x, int y, int regionWidth, int height) {
      _glyphUploadCount++;
      _device.uploadRegion(
        _glyphTexture,
        x: x,
        y: y,
        width: regionWidth,
        height: height,
        pixels: Uint8List.sublistView(_glyphAtlas.pixels, y * width + x),
        bytesPerRow: width,
      );
    });
    _glyphAtlas.markUploaded();
  }

  /// The backend's half of the atlas flush protocol - see
  /// [GpuRasterSink.onAtlasFlush]. Upload first, because the batches about to
  /// be drawn sample texels that so far exist only in the staging image;
  /// submit second, and remember how far it got. Both atlases, because a batch
  /// about to be issued may sample a glyph and a mask this frame wrote.
  void _flushAtlases() {
    _uploadMaskAtlas();
    _uploadGlyphAtlas();
    final int? clear = _pendingClear;
    _pendingClear = null;
    final vectorStream = _vectorStream;
    if (vectorStream == null) {
      _device.submit(
        _batcher,
        _surface.pixelWidth,
        _surface.pixelHeight,
        clear,
        layers: _layers,
        firstBatch: _submittedBatches,
      );
    } else {
      vectorStream.snapshot(totalBatchCount: _batcher.batchCount);
      _device.submitOrderedPaths(
        _batcher,
        vectorStream,
        _vectorCursor,
        _surface.pixelWidth,
        _surface.pixelHeight,
        clear,
      );
    }
    _submittedBatches = _batcher.batchCount;
  }

  PresentResult _stale(String when) => PresentResult(
        status: PresentStatus.stale,
        diagnostic: BackendDiagnostic.note(
          'the frame belonged to a previous generation of the window; it was '
          'dropped $when',
          detail: needsResize
              ? 'the window invalidated itself and resize() has not been '
                  'called with its new size yet, so every frame will be '
                  'dropped until it is'
              : 'the target was resized or the device was lost since the '
                  'frame began',
        ),
      );

  @override
  void onDispose() {
    _device.unregisterTarget(this);
    _images.clear();
    // After endFrame has returned every target: the pool only deletes what is
    // idle, so disposing mid-frame would leak the ones still in flight.
    _layers.endFrame();
    _layerPool.dispose();
    _vector?.dispose();
    _device
      ..releaseTexture(_maskTexture)
      ..releaseTexture(_glyphTexture);
    // The staging bytes go with the texture: an entry that outlived it would
    // say a glyph is resident in a texture the driver has freed.
    _glyphAtlas.clear();
    _fonts.bind(null);
  }
}
