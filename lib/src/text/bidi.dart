/// The Unicode Bidirectional Algorithm, UAX #9.
///
/// Hebrew and Arabic are written right to left, but the numbers, Latin words,
/// punctuation and brackets embedded in them are not, and a paragraph mixing
/// them has no single direction. The bidi algorithm is what turns one logical
/// (typed, stored, searched) order into the visual (displayed) order, by
/// assigning every character an *embedding level* - even means left-to-right,
/// odd means right-to-left - and then reversing nested runs of increasing
/// level.
///
/// This is not optional even for a Latin-only product. The moment a paragraph
/// contains one Arabic word, or a user pastes one, a renderer without bidi
/// draws it mirrored: readable-looking text that says something different from
/// what is stored. And selection is worse than rendering - a selection that is
/// contiguous in logical order is generally *two or three disjoint rectangles*
/// on screen, and getting that wrong makes a text field feel broken in a way
/// users cannot describe.
///
/// ## What is implemented
///
/// All of P2-P3, X1-X10 (including isolates, BD8-BD13), W1-W7, N0-N2
/// (including bracket pairs, BD14-BD16), I1-I2, and L1-L2.
///
/// Deliberately **not** here:
///
///  * **P1**, splitting text into paragraphs. That is the caller's job,
///    because a paragraph boundary is also a layout boundary and the layout
///    code has to see it anyway. [BidiParagraph.resolve] treats its input as
///    one paragraph and gives any type-B character the paragraph level, which
///    is what X8 requires of a trailing separator.
///  * **L3**, reordering combining marks around a right-to-left base. That
///    belongs to the shaper, which is the only thing that knows which glyphs
///    are marks.
///  * **L4**, mirroring. That is a `cmap`-level glyph substitution and needs
///    Bidi_Mirroring_Glyph, which is a shaping concern rather than an ordering
///    one. [BidiParagraph.levels] carries the information L4 needs.
///
/// ## Indices
///
/// Levels are per UTF-16 code unit, matching `GlyphRun.clusters` and every
/// selection offset in the framework. Both halves of a surrogate pair get the
/// level of the code point they encode, so a level array can be sliced at any
/// string offset without decoding.
///
/// ## The property table
///
/// [_bidiClassTable] is the Bidi_Class property of every code point in
/// U+0000..U+10FFFF, taken from `ucd.nounihan.flat.xml` of the Unicode
/// Character Database 17.0.0. That file rather than `DerivedBidiClass.txt`
/// because it is the *derived* view: the `@missing` block defaults - the ones
/// that give unassigned code points in the Hebrew, Arabic, Syriac, Thaana and
/// historic RTL blocks the values R or AL instead of L - are already applied,
/// so nothing here has to re-derive them and get one wrong.
///
/// The coverage is therefore total. There is no "unknown character" fallback,
/// and no range this file guesses at. What it *is* is a snapshot of 17.0.0: a
/// code point assigned in a later version reads as whatever 17.0.0 said about
/// the block it lives in, which for the RTL blocks is still R or AL and
/// elsewhere is L. That mis-orders one character rather than corrupting a
/// paragraph, and refreshing it means regenerating one string.
///
/// [_bracketOpeners]/[_bracketClosers] are the Bidi_Paired_Bracket property
/// from the same source, needed by N0.
library;

import 'dart:typed_data';

import 'shaper.dart' show TextDirection;

// ---------------------------------------------------------------------------
// Property lookup
// ---------------------------------------------------------------------------

/// Bidi_Class property values.
///
/// The order is the one the generated table encodes; changing it silently
/// re-labels every character, so the table has to be regenerated with it.
enum BidiClass {
  /// Left-to-right (strong).
  l,

  /// Right-to-left (strong).
  r,

  /// Right-to-left Arabic (strong).
  al,

  /// European number.
  en,

  /// European number separator.
  es,

  /// European number terminator.
  et,

  /// Arabic number.
  an,

  /// Common number separator.
  cs,

  /// Nonspacing mark.
  nsm,

  /// Boundary neutral.
  bn,

  /// Paragraph separator.
  b,

  /// Segment separator.
  s,

  /// Whitespace.
  ws,

  /// Other neutral.
  on,

  /// Left-to-right embedding.
  lre,

  /// Left-to-right override.
  lro,

  /// Right-to-left embedding.
  rle,

  /// Right-to-left override.
  rlo,

  /// Pop directional format.
  pdf,

  /// Left-to-right isolate.
  lri,

  /// Right-to-left isolate.
  rli,

  /// First strong isolate.
  fsi,

  /// Pop directional isolate.
  pdi;

  /// Whether this is one of LRI, RLI or FSI (BD8).
  bool get isIsolateInitiator =>
      this == BidiClass.lri || this == BidiClass.rli || this == BidiClass.fsi;

  /// Whether X9 removes characters of this class from the algorithm.
  bool get isRemovedByX9 =>
      this == BidiClass.rle ||
      this == BidiClass.lre ||
      this == BidiClass.rlo ||
      this == BidiClass.lro ||
      this == BidiClass.pdf ||
      this == BidiClass.bn;

  /// Whether this is a "neutral or isolate formatting" type, the NI of the
  /// N rules.
  bool get isNeutralOrIsolate =>
      this == BidiClass.b ||
      this == BidiClass.s ||
      this == BidiClass.ws ||
      this == BidiClass.on ||
      this == BidiClass.fsi ||
      this == BidiClass.lri ||
      this == BidiClass.rli ||
      this == BidiClass.pdi;
}

