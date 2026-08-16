library;

import 'dart:io';
import 'dart:typed_data';

import 'decoded_image.dart';
import 'native/imageio_codec.dart';
import 'native/turbojpeg_codec.dart';
import 'native/wic_codec.dart';
import 'raster_codec.dart';

RasterDecodeResult? tryDecodeNativeRaster(
  Uint8List bytes, {
  required RasterImageFormat format,
  required ImageChannelOrder order,
  required RasterImageLimits limits,
}) {
  if (Platform.isWindows) {
    return tryDecodeWic(
      bytes,
      format: format,
      order: order,
      limits: limits,
    );
  }
  if (Platform.isMacOS) {
    return tryDecodeImageIo(
      bytes,
      format: format,
      order: order,
      limits: limits,
    );
  }
  if (Platform.isLinux) {
    return tryDecodeTurboJpeg(
      bytes,
      format: format,
      order: order,
      limits: limits,
    );
  }
  return null;
}
