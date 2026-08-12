/// The tables needed to measure and draw TrueType text.
///
/// Six of them, and no more than six: `head`, `maxp`, `hhea`, `hmtx`, `cmap`
/// and `loca`. Everything else an OpenType font can carry - names, panose
/// classification, vertical metrics, colour layers, variations - is either
/// metadata or a later feature, and parsing it now would be code with no
/// caller.
///
/// Each table is parsed eagerly into small fixed structures, because each is
/// small and every glyph lookup touches them. `glyf` is the exception and it
/// lives in `glyf.dart`: it is the bulk of the file and is decoded one glyph at
/// a time, on demand.
library;

import 'dart:typed_data';

import 'font_data.dart';
import 'sfnt.dart';

/// `head` - the font header.
///
/// Two fields here decide how the rest of the font is read: [unitsPerEm], the
/// grid every coordinate is expressed in, and [indexToLocFormat], which decides
/// whether `loca` holds 16- or 32-bit offsets.
final class HeadTable {
  const HeadTable({
    required this.unitsPerEm,
    required this.indexToLocFormat,
    required this.xMin,
    required this.yMin,
    required this.xMax,
    required this.yMax,
    required this.macStyle,
  });

  /// Font design units per em. 1000 for PostScript-derived fonts, 2048 for
  /// most TrueType ones, and always a power of two for the latter.
  final int unitsPerEm;

  /// 0 = `loca` holds uint16 offsets, halved; 1 = uint32 offsets, as-is.
  final int indexToLocFormat;

  final int xMin, yMin, xMax, yMax;

  /// Bit 0 is bold, bit 1 italic. Used to decide whether a face needs
  /// synthetic emboldening or slanting.
  final int macStyle;

  bool get isBold => macStyle & 0x01 != 0;

  bool get isItalic => macStyle & 0x02 != 0;

  static HeadTable parse(SfntFile file) {
    final FontReader reader = file.readerFor('head');
    reader.skip(18); // version, fontRevision, checkSumAdjustment, magic, flags
    final int unitsPerEm = reader.readUint16();
    reader.skip(16); // created, modified
    final int xMin = reader.readInt16();
    final int yMin = reader.readInt16();
    final int xMax = reader.readInt16();
    final int yMax = reader.readInt16();
    final int macStyle = reader.readUint16();
    reader.skip(4); // lowestRecPPEM, fontDirectionHint
    final int indexToLocFormat = reader.readInt16();

    // FreeType rejects anything outside 16..16384, and so do we: unitsPerEm is
    // a divisor in every scale computation, and a zero here turns every glyph
    // into infinities that only surface as a blank window much later.
    if (unitsPerEm < 16 || unitsPerEm > 16384) {
      throw FontFormatException(
        'unitsPerEm $unitsPerEm is outside the legal range 16..16384',
        table: 'head',
      );
    }
    if (indexToLocFormat != 0 && indexToLocFormat != 1) {
      throw FontFormatException(
        'indexToLocFormat $indexToLocFormat is neither short (0) nor long (1)',
        table: 'head',
      );
    }

    return HeadTable(
      unitsPerEm: unitsPerEm,
      indexToLocFormat: indexToLocFormat,
      xMin: xMin,
      yMin: yMin,
      xMax: xMax,
      yMax: yMax,
      macStyle: macStyle,
    );
  }
}

/// `maxp` - how many glyphs the font has, and how deep composites nest.
final class MaxpTable {
  const MaxpTable({
    required this.numGlyphs,
    required this.maxPoints,
    required this.maxContours,
    required this.maxCompositePoints,
    required this.maxCompositeContours,
    required this.maxZones,
    required this.maxTwilightPoints,
    required this.maxStorage,
    required this.maxFunctionDefs,
    required this.maxInstructionDefs,
    required this.maxStackElements,
    required this.maxSizeOfInstructions,
    required this.maxComponentElements,
    required this.maxComponentDepth,
  });

  final int numGlyphs;
  final int maxPoints;
  final int maxContours;
  final int maxCompositePoints;
  final int maxCompositeContours;
  final int maxZones;
  final int maxTwilightPoints;
  final int maxStorage;
  final int maxFunctionDefs;
  final int maxInstructionDefs;
  final int maxStackElements;
  final int maxSizeOfInstructions;
  final int maxComponentElements;

  /// The font's own claim about composite nesting. Advisory: it is used as a
  /// hint, never as the only guard, because a font that lies about it is
  /// exactly the font that would recurse forever.
  final int maxComponentDepth;