/// A run-length coded map from code point to a small integer.
///
/// Deliberately duplicated in `grapheme.dart` and `line_break.dart` rather
/// than shared: each of the three files is a self-contained implementation of
/// one Unicode annex, and a shared private helper would be a fourth file whose
/// only purpose is to hold sixty lines of decoder. The encoding is documented
/// once, here.
///
/// The data is one string literal: each run contributes a varint delta from
/// the previous run's start and a varint value, five bits of payload per
/// character with the sixth marking continuation, in the standard base64
/// alphabet (chosen because none of its characters need escaping inside a Dart
/// string literal). Decoding is deferred to first lookup.
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

final _RangeTable _bidiClasses = _RangeTable(_bidiClassTable);

/// The Bidi_Class of [codePoint].
BidiClass bidiClassOf(int codePoint) =>
    BidiClass.values[_bidiClasses.lookup(codePoint)];

/// The closing bracket [codePoint] opens, or -1 if it opens nothing.
int _pairedCloserOf(int codePoint) {
  final int index = _binarySearch(_bracketOpeners, codePoint);
  return index < 0 ? -1 : _bracketClosers[index];
}

/// Whether [codePoint] is a closing paired bracket.
bool _isPairedCloser(int codePoint) =>
    _binarySearch(_bracketClosers, codePoint) >= 0;

int _binarySearch(List<int> sorted, int value) {
  int low = 0;
  int high = sorted.length - 1;
  while (low <= high) {
    final int mid = (low + high) >> 1;
    if (sorted[mid] == value) return mid;
    if (sorted[mid] < value) {
      low = mid + 1;
    } else {
      high = mid - 1;
    }
  }
  return -1;
}

/// BD16 compares brackets under canonical equivalence, and the only canonical
/// equivalences among brackets are U+2329/U+3008 and U+232A/U+3009 - a closed
/// set the Unicode Consortium has committed not to extend. Normalising to the
/// older pair is therefore the whole of "canonical equivalence" here, and
/// costs two comparisons instead of a normalisation pass.
int _canonicalBracket(int codePoint) => switch (codePoint) {
      0x3008 => 0x2329,
      0x3009 => 0x232A,
      _ => codePoint,
    };

// ---------------------------------------------------------------------------
// Public results
// ---------------------------------------------------------------------------

/// A maximal span of text at one embedding level.
final class BidiRun {
  const BidiRun(this.start, this.end, this.level);

  /// UTF-16 offset of the first code unit, inclusive.
  final int start;

  /// UTF-16 offset one past the last code unit.
  final int end;

  /// The resolved embedding level: even is left-to-right, odd is right-to-left.
  final int level;

  TextDirection get direction =>
      level.isOdd ? TextDirection.rightToLeft : TextDirection.leftToRight;

  @override
  String toString() => 'BidiRun($start..$end, level $level)';
}

/// The resolved bidi state of one paragraph.
final class BidiParagraph {
  const BidiParagraph._(this.text, this.paragraphLevel, this.levels);

  /// The paragraph text, exactly as given.
  final String text;

  /// The base level from P2/P3, or from an explicit `baseDirection`.
  final int paragraphLevel;

  /// One embedding level per UTF-16 code unit of [text].
  ///
  /// Characters X9 removes (the embedding and override initiators, PDF and
  /// BN) have no level of their own in the algorithm. Rather than leave a hole
  /// they are given the level of the character they follow, as UAX #9 section
  /// 5.2 recommends for implementations that retain them: any other choice
  /// splits a level run in two and makes [levelRuns] produce spurious
  /// fragments.
  final Uint8List levels;

  TextDirection get baseDirection => paragraphLevel.isOdd
      ? TextDirection.rightToLeft
      : TextDirection.leftToRight;

  /// Runs the UAX #9 rules over [text].
  ///
  /// [baseDirection] forces the paragraph level; leaving it null applies P2
  /// and P3, which take the direction of the first strong character and
  /// default to left-to-right when there is none.
  static BidiParagraph resolve(String text, {TextDirection? baseDirection}) =>
      _BidiResolver(text, baseDirection).run();

  /// The level runs of the paragraph, in **logical** order.
  ///
  /// A run is a maximal span at one level, which is also the largest span that
  /// can be shaped as a unit: direction is constant inside it, and no
  /// reordering happens inside it either.
  List<BidiRun> levelRuns() {
    final List<BidiRun> runs = <BidiRun>[];
    if (text.isEmpty) return runs;
    int start = 0;
    for (int i = 1; i <= levels.length; i++) {
      if (i == levels.length || levels[i] != levels[start]) {
        runs.add(BidiRun(start, i, levels[start]));
        start = i;
      }
    }
    return runs;
  }

  /// The same runs as [levelRuns], in the order they are drawn in, left to
  /// right.
  ///
  /// This is the list a painter walks: each run is shaped in its own
  /// direction, and their *positions* come from this order rather than from
  /// the string.
  List<BidiRun> runsInVisualOrder() {
    final List<BidiRun> runs = levelRuns();
    final List<int> order =
        reorderVisual(<int>[for (final BidiRun run in runs) run.level]);
    return <BidiRun>[for (final int i in order) runs[i]];
  }

