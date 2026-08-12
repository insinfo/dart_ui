/// The Unicode Bidirectional Algorithm (UAX #9).
///
/// The hand-written cases spell out what each rule is *for*, using real
/// Hebrew and Arabic rather than the uppercase-means-RTL shorthand of the
/// annex, so a failure names a visible symptom. The two Unicode conformance
/// suites at the bottom are what actually establishes correctness: between
/// them they cover every combination of bidi classes up to length four and
/// every bracket-pair case the Consortium could think of, which is far beyond
/// what anyone would write by hand.
library;

import 'package:dart_ui/src/text/bidi.dart';
import 'package:dart_ui/src/text/shaper.dart' show TextDirection;
import 'package:test/test.dart';

import '../data/unicode/ucd_data.dart';

// Real text, so that a failing expectation can be read out loud.
const String hebrew = 'שלום'; // "shalom"
const String alef = 'א';

// The formatting characters, as escapes rather than literals. They are
// invisible and they reorder the source around them, so a literal one in a
// test would make the file itself display differently from what it means -
// which is exactly the hazard `text_direction_code_point_in_literal` exists
// to catch.
const String lre = '\u202A';
const String rle = '\u202B';
const String pdf = '\u202C';
const String lro = '\u202D';
const String rlo = '\u202E';
const String lri = '\u2066';
const String rli = '\u2067';
const String fsi = '\u2068';
const String pdi = '\u2069';

List<int> _levelsOf(String text, {TextDirection? base}) =>
    BidiParagraph.resolve(text, baseDirection: base).levels.toList();

