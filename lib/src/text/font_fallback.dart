/// The seam through which paragraph layout asks for a second face.
///
/// Layout lives in `text/` and the registry of installed faces lives in
/// `rendering/text/`, and the layering rule forbids the first from naming the
/// second (section 22.7: the font machinery must not know about renderers).
/// So layout depends on this interface and the registry implements it - the
/// same inversion [Shaper] already is.
library;

import 'typeface.dart';

/// Chooses a face for characters the run's own face cannot draw.
abstract interface class FontFallback {
  /// A face that draws [codePoint], to stand in for [primary], or null when
  /// nothing installed does.
  ///
  /// [emojiPresentation] is true when the cluster asked for the colour
  /// presentation - it carries `U+FE0F` - and then a colour emoji face is the
  /// answer **even when [primary] has a glyph**, because that glyph is the
  /// text presentation the selector asked to replace. When it is false the
  /// caller only asks about characters [primary] lacks.
  ///
  /// Called once per cluster that needs it, at layout time; an implementation
  /// is expected to cache, since a paragraph of Japanese asks the same
  /// question for every character.
  Typeface? fallbackFace(
    int codePoint,
    Typeface primary, {
    bool emojiPresentation = false,
  });
}
