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
import 'dart:math' as math;
import 'dart:typed_data';

import '../foundation/diagnostics.dart';
import '../foundation/lifecycle.dart';
import '../geometry/offset.dart';
import '../geometry/path.dart';
import '../geometry/rect.dart';
import '../geometry/transform2d.dart';
import '../graphics/display_list.dart';
import '../graphics/display_list_opcodes.dart';
import '../graphics/display_list_reader.dart';
import '../text/typeface.dart';
import 'framebuffer.dart';
import 'path/coverage_span_sink.dart';
import 'path/fill_rule.dart';
import 'path/scanline_filler.dart';
import 'path/stroker.dart';
import 'raster/blend.dart';
import 'raster/clip_stack.dart' show pixelEdge;
import 'raster/rasterizer.dart';
import 'renderer.dart';
import 'replay/display_list_player.dart';
import 'text/glyph_cache.dart';
import 'text/glyph_raster.dart';

/// Bridges the player's device-space calls onto the rasteriser.
///
/// The player guarantees `clip` is non-empty and overlaps the primitive, but
/// only *overlaps* - so every call still applies it. Doing that here rather
/// than trusting the player keeps the rasteriser's clip stack the single
/// authority on what is on screen.
final class _RasterizerSink implements RasterSink {
  _RasterizerSink(this._rasterizer, this._resources, this._glyphs)
      : _spanSink = _CoverageToRasterizer(_rasterizer);

  final CpuRasterizer _rasterizer;

  /// Held only for [fontAt]. The player resolves paths and images itself but
  /// hands a glyph run's font through as an id, because a sink with no glyph
  /// rasterizer has no use for a face; see [ReplayResources.fontAt].
  final ReplayResources _resources;

  final GlyphCache _glyphs;

  /// Kept across draws: the filler holds the edge and accumulator buffers that
  /// must not be rebuilt per path.
  final ScanlineFiller _filler = ScanlineFiller();

  /// Kept for the same reason, and it matters more here: [PathStroker] grows a
  /// segment buffer and an output builder to the largest contour it has seen
  /// and then stops allocating, which a per-draw instance would throw away
  /// every time.
  ///
  /// Reuse, not a cache of finished outlines. That was measured rather than
  /// assumed: for a 200x100 rounded rectangle with an 8 px radius, stroking
  /// costs about 10 us and rasterising the outline it produces about 58 us,
  /// so an outline cache could remove at most a seventh of a stroked border -
  /// and for a plain rectangle, a fiftieth. Against that sits a keyed map, an
  /// eviction policy, and unbounded retention of outlines for shapes that
  /// resize every frame. The 58 us is where the time is, and `span` below
  /// says what to do about it (one rasteriser call per scanline). A cache
  /// here would be optimising the cheap half.
  final PathStroker _stroker = PathStroker();

  final _CoverageToRasterizer _spanSink;

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
  void fillDeviceRect(Rect deviceRect, Rect clip, ReplayPaint paint) {
    _requireFillStyle(paint, 'rectangle');
    _fillClipped(deviceRect, clip, paint);
  }

  @override
  void fillDeviceRRect(
    Rect deviceRect,
    Rect clip,
    Float32List deviceRadii,
    ReplayPaint paint,
  ) {
    _requireFillStyle(paint, 'rounded rectangle');
    // Through the path filler rather than a special-case span loop in the
    // rasteriser. The filler already antialiases by exact area, so the corners
    // come out at the same quality as every other curve, and there is one
    // implementation of a rounded rectangle rather than two that can disagree.
    //
    // The radii arrive already in device space and in the encoder's order, so
    // addRoundedRectRadii consumes the borrowed scratch buffer directly and
    // the eight-value order is stated in one place instead of here.
    final builder = PathBuilder()..addRoundedRectRadii(deviceRect, deviceRadii);
    _spanSink.paint = paint;
    _filler.fill(builder.build(), clip, _spanSink);
  }

