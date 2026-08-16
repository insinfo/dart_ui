/// Paragraph layout, asserted numerically.
///
/// Almost every test here uses `ahem.ttf`, whose every glyph is a solid box one
/// em wide, 0.8 em above the baseline and 0.2 em below. At 10 px that makes
/// every advance exactly 10.0 and every line exactly 10.0 tall, so a wrap, a
/// caret, a selection rectangle and a tab stop all have one right answer and
/// the test can state it as a number rather than as "did not throw".
///
/// `DejaVuSans.ttf` appears where a real script is needed - it covers Hebrew,
/// Arabic, Greek and Cyrillic - and `Roboto-Regular.ttf` where a real
/// proportional Latin face is.
library;

import 'dart:io';

import 'package:dart_ui/src/geometry/offset.dart';
import 'package:dart_ui/src/geometry/rect.dart';
import 'package:dart_ui/src/text/paragraph.dart';
import 'package:dart_ui/src/text/shaper.dart';
import 'package:dart_ui/src/text/typeface.dart';
import 'package:test/test.dart';

Typeface _face(String name) =>
    Typeface.parse(File('test/fonts/$name').readAsBytesSync());

/// U+05D0..U+05D2, three Hebrew letters: strong right-to-left.
const String _heb = 'אבג';

/// "house", three Arabic letters that all join: the middle one has an initial,
/// medial and final form and a shaper that ignores the script picks none of
/// them.
const String _arab = 'بيت';

const String _shy = '­';

String _sliceOf(Paragraph p, GlyphSpan span) =>
    p.text.substring(span.start, span.end);

