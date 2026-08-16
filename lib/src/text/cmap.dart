/// `cmap` - from Unicode code point to glyph id.
///
/// The table is a list of subtables, each for a different platform and
/// encoding, and picking the right one matters more than parsing any of them:
/// a font typically ships a Macintosh Roman subtable next to a Unicode one,
/// and choosing the former silently limits the font to 256 characters.
///
/// Six formats are implemented, which covers every desktop font in practice:
///
///   * **4** - segmented BMP mapping. Universally present, and the one whose
///     `idRangeOffset` field is the most commonly mis-implemented thing in the
///     whole format (see [_Format4]);
///   * **12** - segmented full-Unicode mapping. Needed for anything above the
///     BMP, and less code than format 4;
///   * **6** - a trimmed contiguous range. Some subsetted and Mac-origin fonts
///     have nothing else;
///   * **0** - a 256-entry byte table. Legacy, ten lines.
///   * **13** - many-to-one. The same shape as format 12, but every code point
///     in a group maps to the *same* glyph rather than to consecutive ones.
///     Only last-resort fonts use it, and those are precisely the fonts a
///     fallback chain ends with, so it is not optional for that chain to work;
///   * **14** - Unicode Variation Sequences. Not a character map at all: it
///     answers "which glyph for this base character *followed by this
///     variation selector*", which is what decides text versus emoji
///     presentation and what makes CJK ideographic variants render. See
///     [VariationSelectorMap].
///
/// Formats 2, 8 and 10 are deliberately absent: 2 is legacy CJK high-byte, and
/// 8 and 10 are effectively extinct.
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

/// U+FE0E, VARIATION SELECTOR-15: "render the preceding character as text".
///
/// The selector a caller appends to force a monochrome glyph for a character
/// that a colour font would otherwise draw as an emoji.
const int variationSelectorText = 0xFE0E;

/// U+FE0F, VARIATION SELECTOR-16: "render the preceding character as emoji".
const int variationSelectorEmoji = 0xFE0F;

/// The `cmap` table: subtable selection plus the chosen map.
final class CmapTable {
  const CmapTable(this.characterMap, this.encoding, {this.variationSelectors});

  final CharacterMap characterMap;

  /// Which `(platformId, encodingId)` was chosen, for diagnostics.
  final ({int platform, int encoding}) encoding;

  /// The format 14 subtable, when the font has one. Null for the vast
  /// majority of fonts, which carry no variation sequences at all.
  final VariationSelectorMap? variationSelectors;

  int glyphFor(int codePoint) => characterMap.glyphFor(codePoint);

  /// The glyph for [baseCodePoint] followed by [variationSelector], or null
  /// when the font defines no such sequence.
  ///
  /// This is the whole point of format 14, and the three outcomes are
  /// genuinely different things that a single nullable int can still express
  /// correctly, because two of them agree on the answer:
  ///
  ///   * **not covered** - the font declares nothing about this pair. Null.
  ///     The caller should drop the selector and render the base character
  ///     alone, which is what the Unicode standard prescribes;
  ///   * **default UVS** - the font declares "for this pair, my ordinary
  ///     mapping is already right". The answer is `glyphFor(baseCodePoint)`,
  ///     and the record exists so that the font can *assert* that rather than
  ///     leave a renderer guessing. Returned as that glyph;
  ///   * **non-default UVS** - the font declares a specific, different glyph.
  ///     Returned as that glyph.
  ///
  /// The distinction between the first and second matters: `U+1F600 U+FE0E`
  /// resolving to null in a colour emoji font means the font has no text
  /// presentation and the caller must fall back to another face, while a
  /// default-UVS hit means "yes, and it is the glyph you already have". Callers
  /// that need to tell the two apart without a second lookup use
  /// [variationSelectors] directly.
  ///
  /// A null [variationSelectors] short-circuits to null, so this costs one
  /// null check on the overwhelmingly common path.
  int? glyphForVariation(int baseCodePoint, int variationSelector) {
    final VariationSelectorMap? map = variationSelectors;
    if (map == null) return null;
    final int? specific = map.nonDefaultGlyph(baseCodePoint, variationSelector);
    if (specific != null) return specific;
    if (map.isDefaultVariation(baseCodePoint, variationSelector)) {
      final int glyph = characterMap.glyphFor(baseCodePoint);
      return glyph == notdefGlyph ? null : glyph;
    }
    return null;
  }

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

