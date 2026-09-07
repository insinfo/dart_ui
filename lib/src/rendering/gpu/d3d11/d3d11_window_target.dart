/// The Direct3D 11 target that puts pixels on a screen.
///
/// [D3d11OffscreenTarget] renders into a texture, copies it to a staging
/// texture and maps it on every present. That is a readback per frame, which
/// section 23 of the roadmap forbids for a production backend ("backend GPU não
/// deve fazer readback por frame"), and it is right: `CopyResource` moves a
/// whole surface, `Map` blocks until the GPU has caught up with it, and the CPU
/// then hands the bytes to somebody else to copy again. What it buys is a
/// [Framebuffer] a golden or parity test can compare, which is worth the cost in
/// a test and nothing at all on a screen.
///
/// This target does the other thing. It binds the render-target view over the
/// swap chain's current back buffer, draws into it, and calls `Present`. The
/// pixels never leave the GPU, and there is deliberately no way to read them
/// back from here.
///
/// ## Three differences from `GlWindowTarget`, and they are all about the
/// back buffer being a resource
///
/// GL's window back buffer is framebuffer 0: a number, fixed for the life of the
/// context, that survives every resize. A DXGI back buffer is an
/// `ID3D11Texture2D` with a view over it, and both are destroyed and recreated
/// by `ResizeBuffers`. Everything below follows from that:
///
///   1. **The view is fetched from the swap chain on every present** rather than
///      cached in a field. A cached pointer that survived a resize would be a
///      dangling one, and `OMSetRenderTargets` does not fault on it - it renders
///      nowhere, silently.
///   2. **[resize] unbinds before it reconfigures.** `ResizeBuffers` refuses
///      with `DXGI_ERROR_INVALID_CALL` while the immediate context still has a
///      back buffer bound, and the context's reference is invisible from Dart.
///      `D3d11RenderDevice.unbindTargets` exists for this one call site.
///   3. **A present returns an `HRESULT`, not a bool.** `DXGI_STATUS_OCCLUDED`
///      is a *success* code that means the frame was thrown away because the
///      window is not visible, and `DXGI_ERROR_DEVICE_REMOVED` means every
///      resource this device ever made is gone. Both are reported by name, and
///      neither is a `failed`.
///
/// ## The generation contract, and why it is checked twice
///
/// Identical to the GL target's, for the identical reason, so the argument is
/// not repeated here - see `gl_window_target.dart`. [generation] folds three
/// counters into one number: this target's own resizes, the device's loss
/// count, and the window's own [GenerationToken] shared through
/// [D3d11WindowSurfaceDescriptor.generation]. [present] compares it against the
/// frame's on entry *and* again immediately before `Present`, because
/// everything in between yields to the event loop and a resize is exactly the
/// thing that arrives while a frame is being drawn.
///
/// ## What this target cannot give a caller
///
/// A windowed GPU target genuinely has no CPU-visible pixels: they are in a
/// swap chain's back buffer. [Frame.framebuffer] used to be non-nullable, so
/// this target carried a 1x1 placeholder that nothing read.
///
/// That placeholder is gone. `Frame` stores the framebuffer nullably and
/// exposes [Frame.cpuPixels] for callers that handle "there are none", keeping
/// [Frame.framebuffer] as a non-null accessor that raises a named failure. This
/// target passes no framebuffer at all.
///
/// ## Absent by name, not by omission
///
/// **DirectComposition is not wired.** This target presents through a swap
/// chain created with `IDXGIFactory2::CreateSwapChainForHwnd`, which is a
/// window's own back buffer. A composed visual would need
/// `DCompositionCreateDevice`, `IDCompositionDevice::CreateTargetForHwnd`,
/// `CreateVisual`, `IDCompositionVisual::SetContent`,
/// `IDCompositionTarget::SetRoot`, `IDCompositionDevice::Commit` and
/// `IDXGIFactory2::CreateSwapChainForComposition` in place of the ForHwnd call.
/// None of them are bound. The consequence, stated rather than discovered: no
/// per-visual transform, and no transparent or non-rectangular window.
///
/// **Device loss is recovered from, except for the swap chain.** The device,
/// the mask atlas this target still owns and the glyph atlas the device shares
/// between its targets all come back - see `gpu_recovery.dart` for the eight
/// steps, [recoverableResources] for what is left in this target's own
/// inventory, and [D3d11RenderDevice.recoverableResources] for why the shared
/// half has to be rebuilt before any target's sink reads a texture id. The swap
/// chain does not, and that is a boundary rather than an omission: a chain
/// belongs to the device that created it, and the chain here was created by the
/// platform code that owns the window
/// (`lib/src/backends/win32/d3d11/win32_d3d11_surface.dart`) and reaches this
/// class as a [D3d11SwapChain] interface with no `recreate` on it. So the
/// recovery names the chain as unrecoverable, and the owner has to rebuild the
/// window surface and its target. Naming it is the point: a half-working
/// re-entry point that presented to a chain belonging to a released device
/// would be the pretended capability section 6.6 forbids.
library;

