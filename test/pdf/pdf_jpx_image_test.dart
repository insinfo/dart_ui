@TestOn('vm')
library;

import 'dart:typed_data';

import 'package:dart_ui/src/graphics/image/decoded_image.dart';
import 'package:dart_ui/src/pdf/format/pdf_object.dart';
import 'package:dart_ui/src/pdf/render/pdf_image_decoder.dart';
import 'package:jpeg2000/jpeg2000.dart' as jp2;
import 'package:test/test.dart';

/// `/JPXDecode` image XObjects: the filter chain passes the JP2 bytes through
/// untouched and this decoder has to recognise them instead of reading them
/// as packed samples.
void main() {
  Uint8List rgbaJp2() => jp2.encodeJpeg2000Pixels(
        Uint8List.fromList(<int>[200, 100, 50, 128, 10, 20, 30, 255]),
        width: 2,
        height: 1,
        components: 4,
        options: const jp2.Jpeg2000EncodeOptions(wrapInJp2: true),
      );

  test('decodes a JPX stream with no image dictionary keys at all', () {
    final Uint8List bytes = jp2.encodeJpeg2000Pixels(
      Uint8List.fromList(<int>[0, 255]),
      width: 2,
      height: 1,
      components: 1,
      options: const jp2.Jpeg2000EncodeOptions(wrapInJp2: true),
    );
    final DecodedImage? image = decodePdfImage(
      bytes: bytes,
      width: 2,
      height: 1,
      dictionary: PdfDict(<String, PdfObject>{
        'Filter': const PdfName('JPXDecode'),
      }),
    );
    expect(image, isNotNull);
    expect(image!.pixels, <int>[0, 0, 0, 255, 255, 255, 255, 255]);
  });

  test('ignores the opacity channel unless SMaskInData says otherwise', () {
    final DecodedImage? image = decodePdfImage(
      bytes: rgbaJp2(),
      width: 2,
      height: 1,
      dictionary: PdfDict(<String, PdfObject>{
        'Filter': const PdfName('JPXDecode'),
        'ColorSpace': const PdfName('DeviceRGB'),
      }),
    );
    expect(image, isNotNull);
    expect(image!.hasAlpha, isFalse);
    expect(image.pixels, <int>[50, 100, 200, 255, 30, 20, 10, 255]);
  });

  test('uses the opacity channel with SMaskInData 1', () {
    final DecodedImage? image = decodePdfImage(
      bytes: rgbaJp2(),
      width: 2,
      height: 1,
      dictionary: PdfDict(<String, PdfObject>{
        'Filter': const PdfName('JPXDecode'),
        'SMaskInData': const PdfNumber(1),
      }),
    );
    expect(image, isNotNull);
    expect(image!.hasAlpha, isTrue);
    expect(image.pixels, <int>[
      premultiplyChannel(50, 128),
      premultiplyChannel(100, 128),
      premultiplyChannel(200, 128),
      128,
      30,
      20,
      10,
      255,
    ]);
  });

  test('a raw J2K codestream works as well as a JP2 container', () {
    final Uint8List bytes = jp2.encodeJpeg2000Pixels(
      Uint8List.fromList(<int>[9]),
      width: 1,
      height: 1,
      components: 1,
    );
    final DecodedImage? image = decodePdfImage(
      bytes: bytes,
      width: 1,
      height: 1,
      dictionary: PdfDict(<String, PdfObject>{
        'Filter': const PdfName('JPXDecode'),
      }),
    );
    expect(image?.pixels, <int>[9, 9, 9, 255]);
  });
}
