/// Decoded pixels, and the two conventions every decoder in this directory
/// must already have honoured before it hands them over.
///
/// ## Premultiplied, always
///
/// The rasteriser composites in **premultiplied** alpha end to end - see
/// `rendering/raster/blend.dart`, where `mul255` is the one rounding every
/// path shares - and every surface the platforms present is premultiplied too.
/// PNG, PSD, and essentially every interchange format store **straight**
/// alpha, because that is what an editor wants to round-trip.
///
/// Somebody has to convert, and doing it here, once, at decode time, is the
/// only place it is free: the alternative is a divide and a multiply per pixel
/// per frame, forever. So [DecodedImage.pixels] is premultiplied and
/// [premultiplyChannel] is how it got that way.
///
/// Skipping the conversion does not produce a wrong-looking image in the
/// obvious cases, which is exactly why it is worth stating. A fully opaque
/// image is identical either way, and a fully transparent one is invisible
/// either way. The difference shows only at *partial* alpha, as a bright
/// fringe - a "halo" - around every soft edge, because the compositor scales a
/// colour that was already meant to be scaled. An icon with an antialiased
/// outline is where it appears first.
///
/// ## Channel order is a property of the target, not of the file
///
/// `PixelFormat` in the rendering layer has both `bgra8888Premultiplied` and
/// `rgba8888Premultiplied`, because the platforms genuinely disagree: a Win32
/// DIB, an X11 image and a CoreGraphics context want blue first, and a GL or
/// Vulkan surface usually wants red first. A decoder that always produced one
/// of them would put a swizzle pass on every draw on half the platforms.
///
/// So [ImageChannelOrder] is an *input* to decoding, and the caller passes the
/// order its target uses. This has already gone wrong once in this repository
/// in the other direction - `Framebuffer.clear` wrote BGRA unconditionally
/// while `clearRect` branched on the format, and no test caught it because
/// every test cleared to black, where the two agree. Both orders are therefore
/// tested here on colours where they differ.
///
/// ## Why this type is not a `Framebuffer`
///
/// `Framebuffer` lives in the rendering layer, and section 8.2 forbids
/// `graphics` from depending on `rendering` -
/// `test/architecture/layering_test.dart` enforces it. A decoder is not a
/// renderer: it turns bytes into pixels, and which surface those pixels are
/// destined for is not its business. The widgets layer, which may name both,
/// is where one becomes the other.
library;

import 'dart:typed_data';

import '../../geometry/rect.dart';
import '../../geometry/size.dart';

/// Which byte comes first in a 32-bit pixel.
///
/// Both are premultiplied; there is no straight-alpha member, for the reason
/// in the library comment.
enum ImageChannelOrder {
  /// Blue, green, red, alpha - what a Win32 DIB, an X11 image and a
  /// CoreGraphics little-endian context expect. Matches
  /// `PixelFormat.bgra8888Premultiplied`.
  bgra,

  /// Red, green, blue, alpha - what GL and Vulkan surfaces usually prefer.
  /// Matches `PixelFormat.rgba8888Premultiplied`.
  rgba;

  /// Byte position of the red channel inside a pixel.
  int get redIndex => this == ImageChannelOrder.bgra ? 2 : 0;

  /// Byte position of the blue channel inside a pixel.
  int get blueIndex => this == ImageChannelOrder.bgra ? 0 : 2;
}

/// Converts one straight-alpha channel byte to premultiplied.
///
/// **Byte-identical to `mul255` in `rendering/raster/blend.dart`**, and that is
/// a requirement rather than a coincidence: an image drawn at full coverage and
/// a rectangle filled with the same colour have to land on the same bytes, or
/// the seam between them shows. The layering rule forbids importing the
/// renderer's copy from here, so the arithmetic is repeated and
/// `test/graphics/image/decoded_image_test.dart` asserts the two agree on all
/// 65 536 inputs.
///
/// The `+ 0x80` and `+ (t >> 8)` are the standard exact-rounding trick for
/// dividing by 255: it gives `round(value * alpha / 255)` for every pair,
/// where the naive `>> 8` would be `floor(value * alpha / 256)` and would drift
/// darker by up to one unit on every channel of every pixel.
int premultiplyChannel(int channel, int alpha) {
  final int t = channel * alpha + 0x80;
  return (t + (t >> 8)) >> 8;
}

/// An image in memory: premultiplied, tightly packed, four bytes per pixel.
final class DecodedImage {
  DecodedImage({
    required this.width,
    required this.height,
    required this.order,
    required this.pixels,
    required this.hasAlpha,
  })  : assert(width > 0 && height > 0),
        assert(pixels.length == width * height * 4);

  /// An opaque image of one colour, for tests and placeholders.
  factory DecodedImage.filled({
    required int width,
    required int height,
    required int argb,
    ImageChannelOrder order = ImageChannelOrder.bgra,
  }) {
    final int alpha = argb >> 24 & 0xFF;
    final int red = premultiplyChannel(argb >> 16 & 0xFF, alpha);
    final int green = premultiplyChannel(argb >> 8 & 0xFF, alpha);
    final int blue = premultiplyChannel(argb & 0xFF, alpha);
    final Uint8List pixels = Uint8List(width * height * 4);
    for (int i = 0; i < pixels.length; i += 4) {
      pixels[i + order.redIndex] = red;
      pixels[i + 1] = green;
      pixels[i + order.blueIndex] = blue;
      pixels[i + 3] = alpha;
    }
    return DecodedImage(
      width: width,
      height: height,
      order: order,
      pixels: pixels,
      hasAlpha: alpha != 255,
    );
  }

