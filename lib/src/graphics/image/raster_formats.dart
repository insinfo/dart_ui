/// Format sniffing and the non-PNG bitmap decoders.
///
/// PNG remains implemented inside this package because its exact filtering,
/// premultiplication and hostile-input checks form the reference decoder for
/// the renderer. JPEG and WebP are deliberately delegated to `package:image`,
/// a pure-Dart MIT implementation, then converted immediately into the one
/// pixel contract used by dart_ui: tightly packed, premultiplied RGBA/BGRA.
/// No `package:image` type crosses this library's public API.
library;

import 'dart:typed_data';

import 'package:image/image.dart' as image_lib;

import 'decoded_image.dart';
import 'image_errors.dart';
import 'native_raster_codec_async_stub.dart'
    if (dart.library.js_interop) 'native_raster_codec_web.dart';
import 'native_raster_codec_stub.dart'
    if (dart.library.io) 'native_raster_codec_io.dart';
import 'png.dart';
import 'raster_codec.dart';

export 'raster_codec.dart';

bool isJpeg(Uint8List bytes) =>
    bytes.length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xD8;

bool isWebP(Uint8List bytes) =>
    bytes.length >= 12 &&
    bytes[0] == 0x52 &&
    bytes[1] == 0x49 &&
    bytes[2] == 0x46 &&
    bytes[3] == 0x46 &&
    bytes[8] == 0x57 &&
    bytes[9] == 0x45 &&
    bytes[10] == 0x42 &&
    bytes[11] == 0x50;

/// Determines a bitmap format from its magic bytes, never from a file name.
RasterImageFormat? sniffImageFormat(Uint8List bytes) {
  if (isPng(bytes)) return RasterImageFormat.png;
  if (isJpeg(bytes)) return RasterImageFormat.jpeg;
  if (isWebP(bytes)) return RasterImageFormat.webp;
  return null;
}

/// Decodes PNG, JPEG, or WebP after inspecting the signature.
DecodedImage decodeImage(
  Uint8List bytes, {
  ImageChannelOrder order = ImageChannelOrder.bgra,
  PngLimits pngLimits = const PngLimits(),
  RasterImageLimits limits = const RasterImageLimits(),
  bool preferNative = true,
}) =>
    decodeImageWithCodec(
      bytes,
      order: order,
      pngLimits: pngLimits,
      limits: limits,
      preferNative: preferNative,
    ).image;

RasterDecodeResult decodeImageWithCodec(
  Uint8List bytes, {
  ImageChannelOrder order = ImageChannelOrder.bgra,
  PngLimits pngLimits = const PngLimits(),
  RasterImageLimits limits = const RasterImageLimits(),
  bool preferNative = true,
}) {
  final RasterImageFormat? format = sniffImageFormat(bytes);
  if (format == null) {
    throw const UnsupportedImageFormatException(
      'expected a PNG, JPEG, or WebP signature',
    );
  }
  limits.checkEncodedLength(bytes.length, format);
  if (preferNative) {
    final RasterDecodeResult? native = tryDecodeNativeRaster(
      bytes,
      format: format,
      order: order,
      limits: limits,
    );
    if (native != null) {
      return format == RasterImageFormat.jpeg
          ? RasterDecodeResult(
              image: _applyExifOrientation(
                native.image,
                _jpegOrientation(bytes),
              ),
              codecName: native.codecName,
              isNative: true,
            )
          : native;
    }
  }
  final DecodedImage decoded = switch (format) {
    RasterImageFormat.png => decodePng(bytes, order: order, limits: pngLimits),
    RasterImageFormat.jpeg =>
      _decodeJpegDart(bytes, order: order, limits: limits),
    RasterImageFormat.webp =>
      _decodeWebPDart(bytes, order: order, limits: limits),
  };
  return RasterDecodeResult(
    image: decoded,
    codecName: format == RasterImageFormat.png
        ? 'dart_ui PNG'
        : 'package:image (Dart)',
    isNative: false,
  );
}

