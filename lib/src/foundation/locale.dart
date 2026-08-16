/// A language tag - `pt-BR`, `zh-Hant-TW`, `ar` - parsed, normalized and
/// comparable.
///
/// This is the value the whole of section 33 hangs off. It is deliberately
/// *only* a value: it holds no strings, loads nothing, and knows about no
/// widget. `widgets/localizations.dart` is where a tree learns about it.
///
/// ## Why parsing and normalization are not optional
///
/// A locale arrives as text, from an environment variable, a window-manager
/// setting, a preferences file or a command line, and it arrives in whatever
/// case and with whatever separator its source felt like using: `pt_BR`,
/// `pt-br`, `PT-BR`, `zh-hant-tw`. BCP 47 says tags are case-insensitive but
/// fixes a *conventional* case - language lower, script title, region upper -
/// and the reason to apply it here rather than at every comparison is that a
/// comparison which forgets fails silently: `Locale('pt', null, 'br')` and
/// `Locale('pt', null, 'BR')` are the same locale, and a `==` that says
/// otherwise produces a resolution miss, an English fallback, and no error
/// anywhere. So the constructor normalizes, and there is no way to build an
/// unnormalized one.
///
/// A tag that cannot be read is a [MalformedLanguageTagError] and never a
/// `Locale('')`. An empty language code compares unequal to everything, which
/// means the mistake reappears far from its cause as "the application is
/// suddenly in English".
///
/// ## What this type models, and what it does not
///
/// `language[-script][-region]`, which is the part of RFC 5646 that changes
/// what an application draws. Variants (`de-DE-1901`), extensions (`-u-ca-
/// buddhist`), private use (`-x-...`) and grandfathered tags are **rejected by
/// name** rather than truncated away, because silently dropping `-u-nu-arab`
/// from a tag is exactly the class of bug that shows up as digits in the wrong
/// script three screens later.
///
/// ## Its relationship to `text/case_mapping.dart`
///
/// [languageCode] is normalized to the lower-case primary subtag, which is
/// precisely what `case_mapping.dart` reads out of the `locale:` argument of
/// [toUpperCase] and friends. So `toUpperCase(s, locale: turkish.toString())`
/// keeps refusing with `UnsupportedCaseLocaleError` for `tr`, `az` and `lt`
/// exactly as it did for a raw string, in upper case or lower, with a hyphen
/// or an underscore. This file does **not** carry a second copy of that
/// refusal list: one list, in the file that owns the missing data.
library;

// ---------------------------------------------------------------------------
// Errors
// ---------------------------------------------------------------------------

/// Thrown when a string is not a `language[-script][-region]` tag.
///
/// An [Error] rather than an exception when it comes from [Locale.parse]: a
/// hard-coded tag that does not parse is a bug in the program, not a condition
/// it can recover from. Input whose shape is genuinely unknown - a value read
/// out of a config file - goes through [Locale.tryParse], which answers null.
final class MalformedLanguageTagError extends Error {
  MalformedLanguageTagError(this.tag, this.subtag, this.reason);

  /// The whole tag as it was handed in, so the message can be searched for in
  /// the file it came from.
  final String tag;

  /// The subtag that could not be accepted, or the empty string when the
  /// problem is the tag as a whole.
  final String subtag;

  /// Why, in prose, already naming the rule that was broken.
  final String reason;

  @override
  String toString() => "MalformedLanguageTagError: '$tag' is not a "
      'language[-script][-region] tag.\n'
      '${subtag.isEmpty ? '' : "  at subtag: '$subtag'\n"}'
      '  $reason\n'
      'Locale models the three subtags that change what an application draws. '
      'Use Locale.tryParse if the input is untrusted and a null answer is '
      'better than a throw.';
}

/// Thrown when no supported locale can serve a requested one.
///
/// Carries both lists because either one alone is unactionable: "pt-PT is not
/// supported" does not say what *is*, and "supported: [en, fr]" does not say
/// what was asked for.
final class UnresolvedLocaleError extends Error {
  UnresolvedLocaleError(this.preferred, this.supported);

  /// What was asked for, most-preferred first.
  final List<Locale> preferred;

  /// What was on offer.
  final List<Locale> supported;

