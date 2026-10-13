/// Placeholders: boxes laid out inside a paragraph for a widget to fill.
///
/// Ahem at 10 px again - every advance 10, ascent 8, descent 2, no line gap -
/// so where a box lands and how tall its line becomes have one right answer
/// each, and the answers below are worked out by hand from
/// `PlaceholderDimensions.extentIn`.
library;

import 'dart:io';

import 'package:dart_ui/src/geometry/offset.dart';
import 'package:dart_ui/src/geometry/rect.dart';
import 'package:dart_ui/src/geometry/size.dart';
import 'package:dart_ui/src/text/paragraph.dart';
import 'package:dart_ui/src/text/shaper.dart';
import 'package:dart_ui/src/text/typeface.dart';
import 'package:test/test.dart';

Typeface _face(String name) =>
    Typeface.parse(File('test/fonts/$name').readAsBytesSync());

/// Three Hebrew letters: strong right-to-left.
const String _heb = 'אבג';

void main() {
  late TextStyle a10;
  late TextStyle d10;

  setUp(() {
    a10 = TextStyle(font: _face('ahem.ttf').atSize(10));
    d10 = TextStyle(font: _face('DejaVuSans.ttf').atSize(10));
  });

  TextSpan box(
    double width,
    double height, {
    PlaceholderAlignment alignment = PlaceholderAlignment.bottom,
    double? baselineOffset,
    TextStyle? style,
  }) =>
      TextSpan.placeholder(
        PlaceholderDimensions(
          size: Size(width, height),
          alignment: alignment,
          baselineOffset: baselineOffset,
        ),
        style ?? a10,
      );

  group('in the text', () {
    test('a placeholder is one U+FFFC, so offsets after it stay honest', () {
      final Paragraph p = Paragraph.layout(spans: <TextSpan>[
        TextSpan('ab', a10),
        box(20, 10),
        TextSpan('cd', a10),
      ]);
      expect(p.text, 'ab\uFFFCcd');
      expect(p.text.codeUnitAt(2), TextSpan.placeholderCodeUnit);
      // Its advance is its width, not a glyph's: 20 + 20 + 20.
      expect(p.longestLine, 60);
      expect(p.placeholderBoxes, hasLength(1));
      expect(
          p.placeholderBoxes.single.rect, const Rect.fromLTWH(20, 0, 20, 10));
      // The text after it moved over by the box.
      final GlyphSpan last = p.lines.single.spans.last;
      expect(p.text.substring(last.start, last.end), 'cd');
      expect(last.left, 40);
    });

    test('a U+FFFC typed as text is a character, not a placeholder', () {
      final Paragraph p = Paragraph.single('a\uFFFCb', a10);
      expect(p.placeholderBoxes, isEmpty);
      expect(
          p.lines.single.spans.any((GlyphSpan s) => s.isPlaceholder), isFalse);
    });

    test('is never drawn: its span has no glyphs and says what it is', () {
      final Paragraph p = Paragraph.layout(spans: <TextSpan>[
        TextSpan('a', a10),
        box(15, 10),
      ]);
      final GlyphSpan span =
          p.lines.single.spans.singleWhere((GlyphSpan s) => s.isPlaceholder);
      expect(span.glyphs.isEmpty, isTrue);
      expect(span.width, 15);
      expect(span.start, 1);
      expect(span.end, 2);
    });

    test('the caret steps over it in one move and a selection covers it', () {
      final Paragraph p = Paragraph.layout(spans: <TextSpan>[
        TextSpan('ab', a10),
        box(30, 10),
        TextSpan('c', a10),
      ]);
      expect(p.getCaretRect(const TextPosition(2)).left, 20);
      expect(p.getCaretRect(const TextPosition(3)).left, 50);
      final List<TextBox> selected = p.getBoxesForSelection(2, 3);
      expect(selected.single.rect.left, 20);
      expect(selected.single.rect.right, 50);
      // A click on its right half lands after it, on its left half before.
      expect(p.getPositionForOffset(const Offset(45, 5)).offset, 3);
      expect(p.getPositionForOffset(const Offset(25, 5)).offset, 2);
    });
  });

  group('line breaking', () {
    test('a placeholder that does not fit wraps to the next line whole', () {
      final Paragraph p = Paragraph.layout(
        spans: <TextSpan>[
          TextSpan('aaa ', a10),
          box(30, 10),
          TextSpan(' bb', a10),
        ],
        maxWidth: 60,
      );
      expect(p.lines, hasLength(2));
      expect(p.lines.first.end, 3);
      final Rect rect = p.placeholderBoxes.single.rect;
      expect(rect.left, 0);
      expect(rect.width, 30);
      expect(rect.top, p.lines[1].top);
    });

    test('it breaks on both sides, as UAX #14 LB20 says, even with no space',
        () {
      // "aaa" + box is 60 wide; at 50 the box goes down alone and the word
      // stays where it was rather than following it.
      final Paragraph p = Paragraph.layout(
        spans: <TextSpan>[
          TextSpan('aaa', a10),
          box(30, 10),
        ],
        maxWidth: 50,
      );
      expect(p.lines, hasLength(2));
      expect(p.lines.first.end, 3);
      expect(p.placeholderBoxes.single.rect.left, 0);
      expect(p.placeholderBoxes.single.rect.top, 10);
    });

    test('a box wider than the line overflows rather than being split', () {
      final Paragraph p = Paragraph.layout(
        spans: <TextSpan>[box(80, 10)],
        maxWidth: 50,
        style: const ParagraphStyle(breakWords: true),
      );
      expect(p.lines, hasLength(1));
      expect(p.placeholderBoxes.single.rect.width, 80);
    });

    test('maxLines drops the boxes it cuts off', () {
      final List<TextSpan> spans = <TextSpan>[
        box(20, 10),
        TextSpan(' aaa ', a10),
        box(20, 10),
      ];
      final Paragraph all = Paragraph.layout(spans: spans, maxWidth: 60);
      expect(all.lines, hasLength(2));
      expect(all.placeholderBoxes, hasLength(2));
      final Paragraph cut = Paragraph.layout(
        spans: spans,
        maxWidth: 60,
        style: const ParagraphStyle(maxLines: 1),
      );
      expect(cut.didExceedMaxLines, isTrue);
      expect(cut.placeholderBoxes, hasLength(1));
      expect(cut.placeholderBoxes.single.rect.left, 0);
    });
  });

  group('line height', () {
    test('a tall placeholder raises its line and moves the baseline down', () {
      final Paragraph p = Paragraph.layout(spans: <TextSpan>[
        TextSpan('a', a10),
        box(10, 40),
      ]);
      final TextLine line = p.lines.single;
      // Bottom-aligned: 38 above the baseline, the face's 2 below.
      expect(line.height, 40);
      expect(line.baseline, 38);
      expect(
          p.placeholderBoxes.single.rect, const Rect.fromLTWH(10, 0, 10, 40));
    });

    test('only the line it is on grows', () {
      final Paragraph p = Paragraph.layout(spans: <TextSpan>[
        TextSpan('a\n', a10),
        box(10, 30),
        TextSpan('\nb', a10),
      ]);
      expect(p.lines.map((TextLine l) => l.height), <double>[10, 30, 10]);
      expect(p.placeholderBoxes.single.rect.top, 10);
      expect(p.height, 50);
    });

    test('the line height multiplier spreads around a placeholder too', () {
      final Paragraph p = Paragraph.layout(
        spans: <TextSpan>[box(10, 20)],
        style: const ParagraphStyle(heightMultiplier: 1.5),
      );
      expect(p.lines.single.height, 30);
      expect(p.placeholderBoxes.single.rect.top, 5);
    });
  });

  group('alignment', () {
    ({TextLine line, Rect rect}) laid(
      double height,
      PlaceholderAlignment alignment, {
      double? baselineOffset,
    }) {
      final Paragraph p = Paragraph.layout(spans: <TextSpan>[
        TextSpan('a', a10),
        box(10, height, alignment: alignment, baselineOffset: baselineOffset),
      ]);
      return (line: p.lines.single, rect: p.placeholderBoxes.single.rect);
    }

    test('baseline: its own baseline on the line\'s', () {
      final ({TextLine line, Rect rect}) r =
          laid(20, PlaceholderAlignment.baseline, baselineOffset: 15);
      expect(r.line.baseline, 15);
      expect(r.rect.top, 0);
      expect(r.rect.top + 15, r.line.baseline);
      expect(r.line.height, 20);
    });

    test('baseline with no offset stands on the line, as a box with no text',
        () {
      final ({TextLine line, Rect rect}) r =
          laid(20, PlaceholderAlignment.baseline);
      expect(r.rect.bottom, r.line.baseline);
    });

    test('aboveBaseline: the bottom on the baseline', () {
      final ({TextLine line, Rect rect}) r =
          laid(20, PlaceholderAlignment.aboveBaseline);
      expect(r.rect.bottom, r.line.baseline);
      // 20 above, the face's 2 below.
      expect(r.line.height, 22);
    });

    test('belowBaseline: the top on the baseline', () {
      final ({TextLine line, Rect rect}) r =
          laid(20, PlaceholderAlignment.belowBaseline);
      expect(r.rect.top, r.line.baseline);
      expect(r.line.baseline, 8);
      expect(r.line.height, 28);
    });

    test('top: the top at the top of the text', () {
      final ({TextLine line, Rect rect}) r = laid(4, PlaceholderAlignment.top);
      expect(r.rect.top, r.line.baseline - 8);
      expect(r.line.height, 10);
    });

    test('bottom: the bottom at the bottom of the text', () {
      final ({TextLine line, Rect rect}) r =
          laid(4, PlaceholderAlignment.bottom);
      expect(r.rect.bottom, r.line.baseline + 2);
      expect(r.line.height, 10);
    });

    test('middle: centred on the text, and a tall one grows both ways', () {
      // Ahem's text runs from 8 above the baseline to 2 below: its centre
      // is 3 above the baseline.
      final ({TextLine line, Rect rect}) small =
          laid(4, PlaceholderAlignment.middle);
      expect(small.rect.center.dy, small.line.baseline - 3);
      expect(small.line.height, 10);

      final ({TextLine line, Rect rect}) tall =
          laid(30, PlaceholderAlignment.middle);
      expect(tall.rect.center.dy, tall.line.baseline - 3);
      expect(tall.line.height, 30);
    });

    test('the three differ for the same box', () {
      final double baseline = laid(4, PlaceholderAlignment.baseline).rect.top;
      final double middle = laid(4, PlaceholderAlignment.middle).rect.top;
      final double top = laid(4, PlaceholderAlignment.top).rect.top;
      expect(<double>{baseline, middle, top}, hasLength(3));
      expect(top, lessThan(middle));
      expect(middle, lessThan(baseline));
    });
  });

  group('bidi', () {
    test('a placeholder between right-to-left words sits between them visually',
        () {
      final Paragraph p = Paragraph.layout(spans: <TextSpan>[
        TextSpan(_heb, d10),
        box(20, 10, style: d10),
        TextSpan(_heb, d10),
      ]);
      expect(p.baseDirection, TextDirection.rightToLeft);
      final List<GlyphSpan> spans = p.lines.single.spans;
      // Visual order, left to right: the second word, the box, the first.
      expect(spans, hasLength(3));
      expect(spans[0].start, 4);
      expect(spans[1].isPlaceholder, isTrue);
      expect(spans[2].start, 0);
      final TextBox placed = p.placeholderBoxes.single;
      expect(placed.direction, TextDirection.rightToLeft);
      expect(placed.rect.left, closeTo(spans[0].right, 1e-9));
      expect(placed.rect.right, closeTo(spans[2].left, 1e-9));
    });

    test(
        'between two right-to-left words in left-to-right text it takes '
        'their direction (UAX #9 N1) and is reordered with them', () {
      final Paragraph p = Paragraph.layout(spans: <TextSpan>[
        TextSpan('ab $_heb', d10),
        box(20, 10, style: d10),
        TextSpan('$_heb cd', d10),
      ]);
      expect(p.baseDirection, TextDirection.leftToRight);
      final TextBox placed = p.placeholderBoxes.single;
      expect(placed.direction, TextDirection.rightToLeft);
      final List<GlyphSpan> spans = p.lines.single.spans;
      final GlyphSpan before =
          spans.singleWhere((GlyphSpan s) => s.start == 3); // first word
      final GlyphSpan after =
          spans.singleWhere((GlyphSpan s) => s.start == 7); // second word
      // Reversed with them: the second word left of the box, the first right.
      expect(after.right, closeTo(placed.rect.left, 1e-9));
      expect(before.left, closeTo(placed.rect.right, 1e-9));
    });
  });

  group('cache', () {
    test('keys on the box: same size hits, a new size lays out again', () {
      final ParagraphCache cache = ParagraphCache();
      cache.layout(spans: <TextSpan>[TextSpan('a', a10), box(10, 10)]);
      cache.layout(spans: <TextSpan>[TextSpan('a', a10), box(10, 10)]);
      expect(cache.hitCount, 1);
      final Paragraph wider =
          cache.layout(spans: <TextSpan>[TextSpan('a', a10), box(30, 10)]);
      expect(cache.missCount, 2);
      expect(wider.longestLine, 40);
    });
  });
}
