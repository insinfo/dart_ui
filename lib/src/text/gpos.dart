/// `GPOS` - the table that moves glyphs without changing them.
///
/// Positioning is the other half of OpenType layout. It adjusts advances and
/// it displaces glyphs, and the two things it is most needed for are kerning
/// and mark attachment.
///
/// **Kerning** here supersedes the legacy `kern` table. A font that has both
/// must be kerned from `GPOS` only: the two describe the same adjustments, so
/// applying both moves every kerned pair twice, and the result is text that is
/// visibly too tight in exactly the places the designer cared about. The rule
/// is HarfBuzz's, observed rather than copied, and it is enforced in
/// `shaper.dart` where both tables are in scope - see [GposTable.hasFeature].
///
/// **Mark attachment** is what makes decomposed text work at all. "a" followed
/// by U+0301 COMBINING ACUTE ACCENT is two glyphs, the second of which has a
/// zero advance and an outline that sits at the origin. Nothing places it over
/// the letter except a `GPOS` anchor pair, and without one the accent lands on
/// the left edge of the following character.
///
/// ## What is implemented
///
/// * **Type 1**, single adjustment, both formats.
/// * **Type 2**, pair adjustment, both formats - modern kerning.
/// * **Type 4**, mark-to-base - an accent onto a letter.
/// * **Type 6**, mark-to-mark - an accent onto an accent, which is what makes
///   a stack of two come out stacked instead of superimposed.
/// * **Types 7 and 8**, context and chained context positioning.
/// * **Type 9**, extension, for the same reason `GSUB` needs type 7.
///
/// Not implemented, and each absence is a script rather than a detail:
///
/// * **Type 3**, cursive attachment. Joins the exit of one glyph to the entry
///   of the next, which is how Arabic and Nastaliq keep a connected baseline.
///   A font that needs it needs an Arabic shaper, which does not exist here.
/// * **Type 5**, mark-to-ligature. Places a mark on one *component* of a
///   ligature, which requires the shaper to remember which component of which
///   ligature each mark belonged to - state that ligature substitution would
///   have to record. Marks on ligatures currently fall through to
///   mark-to-base, which attaches them to the ligature as a whole.
///
/// ## Device tables are read past, not applied
///
/// Value records and anchors may carry device tables: per-ppem integer nudges
/// for hinted rendering at small sizes. They are stepped over rather than
/// honoured, because applying them requires committing to an integer pixel
/// size before layout, and this framework positions in font units and scales
/// once at the end. The error is at most one pixel and only below about 20 px.
library;

import 'dart:typed_data';

import 'font_data.dart';
import 'layout_common.dart';
import 'sfnt.dart';

export 'layout_common.dart' show GdefTable;

/// How deep a context rule may call another context rule.
const int _maxRecursionDepth = 8;

/// An anchor point, in font units.
typedef _Anchor = ({int x, int y});

/// The glyph positioning table.
final class GposTable {
  GposTable._(this.header, this._cache);

  final LayoutHeader header;
  final OffsetCache _cache;

  /// Parses `GPOS`, or returns null when the font has none.
  static GposTable? parse(SfntFile file) {
    final TableRecord? record = file.tableRecord('GPOS');
    if (record == null) return null;
    return GposTable.at(file.data, record.offset);
  }

  /// Parses a `GPOS` table that begins at [offset] in [data].
  static GposTable at(FontData data, int offset) => GposTable._(
      LayoutHeader.parse(data, offset, 'GPOS'), OffsetCache(data, 'GPOS'));

  FontData get _data => header.data;

  /// Whether [tag] is offered for [script].
  ///
  /// Asked of `kern` before the legacy table is even parsed: this answering
  /// yes is what disqualifies `kern`.
  bool hasFeature(String tag, {String script = 'latn', String? language}) =>
      header.hasFeature(tag, script: script, language: language);

