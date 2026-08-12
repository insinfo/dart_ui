/// Shaping: from a string to positioned glyphs.
///
/// Shaping is the step everyone skips and then has to add back. Text is not a
/// sequence of characters each drawn at its own width: ligatures turn two
/// characters into one glyph, kerning changes the gap between specific pairs,
/// marks attach to the base letter they modify, and in some scripts a letter's
/// shape depends on its neighbours. A renderer that draws one glyph per
/// character at its nominal advance produces text that is *legible and wrong*,
/// which is much harder to notice than text that is broken.
///
/// There are two shapers here.
///
/// [LatinShaper] is the smallest correct one: character-to-glyph mapping and
/// legacy `kern` pairs, one glyph per code point. It is enough for text whose
/// accented letters exist as precomposed glyphs, it never changes the glyph
/// count, and it is what a monospace terminal or a diagnostics overlay should
/// use, because its cost is a `cmap` lookup per character.
///
/// [OpenTypeShaper] runs the real pipeline: `cmap`, then `GSUB`, then `GPOS`,
/// then the legacy `kern` table *only* if `GPOS` did not already kern. That
/// buys ligatures, contextual alternates, and mark attachment for decomposed
/// text - and it can change the glyph count, which is why [GlyphRun.clusters]
/// stops being an identity mapping and starts earning its place.
///
/// What is still missing, stated so the gap is on the record rather than
/// discovered later: no bidi, no script itemization, no line breaking, and no
/// script-specific shaping - Arabic joining and Indic reordering both happen
/// *around* `GSUB` rather than inside it, and neither is here. Section 30 owns
/// those, and [Shaper] is the seam they plug into.
library;

import 'dart:typed_data';

import 'gpos.dart';
import 'gsub.dart';
import 'kern.dart';
import 'layout_common.dart';
import 'typeface.dart';

/// The direction a run is laid out in.
enum TextDirection {
  leftToRight,
  rightToLeft;

  bool get isRightToLeft => this == TextDirection.rightToLeft;
}

/// A shaped run: glyphs, where they go, and what text they came from.
///
/// Struct-of-arrays rather than a list of objects, and the two typed lists are
/// exactly the shapes `DisplayList.drawGlyphRun` takes, so a run reaches the
/// encoder without a copy or a conversion. That is not a coincidence to
/// preserve by accident - there is a test asserting it.
final class GlyphRun {
  const GlyphRun({
    required this.font,
    required this.glyphIds,
    required this.positions,
    required this.clusters,
    required this.length,
    required this.width,
    this.direction = TextDirection.leftToRight,
  });

  final ScaledTypeface font;

  /// One glyph id per glyph. Length is at least [length].
  final Int32List glyphIds;

  /// Interleaved x, y offsets from the run's origin, in pixels. Two entries
  /// per glyph, so `positions[2 * i]` and `positions[2 * i + 1]`.
  final Float32List positions;

  /// For each glyph, the index in the source string it came from.
  ///
  /// Not a bijection once ligatures exist. Two characters that became one
  /// glyph share one entry - the *lowest* of their indices - and the source
  /// indices in between belong to that same glyph, which is what
  /// [glyphIndexOfCluster] resolves. Everything above this layer depends on
  /// it: caret placement, selection, hit testing, and the reordering that
  /// Indic and Arabic shaping need.
  final Int32List clusters;

  /// How many glyphs are valid. The arrays may be longer; a shaper reuses
  /// scratch buffers rather than allocating per run.
  final int length;

  /// Total advance of the run, in pixels.
  final double width;

  final TextDirection direction;

  bool get isEmpty => length == 0;

  /// The x offset of glyph [index] from the run origin.
  double xOf(int index) => positions[index * 2];

  /// The y offset of glyph [index] from the run origin.
  ///
  /// Positive is **down**, matching the device coordinates everything above
  /// this layer uses, so an accent lifted above the baseline reads as a
  /// negative offset. The font's own y-up convention stops at the shaper.
  double yOf(int index) => positions[index * 2 + 1];

