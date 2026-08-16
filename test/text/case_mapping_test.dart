/// Case conversion and case folding (UAX #21 and the UCD case mappings).
///
/// **There is no conformance suite here.** `referencias/unicode/` carries the
/// grapheme and line-breaking test files and neither `SpecialCasing.txt` nor
/// `CaseFolding.txt`; the mappings themselves come from the generated table,
/// which `test/text/unicode_tables_test.dart` already checks against the UCD.
/// What is tested here is the *algorithm* on top of them - full mappings,
/// word-driven title case, folding - with cases taken from UAX #21 and from
/// the characters that are famous for breaking naive implementations. The one
/// file that would add real coverage is `CaseFolding.txt`, which would let the
/// fold be checked code point by code point.
///
/// Several tests below assert results that are **wrong for a human language**
/// and right for this implementation - the final sigma, above all. They are
/// written as tests so that the day someone adds `SpecialCasing.txt` the suite
/// tells them exactly which promises change.
library;

import 'package:dart_ui/src/text/case_mapping.dart';
import 'package:dart_ui/src/text/normalize.dart';
import 'package:test/test.dart';

String hex(String text) => text.runes
    .map(
      (int rune) => 'U+${rune.toRadixString(16).toUpperCase().padLeft(4, '0')}',
    )
    .join(' ');

