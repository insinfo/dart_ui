/// A Direct3D 12 target that presents into a window's swap chain.
///
/// This is the target section 23 of the roadmap is about: the pixels the GPU
/// wrote are handed to the compositor as they are, with no CPU round trip.
/// Nothing here reads a pixel back, and the readback path is deliberately not
/// reachable from this file - it lives in [D3d12OffscreenTarget], whose only
/// consumers are tests and image export.
///
/// ## Two things this file has to get right
///
/// **The back buffer index comes from DXGI, every frame.** Under
/// `DXGI_SWAP_EFFECT_FLIP_DISCARD` the buffer the next frame must be drawn into
/// advances on every present, and `GetCurrentBackBufferIndex` is the only
/// correct source for it. A counter kept alongside it drifts the first time a
/// present is skipped, fails, or the compositor decides otherwise - and the
/// symptom is a frame drawn into the buffer being scanned out, which reads as
/// tearing rather than as a bug in the index.
///
/// **The barriers.** A swap chain buffer is in `PRESENT` state when DXGI hands
/// it over and must be in `PRESENT` again when `Present` is called, and must be
/// in `RENDER_TARGET` in between. Both transitions are recorded here, on the
/// same command list as the draws, and the debug layer is what proves they are
/// right - see `test/backends/win32/d3d12/d3d12_barrier_test.dart`, which
/// enables it and fails on any message of severity ERROR or worse. Getting a
/// barrier wrong does not throw: it produces a picture that is correct on one
/// driver and corrupt on another.
///
/// ## Resizing
///
/// `ResizeBuffers` requires that every reference to every back buffer has been
/// released **and** that the GPU is idle. Both are this file's job and both are
/// done in [resize], in that order. Skipping the wait is the classic silent
/// failure: `ResizeBuffers` returns `E_INVALIDARG` if a reference survives, but
/// if only the *wait* is missing it succeeds and the driver frees memory a
/// command list still in flight is reading.
///
/// [resize] also has to hand `ResizeBuffers` the **same flags and the same
/// buffer count** the swap chain was created with. That is not tidiness: under
/// [PresentMode.mailbox] the chain carries
/// `DXGI_SWAP_CHAIN_FLAG_FRAME_LATENCY_WAITABLE_OBJECT`, and a `ResizeBuffers`
/// that passes `0` instead succeeds, silently un-waitables the chain, and
/// leaves the waitable handle pointing at an event that never signals again -
/// so every frame after the first window resize stalls for the wait's whole
/// timeout. This file passes the flags and the count the last successful
/// creation recorded, which is why it records them.
///
/// ## Presentation pacing: this is where `mailbox` is real
///
/// This class implements [PresentPacer]. Before it did, `PresentMode` had two
/// implementations - `GlSwapChainPresentPacer` and `GdiPresentPacer` - and
/// **both refuse [PresentMode.mailbox] by name**, correctly: a swap *interval*
/// is a count of vertical blanks with no value meaning "replace the queued
/// frame", and one DIB blitted over in place is not a queue. DXGI is the one
/// API in this repository outside Vulkan that can express the mode, and it
/// expresses it in swap chain **creation** rather than in the present call:
///
///   * `DXGI_SWAP_EFFECT_FLIP_DISCARD` - already what this file used;
///   * `BufferCount >= 3` - with two buffers the producer has nothing to draw
///     into while one buffer is on screen and one is queued, so it blocks in
///     `Present` no matter what else is set;
///   * `DXGI_SWAP_CHAIN_FLAG_FRAME_LATENCY_WAITABLE_OBJECT` plus
///     `SetMaximumFrameLatency(1)` and a wait on
///     `GetFrameLatencyWaitableObject` **before recording**;
///   * `Present(1, 0)` - sync interval one, because mailbox does not tear. The
///     mode that presents with `DXGI_PRESENT_ALLOW_TEARING` is
///     [PresentMode.immediate], and confusing the two is the standard way this
///     feature is mis-implemented.
///
/// The wait is at the *start* of the frame and that placement is the whole
/// benefit. **It is not that `Present` stops blocking** - the obvious version
/// of this claim, and measured false: on Direct3D 12 `Present` hands the frame
/// over and returns in a few hundred microseconds in every mode. The throttle
/// on a swap chain with no waitable object surfaces later, inside the frame
/// ring's fence wait, where the producer can neither see it, name it, nor do
/// anything during it. The waitable object moves the same idle time into one
/// named call at the top of the frame, which an application is free to spend
/// on work instead - and bounds it to one frame rather than DXGI's default
/// three.
///
/// `tool/d3d12_mailbox_smoke.dart` measures that move, in a real window on
/// this machine's GPU at 60 Hz, over 240 frames per mode:
///
/// | mode | fps | frame | latency wait | rest of frame | Present |
/// |---|---|---|---|---|---|
/// | fifo | 60.1 | 16.64 ms | 0.00 ms | 16.64 ms | 0.36 ms |
/// | mailbox | 60.1 | 16.63 ms | 15.04 ms | 1.67 ms | 0.43 ms |
/// | immediate | 1267.4 | 0.79 ms | 0.00 ms | 0.79 ms | 0.14 ms |
///
/// Same cadence for fifo and mailbox, because both are tear-free and the panel
/// decides; the stall moved out of the frame and into the wait.
///
/// Neither the flag nor the third buffer can be added to a live swap chain, so
/// [requestPresentMode] **rebuilds** the chain when the mode needs a different
/// one, exactly as [resize] rebuilds its buffers. A rebuild bumps [generation],
/// so a frame recorded against the old chain is refused as stale rather than
/// presented into a freed buffer.
library;

