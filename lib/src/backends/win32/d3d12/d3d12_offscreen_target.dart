/// A Direct3D 12 target that renders into a texture and reads it back.
///
/// This is the target the parity test uses, and the reason it exists is the
/// reason `GlOffscreenTarget` exists: a GPU backend whose only output is a
/// window can be asserted about only by a human looking at a screen. Rendering
/// into a committed texture and copying it into a [Framebuffer] makes the whole
/// path - device, root signature, pipeline state, barriers, fence - comparable
/// against the CPU rasteriser pixel for pixel, on a build machine, with no
/// display.
///
/// It reads its pixels back on present, which section 23 of the roadmap forbids
/// for a *production* GPU backend. That rule is about presenting to a screen;
/// [D3d12WindowTarget] is the target it is about, and it does not read
/// anything back. An offscreen target whose only consumer is a test or an image
/// export has nowhere else to put the pixels.
///
/// ## The readback is where the fence stops being optional
///
/// A copy into a readback buffer is a GPU operation. Mapping that buffer and
/// reading it on the CPU before the GPU has performed the copy returns whatever
/// was there before - usually zeros on the first frame and the *previous*
/// frame's image afterwards, which is the kind of wrong that looks like a
/// one-frame lag in the renderer rather than a missing wait. So [present] ends
/// with `end(waitForCompletion: true)`, and that is the one place in this
/// backend where blocking on the GPU is correct rather than a bug.
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
import '../../../rendering/gpu/gpu_batcher.dart';
import '../../../rendering/gpu/gpu_glyph_atlas.dart';
import '../../../rendering/gpu/gpu_mask_atlas.dart';
import '../../../rendering/gpu/gpu_raster_sink.dart';
import '../../../rendering/gpu/gpu_texture.dart';
import '../../../rendering/renderer.dart';
import '../../../rendering/replay/display_list_player.dart';
import 'd3d12_com.dart';
import 'd3d12_device.dart';
import 'd3d12_interfaces.dart';
import 'd3d12_structs.dart';

/// A render target backed by a texture, read back into a [Framebuffer].
final class D3d12OffscreenTarget with DisposableMixin implements RenderTarget {
  D3d12OffscreenTarget(this._device, MemorySurfaceDescriptor surface)
      : _surface = surface {
    _maskAtlas = GpuMaskAtlas();
    _maskTexture = _device.createTexture(
      width: _maskAtlas.width,
      height: _maskAtlas.height,
      format: GpuTextureFormat.alpha8,
      // One texel per pixel by construction, so point sampling reproduces the
      // CPU rasteriser's coverage byte exactly and linear would blur it.
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
      // No layer stack: this device refuses a saveLayer that needs a real
      // offscreen pass, by name, rather than flattening it. See the scope
      // section of d3d12_device.dart.
      onAtlasFlush: _flushAtlases,
    );
    _player = DisplayListPlayer(_sink);
    _createSurfaceObjects();
  }

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

  MemorySurfaceDescriptor _surface;
  D3d12Texture? _colorTexture;
  late Framebuffer _readback;
  int _renderTargetView = 0;
  Pointer<Void> _readbackBuffer = nullptr;
  int _readbackRowPitch = 0;
  int _generation = 0;
  int _observedLossCount = 0;
  int _submittedBatches = 0;
  int? _pendingClear;
  bool _recording = false;

  /// The last pixels read back. Golden and parity tests read this after
  /// [present].
  Framebuffer get framebuffer => _readback;

  GpuBatcher get batcher => _batcher;

  /// The textures this target uploaded for drawn images.
  D3d12ImageCache get images => _images;

  /// The glyph coverage this target keeps between frames.
  GpuGlyphAtlas get glyphAtlas => _glyphAtlas;

