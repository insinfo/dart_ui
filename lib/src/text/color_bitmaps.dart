/// Colour glyphs stored as embedded images: Apple's `sbix`, and Google's
/// `CBDT`/`CBLC`.
///
/// Both tables answer one question - "is there a picture of this glyph, and
/// where does it go" - and they answer it the same way: a set of *strikes*,
/// each an image of every glyph drawn at one pixel size, plus the offset of the
/// picture from the glyph's origin. Apple Color Emoji keeps all of its artwork
/// in `sbix`, and Noto Color Emoji keeps all of its in `CBDT`; neither has a
/// usable outline behind the picture. This file is why those two faces draw an
/// emoji rather than a box.
///
/// ## What is parsed, and when
///
/// Only the table headers are read when a face asks for this - strike sizes
/// and where each strike's index lives. A glyph's own record is read when that
/// glyph is drawn, because Apple Color Emoji is 190 MB of PNGs and a label with
/// one smiley needs exactly one of them. Nothing is decoded here: a
/// [ColorBitmapGlyph] is a borrowed view of compressed bytes plus placement, and
/// decoding them is the renderer's job - the same split `glyf` has, where this
/// layer produces outlines and the renderer rasterises them (section 22.7).
///
/// ## Limits, stated
///
///  * `sbix` graphic types `png `, `jpg ` and `tiff` are returned as they are
///    found; the renderer decodes the first two. `mask` - never shipped by
///    anyone - and `dupe` chains longer than [_maxDupeDepth] are treated as
///    "no picture". `flags` bit 1, "also draw the outline", is reported by
///    [SbixTable.drawsOutlines] and not acted on: no shipping face sets it.
///  * `CBDT` image formats 17, 18 and 19 - PNG with small, big and index-side
///    metrics - are read; the uncompressed formats 1 to 9 (monochrome and
///    grey bitmaps, the `EBDT` heritage) are not, and such a glyph reports no
///    picture. Every shipping colour face uses the PNG formats. Index
///    subtable formats 1 to 5 are all read.
///  * vertical metrics are ignored; text here is laid out horizontally.
library;

import 'dart:typed_data';

import 'font_data.dart';
import 'sfnt.dart';

/// One glyph's picture, as stored, and where it sits.
///
/// All placement is in **pixels of the strike** ([ppem]), y up from the
/// baseline, the way both tables store it. A renderer drawing at another size
/// scales every number here by `pixelSize / ppem`.
final class ColorBitmapGlyph {
  const ColorBitmapGlyph({
    required this.glyphId,
    required this.strikeIndex,
    required this.ppem,
    required this.format,
    required this.data,
    required this.left,
    required this.bottom,
    this.width,
    this.height,
  });

  /// The glyph whose record supplied [data] - the requested glyph, or the one
  /// an `sbix` `dupe` record pointed at.
  final int glyphId;

  /// Which strike [data] came from, in table order. Part of any cache key:
  /// two strikes hold two different pictures of the same glyph.
  final int strikeIndex;

  /// The pixels per em the picture was drawn for.
  final int ppem;

  /// `png `, `jpg ` or `tiff`: the `sbix` graphic type, or `png ` for `CBDT`.
  final String format;

  /// The compressed image bytes - a view into the font file, not a copy.
  final Uint8List data;

  /// Left edge of the picture relative to the pen position, in strike pixels.
  final int left;

  /// Bottom edge of the picture relative to the baseline, in strike pixels,
  /// **y up**: `-12` is twelve pixels below the baseline.
  final int bottom;

  /// The picture's size in strike pixels when the table states it (`CBDT`),
  /// or null when only the image itself knows (`sbix`).
  final int? width;
  final int? height;

  @override
  String toString() => 'ColorBitmapGlyph(glyph $glyphId, strike $strikeIndex '
      '@${ppem}ppem, ${format.trim()}, ${data.length} bytes, '
      'origin ($left, $bottom))';
}

/// The colour-bitmap tables of one face, whichever of the two it carries.
abstract interface class ColorBitmapTable {
  /// The tag this was read from: `sbix` or `CBDT`.
  String get tag;

  /// Pixel sizes of the strikes, in table order.
  List<int> get strikeSizes;

