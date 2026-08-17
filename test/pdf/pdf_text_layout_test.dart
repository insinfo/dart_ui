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

  test('selection joins character fragments into one visual band per line', () {
    const PdfPageTextLayout layout = PdfPageTextLayout(
      pageNumber: 1,
      text: 'AB CD\nEF',
      fragments: <PdfTextFragment>[
        PdfTextFragment(
          text: 'A',
          textStart: 0,
          bounds: Rect.fromLTRB(10, 10, 18, 22),
        ),
        PdfTextFragment(
          text: 'B',
          textStart: 1,
          bounds: Rect.fromLTRB(18, 10.5, 26, 22.5),
        ),
        PdfTextFragment(
          text: 'C',
          textStart: 3,
          bounds: Rect.fromLTRB(30, 9.5, 38, 22),
        ),
        PdfTextFragment(
          text: 'D',
          textStart: 4,
          bounds: Rect.fromLTRB(38, 10, 46, 23),
        ),
        PdfTextFragment(
          text: 'E',
          textStart: 6,
          bounds: Rect.fromLTRB(10, 30, 18, 42),
        ),
        PdfTextFragment(
          text: 'F',
          textStart: 7,
          bounds: Rect.fromLTRB(18, 30, 26, 42),
        ),
      ],
    );

    expect(
      layout.selectionRects(0, layout.text.length),
      const <Rect>[
        Rect.fromLTRB(10, 9.5, 46, 23),
        Rect.fromLTRB(10, 30, 26, 42),
      ],
    );
  });

  test('selection keeps unrelated columns as separate bands', () {
    const PdfPageTextLayout layout = PdfPageTextLayout(
      pageNumber: 1,
      text: 'A B',
      fragments: <PdfTextFragment>[
        PdfTextFragment(
          text: 'A',
          textStart: 0,
          bounds: Rect.fromLTRB(10, 10, 18, 22),
        ),
        PdfTextFragment(
          text: 'B',
          textStart: 2,
          bounds: Rect.fromLTRB(60, 10, 68, 22),
        ),
      ],
    );

    expect(layout.selectionRects(0, layout.text.length), hasLength(2));
  });

  test('selection does not paint orphan boxes for whitespace-only fragments',
      () {
    const PdfPageTextLayout layout = PdfPageTextLayout(
      pageNumber: 1,
      text: 'A   ',
      fragments: <PdfTextFragment>[
        PdfTextFragment(
          text: 'A',
          textStart: 0,
          bounds: Rect.fromLTRB(10, 10, 18, 22),
        ),
        PdfTextFragment(
          text: '   ',
          textStart: 1,
          bounds: Rect.fromLTRB(80, 40, 82, 52),
        ),
      ],
    );

    expect(
      layout.selectionRects(0, layout.text.length),
      const <Rect>[Rect.fromLTRB(10, 10, 18, 22)],
    );
  });

  test('visual reading order includes titles emitted out of stream order', () {
    final PdfDocumentBuilder builder = PdfDocumentBuilder();
    final page = builder.addPage(width: 300, height: 240);
    page.drawText('Paragrafo inferior', const Offset(30, 180), fontSize: 12);
    page.drawText('TITULO INTERMEDIARIO', const Offset(30, 90), fontSize: 18);
    page.drawText('Paragrafo superior', const Offset(30, 45), fontSize: 12);

    final PdfPageTextLayout layout = PdfTextExtractor(
      PdfDocument.fromBytes(builder.build()).getPage(1),
    ).extract();

    expect(
      layout.text,
      'Paragrafo superior\nTITULO INTERMEDIARIO\nParagrafo inferior',
    );
    expect(
      layout.selectionRects(0, layout.text.length),
      hasLength(3),
      reason: 'the visually intermediate title must not be skipped',
    );
  });

  test('controller selects and copies continuously across pages', () {
    final PdfViewController controller = PdfViewController()
      ..attachDocument(_document());
    final int secondEnd = controller.textLayoutFor(2).text.length;

    controller.selectTextRange(1, 0, 2, secondEnd);

    final PdfTextSelection selection = controller.selection!;
    expect(selection.basePageNumber, 1);
    expect(selection.extentPageNumber, 2);
    expect(selection.rangeForPage(1, 100), (start: 0, end: 100));
    expect(selection.rangeForPage(2, secondEnd), (start: 0, end: secondEnd));
    expect(controller.selectedText, contains('Primeira pagina'));
    expect(controller.selectedText, contains('\n'));
    expect(controller.selectedText, contains('Segunda pagina'));

    controller.selectTextRange(2, secondEnd, 1, 0);
    expect(controller.selection!.isForward, isFalse);
    expect(controller.selectedText, contains('Primeira pagina'));
    expect(controller.selectedText, contains('Segunda pagina'));
  });
}
