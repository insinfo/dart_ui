/// A font face: the parsed tables, plus the two questions a renderer asks.
///
/// Those two questions are "which glyph draws this character" and "how wide is
/// it", and everything above this layer - shaping, layout, the glyph cache -
/// is built from them. A [Typeface] is immutable, holds no device state and
/// keeps no rendering configuration, which is the rule from section 22.7: the
/// parser produces outlines and metrics, and each renderer decides for itself
/// what to do with them.
///
/// Sizes live in [ScaledTypeface], not here. A face is loaded once and drawn at
/// many sizes, so baking a size into it would mean parsing the font again per
/// size.
library;

import 'dart:typed_data';

import '../geometry/path.dart';
import 'cmap.dart';
import 'font_data.dart';
import 'font_tables.dart';
import 'glyf.dart';
import 'sfnt.dart';

typedef _GlyphCacheKey = ({int glyphId, double ppem});

/// One parsed font face.
final class Typeface {
  Typeface._({
    required this.sfnt,
    required this.head,
    required this.maxp,
    required this.hhea,
    required this.hmtx,
    required this.cmap,
    required GlyfTable glyf,
  }) : _glyf = glyf;

  final SfntFile sfnt;
  final HeadTable head;
  final MaxpTable maxp;
  final HheaTable hhea;
  final HmtxTable hmtx;
  final CmapTable cmap;
  final GlyfTable _glyf;

  /// Unhinted outlines, keyed by glyph id alone.
  ///
  /// The design coordinates of a glyph do not depend on the size it will be
  /// drawn at - scaling is a transform applied later - so this cache has one
  /// entry per glyph and is bounded by the face's glyph count. That is what
  /// makes it safe to leave unbounded: a face retains at most a few thousand
  /// paths and only for as long as it is in use.
  final Map<int, Path> _outlines = <int, Path>{};

  /// Hinted outlines, keyed by glyph id **and** ppem.
  ///
  /// Hinting *is* a function of the pixel size, so this one genuinely needs
  /// the size in its key - and is therefore unbounded in a way the other is
  /// not. A UI that animates a scale, or a zoom, would grow it without limit,
  /// so it evicts. See [_rememberHinted].
  final Map<_GlyphCacheKey, Path> _hintedOutlines = <_GlyphCacheKey, Path>{};

  /// Advances the hinting program changed, keyed by glyph and ppem.
  ///
  /// Only populated when hinting actually ran *and* moved the phantom points.
  /// An entry's absence is the common case and means "ask `hmtx`", which is an
  /// array read - see [advanceOf] for why that distinction is the difference
  /// between measuring a line in microseconds and in milliseconds.
  final Map<_GlyphCacheKey, double> _hintedAdvances = <_GlyphCacheKey, double>{};

  /// Insertion order over [_hintedOutlines], for eviction.
  final List<_GlyphCacheKey> _hintedOrder = <_GlyphCacheKey>[];

  /// How many hinted outlines are retained before the oldest is dropped.
  ///
  /// A number rather than a byte budget because the entries are paths of
  /// broadly similar size, and because the thing being bounded here is the
  /// *size* dimension: a handful of sizes times the glyphs actually on screen.
  /// The rendered-mask cache is where a byte budget belongs.
  static const int _maxHintedOutlines = 2048;

  /// Above this size, hinting is skipped.
  ///
  /// Hinting exists to align stems to a pixel grid, and that stops mattering
  /// once a stem is several pixels wide - every shipping text engine disables
  /// it somewhere in this range. Skipping it caps the work at the sizes where
  /// it pays, and it is also what keeps a zooming animation from running the
  /// bytecode interpreter once per frame per glyph.
  static const double maxHintedPixelSize = 24.0;

  /// Whether a glyph drawn at [ppem] should be hinted at all.
  static bool shouldHint(double ppem) =>
      ppem > 0 && ppem <= maxHintedPixelSize;

  /// Font design units per em.
  int get unitsPerEm => head.unitsPerEm;

  int get glyphCount => maxp.numGlyphs;

