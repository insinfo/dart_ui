/// The tables needed to measure, draw and **choose** TrueType text.
///
/// The first group is what it takes to put a glyph on screen: `head`, `maxp`,
/// `hhea`, `hmtx`, `cmap` and `loca`, plus the three hinting tables `cvt `,
/// `fpgm` and `prep`.
///
/// The second group is what it takes to pick *which* face to use, and it is not
/// optional metadata as it might look: without it a font manager matches faces
/// by file name rather than by family, has no weight/style/stretch axis to sort
/// on, and has no cheap way to ask "does this face have Arabic?" before parsing
/// its whole `cmap`. That group is:
///
///   * [NameTable] - `name`, the human-readable strings. Family, subfamily,
///     PostScript name; the identity a font is selected by;
///   * [Os2Table] - `OS/2`, the Windows/OS-2 metrics. Weight class, width
///     class, style bits, the typographic vertical metrics, and the 128-bit
///     Unicode coverage summary used as the first-pass fallback filter;
///   * [PostTable] - `post`, PostScript-oriented data. Fixed pitch, italic
///     angle, underline placement, and - for version 2.0 - glyph names.
///
/// Each table is parsed eagerly into small fixed structures, because each is
/// small and every glyph lookup touches them. `glyf` is the exception and it
/// lives in `glyf.dart`: it is the bulk of the file and is decoded one glyph at
/// a time, on demand.
///
/// All three of the new tables are **optional** in the sense that a font may
/// legally lack them, so each `parse` returns null rather than throwing when
/// the table is absent. What they never do is return a plausible-looking
/// default for a table that *is* present but malformed: that is the section 6.6
/// rule, and it is why reading a version-2 field out of a version-0 `OS/2` is a
/// named exception rather than whatever bytes follow the table.
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

/// The name identifiers a font may carry in its `name` table.
///
/// Only the ones with a caller are named. The numbering is the specification's
/// and is stable forever, so a bare integer would work; the constants exist
/// because `nameId == 16` reads as noise at every call site and
/// `NameId.typographicFamily` does not.
abstract final class NameId {
  static const int copyright = 0;

  /// The family a font manager groups faces under - but only when 16 is
  /// absent. See [NameTable.family] for why the two differ.
  static const int family = 1;

  /// Regular / Bold / Italic / Bold Italic, and nothing else, when 17 is
  /// absent.
  static const int subfamily = 2;

  /// A string meant to be unique across all fonts. Used to de-duplicate the
  /// same face found in two directories.
  static const int uniqueId = 3;

  /// The full human name, typically "family subfamily".
  static const int fullName = 4;

  static const int version = 5;

  /// The name a PDF or PostScript stream refers to the face by. ASCII, no
  /// spaces, at most 63 characters - and the only name in the table with those
  /// guarantees.
  static const int postScriptName = 6;

  static const int trademark = 7;
  static const int manufacturer = 8;
  static const int designer = 9;
  static const int description = 10;
  static const int vendorUrl = 11;
  static const int designerUrl = 12;
  static const int licenseDescription = 13;
  static const int licenseUrl = 14;

  /// The *real* family, for families that do not fit the four-style model.
  static const int typographicFamily = 16;

  /// The *real* subfamily: "Semibold Condensed Italic" and the like.
  static const int typographicSubfamily = 17;

  /// A Macintosh-only full name, present when name 4 had to be truncated.
  static const int compatibleFull = 18;

  static const int sampleText = 19;
  static const int postScriptCidFindfontName = 20;

  /// Family under the "weight/width/slope" model: the family with every
  /// variation axis factored out.
  static const int wwsFamily = 21;

  static const int wwsSubfamily = 22;
  static const int lightBackgroundPalette = 23;
  static const int darkBackgroundPalette = 24;
  static const int variationsPostScriptNamePrefix = 25;
}

/// One record in the `name` table: a string, and who it is for.
///
/// The same logical name appears several times in a real font - once per
/// platform, and once per language - which is why a record carries its full
/// address rather than just its text. [NameTable] does the choosing.
final class NameRecord {
  const NameRecord({
    required this.platformId,
    required this.encodingId,
    required this.languageId,
    required this.nameId,
    required this.text,
    this.languageTag,
  });

  /// 0 = Unicode, 1 = Macintosh, 3 = Windows. (2 = ISO is deprecated and 4 =
  /// custom is for OpenType-CFF-in-a-container.)
  final int platformId;

  final int encodingId;

  /// Platform-specific. For Windows it is an LCID - 0x0409 is en-US. For
  /// Macintosh it is a small index - 0 is English. Values at or above 0x8000
  /// are indices into the format 1 language-tag array, and for those
  /// [languageTag] holds the resolved BCP 47 tag.
  final int languageId;

  final int nameId;

  /// The decoded string, or null when the record's encoding is one this parser
  /// does not decode.
  ///
  /// Null is not an error and not silence: the record is still listed, with its
  /// platform and encoding intact, so a caller can see *that* a name exists in
  /// - say - Mac Japanese and that we chose not to guess at Shift-JIS. What is
  /// never done is handing back mojibake as if it were a name. See
  /// [NameTable.parse] for the exact set that is decoded.
  final String? text;

  /// The BCP 47 tag for a format 1 record, when [languageId] >= 0x8000.
  final String? languageTag;

  /// Whether this record is a language-tag record from a format 1 table.
  bool get usesLanguageTag => languageId >= 0x8000;

  /// Whether this record is the Windows en-US one, the preferred spelling of
  /// every name in practice.
  bool get isWindowsEnglish =>
      platformId == 3 && languageId == NameTable.windowsEnglishUnitedStates;

  @override
  String toString() => 'NameRecord(platform $platformId/$encodingId, '
      'language 0x${languageId.toRadixString(16)}, name $nameId, '
      '${text == null ? '<undecoded>' : '"$text"'})';
}

/// `name` - the strings a font is identified by.
///
/// ## Why this table decides font selection
///
/// A font manager that matches on file name is matching on something the
/// format does not define: `arialbd.ttf` and `Arial Bold.ttf` are the same face
/// and `NotoSansCJKjp-Regular.otf` is not the family "NotoSansCJKjp". The
/// family lives here, and so does the subfamily that separates Bold from
/// Regular within it.
///
/// ## The 16/17 versus 1/2 rule
///
/// Name 1 (family) and name 2 (subfamily) are constrained by a rule from the
/// days of the Macintosh font menu: a family may hold at most **four** styles,
/// and name 2 may only be Regular, Bold, Italic or Bold Italic. A family with
/// Light, Medium, Semibold, Black and their italics does not fit, so it ships
/// as several four-style families - "Roboto", "Roboto Light", "Roboto Medium" -
/// each with a compliant name 2.
///
/// Names 16 and 17 are the escape: 16 is the family a human means ("Roboto")
/// and 17 the real style ("Light Italic"). They are present **only when they
/// differ** from 1 and 2, which is exactly what makes the rule "16/17 when
/// present, else 1/2" correct rather than a preference: falling back to 1/2 is
/// not a degraded answer for a font that omits 16/17, it is *the* answer, and
/// ignoring 16/17 for a font that has them shatters one family into four.
///
/// [family] and [subfamily] implement that rule. [legacyFamily] and
/// [legacySubfamily] expose names 1 and 2 unconditionally, because that pair -
/// not the typographic one - is what a `.fon`-era API or a PDF `/BaseFont`
/// entry expects.
///
/// ## Limits, stated out loud
///
/// * Only table formats 0 and 1 exist, and both are implemented. A format
///   field other than 0 or 1 is refused by name rather than parsed as format 0.
/// * Strings are decoded for platform 0 (any encoding, UTF-16BE), platform 3
///   (any encoding, UTF-16BE) and platform 1 encoding 0 (MacRoman). Every
///   other platform 1 encoding - Japanese, Traditional Chinese, Korean, and the
///   rest of the Mac script codes - is left undecoded, with [NameRecord.text]
///   null. Those need full legacy codec tables that no caller has asked for,
///   and guessing Latin-1 for them produces confident garbage.
/// * Platform 2 (ISO) records are read and listed, but not decoded: the
///   platform is deprecated and its encoding ids overlap nothing we implement.
final class NameTable {
  NameTable._(this.format, this.records);

  /// 0 (no language tags) or 1 (with them).
  final int format;

  /// Every record, in file order. Records whose encoding was not decoded are
  /// present with a null [NameRecord.text].
  final List<NameRecord> records;

  /// The Windows LCID for en-US. The de-facto universal name language: a font
  /// that has any Windows name at all has this one.
  static const int windowsEnglishUnitedStates = 0x0409;

  /// The Macintosh language id for English.
  static const int macintoshEnglish = 0;

  /// The family a user means, per the 16/17 rule documented on this class.
  String? get family =>
      forNameId(NameId.typographicFamily) ?? forNameId(NameId.family);

  /// The style within [family], per the 16/17 rule.
  String? get subfamily =>
      forNameId(NameId.typographicSubfamily) ?? forNameId(NameId.subfamily);

  /// Name 1 exactly - the four-style-compatible family.
  String? get legacyFamily => forNameId(NameId.family);

  /// Name 2 exactly - Regular, Bold, Italic or Bold Italic.
  String? get legacySubfamily => forNameId(NameId.subfamily);

  String? get uniqueId => forNameId(NameId.uniqueId);

  String? get fullName => forNameId(NameId.fullName);

  String? get postScriptName => forNameId(NameId.postScriptName);

  /// Name 16, or null when the font does not carry one.
  ///
  /// Deliberately *not* falling back to name 1: a caller asking for this
  /// specifically wants to know whether the font distinguishes them.
  String? get typographicFamily => forNameId(NameId.typographicFamily);

  /// Name 17, or null. Same reasoning as [typographicFamily].
  String? get typographicSubfamily => forNameId(NameId.typographicSubfamily);

  /// The best record for [nameId], or null when the font has none it can
  /// decode.
  ///
  /// "Best" is defined by [_score], and the order is: Windows en-US, then any
  /// Windows record, then any Unicode-platform record, then Macintosh English,
  /// then anything decodable. The first two are the ones that fire on real
  /// fonts; the rest exist so that a Mac-only font still yields a family name
  /// instead of null.
  ///
  /// Ties are broken by file order, so the result is deterministic for a given
  /// font rather than dependent on map iteration.
  String? forNameId(int nameId) {
    int bestScore = -1;
    String? best;
    // Linear over ~20-40 records. Called during font enumeration, not during
    // layout, so a scan beats building and retaining an index per face.
    for (int i = 0; i < records.length; i++) {
      final NameRecord record = records[i];
      if (record.nameId != nameId) continue;
      final String? text = record.text;
      if (text == null || text.isEmpty) continue;
      final int score = _score(record);
      if (score > bestScore) {
        bestScore = score;
        best = text;
      }
    }
    return best;
  }

