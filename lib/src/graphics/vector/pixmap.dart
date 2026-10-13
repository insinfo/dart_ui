import 'dart:typed_data';

import '../../geometry/offset.dart';
import '../../geometry/rect.dart';
import '../image/decoded_image.dart';
import '../image/png_encoder.dart';
import '../image/raster_formats.dart' show decodeImage;
import 'document_object.dart';
import 'selectable_objects.dart';

/// An embedded bitmap image in the vector document.
///
/// The image is stored as raw RGBA pixel data. The [trafo] positions and scales
/// the image in the document coordinate system.
class VectorPixmap extends SelectableObject {
  VectorPixmap({
    super.parent,
    super.trafo,
    this.pixelWidth = 0,
    this.pixelHeight = 0,
    this.pixelData,
    this.imageFormat = PixmapFormat.rgba,
    this.dpi = 72.0,
  });

  /// Image width in pixels.
  int pixelWidth;

  /// Image height in pixels.
  int pixelHeight;

  /// The pixels, row by row: with [PixmapFormat.rgba], red, green, blue and
  /// alpha, **premultiplied** - a [DecodedImage]'s bytes in RGBA order, which
  /// is what the canvas draws without converting.
  Uint8List? pixelData;

  /// The pixel format of [pixelData].
  PixmapFormat imageFormat;

  /// Resolution (dots per inch).
  double dpi;

  /// [image] as a pixmap whose top-left is at [at], [dpi] pixels per inch
  /// (72: one pixel per point).
  factory VectorPixmap.fromImage(
    DecodedImage image, {
    Offset at = Offset.zero,
    double dpi = 72.0,
  }) {
    final Uint8List rgba = image.order == ImageChannelOrder.rgba
        ? Uint8List.fromList(image.pixels)
        : _swapRedBlue(image.pixels);
    return VectorPixmap(
      trafo: <double>[1, 0, 0, 1, at.dx, at.dy],
      pixelWidth: image.width,
      pixelHeight: image.height,
      pixelData: rgba,
      dpi: dpi,
    )..update();
  }

  /// A PNG, JPEG or other file the framework decodes, as a pixmap; null for
  /// bytes that are not an image it can read.
  static VectorPixmap? fromEncoded(
    Uint8List bytes, {
    Offset at = Offset.zero,
    double dpi = 72.0,
  }) {
    try {
      return VectorPixmap.fromImage(
        decodeImage(bytes, order: ImageChannelOrder.rgba),
        at: at,
        dpi: dpi,
      );
    } on Object {
      return null;
    }
  }

  static Uint8List _swapRedBlue(Uint8List bgra) {
    final Uint8List out = Uint8List.fromList(bgra);
    for (int i = 0; i < out.length; i += 4) {
      out[i] = bgra[i + 2];
      out[i + 2] = bgra[i];
    }
    return out;
  }

  /// The pixels as a PNG file - straight alpha, as PNG stores it - or null
  /// with no RGBA data.
  Uint8List? toPng() {
    final Uint8List? data = pixelData;
    if (data == null ||
        imageFormat != PixmapFormat.rgba ||
        pixelWidth <= 0 ||
        pixelHeight <= 0 ||
        data.length < pixelWidth * pixelHeight * 4) {
      return null;
    }
    final Uint8List straight = Uint8List(pixelWidth * pixelHeight * 4);
    for (int i = 0; i < straight.length; i += 4) {
      final int a = data[i + 3];
      straight[i + 3] = a;
      if (a == 0) continue;
      for (int c = 0; c < 3; c++) {
        final int v =
            a == 255 ? data[i + c] : (data[i + c] * 255 + a ~/ 2) ~/ a;
        straight[i + c] = v > 255 ? 255 : v;
      }
    }
    return encodePng(width: pixelWidth, height: pixelHeight, pixels: straight);
  }

  @override
  bool get isPixmap => true;
  @override
  bool get isSelectable => true;

  /// Whether pixel data is loaded.
  bool get hasData => pixelData != null && pixelData!.isNotEmpty;

  @override
  void updateBbox() {
    if (pixelWidth <= 0 || pixelHeight <= 0) {
      cacheBbox = Rect.zero;
      return;
    }
    // The pixmap's native rectangle is [0, 0, w, h] in points (at 72 dpi).
    final wPt = pixelWidth * 72.0 / dpi;
    final hPt = pixelHeight * 72.0 / dpi;

    // Transform the four corners and compute the bounding box.
    final corners = [
      Offset.zero,
      Offset(wPt, 0),
      Offset(wPt, hPt),
      Offset(0, hPt),
    ];
    final transformed = applyTrafoToPoints(corners, trafo);

    double minX = double.infinity;
    double minY = double.infinity;
    double maxX = double.negativeInfinity;
    double maxY = double.negativeInfinity;
    for (final p in transformed) {
      if (p.dx < minX) minX = p.dx;
      if (p.dy < minY) minY = p.dy;
      if (p.dx > maxX) maxX = p.dx;
      if (p.dy > maxY) maxY = p.dy;
    }
    cacheBbox = Rect.fromLTRB(minX, minY, maxX, maxY);
  }

  @override
  void update() {
    updateBbox();
  }

  @override
  DocumentObject createEmpty() => VectorPixmap();

  @override
  void copyFields(DocumentObject target) {
    super.copyFields(target);
    if (target is VectorPixmap) {
      target.pixelWidth = pixelWidth;
      target.pixelHeight = pixelHeight;
      target.pixelData =
          pixelData != null ? Uint8List.fromList(pixelData!) : null;
      target.imageFormat = imageFormat;
      target.dpi = dpi;
    }
  }

  @override
  String toString() =>
      'VectorPixmap($pixelWidth×$pixelHeight, $imageFormat, $dpi dpi)';
}

/// Pixel format of an embedded bitmap.
enum PixmapFormat { rgba, rgb, grayscale, indexed }
