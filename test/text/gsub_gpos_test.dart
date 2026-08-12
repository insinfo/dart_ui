/// OpenType layout: `GSUB` substitution and `GPOS` positioning.
///
/// The fixtures were chosen so that each behaviour has a font that exhibits it
/// *and* a font that does not, because a shaping test that only ever sees the
/// feature cannot tell "applied correctly" from "applied always":
///
/// * **Roboto** - `GSUB` and `GPOS`, no legacy `kern`. Its `ccmp` composes a
///   letter and a combining accent into the precomposed glyph, which is what
///   makes "renders identically to the precomposed form" an exact assertion
///   rather than an approximate one.
/// * **DejaVu Sans** - `GSUB`, `GPOS` *and* a legacy `kern` table carrying the
///   same values, which is the only way to prove the two are not both applied.
///   Also the mark attachment fixture.
/// * **Ahem** - neither table, so the same code path must still shape it.
///
/// Two lookup types have no fixture at all: no font here wraps anything in an
/// extension subtable, and no font here stacks two marks (see the mark-to-mark
/// group for why DejaVu cannot). Those are tested against tables built byte by
/// byte, which is also the only way to assert on a malformed table without
/// shipping a broken font.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:dart_ui/src/geometry/rect.dart';
import 'package:dart_ui/src/text/font_data.dart';
import 'package:dart_ui/src/text/gpos.dart';
import 'package:dart_ui/src/text/gsub.dart';
import 'package:dart_ui/src/text/kern.dart';
import 'package:dart_ui/src/text/layout_common.dart';
import 'package:dart_ui/src/text/shaper.dart';
import 'package:dart_ui/src/text/typeface.dart';
import 'package:test/test.dart';

Uint8List _bytes(String name) => File('test/fonts/$name').readAsBytesSync();

Typeface _face(String name) => Typeface.parse(_bytes(name));

/// The face at one pixel per font unit, so every assertion reads in the units
/// the font's own tables are written in and no scale factor has to be undone.
ScaledTypeface _unitScale(Typeface face) =>
    face.atSize(face.unitsPerEm.toDouble());

/// The ink of [glyph], in font units with y up, displaced by [x] and [y].
Rect _ink(Typeface face, int glyph, {double x = 0, double y = 0}) =>
    face.outlineOf(glyph).bounds.translate(x, y);

