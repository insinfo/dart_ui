/// Turning a glyph outline into pixels.
///
/// This lives under `rendering/`, not under `text/`, and the placement is the
/// point rather than an accident. Section 22.7 requires that the font parser
/// not be coupled to a renderer: it produces outlines and metrics, and each
/// renderer decides for itself whether to fill a path, cache a mask or pack an
/// atlas. So `text/` knows nothing about rasterization, and this file - which
/// is rasterization - depends on `text/` rather than the other way round.
///
/// There is almost nothing here, and that is the point: the framework's
/// existing [ScanlineFiller] is an exact-area coverage accumulator - the same
/// family of algorithm FreeType's smooth rasterizer and font-rs use - so a
/// glyph is filled by the same code that fills every other path. This file is
/// the coordinate change and the mask allocation, and nothing else.
///
/// The coordinate change is worth stating precisely, because getting it wrong
/// produces text that is upside down, or subtly mispositioned in a way that
/// only shows at small sizes:
///
///   * font units are **y-up** with the origin on the baseline at the glyph's
///     left edge, while the framebuffer is **y-down** with the origin at the
///     top left. So the transform scales by `size / unitsPerEm` and negates y;
///   * the mask is allocated from the glyph's own device-space bounds, so a
///     glyph that sits above the baseline (almost all of them) produces a mask
///     whose origin is a negative y offset from the pen position.
///
/// ## Masks are not the only way a glyph is drawn
///
/// A mask is a rectangle of pixels, so it can only be *blitted* - moved by a
/// whole number of pixels. That serves the case every interface is made of and
/// nothing else: upright text, scaled uniformly and positively. The moment the
/// matrix rotates, skews, mirrors or scales the two axes differently, the mask
/// is the wrong representation, and the two sinks that draw text
/// (`cpu_renderer.dart` and `gpu/gpu_raster_sink.dart`) fill the glyph's
/// *outline* under the full matrix instead.
///
/// The two functions that decide and describe that split live here, next to
/// the rasteriser they are about, and both sinks import them rather than
/// re-deriving the rule: [glyphMasksFit] is the criterion, and
/// [glyphOutlineTransform] is the matrix the outline route uses. A criterion
/// copied into two files is exactly how one backend ends up accepting a scene
/// the other refuses.
library;

import 'dart:typed_data';

import '../../geometry/path.dart';
import '../../geometry/rect.dart';
import '../../geometry/transform2d.dart';
import '../../text/typeface.dart';
import '../path/coverage_span_sink.dart';
import '../path/scanline_filler.dart';

/// Whether a cached, axis-aligned coverage mask can stand in for the glyph
/// under [transform].
///
/// True only for the transform a blit can express: no rotation and no skew
/// (`b` and `c` are zero), no mirroring (both diagonal terms positive), and
/// the same factor on both axes, because a mask is rasterised at one size and
/// stretching it afterwards resamples an antialiased edge - the soft, muddy
/// text that gives bitmap glyph caches their reputation.
///
/// This is the dividing line between the fast path and the general one, and
/// it is deliberately conservative: everything it rejects is drawn correctly
/// by the outline route, so a false negative costs time and a false positive
/// would cost correctness.
///
/// Note that `a == d` is an exact comparison. A matrix that is uniform only to
/// within a rounding error is *not* uniform enough for one mask to serve both
/// axes, and there is no threshold that is right at every size; the outline
/// route handles it exactly and costs a fill.
bool glyphMasksFit(Transform2D transform) =>
    transform.b == 0 &&
    transform.c == 0 &&
    transform.a > 0 &&
    transform.d > 0 &&
    transform.a == transform.d;

/// The matrix that maps a glyph's outline, in font units, straight to the
/// device pixels it covers under an arbitrary affine [deviceTransform].
///
/// Three things composed in one matrix, right to left:
///
///   1. **font units to text-space pixels, y flipped** - `fontScale` is
///      [ScaledTypeface.scale], and the negation is the y-up to y-down change
///      described in the library comment;
///   2. **the linear part of [deviceTransform]** - rotation, skew, mirroring
///      and per-axis scale. Only the linear part: the translation is already
///      carried by the pen;
///   3. **the pen**, as the translation, in whatever space the caller is
///      filling into - device pixels, or a layer's own pixels once its origin
///      has been subtracted.
///
/// Composed rather than applied, because [ScanlineFiller.fill] applies a
/// matrix while it flattens: no transformed copy of the outline is ever
/// allocated, which is what makes the outline route affordable enough to be a
/// fallback rather than a refusal.
///
/// Under a matrix [glyphMasksFit] accepts this reduces to
/// `scale(fontScale * k, -fontScale * k)` plus the pen, which is exactly the
/// matrix [GlyphRasterizer.render] builds - so the two routes agree where they
/// overlap, by construction rather than by coincidence.
Transform2D glyphOutlineTransform(
  Transform2D deviceTransform,
  double fontScale,
  double penX,
  double penY,
) =>
    Transform2D(
      deviceTransform.a * fontScale,
      deviceTransform.b * fontScale,
      -deviceTransform.c * fontScale,
      -deviceTransform.d * fontScale,
      penX,
      penY,
    );

