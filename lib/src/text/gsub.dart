/// `GSUB` - the table that changes which glyphs are drawn.
///
/// Substitution is the half of OpenType layout that alters the glyph string
/// rather than moving it. It is what turns "f" and "i" into a single "fi"
/// glyph whose dot does not collide with the f's hook, what composes a letter
/// and a combining accent into one precomposed glyph, what selects the initial,
/// medial and final forms of an Arabic letter, and what a font's small caps or
/// old-style figures are made of.
///
/// Without it a renderer draws the glyphs the character map returned, which
/// for Latin is *nearly* right - and being nearly right is the problem, since
/// the failure is a collided "fi" rather than a missing glyph.
///
/// ## What is implemented
///
/// * **Type 1**, single substitution, both formats - one glyph for one glyph.
/// * **Type 2**, multiple substitution - one glyph becomes several, which is
///   how a font decomposes a precomposed character.
/// * **Type 3**, alternate substitution - the first alternate is taken, since
///   choosing among them needs a user-facing feature selector that does not
///   exist here yet.
/// * **Type 4**, ligature substitution - several glyphs become one.
/// * **Type 5**, context substitution, all three formats.
/// * **Type 6**, chained context substitution, all three formats. `calt`,
///   `clig` and most of the interesting parts of `ccmp` are made of these.
/// * **Type 7**, extension - see below.
/// * **Type 8**, reverse chaining contextual single substitution - the one
///   lookup that runs backwards. See [GsubTable._reverseChainSingle] for why
///   the direction is the whole point of it.
///
/// ## Extension is not optional
///
/// A type 7 lookup contains nothing but a type and a 32-bit offset to a real
/// subtable somewhere else in the table. It exists because subtable offsets
/// are 16-bit and a large font's `GSUB` outgrows 64 KB, and font compilers
/// wrap *everything* in it once anything needs wrapping. A shaper that treats
/// type 7 as unknown does not fail loudly - it silently applies none of the
/// wrapped lookups, so a font's ligatures simply stop existing.
library;

import 'dart:typed_data';

import 'font_data.dart';
import 'layout_common.dart';
import 'sfnt.dart';

/// How deep a context rule may call another context rule.
///
/// Nested lookups are a general recursion and the file decides the shape of
/// it, so a font can describe a cycle. The limit is what turns that from a
/// hang into a rule that quietly stops applying - the same trade every shaper
/// makes, and the reason it is a constant rather than a thrown error is that
/// the affected text should still render.
const int _maxRecursionDepth = 8;

/// The glyph substitution table.
final class GsubTable {
  GsubTable._(this.header, this._cache);

  final LayoutHeader header;
  final OffsetCache _cache;

  /// Parses `GSUB`, or returns null when the font has none.
  ///
  /// Null rather than an exception, on the model of `kern`: a font without
  /// `GSUB` is ordinary - Ahem has none - and the shaper's answer is to skip
  /// substitution, not to refuse the font.
  static GsubTable? parse(SfntFile file) {
    final TableRecord? record = file.tableRecord('GSUB');
    if (record == null) return null;
    return GsubTable.at(file.data, record.offset);
  }

  /// Parses a `GSUB` table that begins at [offset] in [data].
  ///
  /// Separate from [parse] so a table can be read without an sfnt container
  /// around it, which is what lets a test build one byte by byte and assert
  /// on a lookup type no shipping fixture happens to contain.
  static GsubTable at(FontData data, int offset) => GsubTable._(
      LayoutHeader.parse(data, offset, 'GSUB'), OffsetCache(data, 'GSUB'));

  FontData get _data => header.data;

  /// Whether [tag] is offered for [script].
  bool hasFeature(String tag, {String script = 'latn', String? language}) =>
      header.hasFeature(tag, script: script, language: language);

  /// Applies every lookup that [features] select, in lookup-index order.
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

