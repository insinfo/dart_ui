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
import '../../geometry/path.dart';
import '../../geometry/size.dart';
import '../../graphics/color.dart';
import '../../graphics/display_list.dart';
import '../../graphics/display_list_opcodes.dart';
import '../../text/cmap.dart' show notdefGlyph;
import '../../text/default_ignorable.dart';
import '../../text/font_fallback.dart';
import '../../text/font_tables.dart' show PostTable;
import '../../text/paragraph.dart';
import '../../text/shaper.dart';
import '../../text/text_decoration.dart';
import '../../text/typeface.dart';
import 'color_glyph_cache.dart';

/// Shapes text and appends it to a display list.
///
/// Holds a [Shaper], which holds reusable buffers, so one painter per layout
/// context rather than one per string.
final class TextPainter {
  /// [shaper] replaces the default for **both** levels of the API: the
  /// single-run calls use it directly, and the paragraph calls use it for every
  /// script instead of picking one per run.
  ///
  /// [fallback] is where the paragraph calls find a face for a character the
  /// span's face lacks; see [FontFallback]. It is handed to the
  /// [ParagraphCache] this builds, so it is ignored when [paragraphCache] is
  /// supplied - that cache already has its own. The single-run calls never
  /// fall back: a [GlyphRun] is one face by construction, which is why
  /// [needsFallback] exists.
  ///
  /// [colorGlyphs] is where pictures from `sbix` and `CBDT` faces are decoded
  /// and kept; see [emitRun].
  TextPainter({
    Shaper? shaper,
    ParagraphCache? paragraphCache,
    GlyphRunCache? runCache,
    FontFallback? fallback,
    ColorGlyphCache? colorGlyphs,
  })  : _shaper = shaper ?? sharedShaper,
        runs = runCache ?? GlyphRunCache(shaper ?? sharedShaper),
        paragraphs = paragraphCache ??
            ParagraphCache(shaper: shaper, fallback: fallback),
        colorGlyphs = colorGlyphs ?? sharedColorGlyphCache;

  /// Decoded colour glyphs, shared by default with every other painter.
  final ColorGlyphCache colorGlyphs;

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