  static MaxpTable parse(SfntFile file) {
    final FontReader reader = file.readerFor('maxp');
    final double version = reader.readFixed();
    final int numGlyphs = reader.readUint16();
    int maxPoints = 0;
    int maxContours = 0;
    int maxCompositePoints = 0;
    int maxCompositeContours = 0;
    int maxZones = 0;
    int maxTwilightPoints = 0;
    int maxStorage = 0;
    int maxFunctionDefs = 0;
    int maxInstructionDefs = 0;
    int maxStackElements = 0;
    int maxSizeOfInstructions = 0;
    int maxComponentElements = 0;
    int maxComponentDepth = 0;
    // Version 0.5 is the header and the glyph count, nothing else - it is what
    // CFF fonts carry, and reading past it would read another table's bytes.
    if (version >= 1.0) {
      maxPoints = reader.readUint16();
      maxContours = reader.readUint16();
      maxCompositePoints = reader.readUint16();
      maxCompositeContours = reader.readUint16();
      maxZones = reader.readUint16();
      maxTwilightPoints = reader.readUint16();
      maxStorage = reader.readUint16();
      maxFunctionDefs = reader.readUint16();
      maxInstructionDefs = reader.readUint16();
      maxStackElements = reader.readUint16();
      maxSizeOfInstructions = reader.readUint16();
      maxComponentElements = reader.readUint16();
      maxComponentDepth = reader.readUint16();
    }
    return MaxpTable(
      numGlyphs: numGlyphs,
      maxPoints: maxPoints,
      maxContours: maxContours,
      maxCompositePoints: maxCompositePoints,
      maxCompositeContours: maxCompositeContours,
      maxZones: maxZones,
      maxTwilightPoints: maxTwilightPoints,
      maxStorage: maxStorage,
      maxFunctionDefs: maxFunctionDefs,
      maxInstructionDefs: maxInstructionDefs,
      maxStackElements: maxStackElements,
      maxSizeOfInstructions: maxSizeOfInstructions,
      maxComponentElements: maxComponentElements,
      maxComponentDepth: maxComponentDepth,
    );
  }
}

/// `hhea` - horizontal line metrics.
final class HheaTable {
  const HheaTable({
    required this.ascender,
    required this.descender,
    required this.lineGap,
    required this.numberOfHMetrics,
  });

  /// Distance from the baseline to the top of the line, in font units.
  final int ascender;

  /// Distance to the bottom, in font units. **Negative** in a well-formed
  /// font, because it points down from the baseline while y is up.
  final int descender;

  final int lineGap;

  /// How many full metric pairs `hmtx` holds before its compressed tail.
  final int numberOfHMetrics;

  static HheaTable parse(SfntFile file) {
    final FontReader reader = file.readerFor('hhea');
    reader.skip(4); // version
    final int ascender = reader.readInt16();
    final int descender = reader.readInt16();
    final int lineGap = reader.readInt16();
    reader.skip(24); // advanceWidthMax .. metricDataFormat
    final int numberOfHMetrics = reader.readUint16();
    if (numberOfHMetrics == 0) {
      throw const FontFormatException(
        'numberOfHMetrics is zero, so no glyph has an advance width',
        table: 'hhea',
      );
    }
    return HheaTable(
      ascender: ascender,
      descender: descender,
      lineGap: lineGap,
      numberOfHMetrics: numberOfHMetrics,
    );
  }
}

/// `hmtx` - per-glyph advance width and left side bearing.
///
/// The table is compressed in a way worth stating plainly, because it is the
/// most commonly mis-parsed table in the format: it holds `numberOfHMetrics`
/// full `(advance, lsb)` pairs, and then **bare left side bearings** for every
/// remaining glyph. A glyph past the pairs uses the *last* advance. A monospace
/// font routinely ships `numberOfHMetrics == 1`, so getting this wrong makes
/// every glyph but the first collapse to zero width.
final class HmtxTable {
  HmtxTable._(this._advances, this._leftSideBearings, this._numGlyphs);

  final Uint16List _advances;
  final Int16List _leftSideBearings;
  final int _numGlyphs;

  /// Advance width of [glyphId], in font units.
  int advanceOf(int glyphId) {
    if (glyphId < 0 || glyphId >= _numGlyphs) return 0;
    if (glyphId < _advances.length) return _advances[glyphId];
    return _advances[_advances.length - 1];
  }

  /// Left side bearing of [glyphId], in font units.
  int leftSideBearingOf(int glyphId) {
    if (glyphId < 0 || glyphId >= _leftSideBearings.length) return 0;
    return _leftSideBearings[glyphId];
  }

