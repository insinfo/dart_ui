/// Measuring artistic text, so the canvas can hit it and put a caret in it.
///
/// The document model deliberately owns no font engine: a `VectorText` is a
/// string, a size and a transform, and it has to be loadable, convertible and
/// serializable on a machine with no rasterizer at all. That is why
/// `VectorText.getInitialPaths()` returns nothing, and it is also why - before
/// this file - `VectorText.cacheBbox` was `Rect.zero` and no text object could
/// ever be clicked, selected, double-clicked or caught by a rubber band. The
/// text drew perfectly and did not exist to the pointer.
///
/// So the measurement lives here, in the editor, which is the layer that
/// already has [FontRegistry], and is handed to the model through
/// [VectorText.inkProvider]. Installing it is idempotent and cheap;
/// [VectorCanvas] does it on mount so that any document a canvas shows has
/// measurable text, and an application that builds documents before mounting a
/// canvas can call [install] itself.
///
/// **Everything here is in document units, not device pixels.** The face is
/// scaled to the text's own `fontSize`, never to `fontSize * zoom`, so a box
/// measured at 400% zoom is the same box as one measured at 25%. The renderer
/// does the opposite - it shapes at `fontSize * zoom` to keep glyphs crisp -
/// and the two must not be confused: a hit test in device units would move the
/// clickable area of a text every time the user zoomed.
library;

import '../geometry/offset.dart';
import '../geometry/path.dart';
import '../geometry/rect.dart';
import '../graphics/color.dart';
import '../graphics/vector/constants.dart';
import '../graphics/vector/primitives.dart';
import '../graphics/vector/style.dart';
import '../rendering/text/font_registry.dart';
import '../rendering/text/text_painter.dart';
import '../text/grapheme.dart';
import '../text/paragraph.dart'
    show
        GlyphSpan,
        Paragraph,
        ParagraphStyle,
        TextAlign,
        TextBox,
        TextLine,
        TextPosition;
import '../text/shaper.dart' show GlyphRun;
import '../text/typeface.dart';

/// Measures [VectorText] with the registry's fonts.
abstract final class VectorTextMetrics {
  static final TextPainter _painter = TextPainter();

  static bool _installed = false;

  /// Points [VectorText.inkProvider] at this measurer. Idempotent.
  ///
  /// Not automatic: a static initialiser would run at an unpredictable moment
  /// relative to `FrameworkFonts.install()`, and a measurer that ran before the
  /// fonts were registered would cache nothing useful and hide the ordering
  /// problem. Calling it explicitly makes the dependency visible.
  static void install() {
    if (_installed) return;
    _installed = true;
    VectorText.inkProvider = measure;
    VectorText.linesProvider = lines;
  }

  /// Undoes [install], for a test that wants the metric-free approximation.
  static void uninstall() {
    _installed = false;
    VectorText.inkProvider = null;
    VectorText.linesProvider = null;
  }

  /// The face [text] is drawn with, at *document* scale, or null when the
  /// registry has no font loaded.
  static ScaledTypeface? faceFor(VectorText text) {
    final descriptor = text.style.textStyle;
    final size = descriptor.fontSize;
    if (size <= 0) return null;
    return faceAt(descriptor, size);
  }

  static final Map<(String, bool, bool, double), ScaledTypeface?> _faces =
      <(String, bool, bool, double), ScaledTypeface?>{};

