/// The machinery `GSUB` and `GPOS` are both built out of.
///
/// The two tables are different vocabularies over an identical skeleton, and
/// the skeleton is what this file is. A layout table names *scripts*, each
/// script names *languages*, each language selects *features* by tag, each
/// feature names *lookups* by index, and each lookup holds subtables that do
/// the actual work. Only the innermost layer differs between substitution and
/// positioning; everything above it - and the two set primitives, [Coverage]
/// and [ClassDef], that every subtable uses to say "which glyphs do I apply
/// to" - is shared, so it lives here once instead of twice.
///
/// ## Everything is an offset, and every offset is untrusted
///
/// A layout table is a graph of 16-bit offsets, each relative to a different
/// base: a subtable's coverage offset is from the subtable, a mark anchor's
/// offset is from the mark array, a script's language offset is from the
/// script. Getting the base wrong reads a plausible-looking integer from the
/// wrong place, which is why every parse function here takes its base
/// explicitly rather than inheriting a cursor.
///
/// And because the offsets come from the file, they can point anywhere. Every
/// read goes through [FontReader] so that a font that lies produces a named
/// [FontFormatException] instead of a `RangeError` from somewhere deep in a
/// substitution loop - roadmap section 30.8.
///
/// ## Parsed lazily, on purpose
///
/// Subtables are *not* decoded into objects at load time. A lookup keeps the
/// byte offsets of its subtables and reads them as it applies them, which is
/// how HarfBuzz is structured too and for the same reason: DejaVu's `GSUB`
/// holds 29 lookups and a shaping run for Latin text touches four of them.
/// Decoding the other 25 would be work done to be thrown away, and for a
/// 6000-glyph font it is not a small amount of work. What *is* cached is
/// [Coverage] and [ClassDef], because those are consulted once per glyph per
/// subtable - see [OffsetCache].
library;

import 'dart:typed_data';

import 'font_data.dart';
import 'sfnt.dart';

/// The value an absent glyph, feature or offset is written as.
const int _none = 0xFFFF;

/// A set of glyph ids that also numbers its members.
///
/// Both jobs matter. "Is this glyph covered" gates whether a subtable applies
/// at all, and the *index* within the coverage is how the subtable then finds
/// this glyph's data: a coverage index of 3 means "the fourth entry of my
/// parallel array". The two formats trade size against the shape of the set -
/// format 1 lists glyphs, format 2 lists ranges - and both are common enough
/// in shipping fonts that supporting only one loses features silently.
final class Coverage {
  const Coverage._(
    this._glyphs,
    this._rangeStart,
    this._rangeEnd,
    this._rangeIndex,
    this.glyphCount,
  );

  /// Format 1: the covered glyphs, ascending. Null when this is format 2.
  final Uint16List? _glyphs;

  /// Format 2: range bounds and the coverage index of each range's first
  /// glyph. Null when this is format 1.
  final Uint16List? _rangeStart;
  final Uint16List? _rangeEnd;
  final Uint16List? _rangeIndex;

  /// How many glyphs the table covers, and therefore how long the parallel
  /// arrays that [indexOf] indexes are expected to be.
  final int glyphCount;

  /// Reads a coverage table at [offset].
  static Coverage parse(FontData data, int offset, {String? table}) {
    final FontReader reader = data.readerAt(offset, table: table);
    final int format = reader.readUint16();
    switch (format) {
      case 1:
        final int count = reader.readUint16();
        final Uint16List glyphs = reader.readUint16List(count);
        return Coverage._(glyphs, null, null, null, count);
      case 2:
        final int count = reader.readUint16();
        final Uint16List starts = Uint16List(count);
        final Uint16List ends = Uint16List(count);
        final Uint16List indices = Uint16List(count);
        int total = 0;
        for (int i = 0; i < count; i++) {
          starts[i] = reader.readUint16();
          ends[i] = reader.readUint16();
          indices[i] = reader.readUint16();
          // Derived rather than trusted: a range whose end precedes its start
          // would otherwise make glyphCount meaningless.
          if (ends[i] >= starts[i]) {
            total = indices[i] + ends[i] - starts[i] + 1;
          }
        }
        return Coverage._(null, starts, ends, indices, total);
      default:
        throw FontFormatException(
          'coverage format $format is not defined',
          offset: offset,
          table: table,
        );
    }
  }

