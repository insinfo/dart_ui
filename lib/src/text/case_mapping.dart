/// Case conversion and case folding, per UAX #21 and the UCD case mappings.
///
/// Dart's own `String.toUpperCase` is a one-to-one mapping: it turns `ß` into
/// `ß` rather than `SS`, `ﬁ` into `ﬁ` rather than `FI`, and it has no notion of
/// title case or of case folding at all. This file uses the **full** mappings,
/// where one code point may become several, and it separates the three
/// operations that are routinely confused:
///
///  * [toUpperCase] and [toLowerCase] change how text *looks*. They are for
///    display, and they are not comparison operators.
///  * [toTitleCase] uppercases the first cased character of each word and
///    lowercases the rest, which needs word boundaries - see `word_break.dart`.
///  * [caseFold] produces a key for **caseless comparison**. It is not
///    "lowercase both sides": lowercasing is not idempotent under comparison,
///    which is why a third mapping exists. `caseFold('STRASSE')` and
///    `caseFold('straße')` are the same string; `toLowerCase` of the two are
///    not.
///
/// ## Limits, stated out loud
///
/// The generated tables carry `UnicodeData.txt` and `CaseFolding.txt` and
/// **not `SpecialCasing.txt`**, which holds every conditional and
/// locale-sensitive rule. Three consequences, none of them silent:
///
///  * **Final sigma is not implemented.** `toLowerCase('ΟΔΟΣ')` gives `οδοσ`,
///    where the correct answer ends in the final form: `οδος`. The rule is
///    conditional on position, not on language, so it applies in the root
///    locale and no locale argument can switch it on. Greek text lowercased
///    through this file is wrong at the end of every word ending in sigma. Use
///    [caseFold] for comparison, where the two sigmas fold together and the
///    defect cannot change the answer.
///
///  * **Lithuanian dot retention is not implemented** (`lt`).
///
///  * **The Turkish and Azeri dotted/dotless I is not implemented**
///    (`tr`, `az`). In those locales `I` lowercases to `ı` and `i` uppercases
///    to `İ`, and getting it wrong is not cosmetic: uppercasing a Turkish `i`
///    to `I` and then comparing is the classic way an identifier check accepts
///    a string it should have rejected.
///
/// So the locale parameter of every function here **refuses** `tr`, `az` and
/// `lt` rather than quietly returning the root-locale answer. Section 6.6 of
/// the framework roadmap forbids swallowing a missing capability and picking
/// something else; a caller that genuinely wants the root mapping for those
/// locales has to say so, by passing [LocaleHandling.warn].
///
/// ## What is deliberately not here
///
/// **The Cased and Case_Ignorable properties**, which the tables do not carry.
/// [toTitleCase] therefore identifies the first cased character of a word as
/// "the first one that has any case mapping at all". That is exact for every
/// letter with an upper, lower or title case, and it differs from the true
/// `Cased` property only for the handful of characters that are cased but map
/// to themselves - U+00AA FEMININE ORDINAL INDICATOR and its kind - which this
/// treats as uncased and skips over.
///
/// The data is a snapshot of UCD 17.0.0 (`tables/case_table.dart`).
library;

import 'tables/case_table.dart';
import 'word_break.dart';

// ---------------------------------------------------------------------------
// Locale handling
// ---------------------------------------------------------------------------

/// What to do when the requested locale needs rules this file does not have.
enum LocaleHandling {
  /// Throw [UnsupportedCaseLocaleError]. The default, because the alternative
  /// fails silently and looks exactly like success.
  fail,

  /// Report through [caseMappingWarningHandler] and continue with the root
  /// mapping, which is wrong for the locale in a known and documented way.
  warn,
}

/// Thrown when a locale needs `SpecialCasing.txt` rules that are not present.
///
/// Names the locale and the missing data, per section 6.6: a diagnostic that
/// says only "unsupported" sends the reader looking in the wrong file.
final class UnsupportedCaseLocaleError extends Error {
  UnsupportedCaseLocaleError(this.language, this.operation);

  /// The primary language subtag that was rejected, lower-cased.
  final String language;

  /// The function that was called, for the message.
  final String operation;

  @override
  String toString() => 'UnsupportedCaseLocaleError: $operation cannot honour '
      "the '$language' locale. Its rules live in SpecialCasing.txt, which is "
      'not part of the generated case tables (tables/case_table.dart carries '
      'only the unconditional mappings). Pass '
      'onUnsupportedLocale: LocaleHandling.warn to accept the root-locale '
      'result, which is wrong for this language.';
}

/// Where [LocaleHandling.warn] sends its message.
///
/// Mutable so a host application can route it into its own log, and so a test
/// can capture it. Called once per conversion call, never per character.
void Function(String message) caseMappingWarningHandler = print;

