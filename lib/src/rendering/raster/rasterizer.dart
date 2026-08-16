/// The CPU scanline rasteriser.
///
/// This layer is deliberately ignorant. It takes primitives already in device
/// space - whole surface pixels, transform applied, y down - and turns them
/// into bytes in a [Framebuffer]. It has never heard of display lists,
/// transforms, layers or widgets; whatever walks those structures resolves
/// them to device-space rectangles and calls in here. Keeping the arithmetic
/// on one side of that line is what lets the replay layer change shape without
/// touching pixel code, and lets this file be tested with nothing but a buffer
/// and a rectangle.
///
/// ANTIALIASING IS OPT-IN, NOT THE DEFAULT. [CpuRasterizer.fillRect] covers
/// whole pixels: an edge at x = 10.5 lands at 10 or 11 rather than half
/// covering a column. [CpuRasterizer.fillRectAntiAliased] is the same fill
/// with exact coverage on its boundary. The two are separate entry points
/// rather than a flag on one, so that a caller reading a display list can pick
/// per primitive and so that adding antialiasing changed nothing for callers
/// that already existed.
///
/// BLEND MODE IS A PARAMETER, NOT A FIXED EQUATION. Every entry point takes a
/// [CpuBlendMode] and defaults it to source-over. The mode is resolved from
/// the display list's wire constant once, by `cpuBlendForMode`, and travels
/// down as an enum; nothing here allocates per primitive and nothing tests the
/// mode inside a per-pixel loop. See `blend.dart` for the three equations and
/// for what `src` means on an antialiased boundary, which is the one place the
/// answer is not obvious.
///
/// The antialiased path is not a second compositor. It computes a coverage
/// byte per boundary pixel with `spanCoverage` - for an axis-aligned rectangle
/// the exact product of the fractional overlap in x and in y - scales the
/// premultiplied source by it, and hands the result to the same three
/// equations everything else uses. Interior pixels have coverage 255,
/// which is the identity, so they run down the same span loop a hard-edged
/// fill uses and pay nothing. That is the entire cost model: antialiasing is
/// charged to the boundary of a shape, never to its area.
library;

import 'dart:typed_data';

import '../../geometry/rect.dart';
import '../framebuffer.dart';
import 'blend.dart';
import 'clip_stack.dart';
import 'coverage.dart';

/// Draws device-space primitives into a [Framebuffer] on the CPU.
///
/// Every entry point clips against both the clip stack and the surface, and a
/// primitive that falls entirely outside either returns before touching memory
/// or doing per-pixel work.
final class CpuRasterizer {
  CpuRasterizer(this.target)
      : clip = ClipStack.forDevice(target.width, target.height),
        // Read once. Both are final on the framebuffer, and hoisting them here
        // keeps the inner loops off a field load through another object.
        _pixels = target.pixels,
        _bytesPerRow = target.bytesPerRow,
        // Byte index of red within a pixel: 2 for BGRA, 0 for RGBA. Blue is
        // the other one. Storing the index rather than the format turns the
        // per-pixel channel-order question into address arithmetic that has
        // already been answered by the time any loop starts.
        _redIndex = target.format == PixelFormat.bgra8888Premultiplied ? 2 : 0;

  /// The surface being drawn into. Its `bytesPerRow` is used as given and
  /// never recomputed from `width`; see [Framebuffer] for why.
  final Framebuffer target;

  /// The clip in effect. Exposed so a caller that already tracks its own
  /// save/restore nesting can drive it directly, but [save], [restore] and
  /// [clipRect] cover the normal case.
  final ClipStack clip;

  final Uint8List _pixels;
  final int _bytesPerRow;
  final int _redIndex;

  void save() => clip.save();

  void restore() => clip.restore();

  void clipRect(Rect rect) => clip.intersect(rect);

