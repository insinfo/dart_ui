/// The decoded-pixel type, and the one arithmetic identity it has to keep.
library;

import 'dart:typed_data';

import 'package:dart_ui/src/geometry/rect.dart';
import 'package:dart_ui/src/graphics/image/decoded_image.dart';
import 'package:dart_ui/src/rendering/raster/blend.dart';
import 'package:test/test.dart';

void main() {
  group('premultiplyChannel', () {
    test('agrees with the rasteriser\'s mul255 on all 65 536 inputs', () {
      // The layering rule (section 8.2) forbids `graphics` from importing
      // `rendering`, so the arithmetic is written twice. A test is the only
      // thing that can keep the two copies equal, and it has to be exhaustive:
      // a rounding difference of one unit on one channel is invisible in any
      // picture and shows up as a seam where an image meets a fill.
      for (int channel = 0; channel < 256; channel++) {
        for (int alpha = 0; alpha < 256; alpha++) {
          expect(
            premultiplyChannel(channel, alpha),
            mul255(channel, alpha),
            reason: 'channel $channel, alpha $alpha',
          );
        }
      }
    });

    test('rounds rather than truncating', () {
      // The naive `(c * a) >> 8` would answer 127 here and drift darker on
      // every pixel of every image.
      expect(premultiplyChannel(255, 128), 128);
      expect(premultiplyChannel(255, 255), 255);
      expect(premultiplyChannel(255, 0), 0);
      expect(premultiplyChannel(0, 255), 0);
      expect(premultiplyChannel(200, 128), 100);
    });

    test('never exceeds the alpha it was multiplied by', () {
      // The invariant premultiplied compositing depends on: a channel above
      // its own alpha is not a colour, it is a bug that shows as a glow.
      for (int alpha = 0; alpha < 256; alpha++) {
        expect(premultiplyChannel(255, alpha), lessThanOrEqualTo(alpha));
      }
    });
  });

  group('channel order', () {
    test('redIndex and blueIndex are the two ends of the pixel', () {
      expect(ImageChannelOrder.bgra.redIndex, 2);
      expect(ImageChannelOrder.bgra.blueIndex, 0);
      expect(ImageChannelOrder.rgba.redIndex, 0);
      expect(ImageChannelOrder.rgba.blueIndex, 2);
    });

    test('filled writes the colour in the order it was asked for', () {
      final DecodedImage bgra = DecodedImage.filled(
        width: 2,
        height: 1,
        argb: 0xFF3366CC,
      );
      expect(bgra.pixels.sublist(0, 4), <int>[0xCC, 0x66, 0x33, 0xFF]);

      final DecodedImage rgba = DecodedImage.filled(
        width: 2,
        height: 1,
        argb: 0xFF3366CC,
        order: ImageChannelOrder.rgba,
      );
      expect(rgba.pixels.sublist(0, 4), <int>[0x33, 0x66, 0xCC, 0xFF]);
      expect(bgra.argbAt(0, 0), rgba.argbAt(0, 0));
    });

    test('a half-transparent fill is premultiplied on the way in', () {
      final DecodedImage image = DecodedImage.filled(
        width: 1,
        height: 1,
        argb: 0x80FFFFFF,
      );
      expect(image.pixels, <int>[128, 128, 128, 128]);
      expect(image.hasAlpha, isTrue);
    });
  });

  group('argbAt', () {
    test('round-trips an opaque colour exactly', () {
      final DecodedImage image =
          DecodedImage.filled(width: 1, height: 1, argb: 0xFF102030);
      expect(image.argbAt(0, 0), 0xFF102030);
    });

    test('is transparent black where alpha is zero', () {
      final DecodedImage image =
          DecodedImage.filled(width: 1, height: 1, argb: 0x00FF00FF);
      expect(image.argbAt(0, 0), 0);
    });

    test('un-premultiplying is lossy, within half a quantisation step', () {
      // Stated rather than hidden: premultiplying by alpha quantises the
      // channel to steps of 255/alpha, and no divide afterwards can recover
      // what fell between two steps. That is why this is a diagnostic and not a
      // conversion to build a pipeline on - and why the error grows as alpha
      // shrinks, which is exactly what the tolerance below tracks.
      for (final int alpha in <int>[16, 64, 128, 200, 254, 255]) {
        final int tolerance = (255 / alpha / 2).ceil() + 1;
        final DecodedImage image = DecodedImage.filled(
          width: 1,
          height: 1,
          argb: alpha << 24 | 0x9A5C21,
        );
        final int back = image.argbAt(0, 0);
        expect(back >> 24 & 0xFF, alpha);
        for (final (int shift, int original) in <(int, int)>[
          (16, 0x9A),
          (8, 0x5C),
          (0, 0x21),
        ]) {
          expect(
            (back >> shift & 0xFF) - original,
            inInclusiveRange(-tolerance, tolerance),
            reason: 'alpha $alpha, channel at bit $shift',
          );
        }
      }
    });
  });

  group('resample', () {
    /// Four pixels, each a distinguishable colour, as a 2x2.
    DecodedImage quadrants() {
      final Uint8List pixels = Uint8List.fromList(<int>[
        0, 0, 255, 255, // red
        0, 255, 0, 255, // green
        255, 0, 0, 255, // blue
        255, 255, 255, 255, // white
      ]);
      return DecodedImage(
        width: 2,
        height: 2,
        order: ImageChannelOrder.bgra,
        pixels: pixels,
        hasAlpha: false,
      );
    }

    test('scaling by one is the identity', () {
      final DecodedImage source = quadrants();
      expect(source.resample(width: 2, height: 2).pixels, source.pixels);
    });

    test('a whole-number enlargement replicates each pixel exactly', () {
      final DecodedImage big = quadrants().resample(width: 4, height: 4);
      expect(big.width, 4);
      // The top-left quadrant is four copies of the first pixel and nothing
      // else - a filtered resample would have blended the boundary.
      for (final (int x, int y) in <(int, int)>[
        (0, 0),
        (1, 0),
        (0, 1),
        (1, 1)
      ]) {
        expect(big.argbAt(x, y), 0xFFFF0000, reason: '($x, $y)');
      }
      expect(big.argbAt(3, 0), 0xFF00FF00);
      expect(big.argbAt(0, 3), 0xFF0000FF);
      expect(big.argbAt(3, 3), 0xFFFFFFFF);
    });

    test('a source rectangle crops before it scales', () {
      // The right-hand column only: green over white.
      final DecodedImage cropped = quadrants().resample(
        width: 1,
        height: 2,
        source: const Rect.fromLTRB(1, 0, 2, 2),
      );
      expect(cropped.width, 1);
      expect(cropped.argbAt(0, 0), 0xFF00FF00);
      expect(cropped.argbAt(0, 1), 0xFFFFFFFF);
    });

    test('shrinking picks samples rather than averaging them', () {
      // Nearest-neighbour by declaration: a 2x2 down to 1x1 answers one of the
      // four, not their mean. If this ever becomes a box filter, this test is
      // the one that should be changed deliberately.
      final DecodedImage tiny = quadrants().resample(width: 1, height: 1);
      expect(tiny.argbAt(0, 0),
          anyOf(0xFFFF0000, 0xFF00FF00, 0xFF0000FF, 0xFFFFFFFF));
    });

    test('a zero size is refused rather than producing an empty image', () {
      expect(
        () => quadrants().resample(width: 0, height: 4),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('the order and alpha flag survive', () {
      final DecodedImage source = DecodedImage.filled(
        width: 4,
        height: 4,
        argb: 0x80112233,
        order: ImageChannelOrder.rgba,
      );
      final DecodedImage scaled = source.resample(width: 2, height: 2);
      expect(scaled.order, ImageChannelOrder.rgba);
      expect(scaled.hasAlpha, isTrue);
      expect(scaled.pixels.length, 2 * 2 * 4);
    });
  });

  test('bytesPerRow is tight: a decoded image has no stride', () {
    final DecodedImage image =
        DecodedImage.filled(width: 7, height: 3, argb: 0xFF000000);
    expect(image.bytesPerRow, 28);
    expect(image.pixels.length, 84);
    expect(image.size.width, 7);
    expect(image.bounds, const Rect.fromLTRB(0, 0, 7, 3));
  });
}