import 'dart:async';
import 'dart:ffi';
import 'dart:typed_data';

import '../../../foundation/diagnostics.dart';
import '../../../foundation/lifecycle.dart';
import '../../../geometry/rect.dart';
import '../../../geometry/transform2d.dart';
import '../../../graphics/display_list.dart';
import '../../../graphics/display_list_reader.dart';
import '../../../rendering/framebuffer.dart';
import '../../../rendering/gpu/d3d12/d3d12_surface_descriptor.dart';
import '../../../rendering/gpu/gpu_batcher.dart';
import '../../../rendering/gpu/gpu_glyph_atlas.dart';
import '../../../rendering/gpu/gpu_mask_atlas.dart';
import '../../../rendering/gpu/gpu_raster_sink.dart';
import '../../../rendering/gpu/gpu_texture.dart';
import '../../../rendering/present_mode.dart';
import '../../../rendering/renderer.dart';
import '../../../rendering/replay/display_list_player.dart';
import 'd3d12_arena.dart';
import 'd3d12_com.dart';
import 'd3d12_device.dart';
import 'd3d12_interfaces.dart';
import 'd3d12_library.dart';
import 'd3d12_structs.dart';

/// `DXGI_MWA_NO_ALT_ENTER`.
const int _dxgiNoAltEnter = 2;

/// How long [D3d12WindowTarget] will wait on the frame-latency object.
///
/// A second, and not `INFINITE`. See `_awaitFrameLatency`: the object stops
/// signalling while the swap chain cannot present - an occluded window is the
/// everyday case - and an infinite wait there deadlocks the thread that would
/// otherwise process the message saying the window is visible again.
const int _frameLatencyTimeoutMs = 1000;