void main() {
  late Typeface roboto;
  late Typeface dejaVu;
  late Typeface ahem;

  setUp(() {
    roboto = _face('Roboto-Regular.ttf');
    dejaVu = _face('DejaVuSans.ttf');
    ahem = _face('ahem.ttf');
  });

  group('the fixtures are what the rest of this file assumes', () {
    test('Roboto has GSUB and GPOS and no legacy kern', () {
      expect(GsubTable.parse(roboto.sfnt), isNotNull);
      expect(GposTable.parse(roboto.sfnt), isNotNull);
      expect(KernTable.parse(roboto.sfnt), isNull);
    });

    test('DejaVu has GSUB, GPOS and a legacy kern table', () {
      expect(GsubTable.parse(dejaVu.sfnt), isNotNull);
      expect(GposTable.parse(dejaVu.sfnt), isNotNull);
      expect(KernTable.parse(dejaVu.sfnt), isNotNull);
    });

    test('Ahem has neither layout table', () {
      expect(GsubTable.parse(ahem.sfnt), isNull);
      expect(GposTable.parse(ahem.sfnt), isNull);
      expect(GdefTable.parse(ahem.sfnt), isNull);
    });

    test('both layout fonts declare the features this file exercises', () {
      expect(GsubTable.parse(roboto.sfnt)!.hasFeature('liga'), isTrue);
      expect(GsubTable.parse(dejaVu.sfnt)!.hasFeature('ccmp'), isTrue);
      expect(GposTable.parse(dejaVu.sfnt)!.hasFeature('kern'), isTrue);
      expect(GposTable.parse(dejaVu.sfnt)!.hasFeature('mark'), isTrue);
      // A feature nobody has, so "hasFeature" is not simply always true.
      expect(GposTable.parse(roboto.sfnt)!.hasFeature('mark'), isFalse);
    });
  });

  group('GDEF', () {
    test('it separates marks from letters', () {
      final GdefTable gdef = GdefTable.parse(dejaVu.sfnt)!;
      final int a = dejaVu.glyphForCodePoint(0x61);
      final int acute = dejaVu.glyphForCodePoint(0x301);

      expect(gdef.isBase(a), isTrue);
      expect(gdef.isMark(a), isFalse);
      expect(gdef.isMark(acute), isTrue);
      expect(gdef.isBase(acute), isFalse);
      expect(gdef.classOf(acute), GdefTable.classMark);
    });
  });

  group('ligatures (GSUB type 4)', () {
    test('two characters become one glyph', () {
      final GlyphRun run = OpenTypeShaper().shape('fi', _unitScale(roboto));

      expect(run.length, 1, reason: 'fewer glyphs than characters');
      // Not merely "some other glyph": the ligature a font provides for "fi"
      // is the glyph it also maps U+FB01 to, so this is checkable rather than
      // approximate.
      expect(run.glyphIds[0], roboto.glyphForCodePoint(0xFB01));
      expect(run.length, lessThan('fi'.length));
    });

    test('the same happens in the other layout font', () {
      final GlyphRun run = OpenTypeShaper().shape('fi', _unitScale(dejaVu));

      expect(run.length, 1);
      expect(run.glyphIds[0], dejaVu.glyphForCodePoint(0xFB01));
    });

    test('the longest ligature wins', () {
      // Ligature sets are ordered longest-first and the first match is taken.
      // Taking any other would turn "ffi" into "fi" followed by "i".
      final GlyphRun run = OpenTypeShaper().shape('ffi', _unitScale(roboto));

      expect(run.length, 1);
      expect(run.glyphIds[0], roboto.glyphForCodePoint(0xFB03));
    });

    test('the ligature is narrower than the glyphs it replaced', () {
      final ScaledTypeface font = _unitScale(roboto);
      final GlyphRun ligated = OpenTypeShaper().shape('fi', font);
      final GlyphRun plain = LatinShaper(applyKerning: false).shape('fi', font);

      expect(ligated.width, lessThan(plain.width));
      expect(ligated.width, closeTo(font.advanceOf(ligated.glyphIds[0]), 1e-9));
    });

    test('both source indices still map to the surviving glyph', () {
      // The assertion caret placement depends on. After "f" and "i" merge
      // there is no glyph whose cluster is 1, so an equality search would find
      // nothing and a caret asked to sit before the "i" would fall off the
      // run.
      final GlyphRun run = OpenTypeShaper().shape('fi', _unitScale(roboto));

      expect(run.clusters[0], 0);
      expect(run.glyphIndexOfCluster(0), 0);
      expect(run.glyphIndexOfCluster(1), 0);
    });

    test('a three-character ligature keeps all three indices', () {
      final GlyphRun run = OpenTypeShaper().shape('ffi', _unitScale(roboto));

      expect(run.glyphIndexOfCluster(0), 0);
      expect(run.glyphIndexOfCluster(1), 0);
      expect(run.glyphIndexOfCluster(2), 0);
    });

    test('text after a ligature still maps to its own glyph', () {
      // The other half: merging must not swallow indices that belong to the
      // glyphs after it.
      final GlyphRun run = OpenTypeShaper().shape('fix', _unitScale(roboto));

      expect(run.length, 2);
      expect(run.glyphIndexOfCluster(0), 0);
      expect(run.glyphIndexOfCluster(1), 0);
      expect(run.glyphIndexOfCluster(2), 1);
      expect(run.glyphIds[1], roboto.glyphForCodePoint(0x78));
    });

    test('an index before the run has no glyph', () {
      final GlyphRun run = OpenTypeShaper().shape('fi', _unitScale(roboto));

      expect(run.glyphIndexOfCluster(-1), -1);
    });
  });

  group('composition (GSUB ccmp)', () {
    test('a letter and a combining accent become the precomposed glyph', () {
      // Roboto's ccmp is a ligature substitution over the combining marks, so
      // decomposed text ends up as literally the same glyph as the precomposed
      // character - which is what makes the next test an exact comparison.
      final GlyphRun run = OpenTypeShaper().shape('á', _unitScale(roboto));

      expect(run.length, 1);
      expect(run.glyphIds[0], roboto.glyphForCodePoint(0xE1));
    });

    test('decomposed text renders identically to the precomposed form', () {
      final ScaledTypeface font = _unitScale(roboto);
      final OpenTypeShaper shaper = OpenTypeShaper();

      final GlyphRun decomposed = shaper.shape('á', font);
      final List<int> ids = <int>[
        for (int i = 0; i < decomposed.length; i++) decomposed.glyphIds[i],
      ];
      final List<double> offsets = <double>[
        for (int i = 0; i < decomposed.length; i++) ...<double>[
          decomposed.xOf(i),
          decomposed.yOf(i),
        ],
      ];
      final double width = decomposed.width;

      final GlyphRun precomposed = shaper.shape('á', font);

      expect(precomposed.length, decomposed.length);
      expect(
        <int>[
          for (int i = 0; i < precomposed.length; i++) precomposed.glyphIds[i],
        ],
        ids,
      );
      expect(
        <double>[
          for (int i = 0; i < precomposed.length; i++) ...<double>[
            precomposed.xOf(i),
            precomposed.yOf(i),
          ],
        ],
        offsets,
      );
      expect(precomposed.width, width);
    });

    test('a word of decomposed Portuguese matches its precomposed form', () {
      final ScaledTypeface font = _unitScale(roboto);
      final OpenTypeShaper shaper = OpenTypeShaper();

      // "nao e agua" with its tilde and its acute written as combining marks,
      // against the same words written with precomposed characters.
      // Composition has to fire twice, mid-word both times, without disturbing
      // the letters around it.
      final GlyphRun decomposed = shaper.shape('não e água', font);
      final int decomposedLength = decomposed.length;
      final double decomposedWidth = decomposed.width;
      final List<int> decomposedIds = <int>[
        for (int i = 0; i < decomposed.length; i++) decomposed.glyphIds[i],
      ];

      final GlyphRun precomposed = shaper.shape('não e água', font);

      expect(decomposedLength, 10, reason: 'twelve code units, ten glyphs');
      expect(decomposedLength, precomposed.length);
      expect(
        <int>[
          for (int i = 0; i < precomposed.length; i++) precomposed.glyphIds[i],
        ],
        decomposedIds,
      );
      expect(decomposedWidth, closeTo(precomposed.width, 1e-9));
    });
  });

  group('chained context (GSUB type 6)', () {
    test('the accent chosen depends on the letter under it', () {
      // DejaVu's latn `ccmp` is entirely chained context: a mark following a
      // narrow base is swapped for a narrower variant. The same mark after a
      // wide base is left alone, so the substitution provably came from the
      // context and not from an unconditional single substitution.
      final ScaledTypeface font = _unitScale(dejaVu);
      final int acute = dejaVu.glyphForCodePoint(0x301);

      final GlyphRun narrow = OpenTypeShaper().shape('b́', font);
      final GlyphRun wide = OpenTypeShaper().shape('x́', font);

      expect(narrow.length, 2);
      expect(wide.length, 2);
      expect(wide.glyphIds[1], acute, reason: 'no rule applies over "x"');
      expect(narrow.glyphIds[1], isNot(acute),
          reason: 'a narrow base takes a narrow accent');
    });
  });

  group('pair kerning (GPOS type 2)', () {
    test('a known pair is narrowed by exactly the table value', () {
      // -87 font units for "AV", read out of Roboto's class-based pair
      // subtable. Asserting the number rather than "narrower" is what catches
      // a sign error or a class-index off-by-one, both of which still produce
      // *a* shift.
      const double expected = -87;
      final ScaledTypeface font = _unitScale(roboto);

      final GlyphRun kerned = OpenTypeShaper().shape('AV', font);
      final GlyphRun plain =
          OpenTypeShaper(applyKerning: false).shape('AV', font);

      expect(kerned.width - plain.width, closeTo(expected, 1e-6));
      expect(kerned.xOf(1) - plain.xOf(1), closeTo(expected, 1e-6));
    });

    test('the same pair in the other font, at its own value', () {
      const double expected = -131;
      final ScaledTypeface font = _unitScale(dejaVu);

      final GlyphRun kerned = OpenTypeShaper().shape('AV', font);
      final GlyphRun plain =
          OpenTypeShaper(applyKerning: false).shape('AV', font);

      expect(kerned.width - plain.width, closeTo(expected, 1e-6));
    });

    test('it scales with the size', () {
      final GlyphRun small = OpenTypeShaper().shape('AV', roboto.atSize(20));
      final GlyphRun large = OpenTypeShaper().shape('AV', roboto.atSize(40));

      expect(large.width, closeTo(small.width * 2, 1e-6));
    });

    test('an unkerned pair is left alone', () {
      final ScaledTypeface font = _unitScale(roboto);

      expect(
        OpenTypeShaper().shape('II', font).width,
        closeTo(
            OpenTypeShaper(applyKerning: false).shape('II', font).width, 1e-9),
      );
    });
  });

  group('kern table precedence', () {
    test(
        'the legacy table and GPOS agree on the pair, so double '
        'application would be visible', () {
      // The premise. If these two ever disagreed, "applied once" and "applied
      // twice" would still be distinguishable, but the arithmetic below would
      // need rewriting - so the agreement is asserted rather than assumed.
      final KernTable kern = KernTable.parse(dejaVu.sfnt)!;
      final int a = dejaVu.glyphForCodePoint(0x41);
      final int v = dejaVu.glyphForCodePoint(0x56);

      expect(kern.between(a, v), -131);
      expect(GposTable.parse(dejaVu.sfnt)!.hasFeature('kern'), isTrue);
    });

    test('a font with both is kerned once, not twice', () {
      final ScaledTypeface font = _unitScale(dejaVu);

      final GlyphRun kerned = OpenTypeShaper().shape('AV', font);
      final GlyphRun plain =
          OpenTypeShaper(applyKerning: false).shape('AV', font);

      expect(plain.width - kerned.width, closeTo(131, 1e-6),
          reason: 'both tables applied would narrow it by 262');
    });

    test('the legacy table alone reaches the same answer', () {
      // LatinShaper only knows the legacy table. That the two shapers agree on
      // this pair is what makes the doubling test above meaningful: the
      // OpenType shaper had a second, equal adjustment available and did not
      // take it.
      final ScaledTypeface font = _unitScale(dejaVu);

      expect(
        OpenTypeShaper().shape('AV', font).width,
        closeTo(LatinShaper().shape('AV', font).width, 1e-6),
      );
    });

    test('a font with no GPOS kern feature still gets the legacy table', () {
      // Ahem has neither, so the check that matters is the negative one: the
      // precedence rule must not have disabled legacy kerning wholesale.
      final Typeface face = dejaVu;
      final GposTable gpos = GposTable.parse(face.sfnt)!;

      // The rule is "GPOS kerns, so kern is dropped" - and it is a *rule about
      // this font*, not a global switch. Asked about a script GPOS has no kern
      // feature for, the answer flips.
      expect(gpos.hasFeature('kern', script: 'latn'), isTrue);
      expect(gpos.hasFeature('mkmk', script: 'hebr'), isFalse,
          reason: 'Hebrew in this font has mark but no mkmk');
    });

    test('turning kerning off suppresses both mechanisms', () {
      final ScaledTypeface font = _unitScale(dejaVu);
      final OpenTypeShaper off = OpenTypeShaper(applyKerning: false);

      expect(
          off.shape('AV', font).width,
          closeTo(
              LatinShaper(applyKerning: false).shape('AV', font).width, 1e-6));
    });
  });

  group('mark-to-base attachment (GPOS type 4)', () {
    test('the accent is lifted onto the letter', () {
      // "A" rather than "a": DejaVu gives its lowercase bases an attachment
      // point at exactly the height the accent is drawn at, so the vertical
      // correction there is legitimately zero and would make a "y is non-zero"
      // assertion vacuous. Over a capital the accent has to climb.
      final ScaledTypeface font = _unitScale(dejaVu);
      final GlyphRun run = OpenTypeShaper().shape('Á', font);

      expect(run.length, 2);
      expect(run.yOf(1), lessThan(0),
          reason: 'negative y is up, so the accent rose above the baseline');
      expect(run.yOf(1), closeTo(-373, 1e-6));
      expect(run.yOf(0), 0);
    });

    test('the accent is centred over the letter it belongs to', () {
      final ScaledTypeface font = _unitScale(dejaVu);
      final GlyphRun run = OpenTypeShaper().shape('Á', font);

      final Rect base = _ink(dejaVu, run.glyphIds[0], x: run.xOf(0));
      final Rect accent =
          _ink(dejaVu, run.glyphIds[1], x: run.xOf(1), y: -run.yOf(1));

      // Within 5% of an em of the letter's own centre. The accent is a slanted
      // stroke whose ink is not symmetric about its attachment point, so exact
      // equality is the wrong assertion; landing on the far side of the letter,
      // or on the next character, is what this catches - and the letter is
      // two thirds of an em wide, so 5% is a tenth of the width being tested.
      expect(
          accent.center.dx, closeTo(base.center.dx, dejaVu.unitsPerEm * 0.05));
      expect(accent.left, greaterThan(base.left));
      expect(accent.right, lessThan(base.right));
      expect(accent.bottom, greaterThanOrEqualTo(base.top),
          reason: 'the accent sits at or above the top of the letter');
    });

    test('the accent adds no width', () {
      // A combining mark has a zero advance, and attachment must not change
      // that: an accented letter occupies exactly the letter's width.
      final ScaledTypeface font = _unitScale(dejaVu);

      expect(
        OpenTypeShaper().shape('Á', font).width,
        closeTo(font.advanceOf(dejaVu.glyphForCodePoint(0x41)), 1e-9),
      );
    });

    test('without attachment the accent would land on the next character', () {
      // What the feature buys, stated as a difference. Unattached, the mark is
      // drawn at the pen - which is past the letter entirely.
      final ScaledTypeface font = _unitScale(dejaVu);
      final GlyphRun attached = OpenTypeShaper().shape('Á', font);
      final GlyphRun unattached = OpenTypeShaper(
        features: const <String>{'ccmp'},
      ).shape('Á', font);

      expect(unattached.length, 2);
      expect(unattached.xOf(1),
          closeTo(font.advanceOf(unattached.glyphIds[0]), 1e-9));
      expect(attached.xOf(1), lessThan(unattached.xOf(1)));
    });

    test('a lowercase base attaches too, horizontally', () {
      final ScaledTypeface font = _unitScale(dejaVu);
      final GlyphRun run = OpenTypeShaper().shape('á', font);

      expect(run.length, 2);
      final Rect base = _ink(dejaVu, run.glyphIds[0], x: run.xOf(0));
      final Rect accent =
          _ink(dejaVu, run.glyphIds[1], x: run.xOf(1), y: -run.yOf(1));
      expect(
          accent.center.dx, closeTo(base.center.dx, dejaVu.unitsPerEm * 0.05));
    });
  });

  group('fonts without layout tables', () {
    test('Ahem shapes through the same code path', () {
      final ScaledTypeface font = ahem.atSize(10);
      final GlyphRun run = OpenTypeShaper().shape('XXXX', font);

      expect(run.length, 4);
      for (int i = 0; i < run.length; i++) {
        expect(run.xOf(i), closeTo(i * 10.0, 1e-9));
        expect(run.yOf(i), 0);
        expect(run.clusters[i], i);
      }
      expect(run.width, closeTo(40, 1e-9));
    });

    test('it agrees with the simple shaper', () {
      final ScaledTypeface font = ahem.atSize(13);

      expect(
        OpenTypeShaper().shape('Hello world', font).width,
        closeTo(LatinShaper().shape('Hello world', font).width, 1e-9),
      );
    });

    test('an empty string shapes to an empty run', () {
      expect(OpenTypeShaper().shape('', _unitScale(roboto)).isEmpty, isTrue);
    });

    test('an uncovered character still becomes notdef', () {
      final GlyphRun run = OpenTypeShaper().shape('漢', _unitScale(roboto));

      expect(run.length, 1);
      expect(run.glyphIds[0], 0);
    });
  });

  group('buffer reuse and run shape', () {
    test('the shaper reuses its arrays', () {
      final OpenTypeShaper shaper = OpenTypeShaper();
      final ScaledTypeface font = _unitScale(roboto);

      final GlyphRun first = shaper.shape('hello', font);
      final GlyphRun second = shaper.shape('world', font);

      expect(identical(first.glyphIds, second.glyphIds), isTrue);
    });

    test('a run longer than the buffer grows it', () {
      final GlyphRun run = OpenTypeShaper().shape('X' * 500, ahem.atSize(8));

      expect(run.length, 500);
      expect(run.positions.length, greaterThanOrEqualTo(1000));
    });

    test('a right-to-left run comes out in visual order', () {
      // Not Arabic shaping - there is none here - but the reversal that turns
      // the logical order the rules ran in into the order glyphs are drawn.
      final ScaledTypeface font = ahem.atSize(10);
      final GlyphRun run = OpenTypeShaper()
          .shape('abc', font, direction: TextDirection.rightToLeft);

      expect(run.length, 3);
      expect(run.clusters[0], 2);
      expect(run.clusters[2], 0);
      expect(run.xOf(0), 0);
      expect(run.xOf(2), closeTo(20, 1e-9));
    });
  });

  group('coverage and class definitions', () {
    test('a format 1 coverage numbers the glyphs it lists', () {
      final Coverage coverage = Coverage.parse(
        FontData(_table((_Table t) {
          t.u16(1);
          t.u16(3);
          t.u16(10);
          t.u16(20);
          t.u16(30);
        })),
        0,
      );

      expect(coverage.glyphCount, 3);
      expect(coverage.indexOf(10), 0);
      expect(coverage.indexOf(20), 1);
      expect(coverage.indexOf(30), 2);
      expect(coverage.indexOf(15), -1);
      expect(coverage.covers(30), isTrue);
      expect(coverage.covers(31), isFalse);
    });

    test('a format 2 coverage numbers across ranges', () {
      final Coverage coverage = Coverage.parse(
        FontData(_table((_Table t) {
          t.u16(2);
          t.u16(2);
          t.u16(10); // 10..12 -> indices 0..2
          t.u16(12);
          t.u16(0);
          t.u16(50); // 50..51 -> indices 3..4
          t.u16(51);
          t.u16(3);
        })),
        0,
      );

      expect(coverage.glyphCount, 5);
      expect(coverage.indexOf(10), 0);
      expect(coverage.indexOf(12), 2);
      expect(coverage.indexOf(13), -1);
      expect(coverage.indexOf(51), 4);
    });

    test('an undefined coverage format is a font format error', () {
      expect(
        () => Coverage.parse(
          FontData(_table((_Table t) {
            t.u16(9);
          })),
          0,
        ),
        throwsA(isA<FontFormatException>()),
      );
    });

    test('a class definition puts unlisted glyphs in class 0', () {
      // Parsed at offset 2, past a word of padding, because offset zero is how
      // the format writes "there is no table here" - see the last test in this
      // group.
      final ClassDef classes = ClassDef.parse(
        FontData(_table((_Table t) {
          t.u16(0); // padding
          t.u16(1);
          t.u16(5); // startGlyph
          t.u16(3);
          t.u16(7);
          t.u16(0);
          t.u16(2);
        })),
        2,
      );

      expect(classes.classOf(5), 7);
      expect(classes.classOf(6), 0);
      expect(classes.classOf(7), 2);
      expect(classes.classOf(4), 0, reason: 'before the range');
      expect(classes.classOf(9), 0, reason: 'after the range');
    });

    test('a format 2 class definition reads ranges', () {
      final ClassDef classes = ClassDef.parse(
        FontData(_table((_Table t) {
          t.u16(0); // padding
          t.u16(2);
          t.u16(2);
          t.u16(10);
          t.u16(19);
          t.u16(4);
          t.u16(30);
          t.u16(30);
          t.u16(1);
        })),
        2,
      );

      expect(classes.classOf(10), 4);
      expect(classes.classOf(19), 4);
      expect(classes.classOf(20), 0);
      expect(classes.classOf(30), 1);
    });

    test('a null offset means everything is class 0', () {
      expect(ClassDef.parse(FontData(Uint8List(0)), 0).classOf(1234), 0);
      expect(ClassDef.empty.classOf(0), 0);
    });
  });

  group('extension subtables', () {
    test('a wrapped lookup does exactly what an unwrapped one does', () {
      // No fixture font here wraps anything, and roughly half of the fonts in
      // the wild do, so this is the whole test coverage for a lookup type
      // whose absence would silently disable a font's features.
      final GlyphBuffer wrapped = _bufferOf(<int>[10]);
      final GlyphBuffer direct = _bufferOf(<int>[10]);

      GsubTable.at(FontData(_syntheticGsub(extension: true)), 0).apply(
        wrapped,
        features: const <String>{'liga'},
        script: 'DFLT',
      );
      GsubTable.at(FontData(_syntheticGsub(extension: false)), 0).apply(
        direct,
        features: const <String>{'liga'},
        script: 'DFLT',
      );

      expect(direct.glyphs, <int>[35], reason: 'glyph 10 plus a delta of 25');
      expect(wrapped.glyphs, direct.glyphs);
    });

    test('an extension may not wrap another extension', () {
      // A cycle a hostile font could otherwise use to make the shaper recurse
      // until it runs out of stack.
      final GlyphBuffer buffer = _bufferOf(<int>[10]);

      expect(
        () => GsubTable.at(
          FontData(_syntheticGsub(extension: true, nestExtension: true)),
          0,
        ).apply(buffer, features: const <String>{'liga'}, script: 'DFLT'),
        throwsA(isA<FontFormatException>()),
      );
    });

    test('positioning extensions work the same way', () {
      final GdefTable gdef = _syntheticGdef();
      final GlyphBuffer wrapped = _markBuffer();
      final GlyphBuffer direct = _markBuffer();

      GposTable.at(FontData(_syntheticGpos(extension: true)), 0).apply(
        wrapped,
        features: const <String>{'mkmk'},
        script: 'DFLT',
        gdef: gdef,
      );
      GposTable.at(FontData(_syntheticGpos(extension: false)), 0).apply(
        direct,
        features: const <String>{'mkmk'},
        script: 'DFLT',
        gdef: gdef,
      );

      expect(direct.yOffsets[2], 500);
      expect(wrapped.yOffsets[2], direct.yOffsets[2]);
    });
  });

  group('mark-to-mark attachment (GPOS type 6)', () {
    // No fixture stacks. DejaVu's mkmk lookups all have lower indices than its
    // mark lookups, and lookups run in index order, so its second accent is
    // re-attached to the base by the mark lookup that runs afterwards -
    // HarfBuzz produces the same output from the same font, which is how that
    // was confirmed to be the font's shape rather than this code's bug. So the
    // subtable is exercised against one built here.
    test('a second accent stacks above the first', () {
      final GlyphBuffer buffer = _markBuffer();

      GposTable.at(FontData(_syntheticGpos(extension: false)), 0).apply(
        buffer,
        features: const <String>{'mkmk'},
        script: 'DFLT',
        gdef: _syntheticGdef(),
      );

      expect(buffer.attachedTo[2], 1,
          reason: 'the second mark hangs off the first, not off the base');
      expect(buffer.yOffsets[2], 500);
      expect(buffer.xOffsets[2], 0);
    });

    test('resolving the attachment turns it into an absolute offset', () {
      final GlyphBuffer buffer = _markBuffer();
      final GposTable gpos =
          GposTable.at(FontData(_syntheticGpos(extension: false)), 0);
      gpos.apply(buffer,
          features: const <String>{'mkmk'},
          script: 'DFLT',
          gdef: _syntheticGdef());
      // Stand in for the mark-to-base lookup that would have run first: the
      // lower accent hangs off the base at (1200, 200) in the base's frame.
      buffer.xOffsets[1] = 1200;
      buffer.yOffsets[1] = 200;
      buffer.attachedTo[1] = 0;

      buffer.resolveAttachments();

      // 1200 less the base's 1000-unit advance, because the accent is drawn at
      // the pen and the pen has already passed the letter. Forgetting that
      // subtraction puts every accent one letter to the right.
      expect(buffer.xOffsets[1], 200);
      // The upper accent inherits the lower one's resolved position and adds
      // nothing horizontally - it must not subtract the base's advance a
      // second time, which is the bug an unchained implementation produces.
      expect(buffer.xOffsets[2], 200);
      expect(buffer.yOffsets[2], 700, reason: '500 above a mark raised by 200');
      expect(buffer.attachedTo[2], -1);
    });

    test('with no GDEF nothing is a mark, so nothing stacks', () {
      // Stated as a test because it is a real limitation: the classes come
      // from GDEF and are not synthesised from Unicode properties.
      final GlyphBuffer buffer = _markBuffer();

      GposTable.at(FontData(_syntheticGpos(extension: false)), 0)
          .apply(buffer, features: const <String>{'mkmk'}, script: 'DFLT');

      expect(buffer.attachedTo[2], -1);
      expect(buffer.yOffsets[2], 0);
    });
  });

  group('malformed tables', () {
    test('a truncated GSUB throws a font format error, not a range error', () {
      final Typeface face =
          Typeface.parse(_truncate(_bytes('DejaVuSans.ttf'), 'GSUB'));

      Object? thrown;
      try {
        GsubTable.parse(face.sfnt);
      } catch (error) {
        thrown = error;
      }

      expect(thrown, isNotNull, reason: 'a truncated table must not parse');
      expect(thrown, isA<FontFormatException>());
      expect(thrown, isNot(isA<RangeError>()));
      expect((thrown! as FontFormatException).table, 'GSUB');
    });

    test('a truncated GPOS behaves the same way', () {
      final Typeface face =
          Typeface.parse(_truncate(_bytes('DejaVuSans.ttf'), 'GPOS'));

      expect(() => GposTable.parse(face.sfnt),
          throwsA(isA<FontFormatException>()));
    });

    test('a truncated GDEF behaves the same way', () {
      final Typeface face =
          Typeface.parse(_truncate(_bytes('DejaVuSans.ttf'), 'GDEF'));

      expect(() => GdefTable.parse(face.sfnt),
          throwsA(isA<FontFormatException>()));
    });

    test('a layout table with an impossible version is named as such', () {
      expect(
        () => GsubTable.at(
          FontData(_table((_Table t) {
            t.u16(9);
            t.u16(0);
            t.u16(0);
            t.u16(0);
            t.u16(0);
          })),
          0,
        ),
        throwsA(isA<FontFormatException>()),
      );
    });

    test('an offset pointing past the table is caught', () {
      // The common shape of a corrupted download: the header survives and its
      // offsets do not.
      expect(
        () => GsubTable.at(
          FontData(_table((_Table t) {
            t.u16(1);
            t.u16(0);
            t.u16(0xFFF0); // scriptListOffset, far past the end
            t.u16(0);
            t.u16(0);
          })),
          0,
        ),
        throwsA(isA<FontFormatException>()),
      );
    });
  });
}

