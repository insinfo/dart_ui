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
/// ANTIALIASING IS NOT IMPLEMENTED. Every fill covers whole pixels, and an
/// edge at x = 10.5 lands at 10 or 11 rather than half-covering a column. That
/// is a real limitation with a real reason to wait: [ClipStack] is integer and
/// rectangle-only, so an antialiased fill today would be soft on the edges the
/// clip does not touch and hard on the edges it does, which looks worse than
/// uniformly hard edges and produces a seam that moves when a clip changes.
/// The two have to land together.
///
/// Where that seam is, concretely: coverage is already expressible as an alpha.
/// An antialiased fill computes a per-pixel coverage byte for the partially
/// covered rows and columns (for an axis-aligned rectangle, the product of the
/// fractional overlap in x and in y - exact, not an approximation) and calls
/// the same [blendPixelOver] with `mul255(alpha, coverage)` and colour channels
/// scaled to match. The interior span is unchanged. So the work is a coverage
/// source, not a different compositor: nothing below this comment has to move.
library;

import 'dart:typed_data';

import '../../geometry/rect.dart';
import '../framebuffer.dart';
import 'blend.dart';
import 'clip_stack.dart';

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

  /// Fills [rect] with [argbColor] composited source-over.
  ///
  /// [argbColor] is `0xAARRGGBB` with *straight* alpha, the form a colour
  /// arrives in from anything user-facing; it is premultiplied here, once per
  /// call rather than once per pixel. The framebuffer stays premultiplied
  /// throughout.
  ///
  /// Coverage is integer: each pixel is either fully in or fully out, edges
  /// rounded to the nearest pixel by [pixelEdge]. See the library comment for
  /// why antialiasing is not here yet.
  void fillRect(Rect rect, int argbColor) {
    final alpha = (argbColor >> 24) & 0xff;
    // Fully transparent draws are common enough in real UIs - a faded-out
    // layer, an animation at t=0 - to be worth leaving before any clipping
    // arithmetic happens at all.
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

    if (alpha == 255) {
      _fillOpaque(left, top, right, bottom, c0, green, c2);
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
  }

  /// The opaque case of [fillRect], with the alpha test hoisted out.
  ///
  /// `blendPixelOver` would take the same branch on every pixel of the span,
  /// and it would take it correctly - but the alpha of a solid fill is a
  /// constant, so the decision belongs outside both loops rather than inside
  /// the inner one.
  void _fillOpaque(
    int left,
    int top,
    int right,
    int bottom,
    int c0,
    int c1,
    int c2,
  ) {
    for (var y = top; y < bottom; y++) {
      var offset = y * _bytesPerRow + left * 4;
      for (var x = left; x < right; x++) {
        _pixels[offset] = c0;
        _pixels[offset + 1] = c1;
        _pixels[offset + 2] = c2;
        _pixels[offset + 3] = 255;
        offset += 4;
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
  void drawFramebuffer(Framebuffer source, Rect destination) {
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
    }
  }
}

// dart:math's min/max are generic over num and go through a comparison that
// has to consider doubles and NaN. These are only ever handed clip edges.
@pragma('vm:prefer-inline')
int _min(int a, int b) => a < b ? a : b;

@pragma('vm:prefer-inline')
int _max(int a, int b) => a > b ? a : b;