  /// Rule L2: the visual order of the entries of [levels].
  ///
  /// `result[i]` is the index of the entry that should be drawn `i`th from the
  /// left. The entries can be characters or whole runs; L2 only looks at
  /// levels, which is why the same function serves both.
  ///
  /// The rule is "from the highest level down to the lowest odd level, reverse
  /// every contiguous sequence at that level or higher". Doing it top-down is
  /// what makes nesting come out right: an inner run is reversed once by its
  /// own level and then again as part of its parent, which restores its
  /// internal order relative to the parent's.
  static List<int> reorderVisual(List<int> levels) {
    final int count = levels.length;
    final List<int> order = List<int>.generate(count, (int i) => i);
    if (count == 0) return order;

    int highest = 0;
    int lowestOdd = 127;
    for (final int level in levels) {
      if (level > highest) highest = level;
      if (level.isOdd && level < lowestOdd) lowestOdd = level;
    }
    if (lowestOdd > highest) return order;

    for (int level = highest; level >= lowestOdd; level--) {
      int i = 0;
      while (i < count) {
        if (levels[order[i]] < level) {
          i++;
          continue;
        }
        int j = i;
        while (j < count && levels[order[j]] >= level) {
          j++;
        }
        // Reverse order[i..j).
        for (int a = i, b = j - 1; a < b; a++, b--) {
          final int swap = order[a];
          order[a] = order[b];
          order[b] = swap;
        }
        i = j;
      }
    }
    return order;
  }

  @override
  String toString() =>
      'BidiParagraph(${text.length} units, base level $paragraphLevel)';
}

// ---------------------------------------------------------------------------
// The algorithm
// ---------------------------------------------------------------------------

/// The deepest embedding level X1-X8 will accept. Levels above it overflow
/// rather than nest, which is what keeps a hostile string of ten thousand RLEs
/// from growing the status stack without bound.
const int _maxDepth = 125;

/// One entry of the directional status stack of X1.
final class _StatusEntry {
  const _StatusEntry(this.level, this.override, this.isolate);

  final int level;

  /// The directional override status: null when neutral, otherwise the class
  /// (L or R) that X6 forces onto the characters it covers.
  final BidiClass? override;

  final bool isolate;
}

final class _BidiResolver {
  _BidiResolver(this.text, this.forcedDirection);

  final String text;
  final TextDirection? forcedDirection;

  /// One entry per code point: the code point itself.
  late final Int32List _codePoints;

  /// UTF-16 offset of each code point, plus a final entry equal to
  /// `text.length` so a span can always be closed.
  late final Int32List _offsets;

  /// The working bidi class of each code point. X6 overwrites entries here,
  /// and the W and N rules overwrite them again.
  late final List<BidiClass> _types;

  /// The classes as looked up, before any rule touched them. L1 is specified
  /// in terms of these.
  late final List<BidiClass> _originalTypes;

  late final Uint8List _levels;

  /// For each isolate initiator, the index of its matching PDI, or [_count] if
  /// it has none (BD9).
  late final Int32List _matchingPdi;

  /// For each PDI that matches an isolate initiator, that initiator's index;
  /// -1 otherwise.
  late final Int32List _matchingInitiator;

  int _count = 0;
  int _paragraphLevel = 0;

  BidiParagraph run() {
    _decode();
    if (_count == 0) {
      final int level = forcedDirection == TextDirection.rightToLeft ? 1 : 0;
      return BidiParagraph._(text, level, Uint8List(text.length));
    }

    _matchPdis();
    _paragraphLevel = switch (forcedDirection) {
      TextDirection.rightToLeft => 1,
      TextDirection.leftToRight => 0,
      null => _autoLevel(0, _count),
    };

    _resolveExplicitLevels();
    for (final List<int> sequence in _isolatingRunSequences()) {
      _resolveSequence(sequence);
    }
    _resolveImplicitLevels();
    _applyL1();
    _fillRemovedLevels();

    return BidiParagraph._(text, _paragraphLevel, _expandToUtf16());
  }

  // ------------------------------------------------------------------ setup

  void _decode() {
    _codePoints = Int32List(text.length);
    _offsets = Int32List(text.length + 1);
    int index = 0;
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
      _codePoints[index] = codePoint;
      _offsets[index] = cursor;
      index++;
      cursor += width;
    }
    _count = index;
    _offsets[_count] = text.length;