  /// Sweeps [buffer] once with one lookup.
  void _runLookup(int lookupIndex, GlyphBuffer buffer, GdefTable? gdef) {
    final Lookup lookup = header.lookupList.lookups[lookupIndex];
    final GlyphFilter filter = GlyphFilter(lookup, gdef);
    if (_isReverse(lookup)) {
      _runReverseLookup(lookup, filter, buffer, gdef);
      return;
    }
    int index = 0;
    while (index < buffer.length) {
      if (!filter.skips(buffer.glyphs[index])) {
        final int next = _applyLookup(lookup, filter, buffer, index, gdef, 0);
        // A subtable that applied always reports a position strictly past the
        // one it started at. Anything else - a malformed rule that matches
        // zero glyphs, say - would loop here forever.
        if (next > index) {
          index = next;
          continue;
        }
      }
      index++;
    }
  }

  /// Whether [lookup] is a type 8, directly or through an extension.
  ///
  /// The question has to be asked of the *wrapped* type, because a font
  /// compiler that outgrew 16-bit offsets wraps every lookup it emits,
  /// including the reverse one. A shaper that only checked `lookup.type`
  /// would run a wrapped type 8 forwards, which is not a crash and not an
  /// exception - it is Nastaliq text substituted in the wrong order.
  ///
  /// Only the first subtable is consulted, as HarfBuzz does: the spec requires
  /// every subtable of a lookup to have the same type, so a lookup that
  /// disagreed with itself is malformed and the first subtable is as good an
  /// answer as any.
  ///
  /// Memoised by subtable offset, because [_applyNested] asks it once per
  /// nested application - which is once per matched glyph of a contextual
  /// rule - and the answer is a property of the bytes, which do not change.
  bool _isReverse(Lookup lookup) {
    if (lookup.type == 8) return true;
    if (lookup.type != 7 || lookup.subtableOffsets.isEmpty) return false;
    final int offset = lookup.subtableOffsets.first;
    final bool? known = _wrapsReverse[offset];
    if (known != null) return known;
    final FontReader reader = _data.readerAt(offset, table: 'GSUB');
    reader.skip(2); // extension format
    final bool reverse = reader.readUint16() == 8;
    _wrapsReverse[offset] = reverse;
    return reverse;
  }

  final Map<int, bool> _wrapsReverse = <int, bool>{};

  /// Sweeps [buffer] back to front with a type 8 lookup.
  ///
  /// The only backwards sweep in `GSUB`, and the ordering is the feature
  /// rather than an implementation detail - see [_reverseChainSingle].
  ///
  /// Nothing here has to compensate for a changing buffer length, because a
  /// reverse chaining lookup substitutes one glyph for one glyph and can do
  /// nothing else: it has no sequence lookup records to call anything with.
  void _runReverseLookup(
    Lookup lookup,
    GlyphFilter filter,
    GlyphBuffer buffer,
    GdefTable? gdef,
  ) {
    for (int index = buffer.length - 1; index >= 0; index--) {
      if (filter.skips(buffer.glyphs[index])) continue;
      _applyLookup(lookup, filter, buffer, index, gdef, 0);
    }
  }

  /// Tries each of [lookup]'s subtables at [index]; -1 when none applied.
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
      // Every subtable begins by asking whether the glyph under the cursor is
      // one it applies to, and the answer is no for almost every glyph of
      // almost every run. Asking it from a cached coverage table, before
      // decoding the subtable header, is what keeps a lookup with ten
      // subtables from costing ten header decodes per glyph.
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
  /// Null means "this subtable has no single leading coverage", and the caller
  /// must decode it to find out - true of a malformed or unknown format, and
  /// the safe answer, since a wrong "not covered" silently disables a feature.
  Coverage? _leadingCoverage(int type, int offset) =>
      _leading.putIfAbsent(offset, () => _readLeadingCoverage(type, offset));

  final Map<int, Coverage?> _leading = <int, Coverage?>{};

