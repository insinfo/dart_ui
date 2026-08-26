import 'dart:typed_data';

import '../../geometry/offset.dart';
import '../../geometry/rect.dart';
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

  /// Raw pixel data (RGBA by default).
  Uint8List? pixelData;

  /// The pixel format of [pixelData].
  PixmapFormat imageFormat;

  /// Resolution (dots per inch).
  double dpi;

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