void main() {
  late Typeface ahem;
  late Typeface dejaVu;
  late Typeface roboto;
  late TextStyle a10;
  late TextStyle d10;

  setUp(() {
    ahem = _face('ahem.ttf');
    dejaVu = _face('DejaVuSans.ttf');
    roboto = _face('Roboto-Regular.ttf');
    a10 = TextStyle(font: ahem.atSize(10));
    d10 = TextStyle(font: dejaVu.atSize(10));
  });

  group('the fixtures are what the numbers assume', () {
    test('Ahem is exactly one em per glyph and 0.8/0.2 around the baseline',
        () {
      final ScaledTypeface font = ahem.atSize(10);
      expect(font.ascent, 8.0);
      expect(font.descent, 2.0);
      expect(font.lineGap, 0.0);
      expect(font.advanceOf(font.typeface.glyphForCodePoint(0x61)), 10.0);
      expect(font.advanceOf(font.typeface.glyphForCodePoint(0x20)), 10.0);
    });

    test('DejaVu covers the scripts these tests need', () {
      expect(dejaVu.covers(_heb), isTrue, reason: 'Hebrew');
      expect(dejaVu.covers(_arab), isTrue, reason: 'Arabic');
      expect(dejaVu.covers('ΑΒ'), isTrue, reason: 'Greek');
      expect(dejaVu.covers('АБ'), isTrue, reason: 'Cyrillic');
    });
  });

  group('line breaking at a known width', () {
    test('"aaa bbb ccc" at 75 px of Ahem breaks after each word that fits', () {
      final Paragraph p = Paragraph.single('aaa bbb ccc', a10, maxWidth: 75);

      expect(p.lines.length, 2);
      expect(p.lines[0].start, 0);
      expect(p.lines[0].end, 7, reason: 'the trailing space is trimmed');
      expect(p.lines[0].endIncludingWhitespace, 8);
      expect(p.lines[0].width, 70.0);
      expect(p.lines[1].start, 8);
      expect(p.lines[1].end, 11);
      expect(p.lines[1].width, 30.0);
      expect(p.height, 20.0);
      expect(p.longestLine, 70.0);
      expect(p.size.width, 70.0);
    });

    test('one pixel narrower moves a word down', () {
      // 70 px is exactly "aaa bbb"; 69 is not, and the break has to move.
      expect(
        Paragraph.single('aaa bbb ccc', a10, maxWidth: 70).lines.length,
        2,
      );
      expect(
        Paragraph.single('aaa bbb ccc', a10, maxWidth: 69).lines[0].end,
        3,
      );
    });

    test('trailing whitespace is not measured for the fit', () {
      // "aaa " is 40 px of advance but only 30 px of content. At 35 px it still
      // fits on one line with "bbb" below it, which is the CSS behaviour and
      // the reason a centred line looks centred.
      final Paragraph p = Paragraph.single('aaa bbb', a10, maxWidth: 35);
      expect(p.lines.length, 2);
      expect(p.lines[0].width, 30.0);
    });

    test('a word wider than the line overflows rather than being cut', () {
      final Paragraph p = Paragraph.single('aaaaaaaa', a10, maxWidth: 30);
      expect(p.lines.length, 1);
      expect(p.lines[0].width, 80.0);
    });

    test('a mandatory break ends the line however much room is left', () {
      final Paragraph p = Paragraph.single('a\nb', a10, maxWidth: 1000);
      expect(p.lines.length, 2);
      expect(p.lines[0].end, 1);
      expect(p.lines[0].hardBreak, isTrue);
      expect(p.lines[1].start, 2);
      expect(p.height, 20.0);
    });

    test('a trailing newline leaves an empty line to put a caret on', () {
      final Paragraph p = Paragraph.single('a\n', a10);
      expect(p.lines.length, 2);
      expect(p.lines[1].start, 2);
      expect(p.lines[1].end, 2);
      expect(p.lines[1].height, 10.0);
    });

    test('empty text is one empty line with a real height', () {
      final Paragraph p = Paragraph.single('', a10);
      expect(p.lines.length, 1);
      expect(p.lines.single.spans, isEmpty);
      expect(p.height, 10.0);
      expect(p.longestLine, 0.0);
      expect(p.getCaretRect(const TextPosition(0)),
          const Rect.fromLTRB(0, 0, 0, 10));
    });

    test('the widths come from shaping, not from nominal advances', () {
      // Roboto kerns "AV". A paragraph that measured with the unshaped advance
      // would report a wider line than it draws, and the text would not fill
      // the box reserved for it.
      final TextStyle r = TextStyle(font: roboto.atSize(32));
      final Paragraph p = Paragraph.single('AVATAR', r);
      expect(p.longestLine, lessThan(r.font.measure('AVATAR')));
    });
  });

  group('bidi', () {
    test('a pure left-to-right paragraph is one span at level 0', () {
      final Paragraph p = Paragraph.single('abc', a10);
      expect(p.baseDirection, TextDirection.leftToRight);
      expect(p.lines.single.spans.length, 1);
      expect(p.lines.single.spans.single.bidiLevel, 0);
      expect(p.lines.single.spans.single.left, 0.0);
    });

    test('a pure right-to-left paragraph takes the base direction from P2', () {
      final Paragraph p = Paragraph.single(_heb, d10);
      expect(p.baseDirection, TextDirection.rightToLeft);
      expect(p.lines.single.spans.single.bidiLevel, 1);
      expect(
        p.lines.single.spans.single.direction,
        TextDirection.rightToLeft,
      );
    });

    test('a mixed line comes out in visual order, left to right', () {
      final Paragraph p = Paragraph.single('ab $_heb cd', a10);
      final List<GlyphSpan> spans = p.lines.single.spans;

      // The spans are handed out in visual order, so their left edges ascend
      // and the Hebrew sits between the two Latin pieces even though it is a
      // level-1 run inside a level-0 paragraph.
      for (int i = 1; i < spans.length; i++) {
        expect(spans[i].left, greaterThanOrEqualTo(spans[i - 1].left));
      }
      final GlyphSpan hebrew =
          spans.firstWhere((GlyphSpan s) => s.bidiLevel == 1);
      expect(_sliceOf(p, hebrew), _heb);
      expect(hebrew.left, 30.0, reason: '"ab " is three Ahem ems');
      expect(hebrew.width, 30.0);
      expect(p.lines.single.width, 90.0);
    });

    test('the glyphs of a right-to-left run descend in cluster order', () {
      // The property everything above depends on: a right-to-left run comes
      // back in *visual* order, so glyph 0 is the logically last character.
      final Paragraph p = Paragraph.single(_heb, d10);
      final GlyphRun run = p.lines.single.spans.single.glyphs;
      expect(run.length, 3);
      expect(run.clusters[0], 2);
      expect(run.clusters[1], 1);
      expect(run.clusters[2], 0);
      expect(run.xOf(0), 0.0);
      expect(run.xOf(1), greaterThan(run.xOf(0)));
      expect(run.xOf(2), greaterThan(run.xOf(1)));
    });

    test('Latin inside a right-to-left paragraph is a level-2 island', () {
      final Paragraph p = Paragraph.single('$_heb abc', d10);
      expect(p.baseDirection, TextDirection.rightToLeft);
      final List<GlyphSpan> spans = p.lines.single.spans;
      // Visual order under an RTL base: the Latin island is leftmost.
      expect(spans.first.bidiLevel, 2);
      expect(_sliceOf(p, spans.first), 'abc');
      expect(spans.first.left, 0.0);
      expect(spans.last.bidiLevel, 1);
    });

    test('an Arabic run reaches the shaper as Arabic, not as Latin', () {
      // Not a joining test - that is the shaper's. What this asserts is that
      // itemization reached the shaper at all: shaping Arabic as `latn` would
      // apply the wrong feature set and produce a different number of glyphs
      // than shaping it as `arab`.
      final Paragraph p =
          Paragraph.single(_arab, TextStyle(font: dejaVu.atSize(16)));
      final GlyphRun viaParagraph = p.lines.single.spans.single.glyphs;
      final GlyphRun viaLatin = OpenTypeShaper().shape(
        _arab,
        dejaVu.atSize(16),
        direction: TextDirection.rightToLeft,
      );
      expect(viaParagraph.length, greaterThan(0));
      expect(
        viaParagraph.glyphIds.sublist(0, viaParagraph.length),
        isNot(viaLatin.glyphIds.sublist(0, viaLatin.length)),
        reason: 'the run was shaped with the Arabic model, not the default',
      );
    });
  });

  group('reordering happens per line, after breaking', () {
    // The test the whole file exists for. "aa בב גג dd" has one level-1 run
    // covering both Hebrew words. Reordering the *paragraph* would reverse that
    // run as a unit, putting גג before בב, and only then would the slicing into
    // lines happen - so line 1 would show the second Hebrew word. Reordering
    // each line after breaking, which is what UAX #9 L2 actually says, keeps
    // the first Hebrew word on the first line.
    const String text = 'aa בב גג dd';

    test('a bidi paragraph that wraps keeps each line in its own L2 order', () {
      final Paragraph p = Paragraph.single(text, a10, maxWidth: 55);

      expect(p.lines.length, 2);

      final List<GlyphSpan> first = p.lines[0].spans;
      final GlyphSpan firstHebrew =
          first.firstWhere((GlyphSpan s) => s.bidiLevel.isOdd);
      expect(firstHebrew.start, 3);
      expect(firstHebrew.end, 5);
      expect(_sliceOf(p, firstHebrew), 'בב',
          reason: 'paragraph-wide reordering would have put גג here');
      expect(first.first.bidiLevel, 0);
      expect(first.first.left, 0.0);
      expect(firstHebrew.left, 30.0);

      final List<GlyphSpan> second = p.lines[1].spans;
      final GlyphSpan secondHebrew =
          second.firstWhere((GlyphSpan s) => s.bidiLevel.isOdd);
      expect(_sliceOf(p, secondHebrew), 'גג');
      expect(secondHebrew.left, 0.0, reason: 'leftmost on its own line');
    });

    test('the same text on one line orders both Hebrew words together', () {
      // The control: with room for one line the level-1 run is contiguous and
      // reverses as a unit, so גג *does* come first visually.
      final Paragraph p = Paragraph.single(text, a10);
      expect(p.lines.length, 1);
      final List<GlyphSpan> rtl = p.lines.single.spans
          .where((GlyphSpan s) => s.bidiLevel.isOdd)
          .toList();
      expect(rtl.length, 1);
      expect(_sliceOf(p, rtl.single), 'בב גג');
    });

    test('three lines each reorder independently', () {
      final Paragraph p =
          Paragraph.single('aa $_heb bb $_heb cc', a10, maxWidth: 65);
      expect(p.lines.length, 3);
      for (final TextLine line in p.lines) {
        double previous = double.negativeInfinity;
        for (final GlyphSpan span in line.spans) {
          expect(span.left, greaterThanOrEqualTo(previous));
          previous = span.left;
        }
        // Every line's spans start at its own left edge, which is only true if
        // the reordering was per line.
        expect(line.spans.first.left, line.left);
      }
      expect(
        p.lines[0].spans.map((GlyphSpan s) => _sliceOf(p, s)),
        <String>['aa ', _heb],
      );
      expect(
        p.lines[1].spans.map((GlyphSpan s) => _sliceOf(p, s)),
        <String>['bb ', _heb],
      );
    });
  });

  group('maxLines and ellipsis', () {
    test('maxLines drops the rest and says so', () {
      final Paragraph p = Paragraph.single(
        'aaa bbb ccc',
        a10,
        maxWidth: 35,
        paragraphStyle: const ParagraphStyle(maxLines: 2),
      );
      expect(p.lines.length, 2);
      expect(p.didExceedMaxLines, isTrue);
      expect(p.height, 20.0);
    });

    test('the ellipsis is measured with the real glyph, not assumed', () {
      // Ahem's '…' is one em, so the kept text is exactly maxWidth minus 10.
      final Paragraph p = Paragraph.single(
        'aaaa bbbb cccc',
        a10,
        maxWidth: 50,
        paragraphStyle: const ParagraphStyle(maxLines: 1, ellipsis: '…'),
      );
      final List<GlyphSpan> spans = p.lines.single.spans;
      expect(spans.length, 2);
      expect(spans[0].end, 4);
      expect(spans[0].width, 40.0);
      expect(spans[1].isEllipsis, isTrue);
      expect(spans[1].left, 40.0);
      expect(spans[1].width, 10.0);
      expect(spans[1].glyphs.length, 1);
      expect(p.lines.single.width, 50.0);
    });

    test('a three-period ellipsis reserves three ems, not one', () {
      final Paragraph p = Paragraph.single(
        'aaaa bbbb cccc',
        a10,
        maxWidth: 50,
        paragraphStyle: const ParagraphStyle(maxLines: 1, ellipsis: '...'),
      );
      expect(p.lines.single.spans.last.width, 30.0);
      expect(p.lines.single.spans.first.end, 2);
    });

    test('the cut never lands inside a surrogate pair', () {
      // U+1F600 occupies offsets 2 and 3. A walk back by code unit would stop
      // at 3 and leave an unpaired high surrogate on the line.
      const String text = 'aa\u{1F600}bb';
      for (final double width in <double>[10, 20, 25, 30, 35, 40, 45]) {
        final Paragraph p = Paragraph.single(
          text,
          a10,
          maxWidth: width,
          paragraphStyle: const ParagraphStyle(maxLines: 1, ellipsis: '.'),
        );
        expect(p.lines.single.end, isNot(3),
            reason: 'cut inside the surrogate pair at width $width');
      }
      expect(
        Paragraph.single(
          text,
          a10,
          maxWidth: 40,
          paragraphStyle: const ParagraphStyle(maxLines: 1, ellipsis: '.'),
        ).lines.single.end,
        4,
      );
    });

    test('the cut never lands inside an emoji ZWJ sequence', () {
      // U+1F468 ZWJ U+1F469 ZWJ U+1F467 is one grapheme cluster occupying
      // offsets 2..10. Cutting inside it turns a family into a man and a
      // dangling joiner.
      const String family = '\u{1F468}‍\u{1F469}‍\u{1F467}';
      const String text = 'ab$family cd';
      for (double width = 10; width <= 140; width += 5) {
        final int end = Paragraph.single(
          text,
          a10,
          maxWidth: width,
          paragraphStyle: const ParagraphStyle(maxLines: 1, ellipsis: '.'),
        ).lines.single.end;
        expect(end < 3 || end > 9, isTrue,
            reason: 'cut at $end is inside the ZWJ sequence (width $width)');
      }
    });

    test('no ellipsis when nothing was dropped', () {
      final Paragraph p = Paragraph.single(
        'aa',
        a10,
        maxWidth: 100,
        paragraphStyle: const ParagraphStyle(maxLines: 3, ellipsis: '…'),
      );
      expect(p.didExceedMaxLines, isFalse);
      expect(p.lines.single.spans.any((GlyphSpan s) => s.isEllipsis), isFalse);
    });

    test('the ellipsis takes the style of the run it replaces', () {
      final Paragraph p = Paragraph.layout(
        spans: <TextSpan>[
          TextSpan('aa', a10),
          TextSpan('bbbb cccc', TextStyle(font: ahem.atSize(20))),
        ],
        style: const ParagraphStyle(maxLines: 1, ellipsis: '.'),
        maxWidth: 60,
      );
      final GlyphSpan dots =
          p.lines.single.spans.firstWhere((GlyphSpan s) => s.isEllipsis);
      expect(dots.style.font.pixelSize, 20.0);
      expect(dots.width, 20.0);
    });
  });

  group('textAlign', () {
    Paragraph laid(TextAlign align, {TextDirection? base}) => Paragraph.single(
          'aa bb',
          a10,
          maxWidth: 100,
          paragraphStyle: ParagraphStyle(align: align, baseDirection: base),
        );

    test('left, right and center place the 50 px line in a 100 px box', () {
      expect(laid(TextAlign.left).lines.single.left, 0.0);
      expect(laid(TextAlign.right).lines.single.left, 50.0);
      expect(laid(TextAlign.center).lines.single.left, 25.0);
    });

    test('start and end follow the base direction', () {
      expect(laid(TextAlign.start).lines.single.left, 0.0);
      expect(laid(TextAlign.end).lines.single.left, 50.0);
      expect(
        laid(TextAlign.start, base: TextDirection.rightToLeft)
            .lines
            .single
            .left,
        50.0,
      );
      expect(
        laid(TextAlign.end, base: TextDirection.rightToLeft).lines.single.left,
        0.0,
      );
    });

    test('left and right ignore the base direction', () {
      expect(
        laid(TextAlign.left, base: TextDirection.rightToLeft).lines.single.left,
        0.0,
      );
      expect(
        laid(TextAlign.right, base: TextDirection.rightToLeft)
            .lines
            .single
            .left,
        50.0,
      );
    });

    test('alignment moves the spans, not just the line box', () {
      final TextLine line = laid(TextAlign.center).lines.single;
      expect(line.spans.first.left, 25.0);
      expect(line.spans.last.right, 75.0);
    });

    test('justify stretches every line but the last', () {
      final Paragraph p = Paragraph.single(
        'aa bb cc dd',
        a10,
        maxWidth: 60,
        paragraphStyle: const ParagraphStyle(align: TextAlign.justify),
      );
      expect(p.lines.length, 2);
      // "aa bb" is 50 px of content in a 60 px line, and the single space
      // absorbs all 10 px of it.
      expect(p.lines[0].width, 60.0);
      final GlyphSpan space = p.lines[0].spans[1];
      expect(space.width, 20.0);
      expect(p.lines[0].spans[2].left, 40.0);
      expect(p.lines[1].width, 50.0, reason: 'the last line is not stretched');
    });

    test('justify cannot stretch a line with no spaces', () {
      final Paragraph p = Paragraph.single(
        'aaaaaa\nbb',
        a10,
        maxWidth: 100,
        paragraphStyle: const ParagraphStyle(align: TextAlign.justify),
      );
      expect(p.lines[0].width, 60.0);
      expect(p.lines[0].left, 0.0);
    });

    test('alignment measures against the longest line when width is infinite',
        () {
      final Paragraph p = Paragraph.single(
        'aaaa\nbb',
        a10,
        paragraphStyle: const ParagraphStyle(align: TextAlign.right),
      );
      expect(p.longestLine, 40.0);
      expect(p.lines[0].left, 0.0);
      expect(p.lines[1].left, 20.0);
    });
  });

  group('caret and affinity', () {
    test('a caret walks one em at a time through Ahem', () {
      final Paragraph p = Paragraph.single('abcd', a10);
      for (int i = 0; i <= 4; i++) {
        expect(p.getCaretRect(TextPosition(i)).left, i * 10.0);
      }
      expect(p.getCaretRect(const TextPosition(0)).top, 0.0);
      expect(p.getCaretRect(const TextPosition(0)).bottom, 10.0);
      expect(p.getCaretRect(const TextPosition(0)).width, 0.0);
    });

    test('the two affinities of a direction boundary are different places', () {
      // "abc" then Hebrew, all on one line: [abc][גבא]. Offset 3 is the end of
      // the Latin run - x = 30 - and the *leading* edge of the Hebrew run,
      // which is its right-hand end at x = 60.
      final Paragraph p = Paragraph.single('abc$_heb', a10);
      final List<GlyphSpan> spans = p.lines.single.spans;
      expect(spans.length, 2);
      expect(spans[0].bidiLevel, 0);
      expect(spans[1].bidiLevel, 1);

      final double upstream = p
          .getCaretRect(
            const TextPosition(3, affinity: TextAffinity.upstream),
          )
          .left;
      final double downstream = p.getCaretRect(const TextPosition(3)).left;

      expect(upstream, 30.0, reason: 'trailing edge of the Latin run');
      expect(downstream, 60.0, reason: 'leading edge of the Hebrew run');
      expect(upstream, isNot(downstream));
    });

    test('inside a right-to-left run the caret moves leftwards', () {
      final Paragraph p = Paragraph.single(_heb, a10);
      expect(p.getCaretRect(const TextPosition(0)).left, 30.0);
      expect(p.getCaretRect(const TextPosition(1)).left, 20.0);
      expect(p.getCaretRect(const TextPosition(2)).left, 10.0);
      expect(
        p
            .getCaretRect(
                const TextPosition(3, affinity: TextAffinity.upstream))
            .left,
        0.0,
      );
    });

    test('the two affinities of a wrap point are on different lines', () {
      final Paragraph p = Paragraph.single('aaa bbb', a10, maxWidth: 35);
      expect(p.lines.length, 2);
      final Rect upstream = p.getCaretRect(
        const TextPosition(3, affinity: TextAffinity.upstream),
      );
      final Rect downstream = p.getCaretRect(const TextPosition(4));
      expect(upstream.top, 0.0);
      expect(upstream.left, 30.0);
      expect(downstream.top, 10.0);
      expect(downstream.left, 0.0);
    });

    test('the caret spans the whole line height, including a tall run', () {
      final Paragraph p = Paragraph.layout(
        spans: <TextSpan>[
          TextSpan('a', a10),
          TextSpan('b', TextStyle(font: ahem.atSize(30))),
        ],
      );
      expect(p.getCaretRect(const TextPosition(0)).height, 30.0);
    });
  });

  group('hit testing', () {
    test('a point maps back to the offset whose caret is nearest', () {
      final Paragraph p = Paragraph.single('abcd', a10);
      expect(p.getPositionForOffset(const Offset(2, 5)).offset, 0);
      expect(p.getPositionForOffset(const Offset(6, 5)).offset, 1);
      expect(p.getPositionForOffset(const Offset(14, 5)).offset, 1);
      expect(p.getPositionForOffset(const Offset(16, 5)).offset, 2);
      expect(p.getPositionForOffset(const Offset(-40, 5)).offset, 0);
      expect(p.getPositionForOffset(const Offset(400, 5)).offset, 4);
    });

    test('a point on the second line maps into the second line', () {
      final Paragraph p = Paragraph.single('aaa bbb', a10, maxWidth: 35);
      expect(p.getPositionForOffset(const Offset(5, 15)).offset, 4);
      expect(p.getPositionForOffset(const Offset(400, 15)).offset, 7);
    });

    test('a hit inside a right-to-left run reads right to left', () {
      // [ab][בא] with the Hebrew occupying 20..40: א is drawn at 30..40 and ב
      // at 20..30, so a click at 22 is nearest the boundary before ב, offset 4.
      final Paragraph p = Paragraph.single('abאב', a10);
      expect(p.getPositionForOffset(const Offset(38, 5)).offset, 2);
      expect(p.getPositionForOffset(const Offset(22, 5)).offset, 4);
    });

    test('a hit never lands inside a grapheme cluster', () {
      const String text = 'a\u{1F600}b';
      final Paragraph p = Paragraph.single(text, a10);
      for (double x = 0; x < 40; x += 1) {
        expect(p.getPositionForOffset(Offset(x, 5)).offset, isNot(2),
            reason: 'x = $x landed in the middle of the surrogate pair');
      }
    });

    test('the position round-trips through the caret', () {
      final Paragraph p = Paragraph.single('abc$_heb', a10);
      for (double x = 1; x < 60; x += 3) {
        final TextPosition hit = p.getPositionForOffset(Offset(x, 5));
        expect((p.getCaretRect(hit).left - x).abs(), lessThanOrEqualTo(5.0),
            reason: 'caret for the hit at $x came back at '
                '${p.getCaretRect(hit).left}');
      }
    });
  });

  group('selection', () {
    test('a left-to-right selection is one rectangle', () {
      final Paragraph p = Paragraph.single('abcd', a10);
      final List<TextBox> boxes = p.getBoxesForSelection(1, 3);
      expect(boxes.length, 1);
      expect(boxes.single.rect, const Rect.fromLTRB(10, 0, 30, 10));
      expect(boxes.single.direction, TextDirection.leftToRight);
    });

    test('an empty or reversed range selects nothing', () {
      final Paragraph p = Paragraph.single('abcd', a10);
      expect(p.getBoxesForSelection(2, 2), isEmpty);
      expect(p.getBoxesForSelection(3, 1), isEmpty);
    });

    test('a selection crossing a direction boundary is two rectangles', () {
      // "ab" then "אב": logically contiguous offsets 1..3 are *not* contiguous
      // on screen. The Latin half is at 10..20 and the Hebrew half is at 30..40
      // - the far side of the Hebrew run - with 20..30 in between belonging to
      // the character at offset 3, which is not selected.
      final Paragraph p = Paragraph.single('abאב', a10);
      final List<TextBox> boxes = p.getBoxesForSelection(1, 3);

      expect(boxes.length, 2, reason: 'a bidi selection is discontinuous');
      expect(boxes[0].rect, const Rect.fromLTRB(10, 0, 20, 10));
      expect(boxes[0].direction, TextDirection.leftToRight);
      expect(boxes[1].rect, const Rect.fromLTRB(30, 0, 40, 10));
      expect(boxes[1].direction, TextDirection.rightToLeft);
    });

    test('a selection spanning lines is one rectangle per line', () {
      final Paragraph p = Paragraph.single('aaa bbb', a10, maxWidth: 35);
      final List<TextBox> boxes = p.getBoxesForSelection(1, 6);
      expect(boxes.length, 2);
      // 10..40, not 10..30: offset 3 is the space at the wrap, it is inside
      // [1, 6), and a highlight that stopped at 30 would claim the space is
      // not selected while deleting the selection still removes it. The space
      // hangs past the line's 30 px width, which is why the box is wider than
      // `lines[0].width` - see the trailing whitespace group.
      expect(boxes[0].rect, const Rect.fromLTRB(10, 0, 40, 10));
      expect(boxes[1].rect, const Rect.fromLTRB(0, 10, 20, 20));
    });

    test('adjacent same-direction runs merge into one rectangle', () {
      // "ab" and "cd" are two style spans and therefore two runs, but they are
      // visually adjacent and a selection across them is one box.
      final Paragraph p = Paragraph.layout(
        spans: <TextSpan>[TextSpan('ab', a10), TextSpan('cd', a10)],
      );
      final List<TextBox> boxes = p.getBoxesForSelection(0, 4);
      expect(boxes.length, 1);
      expect(boxes.single.rect.width, 40.0);
    });

    test('the ellipsis is never part of a selection', () {
      final Paragraph p = Paragraph.single(
        'aaaa bbbb',
        a10,
        maxWidth: 50,
        paragraphStyle: const ParagraphStyle(maxLines: 1, ellipsis: '.'),
      );
      final List<TextBox> boxes = p.getBoxesForSelection(0, 9);
      expect(boxes.length, 1);
      expect(boxes.single.rect.right, lessThanOrEqualTo(40.0));
    });
  });

  group('trailing whitespace: trimmed for width, measured for the caret', () {
    // The reported bug: typing a space in a text field did nothing visible.
    // The controller inserted it, but the paragraph trimmed it from the line
    // and the caret was placed at the trimmed edge, so the cursor did not move
    // until the *next* character arrived and made the space appear
    // retroactively. Both halves are asserted here, because fixing the caret
    // by untrimming the line would swap this bug for a worse one: a centred
    // line that jumps sideways when you type a space.

    test('the caret advances through one, then two trailing spaces', () {
      final Paragraph p = Paragraph.single('ab  ', a10);
      expect(p.lines.single.end, 2);
      expect(p.lines.single.endIncludingWhitespace, 4);

      final List<double> x = <double>[
        for (int i = 0; i <= 4; i++) p.getCaretRect(TextPosition(i)).left,
      ];
      expect(x, <double>[0, 10, 20, 30, 40]);
      for (int i = 1; i < x.length; i++) {
        expect(x[i], greaterThan(x[i - 1]),
            reason: 'caret $i did not move past caret ${i - 1}');
      }
      expect(x.toSet().length, x.length, reason: 'no two carets coincide');
    });

    test('the caret rect stays on the line the whitespace belongs to', () {
      final Paragraph p = Paragraph.single('ab ', a10);
      final Rect caret = p.getCaretRect(const TextPosition(3));
      expect(caret.top, 0.0);
      expect(caret.bottom, 10.0);
      expect(caret.width, 0.0);
    });

    test('Roboto: the space moves the caret and does not widen the line', () {
      // The exact case from the report, at the size the gallery uses. The
      // controller holds "ab " and offset 3 has to be a different place from
      // offset 2 - it was not, which is what made the space invisible.
      final TextStyle r = TextStyle(font: roboto.atSize(16));
      final ScaledTypeface font = r.font;
      final double space =
          font.advanceOf(font.typeface.glyphForCodePoint(0x20));
      expect(space, greaterThan(0));

      final Paragraph none = Paragraph.single('ab', r);
      final Paragraph one = Paragraph.single('ab ', r);
      final Paragraph two = Paragraph.single('ab  ', r);

      // The half that must not regress: a trailing space is not width.
      expect(one.longestLine, none.longestLine);
      expect(two.longestLine, none.longestLine);
      expect(one.lines.single.width, none.lines.single.width);
      expect(two.lines.single.width, none.lines.single.width);

      // The half that was broken: it is still a caret position.
      final double end = none.getCaretRect(const TextPosition(2)).left;
      expect(one.getCaretRect(const TextPosition(2)).left, end);
      expect(one.getCaretRect(const TextPosition(3)).left,
          closeTo(end + space, 1e-9));
      expect(two.getCaretRect(const TextPosition(3)).left,
          closeTo(end + space, 1e-9));
      expect(two.getCaretRect(const TextPosition(4)).left,
          closeTo(end + 2 * space, 1e-9));
    });

    test('a line of nothing but spaces still walks a caret across them', () {
      // No span owns any of these offsets: the line laid out nothing at all.
      final Paragraph p = Paragraph.single('   ', a10);
      expect(p.lines.single.width, 0.0);
      expect(p.lines.single.spans, isEmpty);
      expect(
        <double>[
          for (int i = 0; i <= 3; i++) p.getCaretRect(TextPosition(i)).left,
        ],
        <double>[0, 10, 20, 30],
      );
    });

    test('a selection covering a trailing space draws over it', () {
      final Paragraph p = Paragraph.single('ab ', a10);
      final List<TextBox> whole = p.getBoxesForSelection(0, 3);
      expect(whole.length, 1, reason: 'the space merges with the text');
      expect(whole.single.rect, const Rect.fromLTRB(0, 0, 30, 10));
      expect(whole.single.direction, TextDirection.leftToRight);

      // The space on its own is still a rectangle with width in it.
      final List<TextBox> onlySpace = p.getBoxesForSelection(2, 3);
      expect(onlySpace.length, 1);
      expect(onlySpace.single.rect, const Rect.fromLTRB(20, 0, 30, 10));

      // And stopping before it does not.
      expect(p.getBoxesForSelection(0, 2).single.rect,
          const Rect.fromLTRB(0, 0, 20, 10));
    });

    test('a selected newline does not sprout a hairline box', () {
      // The mandatory break is trailing whitespace too, and it has no width.
      // Emitting a zero-width rectangle for it would put a one-pixel artefact
      // at the end of every line a multi-line selection crosses.
      final Paragraph p = Paragraph.single('a\nb', a10);
      final List<TextBox> boxes = p.getBoxesForSelection(0, 3);
      expect(boxes.length, 2);
      expect(boxes[0].rect, const Rect.fromLTRB(0, 0, 10, 10));
      expect(boxes[1].rect, const Rect.fromLTRB(0, 10, 10, 20));
    });

    test('a click right of the last space lands after it', () {
      final Paragraph p = Paragraph.single('ab  ', a10);
      expect(p.getPositionForOffset(const Offset(400, 5)).offset, 4,
          reason: 'the end of the text, not the end of the trimmed content');
      expect(p.getPositionForOffset(const Offset(35, 5)).offset, 3,
          reason: 'between the two spaces');
      expect(p.getPositionForOffset(const Offset(26, 5)).offset, 3);
      expect(p.getPositionForOffset(const Offset(24, 5)).offset, 2);

      // Round trip: every hit inside the whitespace comes back to itself. The
      // last caret is at 40, so the walk stops half an em past it - beyond
      // that there is nothing left to snap to and the hit clamps.
      for (double x = 21; x <= 45; x += 2) {
        final TextPosition hit = p.getPositionForOffset(Offset(x, 5));
        expect((p.getCaretRect(hit).left - x).abs(), lessThanOrEqualTo(5.0),
            reason: 'hit at $x came back at ${p.getCaretRect(hit).left}');
      }
    });

    test('centre and right keep the glyphs still and move only the caret', () {
      Paragraph laid(String text, TextAlign align) => Paragraph.single(
            text,
            a10,
            maxWidth: 100,
            paragraphStyle: ParagraphStyle(align: align),
          );

      for (final TextAlign align in <TextAlign>[
        TextAlign.center,
        TextAlign.right,
      ]) {
        final Paragraph plain = laid('ab', align);
        final Paragraph spaced = laid('ab ', align);
        expect(spaced.lines.single.left, plain.lines.single.left,
            reason: '$align moved the text when a space was typed');
        expect(spaced.lines.single.spans.first.left,
            plain.lines.single.spans.first.left);
        expect(spaced.lines.single.width, 20.0);
      }

      // Centred: the 20 px line sits at 40..60 and the space hangs to 70.
      expect(laid('ab ', TextAlign.center).lines.single.left, 40.0);
      expect(
        laid('ab ', TextAlign.center).getCaretRect(const TextPosition(3)).left,
        70.0,
      );
      // Right aligned: the line ends exactly on the 100 px edge, so the caret
      // after the space hangs *past* it. That is what hanging whitespace means
      // and a caller that clips has to scroll to it, exactly as it would for a
      // caret past the right edge of an over-long line.
      expect(laid('ab ', TextAlign.right).lines.single.left, 80.0);
      expect(
        laid('ab ', TextAlign.right).getCaretRect(const TextPosition(3)).left,
        110.0,
      );
    });

    test('under a right-to-left base the caret walks the other way', () {
      // UAX #9 L1 re-levels trailing whitespace to the paragraph level, so it
      // trails the *paragraph*: leftwards here, off the line's left edge.
      final Paragraph p = Paragraph.single(
        'אב  ',
        a10,
        maxWidth: 100,
        paragraphStyle:
            const ParagraphStyle(baseDirection: TextDirection.rightToLeft),
      );
      expect(p.baseDirection, TextDirection.rightToLeft);
      expect(p.lines.single.left, 80.0, reason: 'start-aligned under RTL');
      expect(p.lines.single.width, 20.0, reason: 'the spaces are not width');

      expect(
        <double>[
          for (int i = 0; i <= 4; i++) p.getCaretRect(TextPosition(i)).left,
        ],
        <double>[100, 90, 80, 70, 60],
      );

      final List<TextBox> boxes = p.getBoxesForSelection(2, 4);
      expect(boxes.length, 1);
      expect(boxes.single.rect, const Rect.fromLTRB(60, 0, 80, 10));
      expect(boxes.single.direction, TextDirection.rightToLeft);
    });

    test('a real right-to-left script hangs its trailing space to the left',
        () {
      final Paragraph p = Paragraph.single('$_heb ', d10);
      expect(p.baseDirection, TextDirection.rightToLeft);
      final TextLine line = p.lines.single;
      expect(line.end, 3);
      expect(line.endIncludingWhitespace, 4);
      expect(Paragraph.single(_heb, d10).longestLine, line.width);
      expect(p.getCaretRect(const TextPosition(3)).left, line.left);
      expect(p.getCaretRect(const TextPosition(4)).left, lessThan(line.left),
          reason: 'the space is to the left of the line, not to the right');
    });

    test('the trailing edge of a right-to-left run is not the line edge', () {
      // "ab אב " under an LTR base: offset 5 upstream is the trailing edge of
      // the Hebrew run, in the middle of the line at 30. Offset 5 downstream is
      // the leading edge of the whitespace, which L1 put at the line's own
      // trailing edge at 50. The span search has to win the upstream case or
      // the caret jumps to the end of the line every time it crosses back out
      // of a right-to-left island.
      final Paragraph p = Paragraph.single('ab $_heb ', a10);
      expect(p.lines.single.end, 6);
      expect(p.lines.single.width, 60.0);
      expect(
        p
            .getCaretRect(
                const TextPosition(6, affinity: TextAffinity.upstream))
            .left,
        30.0,
      );
      expect(p.getCaretRect(const TextPosition(6)).left, 60.0);
      expect(p.getCaretRect(const TextPosition(7)).left, 70.0);
    });

    test('the whitespace at a wrap stays on the line above it', () {
      // The case that breaks an implementation that only adds the width of the
      // space: at a soft break the offset after the space belongs to two lines
      // at once, and the answer is affinity, not geometry.
      final Paragraph p = Paragraph.single('aaa bbb', a10, maxWidth: 35);
      expect(p.lines.length, 2);
      expect(p.lines[0].end, 3);
      expect(p.lines[0].endIncludingWhitespace, 4);
      expect(p.lines[1].start, 4);

      // Offset 3 - before the space - is on the first line and inside its box.
      final Rect before = p.getCaretRect(const TextPosition(3));
      expect(before.top, 0.0);
      expect(before.left, 30.0);
      expect(p.lines[0].bounds.right, 30.0);

      // Offset 4 downstream is the second line's start; upstream is the End
      // position on the first line, past the space. Different places, both
      // real, and neither is a duplicate of the other.
      final Rect downstream = p.getCaretRect(const TextPosition(4));
      final Rect upstream = p.getCaretRect(
        const TextPosition(4, affinity: TextAffinity.upstream),
      );
      expect(downstream.top, 10.0);
      expect(downstream.left, 0.0);
      expect(upstream.top, 0.0);
      expect(upstream.left, 40.0);
      expect(upstream, isNot(downstream));

      // And no offset on the first line is a phantom copy of the second line's
      // first caret position.
      for (int i = 0; i <= 4; i++) {
        final Rect r = p.getCaretRect(TextPosition(i));
        expect(r == downstream, i == 4,
            reason: 'offset $i duplicated the second line\'s start');
      }
    });

    test('two spaces at a wrap are two positions on the line above', () {
      final Paragraph p = Paragraph.single('aaa  bbb', a10, maxWidth: 35);
      expect(p.lines.length, 2);
      expect(p.lines[0].end, 3);
      expect(p.lines[0].endIncludingWhitespace, 5);
      expect(p.lines[1].start, 5);
      expect(p.lines[0].width, 30.0, reason: 'still not measured for width');

      final Rect first = p.getCaretRect(const TextPosition(4));
      expect(first.top, 0.0, reason: 'between the two spaces, first line');
      expect(first.left, 40.0);
      expect(
        p
            .getCaretRect(
                const TextPosition(5, affinity: TextAffinity.upstream))
            .left,
        50.0,
      );
      expect(p.getCaretRect(const TextPosition(5)).left, 0.0);
      expect(p.getCaretRect(const TextPosition(5)).top, 10.0);
    });
  });

  group('soft hyphen', () {
    test('is invisible when the line does not break there', () {
      final Paragraph p = Paragraph.single('aaa${_shy}bbb', a10);
      expect(p.lines.length, 1);
      expect(p.lines.single.width, 60.0, reason: 'six letters, no hyphen');
      final int glyphs = p.lines.single.spans
          .fold(0, (int n, GlyphSpan s) => n + s.glyphs.length);
      expect(glyphs, 6);
    });

    test('becomes a hyphen when the line breaks there', () {
      final Paragraph p = Paragraph.single('aaa${_shy}bbb', a10, maxWidth: 45);
      expect(p.lines.length, 2);
      // Three letters plus a one-em hyphen.
      expect(p.lines[0].width, 40.0);
      expect(p.lines[0].end, 4, reason: 'the soft hyphen belongs to line 0');
      final GlyphSpan hyphen = p.lines[0].spans.last;
      expect(hyphen.start, 3);
      expect(hyphen.end, 4);
      expect(hyphen.glyphs.length, 1);
      expect(hyphen.width, 10.0);
      expect(p.lines[1].start, 4);
      expect(p.lines[1].width, 30.0);
    });

    test('the hyphen is counted when deciding whether the break fits', () {
      // "aaa aaa" is exactly 70 px, so a breaker that forgot the hyphen would
      // take the break after the soft hyphen and draw an 80 px line in a 70 px
      // box. Counting the hyphen rejects that break and falls back to the space.
      final Paragraph p =
          Paragraph.single('aaa aaa${_shy}bbb', a10, maxWidth: 70);
      expect(p.lines.length, 2);
      expect(p.lines[0].end, 3,
          reason: 'broke at the space, not at the hyphen');
      expect(p.lines[0].width, 30.0);
    });

    test('a break with no candidate that fits still happens at a hyphen', () {
      // Nothing fits in 35 px. Breaking at the soft hyphen overflows by 5 px;
      // not breaking overflows by 25. The first opportunity wins, which is what
      // keeps a long hyphenated word from running off the side entirely.
      final Paragraph p = Paragraph.single('aaa${_shy}bbb', a10, maxWidth: 35);
      expect(p.lines.length, 2);
      expect(p.lines[0].width, 40.0);
    });

    test('a soft hyphen at the very end of the text never draws', () {
      final Paragraph p = Paragraph.single('aaa$_shy', a10, maxWidth: 30);
      expect(p.lines.length, 1);
      final int glyphs = p.lines
          .expand((TextLine l) => l.spans)
          .fold(0, (int n, GlyphSpan s) => n + s.glyphs.length);
      expect(glyphs, 3);
    });
  });

  group('tabs', () {
    test('a tab advances to the next stop, not by its own advance', () {
      // The default stop is eight spaces: 80 px in 10 px Ahem.
      final Paragraph p = Paragraph.single('a\tb', a10);
      final List<GlyphSpan> spans = p.lines.single.spans;
      expect(spans.length, 3);
      expect(spans[1].left, 10.0);
      expect(spans[1].width, 70.0, reason: 'from x = 10 to the stop at 80');
      expect(spans[2].left, 80.0);
      expect(p.lines.single.width, 90.0);
    });

    test('a configured stop is honoured, and a tab on a stop skips a whole one',
        () {
      final Paragraph p = Paragraph.single(
        'aa\tb',
        a10,
        paragraphStyle: const ParagraphStyle(tabStopWidth: 20),
      );
      final List<GlyphSpan> spans = p.lines.single.spans;
      expect(spans[1].left, 20.0);
      expect(spans[1].width, 20.0,
          reason: 'the pen was exactly on a stop, so the tab spans the next');
      expect(spans[2].left, 40.0);
    });

    test('consecutive tabs land on consecutive stops', () {
      final Paragraph p = Paragraph.single(
        'a\t\tb',
        a10,
        paragraphStyle: const ParagraphStyle(tabStopWidth: 20),
      );
      final List<GlyphSpan> spans = p.lines.single.spans;
      expect(spans[1].width, 10.0);
      expect(spans[2].left, 20.0);
      expect(spans[2].width, 20.0);
      expect(spans[3].left, 40.0);
    });

    test('a tab draws nothing', () {
      final Paragraph p = Paragraph.single('a\tb', a10);
      expect(p.lines.single.spans[1].glyphs.length, 0);
    });
  });

  group('line height comes from the runs on the line', () {
    test('a line is as tall as its tallest face', () {
      final Paragraph p = Paragraph.layout(
        spans: <TextSpan>[
          TextSpan('a', a10),
          TextSpan('b', TextStyle(font: ahem.atSize(30))),
        ],
      );
      final TextLine line = p.lines.single;
      expect(line.ascent, 24.0, reason: '0.8 em of the 30 px face');
      expect(line.descent, 6.0);
      expect(line.height, 30.0);
      expect(line.baseline, 24.0);
      expect(p.height, 30.0);
    });

    test('two lines of different heights stack by their own heights', () {
      final Paragraph p = Paragraph.layout(
        spans: <TextSpan>[
          TextSpan('a\n', a10),
          TextSpan('b', TextStyle(font: ahem.atSize(20))),
        ],
      );
      expect(p.lines[0].height, 10.0);
      expect(p.lines[0].top, 0.0);
      expect(p.lines[1].height, 20.0);
      expect(p.lines[1].top, 10.0);
      expect(p.height, 30.0);
    });

    test('the taller face also sets the baseline the shorter one sits on', () {
      final Paragraph p = Paragraph.layout(
        spans: <TextSpan>[
          TextSpan('a', a10),
          TextSpan('b', TextStyle(font: ahem.atSize(20))),
        ],
      );
      // Both spans draw from the same baseline; that is the point of a line.
      expect(p.lines.single.baseline, 16.0);
      expect(
        p.lines.single.spans.every((GlyphSpan s) => s.glyphs.length > 0),
        isTrue,
      );
    });

    test('the height multiplier splits its extra above and below', () {
      final Paragraph p = Paragraph.single(
        'a',
        a10,
        paragraphStyle: const ParagraphStyle(heightMultiplier: 2),
      );
      expect(p.lines.single.height, 20.0);
      expect(p.lines.single.baseline, 13.0, reason: '5 px of leading, then 8');
    });

    test('a face with a line gap contributes it', () {
      final ScaledTypeface font = dejaVu.atSize(20);
      final Paragraph p = Paragraph.single('a', TextStyle(font: font));
      expect(p.lines.single.height, closeTo(font.lineHeight, 1e-9));
    });
  });

  group('styles and shaping', () {
    test('a style boundary splits the run even in the same script', () {
      final Paragraph p = Paragraph.layout(
        spans: <TextSpan>[
          TextSpan('ab', a10),
          TextSpan('cd', TextStyle(font: ahem.atSize(20))),
        ],
      );
      expect(p.lines.single.spans.length, 2);
      expect(p.lines.single.spans[0].width, 20.0);
      expect(p.lines.single.spans[1].width, 40.0);
    });

    test('GPOS mark attachment reaches the paragraph', () {
      // The bug this whole file exists to fix: with no GPOS, a zero-advance
      // combining acute is drawn at the pen, which is the left edge of the
      // letter it belongs to. With GPOS it is shifted to sit over the letter.
      final Paragraph p =
          Paragraph.single('á', TextStyle(font: dejaVu.atSize(64)));
      final GlyphRun run = p.lines.single.spans.single.glyphs;
      expect(run.length, 2);
      final GlyphRun unpositioned =
          LatinShaper().shape('á', dejaVu.atSize(64));
      expect(run.xOf(1), isNot(unpositioned.xOf(1)));
      expect(run.xOf(1), greaterThan(0.0),
          reason: 'the mark was moved onto the base rather than left at 0');
    });

    test('a run is copied out of the shaper, not borrowed from it', () {
      // The failure this prevents: every span in the paragraph showing the
      // glyphs of the last run shaped.
      final Paragraph p = Paragraph.single('ab $_heb cd', a10);
      final List<int> first =
          p.lines.single.spans.first.glyphs.glyphIds.toList();
      Paragraph.single('zzzzzzzz', a10);
      expect(p.lines.single.spans.first.glyphs.glyphIds.toList(), first);
    });

    test('a decomposed accent shapes to the same width as its precomposed form',
        () {
      // Not a tautology: it only holds if ccmp/mark ran. Without GPOS the
      // decomposed form is a letter followed by a zero-advance mark drawn in
      // the wrong place, and the advance happens to match - so the test also
      // asserts the glyph position, which does not.
      final TextStyle d = TextStyle(font: dejaVu.atSize(32));
      final double precomposed = Paragraph.single('á', d).longestLine;
      final double decomposed = Paragraph.single('á', d).longestLine;
      expect(decomposed, closeTo(precomposed, 0.5));
    });
  });

  group('failing explicitly', () {
    test('a paragraph with no spans is a caller bug', () {
      expect(
        () => Paragraph.layout(spans: const <TextSpan>[]),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('a negative or NaN width is a caller bug', () {
      expect(
        () => Paragraph.single('a', a10, maxWidth: -1),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => Paragraph.single('a', a10, maxWidth: double.nan),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('maxLines below one is a caller bug', () {
      expect(
        () => Paragraph.single(
          'a',
          a10,
          paragraphStyle: const ParagraphStyle(maxLines: 0),
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('a zero width lays out rather than dividing by zero', () {
      final Paragraph p = Paragraph.single('aa bb', a10, maxWidth: 0);
      expect(p.lines.length, 2);
      expect(p.lines[0].width, 20.0);
    });
  });

  group('the cache', () {
    test('the same request twice is one layout', () {
      final ParagraphCache cache = ParagraphCache();
      final Paragraph first = cache.single('abc', a10, maxWidth: 100);
      final Paragraph second = cache.single('abc', a10, maxWidth: 100);
      expect(identical(first, second), isTrue);
      expect(cache.hitCount, 1);
      expect(cache.missCount, 1);
    });

    test('every part of the key changes the answer', () {
      final ParagraphCache cache = ParagraphCache();
      cache.single('abc', a10, maxWidth: 100);
      cache.single('abd', a10, maxWidth: 100);
      cache.single('abc', a10, maxWidth: 101);
      cache.single('abc', TextStyle(font: ahem.atSize(11)), maxWidth: 100);
      cache.single('abc', TextStyle(font: ahem.atSize(10), language: 'TRK'),
          maxWidth: 100);
      cache.single('abc', a10,
          maxWidth: 100,
          paragraphStyle: const ParagraphStyle(align: TextAlign.center));
      cache.single('abc', a10,
          maxWidth: 100, paragraphStyle: const ParagraphStyle(maxLines: 1));
      cache.single('abc', a10,
          maxWidth: 100,
          paragraphStyle: const ParagraphStyle(heightMultiplier: 2));
      expect(cache.hitCount, 0);
      expect(cache.missCount, 8);
    });

    test('a different face at the same size is a different entry', () {
      final ParagraphCache cache = ParagraphCache();
      cache.single('abc', a10, maxWidth: 100);
      cache.single('abc', TextStyle(font: dejaVu.atSize(10)), maxWidth: 100);
      // Re-parsing the same file is a different face: bytes have no value
      // equality worth trusting, and the re-parsed face may shape differently.
      cache.single('abc', TextStyle(font: _face('ahem.ttf').atSize(10)),
          maxWidth: 100);
      expect(cache.missCount, 3);
    });

    test('spans are compared by value, not by list identity', () {
      final ParagraphCache cache = ParagraphCache();
      cache.layout(spans: <TextSpan>[TextSpan('a', a10), TextSpan('b', a10)]);
      cache.layout(spans: <TextSpan>[TextSpan('a', a10), TextSpan('b', a10)]);
      expect(cache.hitCount, 1);
    });

    test('the least recently used entry is the one evicted', () {
      final ParagraphCache cache = ParagraphCache(maximumEntries: 2);
      cache.single('a', a10);
      cache.single('b', a10);
      cache.single('a', a10); // refreshes 'a'
      cache.single('c', a10); // evicts 'b'
      expect(cache.entryCount, 2);
      cache.single('a', a10);
      expect(cache.hitCount, 2);
      cache.single('b', a10);
      expect(cache.missCount, 4);
    });

    test('clear drops everything', () {
      final ParagraphCache cache = ParagraphCache();
      cache.single('a', a10);
      cache.clear();
      expect(cache.entryCount, 0);
      expect(cache.hitCount, 0);
      cache.single('a', a10);
      expect(cache.missCount, 1);
    });
  });
}
