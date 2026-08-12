/// Line breaking, UAX #14.
///
/// Given a paragraph, this answers "where may a line end?". It does not decide
/// where a line *does* end - that needs the measured widths, which live in the
/// layout - it produces the set of legal positions, and marks the ones that
/// are not optional.
///
/// Splitting on spaces is the tempting shortcut and it is wrong in ways that
/// are easy to see and hard to fix later. Chinese and Japanese have no spaces
/// at all and wrap between almost any two ideographs. A space-splitter breaks
/// `(a` after the bracket, leaving a lone `(` hanging at the end of a line;
/// breaks `1 000` in the wrong place; breaks between a number and its unit;
/// separates a closing quotation mark from what it closes; and misses the
/// mandatory break at U+2028, so an explicit line separator does nothing.
/// Each of those is a small visual defect that a reader notices without being
/// able to say why the text looks amateurish.
///
/// ## Which rules are implemented
///
/// LB1 through LB31, as published for Unicode 17.0.0 - including the rules
/// added since the version most implementations stopped at: LB15a-LB15d
/// (unresolved quotation marks and the decimal mark after a space), LB19a
/// (quotation marks not surrounded by East Asian characters), LB20a
/// (word-initial hyphen), LB21b, LB23a, LB28a (Brahmic orthographic
/// syllables), LB30a (regional indicator pairs) and LB30b (emoji modifiers).
///
/// What is deliberately **not** here is tailoring. LB1 lets an implementation
/// resolve AI, CJ, SA, SG and XX "depending on criteria outside the scope of
/// this algorithm"; this file applies the default resolution the annex
/// specifies for their absence, baked into the property table (see below), and
/// offers no locale hook. Korean space-based breaking, Japanese loose/strict
/// modes and CSS `line-break` are all tailorings of the same shape, and each
/// wants a data table rather than a code path, so the place to add them is the
/// table, not the rules.
///
/// ## Indices
///
/// Positions are UTF-16 offsets, matching `GlyphRun.clusters` and the bidi
/// levels, so a line can be sliced out of the paragraph string directly.
///
/// ## The property table
///
/// [_lineBreakClassTable] is the Line_Break property of every code point in
/// U+0000..U+10FFFF, taken from `ucd.nounihan.flat.xml` of the Unicode
/// Character Database 17.0.0, with **LB1 already applied**: AI, SG and XX are
/// stored as AL, CJ as NS, and SA as CM or AL according to its General
/// Category. That is why [LineBreakClass] has no member for those five - a
/// class that cannot reach the rules cannot be mishandled by them.
///
/// The XML rather than `LineBreak.txt` because it is the derived view, and the
/// derivation is not obvious from the text file: its header reads as though
/// every unassigned code point in U+1F000..U+1FAFF defaults to ID, while the
/// derived value of U+1F8FF is in fact XX. Hand-applying the block defaults
/// gets that wrong, and the only symptom is that one reserved code point wraps
/// like an ideograph instead of like a letter - which nothing would ever
/// notice.
///
/// [_lineBreakFlagTable] carries the three non-Line_Break properties the rules
/// need: East_Asian_Width in {F, W, H} for LB19a and LB30, the General
/// Category Pi/Pf distinction among QU characters for LB15a/LB15b/LB19, and
/// Extended_Pictographic on unassigned code points for LB30b.
///
/// Both tables cover the whole code space. They are a snapshot of 17.0.0: a
/// code point assigned later reads as whatever 17.0.0 said about its block,
/// which outside the CJK and emoji ranges is AL - it wraps like a letter.
library;

import 'dart:typed_data';

// ---------------------------------------------------------------------------
// Property lookup
// ---------------------------------------------------------------------------

/// Line_Break property values, after the LB1 resolution described above.
///
/// The order is the one the generated table encodes; changing it silently
/// re-labels every character, so the table has to be regenerated with it.
enum LineBreakClass {
  /// Aksara (Brahmic).
  ak,

  /// Ordinary alphabetic.
  al,

  /// Aksara pre-base.
  ap,

  /// Aksara start.
  as_,

  /// Break opportunity before and after (em dash).
  b2,

  /// Break after.
  ba,

  /// Break before.
  bb,

  /// Mandatory break.
  bk,

  /// Contingent break (an embedded object).
  cb,

  /// Closing punctuation.
  cl,

  /// Combining mark.
  cm,

  /// Closing parenthesis.
  cp,

  /// Carriage return.
  cr,

  /// Emoji base.
  eb,

  /// Emoji modifier.
  em,

  /// Exclamation or interrogation.
  ex,

  /// Non-breaking glue.
  gl,

  /// Hangul LV syllable.
  h2,

  /// Hangul LVT syllable.
  h3,

  /// Unambiguous hyphen.
  hh,

  /// Hebrew letter.
  hl,

  /// Hyphen.
  hy,

  /// Ideographic.
  id,

  /// Inseparable (ellipsis).
  in_,

  /// Infix numeric separator.
  is_,

  /// Hangul L jamo.
  jl,

  /// Hangul T jamo.
  jt,

  /// Hangul V jamo.
  jv,

  /// Line feed.
  lf,

  /// Next line.
  nl,

  /// Non-starter.
  ns,

  /// Numeric.
  nu,

  /// Opening punctuation.
  op,

  /// Postfix numeric.
  po,

  /// Prefix numeric.
  pr,

  /// Quotation.
  qu,

  /// Regional indicator.
  ri,

  /// Space.
  sp,