  /// Applies every lookup that [features] select, in lookup-index order.
  ///
  /// [buffer] must already hold each glyph's unadjusted advance; `GPOS` states
  /// adjustments, not absolutes, and a subtable that only sets an advance for
  /// the pairs it knows about would otherwise zero every other glyph.
  void apply(
    GlyphBuffer buffer, {
    required Set<String> features,
    String script = 'latn',
    String? language,
    GdefTable? gdef,
  }) {
    final List<int> lookups =
        header.lookupsFor(features, script: script, language: language);
    for (final int index in lookups) {
      _runLookup(index, buffer, gdef);
    }
  }

  void _runLookup(int lookupIndex, GlyphBuffer buffer, GdefTable? gdef) {
    final Lookup lookup = header.lookupList.lookups[lookupIndex];
    final GlyphFilter filter = GlyphFilter(lookup, gdef);
    int index = 0;
    while (index < buffer.length) {
      if (!filter.skips(buffer.glyphs[index])) {
        final int next = _applyLookup(lookup, filter, buffer, index, gdef, 0);
        if (next > index) {
          index = next;
          continue;
        }
      }
      index++;
    }
  }

  int _applyLookup(
    Lookup lookup,
    GlyphFilter filter,
    GlyphBuffer buffer,
    int index,
    GdefTable? gdef,
    int depth,
  ) {
    final int glyph = buffer.glyphs[index];
    for (final int offset in lookup.subtableOffsets) {
      // The early-out that keeps mark attachment cheap: on a run of letters,
      // every glyph misses the mark coverage, and answering that from a cached
      // coverage costs a binary search instead of a subtable header decode.
      final Coverage? coverage = _leadingCoverage(lookup.type, offset);
      if (coverage != null && !coverage.covers(glyph)) continue;
      final int next = _applySubtable(
          lookup.type, offset, lookup, filter, buffer, index, gdef, depth);
      if (next > index) return next;
    }
    return -1;
  }

  /// The coverage a subtable rejects on, memoised by subtable offset.
  ///
  /// Null means "no single leading coverage", and the subtable is decoded as
  /// before - the safe answer, since a wrong "not covered" would silently
  /// disable a feature rather than fail.
  Coverage? _leadingCoverage(int type, int offset) =>
      _leading.putIfAbsent(offset, () => _readLeadingCoverage(type, offset));

  final Map<int, Coverage?> _leading = <int, Coverage?>{};

  Coverage? _readLeadingCoverage(int type, int offset) {
    final FontReader reader = _data.readerAt(offset, table: 'GPOS');
    switch (type) {
      // Types 4 and 6 lead with the *mark* coverage, which is the one the
      // cursor sits on when they apply.
      case 1:
      case 2:
      case 4:
      case 6:
        reader.skip(2); // positioning format
        return _cache.coverage(offset + reader.readUint16());
      case 7:
      case 8:
        final int format = reader.readUint16();
        if (format == 1 || format == 2) {
          return _cache.coverage(offset + reader.readUint16());
        }
        if (format != 3) return null;
        if (type == 7) {
          final int glyphCount = reader.readUint16();
          if (glyphCount == 0) return null;
          reader.skip(2); // seqLookupCount
          return _cache.coverage(offset + reader.readUint16());
        }
        reader.skip(reader.readUint16() * 2); // the backtrack sequence
        final int inputCount = reader.readUint16();
        if (inputCount == 0) return null;
        return _cache.coverage(offset + reader.readUint16());
      case 9:
        reader.skip(2); // extension format
        final int extensionType = reader.readUint16();
        final int extensionOffset = reader.readUint32();
        if (extensionType == 9) return null;
        return _readLeadingCoverage(extensionType, offset + extensionOffset);
      default:
        return null;
    }
  }

