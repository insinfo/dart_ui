@TestOn('vm')
library;

import 'dart:typed_data';

import 'package:dart_ui/src/graphics/image/decoded_image.dart';
import 'package:dart_ui/src/graphics/image/image_errors.dart';
import 'package:dart_ui/src/graphics/image/raster_formats.dart';
import 'package:j2k/j2k.dart' as jp2;
import 'package:test/test.dart';

/// JPEG 2000 through the format dispatcher.
///
/// Every input is produced on the spot by the codec's own lossless encoder,
/// so the expected pixels are known exactly and no binary fixture is needed.
void main() {
  Uint8List encode(
    List<int> samples, {
    required int width,
    required int height,
    required int components,
    bool jp2Container = true,
  }) =>
      jp2.encodeJpeg2000Pixels(
        Uint8List.fromList(samples),
        width: width,
        height: height,
        components: components,
        options: jp2.Jpeg2000EncodeOptions(wrapInJp2: jp2Container),
      );

  group('sniffing', () {
    test('recognises the JP2 signature box and the raw SOC+SIZ markers', () {
      final Uint8List container =
          encode(<int>[1, 2, 3, 4], width: 2, height: 2, components: 1);
      final Uint8List raw = encode(<int>[1, 2, 3, 4],
          width: 2, height: 2, components: 1, jp2Container: false);
      expect(sniffImageFormat(container), RasterImageFormat.jpeg2000);
      expect(sniffImageFormat(raw), RasterImageFormat.jpeg2000);
      expect(isJpeg2000(container), isTrue);
      expect(isJpeg2000(raw), isTrue);
    });

    test('does not mistake other signatures or short input', () {
      expect(isJpeg2000(Uint8List.fromList(<int>[0xFF, 0x4F])), isFalse);
      expect(isJpeg2000(Uint8List.fromList(<int>[0xFF, 0xD8, 0xFF, 0xE0])),
          isFalse);
      expect(
        isJpeg2000(Uint8List.fromList(
            <int>[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 0])),
        isFalse,
      );
      expect(sniffImageFormat(Uint8List(0)), isNull);
    });
  });

  group('decoding', () {
    test('gray is replicated into the colour channels, opaque', () {
      final Uint8List bytes =
          encode(<int>[0, 128, 255, 7], width: 2, height: 2, components: 1);
      final DecodedImage image = decodeImage(bytes, preferNative: false);
      expect(image.width, 2);
      expect(image.height, 2);
      expect(image.hasAlpha, isFalse);
      expect(image.pixels, <int>[
        0, 0, 0, 255, //
        128, 128, 128, 255,
        255, 255, 255, 255,
        7, 7, 7, 255,
      ]);
    });

    test('RGB lands in the requested channel order', () {
      final Uint8List bytes =
          encode(<int>[200, 100, 50], width: 1, height: 1, components: 3);
      final DecodedImage bgra = decodeImage(bytes, preferNative: false);
      expect(bgra.pixels, <int>[50, 100, 200, 255]);
      final DecodedImage rgba = decodeImage(
        bytes,
        order: ImageChannelOrder.rgba,
        preferNative: false,
      );
      expect(rgba.pixels, <int>[200, 100, 50, 255]);
    });

    test('alpha from the cdef box is premultiplied with the shared rounding',
        () {
      final Uint8List bytes = encode(
        <int>[200, 100, 50, 128, 10, 20, 30, 255],
        width: 2,
        height: 1,
        components: 4,
      );
      final DecodedImage image = decodeImage(bytes, preferNative: false);
      expect(image.hasAlpha, isTrue);
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

    test('decodeJp2 can drop alpha, which PDF needs without SMaskInData', () {
      final Uint8List bytes = encode(
        <int>[200, 100, 50, 0],
        width: 1,
        height: 1,
        components: 4,
      );
      final DecodedImage image = decodeJp2(bytes, keepAlpha: false);
      expect(image.hasAlpha, isFalse);
      expect(image.pixels, <int>[50, 100, 200, 255]);
    });

    test('16-bit sources are scaled to 8 bits', () {
      final Uint8List bytes = jp2.encodeJpeg2000Pixels(
        Uint16List.fromList(<int>[0, 32768, 65535]),
        width: 3,
        height: 1,
        components: 1,
        bitsPerSample: 16,
      );
      final DecodedImage image = decodeImage(bytes, preferNative: false);
      expect(image.pixels, <int>[
        0, 0, 0, 255, //
        128, 128, 128, 255,
        255, 255, 255, 255,
      ]);
    });

    test('the codec name says which implementation ran', () {
      final Uint8List bytes =
          encode(<int>[1], width: 1, height: 1, components: 1);
      final RasterDecodeResult result =
          decodeImageWithCodec(bytes, preferNative: false);
      expect(result.isNative, isFalse);
      expect(result.codecName, contains('j2k'));
    });

    test('the asynchronous path decodes in a background isolate', () async {
      final Uint8List bytes =
          encode(<int>[9, 8, 7, 6], width: 2, height: 2, components: 1);
      final RasterDecodeResult result =
          await decodeImageAsyncWithCodec(bytes, preferNative: false);
      expect(result.image.pixels.length, 16);
      expect(result.image.pixels[0], 9);
      expect(result.codecName, contains('j2k'));
    });
  });

  group('refusals', () {
    test('a hostile SIZ is refused by the pixel budget before decoding', () {
      // SOC + SIZ declaring 100000 x 100000, one component, nothing else.
      final BytesBuilder builder = BytesBuilder();
      void u16(int v) => builder
        ..addByte(v >> 8 & 0xFF)
        ..addByte(v & 0xFF);
      void u32(int v) => builder
        ..addByte(v >> 24 & 0xFF)
        ..addByte(v >> 16 & 0xFF)
        ..addByte(v >> 8 & 0xFF)
        ..addByte(v & 0xFF);
      u16(0xFF4F);
      u16(0xFF51);
      u16(41);
      u16(0);
      u32(100000);
      u32(100000);
      u32(0);
      u32(0);
      u32(100000);
      u32(100000);
      u32(0);
      u32(0);
      u16(1);
      builder
        ..addByte(7)
        ..addByte(1)
        ..addByte(1);
      expect(
        () => decodeImage(builder.toBytes(), preferNative: false),
        throwsA(isA<ImageBudgetException>()),
      );
    });

    test('truncated data is reported as truncated', () {
      final Uint8List bytes = encode(
        List<int>.generate(64 * 64, (i) => i & 0xFF),
        width: 64,
        height: 64,
        components: 1,
      );
      expect(
        () => decodeImage(
          Uint8List.sublistView(bytes, 0, bytes.length ~/ 2),
          preferNative: false,
        ),
        throwsA(
          isA<Jpeg2000DecodeException>()
              .having((e) => e.kind, 'kind', Jpeg2000FailureKind.truncated),
        ),
      );
    });

    test('decodeJp2 refuses bytes that are not JPEG 2000', () {
      expect(
        () => decodeJp2(Uint8List.fromList(<int>[1, 2, 3, 4, 5])),
        throwsA(
          isA<Jpeg2000DecodeException>()
              .having((e) => e.kind, 'kind', Jpeg2000FailureKind.format),
        ),
      );
    });

    test('a JPEG 2000 refusal is an ImageDecodeException like the others', () {
      final Uint8List bytes =
          encode(<int>[1], width: 1, height: 1, components: 1);
      bytes[bytes.length - 1] ^= 0xFF;
      bytes[bytes.length - 2] ^= 0xFF;
      try {
        decodeImage(bytes, preferNative: false);
      } on ImageDecodeException catch (error) {
        expect(error, isA<Jpeg2000DecodeException>());
        return;
      }
      // A corrupted tail may still decode to something; that is not a
      // failure of the contract under test.
    });
  });
}
