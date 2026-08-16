/// Paragraph layout: the file that connects bidi, itemization, shaping and
/// line breaking into text you can actually draw, click and select.
///
/// Every algorithm below this one already existed and was tested on its own:
/// `bidi.dart` resolves UAX #9 levels, `script.dart` itemizes per UAX #24,
/// `line_break.dart` produces UAX #14 opportunities, `grapheme.dart` produces
/// UAX #29 cluster boundaries, and `shaper.dart` runs `GSUB`/`GPOS`. None of
/// them knows about any of the others. A paragraph is where the order they run
/// in stops being a matter of taste and becomes correctness.
///
/// ## The order, and why it is the only order
///
/// 1. **Bidi first, over the whole paragraph.** The embedding level of a
///    character depends on characters arbitrarily far away - a lone digit takes
///    its direction from the strong character before it, and a bracket pair
///    resolves as a unit (N0). Resolving per line would give a different answer
///    on a paragraph that wraps than on the same paragraph that does not.
/// 2. **Itemize by script**, then intersect with the bidi level runs, the style
///    spans and the tab/soft-hyphen/control characters. The result is the
///    largest span that can be handed to a shaper as a unit: one direction, one
///    script, one face, one size.
/// 3. **Shape each run**, in its own direction. A run at an odd level is shaped
///    right to left and comes back in *visual* order with descending clusters.
/// 4. **Break into lines** using the UAX #14 opportunities, measured with the
///    shaped advances rather than with nominal ones. Measuring with
///    `ScaledTypeface.measure` and drawing with the shaper is the classic way
///    text overflows the box that was reserved for it.
/// 5. **Reorder visually, per line, after breaking.** This is the step that is
///    easy to get backwards and whose symptom only appears in paragraphs that
///    wrap. UAX #9 L2 is defined on *a line*: reordering the paragraph and then
///    slicing it into lines produces different - wrong - text the moment a bidi
///    paragraph occupies more than one line, because a run that L2 would have
///    reversed within line 2 gets reversed against line 1's content instead.
///    There is a test for exactly this.
/// 6. **Align and justify**, which needs the final line width and therefore
///    comes last.
///
/// ## Indices
///
/// Every offset here is a **UTF-16 code unit offset into [Paragraph.text]**,
/// the same indexing `GlyphRun.clusters`, `BidiParagraph.levels`,
/// `ScriptRun.start` and `LineBreakOpportunity.position` all use. Both halves
/// of a surrogate pair belong to the same cluster, the same run and the same
/// line, so any offset this file hands out can be used to slice the string.
///
/// ## Limits, stated out loud
///
/// These are real and they are deliberate. Each one is a place where a later
/// version does better, not a place where this version is secretly correct.
///
///  * **Shaping does not cross a run boundary.** A ligature or a kern pair
///    straddling a script, direction, style or tab boundary is not formed. That
///    is inherent to run segmentation and every shaping engine has it; what is
///    additionally true here is that shaping does not cross a *line* boundary
///    either, and a line break inside a run does not re-shape the two halves.
///    Break opportunities essentially never fall inside a ligature, so the
///    visible consequence is nil - but if one did, the ligature would stay with
///    the first half.
///  * **Widths inside a run come from glyph positions, not from per-glyph
///    advances**, because [GlyphRun] does not carry advances. The boundary of a
///    cluster is taken to be the x position of the first glyph of the next
///    cluster. That glyph is a base, and bases carry no `GPOS` offset, so this
///    is exact in practice; a font that shifted a base with `mark` positioning
///    would move a caret by that shift.
///  * **An offset inside a cluster measures to the cluster's leading edge.**
///    Half of an "fi" ligature, or the low half of a surrogate pair, has zero
///    width. Splitting a ligature proportionally is the alternative and it is a
///    lie of a different shape.
///  * **No emergency breaking.** A word longer than `maxWidth` with no UAX #14
///    opportunity inside it overflows the line rather than being cut. CSS calls
///    the alternative `overflow-wrap: break-word`; it is a tailoring, and it is
///    not here.
///  * **Justification expands U+0020 only.** No kashida, no letter-spacing, no
///    shrinking. A line with no spaces cannot be justified and is left aligned
///    to the paragraph's start edge.
///  * **Trailing whitespace is trimmed from the line's laid-out content.** It
///    is not measured for fitting, not aligned, and has no glyphs, which is
///    what makes a centred line look centred. [TextLine.endIncludingWhitespace]
///    still reports it so that editing can put a caret after it, at the line's
///    trailing edge. UAX #9 L1 re-levels exactly that whitespace, and since it
///    is not laid out, L1 has no observable effect here.
///  * **Tab stops are measured along the line in logical order.** A tab inside
///    right-to-left text advances the logical pen, not the visual one. Tabs and
///    bidi genuinely disagree about what "the next stop" means and no
///    implementation is right; this one is at least deterministic.
///  * **Script and language reach the shaper; the shaping *model* is the
///    shaper's business.** This file hands `shape` the `Script` `itemize`
///    resolved and the caller's language tag, and the shaper picks the tag the
///    font actually names and the model that script needs. A script whose model
///    is not implemented throws rather than rendering wrongly - see
///    [sharedShaper] for how to trade that for approximate text.
///  * **One font per style.** There is no font fallback: a run whose face has
///    no glyph for a character gets `.notdef`, not a second face. The registry
///    that would choose the second face is a neighbouring concern and the seam
///    it needs is the style span - splitting a run further by coverage is the
///    same operation as splitting it by script, and it belongs right next to
///    it in [_ParagraphBuilder._shapeRuns].
library;

import 'dart:math' as math;
import 'dart:typed_data';

import '../geometry/offset.dart';
import '../geometry/rect.dart';
import '../geometry/size.dart';
import 'bidi.dart';
import 'grapheme.dart';
import 'line_break.dart';
import 'script.dart';
import 'shaper.dart';
import 'typeface.dart';

// ---------------------------------------------------------------------------
// Style
// ---------------------------------------------------------------------------

/// Where a line's spare width goes.
enum TextAlign {
  /// The paragraph's leading edge: left under a left-to-right base direction,
  /// right under a right-to-left one. The only alignment that is correct for
  /// both without the caller knowing which it got.
  start,

  /// The paragraph's trailing edge.
  end,

  /// Physically left, whatever the base direction.
  left,

  /// Physically right, whatever the base direction.
  right,

  center,

  /// Spare width is distributed into the spaces, except on the last line of a
  /// paragraph and on any line ending at a mandatory break - a justified line
  /// followed by nothing has no reason to be stretched, and stretching it is
  /// the single most recognisable sign of a home-made text engine.
  justify,
}

/// Which side of a boundary a text position belongs to.
///
/// A text offset is a boundary between two characters, and at a direction
/// change one boundary has **two** legitimate positions on screen: the trailing
/// edge of the run that ends there and the leading edge of the run that starts
/// there. They can be at opposite ends of the line. Affinity is the caller
/// saying which one it means, and a text editor that does not carry it has a
/// caret that jumps.
enum TextAffinity {
  /// The position belongs to the character *before* the offset - the trailing
  /// edge of the run that ends at it, and the end of the line that ends at it.
  upstream,

  /// The position belongs to the character *after* the offset - the leading
  /// edge of the run that starts at it, and the start of the line that starts
  /// at it. The default, because typing inserts after the caret.
  downstream,
}

/// An offset into the paragraph text, plus which side of it is meant.
final class TextPosition {
  const TextPosition(this.offset, {this.affinity = TextAffinity.downstream});

  /// UTF-16 code unit offset into [Paragraph.text].
  final int offset;

  final TextAffinity affinity;