/// The languages whose case mappings need `SpecialCasing.txt`.
///
/// Both the two- and three-letter codes, because a tag arrives in whatever
/// form its source used and `tur` has to be refused as firmly as `tr`.
///
/// Greek is *not* in the set, even though final sigma is missing too: that
/// rule applies in every locale, so refusing `el` would suggest that passing
/// some other locale makes it right.
const Set<String> _localesNeedingSpecialCasing = <String>{
  'tr',
  'tur',
  'az',
  'aze',
  'lt',
  'lit',
};

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// [text] in upper case, using the full mappings.
///
/// One code point may become several: `ß` becomes `SS`, `ﬃ` becomes `FFI`, and
/// the length of the result is not the length of the input. Any code that
/// assumes case conversion preserves offsets - a highlighter, a caret, a
/// selection - has to re-derive them from the result.
///
/// [locale] is a BCP 47 tag or a bare language subtag; only its primary
/// language subtag is read. See the library comment for why `tr`, `az` and
/// `lt` are refused.
String toUpperCase(
  String text, {
  String? locale,
  LocaleHandling onUnsupportedLocale = LocaleHandling.fail,
}) {
  _checkLocale(locale, onUnsupportedLocale, 'toUpperCase');
  return _mapString(text, fullUppercaseOf, simpleUppercaseOf);
}

/// [text] in lower case, using the full mappings.
///
/// **Not** correct for a final sigma: see the library comment. For comparison,
/// use [caseFold], where the defect cannot change the answer.
String toLowerCase(
  String text, {
  String? locale,
  LocaleHandling onUnsupportedLocale = LocaleHandling.fail,
}) {
  _checkLocale(locale, onUnsupportedLocale, 'toLowerCase');
  return _mapString(text, fullLowercaseOf, simpleLowercaseOf);
}

/// [text] with the first cased character of every word in title case and the
/// rest of each word in lower case.
///
/// The words come from [WordBreaks], not from splitting on spaces, which is
/// what makes `don't` come out as `Don't` rather than `Don'T`, keeps `3.14`
/// and `example.com` in one piece, and gives `ǆ` its own title case `ǅ` - a
/// character whose title case is neither its upper nor its lower case, and the
/// reason title casing cannot be built out of [toUpperCase].
///
/// Note that title case is not a normalization: applying it to `MacDonald`
/// gives `Macdonald`, because the rule lowercases everything after the first
/// cased character. That is UAX #21's definition, not an oversight.
String toTitleCase(
  String text, {
  String? locale,
  LocaleHandling onUnsupportedLocale = LocaleHandling.fail,
}) {
  _checkLocale(locale, onUnsupportedLocale, 'toTitleCase');
  if (text.isEmpty) return text;
  final List<int> marks = WordBreaks.boundaries(text);
  final StringBuffer result = StringBuffer();
  for (int i = 1; i < marks.length; i++) {
    _writeTitled(text, marks[i - 1], marks[i], result);
  }
  return result.toString();
}

/// [text] case-folded: the form to compare two strings for caseless equality.
///
/// `caseFold(a) == caseFold(b)` is Unicode's *default caseless matching*, with
/// one caveat that matters: full caseless matching is defined over normalized
/// text, so a caller comparing arbitrary input should fold *and* normalize -
/// `caseFold(nfc(a)) == caseFold(nfc(b))` - or two strings that differ only in
/// how an accent is spelled will still compare unequal.
///
/// With [full] false this uses the simple, one-to-one folding, which keeps the
/// result the same length as the input; that is what a fixed-width buffer
/// needs and it does **not** make `straße` match `strasse`.
///
/// [locale] exists only to refuse the Turkic locales: `CaseFolding.txt` has a
/// separate `T` mapping for them, it is not in the tables, and folding a
/// dotless `ı` with the root rules is the identifier-comparison bug the
/// library comment describes.
String caseFold(
  String text, {
  bool full = true,
  String? locale,
  LocaleHandling onUnsupportedLocale = LocaleHandling.fail,
}) {
  _checkLocale(locale, onUnsupportedLocale, 'caseFold');
  return full
      ? _mapString(text, fullCaseFoldingOf, simpleCaseFoldingOf)
      : _mapString(text, _noFullMapping, simpleCaseFoldingOf);
}

/// Whether [codePoint] has any case at all.
///
/// The documented approximation of the `Cased` property; see the library
/// comment. Exposed because [toTitleCase] is not the only caller that needs to
/// find the first character a case operation would touch.
bool isCased(int codePoint) =>
    simpleUppercaseOf(codePoint) != codePoint ||
    simpleLowercaseOf(codePoint) != codePoint ||
    simpleTitlecaseOf(codePoint) != codePoint;

// ---------------------------------------------------------------------------
// Implementation
// ---------------------------------------------------------------------------

