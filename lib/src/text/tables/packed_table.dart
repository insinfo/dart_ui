/// The decoders the generated Unicode property tables share.
///
/// `bidi.dart`, `grapheme.dart` and `line_break.dart` each carry a private copy
/// of the range decoder rather than importing one, and the comment there
/// explains why: each of those files is a self-contained implementation of one
/// Unicode annex, and a shared sixty-line decoder would have been a fourth file
/// whose only reason to exist is to be shared. That argument stops applying
/// here. This directory holds generated files that already only exist as a
/// group, three of the shapes below are needed by more than one of them, and a
/// file holding the decoding is not a new dependency between otherwise
/// independent things - it is the format those files are written in.
///
/// ## The encoding
///
/// Every table is one `String` literal of base64 characters. Base64 because
/// none of its 64 characters needs escaping inside a Dart string literal, so a
/// table is one flat run of source text with no backslashes to miscount; and a
/// `String` rather than a `const List<int>` because a list literal of a hundred
/// thousand elements costs a constant-pool entry per element and minutes of
/// analyzer time, while a string of the same data costs one.
///
/// Integers are varints, little end first: five bits of payload per character
/// with the sixth bit set on every character but the last. Decoding is deferred
/// to the first lookup, so a program that never lays out text never pays for
/// any of it.
///
/// ## What is deliberately not here
///
/// No mutation, no incremental loading, no way to build a table at runtime.
/// These types read one string that `tool/generate_unicode_tables.dart` wrote.
/// A table that could also be built would need a growable representation and
/// bounds checks on the write path, and no caller in this framework wants
/// either.
library;

import 'dart:typed_data';

/// A run-length coded total map from code point to a small integer.
///
/// "Total" is the load-bearing word: the runs tile U+0000..U+10FFFF with no
/// gaps, so [lookup] has no failure mode and no default to fall back on. The
/// generator refuses to emit a table that does not tile, which is what makes
/// the absence of a bounds check here safe rather than optimistic.
///
/// Passing a negative code point, or one above U+10FFFF, is a programming
/// error. It is **not** checked, because [lookup] runs once per character of
/// every laid-out paragraph; a negative value reads the first run and a huge
/// one reads the last, and neither answer means anything. Callers decode from a
/// `String`, which cannot produce either.
final class RangeTable {
  /// Wraps [_data], a generated table. Nothing is decoded until the first
  /// [lookup].
  RangeTable(this._data);

  final String _data;

  Int32List? _starts;
  late Int32List _values;

