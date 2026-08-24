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
/// ## Layers are real here, and that changes the coordinate space
///
/// `beginLayer` used to increment a counter and nothing else, which flattened
/// every layer's opacity and blend mode in silence - the failure mode section
/// 6.6 exists to forbid, and the worst kind, because a half-transparent panel
/// drawn fully opaque looks like a paint bug rather than a renderer bug.
///
/// A layer that needs one now gets an offscreen target from [layerStack], and
/// everything inside it is written in **layer space**: the layer's whole-pixel
/// top-left corner is subtracted from every quad and every scissor. That is
/// the `_originX`/`_originY` pair threaded through the methods below, it is
/// zero outside a layer, and it is the reason each geometry path subtracts
/// before it writes rather than after. See `gpu_layer_stack.dart` for why the
/// origin is whole pixels and why the target is only layer-sized.
///
/// ## Allocation
///
/// The rectangle path allocates nothing. Clipping is done on bare doubles
/// rather than through [Rect.intersect], because that would put one small
/// object per primitive on the hottest path in the renderer, and the batcher
/// below it was built specifically to avoid that. The mask path does allocate
/// - a result object and a [Path] for a rounded rectangle - and is allowed to:
/// it has already paid for a CPU rasterisation, so one object is noise.
///
/// The glyph path allocates nothing per glyph once the atlas is warm: a hit
/// returns a [GlyphAtlasEntry] the atlas already owns, and the quad is written
/// from bare doubles. A *miss* allocates, and pays for a rasterisation while
/// it is at it - see `gpu_glyph_atlas.dart` for why misses stop happening.
///
/// Layers allocate on push and on pop and are not on the per-primitive path;
/// the tiling loop for an oversized mask allocates and runs only for a shape
/// larger than the whole atlas.
library;

import 'dart:typed_data';

import '../../foundation/diagnostics.dart';
import '../../geometry/offset.dart';
import '../../geometry/path.dart';
import '../../geometry/rect.dart';
import '../../geometry/transform2d.dart';
import '../../graphics/display_list_opcodes.dart';
import '../../text/typeface.dart';
import '../path/fill_rule.dart';
import '../path/stroker.dart';
import '../raster/clip_stack.dart' show pixelEdge;
import '../replay/display_list_player.dart';
import '../text/glyph_cache.dart' show glyphPixelOrigin, glyphSubpixelBucket;
import '../text/glyph_raster.dart'
    show glyphMasksFit, glyphOutlineTransform;
import 'gpu_batcher.dart';
import 'gpu_glyph_atlas.dart';
import 'gpu_layer_stack.dart';
import 'gpu_mask_atlas.dart';
import 'gpu_path_dispatch.dart';
import 'gpu_path_planning.dart';
import 'gpu_path_strategy.dart';
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

/// Turns the display list's interned font id into a face at a size.
///
/// The player hands the sink a raw `fontId` rather than a face, because it
/// positions a run without ever asking what a glyph looks like (see
/// [ReplayResources.fontAt]). A backend that draws text holds those resources
/// anyway, so resolving is one method; a backend that does not should not be
/// handed a face it has no rasteriser for.
abstract interface class GpuFontResolver {
  /// The face and size interned under [fontId], or null when this device
  /// cannot draw with it.
  ScaledTypeface? resolveFont(int fontId);
}

