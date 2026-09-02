@TestOn('vm')
library;

import 'dart:typed_data';

import 'package:dart_ui/src/graphics/image/decoded_image.dart';
import 'package:dart_ui/src/graphics/image/raster_formats.dart';
import 'package:j2k/j2k.dart' as jp2;
import 'package:test/test.dart';

/// The platform JPEG 2000 decoder against the Dart one.
///
/// Windows (WIC) and Linux (TurboJPEG) have no JPEG 2000 codec, so there the
/// dispatcher must fall back to Dart and this file only proves that. macOS
/// ImageIO does decode JP2; the framework workflow runs `dart test test` on a
/// real macOS runner, which is where the comparison below is the actual
/// evidence for the native path.
void main() {
  Uint8List encode(List<int> samples, int components) =>
      jp2.encodeJpeg2000Pixels(
        Uint8List.fromList(samples),
        width: 4,
        height: 2,
        components: components,
        options: const jp2.Jpeg2000EncodeOptions(wrapInJp2: true),
      );

  final Uint8List rgb = encode(
    List<int>.generate(4 * 2 * 3, (i) => (i * 31) & 0xFF),
    3,
  );
  final Uint8List rgba = encode(
    List<int>.generate(4 * 2 * 4, (i) => i % 4 == 3 ? 200 : (i * 29) & 0xFF),
    4,
  );

  test('the native path, when there is one, agrees with the Dart decoder', () {
    for (final Uint8List bytes in <Uint8List>[rgb, rgba]) {
      final RasterDecodeResult native = decodeImageWithCodec(bytes);
      final DecodedImage dart = decodeImage(bytes, preferNative: false);
      if (!native.isNative) {
        expect(native.codecName, contains('jpeg2000'));
        continue;
      }
      expect(native.image.width, dart.width);
      expect(native.image.height, dart.height);
      expect(native.image.hasAlpha, dart.hasAlpha);
      // ImageIO draws through a CGContext, which may round colour-managed
      // samples differently by one step; alpha must match exactly.
      for (var i = 0; i < dart.pixels.length; i++) {
        final int tolerance = i % 4 == 3 ? 0 : 1;
        expect(
          (native.image.pixels[i] - dart.pixels[i]).abs(),
          lessThanOrEqualTo(tolerance),
          reason: 'byte $i: native ${native.image.pixels[i]} vs Dart '
              '${dart.pixels[i]} (${native.codecName})',
        );
      }
    }
  });
}
