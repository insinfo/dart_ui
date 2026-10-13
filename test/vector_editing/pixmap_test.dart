/// Images in a vector document: made from a decoded image, written as PNG,
/// drawn by the canvas at the pixels they cover, and kept by SVG.
library;

import 'dart:typed_data';

import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

DecodedImage _checker() {
  // 4x2: red, green / blue, half-transparent white - premultiplied RGBA.
  final Uint8List pixels = Uint8List.fromList(<int>[
    255, 0, 0, 255, 255, 0, 0, 255, 0, 255, 0, 255, 0, 255, 0, 255, //
    0, 0, 255, 255, 0, 0, 255, 255, 128, 128, 128, 128, 128, 128, 128, 128,
  ]);
  return DecodedImage(
    width: 4,
    height: 2,
    order: ImageChannelOrder.rgba,
    pixels: pixels,
    hasAlpha: true,
  );
}

void main() {
  test('a pixmap from an image keeps its pixels, and its PNG decodes back', () {
    final VectorPixmap pixmap =
        VectorPixmap.fromImage(_checker(), at: const Offset(10, 20), dpi: 144);
    expect(pixmap.cacheBbox, const Rect.fromLTWH(10, 20, 2, 1),
        reason: '144 dpi: two pixels per point');
    final DecodedImage back = decodeImage(pixmap.toPng()!,
        order: ImageChannelOrder.rgba, preferNative: false);
    expect(back.width, 4);
    expect(back.pixels.sublist(0, 4), <int>[255, 0, 0, 255]);
    expect(back.pixels[4 * 7 + 3], 128, reason: 'alpha kept');
    expect(back.pixels[4 * 7], closeTo(128, 1),
        reason: 'premultiplied in the document, premultiplied back');
  });

  test('the canvas draws it at the device pixels it covers', () {
    final VectorDocument doc = VectorDocument();
    final VectorLayer layer = doc.getPageLayers(doc.getPage(0)).first;
    DocumentMethods(doc).addObject(
        layer, VectorPixmap.fromImage(_checker(), at: const Offset(10, 10)));
    final DisplayList list = DisplayList();
    VectorRenderer.renderPage(
      list,
      doc,
      doc.getPage(0),
      viewport: const Rect.fromLTWH(0, 0, 800, 600),
      zoom: 3,
    );
    final List<Framebuffer> images = <Framebuffer>[
      for (int i = 0; i < list.imageCount; i++)
        if (list.imageAt(i) is Framebuffer) list.imageAt(i) as Framebuffer,
    ];
    expect(images.single.width, 12, reason: '4 px at zoom 3');
    expect(images.single.height, 6);
  });

  test('SVG writes it inline and reads it back', () {
    final VectorDocument doc = VectorDocument();
    final VectorLayer layer = doc.getPageLayers(doc.getPage(0)).first;
    final VectorPixmap pixmap =
        VectorPixmap.fromImage(_checker(), at: const Offset(5, 6));
    pixmap.applyTrafo(const <double>[2, 0, 0, 2, 0, 0]);
    DocumentMethods(doc).addObject(layer, pixmap);
    final String svg = VectorSvgCodec.exportToSvg(doc);
    expect(svg, contains('<image '));
    expect(svg, contains('data:image/png;base64,'));

    final VectorDocument back = VectorSvgCodec.importFromSvg(svg);
    final VectorPixmap read = back
        .getPageLayers(back.getPage(0))
        .first
        .children
        .whereType<VectorPixmap>()
        .single;
    expect(read.pixelWidth, 4);
    expect(read.cacheBbox.left, closeTo(10, 1e-6));
    expect(read.cacheBbox.width, closeTo(8, 1e-6));
    expect(read.pixelData!.sublist(0, 4), <int>[255, 0, 0, 255]);
  });

  test('an image the SVG only names by file is skipped', () {
    const String svg = '<svg xmlns="http://www.w3.org/2000/svg" '
        'width="100" height="100"><image href="/etc/passwd" '
        'width="10" height="10"/></svg>';
    final VectorDocument doc = VectorSvgCodec.importFromSvg(svg);
    expect(
        doc
            .getPageLayers(doc.getPage(0))
            .first
            .children
            .whereType<VectorPixmap>(),
        isEmpty);
  });

  test('objects rasterize to an image the size of their box', () {
    final DocumentMethods methods = DocumentMethods(VectorDocument());
    final VectorRectangle red = methods.createRectangle(
      x: 10,
      y: 10,
      width: 20,
      height: 10,
      style: const VectorStyle(
        fill: FillDescriptor.solid(Color(0xFFFF0000)),
        stroke: StrokeDescriptor.none,
      ),
    );
    final DecodedImage image =
        VectorRenderer.rasterizeObjects(<SelectableObject>[red], scale: 2)!;
    expect(image.width, 40);
    expect(image.height, 20);
    const int centre = (10 * 40 + 20) * 4;
    expect(image.pixels.sublist(centre, centre + 4), <int>[255, 0, 0, 255]);
    expect(VectorRenderer.rasterizeObjects(const <SelectableObject>[]), isNull);
  });
}
