/// The join between shaping and drawing.
///
/// Everything below this point exists and is tested: a parser turns font bytes
/// into a [Typeface], a shaper turns a string into positioned glyphs, and a
/// rasterizer turns a glyph into coverage. Everything above it draws by
/// appending to a [DisplayList]. This file is the twenty lines that connect
/// them, and the reason it is worth its own file is that it is the only place
/// that knows the run-splitting rule and the baseline convention - both of
/// which are easy to get subtly wrong and hard to notice.
///
/// It lives under `rendering/` rather than `text/` for the reason section 22.7
/// gives: the font parser must not know about renderers. A display list is a
/// rendering concept, so the file that emits one belongs on this side.
library;

import 'dart:typed_data';

import '../../geometry/offset.dart';
import '../../geometry/size.dart';
import '../../graphics/display_list.dart';
import '../../graphics/display_list_opcodes.dart';
import '../../text/shaper.dart';
import '../../text/typeface.dart';

/// Shapes text and appends it to a display list.
///
/// Holds a [Shaper], which holds reusable buffers, so one painter per layout
/// context rather than one per string.
final class TextPainter {
  TextPainter({Shaper? shaper}) : _shaper = shaper ?? LatinShaper();

  final Shaper _shaper;

  Shaper get shaper => _shaper;

  /// Appends [text] to [list], with the **left end of its baseline** at
  /// [origin].
  ///
  /// Baseline, not top-left. Every font metric is expressed relative to the
  /// baseline - ascent above it, descent below - so a caller that wants to
  /// place a box around text asks the font for its ascent rather than having
  /// this guess. Callers that think in boxes use [paintInBox].
  ///
  /// Returns the shaped run so a caller can measure what it drew without
  /// shaping twice. The run borrows the shaper's buffers and is only valid
  /// until the next call.
  GlyphRun paint(
    DisplayList list,
    String text,
    ScaledTypeface font,
    Offset baselineOrigin,
    int paintId,
  ) {
    final GlyphRun run = _shaper.shape(text, font);
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
      final Int32List ids = Int32List(count);
      final Float32List offsets = Float32List(count * 2);
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
    final GlyphRun run = _shaper.shape(text, font);
    return Size(run.width, font.lineHeight);
  }
}
