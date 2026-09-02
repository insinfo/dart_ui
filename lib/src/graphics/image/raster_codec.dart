library;

import 'decoded_image.dart';
import 'image_errors.dart';

enum RasterImageFormat { png, jpeg, webp, jpeg2000 }

final class RasterImageLimits {
  const RasterImageLimits({
    this.maxEncodedBytes = 268435456,
    this.maxDimension = 16384,
    this.maxPixels = 16777216,
  });

  final int maxEncodedBytes;
  final int maxDimension;
  final int maxPixels;

  void checkEncodedLength(int length, RasterImageFormat format) {
    if (length > maxEncodedBytes) {
      throw ImageBudgetException(
        budget: 'maxEncodedBytes',
        limit: maxEncodedBytes,
        actual: length,
        message: '${format.name} input exceeds the encoded-byte budget',
      );
    }
  }

  void checkDimensions(int width, int height, RasterImageFormat format) {
    if (width <= 0 || height <= 0) {
      throw switch (format) {
        RasterImageFormat.jpeg => const JpegDecodeException(
            'JPEG declares a zero or negative dimension',
          ),
        RasterImageFormat.webp => const WebPDecodeException(
            'WebP declares a zero or negative dimension',
          ),
        RasterImageFormat.png => const PngHeaderException(
            'PNG declares a zero or negative dimension',
          ),
        RasterImageFormat.jpeg2000 => const Jpeg2000DecodeException(
            'JPEG 2000 declares a zero or negative dimension',
          ),
      };
    }
    final int largest = width > height ? width : height;
    if (largest > maxDimension) {
      throw ImageBudgetException(
        budget: 'maxDimension',
        limit: maxDimension,
        actual: largest,
        message: '${format.name} dimensions exceed the configured limit',
      );
    }
    final int pixels = width * height;
    if (pixels > maxPixels) {
      throw ImageBudgetException(
        budget: 'maxPixels',
        limit: maxPixels,
        actual: pixels,
        message: '${format.name} pixel count exceeds the configured limit',
      );
    }
  }
}

/// A decode plus the implementation that produced it.
final class RasterDecodeResult {
  const RasterDecodeResult({
    required this.image,
    required this.codecName,
    required this.isNative,
  });

  final DecodedImage image;
  final String codecName;
  final bool isNative;
}