  /// Refuses a stroke on the primitives that cannot carry one.
  ///
  /// Stroking *is* implemented here - see [drawDevicePath] - but only where
  /// the local-to-device matrix comes with the geometry, because the paint's
  /// width is in local units. These primitives arrive already in device space
  /// with no matrix, so there is nothing to scale the width by, and filling
  /// them anyway would draw a solid block where a border was asked for: wrong
  /// output that looks deliberate.
  ///
  /// The player never sends a stroke-bearing style here (it rebuilds those
  /// shapes as centrelines), so this firing means a different producer drove
  /// the sink - which is exactly when a silent fill would be hardest to trace.
  void _requireFillStyle(ReplayPaint paint, String what) {
    if (paint.style == paintStyleFill) return;
    throw UnsupportedCapabilityError(
      backendName: 'cpu',
      capability: Capability.cpuPresentation,
      detail: 'stroking a device-space $what is not implemented: the stroke '
          'width is in local units and this call carries no transform to '
          'scale it by. Send the shape through drawDevicePath, which strokes',
    );
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
    if (path is! Path) {
      throw ArgumentError.value(
        path,
        'path',
        'the CPU renderer fills and strokes Path objects; got '
            '${path.runtimeType}',
      );
    }
    switch (paint.style) {
      case paintStyleFill:
        _fill(path, transform, clip, paint);
      case paintStyleStroke:
        _fill(_outlineOf(path, transform, paint), transform, clip, paint);
      case paintStyleFillAndStroke:
        // Order is load-bearing, not incidental. The stroke straddles the
        // centreline, so its inner half lies inside the region the fill
        // covers; drawing the fill second paints over that half and the
        // border comes out half as wide as it was asked for - and only on
        // the inside, so it also looks like a positioning bug.
        _fill(path, transform, clip, paint);
        _fill(_outlineOf(path, transform, paint), transform, clip, paint);
      default:
        throw UnsupportedCapabilityError(
          backendName: 'cpu',
          capability: Capability.cpuPresentation,
          detail: 'paint style ${paint.style} is not fill, stroke or '
              'fillAndStroke; this sink has no drawing for it',
        );
    }
  }

  /// Fills [path] under [transform], non-zero.
  ///
  /// The rule is stated rather than left to the filler's default because a
  /// stroke outline *requires* it: the inner side of a join crosses itself and
  /// a closed contour becomes two wound against each other, both of which
  /// even-odd would turn inside out. See `stroker.dart`.
  void _fill(Path path, Transform2D transform, Rect clip, ReplayPaint paint) {
    if (path.isEmpty) return;
    _spanSink.paint = paint;
    _filler.fill(
      path,
      clip,
      _spanSink,
      rule: FillRule.nonZero,
      transform: transform,
    );
  }

  /// The outline swept by the pen along [path], in [path]'s own coordinates.
  ///
  /// Stroking happens *before* the transform, which is what makes a stroke
  /// scale with the shape it outlines: a 2 px border under a 2x scale is four
  /// device pixels, the same as every other length in the subtree. Stroking
  /// after would need an inverse-transformed width, and under a non-uniform
  /// scale there is no single width to use - the pen there is an ellipse.
  ///
  /// A width that is zero, negative or not finite comes back as an empty path
  /// and draws nothing. That is the stroker's contract and the right one: a
  /// width animating through zero is not a programming error the frame can do
  /// anything about, and it is a stroke of no width, not a hairline.
  ///
  /// Cap, join and miter limit take [StrokeStyle]'s defaults because the
  /// display list has no operand for them; see `ReplayPaint.strokeWidth`.
  Path _outlineOf(Path path, Transform2D transform, ReplayPaint paint) {
    // The stroker's tolerance is in local units and the error it allows is
    // magnified by the transform, so a curve stroked inside a 4x scale would
    // come out at four times the intended deviation - visible faceting on a
    // zoomed-in border. Dividing by the scale spends the same tenth of a
    // device pixel at every zoom level.
    final double scale = _maxAxisScale(transform);
    return _stroker.stroke(
      path,
      StrokeStyle(width: paint.strokeWidth),
      tolerance: scale > 0 && scale.isFinite
          ? kDefaultStrokeTolerance / scale
          : kDefaultStrokeTolerance,
    );
  }

