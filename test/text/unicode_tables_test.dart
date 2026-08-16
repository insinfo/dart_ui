/// The generated Unicode property tables, checked against the UCD.
///
/// These are not round-trip tests. `tool/generate_unicode_tables.dart` reads
/// the UCD and writes the tables, so a test that re-read the UCD and compared
/// would only prove the generator is deterministic - it would agree with itself
/// about a mis-shifted bit field for the whole code space. What is checked here
/// is *named characters with values a person can look up*: alef is
/// right-joining, acute accent has combining class 230, sharp s uppercases to
/// two S's. If a packing bug flips a field, one of these stops matching the
/// standard rather than matching a differently-wrong table.
///
/// The second half checks the properties the tables claim rather than
/// individual values: that the range tables really do cover U+0000..U+10FFFF,
/// that the sparse tables are ordered, and that the packed bit fields do not
/// bleed into each other.
library;

import 'package:dart_ui/src/text/tables/case_table.dart';
import 'package:dart_ui/src/text/tables/indic_table.dart';
import 'package:dart_ui/src/text/tables/joining_table.dart';
import 'package:dart_ui/src/text/tables/mirroring_table.dart';
import 'package:dart_ui/src/text/tables/normalization_table.dart';
import 'package:dart_ui/src/text/tables/script_table.dart';
import 'package:dart_ui/src/text/tables/vertical_table.dart';
import 'package:dart_ui/src/text/tables/word_break_table.dart';
import 'package:test/test.dart';

/// One past the last code point.
const int _codeSpace = 0x110000;

