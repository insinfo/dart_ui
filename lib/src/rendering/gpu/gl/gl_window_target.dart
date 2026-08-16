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
/// ## What this target cannot give a caller
///
/// [Frame.framebuffer] is non-nullable in `lib/src/rendering/renderer.dart`,
/// and a windowed GPU target genuinely has no CPU-visible pixels to put there.
/// The frame therefore carries a 1x1 placeholder. That is a mismatch in the
/// `renderer.dart` contract rather than a shortcut here - `Frame` was designed
/// around the CPU rasteriser, where the framebuffer *is* the surface - and
/// fixing it means making the field nullable or splitting `Frame`, which is a
/// change to a file this class does not own. It is called out here so the
/// placeholder is never mistaken for the window's contents. Nothing in the
/// draw path reads it: [beginFrame] takes its damage rectangle from the
/// descriptor's pixel size, and [renderDisplayList] takes its device bounds
/// from the same place.
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
import '../../renderer.dart';
import '../../replay/display_list_player.dart';
import '../gpu_batcher.dart';
import '../gpu_layer_stack.dart';
import '../gpu_mask_atlas.dart';
import '../gpu_raster_sink.dart';
import '../gpu_texture.dart';
import 'gl_backend.dart';
import 'gl_bindings.dart';
import 'gl_framebuffer_pool.dart';
import 'gl_surface_descriptor.dart';

/// A render target backed by a window's back buffer.
final class GlWindowTarget with DisposableMixin implements RenderTarget {
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
    _maskTexture = _device.createTexture(
      width: _maskAtlas.width,
      height: _maskAtlas.height,
      format: GpuTextureFormat.alpha8,
      // One texel per pixel by construction, so nearest reproduces the CPU
      // rasteriser's coverage byte exactly and linear would blur it.
      filter: GpuTextureFilter.nearest,
    );
    _images = GlImageCache(_device);
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
    );
    _sink = GpuRasterSink(
      batcher: _batcher,
      backendName: GlRendererBackend.backendName,
      maskAtlas: _maskAtlas,
      maskTextureId: _maskTexture.id,
      imageResolver: _images,
      layerStack: _layers,
      onAtlasFlush: _flushAtlases,
    );
    _player = DisplayListPlayer(_sink);
  }

  final GlRenderDevice _device;
  final GpuBatcher _batcher = GpuBatcher();

  late final GpuMaskAtlas _maskAtlas;
  late final GlTexture _maskTexture;
  late final GlImageCache _images;
  late final GlFramebufferPool _layerPool;
  late final GpuLayerStack _layers;
  late final GpuRasterSink _sink;
  late final DisplayListPlayer _player;

  /// How many batches of the current frame have already been drawn. See
  /// [GpuRasterSink.onAtlasFlush]: a batch drawn twice blends twice.
  int _submittedBatches = 0;

  /// Where layers get their offscreen targets. Exposed for a memory report and
  /// for a test that asserts the same layer drawn on ten frames created one
  /// framebuffer; reuse is invisible from the pixels.
  GlFramebufferPool get layerPool => _layerPool;

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

  @override
  Frame beginFrame(FrameRequest request) {
    throwIfDisposed();
    _batcher.beginFrame();
    _maskAtlas.beginFrame();
    _layers.beginFrame(
      surfaceWidth: _surface.pixelWidth,
      surfaceHeight: _surface.pixelHeight,
    );
    _submittedBatches = 0;
    _pendingClear = request.clearColor;
    return Frame(
      target: this,
      // Not the window's pixels. See the library comment: `Frame` requires a
      // Framebuffer and a windowed GPU target has none to give.
      framebuffer: _placeholder,
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

    final int? clear = _pendingClear;
    _pendingClear = null;
    final drawn = _device.submit(
      _batcher,
      _surface.pixelWidth,
      _surface.pixelHeight,
      clear,
      layers: _layers,
      // Framebuffer 0 is this target's surface, and submit rebinds it after
      // every layer pass so the swap below finds the back buffer bound.
      firstBatch: _submittedBatches,
    );
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
  Future<PresentResult> renderDisplayList(
    DisplayList list, {
    int? clearColor,
    Transform2D deviceTransform = Transform2D.identity,
  }) async {
    final frame = beginFrame(FrameRequest(clearColor: clearColor));
    _player.play(
      DisplayListReader(list),
      DisplayListResources(list),
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

  /// The backend's half of the atlas flush protocol - see
  /// [GpuRasterSink.onAtlasFlush]. Upload first, because the batches about to
  /// be drawn sample texels that so far exist only in the staging image;
  /// submit second, and remember how far it got.
  void _flushAtlases() {
    _uploadMaskAtlas();
    final int? clear = _pendingClear;
    _pendingClear = null;
    _device.submit(
      _batcher,
      _surface.pixelWidth,
      _surface.pixelHeight,
      clear,
      layers: _layers,
      firstBatch: _submittedBatches,
    );
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

  /// The one pixel [Frame] insists on. Allocated once per target rather than
  /// per frame, because allocating a throwaway buffer sixty times a second to
  /// satisfy a type is worse than allocating it once.
  static final Framebuffer _placeholder = Framebuffer.allocate(
    width: 1,
    height: 1,
    format: PixelFormat.rgba8888Premultiplied,
  );

  @override
  void onDispose() {
    _images.clear();
    // After endFrame has returned every target: the pool only deletes what is
    // idle, so disposing mid-frame would leak the ones still in flight.
    _layers.endFrame();
    _layerPool.dispose();
    _device.releaseTexture(_maskTexture);
  }
}
