/// Rich text content: Flutter's `InlineSpan` tree, spelt the same way.
///
/// A span is a description, not a node: it holds text, a style and children,
/// and nothing about layout. `Text.rich` and `RichText` flatten the tree into
/// paragraph spans at layout time, merging each span's style over its
/// parent's - which is the whole reason the tree exists. A heading that sets
/// a size, with one child that sets only a colour, gets a child that is both
/// coloured and the heading's size, and the child never had to repeat it.
///
/// ## Names
///
/// `TextSpan` here is the widget-level span. The paragraph engine has a span
/// of its own - a run of text with an already-resolved face - which the
/// package exports as `ParagraphTextSpan`, as it exports the engine style as
/// `ParagraphTextStyle`. Ported Flutter code means this one.
///
/// ## Widgets in text
///
/// A [WidgetSpan] puts a widget in the line - an icon in a sentence, a
/// button at the end of a notice. It is a [PlaceholderSpan]: the paragraph
/// makes room for a box and draws nothing there, and `Text.rich` or
/// `RichText` lays the widget out first, tells the paragraph its size, and
/// paints it where the box landed. In the text it is one U+FFFC, as in
/// Flutter, which is what [toPlainText] gives for it.
library;

import '../gestures/recognizer.dart';
import '../layout/render_box.dart' show TextBaseline;
import '../text/paragraph.dart' show PlaceholderAlignment;
import 'theme.dart';
import 'widget.dart';

/// What to do with text that does not fit - Flutter's `TextOverflow`.
///
/// Used by `RichText`; `Text` spells the same choices as an `ellipsis`
/// string, which it predates.
enum TextOverflow {
  /// Cut at the box's edge.
  clip,

  /// Drawn as [clip]. A fade needs a gradient mask over the glyphs, which
  /// the display list cannot apply to text yet; cutting is the honest
  /// substitute, since a fade would have hidden the same pixels.
  fade,

  /// The last line ends in "…", cut where the width runs out. Without
  /// `maxLines` and without soft wrapping that is the one line there is.
  ellipsis,

  /// Not clipped at all: the text paints past its box.
  visible,
}

/// A node of rich text - Flutter's `InlineSpan`.
///
/// Sealed because the code that flattens a tree switches over the kinds -
/// [TextSpan] and [WidgetSpan] - and a kind added later has to be drawn by
/// that code; a sealed class makes the compiler point at the places that
/// need it.
sealed class InlineSpan {
  const InlineSpan({this.style});

  /// The style this span sets, merged over its parent's. Null changes
  /// nothing.
  final TextStyle? style;

  /// The text of this span and every descendant, in order.
  String toPlainText() {
    final StringBuffer buffer = StringBuffer();
    _writePlainText(buffer);
    return buffer.toString();
  }

  void _writePlainText(StringBuffer buffer);

  /// Calls [visitor] on this span and then on every descendant, depth
  /// first, until it returns false. Returns false when it was stopped.
  bool visitChildren(bool Function(InlineSpan span) visitor);
}

/// A span of text with a style, and possibly children - Flutter's `TextSpan`.
///
/// [text] comes first, then [children] in order. Either may be absent: a span
/// with only children is how a style is applied to several differently styled
/// pieces at once.
final class TextSpan extends InlineSpan {
  const TextSpan({
    this.text,
    this.children,
    super.style,
    this.recognizer,
  });

  final String? text;
  final List<InlineSpan>? children;

  /// Receives the pointer events that land on [text] - not on [children],
  /// as in Flutter: a child is its own span, with its own recognizer or none.
  ///
  /// Owned by the caller, again as in Flutter: the span neither creates nor
  /// disposes it, so a widget that makes one in `initState` disposes it in
  /// `dispose`. While the text is in the tree, the pointer over a span with a
  /// recognizer is a hand.
  final GestureRecognizer? recognizer;

  @override
  void _writePlainText(StringBuffer buffer) {
    final String? own = text;
    if (own != null) buffer.write(own);
    final List<InlineSpan>? kids = children;
    if (kids == null) return;
    for (final InlineSpan child in kids) {
      child._writePlainText(buffer);
    }
  }

  @override
  bool visitChildren(bool Function(InlineSpan span) visitor) {
    if (!visitor(this)) return false;
    final List<InlineSpan>? kids = children;
    if (kids == null) return true;
    for (final InlineSpan child in kids) {
      if (!child.visitChildren(visitor)) return false;
    }
    return true;
  }