  /// The best record for [nameId] in a specific language, or null.
  ///
  /// [languageId] is platform-specific, so this is only meaningful together
  /// with [platformId]. Provided for a font picker that wants to show a
  /// Japanese font's Japanese name; the plain [forNameId] deliberately does not
  /// try to guess a UI locale, because this layer does not know one.
  String? forNameIdInLanguage(int nameId, int platformId, int languageId) {
    for (int i = 0; i < records.length; i++) {
      final NameRecord record = records[i];
      if (record.nameId != nameId ||
          record.platformId != platformId ||
          record.languageId != languageId) {
        continue;
      }
      final String? text = record.text;
      if (text != null && text.isNotEmpty) return text;
    }
    return null;
  }

  /// Every distinct BCP 47 language tag declared by a format 1 table.
  ///
  /// Empty for format 0, which has no way to express one.
  Iterable<String> get languageTags {
    final Set<String> tags = <String>{};
    for (final NameRecord record in records) {
      final String? tag = record.languageTag;
      if (tag != null) tags.add(tag);
    }
    return tags;
  }

  static int _score(NameRecord record) {
    if (record.platformId == 3) {
      if (record.languageId == windowsEnglishUnitedStates) return 5;
      // Any other English variant - 0x0809 en-GB, 0x0C09 en-AU and friends.
      // The low ten bits are the primary language, and 0x09 is English.
      if ((record.languageId & 0x3FF) == 0x09) return 4;
      return 3;
    }
    // Platform 0 has no language field at all (the id is an encoding hint),
    // so its strings are language-neutral and safe to take.
    if (record.platformId == 0) return 2;
    if (record.platformId == 1 && record.languageId == macintoshEnglish) {
      return 1;
    }
    return 0;
  }

  /// Parses `name`, or returns null when the font has no such table.
  static NameTable? parse(SfntFile file) {
    if (!file.hasTable('name')) return null;
    final TableRecord record = file.requireTable('name');
    final FontReader reader = file.readerFor('name');

    final int format = reader.readUint16();
    if (format != 0 && format != 1) {
      throw FontFormatException(
        'format $format is neither 0 nor 1; refusing to guess at a layout '
        'this parser does not know',
        table: 'name',
        offset: record.offset,
      );
    }
    final int count = reader.readUint16();
    final int storageOffset = reader.readUint16();

    // 6 bytes of header plus 12 per record must fit, or the records we are
    // about to read are somebody else's bytes.
    final int recordsEnd = 6 + count * 12;
    if (recordsEnd > record.length) {
      throw FontFormatException(
        '$count records need $recordsEnd bytes but the table is only '
        '${record.length}',
        table: 'name',
        offset: record.offset,
      );
    }

    final int storageBase = record.offset + storageOffset;
    final int tableEnd = record.offset + record.length;

    // Format 1 appends a language-tag array after the name records, and every
    // languageId >= 0x8000 indexes into it. Parsed first, because the name
    // records refer to it.
    List<String>? languageTags;
    if (format == 1) {
      final FontReader tagReader = file.data.readerAt(
        record.offset + recordsEnd,
        table: 'name',
      );
      final int tagCount = tagReader.readUint16();
      if (recordsEnd + 2 + tagCount * 4 > record.length) {
        throw FontFormatException(
          'format 1 declares $tagCount language tags, which do not fit in the '
          '${record.length}-byte table',
          table: 'name',
          offset: record.offset,
        );
      }
      languageTags = List<String>.filled(tagCount, '');
      for (int i = 0; i < tagCount; i++) {
        final int length = tagReader.readUint16();
        final int offset = tagReader.readUint16();
        final int at = storageBase + offset;
        if (!file.data.contains(at, length) || at + length > tableEnd) {
          throw FontFormatException(
            'language tag $i points outside the table',
            table: 'name',
            offset: at,
          );
        }
        // Language tags are UTF-16BE like every other Unicode-platform string
        // in this table, even though every real one is ASCII.
        languageTags[i] = _decodeUtf16Be(
          file.data.readerAt(at, table: 'name').readBytes(length),
        );
      }
    }

    final List<NameRecord> parsed = <NameRecord>[];
    for (int i = 0; i < count; i++) {
      final int platformId = reader.readUint16();
      final int encodingId = reader.readUint16();
      final int languageId = reader.readUint16();
      final int nameId = reader.readUint16();
      final int length = reader.readUint16();
      final int offset = reader.readUint16();

      final int at = storageBase + offset;
      // A record pointing outside its own table is corruption, but it is also
      // common in subsetted fonts, and losing one string is not worth losing
      // the face. Skipped, not thrown - and skipped visibly, since the record
      // simply does not appear.
      if (!file.data.contains(at, length) || at + length > tableEnd) continue;

      final Uint8List bytes =
          file.data.readerAt(at, table: 'name').readBytes(length);

      String? languageTag;
      if (languageId >= 0x8000 && languageTags != null) {
        final int index = languageId - 0x8000;
        if (index < languageTags.length) languageTag = languageTags[index];
      }

      parsed.add(
        NameRecord(
          platformId: platformId,
          encodingId: encodingId,
          languageId: languageId,
          nameId: nameId,
          text: _decode(platformId, encodingId, bytes),
          languageTag: languageTag,
        ),
      );
    }

    return NameTable._(format, parsed);
  }

  /// Decodes one record's bytes, or returns null for an encoding we refuse to
  /// guess at.
  static String? _decode(int platformId, int encodingId, Uint8List bytes) {
    switch (platformId) {
      case 0: // Unicode platform: always UTF-16BE, whatever the encoding id.
        return _decodeUtf16Be(bytes);
      case 3: // Windows: also always UTF-16BE, including encoding 0 (symbol)
        // and encoding 10 (UCS-4, which is still stored as surrogate pairs
        // here because the length field is in bytes and the strings are
        // UTF-16).
        return _decodeUtf16Be(bytes);
      case 1:
        if (encodingId == 0) return _decodeMacRoman(bytes);
        return null; // Mac script codes other than Roman - see class doc.
      default:
        return null;
    }
  }

  /// UTF-16BE, with surrogate pairs left as-is.
  ///
  /// Dart strings *are* UTF-16, so the code units go straight through and a
  /// name outside the BMP - which happens, in fonts whose designer signed their
  /// name in emoji - survives without a separate surrogate-pair pass.
  ///
  /// An odd byte count means the record's length field disagrees with its
  /// encoding. The trailing half-unit is dropped rather than thrown on: real
  /// fonts pad name records, and the name up to that point is still correct.
  static String _decodeUtf16Be(Uint8List bytes) {
    final int units = bytes.length >> 1;
    final Uint16List codeUnits = Uint16List(units);
    for (int i = 0; i < units; i++) {
      codeUnits[i] = (bytes[i * 2] << 8) | bytes[i * 2 + 1];
    }
    return String.fromCharCodes(codeUnits);
  }

  /// MacRoman, the Mac OS Roman single-byte encoding.
  ///
  /// The bottom half is ASCII. The top half is **not** Latin-1, and treating it
  /// as such is the bug this table exists to prevent: byte 0xA5 is a bullet in
  /// MacRoman and a yen sign in Latin-1, 0xD5 is a right single quote and not a
  /// capital O with tilde. Real fonts put curly quotes, the trademark sign and
  /// accented Latin letters in their Mac names, so the difference is visible in
  /// the font menu of any application that gets it wrong.
  ///
  /// The mapping is Apple's ROMAN.TXT in its current revision, which is why
  /// 0xDB is the euro sign rather than the generic currency sign it was before
  /// 1998, and why 0xF0 is the Apple logo at U+F8FF in the private use area.
  static String _decodeMacRoman(Uint8List bytes) {
    final List<int> codePoints = List<int>.filled(bytes.length, 0);
    for (int i = 0; i < bytes.length; i++) {
      final int byte = bytes[i];
      codePoints[i] = byte < 0x80 ? byte : _macRomanHigh[byte - 0x80];
    }
    return String.fromCharCodes(codePoints);
  }

  /// The 128 code points MacRoman assigns to bytes 0x80..0xFF.
  static const List<int> _macRomanHigh = <int>[
    0x00C4, 0x00C5, 0x00C7, 0x00C9, 0x00D1, 0x00D6, 0x00DC, 0x00E1, // 80..87
    0x00E0, 0x00E2, 0x00E4, 0x00E3, 0x00E5, 0x00E7, 0x00E9, 0x00E8, // 88..8F
    0x00EA, 0x00EB, 0x00ED, 0x00EC, 0x00EE, 0x00EF, 0x00F1, 0x00F3, // 90..97
    0x00F2, 0x00F4, 0x00F6, 0x00F5, 0x00FA, 0x00F9, 0x00FB, 0x00FC, // 98..9F
    0x2020, 0x00B0, 0x00A2, 0x00A3, 0x00A7, 0x2022, 0x00B6, 0x00DF, // A0..A7
    0x00AE, 0x00A9, 0x2122, 0x00B4, 0x00A8, 0x2260, 0x00C6, 0x00D8, // A8..AF
    0x221E, 0x00B1, 0x2264, 0x2265, 0x00A5, 0x00B5, 0x2202, 0x2211, // B0..B7
    0x220F, 0x03C0, 0x222B, 0x00AA, 0x00BA, 0x03A9, 0x00E6, 0x00F8, // B8..BF
    0x00BF, 0x00A1, 0x00AC, 0x221A, 0x0192, 0x2248, 0x2206, 0x00AB, // C0..C7
    0x00BB, 0x2026, 0x00A0, 0x00C0, 0x00C3, 0x00D5, 0x0152, 0x0153, // C8..CF
    0x2013, 0x2014, 0x201C, 0x201D, 0x2018, 0x2019, 0x00F7, 0x25CA, // D0..D7
    0x00FF, 0x0178, 0x2044, 0x20AC, 0x2039, 0x203A, 0xFB01, 0xFB02, // D8..DF
    0x2021, 0x00B7, 0x201A, 0x201E, 0x2030, 0x00C2, 0x00CA, 0x00C1, // E0..E7
    0x00CB, 0x00C8, 0x00CD, 0x00CE, 0x00CF, 0x00CC, 0x00D3, 0x00D4, // E8..EF
    0xF8FF, 0x00D2, 0x00DA, 0x00DB, 0x00D9, 0x0131, 0x02C6, 0x02DC, // F0..F7
    0x00AF, 0x02D8, 0x02D9, 0x02DA, 0x00B8, 0x02DD, 0x02DB, 0x02C7, // F8..FF
  ];
}