  /// Fills [rect] with [argbColor] composited with [blendMode].
  ///
  /// [argbColor] is `0xAARRGGBB` with *straight* alpha, the form a colour
  /// arrives in from anything user-facing; it is premultiplied here, once per
  /// call rather than once per pixel. The framebuffer stays premultiplied
  /// throughout.
  ///
  /// [blendMode] defaults to source-over, which is what almost everything
  /// paints with and what every caller wanted before the parameter existed.
  /// The equation is chosen *once per call*, outside both loops - see the
  /// switch below - so a fill costs the same per pixel as it did when
  /// source-over was the only equation there was.
  ///
  /// Coverage is integer: each pixel is either fully in or fully out, edges
  /// rounded to the nearest pixel by [pixelEdge], and the clip that applies is
  /// the integer one. [fillRectAntiAliased] is the same fill with fractional
  /// coverage on the boundary; this one stays as it is because a hard edge is
  /// what a pixel-aligned fill wants, and most of what a UI paints is pixel
  /// aligned.
  void fillRect(
    Rect rect,
    int argbColor, {
    CpuBlendMode blendMode = CpuBlendMode.srcOver,
  }) {
    final alpha = (argbColor >> 24) & 0xff;
    // Fully transparent draws are common enough in real UIs - a faded-out
    // layer, an animation at t=0 - to be worth leaving before any clipping
    // arithmetic happens at all.
    //
    // This holds for [CpuBlendMode.src] too, where a transparent source would
    // otherwise *erase* the destination. That is deliberate and it is where
    // `gpu_raster_sink.dart` stops as well: `fillDeviceRect` returns on alpha
    // 0 before it looks at the blend mode, so an invisible primitive draws
    // nothing on either backend. A layer is the opposite case, and
    // [compositeLayer] says why.
    if (alpha == 0) return;

    final left = _max(pixelEdge(rect.left), clip.left);
    final top = _max(pixelEdge(rect.top), clip.top);
    final right = _min(pixelEdge(rect.right), clip.right);
    final bottom = _min(pixelEdge(rect.bottom), clip.bottom);
    if (right <= left || bottom <= top) return;

    // Premultiply once, then order the channels for this surface. c1 is green
    // in both formats, so only the outer two ever move.
    final red = premultiply((argbColor >> 16) & 0xff, alpha);
    final green = premultiply((argbColor >> 8) & 0xff, alpha);
    final blue = premultiply(argbColor & 0xff, alpha);
    final c0 = _redIndex == 0 ? red : blue;
    final c2 = _redIndex == 0 ? blue : red;

    switch (blendMode) {
      case CpuBlendMode.srcOver:
        if (alpha == 255) {
          _fillReplace(left, top, right, bottom, c0, green, c2, 255);
          return;
        }
        final inverse = 255 - alpha;
        for (var y = top; y < bottom; y++) {
          var offset = y * _bytesPerRow + left * 4;
          for (var x = left; x < right; x++) {
            _pixels[offset] = blendChannelOver(c0, _pixels[offset], inverse);
            _pixels[offset + 1] =
                blendChannelOver(green, _pixels[offset + 1], inverse);
            _pixels[offset + 2] =
                blendChannelOver(c2, _pixels[offset + 2], inverse);
            _pixels[offset + 3] =
                blendChannelOver(alpha, _pixels[offset + 3], inverse);
            offset += 4;
          }
        }
      case CpuBlendMode.src:
        _fillReplace(left, top, right, bottom, c0, green, c2, alpha);
      case CpuBlendMode.plus:
        _fillPlus(left, top, right, bottom, c0, green, c2, alpha);
    }
  }

  /// Writes a constant premultiplied pixel over a rectangle: `ONE, ZERO`, and
  /// also the opaque case of source-over, which is the same four bytes.
  ///
  /// `blendPixelOver` would take the same branch on every pixel of the span,
  /// and it would take it correctly - but the alpha of a solid fill is a
  /// constant, so the decision belongs outside both loops rather than inside
  /// the inner one. The two callers reach it from opposite directions and
  /// agree byte for byte, which is what makes an opaque `src` rectangle and an
  /// opaque source-over one indistinguishable, as they must be.
  void _fillReplace(
    int left,
    int top,
    int right,
    int bottom,
    int c0,
    int c1,
    int c2,
    int alpha,
  ) {
    for (var y = top; y < bottom; y++) {
      var offset = y * _bytesPerRow + left * 4;
      for (var x = left; x < right; x++) {
        _pixels[offset] = c0;
        _pixels[offset + 1] = c1;
        _pixels[offset + 2] = c2;
        _pixels[offset + 3] = alpha;
        offset += 4;
      }
    }
  }

