/// `Text.rich`, `RichText` and the rich fields of `TextStyle`, through the
/// widget tree.
///
/// Roboto is the interface face here, so the numbers do not depend on what
/// the machine has installed - except in the one test that looks for a real
/// italic face, which is skipped where there is none.
library;

import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

const Color _red = Color(0xFFFF0000);
const Color _green = Color(0xFF00AA00);

/// Mounts [child] at the top-left of a [size] viewport and paints a frame.
({BuildOwner owner, DisplayList list, RenderText text}) _mount(
  Widget child, {
  Size size = const Size(400, 100),
}) {
  final BuildOwner owner = BuildOwner(
    pipelineOwner: PipelineOwner(rootConstraints: BoxConstraints.tight(size)),
  );
  owner.updateRoot(Directionality(
    textDirection: TextDirection.leftToRight,
    child: Align(alignment: Alignment.topLeft, child: child),
  ));
  owner.buildScope();
  final DisplayList list = DisplayList();
  owner.pipelineOwner.drawFrame(list);
  RenderText? found;
  void walk(RenderBox node) {
    if (node is RenderText) found = node;
    node.visitChildren(walk);
  }

  walk(owner.renderRoot!);
  return (owner: owner, list: list, text: found!);
}

/// The colour of every glyph run, in order.
List<int> _glyphColours(DisplayList list) {
  final List<int> colours = <int>[];
  final DisplayListReader reader = DisplayListReader(list);
  while (reader.moveNext()) {
    if (reader.opcode == opDrawGlyphRun) {
      colours.add(list.paintColor(reader.paintId));
    }
  }
  return colours;
}

List<int> _opcodes(DisplayList list) {
  final List<int> opcodes = <int>[];
  final DisplayListReader reader = DisplayListReader(list);
  while (reader.moveNext()) {
    opcodes.add(reader.opcode);
  }
  return opcodes;
}

PointerDownEvent _down(Offset position) => PointerDownEvent(
      windowId: const NativeWindowId(1),
      generation: 1,
      timestamp: Duration.zero,
      pointerId: 0,
      kind: PointerKind.mouse,
      logicalPosition: position,
      button: PointerButton.primary,
    );

PointerUpEvent _up(Offset position) => PointerUpEvent(
      windowId: const NativeWindowId(1),
      generation: 1,
      timestamp: Duration.zero,
      pointerId: 0,
      kind: PointerKind.mouse,
      logicalPosition: position,
      button: PointerButton.primary,
    );

