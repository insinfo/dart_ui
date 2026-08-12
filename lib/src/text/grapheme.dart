/// Grapheme cluster boundaries, per UAX #29 (extended grapheme clusters).
///
/// A "character" as a user thinks of it is almost never one code point. `é`
/// may be one code point or two; a flag is two regional indicators; a family
/// emoji is up to seven code points joined by ZWJ; Devanagari `क्षि` is a
/// consonant, a virama, a consonant and a vowel sign that render as one shape.
/// The unit the *user* manipulates is the grapheme cluster, and every caret
/// move, backspace, selection extension and hit test has to agree on where
/// those clusters start and end.
///
/// The failure this prevents is specific and ugly: a caret that steps by code
/// point lands *inside* a cluster, and the next keystroke deletes half of a
/// character - leaving a lone combining accent hanging off the previous
/// letter, or a broken surrogate that no longer encodes anything. Doing it by
/// UTF-16 unit is worse still. So this is not a nicety for exotic scripts; it
/// is what makes backspace work on `👨‍👩‍👧`.
///
/// ## Indices
///
/// Every index in this file is a UTF-16 offset into the Dart string, not a
/// code point index, because that is what `String.substring`, `GlyphRun`'s
/// cluster array and every text field's selection model use. Converting at
/// the boundary would just move the off-by-one somewhere less visible.
///
/// ## The property table
///
/// [_graphemeTable] packs three properties of every code point in
/// U+0000..U+10FFFF - Grapheme_Cluster_Break, Extended_Pictographic (rule
/// GB11) and Indic_Conjunct_Break (rule GB9c) - taken from
/// `ucd.nounihan.flat.xml` of the Unicode Character Database 17.0.0. That file
/// rather than the three separate `.txt` files because it is the derived view,
/// with every default already applied, so the code points those files leave
/// implicit are present here as real entries rather than as a fallback that
/// could silently mis-classify.
///
/// It is a *snapshot*: a code point assigned after 17.0.0 reads as Other,
/// which degrades to "breaks on both sides" - a caret that steps past it one
/// code point at a time, rather than anything corrupting.
///
/// See [_RangeTable] for the encoding, and the class comment there for why it
/// is a string rather than a list literal.
library;

import 'dart:typed_data';

// ---------------------------------------------------------------------------
// Property lookup
// ---------------------------------------------------------------------------

/// Grapheme_Cluster_Break property values.
///
/// Named after the UAX #29 values. `hangulL` and friends are spelled out
/// because `L` alone would collide with the bidi class of the same name for
/// anyone reading the two files side by side.
enum GraphemeClass {
  other,
  cr,
  lf,
  control,
  extend,
  zwj,
  regionalIndicator,
  prepend,
  spacingMark,
  hangulL,
  hangulV,
  hangulT,
  hangulLV,
  hangulLVT,
}

/// Indic_Conjunct_Break, needed only by rule GB9c.
enum _Incb { none, linker, consonant, extend }

/// A run-length coded map from code point to a small integer.
///
/// The alternative was a `const List<int>` of a few thousand entries per
/// property, which costs a few thousand lines of source and a constant-pool
/// entry per element. This is one string literal: each run contributes a
/// varint delta from the previous run's start and a varint value, six bits per
/// character in the standard base64 alphabet (chosen because none of its
/// characters need escaping inside a Dart string literal).
///
/// Decoding is deferred to first lookup, so a program that never lays out text
/// never pays for it.
final class _RangeTable {
  _RangeTable(this._data);

  final String _data;

  Int32List? _starts;
  late Int32List _values;

  int lookup(int codePoint) {
    final Int32List starts = _starts ??= _decode();
    // Binary search for the last run whose start is <= the code point. Runs
    // tile the whole code space starting at 0, so there is always one.
    int low = 0;
    int high = starts.length - 1;
    while (low < high) {
      final int mid = (low + high + 1) >> 1;
      if (starts[mid] <= codePoint) {
        low = mid;
      } else {
        high = mid - 1;
      }
    }
    return _values[low];
  }

