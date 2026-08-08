/// The CPU renderer: a display list in, pixels out, on every platform.
///
/// This is where the two halves meet. [DisplayListPlayer] walks the encoded
/// list and resolves transforms and clips into device space; [CpuRasterizer]
/// turns device-space primitives into bytes. Neither knows about the other -
/// the player emits to a [RasterSink] and this file is the adapter - which is
/// what let both be built and tested independently.
///
/// It is also the backend that makes everything above it testable. A golden
/// test does not need a window, a GPU or a display server: it asks for a
/// memory surface and compares bytes.
library;

import 'dart:async';
import 'dart:typed_data';

import '../foundation/diagnostics.dart';
import '../foundation/lifecycle.dart';
import '../geometry/offset.dart';
import '../geometry/rect.dart';
import '../geometry/transform2d.dart';
import '../graphics/display_list.dart';
import '../graphics/display_list_reader.dart';
import 'framebuffer.dart';
import 'raster/rasterizer.dart';
import 'renderer.dart';
import 'replay/display_list_player.dart';

/// Bridges the player's device-space calls onto the rasteriser.
///
/// The player guarantees `clip` is non-empty and overlaps the primitive, but
/// only *overlaps* - so every call still applies it. Doing that here rather
/// than trusting the player keeps the rasteriser's clip stack the single
/// authority on what is on screen.
final class _RasterizerSink implements RasterSink {
  _RasterizerSink(this._rasterizer);

  final CpuRasterizer _rasterizer;

  void _fillClipped(Rect deviceRect, Rect clip, ReplayPaint paint) {
    final visible = deviceRect.intersect(clip);
    if (visible.isEmpty) return;
    // The intersection happens in double space, so a clipped edge arrives here
    // fractional and comes out soft. Antialiasing everything is the right
    // default for a UI: the shapes are axis-aligned most of the time, where
    // coverage is exact and the interior spans take the same loop the hard
    // fill takes, so the cost is confined to boundary pixels.
    //
    // paint.antiAlias exists to turn it OFF - for a caller who has measured
    // that a particular fill is on a hot path and lands on integer bounds
    // anyway, where the two produce identical bytes.
    if (paint.antiAlias) {
      _rasterizer.fillRectAntiAliased(visible, paint.argbColor);
    } else {
      _rasterizer.fillRect(visible, paint.argbColor);
    }
  }

  @override
  void fillDeviceRect(Rect deviceRect, Rect clip, ReplayPaint paint) =>
      _fillClipped(deviceRect, clip, paint);

  @override
  void fillDeviceRRect(
    Rect deviceRect,
    Rect clip,
    Float32List deviceRadii,
    ReplayPaint paint,
  ) {
    // Square corners for now. Filling the bounding box is wrong at the
    // corners, but it is wrong by a documented amount rather than silently:
    // the radii are carried all the way here, so the rasteriser growing a
    // rounded-rect span loop is the only change needed.
    _fillClipped(deviceRect, clip, paint);
  }

  @override
  void beginLayer(Rect deviceBounds, Rect clip, ReplayPaint paint) {
    // A layer with no offscreen buffer behind it is just a clip. That is
    // correct for opaque, source-over layers and wrong for a layer with
    // opacity or a blend mode, which needs compositing after the fact.
    _rasterizer
      ..save()
      ..clipRect(deviceBounds.intersect(clip));
  }

  @override
  void endLayer() => _rasterizer.restore();

  @override
  void drawDevicePath(
    Object path,
    Transform2D transform,
    Rect clip,
    ReplayPaint paint,
  ) {
    throw UnimplementedError(
      'the CPU rasteriser has no path filler yet; paths reach here as opaque '
      'objects and need a scanline edge list',
    );
  }

  @override
  void drawDeviceImage(
    Object image,
    Rect sourceRect,
    Rect deviceRect,
    Rect clip,
    ReplayPaint paint,
  ) {
    if (image is! Framebuffer) {
      throw ArgumentError.value(
        image,
        'image',
        'the CPU renderer draws Framebuffer images; got ${image.runtimeType}',
      );
    }
    // Clipping is the rasteriser's job here: it walks rows anyway, so folding
    // the clip into the blit costs nothing extra.
    _rasterizer
      ..save()
      ..clipRect(clip)
      ..drawFramebuffer(image, deviceRect)
      ..restore();
  }

  @override
  void drawDeviceGlyphRun(
    int fontId,
    Offset deviceOrigin,
    Transform2D transform,
    Int32List glyphIds,
    Float32List deviceOffsets,
    int glyphCount,
    Rect clip,
    ReplayPaint paint,
  ) {
    throw UnimplementedError(
      'text needs a shaper and a glyph atlas; the run reaches here already '
      'positioned in device space, so the atlas is the only missing piece',
    );
  }
}

/// A render target backed by plain memory.
final class MemoryRenderTarget with DisposableMixin implements RenderTarget {
  MemoryRenderTarget(MemorySurfaceDescriptor surface)
      : _surface = surface,
        _framebuffer = Framebuffer.allocate(
          width: surface.pixelWidth,
          height: surface.pixelHeight,
          format: surface.format,
        );