  int _applySubtable(
    int type,
    int offset,
    Lookup lookup,
    GlyphFilter filter,
    GlyphBuffer buffer,
    int index,
    GdefTable? gdef,
    int depth,
  ) {
    switch (type) {
      case 1:
        return _single(offset, buffer, index);
      case 2:
        return _pair(offset, filter, buffer, index);
      case 4:
        return _markToBase(offset, buffer, index, gdef);
      case 6:
        return _markToMark(offset, lookup, buffer, index, gdef);
      case 7:
        return _context(offset, filter, buffer, index, gdef, depth);
      case 8:
        return _chainContext(offset, filter, buffer, index, gdef, depth);
      case 9:
        return _extension(offset, lookup, filter, buffer, index, gdef, depth);
      default:
        // Types 3 and 5, and anything a later revision adds. The spec's own
        // instruction for an unrecognised type is to skip it.
        return -1;
    }
  }

  /// Type 9: a type and a 32-bit offset standing in for a real subtable.
  int _extension(
    int offset,
    Lookup lookup,
    GlyphFilter filter,
    GlyphBuffer buffer,
    int index,
    GdefTable? gdef,
    int depth,
  ) {
    final FontReader reader = _data.readerAt(offset, table: 'GPOS');
    final int format = reader.readUint16();
    if (format != 1) {
      throw FontFormatException(
        'extension subtable format $format is not defined',
        offset: offset,
        table: 'GPOS',
      );
    }
    final int extensionType = reader.readUint16();
    final int extensionOffset = reader.readUint32();
    if (extensionType == 9) {
      throw FontFormatException(
        'an extension subtable may not wrap another',
        offset: offset,
        table: 'GPOS',
      );
    }
    return _applySubtable(extensionType, offset + extensionOffset, lookup,
        filter, buffer, index, gdef, depth);
  }

  /// Type 1: one adjustment for every glyph in a coverage.
  int _single(int offset, GlyphBuffer buffer, int index) {
    final FontReader reader = _data.readerAt(offset, table: 'GPOS');
    final int format = reader.readUint16();
    final int coverageOffset = reader.readUint16();
    final int coverageIndex =
        _cache.coverage(offset + coverageOffset).indexOf(buffer.glyphs[index]);
    if (coverageIndex < 0) return -1;
    final int valueFormat = reader.readUint16();
    switch (format) {
      case 1:
        _applyValue(reader, valueFormat, buffer, index);
        return index + 1;
      case 2:
        final int count = reader.readUint16();
        if (coverageIndex >= count) return -1;
        reader.skip(coverageIndex * _valueSize(valueFormat));
        _applyValue(reader, valueFormat, buffer, index);
        return index + 1;
      default:
        throw FontFormatException(
          'single positioning format $format is not defined',
          offset: offset,
          table: 'GPOS',
        );
    }
  }