  Int32List _decode() {
    // Two passes rather than a growable list: the first counts runs so both
    // typed arrays are allocated exactly once at the right size.
    int runs = 0;
    for (int i = 0; i < _data.length; i++) {
      if (_sixBits(_data.codeUnitAt(i)) < 32) runs++;
    }
    // A run is two varints, so the number of terminating characters is twice
    // the number of runs.
    runs >>= 1;

    final Int32List starts = Int32List(runs);
    final Int32List values = Int32List(runs);
    int position = 0;
    int start = 0;
    for (int run = 0; run < runs; run++) {
      int delta = 0;
      int shift = 0;
      while (true) {
        final int unit = _sixBits(_data.codeUnitAt(position++));
        delta |= (unit & 31) << shift;
        shift += 5;
        if (unit < 32) break;
      }
      int value = 0;
      shift = 0;
      while (true) {
        final int unit = _sixBits(_data.codeUnitAt(position++));
        value |= (unit & 31) << shift;
        shift += 5;
        if (unit < 32) break;
      }
      start += delta;
      starts[run] = start;
      values[run] = value;
    }
    _values = values;
    return starts;
  }

  /// Inverse of the base64 alphabet, as arithmetic rather than a lookup table
  /// so the decoder needs no state of its own.
  static int _sixBits(int codeUnit) {
    // The base64 alphabet, in order: A-Z, a-z, 0-9, '+', '/'.
    if (codeUnit >= 0x41 && codeUnit <= 0x5A) return codeUnit - 0x41;
    if (codeUnit >= 0x61 && codeUnit <= 0x7A) return codeUnit - 0x61 + 26;
    if (codeUnit >= 0x30 && codeUnit <= 0x39) return codeUnit - 0x30 + 52;
    if (codeUnit == 0x2B) return 62;
    return 63;
  }
}

// Packed as `class | extendedPictographic << 4 | indicConjunctBreak << 5`, so
// the three properties GB9c and GB11 need share one table and one search.
const int _classMask = 0xF;
const int _pictBit = 0x10;
const int _incbShift = 5;

final _RangeTable _graphemeProperties = _RangeTable(_graphemeTable);

/// The Grapheme_Cluster_Break value of [codePoint].
GraphemeClass graphemeClassOf(int codePoint) =>
    GraphemeClass.values[_graphemeProperties.lookup(codePoint) & _classMask];

/// Whether [codePoint] has Extended_Pictographic=Yes.
bool isExtendedPictographic(int codePoint) =>
    _graphemeProperties.lookup(codePoint) & _pictBit != 0;

// ---------------------------------------------------------------------------
// The break algorithm
// ---------------------------------------------------------------------------

/// The scanning state that rules GB9c, GB11 and GB12/GB13 need.
///
/// All three look further back than the immediately preceding character - at
/// a run of regional indicators, at an `ExtPict Extend* ZWJ` prefix, at an
/// Indic consonant separated from the current one by a linker. Carrying three
/// small integers forward is what keeps the scan linear instead of making
/// every position re-examine its history.
final class _BreakState {
  /// How many regional indicators end at the current position (GB12, GB13).
  int regionalIndicators = 0;

  /// 0 = nothing, 1 = matched `ExtPict Extend*`, 2 = matched
  /// `ExtPict Extend* ZWJ` (GB11).
  int pictSequence = 0;

  /// 0 = nothing, 1 = matched `Consonant [Extend|Linker]*`, 2 = the same with
  /// at least one Linker, which is what GB9c requires (GB9c).
  int conjunct = 0;

  /// The class of the character the scan last consumed.
  GraphemeClass previous = GraphemeClass.other;

  /// The packed properties of that same character.
  int previousPacked = 0;

  void reset() {
    regionalIndicators = 0;
    pictSequence = 0;
    conjunct = 0;
    previous = GraphemeClass.other;
    previousPacked = 0;
  }

