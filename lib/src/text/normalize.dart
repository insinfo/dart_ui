/// Unicode normalization forms NFC, NFD, NFKC and NFKD, per UAX #15.
///
/// Two strings a user cannot tell apart are routinely different sequences of
/// code points: `é` is U+00E9 or U+0065 U+0301, `Å` is U+00C5 or U+212B or
/// U+0041 U+030A, and a Hangul syllable is one code point or three jamo. Every
/// operation that compares text breaks on that difference - search finds
/// nothing, a sorted list is out of order, two file names that print
/// identically name different files, and a `cmap` lookup finds the spelling the
/// font does not have and falls back to tofu. Normalization is the step that
/// makes those comparisons mean what the user thinks they mean.
///
/// ## The four forms
///
/// The two axes are *canonical vs compatibility* and *decomposed vs composed*.
/// Canonical equivalence is loss-free: U+00C5 and U+0041 U+030A are the same
/// character written two ways, and converting between them changes nothing a
/// reader can see. Compatibility equivalence is not: `ﬁ` and `fi` are the same
/// *letters* but not the same text, and NFKC will happily rewrite `x²` as `x2`.
/// So NFC and NFD are safe to apply to text you are going to display or store,
/// and NFKC and NFKD are for a *key* you are going to compare - an identifier,
/// a search index - and never for the text itself.
///
/// ## The cheap path
///
/// Text that is already normalized is the overwhelmingly common case, and this
/// file is built around it: [quickCheck] scans the string reading one packed
/// table entry per code point, allocates nothing at all, and when the answer is
/// [QuickCheck.yes] the four conversion functions return the *same* `String`
/// instance they were given. Only a `no` or a `maybe` pays for the buffers.
///
/// `maybe` is not a hedge, it is the honest answer: a combining mark with
/// NFC_QC=Maybe composes with what precedes it or does not, and there is no
/// way to tell from the mark alone. A `maybe` therefore falls through to the
/// full algorithm, which may well produce a string equal to its input.
///
/// ## Indices and surrogates
///
/// The API is `String` in, `String` out, and everything inside runs on code
/// points: astral characters are decoded from their surrogate pair before any
/// property is read and re-encoded on the way out, because a normalizer that
/// worked on UTF-16 units would read the properties of a lone surrogate - which
/// has none - and would happily reorder the halves of a musical symbol. An
/// *unpaired* surrogate in damaged input is passed through unchanged rather
/// than throwing; it has ccc 0 and no decomposition, so it behaves as an
/// unremarkable starter and the rest of the string still normalizes.
///
/// ## What is deliberately not here
///
/// **Streaming.** Everything takes a whole string. A normalizer that accepts
/// chunks has to hold back the trailing combining sequence until it knows no
/// more marks are coming, and no caller in this framework normalizes anything
/// it does not already have in memory.
///
/// **Tailoring.** There is none, and there cannot be: normalization forms are
/// fixed by the standard and a "custom" one would not be a normalization form.
///
/// The data is a snapshot of UCD 17.0.0 (see `tables/normalization_table.dart`).
/// A code point assigned later reads as an undecomposable starter, which leaves
/// it alone rather than corrupting it.
library;

import 'tables/normalization_table.dart';

export 'tables/normalization_table.dart' show QuickCheck;

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// One of the four normalization forms of UAX #15.
enum NormalizationForm {
  /// Canonical decomposition. Loss-free.
  nfd,

  /// Canonical decomposition followed by canonical composition. Loss-free,
  /// and the form to store text in.
  nfc,

  /// Compatibility decomposition. **Lossy**: it rewrites `ﬁ` as `fi` and `²`
  /// as `2`.
  nfkd,

  /// Compatibility decomposition followed by canonical composition. **Lossy**,
  /// for comparison keys rather than for text.
  nfkc,
}

/// [text] in canonical decomposed form (NFD).
///
/// Returns [text] itself when it is already in the form, so the caller can use
/// `identical` to detect that nothing happened.
String nfd(String text) => _normalize(text, compat: false, compose: false);

/// [text] in canonical composed form (NFC).
///
/// This is the form to normalize to before storing or comparing display text:
/// it is loss-free, and it is the shortest of the four for nearly all real
/// input.
String nfc(String text) => _normalize(text, compat: false, compose: true);

/// [text] in compatibility decomposed form (NFKD).
///
/// Lossy - see the library comment. Never round-trips.
String nfkd(String text) => _normalize(text, compat: true, compose: false);

/// [text] in compatibility composed form (NFKC).
///
/// Lossy - see the library comment. `nfkc('ﬁ')` is `'fi'`, which is what a
/// search index wants and what a text buffer does not.
String nfkc(String text) => _normalize(text, compat: true, compose: true);

