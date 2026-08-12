/// `cmap` - from Unicode code point to glyph id.
///
/// The table is a list of subtables, each for a different platform and
/// encoding, and picking the right one matters more than parsing any of them:
/// a font typically ships a Macintosh Roman subtable next to a Unicode one,
/// and choosing the former silently limits the font to 256 characters.
///
/// Four formats are implemented, which covers every desktop font in practice:
///
///   * **4** - segmented BMP mapping. Universally present, and the one whose
///     `idRangeOffset` field is the most commonly mis-implemented thing in the
///     whole format (see [_Format4]);
///   * **12** - segmented full-Unicode mapping. Needed for anything above the
///     BMP, and less code than format 4;
///   * **6** - a trimmed contiguous range. Some subsetted and Mac-origin fonts
///     have nothing else;
///   * **0** - a 256-entry byte table. Legacy, ten lines.
///
/// Formats 2, 8, 10 and 13 are deliberately absent: 2 is legacy CJK high-byte,
/// 8 and 10 are effectively extinct, and 13 is for last-resort fonts.
library;

import 'dart:typed_data';

import 'font_data.dart';
import 'sfnt.dart';

/// The glyph id meaning "no glyph for this character".
///
/// Zero is `.notdef` by definition in every OpenType font, and it is a real
/// glyph - usually an empty box - so a caller can draw it rather than having
/// to special-case a missing character.
const int notdefGlyph = 0;

/// A character-to-glyph mapping.
abstract interface class CharacterMap {
  /// The glyph for [codePoint], or [notdefGlyph] when it is not covered.
  int glyphFor(int codePoint);

  /// Every code point this map covers. Ordered ascending.
  ///
  /// Used by font enumeration to answer "can this face render this string"
  /// without probing character by character, and by the tests to cross-check
  /// a fast lookup against a linear scan.
  Iterable<int> get codePoints;
}

/// The `cmap` table: subtable selection plus the chosen map.
final class CmapTable {
  const CmapTable(this.characterMap, this.encoding);

  final CharacterMap characterMap;

  /// Which `(platformId, encodingId)` was chosen, for diagnostics.
  final ({int platform, int encoding}) encoding;

  int glyphFor(int codePoint) => characterMap.glyphFor(codePoint);

  static CmapTable parse(SfntFile file) {
    final TableRecord record = file.requireTable('cmap');
    final FontReader reader = file.readerFor('cmap');
    reader.skip(2); // version
    final int numTables = reader.readUint16();

    final List<({int platform, int encoding, int offset})> subtables =
        <({int platform, int encoding, int offset})>[];
    for (int i = 0; i < numTables; i++) {
      final int platform = reader.readUint16();
      final int encoding = reader.readUint16();
      final int offset = reader.readUint32();
      subtables.add((platform: platform, encoding: encoding, offset: offset));
    }

    // Preference order, following what FreeType's find_unicode_charmap does:
    // full Unicode first, then BMP Unicode, then Mac Roman as a last resort.
    // The ordering is the policy that matters; a font with several subtables
    // is normal and the wrong pick is silently lossy rather than an error.
    const List<({int platform, int encoding})> preference =
        <({int platform, int encoding})>[
      (platform: 3, encoding: 10), // Windows, UCS-4
      (platform: 0, encoding: 6), // Unicode, full repertoire
      (platform: 0, encoding: 4), // Unicode, UCS-4
      (platform: 3, encoding: 1), // Windows, BMP - the common case
      (platform: 0, encoding: 3), // Unicode, BMP
      (platform: 0, encoding: 2),
      (platform: 0, encoding: 1),
      (platform: 0, encoding: 0),
      (platform: 1, encoding: 0), // Macintosh Roman
    ];

    for (final ({int platform, int encoding}) wanted in preference) {
      for (final ({int platform, int encoding, int offset}) subtable
          in subtables) {
        if (subtable.platform != wanted.platform ||
            subtable.encoding != wanted.encoding) {
          continue;
        }
        final CharacterMap? map = _parseSubtable(
          file,
          record.offset + subtable.offset,
        );
        if (map == null) continue;
        return CmapTable(
          map,
          (platform: subtable.platform, encoding: subtable.encoding),
        );
      }
    }

    throw const FontFormatException(
      'no usable subtable: the font has no Unicode or Mac Roman mapping in a '
      'supported format (0, 4, 6 or 12)',
      table: 'cmap',
    );
  }

