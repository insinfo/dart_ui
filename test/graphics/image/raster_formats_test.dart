import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dart_ui/src/graphics/image/codecs/image_lib.dart' as image_lib;
import 'package:dart_ui/src/graphics/image/decoded_image.dart';
import 'package:dart_ui/src/graphics/image/image_errors.dart';
import 'package:dart_ui/src/graphics/image/raster_formats.dart';
import 'package:test/test.dart';

Uint8List _jpeg({int? orientation}) {
  final image_lib.Image source = image_lib.Image(width: 2, height: 1)
    ..setPixelRgba(0, 0, 255, 0, 0, 255)
    ..setPixelRgba(1, 0, 0, 0, 255, 255);
  source.exif.imageIfd.orientation = orientation;
  return image_lib.encodeJpg(source, quality: 100);
}

int _crc32(List<int> bytes) {
  var crc = 0xFFFFFFFF;
  for (final int byte in bytes) {
    crc ^= byte;
    for (var i = 0; i < 8; i++) {
      crc = (crc >> 1) ^ (0xEDB88320 & -(crc & 1));
    }
  }
  return ~crc & 0xFFFFFFFF;
}

Uint8List _pngChunk(String type, List<int> data) {
  final BytesBuilder builder = BytesBuilder();
  final Uint8List length = Uint8List(4);
  ByteData.view(length.buffer).setUint32(0, data.length);
  builder.add(length);
  final List<int> body = <int>[...type.codeUnits, ...data];
  builder.add(body);
  final Uint8List crc = Uint8List(4);
  ByteData.view(crc.buffer).setUint32(0, _crc32(body));
  builder.add(crc);
  return builder.toBytes();
}

/// Minimal RGBA PNG writer so the fixture needs no external encoder.
Uint8List _png() {
  const int width = 1;
  const int height = 1;
  final BytesBuilder builder = BytesBuilder()
    ..add(<int>[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
  final Uint8List ihdr = Uint8List(13);
  // A cascata escreve direto no buffer de `ihdr`; nao ha uso para a view.
  ByteData.view(ihdr.buffer)
    ..setUint32(0, width)
    ..setUint32(4, height)
    ..setUint8(8, 8)
    ..setUint8(9, 6);
  builder.add(_pngChunk('IHDR', ihdr));
  builder.add(
    _pngChunk(
      'IDAT',
      ZLibEncoder().convert(<int>[
        0,
        10,
        20,
        30,
        128,
      ]),
    ),
  );
  builder.add(_pngChunk('IEND', const <int>[]));
  return builder.toBytes();
}

// One opaque 1x1 WebP. Kept inline so the test is independent from files and
// exercises the RIFF size/chunk walk as well as the VP8 decoder.
Uint8List _webp() => base64Decode(
      'UklGRiIAAABXRUJQVlA4IBYAAAAwAQCdASoBAAEADsD+JaQAA3AAAAAA',
    );

void main() {
  test('sniffs formats from magic bytes', () {
    expect(sniffImageFormat(_jpeg()), RasterImageFormat.jpeg);
    expect(sniffImageFormat(_webp()), RasterImageFormat.webp);
    expect(sniffImageFormat(Uint8List.fromList(<int>[1, 2, 3])), isNull);
  });

  test('JPEG decodes into the requested premultiplied channel order', () {
    final DecodedImage bgra = decodeJpeg(_jpeg());
    final DecodedImage rgba = decodeJpeg(
      _jpeg(),
      order: ImageChannelOrder.rgba,
    );

    expect(bgra.size.width, 2);
    expect(bgra.height, 1);
    expect(bgra.hasAlpha, isFalse);
    expect(bgra.order, ImageChannelOrder.bgra);
    expect(rgba.order, ImageChannelOrder.rgba);
    // JPEG is lossy, so assert the dominant channel rather than exact bytes.
    expect((bgra.argbAt(0, 0) >> 16) & 0xFF, greaterThan(200));
    expect(bgra.argbAt(0, 0) & 0xFF, lessThan(80));
    expect(rgba.argbAt(1, 0) & 0xFF, greaterThan(200));
  });

  test('uses the operating-system codec before the Dart fallback', () {
    final RasterDecodeResult result = decodeImageWithCodec(_jpeg());
    if (Platform.isWindows) {
      expect(result.isNative, isTrue);
      expect(result.codecName, contains('Windows Imaging Component'));
      final RasterDecodeResult png = decodeImageWithCodec(_png());
      expect(png.isNative, isTrue);
      expect(png.codecName, contains('Windows Imaging Component'));
      final int pixel = png.image.argbAt(0, 0);
      expect(pixel >> 24, 128);
      expect((pixel >> 16) & 0xFF, closeTo(10, 2));
      expect((pixel >> 8) & 0xFF, closeTo(20, 2));
      expect(pixel & 0xFF, closeTo(30, 2));
    } else if (Platform.isMacOS) {
      expect(result.isNative, isTrue);
      expect(result.codecName, contains('ImageIO'));
    }
    final RasterDecodeResult fallback = decodeImageWithCodec(
      _jpeg(),
      preferNative: false,
    );
    expect(fallback.isNative, isFalse);
    expect(fallback.codecName, contains('Dart'));
  });

  test('honours JPEG EXIF orientation in native and Dart codecs', () {
    final Uint8List oriented = _jpeg(orientation: 6);
    final DecodedImage preferred = decodeJpeg(oriented);
    final DecodedImage fallback = decodeJpeg(oriented, preferNative: false);
    expect((preferred.width, preferred.height), (1, 2));
    expect((fallback.width, fallback.height), (1, 2));
  });

  test('async dispatcher falls back deterministically when needed', () async {
    final RasterDecodeResult result = await decodeImageAsyncWithCodec(
      _jpeg(),
      preferNative: false,
    );
    expect(result.isNative, isFalse);
    expect((result.image.width, result.image.height), (2, 1));
  });

  test('WebP decodes through the shared dispatcher', () {
    final DecodedImage decoded = decodeImage(_webp());
    expect(decoded.width, 1);
    expect(decoded.height, 1);
    expect(decoded.pixels.length, 4);
  });

  test('limits are checked before allocating the decoded surface', () {
    expect(
      () => decodeJpeg(
        _jpeg(),
        limits: const RasterImageLimits(maxPixels: 1),
      ),
      throwsA(
        isA<ImageBudgetException>().having(
          (ImageBudgetException error) => error.budget,
          'budget',
          'maxPixels',
        ),
      ),
    );
  });

  test('unknown and malformed formats have named failures', () {
    expect(
      () => decodeImage(Uint8List.fromList(<int>[1, 2, 3])),
      throwsA(isA<UnsupportedImageFormatException>()),
    );
    expect(
      () => decodeJpeg(Uint8List.fromList(<int>[0xFF, 0xD8, 0xFF])),
      throwsA(isA<JpegDecodeException>()),
    );
    expect(() => decodeJpeg(_webp()), throwsA(isA<JpegDecodeException>()));
    expect(() => decodeWebP(_jpeg()), throwsA(isA<WebPDecodeException>()));
  });
}