  Coverage? _readLeadingCoverage(int type, int offset) {
    final FontReader reader = _data.readerAt(offset, table: 'GSUB');
    switch (type) {
      case 1:
      case 2:
      case 3:
      case 4:
      // Type 8's coverage is the input coverage, in the same slot: the glyph
      // under the cursor is the one glyph it substitutes.
      case 8:
        reader.skip(2); // substitution format
        return _cache.coverage(offset + reader.readUint16());
      case 5:
      case 6:
        final int format = reader.readUint16();
        if (format == 1 || format == 2) {
          return _cache.coverage(offset + reader.readUint16());
        }
        if (format != 3) return null;
        if (type == 5) {
          final int glyphCount = reader.readUint16();
          if (glyphCount == 0) return null;
          reader.skip(2); // seqLookupCount, which precedes the coverages
          return _cache.coverage(offset + reader.readUint16());
        }
        // A chained rule's input coverages start after the backtrack
        // sequence, which is written first even though it matches leftwards.
        reader.skip(reader.readUint16() * 2);
        final int inputCount = reader.readUint16();
        if (inputCount == 0) return null;
        return _cache.coverage(offset + reader.readUint16());
      case 7:
        reader.skip(2); // extension format
        final int extensionType = reader.readUint16();
        final int extensionOffset = reader.readUint32();
        if (extensionType == 7) return null;
        return _readLeadingCoverage(extensionType, offset + extensionOffset);
      default:
        return null;
    }
  }

