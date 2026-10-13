/// Colour glyphs - the pictures `sbix` and `CBDT` store - decoded, sized and
/// ready to blit.
///
/// The parser (`text/color_bitmaps.dart`) finds a glyph's compressed picture
/// and says where it goes. This file is the renderer's half, and it exists
/// for the same reason the glyph mask cache does: decoding a PNG is far more
/// expensive than drawing it, and the same few emoji are drawn on every frame.
///
/// Section 23.5 asks every cache to state the following, so here they are.
///
///  * **Key.** Decoded pictures are keyed by face identity, glyph and strike:
///    the strike is the picture, and two strikes are two different pictures.
///    Sized pictures are keyed by face identity, glyph and pixel size, because
///    that is what a run asks for, and the strike follows from it.
///  * **Size and eviction.** Two LRU maps of [maximumEntries] each, by count.
///    A count rather than bytes because the entries are of one kind and of
///    similar size - an emoji at a strike near the text size is a few
///    kilobytes - and a screen shows tens of distinct emoji, not thousands.
///  * **Invalidation.** None: a [Typeface] is immutable and is part of the
///    key, so a replaced face makes its entries unreachable, and they age out.
///  * **Failures are cached too.** A picture that does not decode is
///    remembered as null, so a corrupt glyph costs one failed decode per
///    process rather than one per frame. It then draws nothing - not its
///    outline, which in these faces is a placeholder box.
///
/// ## Why the picture is resampled here
///
/// The CPU renderer blits an image one source pixel to one destination pixel
/// (see `Rasterizer.drawFramebuffer`), so a picture must reach the display
/// list already at the size it is drawn. That is the same rule the `Image`
/// widget follows. The resample is a box filter, which is the right one for
/// the direction this almost always goes: the strike chosen is the smallest
/// one *at least* as large as the text, so the picture is shrunk, and only
/// slightly.
///
/// The [Framebuffer] handed out is the same instance for as long as the entry
/// lives, which is what lets a GPU backend upload the texture once rather than
/// once per frame.
library;

import 'dart:math' as math;

import '../../graphics/image/decoded_image.dart';
import '../../graphics/image/raster_formats.dart';
import '../../text/color_bitmaps.dart';
import '../../text/typeface.dart';
import '../framebuffer.dart';

/// One colour glyph at the size it is drawn, and where it goes.
final class ColorGlyphImage {
  const ColorGlyphImage({
    required this.image,
    required this.left,
    required this.top,
  });

  /// Premultiplied pixels, exactly [width] by [height].
  final Framebuffer image;

  /// From the pen position to the picture's left edge, in pixels.
  final double left;

  /// From the baseline to the picture's top edge, in pixels, **y down**: a
  /// picture standing on the baseline has `top == -height`.
  final double top;

  int get width => image.width;
  int get height => image.height;

  @override
  String toString() => 'ColorGlyphImage(${width}x$height at '
      '(${left.toStringAsFixed(1)}, ${top.toStringAsFixed(1)}))';
}

/// Decoded and sized colour glyphs, shared by every painter.
final class ColorGlyphCache {
  ColorGlyphCache({this.maximumEntries = 512});

  /// How many entries each of the two maps keeps; least recently used goes.
  final int maximumEntries;

  final Map<(Typeface, int, int), DecodedImage?> _decoded =
      <(Typeface, int, int), DecodedImage?>{};
  final Map<(Typeface, int, double), ColorGlyphImage?> _sized =
      <(Typeface, int, double), ColorGlyphImage?>{};

  int _decodes = 0;

  /// How many pictures have been decoded - the number a test asserts on to
  /// prove the cache works, and the one to look at when the first frame with
  /// emoji in it is slow.
  int get decodeCount => _decodes;

  /// [glyphId] of [face] as a picture at [pixelSize], or null when the glyph
  /// has none - or has one that could not be decoded - and is drawn from its
  /// outline instead.
  ///
  /// Asks the face for its colour table, so this is only worth calling for a
  /// face whose [Typeface.hasColorBitmaps] is true; a painter checks that once
  /// per run.
  ColorGlyphImage? lookup(Typeface face, int glyphId, double pixelSize) {
    final (Typeface, int, double) key = (face, glyphId, pixelSize);
    if (_sized.containsKey(key)) {
      final ColorGlyphImage? hit = _sized.remove(key);
      _sized[key] = hit;
      return hit;
    }
    final ColorGlyphImage? made = _make(face, glyphId, pixelSize);
    _sized[key] = made;
    _trim(_sized);
    return made;
  }

  ColorGlyphImage? _make(Typeface face, int glyphId, double pixelSize) {
    if (pixelSize <= 0) return null;
    final ColorBitmapGlyph? bitmap = face.colorBitmapOf(glyphId, pixelSize);
    if (bitmap == null) return null;
    final DecodedImage? decoded = _decode(face, bitmap);
    if (decoded == null) return null;

    final double scale = pixelSize / bitmap.ppem;
    final int width = math.max(1, (decoded.width * scale).round());
    final int height = math.max(1, (decoded.height * scale).round());
    final DecodedImage sized =
        width == decoded.width && height == decoded.height
            ? decoded
            : decoded.resample(
                width: width,
                height: height,
                filter: ResampleFilter.box,
              );
    return ColorGlyphImage(
      image: Framebuffer(
        width: sized.width,
        height: sized.height,
        bytesPerRow: sized.bytesPerRow,
        format: switch (sized.order) {
          ImageChannelOrder.bgra => PixelFormat.bgra8888Premultiplied,
          ImageChannelOrder.rgba => PixelFormat.rgba8888Premultiplied,
        },
        pixels: sized.pixels,
      ),
      // The table's origin is the picture's bottom-left corner, y up; the
      // display list is y down from the baseline. The decoded height, not a
      // stated one, because `sbix` states none and the image is the truth.
      left: bitmap.left * scale,
      top: -(bitmap.bottom + decoded.height) * scale,
    );
  }

  DecodedImage? _decode(Typeface face, ColorBitmapGlyph bitmap) {
    final (Typeface, int, int) key = (face, bitmap.glyphId, bitmap.strikeIndex);
    if (_decoded.containsKey(key)) {
      final DecodedImage? hit = _decoded.remove(key);
      _decoded[key] = hit;
      return hit;
    }
    DecodedImage? image;
    // `tiff` has no decoder in this framework; such a glyph draws nothing
    // rather than its placeholder outline.
    if (bitmap.format == 'png ' || bitmap.format == 'jpg ') {
      _decodes++;
      try {
        // The pure-Dart decoders, so a colour glyph is the same pixels on
        // every machine and a golden of one means something.
        image = decodeImage(bitmap.data, preferNative: false);
      } on Object {
        image = null;
      }
    }
    _decoded[key] = image;
    _trim(_decoded);
    return image;
  }

  void _trim<K, V>(Map<K, V> map) {
    while (map.length > maximumEntries) {
      map.remove(map.keys.first);
    }
  }

  /// Drops every entry. For a test, or to give memory back.
  void clear() {
    _decoded.clear();
    _sized.clear();
  }
}

/// The cache [TextPainter]s share unless they are given their own.
final ColorGlyphCache sharedColorGlyphCache = ColorGlyphCache();