  /// Symbol allowing break after.
  sy,

  /// Virama final.
  vf,

  /// Virama.
  vi,

  /// Word joiner.
  wj,

  /// Zero width space.
  zw,

  /// Zero width joiner.
  zwj,
}

/// A run-length coded map from code point to a small integer.
///
/// Deliberately duplicated in `bidi.dart` and `grapheme.dart` rather than
/// shared; see the copy in `bidi.dart` for the encoding and the reasoning.
final class _RangeTable {
  _RangeTable(this._data);

  final String _data;

  Int32List? _starts;
  late Int32List _values;

  int lookup(int codePoint) {
    final Int32List starts = _starts ??= _decode();
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
    int terminators = 0;
    for (int i = 0; i < _data.length; i++) {
      if (_sixBits(_data.codeUnitAt(i)) < 32) terminators++;
    }
    final int runs = terminators >> 1;

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

  static int _sixBits(int codeUnit) {
    // The base64 alphabet, in order: A-Z, a-z, 0-9, '+', '/'.
    if (codeUnit >= 0x41 && codeUnit <= 0x5A) return codeUnit - 0x41;
    if (codeUnit >= 0x61 && codeUnit <= 0x7A) return codeUnit - 0x61 + 26;
    if (codeUnit >= 0x30 && codeUnit <= 0x39) return codeUnit - 0x30 + 52;
    if (codeUnit == 0x2B) return 62;
    return 63;
  }
}

final _RangeTable _classes = _RangeTable(_lineBreakClassTable);
final _RangeTable _flags = _RangeTable(_lineBreakFlagTable);

const int _flagEastAsian = 1;
const int _flagUnassignedPictographic = 2;
const int _flagInitialQuote = 4;
const int _flagFinalQuote = 8;

/// U+25CC DOTTED CIRCLE, which LB28a names explicitly as a stand-in for a
/// missing aksara. It has Line_Break=AL, so no class can identify it.
const int _dottedCircle = 0x25CC;

/// The Line_Break value of [codePoint], with LB1 already resolved.
LineBreakClass lineBreakClassOf(int codePoint) =>
    LineBreakClass.values[_classes.lookup(codePoint)];

// ---------------------------------------------------------------------------
// Public results
// ---------------------------------------------------------------------------

/// A position at which a line may end.
final class LineBreakOpportunity {
  const LineBreakOpportunity(this.position, {required this.isMandatory});

  /// The UTF-16 offset of the first code unit of the *next* line.
  final int position;

  /// Whether the break is required rather than merely permitted.
  ///
  /// A mandatory break is a newline, a form feed, U+2028 LINE SEPARATOR or
  /// U+2029 PARAGRAPH SEPARATOR: the line ends there no matter how much room
  /// is left. Layout must honour these even when it is otherwise packing text
  /// greedily, which is why they are flagged rather than left for the caller
  /// to re-derive from the characters.
  final bool isMandatory;

  @override
  String toString() =>
      'LineBreakOpportunity($position${isMandatory ? ', mandatory' : ''})';

  @override
  bool operator ==(Object other) =>
      other is LineBreakOpportunity &&
      other.position == position &&
      other.isMandatory == isMandatory;

  @override
  int get hashCode => Object.hash(position, isMandatory);
}

/// Line break opportunities, per UAX #14.
final class LineBreaker {
  const LineBreaker._();

  /// Every position in [text] at which a line may end, ascending.
  ///
  /// Position 0 is never included: LB2 forbids breaking at the start of text,
  /// and a caller that emitted a line there would produce an empty first line.
  /// `text.length` always is, for the opposite reason - LB3 requires a break
  /// at the end, and including it means a layout loop can consume
  /// opportunities until it reaches the end without a special case. It is
  /// marked mandatory, because a line always ends there.
  ///
  /// Empty text has no opportunities at all rather than one at 0, so that
  /// "number of lines" is the number of opportunities and an empty paragraph
  /// is not reported as having a line.
  static List<LineBreakOpportunity> breakOpportunities(String text) {
    if (text.isEmpty) return const <LineBreakOpportunity>[];
    return _LineBreakScanner(text).run();
  }

  /// The first opportunity strictly after [from], or `text.length`.
  ///
  /// A convenience for a caller that wants one answer. It re-scans the whole
  /// paragraph, so a layout that is walking every line must call
  /// [breakOpportunities] once instead of calling this in a loop - the loop is
  /// quadratic and the difference does not show up until someone opens a long
  /// document.
  static int nextBreak(String text, int from) {
    for (final LineBreakOpportunity o in breakOpportunities(text)) {
      if (o.position > from) return o.position;
    }
    return text.length;
  }
}

// ---------------------------------------------------------------------------
// The rules
// ---------------------------------------------------------------------------

/// Applies LB1-LB31 to one string.
///
/// The scan works over *items* rather than code points. LB9 says a combining
/// mark or ZWJ takes the class of the character it follows and is then
/// invisible to every later rule; folding those into the character they attach
/// to up front means the thirty rules below never have to ask "is this a
/// combining mark, and if so what is it really" - a question that, asked
/// thirty times, is where implementations of this algorithm go wrong.
final class _LineBreakScanner {
  _LineBreakScanner(this.text);

  final String text;

  /// The effective class of each item (LB1, LB9 and LB10 applied).
  late final Uint8List _class;

  /// The base code point of each item, for the rules that need a property
  /// other than the class.
  late final Int32List _base;

  /// The property flags of each item's base code point.
  late final Uint8List _flag;