  /// The coverage index of [glyph], or -1 when it is not covered.
  ///
  /// Binary search in both formats. The format itself requires ascending
  /// order, and a font that violates it loses the affected lookups rather
  /// than misbehaving, which is the right failure: a linear scan to be safe
  /// would cost every glyph of every run for the benefit of broken fonts.
  int indexOf(int glyph) {
    final Uint16List? glyphs = _glyphs;
    if (glyphs != null) {
      int low = 0;
      int high = glyphs.length - 1;
      while (low <= high) {
        final int mid = (low + high) >> 1;
        final int value = glyphs[mid];
        if (value == glyph) return mid;
        if (value < glyph) {
          low = mid + 1;
        } else {
          high = mid - 1;
        }
      }
      return -1;
    }

    final Uint16List starts = _rangeStart!;
    final Uint16List ends = _rangeEnd!;
    int low = 0;
    int high = starts.length - 1;
    while (low <= high) {
      final int mid = (low + high) >> 1;
      if (glyph < starts[mid]) {
        high = mid - 1;
      } else if (glyph > ends[mid]) {
        low = mid + 1;
      } else {
        return _rangeIndex![mid] + glyph - starts[mid];
      }
    }
    return -1;
  }

  bool covers(int glyph) => indexOf(glyph) >= 0;
}

/// A partition of the glyph space into numbered classes.
///
/// Class 0 is not "no class": it is the class of every glyph the table does
/// not mention, and contextual rules match against it like any other. That is
/// why the absent-table case is [ClassDef.empty] rather than null - a class
/// definition offset of zero in a chain context subtable means "everything is
/// class 0", and treating it as "no constraint" would match far too much.
final class ClassDef {
  const ClassDef._(
    this._startGlyph,
    this._classes,
    this._rangeStart,
    this._rangeEnd,
    this._rangeClass,
  );

  /// Every glyph in class 0.
  static const ClassDef empty = ClassDef._(0, null, null, null, null);

  final int _startGlyph;

  /// Format 1: one class per glyph from [_startGlyph].
  final Uint16List? _classes;

  /// Format 2: ranges, ascending, with the class each carries.
  final Uint16List? _rangeStart;
  final Uint16List? _rangeEnd;
  final Uint16List? _rangeClass;

  /// Reads a class definition at [offset], or [empty] when [offset] is zero.
  static ClassDef parse(FontData data, int offset, {String? table}) {
    if (offset == 0) return empty;
    final FontReader reader = data.readerAt(offset, table: table);
    final int format = reader.readUint16();
    switch (format) {
      case 1:
        final int start = reader.readUint16();
        final int count = reader.readUint16();
        return ClassDef._(
            start, reader.readUint16List(count), null, null, null);
      case 2:
        final int count = reader.readUint16();
        final Uint16List starts = Uint16List(count);
        final Uint16List ends = Uint16List(count);
        final Uint16List classes = Uint16List(count);
        for (int i = 0; i < count; i++) {
          starts[i] = reader.readUint16();
          ends[i] = reader.readUint16();
          classes[i] = reader.readUint16();
        }
        return ClassDef._(0, null, starts, ends, classes);
      default:
        throw FontFormatException(
          'class definition format $format is not defined',
          offset: offset,
          table: table,
        );
    }
  }

  /// The class of [glyph]. Zero for anything the table does not list.
  int classOf(int glyph) {
    final Uint16List? classes = _classes;
    if (classes != null) {
      final int index = glyph - _startGlyph;
      if (index < 0 || index >= classes.length) return 0;
      return classes[index];
    }
    final Uint16List? starts = _rangeStart;
    if (starts == null) return 0;
    final Uint16List ends = _rangeEnd!;
    int low = 0;
    int high = starts.length - 1;
    while (low <= high) {
      final int mid = (low + high) >> 1;
      if (glyph < starts[mid]) {
        high = mid - 1;
      } else if (glyph > ends[mid]) {
        low = mid + 1;
      } else {
        return _rangeClass![mid];
      }
    }
    return 0;
  }
}

/// One language system: the features it turns on.
final class LangSys {
  const LangSys(this.requiredFeatureIndex, this.featureIndices);

  /// The feature that is on whatever the caller asked for, or 0xFFFF for none.
  final int requiredFeatureIndex;

  /// Indices into the table's [FeatureList].
  final Uint16List featureIndices;

  static LangSys parse(FontData data, int offset, {String? table}) {
    final FontReader reader = data.readerAt(offset, table: table);
    reader.skip(2); // lookupOrderOffset, reserved and always zero
    final int required = reader.readUint16();
    final int count = reader.readUint16();
    return LangSys(required, reader.readUint16List(count));
  }
}

/// One script, and the language systems written for it.
final class ScriptTable {
  const ScriptTable(this.defaultLangSys, this.languages);

  final LangSys? defaultLangSys;
  final Map<String, LangSys> languages;