void main() {
  group('Script', () {
    test('named characters have the script they are named after', () {
      expect(scriptOf(0x0041), Script.latn); // LATIN CAPITAL LETTER A
      expect(scriptOf(0x05D0), Script.hebr); // HEBREW LETTER ALEF
      expect(scriptOf(0x0627), Script.arab); // ARABIC LETTER ALEF
      expect(scriptOf(0x4E00), Script.hani); // CJK IDEOGRAPH-4E00
      expect(scriptOf(0x0915), Script.deva); // DEVANAGARI LETTER KA
      expect(scriptOf(0x0995), Script.beng); // BENGALI LETTER KA
      expect(scriptOf(0x0E01), Script.thai); // THAI CHARACTER KO KAI
      expect(scriptOf(0x1780), Script.khmr); // KHMER LETTER KA
      expect(scriptOf(0x1000), Script.mymr); // MYANMAR LETTER KA
      expect(scriptOf(0x10330), Script.goth); // GOTHIC LETTER AHSA
      expect(scriptOf(0x0532), Script.armn); // ARMENIAN CAPITAL LETTER BEN
      expect(scriptOf(0x10A0), Script.geor); // GEORGIAN CAPITAL LETTER AN
    });

    test('the contextual and unknown values are what they should be', () {
      expect(scriptOf(0x0020), Script.zyyy); // SPACE
      expect(scriptOf(0x002C), Script.zyyy); // COMMA
      expect(scriptOf(0x0301), Script.zinh); // COMBINING ACUTE ACCENT
      expect(scriptOf(0x200D), Script.zinh); // ZERO WIDTH JOINER
      expect(scriptOf(0x0378), Script.zzzz); // reserved
      expect(scriptOf(0xE0000), Script.zzzz); // reserved
    });

    test('the ISO code survives the round trip through the enum', () {
      expect(Script.latn.code, 'Latn');
      expect(Script.arab.code, 'Arab');
      expect(Script.zyyy.code, 'Zyyy');
      expect(Script.hani.code, 'Hani');
    });

    test('Script_Extensions of a shared character lists its scripts', () {
      // U+064B ARABIC FATHATAN is Inherited, but only occurs in the Arabic
      // and Syriac families.
      expect(scriptOf(0x064B), Script.zinh);
      expect(hasScriptExtension(0x064B, Script.arab), isTrue);
      expect(hasScriptExtension(0x064B, Script.syrc), isTrue);
      expect(hasScriptExtension(0x064B, Script.latn), isFalse);

      // U+0640 ARABIC TATWEEL is Common with a restricted set.
      expect(scriptOf(0x0640), Script.zyyy);
      expect(hasScriptExtension(0x0640, Script.arab), isTrue);
      expect(hasScriptExtension(0x0640, Script.latn), isFalse);
    });

    test('a character with a real script extends to exactly that script', () {
      for (final int cp in <int>[0x0041, 0x05D0, 0x4E00, 0x0915]) {
        expect(scriptExtensionsOf(cp), <Script>[scriptOf(cp)]);
      }
    });

    test('Script_Extensions is never empty', () {
      for (int cp = 0; cp < _codeSpace; cp += 0x40) {
        expect(scriptExtensionsOf(cp), isNotEmpty, reason: 'at U+$cp');
      }
    });
  });

  group('Joining_Type and Joining_Group', () {
    test('the Arabic letters join the way the script does', () {
      // ALEF joins only on its right, which is why a word breaks after it.
      expect(joiningTypeOf(0x0627), JoiningType.rightJoining);
      expect(joiningGroupOf(0x0627), JoiningGroup.alef);
      // BEH joins on both sides and has four shapes.
      expect(joiningTypeOf(0x0628), JoiningType.dualJoining);
      expect(joiningGroupOf(0x0628), JoiningGroup.beh);
      // TEH and THEH share BEH's skeleton and differ only in dots.
      expect(joiningGroupOf(0x062A), JoiningGroup.beh);
      expect(joiningGroupOf(0x062B), JoiningGroup.beh);
    });

    test('the two join controls are what makes ligatures optional', () {
      // ZWJ forces the joined form; ZWNJ is not a joiner at all.
      expect(joiningTypeOf(0x200D), JoiningType.joinCausing);
      expect(joiningTypeOf(0x200C), JoiningType.nonJoining);
      // TATWEEL is the manual elongation and also join-causing.
      expect(joiningTypeOf(0x0640), JoiningType.joinCausing);
    });

    test('marks are transparent, so a join reaches across them', () {
      // Any nonspacing mark: without Transparent, a fatha between two letters
      // would break the connection.
      expect(joiningTypeOf(0x0301), JoiningType.transparent);
      expect(joiningTypeOf(0x064E), JoiningType.transparent);
      expect(joiningTypeOf(0x0670), JoiningType.transparent);
    });

    test('non-cursive characters do not join', () {
      expect(joiningTypeOf(0x0041), JoiningType.nonJoining);
      expect(joiningTypeOf(0x4E00), JoiningType.nonJoining);
      expect(joiningTypeOf(0x0378), JoiningType.nonJoining); // reserved
      expect(joiningGroupOf(0x0041), JoiningGroup.noJoiningGroup);
    });

    test('Syriac and Persian carry their own groups', () {
      expect(joiningGroupOf(0x0710), JoiningGroup.alaph); // SYRIAC ALAPH
      expect(joiningTypeOf(0x0710), JoiningType.rightJoining);
      expect(joiningGroupOf(0x06CC), JoiningGroup.farsiYeh);
      expect(joiningTypeOf(0x06CC), JoiningType.dualJoining);
    });
  });

  group('Word_Break', () {
    test('the classes a double-click depends on', () {
      expect(wordBreakOf(0x0041), WordBreak.aLetter);
      expect(wordBreakOf(0x0030), WordBreak.numeric);
      expect(wordBreakOf(0x05D0), WordBreak.hebrewLetter);
      expect(wordBreakOf(0x30A2), WordBreak.katakana);
      expect(wordBreakOf(0x0020), WordBreak.wSegSpace);
    });

    test('the punctuation that lives inside words', () {
      expect(wordBreakOf(0x0027), WordBreak.singleQuote); // don't
      expect(wordBreakOf(0x0022), WordBreak.doubleQuote);
      expect(wordBreakOf(0x002E), WordBreak.midNumLet); // 3.14
      expect(wordBreakOf(0x002C), WordBreak.midNum); // 1,000
      expect(wordBreakOf(0x00B7), WordBreak.midLetter);
      expect(wordBreakOf(0x005F), WordBreak.extendNumLet); // snake_case
    });

    test('the control and format classes', () {
      expect(wordBreakOf(0x000D), WordBreak.cr);
      expect(wordBreakOf(0x000A), WordBreak.lf);
      expect(wordBreakOf(0x000B), WordBreak.newline);
      expect(wordBreakOf(0x200D), WordBreak.zwj);
      expect(wordBreakOf(0x00AD), WordBreak.format); // SOFT HYPHEN
      expect(wordBreakOf(0x1F1E6), WordBreak.regionalIndicator);
    });

    test('characters outside the rules are Other', () {
      expect(wordBreakOf(0x4E00), WordBreak.other);
      expect(wordBreakOf(0x3042), WordBreak.other); // HIRAGANA A
      expect(wordBreakOf(0x0378), WordBreak.other); // reserved
    });
  });

  group('normalization', () {
    test('the textbook canonical decomposition', () {
      // U+00C5 LATIN CAPITAL LETTER A WITH RING ABOVE.
      expect(decompositionTypeOf(0x00C5), DecompositionType.canonical);
      expect(canonicalDecompositionOf(0x00C5), <int>[0x0041, 0x030A]);
      expect(decompositionOf(0x00C5), <int>[0x0041, 0x030A]);
      // U+00E9 e-acute, the character every search box gets wrong.
      expect(canonicalDecompositionOf(0x00E9), <int>[0x0065, 0x0301]);
    });

    test('decomposition is single-step, as the UCD stores it', () {
      // U+1E17 decomposes to U+0113 + U+0301, not to e + macron + acute. A
      // normalizer recurses; the table does not pretend to have done it.
      expect(canonicalDecompositionOf(0x1E17), <int>[0x0113, 0x0301]);
      expect(canonicalDecompositionOf(0x0113), <int>[0x0065, 0x0304]);
    });

    test('compatibility decompositions are kept out of the canonical one', () {
      // U+FB01 LATIN SMALL LIGATURE FI. Applying this under NFC would rewrite
      // text the caller never asked to change.
      expect(decompositionTypeOf(0xFB01), DecompositionType.compat);
      expect(decompositionOf(0xFB01), <int>[0x0066, 0x0069]);
      expect(canonicalDecompositionOf(0xFB01), isNull);
      // U+00A0 NO-BREAK SPACE is a no-break compatibility mapping.
      expect(decompositionTypeOf(0x00A0), DecompositionType.noBreak);
      expect(canonicalDecompositionOf(0x00A0), isNull);
      // The longest decomposition in the standard: U+FDFA, eighteen code
      // points, which is why the pool is flat rather than fixed width.
      expect(decompositionOf(0xFDFA)!.length, 18);
    });

    test('characters with no decomposition report none', () {
      expect(decompositionTypeOf(0x0041), DecompositionType.none);
      expect(decompositionOf(0x0041), isNull);
      expect(canonicalDecompositionOf(0x0041), isNull);
      expect(decompositionOf(0x0378), isNull);
    });

    test('Hangul is computed, and computed correctly', () {
      // The 11172 syllables are not in the table; the arithmetic replaces
      // them. AC00 is an LV syllable, AC01 an LVT one, and the UCD stores the
      // second as LV + T rather than as three jamo.
      expect(decompositionTypeOf(0xAC00), DecompositionType.canonical);
      expect(canonicalDecompositionOf(0xAC00), <int>[0x1100, 0x1161]);
      expect(canonicalDecompositionOf(0xAC01), <int>[0xAC00, 0x11A8]);
      expect(canonicalDecompositionOf(0xD7A3), <int>[0xD788, 0x11C2]);
      // One past the block is not a syllable.
      expect(canonicalDecompositionOf(0xD7A4), isNull);
      expect(decompositionTypeOf(0xD7A4), DecompositionType.none);
    });

    test('combining classes are the raw UCD numbers', () {
      expect(combiningClassOf(0x0301), 230); // above
      expect(combiningClassOf(0x0316), 220); // below
      expect(combiningClassOf(0x05B0), 10); // HEBREW POINT SHEVA
      expect(combiningClassOf(0x0334), 1); // overlay
      expect(combiningClassOf(0x3099), 8); // KATAKANA VOICED SOUND MARK
      expect(combiningClassOf(0x0041), 0); // a starter
      expect(combiningClassOf(0x0020), 0);
    });

    test('composition exclusions are flagged', () {
      // Singleton: U+2126 OHM SIGN decomposes to OMEGA and must not come
      // back.
      expect(canonicalDecompositionOf(0x2126), <int>[0x03A9]);
      expect(isFullCompositionExclusion(0x2126), isTrue);
      // Script-specific: U+0958 DEVANAGARI LETTER QA.
      expect(isFullCompositionExclusion(0x0958), isTrue);
      // Non-starter decomposition: U+0344.
      expect(isFullCompositionExclusion(0x0344), isTrue);
      // An ordinary composite is not excluded.
      expect(isFullCompositionExclusion(0x00C5), isFalse);
      expect(isFullCompositionExclusion(0x0041), isFalse);
    });

    test('the four quick-check properties are independent of each other', () {
      // A precomposed character is fine under NFC and wrong under NFD.
      expect(nfcQuickCheck(0x00C5), QuickCheck.yes);
      expect(nfdQuickCheck(0x00C5), QuickCheck.no);
      expect(nfkcQuickCheck(0x00C5), QuickCheck.yes);
      expect(nfkdQuickCheck(0x00C5), QuickCheck.no);
      // A compatibility ligature is fine under the canonical forms only.
      expect(nfcQuickCheck(0xFB01), QuickCheck.yes);
      expect(nfdQuickCheck(0xFB01), QuickCheck.yes);
      expect(nfkcQuickCheck(0xFB01), QuickCheck.no);
      expect(nfkdQuickCheck(0xFB01), QuickCheck.no);
      // A combining mark may or may not compose with what precedes it.
      expect(nfcQuickCheck(0x0301), QuickCheck.maybe);
      expect(nfdQuickCheck(0x0301), QuickCheck.yes);
      // Plain ASCII is fine everywhere.
      expect(nfcQuickCheck(0x0041), QuickCheck.yes);
      expect(nfkdQuickCheck(0x0041), QuickCheck.yes);
    });

    test('NFD and NFKD never answer Maybe', () {
      // Only the composing forms can be undecided. A Maybe here would send a
      // normalizer down a code path that does not exist.
      for (int cp = 0; cp < _codeSpace; cp += 0x11) {
        expect(nfdQuickCheck(cp), isNot(QuickCheck.maybe));
        expect(nfkdQuickCheck(cp), isNot(QuickCheck.maybe));
      }
    });
  });

  group('case mappings', () {
    test('the simple mappings', () {
      expect(simpleLowercaseOf(0x0041), 0x0061);
      expect(simpleUppercaseOf(0x0061), 0x0041);
      expect(simpleCaseFoldingOf(0x0041), 0x0061);
      expect(simpleUppercaseOf(0x03C3), 0x03A3); // sigma
      expect(simpleLowercaseOf(0x0410), 0x0430); // Cyrillic A
    });

    test('a character with no mapping maps to itself', () {
      expect(simpleUppercaseOf(0x0041), 0x0041);
      expect(simpleLowercaseOf(0x4E00), 0x4E00);
      expect(simpleTitlecaseOf(0x0020), 0x0020);
      expect(simpleCaseFoldingOf(0x0378), 0x0378);
    });

    test('titlecase is a third mapping, not a synonym for uppercase', () {
      // U+01C4 DZ with caron: upper is itself, title is U+01C5, lower is
      // U+01C6. A stack with only two mappings gets the middle one wrong.
      expect(simpleUppercaseOf(0x01C4), 0x01C4);
      expect(simpleTitlecaseOf(0x01C4), 0x01C5);
      expect(simpleLowercaseOf(0x01C4), 0x01C6);
      expect(simpleUppercaseOf(0x01C5), 0x01C4);
      expect(simpleTitlecaseOf(0x01C5), 0x01C5);
    });

    test('full mappings are longer than one code point', () {
      // U+00DF SHARP S uppercases to SS but has no simple uppercase.
      expect(simpleUppercaseOf(0x00DF), 0x00DF);
      expect(fullUppercaseOf(0x00DF), <int>[0x0053, 0x0053]);
      expect(fullCaseFoldingOf(0x00DF), <int>[0x0073, 0x0073]);
      // U+FB00 LATIN SMALL LIGATURE FF.
      expect(fullUppercaseOf(0xFB00), <int>[0x0046, 0x0046]);
      expect(fullCaseFoldingOf(0xFB00), <int>[0x0066, 0x0066]);
      // U+0130 CAPITAL I WITH DOT: folds to two code points, and its simple
      // fold is itself.
      expect(fullCaseFoldingOf(0x0130), <int>[0x0069, 0x0307]);
      expect(simpleCaseFoldingOf(0x0130), 0x0130);
    });

    test('null from a full mapping means "use the simple one"', () {
      // The calling convention, and the reason there is no allocation per
      // character in the common case.
      expect(fullUppercaseOf(0x0061), isNull);
      expect(simpleUppercaseOf(0x0061), 0x0041);
      expect(fullLowercaseOf(0x0041), isNull);
      expect(fullTitlecaseOf(0x4E00), isNull);
      expect(fullCaseFoldingOf(0x0041), isNull);
      // U+0345 has a full uppercase spelled out in the UCD that says nothing
      // its simple uppercase does not, and is dropped for that reason.
      expect(simpleUppercaseOf(0x0345), 0x0399);
      expect(fullUppercaseOf(0x0345), isNull);
    });

    test('a full mapping never repeats the simple one', () {
      for (int cp = 0; cp < _codeSpace; cp += 0x7) {
        final List<int>? full = fullUppercaseOf(cp);
        if (full != null && full.length == 1) {
          expect(
            full.first,
            isNot(simpleUppercaseOf(cp)),
            reason: 'U+${cp.toRadixString(16)} stores a redundant mapping',
          );
        }
      }
    });
  });

  group('Indic categories', () {
    test('the categories a reordering shaper switches on', () {
      expect(
        indicSyllabicCategoryOf(0x094D),
        IndicSyllabicCategory.virama,
      ); // DEVANAGARI SIGN VIRAMA
      expect(
        indicSyllabicCategoryOf(0x0915),
        IndicSyllabicCategory.consonant,
      );
      expect(
        indicSyllabicCategoryOf(0x093C),
        IndicSyllabicCategory.nukta,
      );
      expect(
        indicSyllabicCategoryOf(0x0905),
        IndicSyllabicCategory.vowelIndependent,
      );
      expect(
        indicSyllabicCategoryOf(0x093F),
        IndicSyllabicCategory.vowelDependent,
      );
      expect(indicSyllabicCategoryOf(0x200D), IndicSyllabicCategory.joiner);
      expect(indicSyllabicCategoryOf(0x200C), IndicSyllabicCategory.nonJoiner);
    });

    test('the positions that decide where a sign is drawn', () {
      // U+093F VOWEL SIGN I is stored after its consonant and drawn before
      // it. This value is what tells the shaper to move it.
      expect(indicPositionalCategoryOf(0x093F), IndicPositionalCategory.left);
      expect(indicPositionalCategoryOf(0x0940), IndicPositionalCategory.right);
      expect(indicPositionalCategoryOf(0x0941), IndicPositionalCategory.bottom);
      expect(indicPositionalCategoryOf(0x0945), IndicPositionalCategory.top);
    });

    test('everything outside the Brahmic scripts is Other and NA', () {
      expect(indicSyllabicCategoryOf(0x0041), IndicSyllabicCategory.other);
      expect(indicPositionalCategoryOf(0x0041), IndicPositionalCategory.na);
      expect(indicSyllabicCategoryOf(0x0378), IndicSyllabicCategory.other);
    });
  });

  group('Vertical_Orientation', () {
    test('ideographs stay upright and Latin rotates', () {
      expect(verticalOrientationOf(0x4E00), VerticalOrientation.upright);
      expect(verticalOrientationOf(0x30A2), VerticalOrientation.upright);
      expect(verticalOrientationOf(0x0041), VerticalOrientation.rotated);
      expect(verticalOrientationOf(0x00C5), VerticalOrientation.rotated);
    });

    test('the transformed values name the ones the font has to help with', () {
      // U+3001 IDEOGRAPHIC COMMA moves to a different position rather than
      // turning, which only the font can do.
      expect(
        verticalOrientationOf(0x3001),
        VerticalOrientation.transformedUpright,
      );
      expect(
        verticalOrientationOf(0x2329),
        VerticalOrientation.transformedRotated,
      );
    });

    test('the block defaults reach unassigned code points', () {
      // The default is Rotated across most of the code space but Upright
      // inside the CJK blocks, including their holes. Getting this from the
      // derived data rather than from block ranges is the whole point.
      expect(verticalOrientationOf(0x0378), VerticalOrientation.rotated);
      expect(verticalOrientationOf(0x1F600), VerticalOrientation.upright);
    });
  });

  group('mirroring and paired brackets', () {
    test('the brackets mirror and pair', () {
      expect(isMirrored(0x0028), isTrue);
      expect(mirrorOf(0x0028), 0x0029);
      expect(mirrorOf(0x0029), 0x0028);
      expect(bracketTypeOf(0x0028), BracketType.open);
      expect(bracketTypeOf(0x0029), BracketType.close);
      expect(pairedBracketOf(0x0028), 0x0029);
      expect(pairedBracketOf(0x0029), 0x0028);
      expect(pairedBracketOf(0x005B), 0x005D);
      expect(pairedBracketOf(0x007B), 0x007D);
    });

    test('mirrored is not the same question as paired', () {
      // U+003C LESS-THAN mirrors but is not a bracket: N0 must not pair it.
      expect(isMirrored(0x003C), isTrue);
      expect(mirrorOf(0x003C), 0x003E);
      expect(bracketTypeOf(0x003C), BracketType.none);
      expect(pairedBracketOf(0x003C), -1);
    });

    test('a character can be mirrored with no mirror glyph', () {
      // U+2226 NOT PARALLEL TO. A renderer that only checks [mirrorOf] skips
      // it silently; this is the case that makes both accessors necessary.
      expect(isMirrored(0x2226), isTrue);
      expect(mirrorOf(0x2226), 0x2226);
    });

    test('ordinary characters mirror nothing and pair with nothing', () {
      expect(isMirrored(0x0041), isFalse);
      expect(mirrorOf(0x0041), 0x0041);
      expect(bracketTypeOf(0x0041), BracketType.none);
      expect(pairedBracketOf(0x0041), -1);
      expect(pairedBracketOf(0x0378), -1);
    });

    test('every pairing is symmetric', () {
      // An asymmetric pair would make N0 match a bracket with something that
      // does not match it back.
      for (int cp = 0; cp < _codeSpace; cp++) {
        final int pair = pairedBracketOf(cp);
        if (pair < 0) continue;
        expect(pairedBracketOf(pair), cp, reason: 'U+${cp.toRadixString(16)}');
        expect(
          bracketTypeOf(pair),
          bracketTypeOf(cp) == BracketType.open
              ? BracketType.close
              : BracketType.open,
        );
      }
    });
  });

  group('table invariants', () {
    test('the range tables cover the whole code space', () {
      // No holes, no fallback, no "unknown character" branch: that is what
      // makes the lookups bounds-check-free. A hole would decode without
      // complaint and answer wrongly for everything inside it.
      for (int cp = 0; cp < _codeSpace; cp++) {
        expect(scriptOf(cp), isNotNull);
      }
      for (int cp = 0; cp < _codeSpace; cp += 0x3) {
        expect(joiningTypeOf(cp), isNotNull);
        expect(wordBreakOf(cp), isNotNull);
        expect(verticalOrientationOf(cp), isNotNull);
        expect(indicSyllabicCategoryOf(cp), isNotNull);
      }
    });

    test('combining classes stay inside the byte the UCD uses', () {
      for (int cp = 0; cp < _codeSpace; cp += 0x3) {
        final int ccc = combiningClassOf(cp);
        expect(ccc, inInclusiveRange(0, 254));
      }
    });

    test('the packed normalization flags do not bleed into each other', () {
      // Six properties share one word. A wrong shift would show up as a
      // decomposition type that tracks a quick-check value.
      int canonical = 0;
      int excluded = 0;
      for (int cp = 0; cp < _codeSpace; cp++) {
        if (decompositionTypeOf(cp) == DecompositionType.canonical) {
          canonical++;
          // Every canonical decomposition has a mapping, and nothing else in
          // the code space does.
          expect(canonicalDecompositionOf(cp), isNotNull);
        } else {
          expect(canonicalDecompositionOf(cp), isNull);
        }
        if (isFullCompositionExclusion(cp)) excluded++;
      }
      // Sanity bounds rather than exact counts, which would just restate the
      // table: 11172 Hangul syllables plus a few thousand composites, and far
      // fewer exclusions than composites.
      expect(canonical, greaterThan(11172));
      expect(excluded, greaterThan(0));
      expect(excluded, lessThan(canonical));
    });

    test('every decomposition maps to real code points', () {
      for (int cp = 0; cp < _codeSpace; cp++) {
        final List<int>? mapping = decompositionOf(cp);
        if (mapping == null) continue;
        expect(mapping, isNotEmpty, reason: 'U+${cp.toRadixString(16)}');
        for (final int component in mapping) {
          expect(component, inInclusiveRange(0, 0x10FFFF));
          expect(component, isNot(cp), reason: 'a decomposition to itself');
        }
      }
    });

    test('every case mapping maps to real code points', () {
      for (int cp = 0; cp < _codeSpace; cp++) {
        for (final int mapped in <int>[
          simpleUppercaseOf(cp),
          simpleLowercaseOf(cp),
          simpleTitlecaseOf(cp),
          simpleCaseFoldingOf(cp),
        ]) {
          expect(mapped, inInclusiveRange(0, 0x10FFFF));
        }
        for (final List<int>? mapping in <List<int>?>[
          fullUppercaseOf(cp),
          fullLowercaseOf(cp),
          fullTitlecaseOf(cp),
          fullCaseFoldingOf(cp),
        ]) {
          if (mapping == null) continue;
          expect(mapping, isNotEmpty);
          for (final int component in mapping) {
            expect(component, inInclusiveRange(0, 0x10FFFF));
          }
        }
      }
    });

    test('the pooled sequences are unmodifiable views', () {
      // They are slices of one shared buffer, so a writable view would let
      // one caller corrupt the table for every later one.
      expect(
        () => decompositionOf(0x00C5)!.add(0),
        throwsUnsupportedError,
      );
      expect(
        () => fullUppercaseOf(0x00DF)![0] = 0,
        throwsUnsupportedError,
      );
    });
  });
}