  /// The face [descriptor] names - its family, bold and italic - at [size]
  /// pixels, or the interface face when the family is not on this machine.
  /// What the canvas draws with and what this measures with, so the two
  /// cannot disagree about a single glyph.
  static ScaledTypeface? faceAt(TextStyleDescriptor descriptor, double size) {
    final key = (
      descriptor.fontFamily,
      descriptor.bold,
      descriptor.italic,
      size,
    );
    if (_faces.containsKey(key)) return _faces[key];
    if (_faces.length > 512) _faces.clear();
    final registry = FontRegistry.instance;
    final weight = descriptor.bold ? 700 : 400;
    final family = descriptor.fontFamily;
    // 'Sans' is the model's default and names no real family: the
    // interface face is what it has always meant.
    final named = family.isEmpty || family == 'Sans'
        ? null
        : registry.faceFor(family, weight: weight, italic: descriptor.italic);
    ScaledTypeface? face = named?.atSize(size);
    if (face == null && descriptor.italic) {
      final ui = registry.uiTypeface;
      final slanted = ui == null
          ? null
          : registry.faceFor(ui.familyName ?? '', weight: weight, italic: true);
      face = slanted?.atSize(size);
    }
    face ??= registry.uiFont(size, weight: weight);
    return _faces[key] = face;
  }

  /// Whether [text] is laid out as lines rather than as one run: a
  /// paragraph text, which wraps in its frame, or an artistic text with a
  /// line break in it.
  static bool isMultiline(VectorText text) =>
      text.isParagraphText || text.textContent.contains('\n');

  /// [text]'s lines with [face], the frame's width multiplied by [scale] -
  /// the document scale for measuring, the device scale for drawing, so the
  /// two break the lines in the same places.
  static Paragraph paragraphAt(
          VectorText text, ScaledTypeface face, double scale) =>
      _painter.layout(
        text.textContent,
        face,
        maxWidth: text.isParagraphText ? text.width * scale : double.infinity,
        style: ParagraphStyle(
          align: switch (text.style.textStyle.alignment) {
            VectorTextAlign.left => TextAlign.left,
            VectorTextAlign.center => TextAlign.center,
            VectorTextAlign.right => TextAlign.right,
            VectorTextAlign.justify => TextAlign.justify,
          },
          // A word longer than the frame is cut rather than spilling out of
          // it, as a paragraph frame does in every layout program.
          breakWords: text.isParagraphText,
        ),
      );

  /// [text]'s lines as laid out, for an exporter: one entry per line, each
  /// placed from the first baseline's origin.
  static List<VectorTextLine> lines(VectorText text) {
    final String content = text.textContent;
    final VectorTextInk ink = measure(text);
    final Paragraph? laid = isMultiline(text) ? paragraph(text) : null;
    if (laid == null) {
      return <VectorTextLine>[
        VectorTextLine(text: content, x: ink.left, y: 0),
      ];
    }
    final bool justify =
        text.style.textStyle.alignment == VectorTextAlign.justify;
    return <VectorTextLine>[
      for (final TextLine line in laid.lines)
        VectorTextLine(
          text: content.substring(line.start, line.end),
          x: ink.left + line.left,
          y: line.baseline - ink.ascent,
          // The last line of a paragraph, and one a break ends, keep their
          // natural width under justification.
          justifiedWidth: justify &&
                  !line.hardBreak &&
                  line.endIncludingWhitespace < content.length
              ? line.width
              : null,
        ),
    ];
  }

  /// [text]'s lines at document scale, or null with no font.
  static Paragraph? paragraph(VectorText text) {
    final face = faceFor(text);
    return face == null ? null : paragraphAt(text, face, 1);
  }

  /// The ink box of [text] in its own units, falling back to the model's
  /// approximation when no font is available.
  ///
  /// The origin is the first line's baseline, for every kind of text: at
  /// the anchor for artistic text, where its alignment hangs the line from,
  /// and at the frame's left edge for paragraph text, whose frame is
  /// [VectorText.width] wide and as tall as its lines.
  static VectorTextInk measure(VectorText text) {
    final face = faceFor(text);
    if (face == null) return VectorText.approximateInk(text);
    if (isMultiline(text)) {
      final Paragraph laid = paragraphAt(text, face, 1);
      final double first = laid.lines.first.baseline;
      final double lines =
          laid.longestLine <= 0 ? face.pixelSize * 0.5 : laid.longestLine;
      final double width = text.isParagraphText ? text.width : lines;
      return VectorTextInk(
        left: text.isParagraphText ? 0 : text.alignmentShift(width),
        width: width,
        ascent: first,
        descent: laid.height - first,
      );
    }
    final width = text.textContent.isEmpty
        ? 0.0
        : _painter.measure(text.textContent, face).width;
    final box = width <= 0 ? face.pixelSize * 0.5 : width;
    return VectorTextInk(
      left: text.alignmentShift(box),
      // An empty text still needs a grabbable box, or clearing every character
      // of a text object would make it impossible to click back into. Half an
      // em of caret is what a text field shows for the same reason.
      width: width <= 0 ? face.pixelSize * 0.5 : width,
      ascent: face.ascent,
      descent: face.descent,
    );
  }