  /// Parses [bytes] as a font face.
  ///
  /// Throws [FontFormatException] for anything malformed, and specifically for
  /// a CFF font: those carry PostScript charstrings rather than a `glyf`
  /// table, which is a different outline format and a separate interpreter.
  /// Refusing by name beats failing later with a missing table.
  factory Typeface.parse(Uint8List bytes, {int faceIndex = 0}) {
    final FontData data = FontData(bytes);
    final SfntFile sfnt = SfntFile.parse(data, faceIndex: faceIndex);

    if (sfnt.flavour == SfntFlavour.cff) {
      throw const FontFormatException(
        'this is a CFF/OpenType font (OTTO). Its outlines are PostScript '
        'charstrings in a "CFF " table, which needs a different interpreter '
        'from the TrueType "glyf" outlines supported today',
      );
    }

    final HeadTable head = HeadTable.parse(sfnt);
    final MaxpTable maxp = MaxpTable.parse(sfnt);
    final HheaTable hhea = HheaTable.parse(sfnt);
    final CmapTable cmap = CmapTable.parse(sfnt);
    final HmtxTable hmtx = HmtxTable.parse(sfnt, hhea, maxp);
    final LocaTable loca = LocaTable.parse(sfnt, head, maxp);
    final GlyfTable glyf = GlyfTable.parse(sfnt, loca, hmtx: hmtx);

    return Typeface._(
      sfnt: sfnt,
      head: head,
      maxp: maxp,
      hhea: hhea,
      hmtx: hmtx,
      cmap: cmap,
      glyf: glyf,
    );
  }

  /// The glyph for [codePoint], or [notdefGlyph] when the face lacks it.
  int glyphForCodePoint(int codePoint) => cmap.glyphFor(codePoint);

  /// Whether every character in [text] has a glyph in this face.
  ///
  /// What font fallback is built from: a face that cannot render a run should
  /// be rejected before layout, not discovered at paint time as a row of boxes.
  bool covers(String text) {
    for (final int rune in text.runes) {
      if (cmap.glyphFor(rune) == notdefGlyph) return false;
    }
    return true;
  }

  /// Advance width of [glyphId], in font units.
  ///
  /// **This must not decode the glyph.** Measuring a line asks for one advance
  /// per character, and layout measures constantly - on every rebuild, for
  /// every label, before anything is drawn. An earlier version forced a full
  /// outline decode here to obtain the hinted advance, which turned measuring
  /// a 43-character string from 3 microseconds into 1,800: eleven percent of a
  /// frame, spent before a single pixel was produced.
  ///
  /// So the fast path is `hmtx`, an array read. A hinted advance is used only
  /// when the glyph has *already* been hinted at this size and the program
  /// actually moved the phantom points - which is the rare case, because most
  /// glyphs in most fonts leave the advance alone. Drawing a glyph populates
  /// that entry, so text that is measured and then drawn converges on the
  /// hinted value by the second layout pass, and text that is only measured
  /// never pays for hinting it did not need.
  double advanceOf(int glyphId, [double ppem = 0.0]) {
    if (ppem > 0) {
      final double? hinted = _hintedAdvances[(glyphId: glyphId, ppem: ppem)];
      if (hinted != null && hinted > 0) return hinted;
    }
    return hmtx.advanceOf(glyphId).toDouble();
  }

  /// Left side bearing of [glyphId], in font units.
  int leftSideBearingOf(int glyphId) => hmtx.leftSideBearingOf(glyphId);

  /// The outline of [glyphId] in font units, y up, cached.
  ///
  /// Y up is the font's own convention and it is kept here rather than flipped
  /// on the way out, so that this value is the font's data and nothing else.
  /// The flip belongs to [ScaledTypeface], with the rest of the device
  /// transform.
  Path outlineOf(int glyphId, [double ppem = 0.0]) {
    // Unhinted: the design outline, which is the same whatever size it will be
    // drawn at. One entry per glyph, shared by every size.
    if (!shouldHint(ppem)) {
      final Path? cached = _outlines[glyphId];
      if (cached != null) return cached;
      final GlyphOutline decoded = _glyf.decode(glyphId);
      _outlines[glyphId] = decoded.path;
      return decoded.path;
    }

    final _GlyphCacheKey key = (glyphId: glyphId, ppem: ppem);
    final Path? cached = _hintedOutlines[key];
    if (cached != null) return cached;

    // TODO: pass ppem into decode once the interpreter runs fpgm and prep;
    // until then this produces the same geometry as the unhinted path and the
    // two caches simply hold equal values.
    final GlyphOutline decoded = _glyf.decode(glyphId);
    _rememberHinted(key, decoded);
    return decoded.path;
  }

