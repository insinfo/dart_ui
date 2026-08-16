/// The WebGL2 target that puts pixels on a page.
///
/// [WebGlOffscreenTarget] renders into a framebuffer object and reads it back
/// on every present. Its own header says why that is right for a test and wrong
/// for a screen: a readback stalls the pipeline until the GPU has finished,
/// copies a whole surface across the bus, and then hands it back to be composited
/// anyway. What it buys is a [Framebuffer] a parity test can compare, which is
/// worth the cost in a test and nothing at all on a page.
///
/// This target does the other thing. It binds the *default* framebuffer - null,
/// where desktop GL writes the integer 0 - which for a context created on a
/// canvas is that canvas's drawing buffer, and draws into it. There is
/// deliberately no way to read pixels back from here.
///
/// ## There is no `swapBuffers`, and that is not an omission
///
/// `GlWindowTarget` ends its present with `swapChain.swapBuffers()`, and the
/// obvious port would look for the equivalent call. There is none, and looking
/// for one is how this class would grow a bug.
///
/// A WebGL drawing buffer is presented by the browser's own compositor, at the
/// end of the task that drew into it - the specification calls it the "current
/// task" and the presentation happens when control returns to the event loop.
/// The application's part of the contract is therefore *when* it draws, not
/// what it calls afterwards: everything must happen inside one
/// `requestAnimationFrame` callback, because a frame drawn across two tasks is
/// composited half-finished. That is why [present] is synchronous in substance
/// even though the interface returns a `Future` - it must not await anything
/// between the first draw call and the end of the callback, and it does not.
///
/// The one consequence worth stating: `preserveDrawingBuffer` is false (see
/// [defaultWebGl2ContextAttributes]), so the drawing buffer's contents are
/// *undefined* after that composite. A frame must redraw everything it wants
/// visible. This is the same promise [RendererCapabilities.supportsPartialPresent]
/// makes by answering false, and it is why `beginFrame`'s clear is not
/// optional in practice even though `FrameRequest` allows a null one.
///
/// ## The generation contract, and why it is checked twice
///
/// A canvas resizes on the page's schedule - a CSS layout change, a device
/// pixel ratio change when a window moves between monitors, a
/// `ResizeObserver` firing. Between the moment a frame is recorded and the
/// moment it is composited, `canvas.width` may have become a different number,
/// which means the geometry in the batcher is for a viewport that no longer
/// exists.
///
/// So [generation] folds three counters into one: this target's own resizes,
/// the device's loss count, and the canvas's [GenerationToken], shared through
/// [WebGlCanvasSurfaceDescriptor.generation]. [present] compares it against the
/// frame's on entry *and* again after the draws, for the reason
/// `gl_window_target.dart` gives: the mask upload and the draw are the longest
/// part of a frame and a resize arriving during them is the common case. A
/// mismatch is [PresentStatus.stale], which the roadmap defines as normal -
/// dropping one frame during a resize is what a correct renderer does.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import '../../../foundation/diagnostics.dart';
import '../../../foundation/lifecycle.dart';
import '../../../geometry/rect.dart';
import '../../../geometry/transform2d.dart';
import '../../../graphics/display_list.dart';
import '../../../graphics/display_list_reader.dart';
import '../../renderer.dart';
import '../../replay/display_list_player.dart';
import '../gpu_batcher.dart';
import '../gpu_glyph_atlas.dart';
import '../gpu_layer_stack.dart';
import '../gpu_mask_atlas.dart';
import '../gpu_raster_sink.dart';
import '../gpu_recovery.dart';
import '../gpu_texture.dart';
import 'webgl_backend.dart';
import 'webgl_framebuffer_pool.dart';
import 'webgl_surface_descriptor.dart';

