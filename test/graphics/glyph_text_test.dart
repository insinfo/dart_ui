/// The text side table: what it costs when it is off, and what it promises
/// when it is on.
///
/// Three properties are load-bearing and each has a test here that fails
/// loudly rather than a comment that asks to be believed:
///
///   * the op and float streams are **byte for byte identical** with capture
///     on and off. The whole design exists so that turning this on cannot
///     change a pixel, and a side table gives that by construction only for as
///     long as nobody adds an operand;
///   * capture off allocates **nothing** - not a table, not a view, not a
///     per-list object. `render_diagnostics_test.dart` holds the disabled
///     recorder to the same standard by driving ten thousand records through
///     it and asserting the snapshot is still the same `const` object; this
///     does the same and additionally asserts two different lists share it;
///   * a run split across several commands attributes each command **exactly**
///     the characters its own glyphs came from: a partition, nothing dropped
///     and nothing counted twice, in both directions and across a cluster that
///     straddles a split.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:dart_ui/src/geometry/offset.dart';
import 'package:dart_ui/src/graphics/display_list.dart';
import 'package:dart_ui/src/graphics/display_list_opcodes.dart';
import 'package:dart_ui/src/graphics/display_list_reader.dart';
import 'package:dart_ui/src/graphics/glyph_text.dart';
import 'package:dart_ui/src/rendering/text/text_painter.dart';
import 'package:dart_ui/src/text/shaper.dart';
import 'package:dart_ui/src/text/typeface.dart';
import 'package:test/test.dart';

Typeface _face(String name) =>
    Typeface.parse(File('test/fonts/$name').readAsBytesSync());

/// One recorded span, flattened so a test can compare whole lists at once.
typedef _Span = ({int at, String text});

List<_Span> _spansOf(DisplayList list) {
  final GlyphTextSpans spans = list.glyphTexts;
  return <_Span>[
    for (var i = 0; i < spans.spanCount; i++)
      (
        at: spans.spanStart(i),
        text: spans
            .spanText(i)
            .substring(spans.spanTextStart(i), spans.spanTextEnd(i)),
      ),
  ];
}

/// The word offset of every `drawGlyphRun` header in [list], in order.
List<int> _glyphRunOffsets(DisplayList list) {
  final List<int> offsets = <int>[];
  final DisplayListReader reader = DisplayListReader(list);
  while (reader.moveNext()) {
    if (reader.opcode == opDrawGlyphRun) offsets.add(reader.headerOffset);
  }
  return offsets;
}

/// A run whose clusters are exactly what the caller says, so the split rules
/// can be tested on shapes no font in the repository happens to produce.
///
/// The glyph ids and positions are filler: nothing here rasterises, and the
/// only thing under test is which characters each command claims.
GlyphRun _run(
  ScaledTypeface font,
  String text,
  Int32List clusters, {
  TextDirection direction = TextDirection.leftToRight,
}) {
  final int count = clusters.length;
  final Int32List ids = Int32List(count);
  final Float32List positions = Float32List(count * 2);
  for (var i = 0; i < count; i++) {
    ids[i] = 1 + (i % 64);
    positions[i * 2] = i * 8.0;
  }
  return GlyphRun(
    font: font,
    glyphIds: ids,
    positions: positions,
    clusters: clusters,
    length: count,
    width: count * 8.0,
    direction: direction,
    text: text,
    textStart: 0,
    textEnd: text.length,
  );
}

