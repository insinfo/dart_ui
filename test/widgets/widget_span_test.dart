/// `WidgetSpan`: widgets laid out, painted and hit-tested inside rich text.
///
/// The boxes the paragraph reports are the ground truth here - the engine's
/// own tests (`test/text/paragraph_placeholder_test.dart`) pin those down to
/// the pixel with Ahem - so these tests check that the widget layer sizes the
/// placeholders from its children, puts each child in its box, and routes
/// pointers and semantics to them.
library;

import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

const Color _blue = Color(0xFF2050C0);

/// A tree mounted in a [size] viewport, top-left aligned, with a frame
/// drawn.
final class _Harness {
  _Harness(Widget child, {Size size = const Size(400, 200)})
      : owner = BuildOwner(
          pipelineOwner:
              PipelineOwner(rootConstraints: BoxConstraints.tight(size)),
        ) {
    pump(child);
  }

  final BuildOwner owner;
  DisplayList list = DisplayList();

  void pump(Widget child) {
    owner.updateRoot(Directionality(
      textDirection: TextDirection.leftToRight,
      child: Align(alignment: Alignment.topLeft, child: child),
    ));
    frame();
  }

  void frame() {
    owner.buildScope();
    list = DisplayList();
    owner.pipelineOwner.drawFrame(list);
  }

  List<T> findAll<T extends RenderBox>() {
    final List<T> found = <T>[];
    void walk(RenderBox node) {
      if (node is T) found.add(node);
      node.visitChildren(walk);
    }

    walk(owner.renderRoot!);
    return found;
  }

  T find<T extends RenderBox>() => findAll<T>().first;

  RenderText get text => find<RenderText>();

  Paragraph get paragraph => text.laidOutParagraph!;

  void click(Offset at) {
    owner.dispatchPointerEvent(PointerDownEvent(
      windowId: const NativeWindowId(1),
      generation: 1,
      timestamp: Duration.zero,
      pointerId: 0,
      kind: PointerKind.mouse,
      logicalPosition: at,
      button: PointerButton.primary,
    ));
    frame();
    owner.dispatchPointerEvent(PointerUpEvent(
      windowId: const NativeWindowId(1),
      generation: 1,
      timestamp: Duration.zero,
      pointerId: 0,
      kind: PointerKind.mouse,
      logicalPosition: at,
      button: PointerButton.primary,
    ));
    frame();
  }

  void dispose() => owner.dispose();
}

/// A solid box of a known size - an inline widget whose size is not in
/// doubt.
Widget _box(double width, double height, {Key? key}) => SizedBox(
      key: key,
      width: width,
      height: height,
      child: const ColoredBox(color: _blue),
    );

/// The render node a [_box] produced: the sized box around the colour.
RenderBox _boxNode(_Harness h, int index) => h.text.childAt(index);

Offset _centre(RenderBox node) =>
    node.localToGlobal(Offset(node.size.width / 2, node.size.height / 2));

