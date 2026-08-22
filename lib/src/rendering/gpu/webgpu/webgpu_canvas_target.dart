/// The WebGPU target that puts pixels on a page.
///
/// The port of `webgl_canvas_target.dart`, and everything that file argues
/// about a canvas holds here unchanged: a canvas resizes on the page's
/// schedule, so the generation is folded from the target's own resizes, the
/// device's loss count and the canvas's shared [GenerationToken], and checked
/// twice per present; the browser composites at the end of the task, so a
/// frame must be drawn inside one `requestAnimationFrame` callback and
/// [present] awaits nothing between the first draw and the return; and there
/// is no swap call to look for.
///
/// What changes is the name of the surface. WebGL draws into "the default
/// framebuffer", which exists for the context's whole life; WebGPU hands out a
/// *current texture* per composite - `getCurrentTexture()` answers the same
/// texture for the rest of the task and a fresh one next task - so where the
/// WebGL target binds framebuffer null, this one fetches the current texture's
/// view and passes it to every `submit` of the frame, mid-frame flushes
/// included. Same texture either way; WebGPU just makes the "per task" part of
/// the contract explicit in the API.
///
/// One more difference is worth a sentence: configuring the context replaces
/// any WebGL claim on the canvas and vice versa, which is why
/// [WebGpuCanvasTarget.open] does everything the *device* can refuse before it
/// touches the element. See `webgpu_interop.dart`'s note on `getContext`, and
/// `web_gpu_presenter.dart` for how that ordering keeps the WebGL2 fallback
/// alive.
library;

import 'dart:async';
import 'dart:typed_data';

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
import 'webgpu_backend.dart';
import 'webgpu_interop.dart';
import 'webgpu_surface_descriptor.dart';

