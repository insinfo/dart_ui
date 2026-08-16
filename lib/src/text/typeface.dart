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
import 'cff.dart';
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
    required this.name,
    required this.os2,
    required this.post,
    required this.verticalMetrics,
    required this.identityIssues,
    required GlyfTable? glyf,
    required CffFont? cff,
  })  : _glyf = glyf,
        _cff = cff;

  final SfntFile sfnt;
  final HeadTable head;
  final MaxpTable maxp;
  final HheaTable hhea;
  final HmtxTable hmtx;
  final CmapTable cmap;

  /// `name` - the strings this face is *selected* by, or null when the file
  /// carries no such table.
  ///
  /// Null is legal and rare: a face without `name` has no family, so a font
  /// manager can only ever address it by path. Nothing here needs it to draw.
  final NameTable? name;

  /// `OS/2` - weight, width, style bits and the coverage summary, or null.
  ///
  /// The one table font *matching* cannot do without. When it is absent the
  /// style axes are inferred from `head.macStyle` and said to be inferred; see
  /// [declaresStyle], which exists so a matcher can prefer a face that states
  /// its weight over one that had a weight guessed for it.
  final Os2Table? os2;

  /// `post` - fixed pitch, italic angle, underline placement, glyph names.
  final PostTable? post;

  /// The line box this face asks for, in font units, resolved once.
  ///
  /// Resolved by [VerticalMetrics.resolve], which is the whole reason these
  /// three tables are parsed here rather than by each caller: `hhea`, `sTypo*`
  /// and `usWin*` disagree in most real fonts, and the choice between them
  /// changes the height of every paragraph. Making it once, at parse time,
  /// means a face cannot lay out at two different heights in one process.
  final VerticalMetrics verticalMetrics;

  /// Everything that went wrong while reading the *identity* tables.
  ///
  /// Empty for a well-formed face, which is the overwhelming case.
  ///
  /// The split this list encodes: `head`, `maxp`, `hhea`, `hmtx`, `cmap` and
  /// the outlines are load-bearing, and a malformed one of those throws, because
  /// a face that cannot be drawn correctly must not be drawn incorrectly. The
  /// three identity tables are advisory - a face with a corrupt `name` still
  /// draws perfectly - so refusing the whole file over one of them would trade
  /// "this font sorts oddly in a font menu" for "this application shows no
  /// text". They are therefore skipped, and **recorded here**: silence would
  /// leave a face indexed as Regular 400 with nobody able to find out that its
  /// `OS/2` was unreadable.
  final List<String> identityIssues;

  /// TrueType outlines, when the face has a `glyf` table.
  ///
  /// Exactly one of [_glyf] and [_cff] is non-null. They are the two outline
  /// formats OpenType allows and a file carries one or the other; a file with
  /// both is malformed, and [Typeface.parse] prefers `glyf` in that case
  /// because that is the path with a hinting interpreter behind it.
  final GlyfTable? _glyf;

  /// PostScript outlines, when the face has a `CFF `/`CFF2` table.
  final CffFont? _cff;

  /// The CFF container, for callers that need glyph names, CIDs or the hint
  /// parameters. Null for a TrueType face.
  CffFont? get cff => _cff;

  /// Whether this face's outlines are PostScript charstrings rather than
  /// TrueType quadratics.
  ///
  /// Worth exposing because it changes what a caller can expect: a CFF outline
  /// contains cubics, and it is never hinted by this engine (see [outlineOf]).
  bool get isCff => _cff != null;

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
  final Map<_GlyphCacheKey, double> _hintedAdvances =
      <_GlyphCacheKey, double>{};

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
  static bool shouldHint(double ppem) => ppem > 0 && ppem <= maxHintedPixelSize;

  /// Font design units per em.
  int get unitsPerEm => head.unitsPerEm;

  int get glyphCount => maxp.numGlyphs;

  /// Parses [bytes] as a font face, TrueType or CFF.
  ///
  /// Which outline format the face uses is decided by the tables it actually
  /// carries, not by the sfnt version tag. The tag is a good hint and a bad
  /// rule: variable CFF2 faces ship under both `OTTO` and `0x00010000`, and a
  /// handful of tools emit `OTTO` over a `glyf` table. Reading the directory
  /// costs nothing here and removes a whole class of "this font opens
  /// everywhere except in ours".
  ///
  /// Throws [FontFormatException] for a malformed file and
  /// [CffUnsupportedFeature] for a well-formed CFF that uses something this
  /// engine refuses to guess at - a variable CFF2 above all. Both are thrown,
  /// rather than degraded to a blank face, because a font that cannot be drawn
  /// correctly must not be drawn incorrectly.
  factory Typeface.parse(Uint8List bytes, {int faceIndex = 0}) {
    final FontData data = FontData(bytes);
    final SfntFile sfnt = SfntFile.parse(data, faceIndex: faceIndex);

    final HeadTable head = HeadTable.parse(sfnt);
    final MaxpTable maxp = MaxpTable.parse(sfnt);
    final HheaTable hhea = HheaTable.parse(sfnt);
    final CmapTable cmap = CmapTable.parse(sfnt);
    final HmtxTable hmtx = HmtxTable.parse(sfnt, hhea, maxp);

    GlyfTable? glyf;
    CffFont? cff;
    switch (sfnt.outlineTable) {
      case 'glyf':
        final LocaTable loca = LocaTable.parse(sfnt, head, maxp);
        glyf = GlyfTable.parse(sfnt, loca, hmtx: hmtx);
      case 'CFF ':
      case 'CFF2':
        // unitsPerEm is passed so the charstrings' FontMatrix is folded into
        // the output and CFF outlines arrive in the same units `glyf` ones do.
        // See the "Units" section of `cff.dart`.
        cff = CffFont.fromSfnt(sfnt, unitsPerEm: head.unitsPerEm);
      default:
        throw const FontFormatException(
          'the face has neither a "glyf" nor a "CFF "/"CFF2" table, so it '
          'carries no outlines at all',
        );
    }

    // The identity tables. Each is optional by specification and advisory in
    // practice, so a failure is collected rather than thrown - see
    // [identityIssues] for the rule and why it differs from the tables above.
    final List<String> issues = <String>[];
    final NameTable? name = _optional(
      () => NameTable.parse(sfnt),
      'name',
      issues,
    );
    final Os2Table? os2 = _optional(
      () => Os2Table.parse(sfnt),
      'OS/2',
      issues,
    );
    final PostTable? post = _optional(
      () => PostTable.parse(sfnt),
      'post',
      issues,
    );

    // A face with no usable line box at all: `hhea` empty and no `OS/2` to
    // fall back to. Recorded rather than thrown for the same reason - it is a
    // face that draws glyphs and cannot say how tall a line of them is, and a
    // caller that cares reads [identityIssues] or
    // [VerticalMetrics.source].
    VerticalMetrics metrics;
    try {
      metrics = VerticalMetrics.resolve(hhea: hhea, os2: os2);
    } on FontFormatException catch (error) {
      issues.add('vertical metrics: ${error.message}');
      metrics = VerticalMetrics(
        ascent: hhea.ascender,
        descent: hhea.descender,
        lineGap: hhea.lineGap,
        source: VerticalMetricsSource.horizontalHeader,
      );
    }

    return Typeface._(
      sfnt: sfnt,
      head: head,
      maxp: maxp,
      hhea: hhea,
      hmtx: hmtx,
      cmap: cmap,
      name: name,
      os2: os2,
      post: post,
      verticalMetrics: metrics,
      identityIssues: List<String>.unmodifiable(issues),
      glyf: glyf,
      cff: cff,
    );
  }

  /// Runs [parse] for an advisory table, recording a failure instead of
  /// propagating it.
  static T? _optional<T>(T? Function() parse, String tag, List<String> issues) {
    try {
      return parse();
    } on FontFormatException catch (error) {
      issues.add('$tag: ${error.message}');
      return null;
    }
  }

  // --- identity, for font matching -----------------------------------------

  /// The family a user means - name 16, else name 1 - or null.
  String? get familyName => name?.family;

  /// The style within [familyName] - name 17, else name 2 - or null.
  String? get subfamilyName => name?.subfamily;

  /// Whether the face states its own style axes, rather than having them
  /// inferred.
  ///
  /// False means [weightClass], [widthClass] and [isItalic] below came from
  /// `head.macStyle`, which can only say bold and italic: a Semibold Condensed
  /// face with no `OS/2` is indistinguishable from Regular there. A matcher
  /// should break ties in favour of a face that declares its axes, because the
  /// alternative is choosing a face on a number nobody wrote.
  bool get declaresStyle => os2 != null;

  /// 1..1000, where 400 is Regular and 700 is Bold.
  ///
  /// Falls back to 700/400 from `head.macStyle` when there is no `OS/2`. That
  /// is an inference, not a reading - see [declaresStyle].
  int get weightClass => os2?.weightClass ?? (head.isBold ? 700 : 400);

  /// 1..9, where 5 is Normal. Falls back to 5, since `head` cannot express
  /// width at all.
  int get widthClass => os2?.widthClass ?? 5;

  /// Whether the face slants. `OS/2.fsSelection` wins over `head.macStyle`
  /// when both are present, per the note on [Os2Table.isItalic].
  bool get isItalic => os2?.isItalic ?? head.isItalic;

  /// Whether the slant is a shear rather than a separate italic design.
  ///
  /// Always false without `OS/2`: bit 9 has no equivalent in `head`, and
  /// reporting "oblique" for a face that never said so would let a matcher
  /// substitute it where a true italic was asked for.
  bool get isOblique => os2?.isOblique ?? false;

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

  /// Whether this face has a glyph for [codePoint]. The authoritative answer.
  ///
  /// One binary search in `cmap`, no allocation, safe to call per candidate
  /// face during fallback. Contrast [declaresCodePoint], which is cheaper still
  /// and only a claim.
  bool coversCodePoint(int codePoint) =>
      cmap.glyphFor(codePoint) != notdefGlyph;

  /// Whether `OS/2` *claims* coverage of [codePoint]'s block.
  ///
  /// The cheap first pass of font fallback: four masked reads against a
  /// coverage summary the manufacturer wrote, versus opening and searching a
  /// `cmap`. It is a filter and never a verdict - fonts set bits for blocks
  /// they half-cover, subsetters strip glyphs and leave the bits behind, and
  /// entire scripts encoded after 2008 have no bit at all. False here on a face
  /// that would in fact render the character is normal. **The truth is
  /// [coversCodePoint]**, and every fallback decision must end there.
  ///
  /// Faces with no `OS/2` answer false, which is why a fallback chain must
  /// still try them by `cmap` before giving up.
  bool declaresCodePoint(int codePoint) =>
      os2?.declaresCodePoint(codePoint) ?? false;

  /// The glyph for [baseCodePoint] under [variationSelector], or null.
  ///
  /// Format 14 of `cmap`, which is what decides text versus emoji presentation
  /// for a `U+FE0E`/`U+FE0F` pair and which ideographic variant a CJK sequence
  /// draws. Null means the face declares nothing about the pair; the caller
  /// then drops the selector and renders the base alone, as Unicode prescribes,
  /// or looks for another face. See [CmapTable.glyphForVariation].
  int? glyphForVariation(int baseCodePoint, int variationSelector) =>
      cmap.glyphForVariation(baseCodePoint, variationSelector);

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
  ///
  /// A CFF face ignores [ppem] entirely and always takes the unhinted path.
  /// PostScript hinting is a different mechanism from TrueType's - declarative
  /// zones and stem widths interpreted by the rasteriser, not a bytecode
  /// program - and none of it is implemented. The hint data *is* parsed and
  /// reachable through [cff]; **it is simply not applied**, so CFF text at
  /// small sizes is unhinted. Saying so here beats letting a caller infer it
  /// from a `ppem` argument that quietly does nothing.
  Path outlineOf(int glyphId, [double ppem = 0.0]) {
    final GlyfTable? glyf = _glyf;

    // Unhinted: the design outline, which is the same whatever size it will be
    // drawn at. One entry per glyph, shared by every size.
    if (glyf == null || !shouldHint(ppem)) {
      final Path? cached = _outlines[glyphId];
      if (cached != null) return cached;
      final Path path = glyf == null
          ? _cff!.outlineOf(glyphId).path
          : glyf.decode(glyphId).path;
      _outlines[glyphId] = path;
      return path;
    }

    final _GlyphCacheKey key = (glyphId: glyphId, ppem: ppem);
    final Path? cached = _hintedOutlines[key];
    if (cached != null) return cached;

    // TODO: pass ppem into decode once the interpreter runs fpgm and prep;
    // until then this produces the same geometry as the unhinted path and the
    // two caches simply hold equal values.
    final GlyphOutline decoded = glyf.decode(glyphId);
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
  ///
  /// Cheap for `glyf` - a `loca` length - and not cheap for CFF, where the
  /// only way to know is to interpret the charstring. The CFF answer routes
  /// through [outlineOf] so that the decode is cached rather than repeated.
  bool hasOutline(int glyphId) {
    final GlyfTable? glyf = _glyf;
    if (glyf != null) return glyf.hasOutline(glyphId);
    return !outlineOf(glyphId).isEmpty;
  }

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
  ///
  /// Taken from [Typeface.verticalMetrics], **not** from `hhea` directly: a
  /// font states its line box up to three times and the three disagree, so the
  /// choice is made once by [VerticalMetrics.resolve] and every size shares it.
  /// For a font that sets `USE_TYPO_METRICS` this is materially shorter than
  /// `hhea` - the designer said so - and for every other font it is `hhea`
  /// exactly, which is what the rest of the industry draws.
  double get ascent => typeface.verticalMetrics.ascent * scale;

  /// Distance from the baseline to the bottom, in pixels, **positive down**.
  ///
  /// The resolved descent is negative in a well-formed font because y is up
  /// there; negating it here means every caller adds ascent and descent rather
  /// than having to remember which one is signed.
  double get descent => -typeface.verticalMetrics.descent * scale;

  double get lineGap => typeface.verticalMetrics.lineGap * scale;

  /// Which of the three sources the line box above came from, for a diagnostic
  /// that would otherwise be "this paragraph is taller than the designer's".
  VerticalMetricsSource get metricsSource => typeface.verticalMetrics.source;

  /// The distance between consecutive baselines.
  double get lineHeight => ascent + descent + lineGap;

  /// Advance width of [glyphId], in pixels.
  double advanceOf(int glyphId) =>
      typeface.advanceOf(glyphId, pixelSize) * scale;

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