  /// Adds a constant premultiplied pixel into a rectangle, saturating.
  ///
  /// The destination is read here where [_fillReplace] only writes, so there
  /// is no opaque short cut: `plus` against an opaque destination is exactly
  /// the case that has to clamp.
  void _fillPlus(
    int left,
    int top,
    int right,
    int bottom,
    int c0,
    int c1,
    int c2,
    int alpha,
  ) {
    for (var y = top; y < bottom; y++) {
      var offset = y * _bytesPerRow + left * 4;
      for (var x = left; x < right; x++) {
        blendPixelPlus(_pixels, offset, c0, c1, c2, alpha);
        offset += 4;
      }
    }
  }

  /// Fills [rect] with [argbColor], antialiased on its boundary.
  ///
  /// Same colour convention and same compositor as [fillRect]; the difference
  /// is that a pixel the rectangle covers partially is blended with that
  /// fraction rather than being rounded in or out. For an axis-aligned
  /// rectangle the fraction is exact - see `coverage.dart` - so this is not a
  /// sampled approximation and does not get better with more work.
  ///
  /// A rectangle already on integer boundaries produces byte-for-byte the same
  /// result as [fillRect]. That is worth relying on: every boundary pixel gets
  /// coverage 255 or 0, and 255 is the identity for the scale, so there is no
  /// path by which antialiasing can perturb a pixel-aligned fill. There is a
  /// test on exactly that.
  ///
  /// This clips against the *exact* clip rectangle, not the integer one, so a
  /// clip edge at 10.5 leaves column 10 half covered instead of chopping it.
  /// See [ClipStack] for why both exist.
  ///
  /// [blendMode] is carried through to [_fillSpan] unchanged. It is worth
  /// reading [blendPixelSrc] before drawing an antialiased rectangle with
  /// [CpuBlendMode.src]: on the boundary, "replace the destination" replaces
  /// it with a *partially transparent* source, so the edge of such a fill
  /// erases rather than blends.
  void fillRectAntiAliased(
    Rect rect,
    int argbColor, {
    CpuBlendMode blendMode = CpuBlendMode.srcOver,
  }) {
    final alpha = (argbColor >> 24) & 0xff;
    if (alpha == 0) return;

    // Clip in continuous space, before anything is rounded. Intersecting two
    // axis-aligned rectangles is exact, so no coverage is lost here - which is
    // the whole reason the clip stack carries fractional edges.
    final left = _maxD(rect.left, clip.exactLeft);
    final top = _maxD(rect.top, clip.exactTop);
    final right = _minD(rect.right, clip.exactRight);
    final bottom = _minD(rect.bottom, clip.exactBottom);
    if (right <= left || bottom <= top) return;

    // Safe without a bounds clamp: the clip's exact rectangle starts at the
    // device bounds and intersection only shrinks it, so flooring its left and
    // ceiling its right cannot leave the buffer.
    final x0 = firstCoveredPixel(left);
    final x1 = coveredPixelEnd(right);
    final y0 = firstCoveredPixel(top);
    final y1 = coveredPixelEnd(bottom);

    final red = premultiply((argbColor >> 16) & 0xff, alpha);
    final green = premultiply((argbColor >> 8) & 0xff, alpha);
    final blue = premultiply(argbColor & 0xff, alpha);
    final c0 = _redIndex == 0 ? red : blue;
    final c2 = _redIndex == 0 ? blue : red;

    // Column coverage is the same for every row, so it is computed once for
    // the two boundary columns and never inside the row loop. Everything
    // between them is a full column by construction.
    final singleColumn = x1 - x0 == 1;
    final leftCoverage = spanCoverage(left, right, x0);
    final rightCoverage =
        singleColumn ? leftCoverage : spanCoverage(left, right, x1 - 1);

    for (var y = y0; y < y1; y++) {
      final rowCoverage = spanCoverage(top, bottom, y);
      // A row the rectangle only touches contributes nothing. Checking here
      // rather than per pixel is what keeps the generous `ceil` bound free.
      if (rowCoverage == 0) continue;

      if (singleColumn) {
        _fillSpan(y, x0, x1, c0, green, c2, alpha,
            mul255(leftCoverage, rowCoverage), blendMode);
        continue;
      }
      _fillSpan(y, x0, x0 + 1, c0, green, c2, alpha,
          mul255(leftCoverage, rowCoverage), blendMode);
      // The interior. Its coverage is the row's, so a fully covered row runs
      // the identical loop `fillRect` runs, including the opaque byte-copy
      // case.
      _fillSpan(
          y, x0 + 1, x1 - 1, c0, green, c2, alpha, rowCoverage, blendMode);
      _fillSpan(y, x1 - 1, x1, c0, green, c2, alpha,
          mul255(rightCoverage, rowCoverage), blendMode);
    }
  }