  /// Type 2: an adjustment for a specific pair. Modern kerning.
  int _pair(
    int offset,
    GlyphFilter filter,
    GlyphBuffer buffer,
    int index,
  ) {
    final int second = buffer.nextVisible(index + 1, filter);
    if (second < 0) return -1;

    final FontReader reader = _data.readerAt(offset, table: 'GPOS');
    final int format = reader.readUint16();
    final int coverageOffset = reader.readUint16();
    final int coverageIndex =
        _cache.coverage(offset + coverageOffset).indexOf(buffer.glyphs[index]);
    if (coverageIndex < 0) return -1;
    final int valueFormat1 = reader.readUint16();
    final int valueFormat2 = reader.readUint16();
    final int size1 = _valueSize(valueFormat1);
    final int size2 = _valueSize(valueFormat2);

    switch (format) {
      case 1:
        final int setCount = reader.readUint16();
        if (coverageIndex >= setCount) return -1;
        reader.skip(coverageIndex * 2);
        final int setOffset = offset + reader.readUint16();
        final FontReader set = _data.readerAt(setOffset, table: 'GPOS');
        final int pairCount = set.readUint16();
        final int recordSize = 2 + size1 + size2;
        final int recordsAt = set.offset;
        // Binary search: the format requires the records to be ordered by the
        // second glyph, and a linear scan here would be O(pairs) per glyph on
        // a font whose densest pair set has hundreds of entries.
        final int target = buffer.glyphs[second];
        int low = 0;
        int high = pairCount - 1;
        while (low <= high) {
          final int mid = (low + high) >> 1;
          final FontReader record =
              _data.readerAt(recordsAt + mid * recordSize, table: 'GPOS');
          final int glyph = record.readUint16();
          if (glyph == target) {
            _applyValue(record, valueFormat1, buffer, index);
            _applyValue(record, valueFormat2, buffer, second);
            // A second value record means the second glyph was adjusted too,
            // so it must not be reconsidered as the first glyph of the next
            // pair; with no second value it may be, and fonts rely on that to
            // chain adjustments across a run.
            return size2 == 0 ? second : second + 1;
          }
          if (glyph < target) {
            low = mid + 1;
          } else {
            high = mid - 1;
          }
        }
        return -1;
      case 2:
        final ClassDef first = _cache.classDef(offset, reader.readUint16());
        final ClassDef next = _cache.classDef(offset, reader.readUint16());
        final int class1Count = reader.readUint16();
        final int class2Count = reader.readUint16();
        final int class1 = first.classOf(buffer.glyphs[index]);
        final int class2 = next.classOf(buffer.glyphs[second]);
        if (class1 >= class1Count || class2 >= class2Count) return -1;
        reader.skip((class1 * class2Count + class2) * (size1 + size2));
        _applyValue(reader, valueFormat1, buffer, index);
        _applyValue(reader, valueFormat2, buffer, second);
        return size2 == 0 ? second : second + 1;
      default:
        throw FontFormatException(
          'pair positioning format $format is not defined',
          offset: offset,
          table: 'GPOS',
        );
    }
  }

  /// Type 4: a mark's anchor onto a base glyph's anchor.
  ///
  /// The base is found by searching backwards for the nearest glyph that is
  /// not a mark, whatever the lookup's own flags say. That is not the flags
  /// being ignored - it is the definition of "base" for this subtable, and a
  /// search that honoured a lookup which does not ignore marks would attach
  /// the second accent of a stack to the first accent.
  int _markToBase(
    int offset,
    GlyphBuffer buffer,
    int index,
    GdefTable? gdef,
  ) {
    final FontReader reader = _data.readerAt(offset, table: 'GPOS');
    final int format = reader.readUint16();
    if (format != 1) {
      throw FontFormatException(
        'mark-to-base format $format is not defined',
        offset: offset,
        table: 'GPOS',
      );
    }
    final int markCoverageOffset = reader.readUint16();
    final int baseCoverageOffset = reader.readUint16();
    final int markClassCount = reader.readUint16();
    final int markArrayOffset = reader.readUint16();
    final int baseArrayOffset = reader.readUint16();

    final int markIndex = _cache
        .coverage(offset + markCoverageOffset)
        .indexOf(buffer.glyphs[index]);
    if (markIndex < 0) return -1;

    final int base =
        buffer.previousVisible(index - 1, GlyphFilter.marksOnly.withGdef(gdef));
    if (base < 0) return -1;
    final int baseIndex = _cache
        .coverage(offset + baseCoverageOffset)
        .indexOf(buffer.glyphs[base]);
    if (baseIndex < 0) return -1;

    final (int markClass, _Anchor? markAnchor) =
        _markRecord(offset + markArrayOffset, markIndex);
    if (markAnchor == null || markClass >= markClassCount) return -1;

    final _Anchor? baseAnchor = _anchorFromArray(
      offset + baseArrayOffset,
      baseIndex,
      markClass,
      markClassCount,
    );
    if (baseAnchor == null) return -1;

    _attach(buffer, index, base, baseAnchor, markAnchor);
    return index + 1;
  }

