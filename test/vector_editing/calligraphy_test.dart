/// The calligraphic pen: thick across the nib, thin along it, kept by SVG.
library;

import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

void main() {
  const StrokeDescriptor flat = StrokeDescriptor(
    color: Color(0xFF000000),
    width: 10,
    nibStretch: 0.1,
    nibAngle: 0,
  );

  VectorPath line(Offset from, Offset to) =>
      VectorPath(start: from, points: <Object>[to]);

  test('a flat horizontal nib is thick down a vertical line', () {
    final Rect box = calligraphicOutline(
      <VectorPath>[line(const Offset(50, 0), const Offset(50, 100))],
      kNormalTrafo,
      flat,
    ).bounds;
    expect(box.width, closeTo(10, 1e-6), reason: 'the whole nib across');
  });

  test('and thin along a horizontal one', () {
    final Rect box = calligraphicOutline(
      <VectorPath>[line(const Offset(0, 50), const Offset(100, 50))],
      kNormalTrafo,
      flat,
    ).bounds;
    expect(box.height, closeTo(1, 1e-6), reason: 'a tenth of the nib');
  });

  test('a round pen is not calligraphic; a flat one is', () {
    expect(const StrokeDescriptor(width: 2).isCalligraphic, isFalse);
    expect(flat.isCalligraphic, isTrue);
    expect(
        StrokeDescriptor.none.copyWith(nibStretch: 0.1).isCalligraphic, isFalse,
        reason: 'no width, no pen');
  });

  test('SVG keeps the nib', () {
    final VectorDocument doc = VectorDocument();
    final DocumentMethods methods = DocumentMethods(doc);
    final VectorRectangle rect =
        methods.createRectangle(x: 0, y: 0, width: 50, height: 20);
    rect
      ..style = rect.style
          .copyWith(stroke: flat.copyWith(nibStretch: 0.25, nibAngle: 30))
      ..update();
    methods.addObject(doc.getPageLayers(doc.getPage(0)).first, rect);
    final VectorDocument back =
        VectorSvgCodec.importFromSvg(VectorSvgCodec.exportToSvg(doc));
    final StrokeDescriptor read = back
        .getPageLayers(back.getPage(0))
        .first
        .children
        .whereType<SelectableObject>()
        .single
        .style
        .stroke;
    expect(read.nibStretch, closeTo(0.25, 1e-6));
    expect(read.nibAngle, closeTo(30, 1e-6));
  });
}