  /// The glyph that draws the character at [sourceIndex] in the source string.
  ///
  /// -1 when the run is empty or [sourceIndex] precedes it. This is the
  /// question a caret asks, and it is not answerable from [clusters] by
  /// equality: shape "fi" in a font with the ligature and there is no glyph
  /// whose cluster is 1, because the "i" is inside glyph 0. The glyph that
  /// covers an index is the one with the greatest cluster not past it - which
  /// also makes this correct for a right-to-left run, where clusters descend.
  ///
  /// Linear, because a run is a handful of glyphs and a caret moves once per
  /// keystroke. A paragraph-wide index would be built by the layer that owns
  /// paragraphs, not here.
  int glyphIndexOfCluster(int sourceIndex) {
    int best = -1;
    int bestCluster = -1;
    for (int i = 0; i < length; i++) {
      final int cluster = clusters[i];
      if (cluster <= sourceIndex && cluster > bestCluster) {
        bestCluster = cluster;
        best = i;
      }
    }
    return best;
  }

  @override
  String toString() =>
      'GlyphRun($length glyphs, ${width.toStringAsFixed(1)}px, '
      '${direction.name})';
}

/// Turns text into positioned glyphs.
///
/// An interface with one implementation today. It exists as an interface
/// because script-specific shaping is the thing that must be pluggable: Arabic
/// needs joining state computed before substitution, Indic needs syllable
/// reordering, and both are selected per script rather than per font. A single
/// concrete class would have to grow those as branches.
abstract interface class Shaper {
  /// Shapes [text] with [font].
  GlyphRun shape(String text, ScaledTypeface font, {TextDirection direction});
}

/// Shaping for Latin and anything else that needs no reordering.
///
/// Maps each code point through `cmap`, accumulates advances, and applies
/// pair kerning. Reuses its buffers between calls, so one shaper per layout
/// context rather than one per run.
final class LatinShaper implements Shaper {
  LatinShaper({this.applyKerning = true});

  /// Whether to apply the font's kerning table.
  ///
  /// Worth being able to turn off: it is the one part of this shaper whose
  /// effect is a small horizontal shift, so a test that wants to assert plain
  /// advances needs it disabled, and a monospace terminal wants it disabled
  /// always.
  final bool applyKerning;

  final Map<Typeface, KernTable?> _kerning = <Typeface, KernTable?>{};

  Int32List _glyphIds = Int32List(64);
  Float32List _positions = Float32List(128);
  Int32List _clusters = Int32List(64);

  @override
  GlyphRun shape(
    String text,
    ScaledTypeface font, {
    TextDirection direction = TextDirection.leftToRight,
  }) {
    final Typeface face = font.typeface;
    final KernTable? kern = applyKerning
        ? _kerning.putIfAbsent(face, () => KernTable.parse(face.sfnt))
        : null;

    // One glyph per code point in this shaper: no ligatures means no
    // many-to-one, and no decomposition means no one-to-many.
    final int capacity = text.length;
    _ensureCapacity(capacity);

    int count = 0;
    double pen = 0;
    int previousGlyph = -1;
    int clusterIndex = 0;

    for (final int rune in text.runes) {
      final int glyphId = face.glyphForCodePoint(rune);

      // Kerning adjusts the gap *before* this glyph, so it moves the pen back
      // before the glyph is placed rather than shrinking the previous advance.
      // The two are equivalent for a whole run's width and different for
      // per-glyph positions, which is what a caret sits on.
      if (kern != null && previousGlyph >= 0) {
        pen += kern.between(previousGlyph, glyphId) * font.scale;
      }

      _glyphIds[count] = glyphId;
      _positions[count * 2] = pen;
      _positions[count * 2 + 1] = 0;
      _clusters[count] = clusterIndex;

      pen += font.advanceOf(glyphId);
      previousGlyph = glyphId;
      count++;
      // A code point above the BMP occupies two UTF-16 units, and the cluster
      // index is into the original string, so it advances by the right amount
      // rather than by one.
      clusterIndex += rune > 0xFFFF ? 2 : 1;
    }

    return GlyphRun(
      font: font,
      glyphIds: _glyphIds,
      positions: _positions,
      clusters: _clusters,
      length: count,
      width: pen,
      direction: direction,
    );
  }