  /// The picture of [glyphId] best suited to drawing at [pixelSize], or null
  /// when no strike has one.
  ///
  /// "Best suited" is the rule a downscale wants: the **smallest strike at
  /// least as large as [pixelSize]**, so the image is only ever shrunk and
  /// shrunk as little as possible; failing that, the largest strike there is.
  /// A glyph missing from that strike is looked for in the others, nearest
  /// first, because a face may leave a glyph out of its small strikes.
  ColorBitmapGlyph? glyphAt(int glyphId, double pixelSize);

  /// Reads whichever colour-bitmap table [sfnt] has, or returns null.
  ///
  /// `sbix` first, because a face with both is an Apple face that kept `CBDT`
  /// for some other renderer. Throws [FontFormatException] for a table whose
  /// header is malformed; a malformed *glyph record* is found later, and that
  /// glyph alone reports no picture.
  static ColorBitmapTable? read(SfntFile sfnt, int glyphCount) {
    if (sfnt.hasTable('sbix')) return SbixTable.parse(sfnt, glyphCount);
    if (sfnt.hasTable('CBDT') && sfnt.hasTable('CBLC')) {
      return CbdtTable.parse(sfnt);
    }
    return null;
  }
}

/// The order strikes are tried in for [pixelSize]: the smallest one at least
/// that large, then the larger ones ascending, then the smaller ones
/// descending - so the first hit is always the least scaling available.
List<int> _strikeOrder(List<int> sizes, double pixelSize) {
  final List<int> order = List<int>.generate(sizes.length, (int i) => i)
    ..sort((int a, int b) => sizes[a].compareTo(sizes[b]));
  final List<int> above = <int>[
    for (final int i in order)
      if (sizes[i] >= pixelSize) i,
  ];
  final List<int> below = <int>[
    for (final int i in order.reversed)
      if (sizes[i] < pixelSize) i,
  ];
  return <int>[...above, ...below];
}

/// How many `dupe` records may be followed before giving up.
///
/// One is what fonts use; the bound exists because a record that points at
/// itself is a loop, and a font must not be able to hang the renderer.
const int _maxDupeDepth = 4;

// ---------------------------------------------------------------------------
// sbix
// ---------------------------------------------------------------------------

/// `sbix` - Apple's standard bitmap graphics table.
///
/// The layout: a header listing strike offsets; each strike is `ppem`, `ppi`
/// and one offset per glyph plus one, so glyph `g`'s record is the bytes
/// between offsets `g` and `g + 1` - empty when the strike has no picture of
/// it. A record is `originOffsetX`, `originOffsetY` (int16, strike pixels, the
/// bottom-left corner of the picture relative to the glyph origin), a four
/// byte graphic type and the image data.
final class SbixTable implements ColorBitmapTable {
  SbixTable._(
    this._data,
    this._tableOffset,
    this._tableLength,
    this._glyphCount,
    this.flags,
    this._strikeOffsets,
    this.strikeSizes,
    this.strikePpi,
  );

  final FontData _data;
  final int _tableOffset;
  final int _tableLength;
  final int _glyphCount;

  /// The header flags. Bit 0 is always set; see [drawsOutlines] for bit 1.
  final int flags;

  /// Strike start, absolute in the file, per strike.
  final List<int> _strikeOffsets;

  @override
  final List<int> strikeSizes;

  /// The density each strike was drawn for. Informational: Apple ships 72 and
  /// 144 and the choice of strike here is by [strikeSizes] alone.
  final List<int> strikePpi;

  @override
  String get tag => 'sbix';

  /// Whether the face asks for its outlines to be drawn *as well as* the
  /// pictures (flags bit 1). Reported, not acted on - see the library comment.
  bool get drawsOutlines => flags & 2 != 0;