  /// The system for [tag], falling back to the script's default.
  ///
  /// Falling back rather than failing: a language tag is a *refinement* -
  /// Turkish differs from the Latin default in exactly one feature - so an
  /// unknown language must still get the script's ordinary behaviour.
  LangSys? forLanguage(String? tag) {
    if (tag != null) {
      final LangSys? exact = languages[tag];
      if (exact != null) return exact;
    }
    return defaultLangSys;
  }

  static ScriptTable parse(FontData data, int offset, {String? table}) {
    final FontReader reader = data.readerAt(offset, table: table);
    final int defaultOffset = reader.readUint16();
    final int count = reader.readUint16();
    final Map<String, LangSys> languages = <String, LangSys>{};
    for (int i = 0; i < count; i++) {
      final String tag = reader.readTag();
      final int langOffset = reader.readUint16();
      if (langOffset == 0) continue;
      languages[tag] = LangSys.parse(data, offset + langOffset, table: table);
    }
    return ScriptTable(
      defaultOffset == 0
          ? null
          : LangSys.parse(data, offset + defaultOffset, table: table),
      languages,
    );
  }
}

/// Every script the table has rules for.
final class ScriptList {
  const ScriptList(this.scripts);

  final Map<String, ScriptTable> scripts;

  /// The script table for [tag], or the best available substitute.
  ///
  /// `DFLT` is the tag a font uses for "rules that apply to every script it
  /// does not name", and a font that only has `DFLT` still has real features
  /// in it. Falling through to the first entry after that is a last resort
  /// which keeps a font with an unexpected tag - `latn` written `Latn`, say -
  /// from silently losing its ligatures.
  ScriptTable? resolve(String tag) =>
      scripts[tag] ??
      scripts['DFLT'] ??
      scripts['dflt'] ??
      (scripts.isEmpty ? null : scripts.values.first);

  static ScriptList parse(FontData data, int offset, {String? table}) {
    final FontReader reader = data.readerAt(offset, table: table);
    final int count = reader.readUint16();
    final Map<String, ScriptTable> scripts = <String, ScriptTable>{};
    for (int i = 0; i < count; i++) {
      final String tag = reader.readTag();
      final int scriptOffset = reader.readUint16();
      if (scriptOffset == 0) continue;
      scripts[tag] =
          ScriptTable.parse(data, offset + scriptOffset, table: table);
    }
    return ScriptList(scripts);
  }
}

/// One feature: a four-character tag and the lookups that implement it.
final class FeatureEntry {
  const FeatureEntry(this.tag, this.lookupIndices);

  final String tag;
  final Uint16List lookupIndices;
}

/// The table's features, in the order the file lists them.
///
/// A tag appears more than once - once per script that uses a different set of
/// lookups for it - so this is a list indexed by [LangSys.featureIndices], not
/// a map keyed by tag. Building a map would silently drop every duplicate but
/// one, which is how a font's Cyrillic ligatures end up applied to Greek.
final class FeatureList {
  const FeatureList(this.features);

  final List<FeatureEntry> features;

  static FeatureList parse(FontData data, int offset, {String? table}) {
    final FontReader reader = data.readerAt(offset, table: table);
    final int count = reader.readUint16();
    final List<int> offsets = <int>[];
    final List<String> tags = <String>[];
    for (int i = 0; i < count; i++) {
      tags.add(reader.readTag());
      offsets.add(reader.readUint16());
    }
    final List<FeatureEntry> features = <FeatureEntry>[];
    for (int i = 0; i < count; i++) {
      final FontReader feature =
          data.readerAt(offset + offsets[i], table: table);
      feature.skip(2); // featureParamsOffset - only `size` and `cv01` use it
      final int lookupCount = feature.readUint16();
      features.add(FeatureEntry(tags[i], feature.readUint16List(lookupCount)));
    }
    return FeatureList(features);
  }
}

/// One lookup: a type, the flags that say what it steps over, and where its
/// subtables are.
final class Lookup {
  const Lookup({
    required this.type,
    required this.flags,
    required this.subtableOffsets,
    required this.markFilteringSet,
  });

  /// What the subtables are. Meaning depends on the table: type 4 is a
  /// ligature substitution in `GSUB` and a mark-to-base attachment in `GPOS`.
  final int type;

  final int flags;

  /// Absolute offsets into the font.
  final List<int> subtableOffsets;

  /// Index into `GDEF`'s mark glyph sets, when [useMarkFilteringSet].
  final int markFilteringSet;

  static const int flagRightToLeft = 0x0001;
  static const int flagIgnoreBaseGlyphs = 0x0002;
  static const int flagIgnoreLigatures = 0x0004;
  static const int flagIgnoreMarks = 0x0008;
  static const int flagUseMarkFilteringSet = 0x0010;
  static const int markAttachmentTypeMask = 0xFF00;