    _types = List<BidiClass>.generate(
      _count,
      (int i) => bidiClassOf(_codePoints[i]),
      growable: false,
    );
    _originalTypes = List<BidiClass>.of(_types, growable: false);
    _levels = Uint8List(_count);
  }

  /// BD9: pair every isolate initiator with its matching PDI.
  void _matchPdis() {
    _matchingPdi = Int32List(_count);
    _matchingInitiator = Int32List(_count)..fillRange(0, _count, -1);
    final List<int> open = <int>[];
    for (int i = 0; i < _count; i++) {
      final BidiClass type = _types[i];
      if (type.isIsolateInitiator) {
        open.add(i);
        _matchingPdi[i] = _count;
      } else if (type == BidiClass.pdi && open.isNotEmpty) {
        final int initiator = open.removeLast();
        _matchingPdi[initiator] = i;
        _matchingInitiator[i] = initiator;
      }
    }
  }

  /// P2 and P3 over `[start, end)`, skipping isolated spans.
  int _autoLevel(int start, int end) {
    int i = start;
    while (i < end) {
      final BidiClass type = _types[i];
      if (type.isIsolateInitiator) {
        // P2 explicitly ignores characters between an isolate initiator and
        // its matching PDI: the whole point of an isolate is that its content
        // does not affect the direction of what surrounds it.
        i = _matchingPdi[i] + 1;
        continue;
      }
      if (type == BidiClass.l) return 0;
      if (type == BidiClass.r || type == BidiClass.al) return 1;
      i++;
    }
    return 0;
  }

  // ------------------------------------------------------- X1-X8: explicit

  void _resolveExplicitLevels() {
    final List<_StatusEntry> stack = <_StatusEntry>[
      _StatusEntry(_paragraphLevel, null, false),
    ];
    int overflowIsolate = 0;
    int overflowEmbedding = 0;
    int validIsolate = 0;

    for (int i = 0; i < _count; i++) {
      final BidiClass type = _types[i];
      switch (type) {
        case BidiClass.rle:
        case BidiClass.lre:
        case BidiClass.rlo:
        case BidiClass.lro:
          // X2-X5. The initiator keeps the level it is written at; X9 removes
          // it anyway, and giving it the outer level keeps the retained
          // character inside the run it visually belongs to.
          _levels[i] = stack.last.level;
          final bool rtl = type == BidiClass.rle || type == BidiClass.rlo;
          final int newLevel =
              rtl ? (stack.last.level + 1) | 1 : (stack.last.level + 2) & ~1;
          if (newLevel <= _maxDepth &&
              overflowIsolate == 0 &&
              overflowEmbedding == 0) {
            stack.add(
              _StatusEntry(
                newLevel,
                switch (type) {
                  BidiClass.rlo => BidiClass.r,
                  BidiClass.lro => BidiClass.l,
                  _ => null,
                },
                false,
              ),
            );
          } else if (overflowIsolate == 0) {
            overflowEmbedding++;
          }

        case BidiClass.rli:
        case BidiClass.lri:
        case BidiClass.fsi:
          // X5a, X5b, X5c. An FSI takes the direction of the first strong
          // character it encloses, which is P2/P3 run over that span.
          final bool rtl = type == BidiClass.rli ||
              (type == BidiClass.fsi &&
                  _autoLevel(i + 1, _min(_matchingPdi[i], _count)) == 1);
          _levels[i] = stack.last.level;
          if (stack.last.override != null) _types[i] = stack.last.override!;
          final int newLevel =
              rtl ? (stack.last.level + 1) | 1 : (stack.last.level + 2) & ~1;
          if (newLevel <= _maxDepth &&
              overflowIsolate == 0 &&
              overflowEmbedding == 0) {
            validIsolate++;
            stack.add(_StatusEntry(newLevel, null, true));
          } else {
            overflowIsolate++;
          }

        case BidiClass.pdi:
          // X6a.
          if (overflowIsolate > 0) {
            overflowIsolate--;
          } else if (validIsolate != 0) {
            overflowEmbedding = 0;
            while (!stack.last.isolate) {
              stack.removeLast();
            }
            stack.removeLast();
            validIsolate--;
          }
          _levels[i] = stack.last.level;
          if (stack.last.override != null) _types[i] = stack.last.override!;

        case BidiClass.pdf:
          // X7. The level is recorded before the pop so that a retained PDF
          // stays with the embedding it closes rather than jumping outward.
          _levels[i] = stack.last.level;
          if (overflowIsolate > 0) {
            // inside an overflow isolate: this PDF matches nothing visible
          } else if (overflowEmbedding > 0) {
            overflowEmbedding--;
          } else if (!stack.last.isolate && stack.length >= 2) {
            stack.removeLast();
          }

        case BidiClass.b:
          // X8. A paragraph separator belongs to no embedding at all.
          _levels[i] = _paragraphLevel;

        case BidiClass.bn:
          _levels[i] = stack.last.level;

        default:
          // X6.
          _levels[i] = stack.last.level;
          if (stack.last.override != null) _types[i] = stack.last.override!;
      }
    }
  }

  // --------------------------------------------------- X10: run sequences

  /// The isolating run sequences of the paragraph (BD13), each as the list of
  /// code point indices it covers, with characters removed by X9 left out.
  List<List<int>> _isolatingRunSequences() {
    // Level runs first, over the text as X9 leaves it.
    final List<int> kept = <int>[];
    for (int i = 0; i < _count; i++) {
      if (!_originalTypes[i].isRemovedByX9) kept.add(i);
    }
    if (kept.isEmpty) return const <List<int>>[];

    final List<List<int>> runs = <List<int>>[];
    final Int32List runOfIndex = Int32List(_count)..fillRange(0, _count, -1);
    List<int> current = <int>[kept.first];
    for (int k = 1; k < kept.length; k++) {
      if (_levels[kept[k]] == _levels[current.last]) {
        current.add(kept[k]);
      } else {
        runs.add(current);
        current = <int>[kept[k]];
      }
    }
    runs.add(current);
    for (int r = 0; r < runs.length; r++) {
      for (final int index in runs[r]) {
        runOfIndex[index] = r;
      }
    }

    final List<List<int>> sequences = <List<int>>[];
    final List<bool> used = List<bool>.filled(runs.length, false);
    for (int r = 0; r < runs.length; r++) {
      if (used[r]) continue;
      final int first = runs[r].first;
      // A run that starts with a PDI matching an isolate initiator is the
      // continuation of an earlier sequence, never the start of one.
      if (_originalTypes[first] == BidiClass.pdi &&
          _matchingInitiator[first] >= 0) {
        continue;
      }
      final List<int> sequence = <int>[];
      int at = r;
      while (true) {
        used[at] = true;
        sequence.addAll(runs[at]);
        final int last = runs[at].last;
        if (!_originalTypes[last].isIsolateInitiator) break;
        final int pdi = _matchingPdi[last];
        if (pdi >= _count) break;
        at = runOfIndex[pdi];
        if (at < 0 || used[at]) break;
      }
      sequences.add(sequence);
    }
    return sequences;
  }

  /// X10: the sos and eos types of a sequence, in that order.
  ///
  /// Both are "what direction does the text on the other side of this boundary
  /// have", answered by the higher of the two levels meeting at the boundary -
  /// which is what makes a neutral at the edge of a run take the outer
  /// direction rather than being left undefined.
  (BidiClass, BidiClass) _boundaryTypes(List<int> sequence) {
    final int level = _levels[sequence.first];

    int before = _paragraphLevel;
    for (int i = sequence.first - 1; i >= 0; i--) {
      if (_originalTypes[i].isRemovedByX9) continue;
      before = _levels[i];
      break;
    }
    final int sos = level > before ? level : before;

    final int last = sequence.last;
    int after = _paragraphLevel;
    if (!(_originalTypes[last].isIsolateInitiator &&
        _matchingPdi[last] >= _count)) {
      for (int i = last + 1; i < _count; i++) {
        if (_originalTypes[i].isRemovedByX9) continue;
        after = _levels[i];
        break;
      }
    }
    final int eos = _levels[last] > after ? _levels[last] : after;

    return (
      sos.isOdd ? BidiClass.r : BidiClass.l,
      eos.isOdd ? BidiClass.r : BidiClass.l,
    );
  }

  // ------------------------------------------------ W1-W7, N0-N2 per run

  void _resolveSequence(List<int> sequence) {
    final int length = sequence.length;
    final (BidiClass sos, BidiClass eos) = _boundaryTypes(sequence);
    final int level = _levels[sequence.first];
    final BidiClass embedding = level.isOdd ? BidiClass.r : BidiClass.l;

    final List<BidiClass> t =
        List<BidiClass>.generate(length, (int i) => _types[sequence[i]]);
    // N0's last clause is stated in terms of the types before W1 changed them,
    // so the snapshot has to be taken here and not from _originalTypes, which
    // predates the X6 overrides as well.
    final List<BidiClass> beforeW1 = List<BidiClass>.of(t);

    // W1: a nonspacing mark takes the type of what it attaches to.
    for (int i = 0; i < length; i++) {
      if (t[i] != BidiClass.nsm) continue;
      if (i == 0) {
        t[i] = sos;
      } else if (t[i - 1].isIsolateInitiator || t[i - 1] == BidiClass.pdi) {
        t[i] = BidiClass.on;
      } else {
        t[i] = t[i - 1];
      }
    }

    // W2: a European number in Arabic context is an Arabic number.
    for (int i = 0; i < length; i++) {
      if (t[i] != BidiClass.en) continue;
      BidiClass strong = sos;
      for (int j = i - 1; j >= 0; j--) {
        if (t[j] == BidiClass.l ||
            t[j] == BidiClass.r ||
            t[j] == BidiClass.al) {
          strong = t[j];
          break;
        }
      }
      if (strong == BidiClass.al) t[i] = BidiClass.an;
    }

    // W3.
    for (int i = 0; i < length; i++) {
      if (t[i] == BidiClass.al) t[i] = BidiClass.r;
    }

    // W4: a single separator between two numbers of the same kind joins them.
    for (int i = 1; i < length - 1; i++) {
      if (t[i] == BidiClass.es &&
          t[i - 1] == BidiClass.en &&
          t[i + 1] == BidiClass.en) {
        t[i] = BidiClass.en;
      } else if (t[i] == BidiClass.cs &&
          t[i - 1] == t[i + 1] &&
          (t[i - 1] == BidiClass.en || t[i - 1] == BidiClass.an)) {
        t[i] = t[i - 1];
      }
    }

    // W5: a run of terminators next to a European number joins it.
    for (int i = 0; i < length; i++) {
      if (t[i] != BidiClass.et) continue;
      int end = i;
      while (end < length && t[end] == BidiClass.et) {
        end++;
      }
      final bool before = i > 0 && t[i - 1] == BidiClass.en;
      final bool after = end < length && t[end] == BidiClass.en;
      if (before || after) {
        for (int j = i; j < end; j++) {
          t[j] = BidiClass.en;
        }
      }
      i = end - 1;
    }

    // W6: anything still a separator or terminator was not part of a number.
    for (int i = 0; i < length; i++) {
      if (t[i] == BidiClass.et ||
          t[i] == BidiClass.es ||
          t[i] == BidiClass.cs) {
        t[i] = BidiClass.on;
      }
    }

    // W7: a European number in Latin context is Latin.
    for (int i = 0; i < length; i++) {
      if (t[i] != BidiClass.en) continue;
      BidiClass strong = sos;
      for (int j = i - 1; j >= 0; j--) {
        if (t[j] == BidiClass.l || t[j] == BidiClass.r) {
          strong = t[j];
          break;
        }
      }
      if (strong == BidiClass.l) t[i] = BidiClass.l;
    }

    _resolveBrackets(sequence, t, beforeW1, sos, embedding);

    // N1: a run of neutrals between two same-direction strongs takes that
    // direction; N2: anything left takes the embedding direction.
    for (int i = 0; i < length; i++) {
      if (!t[i].isNeutralOrIsolate) continue;
      int end = i;
      while (end < length && t[end].isNeutralOrIsolate) {
        end++;
      }
      final BidiClass before = i == 0 ? sos : _strongDirection(t[i - 1]);
      final BidiClass after = end == length ? eos : _strongDirection(t[end]);
      final BidiClass resolved = before == after ? before : embedding;
      for (int j = i; j < end; j++) {
        t[j] = resolved;
      }
      i = end - 1;
    }

    for (int i = 0; i < length; i++) {
      _types[sequence[i]] = t[i];
    }
  }

  /// N0, using the bracket pairs of BD16.
  void _resolveBrackets(
    List<int> sequence,
    List<BidiClass> t,
    List<BidiClass> beforeW1,
    BidiClass sos,
    BidiClass embedding,
  ) {
    final List<(int, int)> pairs = _bracketPairs(sequence, t);
    if (pairs.isEmpty) return;
    final BidiClass opposite =
        embedding == BidiClass.l ? BidiClass.r : BidiClass.l;

    for (final (int open, int close) in pairs) {
      bool foundEmbedding = false;
      bool foundOpposite = false;
      for (int i = open + 1; i < close; i++) {
        final BidiClass direction = _strongOrNone(t[i]);
        if (direction == embedding) {
          foundEmbedding = true;
          break;
        }
        if (direction == opposite) foundOpposite = true;
      }

      BidiClass? resolved;
      if (foundEmbedding) {
        resolved = embedding;
      } else if (foundOpposite) {
        // A bracket pair enclosing only opposite-direction text takes that
        // direction if the text before the pair agrees, and the embedding
        // direction otherwise. This is the rule that keeps "(RTL)" inside an
        // LTR sentence from dragging its parentheses to the wrong side.
        BidiClass preceding = sos;
        for (int i = open - 1; i >= 0; i--) {
          final BidiClass direction = _strongOrNone(t[i]);
          if (direction != BidiClass.on) {
            preceding = direction;
            break;
          }
        }
        resolved = preceding == opposite ? opposite : embedding;
      }
      if (resolved == null) continue;

      t[open] = resolved;
      t[close] = resolved;
      // Marks that followed a bracket before W1 took its old type; now that
      // the bracket has moved, they have to move with it, or an accent ends up
      // on the far side of the line from the bracket it decorates.
      for (final int bracket in <int>[open, close]) {
        for (int i = bracket + 1;
            i < t.length && beforeW1[i] == BidiClass.nsm;
            i++) {
          t[i] = resolved;
        }
      }
    }
  }

  /// BD16: the bracket pairs of a sequence, sorted by opening position.
  List<(int, int)> _bracketPairs(List<int> sequence, List<BidiClass> t) {
    // BD16 fixes the stack at 63 entries and specifies that overflowing it
    // abandons bracket processing for the whole sequence - a bound that exists
    // so that deeply nested brackets cannot make N0 quadratic.
    const int stackLimit = 63;
    final List<(int, int)> openers = <(int, int)>[];
    final List<(int, int)> pairs = <(int, int)>[];

    for (int i = 0; i < sequence.length; i++) {
      // BD14/BD15 look at the *current* type, so a bracket that X6 forced to
      // L or R is no longer a bracket.
      if (t[i] != BidiClass.on) continue;
      final int codePoint = _codePoints[sequence[i]];
      final int closer = _pairedCloserOf(codePoint);
      if (closer >= 0) {
        if (openers.length == stackLimit) return const <(int, int)>[];
        openers.add((_canonicalBracket(closer), i));
        continue;
      }
      if (!_isPairedCloser(codePoint)) continue;
      final int wanted = _canonicalBracket(codePoint);
      for (int s = openers.length - 1; s >= 0; s--) {
        if (openers[s].$1 != wanted) continue;
        pairs.add((openers[s].$2, i));
        openers.removeRange(s, openers.length);
        break;
      }
    }
    pairs.sort(((int, int) a, (int, int) b) => a.$1.compareTo(b.$1));
    return pairs;
  }

  /// The direction a resolved type contributes to N1, where numbers count as
  /// right-to-left because they only ever appear at a level above an RTL run.
  static BidiClass _strongDirection(BidiClass type) => switch (type) {
        BidiClass.l => BidiClass.l,
        BidiClass.r || BidiClass.en || BidiClass.an => BidiClass.r,
        _ => type,
      };

  /// As [_strongDirection], but reporting "not strong" as ON, which is what N0
  /// needs when scanning for context.
  static BidiClass _strongOrNone(BidiClass type) => switch (type) {
        BidiClass.l => BidiClass.l,
        BidiClass.r || BidiClass.en || BidiClass.an => BidiClass.r,
        _ => BidiClass.on,
      };

  // ------------------------------------------------------------- I1-I2, L1

  void _resolveImplicitLevels() {
    for (int i = 0; i < _count; i++) {
      if (_originalTypes[i].isRemovedByX9) continue;
      final int level = _levels[i];
      final BidiClass type = _types[i];
      if (level.isEven) {
        if (type == BidiClass.r) {
          _levels[i] = level + 1;
        } else if (type == BidiClass.an || type == BidiClass.en) {
          _levels[i] = level + 2;
        }
      } else if (type == BidiClass.l ||
          type == BidiClass.en ||
          type == BidiClass.an) {
        _levels[i] = level + 1;
      }
    }
  }

  /// L1, over the whole paragraph treated as one line.
  ///
  /// Callers that wrap the paragraph have to re-apply the "at the end of the
  /// line" clause per line; what is done here is the part that does not depend
  /// on where the breaks fall. Without it, trailing spaces on an RTL line sit
  /// on the left, which looks like a stray indent that nothing accounts for.
  void _applyL1() {
    bool trailing = true;
    for (int i = _count - 1; i >= 0; i--) {
      final BidiClass type = _originalTypes[i];
      if (type == BidiClass.b || type == BidiClass.s) {
        _levels[i] = _paragraphLevel;
        trailing = true;
      } else if (trailing &&
          (type == BidiClass.ws ||
              type.isIsolateInitiator ||
              type == BidiClass.pdi)) {
        _levels[i] = _paragraphLevel;
      } else if (trailing && type.isRemovedByX9) {
        // X9 removed these, so they cannot interrupt a whitespace run; the
        // scan has to see through them or a BN between two spaces would strand
        // the outer one at the wrong level.
        _levels[i] = _paragraphLevel;
      } else {
        trailing = false;
      }
    }
  }

  /// Gives every X9-removed character the level of the character it follows.
  void _fillRemovedLevels() {
    int previous = _paragraphLevel;
    for (int i = 0; i < _count; i++) {
      if (_originalTypes[i].isRemovedByX9) {
        _levels[i] = previous;
      } else {
        previous = _levels[i];
      }
    }
  }

  Uint8List _expandToUtf16() {
    final Uint8List result = Uint8List(text.length);
    for (int i = 0; i < _count; i++) {
      for (int u = _offsets[i]; u < _offsets[i + 1]; u++) {
        result[u] = _levels[i];
      }
    }
    return result;
  }

  static int _min(int a, int b) => a < b ? a : b;
}