  /// Composites a horizontal run of one colour at one coverage, with
  /// [blendMode].
  ///
  /// [coverage] scales the already-premultiplied source: scaling all four
  /// channels including alpha is what keeps the result premultiplied, and it
  /// is done once for the run rather than once per pixel. Coverage 255 skips
  /// the scaling entirely, which is why an interior span costs exactly what it
  /// costs in [fillRect].
  ///
  /// The equation is picked once per span - every `case` below owns a whole
  /// loop rather than sitting inside one - so a mode costs a predictable
  /// branch per run of pixels and nothing per pixel. That is the same shape
  /// [fillRect] uses and the reason both were written this way rather than
  /// with a function pointer per pixel.
  ///
  /// ## A source that rounds away draws nothing, in every mode
  ///
  /// Two tests below leave without writing: zero coverage, and a scaled source
  /// alpha of zero. Both are stated as rules rather than as optimisations,
  /// because for [CpuBlendMode.src] they are the difference between leaving
  /// the destination alone and erasing it.
  ///
  /// Zero coverage is the easy one: a pixel the shape does not touch is not
  /// part of the shape, so `src` has nothing to replace there. It is also the
  /// one place this backend and the GL one can be made to differ - a GPU draws
  /// the shape's whole bounding quad, and `ONE, ZERO` erases the zero-coverage
  /// corners of that quad. The CPU's answer is the one that means what `src`
  /// is for.
  ///
  /// The second is the same rule one level down. `mul255(alpha, coverage)` of
  /// zero leaves a premultiplied source that is zero in all four channels: it
  /// carries no colour and no opacity, and the framework's answer to a source
  /// that rounds away is uniformly to skip it - [fillRect] on a transparent
  /// paint, [blendPixelOver] on alpha zero, `gpu_raster_sink.dart` on alpha
  /// zero. Replacing the destination with it instead would erase a pixel the
  /// shape covers by a fraction of a percent - a 25%-opaque paint at coverage
  /// 1 of 255 rounds to zero - and that is a hole, not an edge. Skipping is
  /// also what keeps this method, [fillRect] and `_CoverageToRasterizer` in
  /// `cpu_renderer.dart` agreeing, which they must: they are three ways to
  /// paint the same span.
  void _fillSpan(
    int y,
    int xStart,
    int xEnd,
    int c0,
    int c1,
    int c2,
    int alpha,
    int coverage,
    CpuBlendMode blendMode,
  ) {
    // Coverage zero must not write. Blending with alpha 0 would be a no-op
    // arithmetically, but it would still read and write four bytes per pixel
    // on every row of every antialiased fill's bounding box.
    if (xEnd <= xStart || coverage == 0) return;

    var a = alpha;
    var s0 = c0;
    var s1 = c1;
    var s2 = c2;
    if (coverage != 255) {
      a = mul255(alpha, coverage);
      // A faint colour under a slight coverage can round away completely. The
      // colour channels are zero too whenever the alpha is: they are
      // premultiplied, so each is at most the alpha.
      if (a == 0) return;
      s0 = mul255(c0, coverage);
      s1 = mul255(c1, coverage);
      s2 = mul255(c2, coverage);
    }

    var offset = y * _bytesPerRow + xStart * 4;
    switch (blendMode) {
      case CpuBlendMode.srcOver:
        if (a == 255) {
          for (var x = xStart; x < xEnd; x++) {
            _pixels[offset] = s0;
            _pixels[offset + 1] = s1;
            _pixels[offset + 2] = s2;
            _pixels[offset + 3] = 255;
            offset += 4;
          }
          return;
        }
        final inverse = 255 - a;
        for (var x = xStart; x < xEnd; x++) {
          _pixels[offset] = blendChannelOver(s0, _pixels[offset], inverse);
          _pixels[offset + 1] =
              blendChannelOver(s1, _pixels[offset + 1], inverse);
          _pixels[offset + 2] =
              blendChannelOver(s2, _pixels[offset + 2], inverse);
          _pixels[offset + 3] =
              blendChannelOver(a, _pixels[offset + 3], inverse);
          offset += 4;
        }
      case CpuBlendMode.src:
        for (var x = xStart; x < xEnd; x++) {
          blendPixelSrc(_pixels, offset, s0, s1, s2, a);
          offset += 4;
        }
      case CpuBlendMode.plus:
        for (var x = xStart; x < xEnd; x++) {
          blendPixelPlus(_pixels, offset, s0, s1, s2, a);
          offset += 4;
        }
    }
  }