/// Batches the player's device-space primitives for a GPU backend.
///
/// ## Gradients, and why the marker moved here from the player
///
/// [GradientRasterSink] used to be the player's gate: a sink that did not
/// implement it never saw a gradient paint at all. That was the right shape
/// while *no* GPU backend could draw one, and the wrong shape the moment one
/// could, because the answer is no longer a property of this class - it is a
/// property of the device and of the pass a particular draw lands in. An
/// OpenGL context with the sparse executor can draw a gradient path; the same
/// class on a device without it cannot.
///
/// So the marker is declared here and the refusal moved *inside*: a gradient
/// that no route accepts raises [UnsupportedCapabilityError] naming the
/// backend and saying what was missing. That is strictly more informative than
/// the player's message and keeps the invariant it existed to protect - a
/// gradient is drawn as a gradient or refused out loud, and is never quietly
/// flattened to the paint's fallback colour.
final class GpuRasterSink implements RasterSink, GradientRasterSink {
  GpuRasterSink({
    required this.batcher,
    required this.backendName,
    this.maskAtlas,
    this.maskTextureId = kNoTexture,
    this.imageResolver,
    this.glyphAtlas,
    this.glyphTextureId = kNoTexture,
    this.fontResolver,
    this.onAtlasFlush,
    this.layerStack,
    this.pathPlanningTelemetry,
    this.pathCommandRecorder,
  })  : assert(
          maskAtlas == null || maskTextureId != kNoTexture,
          'a mask atlas needs a texture id, or every mask would batch as if '
          'it sampled nothing and the wrong texture would stay bound',
        ),
        assert(
          glyphAtlas == null || glyphTextureId != kNoTexture,
          'a glyph atlas needs a texture id of its own; sharing the mask '
          'atlas\'s id would batch text and paths together and sample '
          'whichever texture happened to be bound',
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

  /// Where glyph coverage lives between frames. Null means this device draws
  /// no text and says so when asked, rather than dropping the run.
  final GpuGlyphAtlas? glyphAtlas;

  final int glyphTextureId;

  final GpuFontResolver? fontResolver;

  /// Where a `saveLayer` that needs an offscreen pass gets one.
  ///
  /// Null means this device cannot open a layer that composites - and says so
  /// by name when the display list asks for one. That refusal is the whole
  /// point of the field: the previous behaviour was to flatten the layer,
  /// which drew a translucent subtree at full opacity and reported nothing.
  ///
  /// A layer with alpha 255 and source-over is still handled without a stack,
  /// because compositing one back is the identity - see [GpuLayerStack.push]
  /// for the single stated exception, which this sink refuses by name.
  final GpuLayerStack? layerStack;

  /// Called when an atlas has no room for something the frame still needs.
  ///
  /// The hook that makes a full atlas recoverable instead of fatal, and it is
  /// one hook for both atlases because both need the same thing done. A
  /// handler must, in this order:
  ///
  ///   1. upload every dirty region of both atlases - the draw calls about to
  ///      be issued sample texels this frame wrote and the textures do not
  ///      have them yet;
  ///   2. issue the draw calls the batcher has recorded so far, and remember
  ///      how far it got, because the rest of the frame will be submitted
  ///      afterwards and a batch drawn twice blends twice.
  ///
  /// This sink closes the batcher's open batch **before** calling it, so that
  /// nothing merges into a draw call the handler has already issued, and it
  /// calls `markUploaded` on both atlases and recycles the one that was full
  /// **after** the handler returns. Then it retries exactly once: the atlas is
  /// empty and the shape was already known to fit one, so a second failure is
  /// a bug rather than pressure, and it is reported as one.
  ///
  /// Null - the default - means a full atlas is a named error instead. That is
  /// deliberate: a backend that has not wired the flush cycle cannot silently
  /// drop half a paragraph or half a frame's shapes.
  final void Function()? onAtlasFlush;

  /// Optional advisory planning for real path draws.
  ///
  /// It cannot change execution: every observed draw still continues through
  /// [_drawMask]. This is the safe rollout seam for comparing A/sparse/B/C/D
  /// decisions before any incomplete executor is allowed to affect pixels.
  final GpuPathPlanningTelemetry? pathPlanningTelemetry;

  /// Optional transactional bridge from the selector to ordered vector work.
  ///
  /// It is deliberately separate from telemetry: planning may be enabled to
  /// measure candidates while this remains null. A recorder can only promote
  /// a candidate after retaining a complete command; refusal or failure keeps
  /// the established coverage-atlas path below as the pixel-producing route.
  final GpuPathCommandRecorder? pathCommandRecorder;

  int _layerDepth = 0;

  /// Nesting depth of unbalanced [beginLayer] calls. A backend can assert on
  /// it after a frame; a non-zero value means the player and this sink
  /// disagree, which would mean a clip is still in force.
  int get layerDepth => _layerDepth;

  /// The layer origin every quad and scissor below is written against. Zero
  /// outside a layer, and always a whole pixel inside one.
  double _originX = 0;
  double _originY = 0;

  /// The same origin as integers, for the glyph path, which is integral end to
  /// end and must stay that way: a fractional shift there would break the
  /// one-texel-per-pixel mapping the coverage was rasterised for.
  int _originIntX = 0;
  int _originIntY = 0;

  /// Converts a centreline stroke to the same fillable outline the CPU sink
  /// uses. The resulting path then follows the ordinary GPU mask-atlas route;
  /// no backend-specific stroke shader or tessellator is required.
  final PathStroker _stroker = PathStroker();

  /// Whether a *flattened* layer stands between the primitives being drawn now
  /// and the nearest real offscreen target.
  ///
  /// It is the guard for the one case where flattening an opaque source-over
  /// layer is not an identity: a primitive inside it drawn with `plus` or
  /// `src` blends against the parent's pixels, where an isolating renderer
  /// would have blended it against transparency. See [_setState], which
  /// refuses that combination by name rather than drawing a picture that is
  /// wrong in a way that looks deliberate.
  bool _isolationBroken = false;

  /// The value of [_isolationBroken] outside each open layer. A list because
  /// layers nest; it grows to the deepest layer a process ever opens and then
  /// stops, and it is never touched on the per-primitive path.
  final List<bool> _isolationStack = <bool>[];

  // -------------------------------------------------------------------
  // Rectangles - the common case, and the one that never touches a texture
  // -------------------------------------------------------------------

  @override
  void fillDeviceRect(Rect deviceRect, Rect clip, ReplayPaint paint) {
    _requireFill(paint, 'rectangles');
    if (paint.gradient != null) {
      // The solid pipeline modulates one vertex colour; there is nowhere in it
      // for a ramp. A gradient rectangle is therefore drawn as a *path*, which
      // is the route that has a gradient material - the same route a gradient
      // rounded rectangle already took. The coverage is identical either way:
      // the scanline filler's analytic area for an axis-aligned rectangle is
      // the same quantity `boxCoverage` computes in the fragment shader.
      final builder = PathBuilder()..addRect(deviceRect);
      _drawMask(
        builder.build(),
        Transform2D.identity,
        clip,
        paint,
        'gradient rectangle',
      );
      return;
    }
    final alpha = (paint.argbColor >> 24) & 0xFF;
    if (alpha == 0) return;

    // Bare doubles: see the library comment on allocation.
    var left = deviceRect.left > clip.left ? deviceRect.left : clip.left;
    var top = deviceRect.top > clip.top ? deviceRect.top : clip.top;
    var right = deviceRect.right < clip.right ? deviceRect.right : clip.right;
    var bottom =
        deviceRect.bottom < clip.bottom ? deviceRect.bottom : clip.bottom;
    if (right <= left || bottom <= top) return;

    // Into layer space. Zero outside a layer, so the common case pays two
    // subtractions of a constant the compiler has in a register.
    left -= _originX;
    top -= _originY;
    right -= _originX;
    bottom -= _originY;

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
    switch (paint.style) {
      case paintStyleFill:
        _drawMask(
          path,
          transform,
          clip,
          paint,
          'path',
          rule: _fillRule(paint),
        );
        break;
      case paintStyleStroke:
        _drawMask(
          _stroker.stroke(path, StrokeStyle(width: paint.strokeWidth)),
          transform,
          clip,
          paint,
          'path stroke',
        );
        break;
      case paintStyleFillAndStroke:
        _drawMask(
          path,
          transform,
          clip,
          paint,
          'path fill',
          rule: _fillRule(paint),
        );
        _drawMask(
          _stroker.stroke(path, StrokeStyle(width: paint.strokeWidth)),
          transform,
          clip,
          paint,
          'path stroke',
        );
        break;
      default:
        throw UnsupportedCapabilityError(
          backendName: backendName,
          capability: Capability.gpuPresentation,
          detail: 'paint style ${paint.style} is not fill, stroke or '
              'fillAndStroke',
        );
    }
  }

  /// Rasterises [path] into the mask atlas and batches the quad that samples
  /// it, running the atlas's flush protocol and its tiling recipe when it has
  /// to.
  ///
  /// The four answers [GpuMaskAtlas.rasterizeMask] can give are four different
  /// situations and each gets its own reaction here. Collapsing them into
  /// "null means no quad" - which the older `rasterize` shim does, and which
  /// this used to call - failed the whole frame over an atlas that was merely
  /// out of room, and could not tell that from a shape that was off-screen.
  void _drawMask(
    Path path,
    Transform2D transform,
    Rect clip,
    ReplayPaint paint,
    String what, {
    FillRule rule = FillRule.nonZero,
  }) {
    final bool hasGradient = paint.gradient != null;
    final alpha = (paint.argbColor >> 24) & 0xFF;
    // A gradient carries its own alpha in the ramp, so the paint's alpha
    // channel says nothing about whether it is visible - the CPU replay reads
    // the ramp for a gradient too. Only a solid fill can be skipped here.
    if (alpha == 0 && !hasGradient) return;

    final atlas = maskAtlas;
    if (atlas == null) {
      throw UnsupportedCapabilityError(
        backendName: backendName,
        capability: Capability.gpuPresentation,
        detail: 'this device has no coverage-mask atlas, so a $what cannot be '
            'antialiased; only axis-aligned rectangles and images are '
            'supported',
      );
    }

    final Rect visible = transform.transformRect(path.bounds).intersect(clip);
    final GpuPathPlanningTelemetry? planning = pathPlanningTelemetry;
    final GpuPathPlanningProposal? proposal =
        planning == null || visible.isEmpty
            ? null
            : planning.plan(
                label: what,
                path: path,
                localToTarget: transform,
                clip: clip,
                fillRule: rule,
                denseMaskCacheHit: atlas.containsMask(
                  path,
                  transform: transform,
                  clip: clip,
                  rule: rule,
                ),
                // What the paint asks for decides which routes are *correct*
                // for this draw, as opposed to merely cheaper - see
                // [GpuPathDrawTraits].
                traits: GpuPathDrawTraits(
                  antiAlias: paint.antiAlias,
                  hasGradient: hasGradient,
                ),
              );

    if (proposal != null) {
      var executed = GpuPathStrategy.coverageAtlas;
      final GpuPathCommandRecorder? recorder = pathCommandRecorder;
      final GpuPathStrategy candidate = proposal.candidate.strategy;
      if (recorder != null &&
          candidate != GpuPathStrategy.coverageAtlas &&
          candidate != GpuPathStrategy.analyticPrimitive) {
        // A command at this batch index must not merge a later dense quad into
        // the batch that precedes it. Closing is harmless on refusal: it can
        // cost one draw call, but it can never change pixels.
        batcher.flush();
        try {
          final accepted = recorder.tryRecord(
            GpuPathDispatchRequest(
              proposal: proposal,
              path: path,
              localToTarget: transform,
              clip: clip,
              fillRule: rule,
              paint: paint,
              batchIndex: batcher.batchCount,
            ),
          );
          if (accepted) executed = candidate;
        } catch (_) {
          // Experimental dispatch is never allowed to make the universal
          // dense path unavailable. Diagnostics remain available through the
          // recorder and planning telemetry owned by the backend.
        }
      }
      planning!.complete(proposal, executedStrategy: executed);
      if (executed != GpuPathStrategy.coverageAtlas) return;
    }
    // Everything below rasterises coverage into an alpha8 atlas and modulates
    // it by one colour, which is a picture a gradient does not have. Reaching
    // here with one means no route accepted it, and the honest answer is to
    // say so rather than to fill the shape with the paint's fallback colour -
    // a flat shape where a ramp was asked for reads as a paint bug, not a
    // renderer limitation.
    if (hasGradient) {
      throw UnsupportedCapabilityError(
        backendName: backendName,
        capability: Capability.gpuPresentation,
        detail: 'a gradient $what could not be routed to a shader that samples '
            'a ramp: ${paint.gradient}. The dense coverage atlas stores one '
            'alpha per texel and modulates it by a single colour, so drawing '
            'it here would produce a flat fill. This device needs the sparse '
            'strip executor and a gradient cache '
            '(enableExperimentalSparseStrips), or the paint has a shader '
            'transform that cannot be inverted.',
      );
    }
    var result = atlas.rasterizeMask(
      path,
      transform: transform,
      clip: clip,
      rule: rule,
    );
    if (result.status == MaskRasterStatus.needsFlush) {
      _flushAtlases(atlas, null, 'a $what');
      result = atlas.rasterizeMask(
        path,
        transform: transform,
        clip: clip,
        rule: rule,
      );
      if (result.status == MaskRasterStatus.needsFlush) {
        // Documented as impossible on [MaskRasterStatus.needsFlush]: the atlas
        // was emptied and the shape was already known to fit an empty one. A
        // caller that looped here would spin forever issuing draw calls.
        throw StateError(
          '$backendName: the ${atlas.width}x${atlas.height} coverage atlas '
          'reported needsFlush twice for the same $what. The retry runs on an '
          'empty atlas, so this is a bug in gpu_mask_atlas.dart, not '
          'pressure - looping here would issue draw calls forever.',
        );
      }
    }

    // Clipped away, degenerate or non-finite: normal, and nothing to draw.
    if (result.status == MaskRasterStatus.empty) return;
    // Larger than an empty atlas. Flushing cannot help; tiling can.
    if (result.status == MaskRasterStatus.tooLarge) {
      _drawMaskTiled(atlas, path, transform, clip, paint, what, alpha, rule);
      return;
    }
    _batchMask(result, clip, paint, alpha);
  }

  /// Draws a shape larger than the whole atlas as several masks, one per tile.
  ///
  /// ## Tiling, and not a CPU fallback
  ///
  /// [MaskRasterStatus.tooLarge] leaves a caller two options and only one of
  /// them exists here. "Fall back to the CPU" means rasterising the shape into
  /// a surface - and this sink has no surface. The pixels it produced would
  /// have to be uploaded as a texture and drawn as a quad, which is the same
  /// upload and the same quad tiling does, plus a full-size allocation and
  /// minus the atlas's cache. The GPU backend renders on the GPU; there is
  /// nowhere to fall back *to* without inventing a second compositor.
  ///
  /// Tiling is also the recipe `gpu_mask_atlas.dart` documents on that
  /// constant and verifies with a test: the clip is part of a mask's identity,
  /// and the scanline filler clamps edges outside the clip onto its boundary
  /// rather than dropping them, so tile by tile the coverage is exactly what
  /// one impossible full-size mask would have carried. The seams are seams in
  /// the *quads*, not in the coverage.
  ///
  /// The tile budget is [GpuMaskAtlas.maxMaskWidth] by
  /// [GpuMaskAtlas.maxMaskHeight] - the largest mask the atlas can hold - and
  /// the count is bounded because the shape is clipped first: a tiled shape
  /// can never need more tiles than the clip rectangle covers. [_maxMaskTiles]
  /// bounds it anyway, by name, because a clip the size of a wall display and
  /// a small atlas is a configuration this would otherwise spend a second in.
  void _drawMaskTiled(
    GpuMaskAtlas atlas,
    Path path,
    Transform2D transform,
    Rect clip,
    ReplayPaint paint,
    String what,
    int alpha,
    FillRule rule,
  ) {
    final Rect visible = transform.transformRect(path.bounds).intersect(clip);
    if (visible.isEmpty) return;
    final int tileWidth = atlas.maxMaskWidth;
    final int tileHeight = atlas.maxMaskHeight;
    if (tileWidth <= 0 || tileHeight <= 0) {
      throw UnsupportedCapabilityError(
        backendName: backendName,
        capability: Capability.gpuPresentation,
        detail: 'the ${atlas.width}x${atlas.height} coverage atlas cannot hold '
            'a mask of any size, so a $what cannot be tiled either',
      );
    }

    final double left = visible.left.floorToDouble();
    final double top = visible.top.floorToDouble();
    final double right = visible.right.ceilToDouble();
    final double bottom = visible.bottom.ceilToDouble();
    final int columns = ((right - left) / tileWidth).ceil();
    final int rows = ((bottom - top) / tileHeight).ceil();
    if (columns * rows > _maxMaskTiles) {
      throw UnsupportedCapabilityError(
        backendName: backendName,
        capability: Capability.gpuPresentation,
        detail: 'a $what covering ${right - left}x${bottom - top} device '
            'pixels needs ${columns * rows} tiles of ${tileWidth}x$tileHeight '
            'out of the ${atlas.width}x${atlas.height} coverage atlas, over '
            'the limit of $_maxMaskTiles; a shape this large against an atlas '
            'this small is a configuration mistake, not a drawing',
      );
    }

    for (var y = top; y < bottom; y += tileHeight) {
      for (var x = left; x < right; x += tileWidth) {
        final double tileRight = x + tileWidth < right ? x + tileWidth : right;
        final double tileBottom =
            y + tileHeight < bottom ? y + tileHeight : bottom;
        // Whole-pixel tiles, so each mask is at most the budget and no tile
        // boundary falls inside a pixel - a fractional split would rasterise
        // the same pixel twice and blend its coverage twice.
        final Rect tile = Rect.fromLTRB(x, y, tileRight, tileBottom);
        var result = atlas.rasterizeMask(path,
            transform: transform, clip: tile, rule: rule);
        if (result.status == MaskRasterStatus.needsFlush) {
          _flushAtlases(atlas, null, 'a tile of a $what');
          result = atlas.rasterizeMask(
            path,
            transform: transform,
            clip: tile,
            rule: rule,
          );
        }
        if (result.status == MaskRasterStatus.empty) continue;
        if (!result.isOk) {
          throw StateError(
            '$backendName: a ${tileWidth}x$tileHeight tile of a $what came '
            'back as ${result.status.name} from a '
            '${atlas.width}x${atlas.height} atlas whose own budget says a '
            'mask that size fits. That is a bug in gpu_mask_atlas.dart.',
          );
        }
        _batchMask(result, clip, paint, alpha);
      }
    }
  }

  FillRule _fillRule(ReplayPaint paint) => switch (paint.fillRule) {
        pathFillRuleNonZero => FillRule.nonZero,
        pathFillRuleEvenOdd => FillRule.evenOdd,
        _ => throw UnsupportedCapabilityError(
            backendName: backendName,
            capability: Capability.gpuPresentation,
            detail: 'unknown path fill rule ${paint.fillRule}',
          ),
      };

  /// Writes the quad that samples a finished mask.
  void _batchMask(
    MaskRasterResult result,
    Rect clip,
    ReplayPaint paint,
    int alpha,
  ) {
    _setState(
      GpuPipelineKind.coverageMask,
      maskTextureId,
      paint.blendMode,
      clip,
    );
    final rect = result.deviceRect;
    final double left = rect.left - _originX;
    final double top = rect.top - _originY;
    final double right = rect.right - _originX;
    final double bottom = rect.bottom - _originY;
    batcher.addQuad(
      left: left,
      top: top,
      right: right,
      bottom: bottom,
      u0: result.u0,
      v0: result.v0,
      u1: result.u1,
      v1: result.v1,
      red: _channel(paint.argbColor, 16, alpha),
      green: _channel(paint.argbColor, 8, alpha),
      blue: _channel(paint.argbColor, 0, alpha),
      alpha: alpha / 255.0,
      // The mask carries the coverage, so the analytic term must not also
      // apply: a shape rect equal to the quad evaluates to 1 everywhere.
      shapeLeft: left,
      shapeTop: top,
      shapeRight: right,
      shapeBottom: bottom,
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
    _refuseGradient(
      paint,
      'a drawn image',
      'drawImage uses the image pixels as its source rather than a geometry '
          'shader, so the two colours would have to be combined by a rule the '
          'display list does not encode',
    );
    final resolver = imageResolver;
    final texture = resolver?.resolve(image);
    if (texture == null || !texture.isValid) {
      throw UnsupportedCapabilityError(
        backendName: backendName,
        capability: Capability.gpuPresentation,
        detail: texture == null
            ? 'no texture for ${image.runtimeType}; this device needs a '
                'GpuImageResolver that can upload it'
            : 'the texture for ${image.runtimeType} was invalidated, which '
                'means the device was lost since it was created',
      );
    }

    var left = deviceRect.left > clip.left ? deviceRect.left : clip.left;
    var top = deviceRect.top > clip.top ? deviceRect.top : clip.top;
    var right = deviceRect.right < clip.right ? deviceRect.right : clip.right;
    var bottom =
        deviceRect.bottom < clip.bottom ? deviceRect.bottom : clip.bottom;
    if (right <= left || bottom <= top) return;

    // Same two-rectangle treatment [fillDeviceRect] gives a solid fill, and
    // for the same reason. Handing the fragment stage a shape rect equal to a
    // *fractional* quad makes `boxCoverage` return a fraction on every edge
    // pixel the rasteriser did visit, and zero on the ones it did not - so an
    // image at x = 10.3 loses its leftmost column and darkens the next one.
    // That reads as a seam between two adjacent images, which is exactly what
    // a scrolled list of thumbnails is.
    //
    // The source mapping below is taken in *device* coordinates, so the layer
    // origin is subtracted only after it has been computed - subtracting first
    // would shift the sampled region of the image by the layer's position.
    final double deviceQuadLeft;
    final double deviceQuadTop;
    final double deviceQuadRight;
    final double deviceQuadBottom;
    if (paint.antiAlias) {
      deviceQuadLeft = left.floorToDouble();
      deviceQuadTop = top.floorToDouble();
      deviceQuadRight = right.ceilToDouble();
      deviceQuadBottom = bottom.ceilToDouble();
    } else {
      left = pixelEdge(left).toDouble();
      top = pixelEdge(top).toDouble();
      right = pixelEdge(right).toDouble();
      bottom = pixelEdge(bottom).toDouble();
      if (right <= left || bottom <= top) return;
      deviceQuadLeft = left;
      deviceQuadTop = top;
      deviceQuadRight = right;
      deviceQuadBottom = bottom;
    }

    // The clip is folded into the *source* coordinates too, so a partially
    // clipped image samples the part of itself that survived rather than
    // squeezing the whole image into the visible box. The mapping is taken at
    // the *quad's* corners, not the shape's: the snap above moved them, and
    // reusing the shape's texture coordinates there would stretch the image
    // by up to a pixel per edge.
    final scaleU = (sourceRect.right - sourceRect.left) / deviceRect.width;
    final scaleV = (sourceRect.bottom - sourceRect.top) / deviceRect.height;
    final srcLeft =
        sourceRect.left + (deviceQuadLeft - deviceRect.left) * scaleU;
    final srcTop = sourceRect.top + (deviceQuadTop - deviceRect.top) * scaleV;
    final srcRight =
        sourceRect.right - (deviceRect.right - deviceQuadRight) * scaleU;
    final srcBottom =
        sourceRect.bottom - (deviceRect.bottom - deviceQuadBottom) * scaleV;

    final alpha = (paint.argbColor >> 24) & 0xFF;
    _setState(
      GpuPipelineKind.texturedImage,
      texture.id,
      paint.blendMode,
      clip,
    );
    batcher.addQuad(
      left: deviceQuadLeft - _originX,
      top: deviceQuadTop - _originY,
      right: deviceQuadRight - _originX,
      bottom: deviceQuadBottom - _originY,
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
      // The unsnapped rect: the difference between it and the quad above is
      // the antialiased fringe.
      shapeLeft: left - _originX,
      shapeTop: top - _originY,
      shapeRight: right - _originX,
      shapeBottom: bottom - _originY,
    );
  }

  // -------------------------------------------------------------------
  // Layers
  // -------------------------------------------------------------------

  /// Opens a layer, switching to an offscreen pass when one is needed.
  ///
  /// Three outcomes, and [GpuLayerStack] decides which:
  ///
  ///   * an **empty** layer allocates nothing - the player still delivers the
  ///     pair so that a stack stays balanced;
  ///   * a **flattened** layer (alpha 255, source-over) draws straight into
  ///     the parent, because compositing it back is the identity;
  ///   * anything else takes a target, and every primitive until the matching
  ///     [endLayer] is written in that target's coordinates.
  ///
  /// The batcher's open batch is closed first in the last case, or the layer's
  /// first quad would merge into a batch belonging to the parent's pass and be
  /// drawn into the parent's target.
  ///
  /// With no [layerStack] this refuses a layer it cannot draw, by name. The
  /// old behaviour - increment a counter, draw the subtree at full opacity -
  /// is the silent flattening section 6.6 forbids, and it is invisible: the
  /// frame renders, it just renders the wrong picture.
  @override
  void beginLayer(Rect deviceBounds, Rect clip, ReplayPaint paint) {
    _refuseGradient(
      paint,
      'a saveLayer composite',
      'a layer is composited with one opacity and one blend mode, and a ramp '
          'is neither',
    );
    final int alpha = (paint.argbColor >> 24) & 0xFF;
    final int blendMode = paint.blendMode;
    final GpuLayerStack? stack = layerStack;

    if (stack == null) {
      final bool composites =
          !(alpha == 0xFF && blendMode == blendModeSrcOver) &&
              !deviceBounds.isEmpty;
      if (composites) {
        throw UnsupportedCapabilityError(
          backendName: backendName,
          capability: Capability.gpuPresentation,
          detail: 'a layer with alpha $alpha and blend mode $blendMode needs '
              'an offscreen pass, and this device was built with no '
              'GpuLayerStack. Drawing its contents into the parent instead '
              'would apply neither the opacity nor the blend mode and would '
              'report nothing, which is why it is refused here. Pass a '
              'GpuLayerStack with a target allocator.',
        );
      }
      _layerDepth++;
      _isolationStack.add(_isolationBroken);
      if (!deviceBounds.isEmpty) _isolationBroken = true;
      return;
    }

    final GpuLayer layer = stack.push(
      deviceBounds: deviceBounds,
      clip: clip,
      alpha: alpha,
      blendMode: blendMode,
      batchIndex: batcher.batchCount,
    );
    _layerDepth++;
    _isolationStack.add(_isolationBroken);
    switch (layer.kind) {
      case GpuLayerKind.empty:
        break;
      case GpuLayerKind.flattened:
        _isolationBroken = true;
      case GpuLayerKind.offscreen:
        _isolationBroken = false;
        // Only here, and after the push rather than before it - flushing
        // closes the open batch and does not change the batch *count*, so the
        // pass boundary is the same either way. A layer that is only a clip
        // must not cost a draw call break: `gpu_batcher.dart` promises that
        // one batches exactly like a clip, and it still does.
        batcher.flush();
        _setOrigin(stack.originX, stack.originY);
    }
  }

  /// Closes the innermost layer and composites it.
  ///
  /// The composite is one textured quad in the parent's pass: the layer's
  /// target sampled at one texel per pixel, modulated by the layer's opacity
  /// in all four channels - the texture is premultiplied, so that is a scale
  /// and not a tint - and blended with the layer's own blend mode. It is
  /// exactly the arithmetic `drawDeviceImage` performs, because a finished
  /// layer *is* an image.
  @override
  void endLayer() {
    if (_layerDepth == 0) {
      throw StateError('endLayer() without a matching beginLayer()');
    }
    _layerDepth--;

    final GpuLayerStack? stack = layerStack;
    if (stack == null) {
      _isolationBroken = _isolationStack.removeLast();
      return;
    }

    final GpuLayer layer = stack.pop(batchIndex: batcher.batchCount);
    _isolationBroken = _isolationStack.removeLast();
    _setOrigin(stack.originX, stack.originY);
    if (layer.kind != GpuLayerKind.offscreen || !layer.drewSomething) return;
    // The composite belongs to the parent's pass, so it must not merge into
    // the last batch of the layer's - that batch is drawn into the layer's own
    // target, and the composite would be drawn into it too.
    batcher.flush();

    final GpuLayerTarget target = layer.target!;
    final double opacity = layer.opacity;
    final Rect bounds = layer.deviceBounds;
    final double left = bounds.left - _originX;
    final double top = bounds.top - _originY;
    final double right = bounds.right - _originX;
    final double bottom = bounds.bottom - _originY;

    _setState(
      GpuPipelineKind.texturedImage,
      target.textureId,
      layer.blendMode,
      layer.clip,
    );
    batcher.addQuad(
      left: left,
      top: top,
      right: right,
      bottom: bottom,
      u0: layer.u0,
      v0: layer.v0,
      u1: layer.u1,
      v1: layer.v1,
      red: opacity,
      green: opacity,
      blue: opacity,
      alpha: opacity,
      // The layer's bounds are whole pixels and its contents were clipped to
      // them, so there is no fringe for the analytic term to compute: a shape
      // rect equal to the quad evaluates to 1 everywhere. Letting it run
      // against a fractional rect instead would shave the outer row and
      // column off every layer, which reads as a seam around anything with an
      // opacity animation on it.
      shapeLeft: left,
      shapeTop: top,
      shapeRight: right,
      shapeBottom: bottom,
    );
  }

  // -------------------------------------------------------------------
  // Text
  // -------------------------------------------------------------------

  /// Draws a shaped run as one textured quad per glyph, out of the glyph
  /// atlas, in a single batch.
  ///
  /// The single batch is the whole point. Every glyph in a run shares the
  /// pipeline, the atlas texture, the blend mode and the clip - the four
  /// things [GpuBatcher] breaks a batch on - so a hundred-glyph paragraph is
  /// one draw call. A per-glyph texture would make it a hundred, which is not
  /// acceleration; that is why the atlas exists and why the state is set once,
  /// before the loop.
  ///
  /// ## Subpixel positioning, stated exactly
  ///
  /// The pen's fractional x chooses *which* rasterised variant to sample; the
  /// quad is then placed at the *quantised* pen position, never the original:
  ///
  ///     bucket   = glyphSubpixelBucket(penX)   // 0..3, nearest quarter
  ///     quadLeft = glyphPixelOrigin(penX) + entry.left   // a whole pixel
  ///
  /// Both halves are load-bearing and they must be read as a pair. The mask
  /// already contains the fraction - it was rasterised shifted by
  /// `bucket / 4` - so adding the fraction to the quad as well would apply it
  /// twice. And a quad at a fractional x breaks the one-texel-per-pixel
  /// mapping the coverage was built for: with nearest filtering the sampled
  /// texel would flip between neighbours as the position drifts, which is
  /// text that shimmers and jitters while a list scrolls. Whole-pixel quad,
  /// fractional mask.
  ///
  /// The **baseline snaps to a whole pixel** while x does not, the same
  /// asymmetry `cpu_renderer.dart` documents: vertical subpixel positioning
  /// would blur the horizontal stems a Latin face's legibility rides on, and
  /// would multiply the atlas by four to do it.
  ///
  /// Inside a layer every one of those numbers has the layer's whole-pixel
  /// origin subtracted from it, which is why that origin is required to be a
  /// whole pixel: a fractional one would move the quad off the texel grid and
  /// undo this entire section.
  ///
  /// ## Limits
  ///
  ///   * Each glyph is clipped to whole pixels, so a glyph straddling a
  ///     *fractional* clip edge keeps up to one pixel of ink past it. Cutting
  ///     the quad at the fraction instead would misalign texels against
  ///     pixels for the whole glyph, which is a worse artefact than a pixel of
  ///     overhang, and the batch's scissor already bounds it to that pixel.
  ///   * Stroked text is refused, for the reason the CPU sink gives: what is
  ///     cached is coverage, and outlining coverage traces the antialiased
  ///     edge of a bitmap - the "furry text" artefact, not a stroke.
  ///   * A rotated, skewed, mirrored or non-uniformly scaled transform does
  ///     not come through here at all. An atlas slot is a rectangle of texels
  ///     sampled one-to-one against pixels, and that mapping is exactly what
  ///     such a matrix destroys, so the run is filled from its outlines by
  ///     [_drawGlyphRunAsOutlines] instead. [glyphMasksFit] is the criterion
  ///     and the CPU sink imports the same function: text that draws on one
  ///     backend and throws on the other is the divergence this whole file is
  ///     written to avoid.
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
    _refuseGradient(
      paint,
      'a glyph run',
      'the glyph atlas stores coverage that is modulated by one colour, and '
          'a per-glyph ramp would need a second shader this device does not '
          'build',
    );
    final atlas = glyphAtlas;
    final resolver = fontResolver;
    if (atlas == null || resolver == null) {
      throw UnsupportedCapabilityError(
        backendName: backendName,
        capability: Capability.gpuPresentation,
        detail: atlas == null
            ? 'this device has no glyph atlas, so text cannot be drawn; pass a '
                'GpuGlyphAtlas and the id of the alpha8 texture it stages into'
            : 'this device has no GpuFontResolver, so font id $fontId cannot '
                'be turned into a face; wire one to ReplayResources.fontAt',
      );
    }
    if (paint.style != paintStyleFill) {
      throw UnsupportedCapabilityError(
        backendName: backendName,
        capability: Capability.gpuPresentation,
        detail: 'stroked text is not implemented; the glyph atlas stores '
            'coverage, and the stroker needs the outline that coverage was '
            'rasterised from',
      );
    }
    final int alpha = (paint.argbColor >> 24) & 0xFF;
    // Invisible text is common - a fade at t = 0 - and costs a rasterisation
    // per new glyph if it is not stopped before the atlas is asked.
    if (alpha == 0 || glyphCount <= 0) return;

    final ScaledTypeface? interned = resolver.resolveFont(fontId);
    if (interned == null) {
      throw UnsupportedCapabilityError(
        backendName: backendName,
        capability: Capability.gpuPresentation,
        detail: 'font id $fontId resolved to nothing; the display list '
            'interned a face this device cannot rasterise',
      );
    }
    if (!glyphMasksFit(transform)) {
      _drawGlyphRunAsOutlines(
        interned,
        deviceOrigin,
        transform,
        glyphIds,
        deviceOffsets,
        glyphCount,
        clip,
        paint,
      );
      return;
    }

    final ScaledTypeface font = _deviceFont(interned, transform);

    // Whole-pixel clip bounds in layer space, rounded outward to match the
    // scissor this state sets. Computed once: they are loop invariants, and
    // Rect.intersect per glyph would allocate on the per-glyph path.
    final int clipLeft = clip.left.floor() - _originIntX;
    final int clipTop = clip.top.floor() - _originIntY;
    final int clipRight = clip.right.ceil() - _originIntX;
    final int clipBottom = clip.bottom.ceil() - _originIntY;
    if (clipRight <= clipLeft || clipBottom <= clipTop) return;

    final double red = _channel(paint.argbColor, 16, alpha);
    final double green = _channel(paint.argbColor, 8, alpha);
    final double blue = _channel(paint.argbColor, 0, alpha);
    final double alphaFraction = alpha / 255.0;

    _setState(
      GpuPipelineKind.coverageMask,
      glyphTextureId,
      paint.blendMode,
      clip,
    );

    for (var i = 0; i < glyphCount; i++) {
      final double penX = deviceOrigin.dx + deviceOffsets[i * 2];
      final double penY = deviceOrigin.dy + deviceOffsets[i * 2 + 1];
      final int bucket = glyphSubpixelBucket(penX);
      final int glyphId = glyphIds[i];

      GlyphAtlasEntry? entry =
          atlas.acquire(font, glyphId, subpixelBucket: bucket);
      entry ??= _refillGlyphAtlas(atlas, font, glyphId, bucket);
      if (entry.isBlank) continue;

      // The pair: the whole pixel from [glyphPixelOrigin], plus the mask's own
      // offset from the pen, less the layer's whole-pixel origin.
      final int originX = glyphPixelOrigin(penX) + entry.left - _originIntX;
      final int originY = pixelEdge(penY) + entry.top - _originIntY;

      var left = originX;
      var top = originY;
      var right = originX + entry.width;
      var bottom = originY + entry.height;
      if (left < clipLeft) left = clipLeft;
      if (top < clipTop) top = clipTop;
      if (right > clipRight) right = clipRight;
      if (bottom > clipBottom) bottom = clipBottom;
      if (right <= left || bottom <= top) continue;

      // Integers throughout, so the trimmed quad still maps one texel to one
      // pixel; a fractional trim is what would blur the glyph.
      final int texelX = entry.x + (left - originX);
      final int texelY = entry.y + (top - originY);

      batcher.addQuad(
        left: left.toDouble(),
        top: top.toDouble(),
        right: right.toDouble(),
        bottom: bottom.toDouble(),
        u0: texelX * atlas.texelWidth,
        v0: texelY * atlas.texelHeight,
        u1: (texelX + right - left) * atlas.texelWidth,
        v1: (texelY + bottom - top) * atlas.texelHeight,
        red: red,
        green: green,
        blue: blue,
        alpha: alphaFraction,
        // The mask carries the coverage, so the analytic term must evaluate to
        // 1 everywhere: shape rect equal to the quad. Doubling the two would
        // shave the outer row and column of every glyph.
        shapeLeft: left.toDouble(),
        shapeTop: top.toDouble(),
        shapeRight: right.toDouble(),
        shapeBottom: bottom.toDouble(),
      );
    }
  }

  /// Makes room in a full [atlas] through [onAtlasFlush] and retries once.
  ///
  /// Never returns null: either the glyph is placed, or this raises. Dropping
  /// it would leave a hole in a word that looks like a font bug, and section
  /// 6.6 rules that out. Cold by construction - it runs only when the atlas
  /// overflowed - so allocating an error message here costs nothing.
  GlyphAtlasEntry _refillGlyphAtlas(
    GpuGlyphAtlas atlas,
    ScaledTypeface font,
    int glyphId,
    int bucket,
  ) {
    final GlyphAtlasFailure failure = atlas.lastFailure;
    if (failure == GlyphAtlasFailure.glyphTooLarge) {
      throw UnsupportedCapabilityError(
        backendName: backendName,
        capability: Capability.gpuPresentation,
        detail: 'glyph $glyphId of $font does not fit in a '
            '${atlas.plotSize}x${atlas.plotSize} atlas plot, and glyph tiling '
            'is not implemented; text this large should be drawn as a path',
      );
    }

    _flushAtlases(null, atlas, 'glyph $glyphId of $font');

    final GlyphAtlasEntry? retry =
        atlas.acquire(font, glyphId, subpixelBucket: bucket);
    if (retry != null) return retry;
    throw UnsupportedCapabilityError(
      backendName: backendName,
      capability: Capability.gpuPresentation,
      detail: 'the ${atlas.width}x${atlas.height} glyph atlas had no room for '
          'glyph $glyphId even after a flush (${atlas.lastFailure.name}); one '
          'run needs more glyphs than the whole atlas holds',
    );
  }

  /// Runs the flush cycle both atlases share, in the one order that is safe.
  ///
  /// Exactly one of [fullMask] and [fullGlyphs] is the atlas that ran out;
  /// only that one is recycled, because recycling the other would throw away
  /// masks or glyphs that are still perfectly resident and force them to be
  /// rasterised again on this same frame.
  ///
  /// The order, and why each step cannot move:
  ///
  ///   1. **`batcher.flush()`** closes the open batch. Without it, a quad
  ///      appended after the handler returns could merge into a batch the
  ///      handler has already drawn, and that batch would be drawn a second
  ///      time at the end of the frame - blending everything in it twice.
  ///   2. **the handler** uploads both atlases' dirty regions and issues the
  ///      recorded draw calls. Upload first, submit second: the recorded draws
  ///      sample texels this frame wrote, which are still only in the staging
  ///      image.
  ///   3. **`markUploaded`** on both atlases, because the handler has just
  ///      uploaded both and neither can tell on its own.
  ///   4. **`recycle`** on the full one. Last, because it declares every texel
  ///      reusable and the draws that sample the old ones have only just been
  ///      issued.
  ///
  /// The caller retries exactly once and treats a second failure as a bug.
  void _flushAtlases(
    GpuMaskAtlas? fullMask,
    GpuGlyphAtlas? fullGlyphs,
    String what,
  ) {
    final void Function()? flush = onAtlasFlush;
    if (flush == null) {
      final String which = fullMask != null
          ? 'the ${fullMask.width}x${fullMask.height} coverage atlas'
          : 'the ${fullGlyphs!.width}x${fullGlyphs.height} glyph atlas';
      throw UnsupportedCapabilityError(
        backendName: backendName,
        capability: Capability.gpuPresentation,
        detail: '$which is full of masks this frame has already drawn, and '
            'this backend passed no onAtlasFlush handler, so $what cannot be '
            'placed and the frame cannot be completed correctly. A handler '
            'uploads the dirty regions and issues the batches recorded so '
            'far; this sink does the rest.',
      );
    }

    batcher.flush();
    flush();
    maskAtlas?.markUploaded();
    glyphAtlas?.markUploaded();
    fullMask?.recycle();
    fullGlyphs?.recycleAll();
  }

  /// Draws a run by sending each glyph's outline down the *path* route.
  ///
  /// The GPU's answer to the same question `cpu_renderer.dart` answers with
  /// [ScanlineFiller], and - this is the part worth stating - it is the same
  /// answer. [GpuMaskAtlas.rasterizeMask] runs that identical filler and
  /// uploads the coverage, so a rotated letter on this backend and the same
  /// letter on the software backend are produced by one implementation of
  /// coverage and differ only in how the bytes reach the surface. That is why
  /// the parity test for rotated text can declare a deviation of 0 rather
  /// than a tolerance.
  ///
  /// Each glyph is one [_drawMask] call, so each is a quad sampling a mask
  /// slot, and they batch together exactly as the atlas route's quads do while
  /// the pipeline, texture, blend and clip hold. The cost against the atlas
  /// route is honest: one rasterization per glyph per frame instead of one
  /// per glyph ever, because a mask is a function of the whole matrix and the
  /// glyph atlas is keyed only by size. Rotated text is a label on a chart
  /// axis or a collapsed tab, not a paragraph, and the alternative was
  /// refusing to draw it.
  ///
  /// The outline is **unhinted**, for the reason the CPU sink gives at length
  /// and ADR 0007 records: hinting fits stems to a grid the rotated glyph no
  /// longer shares.
  void _drawGlyphRunAsOutlines(
    ScaledTypeface font,
    Offset deviceOrigin,
    Transform2D transform,
    Int32List glyphIds,
    Float32List deviceOffsets,
    int glyphCount,
    Rect clip,
    ReplayPaint paint,
  ) {
    // The interned face's scale: the device scale rides in the matrix's linear
    // part, and folding it into the font too would apply it twice.
    final double fontScale = font.scale;
    final Typeface face = font.typeface;
    for (var i = 0; i < glyphCount; i++) {
      final Path outline = face.outlineOf(glyphIds[i]);
      if (outline.isEmpty) continue;
      // Device space, not layer space: [_drawMask] does the layer shift
      // itself, exactly as it does for a path.
      _drawMask(
        outline,
        glyphOutlineTransform(
          transform,
          fontScale,
          deviceOrigin.dx + deviceOffsets[i * 2],
          deviceOrigin.dy + deviceOffsets[i * 2 + 1],
        ),
        clip,
        paint,
        'glyph',
        // Non-zero: a glyph is defined by the winding of its contours, which
        // is what leaves the counter of an `o` empty and what keeps the
        // crossing contours of a composite glyph from cancelling.
      );
    }
  }

  /// [font] at the size this device transform asks for.
  ///
  /// The **font** is scaled, not the mask: resampling an antialiased mask is
  /// what gives bitmap glyph caches their soft, muddy reputation, and keeping
  /// the outline is the entire reason it was kept. Returns [font] itself at
  /// unit scale, so the common case allocates nothing and hits the atlas under
  /// the key the caller interned. Mirrors `cpu_renderer.dart`'s rule exactly,
  /// so a run that takes the atlas route on one backend takes it on the other.
  ///
  /// Only ever called for a matrix [glyphMasksFit] has accepted, so both
  /// diagonal terms are equal and positive and there is a single scale to
  /// take. The assert states that rather than trusting the caller: reading
  /// `transform.a` alone under a non-uniform scale would silently produce
  /// upright text at the wrong height.
  ScaledTypeface _deviceFont(ScaledTypeface font, Transform2D transform) {
    assert(
      glyphMasksFit(transform),
      'an atlas slot cannot serve $transform; the outline route handles it',
    );
    final double a = transform.a;
    if (a == 1) return font;
    return ScaledTypeface(font.typeface, font.pixelSize * a);
  }

  // -------------------------------------------------------------------
  // Helpers
  // -------------------------------------------------------------------

  /// Moves the coordinate space every quad below is written in.
  ///
  /// The integer copy is not a cache, it is a *requirement*: the glyph path is
  /// integral end to end, and it may only subtract a whole number of pixels.
  /// The stack guarantees a whole-pixel origin, and this asserts it rather
  /// than rounding, because rounding here would misplace a whole layer by a
  /// pixel and leave nothing to find it by.
  void _setOrigin(double x, double y) {
    assert(
      x == x.roundToDouble() && y == y.roundToDouble(),
      'a layer origin must be a whole pixel; got $x, $y',
    );
    _originX = x;
    _originY = y;
    _originIntX = x.toInt();
    _originIntY = y.toInt();
  }

  /// Sets the batcher's state, rounding the clip outward into a scissor and
  /// moving it into layer space.
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
    if (blendMode != blendModeSrcOver && _isolationBroken) {
      throw UnsupportedCapabilityError(
        backendName: backendName,
        capability: Capability.gpuPresentation,
        detail: 'blend mode $blendMode inside a flattened layer would blend '
            'against the parent\'s pixels, where an isolating renderer blends '
            'against transparency - the two are not the same picture, and '
            'this is the one case where flattening an opaque source-over '
            'layer is not an identity. Give the layer a paint that forces an '
            'offscreen pass, or draw this primitive outside it.',
      );
    }
    batcher.setState(
      pipeline: pipeline,
      textureId: textureId,
      blendMode: blendMode,
      scissorLeft: (clip.left - _originX).floor(),
      scissorTop: (clip.top - _originY).floor(),
      scissorRight: (clip.right - _originX).ceil(),
      scissorBottom: (clip.bottom - _originY).ceil(),
    );
  }