  bool get ignoreBaseGlyphs => flags & flagIgnoreBaseGlyphs != 0;
  bool get ignoreLigatures => flags & flagIgnoreLigatures != 0;
  bool get ignoreMarks => flags & flagIgnoreMarks != 0;
  bool get useMarkFilteringSet => flags & flagUseMarkFilteringSet != 0;

  /// Zero, or the one mark attachment class this lookup does *not* skip.
  int get markAttachmentType => (flags & markAttachmentTypeMask) >> 8;
}

/// Every lookup in the table, addressed by index.
final class LookupList {
  const LookupList(this.lookups);

  final List<Lookup> lookups;

  int get length => lookups.length;

  static LookupList parse(FontData data, int offset, {String? table}) {
    final FontReader reader = data.readerAt(offset, table: table);
    final int count = reader.readUint16();
    final Uint16List offsets = reader.readUint16List(count);
    final List<Lookup> lookups = <Lookup>[];
    for (int i = 0; i < count; i++) {
      final int lookupOffset = offset + offsets[i];
      final FontReader lookup = data.readerAt(lookupOffset, table: table);
      final int type = lookup.readUint16();
      final int flags = lookup.readUint16();
      final int subtableCount = lookup.readUint16();
      final Uint16List subtables = lookup.readUint16List(subtableCount);
      final int filteringSet =
          flags & Lookup.flagUseMarkFilteringSet != 0 ? lookup.readUint16() : 0;
      lookups.add(Lookup(
        type: type,
        flags: flags,
        subtableOffsets: <int>[
          for (final int sub in subtables) lookupOffset + sub,
        ],
        markFilteringSet: filteringSet,
      ));
    }
    return LookupList(lookups);
  }
}

/// The header both `GSUB` and `GPOS` open with.
///
/// Version 1.1 adds a feature-variations offset, used by variable fonts to
/// swap rules at particular design coordinates. It is read past rather than
/// honoured: this framework has no variable-font axis support, so the default
/// instance's rules are the only correct ones to apply.
final class LayoutHeader {
  const LayoutHeader({
    required this.data,
    required this.offset,
    required this.tag,
    required this.scriptList,
    required this.featureList,
    required this.lookupList,
  });

  final FontData data;

  /// Where the table starts, which every offset inside it is relative to.
  final int offset;

  /// `GSUB` or `GPOS`, for error messages.
  final String tag;

  final ScriptList scriptList;
  final FeatureList featureList;
  final LookupList lookupList;

  static LayoutHeader parse(FontData data, int offset, String tag) {
    final FontReader reader = data.readerAt(offset, table: tag);
    final int major = reader.readUint16();
    final int minor = reader.readUint16();
    if (major != 1) {
      throw FontFormatException(
        'version $major.$minor is not a layout table version',
        offset: offset,
        table: tag,
      );
    }
    final int scriptOffset = reader.readUint16();
    final int featureOffset = reader.readUint16();
    final int lookupOffset = reader.readUint16();
    return LayoutHeader(
      data: data,
      offset: offset,
      tag: tag,
      scriptList: scriptOffset == 0
          ? const ScriptList(<String, ScriptTable>{})
          : ScriptList.parse(data, offset + scriptOffset, table: tag),
      featureList: featureOffset == 0
          ? const FeatureList(<FeatureEntry>[])
          : FeatureList.parse(data, offset + featureOffset, table: tag),
      lookupList: lookupOffset == 0
          ? const LookupList(<Lookup>[])
          : LookupList.parse(data, offset + lookupOffset, table: tag),
    );
  }

  /// The feature indices [script] and [language] select.
  List<int> _featureIndices(String script, String? language) {
    final ScriptTable? table = scriptList.resolve(script);
    final LangSys? langSys = table?.forLanguage(language);
    if (langSys == null) return const <int>[];
    return <int>[
      if (langSys.requiredFeatureIndex != _none) langSys.requiredFeatureIndex,
      ...langSys.featureIndices,
    ];
  }

  /// Whether [tag] is a feature this table offers for [script].
  ///
  /// The question the legacy `kern` table's fate hangs on: a font whose `GPOS`
  /// answers yes here must not also be kerned from `kern`, or every kerned
  /// pair moves twice.
  bool hasFeature(String featureTag,
      {String script = 'latn', String? language}) {
    for (final int index in _featureIndices(script, language)) {
      if (index >= featureList.features.length) continue;
      if (featureList.features[index].tag == featureTag) return true;
    }
    return false;
  }

