/// Format sniffing and the non-PNG bitmap decoders.
///
/// PNG remains implemented inside this package because its exact filtering,
/// premultiplication and hostile-input checks form the reference decoder for
/// the renderer. JPEG and WebP are delegated to the pure-Dart codecs adapted
/// from `package:image` (MIT) under `codecs/`, and JPEG 2000 to our own
/// `package:jpeg2000`; every one of them is converted immediately into the one
/// pixel contract used by dart_ui: tightly packed, premultiplied RGBA/BGRA. No
/// codec-internal type crosses this library's public API.
library;

import 'dart:typed_data';

import 'package:jpeg2000/jpeg2000.dart' as jp2;

import '../../foundation/compute.dart';
import 'codecs/image_lib.dart' as image_lib;
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

/// True for a JP2 container (signature box) or a raw J2K codestream (SOC
/// marker followed by SIZ).
bool isJpeg2000(Uint8List bytes) {
  if (bytes.length >= 12 &&
      bytes[0] == 0x00 &&
      bytes[1] == 0x00 &&
      bytes[2] == 0x00 &&
      bytes[3] == 0x0C &&
      bytes[4] == 0x6A &&
      bytes[5] == 0x50 &&
      bytes[6] == 0x20 &&
      bytes[7] == 0x20 &&
      bytes[8] == 0x0D &&
      bytes[9] == 0x0A &&
      bytes[10] == 0x87 &&
      bytes[11] == 0x0A) {
    return true;
  }
  return bytes.length >= 4 &&
      bytes[0] == 0xFF &&
      bytes[1] == 0x4F &&
      bytes[2] == 0xFF &&
      bytes[3] == 0x51;
}

/// Determines a bitmap format from its magic bytes, never from a file name.
RasterImageFormat? sniffImageFormat(Uint8List bytes) {
  if (isPng(bytes)) return RasterImageFormat.png;
  if (isJpeg(bytes)) return RasterImageFormat.jpeg;
  if (isWebP(bytes)) return RasterImageFormat.webp;
  if (isJpeg2000(bytes)) return RasterImageFormat.jpeg2000;
  return null;
}

const String _signatureHint =
    'expected a PNG, JPEG, WebP, or JPEG 2000 signature';

/// Decodes PNG, JPEG, WebP, or JPEG 2000 after inspecting the signature.
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
    throw const UnsupportedImageFormatException(_signatureHint);
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
    RasterImageFormat.jpeg2000 =>
      _decodeJp2Dart(bytes, order: order, limits: limits),
  };
  return RasterDecodeResult(
    image: decoded,
    codecName: switch (format) {
      RasterImageFormat.png => 'dart_ui PNG',
      RasterImageFormat.jpeg2000 => _jp2CodecName,
      _ => 'dart_ui codecs (Dart)',
    },
    isNative: false,
  );
}

/// Decodes a bitmap using the platform's asynchronous codec when available.
///
/// Browsers expose their optimized decoders through asynchronous APIs such as
/// `createImageBitmap`; desktop platforms complete PNG, JPEG and WebP
/// synchronously through [decodeImageWithCodec], and move JPEG 2000 to a
/// background isolate because its pure-Dart decoder costs about a quarter of
/// a microsecond per pixel. In every environment the pure-Dart implementation
/// remains the final fallback.
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
    throw const UnsupportedImageFormatException(_signatureHint);
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
  if (format == RasterImageFormat.jpeg2000) {
    return compute(
      _decodeJp2Request,
      _Jp2Request(bytes, order, limits),
      debugLabel: 'dart_ui jpeg2000 decode',
    );
  }
  return decodeImageWithCodec(
    bytes,
    order: order,
    pngLimits: pngLimits,
    limits: limits,
    preferNative: preferNative,
  );
}

/// Decodes a JP2 container or raw J2K codestream in pure Dart.
///
/// [keepAlpha] false drops the alpha channel before premultiplication, which
/// is what a PDF `/JPXDecode` image without `/SMaskInData` needs: the file may
/// carry alpha, but the page must ignore it.
DecodedImage decodeJp2(
  Uint8List bytes, {
  ImageChannelOrder order = ImageChannelOrder.bgra,
  RasterImageLimits limits = const RasterImageLimits(),
  bool preferNative = true,
  bool keepAlpha = true,
}) {
  if (!isJpeg2000(bytes)) {
    throw const Jpeg2000DecodeException(
      'neither a JP2 signature nor a J2K start-of-codestream marker',
      kind: Jpeg2000FailureKind.format,
    );
  }
  if (!keepAlpha) {
    return _decodeJp2Dart(bytes,
        order: order, limits: limits, keepAlpha: false);
  }
  return decodeImageWithCodec(
    bytes,
    order: order,
    limits: limits,
    preferNative: preferNative,
  ).image;
}

const String _jp2CodecName = 'package:jpeg2000 (Dart)';

final class _Jp2Request {
  const _Jp2Request(this.bytes, this.order, this.limits);

  final Uint8List bytes;
  final ImageChannelOrder order;
  final RasterImageLimits limits;
}

RasterDecodeResult _decodeJp2Request(_Jp2Request request) => RasterDecodeResult(
      image: _decodeJp2Dart(
        request.bytes,
        order: request.order,
        limits: request.limits,
      ),
      codecName: _jp2CodecName,
      isNative: false,
    );