  /// Type 6: a mark's anchor onto another mark's anchor.
  int _markToMark(
    int offset,
    Lookup lookup,
    GlyphBuffer buffer,
    int index,
    GdefTable? gdef,
  ) {
    final FontReader reader = _data.readerAt(offset, table: 'GPOS');
    final int format = reader.readUint16();
    if (format != 1) {
      throw FontFormatException(
        'mark-to-mark format $format is not defined',
        offset: offset,
        table: 'GPOS',
      );
    }
    final int mark1CoverageOffset = reader.readUint16();
    final int mark2CoverageOffset = reader.readUint16();
    final int markClassCount = reader.readUint16();
    final int mark1ArrayOffset = reader.readUint16();
    final int mark2ArrayOffset = reader.readUint16();

    final int markIndex = _cache
        .coverage(offset + mark1CoverageOffset)
        .indexOf(buffer.glyphs[index]);
    if (markIndex < 0) return -1;

    // The glyph this one stacks on is simply the previous one, filtered only
    // by the lookup's mark-attachment class - not by its ignore flags, which
    // would hide the very marks this subtable exists to find.
    final int previous = buffer.previousVisible(
      index - 1,
      GlyphFilter(
        Lookup(
          type: lookup.type,
          flags: lookup.flags &
              ~(Lookup.flagIgnoreBaseGlyphs |
                  Lookup.flagIgnoreLigatures |
                  Lookup.flagIgnoreMarks),
          subtableOffsets: const <int>[],
          markFilteringSet: lookup.markFilteringSet,
        ),
        gdef,
      ),
    );
    if (previous < 0) return -1;
    if (gdef == null || !gdef.isMark(buffer.glyphs[previous])) return -1;

    final int mark2Index = _cache
        .coverage(offset + mark2CoverageOffset)
        .indexOf(buffer.glyphs[previous]);
    if (mark2Index < 0) return -1;

    final (int markClass, _Anchor? markAnchor) =
        _markRecord(offset + mark1ArrayOffset, markIndex);
    if (markAnchor == null || markClass >= markClassCount) return -1;

    final _Anchor? baseAnchor = _anchorFromArray(
      offset + mark2ArrayOffset,
      mark2Index,
      markClass,
      markClassCount,
    );
    if (baseAnchor == null) return -1;

    _attach(buffer, index, previous, baseAnchor, markAnchor);
    return index + 1;
  }

  /// Records that [mark] hangs off [base] with its anchors made to coincide.
  ///
  /// The displacement is stored *relative to the base*, and the base's own
  /// position is added later by [GlyphBuffer.resolveAttachments]. Doing it now
  /// would freeze the mark against a base that later lookups may still move.
  void _attach(
    GlyphBuffer buffer,
    int mark,
    int base,
    _Anchor baseAnchor,
    _Anchor markAnchor,
  ) {
    buffer.xOffsets[mark] = (baseAnchor.x - markAnchor.x).toDouble();
    buffer.yOffsets[mark] = (baseAnchor.y - markAnchor.y).toDouble();
    buffer.attachedTo[mark] = base;
  }

  /// The class and anchor of one entry of a `MarkArray`.
  (int, _Anchor?) _markRecord(int arrayOffset, int markIndex) {
    final FontReader reader = _data.readerAt(arrayOffset, table: 'GPOS');
    final int count = reader.readUint16();
    if (markIndex >= count) return (0, null);
    reader.skip(markIndex * 4);
    final int markClass = reader.readUint16();
    final int anchorOffset = reader.readUint16();
    if (anchorOffset == 0) return (markClass, null);
    return (markClass, _anchor(arrayOffset + anchorOffset));
  }

  /// One anchor out of a `BaseArray` or `Mark2Array`.
  ///
  /// Both are the same shape: a count, then one row per covered glyph holding
  /// one anchor offset per mark class. A null offset in the row is legal and
  /// means this glyph has no attachment point for that class of mark.
  _Anchor? _anchorFromArray(
    int arrayOffset,
    int rowIndex,
    int markClass,
    int markClassCount,
  ) {
    final FontReader reader = _data.readerAt(arrayOffset, table: 'GPOS');
    final int count = reader.readUint16();
    if (rowIndex >= count) return null;
    reader.skip((rowIndex * markClassCount + markClass) * 2);
    final int anchorOffset = reader.readUint16();
    if (anchorOffset == 0) return null;
    return _anchor(arrayOffset + anchorOffset);
  }