  /// Applies one lookup at exactly one position, for a context rule's nested
  /// lookups. Returns the change in buffer length.
  int _applyNested(
    int lookupIndex,
    GlyphBuffer buffer,
    int index,
    GdefTable? gdef,
    int depth,
  ) {
    if (depth >= _maxRecursionDepth) return 0;
    if (lookupIndex >= header.lookupList.length) return 0;
    final Lookup lookup = header.lookupList.lookups[lookupIndex];
    // The spec forbids a contextual rule from calling a reverse chaining
    // lookup, and the reason is not arbitrary: a type 8 lookup is defined by
    // the order its whole sweep runs in, and there is no such thing as running
    // one at a single position on somebody else's behalf. Refusing it by name
    // here is the difference between "this font's rule does nothing" and "this
    // font's rule substitutes in an order nobody specified".
    if (_isReverse(lookup)) return 0;
    final GlyphFilter filter = GlyphFilter(lookup, gdef);
    final int before = buffer.length;
    _applyLookup(lookup, filter, buffer, index, gdef, depth + 1);
    return buffer.length - before;
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
        return _multiple(offset, buffer, index);
      case 3:
        return _alternate(offset, buffer, index);
      case 4:
        return _ligature(offset, filter, buffer, index);
      case 5:
        return _context(offset, filter, buffer, index, gdef, depth);
      case 6:
        return _chainContext(offset, filter, buffer, index, gdef, depth);
      case 7:
        return _extension(offset, lookup, filter, buffer, index, gdef, depth);
      case 8:
        return _reverseChainSingle(offset, filter, buffer, index);
      default:
        // Anything a later spec revision adds. Ignoring an unknown type is the
        // spec's own instruction and is why a font may use a new lookup type
        // without breaking old shapers.
        return -1;
    }
  }

  /// Type 7: a type and a 32-bit offset standing in for a real subtable.
  int _extension(
    int offset,
    Lookup lookup,
    GlyphFilter filter,
    GlyphBuffer buffer,
    int index,
    GdefTable? gdef,
    int depth,
  ) {
    final FontReader reader = _data.readerAt(offset, table: 'GSUB');
    final int format = reader.readUint16();
    if (format != 1) {
      throw FontFormatException(
        'extension subtable format $format is not defined',
        offset: offset,
        table: 'GSUB',
      );
    }
    final int extensionType = reader.readUint16();
    final int extensionOffset = reader.readUint32();
    if (extensionType == 7) {
      // An extension wrapping an extension is forbidden and would otherwise be
      // an easy infinite recursion for a hostile font.
      throw FontFormatException(
        'an extension subtable may not wrap another',
        offset: offset,
        table: 'GSUB',
      );
    }
    return _applySubtable(extensionType, offset + extensionOffset, lookup,
        filter, buffer, index, gdef, depth);
  }

  /// Type 1: one glyph for one glyph.
  int _single(int offset, GlyphBuffer buffer, int index) {
    final FontReader reader = _data.readerAt(offset, table: 'GSUB');
    final int format = reader.readUint16();
    final int coverageOffset = reader.readUint16();
    final int glyph = buffer.glyphs[index];
    final int coverageIndex =
        _cache.coverage(offset + coverageOffset).indexOf(glyph);
    if (coverageIndex < 0) return -1;

    switch (format) {
      case 1:
        // A delta, applied modulo 65536 because the spec says so: a font may
        // encode "the glyph 30 before this one" as a large positive delta that
        // wraps, and clamping instead would substitute the wrong glyph.
        final int delta = reader.readInt16();
        buffer.substitute(index, (glyph + delta) & 0xFFFF);
        return index + 1;
      case 2:
        final int count = reader.readUint16();
        if (coverageIndex >= count) return -1;
        reader.skip(coverageIndex * 2);
        buffer.substitute(index, reader.readUint16());
        return index + 1;
      default:
        throw FontFormatException(
          'single substitution format $format is not defined',
          offset: offset,
          table: 'GSUB',
        );
    }
  }

  /// Type 2: one glyph becomes a sequence.
  int _multiple(int offset, GlyphBuffer buffer, int index) {
    final FontReader reader = _data.readerAt(offset, table: 'GSUB');
    final int format = reader.readUint16();
    if (format != 1) {
      throw FontFormatException(
        'multiple substitution format $format is not defined',
        offset: offset,
        table: 'GSUB',
      );
    }
    final int coverageOffset = reader.readUint16();
    final int coverageIndex =
        _cache.coverage(offset + coverageOffset).indexOf(buffer.glyphs[index]);
    if (coverageIndex < 0) return -1;
    final int count = reader.readUint16();
    if (coverageIndex >= count) return -1;
    reader.skip(coverageIndex * 2);
    final int sequenceOffset = reader.readUint16();
    final FontReader sequence =
        _data.readerAt(offset + sequenceOffset, table: 'GSUB');
    final int glyphCount = sequence.readUint16();
    // A zero-length sequence is legal in the file and means "delete", but the
    // spec advises against it and a deletion here would move every following
    // index under the caller's feet. Refusing to apply is the safe reading.
    if (glyphCount == 0) return -1;
    buffer.expand(index, sequence.readUint16List(glyphCount).toList());
    return index + glyphCount;
  }

  /// Type 3: a choice, of which the first is taken.
  int _alternate(int offset, GlyphBuffer buffer, int index) {
    final FontReader reader = _data.readerAt(offset, table: 'GSUB');
    final int format = reader.readUint16();
    if (format != 1) {
      throw FontFormatException(
        'alternate substitution format $format is not defined',
        offset: offset,
        table: 'GSUB',
      );
    }
    final int coverageOffset = reader.readUint16();
    final int coverageIndex =
        _cache.coverage(offset + coverageOffset).indexOf(buffer.glyphs[index]);
    if (coverageIndex < 0) return -1;
    final int count = reader.readUint16();
    if (coverageIndex >= count) return -1;
    reader.skip(coverageIndex * 2);
    final int setOffset = reader.readUint16();
    final FontReader set = _data.readerAt(offset + setOffset, table: 'GSUB');
    final int alternateCount = set.readUint16();
    if (alternateCount == 0) return -1;
    buffer.substitute(index, set.readUint16());
    return index + 1;
  }

  /// Type 4: a sequence of glyphs becomes one.
  int _ligature(
    int offset,
    GlyphFilter filter,
    GlyphBuffer buffer,
    int index,
  ) {
    final FontReader reader = _data.readerAt(offset, table: 'GSUB');
    final int format = reader.readUint16();
    if (format != 1) {
      throw FontFormatException(
        'ligature substitution format $format is not defined',
        offset: offset,
        table: 'GSUB',
      );
    }
    final int coverageOffset = reader.readUint16();
    final int coverageIndex =
        _cache.coverage(offset + coverageOffset).indexOf(buffer.glyphs[index]);
    if (coverageIndex < 0) return -1;
    final int setCount = reader.readUint16();
    if (coverageIndex >= setCount) return -1;
    reader.skip(coverageIndex * 2);
    final int setOffset = offset + reader.readUint16();

    final FontReader set = _data.readerAt(setOffset, table: 'GSUB');
    final int ligatureCount = set.readUint16();
    final Uint16List ligatureOffsets = set.readUint16List(ligatureCount);

    // In file order. The format requires the longest component sequence first
    // so that "ffi" is tried before "fi"; taking the first match is therefore
    // taking the longest, and reordering would turn "ffi" into "fi" plus "i".
    for (final int ligatureOffset in ligatureOffsets) {
      final FontReader ligature =
          _data.readerAt(setOffset + ligatureOffset, table: 'GSUB');
      final int ligatureGlyph = ligature.readUint16();
      final int componentCount = ligature.readUint16();
      if (componentCount == 0) continue;
      final Uint16List components = ligature.readUint16List(componentCount - 1);
      final List<int>? positions = matchInput(
        buffer,
        filter,
        index,
        componentCount,
        (int element, int glyph) => components[element - 1] == glyph,
      );
      if (positions == null) continue;
      buffer.ligate(positions, ligatureGlyph);
      return index + 1;
    }
    return -1;
  }

  /// Type 5: "when these glyphs appear in a row, run these lookups".
  int _context(
    int offset,
    GlyphFilter filter,
    GlyphBuffer buffer,
    int index,
    GdefTable? gdef,
    int depth,
  ) {
    final FontReader reader = _data.readerAt(offset, table: 'GSUB');
    final int format = reader.readUint16();
    switch (format) {
      case 1:
      case 2:
        final int coverageOffset = reader.readUint16();
        if (!_cache
            .coverage(offset + coverageOffset)
            .covers(buffer.glyphs[index])) {
          return -1;
        }
        // Format 1 keys rule sets by coverage index, format 2 by the class of
        // the first glyph. Everything after that differs only in what the rule
        // compares against.
        final ClassDef? classes =
            format == 2 ? _cache.classDef(offset, reader.readUint16()) : null;
        final int setIndex = format == 2
            ? classes!.classOf(buffer.glyphs[index])
            : _cache.coverage(offset + coverageOffset).indexOf(
                  buffer.glyphs[index],
                );
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
          inputMatcher: (List<int> values, int element, int glyph) =>
              format == 2
                  ? classes!.classOf(glyph) == values[element - 1]
                  : values[element - 1] == glyph,
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
          'context substitution format $format is not defined',
          offset: offset,
          table: 'GSUB',
        );
    }
  }

  /// Type 6: a context with a required prefix and suffix.
  int _chainContext(
    int offset,
    GlyphFilter filter,
    GlyphBuffer buffer,
    int index,
    GdefTable? gdef,
    int depth,
  ) {
    final FontReader reader = _data.readerAt(offset, table: 'GSUB');
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
          'chain context substitution format $format is not defined',
          offset: offset,
          table: 'GSUB',
        );
    }
  }

  /// Type 8: one glyph for one glyph, decided by context, applied backwards.
  ///
  /// Structurally this is a chained context rule whose input is exactly one
  /// glyph and whose action is a direct substitution rather than a list of
  /// nested lookups. Everything that makes it worth having is in the word
  /// *reverse*.
  ///
  /// ## Why the order is the feature
  ///
  /// [_runReverseLookup] walks the buffer from the last glyph to the first,
  /// and each substitution it makes is immediately visible to the glyphs still
  /// to be processed - which are the ones *before* it, and which see it as
  /// lookahead. So a font can write a single rule that propagates a decision
  /// leftwards along a whole word: the final letter picks its shape, the
  /// letter before it picks a shape that fits the one just chosen, and so on
  /// to the start of the word. That is exactly how Nastaliq Arabic chooses the
  /// height of each letter in a descending ligature chain, and it is why the
  /// spec gives this its own lookup type instead of letting a type 6 do it -
  /// a forward sweep would decide each letter against the *unsubstituted*
  /// letter after it, which for a font that relies on the propagation means
  /// every letter but the last one is wrong.
  ///
  /// ## It cannot call anything
  ///
  /// There are no sequence lookup records in this format, so there is nothing
  /// to recurse into - and the spec separately forbids other lookups from
  /// calling *it*, which [_applyNested] enforces. The recursion depth counter
  /// the other contextual types carry is therefore absent here rather than
  /// merely unused.
  ///
  /// ## Which way is "backtrack"
  ///
  /// Backtrack means "earlier in [GlyphBuffer]", full stop, and lookahead
  /// means "later in it". The buffer is in **logical order** for the whole of
  /// substitution and positioning - `shaper.dart` reverses it into visual
  /// order once, at the very end - so for right-to-left text the backtrack
  /// glyphs are the ones that will be drawn to the *right*. Reading the rule
  /// as visual instead of logical mirrors every Arabic contextual rule in the
  /// font, which is a failure that still produces plausible glyphs.
  ///
  /// Within the backtrack array itself the order is nearest-first, as it is
  /// for type 6; [matchBacktrack] owns that detail.
  int _reverseChainSingle(
    int offset,
    GlyphFilter filter,
    GlyphBuffer buffer,
    int index,
  ) {
    final FontReader reader = _data.readerAt(offset, table: 'GSUB');
    final int format = reader.readUint16();
    if (format != 1) {
      throw FontFormatException(
        'reverse chaining substitution format $format is not defined',
        offset: offset,
        table: 'GSUB',
      );
    }
    final int coverageOffset = reader.readUint16();
    final int coverageIndex =
        _cache.coverage(offset + coverageOffset).indexOf(buffer.glyphs[index]);
    if (coverageIndex < 0) return -1;

    final int backtrackCount = reader.readUint16();
    final Uint16List backtrack = reader.readUint16List(backtrackCount);
    final int lookaheadCount = reader.readUint16();
    final Uint16List lookahead = reader.readUint16List(lookaheadCount);
    final int glyphCount = reader.readUint16();
    // The substitute array is indexed by coverage index, so a font whose two
    // arrays disagree in length has no answer for this glyph. Refusing to
    // apply is the only reading that cannot substitute a glyph id read from
    // whatever bytes follow the table.
    if (coverageIndex >= glyphCount) return -1;

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
      index,
      lookaheadCount,
      (int element, int glyph) =>
          _cache.coverage(offset + lookahead[element]).covers(glyph),
    )) {
      return -1;
    }

    reader.skip(coverageIndex * 2);
    buffer.substitute(index, reader.readUint16());
    return index + 1;
  }

  /// Walks the rules of a format 1 or 2 context rule set.
  int _runRuleSet(
    int setOffset,
    GlyphFilter filter,
    GlyphBuffer buffer,
    int index,
    GdefTable? gdef,
    int depth, {
    required bool Function(List<int> values, int element, int glyph)
        inputMatcher,
  }) {
    final FontReader set = _data.readerAt(setOffset, table: 'GSUB');
    final int ruleCount = set.readUint16();
    final Uint16List ruleOffsets = set.readUint16List(ruleCount);
    for (final int ruleOffset in ruleOffsets) {
      final FontReader rule =
          _data.readerAt(setOffset + ruleOffset, table: 'GSUB');
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
        (int element, int glyph) => inputMatcher(values, element, glyph),
      );
      if (positions == null) continue;
      return _applyRecords(records, positions, buffer, gdef, depth);
    }
    return -1;
  }

  /// Walks the rules of a format 1 or 2 chained context rule set.
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
    final FontReader set = _data.readerAt(setOffset, table: 'GSUB');
    final int ruleCount = set.readUint16();
    final Uint16List ruleOffsets = set.readUint16List(ruleCount);
    for (final int ruleOffset in ruleOffsets) {
      final FontReader rule =
          _data.readerAt(setOffset + ruleOffset, table: 'GSUB');
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

  /// Runs a rule's nested lookups and reports where to continue.
  ///
  /// The subtlety is that a nested lookup may change the buffer's length - a
  /// ligature inside a contextual rule is exactly that - and the positions the
  /// rule matched were recorded before it ran. Every later position has to
  /// move by the same amount, or the second nested lookup applies to the wrong
  /// glyph. A rule that substitutes nothing is not an error, and reports
  /// "matched, continue past the input" so the same rule cannot match again.
  int _applyRecords(
    List<SequenceLookupRecord> records,
    List<int> positions,
    GlyphBuffer buffer,
    GdefTable? gdef,
    int depth,
  ) {
    for (final SequenceLookupRecord record in records) {
      if (record.sequenceIndex >= positions.length) continue;
      final int at = positions[record.sequenceIndex];
      if (at < 0 || at >= buffer.length) continue;
      final int delta =
          _applyNested(record.lookupIndex, buffer, at, gdef, depth);
      if (delta == 0) continue;
      for (int i = 0; i < positions.length; i++) {
        if (positions[i] > at) positions[i] += delta;
      }
    }
    int end = positions.first;
    for (final int position in positions) {
      if (position > end) end = position;
    }
    if (end >= buffer.length) end = buffer.length - 1;
    return end + 1;
  }
}