// ---------------------------------------------------------------------------
// Generated tables
// ---------------------------------------------------------------------------

/// Bidi_Class for the whole code space, generated from UCD 17.0.0. See
/// [_RangeTable] for the encoding.
const String _bidiClassTable =
    'AJJLBKBLBMBKBJOKDLBMBNCFDNFEBHBEBHCDKHBNGAaNGAaNEJGKBJaHBNBFENEABNCJBNCF'
    'CDCNBABNDDBABNFAXNBAfNBAhONCAHNOACNOAFNJABNRIwDAENCAINBAFNCABNBAuDNBAsEI'
    'HAgINBACNCFBBBItBBBIBBBICBBICBBIBB4BGGNCCBFCCBHBCBNCILCwBIVGKFBGCCDIBClD'
    'IHGBNBIGCCICNBIECCDKCXIBCeIbC7CILCPBrBIJBCNEBDIBBYIEBBIJBBIDBBIFBrBIDBEC'
    'wBGCCFIJCqBIYGBIgBA3BIBABIBAEIIAEIBADIHAKICAdIBA6BIBAEIEAIIBAUICAOFCAHFB'
    'ACIBACICA5BIBAEICAEICACIDADIBAeICADIBALICA5BIBAEIFABICAEIBAUICANFBAIIGAB'
    'IBA6BIBACIBABIEAIIBAHICALICAeIBA9BIBAMIBAlBNGFBNBAFIBADIBA3BIBABIDAFIDAB'
    'IEAHICALICAUNHACIBA6BIBAPICAUICAcICA5BICAEIEAIIBAUICAdIBAoCIBAHIDABIBA6C'
    'IBACIHAEFBAHIIAiDIBACIJALIHApCICAbIBABIBABIBNEAzBIOABIFABICAFILABIkBAJIB'
    'AmDIEABIGABICACICAZICAEIDAQIEANIBACICAGIBAPIBA/VIDAwBNKAmDNBA/TMBAaNCA1D'
    'IDAdICAeICAeICAgCICABIHAIIBACILAHFBABIBASNKAGNLIDJBIBA1DICAiBIBA2DIDAEIC'
    'AJIBAGIDAENBADNCA4ENiBAXICACIBA6BIBABIHABIBABIBACIIAGIKACIBAwBIuBACIMAUI'
    'EAwBIBABIFABIBAFIBAoBIJAMICAgBIEACICABIDA4BIBABICADIBABIDA6BIIACICA4EIDA'
    'BINABIHAEIBAGIBADICAmGIgCA9NNBABNDALNDANNDANNDANNCABMLJDABBBNYMBKBOBQBSB'
    'PBRBHBFFNPHBNaMBJGTBUBVBWBJGDBADDGECNDABDKECNDARFwBIhBAPNCABNEABNCAKNBAB'
    'NDAFNGABNBABNBABNBAEFBALNCAENFAFNEACNQApBNDAENiEEBFBNiJAlCNaABN0EAWNLAVN'
    'oBDUAuCNiOABNzKAgIN0TACNqEAlHNGAEIDAHNHA/DIBAgDIgBN+CAiBNaABN5CAMN2GAaNQ'
    'MBNEADNZAJIEACNBAFNCAFNDA5CICNCADNBA6CNBAkGNmBAJNBAtBNCAxBNQAcNDAyBNPAMN'
    'EAnFNEAjDNCAfNBAguGNgCAw0VN3BAmKNDA/CIENBIKNCAeICAwCICAONiBAmDNBA5DIBADI'
    'BAEIBAZICABNEIBALFCA6BNEAsCICAaISANIBAmBIIAZILAuBIDAwBIBACIEACICAnBIBAjC'
    'IGACICACICAMIBAIIBAvBIBAzBIBABIDACICAFICABIBAqBICAIIBAzDNCA5DIBACIBAEIBA'
    'v5TBBIBBKEBBmBCzDNQCrLNSCgCNCC2BNIJgBCNNDIQNKAGIQNgBHBNBHBABNBHBNJFBNCEC'
    'NDABNBFCNBAECvEJBABNCFDNFEBHBEBHCDKHBNGAaNGAaNLA6DFCNDFCABNHABJJNFJCAhIN'
    'BA+BNtCADNNADNBA8CIBAiHIBDbA6DIFAlkBB/INBBhHIDBBICBFIEBoBIDBEIBBlFICByCN'
    'HBgOCkBIECIGKCGGKBfIFNBBxHGfBsBICBTCQNJChBIGBwBCWILCfBSIEB6DABIBA2BIPALN'
    'UAKIBACICAKIDAxBIEACICAHIBA9BIDAkBIFABIIA+BIBAMICA0BIJAKIEACIBA/CIDACIBA'
    'BICAGIBACIBA9EIBADIIAVICA5BICADIBAlBIHADIFAmCIGANIBABIBABIBAOICA1CIIACID'
    'ABIBAXIBA0CIGABIBAEICABICAuHIEAGICABICAbICA1CIIACIBABICAfNNA+BIBABIBACIG'
    'ABIBAlDIBABIBACIEABIFAjIIJABICAgIICABIBAEIBAwEIEACICAEIBAgBIGACICAoBIGAC'
    'IEAIIBAJIGACIDAuBINABICAmGIBABIDABIBApGIHABIGA0CIWACIHABICABICA6DIGADIBA'
    'BICABIHABIBAoCICADIBABIBA7KICALICA0BIFAFIBABIBAXIBA6DNIFENRAuiFIBAGIPAom'
    'LIMADIDAguCIFA7BIHA4gBIBA/BIEAvCNBABIBA4lTICABJEA86DN2GAaDKNDADN0NAGNXAP'
    'NRAPIuBACIXAgRIDAJJIIIACIHAeIEA7BNCAVNiCIDNBA6FN3CAqbNBAZNBAfNBAZNBAfNBA'
    'ZNBAfNBAZNBAfNBAZNBAKDyBAgQI3BAEIyBAIIBAOIBAWIFABIPAwqBIHABIRACIHABICABI'
    'FAkDIBAgFIHA3LIBA9BIEAPFBAsPIEA+HICAzHIBACIBAHICAFIBAqIBwGIHBtDIHBlZCwCB'
    'gCCwCBwFCwHNCCOBgINsBAENkDAMNPACNPABNPABNlBAKDLNFAfNBA6BNGA9BNBAyFNGA6EN'
    '5eADNRADNNADN6GAGNMAENBAPNMAEN4BAINKAGNoBAINeACNMAENCAONJAnBN4KAINOACNNA'
    'DNLADN5BABNBAENQACNMAENKAHNzEABN8CDKNBAjgBJCA+//BJCA+//BJCA+//BJCA+//BJC'
    'A+//BJCA+//BJCA+//BJCA+//BJCA+//BJCA+//BJCA+//BJCA+//BJiIIwHJwwDA+/7BJCA'
    '+//BJCA+//BJ';

