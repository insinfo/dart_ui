/// Word boundaries, per UAX #29 section 4 (rules WB1 through WB999).
///
/// This is what `Ctrl+Left`, `Ctrl+Backspace` and a double-click ask for. The
/// naive answer - split on spaces - is wrong in ways every user hits: it breaks
/// `don't` into `don` and `t`, breaks `3.14` into three pieces, breaks
/// `example.com`, and produces exactly one "word" for a whole Japanese
/// sentence, which has no spaces at all. Going the other way and stepping by
/// code unit, which is what a text field does before someone fixes it, walks
/// the caret into the middle of a surrogate pair and lets the next keystroke
/// delete half a character.
///
/// ## What a boundary is here
///
/// A *segmentation*, not a list of words: [WordBreaks.boundaries] returns every
/// position where one segment ends and the next begins, and the segments
/// include the spaces and the punctuation. That is the shape caret movement
/// needs. [WordBreaks.words] filters the segments down to the ones that contain
/// a letter or a digit, which is the shape a spell checker or a double-click
/// needs; the annex itself notes that "word" in the sense of the rules is a
/// segment, and which segments count as words is the caller's decision.
///
/// ## Indices
///
/// Every index is a UTF-16 offset into the Dart string, as in `grapheme.dart`
/// and `line_break.dart`, so a segment can be sliced out with `substring` and
/// compared against a selection directly. Astral characters are decoded from
/// their surrogate pairs before any property is read, so no boundary can ever
/// land between the halves of one.
///
/// ## Rules and their shape
///
/// WB4 - "ignore Extend, Format and ZWJ" - is not implemented as a rule but as
/// the *unit* the rules run on. The scanner groups each character with the run
/// of extenders and format characters that follows it, and every other rule
/// then sees one item per user-perceived character. Doing it the other way,
/// checking for ignorables inside each rule, is where implementations end up
/// with `a<ZWNJ>b` breaking in the middle: some rules remember to skip and
/// some do not.
///
/// The exception in WB4 ("except after sot, CR, LF, and Newline") is why the
/// scanner starts a fresh item for an extender at the start of the text or
/// right after a line terminator - an accent with nothing to attach to is a
/// segment of its own rather than something glued to the newline.
///
/// WB3c (`ZWJ x Extended_Pictographic`) is checked *before* WB4 can hide the
/// joiner, which is what keeps `👨‍👩‍👧` one segment; the scanner therefore
/// records, for each item, whether its ignorable tail ended in a ZWJ.
///
/// ## What is deliberately not here
///
/// **Dictionary-based segmentation.** Thai, Lao, Khmer, Burmese, Chinese and
/// Japanese need a dictionary to find real word boundaries, and UAX #29 says
/// so. The rules here put a boundary around every ideograph and treat a run of
/// Thai as one segment. That is the standard's own default and it is a caret
/// that moves plausibly, not a linguistic analysis.
///
/// **Tailoring.** WB5a and the other suggested tailorings in the annex are not
/// applied; the default rules are.
///
/// The property data is a snapshot of UCD 17.0.0
/// (`tables/word_break_table.dart`). A code point assigned later reads as
/// Other, which segments on both sides.
library;

import 'grapheme.dart' show isExtendedPictographic;
import 'tables/word_break_table.dart';

export 'tables/word_break_table.dart' show WordBreak, wordBreakOf;

/// Every word-segmentation boundary in [text], ascending.
///
/// The free-function spelling of [WordBreaks.boundaries], for the call sites -
/// caret movement, word deletion - that want one name and one list.
List<int> wordBreaks(String text) => WordBreaks.boundaries(text);

/// Word segmentation over a Dart string.
///
/// Stateless and static, like `GraphemeBreaks` in `grapheme.dart`: no
/// configuration, and an instance would only invite someone to cache one per
/// text field and then forget to invalidate it.
final class WordBreaks {
  const WordBreaks._();

  /// Every boundary in [text], ascending, including 0 and `text.length`
  /// (WB1 and WB2).
  ///
  /// Empty text has a single boundary at 0 rather than two, so that a consumer
  /// pairing adjacent entries produces no segments at all instead of one empty
  /// one.
  static List<int> boundaries(String text) {
    final List<int> result = <int>[0];
    if (text.isEmpty) return result;
    final _Items items = _Items(text, 0);
    int i = 1;
    while (true) {
      final int start = items.startAt(i);
      if (start >= text.length) break;
      if (items.breaksBefore(i)) result.add(start);
      i++;
    }
    result.add(text.length);
    return result;
  }