  /// Value equality over the whole subtree, the recognizer by identity.
  ///
  /// What lets a rebuilt `Text.rich` with the same content skip relayout:
  /// the widget is rebuilt with a fresh tree of `const`-less spans on every
  /// frame its parent builds, and comparing by identity would re-lay it out
  /// every time.
  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! TextSpan ||
        other.text != text ||
        other.style != style ||
        !identical(other.recognizer, recognizer)) {
      return false;
    }
    final List<InlineSpan>? a = children;
    final List<InlineSpan>? b = other.children;
    if (a == null || b == null) return a == b;
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(
        text,
        style,
        recognizer == null ? null : identityHashCode(recognizer),
        children == null ? null : Object.hashAll(children!),
      );

  @override
  String toString() => 'TextSpan(${text == null ? '' : '"$text"'}'
      '${children == null ? '' : ', ${children!.length} children'})';
}

/// A span that stands for a box in the line rather than for text - Flutter's
/// `PlaceholderSpan`.
///
/// The paragraph reserves the box and draws nothing in it; what fills it is
/// the subclass's business. [WidgetSpan] is the one subclass, as in Flutter.
sealed class PlaceholderSpan extends InlineSpan {
  const PlaceholderSpan({
    this.alignment = PlaceholderAlignment.bottom,
    this.baseline,
    super.style,
  });

  /// The character a placeholder is in the text: U+FFFC, OBJECT REPLACEMENT
  /// CHARACTER, the code point Unicode reserves for an object embedded in
  /// text.
  static const int placeholderCodeUnit = 0xFFFC;

  /// How the box sits on its line; see [PlaceholderAlignment].
  final PlaceholderAlignment alignment;

  /// Which of the box's baselines [PlaceholderAlignment.baseline] lines up
  /// with the text's.
  ///
  /// Flutter requires it for that alignment and asserts; here null means
  /// [TextBaseline.alphabetic], the baseline every Latin label already
  /// reports, because a missing argument with one sensible answer is not
  /// worth an exception. The other alignments do not read it.
  final TextBaseline? baseline;

  @override
  void _writePlainText(StringBuffer buffer) =>
      buffer.writeCharCode(placeholderCodeUnit);

  @override
  bool visitChildren(bool Function(InlineSpan span) visitor) => visitor(this);
}

/// A widget inside rich text - Flutter's `WidgetSpan`.
///
/// ```dart
/// Text.rich(TextSpan(children: <InlineSpan>[
///   TextSpan(text: 'Press '),
///   WidgetSpan(child: Icon(FluentIcons.save)),
///   TextSpan(text: ' to save.'),
/// ]))
/// ```
///
/// The [child] is laid out first, with the text's maximum width and no
/// limit on its height, and the line then makes room for whatever size it
/// chose: a box that does not fit on the line wraps to the next one whole,
/// and a tall one makes its line taller, by [alignment]. It is painted over
/// the text, receives pointer events like any other widget - a button in a
/// sentence is pressed by clicking it - and keeps its place in the
/// semantics tree.
///
/// [style] does not style the child: a `Text` inside takes the ambient
/// [DefaultTextStyle], as in Flutter. It is merged into the inherited style
/// to find the face whose ascent and descent the
/// [PlaceholderAlignment.top], [PlaceholderAlignment.bottom] and
/// [PlaceholderAlignment.middle] alignments measure against.
final class WidgetSpan extends PlaceholderSpan {
  const WidgetSpan({
    required this.child,
    super.alignment,
    super.baseline,
    super.style,
  });

  /// The widget in the line.
  final Widget child;

  /// The widgets of every [WidgetSpan] in [span]'s tree, in text order -
  /// the order `Text.rich` and `RichText` keep their children in, and the
  /// order of the paragraph's placeholder boxes.
  static List<Widget> extractFromInlineSpan(InlineSpan span) {
    List<Widget>? found;
    span.visitChildren((InlineSpan node) {
      if (node is WidgetSpan) (found ??= <Widget>[]).add(node.child);
      return true;
    });
    return found ?? const <Widget>[];
  }

  /// The child by identity, as Flutter compares it: a rebuilt `Text.rich`
  /// with a fresh child widget is a different paragraph, laid out again
  /// from the paragraph cache.
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is WidgetSpan &&
          identical(other.child, child) &&
          other.alignment == alignment &&
          other.baseline == baseline &&
          other.style == style;

  @override
  int get hashCode =>
      Object.hash(identityHashCode(child), alignment, baseline, style);

  @override
  String toString() => 'WidgetSpan(${child.runtimeType}, ${alignment.name})';
}