/// [text] converted to [form].
///
/// The switch on the form is here rather than at every call site, for a caller
/// that carries the form as data.
String normalize(String text, NormalizationForm form) => switch (form) {
      NormalizationForm.nfd => nfd(text),
      NormalizationForm.nfc => nfc(text),
      NormalizationForm.nfkd => nfkd(text),
      NormalizationForm.nfkc => nfkc(text),
    };

/// Whether [text] is already in NFC, per the UAX #15 quick check.
///
/// [QuickCheck.yes] and [QuickCheck.no] are certain; [QuickCheck.maybe] means
/// the string contains a mark that may or may not compose with what precedes
/// it, and only running [nfc] answers it. Treat `maybe` as "not known to be
/// normalized" - never as `yes`.
QuickCheck isNfc(String text) => quickCheck(text, NormalizationForm.nfc);

/// Whether [text] is already in NFD. Never [QuickCheck.maybe]: a decomposed
/// form is decided by each code point on its own.
QuickCheck isNfd(String text) => quickCheck(text, NormalizationForm.nfd);

/// Whether [text] is already in NFKC. May be [QuickCheck.maybe]; see [isNfc].
QuickCheck isNfkc(String text) => quickCheck(text, NormalizationForm.nfkc);

/// Whether [text] is already in NFKD. Never [QuickCheck.maybe].
QuickCheck isNfkd(String text) => quickCheck(text, NormalizationForm.nfkd);

/// The quick check of [text] against [form].
///
/// Allocates nothing. One packed-table read per code point plus the running
/// combining class, which is the whole reason the quick-check properties exist:
/// the answer for text that is already normalized - nearly all text - costs a
/// linear scan and no buffers.
QuickCheck quickCheck(String text, NormalizationForm form) {
  QuickCheck result = QuickCheck.yes;
  int lastCombiningClass = 0;
  int index = 0;
  while (index < text.length) {
    final int codePoint = _codePointAt(text, index);
    index += codePoint > 0xFFFF ? 2 : 1;

    // Canonical ordering is part of every form, and it is not expressed by any
    // quick-check property: two marks in the wrong order are individually
    // fine. A non-starter whose class is below the previous one's is proof
    // that the string is not normalized, whatever the properties say.
    final int combiningClass = combiningClassOf(codePoint);
    if (combiningClass != 0 && combiningClass < lastCombiningClass) {
      return QuickCheck.no;
    }
    lastCombiningClass = combiningClass;

    final QuickCheck check = switch (form) {
      NormalizationForm.nfd => nfdQuickCheck(codePoint),
      NormalizationForm.nfc => nfcQuickCheck(codePoint),
      NormalizationForm.nfkd => nfkdQuickCheck(codePoint),
      NormalizationForm.nfkc => nfkcQuickCheck(codePoint),
    };
    if (check == QuickCheck.no) return QuickCheck.no;
    if (check == QuickCheck.maybe) result = QuickCheck.maybe;
  }
  return result;
}

// ---------------------------------------------------------------------------
// The algorithm
// ---------------------------------------------------------------------------

String _normalize(String text, {required bool compat, required bool compose}) {
  if (text.isEmpty) return text;
  final NormalizationForm form = compat
      ? (compose ? NormalizationForm.nfkc : NormalizationForm.nfkd)
      : (compose ? NormalizationForm.nfc : NormalizationForm.nfd);
  if (quickCheck(text, form) == QuickCheck.yes) return text;

  final List<int> codePoints = <int>[];
  int index = 0;
  while (index < text.length) {
    final int codePoint = _codePointAt(text, index);
    index += codePoint > 0xFFFF ? 2 : 1;
    _decomposeInto(codePoint, compat, codePoints);
  }

  _canonicalOrder(codePoints);
  if (compose) _composeInPlace(codePoints);
  return String.fromCharCodes(codePoints);
}

/// Appends the *full* decomposition of [codePoint] to [out].
///
/// The `dm` property is a **single step** - U+1E9B LATIN SMALL LETTER LONG S
/// WITH DOT ABOVE decomposes to U+017F U+0307, and U+1E9B's compatibility
/// mapping goes to U+0073 only through U+017F; a Hangul LVT syllable decomposes
/// to an LV syllable and a trailing jamo, not to three jamo. Applying the
/// mapping once and stopping is the classic bug, and it leaves text that is not
/// in the form it claims to be, so this recurses until nothing decomposes
/// further. The UCD guarantees the mappings are acyclic and shallow (the
/// deepest is a handful of steps), so the recursion cannot run away.
///
/// [compat] selects which mappings count. With `false` only canonical mappings
/// apply - mixing the two here is what silently turns `ﬁ` into `fi` inside an
/// NFC that promised to change nothing visible.
void _decomposeInto(int codePoint, bool compat, List<int> out) {
  final List<int>? mapping =
      compat ? decompositionOf(codePoint) : canonicalDecompositionOf(codePoint);
  if (mapping == null) {
    out.add(codePoint);
    return;
  }
  for (int i = 0; i < mapping.length; i++) {
    _decomposeInto(mapping[i], compat, out);
  }
}

