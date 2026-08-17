import 'package:dart_ui/dart_ui.dart';
import 'package:dart_ui/pdf.dart';
import 'package:test/test.dart';

PdfDocument _document() {
  final PdfDocumentBuilder builder = PdfDocumentBuilder();
  builder.addPage(width: 300, height: 200).drawText(
        'Primeira pagina pesquisavel',
        const Offset(30, 40),
        fontSize: 16,
      );
  builder.addPage(width: 300, height: 200).drawText(
        'Segunda pagina com resultado',
        const Offset(30, 60),
        fontSize: 14,
      );
  return PdfDocument.fromBytes(builder.build());
}

void main() {
  test('extracts searchable text and top-left page geometry', () {
    final PdfPageTextLayout layout =
        PdfTextExtractor(_document().getPage(1)).extract();

    expect(layout.text, contains('Primeira pagina pesquisavel'));
    expect(layout.fragments, hasLength(1));
    expect(layout.fragments.single.bounds.left, closeTo(30, 0.01));
    expect(layout.fragments.single.bounds.top, greaterThan(20));
    expect(layout.positionForOffset(layout.fragments.single.bounds.center),
        inInclusiveRange(5, 24));
  });

  test('controller clamps zoom, navigates, searches and exposes selection', () {
    final PdfDocument document = _document();
    final PdfViewController controller = PdfViewController(
      minimumZoom: 0.5,
      maximumZoom: 2,
    )..attachDocument(document);

    controller.setZoom(10);
    expect(controller.zoom, 2);
    controller.zoomOut();
    expect(controller.zoom, 1.6);
    controller.fitWidth(pageWidth: 300, viewportWidth: 180, padding: 30);
    expect(controller.zoom, 0.5);
    controller.fitPage(
      pageWidth: 300,
      pageHeight: 200,
      viewportWidth: 630,
      viewportHeight: 230,
      padding: 30,
    );
    expect(controller.zoom, 1);

    controller.goToPage(99);
    expect(controller.currentPage, 2);
    final PdfSearchMatch? match = controller.findNext('resultado');
    expect(match, isNotNull);
    expect(match!.pageNumber, 2);
    expect(controller.selectedText.toLowerCase(), 'resultado');
    expect(controller.hasSelection, isTrue);
    expect(controller.findNext('resultado')!.pageNumber, 2,
        reason: 'next wraps to the first match');

    controller.clearSelection();
    expect(controller.hasSelection, isFalse);
  });

  test('selection rectangles track partial text ranges', () {
    final PdfPageTextLayout layout =
        PdfTextExtractor(_document().getPage(1)).extract();
    final PdfTextFragment fragment = layout.fragments.single;
    final List<Rect> rects = layout.selectionRects(0, 8);

    expect(rects, hasLength(1));
    expect(rects.single.left, fragment.bounds.left);
    expect(rects.single.width, greaterThan(0));
    expect(rects.single.width, lessThan(fragment.bounds.width));
  });
}