  /// The value of the run containing [codePoint].
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
      if (sixBits(_data.codeUnitAt(i)) < 32) terminators++;
    }
    // A run is two varints, so there are twice as many terminating characters
    // as there are runs.
    final int runs = terminators >> 1;

    final Int32List starts = Int32List(runs);
    final Int32List values = Int32List(runs);
    int position = 0;
    int start = 0;
    for (int run = 0; run < runs; run++) {
      int delta = 0;
      int shift = 0;
      while (true) {
        final int unit = sixBits(_data.codeUnitAt(position++));
        delta |= (unit & 31) << shift;
        shift += 5;
        if (unit < 32) break;
      }
      int value = 0;
      shift = 0;
      while (true) {
        final int unit = sixBits(_data.codeUnitAt(position++));
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
  static int sixBits(int codeUnit) {
    // The base64 alphabet, in order: A-Z, a-z, 0-9, '+', '/'.
    if (codeUnit >= 0x41 && codeUnit <= 0x5A) return codeUnit - 0x41;
    if (codeUnit >= 0x61 && codeUnit <= 0x7A) return codeUnit - 0x61 + 26;
    if (codeUnit >= 0x30 && codeUnit <= 0x39) return codeUnit - 0x30 + 52;
    if (codeUnit == 0x2B) return 62;
    return 63;
  }

  /// Turns the unsigned varint encoding of a signed number back into that
  /// number. Shared with [SparseTable] and [PoolTable], which store values as
  /// signed offsets from their key.
  static int unzigzag(int value) => (value >> 1) ^ -(value & 1);
}

/// A sparse map from code point to one other integer, usually a code point.
///
/// Where [RangeTable] answers for every code point, this answers only for the
/// few thousand that carry the property at all - Bidi_Mirroring_Glyph, the
/// simple case mappings - and reports the rest as absent. A range table would
/// also work, and would be roughly twice the size: a property set on scattered
/// single characters spends one run per character *and* one run per gap.
///
/// Values are stored as a zigzag delta from the key, because the answer is
/// nearly always a code point a few dozen away from the question: `A`
/// lowercases to itself plus 32, `(` mirrors to itself plus one.
final class SparseTable {
  /// Wraps [_data], a generated table. Nothing is decoded until the first
  /// lookup.
  SparseTable(this._data);

  final String _data;

  Int32List? _keys;
  late Int32List _values;

  /// The value stored for [codePoint], or [orElse] when there is none.
  ///
  /// [orElse] is required rather than defaulted, and there is no nullable
  /// variant, because every caller of this in the framework wants "the
  /// uppercase of this character, or the character" and would otherwise write
  /// `?? codePoint` at each call site - which is the shape in which someone
  /// eventually writes `?? 0` and ships it.
  int lookup(int codePoint, {required int orElse}) {
    final Int32List keys = _keys ??= _decode();
    final int index = _search(keys, codePoint);
    return index < 0 ? orElse : _values[index];
  }

  /// Whether [codePoint] has a value at all.
  bool contains(int codePoint) {
    final Int32List keys = _keys ??= _decode();
    return _search(keys, codePoint) >= 0;
  }

  Int32List _decode() {
    int terminators = 0;
    for (int i = 0; i < _data.length; i++) {
      if (RangeTable.sixBits(_data.codeUnitAt(i)) < 32) terminators++;
    }
    final int entries = terminators >> 1;

    final Int32List keys = Int32List(entries);
    final Int32List values = Int32List(entries);
    int position = 0;
    int key = 0;
    for (int entry = 0; entry < entries; entry++) {
      int delta = 0;
      int shift = 0;
      while (true) {
        final int unit = RangeTable.sixBits(_data.codeUnitAt(position++));
        delta |= (unit & 31) << shift;
        shift += 5;
        if (unit < 32) break;
      }
      int zigzag = 0;
      shift = 0;
      while (true) {
        final int unit = RangeTable.sixBits(_data.codeUnitAt(position++));
        zigzag |= (unit & 31) << shift;
        shift += 5;
        if (unit < 32) break;
      }
      key += delta;
      keys[entry] = key;
      values[entry] = key + RangeTable.unzigzag(zigzag);
    }
    _values = values;
    return keys;
  }
}

/// A sparse map from code point to a sequence of code points.
///
/// Decompositions and full case mappings: U+00C5 decomposes into two code
/// points, U+00DF uppercases into two, U+FDFA compatibility-decomposes into
/// eighteen. Every sequence lives end to end in one flat `Int32List`, and a
/// lookup returns a *view* of it rather than building a list, because the
/// normalizer and the shaper call this once per character and cannot afford an
/// allocation per call.
///
/// The views are unmodifiable, so the shared buffer cannot be corrupted through
/// one. They are built once, at decode time, not per lookup.
final class PoolTable {
  /// Wraps [_data], a generated table. Nothing is decoded until the first
  /// [lookup].
  PoolTable(this._data);

  final String _data;

  Int32List? _keys;
  late List<List<int>> _slices;

  /// The sequence stored for [codePoint], or null when there is none.
  ///
  /// Null rather than an empty list: "has no decomposition" and "decomposes to
  /// nothing" are different answers, and a caller that treats the first as the
  /// second deletes the character.
  List<int>? lookup(int codePoint) {
    final Int32List keys = _keys ??= _decode();
    final int index = _search(keys, codePoint);
    return index < 0 ? null : _slices[index];
  }

  Int32List _decode() {
    // The header is two varints - the number of entries, and the total number
    // of pooled code points - so both buffers are sized exactly once. Counting
    // terminating characters the way [RangeTable] does cannot work here,
    // because an entry is a variable number of varints.
    int position = 0;
    int readVarint() {
      int value = 0;
      int shift = 0;
      while (true) {
        final int unit = RangeTable.sixBits(_data.codeUnitAt(position++));
        value |= (unit & 31) << shift;
        shift += 5;
        if (unit < 32) break;
      }
      return value;
    }

    final int entries = readVarint();
    final int pooled = readVarint();
    final Int32List keys = Int32List(entries);
    final Int32List pool = Int32List(pooled);
    final List<List<int>> slices = List<List<int>>.filled(
      entries,
      const <int>[],
    );

    int key = 0;
    int offset = 0;
    for (int entry = 0; entry < entries; entry++) {
      key += readVarint();
      keys[entry] = key;
      final int length = readVarint();
      final int start = offset;
      for (int i = 0; i < length; i++) {
        pool[offset++] = key + RangeTable.unzigzag(readVarint());
      }
      slices[entry] =
          Int32List.sublistView(pool, start, offset).asUnmodifiableView();
    }
    _slices = slices;
    return keys;
  }
}

/// A map from code point to one of a small set of shared integer lists.
///
/// Script_Extensions is the reason this exists. It is a *set* per code point,
/// but only a few hundred distinct sets occur across the whole code space and
/// they occur in long runs, so the shape that fits is a [RangeTable] of set
/// indices plus one pool of the sets themselves - not [PoolTable], which would
/// store the same set thousands of times over.
///
/// The lists are unmodifiable views into one flat buffer, built once.
final class SetTable {
  /// Wraps [_index], a run table of set numbers, and [_sets], the pool those
  /// numbers point into.
  SetTable(this._index, this._sets);

  final RangeTable _index;
  final String _sets;

  List<List<int>>? _decoded;

  /// The set for [codePoint]. Never null - the index table is total.
  List<int> lookup(int codePoint) =>
      (_decoded ??= _decode())[_index.lookup(codePoint)];

  /// How many distinct sets the pool holds.
  int get length => (_decoded ??= _decode()).length;

  /// The set numbered [index], for a caller that wants to translate the whole
  /// pool once instead of per code point.
  List<int> operator [](int index) => (_decoded ??= _decode())[index];

  List<List<int>> _decode() {
    int position = 0;
    int readVarint() {
      int value = 0;
      int shift = 0;
      while (true) {
        final int unit = RangeTable.sixBits(_sets.codeUnitAt(position++));
        value |= (unit & 31) << shift;
        shift += 5;
        if (unit < 32) break;
      }
      return value;
    }

    final int count = readVarint();
    final int pooled = readVarint();
    final Int32List pool = Int32List(pooled);
    final List<List<int>> sets = List<List<int>>.filled(count, const <int>[]);
    int offset = 0;
    for (int i = 0; i < count; i++) {
      final int length = readVarint();
      final int start = offset;
      for (int j = 0; j < length; j++) {
        pool[offset++] = readVarint();
      }
      sets[i] = Int32List.sublistView(pool, start, offset).asUnmodifiableView();
    }
    return sets;
  }
}

/// Index of [value] in the ascending [sorted], or -1.
int _search(Int32List sorted, int value) {
  int low = 0;
  int high = sorted.length - 1;
  while (low <= high) {
    final int mid = (low + high) >> 1;
    final int probe = sorted[mid];
    if (probe < value) {
      low = mid + 1;
    } else if (probe > value) {
      high = mid - 1;
    } else {
      return mid;
    }
  }
  return -1;
}