  /// Whether a cluster boundary falls between the last consumed character and
  /// [packed], applying GB3 through GB999 in rule order.
  bool breaksBefore(int packed) {
    final GraphemeClass next = GraphemeClass.values[packed & _classMask];
    final GraphemeClass prev = previous;

    // GB3: CR x LF. Checked before GB4/GB5 so the pair stays one cluster.
    if (prev == GraphemeClass.cr && next == GraphemeClass.lf) return false;
    // GB4, GB5: controls are clusters of their own, on both sides.
    if (prev == GraphemeClass.control ||
        prev == GraphemeClass.cr ||
        prev == GraphemeClass.lf) {
      return true;
    }
    if (next == GraphemeClass.control ||
        next == GraphemeClass.cr ||
        next == GraphemeClass.lf) {
      return true;
    }
    // GB6, GB7, GB8: conjoining jamo form one Hangul syllable.
    if (prev == GraphemeClass.hangulL &&
        (next == GraphemeClass.hangulL ||
            next == GraphemeClass.hangulV ||
            next == GraphemeClass.hangulLV ||
            next == GraphemeClass.hangulLVT)) {
      return false;
    }
    if ((prev == GraphemeClass.hangulLV || prev == GraphemeClass.hangulV) &&
        (next == GraphemeClass.hangulV || next == GraphemeClass.hangulT)) {
      return false;
    }
    if ((prev == GraphemeClass.hangulLVT || prev == GraphemeClass.hangulT) &&
        next == GraphemeClass.hangulT) {
      return false;
    }
    // GB9, GB9a, GB9b: extending characters, spacing marks and prepends.
    if (next == GraphemeClass.extend || next == GraphemeClass.zwj) return false;
    if (next == GraphemeClass.spacingMark) return false;
    if (prev == GraphemeClass.prepend) return false;
    // GB9c: an Indic conjunct. Without this, backspace inside `क्षि` would
    // split the conjunct into two half-rendered consonants.
    if (conjunct == 2 && _incbOf(packed) == _Incb.consonant) return false;
    // GB11: emoji joined by ZWJ, which is what holds `👨‍👩‍👧` together.
    if (pictSequence == 2 && packed & _pictBit != 0) return false;
    // GB12, GB13: a flag is an *odd*-indexed regional indicator joining the
    // one before it, so a run of four is two flags rather than one blob.
    if (next == GraphemeClass.regionalIndicator && regionalIndicators.isOdd) {
      return false;
    }
    // GB999.
    return true;
  }

  /// Folds [packed] into the state, after [breaksBefore] has been consulted.
  void consume(int packed) {
    final GraphemeClass next = GraphemeClass.values[packed & _classMask];

    regionalIndicators =
        next == GraphemeClass.regionalIndicator ? regionalIndicators + 1 : 0;

    if (packed & _pictBit != 0) {
      pictSequence = 1;
    } else if (pictSequence == 1 && next == GraphemeClass.extend) {
      // stays 1: Extend* is still open
    } else if (pictSequence == 1 && next == GraphemeClass.zwj) {
      pictSequence = 2;
    } else {
      pictSequence = 0;
    }

    final _Incb incb = _incbOf(packed);
    if (incb == _Incb.consonant) {
      conjunct = 1;
    } else if (conjunct != 0 && incb == _Incb.linker) {
      conjunct = 2;
    } else if (conjunct != 0 && incb == _Incb.extend) {
      // stays: [Extend|Linker]* is still open
    } else {
      conjunct = 0;
    }

    previous = next;
    previousPacked = packed;
  }

  static _Incb _incbOf(int packed) => _Incb.values[(packed >> _incbShift) & 3];
}

/// Grapheme cluster boundaries over a Dart string.
///
/// Stateless and static: the algorithm carries no configuration, and giving it
/// an instance would only invite someone to cache one per text field.
final class GraphemeBreaks {
  const GraphemeBreaks._();

  /// Every cluster boundary in [text], ascending, including 0 and
  /// `text.length` (rules GB1 and GB2).
  ///
  /// Empty text has a single boundary at 0 rather than two: GB1 and GB2
  /// coincide there, and returning `[0, 0]` would make every consumer that
  /// pairs up adjacent entries produce one empty cluster.
  static List<int> boundaries(String text) {
    final List<int> result = <int>[0];
    if (text.isEmpty) return result;

    final _BreakState state = _BreakState();
    int index = 0;
    bool first = true;
    while (index < text.length) {
      final int codePoint = _codePointAt(text, index);
      final int packed = _graphemeProperties.lookup(codePoint);
      if (!first && state.breaksBefore(packed)) result.add(index);
      state.consume(packed);
      first = false;
      index += codePoint > 0xFFFF ? 2 : 1;
    }
    result.add(text.length);
    return result;
  }

  /// The clusters of [text], in order.
  static List<String> clusters(String text) {
    final List<int> marks = boundaries(text);
    return <String>[
      for (int i = 1; i < marks.length; i++)
        text.substring(marks[i - 1], marks[i]),
    ];
  }