  /// Composites an alpha8 coverage mask, tinted with [argbColor], with its
  /// top-left corner at ([destinationLeft], [destinationTop]).
  ///
  /// This is the one shape [drawFramebuffer] cannot express. A glyph is not an
  /// image: it carries no colour of its own, only how much of each pixel it
  /// covers, and the colour comes from the paint at the point it is drawn -
  /// which is what lets one cached mask serve black text, red text and the
  /// same string in two themes. Compositing it as a premultiplied image would
  /// need a coloured copy of the mask per colour, and every one of those
  /// copies would be a rasterization the cache exists to avoid.
  ///
  /// [coverage] is `maskWidth * maskHeight` bytes, row-major, one byte per
  /// pixel, in the same 0..255 scale `spanCoverage` and the scanline filler
  /// produce - so a mask byte of 255 means the glyph covers that pixel
  /// entirely. Such a pixel composites to exactly the bytes [fillRect] would
  /// have written for the same colour: this routine folds coverage into the
  /// premultiplied source with the same [mul255] the filler used, and 255 is
  /// that scale's identity. The parity is not decorative - a stem's interior
  /// and a hard rect fill of the same colour meeting at an edge would show a
  /// seam if the two rounded differently.
  ///
  /// Clipping is against the *integer* clip. A mask pixel is whole - it has
  /// already spent its fractional resolution on coverage - so there is no
  /// fraction left for a fractional clip edge to cut into, and the hard-edged
  /// rule is the one [drawFramebuffer] and [fillRect] use.
  ///
  /// [blendMode] applies per mask pixel, through the same [_fillSpan] a
  /// rectangle goes through, so a glyph run and a rectangle of the same colour
  /// and mode land on the same bytes wherever the mask is fully covered. A run
  /// of zero mask bytes is skipped in every mode - a glyph does not touch the
  /// space around its stems, so `src` has nothing to replace there; see
  /// [_fillSpan].
  void blendCoverageMask(
    Uint8List coverage,
    int maskWidth,
    int maskHeight,
    int destinationLeft,
    int destinationTop,
    int argbColor, {
    CpuBlendMode blendMode = CpuBlendMode.srcOver,
  }) {
    final alpha = (argbColor >> 24) & 0xff;
    if (alpha == 0 || maskWidth <= 0 || maskHeight <= 0) return;

    final left = _max(destinationLeft, clip.left);
    final top = _max(destinationTop, clip.top);
    final right = _min(destinationLeft + maskWidth, clip.right);
    final bottom = _min(destinationTop + maskHeight, clip.bottom);
    if (right <= left || bottom <= top) return;

    final red = premultiply((argbColor >> 16) & 0xff, alpha);
    final green = premultiply((argbColor >> 8) & 0xff, alpha);
    final blue = premultiply(argbColor & 0xff, alpha);
    final c0 = _redIndex == 0 ? red : blue;
    final c2 = _redIndex == 0 ? blue : red;

    for (var y = top; y < bottom; y++) {
      final rowBase = (y - destinationTop) * maskWidth - destinationLeft;
      // Run-length, not per pixel. A glyph is mostly flat: the inside of a stem
      // is a run of 255 and the space around it a run of 0, so grouping equal
      // coverage turns the body of every glyph into the same span loop a solid
      // fill takes, and confines the per-pixel work to the antialiased fringe.
      var x = left;
      while (x < right) {
        final value = coverage[rowBase + x];
        var end = x + 1;
        while (end < right && coverage[rowBase + end] == value) {
          end++;
        }
        if (value != 0) {
          _fillSpan(y, x, end, c0, green, c2, alpha, value, blendMode);
        }
        x = end;
      }
    }
  }