/// One bit of `OS/2`'s `ulUnicodeRange`, and the code points it stands for.
///
/// The mapping is fixed by the OpenType specification and never changes, which
/// is what makes a 128-bit field a usable coverage summary at all: bit 13 has
/// meant Arabic since 1996 and will keep meaning Arabic.
final class UnicodeRange {
  const UnicodeRange(this.bit, this.name, this.spans);

  /// 0..122. Bits 123..127 are reserved and have no range.
  final int bit;

  /// The specification's own name for the bit, for diagnostics.
  final String name;

  /// The code point spans, inclusive on both ends.
  ///
  /// Several bits cover more than one block - bit 9 is Cyrillic *and* its three
  /// supplements - because the bit budget ran out long before Unicode stopped
  /// growing.
  final List<({int first, int last})> spans;

  /// Whether [codePoint] falls in one of [spans].
  bool contains(int codePoint) {
    for (int i = 0; i < spans.length; i++) {
      final ({int first, int last}) span = spans[i];
      if (codePoint >= span.first && codePoint <= span.last) return true;
    }
    return false;
  }

  @override
  String toString() => 'UnicodeRange($bit, $name)';
}

/// How the resolved vertical metrics were chosen. See [VerticalMetrics].
enum VerticalMetricsSource {
  /// `OS/2`'s `sTypoAscender`/`sTypoDescender`/`sTypoLineGap`, because the font
  /// set `USE_TYPO_METRICS`.
  typographic,

  /// `hhea`'s ascender/descender/lineGap - the default.
  horizontalHeader,

  /// `OS/2`'s `usWinAscent`/`usWinDescent`, because `hhea` was empty.
  windows,
}

/// The line box a font asks for, and where the numbers came from.
///
/// ## The problem this type exists to settle
///
/// An OpenType font states its vertical metrics **three times**, and the three
/// disagree in most real fonts:
///
///   * `hhea.ascender` / `descender` / `lineGap` - the original TrueType pair,
///     what the Macintosh used;
///   * `OS/2.sTypoAscender` / `sTypoDescender` / `sTypoLineGap` - the
///     *typographic* metrics, meant to be the designer's intended line box;
///   * `OS/2.usWinAscent` / `usWinDescent` - the *clipping* box, which Windows
///     used to decide how tall a bitmap to allocate, and which therefore has to
///     cover the tallest accented capital and the deepest descender even when
///     no line of text ever needs that much room.
///
/// For DejaVu Sans the win pair is a few percent taller than hhea; for fonts
/// with large diacritics, notably several Google-hosted families, `usWinAscent`
/// can be 40% larger than `sTypoAscender`. Picking differently changes the
/// height of every paragraph in the application, so this is a decision that has
/// to be made once, in the open, rather than per call site.
///
/// ## The rule, and why this one
///
/// 1. If `OS/2` sets `fsSelection` bit 7, `USE_TYPO_METRICS`, use the typo
///    metrics. That bit exists for exactly one purpose: it is the font
///    designer stating "my typo metrics are the correct line box, use them".
///    Honouring it is not a heuristic, it is doing what the font asked.
/// 2. Otherwise use `hhea`. This is what the majority of shipping text stacks
///    do for fonts without the bit, and matching them matters more here than
///    any argument about which triple is prettier: a paragraph that reflows
///    differently from every other application is a bug report even when the
///    line height is defensible.
/// 3. Only if `hhea` is empty - both ascender and descender zero, which happens
///    in a handful of broken and subsetted fonts - fall back to `usWinAscent` /
///    `usWinDescent`, with a zero line gap, because the win pair is the one
///    field that is never legitimately zero in a font with visible glyphs.
///
/// The chosen source is reported in [source] rather than hidden, so a font
/// inspector can show why a face lays out taller than expected.
///
/// This type deliberately holds font units, not pixels. Scaling belongs to
/// whatever wraps a face at a size.
final class VerticalMetrics {
  const VerticalMetrics({
    required this.ascent,
    required this.descent,
    required this.lineGap,
    required this.source,
  });

  /// Baseline to top, in font units. Positive.
  final int ascent;

  /// Baseline to bottom, in font units. **Negative**, matching `hhea` and
  /// `sTypoDescender`, so that `ascent - descent` is the em box height and no
  /// caller has to remember which of the three fields was already negated.
  final int descent;

  /// Extra leading between lines, in font units.
  final int lineGap;

  final VerticalMetricsSource source;

  /// `ascent - descent + lineGap`: the distance between two baselines.
  int get lineHeight => ascent - descent + lineGap;

  /// Applies the rule documented on this class.
  ///
  /// [os2] may be null - a font without `OS/2` simply lands in step 2 - but a
  /// font with neither usable `hhea` metrics nor an `OS/2` table has no line
  /// box at all, and that is a [FontFormatException] rather than a silent zero
  /// that would collapse every paragraph to a single line.
  static VerticalMetrics resolve({required HheaTable hhea, Os2Table? os2}) {
    if (os2 != null && os2.useTypographicMetrics) {
      return VerticalMetrics(
        ascent: os2.typoAscender,
        descent: os2.typoDescender,
        lineGap: os2.typoLineGap,
        source: VerticalMetricsSource.typographic,
      );
    }
    if (hhea.ascender != 0 || hhea.descender != 0) {
      return VerticalMetrics(
        ascent: hhea.ascender,
        descent: hhea.descender,
        lineGap: hhea.lineGap,
        source: VerticalMetricsSource.horizontalHeader,
      );
    }
    if (os2 != null && (os2.winAscent != 0 || os2.winDescent != 0)) {
      return VerticalMetrics(
        // usWinDescent is stored as a positive magnitude, unlike every other
        // descender in the format. Negated here so that callers never have to
        // know which of the three sources the number came from.
        ascent: os2.winAscent,
        descent: -os2.winDescent,
        lineGap: 0,
        source: VerticalMetricsSource.windows,
      );
    }
    throw const FontFormatException(
      'the face states no vertical metrics: hhea is empty and there is no '
      'usable OS/2 usWinAscent/usWinDescent to fall back to',
      table: 'hhea',
    );
  }

  @override
  String toString() => 'VerticalMetrics($ascent, $descent, $lineGap, '
      '${source.name})';
}

/// `OS/2` - weight, width, style bits, metrics and coverage.
///
/// Named after the operating system it was invented for and long outliving it.
/// Everything a font *picker* needs lives here: [weightClass] and [widthClass]
/// are the axes a family sorts on, [isItalic] and friends are what "the bold
/// one" resolves to, and [ulUnicodeRange1]..[ulUnicodeRange4] are the cheap
/// first pass of font fallback.
///
/// ## Versions
///
/// The table grew five times and its **length is the only way to know what is
/// really there**, since a font may declare version 4 and ship 78 bytes. So the
/// length is checked against the declared version before anything is read, and
/// a table too short for what it claims is refused by name. The alternative -
/// reading whatever follows the table and calling it `sxHeight` - is exactly
/// the silent-garbage failure section 6.6 forbids.
///
///   * v0: 78 bytes, through `usWinDescent`;
///   * v1: 86, adds the code page ranges;
///   * v2, v3, v4: 96, add `sxHeight`, `sCapHeight`, `usDefaultChar`,
///     `usBreakChar`, `usMaxContext` (the three versions differ only in the
///     documented meaning of `fsSelection` and `fsType`, not in the layout);
///   * v5: 100, adds the optical size range.
///
/// Fields that only exist from v2 are exposed twice: [sxHeight] throws when the
/// table is older, [sxHeightOrNull] returns null. A caller that has a fallback
/// uses the second; a caller that would otherwise silently mis-render uses the
/// first.
///
/// The 68-byte Apple variant of version 0 - which stops after `usLastCharIndex`
/// and has no typographic or win metrics at all - is **refused**, by name. It
/// appears only in pre-2000 Macintosh fonts, and half a table is worse than
/// none because every consumer of this type reasonably expects the vertical
/// metrics to be there.
final class Os2Table {
  const Os2Table._({
    required this.version,
    required this.xAvgCharWidth,
    required this.weightClass,
    required this.widthClass,
    required this.fsType,
    required this.subscriptXSize,
    required this.subscriptYSize,
    required this.subscriptXOffset,
    required this.subscriptYOffset,
    required this.superscriptXSize,
    required this.superscriptYSize,
    required this.superscriptXOffset,
    required this.superscriptYOffset,
    required this.strikeoutSize,
    required this.strikeoutPosition,
    required this.familyClass,
    required this.panose,
    required this.ulUnicodeRange1,
    required this.ulUnicodeRange2,
    required this.ulUnicodeRange3,
    required this.ulUnicodeRange4,
    required this.vendorId,
    required this.fsSelection,
    required this.firstCharIndex,
    required this.lastCharIndex,
    required this.typoAscender,
    required this.typoDescender,
    required this.typoLineGap,
    required this.winAscent,
    required this.winDescent,
    required int codePageRange1,
    required int codePageRange2,
    required int sxHeight,
    required int sCapHeight,
    required int defaultChar,
    required int breakChar,
    required int maxContext,
    required int lowerOpticalPointSize,
    required int upperOpticalPointSize,
  })  : _codePageRange1 = codePageRange1,
        _codePageRange2 = codePageRange2,
        _sxHeight = sxHeight,
        _sCapHeight = sCapHeight,
        _defaultChar = defaultChar,
        _breakChar = breakChar,
        _maxContext = maxContext,
        _lowerOpticalPointSize = lowerOpticalPointSize,
        _upperOpticalPointSize = upperOpticalPointSize;

  /// 0..5, as declared by the font. Values above 5 are read as 5.
  final int version;

  final int xAvgCharWidth;

  /// 1..1000, where 400 is Regular and 700 is Bold.
  ///
  /// A continuum, not an enumeration: variable fonts interpolate across it, and
  /// a family may ship 350 and 450 as distinct faces. Font matching should sort
  /// on the number, never switch on named buckets.
  final int weightClass;

  /// 1..9: 1 is Ultra-condensed, 5 Normal, 9 Ultra-expanded.
  final int widthClass;

  /// Embedding permissions. See [isInstallableEmbedding] and friends.
  final int fsType;