void main() {
  group('paragraph level (P2, P3)', () {
    test('a Latin-first paragraph is left to right', () {
      final BidiParagraph p = BidiParagraph.resolve('hello $hebrew');
      expect(p.paragraphLevel, 0);
      expect(p.baseDirection, TextDirection.leftToRight);
    });

    test('a Hebrew-first paragraph is right to left', () {
      final BidiParagraph p = BidiParagraph.resolve('$hebrew hello');
      expect(p.paragraphLevel, 1);
      expect(p.baseDirection, TextDirection.rightToLeft);
    });

    test('leading neutrals and digits do not decide the direction', () {
      // P2 looks for the first *strong* character. Digits are weak, so a
      // paragraph starting "123 " is decided by whatever word follows - the
      // usual mistake here is to stop at the first non-neutral instead.
      expect(BidiParagraph.resolve('  ...123 $hebrew').paragraphLevel, 1);
      expect(BidiParagraph.resolve('  ...123 abc').paragraphLevel, 0);
    });

    test('a paragraph with no strong character defaults to left to right', () {
      expect(BidiParagraph.resolve('123 ... !!!').paragraphLevel, 0);
      expect(BidiParagraph.resolve('').paragraphLevel, 0);
    });

    test('an explicit base direction overrides P2', () {
      final BidiParagraph p = BidiParagraph.resolve(
        'hello',
        baseDirection: TextDirection.rightToLeft,
      );
      expect(p.paragraphLevel, 1);
      expect(p.levels, <int>[2, 2, 2, 2, 2],
          reason: 'Latin inside an RTL paragraph goes up one level');
    });

    test('characters inside an isolate do not decide the direction', () {
      // P2 skips from an isolate initiator to its matching PDI. Without that,
      // an isolated Hebrew quotation would flip a Latin paragraph.
      const String text = '$lri$hebrew$pdi abc';
      expect(BidiParagraph.resolve(text).paragraphLevel, 0);
    });
  });

  group('implicit levels (W, N, I)', () {
    test('Hebrew in a Latin paragraph is one level up', () {
      expect(_levelsOf('a$alef b'), <int>[0, 1, 0, 0]);
    });

    test('Latin in a Hebrew paragraph is one level up', () {
      expect(_levelsOf('${alef}a$alef'), <int>[1, 2, 1]);
    });

    test('a number between two Arabic words stays with the Arabic', () {
      // The classic case. "12" is EN, but W2 turns it into AN after an AL, and
      // I2 puts AN one level above the surrounding RTL text - so the digits
      // read left to right *inside* right-to-left text rather than dragging
      // the sentence apart.
      const String text = 'مرحبا 12 مرحبا';
      final BidiParagraph p = BidiParagraph.resolve(text);
      expect(p.paragraphLevel, 1);
      final List<int> levels = p.levels.toList();
      expect(levels.sublist(6, 8), <int>[2, 2], reason: 'the digits');
      expect(levels[5], 1, reason: 'the space stays at the Arabic level');
    });

    test('a number after Latin text keeps the Latin direction', () {
      // W7: "IT IS A bmw 500" - the 500 belongs to the Latin run, not to the
      // Hebrew sentence around it.
      final BidiParagraph p = BidiParagraph.resolve('$alef bmw 500',
          baseDirection: TextDirection.rightToLeft);
      final List<int> levels = p.levels.toList();
      expect(levels.sublist(6, 9), <int>[2, 2, 2],
          reason: 'the digits take the level of the Latin run, not AN + 1');
    });

    test('a decimal point inside a number is part of the number', () {
      // W4. "1.5" must not split into "1", ".", "5" with the dot resolved as
      // a neutral, or an RTL paragraph shows "5.1".
      final BidiParagraph p = BidiParagraph.resolve('$alef 1.5',
          baseDirection: TextDirection.rightToLeft);
      expect(p.levels.sublist(2, 5), <int>[2, 2, 2]);
    });

    test('a comma between two numbers separates them', () {
      // Also W4: a comma flanked by numbers joins them, but the sequence
      // "123, 456" has a space after the comma, so it does not.
      final BidiParagraph p = BidiParagraph.resolve(
        '$alef 123, 456',
        baseDirection: TextDirection.rightToLeft,
      );
      final List<int> levels = p.levels.toList();
      expect(levels[5], 1, reason: 'the comma falls back to the RTL run');
      expect(levels.sublist(2, 5), <int>[2, 2, 2]);
      expect(levels.sublist(7, 10), <int>[2, 2, 2]);
    });

    test('a currency sign next to a number joins the number', () {
      // W5: ET adjacent to EN becomes EN.
      expect(_levelsOf('a \$5'), <int>[0, 0, 0, 0]);
      final BidiParagraph rtl = BidiParagraph.resolve('$alef \$5',
          baseDirection: TextDirection.rightToLeft);
      expect(rtl.levels.sublist(2, 4), <int>[2, 2]);
    });

    test('a combining mark takes the direction of its base', () {
      // W1. An accent on a Hebrew letter must not resolve as a neutral, or it
      // ends up on the wrong side of the letter it belongs to.
      final List<int> levels = _levelsOf('a$alef̀b');
      expect(levels, <int>[0, 1, 1, 0]);
    });

    test('neutrals between two RTL runs become RTL', () {
      // N1. The space and the comma sit between Hebrew on both sides, so they
      // join the Hebrew run instead of breaking it into two.
      final List<int> levels = _levelsOf('$alef, $alef');
      expect(levels, <int>[1, 1, 1, 1]);
    });

    test('neutrals between opposite runs take the paragraph direction', () {
      // N2. "a - HEBREW" in an LTR paragraph: the dash has L on one side and
      // R on the other, so it goes to the base direction and stays on the left.
      final List<int> levels = _levelsOf('a - $alef');
      expect(levels, <int>[0, 0, 0, 0, 1]);
    });
  });

  group('bracket pairs (N0)', () {
    test('a parenthesis containing RTL inside LTR stays upright', () {
      // Without N0 the parentheses resolve as ordinary neutrals, one of them
      // joins the Hebrew run, and the pair renders as ")text(" - the single
      // most recognisable bidi bug there is.
      const String text = 'a ($alef$alef) b';
      final List<int> levels = _levelsOf(text);
      expect(levels[2], 0, reason: 'the opening parenthesis');
      expect(levels[5], 0, reason: 'the closing parenthesis');
      expect(levels.sublist(3, 5), <int>[1, 1]);
    });

    test('a parenthesis containing LTR inside RTL stays upright', () {
      final BidiParagraph p = BidiParagraph.resolve(
        '$alef (ab) $alef',
        baseDirection: TextDirection.rightToLeft,
      );
      final List<int> levels = p.levels.toList();
      expect(levels[2], 1, reason: 'the opening parenthesis');
      expect(levels[5], 1, reason: 'the closing parenthesis');
      expect(levels.sublist(3, 5), <int>[2, 2]);
    });

    test('brackets take the opposite direction when context agrees', () {
      // N0 clause 2b, forced to an LTR base so that the rule has something to
      // change: the pair encloses only Hebrew and is *preceded* by Hebrew, so
      // both brackets join the RTL run. The closing one is what proves the
      // rule ran - N2 alone would have given it the base direction, because
      // the character after it is Latin.
      const String text = '$alef ($alef) a';
      final List<int> levels = _levelsOf(text, base: TextDirection.leftToRight);
      expect(levels[2], 1, reason: 'the opening parenthesis follows Hebrew');
      expect(levels[4], 1, reason: 'the closing parenthesis follows it');
    });

    test('brackets around nothing strong are left to N1 and N2', () {
      // N0 clause 3: no strong type inside, so the pair is not resolved as a
      // unit and the ordinary neutral rules apply.
      expect(_levelsOf('a (.) b'), <int>[0, 0, 0, 0, 0, 0, 0]);
    });

    test('unmatched brackets form no pair', () {
      // The same text as above with the brackets the wrong way round, so BD16
      // finds no pair at all and the closing-side character falls back to N2.
      const String text = '$alef )$alef( a';
      final List<int> levels = _levelsOf(text, base: TextDirection.leftToRight);
      expect(levels[4], 0,
          reason: 'a lone opener after a lone closer pairs with nothing');
    });

    test('U+3008 pairs with U+232A under canonical equivalence', () {
      // BD16 compares brackets under canonical equivalence, and this is the
      // only pair in Unicode where that matters.
      const String text = 'a 〈$alef$alef〉 b';
      final List<int> levels = _levelsOf(text);
      expect(levels[2], 0);
      expect(levels[5], 0);
    });
  });

  group('explicit formatting (X1-X8)', () {
    test('an override forces every character to one direction', () {
      // RLO ... PDF. The Latin letters are forced to R, so they come out
      // reversed even though nothing about them is right to left.
      const String text = 'a${rlo}bc${pdf}d';
      final List<int> levels = _levelsOf(text);
      expect(levels[2], 1, reason: 'b, forced to R by the override');
      expect(levels[3], 1, reason: 'c, likewise');
      expect(levels[5], 0, reason: 'd, after the PDF closes the override');
    });

    test('an embedding raises the level without changing types', () {
      const String text = 'a${rle}bc${pdf}d';
      final List<int> levels = _levelsOf(text);
      expect(levels.sublist(2, 4), <int>[2, 2],
          reason: 'Latin inside an RTL embedding is one level above it');
    });

    test('nested isolates each get their own level', () {
      // LRI ( RLI ( LRI ) ) with text at each depth.
      const String text = 'a$rli$alef${lri}b$pdi$alef${pdi}c';
      final List<int> levels = _levelsOf(text);
      expect(levels[0], 0);
      expect(levels[2], 1, reason: 'inside the RLI');
      expect(levels[4], 2, reason: 'inside the nested LRI');
      expect(levels[6], 1, reason: 'back inside the RLI');
      expect(levels[8], 0, reason: 'after the outer PDI');
    });

    test('an isolate does not merge with the run around it', () {
      // The point of an isolate: two Hebrew phrases either side of an
      // isolated Latin one must not fuse into a single RTL run.
      const String text = '$alef${lri}abc$pdi$alef';
      final List<int> levels = _levelsOf(text);
      expect(levels[0], 1);
      expect(levels[2], 2);
      expect(levels[6], 1);
    });

    test('a first-strong isolate picks up its own content direction', () {
      const String ltr = 'a${fsi}bc${pdi}d';
      const String rtl = 'a$fsi$alef$alef${pdi}d';
      expect(_levelsOf(ltr).sublist(2, 4), <int>[2, 2]);
      expect(_levelsOf(rtl).sublist(2, 4), <int>[1, 1]);
    });

    test('overflowing the depth limit does not throw or nest further', () {
      // 200 nested RLEs, well past max_depth of 125. The overflow counters
      // exist so a hostile string cannot grow the status stack without bound.
      final String text = '${rle * 200}a${pdf * 200}';
      final BidiParagraph p = BidiParagraph.resolve(text);
      expect(p.levels.reduce((int a, int b) => a > b ? a : b),
          lessThanOrEqualTo(126));
    });

    test('an unmatched PDI is ignored', () {
      expect(() => BidiParagraph.resolve('a${pdi}b'), returnsNormally);
      expect(_levelsOf('a${pdi}b'), <int>[0, 0, 0]);
    });
  });

  group('reordering (L1, L2)', () {
    test('a level run reverses', () {
      // "a HEBREW b" displays with the Hebrew reversed and nothing else moved.
      final BidiParagraph p = BidiParagraph.resolve('a $hebrew b');
      final List<int> order = BidiParagraph.reorderVisual(p.levels.toList());
      expect(order.take(2), <int>[0, 1]);
      expect(order.sublist(2, 6), <int>[5, 4, 3, 2],
          reason: 'the Hebrew word runs the other way');
      expect(order.sublist(6), <int>[6, 7]);
    });

    test('nested levels reverse from the outside in', () {
      // The whole point of doing L2 top-down: the inner LTR run is reversed
      // once by its own pass and once as part of its RTL parent, so it comes
      // out reading forwards inside a backwards sentence.
      final BidiParagraph p = BidiParagraph.resolve(
        '$alef$alef ab $alef',
        baseDirection: TextDirection.rightToLeft,
      );
      final List<int> order = BidiParagraph.reorderVisual(p.levels.toList());
      expect(order, <int>[6, 5, 3, 4, 2, 1, 0]);
    });

    test('trailing whitespace goes to the paragraph edge', () {
      // L1. Without it, the trailing spaces of an RTL paragraph resolve to
      // level 1 and get reordered to the left margin, where they read as a
      // mystery indent.
      final BidiParagraph p = BidiParagraph.resolve(
        '$alef$alef  ',
        baseDirection: TextDirection.rightToLeft,
      );
      expect(p.levels.sublist(2), <int>[1, 1]);

      final BidiParagraph ltr = BidiParagraph.resolve('$alef$alef  ');
      expect(ltr.paragraphLevel, 1);
      expect(ltr.levels.sublist(2), <int>[1, 1]);

      final BidiParagraph mixed = BidiParagraph.resolve('a $alef  ');
      expect(mixed.levels.sublist(3), <int>[0, 0],
          reason: 'the trailing spaces fall back to the LTR base level');
    });

    test('a tab resets to the paragraph level', () {
      // L1 treats a segment separator, and the whitespace before it, as base
      // direction, so tab stops line up regardless of what surrounds them.
      final BidiParagraph p = BidiParagraph.resolve('$alef \tb');
      expect(p.levels[1], 1, reason: 'the space precedes the tab');
      expect(p.levels[2], 1, reason: 'the tab itself');
      expect(p.paragraphLevel, 1);
    });

    test('reorderVisual on an empty or single-level list is identity', () {
      expect(BidiParagraph.reorderVisual(<int>[]), isEmpty);
      expect(BidiParagraph.reorderVisual(<int>[0, 0, 0]), <int>[0, 1, 2]);
      expect(BidiParagraph.reorderVisual(<int>[2, 2]), <int>[0, 1],
          reason: 'an even level never reverses');
    });

    test('level runs tile the text exactly once', () {
      final BidiParagraph p = BidiParagraph.resolve('a $hebrew 12 b');
      final List<BidiRun> runs = p.levelRuns();
      expect(runs.first.start, 0);
      expect(runs.last.end, p.text.length);
      for (int i = 1; i < runs.length; i++) {
        expect(runs[i].start, runs[i - 1].end);
        expect(runs[i].level, isNot(runs[i - 1].level));
      }
    });

    test('runs in visual order are the same runs, rearranged', () {
      // "HEBREW ab" in an RTL paragraph: the Latin run is drawn first from the
      // left even though it comes second in the string.
      final BidiParagraph p = BidiParagraph.resolve(
        '$hebrew ab',
        baseDirection: TextDirection.rightToLeft,
      );
      final List<BidiRun> visual = p.runsInVisualOrder();
      expect(visual.length, p.levelRuns().length);
      expect(visual.first.level, 2, reason: 'the Latin run comes first');
      expect(visual.last.start, 0, reason: 'the Hebrew run comes last');
      expect(
        visual.map((BidiRun r) => r.start).toList()..sort(),
        p.levelRuns().map((BidiRun r) => r.start).toList(),
      );
    });
  });

  group('surrogates', () {
    test('both halves of a surrogate pair carry one level', () {
      // U+10800 CYPRIOT SYLLABLE A is R and outside the BMP, so a level array
      // indexed by UTF-16 offset has to repeat its level across two units or
      // every downstream slice is off by one.
      const String text = 'a\u{10800}b';
      expect(text.length, 4);
      expect(_levelsOf(text), <int>[0, 1, 1, 0]);
    });
  });

  group('property lookup', () {
    test('classes match the UCD for a spot sample', () {
      expect(bidiClassOf(0x0041), BidiClass.l);
      expect(bidiClassOf(0x05D0), BidiClass.r);
      expect(bidiClassOf(0x0627), BidiClass.al);
      expect(bidiClassOf(0x0030), BidiClass.en);
      expect(bidiClassOf(0x002B), BidiClass.es);
      expect(bidiClassOf(0x0024), BidiClass.et);
      expect(bidiClassOf(0x0660), BidiClass.an);
      expect(bidiClassOf(0x002C), BidiClass.cs);
      expect(bidiClassOf(0x0300), BidiClass.nsm);
      expect(bidiClassOf(0x00AD), BidiClass.bn);
      expect(bidiClassOf(0x000A), BidiClass.b);
      expect(bidiClassOf(0x0009), BidiClass.s);
      expect(bidiClassOf(0x0020), BidiClass.ws);
      expect(bidiClassOf(0x0021), BidiClass.on);
      expect(bidiClassOf(0x202A), BidiClass.lre);
      expect(bidiClassOf(0x202D), BidiClass.lro);
      expect(bidiClassOf(0x202B), BidiClass.rle);
      expect(bidiClassOf(0x202E), BidiClass.rlo);
      expect(bidiClassOf(0x202C), BidiClass.pdf);
      expect(bidiClassOf(0x2066), BidiClass.lri);
      expect(bidiClassOf(0x2067), BidiClass.rli);
      expect(bidiClassOf(0x2068), BidiClass.fsi);
      expect(bidiClassOf(0x2069), BidiClass.pdi);
    });

    test('unassigned code points in RTL blocks default to R or AL', () {
      // The @missing defaults of DerivedBidiClass.txt. A table built only from
      // assigned characters would call these L, and a future Hebrew letter
      // would render in the wrong direction.
      expect(bidiClassOf(0x05EB), BidiClass.r, reason: 'unassigned Hebrew');
      expect(bidiClassOf(0x1EE04), BidiClass.al, reason: 'unassigned Arabic');
      expect(bidiClassOf(0x10FFF), BidiClass.r);
    });
  });

  group('UCD conformance', () {
    _bidiCharacterTest();
    _bidiTest();
  });
}