/// The opening brackets of the Bidi_Paired_Bracket property, ascending.
const List<int> _bracketOpeners = <int>[
  0x28,
  0x5B,
  0x7B,
  0xF3A,
  0xF3C,
  0x169B,
  0x2045,
  0x207D,
  0x208D,
  0x2308,
  0x230A,
  0x2329,
  0x2768,
  0x276A,
  0x276C,
  0x276E,
  0x2770,
  0x2772,
  0x2774,
  0x27C5,
  0x27E6,
  0x27E8,
  0x27EA,
  0x27EC,
  0x27EE,
  0x2983,
  0x2985,
  0x2987,
  0x2989,
  0x298B,
  0x298D,
  0x298F,
  0x2991,
  0x2993,
  0x2995,
  0x2997,
  0x29D8,
  0x29DA,
  0x29FC,
  0x2E22,
  0x2E24,
  0x2E26,
  0x2E28,
  0x2E55,
  0x2E57,
  0x2E59,
  0x2E5B,
  0x3008,
  0x300A,
  0x300C,
  0x300E,
  0x3010,
  0x3014,
  0x3016,
  0x3018,
  0x301A,
  0xFE59,
  0xFE5B,
  0xFE5D,
  0xFF08,
  0xFF3B,
  0xFF5B,
  0xFF5F,
  0xFF62,
];

