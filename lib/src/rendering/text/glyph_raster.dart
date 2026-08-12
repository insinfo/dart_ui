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
library;

import 'dart:typed_data';

import '../../geometry/path.dart';
import '../../geometry/rect.dart';
import '../../geometry/transform2d.dart';
import '../../text/typeface.dart';
import '../path/coverage_span_sink.dart';
import '../path/scanline_filler.dart';

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
  GlyphMask render(
    ScaledTypeface font,
    int glyphId, {
    double subpixelOffsetX = 0,
  }) {
    final Path outline = font.typeface.outlineOf(glyphId);
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
