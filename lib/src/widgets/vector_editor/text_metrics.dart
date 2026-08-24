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

import '../../graphics/vector/primitives.dart';
import '../../rendering/text/font_registry.dart';
import '../../rendering/text/text_painter.dart';
import '../../text/grapheme.dart';
import '../../text/typeface.dart';

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
  }

  /// Undoes [install], for a test that wants the metric-free approximation.
  static void uninstall() {
    _installed = false;
    VectorText.inkProvider = null;
  }

  /// The face [text] is drawn with, at *document* scale, or null when the
  /// registry has no font loaded.
  static ScaledTypeface? faceFor(VectorText text) {
    final descriptor = text.style.textStyle;
    final size = descriptor.fontSize;
    if (size <= 0) return null;
    return FontRegistry.instance
        .uiFont(size, weight: descriptor.bold ? 700 : 400);
  }

  /// The ink box of [text] in its own units, falling back to the model's
  /// approximation when no font is available.
  static VectorTextInk measure(VectorText text) {
    final face = faceFor(text);
    if (face == null) return VectorText.approximateInk(text);
    final width = text.textContent.isEmpty
        ? 0.0
        : _painter.measure(text.textContent, face).width;
    return VectorTextInk(
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
  static double caretX(VectorText text, int offset) {
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
}