  final int subscriptXSize;
  final int subscriptYSize;
  final int subscriptXOffset;
  final int subscriptYOffset;
  final int superscriptXSize;
  final int superscriptYSize;
  final int superscriptXOffset;
  final int superscriptYOffset;
  final int strikeoutSize;
  final int strikeoutPosition;

  /// IBM font class and subclass, packed as `class << 8 | subclass`.
  final int familyClass;

  /// The ten PANOSE digits. A 1970s classification scheme, kept because some
  /// font matchers still use its serif/sans digit as a last-resort tiebreak.
  final Uint8List panose;

  /// Coverage bits 0..31.
  final int ulUnicodeRange1;

  /// Coverage bits 32..63.
  final int ulUnicodeRange2;

  /// Coverage bits 64..95.
  final int ulUnicodeRange3;

  /// Coverage bits 96..127.
  final int ulUnicodeRange4;

  /// The four-character foundry tag, `achVendID`. Space-padded in the file;
  /// trailing spaces are trimmed here.
  final String vendorId;

  /// The style bits. See [isItalic], [isBold], [isRegular],
  /// [useTypographicMetrics], [isWws], [isOblique].
  final int fsSelection;

  final int firstCharIndex;
  final int lastCharIndex;

  /// The designer's intended ascent. Only authoritative when
  /// [useTypographicMetrics] is set - see [VerticalMetrics].
  final int typoAscender;

  /// Negative in a well-formed font.
  final int typoDescender;

  final int typoLineGap;

  /// The Windows clipping ascent. A **positive** magnitude.
  final int winAscent;

  /// The Windows clipping descent, also a positive magnitude - the one
  /// descender in the format that is not negative.
  final int winDescent;

  final int _codePageRange1;
  final int _codePageRange2;
  final int _sxHeight;
  final int _sCapHeight;
  final int _defaultChar;
  final int _breakChar;
  final int _maxContext;
  final int _lowerOpticalPointSize;
  final int _upperOpticalPointSize;

  // --- fsSelection ---------------------------------------------------------

  static const int fsSelectionItalic = 1 << 0;
  static const int fsSelectionUnderscore = 1 << 1;
  static const int fsSelectionNegative = 1 << 2;
  static const int fsSelectionOutlined = 1 << 3;
  static const int fsSelectionStrikeout = 1 << 4;
  static const int fsSelectionBold = 1 << 5;
  static const int fsSelectionRegular = 1 << 6;
  static const int fsSelectionUseTypoMetrics = 1 << 7;
  static const int fsSelectionWws = 1 << 8;
  static const int fsSelectionOblique = 1 << 9;

  /// Whether the face slants.
  ///
  /// `head.macStyle` states this too, and the two disagree in real fonts. This
  /// one wins for font selection because it is the field a font's own metadata
  /// tooling writes; `macStyle` is what a rasteriser consults when deciding
  /// whether to synthesise a slant.
  bool get isItalic => fsSelection & fsSelectionItalic != 0;

  bool get isBold => fsSelection & fsSelectionBold != 0;

  /// The font asserting it is the plain face. Mutually exclusive with bold and
  /// italic by specification, and worth trusting over a name string.
  bool get isRegular => fsSelection & fsSelectionRegular != 0;

  /// Bit 7: "use my `sTypo*` metrics as the line box". See [VerticalMetrics].
  bool get useTypographicMetrics =>
      fsSelection & fsSelectionUseTypoMetrics != 0;

  /// Bit 8: the family name follows the weight/width/slope model, so name 16
  /// needs no further decomposition.
  bool get isWws => fsSelection & fsSelectionWws != 0;

  /// Bit 9: slanted by shearing rather than by a separate italic design. A
  /// renderer may substitute a synthetic slant for an oblique and not for a
  /// true italic.
  bool get isOblique => fsSelection & fsSelectionOblique != 0;

  // --- fsType --------------------------------------------------------------

  /// No embedding restriction at all.
  bool get isInstallableEmbedding => fsType & 0x000F == 0;

  /// Bit 1: the font may not be embedded or exchanged.
  bool get isRestrictedLicense => fsType & 0x0002 != 0;

  /// Bit 2: embeddable read-only, for viewing and printing.
  bool get allowsPreviewAndPrintEmbedding => fsType & 0x0004 != 0;

  /// Bit 3: embeddable and the document may be edited.
  bool get allowsEditableEmbedding => fsType & 0x0008 != 0;

  /// Bit 8: the font may be embedded whole but not subsetted.
  bool get noSubsetting => fsType & 0x0100 != 0;

  /// Bit 9: only bitmaps may be embedded, never the outlines.
  bool get bitmapEmbeddingOnly => fsType & 0x0200 != 0;

  // --- version-gated fields ------------------------------------------------

  /// Whether this table is version 2 or later, and therefore carries
  /// [sxHeight], [capHeight], [defaultChar], [breakChar] and [maxContext].
  bool get hasVersion2Fields => version >= 2;

  /// The height of a lowercase `x`, in font units.
  ///
  /// Throws when the table is version 0 or 1, which do not contain the field.
  /// Callers with a fallback want [sxHeightOrNull].
  int get sxHeight => _requireVersion2(_sxHeight, 'sxHeight');

  /// [sxHeight], or null on a version 0 or 1 table.
  int? get sxHeightOrNull => version >= 2 ? _sxHeight : null;

  /// The height of a flat-topped capital, in font units. Throws below v2.
  int get capHeight => _requireVersion2(_sCapHeight, 'sCapHeight');

  int? get capHeightOrNull => version >= 2 ? _sCapHeight : null;

  /// The code point drawn for a character the font lacks. Throws below v2.
  int get defaultChar => _requireVersion2(_defaultChar, 'usDefaultChar');

  int? get defaultCharOrNull => version >= 2 ? _defaultChar : null;

  /// The code point that acts as a word break - U+0020 in every sane font.
  /// Throws below v2.
  int get breakChar => _requireVersion2(_breakChar, 'usBreakChar');

  int? get breakCharOrNull => version >= 2 ? _breakChar : null;

  /// The longest context any `GSUB`/`GPOS` lookup in the font needs. Throws
  /// below v2.
  int get maxContext => _requireVersion2(_maxContext, 'usMaxContext');

  int? get maxContextOrNull => version >= 2 ? _maxContext : null;

  /// Code pages 0..31, a v1+ field. Null on a version 0 table.
  int? get codePageRange1 => version >= 1 ? _codePageRange1 : null;

  /// Code pages 32..63, a v1+ field. Null on a version 0 table.
  int? get codePageRange2 => version >= 1 ? _codePageRange2 : null;

  /// The smallest point size this face is designed for, in twentieths of a
  /// point. A v5 field; null below that.
  int? get lowerOpticalPointSize =>
      version >= 5 ? _lowerOpticalPointSize : null;

  /// The exclusive upper bound of the optical size range, in twentieths of a
  /// point. A v5 field; null below that.
  int? get upperOpticalPointSize =>
      version >= 5 ? _upperOpticalPointSize : null;

  int _requireVersion2(int value, String field) {
    if (version >= 2) return value;
    throw FontFormatException(
      '$field does not exist in an OS/2 version $version table; the bytes '
      'where it would sit belong to whatever table follows',
      table: 'OS/2',
    );
  }

  // --- Unicode coverage ----------------------------------------------------

  /// Whether coverage bit [bit] (0..127) is set.
  ///
  /// Four masked reads and no allocation, so it is safe to call per candidate
  /// face while scanning a font directory.
  ///
  /// **This is the manufacturer's claim, not a guarantee.** Fonts set bits for
  /// blocks they only partly cover, and subsetters routinely leave the bits
  /// untouched while removing the glyphs. The bit is a *filter*: a face that
  /// does not claim Arabic almost certainly has none and can be skipped without
  /// parsing its `cmap`, while a face that does claim it still has to be asked
  /// through `cmap` before anything is drawn. Truth is the `cmap`; this is the
  /// cheap way to avoid consulting it 400 times.
  bool hasUnicodeRangeBit(int bit) {
    if (bit < 0 || bit > 127) {
      throw FontFormatException(
        'Unicode range bit $bit is outside 0..127',
        table: 'OS/2',
      );
    }
    final int word = switch (bit >> 5) {
      0 => ulUnicodeRange1,
      1 => ulUnicodeRange2,
      2 => ulUnicodeRange3,
      _ => ulUnicodeRange4,
    };
    return word & (1 << (bit & 31)) != 0;
  }

  /// Whether the font *claims* to cover [codePoint].
  ///
  /// Maps the code point to its range bit and tests it. Same caveat as
  /// [hasUnicodeRangeBit], doubled: a code point in no defined range - and
  /// there are many, since the 123 bits stopped tracking Unicode in 2008 -
  /// returns false here while being perfectly renderable. Use it to *rank*
  /// candidate faces, never to reject one outright.
  bool declaresCodePoint(int codePoint) {
    final UnicodeRange? range = rangeForCodePoint(codePoint);
    if (range == null) return false;
    return hasUnicodeRangeBit(range.bit);
  }

  /// Every range the font claims, in bit order. Allocates; for diagnostics and
  /// font-manager indexing, not for a per-glyph path.
  Iterable<UnicodeRange> get declaredRanges sync* {
    for (final UnicodeRange range in unicodeRanges) {
      if (hasUnicodeRangeBit(range.bit)) yield range;
    }
  }

  /// The range [codePoint] belongs to, or null when no bit covers it.
  ///
  /// A linear scan over 123 entries with an early bail on the common Latin
  /// case would be fine, but this is called once per candidate face per missing
  /// character during fallback, so it binary-searches a flat span index built
  /// once for the process.
  static UnicodeRange? rangeForCodePoint(int codePoint) {
    final ({Uint32List starts, Uint32List ends, Uint8List rangeIndex}) index =
        _spanIndex;
    final Uint32List starts = index.starts;
    int low = 0;
    int high = starts.length - 1;
    int found = -1;
    while (low <= high) {
      final int mid = (low + high) >> 1;
      if (starts[mid] <= codePoint) {
        found = mid;
        low = mid + 1;
      } else {
        high = mid - 1;
      }
    }
    if (found < 0) return null;
    // Spans do not overlap, so the last span starting at or before the code
    // point is the only one that can contain it.
    if (codePoint > index.ends[found]) return null;
    return unicodeRanges[index.rangeIndex[found]];
  }