/// A render target backed by a DXGI swap chain over a window.
///
/// [DisplayListRenderTarget] and not merely [RenderTarget], and the difference
/// is the whole point of this class rather than a spelling: a
/// [RenderTargetPresenter] that does not see the narrower interface takes the
/// `beginFrame` / `rasterizeDisplayList` / `present` route instead, and that
/// route rasterises into the [Frame]'s [Framebuffer] - which here is
/// [_placeholder], one shared 1x1 surface. The picture would be dropped into a
/// single pixel nobody reads and the window would present whatever the swap
/// chain last held. Declaring the interface is what routes a frame through
/// [renderDisplayList] and therefore through the GPU.
final class D3d12WindowTarget
    with DisposableMixin
    implements DisplayListRenderTarget, PresentPacer {
  D3d12WindowTarget(this._device, D3d12WindowSurfaceDescriptor surface)
      : _surface = surface {
    _maskAtlas = GpuMaskAtlas();
    _maskTexture = _device.createTexture(
      width: _maskAtlas.width,
      height: _maskAtlas.height,
      format: GpuTextureFormat.alpha8,
      filter: GpuTextureFilter.nearest,
    );
    _glyphAtlas = GpuGlyphAtlas();
    _glyphTexture = _device.createTexture(
      width: _glyphAtlas.width,
      height: _glyphAtlas.height,
      format: GpuTextureFormat.alpha8,
      filter: GpuTextureFilter.nearest,
    );
    _fonts = ReplayFontResolver();
    _images = D3d12ImageCache(_device);
    _sink = GpuRasterSink(
      batcher: _batcher,
      backendName: D3d12RenderDevice.backendName,
      maskAtlas: _maskAtlas,
      maskTextureId: _maskTexture.id,
      imageResolver: _images,
      glyphAtlas: _glyphAtlas,
      glyphTextureId: _glyphTexture.id,
      fontResolver: _fonts,
      onAtlasFlush: _flushAtlases,
    );
    _player = DisplayListPlayer(_sink);
    // Plain, and deliberately so: two buffers and no flags is what this
    // target presented with before it could pace, and wiring a contract in
    // must not change how every existing window presents. An owner that
    // wants mailbox asks for it and finds out whether it got it.
    _createSwapChain(
      flags: 0,
      bufferCount: _surface.bufferCount,
    );
  }

  /// A [Frame] must carry a [Framebuffer] and a windowed GPU target has none
  /// to give: its pixels live in a back buffer the CPU never maps. One 1x1
  /// surface is shared by every windowed target in the process, because
  /// allocating one per target would suggest it meant something.
  static final Framebuffer _placeholder = Framebuffer.allocate(
    width: 1,
    height: 1,
    format: PixelFormat.rgba8888Premultiplied,
  );

  final D3d12RenderDevice _device;
  final GpuBatcher _batcher = GpuBatcher();

  late final GpuMaskAtlas _maskAtlas;
  late final D3d12Texture _maskTexture;
  late final GpuGlyphAtlas _glyphAtlas;
  late final D3d12Texture _glyphTexture;
  late final ReplayFontResolver _fonts;
  late final D3d12ImageCache _images;
  late final GpuRasterSink _sink;
  late final DisplayListPlayer _player;

  D3d12WindowSurfaceDescriptor _surface;
  DxgiSwapChain3? _swapChain;
  final List<Pointer<Void>> _backBuffers = <Pointer<Void>>[];
  final List<int> _backBufferViews = <int>[];
  int _backBufferIndex = 0;
  int _generation = 0;
  int _observedLossCount = 0;
  int _submittedBatches = 0;
  int? _pendingClear;
  bool _recording = false;
  BackendDiagnostic? _creationFailure;

  /// The `DXGI_SWAP_CHAIN_FLAG` bits the live chain was created with.
  ///
  /// Recorded rather than recomputed because [resize] has to pass the *same*
  /// value to `ResizeBuffers`; see the library comment for what dropping it
  /// does.
  int _swapChainFlags = 0;

  /// Back buffers the live chain was created with.
  ///
  /// Not [D3d12WindowSurfaceDescriptor.bufferCount]: [PresentMode.mailbox]
  /// needs at least three and the descriptor's default is two, so once mailbox
  /// is in force the descriptor no longer describes the chain. `ResizeBuffers`
  /// is given this one, for the same reason it is given [_swapChainFlags].
  int _bufferCount = 0;

  /// The `HANDLE` from `GetFrameLatencyWaitableObject`, or 0.
  ///
  /// Non-zero exactly when [PresentMode.mailbox] is in force. It is an OS
  /// handle this object owns and it is closed in [_destroySwapChain] and so in
  /// [onDispose]; leaking it leaks a kernel object per swap chain rebuild,
  /// which is once per mode change.
  int _frameLatencyWaitable = 0;

  /// Why the last [PresentMode.mailbox] request could not be honoured.
  ///
  /// Kept so [supportedPresentModes] stops offering a mode this machine has
  /// already refused instead of promising it again on every call. A refusal
  /// that is not remembered is a refusal the caller has to rediscover.
  BackendDiagnostic? _mailboxRefusal;

  /// Vertical blanks between presents. 1 by default, which is what a UI that
  /// renders on demand wants; a caller chasing a frame-time number sets 0.
  ///
  /// The low-level escape hatch [PresentPacer] is the polite door to;
  /// `tool/render_throughput_bench.dart` sets it directly. [presentMode] is
  /// *derived* from it rather than tracked beside it, so a caller that writes
  /// here is never contradicted by a mode field that did not notice.
  int syncInterval = 1;

  /// Microseconds spent inside `Present` on the last frame.
  ///
  /// An observable rather than a statistic, and it exists for the reason
  /// [backBufferIndex] does: the claim mailbox makes - that the producer does
  /// not block at the end of the frame - cannot be checked from outside
  /// without it. Under [PresentMode.fifo] this is a refresh interval; under
  /// [PresentMode.mailbox] it is microseconds, and that difference is the
  /// evidence that the waitable object reached the driver.
  int presentMicroseconds = 0;

  /// Microseconds spent in the frame-latency wait at the start of the last
  /// frame. Zero whenever [PresentMode.mailbox] is not in force, because then
  /// there is nothing to wait on.
  int frameLatencyWaitMicroseconds = 0;

  @override
  NativeSurfaceDescriptor get surface => _surface;

  /// The device this target presents through.
  ///
  /// Exposed for `d3d12_mesh_pipeline.dart`; see the same getter on
  /// [D3d12OffscreenTarget] for why a mesh pipeline must be built on *this*
  /// device and not a second one.
  D3d12RenderDevice get device => _device;

  /// The render-target-view handle of the buffer the frame in progress draws
  /// into, or 0 when there is no swap chain.
  ///
  /// Refetched from [_backBufferViews] on every read rather than cached by the
  /// caller, which is the trap `tool/mesh_gpu_window_probe.dart` documents:
  /// the views are destroyed and recreated by every resize, and a renderer
  /// holding an old one draws into a freed buffer.
  int get currentRenderTargetView =>
      _backBufferViews.isEmpty ? 0 : _backBufferViews[_backBufferIndex];

  /// The swap chain buffer the frame in progress draws into, or `nullptr`.
  ///
  /// A caller that records draws into this buffer outside [present] has to
  /// move it `PRESENT` -> `RENDER_TARGET` and back itself, because [present]
  /// records exactly that pair and a barrier whose `before` state does not
  /// match is undefined behaviour the debug layer reports as an error.
  Pointer<Void> get currentBackBuffer =>
      _backBuffers.isEmpty ? nullptr : _backBuffers[_backBufferIndex];

  /// Which swap chain buffer the frame in progress is drawn into.
  ///
  /// Exposed because it is the observable that says the flip model is working:
  /// it must advance on every present and wrap at
  /// [D3d12WindowSurfaceDescriptor.bufferCount].
  int get backBufferIndex => _backBufferIndex;

  int get bufferCount => _backBuffers.length;

  /// The `DXGI_SWAP_CHAIN_FLAG` bits in force, for a bug report to quote.
  int get swapChainFlags => _swapChainFlags;

  /// Whether the swap chain was created with a frame-latency waitable object.
  ///
  /// The one observable that separates "mailbox was asked for" from "mailbox
  /// is running": the handle exists only because DXGI accepted the flag.
  bool get hasFrameLatencyWaitableObject => _frameLatencyWaitable != 0;

  /// Why [PresentMode.mailbox] was refused here, or null if it never was.
  BackendDiagnostic? get mailboxRefusal => _mailboxRefusal;

  /// Null when the swap chain was created; otherwise names what refused.
  BackendDiagnostic? get creationFailure => _creationFailure;

  bool get isPresentable => _swapChain != null && !_device.isLost;

  @override
  int get generation {
    final int losses = _device.state.lossCount;
    if (losses != _observedLossCount) {
      _observedLossCount = losses;
      _generation++;
    }
    return _generation;
  }

  @override
  Frame beginFrame(FrameRequest request) {
    throwIfDisposed();
    // Before anything is recorded, and before the back buffer index is even
    // read. Under mailbox this is the block that paces the producer, and the
    // reason it is here rather than after the present is that a wait at the
    // end of the frame is serial with the frame's own work - which is exactly
    // what a swap chain without a waitable object already does inside
    // `Present`, and exactly what this mode exists to stop doing.
    _awaitFrameLatency();
    final DxgiSwapChain3? chain = _swapChain;
    if (chain != null) _backBufferIndex = chain.currentBackBufferIndex;
    _recording = chain != null && _device.frames.begin() != null;
    _batcher.beginFrame();
    _maskAtlas.beginFrame();
    _glyphAtlas.beginFrame();
    _submittedBatches = 0;
    _pendingClear = request.clearColor;
    return Frame(
      target: this,
      framebuffer: _placeholder,
      damage: request.damage ??
          Rect.fromLTWH(
            0,
            0,
            _surface.pixelWidth.toDouble(),
            _surface.pixelHeight.toDouble(),
          ),
      generation: generation,
    );
  }

  @override
  Future<PresentResult> present(Frame frame) async {
    throwIfDisposed();
    final PresentResult? blocked = _device.state.blockedPresent();
    if (blocked != null) {
      _abandon();
      return blocked;
    }
    final DxgiSwapChain3? chain = _swapChain;
    if (chain == null || !_recording) {
      _abandon();
      return PresentResult(
        status: PresentStatus.failed,
        diagnostic: _creationFailure ??
            const BackendDiagnostic(
              kind: DiagnosticKind.surfaceCreationFailed,
              message: 'this window target has no swap chain to present to',
            ),
      );
    }
    if (frame.generation != generation) {
      _abandon();
      return const PresentResult(
        status: PresentStatus.stale,
        diagnostic: BackendDiagnostic.note(
          'frame belonged to a previous generation of the target',
        ),
      );
    }

    final Pointer<Void> buffer = _backBuffers[_backBufferIndex];
    // PRESENT to RENDER_TARGET. DXGI hands the buffer over in PRESENT and
    // takes it back in PRESENT; everything in between is this backend's
    // responsibility and nothing checks it but the debug layer.
    _device.transitionResource(
      buffer,
      d3d12ResourceStatePresent,
      d3d12ResourceStateRenderTarget,
    );

    _uploadMaskAtlas();
    _uploadGlyphAtlas();

    final int? clear = _pendingClear;
    _pendingClear = null;
    _device.submit(
      _batcher,
      _surface.pixelWidth,
      _surface.pixelHeight,
      clear,
      renderTargetView: _backBufferViews[_backBufferIndex],
      firstBatch: _submittedBatches,
    );
    _submittedBatches = _batcher.batchCount;

    _device.transitionResource(
      buffer,
      d3d12ResourceStateRenderTarget,
      d3d12ResourceStatePresent,
    );

    _recording = false;
    // No wait: the whole point of the frame ring is that the CPU walks on
    // while the GPU consumes this list, and the next frame's `begin` is where
    // the fence is honoured.
    if (!_device.frames.end()) {
      _device.markLost('the frame command list could not be executed');
      return _device.state.blockedPresent()!;
    }

    // Timed, not merely called. `presentMicroseconds` is how anything outside
    // this file can tell a mailbox swap chain from a fifo one: the flag, the
    // third buffer and `SetMaximumFrameLatency` are all invisible from the
    // outside, and their whole observable effect is that this call stops
    // blocking.
    final Stopwatch presenting = Stopwatch()..start();
    final int hr = chain.present(syncInterval, 0);
    presenting.stop();
    presentMicroseconds = presenting.elapsedMicroseconds;
    if (comFailed(hr)) {
      _device.markLost('Present failed', detail: hresultText(hr));
      return _device.state.blockedPresent()!;
    }
    return const PresentResult(status: PresentStatus.presented);
  }

  /// Blocks until the swap chain will accept another frame, under
  /// [PresentMode.mailbox] only.
  ///
  /// The timeout is deliberate and is not `INFINITE`. A waitable object stops
  /// signalling when the swap chain is in a state DXGI will not present from -
  /// a fully occluded window is the everyday one, a device removal the loud
  /// one - and an infinite wait there hangs the thread that owns the window,
  /// which is the thread that would otherwise process the message telling it
  /// the window is visible again. One refresh's worth of slack over a slow
  /// 24 Hz panel is 42 ms; a second is far past any of them and still returns.
  void _awaitFrameLatency() {
    frameLatencyWaitMicroseconds = 0;
    final int waitable = _frameLatencyWaitable;
    if (waitable == 0) return;
    final Stopwatch waiting = Stopwatch()..start();
    _device.library.waitForSingleObject(waitable, _frameLatencyTimeoutMs);
    waiting.stop();
    frameLatencyWaitMicroseconds = waiting.elapsedMicroseconds;
  }

  void _abandon() {
    if (!_recording) return;
    _recording = false;
    _device.frames.abandon();
  }

  /// Rasterises [list] into the back buffer and presents it.
  @override
  Future<PresentResult> renderDisplayList(
    DisplayList list, {
    int? clearColor,
    Transform2D deviceTransform = Transform2D.identity,
  }) async {
    final Frame frame = beginFrame(FrameRequest(clearColor: clearColor));
    final DisplayListResources resources = DisplayListResources(list);
    _fonts.bind(resources);
    _player.play(
      DisplayListReader(list),
      resources,
      deviceBounds: Rect.fromLTWH(
        0,
        0,
        _surface.pixelWidth.toDouble(),
        _surface.pixelHeight.toDouble(),
      ),
      deviceTransform: deviceTransform,
    );
    return present(frame);
  }

  @override
  void resize(int pixelWidth, int pixelHeight, double scale) {
    throwIfDisposed();
    if (pixelWidth == _surface.pixelWidth &&
        pixelHeight == _surface.pixelHeight &&
        scale == _surface.scale) {
      return;
    }
    _generation++;
    _surface = _surface.resized(
      pixelWidth: pixelWidth,
      pixelHeight: pixelHeight,
      scale: scale,
    );
    final DxgiSwapChain3? chain = _swapChain;
    if (chain == null) return;

    // Order matters and both halves are required. The wait first, because the
    // buffers about to be released may still be being read; the releases
    // second, because ResizeBuffers refuses outright while a reference
    // survives - and that refusal is the loud half of the failure. A missing
    // wait has no loud half at all.
    _device.frames.waitIdle();
    _releaseBackBuffers();
    // The flags and the buffer count are the ones creation recorded, never 0
    // and never the descriptor's. Passing 0 here is the bug this feature
    // always ships with: `ResizeBuffers` returns S_OK, the chain stops being
    // waitable, and `_frameLatencyWaitable` becomes a handle that never
    // signals - so the first resize turns every later frame into a full
    // `_frameLatencyTimeoutMs` stall. Nothing reports it; the application just
    // drops to one frame a second after the user drags a corner.
    final int hr = chain.resizeBuffers(
      _bufferCount,
      pixelWidth,
      pixelHeight,
      kD3d12SurfaceFormat,
      _swapChainFlags,
    );
    if (comFailed(hr)) {
      _creationFailure = BackendDiagnostic(
        kind: DiagnosticKind.surfaceCreationFailed,
        message: 'ResizeBuffers refused',
        detail: '${pixelWidth}x$pixelHeight: ${hresultText(hr)}',
      );
      _swapChain = null;
      _closeFrameLatencyWaitable();
      chain.release();
      return;
    }
    _acquireBackBuffers(chain);
    _backBufferIndex = chain.currentBackBufferIndex;
  }

  // -------------------------------------------------------------------
  // PresentPacer
  // -------------------------------------------------------------------

  /// Every mode this swap chain can deliver on this machine, right now.
  ///
  /// [PresentMode.fifo] and [PresentMode.immediate] are always in the set: a
  /// flip-model swap chain takes sync interval 1 and 0 with no capability
  /// behind either. [PresentMode.mailbox] is in it until a creation with the
  /// waitable flag has actually been refused, and then it is not - an instance
  /// property rather than a constant precisely because the honest answer is
  /// "what DXGI said when asked", and DXGI is only asked by being told to do
  /// it.
  @override
  Set<PresentMode> get supportedPresentModes => <PresentMode>{
        PresentMode.fifo,
        PresentMode.immediate,
        if (_mailboxRefusal == null) PresentMode.mailbox,
      };

  /// The mode actually in force, derived from the swap chain rather than
  /// remembered.
  ///
  /// A remembered mode is a mode that lies the moment anything changes it by
  /// another route - and [syncInterval] is public, so another route exists.
  /// The waitable handle is the ground truth for mailbox because it can only
  /// exist if DXGI accepted the flag; a caller that then forced
  /// `syncInterval = 0` on that chain is presenting immediately and is told
  /// so, rather than being told mailbox because mailbox was once granted.
  @override
  PresentMode get presentMode {
    if (_frameLatencyWaitable != 0 && syncInterval >= 1) {
      return PresentMode.mailbox;
    }
    return syncInterval >= 1 ? PresentMode.fifo : PresentMode.immediate;
  }

  @override
  PresentModeOutcome requestPresentMode(PresentMode mode) {
    if (isDisposed || _swapChain == null) {
      return PresentModeOutcome.refused(
        mode,
        applied: presentMode,
        reason: 'this target has no swap chain to pace',
        detail: _creationFailure?.message,
      );
    }
    switch (mode) {
      case PresentMode.fifo:
        final PresentModeOutcome? failure = _rebuildFor(mode, waitable: false);
        if (failure != null) return failure;
        syncInterval = 1;
        return PresentModeOutcome.honoured(
          PresentMode.fifo,
          detail: 'IDXGISwapChain3::Present(1, 0) on a FLIP_DISCARD chain of '
              '$_bufferCount buffers. Measured and worth knowing: the present '
              'call itself does not block on Direct3D 12 - it returns in a '
              'few hundred microseconds - and the frame is throttled later, '
              'inside the frame ring fence, where the producer can neither '
              'name the stall nor spend it. Moving that stall is what mailbox '
              'is for',
        );
      case PresentMode.immediate:
        final PresentModeOutcome? failure = _rebuildFor(mode, waitable: false);
        if (failure != null) return failure;
        syncInterval = 0;
        return PresentModeOutcome.honoured(
          PresentMode.immediate,
          detail: 'IDXGISwapChain3::Present(0, 0); the present is not '
              'throttled. DXGI_PRESENT_ALLOW_TEARING is deliberately not '
              'passed - it needs DXGI_SWAP_CHAIN_FLAG_ALLOW_TEARING at '
              'creation and an IDXGIFactory5 capability query this backend '
              'does not make, and under the desktop compositor a windowed '
              'flip-model present does not tear with or without it',
        );
      case PresentMode.mailbox:
        final BackendDiagnostic? refused = _mailboxRefusal;
        if (refused != null) {
          return PresentModeOutcome.refused(
            mode,
            applied: presentMode,
            reason: 'this swap chain already refused the frame-latency '
                'waitable object once',
            detail: refused.detail ?? refused.message,
          );
        }
        final PresentModeOutcome? failure = _rebuildFor(mode, waitable: true);
        if (failure != null) return failure;
        syncInterval = 1;
        return PresentModeOutcome.honoured(
          PresentMode.mailbox,
          detail: 'FLIP_DISCARD over $_bufferCount buffers with '
              'DXGI_SWAP_CHAIN_FLAG_FRAME_LATENCY_WAITABLE_OBJECT, '
              'SetMaximumFrameLatency(1), the wait taken before recording and '
              'Present(1, 0) - so the frame is tear-free and the producer '
              'blocks where it is idle instead of inside the present',
        );
    }
  }

  /// Always false, and the reason is [PresentPacer.awaitVerticalBlank]'s
  /// second bullet: under [PresentMode.fifo] the present itself blocks on the
  /// vertical blank, so waiting again here would halve the frame rate. Under
  /// [PresentMode.mailbox] the wait that matters is the frame-latency one and
  /// it is already taken in [beginFrame], where it overlaps the display's hold
  /// of the previous frame; taking it a second time here would spend the
  /// overlap this mode exists to create.
  @override
  bool awaitVerticalBlank() => false;

  /// Rebuilds the swap chain when [mode] needs a shape the live one does not
  /// have. Returns null when nothing had to change or the change worked, and a
  /// refusal naming what failed otherwise.
  ///
  /// The flag and the third buffer are both creation-time properties, so there
  /// is no in-place route: this is the same teardown [resize] does, plus a
  /// creation. [generation] is bumped so a frame recorded against the chain
  /// being destroyed is refused as stale instead of presented into a buffer
  /// that has been freed.
  PresentModeOutcome? _rebuildFor(PresentMode mode, {required bool waitable}) {
    final int flags =
        waitable ? dxgiSwapChainFlagFrameLatencyWaitableObject : 0;
    final int buffers = waitable
        // Three, or more if the caller asked for more. Two is legal for
        // FLIP_DISCARD and useless here: one buffer on screen and one queued
        // leaves the producer nothing to draw into, so it blocks in `Present`
        // and the waitable object buys nothing.
        ? (_surface.bufferCount < 3 ? 3 : _surface.bufferCount)
        : _surface.bufferCount;
    if (flags == _swapChainFlags && buffers == _bufferCount) return null;

    _destroySwapChain();
    _generation++;
    _createSwapChain(flags: flags, bufferCount: buffers);
    if (_swapChain != null) {
      // Only a *waitable* creation that worked clears the refusal. Coming back
      // through fifo does not un-refuse mailbox, and clearing it there would
      // put mailbox back in `supportedPresentModes` on a machine that has
      // already said no once.
      if (waitable) _mailboxRefusal = null;
      return null;
    }

    // The chain the mode asked for could not be created. Put the window back
    // on a chain that works before answering, because a refusal that leaves
    // the target unable to present has broken more than it reported.
    final BackendDiagnostic asked = _creationFailure ??
        const BackendDiagnostic(
          kind: DiagnosticKind.surfaceCreationFailed,
          message: 'the swap chain could not be created',
        );
    if (waitable) _mailboxRefusal = asked;
    _createSwapChain(flags: 0, bufferCount: _surface.bufferCount);
    if (_swapChain == null) {
      return PresentModeOutcome.refused(
        mode,
        applied: presentMode,
        reason: '${asked.message}, and the fallback swap chain could not be '
            'created either, so this window can no longer present at all',
        detail: _creationFailure?.detail ?? asked.detail,
      );
    }
    _creationFailure = null;
    // Named, not silent: `applied` below is what the window is really running
    // now, which is the fallback and not the request, and `present_mode.dart`
    // exists because a backend that answers a refusal with success makes the
    // application blame the framework for latency it chose.
    syncInterval = 1;
    return PresentModeOutcome.refused(
      mode,
      applied: PresentMode.fifo,
      reason: waitable
          ? 'CreateSwapChainForHwnd refused '
              'DXGI_SWAP_CHAIN_FLAG_FRAME_LATENCY_WAITABLE_OBJECT over '
              '$buffers buffers: ${asked.message}'
          : 'CreateSwapChainForHwnd refused a plain FLIP_DISCARD chain of '
              '$buffers buffers: ${asked.message}',
      detail: '${asked.detail ?? 'no detail'}; the window was rebuilt on a '
          'plain FLIP_DISCARD chain of ${_surface.bufferCount} buffers and is '
          'presenting in fifo',
    );
  }

  // -------------------------------------------------------------------
  // Swap chain
  // -------------------------------------------------------------------

  void _createSwapChain({required int flags, required int bufferCount}) {
    _swapChainFlags = flags;
    _bufferCount = bufferCount;
    D3d12Arena.using(_device.library.allocator, (D3d12Arena arena) {
      final Pointer<DxgiSwapChainDesc1> desc =
          arena<DxgiSwapChainDesc1>(sizeOf<DxgiSwapChainDesc1>());
      desc.ref
        ..width = _surface.pixelWidth
        ..height = _surface.pixelHeight
        ..format = kD3d12SurfaceFormat
        ..stereo = 0
        ..bufferUsage = dxgiUsageRenderTargetOutput
        ..bufferCount = bufferCount
        ..scaling = dxgiScalingStretch
        // The only swap effect Direct3D 12 supports. The blt-model effects
        // fail outright rather than falling back, which is why there is no
        // choice to make here - and it is also half of what PresentMode.mailbox
        // needs, the other half being the flag below and a third buffer.
        ..swapEffect = dxgiSwapEffectFlipDiscard
        ..alphaMode = dxgiAlphaModeUnspecified
        ..flags = flags;
      desc.ref.sampleDesc
        ..count = 1
        ..quality = 0;

      final Pointer<Pointer<Void>> out = arena.allocatePointers(1);
      // The first argument is the *command queue*, not the device. That is
      // Direct3D 12's own rule and the most commonly mis-ported line from
      // Direct3D 11: the flip is ordered against that queue and nothing else.
      final int hr = _device.factory.createSwapChainForHwnd(
        _device.queue.pointer,
        _surface.nativeHandle,
        desc,
        out,
      );
      if (comFailed(hr)) {
        _creationFailure = BackendDiagnostic(
          kind: DiagnosticKind.surfaceCreationFailed,
          message: 'CreateSwapChainForHwnd refused the window',
          detail: '${hresultText(hr)}; the handle is an opaque integer here '
              'and cannot be validated before the call - see '
              'd3d12_surface_descriptor.dart',
        );
        return;
      }

      final Pointer<Guid> iid = arena<Guid>(sizeOf<Guid>());
      writeGuid(iid, D3d12Iids.dxgiSwapChain3);
      final Pointer<Pointer<Void>> upgraded = arena.allocatePointers(1);
      final int queryHr = ComObject(out.value).queryInterface(iid, upgraded);
      ComObject(out.value).release();
      if (comFailed(queryHr)) {
        _creationFailure = BackendDiagnostic(
          kind: DiagnosticKind.incompatibleVersion,
          message: 'this Windows has no IDXGISwapChain3',
          detail: '${hresultText(queryHr)}; GetCurrentBackBufferIndex lives '
              'there, and a counter kept in its place drifts the first time a '
              'present is skipped',
        );
        return;
      }

      final DxgiSwapChain3 chain = DxgiSwapChain3(upgraded.value);
      // DXGI installs a window hook for Alt+Enter unless told not to. A
      // framework that owns its window has to decide about full screen itself,
      // and a hook that changes the swap chain behind the renderer's back is
      // exactly the invisible state change section 6.6 is about.
      _device.factory
          .makeWindowAssociation(_surface.nativeHandle, _dxgiNoAltEnter);
      _swapChain = chain;
      _creationFailure = null;
      if (flags & dxgiSwapChainFlagFrameLatencyWaitableObject != 0) {
        _adoptFrameLatencyWaitable(chain);
        if (_frameLatencyWaitable == 0) {
          // The flag was accepted and the handle was not produced. That is not
          // a state DXGI documents, so it is reported rather than run: a chain
          // that is waitable and has no object to wait on presents through a
          // frame-latency queue nobody is draining.
          _swapChain = null;
          chain.release();
          return;
        }
      }
      _acquireBackBuffers(chain);
      _backBufferIndex = chain.currentBackBufferIndex;
    });
  }

  /// Takes the waitable object and bounds the queue to one frame.
  ///
  /// `SetMaximumFrameLatency` is the half of mailbox that is easy to leave
  /// out, and leaving it out is invisible: DXGI's default is three frames in
  /// flight, so the picture is correct, tear-free and about 33 ms behind the
  /// mouse at 60 Hz. One is what "the newest finished frame" means.
  void _adoptFrameLatencyWaitable(DxgiSwapChain3 chain) {
    final int latencyHr = chain.setMaximumFrameLatency(1);
    if (comFailed(latencyHr)) {
      _creationFailure = BackendDiagnostic(
        kind: DiagnosticKind.surfaceCreationFailed,
        message: 'SetMaximumFrameLatency(1) refused the waitable swap chain',
        detail: hresultText(latencyHr),
      );
      return;
    }
    final int waitable = chain.getFrameLatencyWaitableObject();
    if (waitable == 0) {
      _creationFailure = const BackendDiagnostic(
        kind: DiagnosticKind.surfaceCreationFailed,
        message: 'GetFrameLatencyWaitableObject returned a null handle on a '
            'chain created with '
            'DXGI_SWAP_CHAIN_FLAG_FRAME_LATENCY_WAITABLE_OBJECT',
        detail: 'there is then nothing to wait on, and waiting on 0 would '
            'return immediately every frame - which looks exactly like '
            'mailbox working',
      );
      return;
    }
    _frameLatencyWaitable = waitable;
  }

  /// Releases everything the live swap chain owns, in the order the API
  /// requires: GPU idle, then buffer references, then the waitable handle,
  /// then the chain.
  void _destroySwapChain() {
    final DxgiSwapChain3? chain = _swapChain;
    if (chain == null) return;
    _abandon();
    _device.frames.waitIdle();
    _releaseBackBuffers();
    _closeFrameLatencyWaitable();
    _swapChain = null;
    chain.release();
  }

  /// Closes the waitable object. An OS handle, so `CloseHandle` and not a COM
  /// release - and it has to happen on every teardown, not only on dispose,
  /// because a mode change tears a chain down while the process keeps running.
  void _closeFrameLatencyWaitable() {
    final int waitable = _frameLatencyWaitable;
    if (waitable == 0) return;
    _frameLatencyWaitable = 0;
    _device.library.closeHandle(waitable);
  }

  void _acquireBackBuffers(DxgiSwapChain3 chain) {
    D3d12Arena.using(_device.library.allocator, (D3d12Arena arena) {
      final Pointer<Guid> iid = arena<Guid>(sizeOf<Guid>());
      writeGuid(iid, D3d12Iids.resource);
      final Pointer<Pointer<Void>> out = arena.allocatePointers(1);
      // `_bufferCount`, never the descriptor's: under mailbox the chain has a
      // third buffer the descriptor does not mention, and a loop that stopped
      // at two would leave it with no render target view - so every third
      // frame would draw into a view that was never created.
      for (var i = 0; i < _bufferCount; i++) {
        final int hr = chain.getBuffer(i, iid, out);
        if (comFailed(hr)) {
          _creationFailure = BackendDiagnostic(
            kind: DiagnosticKind.surfaceCreationFailed,
            message: 'swap chain buffer $i could not be obtained',
            detail: hresultText(hr),
          );
          return;
        }
        _backBuffers.add(out.value);
        final int view = i < _backBufferViews.length
            ? _backBufferViews[i]
            : _device.allocateRenderTargetView();
        if (i >= _backBufferViews.length) _backBufferViews.add(view);
        _device.createRenderTargetView(out.value, view);
      }
    });
  }

  void _releaseBackBuffers() {
    for (final Pointer<Void> buffer in _backBuffers) {
      ComObject(buffer).release();
    }
    _backBuffers.clear();
  }

  // -------------------------------------------------------------------
  // Atlases
  // -------------------------------------------------------------------

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

  void _uploadGlyphAtlas() {
    if (!_glyphAtlas.isDirty) return;
    final int width = _glyphAtlas.width;
    _glyphAtlas.forEachDirtyRegion((int x, int y, int regionWidth, int height) {
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

  void _flushAtlases() {
    if (!_recording || _swapChain == null) return;
    _uploadMaskAtlas();
    _uploadGlyphAtlas();
    final int? clear = _pendingClear;
    _pendingClear = null;
    _device.submit(
      _batcher,
      _surface.pixelWidth,
      _surface.pixelHeight,
      clear,
      renderTargetView: _backBufferViews[_backBufferIndex],
      firstBatch: _submittedBatches,
    );
    _submittedBatches = _batcher.batchCount;
  }

  @override
  void onDispose() {
    _abandon();
    _device.frames.waitIdle();
    _releaseBackBuffers();
    _closeFrameLatencyWaitable();
    for (final int view in _backBufferViews) {
      _device.releaseRenderTargetView(view);
    }
    _backBufferViews.clear();
    _swapChain?.release();
    _swapChain = null;
    _images.clear();
    _device
      ..releaseTexture(_maskTexture)
      ..releaseTexture(_glyphTexture);
    _glyphAtlas.clear();
    _fonts.bind(null);
  }
}