// ---------------------------------------------------------------------------
// BidiCharacterTest.txt: real code points, resolved levels and visual order.
// ---------------------------------------------------------------------------

void _bidiCharacterTest() {
  final List<String>? lines = ucdConformanceLines('BidiCharacterTest.txt');
  if (lines == null) {
    test('BidiCharacterTest.txt', () {},
        skip: 'missing: $ucdDataDirectory/BidiCharacterTest.txt.gz');
    return;
  }

  test('every case in BidiCharacterTest.txt', () {
    int cases = 0;
    final List<String> failures = <String>[];
    for (final String rawLine in lines) {
      final String line = _strip(rawLine);
      if (line.isEmpty) continue;
      final List<String> fields = line.split(';');
      if (fields.length < 5) continue;
      cases++;

      final StringBuffer buffer = StringBuffer();
      for (final String hex in fields[0].split(' ')) {
        buffer.writeCharCode(int.parse(hex, radix: 16));
      }
      final String text = buffer.toString();
      final TextDirection? base = switch (fields[1]) {
        '0' => TextDirection.leftToRight,
        '1' => TextDirection.rightToLeft,
        _ => null,
      };

      final BidiParagraph paragraph =
          BidiParagraph.resolve(text, baseDirection: base);
      final _Observed observed = _observe(paragraph, text);

      final int expectedLevel = int.parse(fields[2]);
      final List<String> expectedLevels = fields[3].split(' ');
      final List<int> expectedOrder = fields[4].trim().isEmpty
          ? <int>[]
          : fields[4].split(' ').map(int.parse).toList();

      if (paragraph.paragraphLevel != expectedLevel) {
        failures.add('$line\n  paragraph level ${paragraph.paragraphLevel}');
        continue;
      }
      if (!_levelsMatch(observed.levels, expectedLevels)) {
        failures.add('$line\n  levels ${observed.levels}');
        continue;
      }
      if (!_sameList(observed.order, expectedOrder)) {
        failures.add('$line\n  order ${observed.order} != $expectedOrder');
      }
      if (failures.length > 20) break;
    }
    expect(cases, greaterThan(90000), reason: 'the file should be exhaustive');
    expect(failures, isEmpty, reason: 'of $cases cases');
  }, timeout: const Timeout(Duration(minutes: 5)));
}