/// Decodes a bitmap using the platform's asynchronous codec when available.
///
/// Browsers expose their optimized decoders through asynchronous APIs such as
/// `createImageBitmap`; desktop platforms currently complete this operation
/// synchronously through [decodeImageWithCodec]. In every environment the
/// pure-Dart implementation remains the final fallback.
Future<DecodedImage> decodeImageAsync(
  Uint8List bytes, {
  ImageChannelOrder order = ImageChannelOrder.bgra,
  PngLimits pngLimits = const PngLimits(),
  RasterImageLimits limits = const RasterImageLimits(),
  bool preferNative = true,
}) async =>
    (await decodeImageAsyncWithCodec(
      bytes,
      order: order,
      pngLimits: pngLimits,
      limits: limits,
      preferNative: preferNative,
    ))
        .image;

/// Like [decodeImageWithCodec], but can use asynchronous browser codecs.
Future<RasterDecodeResult> decodeImageAsyncWithCodec(
  Uint8List bytes, {
  ImageChannelOrder order = ImageChannelOrder.bgra,
  PngLimits pngLimits = const PngLimits(),
  RasterImageLimits limits = const RasterImageLimits(),
  bool preferNative = true,
}) async {
  final RasterImageFormat? format = sniffImageFormat(bytes);
  if (format == null) {
    throw const UnsupportedImageFormatException(
      'expected a PNG, JPEG, or WebP signature',
    );
  }
  limits.checkEncodedLength(bytes.length, format);
  if (preferNative) {
    final RasterDecodeResult? native = await tryDecodeNativeRasterAsync(
      bytes,
      format: format,
      order: order,
      limits: limits,
    );
    if (native != null) return native;
  }
  return decodeImageWithCodec(
    bytes,
    order: order,
    pngLimits: pngLimits,
    limits: limits,
    preferNative: preferNative,
  );
}

/// Decodes baseline, extended sequential, and progressive JPEG in pure Dart.
DecodedImage decodeJpeg(
  Uint8List bytes, {
  ImageChannelOrder order = ImageChannelOrder.bgra,
  RasterImageLimits limits = const RasterImageLimits(),
  bool preferNative = true,
}) {
  if (!isJpeg(bytes)) {
    throw const JpegDecodeException('start-of-image marker not found');
  }
  return decodeImageWithCodec(
    bytes,
    order: order,
    limits: limits,
    preferNative: preferNative,
  ).image;
}

DecodedImage _decodeJpegDart(
  Uint8List bytes, {
  required ImageChannelOrder order,
  required RasterImageLimits limits,
}) {
  if (!isJpeg(bytes)) {
    throw const JpegDecodeException('start-of-image marker not found');
  }
  limits.checkEncodedLength(bytes.length, RasterImageFormat.jpeg);
  final image_lib.JpegDecoder decoder = image_lib.JpegDecoder();
  try {
    final image_lib.DecodeInfo? info = decoder.startDecode(bytes);
    if (info == null) {
      throw const JpegDecodeException('JPEG header could not be decoded');
    }
    limits.checkDimensions(info.width, info.height, RasterImageFormat.jpeg);
    image_lib.Image? decoded = decoder.decodeFrame(0);
    if (decoded == null) {
      throw const JpegDecodeException('JPEG contains no decodable frame');
    }
    if (decoded.exif.imageIfd.hasOrientation &&
        decoded.exif.imageIfd.orientation != 1) {
      decoded = image_lib.bakeOrientation(decoded);
    }
    return _fromPackageImage(decoded, order);
  } on ImageDecodeException {
    rethrow;
  } catch (error) {
    throw JpegDecodeException('invalid JPEG data: $error');
  }
}

int _jpegOrientation(Uint8List bytes) {
  try {
    final image_lib.ExifData? exif = image_lib.decodeJpgExif(bytes);
    final int? orientation = exif?.imageIfd.orientation;
    return orientation != null && orientation >= 2 && orientation <= 8
        ? orientation
        : 1;
  } catch (_) {
    return 1;
  }
}