  void _ensureCapacity(int glyphs) {
    if (_glyphIds.length >= glyphs) return;
    // Grow to the next power of two so a paragraph of increasing line lengths
    // does not reallocate on every line.
    int capacity = _glyphIds.length;
    while (capacity < glyphs) {
      capacity *= 2;
    }
    _glyphIds = Int32List(capacity);
    _positions = Float32List(capacity * 2);
    _clusters = Int32List(capacity);
  }
}

/// The three layout tables a face contributes to shaping, parsed once.
///
/// Held per face rather than per run because parsing them is the expensive
/// part - a script list, a feature list and a lookup directory - and a face is
/// shaped with thousands of times.
final class _FaceTables {
  _FaceTables._(this.gsub, this.gpos, this.gdef, this.kern);

  final GsubTable? gsub;
  final GposTable? gpos;
  final GdefTable? gdef;

  /// The legacy table, **or null when `GPOS` already kerns**.
  ///
  /// The precedence decision is made here, once per face, rather than at every
  /// run: a font that offers a `kern` feature in `GPOS` has said everything it
  /// has to say about kerning, and applying the old table as well would narrow
  /// every kerned pair by twice its designed amount. DejaVu ships both, with
  /// identical values, so the bug it prevents is precisely a doubling.
  final KernTable? kern;

  static _FaceTables read(Typeface face, String script, String? language) {
    final GposTable? gpos = GposTable.parse(face.sfnt);
    final bool gposKerns = gpos != null &&
        gpos.hasFeature('kern', script: script, language: language);
    return _FaceTables._(
      GsubTable.parse(face.sfnt),
      gpos,
      GdefTable.parse(face.sfnt),
      gposKerns ? null : KernTable.parse(face.sfnt),
    );
  }
}

/// Shaping through `GSUB` and `GPOS`.
///
/// The pipeline, in the order the spec fixes and every shaper follows:
///
/// 1. map each code point through `cmap`;
/// 2. apply the enabled `GSUB` features, in lookup-index order, which may
///    change the number of glyphs;
/// 3. load each glyph's unadjusted advance;
/// 4. apply the enabled `GPOS` features, which adjust advances and record
///    mark attachments;
/// 5. apply the legacy `kern` table, if and only if `GPOS` did not kern;
/// 6. resolve attachments and accumulate the pen.
///
/// Steps 2 through 5 work in **font units**, and the scale to pixels happens
/// once at the end. Scaling earlier would round each adjustment separately,
/// and a kern of -131 units in a 2048-unit em is a third of a pixel at 16 px -
/// exactly the size of error that accumulates visibly across a line.
///
/// One consequence: advances come from `hmtx`, not from the hinted advance a
/// glyph acquires once it has been drawn at a size. `GPOS` adjustments are
/// design-space quantities and adding them to a size-specific advance would
/// mix two coordinate systems; [LatinShaper], which has no adjustments to add,
/// prefers the hinted value instead.
final class OpenTypeShaper implements Shaper {
  OpenTypeShaper({
    this.features = defaultFeatures,
    this.applyKerning = true,
    this.script = 'latn',
    this.language,
  });

  /// The features that are on unless a caller says otherwise.
  ///
  /// Deliberately small, and each one earns its place:
  ///
  /// * `ccmp` - glyph composition and decomposition. The one that makes
  ///   decomposed accented text work, either by composing it into a
  ///   precomposed glyph or by swapping in a mark variant that fits the base.
  /// * `locl` - localised forms, where a language wants a different glyph for
  ///   the same character.
  /// * `liga` and `clig` - standard and contextual ligatures.
  /// * `calt` - contextual alternates.
  /// * `kern` - pair kerning.
  /// * `mark` and `mkmk` - mark-to-base and mark-to-mark attachment.
  ///
  /// Absent on purpose: `dlig` and `hlig` (discretionary and historical
  /// ligatures, which a user opts into), the figure and case features, and
  /// everything stylistic. Turning those on by default would change how
  /// ordinary text looks in ways nobody asked for.
  static const Set<String> defaultFeatures = <String>{
    'ccmp',
    'locl',
    'liga',
    'clig',
    'calt',
    'kern',
    'mark',
    'mkmk',
  };

  final Set<String> features;

