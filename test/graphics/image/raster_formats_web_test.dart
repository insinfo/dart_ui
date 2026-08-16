@TestOn('browser')
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:dart_ui/src/graphics/image/raster_formats.dart';
import 'package:test/test.dart';

void main() {
  test('browser decode uses createImageBitmap before the Dart fallback',
      () async {
    final Uint8List webp = base64Decode(
      'UklGRiIAAABXRUJQVlA4IBYAAAAwAQCdASoBAAEADsD+JaQAA3AAAAAA',
    );
    final RasterDecodeResult result = await decodeImageAsyncWithCodec(webp);
    expect(result.isNative, isTrue);
    expect(result.codecName, 'Browser createImageBitmap');
    expect((result.image.width, result.image.height), (1, 1));
  });
}