/// Puts the combining marks of [codePoints] in canonical order, in place.
///
/// The definition (UAX #15, D108-D109) is a *stable* sort of each maximal run
/// of non-starters by combining class, and the annex spells it as a bubble
/// sort over adjacent pairs for a reason: the swap is only ever legal when
/// **both** characters have a non-zero combining class. A starter is a barrier.
/// Sorting a whole span with a general-purpose comparison sort - or letting a
/// swap cross a `ccc == 0` character - reorders text across a base letter and
/// moves an accent onto the wrong letter, which is corruption, not
/// mis-normalization.
///
/// Stability is equally load-bearing: two marks with the *same* class are not
/// canonically equivalent in either order, so they must keep the order they
/// arrived in. Swapping only on a strict `>` is what gives that.
void _canonicalOrder(List<int> codePoints) {
  final int length = codePoints.length;
  if (length < 2) return;
  // The class of every code point, read once. The sort compares each element
  // several times and `combiningClassOf` is a binary search.
  final List<int> classes = List<int>.filled(length, 0);
  for (int i = 0; i < length; i++) {
    classes[i] = combiningClassOf(codePoints[i]);
  }
  for (int i = 1; i < length; i++) {
    final int current = classes[i];
    if (current == 0) continue; // a starter never moves
    int j = i;
    while (j > 0) {
      final int previous = classes[j - 1];
      // `previous == 0` stops the walk at the starter; `previous <= current`
      // stops it where the run is already ordered, which is what keeps equal
      // classes in their original order.
      if (previous == 0 || previous <= current) break;
      final int swapPoint = codePoints[j - 1];
      codePoints[j - 1] = codePoints[j];
      codePoints[j] = swapPoint;
      classes[j - 1] = current;
      classes[j] = previous;
      j--;
    }
  }
}

/// Applies the canonical composition algorithm (UAX #15, D117) to the already
/// decomposed and canonically ordered [codePoints], in place, truncating the
/// list to the composed length.
///
/// Two things decide the result, and both are easy to get wrong:
///
///  * **What may compose.** Only a *primary composite*: a code point whose
///    canonical decomposition is exactly two code points, whose first is a
///    starter, and which is not a Full_Composition_Exclusion. See
///    [_compositionIndex].
///
///  * **Blocking.** A character C composes with the last starter S only if
///    nothing stands between them with a combining class greater than or equal
///    to C's (D115). `A + U+0328 (ccc 202) + U+0301 (ccc 230)` composes the
///    acute onto the A, because 202 < 230 leaves the acute unblocked; but
///    `A + U+0301 + U+0328` does not, because the acute at 230 blocks the
///    ogonek at 202 - and an implementation that only looks at "is the previous
///    character a starter" gets the second case wrong and produces a composite
///    that is not canonically equivalent to its input.
///
/// [lastClass] below is the class of the last character actually *kept*. A
/// character that composed away was removed from the sequence and therefore
/// blocks nothing, which is why it does not update it.
void _composeInPlace(List<int> codePoints) {
  final int length = codePoints.length;
  if (length < 2) return;

  int written = 1;
  int starter = codePoints[0];
  int starterPosition = combiningClassOf(starter) == 0 ? 0 : -1;
  // -1 marks "no starter yet"; a leading combining mark has nothing to attach
  // to and must not be treated as a composition target.
  int lastClass = starterPosition == 0 ? 0 : -1;

  for (int i = 1; i < length; i++) {
    final int codePoint = codePoints[i];
    final int combiningClass = combiningClassOf(codePoint);
    if (starterPosition >= 0 &&
        (lastClass == 0 || lastClass < combiningClass)) {
      final int composite = _composePair(starter, codePoint);
      if (composite != 0) {
        codePoints[starterPosition] = composite;
        starter = composite;
        continue;
      }
    }
    codePoints[written++] = codePoint;
    if (combiningClass == 0) {
      starterPosition = written - 1;
      starter = codePoint;
      lastClass = 0;
    } else {
      lastClass = combiningClass;
    }
  }
  codePoints.length = written;
}