// ---------------------------------------------------------------------------
// BidiTest.txt: every combination of bidi classes, as class names.
// ---------------------------------------------------------------------------

/// One representative code point per bidi class, for turning a BidiTest line
/// of class names into a string. Verified against [bidiClassOf] by the first
/// test in the group, so a wrong choice cannot quietly weaken the suite.
const Map<String, int> _representatives = <String, int>{
  'L': 0x0041, // A
  'R': 0x05D0, // HEBREW LETTER ALEF
  'AL': 0x0627, // ARABIC LETTER ALEF
  'EN': 0x0030, // DIGIT ZERO
  'ES': 0x002B, // PLUS SIGN
  'ET': 0x0024, // DOLLAR SIGN
  'AN': 0x0660, // ARABIC-INDIC DIGIT ZERO
  'CS': 0x002C, // COMMA
  'NSM': 0x0300, // COMBINING GRAVE ACCENT
  'BN': 0x00AD, // SOFT HYPHEN
  'B': 0x2029, // PARAGRAPH SEPARATOR
  'S': 0x0009, // TAB
  'WS': 0x0020, // SPACE
  'ON': 0x0021, // EXCLAMATION MARK
  'LRE': 0x202A,
  'RLE': 0x202B,
  'PDF': 0x202C,
  'LRO': 0x202D,
  'RLO': 0x202E,
  'LRI': 0x2066,
  'RLI': 0x2067,
  'FSI': 0x2068,
  'PDI': 0x2069,
};