DecodedImage _applyExifOrientation(DecodedImage source, int orientation) {
  if (orientation == 1) return source;
  final bool swapsAxes = orientation >= 5;
  final int targetWidth = swapsAxes ? source.height : source.width;
  final int targetHeight = swapsAxes ? source.width : source.height;
  final Uint8List pixels = Uint8List(source.pixels.length);

  for (var y = 0; y < source.height; y++) {
    for (var x = 0; x < source.width; x++) {
      final (int, int) destination = switch (orientation) {
        2 => (source.width - 1 - x, y),
        3 => (source.width - 1 - x, source.height - 1 - y),
        4 => (x, source.height - 1 - y),
        5 => (y, x),
        6 => (source.height - 1 - y, x),
        7 => (source.height - 1 - y, source.width - 1 - x),
        8 => (y, source.width - 1 - x),
        _ => (x, y),
      };
      final int from = (y * source.width + x) * 4;
      final int to = (destination.$2 * targetWidth + destination.$1) * 4;
      pixels.setRange(to, to + 4, source.pixels, from);
    }
  }
  return DecodedImage(
    width: targetWidth,
    height: targetHeight,
    order: source.order,
    pixels: pixels,
    hasAlpha: source.hasAlpha,
  );
}

/// Decodes lossy, lossless, alpha, and animated WebP (first frame) in Dart.
DecodedImage decodeWebP(
  Uint8List bytes, {
  ImageChannelOrder order = ImageChannelOrder.bgra,
  RasterImageLimits limits = const RasterImageLimits(),
  bool preferNative = true,
}) {
  if (!isWebP(bytes)) {
    throw const WebPDecodeException('RIFF/WEBP signature not found');
  }
  return decodeImageWithCodec(
    bytes,
    order: order,
    limits: limits,
    preferNative: preferNative,
  ).image;
}

DecodedImage _decodeWebPDart(
  Uint8List bytes, {
  required ImageChannelOrder order,
  required RasterImageLimits limits,
}) {
  if (!isWebP(bytes)) {
    throw const WebPDecodeException('RIFF/WEBP signature not found');
  }
  limits.checkEncodedLength(bytes.length, RasterImageFormat.webp);
  final image_lib.WebPDecoder decoder = image_lib.WebPDecoder();
  try {
    final image_lib.DecodeInfo? info = decoder.startDecode(bytes);
    if (info == null) {
      throw const WebPDecodeException('WebP header could not be decoded');
    }
    limits.checkDimensions(info.width, info.height, RasterImageFormat.webp);
    final image_lib.Image? decoded = decoder.decodeFrame(0);
    if (decoded == null) {
      throw const WebPDecodeException('WebP contains no decodable frame');
    }
    return _fromPackageImage(decoded, order);
  } on ImageDecodeException {
    rethrow;
  } catch (error) {
    throw WebPDecodeException('invalid WebP data: $error');
  }
}

DecodedImage _fromPackageImage(
  image_lib.Image source,
  ImageChannelOrder order,
) {
  final Uint8List straight = source.getBytes(
    order: image_lib.ChannelOrder.rgba,
    alpha: 255,
  );
  final Uint8List pixels = Uint8List(source.width * source.height * 4);
  var hasTransparentPixel = false;
  for (var i = 0; i < straight.length; i += 4) {
    final int alpha = straight[i + 3];
    if (alpha != 255) hasTransparentPixel = true;
    pixels[i + order.redIndex] = premultiplyChannel(straight[i], alpha);
    pixels[i + 1] = premultiplyChannel(straight[i + 1], alpha);
    pixels[i + order.blueIndex] = premultiplyChannel(straight[i + 2], alpha);
    pixels[i + 3] = alpha;
  }
  return DecodedImage(
    width: source.width,
    height: source.height,
    order: order,
    pixels: pixels,
    hasAlpha: source.hasAlpha || hasTransparentPixel,
  );
}