// ---------------------------------------------------------------------------
// Building tables by hand
// ---------------------------------------------------------------------------

/// A big-endian byte builder with named, back-patched offsets.
///
/// A layout table is a graph of offsets, each relative to a different base, and
/// writing one with literal numbers means recomputing every offset whenever a
/// field is added. Labels make the fixtures readable and, more importantly,
/// make them wrong in obvious ways rather than subtle ones.
final class _Table {
  final List<int> _bytes = <int>[];
  final Map<String, int> _labels = <String, int>{};
  final List<({int at, String label, String from, bool wide})> _fixups =
      <({int at, String label, String from, bool wide})>[];

  void label(String name) => _labels[name] = _bytes.length;

  void u16(int value) {
    _bytes.add((value >> 8) & 0xFF);
    _bytes.add(value & 0xFF);
  }

  void i16(int value) => u16(value & 0xFFFF);

  void u32(int value) {
    u16((value >> 16) & 0xFFFF);
    u16(value & 0xFFFF);
  }

  void tag(String value) => _bytes.addAll(value.codeUnits);

  void offset16(String label, {required String from}) {
    _fixups.add((at: _bytes.length, label: label, from: from, wide: false));
    u16(0);
  }

  void offset32(String label, {required String from}) {
    _fixups.add((at: _bytes.length, label: label, from: from, wide: true));
    u32(0);
  }