  /// Reads the header and the strike list. Throws [FontFormatException] when
  /// either runs past the table.
  static SbixTable parse(SfntFile sfnt, int glyphCount) {
    final TableRecord record = sfnt.requireTable('sbix');
    final FontReader reader = sfnt.readerFor('sbix');
    reader.readUint16(); // version
    final int flags = reader.readUint16();
    final int count = reader.readUint32();
    // Each strike costs at least its 4-byte header plus the offset array, so a
    // count that cannot fit in the table is a corrupt header, not a big font.
    if (count * 4 + 8 > record.length) {
      throw FontFormatException(
        'sbix claims $count strikes in ${record.length} bytes',
        table: 'sbix',
      );
    }
    final List<int> offsets = <int>[];
    final List<int> sizes = <int>[];
    final List<int> ppis = <int>[];
    for (int i = 0; i < count; i++) {
      final int relative = reader.readUint32();
      if (relative + 4 + (glyphCount + 1) * 4 > record.length) {
        throw FontFormatException(
          'sbix strike $i at $relative runs past the table',
          table: 'sbix',
        );
      }
      final int absolute = record.offset + relative;
      final FontReader strike = sfnt.data.readerAt(absolute, table: 'sbix');
      sizes.add(strike.readUint16());
      ppis.add(strike.readUint16());
      offsets.add(absolute);
    }
    return SbixTable._(
      sfnt.data,
      record.offset,
      record.length,
      glyphCount,
      flags,
      List<int>.unmodifiable(offsets),
      List<int>.unmodifiable(sizes),
      List<int>.unmodifiable(ppis),
    );
  }

  @override
  ColorBitmapGlyph? glyphAt(int glyphId, double pixelSize) {
    if (glyphId < 0 || glyphId >= _glyphCount) return null;
    for (final int strike in _strikeOrder(strikeSizes, pixelSize)) {
      final ColorBitmapGlyph? found = glyphInStrike(glyphId, strike);
      if (found != null) return found;
    }
    return null;
  }

  /// The record of [glyphId] in strike [strike], following `dupe`, or null.
  ///
  /// Null for an empty record, for a graphic type that is not an image, and
  /// for a record that is malformed - one glyph's bad bytes must not cost the
  /// rest of the face its emoji.
  ColorBitmapGlyph? glyphInStrike(int glyphId, int strike) {
    int glyph = glyphId;
    for (int depth = 0; depth <= _maxDupeDepth; depth++) {
      if (glyph < 0 || glyph >= _glyphCount) return null;
      try {
        final int base = _strikeOffsets[strike];
        final FontReader offsets =
            _data.readerAt(base + 4 + glyph * 4, table: 'sbix');
        final int start = offsets.readUint32();
        final int end = offsets.readUint32();
        // Fewer than eight bytes cannot hold the record header, and zero is
        // the ordinary "this strike has no picture of this glyph".
        if (end <= start || end - start < 8) return null;
        final int absolute = base + start;
        if (absolute + (end - start) > _tableOffset + _tableLength) {
          return null;
        }
        final FontReader record = _data.readerAt(absolute, table: 'sbix');
        final int originX = record.readInt16();
        final int originY = record.readInt16();
        final String type = record.readTag();
        final Uint8List bytes = record.readBytes(end - start - 8);
        if (type == 'dupe') {
          if (bytes.length < 2) return null;
          glyph = (bytes[0] << 8) | bytes[1];
          continue;
        }
        if (type != 'png ' && type != 'jpg ' && type != 'tiff') return null;
        return ColorBitmapGlyph(
          glyphId: glyph,
          strikeIndex: strike,
          ppem: strikeSizes[strike],
          format: type,
          data: bytes,
          left: originX,
          bottom: originY,
        );
      } on FontFormatException {
        return null;
      }
    }
    return null;
  }

  @override
  String toString() => 'SbixTable(${strikeSizes.length} strikes: '
      '${strikeSizes.join(', ')} ppem)';
}

// ---------------------------------------------------------------------------
// CBDT / CBLC
// ---------------------------------------------------------------------------

/// One `CBLC` BitmapSize record: a strike, and where its index lives.
final class _CblcStrike {
  const _CblcStrike({
    required this.ppem,
    required this.arrayOffset,
    required this.subtableCount,
    required this.startGlyph,
    required this.endGlyph,
  });

  final int ppem;

  /// Absolute file offset of the IndexSubTableArray.
  final int arrayOffset;
  final int subtableCount;
  final int startGlyph;
  final int endGlyph;
}