  @override
  String toString() => 'UnresolvedLocaleError: none of the preferred locales '
      'shares a language with any supported one.\n'
      '  preferred: ${preferred.join(', ')}\n'
      '  supported: ${supported.isEmpty ? '(none)' : supported.join(', ')}\n'
      'Add a supported locale for one of these languages, or choose a default '
      'explicitly - resolveLocale returns null rather than inventing one, '
      'because an invented locale is a wrong language that nothing reports.';
}

// ---------------------------------------------------------------------------
// Locale
// ---------------------------------------------------------------------------

/// An identifier for a language, optionally narrowed by script and region.
final class Locale {
  /// A locale from its subtags, normalized and validated.
  ///
  /// `Locale('PT', null, 'br')` and `Locale('pt', null, 'BR')` are the same
  /// value; see the library comment for why that is enforced here rather than
  /// left to each comparison.
  factory Locale(
    String languageCode, [
    String? scriptCode,
    String? countryCode,
  ]) {
    final String tag = <String>[
      languageCode,
      if (scriptCode != null) scriptCode,
      if (countryCode != null) countryCode,
    ].join('-');
    _checkLanguageSubtag(tag, languageCode);
    if (scriptCode != null && !_isScriptSubtag(scriptCode)) {
      throw MalformedLanguageTagError(
        tag,
        scriptCode,
        'a script subtag is exactly four letters (ISO 15924), for example '
        'Latn, Cyrl, Hant.',
      );
    }
    if (countryCode != null && !_isRegionSubtag(countryCode)) {
      throw MalformedLanguageTagError(
        tag,
        countryCode,
        'a region subtag is two letters (ISO 3166-1) or three digits '
        '(UN M.49), for example BR, GB, 419.',
      );
    }
    return Locale._(
      languageCode.toLowerCase(),
      _normalizeScript(scriptCode),
      countryCode?.toUpperCase(),
    );
  }

  /// The already-normalized form. Private so that no unnormalized instance can
  /// exist, which is what makes [operator ==] trustworthy.
  const Locale._(this.languageCode, this.scriptCode, this.countryCode);

  /// Parses a BCP 47 tag such as `pt-BR`, `zh-Hant-TW`, `ar` or `es-419`.
  ///
  /// `_` is accepted as a separator alongside `-`, because POSIX
  /// `LANG=pt_BR.UTF-8` and Java's `Locale.toString()` both produce it and
  /// refusing them would only push a `replaceAll` into every caller. The
  /// encoding suffix is *not* accepted: `pt_BR.UTF-8` names a charset, which is
  /// not part of a locale identity, and quietly ignoring it would make
  /// `pt_BR.UTF-8` and `pt_BR.ISO-8859-1` the same string with different
  /// meanings to whoever wrote them.
  ///
  /// Throws [MalformedLanguageTagError] on anything else, including tags that
  /// are well-formed BCP 47 but carry subtags this type does not model.
  factory Locale.parse(String tag) {
    if (tag.isEmpty) {
      throw MalformedLanguageTagError(
        tag,
        '',
        'the tag is empty. An empty locale compares equal to nothing and '
            'resolves to nothing, so it is refused at the point it is written '
            'rather than at the point it fails.',
      );
    }
    final List<String> parts = tag.replaceAll('_', '-').split('-');
    int index = 0;
    final String language = parts[index++];
    _checkLanguageSubtag(tag, language);

    String? script;
    if (index < parts.length && _isScriptSubtag(parts[index])) {
      script = parts[index++];
    }
    String? region;
    if (index < parts.length && _isRegionSubtag(parts[index])) {
      region = parts[index++];
    }
    if (index < parts.length) {
      throw MalformedLanguageTagError(
        tag,
        parts[index],
        'this is either a variant, an extension or private use. Those are '
        'well-formed BCP 47 and are still refused, because truncating them '
        'away turns "-u-nu-arab" into digits in the wrong script with '
        'nothing to trace it back to. Supply the extra information through '
        'a LocalizationsDelegate instead.',
      );
    }
    return Locale._(
      language.toLowerCase(),
      _normalizeScript(script),
      region?.toUpperCase(),
    );
  }

  /// [Locale.parse], or null when the tag cannot be read.
  ///
  /// For input whose shape is genuinely unknown. The distinction from [parse]
  /// is the same one `int.parse` and `int.tryParse` draw, and it is written at
  /// the call site so a reviewer can see which of the two a given piece of
  /// input deserves.
  static Locale? tryParse(String tag) {
    try {
      return Locale.parse(tag);
    } on MalformedLanguageTagError {
      return null;
    }
  }