  /// Whether [index] is a cluster boundary.
  ///
  /// An index in the middle of a surrogate pair is never a boundary, which is
  /// the answer a caret wants even though UAX #29 is written in code points
  /// and does not have to say so.
  static bool isBoundary(String text, int index) {
    if (index <= 0 || index >= text.length) {
      return index == 0 || index == text.length;
    }
    if (_isLowSurrogate(text.codeUnitAt(index)) &&
        _isHighSurrogate(text.codeUnitAt(index - 1))) {
      return false;
    }
    final _BreakState state = _seekTo(text, index);
    return state.breaksBefore(
      _graphemeProperties.lookup(_codePointAt(text, index)),
    );
  }

  /// The first cluster boundary strictly after [index], clamped to
  /// `text.length`.
  static int next(String text, int index) {
    int position = index < 0 ? 0 : index;
    if (position >= text.length) return text.length;
    // Step off a mid-surrogate index before anything else, so a caller that
    // was handed a bad offset gets a valid one rather than an exception.
    if (_isLowSurrogate(text.codeUnitAt(position)) &&
        position > 0 &&
        _isHighSurrogate(text.codeUnitAt(position - 1))) {
      position++;
    }
    final _BreakState state = _seekTo(text, position);
    while (position < text.length) {
      final int codePoint = _codePointAt(text, position);
      final int packed = _graphemeProperties.lookup(codePoint);
      final int width = codePoint > 0xFFFF ? 2 : 1;
      state.consume(packed);
      position += width;
      if (position >= text.length) return text.length;
      if (state.breaksBefore(
        _graphemeProperties.lookup(_codePointAt(text, position)),
      )) {
        return position;
      }
    }
    return text.length;
  }

  /// The last cluster boundary strictly before [index], clamped to 0.
  static int previous(String text, int index) {
    int position = index > text.length ? text.length : index;
    if (position <= 0) return 0;
    do {
      position -= _isLowSurrogate(text.codeUnitAt(position - 1)) &&
              position >= 2 &&
              _isHighSurrogate(text.codeUnitAt(position - 2))
          ? 2
          : 1;
    } while (position > 0 && !isBoundary(text, position));
    return position;
  }

  /// A [_BreakState] positioned as if the scan had just consumed the character
  /// ending at [index].
  ///
  /// Rebuilt from a *bounded* starting point rather than from the start of the
  /// string: only GB9c, GB11 and GB12/GB13 look back at all, and each of them
  /// looks back over a run of extenders, joiners, jamo or regional indicators
  /// plus the one character that opened it. Walking back over that run and one
  /// more character reaches a position where the state is provably empty, so
  /// caret movement in a long paragraph costs the length of the cluster rather
  /// than the length of the paragraph.
  static _BreakState _seekTo(String text, int index) {
    final _BreakState state = _BreakState();
    if (index <= 0) return state;

    int start = index;
    while (start > 0) {
      final int previousStart = _startOfCodePointBefore(text, start);
      final GraphemeClass cls =
          graphemeClassOf(_codePointAt(text, previousStart));
      final bool continuesRun = cls == GraphemeClass.extend ||
          cls == GraphemeClass.zwj ||
          cls == GraphemeClass.spacingMark ||
          cls == GraphemeClass.prepend ||
          cls == GraphemeClass.regionalIndicator ||
          cls == GraphemeClass.hangulL ||
          cls == GraphemeClass.hangulV ||
          cls == GraphemeClass.hangulT ||
          cls == GraphemeClass.hangulLV ||
          cls == GraphemeClass.hangulLVT;
      start = previousStart;
      if (!continuesRun) break;
    }

    int position = start;
    while (position < index) {
      final int codePoint = _codePointAt(text, position);
      state.consume(_graphemeProperties.lookup(codePoint));
      position += codePoint > 0xFFFF ? 2 : 1;
    }
    return state;
  }
}

bool _isHighSurrogate(int unit) => unit >= 0xD800 && unit <= 0xDBFF;

bool _isLowSurrogate(int unit) => unit >= 0xDC00 && unit <= 0xDFFF;

/// The code point starting at [index].
///
/// An unpaired surrogate is returned as itself. UAX #29 gives it
/// Grapheme_Cluster_Break=Control, so it becomes its own cluster - the right
/// answer for text that arrived damaged, and better than throwing on it.
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

// ---------------------------------------------------------------------------
// Generated table
// ---------------------------------------------------------------------------