  @override
  bool operator ==(Object other) =>
      other is TextPosition &&
      other.offset == offset &&
      other.affinity == affinity;

  @override
  int get hashCode => Object.hash(offset, affinity);

  @override
  String toString() => 'TextPosition($offset, ${affinity.name})';
}

/// One rectangle of a selection, and the direction of the text inside it.
///
/// The direction matters to the caller: a selection highlight drawn over a
/// right-to-left box grows leftwards as the selection extends forwards.
final class TextBox {
  const TextBox(this.rect, this.direction);

  final Rect rect;
  final TextDirection direction;

  @override
  String toString() => 'TextBox($rect, ${direction.name})';
}

/// The face, size and language one span of text is drawn with.
///
/// Not `const`-constructible, because a [ScaledTypeface] is parsed font bytes
/// and cannot be. Value equality, because it is half of the paragraph cache
/// key and two spans with the same face and size must share a cache entry.
final class TextStyle {
  const TextStyle({required this.font, this.language});

  final ScaledTypeface font;

  /// An OpenType language system tag - `TRK`, `SRB` - refining the script's
  /// shaping rules. No property of a code point can supply it, so it has to
  /// come from the caller; null means the script's default language system.
  final String? language;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TextStyle && other.font == font && other.language == language;

  @override
  int get hashCode => Object.hash(font, language);

  @override
  String toString() =>
      'TextStyle($font${language == null ? '' : ', $language'})';
}

/// A stretch of text sharing one style.
///
/// The paragraph's text is the spans concatenated, in order. Spans exist so a
/// line can be as tall as its tallest face rather than as tall as a face the
/// caller nominated: mixed sizes on one line is the requirement that forces the
/// paragraph to carry per-span metrics rather than one global one.
final class TextSpan {
  const TextSpan(this.text, this.style);

  final String text;
  final TextStyle style;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TextSpan && other.text == text && other.style == style;

  @override
  int get hashCode => Object.hash(text, style);

  @override
  String toString() => 'TextSpan(${text.length} units, $style)';
}

/// Everything about a paragraph that is not its text or its per-span style.
final class ParagraphStyle {
  const ParagraphStyle({
    this.align = TextAlign.start,
    this.baseDirection,
    this.maxLines,
    this.ellipsis,
    this.tabStopWidth,
    this.heightMultiplier = 1.0,
  });

  final TextAlign align;

  /// Forces the paragraph's base direction. Null applies UAX #9 P2/P3, which
  /// takes the direction of the first strong character and defaults to
  /// left-to-right when there is none.
  ///
  /// Worth forcing whenever the surrounding UI has a direction: an English
  /// label in an Arabic interface is a left-to-right paragraph in a
  /// right-to-left column, and P2 cannot know that.
  final TextDirection? baseDirection;

  /// The most lines to lay out, or null for as many as it takes.
  ///
  /// Lines past the limit are dropped, [Paragraph.didExceedMaxLines] becomes
  /// true, and if [ellipsis] is set the last surviving line is cut to make room
  /// for it.
  final int? maxLines;

  /// The string that stands in for the text [maxLines] removed.
  ///
  /// Shaped and measured with the real shaper and the real face, not assumed to
  /// be three periods wide: `…` in a proportional face is narrower than `...`
  /// in the same face, and reserving the wrong width is how an ellipsis ends up
  /// clipped by the very box it was supposed to fit.
  final String? ellipsis;

  /// The distance between tab stops, in pixels.
  ///
  /// Null means eight times the advance of a space in the paragraph's first
  /// style, which is the convention every terminal and editor starts from.
  final double? tabStopWidth;

  /// Scales the natural line height, which is the tallest ascent plus the
  /// deepest descent plus the largest line gap among the runs on the line.
  ///
  /// The extra is split evenly above and below, so the baseline stays in the
  /// middle of the leading rather than drifting down as the multiplier grows.
  final double heightMultiplier;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ParagraphStyle &&
          other.align == align &&
          other.baseDirection == baseDirection &&
          other.maxLines == maxLines &&
          other.ellipsis == ellipsis &&
          other.tabStopWidth == tabStopWidth &&
          other.heightMultiplier == heightMultiplier;

  @override
  int get hashCode => Object.hash(
        align,
        baseDirection,
        maxLines,
        ellipsis,
        tabStopWidth,
        heightMultiplier,
      );
}

// ---------------------------------------------------------------------------
// Shaper selection
// ---------------------------------------------------------------------------

/// The shaper a paragraph uses when the caller supplies none.
///
/// One instance for the process, not one per paragraph, because a shaper caches
/// the parsed `GSUB`, `GPOS`, `GDEF` and `kern` tables of every face it has
/// seen and parsing those is the expensive half of shaping. A shaper per
/// paragraph would re-parse a face's layout tables for every string on the
/// screen.
///
/// [OpenTypeShaper] rather than [LatinShaper], and that is the whole point of
/// this file existing: [LatinShaper] runs neither `GSUB` nor `GPOS`, so no
/// ligature forms and a decomposed accent - a zero-advance combining mark - is
/// drawn at the *left edge* of the letter it belongs to.
///
/// Its `unsupportedScript` policy is the shaper's own default, which is to
/// **throw** on a script whose shaping model is not implemented rather than to
/// draw it wrongly. A caller that would rather have approximate Devanagari than
/// an exception constructs its own [OpenTypeShaper] and passes it in; that is
/// two deliberate choices, which is what a decision of that shape should cost.
///
/// Not thread safe and not meant to be: shaping is synchronous, and a
/// [GlyphRun] borrows the shaper's scratch buffers until its next call - which
/// is exactly why [Paragraph] copies every run it keeps.
final Shaper sharedShaper = OpenTypeShaper();

// ---------------------------------------------------------------------------
// Laid-out results
// ---------------------------------------------------------------------------

/// A run of glyphs placed on a line, in the paragraph's coordinate space.
///
/// The unit a painter draws and a hit test walks. [glyphs] is a private copy,
/// not the shaper's scratch buffer, so it stays valid for the life of the
/// paragraph; its positions are relative to the span's own left edge and its
/// baseline, which is why a painter only needs [left] and [TextLine.baseline].
final class GlyphSpan {
  GlyphSpan._({
    required this.glyphs,
    required this.left,
    required this.width,
    required this.start,
    required this.end,
    required this.bidiLevel,
    required this.style,
    required this.isEllipsis,
    required Float64List edges,
  }) : _edges = edges;

  /// The positioned glyphs, origin at (`left`, the line's baseline).
  final GlyphRun glyphs;

  /// Distance from the paragraph's left edge to this span's left edge.
  final double left;

  /// Advance width, including any width justification added to it.
  final double width;

  /// Source range, in logical order and in UTF-16 code units.
  ///
  /// Empty (`start == end`) for a span that is not in the source text at all,
  /// which today means only the ellipsis.
  final int start;
  final int end;

  /// The UAX #9 embedding level. Even is left-to-right, odd is right-to-left.
  final int bidiLevel;

  final TextStyle style;

  /// Whether this span is the ellipsis rather than source text.
  ///
  /// Selection and hit testing skip it: it stands for text that was removed, so
  /// there is no offset it could honestly report.
  final bool isEllipsis;

  /// Prefix advances from the span's *logical* start, one per source offset
  /// plus one for the end.
  final Float64List _edges;

  TextDirection get direction =>
      bidiLevel.isOdd ? TextDirection.rightToLeft : TextDirection.leftToRight;

  double get right => left + width;