  /// Parses one subtable, or returns null when its format is unsupported.
  static CharacterMap? _parseSubtable(SfntFile file, int offset) {
    if (!file.data.contains(offset, 4)) return null;
    final FontReader reader = file.data.readerAt(offset, table: 'cmap');
    final int format = reader.readUint16();
    return switch (format) {
      0 => _Format0.parse(reader),
      4 => _Format4.parse(reader),
      6 => _Format6.parse(reader),
      12 => _Format12.parse(reader),
      _ => null,
    };
  }
}

/// Format 0: a flat 256-byte table, one glyph id per byte value.
final class _Format0 implements CharacterMap {
  _Format0(this._glyphIds);

  final Uint8List _glyphIds;

  @override
  int glyphFor(int codePoint) {
    if (codePoint < 0 || codePoint > 255) return notdefGlyph;
    return _glyphIds[codePoint];
  }

  @override
  Iterable<int> get codePoints sync* {
    for (int i = 0; i < 256; i++) {
      if (_glyphIds[i] != notdefGlyph) yield i;
    }
  }

  static _Format0 parse(FontReader reader) {
    reader.skip(4); // length, language
    return _Format0(Uint8List.fromList(reader.readBytes(256)));
  }
}

/// Format 4: segmented mapping of the Basic Multilingual Plane.
///
/// The format every desktop font has, and the one with the trap. Each segment
/// maps a contiguous range of code points, and does so in one of two ways
/// depending on `idRangeOffset`:
///
///   * zero - the glyph is `codePoint + idDelta`, modulo 65536;
///   * non-zero - it is a **byte offset from the address of the
///     `idRangeOffset` field itself** into `glyphIdArray`.
///
/// That second rule is the notorious part: the offset is relative to where the
/// field sits, not to the start of the table or of the array. It is stored
/// that way so the array could follow the segment records directly. Rather
/// than reproduce the pointer arithmetic, this implementation resolves every
/// segment at parse time into a flat sorted map, which costs one pass over the
/// font's coverage and makes every later lookup a binary search that cannot be
/// wrong.
final class _Format4 implements CharacterMap {
  _Format4(this._codes, this._glyphs);

  /// Ascending code points that map to something.
  final Uint32List _codes;

  /// Glyph ids, parallel to [_codes].
  final Uint16List _glyphs;

  @override
  int glyphFor(int codePoint) {
    int low = 0;
    int high = _codes.length - 1;
    while (low <= high) {
      final int mid = (low + high) >> 1;
      final int value = _codes[mid];
      if (value == codePoint) return _glyphs[mid];
      if (value < codePoint) {
        low = mid + 1;
      } else {
        high = mid - 1;
      }
    }
    return notdefGlyph;
  }

  @override
  Iterable<int> get codePoints => _codes;

  static _Format4 parse(FontReader reader) {
    final int length = reader.readUint16();
    reader.skip(2); // language
    final int segCountX2 = reader.readUint16();
    final int segCount = segCountX2 ~/ 2;
    if (segCount == 0) {
      throw const FontFormatException('no segments', table: 'cmap');
    }
    reader.skip(6); // searchRange, entrySelector, rangeShift

    final Uint16List endCodes = reader.readUint16List(segCount);
    reader.skip(2); // reservedPad
    final Uint16List startCodes = reader.readUint16List(segCount);
    final int idDeltaOffset = reader.offset;
    final Uint16List idDeltas = reader.readUint16List(segCount);
    final int idRangeOffsetBase = reader.offset;
    final Uint16List idRangeOffsets = reader.readUint16List(segCount);

    // The glyph id array is whatever remains of the subtable.
    final int arrayStart = reader.offset;
    final int subtableEnd = idDeltaOffset - segCount * 2 - 8 + length;

    final List<int> codes = <int>[];
    final List<int> glyphs = <int>[];

    for (int segment = 0; segment < segCount; segment++) {
      final int start = startCodes[segment];
      final int end = endCodes[segment];
      // The last segment is required to be 0xFFFF..0xFFFF and maps nothing.
      if (start > end || start == 0xFFFF) continue;

      final int rangeOffset = idRangeOffsets[segment];
      final int delta = idDeltas[segment];

      for (int code = start; code <= end; code++) {
        int glyph;
        if (rangeOffset == 0) {
          glyph = (code + delta) & 0xFFFF;
        } else {
          // The offset is from the field's own address. Its address is
          // idRangeOffsetBase + segment * 2.
          final int at = idRangeOffsetBase +
              segment * 2 +
              rangeOffset +
              (code - start) * 2;
          if (at < arrayStart || at + 2 > subtableEnd) continue;
          if (!reader.data.contains(at, 2)) continue;
          final int raw = reader.data.readerAt(at, table: 'cmap').readUint16();
          // A zero in the array means "not covered", and must not have the
          // delta applied - that would map it to some unrelated glyph.
          if (raw == 0) continue;
          glyph = (raw + delta) & 0xFFFF;
        }
        if (glyph == notdefGlyph) continue;
        codes.add(code);
        glyphs.add(glyph);
      }
    }

    return _Format4(Uint32List.fromList(codes), Uint16List.fromList(glyphs));
  }
}

