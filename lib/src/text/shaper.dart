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
/// This is the Latin subset, and it is deliberately the smallest correct one:
/// character-to-glyph mapping and kerning. That is enough for Portuguese and
/// every other Latin-script language whose accented letters exist as
/// precomposed glyphs, which is essentially all of them.
///
/// What it is **not**, stated so the gap is on the record rather than
/// discovered later: no `GSUB` (so no ligatures and no language-specific
/// forms), no `GPOS` beyond kerning (so no mark attachment for decomposed
/// text), no bidi, no script itemization, no line breaking. Section 30 owns
/// those, and the interfaces here are shaped so they can be added without a
/// rewrite - see [Shaper] and the cluster field on [GlyphRun].
library;

import 'dart:typed_data';

import 'kern.dart';
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
  /// Present from the first version even though nothing consumes it yet,
  /// because everything that will - caret placement, selection, hit testing,
  /// and the reordering that Indic and Arabic shaping need - depends on it,
  /// and retrofitting it means touching every layer above.
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
  double yOf(int index) => positions[index * 2 + 1];

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