/// `CBDT` + `CBLC` - Google's colour bitmap tables, the `EBDT`/`EBLC` pair
/// with PNG payloads.
///
/// `CBLC` is the index: per strike, a list of glyph ranges, each pointing at
/// an index subtable that says where in `CBDT` each glyph's record starts.
/// `CBDT` holds the records: metrics (unless the index carried them) and the
/// PNG. Placement is `bearingX` from the pen to the left edge and `bearingY`
/// from the baseline *up* to the top edge, which [glyphAt] converts to the
/// bottom-left convention `sbix` uses so a renderer handles one shape.
final class CbdtTable implements ColorBitmapTable {
  CbdtTable._(this._data, this._cbdtOffset, this._cbdtLength, this._strikes)
      : strikeSizes = List<int>.unmodifiable(<int>[
          for (final _CblcStrike strike in _strikes) strike.ppem,
        ]);

  final FontData _data;
  final int _cbdtOffset;
  final int _cbdtLength;
  final List<_CblcStrike> _strikes;

  @override
  final List<int> strikeSizes;

  @override
  String get tag => 'CBDT';

  /// Reads the `CBLC` strike list. Throws [FontFormatException] when it runs
  /// past the table.
  static CbdtTable parse(SfntFile sfnt) {
    final TableRecord cblc = sfnt.requireTable('CBLC');
    final TableRecord cbdt = sfnt.requireTable('CBDT');
    final FontReader reader = sfnt.readerFor('CBLC');
    reader.readUint16(); // majorVersion
    reader.readUint16(); // minorVersion
    final int count = reader.readUint32();
    if (8 + count * 48 > cblc.length) {
      throw FontFormatException(
        'CBLC claims $count strikes in ${cblc.length} bytes',
        table: 'CBLC',
      );
    }
    final List<_CblcStrike> strikes = <_CblcStrike>[];
    for (int i = 0; i < count; i++) {
      final int arrayOffset = reader.readUint32();
      reader.readUint32(); // indexTablesSize
      final int subtables = reader.readUint32();
      reader.readUint32(); // colorRef
      reader.skip(24); // hori and vert SbitLineMetrics
      final int startGlyph = reader.readUint16();
      final int endGlyph = reader.readUint16();
      final int ppemX = reader.readUint8();
      reader.readUint8(); // ppemY
      reader.readUint8(); // bitDepth
      reader.readUint8(); // flags
      if (arrayOffset + subtables * 8 > cblc.length) {
        throw FontFormatException(
          'CBLC strike $i index array runs past the table',
          table: 'CBLC',
        );
      }
      strikes.add(_CblcStrike(
        ppem: ppemX,
        arrayOffset: cblc.offset + arrayOffset,
        subtableCount: subtables,
        startGlyph: startGlyph,
        endGlyph: endGlyph,
      ));
    }
    return CbdtTable._(
      sfnt.data,
      cbdt.offset,
      cbdt.length,
      List<_CblcStrike>.unmodifiable(strikes),
    );
  }

  @override
  ColorBitmapGlyph? glyphAt(int glyphId, double pixelSize) {
    for (final int strike in _strikeOrder(strikeSizes, pixelSize)) {
      final ColorBitmapGlyph? found = glyphInStrike(glyphId, strike);
      if (found != null) return found;
    }
    return null;
  }

  /// The record of [glyphId] in strike [strike], or null - for a glyph the
  /// strike does not cover, an image format that is not PNG, and a record
  /// that is malformed.
  ColorBitmapGlyph? glyphInStrike(int glyphId, int strike) {
    final _CblcStrike s = _strikes[strike];
    if (glyphId < s.startGlyph || glyphId > s.endGlyph) return null;
    try {
      final FontReader array = _data.readerAt(s.arrayOffset, table: 'CBLC');
      for (int i = 0; i < s.subtableCount; i++) {
        final int first = array.readUint16();
        final int last = array.readUint16();
        final int additional = array.readUint32();
        if (glyphId < first || glyphId > last) continue;
        return _fromSubtable(
          s.arrayOffset + additional,
          glyphId,
          first,
          last,
          strike,
        );
      }
    } on FontFormatException {
      return null;
    }
    return null;
  }