/// Grapheme_Cluster_Break, Extended_Pictographic and Indic_Conjunct_Break for
/// the whole code space, generated from UCD 17.0.0. See [_RangeTable].
const String _graphemeTable =
    'ADKCBDCBBDSA/CDhBAJQBADDBQBAxSkDwDAzIkDHAnIkDtBABkDBABkDCABkDCABkDBA4BHG'
    'AKkDLABDBAuBkDVAQkDBAlDkDHHBABkDGACkDCABkDEAhBHBABkDBAekDbA7CkDLA6BkDJAJ'
    'kDBAYkDEABkDJABkDDABkDFArBkDDA0BHCAFkDJAqBkDYHBkDgBIBARgClBkDBIBkDBABIDk'
    'DIIEkBBICABkDHgCIACkDCAUgCIABkDBICARgCUABgCHABgCBADgCEACkDBABkDBICkDEACI'
    'CACICkBBAJkDBAEgCCABgCBACkDCAMgCCAMkDBACkDCIBA4BkDBABIDkDCAEkDCACkDDADkD'
    'BAekDCADkDBALkDCIBARgCUABgCHABgCCABgCFACkDBABIDkDFABkDCIBABICkBBAUkDCAVg'
    'CBkDGABkDBICARgCUABgCHABgCCABgCFACkDBABkDCIBkDEACICACICkBBAHkDDAEgCCABgC'
    'BACkDCANgCBAQkDBA7BkDBIBkDBICADIDABIDkDBAJkDBAoBkDBIDkDBAQgCUABgCQACkDBA'
    'BkDDIEABkDDABkDDkBBAHkDCABgCDAHkDCAdkDBICA4BkDBABIBkDCIBkDBICABkDDABkDEA'
    'HkDCALkDCAPIBAMkDCICARgCmBkDCABkDBICkDEABIDABIDkBBHBAIkDBAKkDCAdkDBICAmC'
    'kDBAEkDBICkDDABkDBABIHkDBASICA9BkDBABIBkDHAMkDIAiDkDBABIBkDJALkDHApCkDCA'
    'bkDBABkDBABkDBAEICAxBkDOIBkDFABkDCAFkDLABkDkBAJkDBA5BgCrBACkDEIBkDGABkBB'
    'kDBICkDCgCBAQgCGICkDCgCEkDDgCBADgCCAHgCDkDEgCNkDBABIBkDCAGkDBgCBAOkDBAiD'
    'JgDKoCL4CA9KkDDAydkDEAckDDAdkDCAekDCAMgC0BkDCIBkDHIIkDBICkDJkBBkDBAJkDBA'
    'tBkDDDBkDBA1DkDCAiBkDBA2DkDDIEkDCIDAEICkDBIGkDDA7GkDCICkDBAEgC1BIBkDBIBk'
    'DHABkBBABkDBACkDIIGkDKACkDBAwBkDuBACkDMAUkDEIBAGgCCAGgChBkDKIEkDCkBBgCIA'
    'ekDJAMkDCIBgCeIBkDEICkDDkBBkDCgCCALgCDAoBkDBIBkDCIDkDBIBkDFAwBIIkDIICkDC'
    'A4EkDDABkDNIBkDHAEkDBAGkDBACIBkDCAmGkDgCArQDBEBlDBDCAYDHANQBAMQBAWDQAgDk'
    'DhBAxBQBAWQBA6CQGAPQCAvLQCAMQBAmFQBAZQLAEQDAnGQBAnHQCAKQBAJQBA6BQEABQFAJ'
    'QBACQBACQCACQBAEQBACQBABQCACQBADQBADQCAIQDAFQBABQBAFQMALQCACQBABQCABQBAS'
    'QBACQCASQGABQBABQCADQCAFQBACQCAEQCALQCAFQCACQBAFQCABQBABQCAUQCAFQGABQEAC'
    'QBAEQBACQBACQGABQBACQBABQBABQBAGQBADQBAGQBAKQCAPQBACQBAEQBABQBAEQDABQBAL'
    'QCAwBQDAJQBAOQBAOQBA0LQCAvOQDATQCAzBQBAEQBA5MkDDAtEkDBAgDkDgBAqRkDGQBAMQ'
    'BA7CkDCA8PQBABQBA1+ckDEABkDKAgBkDCAwCkDCAwIkDBADkDBAEkDBAXICkDCIBAEkDBAz'
    'CICAyBIQkDCAakDSANkDBAmBkDIAZkDLIBkDBAMJdADkDDIBAFgCDADgCkBkDBICkDEICkDC'
    'ICkBBAfgCFkDBABgCJAKgCFAqBkDGICkDCICkDCAMkDBAIkDBIBASgCQABgCDAGgCBABkDBA'
    'BgCCAwBkDBABkDDACkDCAFkDCABkDBAegCLIBkDCICAFIBkBBApGgCbAIICkDBICkDBICABI'
    'BkDBASMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMB'
    'NbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMB'
    'NbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMB'
    'NbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMB'
    'NbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMB'
    'NbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMB'
    'NbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMB'
    'NbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMB'
    'NbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMB'
    'NbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMB'
    'NbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMB'
    'NbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMB'
    'NbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMB'
    'NbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMB'
    'NbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMB'
    'NbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMB'
    'NbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMB'
    'NbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMB'
    'NbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMB'
    'NbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMB'
    'NbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMB'
    'NbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMBNbMB'
    'NbMBNbMBNbMBNbMBNbAMKXAELxBAi5IkDBAhXkDQAQkDQAvGDBA+EkDCAwCDMAhQkDBAiHkD'
    'BA1EkDFAl0BgCBkDDABkDCAFkDEgCEABgCDABgCdACkDDAEkBBAlFkDCA9RkDEAhCkDFA9Jk'
    'DCAtCkDGAmCkDLAxBkDEA6DIBkDBIBA1BkDPApBkDBACkDCAKkDDIBAtBIDkDEICkDCACHBA'
    'EkDBAKHBAyBkDDgCkBkDFIBkDGkBBkDBAPgCBICgCBArBkDBAMkDCIBAwBIDkDJIBkDBABHC'
    'AFkDEABIBkDBA8CIDkDDICkDEAGkDBACkDBA9EkDBIDkDIAVkDCICA3BkDCABkDBIBkDBIEA'
    'CICACICkDBAJkDBAKICACkDHADkDFALgCKABgCBACgCBABgCmBACkDBICkDGABkDBACkDBAB'
    'kDDIBABICkDCkBBHBkDBAOkDCAyCIDkDIICkDDIBkDBAXkDBAxCkDBICkDGIBkDBICkDBIBk'
    'DCIBkDCArHkDBICkDEACIEkDCIBkDCAbkDCAyCIDkDIICkDBIBkDCAqDkDBIBkDBICkDIAlD'
    'kDBIBkDBACkDEIBkDFAgIIDkDJIBkDCAlGgCHACgCBACgCIABgCCABgCYkDBIFABICACkDDk'
    'BBHBIBHBIBkDBAtEIDkDEACkDCIEkDBADIBAbgCBkDKgCoBkDGIBABkDEAIkBBAIgCBkDGIC'
    'kDDgCoBHGkDNIBkDBkBBAmGkDBIBkDDIBkDBIBAnGIBkDHABkDGIBkDBAyCkDWABIBkDHIBk'
    'DCIBkDCA6DkDGADkDBABkDCABkDHHBkDBAiCIFABkDCABICkDBIBkDBA7KkDCICAJkDCHBIB'
    'gCNABgCiBICkDFADICkDCkBBAXkDBA1mFDQkDBAGkDPAomLkDMIDkDDAguCkDFA7BkDHAsRK'
    'BADKEAkPkDBABI3BAHkDEAxCkDBALkDCArlTkDCABDEA8yEkDuBACkDXA+QkDFADkDGDIkDI'
    'ACkDHAekDEA0EkDDA79BkD3BAEkDyBAIkDBAOkDBAWkDFABkDPAwqBkDHABkDRACkDHABkDC'
    'ABkDFAkDkDBAgFkDHA3LkDBA9BkDEA8PkDEA+HkDCAzHkDBACkDBAHkDCAFkDBA6OkDHAtDk'
    'DHA51BQBAnBQEAkDQMAPQCAPQBAOQCAlBQKAwDQCAMQCAOQBACQKATQ4BGaABQPAKQBAUQBA'
    'CQJABQEAJQXAGQ8FACQwDACQCABQDACQzCACQDABQEkDFQ+HABQ/BALQGABQYAHQCACQIAMQ'
    'BACQEACQBAEQCANQCACQBAIQCAJQBAFQDAMQDAIQDACQBABQBAEQBAGQBADQBAGQ2CAwBQmC'
    'AFQIACQRADQBABQGACQNA6GQmBAMQEA4BQIAKQGAoBQIAeQCAMQEACQOAJQnBAMQvBABQKAB'
    'Q5FA4CQIAOQyEAgIQ+fAiggYDgBkDgDDgEkDwHDwwDA';
