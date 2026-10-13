@TestOn('vm')
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:dart_ui/src/graphics/image/codecs/image_lib.dart' as image_lib;
import 'package:dart_ui/src/graphics/image/decoded_image.dart';
import 'package:dart_ui/src/graphics/image/image_errors.dart';
import 'package:dart_ui/src/graphics/image/png_encoder.dart';
import 'package:dart_ui/src/graphics/image/raster_formats.dart';
import 'package:test/test.dart';

/// Decoding to a size: what a thumbnail asks of the codecs.
void main() {
  /// [width]x[height], the left half red and the right half blue.
  image_lib.Image halves(int width, int height) {
    final image_lib.Image image = image_lib.Image(width: width, height: height);
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        if (x < width ~/ 2) {
          image.setPixelRgba(x, y, 255, 0, 0, 255);
        } else {
          image.setPixelRgba(x, y, 0, 0, 255, 255);
        }
      }
    }
    return image;
  }

  final Map<String, Uint8List> files = <String, Uint8List>{
    'png': encodePng(
      width: 128,
      height: 64,
      pixels: Uint8List.fromList(<int>[
        for (var y = 0; y < 64; y++)
          for (var x = 0; x < 128; x++)
            ...(x < 64 ? <int>[255, 0, 0, 255] : <int>[0, 0, 255, 255]),
      ]),
    ),
    'jpeg': image_lib.encodeJpg(halves(128, 64), quality: 100),
  };

  for (final MapEntry<String, Uint8List> file in files.entries) {
    for (final bool preferNative in <bool>[true, false]) {
      test(
          '${file.key}, native: $preferNative - fits the longest side, '
          'in proportion, the picture intact', () {
        final RasterDecodeResult result = decodeImageWithCodec(
          file.value,
          order: ImageChannelOrder.rgba,
          preferNative: preferNative,
          maxSide: 16,
        );
        final DecodedImage image = result.image;
        final String codec = result.codecName;
        expect((image.width, image.height), (16, 8), reason: codec);
        final int middle = 4 * image.width * 4;
        expect(image.pixels[middle], greaterThan(200), reason: 'left red');
        expect(image.pixels[middle + 2], lessThan(60), reason: 'left red');
        final int right = middle + 15 * 4;
        expect(image.pixels[right], lessThan(60), reason: 'right blue');
        expect(image.pixels[right + 2], greaterThan(200), reason: 'right');
      });

      test('${file.key}, native: $preferNative - never enlarged', () {
        final DecodedImage image = decodeImage(
          file.value,
          preferNative: preferNative,
          maxSide: 1000,
        );
        expect((image.width, image.height), (128, 64));
      });
    }
  }

  test('past the pixel budget a native codec still makes a thumbnail', () {
    const RasterImageLimits limits = RasterImageLimits(maxPixels: 4000);
    final Uint8List png = files['png']!;
    expect(
      () => decodeImage(png, limits: limits),
      throwsA(isA<ImageBudgetException>()),
      reason: '128x64 is 8192 pixels',
    );
    // ImageIO and WIC read PNG; libjpeg-turbo, on Linux, does not.
    if (Platform.isMacOS || Platform.isWindows) {
      final DecodedImage image = decodeImage(png, limits: limits, maxSide: 16);
      expect((image.width, image.height), (16, 8));
    }
  }, skip: Platform.isMacOS || Platform.isWindows ? false : 'no PNG codec');

  test('fitImageSize keeps the proportions and at least a pixel', () {
    expect(fitImageSize(6000, 4000, 256), (256, 171));
    expect(fitImageSize(4000, 6000, 256), (171, 256));
    expect(fitImageSize(10000, 1, 100), (100, 1));
    expect(fitImageSize(100, 50, null), (100, 50));
    expect(fitImageSize(100, 50, 200), (100, 50));
  });

  group('resample', () {
    // One row, alternating white and transparent.
    final DecodedImage stripes = DecodedImage(
      width: 4,
      height: 1,
      order: ImageChannelOrder.rgba,
      pixels: Uint8List.fromList(<int>[
        255, 255, 255, 255, 0, 0, 0, 0, //
        255, 255, 255, 255, 0, 0, 0, 0,
      ]),
      hasAlpha: true,
    );

    test('box averages what each pixel covers', () {
      final DecodedImage half = stripes.resample(
        width: 2,
        height: 1,
        filter: ResampleFilter.box,
      );
      expect(half.pixels, <int>[128, 128, 128, 128, 128, 128, 128, 128]);
    });

    test('nearest picks one of them', () {
      final DecodedImage half = stripes.resample(width: 2, height: 1);
      expect(half.pixels.toSet(), anyOf(<int>{0}, <int>{255}));
    });

    test('box enlarging is nearest', () {
      final DecodedImage twice = stripes.resample(
        width: 8,
        height: 2,
        filter: ResampleFilter.box,
      );
      expect(twice.pixels, stripes.resample(width: 8, height: 2).pixels,
          reason: 'no blur');
    });
  });
}