  /// How far along the baseline the caret sits for [offset], in text units.
  ///
  /// Measured by shaping the prefix, which is one shaping call per caret move
  /// and exact for everything except a kerning pair straddling the caret - and
  /// a caret cannot be inside a kerning pair without also being inside a
  /// grapheme cluster, which [TextEditingValue] forbids.
  static double caretX(VectorText text, int offset) =>
      caretRect(text, offset).left;

  /// The caret for [offset], as a zero-width rectangle in text units: its
  /// x, and the top and bottom of its line.
  static Rect caretRect(VectorText text, int offset) {
    final VectorTextInk ink = measure(text);
    final Paragraph? laid = isMultiline(text) ? paragraph(text) : null;
    if (laid == null) {
      final double x = _advanceTo(text, offset) + ink.left;
      return Rect.fromLTRB(x, -ink.ascent, x, ink.descent);
    }
    final Rect caret = laid.getCaretRect(TextPosition(offset));
    return caret.shift(Offset(ink.left, -ink.ascent));
  }

  /// The rectangles [start]..[end] covers, one per line, in text units.
  static List<Rect> selectionRects(VectorText text, int start, int end) {
    if (end <= start) return const <Rect>[];
    final VectorTextInk ink = measure(text);
    final Paragraph? laid = isMultiline(text) ? paragraph(text) : null;
    if (laid == null) {
      return <Rect>[
        Rect.fromLTRB(
            caretX(text, start), -ink.ascent, caretX(text, end), ink.descent),
      ];
    }
    return <Rect>[
      for (final TextBox box in laid.getBoxesForSelection(start, end))
        box.rect.shift(Offset(ink.left, -ink.ascent)),
    ];
  }

  /// The cluster boundary nearest [point], in text units.
  static int offsetAt(VectorText text, Offset point) {
    final Paragraph? laid = isMultiline(text) ? paragraph(text) : null;
    if (laid == null) return offsetAtX(text, point.dx);
    final VectorTextInk ink = measure(text);
    return laid
        .getPositionForOffset(point - Offset(ink.left, -ink.ascent))
        .offset;
  }

  static double _advanceTo(VectorText text, int offset) {
    if (offset <= 0) return 0;
    final face = faceFor(text);
    final clamped = offset.clamp(0, text.textContent.length);
    final prefix = text.textContent.substring(0, clamped);
    if (prefix.isEmpty) return 0;
    if (face == null) {
      return prefix.length * text.style.textStyle.fontSize * 0.52;
    }
    return _painter.measure(prefix, face).width;
  }

  /// The cluster boundary nearest to [x], measured along the baseline.
  ///
  /// Used to place the caret from a click. Boundaries only: an offset inside a
  /// cluster is rejected by [TextEditingValue], and rounding to the nearest
  /// boundary is what makes a click in the middle of an emoji land on one side
  /// of it rather than raising.
  static int offsetAtX(VectorText text, double x) {
    final content = text.textContent;
    if (content.isEmpty) return 0;
    var best = 0;
    var bestDistance = double.infinity;
    for (var offset = 0;
        offset <= content.length;
        offset = GraphemeBreaks.next(content, offset)) {
      final distance = (caretX(text, offset) - x).abs();
      if (distance < bestDistance) {
        bestDistance = distance;
        best = offset;
      }
      if (offset == content.length) break;
    }
    return best;
  }

