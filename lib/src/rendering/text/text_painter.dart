/// The join between shaping and drawing.
///
/// Everything below this point exists and is tested: a parser turns font bytes
/// into a [Typeface], a shaper turns a string into positioned glyphs, a
/// paragraph turns a string into lines of positioned runs, and a rasterizer
/// turns a glyph into coverage. Everything above it draws by appending to a
/// [DisplayList]. This file is the lines that connect them, and the reason it
/// is worth its own file is that it is the only place that knows the
/// run-splitting rule and the baseline convention - both of which are easy to
/// get subtly wrong and hard to notice.
///
/// It lives under `rendering/` rather than `text/` for the reason section 22.7
/// gives: the font parser must not know about renderers. A display list is a
/// rendering concept, so the file that emits one belongs on this side. That is
/// also why [Paragraph] itself carries no drawing code: it produces geometry,
/// and [paintParagraph] here is the only thing that turns it into opcodes.
///
/// ## Two levels of API, and which one to use
///
/// [paint] and [measure] take a string and a face and do the smallest correct
/// thing: one run, one line, no wrapping, no alignment, no bidi. They are what
/// a diagnostics overlay and a single-line label want.
///
/// [layout], [paintParagraph] and [measureParagraph] go through [Paragraph],
/// which is bidi, script itemization, line breaking, alignment and the caret
/// and selection queries. Anything a user can type into should use those.
library;

import 'dart:typed_data';

import '../../geometry/offset.dart';
import '../../geometry/size.dart';
import '../../graphics/display_list.dart';
import '../../graphics/display_list_opcodes.dart';
import '../../text/paragraph.dart';
import '../../text/shaper.dart';
import '../../text/typeface.dart';

/// Shapes text and appends it to a display list.
///
/// Holds a [Shaper], which holds reusable buffers, so one painter per layout
/// context rather than one per string.
final class TextPainter {
  /// [shaper] replaces the default for **both** levels of the API: the
  /// single-run calls use it directly, and the paragraph calls use it for every
  /// script instead of picking one per run.
  TextPainter({
    Shaper? shaper,
    ParagraphCache? paragraphCache,
    GlyphRunCache? runCache,
  })  : _shaper = shaper ?? sharedShaper,
        runs = runCache ?? GlyphRunCache(shaper ?? sharedShaper),
        paragraphs = paragraphCache ?? ParagraphCache(shaper: shaper);

  /// The shaper the single-run API uses.
  ///
  /// [OpenTypeShaper] rather than [LatinShaper], and the difference is not
  /// cosmetic: [LatinShaper] runs neither `GSUB` nor `GPOS`, so no ligature
  /// ever forms and a decomposed accent is drawn at its nominal advance -
  /// which for a zero-advance combining mark means at the *left edge* of the
  /// letter it belongs to. Every label in the framework drew that way until
  /// this line changed.
  ///
  /// [paint] and [measure] call it with the default script, `latn`, because
  /// choosing a script per run is itemization and itemization needs a
  /// paragraph. Non-Latin text should go through [layout], which itemizes.
  final Shaper _shaper;

  Shaper get shaper => _shaper;

  /// Laid-out paragraphs, keyed as [ParagraphCache] documents.
  ///
  /// Per painter rather than global for the same reason the shaper is: a
  /// painter is the unit of layout context, and two of them may legitimately
  /// disagree about which shaper they use.
  final ParagraphCache paragraphs;

  /// Shaped runs, keyed as [GlyphRunCache] documents.
  ///
  /// Wraps [shaper] rather than replacing it: [shaper] stays the raw pipeline a
  /// caller handed in or the default [OpenTypeShaper], so code that wants a
  /// guaranteed-fresh shaping - a benchmark, a test of the pipeline itself -
  /// still has it. Everything on the drawing path goes through here, because
  /// the drawing path shapes the same label on every frame.
  final GlyphRunCache runs;

  /// Shapes [text] with [font] through [runs].
  ///
  /// The single-run entry point every widget should use. The result is shared
  /// and immutable: unlike [Shaper.shape], it stays valid past the next call,
  /// and it must not be written to.
  GlyphRun shapeRun(
    String text,
    ScaledTypeface font, {
    Script? script,
    String? language,
    TextDirection direction = TextDirection.leftToRight,
  }) =>
      runs.shape(
        text,
        font,
        script: script,
        language: language,
        direction: direction,
      );

  /// Appends [text] to [list], with the **left end of its baseline** at
  /// [origin].
  ///
  /// Baseline, not top-left. Every font metric is expressed relative to the
  /// baseline - ascent above it, descent below - so a caller that wants to
  /// place a box around text asks the font for its ascent rather than having
  /// this guess. Callers that think in boxes use [paintInBox].
  ///
  /// Returns the shaped run so a caller can measure what it drew without
  /// shaping twice. It comes from [runs], so it is shared, immutable, and
  /// valid past the next call.
  GlyphRun paint(
    DisplayList list,
    String text,
    ScaledTypeface font,
    Offset baselineOrigin,
    int paintId,
  ) {
    final GlyphRun run = shapeRun(text, font);
    emitRun(list, run, baselineOrigin, paintId);
    return run;
  }