  /// ISO 639 language subtag, lower case. Never empty.
  final String languageCode;

  /// ISO 15924 script subtag in title case (`Hant`, `Latn`, `Arab`), or null.
  final String? scriptCode;

  /// ISO 3166-1 or UN M.49 region subtag in upper case (`BR`, `419`), or null.
  final String? countryCode;

  /// The tag for "language not determined", which BCP 47 spells `und`.
  ///
  /// A real value with a real meaning, and the reason no null [Locale] is
  /// needed anywhere: code that has no locale yet can say so.
  static const Locale undetermined = Locale._('und', null, null);

  /// The pseudo-locale conventionally used for expansion testing.
  ///
  /// `en-XA` is the tag CLDR reserves for accented, lengthened English; `XA` is
  /// a user-assigned ISO 3166-1 code, so it can never collide with a real
  /// region. See `PseudoLocalization` in `widgets/localizations.dart`.
  static const Locale pseudo = Locale._('en', null, 'XA');

  /// This locale with the script and region dropped.
  ///
  /// The unit the language-level fallback in [resolveLocale] works in, and the
  /// key `case_mapping.dart` and [LocaleFormats] look things up by.
  Locale get languageOnly => scriptCode == null && countryCode == null
      ? this
      : Locale._(languageCode, null, null);

  /// Whether text in this locale runs right to left.
  ///
  /// Decided by the **script** when the tag names one, and only otherwise by
  /// the language. That order matters and is not a detail: `az-Arab` is
  /// right-to-left and `az-Latn` is not, `ku-Arab` is and `ku-Latn` is not, and
  /// a language-only table gets both of those pairs wrong in one direction or
  /// the other. See [rightToLeftScripts] and [rightToLeftLanguages] for the
  /// data and for where it comes from.
  bool get isRightToLeft {
    final String? script = scriptCode;
    if (script != null) return rightToLeftScripts.contains(script);
    return rightToLeftLanguages.contains(languageCode);
  }

  /// The negation of [isRightToLeft], spelled out so a call site reads as the
  /// question it is asking.
  bool get isLeftToRight => !isRightToLeft;

  /// The canonical `language[-script][-region]` tag.
  ///
  /// Round-trips: `Locale.parse(t).toLanguageTag()` equals `t` for every `t`
  /// already in conventional case, and equals the conventional form of `t`
  /// otherwise.
  String toLanguageTag() {
    final StringBuffer buffer = StringBuffer(languageCode);
    final String? script = scriptCode;
    if (script != null) buffer.write('-$script');
    final String? country = countryCode;
    if (country != null) buffer.write('-$country');
    return buffer.toString();
  }

  /// The tag, so that a locale interpolated into a message or a log line is
  /// the thing a reader can paste back into [Locale.parse].
  @override
  String toString() => toLanguageTag();

  @override
  bool operator ==(Object other) =>
      other is Locale &&
      other.languageCode == languageCode &&
      other.scriptCode == scriptCode &&
      other.countryCode == countryCode;

  @override
  int get hashCode => Object.hash(languageCode, scriptCode, countryCode);
}

// ---------------------------------------------------------------------------
// Subtag grammar
// ---------------------------------------------------------------------------

void _checkLanguageSubtag(String tag, String language) {
  if (language.isEmpty) {
    throw MalformedLanguageTagError(
      tag,
      language,
      'the language subtag is empty; every tag begins with one.',
    );
  }
  if (language.length < 2 || language.length > 8 || !_isAlpha(language)) {
    throw MalformedLanguageTagError(
      tag,
      language,
      'a language subtag is two to eight letters (RFC 5646 section 2.2.1) - '
      'two or three for ISO 639, longer only for registered tags. '
      "'$language' is ${language.length} character"
      '${language.length == 1 ? '' : 's'}'
      '${_isAlpha(language) ? '' : ' and is not all letters'}.',
    );
  }
}

bool _isScriptSubtag(String value) => value.length == 4 && _isAlpha(value);

bool _isRegionSubtag(String value) =>
    (value.length == 2 && _isAlpha(value)) ||
    (value.length == 3 && _isDigits(value));

String? _normalizeScript(String? script) => script == null
    ? null
    : script[0].toUpperCase() + script.substring(1).toLowerCase();

