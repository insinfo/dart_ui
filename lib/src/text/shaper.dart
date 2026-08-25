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
/// ## Script, language and direction arrive per run, not per shaper
///
/// A paragraph is not one script. "Total: ١٢٣ ريال" is Latin, then Arabic, then
/// Latin again, and each stretch needs a different OpenType script tag, a
/// different feature order and possibly a different direction. A shaper with a
/// fixed script would have to be built once per run to shape that sentence -
/// three shapers, three sets of scratch buffers, three parsed copies of the
/// font's layout tables, for one line of text - so [Shaper.shape] takes the
/// script, the language and the direction as arguments and the shaper keeps
/// only what is genuinely per-font.
///
/// The script is a Unicode [Script], not an OpenType tag, because the mapping
/// between them is not one-to-one and depends on the font: the Indic scripts
/// have two registered tags each, and `openTypeTagsOf` returns every tag worth
/// trying, newest first. Resolving that against the font's own script list is
/// this file's job, not the caller's.
///
/// ## What is still missing, named
///
/// Line breaking and bidi live elsewhere; direction reaches this file as a
/// resolved fact rather than being guessed here. Of the script-specific models,
/// Arabic joining is implemented (`shapers/arabic.dart`) and the Indic, Khmer,
/// Myanmar and Universal Shaping Engine models are not - and a run that needs
/// one of them is **refused by name** rather than shaped approximately, because
/// the approximate result is legible-looking and wrong. See
/// `shapers/script_models.dart`.
library;

import 'dart:typed_data';

import 'gpos.dart';
import 'gsub.dart';
import 'kern.dart';
import 'layout_common.dart';
import 'script.dart';
import 'shapers/arabic.dart';
import 'shapers/script_models.dart';
import 'typeface.dart';

export 'script.dart' show Script;
export 'shapers/arabic.dart'
    show ArabicJoiningForm, ArabicMaskLimitException, arabicJoiningForms;
export 'shapers/script_models.dart'
    show
        ShapingModel,
        UnsupportedScriptException,
        UnsupportedScriptPolicy,
        UnsupportedScriptReporter,
        shapingModelForTag;

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

/// Turns one script run of text into positioned glyphs.
///
/// The unit is a **run**: one script, one language, one direction, one font.
/// Splitting a paragraph into runs is `itemize`'s job for script and bidi's for
/// direction, and both happen above this interface - a shaper is handed the
/// answer rather than asked to guess it.
///
/// All three of [shape]'s descriptive arguments are per call, so one shaper
/// instance shapes a whole mixed-script paragraph while reusing one set of
/// scratch buffers and one parsed copy of each font's layout tables. That is
/// the reason they are arguments and not constructor parameters, and it is a
/// hot-path property rather than an aesthetic one.
abstract interface class Shaper {
  /// Shapes [text] with [font].
  ///
  /// [script] is the Unicode script of the run, as `itemize` resolves it, and
  /// it selects both the OpenType script tag and the shaping model. Null means
  /// "whatever this shaper was built for", which is the single-script case -
  /// mixed-script text has to name it per run or it gets one script's rules
  /// applied to all of them.
  ///
  /// [language] is an OpenType language system tag such as `TRK` or `URD`,
  /// refining the script; null asks for the shaper's own, and failing that the
  /// script's default, which is what nearly all text wants.
  ///
  /// [direction] is the resolved bidi direction of the run, and it is *not*
  /// inferred from [script]: a Hebrew word quoted inside an English sentence is
  /// still a right-to-left run, and a lone Arabic word inside a left-to-right
  /// technical string may not be. Direction comes from bidi resolution, which
  /// has the paragraph in view; a shaper has one run in view and cannot answer.
  GlyphRun shape(
    String text,
    ScaledTypeface font, {
    Script? script,
    String? language,
    TextDirection direction,
  });
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