  /// The lookups that [features] select, in the order they must be applied.
  ///
  /// Ascending lookup index, not feature order. The spec fixes it: a lookup's
  /// index *is* its priority, and two features that share a lookup must not
  /// run it twice. Sorting here is what makes "apply the enabled features"
  /// well-defined regardless of what order the caller listed them in.
  List<int> lookupsFor(
    Set<String> features, {
    String script = 'latn',
    String? language,
  }) {
    final Set<int> selected = <int>{};
    for (final int index in _featureIndices(script, language)) {
      if (index >= featureList.features.length) continue;
      final FeatureEntry entry = featureList.features[index];
      if (!features.contains(entry.tag)) continue;
      for (final int lookup in entry.lookupIndices) {
        if (lookup < lookupList.length) selected.add(lookup);
      }
    }
    return selected.toList()..sort();
  }
}

/// A memo over things parsed at a fixed offset.
///
/// [Coverage] and [ClassDef] are read once per glyph per subtable during
/// shaping; re-parsing them each time turns a binary search into a binary
/// search plus a table decode. Keyed by absolute offset because that is what
/// identifies them - two subtables sharing a coverage table, which fonts do
/// constantly, then share the parsed one too.
final class OffsetCache {
  OffsetCache(this.data, this.tag);

  final FontData data;
  final String tag;

  final Map<int, Coverage> _coverages = <int, Coverage>{};
  final Map<int, ClassDef> _classes = <int, ClassDef>{};

  Coverage coverage(int offset) => _coverages.putIfAbsent(
      offset, () => Coverage.parse(data, offset, table: tag));

  /// The class definition [relative] bytes past [base].
  ///
  /// Split into base and relative because a relative offset of zero is the
  /// file's way of writing "no table, everything is class 0". Adding it to the
  /// base first would produce the subtable's own address and then decode the
  /// subtable header as a class definition, which is the kind of bug that
  /// yields plausible garbage rather than an error.
  ClassDef classDef(int base, int relative) => relative == 0
      ? ClassDef.empty
      : _classes.putIfAbsent(base + relative,
          () => ClassDef.parse(data, base + relative, table: tag));
}

/// `GDEF` - what kind of thing each glyph is.
///
/// Substitution and positioning both need to step over glyphs that are not
/// their business: a kerning pair must see through an intervening accent, and
/// an accent must find the letter it belongs to rather than the accent before
/// it. Neither is possible from glyph ids alone, so `GDEF` labels every glyph
/// as a base, a ligature, a mark or a ligature component.
///
/// A font without `GDEF` gets [ClassDef.empty], which reports every glyph as
/// class 0 - "unclassified". That is deliberately *not* the same as "base":
/// mark attachment then finds no marks and does nothing, which is the correct
/// outcome for a font that never told anyone which glyphs are marks. HarfBuzz
/// synthesises the classes from Unicode character properties in that case;
/// doing the same here needs the Unicode general-category data that section 30
/// owns, and until it exists this is the honest behaviour rather than a guess.
final class GdefTable {
  const GdefTable({
    required this.glyphClasses,
    required this.markAttachClasses,
    required this.markGlyphSets,
  });

  /// Glyph classes, from the [classBase] .. [classComponent] constants.
  final ClassDef glyphClasses;

  /// Which mark attachment class each mark belongs to, for lookup flags that
  /// skip all marks but one class.
  final ClassDef markAttachClasses;

  /// Coverage tables a lookup may name to skip everything outside one set.
  final List<Coverage> markGlyphSets;

  static const int classBase = 1;
  static const int classLigature = 2;
  static const int classMark = 3;
  static const int classComponent = 4;

  int classOf(int glyph) => glyphClasses.classOf(glyph);

  bool isMark(int glyph) => glyphClasses.classOf(glyph) == classMark;

  bool isBase(int glyph) => glyphClasses.classOf(glyph) == classBase;

  bool isLigature(int glyph) => glyphClasses.classOf(glyph) == classLigature;