  /// Appends an already-shaped [run] at [baselineOrigin].
  ///
  /// Separate from [paint] because layout shapes once and may draw the same
  /// run repeatedly - a scrolling list redraws lines it already measured - and
  /// re-shaping per frame is the most common way text rendering becomes the
  /// slowest part of a frame.
  void emitRun(
    DisplayList list,
    GlyphRun run,
    Offset baselineOrigin,
    int paintId,
  ) {
    if (run.isEmpty) return;
    final int fontId = list.addFont(run.font);

    // The opcode caps a run at kMaxGlyphsPerRun because the header packs the
    // float-slot count into ten bits. Long text is therefore several runs, and
    // each one carries its own origin so the split is invisible: the second
    // run starts where the first left off, in the *run's* coordinates.
    int emitted = 0;
    while (emitted < run.length) {
      final int count = (run.length - emitted).clamp(0, kMaxGlyphsPerRun);
      final double runOriginX = baselineOrigin.dx + run.xOf(emitted);
      final double runOriginY = baselineOrigin.dy + run.yOf(emitted);

      // Offsets are relative to the run origin, and the origin of a
      // continuation run is the first glyph in it - so that glyph's offset is
      // zero and the rest are measured from it.
      final Int32List ids = _emitIds;
      final Float32List offsets = _emitOffsets;
      for (int i = 0; i < count; i++) {
        ids[i] = run.glyphIds[emitted + i];
        offsets[i * 2] = run.xOf(emitted + i) - run.xOf(emitted);
        offsets[i * 2 + 1] = run.yOf(emitted + i) - run.yOf(emitted);
      }

      list.drawGlyphRun(
        fontId,
        paintId,
        runOriginX,
        runOriginY,
        ids,
        offsets,
        count,
      );
      emitted += count;
    }
  }

  /// Appends [text] positioned so its **top-left** is at [topLeft].
  ///
  /// The convenience every widget wants, and the one place the ascent is added
  /// so that no caller has to remember to. Returns the run.
  GlyphRun paintInBox(
    DisplayList list,
    String text,
    ScaledTypeface font,
    Offset topLeft,
    int paintId,
  ) =>
      paint(
        list,
        text,
        font,
        Offset(topLeft.dx, topLeft.dy + font.ascent),
        paintId,
      );

  /// The size [text] occupies: shaped width by line height.
  ///
  /// Uses the shaper, so it accounts for kerning - which
  /// [ScaledTypeface.measure] does not. Measuring with one and drawing with
  /// the other is how text ends up not fitting the box that was reserved for
  /// it.
  Size measure(String text, ScaledTypeface font) {
    if (text.isEmpty) return Size(0, font.lineHeight);
    final GlyphRun run = shapeRun(text, font);
    return Size(run.width, font.lineHeight);
  }

  // -------------------------------------------------------------------------
  // Paragraphs
  // -------------------------------------------------------------------------

  /// Lays [text] out into lines, through the cache.
  ///
  /// The result is immutable and shared: a caller must not assume it owns it,
  /// and must not hold it across a change to the face registry, because the
  /// entry it came from keys on the [ScaledTypeface] that was passed in.
  Paragraph layout(
    String text,
    ScaledTypeface font, {
    double maxWidth = double.infinity,
    ParagraphStyle style = const ParagraphStyle(),
  }) =>
      paragraphs.single(
        text,
        TextStyle(font: font),
        paragraphStyle: style,
        maxWidth: maxWidth,
      );

  /// The same, for text whose style changes part way through.
  Paragraph layoutSpans(
    List<TextSpan> spans, {
    double maxWidth = double.infinity,
    ParagraphStyle style = const ParagraphStyle(),
  }) =>
      paragraphs.layout(spans: spans, style: style, maxWidth: maxWidth);

  /// Appends [paragraph] to [list] with its **top-left** at [topLeft].
  ///
  /// Top-left rather than baseline, unlike [paint]: a paragraph has as many
  /// baselines as it has lines, and each line's is already recorded in
  /// [TextLine.baseline] relative to the paragraph's top. Asking the caller for
  /// the first baseline would make the second line's position depend on a
  /// number the caller had no way to compute.
  ///
  /// Allocates nothing that layout did not already allocate, apart from the
  /// per-command typed lists [emitRun] builds: the spans hold their own copies
  /// of the shaped glyphs, so redrawing a laid-out paragraph never re-shapes.
  void paintParagraph(
    DisplayList list,
    Paragraph paragraph,
    Offset topLeft,
    int paintId,
  ) {
    for (final TextLine line in paragraph.lines) {
      final double baseline = topLeft.dy + line.baseline;
      for (final GlyphSpan span in line.spans) {
        if (span.glyphs.isEmpty) continue;
        emitRun(
          list,
          span.glyphs,
          Offset(topLeft.dx + span.left, baseline),
          paintId,
        );
      }
    }
  }

  /// Scratch for [emitRun], sized once to the largest run an opcode can carry.
  ///
  /// [DisplayList.drawGlyphRun] copies both arrays into its arena before it
  /// returns and keeps no reference, so one buffer can serve every run in
  /// every frame. Allocating a pair per emitted run instead was, measurably,
  /// the largest single source of per-frame typed-list garbage in the text
  /// path - second only to the re-shaping that [runs] now prevents.
  final Int32List _emitIds = Int32List(kMaxGlyphsPerRun);
  final Float32List _emitOffsets = Float32List(kMaxGlyphsPerRun * 2);

  /// The box [text] occupies once wrapped to [maxWidth].
  ///
  /// The width is the longest line, not [maxWidth]: a caller reserving space
  /// wants what the text needs, and a caller that already decided the width did
  /// not need to ask.
  Size measureParagraph(
    String text,
    ScaledTypeface font, {
    double maxWidth = double.infinity,
    ParagraphStyle style = const ParagraphStyle(),
  }) =>
      layout(text, font, maxWidth: maxWidth, style: style).size;
}