  /// Composites a finished layer's pixels back into this surface.
  ///
  /// This is the second half of `saveLayer`, and the one that cannot be
  /// expressed as any other call here. [drawFramebuffer] blits source-over at
  /// full opacity; a layer is blitted at *its own* opacity and with *its own*
  /// blend mode, and both of those are properties of the composite rather than
  /// of anything inside the layer. That is the whole reason a layer needs a
  /// buffer of its own: [alpha] applies to the layer's contents as a finished
  /// image, not to each primitive in it, and the two differ wherever those
  /// primitives overlap.
  ///
  /// ## Contract
  ///
  ///   * [source] is premultiplied, and its own `width`/`height` are the
  ///     layer's pixel size. A pooled buffer larger than the layer must be
  ///     handed in as a tight view of the used region, never as the whole
  ///     allocation - the extra was never rendered into and compositing it
  ///     would paint the previous tenant's pixels.
  ///   * [destinationLeft] and [destinationTop] are **whole pixels**, because
  ///     a layer's bounds are snapped outward before its buffer is sized. A
  ///     fractional destination would resample the layer through a phase shift
  ///     and soften every glyph inside it; there is no such argument to pass.
  ///   * [alpha] is 0..255 and scales all four channels through the same
  ///     [mul255] the rest of this file uses. Scaling alpha along with colour
  ///     is what keeps the result premultiplied, and reusing `mul255` is what
  ///     makes a layer at alpha 255 composite bit-identically to a plain blit.
  ///   * Clipping is against the **integer** clip. The layer's edges are whole
  ///     pixels by construction, so there is no fraction left for the exact
  ///     clip to cut into, and the parent's own clip has already been narrowed
  ///     by the caller.
  ///
  /// One pixel of the source is read per pixel of the destination: no scaling
  /// and no filtering, the same rule [drawFramebuffer] states, and the reason
  /// the GPU side binds its layer texture with nearest filtering.
  void compositeLayer(
    Framebuffer source,
    int destinationLeft,
    int destinationTop,
    int alpha,
    CpuBlendMode blendMode,
  ) {
    // srcOver and plus with nothing to add are exact identities, so the whole
    // walk is skipped. src is *not*: replacing the destination with a fully
    // transparent layer erases it, which is what `ONE, ZERO` does on the GPU
    // as well.
    if (alpha == 0 && blendMode != CpuBlendMode.src) return;

    final left = _max(destinationLeft, clip.left);
    final top = _max(destinationTop, clip.top);
    final right = _min(destinationLeft + source.width, clip.right);
    final bottom = _min(destinationTop + source.height, clip.bottom);
    if (right <= left || bottom <= top) return;

    final src = source.pixels;
    final srcBytesPerRow = source.bytesPerRow;
    // Resolved before the loops, exactly as [drawFramebuffer] does it: a
    // format mismatch costs an index rather than a branch per pixel.
    final srcRedIndex =
        source.format == PixelFormat.bgra8888Premultiplied ? 2 : 0;
    final read0 = srcRedIndex == _redIndex ? 0 : 2;
    final read2 = 2 - read0;

    for (var y = top; y < bottom; y++) {
      var srcOffset =
          (y - destinationTop) * srcBytesPerRow + (left - destinationLeft) * 4;
      var dstOffset = y * _bytesPerRow + left * 4;
      for (var x = left; x < right; x++) {
        var s0 = src[srcOffset + read0];
        var s1 = src[srcOffset + 1];
        var s2 = src[srcOffset + read2];
        var sa = src[srcOffset + 3];
        if (alpha != 255) {
          s0 = mul255(s0, alpha);
          s1 = mul255(s1, alpha);
          s2 = mul255(s2, alpha);
          sa = mul255(sa, alpha);
        }
        // The three equations themselves live in `blend.dart` and are shared
        // with the per-primitive path below, which is the point: a layer
        // composited with `plus` and a rectangle drawn with `plus` must round
        // identically, and they cannot drift apart if there is one copy of the
        // arithmetic.
        switch (blendMode) {
          case CpuBlendMode.srcOver:
            blendPixelOver(_pixels, dstOffset, s0, s1, s2, sa);
          case CpuBlendMode.src:
            blendPixelSrc(_pixels, dstOffset, s0, s1, s2, sa);
          case CpuBlendMode.plus:
            blendPixelPlus(_pixels, dstOffset, s0, s1, s2, sa);
        }
        srcOffset += 4;
        dstOffset += 4;
      }
    }
  }