bool _isAlpha(String value) {
  for (int i = 0; i < value.length; i++) {
    final int unit = value.codeUnitAt(i);
    final bool letter =
        (unit >= 0x41 && unit <= 0x5A) || (unit >= 0x61 && unit <= 0x7A);
    if (!letter) return false;
  }
  return true;
}

bool _isDigits(String value) {
  for (int i = 0; i < value.length; i++) {
    final int unit = value.codeUnitAt(i);
    if (unit < 0x30 || unit > 0x39) return false;
  }
  return true;
}

// ---------------------------------------------------------------------------
// Writing direction
// ---------------------------------------------------------------------------

/// The ISO 15924 scripts written right to left.
///
/// **Source.** CLDR's `scriptMetadata.json`, the entries whose `rtl` field is
/// `YES`, which CLDR in turn derives from the Bidi_Class of the letters each
/// script contains. Spelled in the title case [Locale] normalizes script
/// subtags to, so a lookup is a plain set membership test.
///
/// Historic scripts are in the list because a tag can name one - `arc-Armi`,
/// `xpr-Prti` - and a text sample in Imperial Aramaic laid out left to right is
/// as wrong as an Arabic one. They cost nothing: this is a constant set.
///
/// `Aran` (Nastaliq) is here as well as `Arab`: it is a separate ISO 15924 code
/// that CLDR uses for Urdu styling, and it is right to left.
const Set<String> rightToLeftScripts = <String>{
  'Adlm',
  'Arab',
  'Aran',
  'Armi',
  'Avst',
  'Cprt',
  'Egyd',
  'Elym',
  'Gara',
  'Hatr',
  'Hebr',
  'Hung',
  'Khar',
  'Lydi',
  'Mand',
  'Mani',
  'Mend',
  'Merc',
  'Mero',
  'Narb',
  'Nbat',
  'Nkoo',
  'Orkh',
  'Palm',
  'Phli',
  'Phlp',
  'Phnx',
  'Prti',
  'Rohg',
  'Samr',
  'Sarb',
  'Sogd',
  'Sogo',
  'Syrc',
  'Thaa',
  'Todr',
  'Yezi',
};

/// The languages whose default script is right to left.
///
/// **Source.** CLDR `likelySubtags.xml` composed with [rightToLeftScripts]:
/// a language is here when the script CLDR would add to the bare language tag
/// is a right-to-left one. That is the same rule CLDR's own `characterOrder`
/// element encodes, computed once and written down instead of shipping the
/// likely-subtags table.
///
/// Consulted **only** when the tag carries no script subtag; see
/// [Locale.isRightToLeft]. That is what keeps `az`, `ku`, `pa`, `sd` and `ha` -
/// languages written in different scripts in different places - out of the
/// argument: name the script and the script decides.
///
/// Both the two- and three-letter forms are present for the major languages,
/// because a tag arrives in whichever form its source used and `ara` has to be
/// answered as firmly as `ar` - the same reasoning
/// `text/case_mapping.dart` gives for its own refusal set. The legacy codes
/// `iw` (Hebrew) and `ji` (Yiddish) are here for the same reason; note that
/// [Locale] does **not** canonicalize them to `he` and `yi`, because a
/// canonicalizing parse would stop round-tripping.
///
/// A language not in this list is treated as left to right. That is a real
/// limitation and not a claim: the fix for a missing one is a script subtag at
/// the call site, which is authoritative, rather than a wait for this constant
/// to grow.
const Set<String> rightToLeftLanguages = <String>{
  // Arabic script.
  'ar', 'ara', // Arabic
  'bal', // Baluchi
  'bgn', // Western Balochi
  'bqi', // Bakhtiari
  'brh', // Brahui
  'ckb', // Central Kurdish (Sorani)
  'dcc', // Deccan
  'fa', 'fas', 'per', // Persian
  'gbz', // Zoroastrian Dari
  'glk', // Gilaki
  'haz', // Hazaragi
  'khw', // Khowar
  'ks', 'kas', // Kashmiri
  'lrc', // Northern Luri
  'luz', // Southern Luri
  'mzn', // Mazanderani
  'pnb', // Western Panjabi
  'prs', // Dari
  'ps', 'pus', // Pashto
  'sd', 'snd', // Sindhi
  'sdh', // Southern Kurdish
  'skr', // Saraiki
  'ug', 'uig', // Uyghur
  'ur', 'urd', // Urdu
  // Hebrew script.
  'he', 'heb', 'iw', // Hebrew
  'jpr', // Judeo-Persian
  'jrb', // Judeo-Arabic
  'yi', 'yid', 'ji', // Yiddish
  // Thaana.
  'dv', 'div', // Divehi
  // N'Ko.
  'nqo', // N'Ko
  // Syriac.
  'aii', // Assyrian Neo-Aramaic
  'syc', // Classical Syriac
  'syr', // Syriac
  // Imperial Aramaic and friends, whose default script is right to left.
  'arc', // Aramaic
  'sam', // Samaritan Aramaic
};