/// Format 6: a trimmed contiguous range.
final class _Format6 implements CharacterMap {
  _Format6(this._firstCode, this._glyphIds);

  final int _firstCode;
  final Uint16List _glyphIds;

  @override
  int glyphFor(int codePoint) {
    final int index = codePoint - _firstCode;
    if (index < 0 || index >= _glyphIds.length) return notdefGlyph;
    return _glyphIds[index];
  }

  @override
  Iterable<int> get codePoints sync* {
    for (int i = 0; i < _glyphIds.length; i++) {
      if (_glyphIds[i] != notdefGlyph) yield _firstCode + i;
    }
  }

  static _Format6 parse(FontReader reader) {
    reader.skip(4); // length, language
    final int firstCode = reader.readUint16();
    final int entryCount = reader.readUint16();
    return _Format6(firstCode, reader.readUint16List(entryCount));
  }
}

/// Format 12: segmented coverage of the whole Unicode range.
///
/// Sorted groups searched by bisection. Unlike format 4 the groups are kept as
/// groups: a full-Unicode font can cover a hundred thousand code points, and
/// expanding those into a flat array would cost megabytes for no gain, since
/// the group form is already directly searchable.
final class _Format12 implements CharacterMap {
  _Format12(this._startCodes, this._endCodes, this._startGlyphs);

  final Uint32List _startCodes;
  final Uint32List _endCodes;
  final Uint32List _startGlyphs;

  @override
  int glyphFor(int codePoint) {
    int low = 0;
    int high = _startCodes.length - 1;
    while (low <= high) {
      final int mid = (low + high) >> 1;
      if (codePoint < _startCodes[mid]) {
        high = mid - 1;
      } else if (codePoint > _endCodes[mid]) {
        low = mid + 1;
      } else {
        return _startGlyphs[mid] + (codePoint - _startCodes[mid]);
      }
    }
    return notdefGlyph;
  }

  @override
  Iterable<int> get codePoints sync* {
    for (int i = 0; i < _startCodes.length; i++) {
      for (int code = _startCodes[i]; code <= _endCodes[i]; code++) {
        yield code;
      }
    }
  }

  static _Format12 parse(FontReader reader) {
    reader.skip(10); // reserved, length, language
    final int groupCount = reader.readUint32();
    // A sanity bound: the field is 32 bits and a corrupt one would otherwise
    // ask for gigabytes of lists before failing.
    if (groupCount > 0x100000) {
      throw FontFormatException(
        'format 12 claims $groupCount groups, which is not plausible',
        table: 'cmap',
      );
    }
    final Uint32List startCodes = Uint32List(groupCount);
    final Uint32List endCodes = Uint32List(groupCount);
    final Uint32List startGlyphs = Uint32List(groupCount);
    for (int i = 0; i < groupCount; i++) {
      startCodes[i] = reader.readUint32();
      endCodes[i] = reader.readUint32();
      startGlyphs[i] = reader.readUint32();
    }
    return _Format12(startCodes, endCodes, startGlyphs);
  }
}