    // The variation selector subtable is not an alternative to the others: it
    // is a *supplement*, always at platform 0 / encoding 5, and a font with one
    // also has a real character map. So it is looked up on its own rather than
    // competing in the preference loop above.
    VariationSelectorMap? variations;
    for (final ({int platform, int encoding, int offset}) subtable
        in subtables) {
      if (subtable.platform != 0 || subtable.encoding != 5) continue;
      variations = VariationSelectorMap.parseAt(
        file,
        record.offset + subtable.offset,
      );
      break;
    }

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
          variationSelectors: variations,
        );
      }
    }

    throw const FontFormatException(
      'no usable subtable: the font has no Unicode or Mac Roman mapping in a '
      'supported format (0, 4, 6, 12 or 13)',
      table: 'cmap',
    );
  }

  /// Parses one subtable, or returns null when its format is unsupported.
  ///
  /// Format 14 is absent from this switch on purpose: it is not a
  /// [CharacterMap] and cannot answer `glyphFor`. See [VariationSelectorMap].
  static CharacterMap? _parseSubtable(SfntFile file, int offset) {
    if (!file.data.contains(offset, 4)) return null;
    final FontReader reader = file.data.readerAt(offset, table: 'cmap');
    final int format = reader.readUint16();
    return switch (format) {
      0 => _Format0.parse(reader),
      4 => _Format4.parse(reader),
      6 => _Format6.parse(reader),
      12 => _Format12.parse(reader),
      13 => _Format13.parse(reader),
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

/// Format 13: many code points to one glyph.
///
/// Byte-for-byte the same layout as format 12, and one word different in
/// meaning: the third field of a group is the glyph for **every** code point in
/// it, not the glyph for its first. That single difference is why it cannot
/// share format 12's lookup - reading a format 13 table as a format 12 one
/// yields ascending garbage glyph ids rather than an obvious failure.
///
/// It exists for last-resort fonts: a face that maps all of Devanagari to one
/// box glyph, all of Thai to another, and so on, so that a user sees "there is
/// text here in a script you have no font for" instead of a row of identical
/// `.notdef` boxes. A fallback chain that does not implement it stops one link
/// short of the link that exists specifically to be last.
final class _Format13 implements CharacterMap {
  _Format13(this._startCodes, this._endCodes, this._glyphs);

  final Uint32List _startCodes;
  final Uint32List _endCodes;
  final Uint32List _glyphs;

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
        return _glyphs[mid];
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

  static _Format13 parse(FontReader reader) {
    reader.skip(10); // reserved, length, language
    final int groupCount = reader.readUint32();
    if (groupCount > 0x100000) {
      throw FontFormatException(
        'format 13 claims $groupCount groups, which is not plausible',
        table: 'cmap',
      );
    }
    final Uint32List startCodes = Uint32List(groupCount);
    final Uint32List endCodes = Uint32List(groupCount);
    final Uint32List glyphs = Uint32List(groupCount);
    for (int i = 0; i < groupCount; i++) {
      startCodes[i] = reader.readUint32();
      endCodes[i] = reader.readUint32();
      glyphs[i] = reader.readUint32();
    }
    return _Format13(startCodes, endCodes, glyphs);
  }
}

/// Format 14: Unicode Variation Sequences.
///
/// ## What it decides
///
/// A variation sequence is a base character followed by a variation selector,
/// and it is how Unicode says "this character, but that particular shape". Two
/// families of them matter:
///
///   * **presentation selectors**, U+FE0E and U+FE0F. `U+2764 U+FE0E` is a
///     black-and-white heart and `U+2764 U+FE0F` is the red emoji one - the
///     same code point, and the selector is the only thing distinguishing
///     them. Without this table a renderer cannot honour the request, and text
///     that asked for a text-presentation glyph gets an emoji in the middle of
///     a paragraph;
///   * **ideographic variation sequences**, U+E0100..U+E01EF. A CJK character
///     whose correct shape differs between a Japanese personal name and its
///     ordinary form. Legal documents in Japan depend on these.
///
/// ## The two record kinds, and why they are not the same
///
/// Each selector has two optional tables, and a base character may appear in
/// either:
///
///   * a **default UVS** record means "for this pair, the glyph from my
///     ordinary `cmap` is already the right one". It carries no glyph id
///     because it does not need to: it is an assertion, and the payoff is that
///     a renderer knows the sequence is supported rather than unknown;
///   * a **non-default UVS** record carries an explicit glyph id, because the
///     sequence needs a glyph that no plain code point maps to.
///
/// Conflating them is the classic bug in both directions: treating a default
/// record as "no glyph" drops support the font does have, and treating it as if
/// it carried a glyph id reads the next record's bytes.
///
/// ## Storage
///
/// Everything is flattened into six typed arrays at parse time, with each
/// selector owning a slice of the default-range arrays and a slice of the
/// non-default mapping arrays. Two binary searches per query, no allocation,
/// and no per-selector object - which matters because a large CJK font has a
/// few hundred selectors and tens of thousands of mappings.
final class VariationSelectorMap {
  VariationSelectorMap._({
    required Uint32List selectors,
    required Int32List defaultStart,
    required Int32List defaultCount,
    required Uint32List defaultRangeFirst,
    required Uint32List defaultRangeLast,
    required Int32List nonDefaultStart,
    required Int32List nonDefaultCount,
    required Uint32List nonDefaultCodes,
    required Uint16List nonDefaultGlyphs,
  })  : _selectors = selectors,
        _defaultStart = defaultStart,
        _defaultCount = defaultCount,
        _defaultRangeFirst = defaultRangeFirst,
        _defaultRangeLast = defaultRangeLast,
        _nonDefaultStart = nonDefaultStart,
        _nonDefaultCount = nonDefaultCount,
        _nonDefaultCodes = nonDefaultCodes,
        _nonDefaultGlyphs = nonDefaultGlyphs;

  final Uint32List _selectors;
  final Int32List _defaultStart;
  final Int32List _defaultCount;
  final Uint32List _defaultRangeFirst;
  final Uint32List _defaultRangeLast;
  final Int32List _nonDefaultStart;
  final Int32List _nonDefaultCount;
  final Uint32List _nonDefaultCodes;
  final Uint16List _nonDefaultGlyphs;

  /// Every variation selector the font says something about, ascending.
  Iterable<int> get selectors => _selectors;

  /// How many selectors this table covers.
  int get selectorCount => _selectors.length;

  /// Whether the font declares anything at all about [variationSelector].
  bool hasSelector(int variationSelector) =>
      _indexOfSelector(variationSelector) >= 0;

  /// Whether `(base, selector)` is a **default** sequence: supported, and
  /// served by the ordinary `cmap` glyph.
  ///
  /// False both when the pair is a non-default sequence and when it is not
  /// covered at all - the two are told apart by [nonDefaultGlyph].
  bool isDefaultVariation(int baseCodePoint, int variationSelector) {
    final int selector = _indexOfSelector(variationSelector);
    if (selector < 0) return false;
    final int count = _defaultCount[selector];
    if (count == 0) return false;
    final int start = _defaultStart[selector];

    int low = start;
    int high = start + count - 1;
    while (low <= high) {
      final int mid = (low + high) >> 1;
      if (baseCodePoint < _defaultRangeFirst[mid]) {
        high = mid - 1;
      } else if (baseCodePoint > _defaultRangeLast[mid]) {
        low = mid + 1;
      } else {
        return true;
      }
    }
    return false;
  }

  /// The explicit glyph for a **non-default** sequence, or null.
  ///
  /// Null means either "this pair is a default sequence" or "this pair is not
  /// covered"; [isDefaultVariation] separates those.
  int? nonDefaultGlyph(int baseCodePoint, int variationSelector) {
    final int selector = _indexOfSelector(variationSelector);
    if (selector < 0) return null;
    final int count = _nonDefaultCount[selector];
    if (count == 0) return null;
    final int start = _nonDefaultStart[selector];

    int low = start;
    int high = start + count - 1;
    while (low <= high) {
      final int mid = (low + high) >> 1;
      final int code = _nonDefaultCodes[mid];
      if (code == baseCodePoint) return _nonDefaultGlyphs[mid];
      if (code < baseCodePoint) {
        low = mid + 1;
      } else {
        high = mid - 1;
      }
    }
    return null;
  }

  /// Whether the font declares `(base, selector)` at all, either way.
  bool covers(int baseCodePoint, int variationSelector) =>
      nonDefaultGlyph(baseCodePoint, variationSelector) != null ||
      isDefaultVariation(baseCodePoint, variationSelector);

  int _indexOfSelector(int variationSelector) {
    int low = 0;
    int high = _selectors.length - 1;
    while (low <= high) {
      final int mid = (low + high) >> 1;
      final int value = _selectors[mid];
      if (value == variationSelector) return mid;
      if (value < variationSelector) {
        low = mid + 1;
      } else {
        high = mid - 1;
      }
    }
    return -1;
  }

  /// Parses a format 14 subtable that starts at [offset] in the file.
  ///
  /// Returns null when the bytes there are not a format 14 subtable, which
  /// covers the one real case: a font that advertises platform 0 / encoding 5
  /// and points it at something else. Refusing loudly there would cost the
  /// whole face over a subtable nothing else needs.
  static VariationSelectorMap? parseAt(SfntFile file, int offset) {
    if (!file.data.contains(offset, 10)) return null;
    final FontReader reader = file.data.readerAt(offset, table: 'cmap');
    if (reader.readUint16() != 14) return null;
    reader.skip(4); // length
    final int recordCount = reader.readUint32();
    // Each record is 11 bytes, and the selector space is only 256 values wide
    // (FE00..FE0F plus E0100..E01EF), so anything past that is corruption.
    if (recordCount > 0x1000) {
      throw FontFormatException(
        'format 14 claims $recordCount variation selector records, which is '
        'more than the selector space holds',
        table: 'cmap',
        offset: offset,
      );
    }

    final Uint32List selectors = Uint32List(recordCount);
    final Uint32List defaultOffsets = Uint32List(recordCount);
    final Uint32List nonDefaultOffsets = Uint32List(recordCount);
    for (int i = 0; i < recordCount; i++) {
      selectors[i] = _readUint24(reader);
      defaultOffsets[i] = reader.readUint32();
      nonDefaultOffsets[i] = reader.readUint32();
      // [_indexOfSelector] bisects this array. Same reasoning as the two
      // ordering checks further down: the specification guarantees ascending
      // order, and a font that breaks it must fail rather than mis-answer.
      if (i > 0 && selectors[i] <= selectors[i - 1]) {
        throw FontFormatException(
          'format 14 variation selector records are not in ascending order',
          table: 'cmap',
          offset: offset,
        );
      }
    }

    final Int32List defaultStart = Int32List(recordCount);
    final Int32List defaultCount = Int32List(recordCount);
    final Int32List nonDefaultStart = Int32List(recordCount);
    final Int32List nonDefaultCount = Int32List(recordCount);

    final List<int> rangeFirst = <int>[];
    final List<int> rangeLast = <int>[];
    final List<int> codes = <int>[];
    final List<int> glyphs = <int>[];

    for (int i = 0; i < recordCount; i++) {
      defaultStart[i] = rangeFirst.length;
      if (defaultOffsets[i] != 0) {
        // Both offsets are from the start of the format 14 subtable, not from
        // the start of `cmap` and not from the record.
        final int at = offset + defaultOffsets[i];
        if (file.data.contains(at, 4)) {
          final FontReader ranges = file.data.readerAt(at, table: 'cmap');
          final int count = ranges.readUint32();
          if (count <= 0x100000 && file.data.contains(at + 4, count * 4)) {
            for (int r = 0; r < count; r++) {
              final int first = _readUint24(ranges);
              // additionalCount is the number of code points *after* the
              // first, so a range of one has additionalCount 0 - not 1.
              final int additional = ranges.readUint8();
              // The lookups below bisect these arrays, so ascending order is a
              // correctness precondition, not a nicety. The specification
              // requires it; a font that breaks it would otherwise return
              // confidently wrong glyphs instead of failing.
              if (r > 0 && first <= rangeLast[rangeFirst.length - 1]) {
                throw FontFormatException(
                  'format 14 default UVS ranges for selector '
                  'U+${selectors[i].toRadixString(16).toUpperCase()} are not '
                  'in ascending order',
                  table: 'cmap',
                  offset: at,
                );
              }
              rangeFirst.add(first);
              rangeLast.add(first + additional);
            }
          }
        }
      }
      defaultCount[i] = rangeFirst.length - defaultStart[i];

      nonDefaultStart[i] = codes.length;
      if (nonDefaultOffsets[i] != 0) {
        final int at = offset + nonDefaultOffsets[i];
        if (file.data.contains(at, 4)) {
          final FontReader mappings = file.data.readerAt(at, table: 'cmap');
          final int count = mappings.readUint32();
          if (count <= 0x100000 && file.data.contains(at + 4, count * 5)) {
            for (int m = 0; m < count; m++) {
              final int code = _readUint24(mappings);
              if (m > 0 && code <= codes[codes.length - 1]) {
                throw FontFormatException(
                  'format 14 non-default UVS mappings for selector '
                  'U+${selectors[i].toRadixString(16).toUpperCase()} are not '
                  'in ascending order',
                  table: 'cmap',
                  offset: at,
                );
              }
              codes.add(code);
              glyphs.add(mappings.readUint16());
            }
          }
        }
      }
      nonDefaultCount[i] = codes.length - nonDefaultStart[i];
    }

    if (recordCount == 0) return null;

    return VariationSelectorMap._(
      selectors: selectors,
      defaultStart: defaultStart,
      defaultCount: defaultCount,
      defaultRangeFirst: Uint32List.fromList(rangeFirst),
      defaultRangeLast: Uint32List.fromList(rangeLast),
      nonDefaultStart: nonDefaultStart,
      nonDefaultCount: nonDefaultCount,
      nonDefaultCodes: Uint32List.fromList(codes),
      nonDefaultGlyphs: Uint16List.fromList(glyphs),
    );
  }

  /// A 24-bit big-endian code point, the width format 14 stores every
  /// character in. Three bytes is enough for U+10FFFF and the format predates
  /// nobody caring about four.
  static int _readUint24(FontReader reader) =>
      (reader.readUint8() << 16) |
      (reader.readUint8() << 8) |
      reader.readUint8();
}
