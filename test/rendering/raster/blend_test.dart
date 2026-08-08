import 'dart:typed_data';

import 'package:dart_ui/src/rendering/raster/blend.dart';
import 'package:test/test.dart';

/// Round half up of `value * alpha / 255`, computed the slow obvious way.
///
/// The point of the exhaustive tests below is that the shift trick in
/// [mul255] is not merely close to this - it is this, for every one of the
/// 65536 inputs.
int reference(int value, int alpha) => (value * alpha * 2 + 255) ~/ 510;

void main() {
  group('mul255', () {
    test('matches round(v * a / 255) over the entire input domain', () {
      for (var value = 0; value <= 255; value++) {
        for (var alpha = 0; alpha <= 255; alpha++) {
          expect(
            mul255(value, alpha),
            reference(value, alpha),
            reason: 'mul255($value, $alpha)',
          );
        }
      }
    });

    test('agrees with the (v * a + 127) ~/ 255 formulation everywhere', () {
      // Documented in blend.dart as an equivalence rather than an
      // approximation, so it is worth holding to that claim: if a future
      // change to mul255 breaks it, the doc comment is wrong too.
      for (var value = 0; value <= 255; value++) {
        for (var alpha = 0; alpha <= 255; alpha++) {
          expect(mul255(value, alpha), (value * alpha + 127) ~/ 255);
        }
      }
    });

    test('alpha 255 is the identity, so white survives a scale by one', () {
      for (var value = 0; value <= 255; value++) {
        expect(mul255(value, 255), value);
      }
      expect(mul255(255, 255), 255);
    });

    test('alpha 0 annihilates, so black stays black', () {
      for (var value = 0; value <= 255; value++) {
        expect(mul255(value, 0), 0);
      }
    });

    test('never leaves the byte range', () {
      for (var value = 0; value <= 255; value++) {
        for (var alpha = 0; alpha <= 255; alpha++) {
          final result = mul255(value, alpha);
          expect(result, inInclusiveRange(0, 255));
        }
      }
    });
  });

  group('blendPixelOver', () {
    /// A one-pixel destination preloaded with a known colour.
    Uint8List pixel(int c0, int c1, int c2, int a) =>
        Uint8List.fromList(<int>[c0, c1, c2, a]);

    test('alpha 0 leaves every byte alone', () {
      final dst = pixel(10, 20, 30, 40);

      blendPixelOver(dst, 0, 200, 200, 200, 0);

      expect(dst, <int>[10, 20, 30, 40]);
    });

    test('alpha 255 replaces the destination outright', () {
      final dst = pixel(10, 20, 30, 40);

      blendPixelOver(dst, 0, 1, 2, 3, 255);

      expect(dst, <int>[1, 2, 3, 255]);
    });

    test('opaque white and opaque black round-trip exactly', () {
      final dst = pixel(123, 45, 67, 89);

      blendPixelOver(dst, 0, 255, 255, 255, 255);
      expect(dst, <int>[255, 255, 255, 255]);

      blendPixelOver(dst, 0, 0, 0, 0, 255);
      expect(dst, <int>[0, 0, 0, 255]);
    });

    test('half-alpha white over opaque black gives 128 grey, alpha 255', () {
      // Premultiplying white by 128 gives 128 in each colour channel, and the
      // destination contributes mul255(0, 127) = 0, so the colour is exactly
      // 128. The alpha is 128 + mul255(255, 127) = 128 + 127 = 255: source-over
      // onto an opaque destination must stay opaque, and this is the assertion
      // that catches a rounding scheme that lets it drift to 254.
      final dst = pixel(0, 0, 0, 255);

      blendPixelOver(dst, 0, 128, 128, 128, 128);

      expect(dst, <int>[128, 128, 128, 255]);
    });

    test('half-alpha white over opaque white stays white', () {
      final dst = pixel(255, 255, 255, 255);

      blendPixelOver(dst, 0, 128, 128, 128, 128);

      expect(dst, <int>[255, 255, 255, 255]);
    });

    test('half-alpha black over opaque white halves the colour', () {
      // Premultiplied black at alpha 128 is (0, 0, 0, 128), so each channel
      // becomes mul255(255, 127) = 127.
      final dst = pixel(255, 255, 255, 255);

      blendPixelOver(dst, 0, 0, 0, 0, 128);

      expect(dst, <int>[127, 127, 127, 255]);
    });

    test('compositing onto a transparent destination keeps the source', () {
      final dst = pixel(0, 0, 0, 0);

      blendPixelOver(dst, 0, 64, 32, 16, 128);

      expect(dst, <int>[64, 32, 16, 128]);
    });

    test('an opaque destination stays opaque for every source alpha', () {
      // The classic visible bug is a destination that leaks towards
      // transparent as translucent things are drawn on it.
      for (var alpha = 0; alpha <= 255; alpha++) {
        final dst = pixel(10, 20, 30, 255);
        blendPixelOver(dst, 0, mul255(200, alpha), 0, 0, alpha);
        expect(dst[3], 255, reason: 'source alpha $alpha');
      }
    });

    test('writes only the four bytes at the offset it was given', () {
      final buffer = Uint8List(12)..fillRange(0, 12, 0x5A);

      blendPixelOver(buffer, 4, 1, 2, 3, 200);

      expect(buffer.sublist(0, 4), <int>[0x5A, 0x5A, 0x5A, 0x5A]);
      expect(buffer.sublist(8, 12), <int>[0x5A, 0x5A, 0x5A, 0x5A]);
    });
  });

  group('premultiply', () {
    test('scales a straight channel by its own alpha', () {
      expect(premultiply(255, 128), 128);
      expect(premultiply(255, 255), 255);
      expect(premultiply(255, 0), 0);
      expect(premultiply(0, 255), 0);
    });
  });

  group('blendChannelOver', () {
    test('is source plus destination scaled by the inverse alpha', () {
      expect(blendChannelOver(100, 200, 0), 100);
      expect(blendChannelOver(0, 200, 255), 200);
      expect(blendChannelOver(128, 255, 127), 128 + 127);
    });
  });
}