// ---------------------------------------------------------------------------
// Locale resolution
// ---------------------------------------------------------------------------

/// The best [supported] locale for the [preferred] list, or null.
///
/// ## The algorithm, written down
///
/// The preferred list is in order of preference: a user who asked for
/// `[pt-PT, es-ES, en]` wants Portuguese first and would rather have Spanish
/// than English. Each preferred locale is tried **to exhaustion** before the
/// next one is looked at - `es-ES` never wins over some Portuguese variant,
/// because "close enough in the right language" beats "exact in the wrong
/// one".
///
/// For one preferred locale `want`, the first of these that hits, wins:
///
///  1. **Exact.** A supported locale equal to `want`, all three subtags.
///  2. **Language and script**, ignoring region - only when `want` names a
///     script. `zh-Hant-TW` takes `zh-Hant-HK` over `zh-Hans-CN`: a reader of
///     Traditional characters handed Simplified cannot read the screen, while
///     a Hong Kong spelling of a Taiwanese string is merely slightly off.
///     This is why the script step comes before the region step.
///  3. **Language and region**, ignoring script - only when `want` names a
///     region.
///  4. **Language only.** The step the whole thing exists for: `pt-PT`
///     requested with only `pt-BR` supported resolves to `pt-BR`. Among
///     several candidates the *generic* entry wins - a supported bare `pt`
///     beats `pt-BR` - and otherwise the earliest in [supported] does. The tie
///     is broken by the application's own ordering rather than alphabetically
///     or by some notion of language distance, because the application is the
///     only party that knows whether its Portuguese is Brazilian or European.
///
/// If no preferred locale reaches step 4 against anything, the answer is null.
/// **Not** `supported.first`: a silent default is a wrong language that nobody
/// reports, and the caller is in a far better position to decide - it may want
/// to throw, to consult a second preference list, or to pick a documented
/// default. [UnresolvedLocaleError] exists for the callers that pick "throw".
///
/// ## What it deliberately does not do
///
/// No macrolanguage expansion (`cmn` is not treated as `zh`), no likely-subtag
/// inference (a supported `zh` is not assumed to be `zh-Hans`), no CLDR
/// language-matching distance table. Those need data this framework does not
/// ship; see the note on [LocaleFormats] for the same boundary drawn again.
Locale? resolveLocale(
  Iterable<Locale> preferred,
  Iterable<Locale> supported,
) {
  final List<Locale> options = List<Locale>.of(supported);
  if (options.isEmpty) return null;
  for (final Locale want in preferred) {
    // 1. Exact.
    for (final Locale have in options) {
      if (have == want) return have;
    }
    // 2. Language and script, ignoring region.
    if (want.scriptCode != null) {
      for (final Locale have in options) {
        if (have.languageCode == want.languageCode &&
            have.scriptCode == want.scriptCode) {
          return have;
        }
      }
    }
    // 3. Language and region, ignoring script.
    if (want.countryCode != null) {
      for (final Locale have in options) {
        if (have.languageCode == want.languageCode &&
            have.countryCode == want.countryCode) {
          return have;
        }
      }
    }
    // 4. Language only; the generic entry first, then declaration order.
    Locale? firstOfLanguage;
    for (final Locale have in options) {
      if (have.languageCode != want.languageCode) continue;
      if (have.scriptCode == null && have.countryCode == null) return have;
      firstOfLanguage ??= have;
    }
    if (firstOfLanguage != null) return firstOfLanguage;
  }
  return null;
}

/// [resolveLocale], throwing [UnresolvedLocaleError] instead of answering null.
///
/// For the caller that has no defensible default. The two are separate
/// functions rather than a flag so that the choice is visible at the call site,
/// the same way `Directionality.of` and `Directionality.maybeOf` are.
Locale resolveLocaleOrThrow(
  Iterable<Locale> preferred,
  Iterable<Locale> supported,
) {
  final Locale? resolved = resolveLocale(preferred, supported);
  if (resolved != null) return resolved;
  throw UnresolvedLocaleError(
    List<Locale>.of(preferred),
    List<Locale>.of(supported),
  );
}