  final int width;
  final int height;

  /// The order [pixels] is in. Chosen by whoever asked for the decode.
  final ImageChannelOrder order;

  /// `width * height * 4` bytes, row-major, **premultiplied**, no padding
  /// between rows.
  ///
  /// No stride: a decoded image is this decoder's own allocation, so there is
  /// nothing for a stride to accommodate. A `Framebuffer` has one because it
  /// may wrap memory a platform gave it.
  final Uint8List pixels;

  /// Whether the source carried any transparency at all.
  ///
  /// Not derived from the pixels - an image may be fully opaque and still have
  /// an alpha channel - and useful because an opaque image can be blitted with
  /// `src` rather than `srcOver`.
  final bool hasAlpha;

  Size get size => Size(width.toDouble(), height.toDouble());

  Rect get bounds => Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble());

  int get bytesPerRow => width * 4;

  /// The `0xAARRGGBB` value of the pixel at ([x], [y]), **undone back to
  /// straight alpha** so that a test can compare it to the colour that was
  /// encoded.
  ///
  /// Un-premultiplying is lossy - it divides by the alpha the encode
  /// multiplied by - so this is a diagnostic, not a conversion to build a
  /// pipeline on. At `alpha == 0` all colour information is genuinely gone and
  /// this answers transparent black.
  int argbAt(int x, int y) {
    final int offset = (y * width + x) * 4;
    final int alpha = pixels[offset + 3];
    if (alpha == 0) return 0;
    int unpremultiply(int channel) {
      if (alpha == 255) return channel;
      final int value = (channel * 255 / alpha).round();
      return value > 255 ? 255 : value;
    }

    return alpha << 24 |
        unpremultiply(pixels[offset + order.redIndex]) << 16 |
        unpremultiply(pixels[offset + 1]) << 8 |
        unpremultiply(pixels[offset + order.blueIndex]);
  }

  /// The same pixels in the other channel order.
  ///
  /// Returns `this` when the order already matches, so a caller may use it
  /// unconditionally without paying for a copy it does not need.
  DecodedImage inOrder(ImageChannelOrder target) {
    if (target == order) return this;
    final Uint8List swapped = Uint8List(pixels.length);
    for (int i = 0; i < pixels.length; i += 4) {
      swapped[i] = pixels[i + 2];
      swapped[i + 1] = pixels[i + 1];
      swapped[i + 2] = pixels[i];
      swapped[i + 3] = pixels[i + 3];
    }
    return DecodedImage(
      width: width,
      height: height,
      order: target,
      pixels: swapped,
      hasAlpha: hasAlpha,
    );
  }

  /// A [width]x[height] copy of the region [source], sampled nearest-neighbour.
  ///
  /// ## Why the caller resamples at all
  ///
  /// The CPU rasteriser's image blit reads exactly one source pixel per
  /// destination pixel and says so: `CpuRasterizer.drawFramebuffer` crops
  /// rather than scaling, deliberately, because a blit with no resampling in it
  /// must not pretend to have one. So a widget that draws an image at any size
  /// other than its own has to produce the pixels at that size, and this is
  /// where it does.
  ///
  /// ## Nearest, and what that costs
  ///
  /// Nearest-neighbour: the destination pixel's centre is mapped back into
  /// [source] and the sample it lands in is copied. Exact, allocation-free per
  /// pixel, and identical on every machine, which is what makes a golden test
  /// of a scaled image mean anything.
  ///
  /// It is also visibly worse than a filtered resample at large scale factors -
  /// enlarging shows hard blocks, and shrinking by more than about half drops
  /// source pixels entirely and aliases. A box filter for minification and a
  /// bilinear one for magnification are the standard fix and are **not
  /// implemented here**; the honest place for them is a filter argument on this
  /// method, so that a caller chooses rather than discovers.
  ///
  /// Because the mapping is from destination centres, the operation is a pure
  /// function of the integers involved: scaling by one is the identity, and
  /// scaling by a whole number replicates each source pixel exactly that many
  /// times.
  DecodedImage resample({
    required int width,
    required int height,
    Rect? source,
  }) {
    final Rect from = source ?? bounds;
    if (width <= 0 || height <= 0) {
      throw ArgumentError(
        'resample to ${width}x$height: a decoded image has at least one pixel '
        'on each axis',
      );
    }
    final Uint8List out = Uint8List(width * height * 4);
    final double scaleX = from.width / width;
    final double scaleY = from.height / height;
    for (int y = 0; y < height; y++) {
      final int sourceY =
          ((from.top + (y + 0.5) * scaleY).floor()).clamp(0, this.height - 1);
      final int sourceRow = sourceY * this.width;
      int target = y * width * 4;
      for (int x = 0; x < width; x++) {
        final int sourceX =
            ((from.left + (x + 0.5) * scaleX).floor()).clamp(0, this.width - 1);
        final int offset = (sourceRow + sourceX) * 4;
        out[target] = pixels[offset];
        out[target + 1] = pixels[offset + 1];
        out[target + 2] = pixels[offset + 2];
        out[target + 3] = pixels[offset + 3];
        target += 4;
      }
    }
    return DecodedImage(
      width: width,
      height: height,
      order: order,
      pixels: out,
      hasAlpha: hasAlpha,
    );
  }

  @override
  String toString() => 'DecodedImage(${width}x$height, ${order.name}'
      '${hasAlpha ? ', alpha' : ''})';
}
