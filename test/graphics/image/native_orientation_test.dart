@TestOn('vm')
library;

import 'dart:typed_data';

import 'package:dart_ui/src/graphics/image/codecs/image_lib.dart' as image_lib;
import 'package:dart_ui/src/graphics/image/decoded_image.dart';
import 'package:dart_ui/src/graphics/image/raster_formats.dart';
import 'package:test/test.dart';

/// Row order of the platform decoders.
///
/// Every earlier native test used a one-row image, so a decoder that handed
/// back the rows bottom-up passed anyway. macOS ImageIO did exactly that
/// until the JPEG 2000 comparison caught it. This test uses two rows with
/// different colours and runs against whichever native decoder the platform
/// has (WIC, ImageIO, TurboJPEG); where there is none it still checks the
/// Dart path, so a regression in the shared adapter shows up everywhere.
void main() {
  Uint8List jpeg() {
    final image_lib.Image source = image_lib.Image(width: 1, height: 2)
      ..setPixelRgba(0, 0, 255, 0, 0, 255) // top: red
      ..setPixelRgba(0, 1, 0, 0, 255, 255); // bottom: blue
    return image_lib.encodeJpg(source, quality: 100);
  }

  test('the top row of the file is the first row of the pixels', () {
    final Uint8List bytes = jpeg();
    for (final bool preferNative in <bool>[true, false]) {
      final RasterDecodeResult result = decodeImageWithCodec(
        bytes,
        order: ImageChannelOrder.rgba,
        preferNative: preferNative,
      );
      final Uint8List pixels = result.image.pixels;
      final String codec = '${result.codecName} (native: ${result.isNative})';
      // JPEG at quality 100 is not exact, but red and blue are far apart.
      expect(pixels[0], greaterThan(200), reason: 'top red, $codec');
      expect(pixels[2], lessThan(60), reason: 'top not blue, $codec');
      expect(pixels[4], lessThan(60), reason: 'bottom not red, $codec');
      expect(pixels[6], greaterThan(200), reason: 'bottom blue, $codec');
    }
  });
}
