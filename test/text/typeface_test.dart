/// The OpenType parser, against real fonts.
///
/// Three fixtures, chosen so the branches that differ between fonts are all
/// exercised: Roboto has a **short** `loca`, DejaVu a **long** one plus a
/// `kern` table and 6000 glyphs, and Ahem has exact integer metrics and no
/// `GSUB`/`GPOS` at all. See `test/fonts/LICENSES.md`.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:dart_ui/src/geometry/path.dart';
import 'package:dart_ui/src/text/cmap.dart';
import 'package:dart_ui/src/text/font_data.dart';
import 'package:dart_ui/src/text/font_tables.dart';
import 'package:dart_ui/src/text/sfnt.dart';
import 'package:dart_ui/src/text/typeface.dart';
import 'package:test/test.dart';

Uint8List _fontBytes(String name) => File('test/fonts/$name').readAsBytesSync();

Typeface _roboto() => Typeface.parse(_fontBytes('Roboto-Regular.ttf'));

Typeface _dejaVu() => Typeface.parse(_fontBytes('DejaVuSans.ttf'));

Typeface _ahem() => Typeface.parse(_fontBytes('ahem.ttf'));

void main() {
  group('sfnt directory', () {
    test('a real font parses and reports its tables', () {
      final SfntFile file = SfntFile.parse(
        FontData(_fontBytes('Roboto-Regular.ttf')),
      );

      expect(file.flavour, SfntFlavour.trueType);
      expect(file.faceCount, 1);
      expect(
        file.tableTags,
        containsAll(
            <String>['head', 'hhea', 'hmtx', 'maxp', 'cmap', 'loca', 'glyf']),
      );
      final TableRecord head = file.requireTable('head');
      expect(head.length, greaterThan(0));
      expect(head.offset + head.length, lessThanOrEqualTo(file.data.length));
    });

    test('a missing table is named rather than dereferenced', () {
      final SfntFile file = SfntFile.parse(FontData(_fontBytes('ahem.ttf')));

      expect(file.hasTable('GSUB'), isFalse);
      expect(file.tableRecord('GSUB'), isNull);
      expect(
        () => file.requireTable('GSUB'),
        throwsA(isA<FontFormatException>().having(
            (FontFormatException e) => e.message, 'message', contains('GSUB'))),
      );
    });

    test('something that is not a font is refused by name', () {
      final Uint8List notAFont = Uint8List.fromList(
        List<int>.generate(512, (int i) => i & 0xFF),
      );

      expect(
        () => SfntFile.parse(FontData(notAFont)),
        throwsA(isA<FontFormatException>().having(
          (FontFormatException e) => e.message,
          'message',
          contains('not an sfnt font'),
        )),
      );
    });
  });

  group('reader bounds', () {
    test('reading past the end throws a typed error, never a RangeError', () {
      final FontData data = FontData(Uint8List(8));
      final FontReader reader = data.readerAt(4, table: 'test');

      expect(reader.readUint32(), 0);
      expect(() => reader.readUint8(), throwsA(isA<FontFormatException>()));
      expect(
        () => data.readerAt(9),
        throwsA(isA<FontFormatException>()),
      );
    });

    test('a truncated font fails to parse instead of hanging or crashing', () {
      // The corruption test section 30.8 asks for: a font file is untrusted
      // input, and every truncation must produce a diagnosis rather than a
      // RangeError from deep inside a table parser.
      final Uint8List full = _fontBytes('ahem.ttf');
      for (final int keep in <int>[4, 12, 40, 200, 2000, 20000]) {
        final Uint8List truncated = Uint8List.sublistView(full, 0, keep);
        expect(
          () => Typeface.parse(truncated),
          throwsA(isA<FontFormatException>()),
          reason: 'truncated to $keep bytes',
        );
      }
    });

    test('flipping bytes never produces an untyped failure', () {
      final Uint8List original = _fontBytes('ahem.ttf');
      for (int offset = 0; offset < 2048; offset += 37) {
        final Uint8List corrupted = Uint8List.fromList(original)
          ..[offset] ^= 0xFF;
        try {
          final Typeface face = Typeface.parse(corrupted);
          // Parsing may legitimately succeed; then drawing must also be safe.
          for (int gid = 0; gid < 8 && gid < face.glyphCount; gid++) {
            face.outlineOf(gid);
          }
        } on FontFormatException {
          // The expected outcome for a corrupt font.
        }
      }
    });
  });

  group('metrics', () {
    test('head and maxp report what the font actually says', () {
      final Typeface roboto = _roboto();
      expect(roboto.unitsPerEm, 2048);
      expect(roboto.head.indexToLocFormat, 0, reason: 'Roboto uses short loca');
      expect(roboto.glyphCount, 1294);

      final Typeface dejaVu = _dejaVu();
      expect(dejaVu.unitsPerEm, 2048);
      expect(dejaVu.head.indexToLocFormat, 1, reason: 'DejaVu uses long loca');
      expect(dejaVu.glyphCount, 6253);

      final Typeface ahem = _ahem();
      expect(ahem.unitsPerEm, 1000);
    });

    test('vertical metrics are signed the way the format defines', () {
      final Typeface roboto = _roboto();

      expect(roboto.hhea.ascender, greaterThan(0));
      expect(roboto.hhea.descender, lessThan(0),
          reason: 'descender points down from the baseline, and y is up');

      // ScaledTypeface flips the descent so callers add rather than subtract.
      final ScaledTypeface scaled = roboto.atSize(16);
      expect(scaled.ascent, greaterThan(0));
      expect(scaled.descent, greaterThan(0));
      expect(scaled.lineHeight, greaterThan(scaled.ascent));
    });

    test('the line box comes from the resolved metrics, not from hhea alone',
        () {
      // Roboto states its line box twice and the two disagree: `hhea` says
      // 1900 / -500 / 0 and `OS/2` says sTypo 1536 / -512 / 102. The rule in
      // VerticalMetrics.resolve picks `hhea` here because Roboto's fsSelection
      // is 0x40 - REGULAR set, USE_TYPO_METRICS (bit 7) **clear** - so the font
      // never asked for its typographic metrics to be used. Reading the typo
      // triple anyway would silently shorten every paragraph in the framework
      // by (1900+500-1536-512-102)/2048 = 12.7% and disagree with every other
      // text stack on the machine.
      final Typeface roboto = _roboto();

      expect(roboto.hhea.ascender, 1900);
      expect(roboto.hhea.descender, -500);
      expect(roboto.os2!.typoAscender, 1536);
      expect(roboto.os2!.useTypographicMetrics, isFalse);
      expect(roboto.verticalMetrics.source,
          VerticalMetricsSource.horizontalHeader);

      // 2048 units per em, so 16 px scales by 16/2048 = 0.0078125 exactly and
      // the arithmetic below is exact in binary floating point.
      final ScaledTypeface scaled = roboto.atSize(16);
      expect(scaled.ascent, 1900 * 16 / 2048);
      expect(scaled.descent, 500 * 16 / 2048);
      expect(scaled.lineGap, 0);
      expect(scaled.lineHeight, closeTo(18.75, 1e-12));
      expect(scaled.metricsSource, VerticalMetricsSource.horizontalHeader);
    });

    test('a font that sets USE_TYPO_METRICS gets the shorter line it asked for',
        () {
      // The other half of the policy, which no fixture in test/fonts exercises:
      // all three of them leave bit 7 clear. Gabriola and Cascadia set it, so
      // the assertion is that the *typographic* triple is what a scaled face
      // reports - the font stating "my sTypo values are the line box" and being
      // believed.
      Typeface? typographic;
      for (final String path in <String>[
        'C:/Windows/Fonts/Gabriola.ttf',
        'C:/Windows/Fonts/CascadiaCode.ttf',
        'C:/Windows/Fonts/Rubik.ttf',
      ]) {
        final File file = File(path);
        if (!file.existsSync()) continue;
        final Typeface face = Typeface.parse(file.readAsBytesSync());
        if (face.os2?.useTypographicMetrics ?? false) {
          typographic = face;
          break;
        }
      }
      if (typographic == null) {
        markTestSkipped('no font setting USE_TYPO_METRICS on this machine');
        return;
      }

      final Os2Table os2 = typographic.os2!;
      expect(typographic.verticalMetrics.source,
          VerticalMetricsSource.typographic);
      expect(typographic.verticalMetrics.ascent, os2.typoAscender);
      expect(typographic.verticalMetrics.descent, os2.typoDescender);
      expect(typographic.verticalMetrics.lineGap, os2.typoLineGap);

      final double scale = 16 / typographic.unitsPerEm;
      final ScaledTypeface scaled = typographic.atSize(16);
      expect(scaled.ascent, os2.typoAscender * scale);
      expect(scaled.descent, -os2.typoDescender * scale);
      expect(scaled.metricsSource, VerticalMetricsSource.typographic);

      // Worth recording, because it is not what one expects: every font on the
      // machine this was written on that sets bit 7 also makes `hhea` repeat
      // the typographic triple, which is precisely what a font *should* do once
      // it has nominated one line box. So the numbers alone cannot tell the two
      // branches apart, and the assertion that carries weight is which field
      // was read - [VerticalMetricsSource] - not what it contained. The fonts
      // where the triples diverge are the badly behaved ones, and those are the
      // ones that make the rule worth having.
    });

    test('Ahem has the exact metrics its design promises', () {
      // Every Ahem glyph is a solid em box: one em advance, ascent 0.8 em,
      // descent 0.2 em. That is what makes it worth having as a fixture -
      // the assertions can be exact rather than approximate.
      final ScaledTypeface ahem = _ahem().atSize(100);
      final int glyph = ahem.typeface.glyphForCodePoint(0x58); // 'X'

      expect(ahem.advanceOf(glyph), closeTo(100, 0.001));
      expect(ahem.ascent, closeTo(80, 0.001));
      expect(ahem.descent, closeTo(20, 0.001));
    });

    test('the hmtx tail gives late glyphs the last full advance', () {
      final Typeface face = _dejaVu();
      final int pairs = face.hhea.numberOfHMetrics;

      // Every glyph past the pairs must answer with the last advance rather
      // than zero. A monospace font ships one pair and thousands of glyphs, so
      // getting this wrong collapses every glyph but the first.
      if (pairs < face.glyphCount) {
        final double lastPairAdvance = face.advanceOf(pairs - 1);
        expect(face.advanceOf(pairs), lastPairAdvance);
        expect(face.advanceOf(face.glyphCount - 1), lastPairAdvance);
      }
      expect(face.advanceOf(-1), 0);
      expect(face.advanceOf(face.glyphCount + 100), 0);
    });
  });

  group('cmap', () {
    test('ASCII maps to real glyphs', () {
      final Typeface face = _roboto();

      for (final String character in <String>['A', 'z', '0', ' ', '.', ',']) {
        expect(
          face.glyphForCodePoint(character.codeUnitAt(0)),
          isNot(notdefGlyph),
          reason: 'no glyph for "$character"',
        );
      }
    });

    test('Portuguese accents map to real glyphs', () {
      final Typeface face = _roboto();

      // The reason this test exists: a parser that mishandles format 4's
      // idRangeOffset usually still gets ASCII right and fails here.
      for (final String character in <String>[
        'á',
        'é',
        'í',
        'ó',
        'ú',
        'â',
        'ê',
        'ô',
        'ã',
        'õ',
        'ç',
        'Á',
        'À',
        'Ç'
      ]) {
        expect(
          face.glyphForCodePoint(character.runes.first),
          isNot(notdefGlyph),
          reason: 'no glyph for "$character"',
        );
      }
      expect(face.covers('Olá, mundo — ação, coração, você'), isTrue,
          reason: 'Roboto covers Portuguese, punctuation and the em dash');
      // A face that lacks a script must say so, which is what font fallback
      // is driven by. Roboto-Regular carries no Han ideographs.
      expect(face.covers('漢字'), isFalse);
    });

    test('an uncovered code point maps to notdef rather than a wrong glyph',
        () {
      final Typeface face = _ahem();

      // A private-use character nothing defines.
      expect(face.glyphForCodePoint(0xE123), notdefGlyph);
      expect(face.glyphForCodePoint(-1), notdefGlyph);
    });

    test('the fast lookup agrees with an exhaustive scan of its own coverage',
        () {
      // The categorical test for format 4: whatever the segment arithmetic
      // produced at parse time, every code point it claims to cover must map
      // to a glyph, and no covered code point may map to notdef.
      final Typeface face = _roboto();
      final List<int> covered = face.cmap.characterMap.codePoints.toList();

      expect(covered.length, greaterThan(200));
      for (int i = 1; i < covered.length; i++) {
        expect(covered[i], greaterThan(covered[i - 1]),
            reason: 'coverage must be ascending for the binary search');
      }
      for (final int codePoint in covered) {
        expect(face.glyphForCodePoint(codePoint), isNot(notdefGlyph),
            reason: 'U+${codePoint.toRadixString(16)} is claimed as covered');
      }
    });
  });

  group('identity', () {
    test('a face knows the family and style it is selected by', () {
      final Typeface roboto = _roboto();

      // The 16/17 rule: Roboto-Regular carries name 1 = "Roboto" and no name
      // 16, so both spellings agree here. What matters is that the face
      // answers with a *name* rather than with its file name.
      expect(roboto.familyName, 'Roboto');
      expect(roboto.subfamilyName, 'Regular');
      expect(roboto.name!.postScriptName, 'Roboto-Regular');
      expect(roboto.weightClass, 400);
      expect(roboto.widthClass, 5);
      expect(roboto.isItalic, isFalse);
      expect(roboto.isOblique, isFalse);
      expect(roboto.declaresStyle, isTrue);
      expect(roboto.identityIssues, isEmpty);

      final Typeface dejaVu = _dejaVu();
      expect(dejaVu.familyName, 'DejaVu Sans');
      expect(dejaVu.subfamilyName, 'Book');
      // post 2.0 stores glyph names; Roboto ships 3.0, which stores none.
      expect(dejaVu.post!.hasGlyphNames, isTrue);
      expect(roboto.post!.hasGlyphNames, isFalse);
    });

    test('an OS/2 claim is a hint and the cmap is the answer', () {
      // The categorical fallback test, on a real font. DejaVu Sans sets the
      // Thai coverage bit and has no Thai glyph whatsoever; Ahem sets the Greek
      // bit and has no Greek. A fallback that trusted the bit would hand back a
      // face full of .notdef, which is why every candidate is confirmed through
      // the cmap.
      final Typeface dejaVu = _dejaVu();
      expect(dejaVu.declaresCodePoint(0x0E01), isTrue, reason: 'claims Thai');
      expect(dejaVu.coversCodePoint(0x0E01), isFalse, reason: 'has no Thai');

      final Typeface ahem = _ahem();
      expect(ahem.declaresCodePoint(0x03B1), isTrue, reason: 'claims Greek');
      expect(ahem.coversCodePoint(0x03B1), isFalse);

      // And the reverse direction: a character with no assigned range bit at
      // all, which DejaVu draws perfectly well. Excluding a face because it
      // failed the bit test would lose this.
      expect(Os2Table.rangeForCodePoint(0x1F600), isNull);
      expect(dejaVu.declaresCodePoint(0x1F600), isFalse);
      expect(dejaVu.coversCodePoint(0x1F600), isTrue);
    });

    test('a variation selector is answered by the font or by nobody', () {
      // None of the three fixtures carries cmap format 14, and the honest
      // answer to "which glyph for this pair" is then null - not the base
      // glyph, which would look like the font had declared a preference.
      final Typeface roboto = _roboto();
      expect(roboto.cmap.variationSelectors, isNull);
      expect(roboto.glyphForVariation(0x263A, 0xFE0F), isNull);
    });
  });

  group('glyph outlines', () {
    test('a simple glyph decodes to a closed path with real bounds', () {
      final Typeface face = _roboto();
      final int glyph = face.glyphForCodePoint(0x6F); // 'o'
      final Path outline = face.outlineOf(glyph);

      expect(outline.isEmpty, isFalse);
      // 'o' is two contours: the outside and the counter.
      expect(_contourCount(outline), 2);
      expect(outline.bounds.width, greaterThan(0));
      expect(outline.bounds.height, greaterThan(0));
      // Font units, so an 'o' in a 2048 upem face is hundreds of units tall.
      expect(outline.bounds.height, greaterThan(500));
    });

    test('quadratic segments survive into the path', () {
      final Typeface face = _roboto();
      final Path outline = face.outlineOf(face.glyphForCodePoint(0x6F));

      // TrueType outlines are quadratic B-splines and PathBuilder takes
      // quadratics, so no flattening happens on the way in. If this is zero,
      // curves were lost and every glyph is a polygon.
      expect(_verbCount(outline, verbQuadraticTo), greaterThan(4));
      expect(_verbCount(outline, verbCubicTo), 0,
          reason: 'glyf has no cubics; those would be CFF');
    });

    test('a space has no outline but keeps its advance', () {
      final Typeface face = _roboto();
      final int space = face.glyphForCodePoint(0x20);

      expect(face.hasOutline(space), isFalse);
      expect(face.outlineOf(space).isEmpty, isTrue);
      expect(face.advanceOf(space), greaterThan(0),
          reason: 'an empty glyph still moves the pen');
    });

    test('a composite glyph is its base plus its accent', () {
      final Typeface face = _roboto();
      final Path a = face.outlineOf(face.glyphForCodePoint(0x61)); // 'a'
      final Path acute = face.outlineOf(face.glyphForCodePoint(0x00E1)); // 'á'

      // 'á' is a composite of 'a' and an acute accent, so it has strictly more
      // contours than 'a' alone, and it is taller.
      expect(_contourCount(acute), greaterThan(_contourCount(a)));
      expect(acute.bounds.height, greaterThan(a.bounds.height));
      // Font space is y-UP, and Rect keeps its edges ordered, so the higher
      // the accent reaches the larger `bottom` becomes. Reading `top` as "the
      // visual top" is the mistake this assertion exists to pin down.
      expect(acute.bounds.bottom, greaterThan(a.bounds.bottom),
          reason: 'the accent reaches higher, and higher means larger y');
      expect(acute.bounds.top, a.bounds.top,
          reason: 'the base letter still sets the lowest point');
    });

    test('outlines are cached by glyph id', () {
      final Typeface face = _roboto();
      final int glyph = face.glyphForCodePoint(0x41);

      expect(identical(face.outlineOf(glyph), face.outlineOf(glyph)), isTrue);
    });

    test('every glyph in a large face decodes without throwing', () {
      // The blunt instrument: 6253 glyphs including composites, ligatures and
      // whatever else DejaVu carries. It catches flag-decompression and
      // coordinate-accumulation bugs that a handful of Latin letters miss.
      final Typeface face = _dejaVu();
      int withOutlines = 0;

      for (int glyph = 0; glyph < face.glyphCount; glyph++) {
        final Path outline = face.outlineOf(glyph);
        if (!outline.isEmpty) withOutlines++;
      }

      expect(withOutlines, greaterThan(6000));
    });

    test('Ahem glyphs are the em box they claim to be', () {
      // Exact geometry, which is the whole point of this fixture: the box runs
      // from -0.2 em to 0.8 em vertically and 0 to 1 em horizontally.
      final Typeface face = _ahem();
      final Path outline = face.outlineOf(face.glyphForCodePoint(0x58));

      expect(_contourCount(outline), 1);
      expect(outline.bounds.left, closeTo(0, 1));
      expect(outline.bounds.right, closeTo(1000, 1));
      // y-up: the box runs from -0.2 em (descender) to 0.8 em (ascender).
      expect(outline.bounds.top, closeTo(-200, 1));
      expect(outline.bounds.bottom, closeTo(800, 1));
    });
  });

  group('outline formats', () {
    test('a CFF font opens and reports itself as CFF', () {
      // This test used to assert the opposite: that an OTTO font was refused
      // by name. It is inverted rather than deleted because the refusal was
      // the *observable* consequence of having no charstring interpreter, and
      // the thing worth keeping under test is that opening an OTTO file now
      // takes the CFF path rather than failing on a missing `glyf`. The
      // charstring interpreter itself is tested in `cff_test.dart`.
      final File otf = File('C:/Windows/Fonts/Academico-Regular.otf');
      if (!otf.existsSync()) {
        markTestSkipped('needs a CFF font; none found on this machine');
        return;
      }

      final Typeface face = Typeface.parse(otf.readAsBytesSync());
      expect(face.isCff, isTrue);
      expect(face.cff, isNotNull);
      expect(face.sfnt.outlineTable, 'CFF ');
      expect(face.outlineOf(face.glyphForCodePoint(0x41)).isEmpty, isFalse);
    });

    test('a TrueType font stays on the glyf path', () {
      final Typeface face = _roboto();
      expect(face.isCff, isFalse);
      expect(face.cff, isNull);
      expect(face.sfnt.outlineTable, 'glyf');
    });
  });

  group('measurement', () {
    test('an unshaped run is the sum of its advances', () {
      final ScaledTypeface font = _ahem().atSize(20);

      // Ahem is monospace at exactly one em, so five characters is 100 px and
      // the assertion can be exact.
      expect(font.measure('XXXXX'), closeTo(100, 0.001));
      expect(font.measure(''), 0);
    });

    test('scale is pixels per em, not per unit', () {
      final Typeface face = _roboto();
      final ScaledTypeface small = face.atSize(16);
      final ScaledTypeface large = face.atSize(32);

      expect(large.scale, closeTo(small.scale * 2, 1e-12));
      expect(large.measure('Hello'), closeTo(small.measure('Hello') * 2, 1e-9));
    });
  });
}

int _contourCount(Path path) => _verbCount(path, verbMoveTo);

int _verbCount(Path path, int verb) {
  int count = 0;
  for (int i = 0; i < path.verbCount; i++) {
    if (path.verbAt(i) == verb) count++;
  }
  return count;
}