  /// Parses `GDEF`, or returns null when the font has none.
  static GdefTable? parse(SfntFile file) {
    final TableRecord? record = file.tableRecord('GDEF');
    if (record == null) return null;
    final FontData data = file.data;
    final int base = record.offset;
    final FontReader reader = data.readerAt(base, table: 'GDEF');
    final int major = reader.readUint16();
    final int minor = reader.readUint16();
    if (major != 1) {
      throw FontFormatException(
        'version $major.$minor is not a GDEF version',
        offset: base,
        table: 'GDEF',
      );
    }
    final int glyphClassOffset = reader.readUint16();
    reader.skip(2); // attachListOffset - caret positions for cursor placement
    reader.skip(2); // ligCaretListOffset - the same, inside a ligature
    final int markAttachOffset = reader.readUint16();
    // 1.2 added mark glyph sets; 1.3 added the variation store. Reading the
    // offset only when the minor version promises it is the difference between
    // an optional field and four bytes of whatever follows the header.
    final int markGlyphSetsOffset = minor >= 2 ? reader.readUint16() : 0;

    final List<Coverage> sets = <Coverage>[];
    if (markGlyphSetsOffset != 0) {
      final int setsBase = base + markGlyphSetsOffset;
      final FontReader setsReader = data.readerAt(setsBase, table: 'GDEF');
      final int format = setsReader.readUint16();
      if (format == 1) {
        final int count = setsReader.readUint16();
        final List<int> offsets = <int>[
          for (int i = 0; i < count; i++) setsReader.readUint32(),
        ];
        for (final int offset in offsets) {
          if (offset == 0) continue;
          sets.add(Coverage.parse(data, setsBase + offset, table: 'GDEF'));
        }
      }
    }

    return GdefTable(
      glyphClasses: ClassDef.parse(
        data,
        glyphClassOffset == 0 ? 0 : base + glyphClassOffset,
        table: 'GDEF',
      ),
      markAttachClasses: ClassDef.parse(
        data,
        markAttachOffset == 0 ? 0 : base + markAttachOffset,
        table: 'GDEF',
      ),
      markGlyphSets: sets,
    );
  }
}

/// Which glyphs one lookup is allowed to see.
///
/// A lookup declares what it steps over, and the whole of contextual matching
/// depends on it: the `kern` pair "A V" must still match when a combining
/// accent sits between them, because the lookup that kerns says it ignores
/// marks. A filter that ignored the flags would leave such text unkerned and
/// the failure would look like a missing kern pair rather than a missing
/// feature.
final class GlyphFilter {
  GlyphFilter(this.lookup, this.gdef)
      : _markSet = lookup.useMarkFilteringSet &&
                gdef != null &&
                lookup.markFilteringSet < gdef.markGlyphSets.length
            ? gdef.markGlyphSets[lookup.markFilteringSet]
            : null;

  /// A filter that hides marks and nothing else.
  ///
  /// Mark attachment searches backwards for its base with exactly this rule,
  /// regardless of what the lookup's own flags say - otherwise the second
  /// accent of a stack would attach to the first accent instead of to the
  /// letter.
  static final GlyphFilter marksOnly = GlyphFilter(
    const Lookup(
      type: 0,
      flags: Lookup.flagIgnoreMarks,
      subtableOffsets: <int>[],
      markFilteringSet: 0,
    ),
    null,
  );

  final Lookup lookup;
  final GdefTable? gdef;
  final Coverage? _markSet;

  /// Whether a lookup applying at some position must step over [glyph].
  bool skips(int glyph) {
    final GdefTable? gdef = this.gdef;
    // Every rule below turns on a glyph's class, and without `GDEF` no glyph
    // has one. Nothing is skipped, which also means nothing is found to be a
    // mark - a font with mark lookups and no `GDEF` gets no mark attachment,
    // and that is stated in [GdefTable].
    if (gdef == null) return false;
    final int glyphClass = gdef.classOf(glyph);
    if (lookup.ignoreMarks && glyphClass == GdefTable.classMark) return true;
    if (lookup.ignoreBaseGlyphs && glyphClass == GdefTable.classBase) {
      return true;
    }
    if (lookup.ignoreLigatures && glyphClass == GdefTable.classLigature) {
      return true;
    }
    if (glyphClass == GdefTable.classMark) {
      final Coverage? set = _markSet;
      if (set != null && !set.covers(glyph)) return true;
      final int type = lookup.markAttachmentType;
      if (type != 0 && gdef.markAttachClasses.classOf(glyph) != type) {
        return true;
      }
    }
    return false;
  }

  /// This filter with [gdef] attached, for the two static filters above.
  GlyphFilter withGdef(GdefTable? gdef) =>
      identical(gdef, this.gdef) ? this : GlyphFilter(lookup, gdef);
}

/// The glyphs being shaped, while they are still being changed.
///
/// [GlyphRun] is the *result* of shaping and is immutable and struct-of-arrays
/// for the encoder's benefit. This is the working state, and it is a different
/// shape because the work is different: substitution inserts and deletes, so
/// the arrays grow and shrink, and positioning accumulates four independent
/// quantities per glyph that only collapse into one x,y pair at the very end.
///
/// One buffer is reused across runs by the shaper that owns it.
final class GlyphBuffer {
  GlyphBuffer();

  final List<int> glyphs = <int>[];

