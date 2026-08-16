library;

import 'dart:typed_data';

import 'decoded_image.dart';
import 'raster_codec.dart';

RasterDecodeResult? tryDecodeNativeRaster(
  Uint8List bytes, {
  required RasterImageFormat format,
  required ImageChannelOrder order,
  required RasterImageLimits limits,
}) =>
    null;