  /// The larger of the two factors a unit length is scaled by, which is the
  /// one that has to be budgeted for.
  static double _maxAxisScale(Transform2D t) {
    final double x = math.sqrt(t.a * t.a + t.b * t.b);
    final double y = math.sqrt(t.c * t.c + t.d * t.d);
    return x > y ? x : y;
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

  /// Draws a shaped run as one cached coverage mask per glyph.
  ///
  /// Three decisions are worth stating, because each is a place text goes
  /// subtly wrong and looks like a font bug rather than a positioning one.
  ///
  /// The **baseline snaps to a whole pixel** and the **pen's x does not**.
  /// Horizontal subpixel positioning is what keeps letter spacing even (see
  /// `glyph_cache.dart`), while vertical subpixel positioning would only blur
  /// the horizontal stems that carry a Latin face's legibility - and would
  /// multiply the cache by another four buckets to do it. Every engine that
  /// renders horizontal text makes this same asymmetric choice.
  ///
  /// The **font is scaled by the transform**, not the mask. Scaling a mask
  /// resamples an antialiased edge and produces the soft, muddy text that
  /// gives bitmap font caches their reputation; rasterizing the outline at the
  /// device size is the whole reason an outline was kept. The player has
  /// already applied the transform to the pen positions, so only the size is
  /// left to carry.
  ///
  /// A **rotated or skewed** transform is refused rather than approximated.
  /// The glyph rasterizer takes a scale and a subpixel offset, so text under
  /// such a matrix would silently come out upright - a wrong picture that
  /// looks deliberate.
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
    final Object resource = _resources.fontAt(fontId);
    if (resource is! ScaledTypeface) {
      throw ArgumentError.value(
        resource,
        'font',
        'the CPU renderer rasterizes ScaledTypeface faces; got '
            '${resource.runtimeType}',
      );
    }
    // Not [_requireFillStyle]: this call does carry a transform, so the reason
    // is a different one. Stroked text needs the glyph's *outline* to hand to
    // the stroker, and what this sink has is a cached alpha8 coverage mask -
    // outlining that would trace the antialiased edge of a bitmap, which is
    // the classic "furry text" artefact rather than a stroke.
    if (paint.style != paintStyleFill) {
      throw UnsupportedCapabilityError(
        backendName: 'cpu',
        capability: Capability.cpuPresentation,
        detail: 'stroked text is not implemented; the glyph cache stores '
            'coverage masks, and the stroker needs the outline the mask was '
            'rasterized from',
      );
    }
    final int argb = paint.argbColor;
    // A fully transparent run still costs a rasterization per glyph if it is
    // not stopped here, and invisible text is common: a fade at t = 0.
    if ((argb >> 24) & 0xFF == 0) return;

    final ScaledTypeface font = _deviceFont(resource, transform);

    _rasterizer
      ..save()
      ..clipRect(clip);
    for (var i = 0; i < glyphCount; i++) {
      final double penX = deviceOrigin.dx + deviceOffsets[i * 2];
      final double penY = deviceOrigin.dy + deviceOffsets[i * 2 + 1];
      final GlyphMask mask = _glyphs.maskFor(
        font,
        glyphIds[i],
        subpixelBucket: glyphSubpixelBucket(penX),
      );
      if (mask.isEmpty) continue;
      // The mask's own left/top are offsets from the pen, and top is negative
      // because a glyph rises above the baseline.
      _rasterizer.blendCoverageMask(
        mask.coverage,
        mask.width,
        mask.height,
        glyphPixelOrigin(penX) + mask.left,
        pixelEdge(penY) + mask.top,
        argb,
      );
    }
    _rasterizer.restore();
  }

  /// [font] at the size the device transform asks for.
  ///
  /// Returns [font] itself at unit scale, so the common case - no device pixel
  /// ratio, or one already folded into the layout - allocates nothing and hits
  /// the cache under the key the caller interned.
  ScaledTypeface _deviceFont(ScaledTypeface font, Transform2D transform) {
    final double a = transform.a;
    final double d = transform.d;
    if (transform.b != 0 || transform.c != 0 || a <= 0 || d <= 0 || a != d) {
      throw UnsupportedCapabilityError(
        backendName: 'cpu',
        capability: Capability.cpuPresentation,
        detail: 'text under a rotated, skewed, mirrored or non-uniformly '
            'scaled transform is not implemented; the glyph rasterizer takes '
            'a uniform scale, and drawing this run would silently produce '
            'upright text (transform $transform)',
      );
    }
    if (a == 1) return font;
    return ScaledTypeface(font.typeface, font.pixelSize * a);
  }
}