  /// An anchor table's coordinates, in font units.
  ///
  /// Format 2 additionally names a contour point on the glyph, to be used in
  /// preference to the coordinates when the outline has been hinted; format 3
  /// carries device tables. Both extras are ignored, which leaves the design
  /// coordinates - correct at any size, and off by at most a hinting nudge at
  /// the small sizes where the alternatives would have applied.
  _Anchor _anchor(int offset) {
    final FontReader reader = _data.readerAt(offset, table: 'GPOS');
    final int format = reader.readUint16();
    if (format < 1 || format > 3) {
      throw FontFormatException(
        'anchor format $format is not defined',
        offset: offset,
        table: 'GPOS',
      );
    }
    return (x: reader.readInt16(), y: reader.readInt16());
  }

  /// Type 7: "when these glyphs appear in a row, run these lookups".
  int _context(
    int offset,
    GlyphFilter filter,
    GlyphBuffer buffer,
    int index,
    GdefTable? gdef,
    int depth,
  ) {
    final FontReader reader = _data.readerAt(offset, table: 'GPOS');
    final int format = reader.readUint16();
    switch (format) {
      case 1:
      case 2:
        final int coverageOffset = reader.readUint16();
        final Coverage coverage = _cache.coverage(offset + coverageOffset);
        if (!coverage.covers(buffer.glyphs[index])) return -1;
        final ClassDef? classes =
            format == 2 ? _cache.classDef(offset, reader.readUint16()) : null;
        final int setIndex = format == 2
            ? classes!.classOf(buffer.glyphs[index])
            : coverage.indexOf(buffer.glyphs[index]);
        final int setCount = reader.readUint16();
        if (setIndex < 0 || setIndex >= setCount) return -1;
        reader.skip(setIndex * 2);
        final int setOffset = reader.readUint16();
        if (setOffset == 0) return -1;
        return _runRuleSet(
          offset + setOffset,
          filter,
          buffer,
          index,
          gdef,
          depth,
          classes: classes,
        );
      case 3:
        final int glyphCount = reader.readUint16();
        final int lookupCount = reader.readUint16();
        if (glyphCount == 0) return -1;
        final Uint16List coverages = reader.readUint16List(glyphCount);
        final List<SequenceLookupRecord> records =
            readSequenceLookups(reader, lookupCount);
        if (!_cache
            .coverage(offset + coverages[0])
            .covers(buffer.glyphs[index])) {
          return -1;
        }
        final List<int>? positions = matchInput(
          buffer,
          filter,
          index,
          glyphCount,
          (int element, int glyph) =>
              _cache.coverage(offset + coverages[element]).covers(glyph),
        );
        if (positions == null) return -1;
        return _applyRecords(records, positions, buffer, gdef, depth);
      default:
        throw FontFormatException(
          'context positioning format $format is not defined',
          offset: offset,
          table: 'GPOS',
        );
    }
  }