/// A render target backed by a canvas's WebGPU swap texture.
final class WebGpuCanvasTarget
    with DisposableMixin
    implements RenderTarget, WebGpuRecoverableTarget {
  /// Wraps [surface] for [device], drawing through [context].
  ///
  /// Public for `WebGlCanvasTarget`'s reason - this class is in a different
  /// library from the device and Dart has no "visible to my package only" -
  /// and with the same caller-error warning: a context that was not created
  /// from `surface.canvas`, or configured on another device, draws nothing
  /// this class can detect. [WebGpuCanvasTarget.open] is the constructor that
  /// cannot get it wrong.
  ///
  /// Takes no ownership of the canvas. The page created it, the page removes
  /// it.
  WebGpuCanvasTarget(
    this._device,
    GPUCanvasContext context,
    WebGpuCanvasSurfaceDescriptor surface,
  )   : _context = context,
        _surface = surface,
        _observedCanvasGeneration = surface.generation.current {
    _maskAtlas = GpuMaskAtlas();
    _glyphAtlas = GpuGlyphAtlas();
    _fonts = WebGpuFontResolver();
    _images = WebGpuImageCache(_device);
    _buildAtlasObjects();
    _device.registerTarget(this);
  }

  /// Requests everything the browser can refuse, in the order that keeps the
  /// canvas virgin for the WebGL2 fallback until nothing can refuse any more.
  ///
  /// The order is the load-bearing part and is stated as a list on purpose:
  ///
  ///   1. `navigator.gpu`, the adapter and the device - none of which touch
  ///      the canvas, and each of which names its own refusal;
  ///   2. the renderer objects on that device, still canvas-free;
  ///   3. only then `getContext('webgpu')` and `configure`, the two calls
  ///      that claim the element.
  ///
  /// A browser that fails at steps 1-2 hands back a diagnostic and an
  /// untouched canvas, so `WebGlCanvasTarget.open` still gets a context. A
  /// failure at step 3 is a browser that advertised WebGPU and then refused
  /// its own canvas API, which is rare enough to cost the fallback and is
  /// reported by name when it happens.
  ///
  /// Returns null and a diagnostic rather than throwing, per section 6.6.
  static Future<
      ({
        WebGpuCanvasTarget? target,
        WebGpuRenderDevice? device,
        BackendDiagnostic? failure,
      })> open(WebGpuCanvasSurfaceDescriptor surface) async {
    final ({
      GPU? gpu,
      GPUAdapter? adapter,
      GPUDevice? device,
      BackendDiagnostic? failure,
    }) answer = await WebGpuRendererBackend.requestDevice();
    if (answer.device == null || answer.gpu == null) {
      return (target: null, device: null, failure: answer.failure);
    }

    final ({WebGpuRenderDevice? device, BackendDiagnostic? failure}) opened =
        WebGpuRenderDevice.adoptDevice(
      answer.device!,
      surfaceFormat: answer.gpu!.getPreferredCanvasFormat(),
      deviceDescription: describeWebGpuAdapter(answer.adapter),
    );
    final WebGpuRenderDevice? device = opened.device;
    if (device == null) {
      return (target: null, device: null, failure: opened.failure);
    }

    final GPUCanvasContext? context = createWebGpuContext(surface.canvas);
    if (context == null) {
      device.dispose();
      return (
        target: null,
        device: null,
        failure: const BackendDiagnostic(
          kind: DiagnosticKind.surfaceCreationFailed,
          message: 'this canvas did not give a WebGPU context',
          detail: 'navigator.gpu answered an adapter and a device, but '
              'getContext("webgpu") answered null or something that is not a '
              'GPUCanvasContext. The canvas may already hold another kind of '
              'context - an element only ever has one',
        ),
      );
    }
    final BackendDiagnostic? configured = _configure(context, device);
    if (configured != null) {
      device.dispose();
      return (target: null, device: null, failure: configured);
    }
    return (
      target: WebGpuCanvasTarget(device, context, surface),
      device: device,
      failure: null,
    );
  }

  static BackendDiagnostic? _configure(
    GPUCanvasContext context,
    WebGpuRenderDevice device,
  ) {
    try {
      // `opaque`, matching `alpha: false` in the WebGL context attributes and
      // for its reason: the framework's surface is opaque, and an alpha
      // channel here would have the page's background blended under pixels
      // the renderer already composited.
      context.configure(GPUCanvasConfiguration(
        device: device.gpuDevice,
        format: device.surfaceFormat,
        alphaMode: 'opaque',
      ));
    } on Object catch (error) {
      return BackendDiagnostic(
        kind: DiagnosticKind.surfaceCreationFailed,
        message: 'the WebGPU canvas context refused configure()',
        detail: '$error',
      );
    }
    return null;
  }

  final WebGpuRenderDevice _device;
  final GPUCanvasContext _context;
  final GpuBatcher _batcher = GpuBatcher();

  late final GpuMaskAtlas _maskAtlas;
  late final GpuGlyphAtlas _glyphAtlas;
  late final WebGpuFontResolver _fonts;
  late final WebGpuImageCache _images;

  // Not final: a device loss destroys all of these and a recovery rebuilds
  // them. The sink in particular is rebuilt rather than mutated, for the
  // reason every sibling target states: it holds the atlas texture ids as
  // final fields, and a recreated texture gets a new id.
  late WebGpuTexture _maskTexture;
  late WebGpuTexture _glyphTexture;
  late WebGpuLayerTargetPool _layerPool;
  late GpuLayerStack _layers;
  late GpuRasterSink _sink;
  late DisplayListPlayer _player;

  /// Creates the atlas textures and everything downstream of their ids.
  /// Shared by the constructor and by [_repopulateAtlasObjects]; a rebuild
  /// that drifted from the constructor would draw a frame that is subtly
  /// wrong instead of one that fails.
  void _buildAtlasObjects() {
    _maskTexture = _device.createTexture(
      width: _maskAtlas.width,
      height: _maskAtlas.height,
      format: GpuTextureFormat.alpha8,
      // Nearest: one texel per pixel by construction, and this filter is what
      // the CPU-parity claim rests on for every backend in this family.
      filter: GpuTextureFilter.nearest,
    );
    // Text is wired exactly as on the WebGL targets, and the symmetry is the
    // point that `webgl_canvas_target.dart` makes: a page is where text is
    // actually read.
    _glyphTexture = _device.createTexture(
      width: _glyphAtlas.width,
      height: _glyphAtlas.height,
      format: GpuTextureFormat.alpha8,
      filter: GpuTextureFilter.nearest,
    );
    _layerPool = WebGpuLayerTargetPool(device: _device);
    _layers = GpuLayerStack(
      allocator: _layerPool,
      backendName: WebGpuRendererBackend.backendName,
    );
    _sink = GpuRasterSink(
      batcher: _batcher,
      backendName: WebGpuRendererBackend.backendName,
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
  /// One entry more than the WebGL canvas target's: the canvas context's
  /// *configuration* names the device, so a recovered device must reconfigure
  /// it or every `getCurrentTexture` would answer textures of the dead one.
  /// The swap texture itself is still nobody's to recreate - the browser
  /// hands out a fresh one per composite.
  @override
  Iterable<GpuRecoverableResource> recoverableResources() sync* {
    yield CallbackGpuResource.fixed(
      resourceName: 'webgpu canvas atlases '
          '(mask ${_maskAtlas.width}x${_maskAtlas.height}, glyph '
          '${_glyphAtlas.width}x${_glyphAtlas.height})',
      recovery: GpuResourceRecovery.rebuilt,
      onDiscard: _discardAtlasObjects,
      onRepopulate: _repopulateAtlasObjects,
    );
    yield CallbackGpuResource.fixed(
      resourceName: 'webgpu canvas configuration',
      recovery: GpuResourceRecovery.recreated,
      // Nothing to discard: the dead configuration died with its device.
      onDiscard: _doNothing,
      onRepopulate: () => _configure(_context, _device),
    );
    yield* _images.recoverableResources();
  }

  static void _doNothing() {}

  void _discardAtlasObjects() {
    // The frame in flight goes with the device, for the sibling targets'
    // reason: its batches name textures the browser has reclaimed.
    _batcher.beginFrame();
    _submittedBatches = 0;
    _pendingClear = null;
    _layers.endFrame();
    _layerPool.forget();
    _device
      ..releaseTexture(_maskTexture)
      ..releaseTexture(_glyphTexture);
    // Both atlases are caches that outlive a frame; the mask atlas is the one
    // that is easy to miss - see `webgl_canvas_target.dart`.
    _maskAtlas.recycle();
    _glyphAtlas.clear();
  }

  BackendDiagnostic? _repopulateAtlasObjects() {
    try {
      _buildAtlasObjects();
    } on UnsupportedCapabilityError catch (error) {
      return BackendDiagnostic(
        kind: DiagnosticKind.incompatibleDevice,
        message: 'the recovered WebGPU device refused an atlas texture',
        detail: '$error',
      );
    }
    return _device.lastError;
  }

  /// How many batches of the current frame have already been drawn. See
  /// [GpuRasterSink.onAtlasFlush]: a batch drawn twice blends twice.
  int _submittedBatches = 0;

  /// The device this target draws through. Exposed so an owner that used
  /// [open] can dispose it and run recoveries on it.
  WebGpuRenderDevice get device => _device;

  /// The context, for an owner that reconfigures or tears down by hand.
  GPUCanvasContext get context => _context;

  WebGpuLayerTargetPool get layerPool => _layerPool;

  GpuGlyphAtlas get glyphAtlas => _glyphAtlas;

  /// `writeTexture` calls this target has made for glyph coverage. A frame
  /// that redraws the same text must not increase it.
  int get glyphUploadCount => _glyphUploadCount;
  int _glyphUploadCount = 0;

  WebGpuImageCache get images => _images;

  GpuBatcher get batcher => _batcher;

  WebGpuCanvasSurfaceDescriptor _surface;
  int? _pendingClear;

  int _generation = 0;
  int _observedLossCount = 0;
  int _observedCanvasGeneration;

  @override
  WebGpuCanvasSurfaceDescriptor get surface => _surface;

  @override
  int get generation {
    final int losses = _device.state.lossCount;
    if (losses != _observedLossCount) {
      _observedLossCount = losses;
      _generation++;
    }
    return _generation + _surface.generation.current;
  }

  /// Whether the canvas has been invalidated since this target last agreed
  /// with it. See `WebGlCanvasTarget.needsResize` - same field, same reason,
  /// same two indistinguishable [PresentStatus]es it disambiguates.
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
      // No framebuffer, truthfully: the pixels are in the canvas's swap
      // texture and never come back. See `Frame.cpuPixels`.
      damage: request.damage ?? _surfaceRect,
      generation: generation,
    );
  }

  /// Draws the recorded batches into the canvas's current swap texture.
  ///
  /// Never reads pixels back. The failure modes and their order are
  /// `WebGlCanvasTarget.present`'s, with one addition at the front: fetching
  /// the current texture can itself refuse - an unconfigured context, a
  /// zero-sized canvas - and that refusal is a named result, not a throw.
  /// There is no swap step at the end; the browser composites the texture
  /// when this task returns.
  @override
  Future<PresentResult> present(Frame frame) async {
    throwIfDisposed();
    final PresentResult? blocked = _device.state.blockedPresent();
    if (blocked != null) return blocked;
    if (frame.generation != generation) return _stale('before it was drawn');

    final GPUTextureView? view = _currentView();
    if (view == null) {
      return _device.state.blockedPresent() ??
          const PresentResult(
            status: PresentStatus.failed,
            diagnostic: BackendDiagnostic(
              kind: DiagnosticKind.surfaceCreationFailed,
              message: 'the canvas did not hand over its current texture',
              detail: 'getCurrentTexture threw. An unconfigured context or a '
                  'zero-sized canvas both do this; neither is a lost device',
            ),
          );
    }

    _uploadMaskAtlas();
    _uploadGlyphAtlas();

    final int? clear = _pendingClear;
    _pendingClear = null;
    final bool drawn = _device.submit(
      _batcher,
      _surface.pixelWidth,
      _surface.pixelHeight,
      clear,
      surfaceView: view,
      layers: _layers,
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
              message: 'the device was lost while the frame was being drawn',
            ),
          );
    }

    // Checked again, for `webgl_canvas_target.dart`'s stated reason: the
    // uploads and draws are the longest part of a frame and a resize during
    // them is the common case, not the exotic one.
    if (frame.generation != generation) {
      return _stale('after it was drawn');
    }

    final PresentResult? lost = _device.state.blockedPresent();
    if (lost != null) return lost;
    return const PresentResult(status: PresentStatus.presented);
  }

  /// The current swap texture's view, or null when the canvas refuses one.
  ///
  /// Stable within a task - a mid-frame flush and the final present see the
  /// same texture - which is what makes calling this per submission correct
  /// rather than wasteful. See `webgpu_interop.dart` on `getCurrentTexture`.
  GPUTextureView? _currentView() {
    try {
      return _context.getCurrentTexture().createView();
    } on Object {
      return null;
    }
  }

  /// Reconciles this target with a canvas that is now [pixelWidth] x
  /// [pixelHeight] physical pixels at [scale].
  ///
  /// **Writes `canvas.width` and `canvas.height`** - the one piece of DOM
  /// mutation this class does, for `WebGlCanvasTarget.resize`'s reasons, CSS
  /// size left alone included. The context's configuration survives a resize:
  /// WebGPU sizes each new swap texture from the canvas at `getCurrentTexture`
  /// time, so there is no reconfigure here.
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
    _surface = WebGpuCanvasSurfaceDescriptor(
      canvas: _surface.canvas,
      generation: _surface.generation,
      scale: scale,
    );
    _observedCanvasGeneration = _surface.generation.current;
  }

  /// Rasterises [list] into the canvas and presents it.
  ///
  /// Mirrors `WebGlCanvasTarget.renderDisplayList` argument for argument, so
  /// a caller - or a test - can swap the two targets and compare what
  /// happened, which is how the WebGPU path is checked against the path the
  /// parity suite covers.
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

  /// Sends the plots this frame wrote glyphs into, and nothing else - one
  /// `writeTexture` per dirty plot, so a static page uploads nothing after
  /// its first frame. Orientation: an atlas is *uploaded*, not rendered into;
  /// `writeTexture` puts the first row it is given at texture row `y`, the
  /// staging image is top-down, and on WebGPU even rendered targets share
  /// that orientation - see `wgsl_shaders.dart`.
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

  /// The backend's half of the atlas flush protocol. Upload first, because
  /// the batches about to be drawn sample texels that so far exist only in
  /// the staging image; submit second, and remember how far it got.
  void _flushAtlases() {
    _uploadMaskAtlas();
    _uploadGlyphAtlas();
    final GPUTextureView? view = _currentView();
    if (view == null) return;
    final int? clear = _pendingClear;
    _pendingClear = null;
    _device.submit(
      _batcher,
      _surface.pixelWidth,
      _surface.pixelHeight,
      clear,
      surfaceView: view,
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
              : 'the target was resized or the device was lost since the '
                  'frame began',
        ),
      );

  @override
  void onDispose() {
    _device.unregisterTarget(this);
    _images.clear();
    // After endFrame has returned every target: the pool only destroys what
    // is idle, so disposing mid-frame would take textures still in flight.
    _layers.endFrame();
    _layerPool.dispose();
    _device
      ..releaseTexture(_maskTexture)
      ..releaseTexture(_glyphTexture);
    _glyphAtlas.clear();
    _fonts.bind(null);
    // The canvas is not touched, and the context is left configured: both
    // belong with the element, the page owns the element, and unconfiguring
    // here would surprise a page that re-attaches a presenter to the same
    // canvas.
  }
}