void _bidiTest() {
  final List<String>? lines = ucdConformanceLines('BidiTest.txt');
  if (lines == null) {
    test('BidiTest.txt', () {},
        skip: 'missing: $ucdDataDirectory/BidiTest.txt.gz');
    return;
  }

  test('the representative code points really have the classes claimed', () {
    _representatives.forEach((String name, int codePoint) {
      expect(bidiClassOf(codePoint).name.toUpperCase(), name);
    });
    // ON is stood in for by '!', which must not be a paired bracket or N0
    // would take a hand in every ON case in the suite.
    expect(BidiParagraph.resolve('a(!)b').levels, <int>[0, 0, 0, 0, 0]);
  });

  test('every case in BidiTest.txt', () {
    int cases = 0;
    final List<String> failures = <String>[];
    List<String> expectedLevels = <String>[];
    List<int> expectedOrder = <int>[];

    for (final String rawLine in lines) {
      final String line = _strip(rawLine);
      if (line.isEmpty) continue;
      if (line.startsWith('@Levels:')) {
        expectedLevels = _words(line.substring(8));
        continue;
      }
      if (line.startsWith('@Reorder:')) {
        expectedOrder = _words(line.substring(9)).map(int.parse).toList();
        continue;
      }
      if (line.startsWith('@')) continue;

      final List<String> fields = line.split(';');
      if (fields.length < 2) continue;
      final List<String> classes = _words(fields[0]);
      final int bitset = int.parse(fields[1].trim(), radix: 16);

      final StringBuffer buffer = StringBuffer();
      for (final String name in classes) {
        final int? codePoint = _representatives[name];
        if (codePoint == null) throw StateError('no representative for $name');
        buffer.writeCharCode(codePoint);
      }
      final String text = buffer.toString();

      for (final (int bit, TextDirection? base) in <(int, TextDirection?)>[
        (1, null),
        (2, TextDirection.leftToRight),
        (4, TextDirection.rightToLeft),
      ]) {
        if (bitset & bit == 0) continue;
        cases++;
        final _Observed observed =
            _observe(BidiParagraph.resolve(text, baseDirection: base), text);
        if (!_levelsMatch(observed.levels, expectedLevels)) {
          failures.add('$line [p=$bit]\n  levels ${observed.levels} '
              '!= $expectedLevels');
        } else if (!_sameList(observed.order, expectedOrder)) {
          failures.add('$line [p=$bit]\n  order ${observed.order} '
              '!= $expectedOrder');
        }
        if (failures.length > 20) break;
      }
      if (failures.length > 20) break;
    }
    expect(cases, greaterThan(400000), reason: 'the file should be exhaustive');
    expect(failures, isEmpty, reason: 'of $cases cases');
  }, timeout: const Timeout(Duration(minutes: 10)));
}