  /// The UTF-16 offset each item starts at, plus a final entry of
  /// `text.length`.
  late final Int32List _offset;

  /// Whether the last code point of each item is a ZWJ, which LB8a needs and
  /// LB9 would otherwise have hidden.
  late final Uint8List _endsWithZwj;

  int _count = 0;

  List<LineBreakOpportunity> run() {
    _buildItems();
    final List<LineBreakOpportunity> result = <LineBreakOpportunity>[];
    for (int i = 1; i < _count; i++) {
      final _Decision decision = _decide(i);
      if (decision != _Decision.noBreak) {
        result.add(
          LineBreakOpportunity(
            _offset[i],
            isMandatory: decision == _Decision.mandatory,
          ),
        );
      }
    }
    // LB3: always break at the end of text.
    result.add(LineBreakOpportunity(text.length, isMandatory: true));
    return result;
  }

  /// LB1, LB9 and LB10: classify, then fold combining marks into their base.
  void _buildItems() {
    final int capacity = text.length;
    _class = Uint8List(capacity);
    _base = Int32List(capacity);
    _flag = Uint8List(capacity);
    _offset = Int32List(capacity + 1);
    _endsWithZwj = Uint8List(capacity);

    int cursor = 0;
    while (cursor < text.length) {
      final int unit = text.codeUnitAt(cursor);
      int codePoint = unit;
      int width = 1;
      if (unit >= 0xD800 && unit <= 0xDBFF && cursor + 1 < text.length) {
        final int low = text.codeUnitAt(cursor + 1);
        if (low >= 0xDC00 && low <= 0xDFFF) {
          codePoint = 0x10000 + ((unit - 0xD800) << 10) + (low - 0xDC00);
          width = 2;
        }
      }

      final int cls = _classes.lookup(codePoint);
      final bool combining =
          cls == LineBreakClass.cm.index || cls == LineBreakClass.zwj.index;
      if (combining && _count > 0 && _acceptsCombining(_class[_count - 1])) {
        // LB9: the mark disappears into the base, so no break can fall here.
        _endsWithZwj[_count - 1] = cls == LineBreakClass.zwj.index ? 1 : 0;
      } else {
        // LB10: a mark with nothing to attach to behaves like a letter.
        _class[_count] = combining ? LineBreakClass.al.index : cls;
        _base[_count] = codePoint;
        _flag[_count] = _flags.lookup(codePoint);
        _offset[_count] = cursor;
        _endsWithZwj[_count] = cls == LineBreakClass.zwj.index ? 1 : 0;
        _count++;
      }
      cursor += width;
    }
    _offset[_count] = text.length;
  }

  /// Whether a combining mark may attach to a base of this class (LB9).
  static bool _acceptsCombining(int cls) =>
      cls != LineBreakClass.bk.index &&
      cls != LineBreakClass.cr.index &&
      cls != LineBreakClass.lf.index &&
      cls != LineBreakClass.nl.index &&
      cls != LineBreakClass.sp.index &&
      cls != LineBreakClass.zw.index;

  // -------------------------------------------------------------- accessors

  LineBreakClass _at(int i) => LineBreakClass.values[_class[i]];

  bool _isEastAsian(int i) => _flag[i] & _flagEastAsian != 0;

  bool _isInitialQuote(int i) => _flag[i] & _flagInitialQuote != 0;

  bool _isFinalQuote(int i) => _flag[i] & _flagFinalQuote != 0;

  /// The last item before [i] that is not a space, or -1.
  ///
  /// Five rules are written `X SP* ×`, and this is the whole of what that
  /// notation needs.
  int _skipSpacesBefore(int i) {
    int j = i - 1;
    while (j >= 0 && _class[j] == LineBreakClass.sp.index) {
      j--;
    }
    return j;
  }

  /// Whether `NU (SY | IS)*` ends immediately before [i], which is the shape
  /// every clause of LB25 is built from.
  bool _numberEndsBefore(int i) {
    int j = i - 1;
    while (j >= 0 &&
        (_class[j] == LineBreakClass.sy.index ||
            _class[j] == LineBreakClass.is_.index)) {
      j--;
    }
    return j >= 0 && _class[j] == LineBreakClass.nu.index;
  }

  /// The `(AK | ◌ | AS)` of LB28a.
  bool _isAksara(int i) =>
      _class[i] == LineBreakClass.ak.index ||
      _class[i] == LineBreakClass.as_.index ||
      _base[i] == _dottedCircle;

  bool _isHangul(int i) =>
      _class[i] == LineBreakClass.jl.index ||
      _class[i] == LineBreakClass.jv.index ||
      _class[i] == LineBreakClass.jt.index ||
      _class[i] == LineBreakClass.h2.index ||
      _class[i] == LineBreakClass.h3.index;

  bool _isAlphabetic(int i) =>
      _class[i] == LineBreakClass.al.index ||
      _class[i] == LineBreakClass.hl.index;

  bool _isHyphen(int i) =>
      _class[i] == LineBreakClass.hy.index ||
      _class[i] == LineBreakClass.hh.index;

  // ------------------------------------------------------------- the rules

