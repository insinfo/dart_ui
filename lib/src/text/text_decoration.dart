/// The lines drawn with text rather than as text: underline, overline and
/// strike-through, and the stroke each is drawn with.
///
/// They live in `text` rather than next to the widget `TextStyle` because the
/// paragraph engine carries them per span: a decoration has to follow the
/// span it belongs to through bidi reordering, line breaking and the
/// ellipsis, and the only layer that knows where a span ended up is the one
/// that laid it out. The widget layer re-exports the same types, so there is
/// one spelling of "underline" in the framework, not one per layer.
///
/// The names and members are Flutter's (`dart:ui`), so code that decorates
/// text ports without edits.
library;

/// A set of lines to draw with a span of text.
///
/// A bit set rather than an enum because the lines combine: a link that is
/// also deleted is underlined *and* struck through, which is
/// `TextDecoration.combine([underline, lineThrough])`. Value equality, so a
/// combined decoration built twice compares equal - it is part of the
/// paragraph cache key.
final class TextDecoration {
  const TextDecoration._(this._mask);

  /// All of [decorations] at once.
  factory TextDecoration.combine(List<TextDecoration> decorations) {
    int mask = 0;
    for (final TextDecoration decoration in decorations) {
      mask |= decoration._mask;
    }
    return TextDecoration._(mask);
  }

  final int _mask;

  /// No line at all - the default, and the value that keeps a span on the
  /// cheap painting path.
  static const TextDecoration none = TextDecoration._(0x0);

  /// A line below the glyphs, where the face's `post` table puts it.
  static const TextDecoration underline = TextDecoration._(0x1);

  /// A line above the glyphs, at the face's ascent.
  static const TextDecoration overline = TextDecoration._(0x2);

  /// A line through the glyphs, at half the face's x-height.
  static const TextDecoration lineThrough = TextDecoration._(0x4);

  /// Whether every line in [other] is also in this one.
  bool contains(TextDecoration other) => (_mask | other._mask) == _mask;

  /// Whether this draws nothing.
  bool get isNone => _mask == 0;

  @override
  bool operator ==(Object other) =>
      other is TextDecoration && other._mask == _mask;

  @override
  int get hashCode => _mask.hashCode;

  @override
  String toString() {
    if (_mask == 0) return 'TextDecoration.none';
    final List<String> names = <String>[
      if (_mask & 0x1 != 0) 'underline',
      if (_mask & 0x2 != 0) 'overline',
      if (_mask & 0x4 != 0) 'lineThrough',
    ];
    return names.length == 1
        ? 'TextDecoration.${names.single}'
        : 'TextDecoration.combine([${names.join(', ')}])';
  }
}

/// The stroke a [TextDecoration] is drawn with.
///
/// Every member is drawn as itself. The broken styles are laid out from the
/// paragraph's left edge rather than from each span's, so an underline that
/// changes colour half way along a line keeps its rhythm instead of
/// restarting a dash at every span boundary.
enum TextDecorationStyle {
  /// One continuous line.
  solid,

  /// Two lines, one stroke-width apart.
  double,

  /// Square dots one stroke wide, one stroke apart.
  dotted,

  /// Dashes, longer than they are apart.
  dashed,

  /// A wave whose height is about twice the stroke, as a spell checker
  /// draws it.
  wavy,
}