  /// Resolves [glyphId] through the index subtable at [at], then reads its
  /// `CBDT` record.
  ColorBitmapGlyph? _fromSubtable(
    int at,
    int glyphId,
    int first,
    int last,
    int strike,
  ) {
    final FontReader index = _data.readerAt(at, table: 'CBLC');
    final int indexFormat = index.readUint16();
    final int imageFormat = index.readUint16();
    final int imageDataOffset = index.readUint32();
    int start;
    int end;
    _BigMetrics? metrics;
    switch (indexFormat) {
      case 1:
        // uint32 offsets, one per glyph plus one.
        index.skip((glyphId - first) * 4);
        start = index.readUint32();
        end = index.readUint32();
      case 3:
        // The same with uint16 offsets.
        index.skip((glyphId - first) * 2);
        start = index.readUint16();
        end = index.readUint16();
      case 2:
        // Every glyph the same size, back to back, metrics shared.
        final int size = index.readUint32();
        metrics = _BigMetrics.read(index);
        start = (glyphId - first) * size;
        end = start + size;
      case 4:
        // Sparse: (glyph, offset) pairs, plus one sentinel pair.
        final int count = index.readUint32();
        int? found;
        int? next;
        for (int i = 0; i < count; i++) {
          final int glyph = index.readUint16();
          final int offset = index.readUint16();
          if (found != null) {
            next = offset;
            break;
          }
          if (glyph == glyphId) found = offset;
        }
        if (found == null) return null;
        if (next == null) {
          index.readUint16(); // the sentinel's glyph
          next = index.readUint16();
        }
        start = found;
        end = next;
      case 5:
        // Sparse and fixed-size: a sorted glyph list, metrics shared.
        final int size = index.readUint32();
        metrics = _BigMetrics.read(index);
        final int count = index.readUint32();
        int position = -1;
        for (int i = 0; i < count; i++) {
          if (index.readUint16() == glyphId) {
            position = i;
            break;
          }
        }
        if (position < 0) return null;
        start = position * size;
        end = start + size;
      default:
        return null;
    }
    if (end <= start) return null;
    final int absolute = _cbdtOffset + imageDataOffset + start;
    final int length = end - start;
    if (imageDataOffset + start + length > _cbdtLength) return null;
    return _record(absolute, length, imageFormat, metrics, glyphId, strike);
  }

  /// Reads one `CBDT` record of image format 17, 18 or 19.
  ColorBitmapGlyph? _record(
    int at,
    int length,
    int imageFormat,
    _BigMetrics? indexMetrics,
    int glyphId,
    int strike,
  ) {
    final FontReader record = _data.readerAt(at, table: 'CBDT');
    final int width;
    final int height;
    final int bearingX;
    final int bearingY;
    switch (imageFormat) {
      case 17:
        // SmallGlyphMetrics: height, width, bearingX, bearingY, advance.
        height = record.readUint8();
        width = record.readUint8();
        bearingX = record.readInt8();
        bearingY = record.readInt8();
        record.readUint8();
      case 18:
        final _BigMetrics big = _BigMetrics.read(record);
        height = big.height;
        width = big.width;
        bearingX = big.bearingX;
        bearingY = big.bearingY;
      case 19:
        if (indexMetrics == null) return null;
        height = indexMetrics.height;
        width = indexMetrics.width;
        bearingX = indexMetrics.bearingX;
        bearingY = indexMetrics.bearingY;
      default:
        return null;
    }
    final int dataLength = record.readUint32();
    if (record.offset + dataLength > at + length) return null;
    return ColorBitmapGlyph(
      glyphId: glyphId,
      strikeIndex: strike,
      ppem: strikeSizes[strike],
      format: 'png ',
      data: record.readBytes(dataLength),
      left: bearingX,
      bottom: bearingY - height,
      width: width,
      height: height,
    );
  }

  @override
  String toString() => 'CbdtTable(${strikeSizes.length} strikes: '
      '${strikeSizes.join(', ')} ppem)';
}

/// BigGlyphMetrics, horizontal half: the only half horizontal text reads.
final class _BigMetrics {
  const _BigMetrics(this.height, this.width, this.bearingX, this.bearingY);

  /// Reads all eight bytes, so the reader ends past the vertical half too.
  static _BigMetrics read(FontReader reader) {
    final int height = reader.readUint8();
    final int width = reader.readUint8();
    final int bearingX = reader.readInt8();
    final int bearingY = reader.readInt8();
    reader.skip(4); // horiAdvance, vertBearingX, vertBearingY, vertAdvance
    return _BigMetrics(height, width, bearingX, bearingY);
  }

  final int height;
  final int width;
  final int bearingX;
  final int bearingY;
}
