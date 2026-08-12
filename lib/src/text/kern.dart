/// `kern` - the legacy kerning table.
///
/// Kerning is the per-pair adjustment that stops "AV" and "To" from looking
/// like they have a hole in them: the pair's advance is narrowed by an amount
/// the font's designer chose. Without it, text at a large size looks visibly
/// loose, which is the most common way homemade text rendering announces
/// itself.
///
/// This table is the *old* mechanism. The modern one is the `kern` feature in
/// `GPOS`, and where a font has both, GPOS wins - HarfBuzz applies the legacy
/// table only when GPOS has no `kern` feature, and that precedence is a
/// behaviour worth copying exactly, because a font that has both and gets both
/// applied is kerned twice.
///
/// Only format 0 is implemented. It is a sorted list of pairs, and it is what
/// every desktop font that ships this table uses; formats 1 through 3 are
/// Apple's, and a font that has only those is a font that expects AAT layout,
/// which is a different problem entirely.
library;

import 'dart:typed_data';

import 'font_data.dart';
import 'sfnt.dart';

/// Per-pair horizontal adjustments, in font units.
final class KernTable {
  KernTable._(this._pairs, this._values);

  /// Packed `(left << 16) | right` glyph pairs, ascending, for binary search.
  ///
  /// Packed rather than two parallel lists because the format itself defines
  /// the sort order as that of this packed value, so searching it directly
  /// means the search cannot disagree with the file's ordering.
  final Uint32List _pairs;

  /// Adjustment for each pair, parallel to [_pairs]. Negative pulls together.
  final Int16List _values;

  int get pairCount => _pairs.length;

  /// The adjustment between [left] and [right], in font units. Zero when the
  /// pair is not kerned, which is the overwhelming majority of pairs.
  int between(int left, int right) {
    final int key = (left << 16) | (right & 0xFFFF);
    int low = 0;
    int high = _pairs.length - 1;
    while (low <= high) {
      final int mid = (low + high) >> 1;
      final int value = _pairs[mid];
      if (value == key) return _values[mid];
      if (value < key) {
        low = mid + 1;
      } else {
        high = mid - 1;
      }
    }
    return 0;
  }

  /// Parses the table, or returns null when the font has no usable kerning.
  ///
  /// Null rather than an exception: a font without `kern` is completely normal
  /// - Roboto has none - and so is one whose only subtables are Apple's.
  static KernTable? parse(SfntFile file) {
    final TableRecord? record = file.tableRecord('kern');
    if (record == null) return null;

    final FontReader reader = file.data.readerAt(record.offset, table: 'kern');
    final int version = reader.readUint16();
    // Apple's version of this table starts with a 32-bit version and counts
    // subtables differently. Only the Microsoft form is handled; the Apple one
    // travels with `kerx` and AAT, which this framework does not implement.
    if (version != 0) return null;

    final int subtableCount = reader.readUint16();
    final List<int> pairs = <int>[];
    final List<int> values = <int>[];

    for (int i = 0; i < subtableCount; i++) {
      final int subtableStart = reader.offset;
      reader.skip(2); // subtable version
      final int length = reader.readUint16();
      final int coverage = reader.readUint16();

      // Bit 0 is "horizontal", bit 1 "minimum values", bit 2 "cross-stream",
      // and the format is the high byte. Only horizontal, non-minimum,
      // non-cross-stream format 0 is meaningful for laying out a line of text.
      final int format = coverage >> 8;
      final bool horizontal = coverage & 0x0001 != 0;
      final bool minimum = coverage & 0x0002 != 0;
      final bool crossStream = coverage & 0x0004 != 0;

      if (format == 0 && horizontal && !minimum && !crossStream) {
        final int pairCount = reader.readUint16();
        reader.skip(6); // searchRange, entrySelector, rangeShift
        for (int pair = 0; pair < pairCount; pair++) {
          final int left = reader.readUint16();
          final int right = reader.readUint16();
          final int value = reader.readInt16();
          pairs.add((left << 16) | right);
          values.add(value);
        }
      }

      // Always advance by the declared length rather than by what was read: a
      // subtable this code skipped still has to be stepped over exactly.
      if (length <= 0) break;
      reader.offset = subtableStart + length;
    }

    if (pairs.isEmpty) return null;

    // The format requires ascending order and the binary search depends on it,
    // but a font that violates it would silently lose kerning rather than
    // fail, so it is sorted here instead of trusted.
    final List<int> order = List<int>.generate(pairs.length, (int i) => i)
      ..sort((int a, int b) => pairs[a].compareTo(pairs[b]));
    final Uint32List sortedPairs = Uint32List(pairs.length);
    final Int16List sortedValues = Int16List(pairs.length);
    for (int i = 0; i < order.length; i++) {
      sortedPairs[i] = pairs[order[i]];
      sortedValues[i] = values[order[i]];
    }

    return KernTable._(sortedPairs, sortedValues);
  }
}