  /// Type 8: a context with a required prefix and suffix.
  int _chainContext(
    int offset,
    GlyphFilter filter,
    GlyphBuffer buffer,
    int index,
    GdefTable? gdef,
    int depth,
  ) {
    final FontReader reader = _data.readerAt(offset, table: 'GPOS');
    final int format = reader.readUint16();
    switch (format) {
      case 1:
      case 2:
        final int coverageOffset = reader.readUint16();
        final Coverage coverage = _cache.coverage(offset + coverageOffset);
        if (!coverage.covers(buffer.glyphs[index])) return -1;
        ClassDef? backtrackClasses;
        ClassDef? inputClasses;
        ClassDef? lookaheadClasses;
        int setIndex;
        if (format == 2) {
          backtrackClasses = _cache.classDef(offset, reader.readUint16());
          inputClasses = _cache.classDef(offset, reader.readUint16());
          lookaheadClasses = _cache.classDef(offset, reader.readUint16());
          setIndex = inputClasses.classOf(buffer.glyphs[index]);
        } else {
          setIndex = coverage.indexOf(buffer.glyphs[index]);
        }
        final int setCount = reader.readUint16();
        if (setIndex < 0 || setIndex >= setCount) return -1;
        reader.skip(setIndex * 2);
        final int setOffset = reader.readUint16();
        if (setOffset == 0) return -1;
        return _runChainRuleSet(
          offset + setOffset,
          filter,
          buffer,
          index,
          gdef,
          depth,
          backtrack: backtrackClasses,
          input: inputClasses,
          lookahead: lookaheadClasses,
        );
      case 3:
        final int backtrackCount = reader.readUint16();
        final Uint16List backtrack = reader.readUint16List(backtrackCount);
        final int inputCount = reader.readUint16();
        if (inputCount == 0) return -1;
        final Uint16List input = reader.readUint16List(inputCount);
        final int lookaheadCount = reader.readUint16();
        final Uint16List lookahead = reader.readUint16List(lookaheadCount);
        final int recordCount = reader.readUint16();
        final List<SequenceLookupRecord> records =
            readSequenceLookups(reader, recordCount);

        if (!_cache.coverage(offset + input[0]).covers(buffer.glyphs[index])) {
          return -1;
        }
        final List<int>? positions = matchInput(
          buffer,
          filter,
          index,
          inputCount,
          (int element, int glyph) =>
              _cache.coverage(offset + input[element]).covers(glyph),
        );
        if (positions == null) return -1;
        if (!matchBacktrack(
          buffer,
          filter,
          index,
          backtrackCount,
          (int element, int glyph) =>
              _cache.coverage(offset + backtrack[element]).covers(glyph),
        )) {
          return -1;
        }
        if (!matchLookahead(
          buffer,
          filter,
          positions.last,
          lookaheadCount,
          (int element, int glyph) =>
              _cache.coverage(offset + lookahead[element]).covers(glyph),
        )) {
          return -1;
        }
        return _applyRecords(records, positions, buffer, gdef, depth);
      default:
        throw FontFormatException(
          'chain context positioning format $format is not defined',
          offset: offset,
          table: 'GPOS',
        );
    }
  }

  int _runRuleSet(
    int setOffset,
    GlyphFilter filter,
    GlyphBuffer buffer,
    int index,
    GdefTable? gdef,
    int depth, {
    required ClassDef? classes,
  }) {
    final FontReader set = _data.readerAt(setOffset, table: 'GPOS');
    final int ruleCount = set.readUint16();
    final Uint16List ruleOffsets = set.readUint16List(ruleCount);
    for (final int ruleOffset in ruleOffsets) {
      final FontReader rule =
          _data.readerAt(setOffset + ruleOffset, table: 'GPOS');
      final int glyphCount = rule.readUint16();
      if (glyphCount == 0) continue;
      final int recordCount = rule.readUint16();
      final Uint16List values = rule.readUint16List(glyphCount - 1);
      final List<SequenceLookupRecord> records =
          readSequenceLookups(rule, recordCount);
      final List<int>? positions = matchInput(
        buffer,
        filter,
        index,
        glyphCount,
        (int element, int glyph) => classes == null
            ? values[element - 1] == glyph
            : classes.classOf(glyph) == values[element - 1],
      );
      if (positions == null) continue;
      return _applyRecords(records, positions, buffer, gdef, depth);
    }
    return -1;
  }