  MemorySurfaceDescriptor _surface;
  Framebuffer _framebuffer;
  int _generation = 0;

  @override
  void onDispose() {}

  /// The last presented pixels. Golden tests read this.
  Framebuffer get framebuffer => _framebuffer;

  @override
  NativeSurfaceDescriptor get surface => _surface;

  @override
  int get generation => _generation;

  @override
  Frame beginFrame(FrameRequest request) {
    throwIfDisposed();
    final clear = request.clearColor;
    if (clear != null) {
      _framebuffer.clear(
        clear & 0xFF,
        (clear >> 8) & 0xFF,
        (clear >> 16) & 0xFF,
        (clear >> 24) & 0xFF,
      );
    }
    return Frame(
      target: this,
      framebuffer: _framebuffer,
      damage: request.damage ??
          Rect.fromLTWH(
            0,
            0,
            _framebuffer.width.toDouble(),
            _framebuffer.height.toDouble(),
          ),
      generation: _generation,
    );
  }

  @override
  Future<PresentResult> present(Frame frame) async {
    throwIfDisposed();
    // Rejecting rather than drawing is the whole reason Frame carries a
    // generation: a resize between beginFrame and present means these pixels
    // describe a surface that no longer exists.
    if (frame.generation != _generation) {
      return const PresentResult(
        status: PresentStatus.stale,
        diagnostic: BackendDiagnostic.note(
          'frame belonged to a previous generation of the target',
        ),
      );
    }
    return const PresentResult(status: PresentStatus.presented);
  }

  @override
  void resize(int pixelWidth, int pixelHeight, double scale) {
    throwIfDisposed();
    if (pixelWidth == _framebuffer.width &&
        pixelHeight == _framebuffer.height &&
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
    _framebuffer = Framebuffer.allocate(
      width: pixelWidth,
      height: pixelHeight,
      format: _surface.format,
    );
  }

  /// Rasterises [list] into this target and presents it.
  ///
  /// The convenience that makes a golden test three lines long instead of
  /// thirty.
  Future<PresentResult> renderDisplayList(
    DisplayList list, {
    int? clearColor,
    Transform2D deviceTransform = Transform2D.identity,
  }) async {
    final frame = beginFrame(FrameRequest(clearColor: clearColor));
    final rasterizer = CpuRasterizer(frame.framebuffer);
    DisplayListPlayer(_RasterizerSink(rasterizer)).play(
      DisplayListReader(list),
      DisplayListResources(list),
      deviceBounds: Rect.fromLTWH(
        0,
        0,
        frame.framebuffer.width.toDouble(),
        frame.framebuffer.height.toDouble(),
      ),
      deviceTransform: deviceTransform,
    );
    return present(frame);
  }
}

final class CpuRenderDevice with DisposableMixin implements RenderDevice {
  @override
  void onDispose() {}

  @override
  RendererInfo get info => const RendererInfo(
        name: 'cpu',
        deviceDescription: 'software scanline rasteriser',
      );

  @override
  RendererCapabilities get capabilities => const RendererCapabilities(
        // Honest answers, not aspirational ones. Partial present is true
        // because a memory target simply does not clear what it was not asked
        // to; msaa and compute are false because there is no path to them from
        // a scanline filler.
        supportsPartialPresent: true,
        supportsMsaa: false,
        supportsCompute: false,
        supportsExternalTextures: false,
        supportsLinearColor: false,
        maxTextureSize: 1 << 16,
        formats: {
          PixelFormat.bgra8888Premultiplied,
          PixelFormat.rgba8888Premultiplied,
        },
      );

  @override
  bool get isLost => false;

  @override
  RenderTarget createTarget(NativeSurfaceDescriptor surface) {
    throwIfDisposed();
    if (surface is! MemorySurfaceDescriptor) {
      throw UnsupportedCapabilityError(
        backendName: 'cpu',
        capability: Capability.cpuPresentation,
        detail: 'the CPU renderer presents to memory surfaces, not '
            '${surface.kind}',
      );
    }
    return MemoryRenderTarget(surface);
  }
}

/// Always available: it has no library to load and no device to lose.
final class CpuRendererBackend implements RendererBackend {
  const CpuRendererBackend();

  @override
  RendererInfo get info => const RendererInfo(
        name: 'cpu',
        deviceDescription: 'software scanline rasteriser',
      );

  @override
  BackendProbeResult probe() => BackendProbeResult(
        backendName: 'cpu',
        supported: true,
        capabilities: const {
          Capability.cpuPresentation,
          Capability.partialPresent,
        },
        diagnostics: const [
          BackendDiagnostic.note(
            'pure Dart; no antialiasing, no path filling and no text yet',
          ),
        ],
      );

  @override
  bool supportsSurface(NativeSurfaceDescriptor surface) =>
      surface is MemorySurfaceDescriptor;

  @override
  Future<RenderDevice> createDevice() async => CpuRenderDevice();
}