// ---------------------------------------------------------------------------
// Number and date formatting: the contract, and a minimum
// ---------------------------------------------------------------------------

/// Where the fraction starts and where the digits are grouped.
final class NumberSymbols {
  const NumberSymbols({
    required this.decimalSeparator,
    required this.groupSeparator,
    this.groupSize = 3,
    this.minusSign = '-',
  }) : assert(groupSize > 0);

  /// What separates the integer part from the fraction: `.` or `,`.
  final String decimalSeparator;

  /// What separates groups of digits: `,`, `.`, U+00A0 or U+202F.
  final String groupSeparator;

  /// How many digits per group. Three nearly everywhere; the South Asian
  /// 2-2-3 grouping of `en-IN` is **not** expressible with this field, and is
  /// one of the things named as out of scope on [LocaleFormats].
  final int groupSize;

  /// The sign written before a negative number.
  final String minusSign;

  @override
  bool operator ==(Object other) =>
      other is NumberSymbols &&
      other.decimalSeparator == decimalSeparator &&
      other.groupSeparator == groupSeparator &&
      other.groupSize == groupSize &&
      other.minusSign == minusSign;

  @override
  int get hashCode =>
      Object.hash(decimalSeparator, groupSeparator, groupSize, minusSign);

  @override
  String toString() =>
      'NumberSymbols(decimal: $decimalSeparator, group: $groupSeparator)';
}

/// The order the three numeric date fields are written in.
///
/// The only part of date formatting that changes meaning rather than
/// appearance: `03/04/2026` is the third of April in `en-GB` and the fourth of
/// March in `en-US`, and there is nothing in the string to tell them apart.
enum DateFieldOrder { dayMonthYear, monthDayYear, yearMonthDay }

/// How a numeric date is spelled.
final class DateSymbols {
  const DateSymbols({
    required this.fieldOrder,
    this.fieldSeparator = '/',
  });

  final DateFieldOrder fieldOrder;

  /// What goes between the fields: `/`, `.` or `-`.
  final String fieldSeparator;

  @override
  bool operator ==(Object other) =>
      other is DateSymbols &&
      other.fieldOrder == fieldOrder &&
      other.fieldSeparator == fieldSeparator;

  @override
  int get hashCode => Object.hash(fieldOrder, fieldSeparator);

  @override
  String toString() => 'DateSymbols($fieldOrder, "$fieldSeparator")';
}

/// The formatting contract, plus a table small enough to read in one screen.
///
/// ## This is not ICU, and it does not pretend to be
///
/// Section 33 of the roadmap says the number and date formatting of a real
/// application comes from a Dart package or the host platform, and that the
/// core must stay an extension point. So what is here is the **contract** -
/// a locale maps to [NumberSymbols] and [DateSymbols], and there are two
/// functions that use them - and a default table covering the handful of
/// languages a framework can be tested against.
///
/// Named explicitly as **out of scope**, so that nobody discovers it by
/// shipping: currency symbols and their placement; percent and per-mille;
/// compact notation (`1.2M`); scientific notation; significant-digit rounding;
/// plural and ordinal categories; month, weekday and era names; time of day,
/// 12- versus 24-hour clocks and time zones; any calendar other than
/// proleptic Gregorian; non-ASCII digit shapes (`en-XA`, `ar-EG` with
/// U+0660..U+0669, `fa` with U+06F0..U+06F9) and the Arabic decimal and group
/// marks U+066B and U+066C; the South Asian 2-2-3 grouping; and CLDR's
/// skeleton and pattern languages. Every one of those needs data measured in
/// megabytes, and half of them need language-specific rules on top.
///
/// An application that needs any of it supplies its own [LocaleFormats]
/// through a `LocalizationsDelegate` - the constructor is public precisely so
/// that a delegate wrapping a real CLDR package can replace the whole thing
/// without this file changing.
///
/// The default table below is a **declared approximation**. It is right for
/// the separators and the field order of the locales it lists, and it is
/// silent about everything else by falling back to the root entry.
final class LocaleFormats {
  const LocaleFormats({required this.numbers, required this.dates});

  final NumberSymbols numbers;
  final DateSymbols dates;

