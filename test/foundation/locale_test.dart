/// A language tag as a value: parsed, normalized, compared and resolved.
///
/// Four separate claims live here, and each of them is a bug that costs a
/// whole language when it is wrong:
///
///  * a tag round-trips, so writing one down and reading it back is lossless;
///  * case is normalized, so `pt_br` and `pt-BR` are one value and not two
///    that compare unequal and resolve to different things;
///  * a tag that cannot be read is a **named** error and never a `Locale('')`,
///    which would compare unequal to everything and surface far from its
///    cause;
///  * resolution falls back by language, so `pt-PT` requested against a build
///    that only ships `pt-BR` is Portuguese rather than English.
library;

import 'package:dart_ui/src/foundation/locale.dart';
import 'package:test/test.dart';

void main() {
  group('parsing and round-trip', () {
    test('the four shapes a tag comes in', () {
      final Locale bare = Locale.parse('ar');
      expect(bare.languageCode, 'ar');
      expect(bare.scriptCode, isNull);
      expect(bare.countryCode, isNull);

      final Locale regional = Locale.parse('pt-BR');
      expect(regional.languageCode, 'pt');
      expect(regional.scriptCode, isNull);
      expect(regional.countryCode, 'BR');

      final Locale full = Locale.parse('zh-Hant-TW');
      expect(full.languageCode, 'zh');
      expect(full.scriptCode, 'Hant');
      expect(full.countryCode, 'TW');

      // A script with no region, which the grammar has to distinguish from a
      // region with no script purely by subtag shape.
      final Locale scripted = Locale.parse('sr-Latn');
      expect(scripted.scriptCode, 'Latn');
      expect(scripted.countryCode, isNull);
    });

    test('toLanguageTag reproduces the tag exactly', () {
      for (final String tag in <String>[
        'en',
        'ar',
        'pt-BR',
        'zh-Hant-TW',
        'sr-Latn',
        'es-419',
        'und',
      ]) {
        expect(Locale.parse(tag).toLanguageTag(), tag, reason: tag);
        // toString is the tag, so a locale interpolated into a log line is
        // something the reader can paste back into Locale.parse.
        expect(Locale.parse(tag).toString(), tag, reason: tag);
        // And it survives a second trip, which is what makes it canonical
        // rather than merely stable.
        expect(
          Locale.parse(Locale.parse(tag).toLanguageTag()),
          Locale.parse(tag),
          reason: tag,
        );
      }
    });

    test('a UN M.49 region is three digits and is not a language', () {
      final Locale latinAmerica = Locale.parse('es-419');
      expect(latinAmerica.countryCode, '419');
      expect(latinAmerica.toLanguageTag(), 'es-419');
    });

    test('an underscore separator is accepted, because POSIX produces it', () {
      expect(Locale.parse('pt_BR'), Locale.parse('pt-BR'));
      expect(Locale.parse('zh_Hant_TW'), Locale.parse('zh-Hant-TW'));
      // ... and it is *normalized away*, so the two spellings are one value
      // and one string.
      expect(Locale.parse('pt_BR').toLanguageTag(), 'pt-BR');
    });
  });

  group('case normalization', () {
    test('language lowers, script titles, region uppers', () {
      final Locale locale = Locale.parse('ZH-hANT-tw');
      expect(locale.languageCode, 'zh');
      expect(locale.scriptCode, 'Hant');
      expect(locale.countryCode, 'TW');
      expect(locale.toLanguageTag(), 'zh-Hant-TW');
    });

    test('the constructor normalizes too, not only the parser', () {
      // The important half: a locale built from subtags read out of three
      // different places must not compare unequal to a parsed one.
      expect(Locale('PT', null, 'br'), Locale.parse('pt-BR'));
      expect(Locale('ZH', 'hant', 'tw'), Locale.parse('zh-Hant-TW'));
    });

    test('equal locales hash equally, so a Set and a Map agree with ==', () {
      final Set<Locale> seen = <Locale>{
        Locale.parse('pt-br'),
        Locale.parse('PT-BR'),
        Locale('pt', null, 'BR'),
      };
      expect(seen, hasLength(1));
      expect(
        Locale.parse('pt-br').hashCode,
        Locale.parse('PT-BR').hashCode,
      );
    });

    test('locales that really differ stay different', () {
      expect(Locale.parse('pt-BR'), isNot(Locale.parse('pt-PT')));
      expect(Locale.parse('pt'), isNot(Locale.parse('pt-BR')));
      expect(Locale.parse('zh-Hans'), isNot(Locale.parse('zh-Hant')));
    });

    test('languageOnly drops the narrowing subtags and nothing else', () {
      expect(Locale.parse('zh-Hant-TW').languageOnly, Locale.parse('zh'));
      // Already bare: the same instance, so the common case allocates nothing.
      final Locale bare = Locale.parse('zh');
      expect(identical(bare.languageOnly, bare), isTrue);
    });
  });

  group('a malformed tag fails by name', () {
    test('the empty string is refused rather than becoming an empty locale',
        () {
      expect(
        () => Locale.parse(''),
        throwsA(
          isA<MalformedLanguageTagError>().having(
            (MalformedLanguageTagError error) => error.reason,
            'reason',
            contains('empty'),
          ),
        ),
      );
    });

    test('a one-letter or non-alphabetic language subtag', () {
      for (final String tag in <String>['e', '1', '12', 'p7', 'toolonglang']) {
        expect(
          () => Locale.parse(tag),
          throwsA(isA<MalformedLanguageTagError>()),
          reason: tag,
        );
      }
    });

    test('the error names the tag, the subtag and the rule', () {
      Object? caught;
      try {
        Locale.parse('en-Latn-US-x-private');
      } catch (error) {
        caught = error;
      }
      final MalformedLanguageTagError error =
          caught! as MalformedLanguageTagError;
      expect(error.tag, 'en-Latn-US-x-private');
      expect(error.subtag, 'x');
      // The message is what gets pasted into an issue, so it has to be
      // actionable on its own.
      expect(
        error.toString(),
        allOf(
          contains('en-Latn-US-x-private'),
          contains('private use'),
          contains('Locale.tryParse'),
        ),
      );
    });

    test('a well-formed BCP 47 variant is refused rather than truncated', () {
      // de-DE-1901 is legal BCP 47. Silently dropping "1901" would produce a
      // locale that says it is de-DE and is not, which is worse than a throw.
      expect(
        () => Locale.parse('de-DE-1901'),
        throwsA(isA<MalformedLanguageTagError>()),
      );
      expect(
        () => Locale.parse('th-TH-u-ca-buddhist'),
        throwsA(isA<MalformedLanguageTagError>()),
      );
    });

    test('a charset suffix is not silently ignored', () {
      // POSIX LANG values carry one, and pt_BR.UTF-8 and pt_BR.ISO-8859-1 mean
      // different things to whoever wrote them.
      expect(
        () => Locale.parse('pt_BR.UTF-8'),
        throwsA(isA<MalformedLanguageTagError>()),
      );
    });

    test('the constructor validates its subtags separately', () {
      expect(
        () => Locale('en', 'Lat'),
        throwsA(
          isA<MalformedLanguageTagError>().having(
            (MalformedLanguageTagError error) => error.subtag,
            'subtag',
            'Lat',
          ),
        ),
      );
      expect(() => Locale('en', null, 'USA'), throwsA(isA<Object>()));
      expect(() => Locale('en', null, '4'), throwsA(isA<Object>()));
    });

    test('tryParse answers null where parse throws', () {
      expect(Locale.tryParse('de-DE-1901'), isNull);
      expect(Locale.tryParse(''), isNull);
      expect(Locale.tryParse('pt-BR'), Locale.parse('pt-BR'));
    });

    test('und is a real value, not a null stand-in', () {
      expect(Locale.undetermined.languageCode, 'und');
      expect(Locale.undetermined, Locale.parse('und'));
      expect(Locale.undetermined.toLanguageTag(), 'und');
    });
  });

  group('reading direction', () {
    test('the four right-to-left languages an application meets first', () {
      for (final String tag in <String>['ar', 'he', 'fa', 'ur']) {
        expect(Locale.parse(tag).isRightToLeft, isTrue, reason: tag);
        expect(Locale.parse(tag).isLeftToRight, isFalse, reason: tag);
      }
      // With a region, which must not change the answer.
      for (final String tag in <String>['ar-EG', 'he-IL', 'fa-IR', 'ur-PK']) {
        expect(Locale.parse(tag).isRightToLeft, isTrue, reason: tag);
      }
    });

    test('the wider set: Pashto, Sindhi, Uyghur, Divehi, Syriac, N Ko', () {
      for (final String tag in <String>['ps', 'sd', 'ug', 'dv', 'syr', 'nqo']) {
        expect(Locale.parse(tag).isRightToLeft, isTrue, reason: tag);
      }
    });

    test('three-letter and legacy codes are answered as firmly', () {
      for (final String tag in <String>['ara', 'heb', 'fas', 'urd', 'iw']) {
        expect(Locale.parse(tag).isRightToLeft, isTrue, reason: tag);
      }
    });

    test('latin, cyrillic and CJK languages are left to right', () {
      for (final String tag in <String>[
        'en',
        'pt-BR',
        'de',
        'fr',
        'tr',
        'ru',
        'el',
        'ja',
        'zh-Hant-TW',
        'ko',
        'hi',
        'th',
        'und',
      ]) {
        expect(Locale.parse(tag).isLeftToRight, isTrue, reason: tag);
      }
    });

    test('the script subtag decides, and outranks the language', () {
      // The pair the whole design is for: one language, two scripts, two
      // directions. A language-only table gets one of these wrong whichever
      // way it is filled in.
      expect(Locale.parse('az-Arab').isRightToLeft, isTrue);
      expect(Locale.parse('az-Latn').isLeftToRight, isTrue);
      expect(Locale.parse('ku-Arab').isRightToLeft, isTrue);
      expect(Locale.parse('ku-Latn').isLeftToRight, isTrue);
      expect(Locale.parse('pa-Arab').isRightToLeft, isTrue);
      expect(Locale.parse('pa-Guru').isLeftToRight, isTrue);
      // And in the other direction: Arabic written in Latin transliteration is
      // left to right, however unusual the tag is.
      expect(Locale.parse('ar-Latn').isLeftToRight, isTrue);
    });

    test('the declared data is reachable, so the source can be checked', () {
      expect(rightToLeftScripts, contains('Arab'));
      expect(rightToLeftScripts, contains('Hebr'));
      expect(rightToLeftScripts, contains('Thaa'));
      expect(rightToLeftScripts, isNot(contains('Latn')));
      expect(rightToLeftScripts, isNot(contains('Cyrl')));
      // Title case throughout, matching the normalization Locale applies, or
      // every lookup would silently miss.
      for (final String script in rightToLeftScripts) {
        expect(script.length, 4, reason: script);
        expect(script, script[0].toUpperCase() + script.substring(1),
            reason: script);
      }
      // Lower case throughout, for the same reason.
      for (final String language in rightToLeftLanguages) {
        expect(language, language.toLowerCase(), reason: language);
        expect(language.length, inInclusiveRange(2, 3), reason: language);
      }
    });
  });

  group('locale resolution', () {
    final List<Locale> supported = <Locale>[
      Locale.parse('en'),
      Locale.parse('en-GB'),
      Locale.parse('pt-BR'),
      Locale.parse('zh-Hans-CN'),
      Locale.parse('zh-Hant-HK'),
    ];

    test('step 1: an exact match wins', () {
      expect(
        resolveLocale(<Locale>[Locale.parse('pt-BR')], supported),
        Locale.parse('pt-BR'),
      );
      expect(
        resolveLocale(<Locale>[Locale.parse('en-GB')], supported),
        Locale.parse('en-GB'),
      );
    });

    test('step 2: script beats region', () {
      // A reader of Traditional characters handed Simplified cannot read the
      // screen; a Hong Kong spelling of a Taiwanese string is merely off.
      expect(
        resolveLocale(<Locale>[Locale.parse('zh-Hant-TW')], supported),
        Locale.parse('zh-Hant-HK'),
      );
      expect(
        resolveLocale(<Locale>[Locale.parse('zh-Hans-SG')], supported),
        Locale.parse('zh-Hans-CN'),
      );
    });

    test('step 3: region matches when the script does not narrow it', () {
      final List<Locale> byRegion = <Locale>[
        Locale.parse('sr-Latn-RS'),
        Locale.parse('sr-RS'),
      ];
      expect(
        resolveLocale(<Locale>[Locale.parse('sr-RS')], byRegion),
        Locale.parse('sr-RS'),
      );
    });

    test('step 4: pt-PT resolves to pt-BR, which is the whole point', () {
      expect(
        resolveLocale(<Locale>[Locale.parse('pt-PT')], supported),
        Locale.parse('pt-BR'),
      );
      expect(
        resolveLocale(<Locale>[Locale.parse('pt')], supported),
        Locale.parse('pt-BR'),
      );
    });

    test('step 4 prefers the generic entry over a narrowed one', () {
      // en-AU matches no exact and no region, so the language step runs; the
      // bare `en` beats `en-GB` because it claims nothing it cannot deliver.
      expect(
        resolveLocale(<Locale>[Locale.parse('en-AU')], supported),
        Locale.parse('en'),
      );
    });

    test('with no generic entry the supported order breaks the tie', () {
      final List<Locale> onlyRegional = <Locale>[
        Locale.parse('pt-PT'),
        Locale.parse('pt-BR'),
      ];
      expect(
        resolveLocale(<Locale>[Locale.parse('pt-AO')], onlyRegional),
        Locale.parse('pt-PT'),
      );
      expect(
        resolveLocale(
          <Locale>[Locale.parse('pt-AO')],
          onlyRegional.reversed.toList(),
        ),
        Locale.parse('pt-BR'),
      );
    });

    test('a preferred locale is exhausted before the next one is tried', () {
      // "Close enough in the right language" beats "exact in the wrong one":
      // pt-PT must not lose to an exact en-GB later in the preference list.
      expect(
        resolveLocale(
          <Locale>[Locale.parse('pt-PT'), Locale.parse('en-GB')],
          supported,
        ),
        Locale.parse('pt-BR'),
      );
      // ... and the second preference is used when the first cannot be served.
      expect(
        resolveLocale(
          <Locale>[Locale.parse('ja'), Locale.parse('en-GB')],
          supported,
        ),
        Locale.parse('en-GB'),
      );
    });

    test('no possible fallback is null, not a silent first entry', () {
      expect(resolveLocale(<Locale>[Locale.parse('ja')], supported), isNull);
      expect(
        resolveLocale(
          <Locale>[Locale.parse('ja'), Locale.parse('ko')],
          supported,
        ),
        isNull,
      );
      // An empty catalogue cannot serve anything, including a locale that
      // would otherwise match itself.
      expect(
        resolveLocale(<Locale>[Locale.parse('en')], const <Locale>[]),
        isNull,
      );
      // An empty request likewise.
      expect(resolveLocale(const <Locale>[], supported), isNull);
    });

    test('resolveLocaleOrThrow names both lists', () {
      expect(
        resolveLocaleOrThrow(<Locale>[Locale.parse('pt-PT')], supported),
        Locale.parse('pt-BR'),
      );
      expect(
        () => resolveLocaleOrThrow(<Locale>[Locale.parse('ja')], supported),
        throwsA(
          isA<UnresolvedLocaleError>().having(
            (UnresolvedLocaleError error) => error.toString(),
            'toString',
            allOf(contains('ja'), contains('pt-BR'), contains('zh-Hant-HK')),
          ),
        ),
      );
    });
  });

  group('number formatting', () {
    test('the separators of the locales the table declares', () {
      expect(
        LocaleFormats.forLocale(Locale.parse('en-US'))
            .formatDecimal(1234567.891, fractionDigits: 2),
        '1,234,567.89',
      );
      expect(
        LocaleFormats.forLocale(Locale.parse('pt-BR'))
            .formatDecimal(1234567.891, fractionDigits: 2),
        '1.234.567,89',
      );
      expect(
        LocaleFormats.forLocale(Locale.parse('de-DE'))
            .formatDecimal(1234567.891, fractionDigits: 2),
        '1.234.567,89',
      );
    });

    test('grouping is by threes, from the right, and starts at four digits',
        () {
      final LocaleFormats english = LocaleFormats.forLocale(Locale.parse('en'));
      expect(english.formatDecimal(0), '0');
      expect(english.formatDecimal(999), '999');
      expect(english.formatDecimal(1000), '1,000');
      expect(english.formatDecimal(12345), '12,345');
      expect(english.formatDecimal(123456), '123,456');
      expect(english.formatDecimal(1000000), '1,000,000');
      // Ungrouped on request, for a field that is being edited rather than
      // read.
      expect(english.formatDecimal(1000000, grouped: false), '1000000');
    });

    test('fractionDigits is exact, not a maximum', () {
      final LocaleFormats english = LocaleFormats.forLocale(Locale.parse('en'));
      expect(english.formatDecimal(1, fractionDigits: 2), '1.00');
      expect(english.formatDecimal(1.5, fractionDigits: 2), '1.50');
      expect(english.formatDecimal(1.005, fractionDigits: 2), '1.00');
    });

    test('the minus sign is the locale symbol and precedes the digits', () {
      final LocaleFormats brazilian =
          LocaleFormats.forLocale(Locale.parse('pt-BR'));
      expect(brazilian.formatDecimal(-1234.5, fractionDigits: 1), '-1.234,5');
    });

    test('the root entry answers for a language the table does not know', () {
      final LocaleFormats unknown =
          LocaleFormats.forLocale(Locale.parse('sw-KE'));
      expect(unknown, LocaleFormats.root);
      expect(unknown.formatDecimal(1234, fractionDigits: 1), '1,234.0');
    });
  });

  group('date formatting', () {
    final DateTime date = DateTime(2026, 4, 3);

    test('the field order, which is the part that changes the meaning', () {
      expect(
        LocaleFormats.forLocale(Locale.parse('en-US')).formatDate(date),
        '04/03/2026',
      );
      expect(
        LocaleFormats.forLocale(Locale.parse('en-GB')).formatDate(date),
        '03/04/2026',
      );
      expect(
        LocaleFormats.forLocale(Locale.parse('pt-BR')).formatDate(date),
        '03/04/2026',
      );
      expect(
        LocaleFormats.forLocale(Locale.parse('de-DE')).formatDate(date),
        '03.04.2026',
      );
      expect(
        LocaleFormats.forLocale(Locale.parse('ja-JP')).formatDate(date),
        '2026/04/03',
      );
    });

    test('the root order is the unambiguous one', () {
      // A reader who reached the root entry is a reader whose locale is
      // unknown, and 2026-04-03 cannot be misread the way 03/04/2026 can.
      expect(LocaleFormats.root.formatDate(date), '2026-04-03');
      expect(
        LocaleFormats.forLocale(Locale.undetermined).formatDate(date),
        '2026-04-03',
      );
    });

    test('fields are zero padded, so a column of dates lines up', () {
      expect(
        LocaleFormats.forLocale(Locale.parse('en-GB'))
            .formatDate(DateTime(7, 1, 2)),
        '02/01/0007',
      );
    });
  });

  group('the lookup table itself', () {
    test('the region step exists and is exercised by English', () {
      // en-US and en-GB agree about everything except the field order, which
      // is exactly the case a language-only table gets wrong.
      expect(
        LocaleFormats.forLocale(Locale.parse('en-US')).dates.fieldOrder,
        DateFieldOrder.monthDayYear,
      );
      expect(
        LocaleFormats.forLocale(Locale.parse('en-GB')).dates.fieldOrder,
        DateFieldOrder.dayMonthYear,
      );
      // A region the table does not list falls back to the language entry.
      expect(
        LocaleFormats.forLocale(Locale.parse('en-CA')).dates.fieldOrder,
        DateFieldOrder.monthDayYear,
      );
    });

    test('the script subtag does not disturb the lookup', () {
      expect(
        LocaleFormats.forLocale(Locale.parse('zh-Hant-TW')),
        LocaleFormats.defaults['zh'],
      );
    });

    test('it is small, and that is stated rather than hidden', () {
      // The point of asserting a bound: the table is a declared approximation,
      // and a future change that quietly grows it into half a CLDR is the
      // thing this test is here to make somebody argue for.
      expect(LocaleFormats.defaults.length, lessThan(25));
      expect(LocaleFormats.defaults.keys, contains('en'));
      expect(LocaleFormats.defaults.keys, contains('ar'));
    });
  });
}