  /// Whether a line may end between item `i - 1` and item [i].
  ///
  /// Written as a top-to-bottom cascade in the annex's own order, with the
  /// first matching rule winning. The order is load-bearing: LB13's "never
  /// break before a closing bracket" has to be consulted before LB18's "break
  /// after a space", or `foo )` would break between the space and the bracket.
  _Decision _decide(int i) {
    final LineBreakClass before = _at(i - 1);
    final LineBreakClass after = _at(i);

    // LB4, LB5: the mandatory breaks.
    if (before == LineBreakClass.bk) return _Decision.mandatory;
    if (before == LineBreakClass.cr && after == LineBreakClass.lf) {
      return _Decision.noBreak;
    }
    if (before == LineBreakClass.cr ||
        before == LineBreakClass.lf ||
        before == LineBreakClass.nl) {
      return _Decision.mandatory;
    }

    // LB6: nothing gets between a character and the hard break after it.
    if (after == LineBreakClass.bk ||
        after == LineBreakClass.cr ||
        after == LineBreakClass.lf ||
        after == LineBreakClass.nl) {
      return _Decision.noBreak;
    }

    // LB7: a space or zero-width space belongs to the line it ends.
    if (after == LineBreakClass.sp || after == LineBreakClass.zw) {
      return _Decision.noBreak;
    }

    final int nonSpace = _skipSpacesBefore(i);

    // LB8: ZW is a break opportunity that survives following spaces.
    if (nonSpace >= 0 && _at(nonSpace) == LineBreakClass.zw) {
      return _Decision.allowed;
    }
    // LB8a: ZWJ holds an emoji sequence together.
    if (_endsWithZwj[i - 1] == 1) return _Decision.noBreak;

    // LB11, LB12: the joiners.
    if (after == LineBreakClass.wj || before == LineBreakClass.wj) {
      return _Decision.noBreak;
    }
    if (before == LineBreakClass.gl) return _Decision.noBreak;
    // LB12a: a space or a hyphen before glue re-enables the break, which is
    // what lets "word-  " wrap where "word " does not.
    if (after == LineBreakClass.gl &&
        before != LineBreakClass.sp &&
        before != LineBreakClass.ba &&
        before != LineBreakClass.hy &&
        before != LineBreakClass.hh) {
      return _Decision.noBreak;
    }

    // LB13: never strand a closing bracket, an exclamation mark or a solidus
    // at the start of a line.
    if (after == LineBreakClass.cl ||
        after == LineBreakClass.cp ||
        after == LineBreakClass.ex ||
        after == LineBreakClass.sy) {
      return _Decision.noBreak;
    }

    // LB14: never strand an opening bracket at the end of one.
    if (nonSpace >= 0 && _at(nonSpace) == LineBreakClass.op) {
      return _Decision.noBreak;
    }

    // LB15a, LB15b: an unresolved quotation mark stays with the text it
    // opens or closes. "Unresolved" because the annex cannot tell an opening
    // from a closing `"` without context, so it uses position instead.
    if (nonSpace >= 0 && _isInitialQuote(nonSpace)) {
      final int context = nonSpace - 1;
      if (context < 0 || _opensQuoteContext(_at(context))) {
        return _Decision.noBreak;
      }
    }
    if (_isFinalQuote(i) &&
        (i + 1 >= _count || _closesQuoteContext(_at(i + 1)))) {
      return _Decision.noBreak;
    }

    // LB15c: "subtract .5" - a decimal mark after a space starts a number, so
    // the break belongs before it and not after.
    if (before == LineBreakClass.sp &&
        after == LineBreakClass.is_ &&
        i + 1 < _count &&
        _at(i + 1) == LineBreakClass.nu) {
      return _Decision.allowed;
    }
    // LB15d.
    if (after == LineBreakClass.is_) return _Decision.noBreak;

    // LB16, LB17.
    if (after == LineBreakClass.ns &&
        nonSpace >= 0 &&
        (_at(nonSpace) == LineBreakClass.cl ||
            _at(nonSpace) == LineBreakClass.cp)) {
      return _Decision.noBreak;
    }
    if (after == LineBreakClass.b2 &&
        nonSpace >= 0 &&
        _at(nonSpace) == LineBreakClass.b2) {
      return _Decision.noBreak;
    }

    // LB18: everything above has had its say, so a space now ends the line.
    if (before == LineBreakClass.sp) return _Decision.allowed;

    // LB19: a quotation mark that is neither initial nor final punctuation -
    // the ASCII `"` and `'` - binds on both sides.
    if (after == LineBreakClass.qu && !_isInitialQuote(i)) {
      return _Decision.noBreak;
    }
    if (before == LineBreakClass.qu && !_isFinalQuote(i - 1)) {
      return _Decision.noBreak;
    }
    // LB19a: and a quotation mark next to non-East-Asian text binds too. The
    // exception exists because CJK quotation marks are full-width and wrap
    // like ideographs.
    if (after == LineBreakClass.qu) {
      if (!_isEastAsian(i - 1)) return _Decision.noBreak;
      if (i + 1 >= _count || !_isEastAsian(i + 1)) return _Decision.noBreak;
    }
    if (before == LineBreakClass.qu) {
      if (!_isEastAsian(i)) return _Decision.noBreak;
      if (i - 2 < 0 || !_isEastAsian(i - 2)) return _Decision.noBreak;
    }

    // LB20: an embedded object breaks on both sides.
    if (after == LineBreakClass.cb || before == LineBreakClass.cb) {
      return _Decision.allowed;
    }

    // LB20a: a hyphen that starts a word is part of it, as in a dash used to
    // introduce dialogue.
    if (_isAlphabetic(i) && _isHyphen(i - 1)) {
      final LineBreakClass? context = i - 2 < 0 ? null : _at(i - 2);
      if (context == null ||
          context == LineBreakClass.bk ||
          context == LineBreakClass.cr ||
          context == LineBreakClass.lf ||
          context == LineBreakClass.nl ||
          context == LineBreakClass.sp ||
          context == LineBreakClass.zw ||
          context == LineBreakClass.cb ||
          context == LineBreakClass.gl) {
        return _Decision.noBreak;
      }
    }

    // LB21.
    if (after == LineBreakClass.ba ||
        after == LineBreakClass.hh ||
        after == LineBreakClass.hy ||
        after == LineBreakClass.ns) {
      return _Decision.noBreak;
    }
    if (before == LineBreakClass.bb) return _Decision.noBreak;
    // LB21a: Hebrew uses a hyphen as a prefix marker, so the break belongs
    // after the following word rather than after the hyphen.
    if (i >= 2 &&
        _at(i - 2) == LineBreakClass.hl &&
        _isHyphen(i - 1) &&
        after != LineBreakClass.hl) {
      return _Decision.noBreak;
    }
    // LB21b.
    if (before == LineBreakClass.sy && after == LineBreakClass.hl) {
      return _Decision.noBreak;
    }

    // LB22.
    if (after == LineBreakClass.in_) return _Decision.noBreak;

    // LB23: digits and letters do not come apart.
    if (_isAlphabetic(i - 1) && after == LineBreakClass.nu) {
      return _Decision.noBreak;
    }
    if (before == LineBreakClass.nu && _isAlphabetic(i)) {
      return _Decision.noBreak;
    }
    // LB23a: a currency symbol or a counter word stays with its ideograph.
    if (before == LineBreakClass.pr &&
        (after == LineBreakClass.id ||
            after == LineBreakClass.eb ||
            after == LineBreakClass.em)) {
      return _Decision.noBreak;
    }
    if ((before == LineBreakClass.id ||
            before == LineBreakClass.eb ||
            before == LineBreakClass.em) &&
        after == LineBreakClass.po) {
      return _Decision.noBreak;
    }

    // LB24.
    if ((before == LineBreakClass.pr || before == LineBreakClass.po) &&
        _isAlphabetic(i)) {
      return _Decision.noBreak;
    }
    if (_isAlphabetic(i - 1) &&
        (after == LineBreakClass.pr || after == LineBreakClass.po)) {
      return _Decision.noBreak;
    }

    // LB25: everything that keeps a number and its sign, separators, brackets
    // and unit on one line - "$(12.35)", "1,00,000.00", "12%".
    if (after == LineBreakClass.po || after == LineBreakClass.pr) {
      if ((before == LineBreakClass.cl || before == LineBreakClass.cp) &&
          _numberEndsBefore(i - 1)) {
        return _Decision.noBreak;
      }
      if (_numberEndsBefore(i)) return _Decision.noBreak;
    }
    if (before == LineBreakClass.po || before == LineBreakClass.pr) {
      if (after == LineBreakClass.nu) return _Decision.noBreak;
      if (after == LineBreakClass.op) {
        if (i + 1 < _count && _at(i + 1) == LineBreakClass.nu) {
          return _Decision.noBreak;
        }
        if (i + 2 < _count &&
            _at(i + 1) == LineBreakClass.is_ &&
            _at(i + 2) == LineBreakClass.nu) {
          return _Decision.noBreak;
        }
      }
    }
    if ((before == LineBreakClass.hy || before == LineBreakClass.is_) &&
        after == LineBreakClass.nu) {
      return _Decision.noBreak;
    }
    if (after == LineBreakClass.nu && _numberEndsBefore(i)) {
      return _Decision.noBreak;
    }

    // LB26, LB27: a Korean syllable block is one unit and behaves like an
    // ideograph.
    if (before == LineBreakClass.jl &&
        (after == LineBreakClass.jl ||
            after == LineBreakClass.jv ||
            after == LineBreakClass.h2 ||
            after == LineBreakClass.h3)) {
      return _Decision.noBreak;
    }
    if ((before == LineBreakClass.jv || before == LineBreakClass.h2) &&
        (after == LineBreakClass.jv || after == LineBreakClass.jt)) {
      return _Decision.noBreak;
    }
    if ((before == LineBreakClass.jt || before == LineBreakClass.h3) &&
        after == LineBreakClass.jt) {
      return _Decision.noBreak;
    }
    if (_isHangul(i - 1) && after == LineBreakClass.po) {
      return _Decision.noBreak;
    }
    if (before == LineBreakClass.pr && _isHangul(i)) {
      return _Decision.noBreak;
    }

    // LB28: the rule that makes a Latin word a word.
    if (_isAlphabetic(i - 1) && _isAlphabetic(i)) return _Decision.noBreak;

    // LB28a: a Brahmic orthographic syllable is one unit even though its
    // parts are separate code points.
    if (before == LineBreakClass.ap && _isAksara(i)) {
      return _Decision.noBreak;
    }
    if (_isAksara(i - 1) &&
        (after == LineBreakClass.vf || after == LineBreakClass.vi)) {
      return _Decision.noBreak;
    }
    if (i >= 2 &&
        _isAksara(i - 2) &&
        before == LineBreakClass.vi &&
        (after == LineBreakClass.ak || _base[i] == _dottedCircle)) {
      return _Decision.noBreak;
    }
    if (_isAksara(i - 1) &&
        _isAksara(i) &&
        i + 1 < _count &&
        _at(i + 1) == LineBreakClass.vf) {
      return _Decision.noBreak;
    }

    // LB29: "e.g." does not break after the dot.
    if (before == LineBreakClass.is_ && _isAlphabetic(i)) {
      return _Decision.noBreak;
    }

    // LB30: "person(s)" keeps its brackets, but a full-width bracket next to
    // Latin text may still break - that is the East Asian exclusion.
    if ((_isAlphabetic(i - 1) || before == LineBreakClass.nu) &&
        after == LineBreakClass.op &&
        !_isEastAsian(i)) {
      return _Decision.noBreak;
    }
    if (before == LineBreakClass.cp &&
        !_isEastAsian(i - 1) &&
        (_isAlphabetic(i) || after == LineBreakClass.nu)) {
      return _Decision.noBreak;
    }

    // LB30a: a flag is two regional indicators, so the break falls between
    // pairs and not between the halves of one flag.
    if (after == LineBreakClass.ri && before == LineBreakClass.ri) {
      int run = 0;
      int j = i - 1;
      while (j >= 0 && _class[j] == LineBreakClass.ri.index) {
        run++;
        j--;
      }
      if (run.isOdd) return _Decision.noBreak;
    }

    // LB30b: a skin tone modifier stays with the emoji it modifies.
    if (after == LineBreakClass.em) {
      if (before == LineBreakClass.eb) return _Decision.noBreak;
      if (_flag[i - 1] & _flagUnassignedPictographic != 0) {
        return _Decision.noBreak;
      }
    }

    // LB31.
    return _Decision.allowed;
  }