/// A rendered glyph: an 8-bit coverage mask and where to put it.
///
/// Coverage rather than colour. A glyph is a shape, and its colour belongs to
/// the paint at the point it is drawn - which is what lets one cached mask
/// serve black text, red text and text under a gradient.
final class GlyphMask {
  const GlyphMask({
    required this.coverage,
    required this.width,
    required this.height,
    required this.left,
    required this.top,
  });

  /// One byte of coverage per pixel, row-major, `width * height` long.
  final Uint8List coverage;

  final int width;
  final int height;

  /// Where the mask's top-left corner sits relative to the pen position, in
  /// whole pixels. Nearly always negative in y, because glyphs rise above the
  /// baseline.
  final int left;
  final int top;

  bool get isEmpty => width == 0 || height == 0;

  /// Coverage at ([x], [y]) within the mask; 0 outside it.
  int coverageAt(int x, int y) {
    if (x < 0 || y < 0 || x >= width || y >= height) return 0;
    return coverage[y * width + x];
  }

  /// The mask of a glyph that draws nothing - a space, or one whose outline
  /// collapsed to less than a pixel. Shared, because there are many of them
  /// and they are all the same nothing.
  static final GlyphMask empty = GlyphMask(
    coverage: Uint8List(0),
    width: 0,
    height: 0,
    left: 0,
    top: 0,
  );

  @override
  String toString() => 'GlyphMask(${width}x$height at $left,$top)';
}

/// Rasterizes glyph outlines into coverage masks.
///
/// Holds one [ScanlineFiller], because the filler reuses its edge and
/// accumulator buffers between calls and allocating a new one per glyph would
/// throw that away. Not thread-safe, and does not need to be: rasterization
/// happens on whichever isolate owns the frame.
final class GlyphRasterizer {
  final ScanlineFiller _filler = ScanlineFiller();

  /// Renders [glyphId] from [font] at a subpixel horizontal offset.
  ///
  /// [subpixelOffsetX] shifts the glyph by a fraction of a pixel before
  /// rasterizing, which is how text avoids snapping every stem to the pixel
  /// grid. It is the caller's job to quantise it - typically to quarters - so
  /// the cache has a bounded number of variants.
  /// Hinting is asked for here and nowhere else, by passing the pixel size as
  /// the ppem. A mask is rasterised on the pixel grid, upright and unrotated -
  /// [glyphMasksFit] is what guarantees it - which is the only situation in
  /// which grid-fitting a stem to a pixel boundary means anything. The outline
  /// route in the two sinks deliberately asks for the *unhinted* outline: see
  /// there, and see `doc/adr/0007`.
  GlyphMask render(
    ScaledTypeface font,
    int glyphId, {
    double subpixelOffsetX = 0,
  }) {
    final Path outline = font.typeface.outlineOf(glyphId, font.pixelSize);
    if (outline.isEmpty) return GlyphMask.empty;

    // Font units to device pixels: scale, negate y, then shift by the
    // subpixel offset. Composed as one matrix so the filler applies it during
    // flattening and no transformed copy of the path is ever allocated.
    final Transform2D transform = Transform2D(
      font.scale,
      0,
      0,
      -font.scale,
      subpixelOffsetX,
      0,
    );

    final Rect deviceBounds = outline.bounds.transformedBy(transform);
    final int left = deviceBounds.left.floor();
    final int top = deviceBounds.top.floor();
    final int right = deviceBounds.right.ceil();
    final int bottom = deviceBounds.bottom.ceil();
    final int width = right - left;
    final int height = bottom - top;
    if (width <= 0 || height <= 0) return GlyphMask.empty;

    final Uint8List coverage = Uint8List(width * height);
    final _MaskSink sink = _MaskSink(coverage, width, height, left, top);

    _filler.fill(
      outline,
      Rect.fromLTRB(
        left.toDouble(),
        top.toDouble(),
        right.toDouble(),
        bottom.toDouble(),
      ),
      sink,
      transform: transform,
    );

    return GlyphMask(
      coverage: coverage,
      width: width,
      height: height,
      left: left,
      top: top,
    );
  }
}

/// Writes coverage spans into a mask, translated to the mask's own origin.
final class _MaskSink implements CoverageSpanSink {
  _MaskSink(this._coverage, this._width, this._height, this._left, this._top);

  final Uint8List _coverage;
  final int _width;
  final int _height;
  final int _left;
  final int _top;

  @override
  void span(int y, int xStart, int xEnd, int coverage) {
    final int row = y - _top;
    if (row < 0 || row >= _height) return;
    final int start = (xStart - _left).clamp(0, _width);
    final int end = (xEnd - _left).clamp(0, _width);
    if (end <= start) return;
    // fillRange rather than a loop: a glyph stem is a run of full-coverage
    // pixels, and this is the inner loop of every frame that draws text.
    _coverage.fillRange(row * _width + start, row * _width + end, coverage);
  }
}

extension on Rect {
  /// This rect's axis-aligned bounds after [transform].
  ///
  /// Local to this file: the general case belongs on Transform2D, but a glyph
  /// transform is a scale and a flip, so the four-corner walk is exact here
  /// rather than conservative.
  Rect transformedBy(Transform2D transform) => transform.transformRect(this);
}