  /// The x of the boundary at source [offset], in paragraph coordinates.
  ///
  /// For a right-to-left span the logically-first character is drawn at the
  /// right, so the edges run backwards - which is the whole reason a caret
  /// cannot be placed by counting characters from the left.
  double edgeOf(int offset) {
    final int index = offset <= start
        ? 0
        : offset >= end
            ? _edges.length - 1
            : offset - start;
    final double advance = _edges[index];
    return direction.isRightToLeft ? left + width - advance : left + advance;
  }

  @override
  String toString() => 'GlyphSpan($start..$end, level $bidiLevel, '
      'x ${left.toStringAsFixed(1)}..${right.toStringAsFixed(1)})';
}

/// One laid-out line.
final class TextLine {
  TextLine._({
    required this.lineNumber,
    required this.start,
    required this.end,
    required this.endIncludingWhitespace,
    required this.hardBreak,
    required this.left,
    required this.width,
    required this.top,
    required this.ascent,
    required this.descent,
    required this.height,
    required this.baseline,
    required this.spans,
  });

  final int lineNumber;

  /// Source range of the text that was laid out, trailing whitespace excluded.
  final int start;
  final int end;

  /// One past the last code unit the line owns, whitespace included.
  ///
  /// The difference from [end] is where a caret goes when the user presses End
  /// on a line that wrapped after a space.
  final int endIncludingWhitespace;

  /// Whether the line ends at a mandatory break (a newline, or the end of the
  /// paragraph) rather than because it ran out of room.
  final bool hardBreak;

  /// The line's left edge in paragraph coordinates: the alignment offset.
  final double left;

  /// Advance width of the laid-out content, after justification.
  final double width;

  /// Distance from the paragraph's top to this line's top.
  final double top;

  /// The tallest ascent and the deepest descent among the line's spans - the
  /// line is as tall as its tallest run, which is what keeps a large word from
  /// overlapping the line above it.
  final double ascent;
  final double descent;

  /// Ascent plus descent plus line gap, scaled by
  /// [ParagraphStyle.heightMultiplier].
  final double height;

  /// Distance from the paragraph's top to this line's baseline.
  final double baseline;

  /// The line's spans, **in visual order, left to right**.
  final List<GlyphSpan> spans;

  double get bottom => top + height;

  Rect get bounds => Rect.fromLTWH(left, top, width, height);

  @override
  String toString() => 'TextLine($lineNumber: $start..$end, '
      '${width.toStringAsFixed(1)}x${height.toStringAsFixed(1)}, '
      '${spans.length} spans)';
}

// ---------------------------------------------------------------------------
// The paragraph
// ---------------------------------------------------------------------------

/// Text laid out into lines: the thing a widget measures, draws and hit tests.
///
/// Immutable once built. Building it is the expensive part - bidi over the
/// whole string, shaping every run, a pass per break opportunity - so a caller
/// that lays out per frame should go through [ParagraphCache] instead.
final class Paragraph {
  Paragraph._({
    required this.text,
    required this.spans,
    required this.style,
    required this.maxWidth,
    required this.baseDirection,
    required this.lines,
    required this.height,
    required this.longestLine,
    required this.didExceedMaxLines,
  });

  /// Lays out [spans] into at most [maxWidth] pixels per line.
  ///
  /// [maxWidth] may be infinite, in which case the paragraph breaks only at
  /// mandatory breaks and alignment measures against the longest line.
  ///
  /// Throws [ArgumentError] on an empty span list or a non-positive
  /// [maxWidth] - both are caller bugs that would otherwise surface as an empty
  /// paragraph nobody can explain.
  factory Paragraph.layout({
    required List<TextSpan> spans,
    ParagraphStyle style = const ParagraphStyle(),
    double maxWidth = double.infinity,
    Shaper? shaper,
  }) {
    if (spans.isEmpty) {
      throw ArgumentError.value(spans, 'spans', 'a paragraph needs a style');
    }
    if (maxWidth.isNaN || maxWidth < 0) {
      throw ArgumentError.value(maxWidth, 'maxWidth', 'must not be negative');
    }
    if (style.maxLines != null && style.maxLines! < 1) {
      throw ArgumentError.value(style.maxLines, 'maxLines', 'must be positive');
    }
    return _ParagraphBuilder(
      spans,
      style,
      maxWidth,
      shaper ?? sharedShaper,
    ).build();
  }

  /// The single-style case, which is most of them.
  factory Paragraph.single(
    String text,
    TextStyle style, {
    ParagraphStyle paragraphStyle = const ParagraphStyle(),
    double maxWidth = double.infinity,
    Shaper? shaper,
  }) =>
      Paragraph.layout(
        spans: <TextSpan>[TextSpan(text, style)],
        style: paragraphStyle,
        maxWidth: maxWidth,
        shaper: shaper,
      );

  /// The spans concatenated: the string every offset here indexes into.
  final String text;

  final List<TextSpan> spans;
  final ParagraphStyle style;

  /// The width the paragraph was laid out against, possibly infinite.
  final double maxWidth;

  /// The resolved base direction, from [ParagraphStyle.baseDirection] or P2/P3.
  final TextDirection baseDirection;

  /// The lines, top to bottom. Never empty: an empty string is one empty line,
  /// because a text field with no text still has a caret with a height.
  final List<TextLine> lines;

  /// Total height of all lines.
  final double height;

  /// The widest line. The paragraph's intrinsic width, and what alignment
  /// measures against when [maxWidth] is infinite.
  final double longestLine;

  /// Whether [ParagraphStyle.maxLines] removed anything.
  final bool didExceedMaxLines;

  /// The box the paragraph occupies, using [longestLine] rather than
  /// [maxWidth]: a caller that asked for infinite width wants the real one
  /// back, and a caller that asked for a finite one already knows it.
  Size get size => Size(longestLine, height);

  // -------------------------------------------------------------------------
  // Queries
  // -------------------------------------------------------------------------

  /// The line containing [offset], preferring the line that *ends* there when
  /// [affinity] is upstream.
  ///
  /// The disagreement is real: on a wrapped line, the offset just past the last
  /// character is both the end of one line and the start of the next, and a
  /// caret that lands on the wrong one appears at the opposite end of the
  /// screen.
  int lineIndexAt(int offset,
      [TextAffinity affinity = TextAffinity.downstream]) {
    final int o = offset.clamp(0, text.length);
    if (affinity == TextAffinity.upstream) {
      for (int i = 0; i < lines.length; i++) {
        if (o > lines[i].start && o <= lines[i].endIncludingWhitespace) {
          return i;
        }
      }
      return 0;
    }
    for (int i = 0; i < lines.length; i++) {
      if (o < lines[i].endIncludingWhitespace) return i;
    }
    return lines.length - 1;
  }

  /// Where the caret goes for [position]: a zero-width rectangle spanning the
  /// line's height.
  ///
  /// Zero-width on purpose. A caret's thickness is a painting decision that
  /// belongs to whoever draws it, and baking one in here would make the
  /// rectangle mean two different things depending on the direction of the text
  /// it sits next to.
  ///
  /// The affinity is what makes this correct at a direction boundary. In
  /// `"abc"` followed by Hebrew, offset 3 is the trailing edge of the Latin run
  /// (upstream) *and* the leading - that is, right hand - edge of the Hebrew
  /// run (downstream), and those are different places on the line.
  Rect getCaretRect(TextPosition position) {
    final int offset = position.offset.clamp(0, text.length);
    final TextLine line = lines[lineIndexAt(offset, position.affinity)];
    final double x = _caretX(line, offset, position.affinity);
    return Rect.fromLTRB(x, line.top, x, line.top + line.height);
  }