  /// The left context of LB15a.
  static bool _opensQuoteContext(LineBreakClass cls) =>
      cls == LineBreakClass.bk ||
      cls == LineBreakClass.cr ||
      cls == LineBreakClass.lf ||
      cls == LineBreakClass.nl ||
      cls == LineBreakClass.op ||
      cls == LineBreakClass.qu ||
      cls == LineBreakClass.gl ||
      cls == LineBreakClass.sp ||
      cls == LineBreakClass.zw;

  /// The right context of LB15b.
  static bool _closesQuoteContext(LineBreakClass cls) =>
      cls == LineBreakClass.sp ||
      cls == LineBreakClass.gl ||
      cls == LineBreakClass.wj ||
      cls == LineBreakClass.cl ||
      cls == LineBreakClass.qu ||
      cls == LineBreakClass.cp ||
      cls == LineBreakClass.ex ||
      cls == LineBreakClass.is_ ||
      cls == LineBreakClass.sy ||
      cls == LineBreakClass.bk ||
      cls == LineBreakClass.cr ||
      cls == LineBreakClass.lf ||
      cls == LineBreakClass.nl ||
      cls == LineBreakClass.zw;
}

enum _Decision { noBreak, allowed, mandatory }

// ---------------------------------------------------------------------------
// Generated tables
// ---------------------------------------------------------------------------

/// Line_Break for the whole code space with LB1 resolved, generated from UCD
/// 17.0.0. See [_RangeTable] for the encoding.
const String _lineBreakClassTable =
    'AKJFBcBHCMBKSlBBPBjBBBBiBBhBBBBjBBgBBLBBBiBBYBVBYBmBBfKYCBDPBBbgBBiBBLBB'
    'dgBBFBJBBBKGdBKaQBgBBhBBiBDBFjBBBBFBBChBBiBBBCGBBGjBBBDgBBBoQGBBDGBBSGBB'
    'gBK8CQHKNBOYBBkIKHB/HYBTBBEiBBBBKtBTBKBBBKCBBKCPBKBBIUbBEUEBNfGBDhBDYCBC'
    'KLPBKBPDBrBKVfKhBBfCBDKBBjDPBBBKHfBBBKGBCKCBBKEBCfKBXKBBeKbB7CKLBPfKBhBK'
    'JBEYBPBBDKBiBCBWKEBBKJBBKDBBKFBrBKDB0BfCBFKJBqBKYfBKhBB2BKDBBKSBBKHBKKCF'
    'CfKBRKDB4BKBBBKHBCKCBCKDBJKBBKKCBCfKBChBCBFhBBBBiBBBCKBBCKDB4BKBBBKFBEKC'
    'BCKDBDKBBUfKKCBDKBBLKDB4BKBBBKIBBKDBBKDBUKCBCfKBBiBBBIKGBBKDB4BKBBBKHBCK'
    'CBCKDBHKDBKKCBCfKBSKBB7BKFBDKDBBKEBJKBBOfKBJiBBBGKFB3BKBBBKHBBKDBBKEBHKC'
    'BLKCBCfKBHGBBJKDGBB3BKBBBKHBBKDBBKEBHKCBLKCBCfKBDKBBMKEB3BKCBBKHBBKDBBKE'
    'BJKBBKKCBCfKBJhBBBHKDBmCKBBEKGBBKBBBKIBGfKBCKCB9BKBBCKHBEiBBBHKIBBfKFCB1'
    'CKBBCKJBLKHBBfKBnBGEBBGCQBGCFBQBPFQBBBPBBDKCBGfKBKFBKBBBKBBBKBgBBJBgBBJB'
    'KCBxBKOFBKFFBKCBFKLBBKkBBBFCBGKBBJGCFBGBBFQCBwCKUBBfKFCBKKEBEKDBBKDBCKHB'
    'DKEBNKMBBKBfKKEBiDZgDboCa4CB9KKDBBFBB+ETBB/TFBBagBBJBBuCFDBkBKEBcKDFCBbK'
    'CBeKCBgCKgBFCeBBBFBBBFBiBBBBKBBCfKBYPCFCGBBBPCBBKDQBKBfKBrDKCBiBKBB2DKMB'
    'EKMBIPCfKBgEfLB8BKFB5BKKBBKdBCKBfKBGfKBWKuBBCKLQBBUKFAvBKQoBBAIBBFCDKFCW'
    'BFEWKKJWJFDKDBeKNBCfKBGDmBKMnBCBwBKUBDFFfKBGfKBkBFCBwCKDBBKVBEKBBGKBBCKD'
    'BmGKNQBKuBQBKDB9PGBBCFHQBFDqBBKBrBBKCTBQBTCEBBDjBCgBBjBDgBBjBBBEXDFBHCKF'
    'QBhBIBBjBCBBeCBGYBgBBJBeDBMFBhBBFEBBFDpBBBFKKBNgBBJBBOgBBJBBRiBHhBBiBOhB'
    'BiBEhBBiBChBBiBBhBBiBPKhBBShBBBFhBBBMiBBB7HiBCB7GXBBYgBBJBgBBJBBOWCBNgBB'
    'JBBlGWEBsQWEBQWCBCWBBBWDNBWCBZWDBsBWBBWWBB9BWMBEWBBBWDBBWCBDWCBCWBBCWDBI'
    'WBBGWFBBWCNBWBBCWIBDWCNEBtCjBGBBPCWBBDgBBJBgBBJBgBBJBgBBJBgBBJBgBBJBgBBJ'
    'BBvCgBBJBBfgBBJBgBBJBgBBJBgBBJBgBBJBBQFBBiMgBBJBgBBJBgBBJBgBBJBgBBJBgBBJ'
    'BgBBJBgBBJBgBBJBgBBJBgBBJBB/BgBBJBgBBJBBgBgBBJBBxXKDBHPBFDBBPBFBBwDFBBOK'
    'BBgDKgBjBOFIBBTBgBBFBBCjBCBCjBCgBBJBgBBJBgBBJBgBBJBFEPBBBFCBBFCBFECFDBBT'
    'BFBgBBFIBBFBBBFCBDPCgBBLBgBBLBgBBLBgBBLBTBBiBWaBBW5CBMW2GBaWQFBJCWCeBWCg'
    'BBJBgBBJBgBBJBgBBJBgBBJBWCgBBJBgBBJBgBBJBgBBJBeBgBBJCWKKGWFKBWFeCWDBBeBW'
    'BeBWBeBWBeBWBeBWZeBWfeBWBeBWBeBWGeBWGeCBCKCeEWBeCWBeBWBeBWBeBWBeBWZeBWfe'
    'BWBeBWBeBWGeBWGeCWEeEWBBFWrBBBW+CBBW2CBJWBeQWfBBWoBBIWw7GBgCW1wUeBW3jBBD'
    'W3BB3BFCBtIFBPBFBBQfKBlCKEBBKKBgBKCBwCKCBBFFBqIKBBDKBBEKBBXKFBEKBBLhBBB7'
    'BGCPCBIKCByBKSBIFCfKBGKSBKGBBCKBfKBcKIFCBXKNBMZdBDKEAvBKNoBBWGFDWEBBFBDK'
    'BEWCBFKBBKfKBGDpBKOBJFDKBFIKCBCDKBCWBFDBbKDByBKBBBKDBCKCBFKCBBKBBpBKFFCB'
    'DKCBsHKIFBKCBCfKBGRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRB'
    'SbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRB'
    'SbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRB'
    'SbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRB'
    'SbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRB'
    'SbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRB'
    'SbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRB'
    'SbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRB'
    'SbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRB'
    'SbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRB'
    'SbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRB'
    'SbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRB'
    'SbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRB'
    'SbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRB'
    'SbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRB'
    'SbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRB'
    'SbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRB'
    'SbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRB'
    'SbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRB'
    'SbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRB'
    'SbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRB'
    'SbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRBSbRB'
    'SbRBSbRBSbRBSbRBSbRBSbRBSbRBSbBMbXBEaxBBkoIWgQBdUBKBUKBBUNBBUFBBUBBBUCBB'
    'UCBBUKBuPJBgBBB8FhBBBDKQJDeCPCgBBJBXBBGQBKBQBKBQBKBQCKBQBKBQBKBQCKBWFgBB'
    'JBgBBJBgBBJBgBBJBgBBJBgBBJBgBBJBgBBJBWCgBBJBWHJBWBJBBBeCPCWBgBBJBgBBJBgB'
    'BJBWIBBWBiBBhBBWBBzEpBBBBPBWCiBBhBBWCgBBJBWCJBWBJBWLeCWDPBWbgBBWBJBWdgBB'
    'WBJBWBgBBJCgBBJCeBWBeKWtBeCWfBDWGBCWGBCWGBCWDBDhBBiBBWDiBCBSKDIBBjIFDB6H'
    'KBBiHKBB1EKFBkBFBBwBFBBvGfKBtdFBBnGFBBhHKDBBKCBFKEBoBKDBEKBBQFIBtEKCBJFG'
    'XBBiCFHBkPKEBIfKBGfKBfKFTBB8JKCTBBiBFBBpBKGBmCKLBxBKEB6DKDCCAzBKOoBBFCWF'
    'BEWUDKKBACKCABBJQBKDBtBKLBCfBFEKBBKfBBiBfKBGKDBkBKOBBfKFEBBKCBsBKBBBGBBK'
    'KDBwBKOBEFCBBFBKEBBKCfKBBGBBBFDBsCKMFCBBFCBBKBBCKBBnDFBB1BKMBFfKBGKEBBAI'
    'BCACBCAWBBAHBBACBBAFBBKCFBKHBCKCBCKCoBBBCDBBGKBBFFBDCACKCBCKHBDKFBLDKBBD'
    'BBCDBBBDCAkBBBWBKJBBKBBCKBBBKEBBKEoBBCBKBWDBBWCBIKCByCKSBEFEBBfKFCBCKBBx'
    'CKUBMfKB1GKHBCKJGBFCPCBDFPBEKCByCKRFCBNfKBGGNB+BKNBIfKBGfUB5BKPBEfKBCFDB'
    'tHKPBlFfKBWAHBCABBCAIBBACBBAYKGBBKCBCKDoBBCBKBCBKCFDBJDKB3DKHBCKHBBGBBBK'
    'BBcKKBoBKHBBKEGBBBFEGBBBKBBJKLBuBKQFDBBGDFCB9CGKB2CKIBoEfKB1BKIBBKIBBFFB'
    'KfKBWGBPBBgBKWBBKOB6DKGBDKBBBKCBBKHBBKBBIfKBwBKFBBKCBBKFBIfKB2BfKB2HDSFB'
    'KEFCBHKCCBKBANBBAiBKHBDKEoBBFCWLDKKBBiEhBEBeFBBwjBFFBjvDgBDJDBkBJBBDgBBJ'
    'BgBBJBBvHgBBJCBzFgBBQHgBBJBQDgBBJBgBBJBKBBGKPB4rEgBBJBBw5GDeKSDKBmpCfKBE'
    'FCBwCfKBmBKFFBB6BKHFDBKFBBLfKB0QFCfKB9IFCB2FKBBBK3BBHKEBtCeEQBBLKCeCWDBJ'
    'Wg4GBgQWfBhDWzDBtwIWjJBPeBBdeDBCeBBOeEBIWsMBhtCKCFBKEBsiEfKBmQKuBBCKXB+Q'
    'KFBDKWBCKHBeKEB0EKDBpsBfyBBgQK3BBEKyBBIKBBOKBBCFEBQKFBBKPBwqBKHBBKRBCKHB'
    'BKCBBKFBkDKBBgFKHBJfKBkLKBB9BKEfKBFiBBBsPKEfKB0HKCBBfKBoHKBBCKBBHKCBFKBB'
    '6OKHBtDKHBFfKBEgBCBsahBBBDhBBBvaWgIBuFW4BkBaWlMNBWWBCWXBCWFBBWFNDWCNBWCN'
    'DWuBOFWiCNCWCNLWVNTWDNBWENDWBNDWHNBWBNBWOBBWBBBWBBBWFNBWEBBWBBCWtCBHWQBO'
    'WNBYWqBNCWENBWVNBWENCW9BBIWYBGWrCNDWDNFBmBjBDeDBEWjBNBWQNDWJNBWLNBWzBB0D'
    'WDBEWFB1CWrBBsINBWCNBWINIWGNBWJNKWCNDW4BNBW9BNCWBNCWBNBWRNDWBNNWiBB4CWrD'
    'NDWqBNJWHBwHfKBGW+fBCW+//BBCW+//BBjggUKBBeKgDBgEKwHB';

/// East_Asian_Width, quotation-mark category and unassigned-pictographic bits
/// for the whole code space, generated from UCD 17.0.0.
const String _lineBreakFlagTable =
    'AArFEBAPIBAkiEBgDA41DEBIBABECIBABEBAZEBIBAuDBBAwTBCANBCA+FBEADBBACBBApQB'
    'CAVBCAaBIAQBMArBBBAKBGADBBANBBAIBCARBCAFBCAIBBAFBBAVBBAHBCABBBAEBBACBBAH'
    'BBAEBCAcBBAjBBBABBBAEBDABBBA9BBDAYBBAOBBA7aBCAzBBBAEBBAsVEBIBEBIBADEBIBA'
    'BEBIBAOEBIBACEBIBA+CBaABB5CAMB2GAaBvCACB2CACBnDAFBrBABB+CABB2CAJBwBABBoB'
    'AIB9xcADB3BA5kBBdAjUBk9KA8qIBgQAwYBKAWBjBABBTABBEA1EB+FADBGACBGACBGACBDA'
    'DBHABBHAx/bBFALBHAJB2mHApBBgBAhDBzDA9vIBEABBHABBCABBjJAPBBAdBDACBBAOBEAI'
    'BsMAkgIB3CAJBXAtkHBBAnBCEAkDCMAPCCAPCBAOBBCBAlBCKAuEBBACBKATC4BAaBDCNBsB'
    'CEBJCHBCCOBGC6EBhBAMBJABBmCABBWAMBrBAEBFAMBRADBBADBnCABBBABB7FACB/BANBEA'
    'BBYASBBAaBCANBBA2CB1CAwBBmCAGBBADBDACBECDBEALBCCDAEBJCDA6GCGBMCEBBCPAMCE'
    'A4BCIAKCGAoBCIAeCCAMCEACCOAJCnBAMBvBABBKABB5FA4CCIAOCCBNCDBLCDB5BCBBBCEB'
    'QCCBMCEBKCHAgIC+fACB+//BACB+//BA';