  /// The specification's bit-to-block table, bits 0..122.
  ///
  /// Bits 123..127 are reserved and absent. Bit 57, "Non-Plane 0", is the odd
  /// one: it is not a block but a claim of any supplementary-plane coverage at
  /// all, so its span is the whole of U+10000..U+10FFFF and it is listed last
  /// in the span index so that a more specific bit wins.
  static const List<UnicodeRange> unicodeRanges = <UnicodeRange>[
    UnicodeRange(0, 'Basic Latin', <({int first, int last})>[
      (first: 0x0000, last: 0x007F),
    ]),
    UnicodeRange(1, 'Latin-1 Supplement', <({int first, int last})>[
      (first: 0x0080, last: 0x00FF),
    ]),
    UnicodeRange(2, 'Latin Extended-A', <({int first, int last})>[
      (first: 0x0100, last: 0x017F),
    ]),
    UnicodeRange(3, 'Latin Extended-B', <({int first, int last})>[
      (first: 0x0180, last: 0x024F),
    ]),
    UnicodeRange(4, 'IPA and Phonetic Extensions', <({int first, int last})>[
      (first: 0x0250, last: 0x02AF),
      (first: 0x1D00, last: 0x1D7F),
      (first: 0x1D80, last: 0x1DBF),
    ]),
    UnicodeRange(5, 'Spacing Modifier Letters', <({int first, int last})>[
      (first: 0x02B0, last: 0x02FF),
      (first: 0xA700, last: 0xA71F),
    ]),
    UnicodeRange(6, 'Combining Diacritical Marks', <({int first, int last})>[
      (first: 0x0300, last: 0x036F),
      (first: 0x1DC0, last: 0x1DFF),
    ]),
    UnicodeRange(7, 'Greek and Coptic', <({int first, int last})>[
      (first: 0x0370, last: 0x03FF),
    ]),
    UnicodeRange(8, 'Coptic', <({int first, int last})>[
      (first: 0x2C80, last: 0x2CFF),
    ]),
    UnicodeRange(9, 'Cyrillic', <({int first, int last})>[
      (first: 0x0400, last: 0x04FF),
      (first: 0x0500, last: 0x052F),
      (first: 0x2DE0, last: 0x2DFF),
      (first: 0xA640, last: 0xA69F),
    ]),
    UnicodeRange(10, 'Armenian', <({int first, int last})>[
      (first: 0x0530, last: 0x058F),
    ]),
    UnicodeRange(11, 'Hebrew', <({int first, int last})>[
      (first: 0x0590, last: 0x05FF),
    ]),
    UnicodeRange(12, 'Vai', <({int first, int last})>[
      (first: 0xA500, last: 0xA63F),
    ]),
    UnicodeRange(13, 'Arabic', <({int first, int last})>[
      (first: 0x0600, last: 0x06FF),
      (first: 0x0750, last: 0x077F),
    ]),
    UnicodeRange(14, 'NKo', <({int first, int last})>[
      (first: 0x07C0, last: 0x07FF),
    ]),
    UnicodeRange(15, 'Devanagari', <({int first, int last})>[
      (first: 0x0900, last: 0x097F),
    ]),
    UnicodeRange(16, 'Bengali', <({int first, int last})>[
      (first: 0x0980, last: 0x09FF),
    ]),
    UnicodeRange(17, 'Gurmukhi', <({int first, int last})>[
      (first: 0x0A00, last: 0x0A7F),
    ]),
    UnicodeRange(18, 'Gujarati', <({int first, int last})>[
      (first: 0x0A80, last: 0x0AFF),
    ]),
    UnicodeRange(19, 'Oriya', <({int first, int last})>[
      (first: 0x0B00, last: 0x0B7F),
    ]),
    UnicodeRange(20, 'Tamil', <({int first, int last})>[
      (first: 0x0B80, last: 0x0BFF),
    ]),
    UnicodeRange(21, 'Telugu', <({int first, int last})>[
      (first: 0x0C00, last: 0x0C7F),
    ]),
    UnicodeRange(22, 'Kannada', <({int first, int last})>[
      (first: 0x0C80, last: 0x0CFF),
    ]),
    UnicodeRange(23, 'Malayalam', <({int first, int last})>[
      (first: 0x0D00, last: 0x0D7F),
    ]),
    UnicodeRange(24, 'Thai', <({int first, int last})>[
      (first: 0x0E00, last: 0x0E7F),
    ]),
    UnicodeRange(25, 'Lao', <({int first, int last})>[
      (first: 0x0E80, last: 0x0EFF),
    ]),
    UnicodeRange(26, 'Georgian', <({int first, int last})>[
      (first: 0x10A0, last: 0x10FF),
      (first: 0x2D00, last: 0x2D2F),
    ]),
    UnicodeRange(27, 'Balinese', <({int first, int last})>[
      (first: 0x1B00, last: 0x1B7F),
    ]),
    UnicodeRange(28, 'Hangul Jamo', <({int first, int last})>[
      (first: 0x1100, last: 0x11FF),
    ]),
    UnicodeRange(29, 'Latin Extended Additional', <({int first, int last})>[
      (first: 0x1E00, last: 0x1EFF),
      (first: 0x2C60, last: 0x2C7F),
      (first: 0xA720, last: 0xA7FF),
    ]),
    UnicodeRange(30, 'Greek Extended', <({int first, int last})>[
      (first: 0x1F00, last: 0x1FFF),
    ]),
    UnicodeRange(31, 'General Punctuation', <({int first, int last})>[
      (first: 0x2000, last: 0x206F),
      (first: 0x2E00, last: 0x2E7F),
    ]),
    UnicodeRange(32, 'Superscripts and Subscripts', <({int first, int last})>[
      (first: 0x2070, last: 0x209F),
    ]),
    UnicodeRange(33, 'Currency Symbols', <({int first, int last})>[
      (first: 0x20A0, last: 0x20CF),
    ]),
    UnicodeRange(34, 'Combining Marks for Symbols', <({int first, int last})>[
      (first: 0x20D0, last: 0x20FF),
    ]),
    UnicodeRange(35, 'Letterlike Symbols', <({int first, int last})>[
      (first: 0x2100, last: 0x214F),
    ]),
    UnicodeRange(36, 'Number Forms', <({int first, int last})>[
      (first: 0x2150, last: 0x218F),
    ]),
    UnicodeRange(37, 'Arrows', <({int first, int last})>[
      (first: 0x2190, last: 0x21FF),
      (first: 0x27F0, last: 0x27FF),
      (first: 0x2900, last: 0x297F),
      (first: 0x2B00, last: 0x2BFF),
    ]),
    UnicodeRange(38, 'Mathematical Operators', <({int first, int last})>[
      (first: 0x2200, last: 0x22FF),
      (first: 0x27C0, last: 0x27EF),
      (first: 0x2980, last: 0x29FF),
      (first: 0x2A00, last: 0x2AFF),
    ]),
    UnicodeRange(39, 'Miscellaneous Technical', <({int first, int last})>[
      (first: 0x2300, last: 0x23FF),
    ]),
    UnicodeRange(40, 'Control Pictures', <({int first, int last})>[
      (first: 0x2400, last: 0x243F),
    ]),
    UnicodeRange(41, 'Optical Character Recognition', <({int first, int last})>[
      (first: 0x2440, last: 0x245F),
    ]),
    UnicodeRange(42, 'Enclosed Alphanumerics', <({int first, int last})>[
      (first: 0x2460, last: 0x24FF),
    ]),
    UnicodeRange(43, 'Box Drawing', <({int first, int last})>[
      (first: 0x2500, last: 0x257F),
    ]),
    UnicodeRange(44, 'Block Elements', <({int first, int last})>[
      (first: 0x2580, last: 0x259F),
    ]),
    UnicodeRange(45, 'Geometric Shapes', <({int first, int last})>[
      (first: 0x25A0, last: 0x25FF),
    ]),
    UnicodeRange(46, 'Miscellaneous Symbols', <({int first, int last})>[
      (first: 0x2600, last: 0x26FF),
    ]),
    UnicodeRange(47, 'Dingbats', <({int first, int last})>[
      (first: 0x2700, last: 0x27BF),
    ]),
    UnicodeRange(48, 'CJK Symbols and Punctuation', <({int first, int last})>[
      (first: 0x3000, last: 0x303F),
    ]),
    UnicodeRange(49, 'Hiragana', <({int first, int last})>[
      (first: 0x3040, last: 0x309F),
    ]),
    UnicodeRange(50, 'Katakana', <({int first, int last})>[
      (first: 0x30A0, last: 0x30FF),
      (first: 0x31F0, last: 0x31FF),
    ]),
    UnicodeRange(51, 'Bopomofo', <({int first, int last})>[
      (first: 0x3100, last: 0x312F),
      (first: 0x31A0, last: 0x31BF),
    ]),
    UnicodeRange(52, 'Hangul Compatibility Jamo', <({int first, int last})>[
      (first: 0x3130, last: 0x318F),
    ]),
    UnicodeRange(53, 'Phags-pa', <({int first, int last})>[
      (first: 0xA840, last: 0xA87F),
    ]),
    UnicodeRange(
        54, 'Enclosed CJK Letters and Months', <({int first, int last})>[
      (first: 0x3200, last: 0x32FF),
    ]),
    UnicodeRange(55, 'CJK Compatibility', <({int first, int last})>[
      (first: 0x3300, last: 0x33FF),
    ]),
    UnicodeRange(56, 'Hangul Syllables', <({int first, int last})>[
      (first: 0xAC00, last: 0xD7AF),
    ]),
    UnicodeRange(57, 'Non-Plane 0', <({int first, int last})>[
      (first: 0x10000, last: 0x10FFFF),
    ]),
    UnicodeRange(58, 'Phoenician', <({int first, int last})>[
      (first: 0x10900, last: 0x1091F),
    ]),
    UnicodeRange(59, 'CJK Unified Ideographs', <({int first, int last})>[
      (first: 0x2E80, last: 0x2EFF),
      (first: 0x2F00, last: 0x2FDF),
      (first: 0x2FF0, last: 0x2FFF),
      (first: 0x3190, last: 0x319F),
      (first: 0x3400, last: 0x4DBF),
      (first: 0x4E00, last: 0x9FFF),
      (first: 0x20000, last: 0x2A6DF),
    ]),
    UnicodeRange(60, 'Private Use Area', <({int first, int last})>[
      (first: 0xE000, last: 0xF8FF),
    ]),
    UnicodeRange(61, 'CJK Compatibility Ideographs', <({int first, int last})>[
      (first: 0x31C0, last: 0x31EF),
      (first: 0xF900, last: 0xFAFF),
      (first: 0x2F800, last: 0x2FA1F),
    ]),
    UnicodeRange(62, 'Alphabetic Presentation Forms', <({int first, int last})>[
      (first: 0xFB00, last: 0xFB4F),
    ]),
    UnicodeRange(63, 'Arabic Presentation Forms-A', <({int first, int last})>[
      (first: 0xFB50, last: 0xFDFF),
    ]),
    UnicodeRange(64, 'Combining Half Marks', <({int first, int last})>[
      (first: 0xFE20, last: 0xFE2F),
    ]),
    UnicodeRange(
        65, 'Vertical and CJK Compatibility Forms', <({int first, int last})>[
      (first: 0xFE10, last: 0xFE1F),
      (first: 0xFE30, last: 0xFE4F),
    ]),
    UnicodeRange(66, 'Small Form Variants', <({int first, int last})>[
      (first: 0xFE50, last: 0xFE6F),
    ]),
    UnicodeRange(67, 'Arabic Presentation Forms-B', <({int first, int last})>[
      (first: 0xFE70, last: 0xFEFF),
    ]),
    UnicodeRange(68, 'Halfwidth and Fullwidth Forms', <({int first, int last})>[
      (first: 0xFF00, last: 0xFFEF),
    ]),
    UnicodeRange(69, 'Specials', <({int first, int last})>[
      (first: 0xFFF0, last: 0xFFFF),
    ]),
    UnicodeRange(70, 'Tibetan', <({int first, int last})>[
      (first: 0x0F00, last: 0x0FFF),
    ]),
    UnicodeRange(71, 'Syriac', <({int first, int last})>[
      (first: 0x0700, last: 0x074F),
    ]),
    UnicodeRange(72, 'Thaana', <({int first, int last})>[
      (first: 0x0780, last: 0x07BF),
    ]),
    UnicodeRange(73, 'Sinhala', <({int first, int last})>[
      (first: 0x0D80, last: 0x0DFF),
    ]),
    UnicodeRange(74, 'Myanmar', <({int first, int last})>[
      (first: 0x1000, last: 0x109F),
    ]),
    UnicodeRange(75, 'Ethiopic', <({int first, int last})>[
      (first: 0x1200, last: 0x137F),
      (first: 0x1380, last: 0x139F),
      (first: 0x2D80, last: 0x2DDF),
    ]),
    UnicodeRange(76, 'Cherokee', <({int first, int last})>[
      (first: 0x13A0, last: 0x13FF),
    ]),
    UnicodeRange(
        77, 'Unified Canadian Aboriginal Syllabics', <({int first, int last})>[
      (first: 0x1400, last: 0x167F),
    ]),
    UnicodeRange(78, 'Ogham', <({int first, int last})>[
      (first: 0x1680, last: 0x169F),
    ]),
    UnicodeRange(79, 'Runic', <({int first, int last})>[
      (first: 0x16A0, last: 0x16FF),
    ]),
    UnicodeRange(80, 'Khmer', <({int first, int last})>[
      (first: 0x1780, last: 0x17FF),
      (first: 0x19E0, last: 0x19FF),
    ]),
    UnicodeRange(81, 'Mongolian', <({int first, int last})>[
      (first: 0x1800, last: 0x18AF),
    ]),
    UnicodeRange(82, 'Braille Patterns', <({int first, int last})>[
      (first: 0x2800, last: 0x28FF),
    ]),
    UnicodeRange(83, 'Yi', <({int first, int last})>[
      (first: 0xA000, last: 0xA48F),
      (first: 0xA490, last: 0xA4CF),
    ]),
    UnicodeRange(84, 'Philippine Scripts', <({int first, int last})>[
      (first: 0x1700, last: 0x171F),
      (first: 0x1720, last: 0x173F),
      (first: 0x1740, last: 0x175F),
      (first: 0x1760, last: 0x177F),
    ]),
    UnicodeRange(85, 'Old Italic', <({int first, int last})>[
      (first: 0x10300, last: 0x1032F),
    ]),
    UnicodeRange(86, 'Gothic', <({int first, int last})>[
      (first: 0x10330, last: 0x1034F),
    ]),
    UnicodeRange(87, 'Deseret', <({int first, int last})>[
      (first: 0x10400, last: 0x1044F),
    ]),
    UnicodeRange(88, 'Musical Symbols', <({int first, int last})>[
      (first: 0x1D000, last: 0x1D0FF),
      (first: 0x1D100, last: 0x1D1FF),
      (first: 0x1D200, last: 0x1D24F),
    ]),
    UnicodeRange(
        89, 'Mathematical Alphanumeric Symbols', <({int first, int last})>[
      (first: 0x1D400, last: 0x1D7FF),
    ]),
    UnicodeRange(
        90, 'Supplementary Private Use Area', <({int first, int last})>[
      (first: 0xF0000, last: 0xFFFFD),
      (first: 0x100000, last: 0x10FFFD),
    ]),
    UnicodeRange(91, 'Variation Selectors', <({int first, int last})>[
      (first: 0xFE00, last: 0xFE0F),
      (first: 0xE0100, last: 0xE01EF),
    ]),
    UnicodeRange(92, 'Tags', <({int first, int last})>[
      (first: 0xE0000, last: 0xE007F),
    ]),
    UnicodeRange(93, 'Limbu', <({int first, int last})>[
      (first: 0x1900, last: 0x194F),
    ]),
    UnicodeRange(94, 'Tai Le', <({int first, int last})>[
      (first: 0x1950, last: 0x197F),
    ]),
    UnicodeRange(95, 'New Tai Lue', <({int first, int last})>[
      (first: 0x1980, last: 0x19DF),
    ]),
    UnicodeRange(96, 'Buginese', <({int first, int last})>[
      (first: 0x1A00, last: 0x1A1F),
    ]),
    UnicodeRange(97, 'Glagolitic', <({int first, int last})>[
      (first: 0x2C00, last: 0x2C5F),
    ]),
    UnicodeRange(98, 'Tifinagh', <({int first, int last})>[
      (first: 0x2D30, last: 0x2D7F),
    ]),
    UnicodeRange(99, 'Yijing Hexagram Symbols', <({int first, int last})>[
      (first: 0x4DC0, last: 0x4DFF),
    ]),
    UnicodeRange(100, 'Syloti Nagri', <({int first, int last})>[
      (first: 0xA800, last: 0xA82F),
    ]),
    UnicodeRange(101, 'Linear B and Aegean Numbers', <({int first, int last})>[
      (first: 0x10000, last: 0x1007F),
      (first: 0x10080, last: 0x100FF),
      (first: 0x10100, last: 0x1013F),
    ]),
    UnicodeRange(102, 'Ancient Greek Numbers', <({int first, int last})>[
      (first: 0x10140, last: 0x1018F),
    ]),
    UnicodeRange(103, 'Ugaritic', <({int first, int last})>[
      (first: 0x10380, last: 0x1039F),
    ]),
    UnicodeRange(104, 'Old Persian', <({int first, int last})>[
      (first: 0x103A0, last: 0x103DF),
    ]),
    UnicodeRange(105, 'Shavian', <({int first, int last})>[
      (first: 0x10450, last: 0x1047F),
    ]),
    UnicodeRange(106, 'Osmanya', <({int first, int last})>[
      (first: 0x10480, last: 0x104AF),
    ]),
    UnicodeRange(107, 'Cypriot Syllabary', <({int first, int last})>[
      (first: 0x10800, last: 0x1083F),
    ]),
    UnicodeRange(108, 'Kharoshthi', <({int first, int last})>[
      (first: 0x10A00, last: 0x10A5F),
    ]),
    UnicodeRange(109, 'Tai Xuan Jing Symbols', <({int first, int last})>[
      (first: 0x1D300, last: 0x1D35F),
    ]),
    UnicodeRange(110, 'Cuneiform', <({int first, int last})>[
      (first: 0x12000, last: 0x123FF),
      (first: 0x12400, last: 0x1247F),
    ]),
    UnicodeRange(111, 'Counting Rod Numerals', <({int first, int last})>[
      (first: 0x1D360, last: 0x1D37F),
    ]),
    UnicodeRange(112, 'Sundanese', <({int first, int last})>[
      (first: 0x1B80, last: 0x1BBF),
    ]),
    UnicodeRange(113, 'Lepcha', <({int first, int last})>[
      (first: 0x1C00, last: 0x1C4F),
    ]),
    UnicodeRange(114, 'Ol Chiki', <({int first, int last})>[
      (first: 0x1C50, last: 0x1C7F),
    ]),
    UnicodeRange(115, 'Saurashtra', <({int first, int last})>[
      (first: 0xA880, last: 0xA8DF),
    ]),
    UnicodeRange(116, 'Kayah Li', <({int first, int last})>[
      (first: 0xA900, last: 0xA92F),
    ]),
    UnicodeRange(117, 'Rejang', <({int first, int last})>[
      (first: 0xA930, last: 0xA95F),
    ]),
    UnicodeRange(118, 'Cham', <({int first, int last})>[
      (first: 0xAA00, last: 0xAA5F),
    ]),
    UnicodeRange(119, 'Ancient Symbols', <({int first, int last})>[
      (first: 0x10190, last: 0x101CF),
    ]),
    UnicodeRange(120, 'Phaistos Disc', <({int first, int last})>[
      (first: 0x101D0, last: 0x101FF),
    ]),
    UnicodeRange(121, 'Carian, Lycian and Lydian', <({int first, int last})>[
      (first: 0x10280, last: 0x1029F),
      (first: 0x102A0, last: 0x102DF),
      (first: 0x10920, last: 0x1093F),
    ]),
    UnicodeRange(122, 'Domino and Mahjong Tiles', <({int first, int last})>[
      (first: 0x1F000, last: 0x1F02F),
      (first: 0x1F030, last: 0x1F09F),
    ]),
  ];