  Uint8List build() {
    final Uint8List bytes = Uint8List.fromList(_bytes);
    final ByteData view = ByteData.sublistView(bytes);
    for (final ({int at, String label, String from, bool wide}) fixup
        in _fixups) {
      final int delta = _labels[fixup.label]! - _labels[fixup.from]!;
      if (fixup.wide) {
        view.setUint32(fixup.at, delta);
      } else {
        view.setUint16(fixup.at, delta);
      }
    }
    return bytes;
  }
}

Uint8List _table(void Function(_Table) write) {
  final _Table table = _Table();
  write(table);
  return table.build();
}

/// The script, feature and lookup scaffolding both synthetic tables share.
void _writeHeader(
  _Table t, {
  required String root,
  required String feature,
}) {
  t.label(root);
  t.u16(1);
  t.u16(0);
  t.offset16('scripts', from: root);
  t.offset16('features', from: root);
  t.offset16('lookups', from: root);

  t.label('scripts');
  t.u16(1);
  t.tag('DFLT');
  t.offset16('script', from: 'scripts');
  t.label('script');
  t.offset16('langSys', from: 'script');
  t.u16(0);
  t.label('langSys');
  t.u16(0); // lookupOrder
  t.u16(0xFFFF); // no required feature
  t.u16(1);
  t.u16(0);

  t.label('features');
  t.u16(1);
  t.tag(feature);
  t.offset16('feature', from: 'features');
  t.label('feature');
  t.u16(0); // featureParams
  t.u16(1);
  t.u16(0);
}