  double _caretX(TextLine line, int offset, TextAffinity affinity) {
    if (line.spans.isEmpty) return line.left;

    GlyphSpan? best;
    for (final GlyphSpan span in line.spans) {
      if (span.isEllipsis) continue;
      final bool holds = affinity == TextAffinity.upstream
          ? offset > span.start && offset <= span.end
          : offset >= span.start && offset < span.end;
      if (holds) {
        best = span;
        break;
      }
    }
    if (best != null) return best.edgeOf(offset);

    // No span owns the offset with that affinity: it is at one end of the line,
    // or inside trimmed trailing whitespace. Fall back to whichever end of the
    // line the paragraph's direction puts it at.
    if (offset <= line.start) {
      return baseDirection.isRightToLeft ? line.left + line.width : line.left;
    }
    return baseDirection.isRightToLeft ? line.left : line.left + line.width;
  }

  /// The text position nearest to [point], in paragraph coordinates.
  ///
  /// Snaps to grapheme cluster boundaries, so a click in the middle of an emoji
  /// or of a surrogate pair lands on one side of it rather than inside it. The
  /// returned affinity says which side of the boundary was hit, so feeding the
  /// result straight back to [getCaretRect] puts the caret where the user
  /// clicked even at a direction boundary.
  TextPosition getPositionForOffset(Offset point) {
    if (lines.isEmpty) return const TextPosition(0);

    int lineIndex = lines.length - 1;
    for (int i = 0; i < lines.length; i++) {
      if (point.dy < lines[i].bottom) {
        lineIndex = i;
        break;
      }
    }
    final TextLine line = lines[lineIndex];
    if (line.spans.isEmpty) return TextPosition(line.start);

    // Pick the span horizontally, clamping past both ends of the line rather
    // than reporting a miss: a drag that leaves the line still selects to its
    // edge.
    GlyphSpan target = line.spans.first;
    for (final GlyphSpan span in line.spans) {
      if (span.isEllipsis) continue;
      target = span;
      if (point.dx < span.right) break;
    }
    if (target.isEllipsis) return TextPosition(line.end);

    // Walk the span's boundaries and take the closest. Offsets inside a cluster
    // share their cluster's edge, so ties resolve to the cluster start and a
    // caret never lands mid-cluster.
    final double dx = point.dx;
    int bestOffset = target.start;
    double bestDistance = double.infinity;
    for (int offset = target.start; offset <= target.end; offset++) {
      if (offset != target.start &&
          offset != target.end &&
          !GraphemeBreaks.isBoundary(text, offset)) {
        continue;
      }
      final double distance = (target.edgeOf(offset) - dx).abs();
      if (distance < bestDistance) {
        bestDistance = distance;
        bestOffset = offset;
      }
    }
    return TextPosition(
      bestOffset,
      affinity: bestOffset == target.end
          ? TextAffinity.upstream
          : TextAffinity.downstream,
    );
  }

  /// The rectangles covering `[start, end)` - **plural, and that is the point.**
  ///
  /// A selection that is one contiguous range in logical order is generally two
  /// or three disjoint rectangles on screen the moment it crosses a direction
  /// boundary, because the characters between its two ends are drawn somewhere
  /// else entirely. Returning one rectangle would either miss selected text or
  /// highlight text that is not selected, and there is no third option. A
  /// selection spanning several lines is likewise one rectangle per line.
  ///
  /// Rectangles come out in visual order within each line, and adjacent ones
  /// that touch are merged so that a plain left-to-right selection is one box.
  /// The ellipsis is never included: it stands for text that was removed.
  List<TextBox> getBoxesForSelection(int start, int end) {
    final int from = start.clamp(0, text.length);
    final int to = end.clamp(0, text.length);
    if (from >= to) return const <TextBox>[];

    final List<TextBox> boxes = <TextBox>[];
    for (final TextLine line in lines) {
      if (line.endIncludingWhitespace <= from || line.start >= to) continue;
      TextBox? pending;
      for (final GlyphSpan span in line.spans) {
        if (span.isEllipsis) continue;
        final int a = math.max(from, span.start);
        final int b = math.min(to, span.end);
        if (a >= b) continue;
        final double e1 = span.edgeOf(a);
        final double e2 = span.edgeOf(b);
        final Rect rect = Rect.fromLTRB(
          math.min(e1, e2),
          line.top,
          math.max(e1, e2),
          line.top + line.height,
        );
        if (pending != null &&
            pending.direction == span.direction &&
            (rect.left - pending.rect.right).abs() < _epsilon) {
          pending = TextBox(
            Rect.fromLTRB(
              pending.rect.left,
              rect.top,
              rect.right,
              rect.bottom,
            ),
            span.direction,
          );
          continue;
        }
        if (pending != null) boxes.add(pending);
        pending = TextBox(rect, span.direction);
      }
      if (pending != null) boxes.add(pending);
    }
    return boxes;
  }

  @override
  String toString() => 'Paragraph(${text.length} units, ${lines.length} lines, '
      '${longestLine.toStringAsFixed(1)}x${height.toStringAsFixed(1)})';
}

const double _epsilon = 0.01;

// ---------------------------------------------------------------------------
// Segmentation and shaping
// ---------------------------------------------------------------------------

/// What a run contributes to a line.
enum _RunKind {
  /// Ordinary text, shaped.
  glyphs,

  /// A single U+0009, whose width depends on where it lands.
  tab,

  /// A single U+00AD, which is invisible unless the line breaks right after it.
  softHyphen,

  /// A mandatory-break character. Occupies no width and draws nothing: a
  /// newline shaped through `cmap` would otherwise come out as `.notdef`.
  control,
}

const int _tab = 0x09;
const int _softHyphen = 0x00AD;
const int _space = 0x20;
const int _hyphen = 0x2010;
const int _hyphenMinus = 0x2D;

bool _isHardBreak(int unit) =>
    unit == 0x0A ||
    unit == 0x0D ||
    unit == 0x0B ||
    unit == 0x0C ||
    unit == 0x85 ||
    unit == 0x2028 ||
    unit == 0x2029;

/// Whitespace a line may drop from its trailing edge.
///
/// Tabs are **not** in this set. A tab's width depends on the pen position, so
/// trimming one would make the line's width depend on how the trimming was
/// ordered; and a trailing tab is nearly always deliberate.
bool _isTrimmable(int unit) => unit == _space || _isHardBreak(unit);

/// A maximal span of one direction, one script, one style and one kind, shaped.
final class _ShapedRun {
  _ShapedRun({
    required this.start,
    required this.end,
    required this.level,
    required this.style,
    required this.kind,
    required this.glyphIds,
    required this.positions,
    required this.clusters,
    required this.glyphCount,
    required this.width,
    required this.prefix,
  });

  final int start;
  final int end;
  final int level;
  final TextStyle style;
  final _RunKind kind;

  final Int32List glyphIds;
  final Float32List positions;

  /// Source offsets, already rebased into paragraph coordinates.
  final Int32List clusters;
  final int glyphCount;
  final double width;

  /// `prefix[i]` is the advance of the run's logically-first `i` code units.
  ///
  /// Monotonic, `prefix[0] == 0`, `prefix[end - start] == width`. Precomputed
  /// rather than searched per query because line breaking asks for it once per
  /// break opportunity and hit testing asks for it once per character.
  final Float64List prefix;

  bool get isRightToLeft => level.isOdd;

  TextDirection get direction =>
      level.isOdd ? TextDirection.rightToLeft : TextDirection.leftToRight;
}

/// Runs the pipeline once, for one paragraph.
final class _ParagraphBuilder {
  _ParagraphBuilder(this.spans, this.style, this.maxWidth, this.shaper)
      : text = spans.length == 1
            ? spans.first.text
            : spans.map((TextSpan s) => s.text).join();

  final List<TextSpan> spans;
  final ParagraphStyle style;
  final double maxWidth;
  final Shaper shaper;
  final String text;