  /// Flat, ascending span index over [unicodeRanges], for
  /// [rangeForCodePoint].
  ///
  /// Bit 57's whole-supplementary-plane span is excluded: it overlaps every
  /// other astral bit, and including it would make the "spans do not overlap"
  /// invariant the binary search relies on false. A caller who wants to know
  /// whether a font claims *any* astral coverage tests bit 57 directly.
  ///
  /// A `static final` is lazily initialised in Dart, so the sort happens on the
  /// first fallback query in a process and never again.
  static final ({
    Uint32List starts,
    Uint32List ends,
    Uint8List rangeIndex
  }) _spanIndex = _buildSpanIndex();

  static ({Uint32List starts, Uint32List ends, Uint8List rangeIndex})
      _buildSpanIndex() {
    final List<({int start, int end, int index})> flat =
        <({int start, int end, int index})>[];
    for (int i = 0; i < unicodeRanges.length; i++) {
      final UnicodeRange range = unicodeRanges[i];
      if (range.bit == 57) continue; // see the doc on _spanStarts
      for (final ({int first, int last}) span in range.spans) {
        flat.add((start: span.first, end: span.last, index: i));
      }
    }
    flat.sort((({int start, int end, int index}) a,
            ({int start, int end, int index}) b) =>
        a.start.compareTo(b.start));

    final Uint32List starts = Uint32List(flat.length);
    final Uint32List ends = Uint32List(flat.length);
    final Uint8List rangeIndex = Uint8List(flat.length);
    for (int i = 0; i < flat.length; i++) {
      starts[i] = flat[i].start;
      ends[i] = flat[i].end;
      rangeIndex[i] = flat[i].index;
    }
    return (starts: starts, ends: ends, rangeIndex: rangeIndex);
  }