void main() {
  group('upper case', () {
    test('ASCII, and unchanged text is returned identically', () {
      expect(toUpperCase('hello'), 'HELLO');
      expect(
        identical(toUpperCase('HELLO'), 'HELLO'),
        isTrue,
        reason: 'text that is already upper case must not be copied',
      );
    });

    test('sharp s becomes two letters', () {
      // U+00DF. The canonical example of a full mapping: one code point in,
      // two out, and Dart's own toUpperCase leaves it alone.
      expect(toUpperCase('straße'), 'STRASSE');
      expect(toUpperCase('ß').length, 2);
      expect('ß'.toUpperCase(), 'ß',
          reason: 'the platform mapping is the thing this file exists to fix');
    });

    test('a ligature becomes its letters', () {
      expect(toUpperCase('ﬁ'), 'FI');
      expect(toUpperCase('ﬃ'), 'FFI');
      // U+FB05 LATIN SMALL LIGATURE LONG S T.
      expect(toUpperCase('ﬅ'), 'ST');
    });

    test('the result can be longer than the input, and offsets move', () {
      const String text = 'aßb';
      expect(text.length, 3);
      expect(toUpperCase(text).length, 4);
    });

    test('an astral letter has a case too', () {
      // U+10400 DESERET CAPITAL LETTER LONG I lowercases to U+10428. A mapping
      // that worked on UTF-16 units would look up a lone surrogate and find
      // nothing.
      expect(toLowerCase('\u{10400}'), '\u{10428}');
      expect(toUpperCase('\u{10428}'), '\u{10400}');
    });

    test('an unpaired surrogate is passed through', () {
      expect(toUpperCase('a\uD800b'), 'A\uD800B');
    });
  });

  group('lower case', () {
    test('ASCII', () {
      expect(toLowerCase('HELLO'), 'hello');
      expect(identical(toLowerCase('hello'), 'hello'), isTrue);
    });

    test('dotted capital I lowercases to i plus a combining dot', () {
      // U+0130 is the one character whose full lowercase mapping differs from
      // its simple one: i + U+0307, so that the dot survives the round trip.
      expect(toLowerCase('İ'), 'i̇');
      expect(toLowerCase('İ').length, 2);
    });

    test('final sigma is NOT implemented, and this records it', () {
      // The correct lowercase of U+039F U+0394 U+039F U+03A3 ends in U+03C2
      // FINAL SIGMA. Without SpecialCasing.txt there is no way to know that a
      // sigma is word-final, so it comes out as U+03C3. Declared in the
      // library comment; asserted here so the gap is visible rather than
      // folklore.
      expect(hex(toLowerCase('ΟΔΟΣ')), 'U+03BF U+03B4 U+03BF U+03C3');
      expect(toLowerCase('ΟΔΟΣ').endsWith('ς'), isFalse,
          reason: 'this is the documented defect, not a passing behaviour');
    });
  });

  group('title case', () {
    test('one word per boundary, not per space', () {
      expect(toTitleCase('hello world'), 'Hello World');
      expect(toTitleCase(''), '');
      expect(toTitleCase('a'), 'A');
    });

    test('an apostrophe does not start a new word', () {
      // This is why title casing needs UAX #29 and not `split(' ')`: the
      // segmenter keeps `can't` in one piece, so the `t` is not capitalised.
      expect(toTitleCase("can't"), "Can't");
      expect(toTitleCase("o'clock"), "O'clock");
    });

    test('a hyphen does', () {
      expect(toTitleCase('jean-luc'), 'Jean-Luc');
    });

    test('leading punctuation is skipped, not capitalised', () {
      expect(toTitleCase('(hello)'), '(Hello)');
      expect(toTitleCase('"quoted"'), '"Quoted"');
    });

    test('a number in a word does not reset the case', () {
      expect(toTitleCase('3.14 abc'), '3.14 Abc');
    });

    test('a digraph gets its own title case, not its upper case', () {
      // U+01C6 lowercase dz-caron. Upper is U+01C4, *title* is U+01C5, and
      // they are three different characters - which is the whole reason a
      // separate title mapping exists.
      expect(toTitleCase('ǆungla'), 'ǅungla');
      expect(toUpperCase('ǆungla'), 'ǄUNGLA');
    });

    test('everything after the first cased character is lowercased', () {
      // UAX #21's definition, and the reason title case is not a spelling
      // corrector: `MacDonald` becomes `Macdonald`.
      expect(toTitleCase('MacDonald'), 'Macdonald');
      expect(toTitleCase('IBM'), 'Ibm');
    });

    test('a combining mark stays with its letter', () {
      expect(toTitleCase('ábc'), 'Ábc');
    });
  });

  group('case folding', () {
    test('folding makes two spellings of one word compare equal', () {
      expect(caseFold('STRASSE'), caseFold('straße'));
      expect(caseFold('straße'), 'strasse');
      // And lowercasing does not, which is why folding exists.
      expect(toLowerCase('STRASSE') == toLowerCase('straße'), isFalse);
    });

    test('capital sharp s folds with the small one', () {
      // U+1E9E folds to `ss` under full folding and to U+00DF under simple.
      expect(caseFold('ẞ'), 'ss');
      expect(caseFold('ẞ', full: false), 'ß');
    });

    test('simple folding keeps the length and loses the equivalence', () {
      // U+FB05 and U+FB06 are the two spellings of the st ligature. Simple
      // folding maps one onto the other; full folding takes both to `st`.
      expect(caseFold('ﬅ', full: false), 'ﬆ');
      expect(caseFold('ﬆ', full: false), 'ﬆ');
      expect(caseFold('ﬅ'), 'st');
      expect(caseFold('ﬆ'), 'st');
    });

    test('both sigmas fold to the same letter', () {
      // The defect in [toLowerCase] cannot affect a comparison done through
      // the fold, which is the reason the library comment sends callers here.
      expect(caseFold('Σ'), caseFold('ς'));
      expect(caseFold('σ'), caseFold('ς'));
    });

    test('folding is not a substitute for normalizing', () {
      // Two spellings of the same accented letter fold to two different
      // strings; the caller has to normalize as well, exactly as the doc
      // comment says.
      expect(caseFold('É') == caseFold('É'), isFalse);
      expect(caseFold(nfc('É')), caseFold(nfc('É')));
      expect(caseFold(nfd('É')), caseFold(nfd('É')));
    });

    test('text with no case is returned identically', () {
      expect(identical(caseFold('12 一'), '12 一'), isTrue);
    });
  });

  group('locales that need SpecialCasing.txt', () {
    test('the root locale and ordinary tags are accepted', () {
      expect(toUpperCase('i', locale: null), 'I');
      expect(toUpperCase('i', locale: 'en-US'), 'I');
      expect(toUpperCase('i', locale: 'pt_BR'), 'I');
      expect(toLowerCase('I', locale: 'de'), 'i');
    });

    test('Turkish, Azeri and Lithuanian are refused, not guessed', () {
      // The Turkish dotless I is the classic identifier-comparison hole: an
      // implementation that silently returns the root mapping reports that
      // `I` and `i` are the same letter in a language where they are not.
      for (final String locale in <String>['tr', 'tr-TR', 'TR', 'az', 'lt']) {
        expect(
          () => toUpperCase('i', locale: locale),
          throwsA(isA<UnsupportedCaseLocaleError>()),
          reason: locale,
        );
      }
      expect(() => toLowerCase('I', locale: 'tr'),
          throwsA(isA<UnsupportedCaseLocaleError>()));
      expect(() => toTitleCase('i', locale: 'az'),
          throwsA(isA<UnsupportedCaseLocaleError>()));
      expect(() => caseFold('I', locale: 'tr'),
          throwsA(isA<UnsupportedCaseLocaleError>()));
    });

    test('the three-letter language codes are refused too', () {
      expect(() => toUpperCase('i', locale: 'tur'),
          throwsA(isA<UnsupportedCaseLocaleError>()));
      expect(() => toUpperCase('i', locale: 'lit-LT'),
          throwsA(isA<UnsupportedCaseLocaleError>()));
    });

    test('the error names the locale and the missing data', () {
      // Section 6.6: a diagnostic that says only "unsupported" sends the
      // reader looking in the wrong file.
      final Object error = () {
        try {
          toUpperCase('i', locale: 'tr');
        } catch (e) {
          return e;
        }
        return 'no error';
      }();
      expect(error.toString(), contains('tr'));
      expect(error.toString(), contains('SpecialCasing.txt'));
      expect(error.toString(), contains('toUpperCase'));
    });

    test('warn reports once per call and returns the root result', () {
      final List<String> messages = <String>[];
      final void Function(String) saved = caseMappingWarningHandler;
      caseMappingWarningHandler = messages.add;
      addTearDown(() => caseMappingWarningHandler = saved);

      expect(
        toUpperCase(
          'iii',
          locale: 'tr',
          onUnsupportedLocale: LocaleHandling.warn,
        ),
        'III',
      );
      expect(messages, hasLength(1), reason: 'once per call, not per letter');
      expect(messages.single, contains('SpecialCasing.txt'));
      expect(messages.single, contains('tr'));
    });
  });

  group('isCased', () {
    test('letters with a mapping are cased, punctuation is not', () {
      expect(isCased(0x61), isTrue);
      expect(isCased(0x41), isTrue);
      expect(isCased(0x01C5), isTrue, reason: 'the digraph title case');
      expect(isCased(0x20), isFalse);
      expect(isCased(0x33), isFalse);
      expect(isCased(0x4E00), isFalse, reason: 'an ideograph has no case');
      expect(isCased(0x0301), isFalse, reason: 'a combining mark has no case');
    });
  });
}