DecodedImage _decodeJp2Dart(
  Uint8List bytes, {
  required ImageChannelOrder order,
  required RasterImageLimits limits,
  bool keepAlpha = true,
}) {
  if (!isJpeg2000(bytes)) {
    throw const Jpeg2000DecodeException(
      'neither a JP2 signature nor a J2K start-of-codestream marker',
      kind: Jpeg2000FailureKind.format,
    );
  }
  limits.checkEncodedLength(bytes.length, RasterImageFormat.jpeg2000);
  final jp2.Jpeg2000Image decoded;
  try {
    // The probe reads only the headers, so an oversized SIZ is refused here
    // before the codec allocates anything; the budget passed to the codec is
    // a second line for the same policy.
    final jp2.Jpeg2000Info info = jp2.probeJpeg2000(bytes);
    limits.checkDimensions(info.width, info.height, RasterImageFormat.jpeg2000);
    decoded = jp2.decodeJpeg2000(
      bytes,
      options: jp2.Jpeg2000DecodeOptions(
        maxPixels: limits.maxPixels,
        maxDimension: limits.maxDimension,
      ),
    );
  } on ImageDecodeException {
    rethrow;
  } on jp2.Jpeg2000BudgetException catch (error) {
    throw ImageBudgetException(
      budget: error.budget,
      limit: error.limit,
      actual: error.actual,
      message: 'JPEG 2000 ${error.message}',
    );
  } on jp2.Jpeg2000Exception catch (error) {
    throw Jpeg2000DecodeException(
      error.message,
      kind: switch (error) {
        jp2.Jpeg2000FormatException() => Jpeg2000FailureKind.format,
        jp2.Jpeg2000TruncatedException() => Jpeg2000FailureKind.truncated,
        jp2.Jpeg2000CorruptedException() => Jpeg2000FailureKind.corrupted,
        jp2.Jpeg2000UnsupportedException() => Jpeg2000FailureKind.unsupported,
        jp2.Jpeg2000BudgetException() => Jpeg2000FailureKind.corrupted,
      },
    );
  }
  return _fromJp2Image(decoded, order, keepAlpha: keepAlpha);
}

/// Expands the codec's tightly packed channels into premultiplied 32-bit
/// pixels in the caller's channel order.
///
/// Gray is replicated into the three colour channels. A `multiComponent`
/// image (CMYK, multispectral) has no colour meaning the codec could give it,
/// so its first three channels are shown as RGB, or its first channel as gray
/// when there are fewer than three; that keeps such files visible instead of
/// refused, and the caller can go to `package:jpeg2000` for the raw channels.
DecodedImage _fromJp2Image(
  jp2.Jpeg2000Image source,
  ImageChannelOrder order, {
  required bool keepAlpha,
}) {
  final int width = source.width;
  final int height = source.height;
  final int count = width * height;
  final int stride = source.components;
  final Uint8List samples = source.pixels;
  final bool hasAlpha = keepAlpha && source.hasAlpha;
  final bool premultiplied = source.alphaIsPremultiplied;
  final int alphaIndex = stride - 1;
  final bool gray = source.colorComponents < 3;
  final int redIndex = order.redIndex;
  final int blueIndex = order.blueIndex;

  final Uint8List pixels = Uint8List(count * 4);
  var hasTransparentPixel = false;
  var sourceIndex = 0;
  var target = 0;
  for (var i = 0; i < count; i++) {
    final int red = samples[sourceIndex];
    final int green = gray ? red : samples[sourceIndex + 1];
    final int blue = gray ? red : samples[sourceIndex + 2];
    final int alpha = hasAlpha ? samples[sourceIndex + alphaIndex] : 255;
    if (alpha != 255) {
      hasTransparentPixel = true;
    }
    if (alpha == 255 || premultiplied) {
      pixels[target + redIndex] = red;
      pixels[target + 1] = green;
      pixels[target + blueIndex] = blue;
    } else {
      pixels[target + redIndex] = premultiplyChannel(red, alpha);
      pixels[target + 1] = premultiplyChannel(green, alpha);
      pixels[target + blueIndex] = premultiplyChannel(blue, alpha);
    }
    pixels[target + 3] = alpha;
    sourceIndex += stride;
    target += 4;
  }
  return DecodedImage(
    width: width,
    height: height,
    order: order,
    pixels: pixels,
    hasAlpha: hasAlpha && hasTransparentPixel,
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
    final image_lib.Image? decoded = decoder.decodeFrame(0);
    if (decoded == null) {
      throw const JpegDecodeException('JPEG contains no decodable frame');
    }
    final int? rawOrientation = decoded.exif.imageIfd.hasOrientation
        ? decoded.exif.imageIfd.orientation
        : null;
    final int orientation =
        rawOrientation != null && rawOrientation >= 2 && rawOrientation <= 8
            ? rawOrientation
            : 1;
    final DecodedImage image = _fromPackageImage(decoded, order);
    return _applyExifOrientation(image, orientation);
  } on ImageDecodeException {
    rethrow;
  } catch (error) {
    throw JpegDecodeException('invalid JPEG data: $error');
  }
}

int _jpegOrientation(Uint8List bytes) {
  try {
    final image_lib.ExifData? exif = image_lib.JpegUtil().decodeExif(bytes);
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
