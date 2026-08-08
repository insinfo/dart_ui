/// The bridge from the display-list player to the GPU batcher.
///
/// This is the GPU counterpart of `cpu_renderer.dart`'s `_RasterizerSink`, and
/// deliberately the *only* new interpreter in the GPU path: the player still
/// walks the encoded list, still resolves transforms and clips into device
/// space, and still culls. Writing a second walker for the GPU would double
/// the number of places a transform-order bug can live, and the two would
/// diverge in exactly the cases nobody draws in a test.
///
/// The difference from the CPU sink is one word: it *batches* instead of
/// compositing. Nothing is drawn when a method here returns; a quad has been
/// appended to a vertex buffer and possibly merged into an open draw call.
/// The backend issues the draws at present time, which is what makes the
/// batching testable with no device attached.
///
/// ## Allocation
///
/// The rectangle path allocates nothing. Clipping is done on bare doubles
/// rather than through [Rect.intersect], because that would put one small
/// object per primitive on the hottest path in the renderer, and the batcher
/// below it was built specifically to avoid that. The mask path does allocate
/// - a [MaskQuad] and a [Path] for a rounded rectangle - and is allowed to:
/// it has already paid for a CPU rasterisation, so one object is noise.
library;

import 'dart:typed_data';

import '../../foundation/diagnostics.dart';
import '../../geometry/offset.dart';
import '../../geometry/path.dart';
import '../../geometry/rect.dart';
import '../../geometry/transform2d.dart';
import '../../graphics/display_list_opcodes.dart';
import '../raster/clip_stack.dart' show pixelEdge;
import '../replay/display_list_player.dart';
import 'gpu_batcher.dart';
import 'gpu_mask_atlas.dart';
import 'gpu_pipeline.dart';
import 'gpu_texture.dart';

/// Turns whatever the display list interned as an image into a texture.
///
/// An interface rather than a concrete cache because the answer is
/// device-specific: one backend uploads a `Framebuffer`, another wraps a
/// platform surface it never copied. The sink only needs to know whether
/// there is a texture and how big it is.
abstract interface class GpuImageResolver {
  /// The texture holding [image], or null if this device cannot draw it.
  GpuTextureHandle? resolve(Object image);
}

/// Batches the player's device-space primitives for a GPU backend.
final class GpuRasterSink implements RasterSink {
  GpuRasterSink({
    required this.batcher,
    required this.backendName,
    this.maskAtlas,
    this.maskTextureId = kNoTexture,
    this.imageResolver,
  }) : assert(
          maskAtlas == null || maskTextureId != kNoTexture,
          'a mask atlas needs a texture id, or every mask would batch as if '
          'it sampled nothing and the wrong texture would stay bound',
        );

  final GpuBatcher batcher;

  /// Named in every error this sink raises, per section 6.6.
  final String backendName;

  /// Where paths and rounded rectangles get their coverage. Null means this
  /// device draws rectangles and images only, and says so when asked for
  /// anything else instead of approximating it.
  final GpuMaskAtlas? maskAtlas;

  final int maskTextureId;

  final GpuImageResolver? imageResolver;

  int _layerDepth = 0;

  /// Nesting depth of unbalanced [beginLayer] calls. A backend can assert on
  /// it after a frame; a non-zero value means the player and this sink
  /// disagree, which would mean a clip is still in force.
  int get layerDepth => _layerDepth;

  // -------------------------------------------------------------------
  // Rectangles - the common case, and the one that never touches a texture
  // -------------------------------------------------------------------

  @override
  void fillDeviceRect(Rect deviceRect, Rect clip, ReplayPaint paint) {
    _requireFill(paint, 'rectangles');
    final alpha = (paint.argbColor >> 24) & 0xFF;
    if (alpha == 0) return;

    // Bare doubles: see the library comment on allocation.
    var left = deviceRect.left > clip.left ? deviceRect.left : clip.left;
    var top = deviceRect.top > clip.top ? deviceRect.top : clip.top;
    var right = deviceRect.right < clip.right ? deviceRect.right : clip.right;
    var bottom =
        deviceRect.bottom < clip.bottom ? deviceRect.bottom : clip.bottom;
    if (right <= left || bottom <= top) return;

    final double quadLeft;
    final double quadTop;
    final double quadRight;
    final double quadBottom;
    if (paint.antiAlias) {
      // The quad is snapped outward so the rasteriser visits every pixel the
      // shape touches even partially; the fragment stage then computes how
      // much of each it actually covers, from the unsnapped rect below.
      quadLeft = left.floorToDouble();
      quadTop = top.floorToDouble();
      quadRight = right.ceilToDouble();
      quadBottom = bottom.ceilToDouble();
    } else {
      // Hard edges, rounded exactly the way CpuRasterizer.fillRect rounds
      // them, so an aliased fill produces the same pixels on both backends.
      // Shape and quad coincide, which makes the shader's coverage 1 inside.
      left = pixelEdge(left).toDouble();
      top = pixelEdge(top).toDouble();
      right = pixelEdge(right).toDouble();
      bottom = pixelEdge(bottom).toDouble();
      if (right <= left || bottom <= top) return;
      quadLeft = left;
      quadTop = top;
      quadRight = right;
      quadBottom = bottom;
    }

    _setState(GpuPipelineKind.solid, kNoTexture, paint.blendMode, clip);
    batcher.addQuad(
      left: quadLeft,
      top: quadTop,
      right: quadRight,
      bottom: quadBottom,
      u0: 0,
      v0: 0,
      u1: 0,
      v1: 0,
      red: _channel(paint.argbColor, 16, alpha),
      green: _channel(paint.argbColor, 8, alpha),
      blue: _channel(paint.argbColor, 0, alpha),
      alpha: alpha / 255.0,
      shapeLeft: left,
      shapeTop: top,
      shapeRight: right,
      shapeBottom: bottom,
    );
  }