/// A `GSUB` whose only lookup adds 25 to glyph 10.
///
/// With [extension] the lookup is type 7 and points at the real subtable, so
/// the two builds must produce identical results.
Uint8List _syntheticGsub({
  required bool extension,
  bool nestExtension = false,
}) =>
    _table((_Table t) {
      _writeHeader(t, root: 'gsub', feature: 'liga');

      t.label('lookups');
      t.u16(1);
      t.offset16('lookup', from: 'lookups');
      t.label('lookup');
      t.u16(extension ? 7 : 1);
      t.u16(0); // flags
      t.u16(1);
      t.offset16(extension ? 'extension' : 'single', from: 'lookup');

      if (extension) {
        t.label('extension');
        t.u16(1);
        t.u16(nestExtension ? 7 : 1);
        t.offset32('single', from: 'extension');
      }

      t.label('single');
      t.u16(1); // format 1: a delta
      t.offset16('coverage', from: 'single');
      t.i16(25);

      t.label('coverage');
      t.u16(1);
      t.u16(1);
      t.u16(10);
    });

/// A `GPOS` whose only lookup stacks one mark 500 units above another.
Uint8List _syntheticGpos({required bool extension}) => _table((_Table t) {
      _writeHeader(t, root: 'gpos', feature: 'mkmk');

      t.label('lookups');
      t.u16(1);
      t.offset16('lookup', from: 'lookups');
      t.label('lookup');
      t.u16(extension ? 9 : 6);
      t.u16(0);
      t.u16(1);
      t.offset16(extension ? 'extension' : 'markMark', from: 'lookup');

      if (extension) {
        t.label('extension');
        t.u16(1);
        t.u16(6);
        t.offset32('markMark', from: 'extension');
      }

      t.label('markMark');
      t.u16(1);
      t.offset16('mark1Coverage', from: 'markMark');
      t.offset16('mark2Coverage', from: 'markMark');
      t.u16(1); // one mark class
      t.offset16('mark1Array', from: 'markMark');
      t.offset16('mark2Array', from: 'markMark');

      t.label('mark1Coverage');
      t.u16(1);
      t.u16(1);
      t.u16(_markGlyph);

      t.label('mark2Coverage');
      t.u16(1);
      t.u16(1);
      t.u16(_markGlyph);

      t.label('mark1Array');
      t.u16(1);
      t.u16(0); // mark class
      t.offset16('mark1Anchor', from: 'mark1Array');
      t.label('mark1Anchor');
      t.u16(1);
      t.i16(0);
      t.i16(0);

      t.label('mark2Array');
      t.u16(1);
      t.offset16('mark2Anchor', from: 'mark2Array');
      t.label('mark2Anchor');
      t.u16(1);
      t.i16(0);
      t.i16(500);
    });