  late final BidiParagraph _bidi;
  late final List<_ShapedRun> _runs;
  late final double _tabStop;

  TextStyle get _defaultStyle => spans.first.style;

  Paragraph build() {
    _bidi = BidiParagraph.resolve(text, baseDirection: style.baseDirection);
    _tabStop = style.tabStopWidth ?? _defaultTabStop();
    _runs = _shapeRuns();

    final List<_LineRange> ranges = _breakLines();
    final bool exceeded =
        style.maxLines != null && ranges.length > style.maxLines!;
    if (exceeded) ranges.length = style.maxLines!;

    double ellipsisWidth = 0;
    _EllipsisRun? ellipsis;
    if (exceeded && style.ellipsis != null && style.ellipsis!.isNotEmpty) {
      ellipsis = _shapeEllipsis(ranges.last);
      ellipsisWidth = ellipsis.width;
      ranges[ranges.length - 1] = _truncate(ranges.last, ellipsisWidth);
    }

    // Two passes over the lines: alignment needs the paragraph's own width when
    // maxWidth is infinite, and that is only known once every line is measured.
    double longest = 0;
    for (int i = 0; i < ranges.length; i++) {
      final _LineRange r = ranges[i];
      final double w = _advance(0, r.start, _trimEnd(r.start, r.end)) +
          (r.ellipsis ? ellipsisWidth : 0) +
          _hyphenWidthAt(r, i == ranges.length - 1);
      longest = math.max(longest, w);
    }
    final double available = maxWidth.isFinite ? maxWidth : longest;

    final List<TextLine> lines = <TextLine>[];
    double top = 0;
    double widest = 0;
    for (int i = 0; i < ranges.length; i++) {
      final TextLine line = _buildLine(
        i,
        ranges[i],
        isLast: i == ranges.length - 1,
        available: available,
        top: top,
        ellipsis: ranges[i].ellipsis ? ellipsis : null,
      );
      lines.add(line);
      top += line.height;
      widest = math.max(widest, line.width);
    }

    return Paragraph._(
      text: text,
      spans: List<TextSpan>.unmodifiable(spans),
      style: style,
      maxWidth: maxWidth,
      baseDirection: _bidi.baseDirection,
      lines: List<TextLine>.unmodifiable(lines),
      height: top,
      longestLine: widest,
      didExceedMaxLines: exceeded,
    );
  }

  double _defaultTabStop() {
    final ScaledTypeface font = _defaultStyle.font;
    final int glyph = font.typeface.glyphForCodePoint(_space);
    final double advance =
        glyph == 0 ? font.pixelSize * 0.5 : font.advanceOf(glyph);
    return advance * 8;
  }

  // -------------------------------------------------------------------------
  // Step 2 and 3: segment, then shape
  // -------------------------------------------------------------------------

  List<_ShapedRun> _shapeRuns() {
    if (text.isEmpty) return const <_ShapedRun>[];
    final int length = text.length;

    // A boundary is the union of every reason to stop a run. Marking them in
    // one array rather than intersecting three lists of ranges keeps this O(n)
    // and makes "add another reason" a one-line change.
    final Uint8List boundary = Uint8List(length + 1);
    boundary[0] = 1;
    boundary[length] = 1;

    int offset = 0;
    for (final TextSpan span in spans) {
      offset += span.text.length;
      if (offset < length) boundary[offset] = 1;
    }
    final Uint8List levels = _bidi.levels;
    for (int i = 1; i < length; i++) {
      if (levels[i] != levels[i - 1]) boundary[i] = 1;
    }
    for (final ScriptRun run in itemize(text)) {
      boundary[run.start] = 1;
    }
    final bool justifying = style.align == TextAlign.justify;
    for (int i = 0; i < length; i++) {
      final int unit = text.codeUnitAt(i);
      if (unit == _tab ||
          unit == _softHyphen ||
          _isHardBreak(unit) ||
          (justifying && unit == _space)) {
        boundary[i] = 1;
        boundary[i + 1] = 1;
      }
    }

    final List<_ShapedRun> runs = <_ShapedRun>[];
    int start = 0;
    for (int i = 1; i <= length; i++) {
      if (boundary[i] == 0) continue;
      runs.add(_shapeRun(start, i));
      start = i;
    }
    return runs;
  }

  _ShapedRun _shapeRun(int start, int end) {
    final int level = _bidi.levels[start];
    final TextStyle runStyle = _styleAt(start);
    final int first = text.codeUnitAt(start);
    final _RunKind kind = first == _tab
        ? _RunKind.tab
        : first == _softHyphen
            ? _RunKind.softHyphen
            : _isHardBreak(first)
                ? _RunKind.control
                : _RunKind.glyphs;

    if (kind != _RunKind.glyphs) {
      return _emptyRun(start, end, level, runStyle, kind);
    }

    final GlyphRun run = shaper.shape(
      text.substring(start, end),
      runStyle.font,
      script: _scriptAt(start),
      language: runStyle.language,
      direction:
          level.isOdd ? TextDirection.rightToLeft : TextDirection.leftToRight,
    );
    return _copy(run, start, end, level, runStyle, _RunKind.glyphs);
  }

  _ShapedRun _emptyRun(
    int start,
    int end,
    int level,
    TextStyle runStyle,
    _RunKind kind,
  ) =>
      _ShapedRun(
        start: start,
        end: end,
        level: level,
        style: runStyle,
        kind: kind,
        glyphIds: _noGlyphs,
        positions: _noPositions,
        clusters: _noGlyphs,
        glyphCount: 0,
        width: 0,
        prefix: Float64List(end - start + 1),
      );

  /// Copies a shaped run out of the shaper's scratch buffers.
  ///
  /// Not optional. A [GlyphRun] borrows arrays the shaper reuses on its next
  /// call, and a paragraph outlives every call that built it; keeping the
  /// borrowed arrays would give every run in the paragraph the glyphs of the
  /// last one shaped. The allocation happens once per run at layout time, never
  /// per frame - painting a laid-out paragraph allocates nothing here.
  _ShapedRun _copy(
    GlyphRun run,
    int start,
    int end,
    int level,
    TextStyle runStyle,
    _RunKind kind,
  ) {
    final int count = run.length;
    final Int32List ids = Int32List(count);
    final Float32List positions = Float32List(count * 2);
    final Int32List clusters = Int32List(count);
    for (int i = 0; i < count; i++) {
      ids[i] = run.glyphIds[i];
      positions[i * 2] = run.positions[i * 2];
      positions[i * 2 + 1] = run.positions[i * 2 + 1];
      clusters[i] = run.clusters[i] + start;
    }
    return _ShapedRun(
      start: start,
      end: end,
      level: level,
      style: runStyle,
      kind: kind,
      glyphIds: ids,
      positions: positions,
      clusters: clusters,
      glyphCount: count,
      width: run.width,
      prefix: _buildPrefix(
        start,
        end,
        positions,
        clusters,
        count,
        run.width,
        level.isOdd,
      ),
    );
  }