  /// Stores a hinted outline, evicting the oldest when the cache is full.
  ///
  /// Insertion-order eviction rather than true LRU: the access pattern here is
  /// a frame drawing a set of glyphs at a set of sizes, so what matters is
  /// bounding the *size* dimension, and recency within one frame is noise.
  void _rememberHinted(_GlyphCacheKey key, GlyphOutline outline) {
    if (_hintedOrder.length >= _maxHintedOutlines) {
      final _GlyphCacheKey oldest = _hintedOrder.removeAt(0);
      _hintedOutlines.remove(oldest);
      _hintedAdvances.remove(oldest);
    }
    _hintedOutlines[key] = outline.path;
    _hintedOrder.add(key);
    // Only record an advance the program actually changed. Recording the
    // unhinted value would defeat the fast path in [advanceOf] by filling the
    // map with entries that say nothing.
    final double unhinted = hmtx.advanceOf(key.glyphId).toDouble();
    if (outline.advance > 0 && outline.advance != unhinted) {
      _hintedAdvances[key] = outline.advance;
    }
  }

  /// How many outlines are retained, for diagnostics and tests.
  ({int unhinted, int hinted, int advances}) get cacheSizes => (
        unhinted: _outlines.length,
        hinted: _hintedOutlines.length,
        advances: _hintedAdvances.length,
      );

  /// Whether [glyphId] draws anything. False for a space.
  bool hasOutline(int glyphId) => _glyf.hasOutline(glyphId);

  /// This face at [pixelSize] pixels per em.
  ScaledTypeface atSize(double pixelSize) => ScaledTypeface(this, pixelSize);

  @override
  String toString() => 'Typeface(${maxp.numGlyphs} glyphs, '
      'upem $unitsPerEm, cmap ${cmap.encoding})';
}

/// A face at one size, which is what layout and painting actually use.
///
/// Cheap to create - it holds a face and a scalar - so a caller may make one
/// per draw rather than caching it.
final class ScaledTypeface {
  ScaledTypeface(this.typeface, this.pixelSize)
      : scale = pixelSize / typeface.unitsPerEm;

  final Typeface typeface;

  /// Pixels per em.
  final double pixelSize;

  /// Font units to pixels.
  final double scale;

  /// Distance from the baseline to the top of the line, in pixels.
  double get ascent => typeface.hhea.ascender * scale;

  /// Distance from the baseline to the bottom, in pixels, **positive down**.
  ///
  /// `hhea.descender` is negative in a well-formed font because y is up there;
  /// negating it here means every caller adds ascent and descent rather than
  /// having to remember which one is signed.
  double get descent => -typeface.hhea.descender * scale;

  double get lineGap => typeface.hhea.lineGap * scale;

  /// The distance between consecutive baselines.
  double get lineHeight => ascent + descent + lineGap;

  /// Advance width of [glyphId], in pixels.
  double advanceOf(int glyphId) => typeface.advanceOf(glyphId, pixelSize) * scale;

  /// Total advance of [text] with no shaping: one glyph per code point, no
  /// kerning, no ligatures.
  ///
  /// Correct for measuring a monospace run and for a first approximation
  /// everywhere else. It is not a substitute for shaping and callers that need
  /// exact placement must go through the shaper.
  double measure(String text) {
    double total = 0;
    for (final int rune in text.runes) {
      total += advanceOf(typeface.glyphForCodePoint(rune));
    }
    return total;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ScaledTypeface &&
          identical(typeface, other.typeface) &&
          pixelSize == other.pixelSize;

  @override
  int get hashCode => Object.hash(identityHashCode(typeface), pixelSize);

  @override
  String toString() =>
      'ScaledTypeface(${pixelSize.toStringAsFixed(1)}px, $typeface)';
}