  int _runChainRuleSet(
    int setOffset,
    GlyphFilter filter,
    GlyphBuffer buffer,
    int index,
    GdefTable? gdef,
    int depth, {
    required ClassDef? backtrack,
    required ClassDef? input,
    required ClassDef? lookahead,
  }) {
    final FontReader set = _data.readerAt(setOffset, table: 'GPOS');
    final int ruleCount = set.readUint16();
    final Uint16List ruleOffsets = set.readUint16List(ruleCount);
    for (final int ruleOffset in ruleOffsets) {
      final FontReader rule =
          _data.readerAt(setOffset + ruleOffset, table: 'GPOS');
      final int backtrackCount = rule.readUint16();
      final Uint16List backtrackValues = rule.readUint16List(backtrackCount);
      final int inputCount = rule.readUint16();
      if (inputCount == 0) continue;
      final Uint16List inputValues = rule.readUint16List(inputCount - 1);
      final int lookaheadCount = rule.readUint16();
      final Uint16List lookaheadValues = rule.readUint16List(lookaheadCount);
      final int recordCount = rule.readUint16();
      final List<SequenceLookupRecord> records =
          readSequenceLookups(rule, recordCount);

      final List<int>? positions = matchInput(
        buffer,
        filter,
        index,
        inputCount,
        (int element, int glyph) => input == null
            ? inputValues[element - 1] == glyph
            : input.classOf(glyph) == inputValues[element - 1],
      );
      if (positions == null) continue;
      if (!matchBacktrack(
        buffer,
        filter,
        index,
        backtrackCount,
        (int element, int glyph) => backtrack == null
            ? backtrackValues[element] == glyph
            : backtrack.classOf(glyph) == backtrackValues[element],
      )) {
        continue;
      }
      if (!matchLookahead(
        buffer,
        filter,
        positions.last,
        lookaheadCount,
        (int element, int glyph) => lookahead == null
            ? lookaheadValues[element] == glyph
            : lookahead.classOf(glyph) == lookaheadValues[element],
      )) {
        continue;
      }
      return _applyRecords(records, positions, buffer, gdef, depth);
    }
    return -1;
  }

  /// Runs a rule's nested lookups.
  ///
  /// Simpler than the substitution equivalent, because positioning never
  /// changes the buffer's length: the matched positions stay valid throughout.
  int _applyRecords(
    List<SequenceLookupRecord> records,
    List<int> positions,
    GlyphBuffer buffer,
    GdefTable? gdef,
    int depth,
  ) {
    if (depth < _maxRecursionDepth) {
      for (final SequenceLookupRecord record in records) {
        if (record.sequenceIndex >= positions.length) continue;
        if (record.lookupIndex >= header.lookupList.length) continue;
        final int at = positions[record.sequenceIndex];
        if (at < 0 || at >= buffer.length) continue;
        final Lookup nested = header.lookupList.lookups[record.lookupIndex];
        _applyLookup(
          nested,
          GlyphFilter(nested, gdef),
          buffer,
          at,
          gdef,
          depth + 1,
        );
      }
    }
    return positions.last + 1;
  }

  /// Adds one value record's adjustments to [index], advancing [reader].
  void _applyValue(
    FontReader reader,
    int format,
    GlyphBuffer buffer,
    int index,
  ) {
    if (format & 0x0001 != 0) {
      buffer.xOffsets[index] += reader.readInt16();
    }
    if (format & 0x0002 != 0) {
      buffer.yOffsets[index] += reader.readInt16();
    }
    if (format & 0x0004 != 0) {
      buffer.xAdvances[index] += reader.readInt16();
    }
    if (format & 0x0008 != 0) {
      buffer.yAdvances[index] += reader.readInt16();
    }
    // The four device table offsets. Stepped over so the cursor lands on the
    // next record; see the note at the top of this file for why they are not
    // applied.
    if (format & 0x0010 != 0) reader.skip(2);
    if (format & 0x0020 != 0) reader.skip(2);
    if (format & 0x0040 != 0) reader.skip(2);
    if (format & 0x0080 != 0) reader.skip(2);
  }

  /// How many bytes a value record with [format] occupies.
  static int _valueSize(int format) {
    int size = 0;
    for (int bit = 0; bit < 8; bit++) {
      if (format & (1 << bit) != 0) size += 2;
    }
    return size;
  }
}