  /// The root formats: `.` decimal, `,` grouping, ISO-ish year-month-day.
  ///
  /// Deliberately the ISO field order rather than any national one, because
  /// the fallback should be the unambiguous spelling: a reader who gets the
  /// root entry is a reader whose locale this table does not know, and
  /// `2026-04-03` cannot be misread the way `03/04/2026` can.
  static const LocaleFormats root = LocaleFormats(
    numbers: NumberSymbols(decimalSeparator: '.', groupSeparator: ','),
    dates: DateSymbols(
      fieldOrder: DateFieldOrder.yearMonthDay,
      fieldSeparator: '-',
    ),
  );

  /// The whole default table. Public so a test - or a reader deciding whether
  /// it covers them - can enumerate it rather than take its size on trust.
  static const Map<String, LocaleFormats> defaults = <String, LocaleFormats>{
    'en': LocaleFormats(
      numbers: NumberSymbols(decimalSeparator: '.', groupSeparator: ','),
      dates: DateSymbols(fieldOrder: DateFieldOrder.monthDayYear),
    ),
    // The split inside English is the reason the lookup has a region step at
    // all: en-US and en-GB disagree about the field order and agree about
    // everything else, and getting it wrong silently changes the date.
    'en-GB': LocaleFormats(
      numbers: NumberSymbols(decimalSeparator: '.', groupSeparator: ','),
      dates: DateSymbols(fieldOrder: DateFieldOrder.dayMonthYear),
    ),
    'en-AU': LocaleFormats(
      numbers: NumberSymbols(decimalSeparator: '.', groupSeparator: ','),
      dates: DateSymbols(fieldOrder: DateFieldOrder.dayMonthYear),
    ),
    'pt': LocaleFormats(
      numbers: NumberSymbols(decimalSeparator: ',', groupSeparator: '.'),
      dates: DateSymbols(fieldOrder: DateFieldOrder.dayMonthYear),
    ),
    'es': LocaleFormats(
      numbers: NumberSymbols(decimalSeparator: ',', groupSeparator: '.'),
      dates: DateSymbols(fieldOrder: DateFieldOrder.dayMonthYear),
    ),
    'it': LocaleFormats(
      numbers: NumberSymbols(decimalSeparator: ',', groupSeparator: '.'),
      dates: DateSymbols(fieldOrder: DateFieldOrder.dayMonthYear),
    ),
    'nl': LocaleFormats(
      numbers: NumberSymbols(decimalSeparator: ',', groupSeparator: '.'),
      dates: DateSymbols(
        fieldOrder: DateFieldOrder.dayMonthYear,
        fieldSeparator: '-',
      ),
    ),
    'tr': LocaleFormats(
      numbers: NumberSymbols(decimalSeparator: ',', groupSeparator: '.'),
      dates: DateSymbols(
        fieldOrder: DateFieldOrder.dayMonthYear,
        fieldSeparator: '.',
      ),
    ),
    'de': LocaleFormats(
      numbers: NumberSymbols(decimalSeparator: ',', groupSeparator: '.'),
      dates: DateSymbols(
        fieldOrder: DateFieldOrder.dayMonthYear,
        fieldSeparator: '.',
      ),
    ),
    // U+202F NARROW NO-BREAK SPACE, which is what CLDR gives French. A plain
    // space would let a number wrap in half across a line break.
    'fr': LocaleFormats(
      numbers: NumberSymbols(
        decimalSeparator: ',',
        groupSeparator: ' ',
      ),
      dates: DateSymbols(fieldOrder: DateFieldOrder.dayMonthYear),
    ),
    // U+00A0 NO-BREAK SPACE, likewise.
    'ru': LocaleFormats(
      numbers: NumberSymbols(
        decimalSeparator: ',',
        groupSeparator: ' ',
      ),
      dates: DateSymbols(
        fieldOrder: DateFieldOrder.dayMonthYear,
        fieldSeparator: '.',
      ),
    ),
    'ja': LocaleFormats(
      numbers: NumberSymbols(decimalSeparator: '.', groupSeparator: ','),
      dates: DateSymbols(fieldOrder: DateFieldOrder.yearMonthDay),
    ),
    'zh': LocaleFormats(
      numbers: NumberSymbols(decimalSeparator: '.', groupSeparator: ','),
      dates: DateSymbols(fieldOrder: DateFieldOrder.yearMonthDay),
    ),
    'ko': LocaleFormats(
      numbers: NumberSymbols(decimalSeparator: '.', groupSeparator: ','),
      dates: DateSymbols(
        fieldOrder: DateFieldOrder.yearMonthDay,
        fieldSeparator: '.',
      ),
    ),
    // Latin-script Arabic digits, which is what this file's ASCII-only
    // formatter can honestly produce; see the out-of-scope list above for the
    // Eastern digit shapes and U+066B/U+066C it cannot.
    'ar': LocaleFormats(
      numbers: NumberSymbols(decimalSeparator: ',', groupSeparator: '.'),
      dates: DateSymbols(fieldOrder: DateFieldOrder.dayMonthYear),
    ),
    'he': LocaleFormats(
      numbers: NumberSymbols(decimalSeparator: '.', groupSeparator: ','),
      dates: DateSymbols(
        fieldOrder: DateFieldOrder.dayMonthYear,
        fieldSeparator: '.',
      ),
    ),
  };