  /// The UTF-16 index in the source string each glyph came from.
  ///
  /// Merged, not discarded, when glyphs combine: a ligature carries the
  /// *lowest* index of its components, and every source index between that and
  /// the next glyph's index belongs to it. That is what lets a caret land
  /// between "f" and "i" inside an "fi" ligature instead of jumping the pair.
  final List<int> clusters = <int>[];

  /// Advance per glyph, in font units, before positioning.
  final List<double> xAdvances = <double>[];
  final List<double> yAdvances = <double>[];

  /// Displacement from the pen position, in font units.
  final List<double> xOffsets = <double>[];
  final List<double> yOffsets = <double>[];

  /// For an attached mark, the index of the glyph it hangs off; -1 otherwise.
  ///
  /// Recorded rather than resolved on the spot, because the base has not
  /// finished moving: a kerning lookup with a higher index than the mark
  /// lookup will still shift it, and a mark resolved early would be left
  /// behind. See [resolveAttachments].
  final List<int> attachedTo = <int>[];

  int get length => glyphs.length;

  bool get isEmpty => glyphs.isEmpty;

  void clear() {
    glyphs.clear();
    clusters.clear();
    xAdvances.clear();
    yAdvances.clear();
    xOffsets.clear();
    yOffsets.clear();
    attachedTo.clear();
  }

  /// Appends a glyph with no positioning yet.
  void add(int glyph, int cluster) {
    glyphs.add(glyph);
    clusters.add(cluster);
    xAdvances.add(0);
    yAdvances.add(0);
    xOffsets.add(0);
    yOffsets.add(0);
    attachedTo.add(-1);
  }

  /// Replaces the glyph at [index], keeping its cluster.
  void substitute(int index, int glyph) => glyphs[index] = glyph;

  /// Replaces the glyph at [index] with [replacements], all in its cluster.
  void expand(int index, List<int> replacements) {
    if (replacements.isEmpty) {
      _removeAt(index);
      return;
    }
    glyphs[index] = replacements[0];
    final int cluster = clusters[index];
    for (int i = 1; i < replacements.length; i++) {
      glyphs.insert(index + i, replacements[i]);
      clusters.insert(index + i, cluster);
      xAdvances.insert(index + i, 0);
      yAdvances.insert(index + i, 0);
      xOffsets.insert(index + i, 0);
      yOffsets.insert(index + i, 0);
      attachedTo.insert(index + i, -1);
    }
  }

  /// Merges the glyphs at [positions] into one glyph, at the first position.
  ///
  /// [positions] need not be contiguous: a lookup that ignores marks matches
  /// "f", "i" across an accent between them, and the accent must survive. It
  /// does, by staying where it is while the components around it are deleted -
  /// which also leaves it *after* the ligature, where a mark on a ligature
  /// belongs.
  void ligate(List<int> positions, int ligature) {
    final int first = positions.first;
    final int last = positions.last;
    int cluster = clusters[first];
    for (final int position in positions) {
      if (clusters[position] < cluster) cluster = clusters[position];
    }
    glyphs[first] = ligature;
    // Everything between the outermost components is now one indivisible unit
    // of text, so it is one cluster. Leaving the intermediate marks with their
    // own cluster indices would offer a caret position inside a glyph.
    for (int i = first; i <= last; i++) {
      clusters[i] = cluster;
    }
    for (int i = positions.length - 1; i >= 1; i--) {
      _removeAt(positions[i]);
    }
  }

  void _removeAt(int index) {
    glyphs.removeAt(index);
    clusters.removeAt(index);
    xAdvances.removeAt(index);
    yAdvances.removeAt(index);
    xOffsets.removeAt(index);
    yOffsets.removeAt(index);
    attachedTo.removeAt(index);
  }

  /// The next position at or after [index] that [filter] does not hide.
  int nextVisible(int index, GlyphFilter filter) {
    for (int i = index; i < glyphs.length; i++) {
      if (!filter.skips(glyphs[i])) return i;
    }
    return -1;
  }

  /// The previous position at or before [index] that [filter] does not hide.
  int previousVisible(int index, GlyphFilter filter) {
    for (int i = index; i >= 0; i--) {
      if (!filter.skips(glyphs[i])) return i;
    }
    return -1;
  }

