/// Letter and word spacing, asserted numerically.
///
/// Spacing is folded into the shaped runs' glyph positions, so everything the
/// paragraph derives from them - line widths, line breaks, carets, hit
/// testing, selection boxes - has to move with it. These tests check each of
/// those against the number it must come out as. Ahem at 10 px makes every
/// cluster exactly 10 wide, so "3 clusters plus 3 gaps of 2" is 36 and not
/// "about 36".
library;

import 'dart:io';

import 'package:dart_ui/src/geometry/offset.dart';
import 'package:dart_ui/src/text/paragraph.dart';
import 'package:dart_ui/src/text/shaper.dart';
import 'package:dart_ui/src/text/typeface.dart';
import 'package:test/test.dart';

Typeface _face(String name) =>
    Typeface.parse(File('test/fonts/$name').readAsBytesSync());

void main() {
  late Typeface ahem;
  late Typeface dejaVu;

  setUpAll(() {
    ahem = _face('ahem.ttf');
    dejaVu = _face('DejaVuSans.ttf');
  });

  TextStyle spaced(
    Typeface face, {
    double size = 10,
    double letter = 0,
    double word = 0,
  }) =>
      TextStyle(
        font: face.atSize(size),
        letterSpacing: letter,
        wordSpacing: word,
      );

  group('letter spacing', () {
    test('widens the line by the spacing once per cluster', () {
      final Paragraph p = Paragraph.single('abc', spaced(ahem, letter: 2));
      expect(p.longestLine, 36.0, reason: '3 x 10 plus 3 x 2');
      expect(p.lines.single.width, 36.0);
    });

    test('carets, hit testing and selection follow the drawn glyphs', () {
      final Paragraph p = Paragraph.single('abc', spaced(ahem, letter: 2));
      double caret(int offset) => p.getCaretRect(TextPosition(offset)).left;
      expect(caret(0), 0.0);
      expect(caret(1), 12.0, reason: 'after "a" and its gap');
      expect(caret(2), 24.0);
      expect(caret(3), 36.0);

      // Glyph k is drawn at 12 k: the painter and the caret agree.
      final GlyphRun glyphs = p.lines.single.spans.single.glyphs;
      expect(glyphs.xOf(1), 12.0);
      expect(glyphs.xOf(2), 24.0);

      expect(p.getPositionForOffset(const Offset(13, 5)).offset, 1);
      expect(p.getPositionForOffset(const Offset(19, 5)).offset, 2);
      final List<TextBox> boxes = p.getBoxesForSelection(1, 2);
      expect(boxes, hasLength(1));
      expect(boxes.single.rect.left, 12.0);
      expect(boxes.single.rect.right, 24.0);
    });

    test('line breaking measures with it', () {
      // 'aa aa' is 50 wide unspaced and fits a 50 px line; spaced by 2 it is
      // 60, so the second word has to wrap.
      expect(Paragraph.single('aa aa', spaced(ahem), maxWidth: 50).lines,
          hasLength(1));
      final Paragraph p =
          Paragraph.single('aa aa', spaced(ahem, letter: 2), maxWidth: 50);
      expect(p.lines, hasLength(2));
      expect(p.lines[1].start, 3);
      expect(p.lines.first.width, 24.0, reason: 'trailing space trimmed');
    });

    test('a mark stays on its base: the gap is per cluster', () {
      // x + COMBINING ACUTE is one cluster - and has no precomposed form, so
      // the mark is a glyph of its own: one gap, after the accent.
      const String text = 'x\u0301e';
      final Paragraph plain = Paragraph.single(text, spaced(dejaVu, size: 20));
      final Paragraph p =
          Paragraph.single(text, spaced(dejaVu, size: 20, letter: 4));
      expect(p.longestLine, closeTo(plain.longestLine + 8, 1e-6));

      final GlyphRun a = plain.lines.single.spans.single.glyphs;
      final GlyphRun b = p.lines.single.spans.single.glyphs;
      expect(b.length, 3, reason: 'base, mark and the next letter');
      expect(b.length, a.length);
      for (int k = 0; k < a.length; k++) {
        final int cluster = b.clusters[k];
        expect(b.xOf(k) - a.xOf(k), cluster < 2 ? 0.0 : closeTo(4, 1e-6),
            reason: 'glyph $k (cluster $cluster)');
      }
      // No caret inside the cluster moves away from its leading edge.
      expect(p.getCaretRect(const TextPosition(2)).left,
          closeTo(plain.getCaretRect(const TextPosition(2)).left + 4, 1e-6));
    });

    test('right-to-left: same width, edges still monotonic', () {
      const String hebrew = '\u05D0\u05D1\u05D2';
      final Paragraph plain = Paragraph.single(hebrew, spaced(dejaVu));
      final Paragraph p = Paragraph.single(hebrew, spaced(dejaVu, letter: 3));
      expect(p.longestLine, closeTo(plain.longestLine + 9, 1e-6));

      final GlyphSpan span = p.lines.single.spans.single;
      expect(span.direction, TextDirection.rightToLeft);
      expect(span.edgeOf(0), closeTo(span.right, 1e-9));
      expect(span.edgeOf(3), closeTo(span.left, 1e-9));
      expect(span.edgeOf(1), lessThan(span.edgeOf(0)));
      expect(span.edgeOf(2), lessThan(span.edgeOf(1)));
      // Every glyph sits inside its own caret interval, so a click on a
      // letter lands on one of that letter's two edges.
      for (int k = 0; k < span.glyphs.length; k++) {
        final int c = span.glyphs.clusters[k];
        final double x = span.left + span.glyphs.xOf(k);
        expect(x, greaterThanOrEqualTo(span.edgeOf(c + 1) - 1e-6));
        expect(x, lessThan(span.edgeOf(c)));
      }
    });

    test('negative spacing tightens', () {
      final Paragraph p = Paragraph.single('abcd', spaced(ahem, letter: -1));
      expect(p.longestLine, 36.0);
    });
  });

  group('word spacing', () {
    test('is added after each space only', () {
      final Paragraph p = Paragraph.single('a b c', spaced(ahem, word: 5));
      expect(p.longestLine, 60.0, reason: '5 x 10 plus 2 spaces x 5');
      expect(p.getCaretRect(const TextPosition(2)).left, 25.0);
    });

    test('adds to letter spacing', () {
      final Paragraph p =
          Paragraph.single('a b', spaced(ahem, letter: 1, word: 5));
      expect(p.longestLine, 30.0 + 3 + 5);
    });
  });

  test('the ellipsis is spaced like the text it replaces', () {
    final Paragraph plain = Paragraph.single(
      'aaaa aaaa aaaa',
      spaced(ahem),
      paragraphStyle: const ParagraphStyle(maxLines: 1, ellipsis: '..'),
      maxWidth: 70,
    );
    final Paragraph p = Paragraph.single(
      'aaaa aaaa aaaa',
      spaced(ahem, letter: 2),
      paragraphStyle: const ParagraphStyle(maxLines: 1, ellipsis: '..'),
      maxWidth: 70,
    );
    final GlyphSpan dots = p.lines.single.spans.last;
    expect(dots.isEllipsis, isTrue);
    expect(dots.width, plain.lines.single.spans.last.width + 4);
    expect(p.lines.single.width, lessThanOrEqualTo(70));
  });

  test('spacing is part of the cache key', () {
    final ParagraphCache cache = ParagraphCache();
    final Paragraph a = cache.single('abc', spaced(ahem));
    final Paragraph b = cache.single('abc', spaced(ahem, letter: 2));
    expect(identical(a, b), isFalse);
    expect(b.longestLine, 36.0);
  });
}