import 'dart:async';
import 'dart:ffi';
import 'dart:typed_data';

import '../../../ffi/com.dart';
import '../../../foundation/diagnostics.dart';
import '../../../foundation/lifecycle.dart';
import '../../../geometry/rect.dart';
import '../../../geometry/transform2d.dart';
import '../../../graphics/display_list.dart';
import '../../../graphics/display_list_reader.dart';
import '../../framebuffer.dart';
import '../../renderer.dart';
import '../../replay/display_list_player.dart';
import '../gpu_batcher.dart';
import '../gpu_glyph_atlas.dart';
import '../gpu_layer_stack.dart';
import '../gpu_mask_atlas.dart';
import '../gpu_path_planning.dart';
import '../gpu_raster_sink.dart';
import '../gpu_recovery.dart';
import '../gpu_texture.dart';
import '../gpu_vector_command_stream.dart';
import '../gpu_vector_submission_cursor.dart';
import 'd3d11_backend.dart';
import 'd3d11_surface_descriptor.dart';
import 'd3d11_vector_replay.dart';

/// A render target backed by a swap chain's back buffer.
final class D3d11WindowTarget
    with DisposableMixin
    implements DisplayListRenderTarget, D3d11RecoverableTarget {
  /// Wraps [surface] for [device].
  ///
  /// Public - unlike [D3d11OffscreenTarget]'s constructor, which is also public,
  /// and unlike `GlOffscreenTarget`'s, which is not - because this class is in a
  /// different library from the device that builds it. `createTarget` is still
  /// the way to get one; handing this a device that did not create
  /// [D3d11WindowSurfaceDescriptor.swapChain] is a caller error this class
  /// cannot detect, because a swap chain is an interface here on purpose.
  ///
  /// Takes no ownership of the window, of the [D3d11SwapChain], or of the
  /// caches the device shares between its targets. Disposing this target
  /// releases its own mask texture and its layer pool and nothing else: the
  /// window outlives its targets, which is the split `renderer.dart` describes
  /// between a target and the surface it draws into, and the glyph atlas
  /// outlives them too, which is what makes a popup cheap.
  D3d11WindowTarget(this._device, D3d11WindowSurfaceDescriptor surface)
      : _surface = surface,
        _observedWindowGeneration = surface.generation.current {
    _buildAtlasObjects();
    _device.registerTarget(this);
  }

  /// Creates the mask texture and everything downstream of its id.
  ///
  /// Shared by the constructor and by [_repopulateAtlasObjects]: the sink holds
  /// the two texture ids as final fields, so a recovery has to rebuild the sink
  /// rather than the textures alone. That is still true now that the glyph
  /// texture belongs to the device - the id reaches the sink the same way, so a
  /// device that rebuilt the shared texture must reach every target's
  /// repopulate, and [D3d11RenderDevice.recoverableResources] orders itself so
  /// that the id read here is the new one.
  void _buildAtlasObjects() {
    _maskTexture = _device.createTexture(
      width: _maskAtlas.width,
      height: _maskAtlas.height,
      format: GpuTextureFormat.alpha8,
      // One texel per pixel by construction, so point sampling reproduces the
      // CPU rasteriser's coverage byte exactly and linear would blur it.
      filter: GpuTextureFilter.nearest,
    );
    // Text is wired here exactly as it is on the offscreen target, and that
    // symmetry is the point: a window is where text is actually read, so a
    // backend whose *test* target drew glyphs and whose *window* target refused
    // them would pass every golden test and show a blank panel on screen. The
    // atlas, its texture and the resolvers now come from the device, so the two
    // targets are not merely wired alike - they are wired to the same objects,
    // and a menu drawn over a window finds its glyphs already rasterised.
    _layerPool = D3d11LayerPool(_device);
    _layers = GpuLayerStack(
      allocator: _layerPool,
      backendName: D3d11RendererBackend.backendName,
      // Built identically to the offscreen target's, which is the whole point
      // of `d3d11LayerAttachmentsFor` being a function rather than a literal in
      // two files: a window that allocated its layers differently from the test
      // target would promote draws no golden test had ever exercised.
      layerAttachmentPolicy: (int width, int height) =>
          d3d11LayerAttachmentsFor(
        width: width,
        height: height,
        stencilCoverEnabled: _device.experimentalStencilCoverEnabled,
      ),
    );
    final D3d11VectorReplay? vector = D3d11VectorReplay.create(
      layers: _layers,
      stencilEnabled: _device.experimentalStencilCoverEnabled,
      tessellationEnabled: _device.experimentalCpuTessellationEnabled,
    );
    _vector = vector;
    _vectorStream = vector?.stream;
    _sink = GpuRasterSink(
      batcher: _batcher,
      backendName: D3d11RendererBackend.backendName,
      maskAtlas: _maskAtlas,
      maskTextureId: _maskTexture.id,
      imageResolver: _device.imageCache,
      glyphAtlas: _device.glyphAtlas,
      glyphTextureId: _device.glyphTextureId,
      fontResolver: _device.fontResolver,
      layerStack: _layers,
      onAtlasFlush: _flushAtlases,
      pathPlanningTelemetry: vector?.telemetry,
      pathCommandRecorder: vector?.recorder,
      // Refreshed in `beginFrame` as well; set here so a window created after
      // the device's switch was flipped does not draw its first frame the old
      // way. The offscreen target does the same, and it has to be the same in
      // both files: a window that drew rounded rectangles through a different
      // rasteriser than the target the golden tests use would be a difference
      // no test in this repository could see.
      analyticPrimitives: _device.analyticPrimitivesEnabled,
    );
    _player = DisplayListPlayer(_sink);
  }

  /// The ordered vector wiring, or null on a device with neither promoted
  /// route - which is every device a default `RenderPolicy` opens.
  D3d11VectorReplay? _vector;
  GpuVectorCommandStream<ReplayPaint, D3d11VectorPathPayload>? _vectorStream;
  final GpuVectorSubmissionCursor _vectorCursor = GpuVectorSubmissionCursor();

  /// The strategy decisions this target's sink observed, or null.
  GpuPathPlanningTelemetry? get pathPlanning => _vector?.telemetry;

  final D3d11RenderDevice _device;
  final GpuBatcher _batcher = GpuBatcher();

  /// The one cache that stayed per target, and deliberately.
  ///
  /// The glyph atlas, the font resolver and the image cache went up to the
  /// device because they are caches of stable things: a rasterised glyph, a
  /// face for an id, an uploaded image. The mask atlas is not. Its `beginFrame`
  /// repacks whenever the waste crosses a threshold and it evicts, so two
  /// windows sharing one would move each other's live slots at whatever
  /// interleaving their frame loops produced. The failure - a shape drawn from
  /// a slot its neighbour has since taken - is intermittent, invisible to a
  /// headless test, and gets blamed on the geometry. Sharing it needs its own
  /// evidence, which this change did not set out to gather.
  final GpuMaskAtlas _maskAtlas = GpuMaskAtlas();

  // Not final: a device loss destroys all five and a recovery rebuilds them.
  late D3d11Texture _maskTexture;
  late D3d11LayerPool _layerPool;
  late GpuLayerStack _layers;
  late GpuRasterSink _sink;
  late DisplayListPlayer _player;

  /// Whether this target has opened a frame against the device's shared glyph
  /// atlas and not yet closed it. See [D3d11RenderDevice.beginSharedFrame] for
  /// what the device does with the count and why an unclosed frame is not just
  /// untidy.
  bool _sharedFrameOpen = false;

  // -------------------------------------------------------------------
  // Device-loss recovery
  // -------------------------------------------------------------------

  /// Step 5's inventory for what this target still owns alone.
  ///
  /// The glyph atlas and the uploaded images used to be here and are not any
  /// more: they belong to the device, which yields them once for itself before
  /// it reaches any target, so a two-window application rebuilds them once
  /// rather than twice and the recovery report stops double-counting them. See
  /// [D3d11RenderDevice.recoverableResources] for why that order is not merely
  /// tidy.
  ///
  /// The last entry is the interesting one and it always answers
  /// [GpuResourceRecovery.orphaned]: an `IDXGISwapChain1` belongs to the device
  /// that created it, and the one here was created by the platform code that
  /// owns the window. This class holds it as a [D3d11SwapChain] interface with
  /// no `recreate` on it, so it cannot honestly claim to rebuild one. Naming it
  /// makes the recovery report say `recoveredWithLosses` and tell the owner
  /// exactly what it has to do - rebuild the window surface and its target -
  /// instead of leaving a device that draws into a chain the driver released.
  @override
  Iterable<GpuRecoverableResource> recoverableResources() sync* {
    yield CallbackGpuResource.fixed(
      resourceName: 'direct3d11 window mask atlas '
          '(${_maskAtlas.width}x${_maskAtlas.height})',
      recovery: GpuResourceRecovery.rebuilt,
      onDiscard: _discardAtlasObjects,
      onRepopulate: _repopulateAtlasObjects,
    );
    yield CallbackGpuResource.fixed(
      resourceName: 'direct3d11 window swap chain '
          '(${_surface.pixelWidth}x${_surface.pixelHeight}, '
          '${_surface.kind})',
      recovery: GpuResourceRecovery.orphaned,
      onDiscard: () {},
      onRepopulate: () => const BackendDiagnostic(
        kind: DiagnosticKind.surfaceCreationFailed,
        message: 'a swap chain cannot be recreated from the renderer',
        detail: 'it belongs to the device that made it and to the window it '
            'presents to; rebuild it through '
            'lib/src/backends/win32/d3d11/win32_d3d11_surface.dart and create '
            'a new target for the new descriptor',
      ),
    );
  }

  void _discardAtlasObjects() {
    // The frame in flight goes with the device.
    _batcher.beginFrame();
    _submittedBatches = 0;
    _pendingClear = null;
    _closeSharedFrame();
    _layers.endFrame();
    _layerPool.dispose();
    // Rebuilt whole by `_buildAtlasObjects`, so its CPU caches go with it: a
    // retained tessellation left behind would be a mesh nothing can reach.
    _vector?.dispose();
    _vector = null;
    _vectorStream = null;
    _vectorCursor.reset();
    _device.releaseTexture(_maskTexture);
    // The mask atlas is a cache that outlives a frame, so it has to be told
    // its texels are gone, and it is the one that is easy to miss: its
    // `beginFrame` deliberately *keeps* every cached mask, so a static rounded
    // rectangle drawn before the loss would be found resident, re-batched
    // against a texture that was never re-uploaded, and drawn as nothing at
    // all - a frame that differs from the pre-loss one by exactly the shapes
    // the cache was working for. The glyph atlas needs the identical treatment
    // and now gets it once, on the device, instead of once per target.
    _maskAtlas.recycle();
  }

  BackendDiagnostic? _repopulateAtlasObjects() {
    try {
      _buildAtlasObjects();
    } on Object catch (error) {
      return BackendDiagnostic(
        kind: DiagnosticKind.incompatibleDevice,
        message: 'the recreated Direct3D 11 device refused an atlas texture',
        detail: '$error',
      );
    }
    return null;
  }

  /// How many batches of the current frame have already been drawn. See
  /// [GpuRasterSink.onAtlasFlush]: a batch drawn twice blends twice.
  int _submittedBatches = 0;

  D3d11WindowSurfaceDescriptor _surface;
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
  /// A window that resizes without anybody calling [resize] - the normal case,
  /// because the resize event and the frame loop are different code paths -
  /// invalidates the token. Frames are then rejected until the owner calls
  /// [resize] with the new size, which is the right behaviour: this class must
  /// not guess the new size and has no way to ask the window.
  int _observedWindowGeneration;

  /// The raw `HRESULT` the last `Present` returned, or `S_OK` before the first.
  ///
  /// Exposed because the interesting outcomes of a present are *success* codes
  /// that mean different things - `DXGI_STATUS_OCCLUDED` above all - and a
  /// caller or a test that only sees [PresentStatus] cannot tell them apart.
  int get lastPresentHresult => _lastPresentHresult;
  int _lastPresentHresult = sOk;

  /// The textures uploaded for drawn images. The device's, shared with every
  /// other target on it; kept here as a getter because a caller asking a target
  /// what it drew with should not have to know where the cache lives.
  D3d11ImageCache get images => _device.imageCache;

  /// Where layers get their offscreen targets. Exposed for a memory report and
  /// for a test that asserts the same layer drawn on ten frames created one
  /// target; reuse is invisible from the pixels and very visible in frame time.
  D3d11LayerPool get layerPool => _layerPool;

  /// The coverage this target packs its own path masks into.
  ///
  /// Exposed so a test can assert that two targets on one device do *not* share
  /// it. That is not a detail: the mask atlas repacks and evicts, and the whole
  /// argument for leaving it here rather than on the device is in the field's
  /// own comment.
  GpuMaskAtlas get maskAtlas => _maskAtlas;

  /// The device's font resolver, which every target on it binds in turn.
  D3d11FontResolver get fontResolver => _device.fontResolver;

  /// The glyph coverage the device keeps between frames, for every target on
  /// it. A menu's label is already in here when the window behind it drew the
  /// same face at the same size, which is the claim section 3.7 of
  /// `doc/PLANO_POPUPS_EM_JANELAS_NATIVAS.md` makes.
  GpuGlyphAtlas get glyphAtlas => _device.glyphAtlas;

  /// `UpdateSubresource` calls made for glyph coverage, across every target on
  /// the device. A frame that redraws the same text must not increase it, and
  /// neither must a second window drawing text the first one already drew.
  int get glyphUploadCount => _device.glyphUploadCount;

  GpuBatcher get batcher => _batcher;

  /// How the back buffer reaches the screen. Exposed so an owner can set the
  /// sync interval without holding the platform object separately.
  D3d11SwapChain get swapChain => _surface.swapChain;

  @override
  D3d11WindowSurfaceDescriptor get surface => _surface;

  @override
  int get generation {
    final int losses = _device.state.lossCount;
    if (losses != _observedLossCount) {
      _observedLossCount = losses;
      _generation++;
    }
    return _generation + _surface.generation.current;
  }

  /// Whether the window has been invalidated since this target last agreed with
  /// it.
  ///
  /// True means every frame will be rejected until [resize] is called with the
  /// window's current size. Exposed so an owner can distinguish "my frames are
  /// dropped because I have not reconciled the resize" from "my frames are
  /// dropped because the device is gone", which produce the same
  /// [PresentStatus] and have completely different fixes.
  bool get needsResize =>
      _surface.generation.current != _observedWindowGeneration;

  @override
  Frame beginFrame(FrameRequest request) {
    throwIfDisposed();
    _batcher.beginFrame();
    _maskAtlas.beginFrame();
    // Per frame, from the device, for the reason `D3d11OffscreenTarget`'s
    // `beginFrame` gives: the flag belongs to the device and a caller may flip
    // it between two frames of one target.
    _sink.analyticPrimitives = _device.analyticPrimitivesEnabled;
    // Keeps every glyph and advances the counter its LRU compares against; a
    // target that forgot it would leave every plot pinned to the frame in
    // progress and report the atlas permanently full. It goes through the
    // device now because the atlas is shared, and the device is the only place
    // that can tell whether another target still has a frame open against it.
    _openSharedFrame();
    _layers.beginFrame(
      surfaceWidth: _surface.pixelWidth,
      surfaceHeight: _surface.pixelHeight,
    );
    _vector?.beginFrame();
    _vectorCursor.reset();
    _submittedBatches = 0;
    _pendingClear = request.clearColor;
    return Frame(
      target: this,
      // No framebuffer, and that is the truth rather than an omission: the
      // pixels are in the swap chain's back buffer. See the library comment.
      damage: request.damage ?? _surfaceRect,
      generation: generation,
    );
  }

  /// Draws the recorded batches into the back buffer and presents it.
  ///
  /// Never maps a resource. The failure modes, in the order they are checked,
  /// each producing a named [PresentResult] rather than a throw:
  ///
  ///   1. the device is already lost - retrying is pointless, the caller must
  ///      build a new device;
  ///   2. the frame is from a previous generation - a resize landed, drop it;
  ///   3. the window went away, so there is nothing to present to;
  ///   4. the swap chain has no back-buffer view, which is what a failed
  ///      `ResizeBuffers` leaves behind;
  ///   5. the device was lost while the frame was being drawn;
  ///   6. `Present` itself refused.
  ///
  /// All six exit through [_present] so that the one thing that must happen on
  /// every path - closing this target's frame against the device's shared glyph
  /// atlas - happens in a `finally` rather than six times. A target that took
  /// an early return and left its frame open would hold the atlas at one frame
  /// index for the life of the device, which pins every plot and makes a
  /// long-running window report the atlas permanently full.
  @override
  Future<PresentResult> present(Frame frame) async {
    try {
      return await _present(frame);
    } finally {
      _closeSharedFrame();
    }
  }

  Future<PresentResult> _present(Frame frame) async {
    throwIfDisposed();
    final PresentResult? blocked = _device.state.blockedPresent();
    if (blocked != null) return blocked;
    if (frame.generation != generation) return _stale('before it was drawn');

    if (!_surface.swapChain.isPresentable) {
      return PresentResult(
        status: PresentStatus.failed,
        diagnostic: BackendDiagnostic(
          kind: DiagnosticKind.surfaceCreationFailed,
          message: 'the window is gone, so its back buffer cannot be presented',
          detail: 'surface: $_surface',
        ),
      );
    }

    final Pointer<Void> view = _surface.swapChain.backBufferView;
    if (view == nullptr) {
      // Not a crash and not a silent no-op: OMSetRenderTargets accepts a null
      // view and renders nowhere, so a frame drawn against one would look
      // exactly like a frame the compositor lost.
      return PresentResult(
        status: PresentStatus.failed,
        diagnostic: BackendDiagnostic(
          kind: DiagnosticKind.surfaceCreationFailed,
          message: 'the swap chain has no back-buffer view to draw into',
          detail: 'surface: $_surface; a ResizeBuffers that failed leaves the '
              'chain in exactly this state, so the previous resize diagnostic '
              'is the one worth reading',
        ),
      );
    }

    _uploadMaskAtlas();
    _device.uploadGlyphAtlas();

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
        view,
        layers: _layers,
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
        view,
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
    // the atlas uploads and the draws are the longest part of a frame, and a
    // resize arriving during them is the common case rather than the exotic
    // one. Presenting now would show a frame drawn for a viewport that no
    // longer exists, into a buffer the driver has already reallocated.
    if (frame.generation != generation) {
      return _stale('after it was drawn and before the present');
    }

    final int hr = hresult(_surface.swapChain.present());
    _lastPresentHresult = hr;
    if (failed(hr)) {
      // A present is where device removal is normally noticed, because it is
      // the call that actually waits on the GPU. checkDeviceRemoved asks
      // GetDeviceRemovedReason rather than trusting this code, since a removed
      // device fails every subsequent call with a code about *that* call.
      if (_device.checkDeviceRemoved('presenting the swap chain') ||
          hr == dxgiErrorDeviceRemoved ||
          hr == dxgiErrorDeviceReset) {
        return _device.state.blockedPresent() ??
            PresentResult(
              status: PresentStatus.deviceLost,
              diagnostic: BackendDiagnostic(
                kind: DiagnosticKind.connectionFailed,
                message: 'the device was removed during Present',
                detail: hresultName(hr),
              ),
            );
      }
      return PresentResult(
        status: PresentStatus.failed,
        diagnostic: BackendDiagnostic(
          kind: DiagnosticKind.surfaceCreationFailed,
          message: 'the swap chain refused to present the back buffer',
          detail: '${hresultName(hr)}; surface: $_surface. The frame was drawn '
              'and is lost. A window destroyed between the draw and the '
              'present is the usual cause',
        ),
      );
    }

    final PresentResult? lost = _device.state.blockedPresent();
    if (lost != null) return lost;
    if (hr == dxgiStatusOccluded) {
      // A success code, and reported as one: the frame was accepted and thrown
      // away because nothing can see the window. Calling it `failed` would make
      // a minimised application look like a broken renderer; saying nothing at
      // all would hide the reason a frame rate collapses to nothing while the
      // window is behind another one.
      return const PresentResult(
        status: PresentStatus.presented,
        diagnostic: BackendDiagnostic.note(
          'the window is occluded, so the presented frame was discarded',
          detail: 'DXGI_STATUS_OCCLUDED (0x087a0002) is a success code. A '
              'caller pacing frames should back off until a present returns '
              'S_OK again rather than spinning on an invisible window',
        ),
      );
    }
    return const PresentResult(status: PresentStatus.presented);
  }

  /// Reconciles this target with a window that is now [pixelWidth] x
  /// [pixelHeight] physical pixels at [scale].
  ///
  /// Four things happen and the order is the whole content of this method:
  ///
  ///   1. the generation is bumped, so any frame already in flight is rejected
  ///      even if everything below then fails;
  ///   2. the descriptor is replaced, so the next viewport is the new size;
  ///   3. **the device unbinds every render target and shader resource**,
  ///      because the immediate context holds a reference to whatever is bound
  ///      and `ResizeBuffers` refuses with `DXGI_ERROR_INVALID_CALL` while any
  ///      reference to any back buffer is outstanding. This is the step a D3D11
  ///      backend forgets, and forgetting it does not crash - the resize simply
  ///      returns an error and every frame afterwards is the wrong size;
  ///   4. the swap chain resizes, which releases its own view and texture and
  ///      then calls `ResizeBuffers`.
  ///
  /// A no-op when nothing changed *and* the window has not invalidated itself.
  /// That second condition is why this is not the usual early return: a window
  /// resized away and back to the same size still bumped its token, and
  /// skipping the reconcile would leave [needsResize] true forever.
  ///
  /// A reconfigure failure marks the device lost rather than throwing. There is
  /// no useful recovery: a swap chain that cannot be brought to the window's
  /// size will not produce a correct frame, and pretending otherwise is how a
  /// renderer ends up showing a stretched surface.
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

    _device.unbindTargets();
    final BackendDiagnostic? failure = _surface.swapChain.reconfigure(
      pixelWidth: pixelWidth,
      pixelHeight: pixelHeight,
    );
    if (failure != null) _device.state.markLost(failure);
  }

  /// Rasterises [list] into the window and presents it.
  ///
  /// Mirrors [D3d11OffscreenTarget.renderDisplayList] argument for argument, so
  /// a caller - or a test - can swap one target for the other and compare what
  /// happened, which is the only way to check that the windowed path draws the
  /// same geometry as the path the parity tests cover.
  @override
  Future<PresentResult> renderDisplayList(
    DisplayList list, {
    int? clearColor,
    Transform2D deviceTransform = Transform2D.identity,
  }) async {
    final Frame frame = beginFrame(FrameRequest(clearColor: clearColor));
    // One resource table, walked by the player and read by the sink's font
    // resolver, so the two cannot disagree about which face an id names.
    final resources = DisplayListResources(list);
    _device.fontResolver.bind(resources);
    _player.play(
      DisplayListReader(list),
      resources,
      deviceBounds: _surfaceRect,
      deviceTransform: deviceTransform,
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
    final int top = _maskAtlas.dirtyTop;
    final int height = _maskAtlas.dirtyBottom - top;
    _device.uploadRegion(
      _maskTexture,
      x: 0,
      y: top,
      width: _maskAtlas.width,
      height: height,
      pixels: Uint8List.sublistView(_maskAtlas.pixels, top * _maskAtlas.width),
      bytesPerRow: _maskAtlas.width,
    );
    _maskAtlas.markUploaded();
  }

  /// Opens a frame against the device's shared glyph atlas, once per frame even
  /// if [beginFrame] is called twice without an intervening present.
  void _openSharedFrame() {
    if (_sharedFrameOpen) return;
    _sharedFrameOpen = true;
    _device.beginSharedFrame();
  }

  void _closeSharedFrame() {
    if (!_sharedFrameOpen) return;
    _sharedFrameOpen = false;
    _device.endSharedFrame();
  }

  /// The backend's half of the atlas flush protocol - see
  /// [GpuRasterSink.onAtlasFlush]. Upload first, because the batches about to be
  /// drawn sample texels that so far exist only in the staging image; submit
  /// second, and remember how far it got.
  ///
  /// The glyph half of the flush is the device's, and one caveat comes with
  /// that. When this path runs because the atlas was *full*, the sink calls
  /// `recycleAll` on it once this returns, which now frees plots another
  /// target's unsubmitted frame may be about to sample. A device that runs two
  /// windows into a full 1024x1024 atlas within one round of frames can
  /// therefore repaint the other window's already-recorded glyphs with the next
  /// tenant. Stated rather than hidden: the fix belongs in the sink's flush
  /// protocol, which is not this backend's file to change.
  void _flushAtlases() {
    _uploadMaskAtlas();
    _device.uploadGlyphAtlas();
    final Pointer<Void> view = _surface.swapChain.backBufferView;
    if (view == nullptr) return;
    final int? clear = _pendingClear;
    _pendingClear = null;
    final vectorStream = _vectorStream;
    if (vectorStream == null) {
      _device.submit(
        _batcher,
        _surface.pixelWidth,
        _surface.pixelHeight,
        clear,
        view,
        layers: _layers,
        firstBatch: _submittedBatches,
      );
    } else {
      // A snapshot rather than `finish`: replay has not ended, and the cursor
      // is what stops a command this prefix issued from being issued again by
      // the present that follows.
      vectorStream.snapshot(totalBatchCount: _batcher.batchCount);
      _device.submitOrderedPaths(
        _batcher,
        vectorStream,
        _vectorCursor,
        _surface.pixelWidth,
        _surface.pixelHeight,
        clear,
        view,
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

  /// Releases what this target owns, and nothing the device owns.
  ///
  /// The glyph atlas, its texture, the font resolver and the image cache are
  /// deliberately left alone. Clearing them here is what closing a popup would
  /// do to the window underneath it: the atlas's entries would go, the texture
  /// they name would be released, and the next frame of a window that never
  /// asked for any of this would re-rasterise every glyph on screen - or, if
  /// the texture went and the entries stayed, draw them as nothing. The device
  /// releases all four in its own dispose, when it is the last one out.
  @override
  void onDispose() {
    _device.unregisterTarget(this);
    _closeSharedFrame();
    // After endFrame has returned every target: the pool only destroys what is
    // idle, so disposing mid-frame would leak the ones still in flight.
    _layers.endFrame();
    _layerPool.dispose();
    _device.releaseTexture(_maskTexture);
  }
}