List<int>? _noFullMapping(int codePoint) => null;

void _checkLocale(
  String? locale,
  LocaleHandling handling,
  String operation,
) {
  if (locale == null) return;
  final String language = _primaryLanguage(locale);
  if (!_localesNeedingSpecialCasing.contains(language)) return;
  switch (handling) {
    case LocaleHandling.fail:
      throw UnsupportedCaseLocaleError(language, operation);
    case LocaleHandling.warn:
      caseMappingWarningHandler(
        "case_mapping: $operation is using root-locale rules for '$language'; "
        'the conditional mappings that locale needs are in SpecialCasing.txt, '
        'which is not in the generated tables. The result is wrong for this '
        'language.',
      );
  }
}

/// The primary language subtag of [locale], lower-cased.
///
/// A tag is `language[-script][-region]...`; underscores are accepted because
/// half the world writes `pt_BR`. Anything that is not a subtag separator is
/// left alone, so a bare `TR` works as well as `tr-TR`.
String _primaryLanguage(String locale) {
  int end = locale.length;
  for (int i = 0; i < locale.length; i++) {
    final int unit = locale.codeUnitAt(i);
    if (unit == 0x2D || unit == 0x5F) {
      end = i;
      break;
    }
  }
  return locale.substring(0, end).toLowerCase();
}

/// Applies a case mapping to every code point of [text].
///
/// Returns [text] itself when nothing changed - which is the common case for
/// text that is already in the wanted case - so a caller can use `identical`
/// and no buffer is allocated at all. The full mapping is consulted first and
/// the simple one only when it returns null, which is the calling convention
/// `case_table.dart` documents: a full mapping is stored only where it differs
/// from the simple one, so "null" really does mean "use the simple mapping"
/// rather than "no mapping".
String _mapString(
  String text,
  List<int>? Function(int) full,
  int Function(int) simple,
) {
  StringBuffer? result;
  int copied = 0;
  int index = 0;
  while (index < text.length) {
    final int codePoint = _codePointAt(text, index);
    final int width = codePoint > 0xFFFF ? 2 : 1;
    final List<int>? fullMapping = full(codePoint);
    final int simpleMapping = fullMapping == null ? simple(codePoint) : 0;
    if (fullMapping == null && simpleMapping == codePoint) {
      index += width;
      continue;
    }
    result ??= StringBuffer();
    result.write(text.substring(copied, index));
    if (fullMapping != null) {
      for (int i = 0; i < fullMapping.length; i++) {
        result.writeCharCode(fullMapping[i]);
      }
    } else {
      result.writeCharCode(simpleMapping);
    }
    index += width;
    copied = index;
  }
  if (result == null) return text;
  result.write(text.substring(copied));
  return result.toString();
}

/// Writes the segment `[start, end)` of [text] to [result], title-cased.
///
/// UAX #21's definition: find the first cased character, title case it, lower
/// case everything after it. Everything before it - an opening quote, a
/// hyphen, a combining mark with no case - is copied through untouched.
void _writeTitled(String text, int start, int end, StringBuffer result) {
  int index = start;
  bool seenCased = false;
  while (index < end) {
    final int codePoint = _codePointAt(text, index);
    index += codePoint > 0xFFFF ? 2 : 1;
    if (!seenCased) {
      if (!isCased(codePoint)) {
        result.writeCharCode(codePoint);
        continue;
      }
      seenCased = true;
      _writeMapped(codePoint, fullTitlecaseOf, simpleTitlecaseOf, result);
      continue;
    }
    _writeMapped(codePoint, fullLowercaseOf, simpleLowercaseOf, result);
  }
}

void _writeMapped(
  int codePoint,
  List<int>? Function(int) full,
  int Function(int) simple,
  StringBuffer result,
) {
  final List<int>? mapping = full(codePoint);
  if (mapping == null) {
    result.writeCharCode(simple(codePoint));
    return;
  }
  for (int i = 0; i < mapping.length; i++) {
    result.writeCharCode(mapping[i]);
  }
}

bool _isHighSurrogate(int unit) => unit >= 0xD800 && unit <= 0xDBFF;

bool _isLowSurrogate(int unit) => unit >= 0xDC00 && unit <= 0xDFFF;

/// The code point starting at [index]. An unpaired surrogate is returned as
/// itself and has no case mapping, so it survives conversion unchanged.
int _codePointAt(String text, int index) {
  final int unit = text.codeUnitAt(index);
  if (_isHighSurrogate(unit) && index + 1 < text.length) {
    final int low = text.codeUnitAt(index + 1);
    if (_isLowSurrogate(low)) {
      return 0x10000 + ((unit - 0xD800) << 10) + (low - 0xDC00);
    }
  }
  return unit;
}