  /// Shapes [text], ignoring [script] and [language].
  ///
  /// Accepting them and doing nothing with them is the honest signature: this
  /// shaper has no script-specific behaviour at all, by design, and pretending
  /// otherwise by refusing the arguments would only force every caller to
  /// branch on which shaper it holds. What it *cannot* do is shape a script
  /// that needs a model - Arabic through here is a row of isolated letterforms
  /// - which is why [OpenTypeShaper] exists and why this one is documented as
  /// the diagnostics-and-monospace shaper rather than the small default.
  @override
  GlyphRun shape(
    String text,
    ScaledTypeface font, {
    Script? script,
    String? language,
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

/// The four layout tables a face contributes to shaping, parsed once.
///
/// Held per face rather than per run because parsing them is the expensive
/// part - a script list, a feature list and a lookup directory - and a face is
/// shaped with thousands of times.
final class _FaceTables {
  _FaceTables._(this.gsub, this.gpos, this.gdef, this.kern);

  final GsubTable? gsub;
  final GposTable? gpos;
  final GdefTable? gdef;

  /// The legacy kerning table, parsed if the font has one.
  ///
  /// Whether it may be *used* is not a property of the face - it is a property
  /// of the face and the script together, because a font may offer a `GPOS`
  /// `kern` feature under `latn` and none under `arab`. Deciding it once per
  /// face, as this used to, is only right while every run is Latin; see
  /// [_ScriptPlan.gposKerns], which is where the decision moved to when script
  /// became a per-run argument.
  final KernTable? kern;

  static _FaceTables read(Typeface face) => _FaceTables._(
        GsubTable.parse(face.sfnt),
        GposTable.parse(face.sfnt),
        GdefTable.parse(face.sfnt),
        KernTable.parse(face.sfnt),
      );

  final Map<Script, String> _tags = <Script, String>{};
  final Map<String, Map<String?, _ScriptPlan>> _plans =
      <String, Map<String?, _ScriptPlan>>{};

  /// The OpenType script tag to shape [script] with **in this font**.
  ///
  /// `openTypeTagsOf` returns every tag worth trying, best first, and the
  /// choice between them cannot be made without the font: Devanagari is `dev2`
  /// in anything compiled this century and `deva` in older faces, and the two
  /// tags select different rules written for different shaping models. The
  /// first tag the font actually names wins; `DFLT` closes the list, and a font
  /// that names none of them gets it - where `ScriptList.resolve` then applies
  /// its own last-resort fallbacks.
  ///
  /// One tag is resolved for both tables, not one each. That is exact whenever
  /// a font's `GSUB` and `GPOS` agree, which they do unless a face carries the
  /// v1 tag in one and the v2 tag in the other - a mismatch that only exists
  /// for the Indic scripts, whose model is refused outright.
  ///
  /// Memoised per script because a paragraph asks the same question once per
  /// run and the answer is a property of the font.
  String tagFor(Script script) {
    final String? known = _tags[script];
    if (known != null) return known;
    final List<String> candidates = openTypeTagsOf(script);
    String chosen = candidates.last;
    for (final String tag in candidates) {
      if ((gsub?.header.scriptList.scripts.containsKey(tag) ?? false) ||
          (gpos?.header.scriptList.scripts.containsKey(tag) ?? false)) {
        chosen = tag;
        break;
      }
    }
    _tags[script] = chosen;
    return chosen;
  }

  /// What this font offers for one script tag and language system.
  ///
  /// Two nested maps rather than one keyed by a joined string, because joining
  /// two strings to look something up allocates on every run.
  _ScriptPlan planFor(String tag, String? language) {
    final Map<String?, _ScriptPlan> byLanguage =
        _plans[tag] ??= <String?, _ScriptPlan>{};
    return byLanguage[language] ??= _ScriptPlan._(this, tag, language);
  }
}

/// The per-script answers that would otherwise be recomputed every run.
///
/// Everything here is a question about a (face, script, language) triple whose
/// answer never changes, and every one of them costs a walk of a feature index
/// list to answer. A paragraph of forty runs would ask them forty times.
final class _ScriptPlan {
  _ScriptPlan._(this._tables, this._tag, this._language)
      : gposKerns = _tables.gpos
                ?.hasFeature('kern', script: _tag, language: _language) ??
            false;

  final _FaceTables _tables;
  final String _tag;
  final String? _language;

  /// Whether `GPOS` kerns this script, and therefore whether the legacy `kern`
  /// table must be left alone.
  ///
  /// A font that offers a `kern` feature in `GPOS` has said everything it has
  /// to say about kerning, and applying the old table as well would narrow
  /// every kerned pair by twice its designed amount. DejaVu ships both, with
  /// identical values, so the bug this prevents is precisely a doubling.
  final bool gposKerns;

  /// Which of [arabicGsubFeatures] the font states for this script.
  ///
  /// Built on first use rather than in the constructor: ten feature lookups is
  /// cheap, but it is ten lookups no Latin run has any use for.
  Set<String> get arabicGsubOffered => _arabicGsubOffered ??= <String>{
        for (final String tag in arabicGsubFeatures)
          if (_tables.gsub
                  ?.hasFeature(tag, script: _tag, language: _language) ??
              false)
            tag,
      };

  Set<String>? _arabicGsubOffered;
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
///
/// ## Step 2 is not one step for every script
///
/// For a script with [ShapingModel.simple] it is one call: every enabled
/// feature at once, lookups in index order, which is what the spec says and
/// what the font was compiled against. For Arabic it is a sequence of stages in
/// a fixed order, four of which are applied to individual glyphs rather than to
/// the run - see `shapers/arabic.dart`. For Indic, Khmer, Myanmar and the USE
/// scripts there is no implementation, and a run needing one is refused by name
/// rather than pushed through the simple path; see [unsupportedScript].
final class OpenTypeShaper implements Shaper {
  OpenTypeShaper({
    this.features = defaultFeatures,
    this.applyKerning = true,
    this.script = 'latn',
    this.language,
    this.unsupportedScript = UnsupportedScriptPolicy.fail,
    this.onUnsupportedScript,
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

  /// The OpenType script tag to use when [shape] is not told one.
  ///
  /// A raw four-character tag, used as written and *not* resolved against the
  /// font: it is the escape hatch for a caller that knows exactly which tag it
  /// wants, and for the single-script case where naming it once is less noise
  /// than naming it per call.
  ///
  /// It is a default, not a fixture. A paragraph is not one script - "Total:
  /// ١٢٣ ريال" is three runs - and shaping all of them under one tag applies
  /// one script's rules to the others, which does not fail, it merely produces
  /// disconnected Arabic. The per-run argument to [shape] is the mechanism for
  /// that case, and it takes a [Script] rather than a tag precisely so the tag
  /// can be resolved against the font's own script list.
  final String script;

  /// The language system tag to use when [shape] is not told one.
  ///
  /// The same relationship to [shape]'s argument as [script] has: a default,
  /// overridden per run.
  final String? language;

  /// What to do with a run whose script needs a model that is not implemented.
  ///
  /// [UnsupportedScriptPolicy.fail] by default. The alternative is not a silent
  /// fallback: it reports through [onUnsupportedScript] and then shapes with
  /// the simple model, which produces text a reader of that script cannot use.
  final UnsupportedScriptPolicy unsupportedScript;

  /// Where the report goes when [unsupportedScript] is
  /// [UnsupportedScriptPolicy.shapeAsSimple].
  ///
  /// Null means the run is shaped approximately and nothing is said, which is
  /// the one configuration of this shaper that can produce wrong text quietly.
  /// It takes two deliberate choices to reach.
  final UnsupportedScriptReporter? onUnsupportedScript;

  final Map<Typeface, _FaceTables> _tables = <Typeface, _FaceTables>{};
  final GlyphBuffer _buffer = GlyphBuffer();

  /// The joining machine, built on first use.
  ///
  /// One per shaper, not one per run: it owns the form array and the scratch
  /// buffer the positional features are masked through, and both are reused.
  late final ArabicShaper _arabic = ArabicShaper();

  Int32List _glyphIds = Int32List(64);
  Float32List _positions = Float32List(128);
  Int32List _clusters = Int32List(64);

  /// The features actually enabled, honouring [applyKerning].
  late final Set<String> _activeFeatures = <String>{
    for (final String feature in features)
      if (applyKerning || feature != 'kern') feature,
  };

  /// [_activeFeatures] plus the positioning features Arabic adds.
  ///
  /// Built once rather than per run, and only for a shaper that ever sees a
  /// cursive run.
  late final Set<String> _arabicGposFeatures = <String>{
    ..._activeFeatures,
    ...arabicGposFeatures,
  };

  @override
  GlyphRun shape(
    String text,
    ScaledTypeface font, {
    Script? script,
    String? language,
    TextDirection direction = TextDirection.leftToRight,
  }) {
    final Typeface face = font.typeface;
    final _FaceTables tables =
        _tables.putIfAbsent(face, () => _FaceTables.read(face));

    // Two different tags, and conflating them is a real bug. The model is
    // chosen from the *script's* canonical tag, because Arabic text needs the
    // joining machine whether or not this particular font has an `arab` script
    // table; the features are looked up under the tag the font actually names.
    // A caller that gave a raw tag instead of a [Script] gets that tag for
    // both, which is what "used as written" means.
    final String modelTag =
        script == null ? this.script : openTypeTagOf(script);
    final String tag = script == null ? this.script : tables.tagFor(script);
    final String? languageTag = language ?? this.language;
    final _ScriptPlan plan = tables.planFor(tag, languageTag);

    ShapingModel model = shapingModelForTag(modelTag);
    if (!model.isImplemented) {
      final UnsupportedScriptException report =
          UnsupportedScriptException(modelTag, model);
      if (unsupportedScript == UnsupportedScriptPolicy.fail) throw report;
      onUnsupportedScript?.call(report);
      model = ShapingModel.simple;
    }

    _buffer.clear();
    int clusterIndex = 0;
    for (final int rune in text.runes) {
      _buffer.add(face.glyphForCodePoint(rune), clusterIndex);
      // A code point above the BMP occupies two UTF-16 units and the cluster
      // index is into the original string, so it advances by the right amount.
      clusterIndex += rune > 0xFFFF ? 2 : 1;
    }

    if (model == ShapingModel.arabic) {
      // The joining analysis runs on the *text*, not on the buffer: it is a
      // property of the characters, and it has to exist before any substitution
      // has had a chance to change what the glyphs are.
      _arabic.planJoining(text);
      _arabic.substitute(
        _buffer,
        face: face,
        gsub: tables.gsub,
        gdef: tables.gdef,
        script: tag,
        language: languageTag,
        enabled: _activeFeatures,
        offered: plan.arabicGsubOffered,
      );
    } else {
      tables.gsub?.apply(
        _buffer,
        features: _activeFeatures,
        script: tag,
        language: languageTag,
        gdef: tables.gdef,
      );
    }

    // Advances are loaded *after* substitution because substitution decides
    // which glyphs there are: an "fi" ligature is one advance, not two.
    for (int i = 0; i < _buffer.length; i++) {
      _buffer.xAdvances[i] = face.advanceOf(_buffer.glyphs[i]);
    }

    tables.gpos?.apply(
      _buffer,
      features:
          model == ShapingModel.arabic ? _arabicGposFeatures : _activeFeatures,
      script: tag,
      language: languageTag,
      gdef: tables.gdef,
      // The parameter `gpos.dart` documents as a live gap. It is the run's
      // direction, and the run's direction is an argument now, so it is simply
      // passed: a cursive join in a right-to-left run trims the advance of the
      // glyph that trails the pen, which is the *second* glyph of the pair in
      // logical order, not the first.
      rightToLeft: direction.isRightToLeft,
    );

    final KernTable? kern =
        applyKerning && !plan.gposKerns ? tables.kern : null;
    if (kern != null) {
      // Reached only when GPOS offered no `kern` feature for *this script* -
      // see [_ScriptPlan.gposKerns].
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

// ---------------------------------------------------------------------------
// Cache
// ---------------------------------------------------------------------------

/// Shaped runs, keyed by everything that changes one.
///
/// The single-run API - a label, a button caption, a grid cell - has no
/// [Paragraph] to hang a layout on, so before this existed every one of them
/// ran the whole `GSUB`/`GPOS` pipeline again on **every paint**, which is to
/// say on every frame. The tree was never the problem; the shaping was.
///
/// This is [ParagraphCache] one level down, deliberately: the same LRU, the
/// same "insertion order is recency order" trick that makes eviction O(1)
/// without a second structure, the same reasoning about what belongs in the
/// key. Two caches rather than one because they hold two different things -
/// a laid-out paragraph and a shaped run - but one policy, written once here
/// and once there, so they cannot drift into disagreeing about eviction.
///
/// ## What is in the key
///
/// Every argument [shape] takes, because every one of them changes the answer:
///
///  * the text, by value;
///  * the [ScaledTypeface], which compares by face *identity* and pixel size -
///    the same rule [ParagraphCache] uses, and for the same reason: a
///    [Typeface] is parsed bytes with no meaningful value equality, and
///    re-parsing the same file legitimately produces a face that may shape
///    differently;
///  * the [Script], the OpenType language tag and the resolved [TextDirection],
///    which between them pick the shaping model, the feature list and the
///    visual order.
///
/// Not in the key: the wrapped [shaper], which is a property of the cache
/// rather than of the request - a cache built around a different shaper is a
/// different cache.
///
/// ## The entries own their arrays
///
/// A [Shaper] returns a run that borrows its scratch buffers and is valid only
/// until the next call, which is exactly right for a caller that draws
/// immediately and exactly wrong for a cache. So a miss copies the run into
/// arrays sized to it before storing it, once, at the cost [Paragraph] already
/// pays per run at layout time. A run handed back from here is therefore
/// *more* durable than the interface promises, never less.
///
/// ## Invalidation
///
/// None, by design, for [ParagraphCache]'s reason: every input is immutable and
/// value-compared, so an entry cannot go stale. Replacing a [Typeface] produces
/// new [ScaledTypeface] instances and hence new keys, so the old entries become
/// unreachable rather than wrong, and age out. [clear] is for reclaiming them.
final class GlyphRunCache implements Shaper {
  GlyphRunCache(this.shaper, {this.maximumEntries = 1024});

  /// The shaper a miss goes to.
  final Shaper shaper;

  /// How many shaped runs to keep. Least recently used goes first.
  ///
  /// Much larger than [ParagraphCache.maximumEntries], on purpose and with a
  /// measurement behind it. An entry here is one label - a few dozen glyphs,
  /// on the order of half a kilobyte with its key and its map slot - rather
  /// than a whole wrapped paragraph, and the population it has to cover is
  /// every distinct string painted in a frame. A data grid or a properties
  /// panel puts several hundred on screen at once.
  ///
  /// That matters because a cache smaller than the working set does not
  /// degrade gracefully. Every entry is evicted before it is asked for again,
  /// so the hit rate is not merely low, it is zero - and each miss then pays
  /// for the copy and the map churn on top of the shaping it was going to do
  /// anyway. Measured, painting more distinct labels per frame than fit here
  /// costs between 20% and 70% more than having no cache at all, the penalty
  /// growing with how far past the limit the frame goes.
  ///
  /// So the number has to sit above a realistic screen rather than near it. A
  /// thousand entries is on the order of half a megabyte, and it puts the
  /// cliff at a thousand distinct non-wrapping labels painted in a single
  /// frame - a frame that, before any of this existed, already spent about 24
  /// milliseconds shaping them and could not have run at speed either way.
  final int maximumEntries;

  final Map<_GlyphRunKey, GlyphRun> _entries = <_GlyphRunKey, GlyphRun>{};

  int _hits = 0;
  int _misses = 0;

  int get hitCount => _hits;
  int get missCount => _misses;
  int get entryCount => _entries.length;

  @override
  GlyphRun shape(
    String text,
    ScaledTypeface font, {
    Script? script,
    String? language,
    TextDirection direction = TextDirection.leftToRight,
  }) {
    final _GlyphRunKey key =
        _GlyphRunKey(text, font, script, language, direction);
    final GlyphRun? hit = _entries.remove(key);
    if (hit != null) {
      // Re-inserted so the map's insertion order is the recency order.
      _entries[key] = hit;
      _hits++;
      return hit;
    }
    _misses++;
    final GlyphRun owned = _own(
      shaper.shape(
        text,
        font,
        script: script,
        language: language,
        direction: direction,
      ),
    );
    _entries[key] = owned;
    while (_entries.length > maximumEntries) {
      _entries.remove(_entries.keys.first);
    }
    return owned;
  }

  /// A copy of [run] holding arrays sized to it rather than the shaper's.
  static GlyphRun _own(GlyphRun run) {
    final int count = run.length;
    final Int32List ids = Int32List(count);
    final Float32List positions = Float32List(count * 2);
    final Int32List clusters = Int32List(count);
    for (int i = 0; i < count; i++) {
      ids[i] = run.glyphIds[i];
      positions[i * 2] = run.positions[i * 2];
      positions[i * 2 + 1] = run.positions[i * 2 + 1];
      clusters[i] = run.clusters[i];
    }
    return GlyphRun(
      font: run.font,
      glyphIds: ids,
      positions: positions,
      clusters: clusters,
      length: count,
      width: run.width,
      direction: run.direction,
    );
  }

  void clear() {
    _entries.clear();
    _hits = 0;
    _misses = 0;
  }
}

final class _GlyphRunKey {
  _GlyphRunKey(
    this.text,
    this.font,
    this.script,
    this.language,
    this.direction,
  ) : _hash = Object.hash(text, font, script, language, direction);

  final String text;
  final ScaledTypeface font;
  final Script? script;
  final String? language;
  final TextDirection direction;
  final int _hash;

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is _GlyphRunKey &&
        other._hash == _hash &&
        other.text == text &&
        other.font == font &&
        other.script == script &&
        other.language == language &&
        other.direction == direction;
  }

  @override
  int get hashCode => _hash;
}