  /// One premultiplied colour channel of a non-premultiplied 0xAARRGGBB, in
  /// 0..1. See `gpu_pipeline.dart` for why premultiplication happens here.
  static double _channel(int argb, int shift, int alpha) =>
      ((argb >> shift) & 0xFF) * alpha / (255.0 * 255.0);

  /// The mask atlas rasterises the region an outline encloses, so a
  /// stroke-styled paint would come out as a solid shape where a border was
  /// asked for - wrong output that looks deliberate.
  ///
  /// No longer the same refusal the CPU sink makes: that one now converts the
  /// centreline with `PathStroker` and rasterises the outline instead, and
  /// says so, so a message here claiming stroking "is not implemented" would
  /// send a reader looking for a stroker that exists. What is missing is on
  /// this side - the conversion is CPU geometry the GPU path has no stage for
  /// yet, and the player hands a stroked rectangle here as a path expecting
  /// exactly that.
  /// Refuses a gradient on a route that has no shader to sample one.
  ///
  /// Images, glyph runs and layer composites are all textured quads whose
  /// colour comes from a texture or a modulation factor; none of them has a
  /// slot for a ramp, and the display list cannot express what a gradient
  /// would even mean for two of them (the CPU renderer refuses the same three
  /// by name). The refusal is stated here so a caller reads which primitive
  /// was involved rather than a generic message from three call sites.
  void _refuseGradient(ReplayPaint paint, String what, String because) {
    if (paint.gradient == null) return;
    throw UnsupportedCapabilityError(
      backendName: backendName,
      capability: Capability.gpuPresentation,
      detail: 'a gradient paint on $what is not defined: $because. The '
          'display-list resource was preserved as ${paint.gradient} instead '
          'of being rendered as an incorrect solid colour.',
    );
  }

  void _requireFill(ReplayPaint paint, String what) {
    if (paint.style == paintStyleFill) return;
    throw UnsupportedCapabilityError(
      backendName: backendName,
      capability: Capability.gpuPresentation,
      detail: 'stroking is not implemented on the GPU path; the CPU sink '
          'strokes through PathStroker and nothing here calls it, so a '
          'stroke-styled $what would be filled as its enclosed region',
    );
  }

  /// Tiles one oversized shape may be split into before this refuses.
  ///
  /// Sixty-four covers a shape eight atlases wide and eight tall - far past
  /// anything a clipped device rectangle can produce against a sane atlas -
  /// and turns the pathological configuration (a wall-sized clip and a 64 px
  /// atlas) into a named refusal instead of thousands of rasterisations.
  static const int _maxMaskTiles = 64;
}