  // --- parsing -------------------------------------------------------------

  static String _trimTag(String tag) {
    int end = tag.length;
    while (end > 0) {
      final int unit = tag.codeUnitAt(end - 1);
      if (unit != 0x20 && unit != 0x00) break;
      end--;
    }
    return tag.substring(0, end);
  }

  /// Byte length of an `OS/2` table of each version.
  static int requiredLengthFor(int version) => switch (version) {
        0 => 78,
        1 => 86,
        2 || 3 || 4 => 96,
        _ => 100,
      };

  /// Parses `OS/2`, or returns null when the font has no such table.
  ///
  /// A TrueType font may legally omit it - Ahem does not, but many
  /// bitmap-origin and test fonts do - so absence is null rather than an
  /// exception. Presence with a length that contradicts the declared version
  /// *is* an exception: see the class doc.
  static Os2Table? parse(SfntFile file) {
    if (!file.hasTable('OS/2')) return null;
    final TableRecord record = file.requireTable('OS/2');
    final FontReader reader = file.readerFor('OS/2');

    final int version = reader.readUint16();
    final int required = requiredLengthFor(version);
    if (record.length < required) {
      throw FontFormatException(
        record.length == 68
            ? 'this is the 68-byte Apple variant of OS/2 version 0, which '
                'stops before the vertical metrics; it is refused rather than '
                'parsed, because half an OS/2 table is worse than none'
            : 'version $version needs $required bytes but the table is only '
                '${record.length}',
        table: 'OS/2',
        offset: record.offset,
      );
    }

    final int xAvgCharWidth = reader.readInt16();
    final int weightClass = reader.readUint16();
    final int widthClass = reader.readUint16();
    final int fsType = reader.readUint16();

    // Both are validated because both are *matching* inputs: a zero weight
    // sorts before Thin and a zero width indexes off the end of any table
    // keyed by width class. A font that states them out of range has told us
    // something false, and there is no correct repair - 0 might mean "unset"
    // or might mean the writer used a 0-based scale.
    if (weightClass < 1 || weightClass > 1000) {
      throw FontFormatException(
        'usWeightClass $weightClass is outside the legal range 1..1000',
        table: 'OS/2',
        offset: record.offset + 4,
      );
    }
    if (widthClass < 1 || widthClass > 9) {
      throw FontFormatException(
        'usWidthClass $widthClass is outside the legal range 1..9',
        table: 'OS/2',
        offset: record.offset + 6,
      );
    }

    final int subscriptXSize = reader.readInt16();
    final int subscriptYSize = reader.readInt16();
    final int subscriptXOffset = reader.readInt16();
    final int subscriptYOffset = reader.readInt16();
    final int superscriptXSize = reader.readInt16();
    final int superscriptYSize = reader.readInt16();
    final int superscriptXOffset = reader.readInt16();
    final int superscriptYOffset = reader.readInt16();
    final int strikeoutSize = reader.readInt16();
    final int strikeoutPosition = reader.readInt16();
    final int familyClass = reader.readInt16();
    final Uint8List panose = Uint8List.fromList(reader.readBytes(10));
    final int range1 = reader.readUint32();
    final int range2 = reader.readUint32();
    final int range3 = reader.readUint32();
    final int range4 = reader.readUint32();
    // Space-padded to four characters by specification, and NUL-padded by a
    // handful of real tools. Both are stripped, because "MS  " and "MS\0\0"
    // are the same foundry and a font manager that groups by vendor should not
    // see two.
    final String vendorId = _trimTag(reader.readTag());
    final int fsSelection = reader.readUint16();
    final int firstCharIndex = reader.readUint16();
    final int lastCharIndex = reader.readUint16();
    final int typoAscender = reader.readInt16();
    final int typoDescender = reader.readInt16();
    final int typoLineGap = reader.readInt16();
    final int winAscent = reader.readUint16();
    final int winDescent = reader.readUint16();

    int codePageRange1 = 0;
    int codePageRange2 = 0;
    if (version >= 1) {
      codePageRange1 = reader.readUint32();
      codePageRange2 = reader.readUint32();
    }

    int sxHeight = 0;
    int sCapHeight = 0;
    int defaultChar = 0;
    int breakChar = 0;
    int maxContext = 0;
    if (version >= 2) {
      sxHeight = reader.readInt16();
      sCapHeight = reader.readInt16();
      defaultChar = reader.readUint16();
      breakChar = reader.readUint16();
      maxContext = reader.readUint16();
    }

    int lowerOpticalPointSize = 0;
    int upperOpticalPointSize = 0;
    if (version >= 5) {
      lowerOpticalPointSize = reader.readUint16();
      upperOpticalPointSize = reader.readUint16();
    }

    return Os2Table._(
      // A version beyond 5 is reported as 5: the specification only ever
      // appends, so the v5 layout is a valid prefix of whatever came later, and
      // clamping keeps every `version >= n` gate in this class honest.
      version: version > 5 ? 5 : version,
      xAvgCharWidth: xAvgCharWidth,
      weightClass: weightClass,
      widthClass: widthClass,
      fsType: fsType,
      subscriptXSize: subscriptXSize,
      subscriptYSize: subscriptYSize,
      subscriptXOffset: subscriptXOffset,
      subscriptYOffset: subscriptYOffset,
      superscriptXSize: superscriptXSize,
      superscriptYSize: superscriptYSize,
      superscriptXOffset: superscriptXOffset,
      superscriptYOffset: superscriptYOffset,
      strikeoutSize: strikeoutSize,
      strikeoutPosition: strikeoutPosition,
      familyClass: familyClass,
      panose: panose,
      ulUnicodeRange1: range1,
      ulUnicodeRange2: range2,
      ulUnicodeRange3: range3,
      ulUnicodeRange4: range4,
      vendorId: vendorId,
      fsSelection: fsSelection,
      firstCharIndex: firstCharIndex,
      lastCharIndex: lastCharIndex,
      typoAscender: typoAscender,
      typoDescender: typoDescender,
      typoLineGap: typoLineGap,
      winAscent: winAscent,
      winDescent: winDescent,
      codePageRange1: codePageRange1,
      codePageRange2: codePageRange2,
      sxHeight: sxHeight,
      sCapHeight: sCapHeight,
      defaultChar: defaultChar,
      breakChar: breakChar,
      maxContext: maxContext,
      lowerOpticalPointSize: lowerOpticalPointSize,
      upperOpticalPointSize: upperOpticalPointSize,
    );
  }
}

/// `post` - PostScript-oriented data, and the glyph names.
///
/// Two unrelated things share this table. The header is layout data every
/// version carries: [isFixedPitch], [italicAngle], [underlinePosition] and
/// [underlineThickness]. After it, depending on the version, come glyph names.
///
/// ## The four versions
///
///   * **1.0** - the font's glyphs *are* the 258 Macintosh standard glyphs, in
///     standard order, so the names are implied and nothing is stored;
///   * **2.0** - the general case: an index per glyph, where indices below 258
///     name a standard glyph and the rest point into a list of Pascal strings
///     that follows;
///   * **2.5** - deprecated since 1997. A signed delta per glyph into the
///     standard order, for a font that has the standard glyphs in a permuted
///     order. Implemented because it costs ten lines and old fonts still have
///     it;
///   * **3.0** - **no names at all**. The version every modern font ships,
///     because names cost kilobytes and nothing at render time needs them.
///
/// [hasGlyphNames] is false for 3.0, and [nameOf] returns null for every glyph.
/// It does not return `''` or `'glyph42'`: a synthesised name looks like a real
/// one to a caller writing a PDF, and a PDF with invented glyph names is a file
/// that renders wrongly somewhere else, days later.
final class PostTable {
  PostTable._({
    required this.version,
    required this.italicAngle,
    required this.underlinePosition,
    required this.underlineThickness,
    required this.isFixedPitch,
    required this.minMemType42,
    required this.maxMemType42,
    required this.minMemType1,
    required this.maxMemType1,
    required List<String>? names,
  }) : _names = names;

  /// 1.0, 2.0, 2.5 or 3.0, as a double because the field is a 16.16 fixed.
  final double version;

  /// The slant, in **counter-clockwise degrees**. Negative for a normal
  /// forward-leaning italic - the sign trips up everyone once, so: Roboto
  /// Italic is -12, not 12.
  final double italicAngle;

  /// Where the underline sits relative to the baseline, in font units.
  /// Negative, since it is below.
  final int underlinePosition;

  final int underlineThickness;

  /// Whether every glyph has the same advance.
  ///
  /// A claim, not a measurement: a font may set it and still ship a wide glyph.
  /// Useful as a hint for terminal-style layout, never as a licence to skip
  /// reading `hmtx`.
  final bool isFixedPitch;

  final int minMemType42;
  final int maxMemType42;
  final int minMemType1;
  final int maxMemType1;

  /// Per-glyph names, or null when the version carries none.
  final List<String>? _names;

  /// Lazily built reverse index for [glyphForName]. Absent until asked for,
  /// because most callers only ever go glyph-to-name.
  Map<String, int>? _byName;

  /// Whether this version stores or implies glyph names.
  ///
  /// False for 3.0. Check it before [nameOf] if the distinction between "this
  /// glyph has no name" and "this font has no names" matters - and it usually
  /// does, since the first is a data question and the second a format one.
  bool get hasGlyphNames => _names != null;

  /// How many glyphs this table names. Zero when [hasGlyphNames] is false.
  int get namedGlyphCount => _names?.length ?? 0;

  /// The name of [glyphId], or null.
  ///
  /// Null means one of three things, all of them honest: the version has no
  /// names, the glyph id is past what this table covers, or the font stored an
  /// empty name for it.
  String? nameOf(int glyphId) {
    final List<String>? names = _names;
    if (names == null || glyphId < 0 || glyphId >= names.length) return null;
    final String name = names[glyphId];
    return name.isEmpty ? null : name;
  }