  /// Whether [text] has a cluster that [font] alone would draw wrongly, and
  /// so must go through [layout] - whose paragraphs fall back - rather than
  /// through [shapeRun].
  ///
  /// True when the paragraph cache has a fallback and [text] has a character
  /// [font] cannot draw, or asks for the emoji presentation with `U+FE0F`.
  /// Default-ignorable characters do not count: the shaper hides them. A
  /// widget that draws single lines through [shapeRun] asks this first; the
  /// cost is one `cmap` lookup per character.
  bool needsFallback(String text, ScaledTypeface font) {
    if (paragraphs.fallback == null) return false;
    final Typeface face = font.typeface;
    for (final int rune in text.runes) {
      if (rune == 0xFE0F) return true;
      if (rune < 0x20 || isDefaultIgnorable(rune)) continue;
      if (face.glyphForCodePoint(rune) == notdefGlyph) return true;
    }
    return false;
  }

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
  ///
  /// ## Colour glyphs
  ///
  /// A glyph whose face has a picture of it (`sbix`, `CBDT` - see
  /// [Typeface.colorBitmapOf]) is drawn as an image and **left out of the
  /// glyph run**. Leaving it out is not an optimisation: those faces' outlines
  /// are placeholders, and drawing both would put a box behind every emoji.
  /// The picture is placed by the table's origin offsets from the glyph's pen
  /// position and baseline, at whole pixels - the blit is pixel for pixel -
  /// and drawn with [paintId], whose alpha a GPU backend applies and whose
  /// colour nothing applies: an emoji is not tinted by the text colour.
  /// Ordinary glyphs of the same run still go out as one glyph command, and
  /// carry the run's text to a backend that captures it.
  ///
  /// Sequences an `sbix` face forms with AAT `morx` - a thumbs-up with a skin
  /// tone, a family joined with `U+200D` - are not formed, because this engine
  /// does not run `morx`; each part draws as its own picture, 👍 then the
  /// 🏽 swatch, rather than as a box.
  void emitRun(
    DisplayList list,
    GlyphRun run,
    Offset baselineOrigin,
    int paintId,
  ) {
    if (run.isEmpty) return;
    final int fontId = list.addFont(run.font);
    final Typeface face = run.font.typeface;
    final bool pictures = face.hasColorBitmaps;
    final double pixelSize = run.font.pixelSize;

    // Scanning clusters is the only work this method does that a rasteriser
    // has no use for, so it is asked for once, here, and not per command. The
    // guard is the one `render_diagnostics.dart` sanctions: the recording call
    // itself is free when capture is off, but the scan behind it would not be.
    final bool captureText = list.capturesGlyphText && run.hasText;

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
      // A glyph drawn as a picture is skipped here and drawn below; the
      // offsets of the rest are still from the chunk's origin, so leaving one
      // out moves nothing else.
      final Int32List ids = _emitIds;
      final Float32List offsets = _emitOffsets;
      int kept = 0;
      int drawnAsPictures = 0;
      for (int i = 0; i < count; i++) {
        final int glyph = run.glyphIds[emitted + i];
        if (pictures && colorGlyphs.lookup(face, glyph, pixelSize) != null) {
          drawnAsPictures++;
          continue;
        }
        ids[kept] = glyph;
        offsets[kept * 2] = run.xOf(emitted + i) - run.xOf(emitted);
        offsets[kept * 2 + 1] = run.yOf(emitted + i) - run.yOf(emitted);
        kept++;
      }

      // Before the command, because the side table keys on the offset the
      // *next* command will be written at. Per command rather than per run:
      // one logical string becomes several commands here, and a table that
      // named the whole string on each of them would spell a paragraph out
      // once per split - which reads correctly in a short label and duplicates
      // text in anything long enough to matter.
      if (captureText) {
        final int from = run.textStartOfGlyphs(emitted, count);
        final int to = run.textEndOfGlyphs(emitted, count);
        // Empty only when every glyph in this command continues a cluster the
        // previous command already claimed, which needs a single cluster wider
        // than kMaxGlyphsPerRun. Recording nothing then is what keeps the
        // table's spans a partition: the characters are already named, once,
        // on the command that drew the cluster's first glyph.
        if (to > from) list.recordGlyphText(run.text, from, to);
      }

      // Emitted even when every glyph became a picture, if the text is being
      // captured: the command is what the side table's entry belongs to.
      if (kept > 0 || captureText) {
        list.drawGlyphRun(
          fontId,
          paintId,
          runOriginX,
          runOriginY,
          ids,
          offsets,
          kept,
        );
      }
      if (drawnAsPictures > 0) {
        _emitPictures(list, run, emitted, count, baselineOrigin, paintId);
      }
      emitted += count;
    }
  }

  /// Draws the glyphs `[first, first + count)` of [run] that have pictures.
  ///
  /// Every lookup here is a cache hit - [emitRun] made the same ones a moment
  /// ago to decide what to leave out of the glyph command.
  void _emitPictures(
    DisplayList list,
    GlyphRun run,
    int first,
    int count,
    Offset baselineOrigin,
    int paintId,
  ) {
    final Typeface face = run.font.typeface;
    final double pixelSize = run.font.pixelSize;
    for (int i = first; i < first + count; i++) {
      final ColorGlyphImage? picture =
          colorGlyphs.lookup(face, run.glyphIds[i], pixelSize);
      if (picture == null) continue;
      final double left =
          (baselineOrigin.dx + run.xOf(i) + picture.left).roundToDouble();
      final double top =
          (baselineOrigin.dy + run.yOf(i) + picture.top).roundToDouble();
      list.drawImage(
        list.addImage(picture.image),
        0,
        0,
        picture.width.toDouble(),
        picture.height.toDouble(),
        left,
        top,
        left + picture.width,
        top + picture.height,
        paintId,
      );
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
  /// [paintId] draws every span whose style names no colour of its own. A
  /// paragraph in which no span does - and has no background or decoration
  /// either, which is nearly all of them - is drawn by the same one-paint loop
  /// as before spans could be styled, command for command. One that does is
  /// drawn in four passes; see [_paintStyledParagraph].
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
    if (paragraph.hasPaintStyles) {
      _paintStyledParagraph(list, paragraph, topLeft, paintId);
      return;
    }
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

  /// Draws a paragraph whose spans carry colours, backgrounds or decorations.
  ///
  /// The order is the one CSS specifies and every browser follows, and each
  /// step is a pass over every line so that nothing from a later step can be
  /// covered by an earlier one on the next line:
  ///
  ///  1. **backgrounds**, so text is never under its own highlight;
  ///  2. **underlines and overlines**, under the glyphs - a descender crosses
  ///     an underline rather than being cut by it;
  ///  3. **glyphs**, each span in its own paint - colour emoji included,
  ///     which [emitRun] still draws as pictures;
  ///  4. **strike-throughs**, over the glyphs, which is the point of them.
  ///
  /// A span keeps the caller's [paintId] when its style has no colour, so a
  /// mixed paragraph - one red word in an otherwise default label - only
  /// adds paints for what differs.
  void _paintStyledParagraph(
    DisplayList list,
    Paragraph paragraph,
    Offset topLeft,
    int paintId,
  ) {
    final _SpanPaints paints = _SpanPaints(list, paintId);
    for (final TextLine line in paragraph.lines) {
      _paintBackgrounds(list, line, topLeft, paints);
    }
    for (final TextLine line in paragraph.lines) {
      _paintDecorations(list, line, topLeft, paints, TextDecoration.underline);
      _paintDecorations(list, line, topLeft, paints, TextDecoration.overline);
    }
    for (final TextLine line in paragraph.lines) {
      final double baseline = topLeft.dy + line.baseline;
      for (final GlyphSpan span in line.spans) {
        if (span.glyphs.isEmpty) continue;
        // A fallback face with pictures is an emoji face: not sheared.
        final bool shear = span.style.syntheticItalic &&
            !span.glyphs.font.typeface.hasColorBitmaps;
        if (shear) {
          // x' = x - k (y - baseline): the baseline stays put, so the
          // advances, carets and selection boxes still line up with it.
          list
            ..save()
            ..transform(
              1,
              0,
              -_syntheticItalicSkew,
              1,
              _syntheticItalicSkew * baseline,
              0,
            );
        }
        emitRun(
          list,
          span.glyphs,
          Offset(topLeft.dx + span.left, baseline),
          paints.glyphs(span.style),
        );
        if (shear) list.restore();
      }
    }
    for (final TextLine line in paragraph.lines) {
      _paintDecorations(
          list, line, topLeft, paints, TextDecoration.lineThrough);
    }
  }

  /// One rectangle per stretch of equal background on [line].
  ///
  /// Neighbouring spans with the same colour and the same box are merged
  /// before drawing. Two antialiased rectangles meeting at a fractional x
  /// each cover the shared pixel partly, and the pixel comes out lighter
  /// than either: a seam down the middle of a highlighted phrase wherever a
  /// span boundary - a bidi run, a script change - happened to fall.
  void _paintBackgrounds(
    DisplayList list,
    TextLine line,
    Offset topLeft,
    _SpanPaints paints,
  ) {
    final double baseline = topLeft.dy + line.baseline;
    Color? color;
    double left = 0;
    double right = 0;
    double top = 0;
    double bottom = 0;
    void flush() {
      if (color != null && right > left) {
        list.drawRect(left, top, right, bottom, paints.fill(color!));
      }
      color = null;
    }

    for (final GlyphSpan span in line.spans) {
      final Color? background = span.style.backgroundColor;
      if (background == null || span.width <= 0) {
        flush();
        continue;
      }
      final ScaledTypeface font = span.style.font;
      final double spanLeft = topLeft.dx + span.left;
      final double spanTop = baseline - font.ascent;
      final double spanBottom = baseline + font.descent;
      if (color == background &&
          spanTop == top &&
          spanBottom == bottom &&
          (spanLeft - right).abs() < 0.01) {
        right = spanLeft + span.width;
        continue;
      }
      flush();
      color = background;
      left = spanLeft;
      right = spanLeft + span.width;
      top = spanTop;
      bottom = spanBottom;
    }
    flush();
  }

  /// Draws every [kind] line on [line], merging neighbouring spans whose
  /// lines would be identical, for the reason [_paintBackgrounds] merges.
  ///
  /// The geometry is per span and comes from the span's own face - not the
  /// face a fallback run was drawn in, so an emoji in an underlined phrase
  /// does not drop the underline to wherever the emoji face keeps its own -
  /// which is why a larger word on the same line has its underline lower
  /// and thicker, as in every browser.
  void _paintDecorations(
    DisplayList list,
    TextLine line,
    Offset topLeft,
    _SpanPaints paints,
    TextDecoration kind,
  ) {
    final double baseline = topLeft.dy + line.baseline;
    _DecorationSegment? pending;
    for (final GlyphSpan span in line.spans) {
      final TextStyle style = span.style;
      if (!style.decoration.contains(kind) || span.width <= 0) {
        if (pending != null) _drawDecoration(list, pending, topLeft.dx, paints);
        pending = null;
        continue;
      }
      final _DecorationSegment segment = _DecorationSegment.of(
        style,
        kind,
        baseline,
        topLeft.dx + span.left,
        topLeft.dx + span.right,
      );
      if (pending != null && pending.continuesWith(segment)) {
        pending.right = segment.right;
        continue;
      }
      if (pending != null) _drawDecoration(list, pending, topLeft.dx, paints);
      pending = segment;
    }
    if (pending != null) _drawDecoration(list, pending, topLeft.dx, paints);
  }

  /// Draws one merged decoration line in its [TextDecorationStyle].
  ///
  /// The broken styles are phased from [originX], the paragraph's left
  /// edge, so a dash pattern runs on unbroken across a colour change.
  void _drawDecoration(
    DisplayList list,
    _DecorationSegment segment,
    double originX,
    _SpanPaints paints,
  ) {
    final double left = segment.left;
    final double right = segment.right;
    final double top = segment.top;
    final double t = segment.thickness;
    switch (segment.style) {
      case TextDecorationStyle.solid:
        list.drawRect(
            left, top, right, top + t, paints.decoration(segment.source));
      case TextDecorationStyle.double:
        // The second line goes away from the glyphs: below an underline,
        // above an overline, and a strike-through splits around its centre.
        final double second = segment.kind == TextDecoration.overline
            ? top - 2 * t
            : segment.kind == TextDecoration.lineThrough
                ? top + t
                : top + 2 * t;
        final double first =
            segment.kind == TextDecoration.lineThrough ? top - t : top;
        final int paint = paints.decoration(segment.source);
        list
          ..drawRect(left, first, right, first + t, paint)
          ..drawRect(left, second, right, second + t, paint);
      case TextDecorationStyle.dotted:
        _drawPattern(list, segment, originX, t, t, paints);
      case TextDecorationStyle.dashed:
        _drawPattern(list, segment, originX, 4 * t, 3 * t, paints);
      case TextDecorationStyle.wavy:
        _drawWave(list, segment, originX, paints);
    }
  }

  /// Rectangles [on] long and [off] apart, from [originX], cut to the
  /// segment.
  void _drawPattern(
    DisplayList list,
    _DecorationSegment segment,
    double originX,
    double on,
    double off,
    _SpanPaints paints,
  ) {
    final double period = on + off;
    final int paint = paints.decoration(segment.source);
    double x =
        originX + ((segment.left - originX) / period).floorToDouble() * period;
    for (; x < segment.right; x += period) {
      final double a = x < segment.left ? segment.left : x;
      final double b = x + on > segment.right ? segment.right : x + on;
      if (b > a) {
        list.drawRect(
            a, segment.top, b, segment.top + segment.thickness, paint);
      }
    }
  }

  /// A wave of quadratic arcs, stroked [_DecorationSegment.thickness] wide
  /// and clipped to the segment.
  ///
  /// Each arc is half a period, `3t` long and `1.5t` tall either side of
  /// the centre, so the wave stays legible at a one-pixel stroke without
  /// looking like a zigzag at a heavy one. An underline's wave is moved down
  /// by its own height so it clears the descenders the straight line would
  /// have touched, and an overline's up.
  void _drawWave(
    DisplayList list,
    _DecorationSegment segment,
    double originX,
    _SpanPaints paints,
  ) {
    final double t = segment.thickness;
    final double half = 3 * t;
    final double amplitude = 1.5 * t;
    final double centre = segment.top +
        t / 2 +
        switch (segment.kind) {
          TextDecoration.underline => amplitude / 2,
          TextDecoration.overline => -amplitude / 2,
          _ => 0,
        };
    final int start = ((segment.left - originX) / half).floor();
    final PathBuilder wave = PathBuilder()
      ..moveTo(originX + start * half, centre);
    for (int i = start; originX + i * half < segment.right; i++) {
      final double x = originX + i * half;
      final double peak =
          i.isEven ? centre - 2 * amplitude : centre + 2 * amplitude;
      wave.quadraticBezierTo(x + half / 2, peak, x + half, centre);
    }
    final double reach = amplitude + t;
    list
      ..save()
      ..clipRect(
        segment.left,
        centre - reach,
        segment.right,
        centre + reach,
      )
      ..drawPath(list.addPath(wave.build()), paints.stroke(segment.source, t))
      ..restore();
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

/// The horizontal shear of a synthesized italic: tan 14 degrees, CSS's default
/// `oblique` angle, and within a hair of the quarter Skia shears by. Real
/// italics lean between 9 and 15 degrees; this sits in the range without
/// pretending to be any one face's.
const double _syntheticItalicSkew = 0.25;

/// The paints a styled paragraph draws with, derived from the caller's.
///
/// A span with no colour uses the caller's paint id itself, so whatever that
/// paint carries - a blend mode, a gradient - survives. A span with a colour
/// gets a paint that keeps the caller's antialiasing and blend mode and
/// changes only the colour; [DisplayList.addPaint] interns, so asking twice
/// costs a lookup, not a second paint.
final class _SpanPaints {
  _SpanPaints(this.list, this.base)
      : _antiAlias = list.paintAntiAlias(base),
        _blendMode = list.paintBlendMode(base);

  final DisplayList list;
  final int base;
  final bool _antiAlias;
  final int _blendMode;

  int glyphs(TextStyle style) {
    final Color? color = style.color;
    return color == null ? base : fill(color);
  }

  int fill(Color color) => list.addPaint(
        colorArgb: color.value,
        antiAlias: _antiAlias,
        blendMode: _blendMode,
      );

  /// The decoration colour falls back to the glyph colour and then to the
  /// caller's paint, as `decorationColor` does in Flutter.
  int decoration(TextStyle style) {
    final Color? color = style.decorationColor ?? style.color;
    return color == null ? base : fill(color);
  }

  int stroke(TextStyle style, double width) {
    final Color? color = style.decorationColor ?? style.color;
    return list.addPaint(
      colorArgb: color?.value ?? list.paintColor(base),
      style: paintStyleStroke,
      strokeWidth: width,
      antiAlias: true,
      blendMode: _blendMode,
    );
  }
}

/// One decoration line across one or more neighbouring spans.
final class _DecorationSegment {
  _DecorationSegment._({
    required this.source,
    required this.kind,
    required this.style,
    required this.left,
    required this.right,
    required this.top,
    required this.thickness,
  });

  /// Where [kind] sits for [style]'s face, on a line whose baseline is at
  /// [baseline].
  ///
  /// ## The numbers
  ///
  ///  * **Thickness** is the `post` table's `underlineThickness` - the
  ///    designer's stroke - or a fourteenth of the em when the face has no
  ///    `post` or says zero, times [TextStyle.decorationThickness].
  ///  * **Underline**: `post.underlinePosition` is the distance from the
  ///    baseline to the *top* of the stroke (OpenType defines it so; the
  ///    PostScript centre is the older reading, and FreeType converts from
  ///    this one). A tenth of the em below the baseline without it.
  ///  * **Strike-through**: centred on half the x-height, `OS/2.sxHeight`,
  ///    which is where the eye expects the middle of a lowercase letter; half
  ///    an em's half when the table is too old to have one. `OS/2`'s own
  ///    `strikeoutPosition` is deliberately not used: fonts disagree wildly
  ///    about it, and half the x-height is what Flutter and Chrome draw.
  ///  * **Overline**: its top at the face's ascent.
  ///
  /// The straight styles are snapped to whole pixels - top and thickness,
  /// at least one pixel - because a one-pixel line at y = 10.4 is drawn as
  /// two grey rows and reads as blurred. The wave is not snapped: it is
  /// antialiased along its whole length anyway.
  factory _DecorationSegment.of(
    TextStyle style,
    TextDecoration kind,
    double baseline,
    double left,
    double right,
  ) {
    final ScaledTypeface font = style.font;
    final Typeface face = font.typeface;
    final PostTable? post = face.post;
    double thickness = post != null && post.underlineThickness > 0
        ? post.underlineThickness * font.scale
        : font.pixelSize / 14;
    thickness *= style.decorationThickness;
    double top;
    if (kind == TextDecoration.underline) {
      top = post != null && post.underlinePosition != 0
          ? baseline - post.underlinePosition * font.scale
          : baseline + font.pixelSize / 10;
    } else if (kind == TextDecoration.overline) {
      top = baseline - font.ascent;
    } else {
      final int? xHeight = face.os2?.sxHeightOrNull;
      final double half = xHeight != null && xHeight > 0
          ? xHeight * font.scale / 2
          : font.pixelSize / 4;
      top = baseline - half - thickness / 2;
    }
    if (style.decorationStyle != TextDecorationStyle.wavy) {
      thickness = thickness.roundToDouble();
      if (thickness < 1) thickness = 1;
      top = top.roundToDouble();
    }
    return _DecorationSegment._(
      source: style,
      kind: kind,
      style: style.decorationStyle,
      left: left,
      right: right,
      top: top,
      thickness: thickness,
    );
  }

  /// The style whose colours the line is drawn in.
  final TextStyle source;
  final TextDecoration kind;
  final TextDecorationStyle style;
  final double left;
  double right;
  final double top;
  final double thickness;

  /// Whether [next] is the same line carried on: same place, same stroke,
  /// same colour, and starting where this one ends.
  bool continuesWith(_DecorationSegment next) =>
      next.style == style &&
      next.top == top &&
      next.thickness == thickness &&
      (next.source.decorationColor ?? next.source.color) ==
          (source.decorationColor ?? source.color) &&
      (next.left - right).abs() < 0.01;
}