/// The closer each entry of [_bracketOpeners] pairs with, and, sorted, the
/// set BD15 calls a closing paired bracket.
const List<int> _bracketClosers = <int>[
  0x29,
  0x5D,
  0x7D,
  0xF3B,
  0xF3D,
  0x169C,
  0x2046,
  0x207E,
  0x208E,
  0x2309,
  0x230B,
  0x232A,
  0x2769,
  0x276B,
  0x276D,
  0x276F,
  0x2771,
  0x2773,
  0x2775,
  0x27C6,
  0x27E7,
  0x27E9,
  0x27EB,
  0x27ED,
  0x27EF,
  0x2984,
  0x2986,
  0x2988,
  0x298A,
  0x298C,
  0x2990,
  0x298E,
  0x2992,
  0x2994,
  0x2996,
  0x2998,
  0x29D9,
  0x29DB,
  0x29FD,
  0x2E23,
  0x2E25,
  0x2E27,
  0x2E29,
  0x2E56,
  0x2E58,
  0x2E5A,
  0x2E5C,
  0x3009,
  0x300B,
  0x300D,
  0x300F,
  0x3011,
  0x3015,
  0x3017,
  0x3019,
  0x301B,
  0xFE5A,
  0xFE5C,
  0xFE5E,
  0xFF09,
  0xFF3D,
  0xFF5D,
  0xFF60,
  0xFF63,
];
