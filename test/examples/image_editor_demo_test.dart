@TestOn('vm')
library;

import 'dart:typed_data';

import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

import '../../examples/image_editor_demo/main.dart';

/// The editor's document and encoders, without a window: paint a stroke,
/// save in every format the toolbar offers, and read each file back through
/// the same dispatcher the app uses.
void main() {
  PaintDocument painted() {
    final PaintDocument document = PaintDocument.blank(64, 48);
    document.stroke(
      const Offset(8, 8),
      const Offset(56, 40),
      4,
      const Color(0xFFE53935),
    );
    return document;
  }

  test('a stroke lands where the pointer went', () {
    final PaintDocument document = painted();
    const int onStroke = (24 * 64 + 32) * 4;
    expect(document.pixels.sublist(onStroke, onStroke + 4),
        <int>[0x35, 0x39, 0xE5, 0xFF]);
    const int offStroke = (2 * 64 + 60) * 4;
    expect(document.pixels.sublist(offStroke, offStroke + 4),
        <int>[0xFF, 0xFF, 0xFF, 0xFF]);
  });

  for (final SaveFormat format in SaveFormat.values) {
    test('${format.name} round-trips through decodeImage', () {
      final PaintDocument document = painted();
      final Uint8List bytes = encodeDocument(document, format);
      final RasterDecodeResult result =
          decodeImageWithCodec(bytes, preferNative: false);
      expect(result.image.width, 64, reason: format.name);
      expect(result.image.height, 48, reason: format.name);
      const int onStroke = (24 * 64 + 32) * 4;
      final List<int> pixel =
          result.image.pixels.sublist(onStroke, onStroke + 4);
      // JPEG is lossy; the others are exact.
      final int tolerance = format == SaveFormat.jpeg ? 12 : 0;
      expect((pixel[0] - 0x35).abs(), lessThanOrEqualTo(tolerance));
      expect((pixel[1] - 0x39).abs(), lessThanOrEqualTo(tolerance));
      expect((pixel[2] - 0xE5).abs(), lessThanOrEqualTo(tolerance));
      expect(pixel[3], 255);
    });
  }

  test('a JP2 with alpha keeps it through save and load', () {
    final DecodedImage source = DecodedImage(
      width: 2,
      height: 1,
      order: ImageChannelOrder.bgra,
      pixels: Uint8List.fromList(<int>[0, 0, 0, 0, 100, 50, 25, 200]),
      hasAlpha: true,
    );
    final PaintDocument document = PaintDocument.fromDecoded(source);
    final Uint8List bytes = encodeDocument(document, SaveFormat.jp2);
    final DecodedImage back = decodeImage(bytes, preferNative: false);
    expect(back.hasAlpha, isTrue);
    expect(back.pixels, source.pixels);
  });
}