  /// The segments of [text], in order, including the spaces and punctuation
  /// between words. Concatenating them reproduces [text].
  static List<String> segments(String text) {
    final List<int> marks = boundaries(text);
    return <String>[
      for (int i = 1; i < marks.length; i++)
        text.substring(marks[i - 1], marks[i]),
    ];
  }

  /// The segments of [text] that contain a letter, a digit or a Katakana -
  /// that is, the ones a user would call words.
  ///
  /// The filter is deliberately simple and stated rather than derived: a
  /// segment counts when at least one of its code points has Word_Break in
  /// {ALetter, Hebrew_Letter, Numeric, Katakana}. A run of emoji or of
  /// punctuation is a segment but not a word, and a caller that wants those
  /// should walk [boundaries] instead.
  static List<String> words(String text) {
    final List<int> marks = boundaries(text);
    final List<String> result = <String>[];
    for (int i = 1; i < marks.length; i++) {
      if (_isWordSegment(text, marks[i - 1], marks[i])) {
        result.add(text.substring(marks[i - 1], marks[i]));
      }
    }
    return result;
  }

  /// Whether a boundary falls at [index].
  ///
  /// An index inside a surrogate pair, or between a character and one of the
  /// extenders WB4 folds into it, is never a boundary - which is the answer a
  /// caret wants, and the reason this exists rather than a search through
  /// [boundaries].
  static bool isBoundary(String text, int index) {
    if (index <= 0 || index >= text.length) {
      return index == 0 || index == text.length;
    }
    if (_isLowSurrogate(text.codeUnitAt(index)) &&
        _isHighSurrogate(text.codeUnitAt(index - 1))) {
      return false;
    }
    final int start = _itemStartAtOrBefore(text, index);
    if (start != index) return false;
    final _Items items = _Items(text, _safeStart(text, start));
    return items.breaksBefore(items.indexOfOffset(start));
  }

  /// The first boundary strictly after [index], clamped to `text.length`.
  ///
  /// This is `Ctrl+Right`. Costs the length of the segment it crosses plus a
  /// bounded look back, not the length of the paragraph - see [_safeStart].
  static int next(String text, int index) {
    int position = index < 0 ? 0 : index;
    if (position >= text.length) return text.length;
    // An offset inside a surrogate pair is snapped *back* to the start of that
    // code point, not forward past it: the answer wanted for a caret that was
    // handed a damaged offset is the next real boundary, and skipping the
    // character would step over one.
    if (position > 0 &&
        _isLowSurrogate(text.codeUnitAt(position)) &&
        _isHighSurrogate(text.codeUnitAt(position - 1))) {
      position--;
    }
    final int start = _itemStartAtOrBefore(text, position);
    final _Items items = _Items(text, _safeStart(text, start));
    int i = items.indexOfOffset(start);
    while (true) {
      i++;
      final int offset = items.startAt(i);
      if (offset >= text.length) return text.length;
      if (offset > position && items.breaksBefore(i)) return offset;
    }
  }

  /// The last boundary strictly before [index], clamped to 0.
  ///
  /// This is `Ctrl+Left`, and with [next] it is what word-wise deletion is
  /// built from.
  static int previous(String text, int index) {
    final int position = index > text.length ? text.length : index;
    if (position <= 0) return 0;
    // No surrogate adjustment here, and deliberately: an offset inside a pair
    // is not a boundary, so the last boundary *before* it is the start of the
    // character it fell into, and the walk below finds exactly that.
    int candidate = _itemStartAtOrBefore(text, position);
    if (candidate >= position) candidate = _previousItemStart(text, position);
    while (candidate > 0 && !isBoundary(text, candidate)) {
      candidate = _previousItemStart(text, candidate);
    }
    return candidate;
  }

  static bool _isWordSegment(String text, int start, int end) {
    int index = start;
    while (index < end) {
      final int codePoint = _codePointAt(text, index);
      index += codePoint > 0xFFFF ? 2 : 1;
      switch (wordBreakOf(codePoint)) {
        case WordBreak.aLetter:
        case WordBreak.hebrewLetter:
        case WordBreak.numeric:
        case WordBreak.katakana:
          return true;
        default:
          continue;
      }
    }
    return false;
  }
}