  @override
  NativeSurfaceDescriptor get surface => _surface;

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
    // The command list is opened here rather than in present because the
    // display list is played in between, and an image drawn for the first time
    // uploads a texture - which is a copy that has to land on this frame's
    // list, not on one opened after the draws that sample it.
    _recording = _device.frames.begin() != null;
    if (!_recording && !_device.isLost) {
      _device.markLost('the frame command list could not be opened');
    }
    _batcher.beginFrame();
    _maskAtlas.beginFrame();
    _glyphAtlas.beginFrame();
    _submittedBatches = 0;
    _pendingClear = request.clearColor;
    return Frame(
      target: this,
      framebuffer: _readback,
      damage: request.damage ??
          Rect.fromLTWH(
            0,
            0,
            _readback.width.toDouble(),
            _readback.height.toDouble(),
          ),
      generation: generation,
    );
  }

  @override
  Future<PresentResult> present(Frame frame) async {
    throwIfDisposed();
    final PresentResult? blocked = _device.state.blockedPresent();
    if (blocked != null) {
      if (_recording) {
        _device.frames.abandon();
        _recording = false;
      }
      return blocked;
    }
    if (frame.generation != generation) {
      if (_recording) {
        _device.frames.abandon();
        _recording = false;
      }
      return const PresentResult(
        status: PresentStatus.stale,
        diagnostic: BackendDiagnostic.note(
          'frame belonged to a previous generation of the target',
        ),
      );
    }
    if (!_recording) {
      return const PresentResult(
        status: PresentStatus.deviceLost,
        diagnostic: BackendDiagnostic(
          kind: DiagnosticKind.connectionFailed,
          message: 'no command list was open for this frame',
        ),
      );
    }

    _uploadMaskAtlas();
    _uploadGlyphAtlas();

    final int? clear = _pendingClear;
    _pendingClear = null;
    final bool drawn = _device.submit(
      _batcher,
      _readback.width,
      _readback.height,
      clear,
      renderTargetView: _renderTargetView,
      firstBatch: _submittedBatches,
    );
    _submittedBatches = _batcher.batchCount;

    final D3d12Texture? colour = _colorTexture;
    if (drawn && colour != null) {
      _device.copyRenderTargetToBuffer(
        colour,
        _readbackBuffer,
        _readbackRowPitch,
      );
    }

    _recording = false;
    // The one blocking wait in this backend, and the reason it is right is in
    // the library comment: the bytes are read on the CPU on the next line.
    final bool finished = _device.frames.end(waitForCompletion: true);
    if (!finished) {
      _device.markLost('the frame did not complete on the GPU');
      return _device.state.blockedPresent()!;
    }
    if (drawn) _readPixels();

    return _device.state.blockedPresent() ??
        const PresentResult(status: PresentStatus.presented);
  }

  /// Copies the readback buffer into [_readback], swizzling if the caller
  /// asked for BGRA.
  ///
  /// No row flip. Direct3D writes render-target row 0 at the top and a
  /// `CopyTextureRegion` preserves that order, so the buffer is already
  /// top-down like every [Framebuffer]. The GL backend has to flip here and
  /// this one must not - see the orientation section of `d3d12_shaders.dart`.
  void _readPixels() {
    final int width = _readback.width;
    final int height = _readback.height;
    final D3d12Resource resource = D3d12Resource(_readbackBuffer);
    final Pointer<D3d12Range> range =
        _device.library.allocator.allocate<D3d12Range>(sizeOf<D3d12Range>());
    final Pointer<Pointer<Void>> mapped = _device.library.allocator
        .allocate<Pointer<Void>>(sizeOf<Pointer<Void>>());
    range.ref
      ..begin = 0
      ..end = _readbackRowPitch * height;
    try {
      if (comFailed(resource.map(range, mapped))) {
        _device.markLost('the readback buffer could not be mapped');
        return;
      }
      final source = mapped.value.cast<Uint8>().asTypedList(range.ref.end);
      final bool swizzle =
          _readback.format == PixelFormat.bgra8888Premultiplied;
      for (var y = 0; y < height; y++) {
        final int sourceRow = y * _readbackRowPitch;
        final int destinationRow = y * _readback.bytesPerRow;
        if (!swizzle) {
          _readback.pixels.setRange(
            destinationRow,
            destinationRow + width * 4,
            source,
            sourceRow,
          );
          continue;
        }
        for (var x = 0; x < width; x++) {
          final int s = sourceRow + x * 4;
          final int d = destinationRow + x * 4;
          _readback.pixels[d] = source[s + 2];
          _readback.pixels[d + 1] = source[s + 1];
          _readback.pixels[d + 2] = source[s];
          _readback.pixels[d + 3] = source[s + 3];
        }
      }
      // A zero-length written range: the CPU only read.
      range.ref
        ..begin = 0
        ..end = 0;
      resource.unmap(range);
    } finally {
      _device.library.allocator
        ..free(range)
        ..free(mapped);
    }
  }

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

  /// Sends the plots the frame wrote into, and nothing else.
  ///
  /// The atlas is **uploaded**, not rendered into, so no orientation question
  /// arises: `CopyTextureRegion` writes the first row of the footprint at
  /// texture row `y`, and [GpuGlyphAtlas.pixels] is row-major top-down, so
  /// atlas row `y` is texture row `y` is texture coordinate `y / height` -
  /// which is exactly the `v` `gpu_raster_sink.dart` computes for the top edge
  /// of a glyph's quad.
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

  /// `CopyTextureRegion` calls this target has made for glyph coverage.
  int get glyphUploadCount => _glyphUploadCount;
  int _glyphUploadCount = 0;

  /// The backend's half of the atlas flush protocol - see
  /// [GpuRasterSink.onAtlasFlush].
  ///
  /// Upload first: the batches about to be drawn sample texels this frame
  /// wrote, which so far exist only in the atlas's staging image. Submit
  /// second, and remember how far it got, because the sink is about to hand
  /// those texels to a different mask.
  void _flushAtlases() {
    if (!_recording) return;
    _uploadMaskAtlas();
    _uploadGlyphAtlas();
    final int? clear = _pendingClear;
    _pendingClear = null;
    _device.submit(
      _batcher,
      _readback.width,
      _readback.height,
      clear,
      renderTargetView: _renderTargetView,
      firstBatch: _submittedBatches,
    );
    _submittedBatches = _batcher.batchCount;
  }

  @override
  void resize(int pixelWidth, int pixelHeight, double scale) {
    throwIfDisposed();
    if (pixelWidth == _readback.width &&
        pixelHeight == _readback.height &&
        scale == _surface.scale) {
      return;
    }
    _generation++;
    _surface = MemorySurfaceDescriptor(
      pixelWidth: pixelWidth,
      pixelHeight: pixelHeight,
      scale: scale,
      format: _surface.format,
    );
    // Everything below is a resource the GPU may still be reading, so the wait
    // is not optional and is not the fence ring's job to guess at.
    _device.frames.waitIdle();
    _destroySurfaceObjects();
    _createSurfaceObjects();
  }

  /// Rasterises [list] into this target and presents it.
  ///
  /// Mirrors `MemoryRenderTarget.renderDisplayList` and
  /// `GlOffscreenTarget.renderDisplayList` argument for argument, so a
  /// differential test can swap one for another and compare.
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
        _readback.width.toDouble(),
        _readback.height.toDouble(),
      ),
      deviceTransform: deviceTransform,
    );
    return present(frame);
  }

  void _createSurfaceObjects() {
    _readback = Framebuffer.allocate(
      width: _surface.pixelWidth,
      height: _surface.pixelHeight,
      format: _surface.format,
    );
    final D3d12Texture? colour = _device.createRenderTargetTexture(
      _surface.pixelWidth,
      _surface.pixelHeight,
    );
    if (colour == null) {
      _device.markLost(
        'the offscreen colour texture could not be created',
        detail: '${_surface.pixelWidth}x${_surface.pixelHeight}',
      );
      return;
    }
    _colorTexture = colour;
    _renderTargetView = _device.allocateRenderTargetView();
    _device.createRenderTargetView(
        _device.resourceOf(colour), _renderTargetView);

    _readbackRowPitch =
        alignUp(_surface.pixelWidth * 4, d3d12TextureDataPitchAlignment);
    _readbackBuffer = _device.createReadbackBuffer(
      _readbackRowPitch * _surface.pixelHeight,
    );
    if (_readbackBuffer == nullptr) {
      _device.markLost('the readback buffer could not be created');
    }
  }

  void _destroySurfaceObjects() {
    if (_renderTargetView != 0) {
      _device.releaseRenderTargetView(_renderTargetView);
      _renderTargetView = 0;
    }
    final D3d12Texture? colour = _colorTexture;
    // Nullable, and checked, because `_createSurfaceObjects` returns early
    // when the device refuses the texture. A `late` field would turn a device
    // that could not allocate into a LateInitializationError during teardown -
    // an error about the wrong thing, raised at the point where it is hardest
    // to attribute.
    if (colour != null) _device.releaseTexture(colour);
    _colorTexture = null;
    _readbackBuffer = releaseCom(_readbackBuffer);
  }

  @override
  void onDispose() {
    if (_recording) {
      _device.frames.abandon();
      _recording = false;
    }
    _device.frames.waitIdle();
    _destroySurfaceObjects();
    _images.clear();
    _device
      ..releaseTexture(_maskTexture)
      ..releaseTexture(_glyphTexture);
    // The staging bytes go with the texture: keeping the entries would say a
    // glyph is resident in a texture that no longer exists.
    _glyphAtlas.clear();
    _fonts.bind(null);
  }
}
