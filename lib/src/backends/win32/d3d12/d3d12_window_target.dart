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

/// A render target backed by a DXGI swap chain over a window.
final class D3d12WindowTarget with DisposableMixin implements RenderTarget {
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
    _fonts = D3d12FontResolver();
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
    _createSwapChain();
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
  late final D3d12FontResolver _fonts;
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

  /// Vertical blanks between presents. 1 by default, which is what a UI that
  /// renders on demand wants; a caller chasing a frame-time number sets 0.
  int syncInterval = 1;

  @override
  NativeSurfaceDescriptor get surface => _surface;

  /// Which swap chain buffer the frame in progress is drawn into.
  ///
  /// Exposed because it is the observable that says the flip model is working:
  /// it must advance on every present and wrap at
  /// [D3d12WindowSurfaceDescriptor.bufferCount].
  int get backBufferIndex => _backBufferIndex;

  int get bufferCount => _backBuffers.length;

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

    final int hr = chain.present(syncInterval, 0);
    if (comFailed(hr)) {
      _device.markLost('Present failed', detail: hresultText(hr));
      return _device.state.blockedPresent()!;
    }
    return const PresentResult(status: PresentStatus.presented);
  }

  void _abandon() {
    if (!_recording) return;
    _recording = false;
    _device.frames.abandon();
  }

  /// Rasterises [list] into the back buffer and presents it.
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
    final int hr = chain.resizeBuffers(
      _surface.bufferCount,
      pixelWidth,
      pixelHeight,
      kD3d12SurfaceFormat,
      0,
    );
    if (comFailed(hr)) {
      _creationFailure = BackendDiagnostic(
        kind: DiagnosticKind.surfaceCreationFailed,
        message: 'ResizeBuffers refused',
        detail: '${pixelWidth}x$pixelHeight: ${hresultText(hr)}',
      );
      _swapChain = null;
      chain.release();
      return;
    }
    _acquireBackBuffers(chain);
    _backBufferIndex = chain.currentBackBufferIndex;
  }

  // -------------------------------------------------------------------
  // Swap chain
  // -------------------------------------------------------------------

  void _createSwapChain() {
    D3d12Arena.using(_device.library.allocator, (D3d12Arena arena) {
      final Pointer<DxgiSwapChainDesc1> desc =
          arena<DxgiSwapChainDesc1>(sizeOf<DxgiSwapChainDesc1>());
      desc.ref
        ..width = _surface.pixelWidth
        ..height = _surface.pixelHeight
        ..format = kD3d12SurfaceFormat
        ..stereo = 0
        ..bufferUsage = dxgiUsageRenderTargetOutput
        ..bufferCount = _surface.bufferCount
        ..scaling = dxgiScalingStretch
        // The only swap effect Direct3D 12 supports. The blt-model effects
        // fail outright rather than falling back, which is why there is no
        // choice to make here.
        ..swapEffect = dxgiSwapEffectFlipDiscard
        ..alphaMode = dxgiAlphaModeUnspecified
        ..flags = 0;
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
      _acquireBackBuffers(chain);
      _backBufferIndex = chain.currentBackBufferIndex;
    });
  }

  void _acquireBackBuffers(DxgiSwapChain3 chain) {
    D3d12Arena.using(_device.library.allocator, (D3d12Arena arena) {
      final Pointer<Guid> iid = arena<Guid>(sizeOf<Guid>());
      writeGuid(iid, D3d12Iids.resource);
      final Pointer<Pointer<Void>> out = arena.allocatePointers(1);
      for (var i = 0; i < _surface.bufferCount; i++) {
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