/// A cursor over the boundaries of one string.
///
/// [WordBreaks.next] and [WordBreaks.previous] each re-derive their context
/// from the string, which is right for a key press and wasteful for a loop
/// that walks a paragraph. This keeps the position and hands the work to the
/// same two functions, so a caller that wants "every word in this paragraph"
/// without materialising the boundary list can have it.
///
/// The iterator holds the string, not a reference into it: strings are
/// immutable, so an iterator cannot go stale. A text field that edits its
/// buffer must make a new one, which is the point - the old one refers to text
/// that no longer exists.
final class WordBreakIterator {
  /// Positions the cursor at [index], clamped into [text].
  WordBreakIterator(this.text, {int index = 0})
      : _index = index < 0
            ? 0
            : index > text.length
                ? text.length
                : index;

  /// The string being segmented.
  final String text;

  int _index;

  /// The current boundary, a UTF-16 offset.
  ///
  /// It is only guaranteed to *be* a boundary if the iterator was constructed
  /// at one and has been moved with [moveNext] or [movePrevious] since; the
  /// constructor takes an arbitrary offset so a caller can start at the caret.
  int get index => _index;

  /// Moves to the next boundary. False when already at the end of the text,
  /// in which case the position does not change.
  bool moveNext() {
    if (_index >= text.length) return false;
    _index = WordBreaks.next(text, _index);
    return true;
  }

  /// Moves to the previous boundary. False when already at 0.
  bool movePrevious() {
    if (_index <= 0) return false;
    _index = WordBreaks.previous(text, _index);
    return true;
  }
}

// ---------------------------------------------------------------------------
// The scanner
// ---------------------------------------------------------------------------

/// The items the rules run on: one base character plus the run of Extend,
/// Format and ZWJ characters WB4 folds into it.
///
/// Decoding is incremental. Every query the caret makes needs a bounded window
/// of items - two behind for WB7 and WB7c, one ahead for WB6 and WB12, plus
/// however many regional indicators precede - and decoding the rest of the
/// paragraph to answer one key press would make `Ctrl+Left` quadratic in a
/// long document.
final class _Items {
  _Items(this._text, int from) : _scan = from;

  final String _text;
  int _scan;

  final List<int> _starts = <int>[];
  final List<WordBreak> _classes = <WordBreak>[];
  final List<bool> _endsWithZwj = <bool>[];
  final List<bool> _pictographic = <bool>[];

  /// The number of regional indicators in the run ending at each item, which
  /// is the whole of what WB15 and WB16 need. Accumulated while decoding
  /// rather than walked backwards per query, so a row of fifty flags does not
  /// turn each decision into a scan.
  final List<int> _regionalRun = <int>[];

  /// Decodes items until at least [count] exist. False when the text ran out
  /// first.
  bool _ensure(int count) {
    while (_starts.length < count) {
      if (!_decodeOne()) return false;
    }
    return true;
  }

  bool _decodeOne() {
    if (_scan >= _text.length) return false;
    final int start = _scan;
    final int base = _codePointAt(_text, _scan);
    _scan += base > 0xFFFF ? 2 : 1;
    final WordBreak cls = wordBreakOf(base);
    bool endsWithZwj = cls == WordBreak.zwj;
    // A line terminator never absorbs anything: WB4's exception exists so that
    // a combining mark after a newline starts its own segment instead of
    // becoming part of the break.
    if (cls != WordBreak.cr &&
        cls != WordBreak.lf &&
        cls != WordBreak.newline) {
      while (_scan < _text.length) {
        final int codePoint = _codePointAt(_text, _scan);
        final WordBreak tail = wordBreakOf(codePoint);
        if (!_isIgnorable(tail)) break;
        endsWithZwj = tail == WordBreak.zwj;
        _scan += codePoint > 0xFFFF ? 2 : 1;
      }
    }

    final int i = _starts.length;
    _starts.add(start);
    _classes.add(cls);
    _endsWithZwj.add(endsWithZwj);
    _pictographic.add(isExtendedPictographic(base));
    _regionalRun.add(
      cls == WordBreak.regionalIndicator
          ? (i > 0 ? _regionalRun[i - 1] : 0) + 1
          : 0,
    );
    return true;
  }