// ---------------------------------------------------------------------------
// Shared conformance helpers
// ---------------------------------------------------------------------------

/// What a conformance file can observe: levels and visual order of the
/// characters whose level the algorithm actually defines.
///
/// Both files leave out the characters X9 removes - the embedding and override
/// initiators, PDF and BN - because UAX #9 does not specify where a retained
/// one ends up. This project *does* give them a level so that runs stay
/// contiguous, so the comparison filters them out here rather than weakening
/// the implementation to match the file.
final class _Observed {
  const _Observed(this.levels, this.order);

  /// One entry per code point, `null` where the file writes `x`.
  final List<int?> levels;

  /// Code point indices in visual order, omitting the removed ones.
  final List<int> order;
}

_Observed _observe(BidiParagraph paragraph, String text) {
  final List<int?> levels = <int?>[];
  final List<int> kept = <int>[];
  final List<int> keptLevels = <int>[];

  int index = 0;
  int offset = 0;
  for (final int codePoint in text.runes) {
    if (bidiClassOf(codePoint).isRemovedByX9) {
      levels.add(null);
    } else {
      levels.add(paragraph.levels[offset]);
      kept.add(index);
      keptLevels.add(paragraph.levels[offset]);
    }
    offset += codePoint > 0xFFFF ? 2 : 1;
    index++;
  }

  final List<int> order =
      BidiParagraph.reorderVisual(keptLevels).map((int i) => kept[i]).toList();
  return _Observed(levels, order);
}

bool _levelsMatch(List<int?> actual, List<String> expected) {
  if (actual.length != expected.length) return false;
  for (int i = 0; i < actual.length; i++) {
    if (expected[i] == 'x') {
      if (actual[i] != null) return false;
    } else if (actual[i] != int.parse(expected[i])) {
      return false;
    }
  }
  return true;
}

bool _sameList(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (int i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

String _strip(String rawLine) {
  final int hash = rawLine.indexOf('#');
  return (hash >= 0 ? rawLine.substring(0, hash) : rawLine).trim();
}

List<String> _words(String text) => text
    .trim()
    .split(RegExp(r'\s+'))
    .where((String w) => w.isNotEmpty)
    .toList();