  /// Composites [source] source-over at [destination]'s top-left corner.
  ///
  /// One source pixel per destination pixel: there is no scaling and no
  /// filtering. [destination] positions the blit and bounds it, so a
  /// destination smaller than [source] crops the source and a larger one
  /// leaves the remainder of the destination untouched. Cropping rather than
  /// scaling is the honest behaviour for a routine with no resampling in it -
  /// silently stretching would produce a nearest-neighbour result that looks
  /// like a bug in whatever asked for it. Scaled draws want a separate entry
  /// point with a stated filter.
  ///
  /// [source] may differ from [target] in both `bytesPerRow` and
  /// `PixelFormat`. Strides are taken from each buffer independently, and a
  /// format mismatch is handled by swapping red and blue as the pixels are
  /// read - both formats are premultiplied, so nothing else has to change.
  ///
  /// [blendMode] is chosen once per *row*, not once per pixel: the three cases
  /// below each own the whole inner loop. A row is hundreds of pixels wide in
  /// any blit worth measuring, so the branch is amortised to nothing, and the
  /// duplication buys an inner loop with no test in it. Unlike a fill, the
  /// source colour is different for every pixel here, so there is no
  /// per-call scaling to hoist and the switch is as far out as it can go
  /// without three copies of the addressing arithmetic.
  void drawFramebuffer(
    Framebuffer source,
    Rect destination, {
    CpuBlendMode blendMode = CpuBlendMode.srcOver,
  }) {
    final originX = pixelEdge(destination.left);
    final originY = pixelEdge(destination.top);

    // The blit covers the source's own extent, cropped by the destination
    // rectangle, then by the clip. Doing it in that order means the crop is
    // decided once here rather than being re-tested per pixel.
    final left = _max(originX, clip.left);
    final top = _max(originY, clip.top);
    final right = _min(
      _min(originX + source.width, pixelEdge(destination.right)),
      clip.right,
    );
    final bottom = _min(
      _min(originY + source.height, pixelEdge(destination.bottom)),
      clip.bottom,
    );
    if (right <= left || bottom <= top) return;

    final src = source.pixels;
    final srcBytesPerRow = source.bytesPerRow;
    // Same trick as [_redIndex]: resolve the channel order into read offsets
    // before the loop, so a format mismatch costs an index and not a branch
    // per pixel.
    final srcRedIndex =
        source.format == PixelFormat.bgra8888Premultiplied ? 2 : 0;
    final read0 = srcRedIndex == _redIndex ? 0 : 2;
    final read2 = 2 - read0;

    for (var y = top; y < bottom; y++) {
      var srcOffset = (y - originY) * srcBytesPerRow + (left - originX) * 4;
      var dstOffset = y * _bytesPerRow + left * 4;
      switch (blendMode) {
        case CpuBlendMode.srcOver:
          for (var x = left; x < right; x++) {
            blendPixelOver(
              _pixels,
              dstOffset,
              src[srcOffset + read0],
              src[srcOffset + 1],
              src[srcOffset + read2],
              src[srcOffset + 3],
            );
            srcOffset += 4;
            dstOffset += 4;
          }
        case CpuBlendMode.src:
          for (var x = left; x < right; x++) {
            blendPixelSrc(
              _pixels,
              dstOffset,
              src[srcOffset + read0],
              src[srcOffset + 1],
              src[srcOffset + read2],
              src[srcOffset + 3],
            );
            srcOffset += 4;
            dstOffset += 4;
          }
        case CpuBlendMode.plus:
          for (var x = left; x < right; x++) {
            blendPixelPlus(
              _pixels,
              dstOffset,
              src[srcOffset + read0],
              src[srcOffset + 1],
              src[srcOffset + read2],
              src[srcOffset + 3],
            );
            srcOffset += 4;
            dstOffset += 4;
          }
      }
    }
  }
}

// dart:math's min/max are generic over num and go through a comparison that
// has to consider doubles and NaN. These are only ever handed clip edges.
@pragma('vm:prefer-inline')
int _min(int a, int b) => a < b ? a : b;

@pragma('vm:prefer-inline')
int _max(int a, int b) => a > b ? a : b;

@pragma('vm:prefer-inline')
double _minD(double a, double b) => a < b ? a : b;

@pragma('vm:prefer-inline')
double _maxD(double a, double b) => a > b ? a : b;