  /// The class of item [i], or null when [i] is before the start of the window
  /// or past the end of the text. Null is "there is no such character", which
  /// is what every rule that looks two items back or one ahead means by it.
  WordBreak? _classAt(int i) {
    if (i < 0 || !_ensure(i + 1)) return null;
    return _classes[i];
  }

  /// The offset item [i] starts at, or `text.length` past the end.
  int startAt(int i) => _ensure(i + 1) ? _starts[i] : _text.length;

  /// The index of the item starting at [offset], which must be an item start
  /// at or after the window's own start.
  int indexOfOffset(int offset) {
    int i = 0;
    while (_ensure(i + 1) && _starts[i] < offset) {
      i++;
    }
    return i;
  }

  /// Whether a boundary falls before item [i], applying WB3 through WB999 in
  /// the annex's order.
  ///
  /// The order is load-bearing in both directions: WB3 has to beat WB3a so
  /// CRLF stays one segment, and WB13a has to be consulted before WB999 or
  /// `foo_bar` comes apart at the underscore.
  bool breaksBefore(int i) {
    if (i <= 0) return true;
    final WordBreak? previous = _classAt(i - 1);
    final WordBreak? next = _classAt(i);
    if (previous == null || next == null) return true;

    // WB3: never inside CRLF.
    if (previous == WordBreak.cr && next == WordBreak.lf) return false;
    // WB3a, WB3b: always around any other line terminator.
    if (_isNewline(previous) || _isNewline(next)) return true;
    // WB3c: an emoji ZWJ sequence is one segment. Read before WB4's folding
    // could hide the joiner - `_endsWithZwj` is exactly that record.
    if (_endsWithZwj[i - 1] && _pictographic[i]) return false;
    // WB3d: runs of horizontal whitespace stay together.
    if (previous == WordBreak.wSegSpace && next == WordBreak.wSegSpace) {
      return false;
    }
    // WB4 is the item structure itself; see the class comment.

    // WB5: letters stick to letters.
    if (_isAHLetter(previous) && _isAHLetter(next)) return false;
    // WB6, WB7: a letter, a joining punctuation and another letter - `e.g.`,
    // `example.com`, `don't`. Both directions are needed, because the rules
    // are stated over three characters and the scan only ever decides one
    // boundary at a time.
    if (_isAHLetter(previous) &&
        _isMidLetterQ(next) &&
        _isAHLetter(_classAt(i + 1))) {
      return false;
    }
    if (_isMidLetterQ(previous) &&
        _isAHLetter(next) &&
        _isAHLetter(_classAt(i - 2))) {
      return false;
    }
    // WB7a, WB7b, WB7c: Hebrew uses the quotation marks inside words.
    if (previous == WordBreak.hebrewLetter && next == WordBreak.singleQuote) {
      return false;
    }
    if (previous == WordBreak.hebrewLetter &&
        next == WordBreak.doubleQuote &&
        _classAt(i + 1) == WordBreak.hebrewLetter) {
      return false;
    }
    if (previous == WordBreak.doubleQuote &&
        next == WordBreak.hebrewLetter &&
        _classAt(i - 2) == WordBreak.hebrewLetter) {
      return false;
    }
    // WB8, WB9, WB10: digits, and digits against letters - `3a`, `A3`.
    if (previous == WordBreak.numeric && next == WordBreak.numeric) {
      return false;
    }
    if (_isAHLetter(previous) && next == WordBreak.numeric) return false;
    if (previous == WordBreak.numeric && _isAHLetter(next)) return false;
    // WB11, WB12: the separators inside `3,456.789`.
    if (_isMidNumQ(previous) &&
        next == WordBreak.numeric &&
        _classAt(i - 2) == WordBreak.numeric) {
      return false;
    }
    if (previous == WordBreak.numeric &&
        _isMidNumQ(next) &&
        _classAt(i + 1) == WordBreak.numeric) {
      return false;
    }
    // WB13: Katakana words as a block, because Japanese has no spaces.
    if (previous == WordBreak.katakana && next == WordBreak.katakana) {
      return false;
    }
    // WB13a, WB13b: the connectors, which is what keeps `foo_bar` and
    // `snake_case_2` in one piece.
    if (next == WordBreak.extendNumLet &&
        (_isAHLetter(previous) ||
            previous == WordBreak.numeric ||
            previous == WordBreak.katakana ||
            previous == WordBreak.extendNumLet)) {
      return false;
    }
    if (previous == WordBreak.extendNumLet &&
        (_isAHLetter(next) ||
            next == WordBreak.numeric ||
            next == WordBreak.katakana)) {
      return false;
    }
    // WB15, WB16: a flag is a *pair* of regional indicators, so the break is
    // suppressed only on an odd count - four indicators are two flags, not one
    // uneditable blob.
    if (next == WordBreak.regionalIndicator && _regionalRun[i - 1].isOdd) {
      return false;
    }
    // WB999.
    return true;
  }
}

