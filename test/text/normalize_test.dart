/// Unicode normalization (UAX #15).
///
/// **There is no conformance suite here, because there is no data file to run
/// one from.** `referencias/unicode/` carries `GraphemeBreakTest.txt` and
/// `LineBreakTest.txt`, which the sibling suites consume, but not
/// `NormalizationTest.txt` - the file that lists every canonical and
/// compatibility equivalence and is the only exhaustive check of a normalizer.
/// Every case below is therefore hand-written, and each one says where it
/// comes from: the worked examples of UAX #15 itself, the
/// composition-exclusion list, and the Hangul arithmetic. That is a real gap:
/// these tests prove the cases a person thought of, and adding
/// `NormalizationTest.txt` to `test/data/unicode/` would prove the rest.
///
/// Every non-ASCII character here is written as a `\u` escape rather than as
/// literal accented text. A composed and a decomposed A-with-ring are
/// indistinguishable in an editor, and a test whose expectation looks
/// identical to its input proves nothing.
library;

import 'package:dart_ui/src/text/normalize.dart';
import 'package:test/test.dart';

String hex(String text) => text.runes
    .map(
      (int rune) => 'U+${rune.toRadixString(16).toUpperCase().padLeft(4, '0')}',
    )
    .join(' ');

void main() {
  group('canonical decomposition (NFD)', () {
    test('empty text is returned unchanged and identically', () {
      expect(identical(nfd(''), ''), isTrue);
      expect(identical(nfc(''), ''), isTrue);
    });

    test('a precomposed letter decomposes into base and mark', () {
      // UAX #15's headline example: U+00C5 LATIN CAPITAL LETTER A WITH RING
      // ABOVE is canonically equivalent to U+0041 U+030A, and the two
      // spellings have to convert into each other in both directions.
      expect(nfd('Å'), 'Å');
      expect(nfc('Å'), 'Å');
    });

    test('a singleton decomposes and never comes back', () {
      // U+212B ANGSTROM SIGN decomposes to one code point, so it is a
      // singleton and Full_Composition_Exclusion: NFC of it is U+00C5, not
      // U+212B. A composer that indexed singletons would turn every
      // A-with-ring into the deprecated symbol.
      expect(nfd('Å'), 'Å');
      expect(nfc('Å'), 'Å');
      expect(nfc('Å'), 'Å');
    });

    test('decomposition is recursive, not one step', () {
      // U+1E9B LATIN SMALL LETTER LONG S WITH DOT ABOVE. Its `dm` is
      // U+017F U+0307, and U+017F's own compatibility mapping is `s`.
      // Applying the mapping once and stopping gives U+017F U+0307, which is
      // not NFKD.
      expect(nfd('ẛ'), 'ẛ');
      expect(nfkd('ẛ'), 'ṡ');
      // Composing that gives U+1E61 s-with-dot-above, which can only appear
      // if the recursion happened first.
      expect(nfkc('ẛ'), 'ṡ');
    });

    test('a surrogate pair decomposes without coming apart', () {
      // U+1D15E MUSICAL SYMBOL HALF NOTE, an astral character with a canonical
      // decomposition. Working in UTF-16 units would read the properties of a
      // lone surrogate, which has none.
      expect('\u{1D15E}'.length, 2, reason: 'the test needs an astral input');
      expect(nfd('\u{1D15E}'), '\u{1D157}\u{1D165}');
      expect(nfd('\u{1D15E}').length, 4);
    });

    test('an unpaired surrogate survives instead of throwing', () {
      const String damaged = '\uD800';
      expect(nfd('a${damaged}b'), 'a${damaged}b');
      expect(nfc('a${damaged}b'), 'a${damaged}b');
    });
  });

  group('canonical ordering', () {
    test('two marks out of order are sorted by combining class', () {
      // UAX #15's example: q + U+0307 dot above (ccc 230) + U+0323 dot below
      // (ccc 220). The lower class sorts first, so the input order is the
      // wrong one and NFD has to fix it.
      expect(nfd('q̣̇'), 'q̣̇');
      expect(nfd('q̣̇'), 'q̣̇');
    });

    test('reordering happens across a whole run of marks', () {
      // ccc 230, 220 and 1: the tilde overlay has to travel to the front of
      // the run, past two other marks.
      expect(nfd('ạ̴́'), 'ạ̴́');
    });

    test('a starter is a barrier: marks never move past one', () {
      // U+00E9 U+00E0 decomposes to e + acute + a + grave. Sorting the buffer
      // as a whole rather than run by run would pull the grave (230) next to
      // the acute (230) and hang it off the wrong letter - corruption, not a
      // normalization difference.
      expect(nfd('éà'), 'éà');
    });

    test('the sort is stable: equal classes keep their order', () {
      // U+0300 and U+0301 are both ccc 230, so `a grave acute` and
      // `a acute grave` are *not* canonically equivalent and must stay apart.
      // An unstable sort would collapse them into one answer.
      expect(nfd('à́'), 'à́');
      expect(nfd('á̀'), 'á̀');
      expect(nfc('à́'), 'à́');
      expect(nfc('á̀'), 'á̀');
    });
  });

  group('canonical composition (NFC)', () {
    test('the classic two-mark example composes the right one', () {
      // UAX #15: U+1E0B (d with dot above) followed by U+0323 (dot below)
      // normalizes to U+1E0D (d with dot below) followed by U+0307 - the mark
      // that composes is the one canonical ordering put first, not the one
      // the input happened to spell.
      expect(nfd('ḍ̇'), 'ḍ̇');
      expect(nfc('ḍ̇'), 'ḍ̇');
    });

    test('a blocked mark does not compose with the starter', () {
      // A + U+0305 overline (ccc 230) + U+030A ring (ccc 230). The overline
      // stands between the A and the ring with an equal class, so the ring is
      // *blocked* (UAX #15, D115) and U+00C5 must not appear. An
      // implementation that only asks "is the previous character a starter"
      // gets this wrong.
      expect(hex(nfc('A̅̊')), 'U+0041 U+0305 U+030A');
    });

    test('a mark of lower class does not block', () {
      // The same shape with U+0334 tilde overlay (ccc 1) in between: 1 < 230
      // leaves the ring unblocked, so it composes onto the A while the
      // overlay stays where canonical ordering put it.
      expect(nfc('Å̴'), 'Å̴');
    });

    test('a composition exclusion is decomposed and left apart', () {
      // U+0958 DEVANAGARI LETTER KHA WITH NUKTA is in CompositionExclusions:
      // it decomposes to U+0915 U+093C and must never be put back together,
      // from either spelling.
      expect(nfd('क़'), 'क़');
      expect(nfc('क़'), 'क़');
      expect(nfc('क़'), 'क़');
    });

    test('an astral composition exclusion stays decomposed', () {
      expect(nfc('\u{1D157}\u{1D165}'), '\u{1D157}\u{1D165}');
      expect(nfc('\u{1D15E}'), '\u{1D157}\u{1D165}');
    });

    test('a leading combining mark has nothing to compose with', () {
      expect(nfc('̊abc'), '̊abc');
      expect(nfd('̣̇abc'), '̣̇abc');
    });
  });

  group('Hangul', () {
    // The 11172 syllables are not in the table; both directions are
    // arithmetic (UAX #15, Hangul syllable decomposition and composition).
    test('an LVT syllable decomposes into three jamo', () {
      // U+AC01 GAG.
      expect(nfd('각'), '각');
    });

    test('an LV syllable decomposes into two jamo', () {
      expect(nfd('가'), '가');
    });

    test('three jamo compose back into one syllable', () {
      expect(nfc('각'), '각');
    });

    test('LV plus a trailing jamo composes, which is the second step', () {
      // The case a one-step composer misses: L and V have already become an
      // LV syllable, and the T has to compose onto *that*.
      expect(nfc('각'), '각');
    });

    test('U+11A7 is not a trailing jamo and must not compose', () {
      // Trailing index 0 means "no trailing jamo"; U+11A7 is the base of the
      // arithmetic, not a character to append.
      expect(nfc('가ᆧ'), '가ᆧ');
    });

    test('a whole word round-trips', () {
      const String word = '한글'; // HAN GEUL
      expect(nfd(word).length, 6);
      expect(nfc(nfd(word)), word);
    });
  });

  group('compatibility forms (NFKC, NFKD)', () {
    test('a ligature is broken into its letters', () {
      expect(nfkc('ﬁ'), 'fi');
      expect(nfkd('ﬀ'), 'ff');
      expect(nfkc('oﬃce'), 'office');
    });

    test('a circled digit becomes the digit', () {
      expect(nfkc('①'), '1');
      expect(nfkd('②③'), '23');
    });

    test('a squared abbreviation expands', () {
      expect(nfkd('㎒'), 'MHz');
    });

    test('the canonical forms leave all of that alone', () {
      // The whole point of the canonical/compatibility split: NFC must not
      // rewrite text the user did not ask to change.
      expect(nfc('ﬁ'), 'ﬁ');
      expect(nfd('①'), '①');
      expect(nfc('㎒'), '㎒');
    });

    test('a compatibility decomposition is also canonically composed', () {
      // U+FDFA ARABIC LIGATURE SALLALLAHOU ALAYHE WASALLAM expands to
      // eighteen code points, and the result still goes through composition.
      expect(nfkd('ﷺ').length, 18);
      expect(nfkc('ﷺ'), nfc(nfkd('ﷺ')));
    });
  });

  group('quick check', () {
    test('already normalized text is yes and is returned identically', () {
      const String plain = 'The quick brown fox';
      expect(isNfc(plain), QuickCheck.yes);
      expect(isNfd(plain), QuickCheck.yes);
      expect(
        identical(nfc(plain), plain),
        isTrue,
        reason: 'the no-op path must not allocate',
      );
      expect(identical(nfd(plain), plain), isTrue);
      expect(identical(nfkc(plain), plain), isTrue);
      expect(identical(nfkd(plain), plain), isTrue);
    });

    test('a precomposed character is no for NFD and yes for NFC', () {
      expect(isNfd('Å'), QuickCheck.no);
      expect(isNfc('Å'), QuickCheck.yes);
      expect(identical(nfc('Å'), 'Å'), isTrue);
    });

    test('a combining mark that may compose is maybe, never yes', () {
      // U+0301 has NFC_QC=Maybe: whether it composes depends on what precedes
      // it, and answering yes here would skip work that changes the string.
      expect(isNfc('é'), QuickCheck.maybe);
      expect(nfc('é'), 'é');
      // The same mark after a character it cannot compose with: still maybe,
      // and this time the text really is unchanged. Maybe means maybe.
      expect(isNfc('一́'), QuickCheck.maybe);
      expect(nfc('一́'), '一́');
    });

    test('NFD and NFKD never answer maybe', () {
      for (final String sample in <String>[
        'é',
        'Å',
        '각',
        'ḍ̇',
        'ﬁ',
      ]) {
        expect(isNfd(sample), isNot(QuickCheck.maybe), reason: hex(sample));
        expect(isNfkd(sample), isNot(QuickCheck.maybe), reason: hex(sample));
      }
    });

    test('marks in the wrong order are no, whatever the properties say', () {
      // Neither U+0307 nor U+0323 is NFD_QC=No on its own; the string is not
      // normalized because they are out of canonical order, and the quick
      // check has to notice that too or it reports yes for text that NFD
      // changes.
      expect(isNfd('q̣̇'), QuickCheck.no);
      expect(isNfc('q̣̇'), QuickCheck.no);
      expect(isNfd('q̣̇'), QuickCheck.yes);
    });

    test('quickCheck agrees with the form it names', () {
      const String sample = 'ḍ̇';
      expect(quickCheck(sample, NormalizationForm.nfd), isNfd(sample));
      expect(quickCheck(sample, NormalizationForm.nfc), isNfc(sample));
      expect(quickCheck(sample, NormalizationForm.nfkd), isNfkd(sample));
      expect(quickCheck(sample, NormalizationForm.nfkc), isNfkc(sample));
    });

    test('normalize dispatches to the same functions', () {
      const String sample = 'ẛ';
      expect(normalize(sample, NormalizationForm.nfd), nfd(sample));
      expect(normalize(sample, NormalizationForm.nfc), nfc(sample));
      expect(normalize(sample, NormalizationForm.nfkd), nfkd(sample));
      expect(normalize(sample, NormalizationForm.nfkc), nfkc(sample));
    });
  });

  group('invariants over a corpus', () {
    // Varied on purpose: Latin with marks in both spellings, Greek, Hebrew,
    // Devanagari, Hangul in both spellings, astral music, a flag, ligatures,
    // mis-ordered marks, and text that is already normalized.
    const List<String> corpus = <String>[
      '',
      'ascii only',
      'é',
      'é',
      'Å',
      'Å',
      'A̅̊',
      'Å̴',
      'q̣̇',
      'ḍ̇',
      'ẛ',
      'क़',
      'क़ि',
      '각한',
      '각',
      'Σος',
      'אָ',
      'ﬁﬀﬃ',
      '①㎒㏂',
      '\u{1D15E}\u{1D160}',
      '\u{1F1E7}\u{1F1F7}',
      'Straße, Grüße',
      'ạ̴́b́',
      'ﷺ',
    ];

    test('every form is idempotent', () {
      for (final String sample in corpus) {
        expect(nfc(nfc(sample)), nfc(sample), reason: hex(sample));
        expect(nfd(nfd(sample)), nfd(sample), reason: hex(sample));
        expect(nfkc(nfkc(sample)), nfkc(sample), reason: hex(sample));
        expect(nfkd(nfkd(sample)), nfkd(sample), reason: hex(sample));
      }
    });

    test('the output of each form quick-checks as being in it', () {
      for (final String sample in corpus) {
        expect(isNfd(nfd(sample)), QuickCheck.yes, reason: hex(sample));
        expect(isNfkd(nfkd(sample)), QuickCheck.yes, reason: hex(sample));
        // NFC and NFKC output may quick-check as maybe - a trailing mark that
        // could have composed with something else - but never as no.
        expect(isNfc(nfc(sample)), isNot(QuickCheck.no), reason: hex(sample));
        expect(isNfkc(nfkc(sample)), isNot(QuickCheck.no), reason: hex(sample));
      }
    });

    test('NFC and NFD are two spellings of the same text', () {
      for (final String sample in corpus) {
        expect(nfd(nfc(sample)), nfd(sample), reason: hex(sample));
        expect(nfc(nfd(sample)), nfc(sample), reason: hex(sample));
      }
    });

    test('the compatibility forms subsume the canonical ones', () {
      for (final String sample in corpus) {
        expect(nfkc(nfc(sample)), nfkc(sample), reason: hex(sample));
        expect(nfkd(nfd(sample)), nfkd(sample), reason: hex(sample));
        expect(nfkc(nfkd(sample)), nfkc(sample), reason: hex(sample));
      }
    });
  });
}