void main() {
  late Typeface roboto;
  late ScaledTypeface font;

  setUpAll(() {
    roboto = _face('Roboto-Regular.ttf');
    font = roboto.atSize(16);
  });

  group('capture off', () {
    test('allocates nothing and is shared between lists', () {
      final DisplayList a = DisplayList();
      final DisplayList b = DisplayList();
      expect(a.capturesGlyphText, isFalse);
      expect(identical(a.glyphTexts, GlyphTextSpans.empty), isTrue);
      expect(identical(a.glyphTexts, b.glyphTexts), isTrue);

      // The analogue of the diagnostics test: ten thousand records through the
      // disabled capture must leave the same const object behind.
      for (var i = 0; i < 10000; i++) {
        a.recordGlyphText('discarded', 0, 9);
      }
      expect(a.glyphTexts.spanCount, 0);
      expect(identical(a.glyphTexts, GlyphTextSpans.empty), isTrue);
      expect(a.bufferGrowths, 0);
    });

    test('reset and appendFrom do not turn it on', () {
      final DisplayList source = DisplayList()..capturesGlyphText = true;
      final TextPainter painter = TextPainter();
      painter.paint(
        source,
        'hello',
        font,
        const Offset(0, 20),
        source.addPaint(colorArgb: 0xFF000000),
      );
      expect(source.glyphTexts.spanCount, 1);

      final DisplayList sink = DisplayList()..appendFrom(source);
      expect(sink.capturesGlyphText, isFalse);
      expect(identical(sink.glyphTexts, GlyphTextSpans.empty), isTrue);

      source.reset();
      expect(source.capturesGlyphText, isTrue);
      expect(source.glyphTexts.spanCount, 0);
    });
  });

  group('the streams do not move', () {
    test('op and float words are identical with capture on and off', () {
      const String text = 'Selectable, findable, spoken: office affluent fi';
      final TextPainter painter = TextPainter();

      DisplayList build({required bool capture}) {
        final DisplayList list = DisplayList()..capturesGlyphText = capture;
        final int paint = list.addPaint(colorArgb: 0xFF102030);
        painter.paint(list, text, font, const Offset(3, 40), paint);
        painter.paintParagraph(
          list,
          painter.layout(text, font, maxWidth: 90),
          const Offset(4, 60),
          paint,
        );
        return list;
      }

      final DisplayList on = build(capture: true);
      final DisplayList off = build(capture: false);

      expect(on.opLength, off.opLength);
      expect(on.floatLength, off.floatLength);
      expect(on.commandCount, off.commandCount);
      for (var i = 0; i < off.opLength; i++) {
        expect(on.opBuffer[i], off.opBuffer[i], reason: 'op word $i');
      }
      for (var i = 0; i < off.floatLength; i++) {
        expect(on.floatBuffer[i], off.floatBuffer[i], reason: 'float slot $i');
      }
      expect(on.glyphTexts.spanCount, greaterThan(1));
      expect(off.glyphTexts.spanCount, 0);
    });
  });

  group('attribution', () {
    test('the ligature case, fixed at the source', () {
      // The case that motivated all of this. Roboto's GSUB turns `fi` into one
      // glyph, so a backend that recovers characters from the cmap gets back
      // U+FB01 - visually perfect, and Ctrl+F for "find" does not match it.
      // Here the string never left, so there is nothing to recover.
      final DisplayList list = DisplayList()..capturesGlyphText = true;
      final TextPainter painter = TextPainter();
      final GlyphRun run = painter.shapeRun('findable', font);
      expect(run.length, lessThan('findable'.length),
          reason: 'no ligature formed, so this asserts nothing');

      painter.emitRun(
        list,
        run,
        const Offset(0, 20),
        list.addPaint(colorArgb: 0xFF000000),
      );
      expect(_spansOf(list),
          <_Span>[(at: _glyphRunOffsets(list).single, text: 'findable')]);
      expect(_spansOf(list).single.text.contains('ﬁ'), isFalse);
    });

    test('spans land on the drawGlyphRun headers, not near them', () {
      final DisplayList list = DisplayList()..capturesGlyphText = true;
      final TextPainter painter = TextPainter();
      final int paint = list.addPaint(colorArgb: 0xFF000000);
      list.drawRect(0, 0, 10, 10, paint);
      painter.paint(list, 'one', font, const Offset(0, 20), paint);
      list.drawRect(0, 0, 10, 10, paint);
      painter.paint(list, 'two', font, const Offset(0, 40), paint);

      final List<int> headers = _glyphRunOffsets(list);
      expect(headers, hasLength(2));
      expect(_spansOf(list), <_Span>[
        (at: headers[0], text: 'one'),
        (at: headers[1], text: 'two'),
      ]);
    });

    test('a run split over three commands partitions its text', () {
      // 1100 glyphs at kMaxGlyphsPerRun = 510 is 510 + 510 + 80, and the
      // clusters are arranged so that one cluster - the one at the first split
      // - produced two glyphs, landing one on each side of it.
      const int glyphs = 1100;
      final Int32List clusters = Int32List(glyphs);
      for (var i = 0; i < glyphs; i++) {
        clusters[i] = i < kMaxGlyphsPerRun ? i : i - 1;
      }
      final String text = String.fromCharCodes(
        List<int>.generate(glyphs - 1, (int i) => 0x61 + i % 26),
      );

      final DisplayList list = DisplayList()..capturesGlyphText = true;
      TextPainter().emitRun(
        list,
        _run(font, text, clusters),
        const Offset(0, 20),
        list.addPaint(colorArgb: 0xFF000000),
      );

      final List<int> headers = _glyphRunOffsets(list);
      expect(headers, hasLength(3));
      final List<_Span> spans = _spansOf(list);
      expect(spans.map((_Span s) => s.at), headers);

      // A partition: concatenating the commands in order reproduces the text
      // exactly once. This is the assertion that fails if a straddling cluster
      // is claimed twice, which is the failure a paragraph would hide.
      expect(spans.map((_Span s) => s.text).join(), text);

      // And the straddle is where it was built: the cluster at 509 produced
      // glyph 509 in the first command and glyph 510 in the second, and it is
      // the first command - the one that drew its first glyph - that names it.
      expect(spans[0].text.length, kMaxGlyphsPerRun);
      expect(spans[0].text.endsWith(text[kMaxGlyphsPerRun - 1]), isTrue);
      expect(spans[1].text.startsWith(text[kMaxGlyphsPerRun]), isTrue);
    });

    test('a right-to-left run, where clusters descend, partitions too', () {
      const int glyphs = 1100;
      final Int32List clusters = Int32List(glyphs);
      // Visual order: the leftmost glyph carries the last character. The
      // straddle is built at the same split and therefore at a *higher*
      // cluster than everything after it, which is the case a neighbour test
      // in the wrong direction would get backwards.
      for (var i = 0; i < glyphs; i++) {
        clusters[i] = i < kMaxGlyphsPerRun ? glyphs - 2 - i : glyphs - 1 - i;
      }
      final String text = String.fromCharCodes(
        List<int>.generate(glyphs - 1, (int i) => 0x5D0 + i % 22),
      );

      final DisplayList list = DisplayList()..capturesGlyphText = true;
      TextPainter().emitRun(
        list,
        _run(font, text, clusters, direction: TextDirection.rightToLeft),
        const Offset(0, 20),
        list.addPaint(colorArgb: 0xFF000000),
      );

      final List<_Span> spans = _spansOf(list);
      expect(spans, hasLength(3));
      // Commands run left to right and the text runs right to left, so the
      // pieces reassemble in reverse command order - each piece itself in
      // logical order, which is what a DOM text node needs.
      expect(spans.reversed.map((_Span s) => s.text).join(), text);
    });

    test('a run with no text records nothing and is a legal input', () {
      final DisplayList list = DisplayList()..capturesGlyphText = true;
      final Int32List clusters = Int32List.fromList(<int>[0, 1, 2]);
      final GlyphRun run = GlyphRun(
        font: font,
        glyphIds: Int32List.fromList(<int>[10, 11, 12]),
        positions: Float32List(6),
        clusters: clusters,
        length: 3,
        width: 30,
      );
      expect(run.hasText, isFalse);
      TextPainter().emitRun(
        list,
        run,
        const Offset(0, 20),
        list.addPaint(colorArgb: 0xFF000000),
      );
      expect(_glyphRunOffsets(list), hasLength(1));
      expect(list.glyphTexts.spanCount, 0);
    });

    test('a paragraph names each line span with the paragraph text', () {
      final DisplayList list = DisplayList()..capturesGlyphText = true;
      final TextPainter painter = TextPainter();
      const String text = 'one two three four five six seven eight';
      painter.paintParagraph(
        list,
        painter.layout(text, font, maxWidth: 70),
        const Offset(0, 0),
        list.addPaint(colorArgb: 0xFF000000),
      );
      final List<_Span> spans = _spansOf(list);
      expect(spans.length, greaterThan(1));
      // Every piece is a slice of the source, in order, and together they are
      // the whole of it once the wrapped spaces are put back.
      expect(text.replaceAll(' ', ''),
          spans.map((_Span s) => s.text).join().replaceAll(' ', ''));
    });
  });

  group('splicing', () {
    test('spans follow the commands they name', () {
      final TextPainter painter = TextPainter();
      final DisplayList sub = DisplayList()..capturesGlyphText = true;
      painter.paint(
        sub,
        'spliced',
        font,
        const Offset(0, 20),
        sub.addPaint(colorArgb: 0xFF000000),
      );

      final DisplayList parent = DisplayList()..capturesGlyphText = true;
      final int paint = parent.addPaint(colorArgb: 0xFF000000);
      painter.paint(parent, 'before', font, const Offset(0, 20), paint);
      parent.appendFrom(sub);

      final List<int> headers = _glyphRunOffsets(parent);
      expect(headers, hasLength(2));
      expect(_spansOf(parent), <_Span>[
        (at: headers[0], text: 'before'),
        (at: headers[1], text: 'spliced'),
      ]);
    });
  });

  group('the recording table itself', () {
    test('a second record at the same offset overwrites the first', () {
      final DisplayList list = DisplayList()..capturesGlyphText = true;
      list
        ..recordGlyphText('never emitted', 0, 5)
        ..recordGlyphText('actual', 0, 6);
      final int paint = list.addPaint(colorArgb: 0xFF000000);
      list.drawGlyphRun(
        list.addFont(font),
        paint,
        0,
        0,
        Int32List.fromList(<int>[7]),
        Float32List(2),
        1,
      );
      expect(_spansOf(list), <_Span>[(at: 0, text: 'actual')]);
    });

    test('reset drops the strings but keeps the table', () {
      final DisplayList list = DisplayList()..capturesGlyphText = true;
      TextPainter().paint(
        list,
        'held',
        font,
        const Offset(0, 20),
        list.addPaint(colorArgb: 0xFF000000),
      );
      expect(list.glyphTexts.spanCount, 1);
      list.reset();
      expect(list.glyphTexts.spanCount, 0);
      expect(list.capturesGlyphText, isTrue);
      expect(() => list.glyphTexts.spanStart(0), throwsRangeError);
    });

    test('turning capture off drops the table and answers the const one', () {
      final DisplayList list = DisplayList()..capturesGlyphText = true;
      TextPainter().paint(
        list,
        'dropped',
        font,
        const Offset(0, 20),
        list.addPaint(colorArgb: 0xFF000000),
      );
      list.capturesGlyphText = false;
      expect(identical(list.glyphTexts, GlyphTextSpans.empty), isTrue);
    });
  });
}