  /// The advance of every logical prefix of a run.
  ///
  /// The left-to-right case reads the x of the first glyph of each cluster. The
  /// right-to-left case is the mirror and is the one that is easy to get wrong:
  /// the run's glyphs come back in *visual* order with descending clusters, so
  /// the logical prefix ending at a boundary is the part drawn on the **right**,
  /// and its advance is the run width minus the x of the glyph that starts the
  /// remainder.
  ///
  /// Offsets with no glyph of their own - the interior of a ligature, the low
  /// half of a surrogate pair - inherit the previous boundary, which places
  /// them at their cluster's leading edge.
  static Float64List _buildPrefix(
    int start,
    int end,
    Float32List positions,
    Int32List clusters,
    int count,
    double width,
    bool rightToLeft,
  ) {
    final int length = end - start;
    final Float64List prefix = Float64List(length + 1);
    final Uint8List known = Uint8List(length + 1);
    if (!rightToLeft) {
      for (int k = 0; k < count; k++) {
        final int index = clusters[k] - start;
        if (index < 0 || index > length || known[index] != 0) continue;
        prefix[index] = positions[k * 2];
        known[index] = 1;
      }
    } else {
      for (int k = 0; k < count; k++) {
        // Glyph k is the leftmost glyph of everything logically after the
        // boundary that the previous glyph in visual order starts at.
        final int index = k == 0 ? length : clusters[k - 1] - start;
        if (index < 0 || index > length) continue;
        prefix[index] = width - positions[k * 2];
        known[index] = 1;
      }
    }
    prefix[0] = 0;
    known[0] = 1;
    prefix[length] = width;
    known[length] = 1;
    for (int i = 1; i <= length; i++) {
      if (known[i] == 0) prefix[i] = prefix[i - 1];
    }
    return prefix;
  }

  TextStyle _styleAt(int offset) {
    int cursor = 0;
    for (final TextSpan span in spans) {
      cursor += span.text.length;
      if (offset < cursor) return span.style;
    }
    return spans.last.style;
  }

  late final List<ScriptRun> _scriptRuns = itemize(text);

  Script _scriptAt(int offset) {
    for (final ScriptRun run in _scriptRuns) {
      if (offset < run.end) return run.script;
    }
    return Script.zyyy;
  }

  // -------------------------------------------------------------------------
  // Measurement
  // -------------------------------------------------------------------------

  int _runIndexAt(int offset) {
    int low = 0;
    int high = _runs.length - 1;
    while (low < high) {
      final int mid = (low + high + 1) >> 1;
      if (_runs[mid].start <= offset) {
        low = mid;
      } else {
        high = mid - 1;
      }
    }
    return low;
  }

  /// Advances [pen] - a width measured from the start of the current line -
  /// across `[from, to)`.
  ///
  /// Takes the pen rather than returning a width because a tab's width is not a
  /// property of the tab: it is the distance from wherever the pen is to the
  /// next stop.
  double _advance(double pen, int from, int to) {
    if (from >= to || _runs.isEmpty) return pen;
    double x = pen;
    for (int i = _runIndexAt(from); i < _runs.length; i++) {
      final _ShapedRun run = _runs[i];
      if (run.start >= to) break;
      final int a = math.max(from, run.start);
      final int b = math.min(to, run.end);
      if (a >= b) continue;
      switch (run.kind) {
        case _RunKind.tab:
          x = (x / _tabStop).floorToDouble() * _tabStop + _tabStop;
        case _RunKind.control:
        case _RunKind.softHyphen:
          break;
        case _RunKind.glyphs:
          x += run.prefix[b - run.start] - run.prefix[a - run.start];
      }
    }
    return x;
  }

  int _trimEnd(int start, int end) {
    int cursor = end;
    while (cursor > start && _isTrimmable(text.codeUnitAt(cursor - 1))) {
      cursor--;
    }
    return cursor;
  }

  final Map<TextStyle, _HyphenGlyph> _hyphens = <TextStyle, _HyphenGlyph>{};

  /// The hyphen a soft break at [offset] would need, measured for real.
  _HyphenGlyph _hyphenFor(TextStyle runStyle) =>
      _hyphens.putIfAbsent(runStyle, () {
        final Typeface face = runStyle.font.typeface;
        int glyph = face.glyphForCodePoint(_hyphen);
        if (glyph == 0) glyph = face.glyphForCodePoint(_hyphenMinus);
        return _HyphenGlyph(
            glyph, glyph == 0 ? 0 : runStyle.font.advanceOf(glyph));
      });

  /// The width a break at [position] costs, which is a hyphen when the
  /// character before it is a soft hyphen and zero otherwise.
  double _softHyphenWidthAt(int position) {
    if (position <= 0 || position > text.length) return 0;
    if (text.codeUnitAt(position - 1) != _softHyphen) return 0;
    return _hyphenFor(_styleAt(position - 1)).width;
  }

  double _hyphenWidthAt(_LineRange range, bool isLast) {
    if (isLast || range.hard) return 0;
    return _softHyphenWidthAt(range.end);
  }

  // -------------------------------------------------------------------------
  // Step 4: break into lines
  // -------------------------------------------------------------------------

  List<_LineRange> _breakLines() {
    final List<_LineRange> ranges = <_LineRange>[];
    if (text.isEmpty) {
      return <_LineRange>[const _LineRange(0, 0, true)];
    }

    int lineStart = 0;
    double pen = 0;
    int measured = 0;
    int candidate = -1;

    double widthAt(int position) =>
        pen -
        _advance(0, _trimEnd(lineStart, position), position) +
        _softHyphenWidthAt(position);

    for (final LineBreakOpportunity op
        in LineBreaker.breakOpportunities(text)) {
      final int p = op.position;
      if (p <= lineStart) continue;
      pen = _advance(pen, measured, p);
      measured = p;
      double width = widthAt(p);

      if (width > maxWidth && candidate > lineStart) {
        // The line has a break that fits; take it and re-measure this
        // opportunity against the line that starts there. One retry is enough:
        // the new line has no opportunity inside it, so it either fits or
        // overflows, and overflowing is what "no emergency breaking" means.
        ranges.add(_LineRange(lineStart, candidate, false));
        lineStart = candidate;
        pen = 0;
        measured = lineStart;
        pen = _advance(pen, measured, p);
        measured = p;
        width = widthAt(p);
        candidate = -1;
      }
      candidate = p;

      if (op.isMandatory) {
        ranges.add(_LineRange(lineStart, p, true));
        lineStart = p;
        pen = 0;
        measured = p;
        candidate = -1;
      }
    }
    if (lineStart < text.length) {
      ranges.add(_LineRange(lineStart, text.length, true));
    }
    if (ranges.isEmpty) {
      ranges.add(const _LineRange(0, 0, true));
    } else if (_isHardBreak(text.codeUnitAt(text.length - 1))) {
      // UAX #14 puts its last opportunity at `text.length`, so `"a\n"` produces
      // one line. A trailing newline means an empty line follows it, and a text
      // field that does not show one has no way to put the caret there.
      ranges.add(_LineRange(text.length, text.length, true));
    }
    return ranges;
  }

  // -------------------------------------------------------------------------
  // Step 5 (maxLines and ellipsis)
  // -------------------------------------------------------------------------

  _EllipsisRun _shapeEllipsis(_LineRange range) {
    // Shaped with the style of the last run the line kept, so an ellipsis after
    // a large word is drawn large. Falls back to the paragraph's first style
    // for a line with no runs at all.
    TextStyle runStyle = _defaultStyle;
    for (final _ShapedRun run in _runs) {
      if (run.start >= range.end) break;
      if (run.kind == _RunKind.glyphs) runStyle = run.style;
    }
    final String ellipsis = style.ellipsis!;
    final GlyphRun run = shaper.shape(
      ellipsis,
      runStyle.font,
      script: itemize(ellipsis).first.script,
      language: runStyle.language,
      direction: _bidi.baseDirection,
    );
    final int count = run.length;
    final Int32List ids = Int32List(count);
    final Float32List positions = Float32List(count * 2);
    for (int i = 0; i < count; i++) {
      ids[i] = run.glyphIds[i];
      positions[i * 2] = run.positions[i * 2];
      positions[i * 2 + 1] = run.positions[i * 2 + 1];
    }
    return _EllipsisRun(ids, positions, count, run.width, runStyle);
  }