  static HmtxTable parse(SfntFile file, HheaTable hhea, MaxpTable maxp) {
    final TableRecord record = file.requireTable('hmtx');
    final FontReader reader = file.readerFor('hmtx');
    final int numGlyphs = maxp.numGlyphs;

    // Clamped against the table's real size rather than trusted: a font whose
    // hhea and hmtx disagree is common enough that FreeType repairs it, and
    // reading past the table would read whatever follows it.
    final int maxPairs = record.length ~/ 4;
    final int pairs = hhea.numberOfHMetrics.clamp(0, maxPairs);
    if (pairs == 0) {
      throw const FontFormatException(
        'no complete metric pairs fit in the table',
        table: 'hmtx',
      );
    }

    final Uint16List advances = Uint16List(pairs);
    final Int16List bearings = Int16List(numGlyphs);
    for (int i = 0; i < pairs; i++) {
      advances[i] = reader.readUint16();
      bearings[i] = reader.readInt16();
    }
    // The tail: one int16 per remaining glyph, and it may simply be absent in
    // a subsetted font, which is not an error.
    final int tail = ((record.offset + record.length) - reader.offset) ~/ 2;
    final int tailCount = tail.clamp(0, numGlyphs - pairs);
    for (int i = 0; i < tailCount; i++) {
      bearings[pairs + i] = reader.readInt16();
    }

    return HmtxTable._(advances, bearings, numGlyphs);
  }
}

/// `loca` - where each glyph's outline starts in `glyf`.
///
/// `numGlyphs + 1` offsets, so that glyph *i* occupies
/// `[offsets[i], offsets[i + 1])`. Equal neighbours mean a glyph with no
/// outline - a space - which is legal and still has an advance width.
final class LocaTable {
  LocaTable._(this._offsets);

  final Uint32List _offsets;

  int get glyphCount => _offsets.length - 1;

  int offsetOf(int glyphId) => _offsets[glyphId];

  /// Byte length of glyph [glyphId]'s outline; zero for an empty glyph.
  int lengthOf(int glyphId) {
    if (glyphId < 0 || glyphId >= glyphCount) return 0;
    final int start = _offsets[glyphId];
    final int end = _offsets[glyphId + 1];
    // A non-monotonic loca is corrupt; treating it as empty keeps the rest of
    // the font usable rather than failing the whole face for one bad glyph.
    return end <= start ? 0 : end - start;
  }

  static LocaTable parse(SfntFile file, HeadTable head, MaxpTable maxp) {
    final TableRecord record = file.requireTable('loca');
    final FontReader reader = file.readerFor('loca');
    final bool isLong = head.indexToLocFormat == 1;
    final int entrySize = isLong ? 4 : 2;

    // The table's own size decides how many entries there really are; maxp is
    // only a claim. Clamping means a font whose maxp overcounts loses its last
    // glyphs instead of throwing.
    final int available = record.length ~/ entrySize;
    final int count = (maxp.numGlyphs + 1).clamp(0, available);
    if (count < 2) {
      throw const FontFormatException(
        'fewer than two offsets, so no glyph has an outline range',
        table: 'loca',
      );
    }

    final Uint32List offsets = Uint32List(count);
    for (int i = 0; i < count; i++) {
      // The short format stores offsets divided by two, which is how a 16-bit
      // field addresses a 128 KB table. Forgetting the doubling produces
      // glyphs that decode as garbage rather than failing outright.
      offsets[i] = isLong ? reader.readUint32() : reader.readUint16() * 2;
    }
    return LocaTable._(offsets);
  }
}

/// `cvt ` - Control Value Table.
/// An array of FWORD (int16) values used by the bytecode interpreter.
final class CvtTable {
  const CvtTable._(this.values);

  final Int16List values;

  static CvtTable? parse(SfntFile file) {
    if (!file.hasTable('cvt ')) return null;
    final TableRecord record = file.requireTable('cvt ');
    final FontReader reader = file.readerFor('cvt ');
    final int count = record.length ~/ 2;
    final Int16List values = Int16List(count);
    for (int i = 0; i < count; i++) {
      values[i] = reader.readInt16();
    }
    return CvtTable._(values);
  }
}

/// `fpgm` - Font Program.
/// A set of instructions executed once, before any glyph is processed.
final class FpgmTable {
  const FpgmTable._(this.instructions);

  final Uint8List instructions;

  static FpgmTable? parse(SfntFile file) {
    if (!file.hasTable('fpgm')) return null;
    final TableRecord record = file.requireTable('fpgm');
    final FontReader reader = file.readerFor('fpgm');
    final Uint8List instructions = Uint8List(record.length);
    for (int i = 0; i < record.length; i++) {
      instructions[i] = reader.readUint8();
    }
    return FpgmTable._(instructions);
  }
}

/// `prep` - Control Value Program.
/// Instructions executed once per size (or CVT scale).
final class PrepTable {
  const PrepTable._(this.instructions);

  final Uint8List instructions;

  static PrepTable? parse(SfntFile file) {
    if (!file.hasTable('prep')) return null;
    final TableRecord record = file.requireTable('prep');
    final FontReader reader = file.readerFor('prep');
    final Uint8List instructions = Uint8List(record.length);
    for (int i = 0; i < record.length; i++) {
      instructions[i] = reader.readUint8();
    }
    return PrepTable._(instructions);
  }
}