/// The primary composite of [first] and [second], or 0 when there is none.
///
/// Zero rather than null because this runs once per character of every string
/// being composed and a nullable return boxes on every call; U+0000 is not a
/// composite of anything, so the sentinel cannot collide with an answer.
int _composePair(int first, int second) {
  // Hangul first: the syllables are the largest family of composites by three
  // orders of magnitude and none of them is in the table, by design - they are
  // arithmetic (UAX #15, "Hangul Composition"). Both steps are needed: L+V
  // makes an LV syllable, and LV+T makes an LVT one, so `ᄒ ᅡ ᆫ` composes to
  // `한` in two passes of the loop above.
  final int leadIndex = first - _hangulLeadBase;
  if (leadIndex >= 0 && leadIndex < _hangulLeadCount) {
    final int vowelIndex = second - _hangulVowelBase;
    if (vowelIndex >= 0 && vowelIndex < _hangulVowelCount) {
      return _hangulSyllableBase +
          (leadIndex * _hangulVowelCount + vowelIndex) * _hangulTrailCount;
    }
  }
  final int syllableIndex = first - _hangulSyllableBase;
  if (syllableIndex >= 0 &&
      syllableIndex < _hangulSyllableCount &&
      syllableIndex % _hangulTrailCount == 0) {
    final int trailIndex = second - _hangulTrailBase;
    // Strictly greater than zero: index 0 is "no trailing jamo" and U+11A7 is
    // not a character that can be appended.
    if (trailIndex > 0 && trailIndex < _hangulTrailCount) {
      return first + trailIndex;
    }
  }

  return _compositionIndex()[first << 21 | second] ?? 0;
}

Map<int, int>? _composition;

/// The inverse of the canonical decompositions: `(first, second) -> composite`.
///
/// Built here rather than generated, because the table file holds the forward
/// mapping and the inverse is a hash table - a normalizer's business, as the
/// comment there says. It is built from the table and nothing is hard-coded, so
/// regenerating the tables for a new UCD moves the composites with them.
///
/// A pair belongs in the index when the composite's canonical decomposition is
/// exactly two code points, the first of those is a starter, and the composite
/// is not a Full_Composition_Exclusion. The three conditions are checked
/// separately even though `Full_Composition_Exclusion` is defined to already
/// cover singletons and non-starter decompositions, because the two that
/// survive the redundancy are the ones the *algorithm* requires: a singleton
/// like U+212B ANGSTROM SIGN must decompose to U+00C5 and never come back, and
/// a decomposition beginning with a non-starter has no starter to compose onto.
///
/// The cost is one scan of the code space, about 40 ms, paid lazily on the
/// first composition and never again. The alternative - scanning only up to
/// some bound where composites are known to stop - would be an assumption about
/// the data rather than a fact about the format; the highest primary composite
/// in UCD 17.0.0 is U+16D6A, in a script added two versions ago, and any such
/// bound would have been wrong twice already.
Map<int, int> _compositionIndex() {
  final Map<int, int>? built = _composition;
  if (built != null) return built;
  final Map<int, int> index = <int, int>{};
  for (int codePoint = 0; codePoint <= _maxCodePoint; codePoint++) {
    // Hangul syllables decompose canonically into exactly two code points and
    // would fill the index with 11172 entries that `_composePair` already
    // answers arithmetically - and each lookup here would allocate the pair.
    if (codePoint >= _hangulSyllableBase &&
        codePoint < _hangulSyllableBase + _hangulSyllableCount) {
      continue;
    }
    final List<int>? mapping = canonicalDecompositionOf(codePoint);
    if (mapping == null || mapping.length != 2) continue;
    if (isFullCompositionExclusion(codePoint)) continue;
    if (combiningClassOf(mapping[0]) != 0) continue;
    // 21 bits is exactly the width of a code point, so the packed key stays
    // inside the 53 bits that survive on the web as well as the 64 on native.
    index[mapping[0] << 21 | mapping[1]] = codePoint;
  }
  return _composition = index;
}

// ---------------------------------------------------------------------------
// Constants and UTF-16
// ---------------------------------------------------------------------------

const int _maxCodePoint = 0x10FFFF;

// The Hangul constants of UAX #15. Repeated here rather than imported because
// the table file keeps its own copies private; they are fixed by the standard
// and cannot drift.
const int _hangulSyllableBase = 0xAC00;
const int _hangulLeadBase = 0x1100;
const int _hangulVowelBase = 0x1161;
const int _hangulTrailBase = 0x11A7;
const int _hangulLeadCount = 19;
const int _hangulVowelCount = 21;
const int _hangulTrailCount = 28;
const int _hangulSyllableCount = 11172;

bool _isHighSurrogate(int unit) => unit >= 0xD800 && unit <= 0xDBFF;

bool _isLowSurrogate(int unit) => unit >= 0xDC00 && unit <= 0xDFFF;

/// The code point starting at [index]. An unpaired surrogate is returned as
/// itself, which normalizes as an undecomposable starter.
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