/// Turns coverage spans into composited pixels.
///
/// A span is already whole pixels with its antialiasing carried as a coverage
/// byte, so folding that byte into the paint's alpha and asking for a hard
/// fill on integer bounds is exactly right - no second antialiasing pass, and
/// no new compositor. `mul255` is the same rounding the filler used, which is
/// what makes a full-coverage span composite bit-identically to a rect fill.
///
/// One fill call per span is the cost. Spans are per-scanline runs rather than
/// per-pixel, so this is on the order of the shape's height; a public
/// span-level entry point on the rasteriser would remove even that, and is the
/// obvious next optimisation if paths ever show up in a profile.
final class _CoverageToRasterizer implements CoverageSpanSink {
  _CoverageToRasterizer(this._rasterizer);

  final CpuRasterizer _rasterizer;

  /// Set immediately before each fill. Mutable on purpose: a sink allocated
  /// per draw would put an allocation on the path-drawing path.
  ReplayPaint? paint;

  @override
  void span(int y, int xStart, int xEnd, int coverage) {
    final current = paint;
    if (current == null) return;
    final argb = current.argbColor;
    final alpha = mul255((argb >> 24) & 0xFF, coverage);
    if (alpha == 0) return;
    _rasterizer.fillRect(
      Rect.fromLTRB(
        xStart.toDouble(),
        y.toDouble(),
        xEnd.toDouble(),
        (y + 1).toDouble(),
      ),
      (alpha << 24) | (argb & 0x00FFFFFF),
    );
  }
}

/// Rasterises [list] directly into an existing [framebuffer].
///
/// This is the shared CPU drawing path for owned memory targets and native
/// framebuffers such as a Win32 DIB section. Keeping the adapter here avoids a
/// full-frame staging copy and, more importantly, prevents platform backends
/// from growing their own subtly different display-list players.
///
/// [glyphCache] defaults to [GlyphCache.shared], because a cache that did not
/// outlive the frame would rasterize every glyph again on the next one.
void rasterizeDisplayList(
  DisplayList list,
  Framebuffer framebuffer, {
  int? clearColor,
  Rect? damage,
  Transform2D deviceTransform = Transform2D.identity,
  GlyphCache? glyphCache,
}) {
  if (clearColor != null) {
    final blue = clearColor & 0xFF;
    final green = (clearColor >> 8) & 0xFF;
    final red = (clearColor >> 16) & 0xFF;
    final alpha = (clearColor >> 24) & 0xFF;
    if (damage == null) {
      framebuffer.clear(blue, green, red, alpha);
    } else {
      framebuffer.clearRect(damage, blue, green, red, alpha);
    }
  }
  final rasterizer = CpuRasterizer(framebuffer);
  final resources = DisplayListResources(list);
  DisplayListPlayer(
    _RasterizerSink(rasterizer, resources, glyphCache ?? GlyphCache.shared),
  ).play(
    DisplayListReader(list),
    resources,
    deviceBounds: (damage ??
            Rect.fromLTWH(
              0,
              0,
              framebuffer.width.toDouble(),
              framebuffer.height.toDouble(),
            ))
        .intersect(Rect.fromLTWH(
      0,
      0,
      framebuffer.width.toDouble(),
      framebuffer.height.toDouble(),
    )),
    deviceTransform: deviceTransform,
  );
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
    GlyphCache? glyphCache,
  }) async {
    final frame = beginFrame(const FrameRequest());
    rasterizeDisplayList(
      list,
      frame.framebuffer,
      clearColor: clearColor,
      deviceTransform: deviceTransform,
      glyphCache: glyphCache,
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
            'pure Dart scanline path with antialiasing; text renders through '
            'the same filler, cached as alpha8 glyph masks',
          ),
        ],
      );

  @override
  bool supportsSurface(NativeSurfaceDescriptor surface) =>
      surface is MemorySurfaceDescriptor;

  @override
  Future<RenderDevice> createDevice() async => CpuRenderDevice();
}