  /// Cuts [range] back until the ellipsis fits, never inside a cluster.
  ///
  /// [GraphemeBreaks.previous] is what makes that true. Walking back by code
  /// unit would split a surrogate pair into two unpaired halves - the text
  /// would render as two replacement boxes - and would strip the modifier off
  /// an emoji, or one member off a ZWJ sequence, turning a family into a man.
  _LineRange _truncate(_LineRange range, double ellipsisWidth) {
    int cut = _trimEnd(range.start, range.end);
    while (cut > range.start &&
        _advance(0, range.start, cut) + ellipsisWidth > maxWidth) {
      cut = GraphemeBreaks.previous(text, cut);
    }
    return _LineRange(range.start, cut, true, ellipsis: true);
  }

  // -------------------------------------------------------------------------
  // Step 6: visual order, alignment, justification
  // -------------------------------------------------------------------------

  TextLine _buildLine(
    int index,
    _LineRange range, {
    required bool isLast,
    required double available,
    required double top,
    required _EllipsisRun? ellipsis,
  }) {
    final int end =
        range.ellipsis ? range.end : _trimEnd(range.start, range.end);
    final List<_Draft> drafts = <_Draft>[];

    // Logical order first: the levels L2 reorders are the levels of the runs in
    // the order they are stored in, and the tab stops are counted in that order
    // too.
    double pen = 0;
    for (int i = _runs.isEmpty ? 0 : _runIndexAt(range.start);
        i < _runs.length;
        i++) {
      final _ShapedRun run = _runs[i];
      if (run.start >= end) break;
      final int a = math.max(range.start, run.start);
      final int b = math.min(end, run.end);
      if (a >= b || run.kind == _RunKind.control) continue;

      double width;
      switch (run.kind) {
        case _RunKind.tab:
          width = (pen / _tabStop).floorToDouble() * _tabStop + _tabStop - pen;
        case _RunKind.softHyphen:
          // Invisible unless the line ends right here and something follows:
          // that is the whole contract of U+00AD, and rendering it always is
          // the bug this branch exists to avoid.
          width = b == end && !isLast && !range.hard
              ? _hyphenFor(run.style).width
              : 0;
        case _RunKind.control:
        case _RunKind.glyphs:
          width = run.prefix[b - run.start] - run.prefix[a - run.start];
      }
      drafts.add(_Draft(run, a, b, width));
      pen += width;
    }

    if (ellipsis != null) {
      drafts.add(_Draft.ellipsis(ellipsis, end, _bidi.paragraphLevel));
      pen += ellipsis.width;
    }

    // Justification. Only U+0020 stretches, only on a line that has another
    // line after it, and only when there is a finite width to stretch to.
    if (style.align == TextAlign.justify &&
        !isLast &&
        !range.hard &&
        available.isFinite &&
        pen < available) {
      int spaces = 0;
      for (final _Draft draft in drafts) {
        if (draft.isSpace(text)) spaces++;
      }
      if (spaces > 0) {
        final double extra = (available - pen) / spaces;
        for (final _Draft draft in drafts) {
          if (draft.isSpace(text)) draft.width += extra;
        }
        pen = available;
      }
    }

    final double lineWidth = pen;
    final double free = available.isFinite ? available - lineWidth : 0;
    final bool ltr = !_bidi.baseDirection.isRightToLeft;
    final double offset = switch (style.align) {
      TextAlign.left => 0,
      TextAlign.right => free,
      TextAlign.center => free / 2,
      TextAlign.start || TextAlign.justify => ltr ? 0 : free,
      TextAlign.end => ltr ? free : 0,
    };

    // Rule L2, on this line's runs and no others. Reordering before breaking
    // would have mixed this line's runs with the next line's.
    final List<int> order = BidiParagraph.reorderVisual(
      <int>[for (final _Draft draft in drafts) draft.level],
    );
    final List<GlyphSpan> ordered = <GlyphSpan>[];
    double x = offset;
    for (final int i in order) {
      final _Draft draft = drafts[i];
      ordered.add(draft.toSpan(x, text));
      x += draft.width;
    }

    double ascent = 0;
    double descent = 0;
    double gap = 0;
    for (final _Draft draft in drafts) {
      final ScaledTypeface font = draft.style.font;
      ascent = math.max(ascent, font.ascent);
      descent = math.max(descent, font.descent);
      gap = math.max(gap, font.lineGap);
    }
    if (drafts.isEmpty) {
      final ScaledTypeface font = _styleAt(
        range.start >= text.length ? math.max(0, text.length - 1) : range.start,
      ).font;
      ascent = font.ascent;
      descent = font.descent;
      gap = font.lineGap;
    }
    final double natural = ascent + descent + gap;
    final double height = natural * style.heightMultiplier;
    // The multiplier's extra is split above and below rather than dropped below
    // the baseline, so raising it keeps text centred in its line box.
    final double leading = (height - natural) / 2;

    return TextLine._(
      lineNumber: index,
      start: range.start,
      end: end,
      endIncludingWhitespace: range.end,
      hardBreak: range.hard,
      left: offset,
      width: lineWidth,
      top: top,
      ascent: ascent,
      descent: descent,
      height: height,
      baseline: top + leading + ascent,
      spans: List<GlyphSpan>.unmodifiable(ordered),
    );
  }
}

final Int32List _noGlyphs = Int32List(0);
final Float32List _noPositions = Float32List(0);

final class _HyphenGlyph {
  const _HyphenGlyph(this.glyphId, this.width);

  final int glyphId;
  final double width;
}

final class _EllipsisRun {
  const _EllipsisRun(
    this.glyphIds,
    this.positions,
    this.count,
    this.width,
    this.style,
  );

  final Int32List glyphIds;
  final Float32List positions;
  final int count;
  final double width;
  final TextStyle style;
}

/// A line's extent before it becomes geometry.
final class _LineRange {
  const _LineRange(this.start, this.end, this.hard, {this.ellipsis = false});

  final int start;

  /// One past the last code unit, trailing whitespace included.
  final int end;

  /// Whether the line ends at a mandatory break or at the end of the text.
  final bool hard;

  /// Whether the line was cut by [ParagraphStyle.maxLines] and gets an
  /// ellipsis.
  final bool ellipsis;
}

/// A piece of a run assigned to a line, before its position is known.
final class _Draft {
  _Draft(_ShapedRun this.run, this.start, this.end, this.width)
      : level = run.level,
        style = run.style,
        ellipsis = null;

  _Draft.ellipsis(_EllipsisRun this.ellipsis, int at, this.level)
      : run = null,
        start = at,
        end = at,
        style = ellipsis.style,
        width = ellipsis.width;

  final _ShapedRun? run;
  final _EllipsisRun? ellipsis;
  final int start;
  final int end;
  final int level;
  final TextStyle style;
  double width;

  bool get isRightToLeft => level.isOdd;

  bool isSpace(String text) =>
      run != null &&
      run!.kind == _RunKind.glyphs &&
      end - start == 1 &&
      text.codeUnitAt(start) == _space;