  /// Turns every recorded attachment into an absolute offset.
  ///
  /// A mark's offset is stored relative to the glyph it attaches to, because
  /// that is the only thing that is stable while lookups are still running.
  /// Converting it costs two corrections: the base's own offset, and the
  /// advances that separate the two glyphs - the mark is drawn at the pen,
  /// which has already moved past the base by the time it gets there.
  ///
  /// Order matters. Marks are resolved front to back so that a mark attached
  /// to a mark reads a base that is already absolute, which is what makes a
  /// stack of two accents sit above one another instead of both above the
  /// letter.
  void resolveAttachments({bool rightToLeft = false}) {
    for (int i = 0; i < glyphs.length; i++) {
      final int base = attachedTo[i];
      if (base < 0) continue;
      xOffsets[i] += xOffsets[base];
      yOffsets[i] += yOffsets[base];
      if (!rightToLeft) {
        for (int k = base; k < i; k++) {
          xOffsets[i] -= xAdvances[k];
          yOffsets[i] -= yAdvances[k];
        }
      } else {
        for (int k = base + 1; k <= i; k++) {
          xOffsets[i] += xAdvances[k];
          yOffsets[i] += yAdvances[k];
        }
      }
      attachedTo[i] = -1;
    }
  }

  /// Reverses the run, for right-to-left output.
  ///
  /// Substitution and positioning both run in logical order - that is the
  /// order the rules are written in, and an Arabic font's contextual rules
  /// would match backwards otherwise. Visual order is produced once, here, at
  /// the end, which is also why [resolveAttachments] must have run first.
  void reverse() {
    _reverseInts(glyphs);
    _reverseInts(clusters);
    _reverseInts(attachedTo);
    _reverseDoubles(xAdvances);
    _reverseDoubles(yAdvances);
    _reverseDoubles(xOffsets);
    _reverseDoubles(yOffsets);
  }

  static void _reverseInts(List<int> values) {
    for (int i = 0, j = values.length - 1; i < j; i++, j--) {
      final int tmp = values[i];
      values[i] = values[j];
      values[j] = tmp;
    }
  }

  static void _reverseDoubles(List<double> values) {
    for (int i = 0, j = values.length - 1; i < j; i++, j--) {
      final double tmp = values[i];
      values[i] = values[j];
      values[j] = tmp;
    }
  }
}

/// One "then run lookup L at position P" instruction inside a context rule.
final class SequenceLookupRecord {
  const SequenceLookupRecord(this.sequenceIndex, this.lookupIndex);

  /// Which of the matched input glyphs to apply the lookup at, counted in
  /// matched positions rather than buffer positions - the two differ whenever
  /// the rule stepped over something.
  final int sequenceIndex;

  final int lookupIndex;
}

/// Reads [count] sequence lookup records from [reader].
List<SequenceLookupRecord> readSequenceLookups(FontReader reader, int count) {
  final List<SequenceLookupRecord> records = <SequenceLookupRecord>[];
  for (int i = 0; i < count; i++) {
    final int sequenceIndex = reader.readUint16();
    final int lookupIndex = reader.readUint16();
    records.add(SequenceLookupRecord(sequenceIndex, lookupIndex));
  }
  return records;
}

/// Tests a glyph against one element of a context rule.
typedef GlyphMatcher = bool Function(int element, int glyph);

/// The buffer positions matched by an input sequence starting at [start].
///
/// Returns null when the sequence does not match. Position 0 is [start]
/// itself; the rest are found by stepping forward over whatever [filter]
/// hides, which is what makes "f i" match across an intervening accent.
List<int>? matchInput(
  GlyphBuffer buffer,
  GlyphFilter filter,
  int start,
  int count,
  GlyphMatcher matches,
) {
  final List<int> positions = <int>[start];
  if (count <= 1) return positions;
  int at = start;
  for (int element = 1; element < count; element++) {
    at = buffer.nextVisible(at + 1, filter);
    if (at < 0) return null;
    if (!matches(element, buffer.glyphs[at])) return null;
    positions.add(at);
  }
  return positions;
}

/// Whether [count] elements match going backwards from just before [start].
///
/// Backtrack sequences are written *nearest-first* in the file - element 0 is
/// the glyph immediately before the input - which is the opposite of how they
/// read on the page, and getting it backwards produces a rule that almost
/// never fires.
bool matchBacktrack(
  GlyphBuffer buffer,
  GlyphFilter filter,
  int start,
  int count,
  GlyphMatcher matches,
) {
  int at = start - 1;
  for (int element = 0; element < count; element++) {
    at = buffer.previousVisible(at, filter);
    if (at < 0) return false;
    if (!matches(element, buffer.glyphs[at])) return false;
    at--;
  }
  return true;
}

/// Whether [count] elements match going forwards from just after [start].
bool matchLookahead(
  GlyphBuffer buffer,
  GlyphFilter filter,
  int start,
  int count,
  GlyphMatcher matches,
) {
  int at = start + 1;
  for (int element = 0; element < count; element++) {
    at = buffer.nextVisible(at, filter);
    if (at < 0) return false;
    if (!matches(element, buffer.glyphs[at])) return false;
    at++;
  }
  return true;
}
