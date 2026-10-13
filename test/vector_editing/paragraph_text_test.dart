/// Paragraph text: lines that wrap in a frame, artistic text that breaks at
/// a newline, a caret that moves between lines, the Text tool's drag, curves
/// and SVG that keep the lines.
library;

import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

void main() {
  setUpAll(() {
    FrameworkFonts.install();
    VectorTextMetrics.install();
  });
  tearDownAll(() {
    VectorTextMetrics.uninstall();
    FontRegistry.instance.reset();
  });

  late VectorDocument doc;
  late DocumentMethods methods;
  late VectorLayer layer;

  setUp(() {
    doc = VectorDocument();
    methods = DocumentMethods(doc);
    layer = doc.getPageLayers(doc.getPage(0)).first;
  });

  const String long = 'Paragraph text wraps inside its frame, and a long '
      'sentence becomes several lines as the frame fills.';

  VectorText paragraph({double width = 160, String text = long}) =>
      methods.createText(text: text, x: 10, y: 40, width: width);

  test('a frame wraps its text; the box is the frame, as tall as the lines',
      () {
    final VectorText text = paragraph();
    final VectorText single = methods.createText(text: 'One line', x: 0, y: 0);
    final VectorTextInk ink = text.ink;
    expect(VectorTextMetrics.paragraph(text)!.lines.length, greaterThan(2));
    expect(ink.left, 0);
    expect(ink.width, 160);
    expect(ink.height, greaterThan(single.ink.height * 2.5));
    expect(text.cacheBbox.width, closeTo(160, 1e-6));
  });

  test('a narrower frame makes more lines', () {
    expect(VectorTextMetrics.paragraph(paragraph(width: 80))!.lines.length,
        greaterThan(VectorTextMetrics.paragraph(paragraph())!.lines.length));
  });

  test('artistic text breaks at a newline and hangs from its anchor', () {
    final VectorText text =
        methods.createText(text: 'Top line\nbottom', x: 100, y: 100);
    text
      ..style = text.style.copyWith(
          textStyle:
              text.style.textStyle.copyWith(alignment: VectorTextAlign.right))
      ..update();
    expect(VectorTextMetrics.isMultiline(text), isTrue);
    expect(VectorTextMetrics.paragraph(text)!.lines, hasLength(2));
    expect(text.ink.right, closeTo(0, 1e-6), reason: 'right-aligned');
  });

  test('the caret moves to the next line, and a point finds its offset', () {
    final VectorText text = paragraph();
    final Rect first = VectorTextMetrics.caretRect(text, 0);
    final int secondStart = VectorTextMetrics.paragraph(text)!.lines[1].start;
    final Rect second = VectorTextMetrics.caretRect(text, secondStart);
    expect(second.top, greaterThan(first.top + first.height * 0.9));
    expect(
        VectorTextMetrics.offsetAt(
            text, Offset(second.left + 0.5, second.center.dy)),
        secondStart);
    expect(VectorTextMetrics.selectionRects(text, 2, secondStart + 3),
        hasLength(2),
        reason: 'one rectangle per line crossed');
  });

  test('a canvas editor walks lines with Up and Down, Home and End', () {
    final VectorText text = paragraph();
    final CanvasTextEditor editor = CanvasTextEditor(text, caretOffset: 3);
    KeyDownEvent key(int code) => KeyDownEvent(
          windowId: const NativeWindowId(1),
          generation: 1,
          timestamp: Duration.zero,
          physicalKey: code,
          logicalKey: code,
        );
    final double top = editor.caret.top;
    editor.handleKey(key(logicalKeyArrowDown));
    expect(editor.caret.top, greaterThan(top));
    expect(
        (editor.caret.left - VectorTextMetrics.caretRect(text, 3).left).abs(),
        lessThan(text.style.textStyle.fontSize),
        reason: 'about the same column');
    editor.handleKey(key(logicalKeyHome));
    expect(editor.value.selection.extentOffset,
        VectorTextMetrics.paragraph(text)!.lines[1].start);
    editor.handleKey(key(logicalKeyArrowUp));
    editor.handleKey(key(logicalKeyArrowUp));
    expect(editor.value.selection.extentOffset, 0, reason: 'past the top');
  });

  test('a Text tool drag makes a frame; a click makes artistic text', () {
    final TextToolController tool = TextToolController(
      doc: doc,
      methods: methods,
      selection: SelectionManager(),
      snap: SnapManager()..snapToGrid = false,
    );
    final VectorPage page = doc.getPage(0);
    tool
      ..onPointerDown(const Offset(50, 50), page)
      ..onPointerMove(const Offset(250, 120), page)
      ..onPointerUp(const Offset(250, 120), page);
    final VectorText framed = layer.children.whereType<VectorText>().last;
    expect(framed.isParagraphText, isTrue);
    expect(framed.width, 200);
    expect(framed.cacheBbox.top, closeTo(50, 1e-6),
        reason: 'the first line hangs from the top of the drag');

    tool
      ..onPointerDown(const Offset(50, 300), page)
      ..onPointerMove(const Offset(51, 301), page)
      ..onPointerUp(const Offset(51, 301), page);
    expect(layer.children.whereType<VectorText>().last.isArtisticText, isTrue,
        reason: 'a shaky click stays artistic');
  });

  test('converting a paragraph to curves keeps every line', () {
    final VectorText text = paragraph();
    final VectorCurve curve = VectorTextMetrics.toCurves(text)!;
    expect(curve.cacheBbox.height, greaterThan(text.ink.height * 0.7));
    expect(curve.cacheBbox.width, lessThanOrEqualTo(161));
  });

  test('SVG keeps the string, the frame and the alignment; lines are tspans',
      () {
    final VectorText text = paragraph(text: '$long\nA last line.');
    text
      ..style = text.style.copyWith(
          textStyle:
              text.style.textStyle.copyWith(alignment: VectorTextAlign.justify))
      ..update();
    methods.addObject(layer, text);
    final String svg = VectorSvgCodec.exportToSvg(doc);
    final int lines = VectorTextMetrics.paragraph(text)!.lines.length;
    expect('<tspan'.allMatches(svg).length, lines);
    expect(svg, contains('textLength='), reason: 'justified lines stretch');
    expect(svg, contains('dartui:width="160"'));

    final VectorDocument back = VectorSvgCodec.importFromSvg(svg);
    final VectorText read = back
        .getPageLayers(back.getPage(0))
        .first
        .children
        .whereType<VectorText>()
        .single;
    expect(read.textContent, text.textContent);
    expect(read.width, 160);
    expect(read.style.textStyle.alignment, VectorTextAlign.justify);
  });
}