  GlyphSpan toSpan(double left, String text) {
    final _EllipsisRun? dots = ellipsis;
    if (dots != null) {
      return GlyphSpan._(
        glyphs: GlyphRun(
          font: style.font,
          glyphIds: dots.glyphIds,
          positions: dots.positions,
          clusters: _noGlyphs,
          length: dots.count,
          width: dots.width,
        ),
        left: left,
        width: width,
        start: start,
        end: end,
        bidiLevel: level,
        style: style,
        isEllipsis: true,
        edges: Float64List(1),
      );
    }

    final _ShapedRun source = run!;
    final double a = source.prefix[start - source.start];
    final double b = source.prefix[end - source.start];
    final double leftEdge = source.isRightToLeft ? source.width - b : a;

    if (source.kind != _RunKind.glyphs) {
      // A tab, or a soft hyphen that the break landed on. Neither has glyphs
      // from the run itself; the hyphen borrows one from the face.
      final bool drawsHyphen = source.kind == _RunKind.softHyphen && width > 0;
      final _HyphenGlyph glyph = drawsHyphen
          ? _HyphenGlyph(
              style.font.typeface.glyphForCodePoint(_hyphen) == 0
                  ? style.font.typeface.glyphForCodePoint(_hyphenMinus)
                  : style.font.typeface.glyphForCodePoint(_hyphen),
              width,
            )
          : const _HyphenGlyph(0, 0);
      final Int32List ids =
          drawsHyphen ? Int32List.fromList(<int>[glyph.glyphId]) : _noGlyphs;
      final Float32List positions = drawsHyphen ? Float32List(2) : _noPositions;
      final Int32List clusters =
          drawsHyphen ? Int32List.fromList(<int>[start]) : _noGlyphs;
      final Float64List edges = Float64List(end - start + 1);
      edges[edges.length - 1] = width;
      return GlyphSpan._(
        glyphs: GlyphRun(
          font: style.font,
          glyphIds: ids,
          positions: positions,
          clusters: clusters,
          length: drawsHyphen ? 1 : 0,
          width: width,
          direction: level.isOdd
              ? TextDirection.rightToLeft
              : TextDirection.leftToRight,
        ),
        left: left,
        width: width,
        start: start,
        end: end,
        bidiLevel: level,
        style: style,
        isEllipsis: false,
        edges: edges,
      );
    }

    // Glyphs whose cluster falls inside the slice, which is a contiguous range
    // in visual order in both directions: clusters ascend in a left-to-right
    // run and descend in a right-to-left one.
    int first = source.glyphCount;
    int last = 0;
    for (int k = 0; k < source.glyphCount; k++) {
      final int cluster = source.clusters[k];
      if (cluster < start || cluster >= end) continue;
      if (k < first) first = k;
      if (k + 1 > last) last = k + 1;
    }
    final int count = last > first ? last - first : 0;
    final Int32List ids = Int32List(count);
    final Float32List positions = Float32List(count * 2);
    final Int32List clusters = Int32List(count);
    for (int k = 0; k < count; k++) {
      ids[k] = source.glyphIds[first + k];
      positions[k * 2] = source.positions[(first + k) * 2] - leftEdge;
      positions[k * 2 + 1] = source.positions[(first + k) * 2 + 1];
      clusters[k] = source.clusters[first + k];
    }

    final Float64List edges = Float64List(end - start + 1);
    for (int i = 0; i <= end - start; i++) {
      edges[i] = source.prefix[start - source.start + i] - a;
    }
    edges[edges.length - 1] = width;

    return GlyphSpan._(
      glyphs: GlyphRun(
        font: style.font,
        glyphIds: ids,
        positions: positions,
        clusters: clusters,
        length: count,
        width: b - a,
        direction:
            level.isOdd ? TextDirection.rightToLeft : TextDirection.leftToRight,
      ),
      left: left,
      width: width,
      start: start,
      end: end,
      bidiLevel: level,
      style: style,
      isEllipsis: false,
      edges: edges,
    );
  }
}

// ---------------------------------------------------------------------------
// Cache
// ---------------------------------------------------------------------------

/// Laid-out paragraphs, keyed by everything that changes one.
///
/// Shaping is the expensive step and a widget lays out on every constraint
/// change, so the same string at the same width is laid out again and again.
///
/// ## What is in the key, exactly
///
/// The key is the pair (spans, [ParagraphStyle], `maxWidth`):
///
///  * every [TextSpan]: its text **and** its [TextStyle], which is the
///    [ScaledTypeface] - compared by face *identity* and pixel size - plus the
///    OpenType language tag. Face identity rather than face equality because a
///    [Typeface] is parsed bytes with no meaningful value equality, and because
///    re-parsing the same file legitimately produces a different face that may
///    shape differently;
///  * every field of [ParagraphStyle]: alignment, forced base direction,
///    `maxLines`, the ellipsis string, the tab stop and the height multiplier.
///    All of them change the geometry, and `align` additionally changes the run
///    segmentation, because justification splits spaces into their own runs;
///  * `maxWidth`, by exact value. A paragraph resized by a pixel is a different
///    paragraph, and rounding the key would hand back a layout that overflows.
///
/// What is deliberately **not** in the key: the [Shaper], which is a property of
/// the cache rather than of the request - a cache built with a different shaper
/// is a different cache. And nothing about the paint: colour does not change
/// layout.
///
/// ## Invalidation
///
/// There is none, by design: every input is immutable and value-compared, so an
/// entry cannot go stale. The one thing that *can* change underneath it is a
/// [Typeface] being replaced - `FontRegistry.useTypeface`, a font file
/// reloaded - and that produces new [ScaledTypeface] instances, so the old
/// entries become unreachable rather than wrong. They still occupy the cache,
/// which is what [clear] is for.
final class ParagraphCache {
  ParagraphCache({this.maximumEntries = 64, Shaper? shaper})
      : shaper = shaper ?? sharedShaper;

  /// How many laid-out paragraphs to keep. Least recently used goes first.
  final int maximumEntries;

  final Shaper shaper;

  final Map<_ParagraphKey, Paragraph> _entries = <_ParagraphKey, Paragraph>{};

  int _hits = 0;
  int _misses = 0;

  int get hitCount => _hits;
  int get missCount => _misses;
  int get entryCount => _entries.length;

  Paragraph layout({
    required List<TextSpan> spans,
    ParagraphStyle style = const ParagraphStyle(),
    double maxWidth = double.infinity,
  }) {
    final _ParagraphKey key = _ParagraphKey(spans, style, maxWidth);
    final Paragraph? hit = _entries.remove(key);
    if (hit != null) {
      // Re-inserted so the map's insertion order is the recency order, which is
      // what makes eviction O(1) without a second structure.
      _entries[key] = hit;
      _hits++;
      return hit;
    }
    _misses++;
    final Paragraph laid = Paragraph.layout(
      spans: spans,
      style: style,
      maxWidth: maxWidth,
      shaper: shaper,
    );
    _entries[key] = laid;
    while (_entries.length > maximumEntries) {
      _entries.remove(_entries.keys.first);
    }
    return laid;
  }

  Paragraph single(
    String text,
    TextStyle style, {
    ParagraphStyle paragraphStyle = const ParagraphStyle(),
    double maxWidth = double.infinity,
  }) =>
      layout(
        spans: <TextSpan>[TextSpan(text, style)],
        style: paragraphStyle,
        maxWidth: maxWidth,
      );

  void clear() {
    _entries.clear();
    _hits = 0;
    _misses = 0;
  }
}

final class _ParagraphKey {
  _ParagraphKey(List<TextSpan> spans, this.style, this.maxWidth)
      : spans = List<TextSpan>.unmodifiable(spans),
        _hash = Object.hash(
          Object.hashAll(spans),
          style,
          maxWidth,
        );

  final List<TextSpan> spans;
  final ParagraphStyle style;
  final double maxWidth;
  final int _hash;

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! _ParagraphKey) return false;
    if (other._hash != _hash ||
        other.maxWidth != maxWidth ||
        other.style != style ||
        other.spans.length != spans.length) {
      return false;
    }
    for (int i = 0; i < spans.length; i++) {
      if (other.spans[i] != spans[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => _hash;
}