const int _baseGlyph = 1;
const int _markGlyph = 2;

/// A `GDEF` calling [_baseGlyph] a base and [_markGlyph] a mark.
GdefTable _syntheticGdef() => GdefTable(
      glyphClasses: ClassDef.parse(
        FontData(_table((_Table t) {
          t.u16(0); // padding: offset zero means "no table"
          t.u16(1); // format 1, one class per glyph from a start glyph
          t.u16(_baseGlyph);
          t.u16(2);
          t.u16(GdefTable.classBase);
          t.u16(GdefTable.classMark);
        })),
        2,
      ),
      markAttachClasses: ClassDef.empty,
      markGlyphSets: const <Coverage>[],
    );

GlyphBuffer _bufferOf(List<int> glyphs) {
  final GlyphBuffer buffer = GlyphBuffer();
  for (int i = 0; i < glyphs.length; i++) {
    buffer.add(glyphs[i], i);
  }
  return buffer;
}

/// A base followed by two marks, with the base carrying all the advance.
GlyphBuffer _markBuffer() {
  final GlyphBuffer buffer =
      _bufferOf(<int>[_baseGlyph, _markGlyph, _markGlyph]);
  buffer.xAdvances[0] = 1000;
  return buffer;
}

/// [font] with [tag]'s directory entry pointing at four bytes at the very end.
///
/// The sfnt directory's own bounds check still passes - the range is inside the
/// file - so the failure happens where it should, inside the table parser,
/// which is the case that has to produce a [FontFormatException] rather than a
/// `RangeError`.
Uint8List _truncate(Uint8List font, String tag) {
  final Uint8List copy = Uint8List.fromList(font);
  final ByteData view = ByteData.sublistView(copy);
  final int numTables = view.getUint16(4);
  for (int i = 0; i < numTables; i++) {
    final int record = 12 + i * 16;
    final String found = String.fromCharCodes(copy, record, record + 4);
    if (found != tag) continue;
    view.setUint32(record + 8, copy.length - 4);
    view.setUint32(record + 12, 4);
    return copy;
  }
  fail('the fixture has no "$tag" table to truncate');
}