  /// Whether to kern at all, from either table.
  ///
  /// The same escape hatch [LatinShaper] has, and it must suppress both
  /// mechanisms or a font with `GPOS` kerning would ignore it.
  final bool applyKerning;

  /// The OpenType script tag whose rules to apply.
  ///
  /// Fixed per shaper rather than detected per run, because detecting it is
  /// script itemization and that belongs above this layer: a run reaching a
  /// shaper is supposed to already be one script.
  final String script;

  /// An optional language system tag, refining [script].
  final String? language;

  final Map<Typeface, _FaceTables> _tables = <Typeface, _FaceTables>{};
  final GlyphBuffer _buffer = GlyphBuffer();

  Int32List _glyphIds = Int32List(64);
  Float32List _positions = Float32List(128);
  Int32List _clusters = Int32List(64);

  /// The features actually enabled, honouring [applyKerning].
  late final Set<String> _activeFeatures = <String>{
    for (final String feature in features)
      if (applyKerning || feature != 'kern') feature,
  };

  @override
  GlyphRun shape(
    String text,
    ScaledTypeface font, {
    TextDirection direction = TextDirection.leftToRight,
  }) {
    final Typeface face = font.typeface;
    final _FaceTables tables = _tables.putIfAbsent(
      face,
      () => _FaceTables.read(face, script, language),
    );

    _buffer.clear();
    int clusterIndex = 0;
    for (final int rune in text.runes) {
      _buffer.add(face.glyphForCodePoint(rune), clusterIndex);
      // A code point above the BMP occupies two UTF-16 units and the cluster
      // index is into the original string, so it advances by the right amount.
      clusterIndex += rune > 0xFFFF ? 2 : 1;
    }

    tables.gsub?.apply(
      _buffer,
      features: _activeFeatures,
      script: script,
      language: language,
      gdef: tables.gdef,
    );

    // Advances are loaded *after* substitution because substitution decides
    // which glyphs there are: an "fi" ligature is one advance, not two.
    for (int i = 0; i < _buffer.length; i++) {
      _buffer.xAdvances[i] = face.advanceOf(_buffer.glyphs[i]);
    }

    tables.gpos?.apply(
      _buffer,
      features: _activeFeatures,
      script: script,
      language: language,
      gdef: tables.gdef,
    );

    final KernTable? kern = applyKerning ? tables.kern : null;
    if (kern != null) {
      // Reached only when GPOS offered no `kern` feature - see [_FaceTables].
      // The adjustment lands on the left glyph's advance, which is the same
      // total width as moving the right glyph back and the same per-glyph
      // positions too, since the pen accumulates advances.
      for (int i = 0; i + 1 < _buffer.length; i++) {
        _buffer.xAdvances[i] +=
            kern.between(_buffer.glyphs[i], _buffer.glyphs[i + 1]);
      }
    }

    _buffer.resolveAttachments(rightToLeft: direction.isRightToLeft);
    // Logical order until now, because that is the order the font's rules are
    // written in. Visual order is produced once, here.
    if (direction.isRightToLeft) _buffer.reverse();

    final int count = _buffer.length;
    _ensureCapacity(count);
    final double scale = font.scale;
    double penX = 0;
    double penY = 0;
    for (int i = 0; i < count; i++) {
      _glyphIds[i] = _buffer.glyphs[i];
      _clusters[i] = _buffer.clusters[i];
      _positions[i * 2] = (penX + _buffer.xOffsets[i]) * scale;
      // Negated: font units are y-up and a run's positions are y-down.
      _positions[i * 2 + 1] = -(penY + _buffer.yOffsets[i]) * scale;
      penX += _buffer.xAdvances[i];
      penY += _buffer.yAdvances[i];
    }

    return GlyphRun(
      font: font,
      glyphIds: _glyphIds,
      positions: _positions,
      clusters: _clusters,
      length: count,
      width: penX * scale,
      direction: direction,
    );
  }

  void _ensureCapacity(int glyphs) {
    if (_glyphIds.length >= glyphs) return;
    int capacity = _glyphIds.length;
    while (capacity < glyphs) {
      capacity *= 2;
    }
    _glyphIds = Int32List(capacity);
    _positions = Float32List(capacity * 2);
    _clusters = Int32List(capacity);
  }
}