void main() {
  group('the span', () {
    test('is one U+FFFC in the plain text, as in Flutter', () {
      final TextSpan span = TextSpan(children: <InlineSpan>[
        const TextSpan(text: 'a'),
        WidgetSpan(child: _box(10, 10)),
        const TextSpan(text: 'b'),
      ]);
      expect(span.toPlainText(), 'a\uFFFCb');
      expect(Text.rich(span).text, 'a\uFFFCb');
      expect(PlaceholderSpan.placeholderCodeUnit, 0xFFFC);
    });

    test('its widgets come out in text order', () {
      final Widget first = _box(1, 1);
      final Widget second = _box(2, 2);
      final TextSpan span = TextSpan(children: <InlineSpan>[
        WidgetSpan(child: first),
        TextSpan(text: 'x', children: <InlineSpan>[WidgetSpan(child: second)]),
      ]);
      expect(WidgetSpan.extractFromInlineSpan(span), <Widget>[first, second]);
      expect(Text.rich(span).children, <Widget>[first, second]);
      expect(const Text('plain').children, isEmpty);
    });

    test('compares its child by identity', () {
      final Widget child = _box(1, 1);
      expect(WidgetSpan(child: child), WidgetSpan(child: child));
      expect(WidgetSpan(child: child), isNot(WidgetSpan(child: _box(1, 1))));
      expect(
        WidgetSpan(child: child),
        isNot(WidgetSpan(child: child, alignment: PlaceholderAlignment.top)),
      );
    });
  });

  group('layout', () {
    test('an inline widget sits in its box, after the text before it', () {
      final _Harness h = _Harness(Text.rich(TextSpan(children: <InlineSpan>[
        const TextSpan(text: 'Press '),
        WidgetSpan(child: _box(20, 12)),
        const TextSpan(text: ' to save'),
      ])));
      final Paragraph p = h.paragraph;
      expect(p.placeholderBoxes, hasLength(1));
      final Rect box = p.placeholderBoxes.single.rect;
      // Its x is the caret's after "Press ", its size the child's.
      expect(
          box.left, closeTo(p.getCaretRect(const TextPosition(6)).left, 1e-9));
      expect(box.width, 20);
      expect(box.height, 12);
      final RenderBox child = _boxNode(h, 0);
      expect(child.size, const Size(20, 12));
      expect(child.offsetFromParent, box.topLeft);
      // Bottom-aligned, Flutter's default: its bottom on the text's.
      final TextLine line = p.lines.single;
      expect(box.bottom, closeTo(line.baseline + h.text.font!.descent, 1e-9));
      // And the text after it starts after it.
      expect(
          p.getCaretRect(const TextPosition(7)).left, closeTo(box.right, 1e-9));
      h.dispose();
    });

    test('an Icon in a sentence is laid out where its placeholder is', () {
      final _Harness h =
          _Harness(const Text.rich(TextSpan(children: <InlineSpan>[
        TextSpan(text: 'Saved '),
        WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: Icon(FluentIcons.save, size: 16),
        ),
        TextSpan(text: ' just now'),
      ])));
      final RenderIcon icon = h.find<RenderIcon>();
      final Rect box = h.paragraph.placeholderBoxes.single.rect;
      expect(icon.size.width, box.width);
      expect(
          icon.localToGlobal(Offset.zero), h.text.localToGlobal(box.topLeft));
      expect(box.left, greaterThan(0));
      // Middle: its centre on the centre of the text.
      final ScaledTypeface font = h.text.font!;
      final double centre =
          h.paragraph.lines.single.baseline - (font.ascent - font.descent) / 2;
      expect(box.center.dy, closeTo(centre, 1e-9));
      h.dispose();
    });

    test('a tall widget makes its line taller', () {
      final _Harness flat = _Harness(const Text.rich(TextSpan(text: 'Hello')));
      final double lineHeight = flat.text.size.height;
      flat.dispose();

      final _Harness h = _Harness(Text.rich(TextSpan(children: <InlineSpan>[
        const TextSpan(text: 'Hello '),
        WidgetSpan(child: _box(10, 60)),
      ])));
      expect(h.text.size.height, greaterThanOrEqualTo(60));
      expect(h.text.size.height, greaterThan(lineHeight));
      // The text sits on the raised baseline, under the tall box's top.
      expect(h.paragraph.lines.single.baseline, greaterThan(lineHeight));
      h.dispose();
    });

    test('baseline alignment lines a child\'s text up with the sentence', () {
      final _Harness h =
          _Harness(const Text.rich(TextSpan(children: <InlineSpan>[
        TextSpan(text: 'Total: '),
        WidgetSpan(
          alignment: PlaceholderAlignment.baseline,
          baseline: TextBaseline.alphabetic,
          child: Text('42', style: TextStyle(fontSize: 28)),
        ),
      ])));
      final RenderText outer = h.text;
      final RenderText inner = outer.childAt(0) as RenderText;
      final double innerBaseline = inner.offsetFromParent.dy +
          inner.getDistanceToBaseline(TextBaseline.alphabetic)!;
      expect(innerBaseline,
          closeTo(outer.laidOutParagraph!.lines.single.baseline, 1e-9));
      h.dispose();
    });

    test('a long sentence wraps around an inline widget', () {
      final _Harness h = _Harness(
        SizedBox(
          width: 180,
          child: Text.rich(
            TextSpan(children: <InlineSpan>[
              const TextSpan(text: 'This sentence is long enough that the '),
              WidgetSpan(child: _box(40, 14)),
              const TextSpan(text: ' box inside it lands on a later line.'),
            ]),
            softWrap: true,
          ),
        ),
      );
      final Paragraph p = h.paragraph;
      expect(p.lines.length, greaterThan(2));
      for (final TextLine line in p.lines) {
        expect(line.left + line.width, lessThanOrEqualTo(180 + 1e-9));
      }
      final Rect box = p.placeholderBoxes.single.rect;
      expect(box.right, lessThanOrEqualTo(180 + 1e-9));
      // On some line past the first, inside that line's box.
      final TextLine line = p.lines.firstWhere(
        (TextLine l) => l.start <= 38 && 38 < l.endIncludingWhitespace,
      );
      expect(line.lineNumber, greaterThan(0));
      expect(box.top, greaterThanOrEqualTo(line.top - 1e-9));
      expect(box.bottom, lessThanOrEqualTo(line.bottom + 1e-9));
      expect(_boxNode(h, 0).offsetFromParent, box.topLeft);
      h.dispose();
    });

    test('a child is laid out under the text\'s width, loosely', () {
      final _Harness h = _Harness(const SizedBox(
        width: 120,
        child: Text.rich(
          TextSpan(children: <InlineSpan>[
            WidgetSpan(child: SizedBox(width: 500, height: 10)),
          ]),
          softWrap: true,
        ),
      ));
      expect(_boxNode(h, 0).size, const Size(120, 10));
      h.dispose();
    });

    test('the intrinsic width counts the widgets', () {
      final _Harness plain = _Harness(const Text.rich(TextSpan(text: 'ab')));
      final double base = plain.text.getMaxIntrinsicWidth(double.infinity);
      plain.dispose();
      final _Harness h = _Harness(Text.rich(TextSpan(children: <InlineSpan>[
        const TextSpan(text: 'ab'),
        WidgetSpan(child: _box(50, 10)),
      ])));
      expect(h.text.getMaxIntrinsicWidth(double.infinity),
          closeTo(base + 50, 1e-9));
      h.dispose();
    });

    test('children follow their spans when the spans are rebuilt', () {
      Widget build(double first, double second) =>
          Text.rich(TextSpan(children: <InlineSpan>[
            WidgetSpan(child: _box(first, 10, key: ValueKey<double>(first))),
            const TextSpan(text: ' and '),
            WidgetSpan(child: _box(second, 10, key: ValueKey<double>(second))),
          ]));
      final _Harness h = _Harness(build(10, 30));
      expect(h.paragraph.placeholderBoxes.first.rect.width, 10);
      h.pump(build(30, 10));
      final List<TextBox> boxes = h.paragraph.placeholderBoxes;
      expect(boxes.first.rect.width, 30);
      expect(boxes.last.rect.width, 10);
      expect(_boxNode(h, 0).size.width, 30);
      expect(_boxNode(h, 0).offsetFromParent, boxes.first.rect.topLeft);
      expect(_boxNode(h, 1).offsetFromParent, boxes.last.rect.topLeft);
      h.dispose();
    });

    test('RichText takes widgets too', () {
      final _Harness h = _Harness(RichText(
        text: TextSpan(children: <InlineSpan>[
          const TextSpan(text: 'x '),
          WidgetSpan(child: _box(16, 16)),
        ]),
      ));
      expect(h.text.childCount, 1);
      expect(_boxNode(h, 0).offsetFromParent,
          h.paragraph.placeholderBoxes.single.rect.topLeft);
      h.dispose();
    });

    test('text with no widgets has no children, rich or plain', () {
      final _Harness plain = _Harness(const Text('label'));
      expect(plain.text.childCount, 0);
      plain.dispose();
      final _Harness rich = _Harness(const Text.rich(TextSpan(text: 'rich')));
      expect(rich.text.childCount, 0);
      expect(rich.paragraph.placeholderBoxes, isEmpty);
      rich.dispose();
    });
  });

  group('paint', () {
    test('a child is painted over the text', () {
      final _Harness h = _Harness(Text.rich(TextSpan(children: <InlineSpan>[
        const TextSpan(text: 'ab '),
        WidgetSpan(child: _box(12, 12)),
      ])));
      final List<int> opcodes = <int>[];
      final DisplayListReader reader = DisplayListReader(h.list);
      while (reader.moveNext()) {
        opcodes.add(reader.opcode);
      }
      final int glyphs = opcodes.indexOf(opDrawGlyphRun);
      final int box = opcodes.lastIndexOf(opDrawRect);
      expect(glyphs, greaterThanOrEqualTo(0));
      expect(box, greaterThan(glyphs));
      h.dispose();
    });
  });

  group('pointer', () {
    test('a Button inside text takes the click', () {
      int clicks = 0;
      final _Harness h = _Harness(Text.rich(TextSpan(children: <InlineSpan>[
        const TextSpan(text: 'Changes saved. '),
        WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: Button(label: 'Undo', onPressed: () => clicks++),
        ),
      ])));
      final RenderButton button = h.find<RenderButton>();
      expect(
          button.localToGlobal(Offset.zero),
          h.text
              .localToGlobal(h.paragraph.placeholderBoxes.single.rect.topLeft));
      h.click(_centre(button));
      expect(clicks, 1);
      // A click on the words beside it is not a click on the button.
      h.click(h.text.localToGlobal(const Offset(4, 8)));
      expect(clicks, 1);
      h.dispose();
    });

    test('a child cut off by maxLines is neither placed nor hit', () {
      int clicks = 0;
      final _Harness h = _Harness(SizedBox(
        width: 100,
        child: RichText(
          maxLines: 1,
          text: TextSpan(children: <InlineSpan>[
            const TextSpan(text: 'first line words '),
            WidgetSpan(child: Button(label: 'Go', onPressed: () => clicks++)),
          ]),
        ),
      ));
      expect(h.paragraph.didExceedMaxLines, isTrue);
      expect(h.paragraph.placeholderBoxes, isEmpty);
      final RenderButton button = h.find<RenderButton>();
      // Laid out - its size decided the cut - but not placed anywhere, so
      // its default offset overlaps the first line's text.
      expect(button.hasSize, isTrue);
      h.click(_centre(button));
      expect(clicks, 0);
      h.dispose();
    });
  });

  group('semantics', () {
    test('a Button inside text is still a button to a screen reader', () {
      final _Harness h = _Harness(Text.rich(TextSpan(children: <InlineSpan>[
        const TextSpan(text: 'Changes saved. '),
        WidgetSpan(child: Button(label: 'Undo', onPressed: () {})),
      ])));
      final SemanticsSnapshot snapshot =
          SemanticsOwner().build(h.owner.renderRoot);
      final SemanticsNode node = snapshot.nodes
          .firstWhere((SemanticsNode n) => n.role == SemanticsRole.button);
      expect(node.label, 'Undo');
      final RenderButton button = h.find<RenderButton>();
      expect(node.bounds.left, button.localToGlobal(Offset.zero).dx);
      h.dispose();
    });
  });
}