bool _isIgnorable(WordBreak cls) =>
    cls == WordBreak.extend || cls == WordBreak.format || cls == WordBreak.zwj;

bool _isNewline(WordBreak cls) =>
    cls == WordBreak.newline || cls == WordBreak.cr || cls == WordBreak.lf;

/// The AHLetter macro of the annex.
bool _isAHLetter(WordBreak? cls) =>
    cls == WordBreak.aLetter || cls == WordBreak.hebrewLetter;

/// `(MidLetter | MidNumLetQ)`, the left half of WB6 and WB7. Single_Quote is
/// in it, which is the whole reason `don't` survives.
bool _isMidLetterQ(WordBreak? cls) =>
    cls == WordBreak.midLetter ||
    cls == WordBreak.midNumLet ||
    cls == WordBreak.singleQuote;

/// `(MidNum | MidNumLetQ)`, the separator set of WB11 and WB12.
bool _isMidNumQ(WordBreak? cls) =>
    cls == WordBreak.midNum ||
    cls == WordBreak.midNumLet ||
    cls == WordBreak.singleQuote;

// ---------------------------------------------------------------------------
// Item geometry over the raw string
// ---------------------------------------------------------------------------

/// The start of the item containing [index], which must be a code point start.
///
/// A base character starts its own item. An extender does not, unless the run
/// it belongs to begins at the start of the text or right after a line
/// terminator - WB4's exception.
int _itemStartAtOrBefore(String text, int index) {
  if (index <= 0) return 0;
  if (index >= text.length) return text.length;
  if (!_isIgnorable(wordBreakOf(_codePointAt(text, index)))) return index;
  int runStart = index;
  while (runStart > 0) {
    final int candidate = _startOfCodePointBefore(text, runStart);
    final WordBreak cls = wordBreakOf(_codePointAt(text, candidate));
    if (_isIgnorable(cls)) {
      runStart = candidate;
      continue;
    }
    // A line terminator absorbs nothing, so the run after it is its own item.
    return _isNewline(cls) ? runStart : candidate;
  }
  return 0;
}

/// The start of the item before the one starting at [offset].
int _previousItemStart(String text, int offset) {
  if (offset <= 0) return 0;
  return _itemStartAtOrBefore(text, _startOfCodePointBefore(text, offset));
}

/// An offset far enough before [start] that a scan beginning there sees the
/// same items, and the same rule context, as a scan of the whole string.
///
/// Only three things reach behind the immediately preceding item: WB7, WB7c
/// and WB11 look two items back, and WB15/WB16 need the parity of the run of
/// regional indicators, which has no fixed length. So: back over the whole
/// regional-indicator run, then two items more. Everything else in the rule
/// set is local, which is what makes a bounded window sound rather than
/// optimistic.
int _safeStart(String text, int start) {
  int position = start;
  while (position > 0) {
    final int candidate = _previousItemStart(text, position);
    if (wordBreakOf(_codePointAt(text, candidate)) !=
        WordBreak.regionalIndicator) {
      break;
    }
    position = candidate;
  }
  for (int i = 0; i < 2 && position > 0; i++) {
    position = _previousItemStart(text, position);
  }
  return position;
}

bool _isHighSurrogate(int unit) => unit >= 0xD800 && unit <= 0xDBFF;

bool _isLowSurrogate(int unit) => unit >= 0xDC00 && unit <= 0xDFFF;

/// The code point starting at [index]. An unpaired surrogate is returned as
/// itself; its Word_Break is Other, so it segments on both sides rather than
/// throwing.
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

int _startOfCodePointBefore(String text, int index) {
  if (index >= 2 &&
      _isLowSurrogate(text.codeUnitAt(index - 1)) &&
      _isHighSurrogate(text.codeUnitAt(index - 2))) {
    return index - 2;
  }
  return index - 1;
}