  /// The name of [glyphId], or a named exception.
  ///
  /// For a caller - a PDF writer, a font subsetter - that cannot proceed
  /// without a name and must not invent one.
  String requireNameOf(int glyphId) {
    final String? name = nameOf(glyphId);
    if (name != null) return name;
    throw FontFormatException(
      _names == null
          ? 'this is a post version $version table, which stores no glyph '
              'names at all'
          : 'glyph $glyphId has no name in this post table',
      table: 'post',
    );
  }

  /// The glyph called [name], or null.
  ///
  /// Builds an index on first use. Ambiguity is resolved to the *lowest* glyph
  /// id, because a font that names two glyphs the same is malformed and the
  /// first is the one every other tool picks.
  int? glyphForName(String name) {
    final List<String>? names = _names;
    if (names == null) return null;
    Map<String, int>? index = _byName;
    if (index == null) {
      index = <String, int>{};
      for (int i = names.length - 1; i >= 0; i--) {
        if (names[i].isNotEmpty) index[names[i]] = i;
      }
      _byName = index;
    }
    return index[name];
  }

  /// Parses `post`, or returns null when the font has no such table.
  static PostTable? parse(SfntFile file) {
    if (!file.hasTable('post')) return null;
    final TableRecord record = file.requireTable('post');
    final FontReader reader = file.readerFor('post');

    // The 32-byte header is common to every version, so a table shorter than
    // that is truncated no matter what version it claims.
    if (record.length < 32) {
      throw FontFormatException(
        'the table is ${record.length} bytes, shorter than the 32-byte header '
        'every version has',
        table: 'post',
        offset: record.offset,
      );
    }

    final double version = reader.readFixed();
    final double italicAngle = reader.readFixed();
    final int underlinePosition = reader.readInt16();
    final int underlineThickness = reader.readInt16();
    final bool isFixedPitch = reader.readUint32() != 0;
    final int minMemType42 = reader.readUint32();
    final int maxMemType42 = reader.readUint32();
    final int minMemType1 = reader.readUint32();
    final int maxMemType1 = reader.readUint32();

    List<String>? names;
    if (version == 1.0) {
      // Version 1.0 says: my glyphs are the standard 258, in standard order.
      names = macintoshGlyphNames;
    } else if (version == 2.0) {
      names = _parseVersion2Names(record, reader);
    } else if (version == 2.5) {
      names = _parseVersion25Names(record, reader);
    } else if (version != 3.0) {
      throw FontFormatException(
        'version $version is not one of 1.0, 2.0, 2.5 or 3.0',
        table: 'post',
        offset: record.offset,
      );
    }

    return PostTable._(
      version: version,
      italicAngle: italicAngle,
      underlinePosition: underlinePosition,
      underlineThickness: underlineThickness,
      isFixedPitch: isFixedPitch,
      minMemType42: minMemType42,
      maxMemType42: maxMemType42,
      minMemType1: minMemType1,
      maxMemType1: maxMemType1,
      names: names,
    );
  }

  static List<String> _parseVersion2Names(
    TableRecord record,
    FontReader reader,
  ) {
    final int tableEnd = record.offset + record.length;
    final int numGlyphs = reader.readUint16();
    if (reader.offset + numGlyphs * 2 > tableEnd) {
      throw FontFormatException(
        'version 2.0 declares $numGlyphs glyph name indices, which do not fit '
        'in the ${record.length}-byte table',
        table: 'post',
        offset: record.offset,
      );
    }
    final Uint16List indices = reader.readUint16List(numGlyphs);

    // The Pascal strings follow, one after another, each a length byte plus
    // that many bytes. There is no count: the list ends when the table does,
    // which is why the loop is bounded by the table and not by numGlyphs.
    final List<String> pool = <String>[];
    while (reader.offset < tableEnd) {
      final int length = reader.readUint8();
      if (reader.offset + length > tableEnd) break;
      // Pascal strings here are ASCII by specification, and a glyph name that
      // is not is already outside what any consumer would accept.
      pool.add(String.fromCharCodes(reader.readBytes(length)));
    }

    final List<String> names = List<String>.filled(numGlyphs, '');
    for (int i = 0; i < numGlyphs; i++) {
      final int index = indices[i];
      if (index < 258) {
        names[i] = macintoshGlyphNames[index];
      } else {
        final int poolIndex = index - 258;
        // An index past the pool is corruption, and it is common in fonts
        // produced by subsetters that rewrote the indices and not the strings.
        // The glyph loses its name; the font keeps its other 5000.
        names[i] = poolIndex < pool.length ? pool[poolIndex] : '';
      }
    }
    return names;
  }

  static List<String> _parseVersion25Names(
    TableRecord record,
    FontReader reader,
  ) {
    final int tableEnd = record.offset + record.length;
    final int numGlyphs = reader.readUint16();
    if (reader.offset + numGlyphs > tableEnd) {
      throw FontFormatException(
        'version 2.5 declares $numGlyphs offsets, which do not fit in the '
        '${record.length}-byte table',
        table: 'post',
        offset: record.offset,
      );
    }
    final List<String> names = List<String>.filled(numGlyphs, '');
    for (int i = 0; i < numGlyphs; i++) {
      // The stored value is a signed delta: glyph i is standard glyph
      // i + offset[i]. That is the whole of format 2.5 - it exists to permute
      // the standard order without storing a single string.
      final int index = i + reader.readInt8();
      names[i] = index >= 0 && index < 258 ? macintoshGlyphNames[index] : '';
    }
    return names;
  }

  /// The 258 Macintosh standard glyph names, in standard order.
  ///
  /// Indices 0..2 are the three special glyphs every font begins with, 3..97
  /// are printable ASCII in code point order, and 98..257 are the accented
  /// Latin, punctuation and symbol glyphs of the Mac Roman repertoire in the
  /// order Apple fixed in 1991. The order is not derivable from anything - it
  /// is a historical list - which is why it is written out.
  static const List<String> macintoshGlyphNames = <String>[
    '.notdef',
    '.null',
    'nonmarkingreturn',
    'space',
    'exclam',
    'quotedbl',
    'numbersign',
    'dollar',
    'percent',
    'ampersand',
    'quotesingle',
    'parenleft',
    'parenright',
    'asterisk',
    'plus',
    'comma',
    'hyphen',
    'period',
    'slash',
    'zero',
    'one',
    'two',
    'three',
    'four',
    'five',
    'six',
    'seven',
    'eight',
    'nine',
    'colon',
    'semicolon',
    'less',
    'equal',
    'greater',
    'question',
    'at',
    'A',
    'B',
    'C',
    'D',
    'E',
    'F',
    'G',
    'H',
    'I',
    'J',
    'K',
    'L',
    'M',
    'N',
    'O',
    'P',
    'Q',
    'R',
    'S',
    'T',
    'U',
    'V',
    'W',
    'X',
    'Y',
    'Z',
    'bracketleft',
    'backslash',
    'bracketright',
    'asciicircum',
    'underscore',
    'grave',
    'a',
    'b',
    'c',
    'd',
    'e',
    'f',
    'g',
    'h',
    'i',
    'j',
    'k',
    'l',
    'm',
    'n',
    'o',
    'p',
    'q',
    'r',
    's',
    't',
    'u',
    'v',
    'w',
    'x',
    'y',
    'z',
    'braceleft',
    'bar',
    'braceright',
    'asciitilde',
    'Adieresis',
    'Aring',
    'Ccedilla',
    'Eacute',
    'Ntilde',
    'Odieresis',
    'Udieresis',
    'aacute',
    'agrave',
    'acircumflex',
    'adieresis',
    'atilde',
    'aring',
    'ccedilla',
    'eacute',
    'egrave',
    'ecircumflex',
    'edieresis',
    'iacute',
    'igrave',
    'icircumflex',
    'idieresis',
    'ntilde',
    'oacute',
    'ograve',
    'ocircumflex',
    'odieresis',
    'otilde',
    'uacute',
    'ugrave',
    'ucircumflex',
    'udieresis',
    'dagger',
    'degree',
    'cent',
    'sterling',
    'section',
    'bullet',
    'paragraph',
    'germandbls',
    'registered',
    'copyright',
    'trademark',
    'acute',
    'dieresis',
    'notequal',
    'AE',
    'Oslash',
    'infinity',
    'plusminus',
    'lessequal',
    'greaterequal',
    'yen',
    'mu',
    'partialdiff',
    'summation',
    'product',
    'pi',
    'integral',
    'ordfeminine',
    'ordmasculine',
    'Omega',
    'ae',
    'oslash',
    'questiondown',
    'exclamdown',
    'logicalnot',
    'radical',
    'florin',
    'approxequal',
    'Delta',
    'guillemotleft',
    'guillemotright',
    'ellipsis',
    'nonbreakingspace',
    'Agrave',
    'Atilde',
    'Otilde',
    'OE',
    'oe',
    'endash',
    'emdash',
    'quotedblleft',
    'quotedblright',
    'quoteleft',
    'quoteright',
    'divide',
    'lozenge',
    'ydieresis',
    'Ydieresis',
    'fraction',
    'currency',
    'guilsinglleft',
    'guilsinglright',
    'fi',
    'fl',
    'daggerdbl',
    'periodcentered',
    'quotesinglbase',
    'quotedblbase',
    'perthousand',
    'Acircumflex',
    'Ecircumflex',
    'Aacute',
    'Edieresis',
    'Egrave',
    'Iacute',
    'Icircumflex',
    'Idieresis',
    'Igrave',
    'Oacute',
    'Ocircumflex',
    'apple',
    'Ograve',
    'Uacute',
    'Ucircumflex',
    'Ugrave',
    'dotlessi',
    'circumflex',
    'tilde',
    'macron',
    'breve',
    'dotaccent',
    'ring',
    'cedilla',
    'hungarumlaut',
    'ogonek',
    'caron',
    'Lslash',
    'lslash',
    'Scaron',
    'scaron',
    'Zcaron',
    'zcaron',
    'brokenbar',
    'Eth',
    'eth',
    'Yacute',
    'yacute',
    'Thorn',
    'thorn',
    'minus',
    'multiply',
    'onesuperior',
    'twosuperior',
    'threesuperior',
    'onehalf',
    'onequarter',
    'threequarters',
    'franc',
    'Gbreve',
    'gbreve',
    'Idotaccent',
    'Scedilla',
    'scedilla',
    'Cacute',
    'cacute',
    'Ccaron',
    'ccaron',
    'dcroat',
  ];
}
