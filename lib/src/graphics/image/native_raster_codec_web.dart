library;

import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import 'decoded_image.dart';
import 'image_errors.dart';
import 'raster_codec.dart';

/// Uses the browser's image pipeline without putting package:web in the VM
/// dependency graph. A rejected promise or unavailable 2D context means that
/// the caller should use the deterministic Dart decoder.
Future<RasterDecodeResult?> tryDecodeNativeRasterAsync(
  Uint8List bytes, {
  required RasterImageFormat format,
  required ImageChannelOrder order,
  required RasterImageLimits limits,
}) async {
  web.ImageBitmap? bitmap;
  try {
    final web.Blob blob = web.Blob(
      <web.BlobPart>[bytes.toJS].toJS,
      web.BlobPropertyBag(type: _mimeType(format)),
    );
    bitmap = await web.window.createImageBitmap(blob).toDart;
    limits.checkDimensions(bitmap.width, bitmap.height, format);

    final web.OffscreenCanvas canvas = web.OffscreenCanvas(
      bitmap.width,
      bitmap.height,
    );
    final web.OffscreenRenderingContext? rawContext = canvas.getContext('2d');
    if (rawContext == null) return null;
    final web.OffscreenCanvasRenderingContext2D context =
        rawContext as web.OffscreenCanvasRenderingContext2D;
    context.drawImage(bitmap, 0, 0);
    final Uint8ClampedList straight =
        context.getImageData(0, 0, bitmap.width, bitmap.height).data.toDart;
    final Uint8List pixels = Uint8List(straight.length);
    var hasAlpha = false;
    for (var i = 0; i < straight.length; i += 4) {
      final int alpha = straight[i + 3];
      if (alpha != 255) hasAlpha = true;
      pixels[i + order.redIndex] = premultiplyChannel(straight[i], alpha);
      pixels[i + 1] = premultiplyChannel(straight[i + 1], alpha);
      pixels[i + order.blueIndex] = premultiplyChannel(straight[i + 2], alpha);
      pixels[i + 3] = alpha;
    }
    return RasterDecodeResult(
      image: DecodedImage(
        width: bitmap.width,
        height: bitmap.height,
        order: order,
        pixels: pixels,
        hasAlpha: hasAlpha,
      ),
      codecName: 'Browser createImageBitmap',
      isNative: true,
    );
  } on ImageBudgetException {
    rethrow;
  } catch (_) {
    return null;
  } finally {
    bitmap?.close();
  }
}

String _mimeType(RasterImageFormat format) => switch (format) {
      RasterImageFormat.png => 'image/png',
      RasterImageFormat.jpeg => 'image/jpeg',
      RasterImageFormat.webp => 'image/webp',
      // Only Safari decodes JPEG 2000 natively; elsewhere createImageBitmap
      // rejects the blob and the caller falls back to the Dart codec.
      RasterImageFormat.jpeg2000 => 'image/jp2',
    };