/// A render target backed by a canvas's drawing buffer.
final class WebGlCanvasTarget
    with DisposableMixin
    implements RenderTarget, WebGlRecoverableTarget {
  /// Wraps [surface] for [device].
  ///
  /// The constructor is public - unlike [WebGlOffscreenTarget]'s - because this
  /// class is in a different library from the device that builds it and Dart
  /// has no "visible to my package only" between the two. Calling it with a
  /// device whose context did not come from `surface.canvas` is a caller error
  /// this class cannot detect and that draws nothing: the draws would land in
  /// the other canvas's buffer. [WebGlCanvasTarget.open] below is the
  /// constructor that cannot get it wrong, and is what callers should use.
  ///
  /// Takes no ownership of the canvas. Disposing this target releases the
  /// textures it uploaded and nothing else: the page created the element and
  /// the page removes it, which is the split `renderer.dart` describes between
  /// a target and the surface it draws into.
  WebGlCanvasTarget(this._device, WebGlCanvasSurfaceDescriptor surface)
      : _surface = surface,
        _observedCanvasGeneration = surface.generation.current {
    _maskAtlas = GpuMaskAtlas();
    _glyphAtlas = GpuGlyphAtlas();
    _fonts = WebGlFontResolver();
    _images = WebGlImageCache(_device);
    _buildAtlasObjects();
    _device.registerTarget(this);
  }

  /// Opens a context on [surface]'s canvas and builds a device and a target on
  /// it, or names what the browser refused.
  ///
  /// The constructor a caller wants, because it is the one that cannot pair a
  /// device with the wrong canvas: the context comes from the descriptor's own
  /// element, and the device is built on that context. A page with two canvases
  /// gets two devices, which is also correct - a WebGL context cannot draw into
  /// a canvas it was not created for, so sharing one device between two
  /// canvases is not a thing the platform offers.
  ///
  /// Returns a null target and a diagnostic rather than throwing, because every
  /// failure here is "this browser cannot run this backend", which section 6.6
  /// says must be reported.
  static ({
    WebGlCanvasTarget? target,
    WebGlRenderDevice? device,
    BackendDiagnostic? failure,
  }) open(WebGlCanvasSurfaceDescriptor surface) {
    final web.WebGL2RenderingContext? gl = createWebGl2Context(
      surface.canvas,
      attributes: surface.contextAttributes,
    );
    if (gl == null) {
      return (
        target: null,
        device: null,
        failure: const BackendDiagnostic(
          kind: DiagnosticKind.unsupportedPlatform,
          message: 'this canvas did not give a WebGL2 context',
          detail: 'getContext("webgl2") answered null or something that is '
              'not a WebGL2RenderingContext. WebGL may be disabled, the '
              'browser may support only WebGL1, or this canvas may already '
              'have a 2d context - an element can only ever have one kind',
        ),
      );
    }
    final ({WebGlRenderDevice? device, BackendDiagnostic? failure}) opened =
        WebGlRenderDevice.adoptContext(gl);
    final WebGlRenderDevice? device = opened.device;
    if (device == null) {
      return (target: null, device: null, failure: opened.failure);
    }
    return (
      target: WebGlCanvasTarget(device, surface),
      device: device,
      failure: null,
    );
  }

  final WebGlRenderDevice _device;
  final GpuBatcher _batcher = GpuBatcher();

  late final GpuMaskAtlas _maskAtlas;
  late final GpuGlyphAtlas _glyphAtlas;
  late final WebGlFontResolver _fonts;
  late final WebGlImageCache _images;

  // Not final: a context loss destroys all six and a recovery rebuilds them.
  late WebGlTexture _maskTexture;
  late WebGlTexture _glyphTexture;
  late WebGlFramebufferPool _layerPool;
  late GpuLayerStack _layers;
  late GpuRasterSink _sink;
  late DisplayListPlayer _player;

  /// Creates the atlas textures and everything downstream of their ids.
  ///
  /// Shared by the constructor and by [_repopulateAtlasObjects], for the reason
  /// `gl_window_target.dart` gives for its copy: the sink holds the mask and
  /// glyph texture ids as final fields, so a recovery has to rebuild the sink
  /// rather than the textures alone, and a rebuild that drifted from the
  /// constructor would draw a frame that is subtly wrong instead of one that
  /// fails.
  void _buildAtlasObjects() {
    _maskTexture = _device.createTexture(
      width: _maskAtlas.width,
      height: _maskAtlas.height,
      format: GpuTextureFormat.alpha8,
      filter: GpuTextureFilter.nearest,
    );
    // Text is wired here exactly as it is on the offscreen target, and that
    // symmetry is the point: a page is where text is actually read, so a
    // backend whose *test* target drew glyphs and whose *canvas* target refused
    // them would pass every parity test and show a blank panel on screen.
    _glyphTexture = _device.createTexture(
      width: _glyphAtlas.width,
      height: _glyphAtlas.height,
      format: GpuTextureFormat.alpha8,
      filter: GpuTextureFilter.nearest,
    );
    // Layers cost the same here as on the offscreen target. Without them a
    // `saveLayer` with an opacity would be refused by name - which is correct,
    // and is not the same thing as being drawable.
    _layerPool = WebGlFramebufferPool(
      gl: _device.gl,
      textures: _device.textures,
      onError: _device.state.markLost,
    );
    _layers = GpuLayerStack(
      allocator: _layerPool,
      backendName: WebGlRendererBackend.backendName,
    );
    _sink = GpuRasterSink(
      batcher: _batcher,
      backendName: WebGlRendererBackend.backendName,
      maskAtlas: _maskAtlas,
      maskTextureId: _maskTexture.id,
      imageResolver: _images,
      glyphAtlas: _glyphAtlas,
      glyphTextureId: _glyphTexture.id,
      fontResolver: _fonts,
      layerStack: _layers,
      onAtlasFlush: _flushAtlases,
    );
    _player = DisplayListPlayer(_sink);
  }

  /// Step 5's inventory for this target.
  ///
  /// Shorter than [WebGlOffscreenTarget]'s by exactly one entry, and the
  /// missing one is the point: an offscreen target owns its colour texture and
  /// its framebuffer object, and a canvas target owns neither. The default
  /// framebuffer is the *canvas's* drawing buffer; the browser reallocates it
  /// when the context is restored and nothing on this side creates or destroys
  /// it. A recovery that tried to recreate it would be recreating the element.
  @override
  Iterable<GpuRecoverableResource> recoverableResources() sync* {
    yield CallbackGpuResource.fixed(
      resourceName: 'webgl2 canvas atlases '
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
    // browser has reclaimed, so it must never be submitted after the recovery.
    _batcher.beginFrame();
    _submittedBatches = 0;
    _pendingClear = null;
    _layers.endFrame();
    _layerPool.forget();
    _device
      ..releaseTexture(_maskTexture)
      ..releaseTexture(_glyphTexture);
    // Both atlases are caches that outlive a frame. The mask atlas is the one
    // that is easy to miss: its `beginFrame` deliberately keeps every cached
    // mask, so a static rounded rectangle drawn before the loss would be found
    // resident, re-batched against a texture that was never re-uploaded, and
    // drawn as nothing at all.
    _maskAtlas.recycle();
    _glyphAtlas.clear();
  }

  BackendDiagnostic? _repopulateAtlasObjects() {
    try {
      _buildAtlasObjects();
    } on UnsupportedCapabilityError catch (error) {
      return BackendDiagnostic(
        kind: DiagnosticKind.incompatibleDevice,
        message: 'the recovered WebGL2 device refused an atlas texture',
        detail: '$error',
      );
    }
    return _device.lastError;
  }

  /// How many batches of the current frame have already been drawn. See
  /// [GpuRasterSink.onAtlasFlush]: a batch drawn twice blends twice.
  int _submittedBatches = 0;

  /// The device this target draws through. Exposed so an owner that used
  /// [open] can dispose it, and so a `webglcontextrestored` handler can run a
  /// recovery on it.
  WebGlRenderDevice get device => _device;

  WebGlFramebufferPool get layerPool => _layerPool;

  GpuGlyphAtlas get glyphAtlas => _glyphAtlas;

  /// `texSubImage2D` calls this target has made for glyph coverage. A frame
  /// that redraws the same text must not increase it.
  int get glyphUploadCount => _glyphUploadCount;
  int _glyphUploadCount = 0;

  WebGlImageCache get images => _images;

  GpuBatcher get batcher => _batcher;

  WebGlCanvasSurfaceDescriptor _surface;
  int? _pendingClear;

  int _generation = 0;
  int _observedLossCount = 0;
  int _observedCanvasGeneration;

  @override
  WebGlCanvasSurfaceDescriptor get surface => _surface;

  @override
  int get generation {
    final int losses = _device.state.lossCount;
    if (losses != _observedLossCount) {
      _observedLossCount = losses;
      _generation++;
    }
    return _generation + _surface.generation.current;
  }

  /// Whether the canvas has been invalidated since this target last agreed with
  /// it.
  ///
  /// True means every frame will be rejected until [resize] is called with the
  /// canvas's current backing-store size. Exposed so an owner can tell "my
  /// frames are dropped because I have not reconciled the resize" from "my
  /// frames are dropped because the context is gone", which produce the same
  /// [PresentStatus] and have completely different fixes.
  bool get needsResize =>
      _surface.generation.current != _observedCanvasGeneration;

  @override
  Frame beginFrame(FrameRequest request) {
    throwIfDisposed();
    _batcher.beginFrame();
    _maskAtlas.beginFrame();
    _glyphAtlas.beginFrame();
    _layers.beginFrame(
      surfaceWidth: _surface.pixelWidth,
      surfaceHeight: _surface.pixelHeight,
    );
    _submittedBatches = 0;
    _pendingClear = request.clearColor;
    return Frame(
      target: this,
      // No framebuffer, and that is the truth rather than an omission: the
      // pixels are in the canvas's drawing buffer and never come back. See
      // `Frame.cpuPixels`.
      damage: request.damage ?? _surfaceRect,
      generation: generation,
    );
  }

  /// Draws the recorded batches into the canvas's drawing buffer.
  ///
  /// Never reads pixels back. The failure modes, in the order they are checked,
  /// each producing a named [PresentResult] rather than a throw:
  ///
  ///   1. the device is already lost - retrying is pointless, the caller must
  ///      recover it from a `webglcontextrestored` handler;
  ///   2. the frame is from a previous generation - a resize landed, drop it;
  ///   3. the context was lost between the frame beginning and now;
  ///   4. the canvas resized between the draw and the end of the callback.
  ///
  /// There is no fifth step where the buffer is swapped. See the library
  /// comment: the browser composites the drawing buffer when this task ends,
  /// which is why nothing here awaits between the first draw and the return.
  @override
  Future<PresentResult> present(Frame frame) async {
    throwIfDisposed();
    final PresentResult? blocked = _device.state.blockedPresent();
    if (blocked != null) return blocked;
    if (frame.generation != generation) return _stale('before it was drawn');

    if (!_device.checkContextAlive()) {
      return _device.state.blockedPresent() ??
          const PresentResult(
            status: PresentStatus.deviceLost,
            diagnostic: BackendDiagnostic(
              kind: DiagnosticKind.connectionFailed,
              message: 'the WebGL2 context was lost before the present',
            ),
          );
    }

    // The default framebuffer is this canvas's drawing buffer. Bound explicitly
    // and not assumed, because the same context may have rendered a layer pass
    // into a framebuffer object a moment ago and left it bound - the binding is
    // context state, not target state.
    _device.gl.bindFramebuffer(web.WebGL2RenderingContext.FRAMEBUFFER, null);

    _uploadMaskAtlas();
    _uploadGlyphAtlas();

    final int? clear = _pendingClear;
    _pendingClear = null;
    final bool drawn = _device.submit(
      _batcher,
      _surface.pixelWidth,
      _surface.pixelHeight,
      clear,
      layers: _layers,
      // Null is the default framebuffer, and `submit` rebinds it after every
      // layer pass so the compositor finds the drawing buffer bound.
      layerPool: _layerPool,
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
              message: 'the context was lost while the frame was being drawn',
            ),
          );
    }

    // Checked again, and this is not belt and braces. The mask upload and the
    // draw are the longest part of a frame, and a canvas resized by a CSS
    // change or a monitor switch during them is the common case rather than the
    // exotic one. The pixels are already in the drawing buffer by now, so this
    // cannot un-draw them - what it does is tell the caller the frame it is
    // about to see is for the old size, so it redraws rather than leaving a
    // stretched one up.
    if (frame.generation != generation) {
      return _stale('after it was drawn');
    }

    final PresentResult? lost = _device.state.blockedPresent();
    if (lost != null) return lost;
    return const PresentResult(status: PresentStatus.presented);
  }

  /// Reconciles this target with a canvas that is now [pixelWidth] x
  /// [pixelHeight] physical pixels at [scale].
  ///
  /// **Writes `canvas.width` and `canvas.height`.** That is the one piece of
  /// DOM mutation this class does, and it is not optional: a canvas's drawing
  /// buffer only changes size when those two properties are assigned, and
  /// setting them is also what *clears* it. The CSS size is left alone, because
  /// that is the page's layout decision - the ratio between the two is the
  /// device pixel ratio, and a renderer that wrote the CSS size would be
  /// overriding the page's layout.
  ///
  /// The generation is bumped first, so any frame already in flight is rejected
  /// even if the assignment then fails to take.
  ///
  /// A no-op when nothing changed *and* the canvas has not invalidated itself.
  /// That second condition is why this is not the usual early return: a canvas
  /// resized away and back to the same size still bumped its token, and
  /// skipping the reconcile would leave [needsResize] true forever.
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
      throw ArgumentError('a canvas surface must have a positive size, got '
          '${pixelWidth}x$pixelHeight');
    }

    _generation++;
    _surface.canvas
      ..width = pixelWidth
      ..height = pixelHeight;
    _surface = WebGlCanvasSurfaceDescriptor(
      canvas: _surface.canvas,
      generation: _surface.generation,
      scale: scale,
      contextAttributes: _surface.contextAttributes,
    );
    _observedCanvasGeneration = _surface.generation.current;
  }

  /// Rasterises [list] into the canvas and presents it.
  ///
  /// Mirrors [WebGlOffscreenTarget.renderDisplayList] argument for argument, so
  /// a caller - or a test - can swap one target for the other and compare what
  /// happened, which is the only way to check that the on-page path draws the
  /// same geometry as the path the parity tests cover.
  Future<PresentResult> renderDisplayList(
    DisplayList list, {
    int? clearColor,
    Transform2D deviceTransform = Transform2D.identity,
  }) async {
    final Frame frame = beginFrame(FrameRequest(clearColor: clearColor));
    // One resource table, walked by the player and read by the sink's font
    // resolver, so the two cannot disagree about which face an id names.
    final DisplayListResources resources = DisplayListResources(list);
    _fonts.bind(resources);
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

  /// Sends the plots this frame wrote glyphs into, and nothing else.
  ///
  /// One `texSubImage2D` per dirty plot, so a page redrawing the same label
  /// sixty times a second uploads nothing at all after the first frame - which
  /// is the entire reason the glyph atlas survives [beginFrame] while the mask
  /// atlas does not.
  ///
  /// Orientation: an atlas is *uploaded*, not rendered into, so `uYFlip` does
  /// not apply. See `webgl_backend.dart`'s copy of this method for the long
  /// form of the argument.
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

  /// The backend's half of the atlas flush protocol. Upload first, because the
  /// batches about to be drawn sample texels that so far exist only in the
  /// staging image; submit second, and remember how far it got.
  void _flushAtlases() {
    _uploadMaskAtlas();
    _uploadGlyphAtlas();
    final int? clear = _pendingClear;
    _pendingClear = null;
    _device.submit(
      _batcher,
      _surface.pixelWidth,
      _surface.pixelHeight,
      clear,
      layers: _layers,
      layerPool: _layerPool,
      firstBatch: _submittedBatches,
    );
    _submittedBatches = _batcher.batchCount;
  }

  PresentResult _stale(String when) => PresentResult(
        status: PresentStatus.stale,
        diagnostic: BackendDiagnostic.note(
          'the frame belonged to a previous generation of the canvas; it was '
          'dropped $when',
          detail: needsResize
              ? 'the canvas invalidated itself and resize() has not been '
                  'called with its new backing-store size yet, so every frame '
                  'will be dropped until it is'
              : 'the target was resized or the context was lost since the '
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
    _device
      ..releaseTexture(_maskTexture)
      ..releaseTexture(_glyphTexture);
    _glyphAtlas.clear();
    _fonts.bind(null);
    // The canvas is not touched. The page created it and the page removes it.
  }
}