void main() {
  setUp(() {
    FontRegistry.instance
      ..reset()
      ..useFontFile('test/fonts/Roboto-Regular.ttf');
  });
  tearDown(FontRegistry.instance.reset);

  group('TextStyle', () {
    test('merge lets the argument win field by field, new fields included', () {
      const TextStyle base = TextStyle(
        fontSize: 20,
        letterSpacing: 1,
        decoration: TextDecoration.underline,
      );
      final TextStyle merged = base.merge(const TextStyle(
        letterSpacing: 3,
        fontStyle: FontStyle.italic,
        decorationStyle: TextDecorationStyle.dashed,
      ));
      expect(merged.fontSize, 20);
      expect(merged.letterSpacing, 3);
      expect(merged.fontStyle, FontStyle.italic);
      expect(merged.decoration, TextDecoration.underline);
      expect(merged.decorationStyle, TextDecorationStyle.dashed);
      expect(
        base.copyWith(wordSpacing: 4, backgroundColor: _red),
        const TextStyle(
          fontSize: 20,
          letterSpacing: 1,
          wordSpacing: 4,
          backgroundColor: _red,
          decoration: TextDecoration.underline,
        ),
      );
    });

    test('TextDecoration.combine contains its parts', () {
      final TextDecoration both = TextDecoration.combine(<TextDecoration>[
        TextDecoration.underline,
        TextDecoration.lineThrough,
      ]);
      expect(both.contains(TextDecoration.underline), isTrue);
      expect(both.contains(TextDecoration.lineThrough), isTrue);
      expect(both.contains(TextDecoration.overline), isFalse);
      expect(
        both,
        TextDecoration.combine(<TextDecoration>[
          TextDecoration.lineThrough,
          TextDecoration.underline,
        ]),
      );
    });
  });

  group('Text.rich', () {
    test('styles inherit down the span tree from the ambient style', () {
      final ({BuildOwner owner, DisplayList list, RenderText text}) m = _mount(
        const DefaultTextStyle(
          style: TextStyle(fontSize: 20, color: _green),
          child: Text.rich(
            TextSpan(
              style: TextStyle(letterSpacing: 2),
              children: <InlineSpan>[
                TextSpan(text: 'ab'),
                TextSpan(
                  text: 'cd',
                  style: TextStyle(color: _red),
                  children: <InlineSpan>[
                    TextSpan(text: 'ef', style: TextStyle(fontSize: 30)),
                  ],
                ),
              ],
            ),
          ),
        ),
      );
      expect(m.text.text, 'abcdef');
      final Paragraph p = m.text.laidOutParagraph!;
      final List<ParagraphTextStyle> styles = <ParagraphTextStyle>[
        for (final ParagraphTextSpan span in p.spans) span.style,
      ];
      expect(styles, hasLength(3));
      // Size from DefaultTextStyle, spacing from the root span, everywhere.
      expect(styles[0].font.pixelSize, 20);
      expect(styles[1].font.pixelSize, 20);
      expect(styles[2].font.pixelSize, 30, reason: 'its own size');
      expect(styles.map((ParagraphTextStyle s) => s.letterSpacing),
          everyElement(2));
      // A leaf with no colour of its own is drawn in the ambient colour; a
      // child inherits its parent's red.
      expect(styles[0].color, isNull);
      expect(styles[1].color, _red);
      expect(styles[2].color, _red);
      expect(
          _glyphColours(m.list), <int>[_green.value, _red.value, _red.value]);
    });

    test('a rebuilt identical span tree does not lay out again', () {
      // Built fresh on every call - not const - so only value equality can
      // tell the two trees are the same.
      Widget tree() {
        final String b = String.fromCharCode(0x62);
        return Text.rich(TextSpan(
          text: 'a',
          children: <InlineSpan>[
            TextSpan(text: b, style: const TextStyle(color: _red)),
          ],
        ));
      }

      final ({BuildOwner owner, DisplayList list, RenderText text}) m =
          _mount(tree());
      expect(m.text.needsLayout, isFalse);
      m.owner.updateRoot(Directionality(
        textDirection: TextDirection.leftToRight,
        child: Align(alignment: Alignment.topLeft, child: tree()),
      ));
      m.owner.buildScope();
      // Asked before layout runs: the paragraph cache would hand back the
      // same paragraph either way, so only the dirty bit tells.
      expect(m.text.needsLayout, isFalse);

      m.owner.updateRoot(Directionality(
        textDirection: TextDirection.leftToRight,
        child: Align(
          alignment: Alignment.topLeft,
          child: Text.rich(TextSpan(
            text: 'a',
            children: <InlineSpan>[
              TextSpan(
                text: String.fromCharCode(0x62),
                style: const TextStyle(color: _green),
              ),
            ],
          )),
        ),
      ));
      m.owner.buildScope();
      expect(m.text.needsLayout, isTrue, reason: 'a different tree does');
    });

    test('a span with a recognizer is tapped over its glyphs only', () {
      int taps = 0;
      final TapGestureRecognizer link = TapGestureRecognizer()
        ..onTap = () => taps++;
      addTearDown(link.dispose);
      final ({BuildOwner owner, DisplayList list, RenderText text}) m = _mount(
        Text.rich(TextSpan(
          style: const TextStyle(fontSize: 20),
          children: <InlineSpan>[
            const TextSpan(text: 'plain '),
            TextSpan(text: 'link', recognizer: link),
          ],
        )),
      );
      final Paragraph p = m.text.laidOutParagraph!;
      final Rect linkBox = p.getBoxesForSelection(6, 10).single.rect;
      final Rect plainBox = p.getBoxesForSelection(0, 5).single.rect;

      m.owner.dispatchPointerEvent(_down(plainBox.center));
      m.owner.dispatchPointerEvent(_up(plainBox.center));
      expect(taps, 0, reason: 'the plain text is not the link');

      m.owner.dispatchPointerEvent(_down(linkBox.center));
      m.owner.dispatchPointerEvent(_up(linkBox.center));
      expect(taps, 1);
      expect(
        m.text.cursorFor(_down(linkBox.center)),
        SystemCursor.hand,
      );
    });
  });

  group('plain Text with a rich style', () {
    test('stays on the single-run path when it needs nothing more', () {
      final ({BuildOwner owner, DisplayList list, RenderText text}) m =
          _mount(const Text('plain', style: TextStyle(fontSize: 16)));
      expect(m.text.laidOutParagraph, isNull);
    });

    test('routes through the paragraph for underline, spacing and italic', () {
      final ({BuildOwner owner, DisplayList list, RenderText text}) m = _mount(
        const Text(
          'Styled',
          style: TextStyle(
            fontSize: 16,
            fontStyle: FontStyle.italic,
            decoration: TextDecoration.underline,
            letterSpacing: 2,
          ),
        ),
      );
      final Paragraph? p = m.text.laidOutParagraph;
      expect(p, isNotNull);
      final ParagraphTextStyle style = p!.spans.single.style;
      expect(style.decoration, TextDecoration.underline);
      expect(style.letterSpacing, 2);
      // Roboto Regular is the only face registered: italic is sheared.
      expect(style.syntheticItalic, isTrue);
      final List<int> opcodes = _opcodes(m.list);
      expect(opcodes, contains(opTransform));
      expect(opcodes, contains(opDrawRect), reason: 'the underline');
    });

    test(
        'letter spacing widens the box by about spacing x clusters, and the '
        'carets follow', () {
      const String text = 'Spacing';
      final double plain =
          _mount(const Text(text, fontSize: 16)).text.size.width;
      final RenderText spaced = _mount(const Text(
        text,
        fontSize: 16,
        style: TextStyle(letterSpacing: 3),
      )).text;
      expect(spaced.size.width, closeTo(plain + 3 * text.length, 0.5));
      final Paragraph p = spaced.laidOutParagraph!;
      final double c1 = p.getCaretRect(const TextPosition(1)).left;
      final double c2 = p.getCaretRect(const TextPosition(2)).left;
      final GlyphRun glyphs = p.lines.single.spans.single.glyphs;
      expect(glyphs.xOf(1), closeTo(c1, 1e-6),
          reason: 'drawn where the caret is');
      expect(glyphs.xOf(2), closeTo(c2, 1e-6));
    });
  });

  test('italic picks an italic face when the family has one', () {
    // Any installed family with both an upright and a true italic will do.
    final FontRegistry registry = FontRegistry.instance;
    String? family;
    final Set<String> upright = <String>{
      for (final SystemFontFace face in registry.systemFonts.faces)
        if (!face.italic && !face.oblique) face.family,
    };
    for (final SystemFontFace face in registry.systemFonts.faces) {
      if (face.italic && !face.oblique && upright.contains(face.family)) {
        family = face.family;
        break;
      }
    }
    if (family == null) {
      markTestSkipped('no family with an italic face is installed');
      return;
    }
    final ({BuildOwner owner, DisplayList list, RenderText text}) m = _mount(
      Text('Italic',
          style: TextStyle(fontFamily: family, fontStyle: FontStyle.italic)),
    );
    expect(m.text.font!.typeface.isItalic, isTrue, reason: family);
    // A real italic is a choice of face: no shear, and still one run.
    expect(m.text.laidOutParagraph, isNull);
    expect(_opcodes(m.list), isNot(contains(opTransform)));
  });

  group('RichText', () {
    test('cuts to maxLines and ends the last line in an ellipsis', () {
      final ({BuildOwner owner, DisplayList list, RenderText text}) m = _mount(
        const SizedBox(
          width: 120,
          child: RichText(
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            text: TextSpan(
              text: 'one two three four five six seven eight nine ten',
              style: TextStyle(fontSize: 14),
            ),
          ),
        ),
      );
      final Paragraph p = m.text.laidOutParagraph!;
      expect(p.lines, hasLength(2));
      expect(p.didExceedMaxLines, isTrue);
      expect(p.lines.last.spans.last.isEllipsis, isTrue);
      expect(p.lines.last.width, lessThanOrEqualTo(120));
    });

    test('an ellipsis without maxLines on unwrapped text cuts one line', () {
      final ({BuildOwner owner, DisplayList list, RenderText text}) m = _mount(
        const SizedBox(
          width: 60,
          child: RichText(
            softWrap: false,
            overflow: TextOverflow.ellipsis,
            text: TextSpan(text: 'a long single line of text'),
          ),
        ),
      );
      final Paragraph p = m.text.laidOutParagraph!;
      expect(p.lines, hasLength(1));
      expect(p.lines.single.spans.last.isEllipsis, isTrue);
    });

    test('does not inherit the ambient style, as in Flutter', () {
      final ({BuildOwner owner, DisplayList list, RenderText text}) m = _mount(
        const DefaultTextStyle(
          style: TextStyle(fontSize: 30, color: _green),
          child: RichText(text: TextSpan(text: 'x')),
        ),
      );
      expect(m.text.fontSize, kDefaultUiFontSize);
      expect(_glyphColours(m.list), isNot(contains(_green.value)));
    });
  });
}