  /// The entry for [locale], falling back by the same shape [resolveLocale]
  /// uses: exact tag, then language and region, then language, then [root].
  ///
  /// The script subtag is not consulted, because nothing in this table varies
  /// by script. When it does, this becomes a call to [resolveLocale] over
  /// `defaults.keys` and stops being a special case.
  static LocaleFormats forLocale(Locale locale) {
    final LocaleFormats? exact = defaults[locale.toLanguageTag()];
    if (exact != null) return exact;
    final String? country = locale.countryCode;
    if (country != null) {
      final LocaleFormats? regional =
          defaults['${locale.languageCode}-$country'];
      if (regional != null) return regional;
    }
    return defaults[locale.languageCode] ?? root;
  }

  /// [value] with this locale's separators.
  ///
  /// [fractionDigits] is exact, not a maximum: passing 2 gives `1,00` and not
  /// `1`, because a price list in which some rows have cents and some do not
  /// is a formatting bug that only shows up on real data.
  ///
  /// Rounding is `num.toStringAsFixed`'s, which is round-half-away-from-zero on
  /// the decimal expansion of the double. Money that has to round a specific
  /// way should be rounded by the caller before it gets here.
  String formatDecimal(
    num value, {
    int fractionDigits = 0,
    bool grouped = true,
  }) {
    final String fixed = value.abs().toStringAsFixed(fractionDigits);
    final int point = fixed.indexOf('.');
    final String whole = point < 0 ? fixed : fixed.substring(0, point);
    final String fraction = point < 0 ? '' : fixed.substring(point + 1);
    final StringBuffer out = StringBuffer();
    if (value.isNegative) out.write(numbers.minusSign);
    out.write(grouped ? _group(whole) : whole);
    if (fraction.isNotEmpty) {
      out
        ..write(numbers.decimalSeparator)
        ..write(fraction);
    }
    return out.toString();
  }

  /// [date] as a zero-padded numeric date in this locale's field order.
  ///
  /// Zero padded and four-digit years, so the result is fixed width and a
  /// column of them lines up. Only the date: see the out-of-scope list for
  /// why there is no time here.
  String formatDate(DateTime date) {
    final String year = date.year.toString().padLeft(4, '0');
    final String month = date.month.toString().padLeft(2, '0');
    final String day = date.day.toString().padLeft(2, '0');
    final String separator = dates.fieldSeparator;
    return switch (dates.fieldOrder) {
      DateFieldOrder.dayMonthYear => '$day$separator$month$separator$year',
      DateFieldOrder.monthDayYear => '$month$separator$day$separator$year',
      DateFieldOrder.yearMonthDay => '$year$separator$month$separator$day',
    };
  }

  String _group(String digits) {
    if (digits.length <= numbers.groupSize) return digits;
    final StringBuffer out = StringBuffer();
    final int lead = digits.length % numbers.groupSize;
    int index = lead == 0 ? numbers.groupSize : lead;
    out.write(digits.substring(0, index));
    while (index < digits.length) {
      out
        ..write(numbers.groupSeparator)
        ..write(digits.substring(index, index + numbers.groupSize));
      index += numbers.groupSize;
    }
    return out.toString();
  }

  @override
  bool operator ==(Object other) =>
      other is LocaleFormats &&
      other.numbers == numbers &&
      other.dates == dates;

  @override
  int get hashCode => Object.hash(numbers, dates);

  @override
  String toString() => 'LocaleFormats($numbers, $dates)';
}
