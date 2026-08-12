/// Shaping: glyph selection, advances and kerning.
///
/// DejaVu carries a legacy `kern` table and Roboto does not, so the pair is
/// what makes "kerning happened" and "kerning was correctly absent" both
/// testable. See `test/fonts/LICENSES.md`.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:dart_ui/src/text/cmap.dart';
import 'package:dart_ui/src/text/kern.dart';
import 'package:dart_ui/src/text/shaper.dart';
import 'package:dart_ui/src/text/typeface.dart';
import 'package:test/test.dart';

Typeface _face(String name) =>
    Typeface.parse(File('test/fonts/$name').readAsBytesSync());

void main() {
  late Typeface roboto;
  late Typeface dejaVu;
  late Typeface ahem;

  setUp(() {
    roboto = _face('Roboto-Regular.ttf');
    dejaVu = _face('DejaVuSans.ttf');
    ahem = _face('ahem.ttf');
  });

  group('glyph selection and positions', () {
    test('one glyph per character, laid out left to right', () {
      final GlyphRun run = LatinShaper().shape('Hello', roboto.atSize(16));

      expect(run.length, 5);
      expect(run.isEmpty, isFalse);
      for (int i = 1; i < run.length; i++) {
        expect(run.xOf(i), greaterThan(run.xOf(i - 1)));
        expect(run.yOf(i), 0);
      }
      expect(run.xOf(0), 0, reason: 'the first glyph sits at the origin');
    });

    test('positions are exact for a monospace face', () {
      // Ahem advances exactly one em, so every position is a multiple of the
      // size and the assertion needs no tolerance for design decisions.
      final GlyphRun run = LatinShaper().shape('XXXX', ahem.atSize(10));

      expect(run.length, 4);
      for (int i = 0; i < run.length; i++) {
        expect(run.xOf(i), closeTo(i * 10.0, 0.001));
      }
      expect(run.width, closeTo(40, 0.001));
    });

    test('the width is the sum of the advances', () {
      final ScaledTypeface font = roboto.atSize(20);
      final GlyphRun run = LatinShaper(applyKerning: false).shape('abc', font);

      expect(run.width, closeTo(font.measure('abc'), 1e-9));
    });

    test('an empty string shapes to an empty run', () {
      final GlyphRun run = LatinShaper().shape('', roboto.atSize(16));

      expect(run.isEmpty, isTrue);
      expect(run.length, 0);
      expect(run.width, 0);
    });

    test('an uncovered character becomes notdef rather than nothing', () {
      // Dropping it would silently shorten the text; notdef draws a box, which
      // is what tells a user their font lacks the script.
      final GlyphRun run = LatinShaper().shape('漢', roboto.atSize(16));

      expect(run.length, 1);
      expect(run.glyphIds[0], notdefGlyph);
    });

    test('Portuguese shapes to real glyphs, not to notdef', () {
      final GlyphRun run =
          LatinShaper().shape('Olá, coração!', roboto.atSize(16));

      expect(run.length, 13);
      for (int i = 0; i < run.length; i++) {
        expect(run.glyphIds[i], isNot(notdefGlyph),
            reason: 'glyph $i of "Olá, coração!" is missing');
      }
    });
  });

  group('clusters', () {
    test('each glyph records the string index it came from', () {
      final GlyphRun run = LatinShaper().shape('abc', roboto.atSize(16));

      expect(run.clusters[0], 0);
      expect(run.clusters[1], 1);
      expect(run.clusters[2], 2);
    });

    test('a supplementary-plane character advances the cluster by two', () {
      // It occupies two UTF-16 units, and the cluster index is into the
      // original string - a caret placed by cluster would land inside a
      // surrogate pair otherwise.
      final GlyphRun run =
          LatinShaper().shape('a\u{1F600}b', dejaVu.atSize(16));

      expect(run.length, 3);
      expect(run.clusters[0], 0);
      expect(run.clusters[1], 1);
      expect(run.clusters[2], 3, reason: 'the emoji used two UTF-16 units');
    });
  });

  group('kerning', () {
    test('DejaVu has a kern table and Roboto does not', () {
      // The premise the rest of this group rests on, asserted rather than
      // assumed - if a fixture is replaced, this fails first and explains why.
      expect(KernTable.parse(dejaVu.sfnt), isNotNull);
      expect(KernTable.parse(roboto.sfnt), isNull);
    });

    test('a kerned pair is narrower than the sum of its advances', () {
      final ScaledTypeface font = dejaVu.atSize(64);
      final KernTable kern = KernTable.parse(dejaVu.sfnt)!;
      final int a = dejaVu.glyphForCodePoint(0x41); // 'A'
      final int v = dejaVu.glyphForCodePoint(0x56); // 'V'

      final int adjustment = kern.between(a, v);
      expect(adjustment, lessThan(0), reason: '"AV" should pull together');

      final GlyphRun kerned = LatinShaper().shape('AV', font);
      final GlyphRun plain = LatinShaper(applyKerning: false).shape('AV', font);

      expect(kerned.width, lessThan(plain.width));
      // The shift must be exactly the table's value, scaled - not merely "some
      // shift", which a sign error would also satisfy.
      expect(
        plain.width - kerned.width,
        closeTo(-adjustment * font.scale, 1e-6),
      );
      expect(
          kerned.xOf(1), closeTo(plain.xOf(1) + adjustment * font.scale, 1e-6));
    });

    test('an unkerned pair is unaffected', () {
      final ScaledTypeface font = dejaVu.atSize(64);
      final GlyphRun kerned = LatinShaper().shape('II', font);
      final GlyphRun plain = LatinShaper(applyKerning: false).shape('II', font);

      expect(kerned.width, closeTo(plain.width, 1e-9));
    });

    test('kerning scales with the size', () {
      final GlyphRun small = LatinShaper().shape('AV', dejaVu.atSize(20));
      final GlyphRun large = LatinShaper().shape('AV', dejaVu.atSize(40));

      expect(large.width, closeTo(small.width * 2, 1e-6));
    });

    test('a font without kerning shapes identically either way', () {
      final ScaledTypeface font = roboto.atSize(32);

      expect(
        LatinShaper().shape('AVATAR', font).width,
        closeTo(
            LatinShaper(applyKerning: false).shape('AVATAR', font).width, 1e-9),
      );
    });

    test('an unknown pair returns no adjustment', () {
      final KernTable kern = KernTable.parse(dejaVu.sfnt)!;

      expect(kern.between(0, 0), 0);
      expect(kern.between(99999, 99999), 0);
      expect(kern.pairCount, greaterThan(100));
    });
  });

  group('buffer reuse', () {
    test('a shaper reuses its buffers across runs', () {
      final LatinShaper shaper = LatinShaper();
      final ScaledTypeface font = roboto.atSize(16);

      final GlyphRun first = shaper.shape('hello', font);
      final GlyphRun second = shaper.shape('world', font);

      // Same backing arrays: a run borrows the shaper's scratch, which is why
      // a caller that needs to keep one must copy it. Stating it in a test
      // makes the contract discoverable rather than a trap.
      expect(identical(first.glyphIds, second.glyphIds), isTrue);
    });

    test('a run longer than the buffer grows it', () {
      final LatinShaper shaper = LatinShaper();
      final ScaledTypeface font = ahem.atSize(8);
      final String long = 'X' * 500;

      final GlyphRun run = shaper.shape(long, font);

      expect(run.length, 500);
      expect(run.width, closeTo(4000, 0.01));
      expect(run.glyphIds.length, greaterThanOrEqualTo(500));
      expect(run.positions.length, greaterThanOrEqualTo(1000));
    });
  });

  test('the run arrays are exactly what the display list encoder takes', () {
    // drawGlyphRun takes an Int32List of ids and a Float32List of interleaved
    // offsets. Keeping the shaper's output in those types is what lets text
    // reach the encoder with no copy at the boundary.
    final GlyphRun run = LatinShaper().shape('test', roboto.atSize(16));

    expect(run.glyphIds, isA<Int32List>());
    expect(run.positions, isA<Float32List>());
    expect(run.positions.length, greaterThanOrEqualTo(run.length * 2));
  });
}