  // -------------------------------------------------------------------
  // Shapes that need coverage - through the mask atlas
  // -------------------------------------------------------------------

  @override
  void fillDeviceRRect(
    Rect deviceRect,
    Rect clip,
    Float32List deviceRadii,
    ReplayPaint paint,
  ) {
    _requireFill(paint, 'rounded rectangles');
    // Built as a path rather than given its own primitive, for the reason the
    // CPU sink gives: one implementation of a rounded rectangle instead of
    // two that can disagree about a corner. The radii already arrive in
    // device space and in the encoder's order, so the borrowed buffer is
    // consumed directly.
    final builder = PathBuilder()..addRoundedRectRadii(deviceRect, deviceRadii);
    _drawMask(
      builder.build(),
      Transform2D.identity,
      clip,
      paint,
      'rounded rectangle',
    );
  }

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
        'the GPU renderer rasterises Path objects into a coverage mask; got '
            '${path.runtimeType}',
      );
    }
    _requireFill(paint, 'paths');
    _drawMask(path, transform, clip, paint, 'path');
  }

  void _drawMask(
    Path path,
    Transform2D transform,
    Rect clip,
    ReplayPaint paint,
    String what,
  ) {
    final alpha = (paint.argbColor >> 24) & 0xFF;
    if (alpha == 0) return;

    final atlas = maskAtlas;
    if (atlas == null) {
      throw UnsupportedCapabilityError(
        backendName: backendName,
        capability: Capability.cpuPresentation,
        detail: 'this device has no coverage-mask atlas, so a $what cannot be '
            'antialiased; only axis-aligned rectangles and images are '
            'supported',
      );
    }

    final quad = atlas.rasterize(path, transform: transform, clip: clip);
    if (quad == null) {
      // Two causes, and only one is an error. An empty result means the shape
      // was clipped away, which is normal; a full atlas means the frame
      // cannot be drawn correctly, and drawing it wrong is worse than saying
      // so. Distinguished by whether the shape had any visible area at all.
      if (transform.transformRect(path.bounds).intersect(clip).isEmpty) return;
      throw UnsupportedCapabilityError(
        backendName: backendName,
        capability: Capability.cpuPresentation,
        detail: 'the ${atlas.width}x${atlas.height} coverage atlas is full or '
            'the $what is larger than it; mid-frame atlas flushing and mask '
            'tiling are not implemented',
      );
    }

    _setState(
      GpuPipelineKind.coverageMask,
      maskTextureId,
      paint.blendMode,
      clip,
    );
    final rect = quad.deviceRect;
    batcher.addQuad(
      left: rect.left,
      top: rect.top,
      right: rect.right,
      bottom: rect.bottom,
      u0: quad.u0,
      v0: quad.v0,
      u1: quad.u1,
      v1: quad.v1,
      red: _channel(paint.argbColor, 16, alpha),
      green: _channel(paint.argbColor, 8, alpha),
      blue: _channel(paint.argbColor, 0, alpha),
      alpha: alpha / 255.0,
      // The mask carries the coverage, so the analytic term must not also
      // apply: a shape rect equal to the quad evaluates to 1 everywhere.
      shapeLeft: rect.left,
      shapeTop: rect.top,
      shapeRight: rect.right,
      shapeBottom: rect.bottom,
    );
  }

  // -------------------------------------------------------------------
  // Images
  // -------------------------------------------------------------------

  @override
  void drawDeviceImage(
    Object image,
    Rect sourceRect,
    Rect deviceRect,
    Rect clip,
    ReplayPaint paint,
  ) {
    final resolver = imageResolver;
    final texture = resolver?.resolve(image);
    if (texture == null || !texture.isValid) {
      throw UnsupportedCapabilityError(
        backendName: backendName,
        capability: Capability.cpuPresentation,
        detail: texture == null
            ? 'no texture for ${image.runtimeType}; this device needs a '
                'GpuImageResolver that can upload it'
            : 'the texture for ${image.runtimeType} was invalidated, which '
                'means the device was lost since it was created',
      );
    }

    final left = deviceRect.left > clip.left ? deviceRect.left : clip.left;
    final top = deviceRect.top > clip.top ? deviceRect.top : clip.top;
    final right = deviceRect.right < clip.right ? deviceRect.right : clip.right;
    final bottom =
        deviceRect.bottom < clip.bottom ? deviceRect.bottom : clip.bottom;
    if (right <= left || bottom <= top) return;

    // The clip is folded into the *source* coordinates too, so a partially
    // clipped image samples the part of itself that survived rather than
    // squeezing the whole image into the visible box.
    final scaleU = (sourceRect.right - sourceRect.left) / deviceRect.width;
    final scaleV = (sourceRect.bottom - sourceRect.top) / deviceRect.height;
    final srcLeft = sourceRect.left + (left - deviceRect.left) * scaleU;
    final srcTop = sourceRect.top + (top - deviceRect.top) * scaleV;
    final srcRight = sourceRect.right - (deviceRect.right - right) * scaleU;
    final srcBottom = sourceRect.bottom - (deviceRect.bottom - bottom) * scaleV;

    final alpha = (paint.argbColor >> 24) & 0xFF;
    _setState(
      GpuPipelineKind.texturedImage,
      texture.id,
      paint.blendMode,
      clip,
    );
    batcher.addQuad(
      left: left,
      top: top,
      right: right,
      bottom: bottom,
      u0: srcLeft / texture.width,
      v0: srcTop / texture.height,
      u1: srcRight / texture.width,
      v1: srcBottom / texture.height,
      // Modulation only: an image is drawn at the paint's alpha and is not
      // tinted, so the colour channels stay at that alpha and the texture
      // supplies the colour.
      red: alpha / 255.0,
      green: alpha / 255.0,
      blue: alpha / 255.0,
      alpha: alpha / 255.0,
      shapeLeft: left,
      shapeTop: top,
      shapeRight: right,
      shapeBottom: bottom,
    );
  }

  // -------------------------------------------------------------------
  // Layers and text
  // -------------------------------------------------------------------

  @override
  void beginLayer(Rect deviceBounds, Rect clip, ReplayPaint paint) {
    // Nothing to do, and that is the same approximation the CPU sink makes:
    // the player has already intersected the layer's bounds into the clip it
    // passes with every primitive inside it, so a layer that is only a clip
    // is already handled. A layer with opacity or a blend mode of its own
    // needs a real offscreen pass - on this backend, a second framebuffer
    // object and a composite quad - and is deferred rather than silently
    // flattened. It is tracked here only so an unbalanced pair is visible.
    _layerDepth++;
  }

  @override
  void endLayer() {
    if (_layerDepth == 0) {
      throw StateError('endLayer() without a matching beginLayer()');
    }
    _layerDepth--;
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
      'text needs a shaper and a glyph atlas. The atlas half exists here - '
      'GpuMaskAtlas is exactly the alpha8 packer a glyph cache wants - so '
      'what is missing is the shaper and a glyph-to-outline source, not the '
      'GPU path',
    );
  }

  // -------------------------------------------------------------------
  // Helpers
  // -------------------------------------------------------------------

  /// Sets the batcher's state, rounding the clip outward into a scissor.
  ///
  /// Outward, not inward: the geometry above has already been intersected
  /// against the exact clip, so the scissor is a backstop against a shape
  /// whose quad was snapped out past it, and a scissor that rounded inward
  /// would eat the antialiased fringe of a fractional clip edge.
  void _setState(
    GpuPipelineKind pipeline,
    int textureId,
    int blendMode,
    Rect clip,
  ) {
    batcher.setState(
      pipeline: pipeline,
      textureId: textureId,
      blendMode: blendMode,
      scissorLeft: clip.left.floor(),
      scissorTop: clip.top.floor(),
      scissorRight: clip.right.ceil(),
      scissorBottom: clip.bottom.ceil(),
    );
  }

  /// One premultiplied colour channel of a non-premultiplied 0xAARRGGBB, in
  /// 0..1. See `gpu_pipeline.dart` for why premultiplication happens here.
  static double _channel(int argb, int shift, int alpha) =>
      ((argb >> shift) & 0xFF) * alpha / (255.0 * 255.0);

  /// The filler produces the region an outline encloses, so a stroke-styled
  /// paint would come out as a solid shape where a border was asked for -
  /// wrong output that looks deliberate. Same refusal the CPU sink makes.
  void _requireFill(ReplayPaint paint, String what) {
    if (paint.style == paintStyleFill) return;
    throw UnsupportedCapabilityError(
      backendName: backendName,
      capability: Capability.cpuPresentation,
      detail: 'stroking is not implemented; a stroke-styled $what would be '
          'filled as its enclosed region',
    );
  }
}