  /// [text] as a curve with the same outline: every glyph's contours, placed
  /// where the shaper put them, in the text's own units and under its
  /// transform - CorelDRAW's Convert to Curves (Ctrl+Q) on artistic text.
  ///
  /// The fill is the text's colour - black when it has none, as the renderer
  /// draws it - with the nonzero rule fonts are designed for, so a glyph whose
  /// contours overlap is not punched with holes. Null when the registry has no
  /// font to take the outlines from, or the text is empty.
  static VectorCurve? toCurves(VectorText text) {
    final content = text.textContent;
    final face = faceFor(text);
    if (face == null || content.isEmpty) return null;
    final paths = <VectorPath>[];
    final double scale = face.scale;
    final VectorTextInk ink = measure(text);
    // Every run with where its glyphs start: one for a line of artistic
    // text, one per span of every line for a paragraph.
    final runs = <(GlyphRun, Offset)>[];
    if (isMultiline(text)) {
      final Paragraph laid = paragraphAt(text, face, 1);
      for (final TextLine line in laid.lines) {
        for (final GlyphSpan span in line.spans) {
          runs.add((
            span.glyphs,
            Offset(ink.left + span.left, line.baseline - ink.ascent),
          ));
        }
      }
    } else {
      runs.add((_painter.shapeRun(content, face), Offset(ink.left, 0)));
    }
    for (final (GlyphRun run, Offset origin) in runs) {
      _outline(run, origin, face, scale, paths);
    }
    if (paths.isEmpty) return null;
    final fill = text.style.fill.isNone
        ? const FillDescriptor.solid(Color(0xFF000000))
        : text.style.fill;
    final curve = VectorCurve(
      trafo: List.of(text.trafo),
      style: text.style.copyWith(
        fill: fill.copyWith(fillRule: FillRule.nonZero),
        // The renderer draws text without its outline; the curve must look
        // the same the moment it replaces it.
        stroke: StrokeDescriptor.none,
      ),
      paths: paths,
    );
    curve.update();
    return curve;
  }

  /// Appends [run]'s glyph outlines, placed from [origin], to [paths].
  static void _outline(GlyphRun run, Offset origin, ScaledTypeface face,
      double scale, List<VectorPath> paths) {
    for (var i = 0; i < run.length; i++) {
      final double gx = run.positions[2 * i] + origin.dx;
      final double gy = run.positions[2 * i + 1] + origin.dy;
      // Font units, y up, to text units, y down from the baseline.
      Offset at(Path path, int point) => Offset(
            gx + path.pointX(point) * scale,
            gy - path.pointY(point) * scale,
          );
      final Path outline = face.typeface.outlineOf(run.glyphIds[i]);
      VectorPath? current;
      Offset pen = Offset.zero;
      var point = 0;
      for (var v = 0; v < outline.verbCount; v++) {
        final int verb = outline.verbAt(v);
        switch (verb) {
          case verbMoveTo:
            pen = at(outline, point);
            current = VectorPath(start: pen);
            paths.add(current);
          case verbLineTo:
            pen = at(outline, point);
            current?.points.add(pen);
          case verbQuadraticTo:
            // Exact as a cubic: controls two thirds of the way to the
            // quadratic's one.
            final Offset q = at(outline, point);
            final Offset end = at(outline, point + 1);
            current?.points.add(CurvePoint(
              pen + (q - pen) * (2 / 3),
              end + (q - end) * (2 / 3),
              end,
            ));
            pen = end;
          case verbCubicTo:
            final Offset end = at(outline, point + 2);
            current?.points.add(
                CurvePoint(at(outline, point), at(outline, point + 1), end));
            pen = end;
          case verbClose:
            current?.closure = PathClosure.closed;
        }
        point += pointsPerVerb(verb);
      }
    }
  }
}
