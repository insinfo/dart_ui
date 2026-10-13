library;

import '../geometry/offset.dart';
import '../geometry/rect.dart';
import '../geometry/size.dart';
import '../gestures/recognizer.dart';
import '../graphics/color.dart';
import '../graphics/display_list.dart';
import '../graphics/display_list_geometry.dart';
import '../layout/alignment.dart';
import '../layout/box_constraints.dart';
import '../layout/edge_insets.dart';
import '../layout/render_align.dart' as layout;
import '../layout/render_aspect_ratio.dart' as layout;
import '../layout/render_box.dart';
import '../layout/render_colored_box.dart' as layout;
import '../layout/render_constrained_box.dart' as layout;
import '../layout/render_flex.dart' as layout;
import '../layout/render_grid.dart' as layout;
import '../layout/render_padding.dart' as layout;
import '../layout/render_stack.dart' as layout;
import '../layout/render_wrap.dart' as layout;
import '../platform/input_events.dart';
import '../platform/native_window.dart' show SystemCursor;
import '../rendering/text/font_registry.dart';
import '../text/paragraph.dart' as paragraph;
import '../text/shaper.dart';
import '../text/text_decoration.dart';
import '../text/typeface.dart';
import 'directionality.dart';
import 'element.dart';
import 'pointer_router.dart';
import 'text_span.dart';
import 'theme.dart';
import 'widget.dart';

/// Positions a smaller child within the space offered by its parent.
final class Align extends SingleChildRenderObjectWidget {
  const Align({
    super.key,
    this.alignment = Alignment.center,
    this.widthFactor,
    this.heightFactor,
    super.child,
  });

  final Alignment alignment;
  final double? widthFactor;
  final double? heightFactor;

  @override
  layout.RenderAlign createRenderObject(BuildContext context) =>
      layout.RenderAlign(
        alignment: alignment,
        widthFactor: widthFactor,
        heightFactor: heightFactor,
      );

  @override
  void updateRenderObject(
    BuildContext context,
    covariant layout.RenderAlign renderObject,
  ) {
    renderObject
      ..alignment = alignment
      ..widthFactor = widthFactor
      ..heightFactor = heightFactor;
  }
}

/// A single-child widget backed by the production layout/render tree.
final class ColoredBox extends SingleChildRenderObjectWidget {
  const ColoredBox({
    super.key,
    required this.color,
    super.child,
  });

  final Color color;

  @override
  layout.RenderColoredBox createRenderObject(BuildContext context) =>
      layout.RenderColoredBox(color: color);

  @override
  void updateRenderObject(
    BuildContext context,
    covariant layout.RenderColoredBox renderObject,
  ) {
    renderObject.color = color;
  }
}

/// Insets one child using the production layout implementation.
final class Padding extends SingleChildRenderObjectWidget {
  const Padding({
    super.key,
    required this.padding,
    super.child,
  });

  final EdgeInsets padding;

  @override
  layout.RenderPadding createRenderObject(BuildContext context) =>
      layout.RenderPadding(padding: padding);

  @override
  void updateRenderObject(
    BuildContext context,
    covariant layout.RenderPadding renderObject,
  ) {
    renderObject.padding = padding;
  }
}

/// Lays children out along an axis, the widget face of [layout.RenderFlex].
final class Flex extends MultiChildRenderObjectWidget {
  const Flex({
    super.key,
    required this.direction,
    this.mainAxisAlignment = layout.MainAxisAlignment.start,
    this.crossAxisAlignment = layout.CrossAxisAlignment.start,
    this.mainAxisSize = layout.MainAxisSize.max,
    super.children,
  });

  final layout.Axis direction;
  final layout.MainAxisAlignment mainAxisAlignment;
  final layout.CrossAxisAlignment crossAxisAlignment;
  final layout.MainAxisSize mainAxisSize;

  /// `maybeOf` rather than `of`, and the choice is not laziness.
  ///
  /// [Directionality.of] throws when nothing installed a direction, on the
  /// argument that a silent left-to-right default is invisible to whoever
  /// forgot it - they are almost certainly working in a left-to-right locale,
  /// so it looks right on their machine and wrong only for people who cannot
  /// report it in their language. That argument is about *deciding* a locale.
  ///
  /// A `Row` does not decide one. It forwards whatever the tree says to
  /// [layout.RenderFlex.textDirection], which is nullable and documents null as
  /// laying out left-to-right - the render layer's declared policy, because a
  /// render object is assembled by tests and tools that have no locale to
  /// offer. Passing `maybeOf` through honours that policy instead of inventing
  /// a second one here; an application that wants the loud version installs a
  /// [Directionality] and any descendant that genuinely needs a decision -
  /// an icon that asked to mirror, a directional inset - calls `of` and gets
  /// the named failure.
  TextDirection? _directionOf(BuildContext context) =>
      Directionality.maybeOf(context);

  @override
  layout.RenderFlex createRenderObject(BuildContext context) =>
      layout.RenderFlex(
        direction: direction,
        mainAxisAlignment: mainAxisAlignment,
        crossAxisAlignment: crossAxisAlignment,
        mainAxisSize: mainAxisSize,
        textDirection: _directionOf(context),
      );

  @override
  void updateRenderObject(
    BuildContext context,
    covariant layout.RenderFlex renderObject,
  ) {
    renderObject
      ..direction = direction
      ..mainAxisAlignment = mainAxisAlignment
      ..crossAxisAlignment = crossAxisAlignment
      ..mainAxisSize = mainAxisSize
      ..textDirection = _directionOf(context);
  }
}

/// A vertical [Flex].
final class Column extends Flex {
  const Column({
    super.key,
    super.mainAxisAlignment,
    super.crossAxisAlignment,
    super.mainAxisSize,
    super.children,
  }) : super(direction: layout.Axis.vertical);
}

/// A horizontal [Flex].
final class Row extends Flex {
  const Row({
    super.key,
    super.mainAxisAlignment,
    super.crossAxisAlignment,
    super.mainAxisSize,
    super.children,
  }) : super(direction: layout.Axis.horizontal);
}

/// Gives one child of a [Flex] a share of the space the inflexible children
/// left over.
///
/// The share is proportional: two children with [flex] 1 and 3 split the
/// remainder one quarter to three quarters, and a child that is not wrapped in
/// one of these keeps its natural size and is measured first.
///
/// [fit] is the difference between this and [Expanded], and it is the whole
/// difference. [layout.FlexFit.loose] - the default here - makes the share an
/// upper bound: the child may be smaller, and the leftover stays empty. That is
/// what a label that should not be stretched wants. [layout.FlexFit.tight] -
/// what [Expanded] passes - makes the share exact, which is what a text field
/// filling a toolbar wants.
class Flexible extends ParentDataWidget<layout.FlexParentData> {
  const Flexible({
    super.key,
    this.flex = 1,
    this.fit = layout.FlexFit.loose,
    required super.child,
  }) : assert(flex >= 0, 'a flex factor is a share, and cannot be negative');

  /// This child's weight in the division of the leftover space. Zero opts out
  /// and is the same as not wrapping the child at all.
  final int flex;

  final layout.FlexFit fit;

  @override
  Type get typicalAncestorWidget => Flex;

  @override
  bool applyParentData(layout.FlexParentData parentData) {
    if (parentData.flex == flex && parentData.fit == fit) return false;
    parentData
      ..flex = flex
      ..fit = fit;
    return true;
  }
}

/// A [Flexible] that must fill its share exactly.
///
/// `Row(children: [Expanded(child: field), sendButton])` is the reason this
/// layer exists: the button keeps its natural width, the field takes the whole
/// rest of the row, and neither of them had to be told how wide the window is.
final class Expanded extends Flexible {
  const Expanded({super.key, super.flex, required super.child})
      : super(fit: layout.FlexFit.tight);
}

/// Empty, flexible space in a [Flex].
///
/// The declarative spelling of "push everything after this to the far end". It
/// is an [Expanded] around nothing, which is why it takes part in the same
/// proportional division: two spacers with the default [flex] split the gap
/// evenly, and `Spacer(flex: 2)` takes twice as much as its neighbour.
///
/// Not the same thing as `MainAxisAlignment.spaceBetween`: that distributes the
/// free space by a rule the whole row shares, while a spacer puts a specific
/// amount of it in a specific place - which is what a toolbar with a left
/// group, a centred title and a right group actually needs.
final class Spacer extends StatelessWidget {
  const Spacer({super.key, this.flex = 1})
      : assert(flex >= 0, 'a flex factor is a share, and cannot be negative');

  final int flex;

  @override
  Widget build(BuildContext context) => Expanded(
        flex: flex,
        // Zero on both axes, then widened by the tight share the flex hands
        // down: RenderConstrainedBox lets the parent win, so a spacer occupies
        // its share of the main axis and no cross extent of its own.
        child: const SizedBox(width: 0, height: 0),
      );
}

/// Lays children out in a line that breaks when it runs out of room.
final class Wrap extends MultiChildRenderObjectWidget {
  const Wrap({
    super.key,
    this.direction = layout.Axis.horizontal,
    this.spacing = 0.0,
    this.runSpacing = 0.0,
    this.alignment = layout.MainAxisAlignment.start,
    this.runAlignment = layout.MainAxisAlignment.start,
    this.crossAxisAlignment = layout.WrapCrossAlignment.start,
    super.children,
  });

  final layout.Axis direction;
  final double spacing;
  final double runSpacing;
  final layout.MainAxisAlignment alignment;
  final layout.MainAxisAlignment runAlignment;
  final layout.WrapCrossAlignment crossAxisAlignment;

  @override
  layout.RenderWrap createRenderObject(BuildContext context) =>
      layout.RenderWrap(
        direction: direction,
        spacing: spacing,
        runSpacing: runSpacing,
        alignment: alignment,
        runAlignment: runAlignment,
        crossAxisAlignment: crossAxisAlignment,
      );

  @override
  void updateRenderObject(
    BuildContext context,
    covariant layout.RenderWrap renderObject,
  ) {
    renderObject
      ..direction = direction
      ..spacing = spacing
      ..runSpacing = runSpacing
      ..alignment = alignment
      ..runAlignment = runAlignment
      ..crossAxisAlignment = crossAxisAlignment;
  }
}

/// Forces its child into a box of a fixed width-to-height ratio.
final class AspectRatio extends SingleChildRenderObjectWidget {
  const AspectRatio({super.key, required this.aspectRatio, super.child});

  /// Width divided by height.
  final double aspectRatio;

  @override
  layout.RenderAspectRatio createRenderObject(BuildContext context) =>
      layout.RenderAspectRatio(aspectRatio: aspectRatio);

  @override
  void updateRenderObject(
    BuildContext context,
    covariant layout.RenderAspectRatio renderObject,
  ) {
    renderObject.aspectRatio = aspectRatio;
  }
}

/// Arranges children into rows and columns of sized tracks.
///
/// Children are auto-placed in order, one per cell, row-major. Explicit
/// placement and spans exist on the render node ([layout.RenderGrid.place]) but
/// have no widget-layer spelling yet. The machinery they need now exists -
/// [ParentDataWidget], the same one [Expanded] and [Positioned] are built on -
/// so the remaining work is a `GridPlacement` widget over whatever per-child
/// record `RenderGrid` installs, not another layer.
final class Grid extends MultiChildRenderObjectWidget {
  const Grid({
    super.key,
    required this.columns,
    this.rows = const <layout.GridTrack>[],
    this.columnGap = 0.0,
    this.rowGap = 0.0,
    this.fit = layout.GridFit.stretch,
    this.alignment = Alignment.center,
    super.children,
  });

  final List<layout.GridTrack> columns;
  final List<layout.GridTrack> rows;
  final double columnGap;
  final double rowGap;
  final layout.GridFit fit;
  final Alignment alignment;

  @override
  layout.RenderGrid createRenderObject(BuildContext context) =>
      layout.RenderGrid(
        columns: columns,
        rows: rows,
        columnGap: columnGap,
        rowGap: rowGap,
        fit: fit,
        alignment: alignment,
      );

  @override
  void updateRenderObject(
    BuildContext context,
    covariant layout.RenderGrid renderObject,
  ) {
    renderObject
      ..columns = columns
      ..rows = rows
      ..columnGap = columnGap
      ..rowGap = rowGap
      ..fit = fit
      ..alignment = alignment;
  }
}

/// Overlays children, last on top.
final class Stack extends MultiChildRenderObjectWidget {
  const Stack({
    super.key,
    this.alignment = Alignment.topLeft,
    this.fit = layout.StackFit.loose,
    super.children,
  });

  final Alignment alignment;
  final layout.StackFit fit;

  @override
  layout.RenderStack createRenderObject(BuildContext context) =>
      layout.RenderStack(alignment: alignment, fit: fit);

  @override
  void updateRenderObject(
    BuildContext context,
    covariant layout.RenderStack renderObject,
  ) {
    renderObject
      ..alignment = alignment
      ..fit = fit;
  }
}

/// Pins one child of a [Stack] to its edges.
///
/// Any edge or extent given makes the child *positioned*, which takes it out of
/// the stack's own sizing: a child pinned 20px from the right cannot also be
/// what decides where the right edge is. Children with none of these set are
/// sized normally and placed by the stack's alignment.
///
/// Giving both edges on an axis stretches the child between them, which is the
/// one thing [Align] and [SizedBox] together cannot express: `left: 8,
/// right: 8` is "as wide as the stack minus sixteen", at any stack width, with
/// no arithmetic in the caller.
final class Positioned extends ParentDataWidget<layout.StackParentData> {
  const Positioned({
    super.key,
    this.left,
    this.top,
    this.right,
    this.bottom,
    this.width,
    this.height,
    required super.child,
  });

  /// Pins all four edges, so the child is exactly the stack's box, inset.
  const Positioned.fill({
    super.key,
    this.left = 0,
    this.top = 0,
    this.right = 0,
    this.bottom = 0,
    required super.child,
  })  : width = null,
        height = null;

  final double? left;
  final double? top;
  final double? right;
  final double? bottom;
  final double? width;
  final double? height;

  @override
  Type get typicalAncestorWidget => Stack;

  @override
  bool applyParentData(layout.StackParentData parentData) {
    if (parentData.left == left &&
        parentData.top == top &&
        parentData.right == right &&
        parentData.bottom == bottom &&
        parentData.width == width &&
        parentData.height == height) {
      return false;
    }
    parentData
      ..left = left
      ..top = top
      ..right = right
      ..bottom = bottom
      ..width = width
      ..height = height;
    return true;
  }
}

/// Forces a size on its child, or occupies one on its own.
final class SizedBox extends SingleChildRenderObjectWidget {
  const SizedBox({super.key, this.width, this.height, super.child});

  const SizedBox.square({Key? key, required double extent, Widget? child})
      : this(key: key, width: extent, height: extent, child: child);

  final double? width;
  final double? height;

  @override
  layout.RenderConstrainedBox createRenderObject(BuildContext context) =>
      layout.RenderConstrainedBox(additionalConstraints: _constraints);

  @override
  void updateRenderObject(
    BuildContext context,
    covariant layout.RenderConstrainedBox renderObject,
  ) {
    renderObject.additionalConstraints = _constraints;
  }

  BoxConstraints get _constraints => BoxConstraints(
        minWidth: width ?? 0,
        maxWidth: width ?? double.infinity,
        minHeight: height ?? 0,
        maxHeight: height ?? double.infinity,
      );
}

/// Supplies a default style to descendant [Text] widgets.
///
/// This mirrors the useful core of Flutter's API and lets compound controls
/// colour arbitrary text children without reaching into those children.
final class DefaultTextStyle extends InheritedWidget {
  const DefaultTextStyle({
    super.key,
    required this.style,
    required super.child,
  });

  final TextStyle style;

  static TextStyle of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<DefaultTextStyle>()?.style ??
      const TextStyle();

  static TextStyle? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<DefaultTextStyle>()?.style;

  @override
  bool updateShouldNotify(DefaultTextStyle oldWidget) =>
      !identical(style, oldWidget.style);
}

/// Text configuration. Shaping and glyph painting remain a renderer concern.
///
/// Two spellings, as in Flutter: `Text('plain')` and `Text.rich(span)`. Both
/// resolve [style] over the ambient [DefaultTextStyle] - or the theme's
/// `bodyMedium` when there is none - and a rich text then merges each span's
/// style over that, down the span tree, so a span that names only a colour
/// keeps the ambient size, face and weight.
///
/// A plain `Text` whose style sets only colour, size, family, weight and
/// slant stays on the single shaped run every control label uses. Letter or
/// word spacing, a background or a decoration moves it to the paragraph
/// engine, which carries them per span; `Text.rich` always uses it.
final class Text extends RenderObjectWidget {
  const Text(
    String this._data, {
    super.key,
    this.style,
    this.fontSize,
    this.color,
    this.softWrap = false,
    this.maxLines,
    this.ellipsis,
    this.textAlign = paragraph.TextAlign.start,
    this.breakWords = false,
  })  : textSpan = null,
        assert(maxLines == null || maxLines > 0),
        assert(ellipsis == null || maxLines != null);

  /// Rich text: [textSpan]'s tree, its styles inheriting from [style] and
  /// the ambient text style.
  ///
  /// Soft wrapping is off by default, as for the plain constructor - a
  /// `Text` here is a label first. Turn it on for prose, or use [RichText],
  /// which wraps by default as Flutter's does.
  const Text.rich(
    InlineSpan this.textSpan, {
    super.key,
    this.style,
    this.fontSize,
    this.color,
    this.softWrap = false,
    this.maxLines,
    this.ellipsis,
    this.textAlign = paragraph.TextAlign.start,
    this.breakWords = false,
  })  : _data = null,
        assert(maxLines == null || maxLines > 0),
        assert(ellipsis == null || maxLines != null);

  final String? _data;

  /// The string of a plain `Text`, or null for [Text.rich] - Flutter's name.
  String? get data => _data;

  /// The rich content, or null for a plain `Text`.
  final InlineSpan? textSpan;

  /// What is drawn, as plain text: the string, or the spans' text joined.
  String get text => _data ?? textSpan!.toPlainText();

  /// Flutter-compatible style surface. Explicit legacy fields below win.
  final TextStyle? style;

  /// The pixel size to draw at, or null to take the ambient theme's.
  final double? fontSize;

  /// Overrides [style] and the ambient text style.
  final Color? color;

  /// Uses the paragraph engine to break text at the available width.
  ///
  /// False preserves the compact single-line label used by controls. Enable
  /// it for descriptions, status messages and other prose in responsive UI.
  final bool softWrap;

  /// Maximum number of wrapped lines, or null for all lines.
  final int? maxLines;

  /// Text placed at the end when [maxLines] removes content - or, on a
  /// single line that does not fit its box, where the cut is.
  final String? ellipsis;

  /// How the lines sit across the text's width - centred under an icon,
  /// say. Matters once there are lines of different lengths.
  final paragraph.TextAlign textAlign;

  /// Whether a word too wide for the line is cut between characters - a
  /// file name with no space in it, under an icon.
  final bool breakWords;

  @override
  RenderObjectElement createElement() => RenderObjectElement(this);

  @override
  RenderText createRenderObject(BuildContext context) {
    final TextStyle resolved = _styleFrom(context);
    return RenderText(
      text,
      span: textSpan,
      fontSize: resolved.fontSize ?? kDefaultUiFontSize,
      color: resolved.color ?? const Color(0xFF111111),
      fontFamily: resolved.fontFamily,
      fontWeight: resolved.fontWeight?.value ?? 400,
      fontStyle: resolved.fontStyle ?? FontStyle.normal,
      lineHeight: resolved.height,
      letterSpacing: resolved.letterSpacing ?? 0,
      wordSpacing: resolved.wordSpacing ?? 0,
      backgroundColor: resolved.backgroundColor,
      decoration: resolved.decoration ?? TextDecoration.none,
      decorationColor: resolved.decorationColor,
      decorationStyle: resolved.decorationStyle ?? TextDecorationStyle.solid,
      decorationThickness: resolved.decorationThickness ?? 1.0,
      softWrap: softWrap,
      maxLines: maxLines,
      ellipsis: ellipsis,
      textAlign: textAlign,
      breakWords: breakWords,
    );
  }

  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderText renderObject,
  ) {
    final TextStyle resolved = _styleFrom(context);
    renderObject
      ..span = textSpan
      ..text = text
      ..fontSize = resolved.fontSize ?? kDefaultUiFontSize
      ..color = resolved.color ?? const Color(0xFF111111)
      ..fontFamily = resolved.fontFamily
      ..fontWeight = resolved.fontWeight?.value ?? 400
      ..fontStyle = resolved.fontStyle ?? FontStyle.normal
      ..lineHeight = resolved.height
      ..letterSpacing = resolved.letterSpacing ?? 0
      ..wordSpacing = resolved.wordSpacing ?? 0
      ..backgroundColor = resolved.backgroundColor
      ..decoration = resolved.decoration ?? TextDecoration.none
      ..decorationColor = resolved.decorationColor
      ..decorationStyle = resolved.decorationStyle ?? TextDecorationStyle.solid
      ..decorationThickness = resolved.decorationThickness ?? 1.0
      ..softWrap = softWrap
      ..maxLines = maxLines
      ..ellipsis = ellipsis
      ..textAlign = textAlign
      ..breakWords = breakWords;
  }

  /// Resolves and subscribes to the ambient styles. Render-object elements
  /// push inherited changes through `updateRenderObject`, which is essential
  /// for const labels retained across a light/dark theme switch.
  TextStyle _styleFrom(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final TextStyle ambient =
        DefaultTextStyle.maybeOf(context) ?? theme.textTheme.bodyMedium;
    final TextStyle merged = ambient.merge(style);
    return merged.copyWith(
      color: color ?? merged.color ?? theme.foreground,
      fontSize: fontSize ?? merged.fontSize ?? theme.fontSize,
    );
  }
}

/// Rich text with no ambient style - Flutter's `RichText`.
///
/// Draws [text] exactly as its spans describe it: nothing is inherited from
/// [DefaultTextStyle] or the theme, so a span tree that names no size gets
/// the framework's default size and near-black, as Flutter's `RichText` gets
/// its engine defaults. That is the point of the widget - text whose look
/// must not depend on where it is placed. [Text.rich] is the one that
/// inherits, and is usually what an application wants.
///
/// Unlike [Text], it wraps by default ([softWrap] true), as in Flutter.
final class RichText extends RenderObjectWidget {
  const RichText({
    super.key,
    required this.text,
    this.textAlign = paragraph.TextAlign.start,
    this.softWrap = true,
    this.overflow = TextOverflow.clip,
    this.maxLines,
  }) : assert(maxLines == null || maxLines > 0);

  final InlineSpan text;
  final paragraph.TextAlign textAlign;

  /// Whether lines break at the box's width. False breaks only at newlines.
  final bool softWrap;

  /// What happens to text that does not fit; see [TextOverflow].
  final TextOverflow overflow;

  /// The most lines to show, or null for all of them.
  final int? maxLines;

  /// The line limit the engine is given. An ellipsis with no limit on text
  /// that does not wrap means "cut this one line", as in Flutter, and the
  /// engine places an ellipsis only on a limited paragraph.
  int? get _effectiveMaxLines =>
      maxLines ?? (overflow == TextOverflow.ellipsis && !softWrap ? 1 : null);

  String? get _ellipsis =>
      overflow == TextOverflow.ellipsis && _effectiveMaxLines != null
          ? '\u2026'
          : null;

  @override
  RenderObjectElement createElement() => RenderObjectElement(this);

  @override
  RenderText createRenderObject(BuildContext context) => RenderText(
        text.toPlainText(),
        span: text,
        softWrap: softWrap,
        maxLines: _effectiveMaxLines,
        ellipsis: _ellipsis,
        textAlign: textAlign,
        clipsOverflow: overflow != TextOverflow.visible,
      );

  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderText renderObject,
  ) {
    renderObject
      ..span = text
      ..text = text.toPlainText()
      ..softWrap = softWrap
      ..maxLines = _effectiveMaxLines
      ..ellipsis = _ellipsis
      ..textAlign = textAlign
      ..clipsOverflow = overflow != TextOverflow.visible;
  }
}

/// A text leaf with an inexpensive single-line path and opt-in paragraph
/// wrapping.
///
/// Compact labels keep using the shaped-run path. Prose with [softWrap]
/// enabled uses the same paragraph engine as rich document text. Both paths
/// guarantee that layout and paint use the same shaping result, so a label
/// cannot measure at one width and paint at another.
///
/// ## Rich text
///
/// With a [span], the text is the span tree flattened into paragraph spans:
/// each leaf's style is its ancestors' styles merged in order, and every
/// field a leaf leaves unset falls back to this node's own - [fontSize],
/// [fontFamily], [letterSpacing], [decoration] and the rest - which is where
/// `Text.rich` puts the ambient style. A leaf's colour is the one exception:
/// unset, it stays unset, and the glyphs are drawn in [color] at paint time,
/// so changing [color] repaints without laying out again.
///
/// A leaf whose span has a recognizer makes the text hit-testable over that
/// leaf's glyphs - and only there, so a click on plain text still reaches
/// whatever is behind it - and hands the press to the recognizer.
final class RenderText extends RenderBox
    implements PointerEventTarget, MouseCursorTarget {
  RenderText(
    String text, {
    InlineSpan? span,
    Color color = const Color(0xFF111111),
    double fontSize = kDefaultUiFontSize,
    String? fontFamily,
    int fontWeight = 400,
    FontStyle fontStyle = FontStyle.normal,
    double? lineHeight,
    double letterSpacing = 0,
    double wordSpacing = 0,
    Color? backgroundColor,
    TextDecoration decoration = TextDecoration.none,
    Color? decorationColor,
    TextDecorationStyle decorationStyle = TextDecorationStyle.solid,
    double decorationThickness = 1.0,
    bool softWrap = false,
    int? maxLines,
    String? ellipsis,
    paragraph.TextAlign textAlign = paragraph.TextAlign.start,
    bool breakWords = false,
    bool clipsOverflow = true,
  })  : _text = text,
        _span = span,
        _color = color,
        _fontSize = fontSize,
        _fontFamily = fontFamily,
        _fontWeight = fontWeight,
        _fontStyle = fontStyle,
        _lineHeight = lineHeight,
        _letterSpacing = letterSpacing,
        _wordSpacing = wordSpacing,
        _backgroundColor = backgroundColor,
        _decoration = decoration,
        _decorationColor = decorationColor,
        _decorationStyle = decorationStyle,
        _decorationThickness = decorationThickness,
        _softWrap = softWrap,
        _maxLines = maxLines,
        _ellipsis = ellipsis,
        _textAlign = textAlign,
        _breakWords = breakWords,
        _clipsOverflow = clipsOverflow;

  String _text;
  InlineSpan? _span;
  Color _color;
  double _fontSize;
  String? _fontFamily;
  int _fontWeight;
  FontStyle _fontStyle;
  double? _lineHeight;
  double _letterSpacing;
  double _wordSpacing;
  Color? _backgroundColor;
  TextDecoration _decoration;
  Color? _decorationColor;
  TextDecorationStyle _decorationStyle;
  double _decorationThickness;
  bool _softWrap;
  int? _maxLines;
  String? _ellipsis;
  paragraph.TextAlign _textAlign;
  paragraph.Paragraph? _paragraph;

  /// The paragraph the text was laid out into, or null on the single-run
  /// path - a plain label with nothing the paragraph engine is needed for.
  ///
  /// For a caller that wants the geometry the text was drawn with: caret
  /// rectangles, selection boxes, the line count, whether `maxLines` cut
  /// anything. Valid until the next layout.
  paragraph.Paragraph? get laidOutParagraph => _paragraph;

  bool _breakWords;
  bool _clipsOverflow;

  /// Forgets everything derived from the text or its style - the laid-out
  /// paragraph and the flattened spans - and asks for layout.
  void _textChanged() {
    _paragraph = null;
    _spans = null;
    // Links are rebuilt with the spans; plain text has none to rebuild.
    if (_span == null) _links = const [];
    markNeedsLayout();
  }

  bool get breakWords => _breakWords;

  set breakWords(bool value) {
    if (value == _breakWords) return;
    _breakWords = value;
    _textChanged();
  }

  paragraph.TextAlign get textAlign => _textAlign;

  set textAlign(paragraph.TextAlign value) {
    if (value == _textAlign) return;
    _textAlign = value;
    _textChanged();
  }

  /// Whether text past the box's edge is cut. False only for
  /// [TextOverflow.visible].
  bool get clipsOverflow => _clipsOverflow;

  set clipsOverflow(bool value) {
    if (value == _clipsOverflow) return;
    _clipsOverflow = value;
    markNeedsPaint();
  }

  /// The text as a plain string. With a [span], the span tree's text - set
  /// both, the span first; the widgets do.
  String get text => _text;

  set text(String value) {
    if (value == _text) return;
    _text = value;
    _hasHardBreak = _containsHardBreak(value);
    _textChanged();
  }

  /// The rich content, or null for plain [text].
  InlineSpan? get span => _span;

  set span(InlineSpan? value) {
    if (value == _span) return;
    _span = value;
    _textChanged();
  }

  /// Whether the text contains a newline or another mandatory break.
  ///
  /// A label with one goes through the paragraph engine even without
  /// [softWrap], because the single-line path shapes every character it is
  /// given and a newline shaped through `cmap` comes out as a `.notdef` box -
  /// which is what `'one\ntwo'` drew until 12/10/2026. [softWrap] decides only
  /// whether lines also break at the width, as in Flutter, where a `\n`
  /// always breaks.
  late bool _hasHardBreak = _containsHardBreak(_text);

  static bool _containsHardBreak(String text) {
    for (var i = 0; i < text.length; i++) {
      if (paragraph.isMandatoryLineBreak(text.codeUnitAt(i))) return true;
    }
    return false;
  }

  /// The paragraph engine wraps, aligns lines and cuts with an ellipsis;
  /// the single-line path only shapes. An [_ellipsis] therefore takes the
  /// paragraph path too: a label that does not fit its box ends in "…"
  /// instead of being cut through a letter.
  ///
  /// So does text with a character the face cannot draw, or an emoji asked
  /// for with `U+FE0F`: a shaped run is one face, and only a paragraph falls
  /// back to a second - the platform's emoji face for "Hello 😀", which the
  /// single-line path drew as a `.notdef` box until 13/10/2026.
  ///
  /// And so does rich text, or a style the single run cannot draw - see
  /// [_needsSpans].
  bool get _usesParagraph =>
      _softWrap ||
      _hasHardBreak ||
      _ellipsis != null ||
      _alignsAcross ||
      _needsSpans ||
      _fallsBack;

  /// Whether the text is laid out from styled paragraph spans rather than
  /// from the string and one face: a [span] tree, or spacing, a background or
  /// a decoration, which the paragraph carries per span and the single
  /// shaped run has nowhere to put. Weight and slant are not in the list -
  /// they are a choice of face, and a single run has a face - unless italic
  /// was asked of a family with no italic, which is drawn sheared, and only
  /// the paragraph painter shears.
  bool get _needsSpans =>
      _span != null ||
      _letterSpacing != 0 ||
      _wordSpacing != 0 ||
      _backgroundColor != null ||
      !_decoration.isNone ||
      // Asked last, and only of an italic: [font] is a registry lookup.
      (_fontStyle == FontStyle.italic && _shears(font, true));

  /// Whether italic was asked for and [face] cannot provide it, so the
  /// painter has to shear the upright.
  static bool _shears(ScaledTypeface? face, bool italic) =>
      italic &&
      face != null &&
      !face.typeface.isItalic &&
      !face.typeface.isOblique;

  /// Whether the text needs a face other than [font] somewhere, remembered
  /// per text and face so layout, paint and the intrinsics ask the `cmap`
  /// once rather than once each.
  bool get _fallsBack {
    final ScaledTypeface? face = font;
    if (face == null) return false;
    if (_fallbackText != _text || _fallbackFace != face) {
      _fallbackText = _text;
      _fallbackFace = face;
      _fallbackNeeded = uiTextPainter.needsFallback(_text, face);
    }
    return _fallbackNeeded;
  }

  String? _fallbackText;
  ScaledTypeface? _fallbackFace;
  bool _fallbackNeeded = false;

  /// The paragraph's line-height multiplier: [lineHeight], unless the label
  /// is only in the paragraph engine for [_fallsBack] or for its style.
  ///
  /// A single line has no leading - see [lineHeight] - and a label must not
  /// grow by its multiplier the moment someone types an emoji into it, or
  /// underlines it, so a line that would have taken the single-line path
  /// keeps its height.
  double get _heightMultiplier {
    final bool singleLine =
        !_softWrap && !_hasHardBreak && _ellipsis == null && !_alignsAcross;
    return singleLine ? 1.0 : (_lineHeight ?? 1.0);
  }

  /// The width paragraph layout may use: the constraint when soft wrapping,
  /// otherwise none, so that only mandatory breaks end a line.
  /// The width lines break at: the box's when the text wraps, or when it
  /// is cut with an ellipsis - which needs a width to cut at.
  double _layoutWidth(double available) =>
      (_softWrap || _ellipsis != null || _alignsAcross) && available.isFinite
          ? available
          : double.infinity;

  /// Whether the lines are placed across the width - centred, or against
  /// the far edge - rather than from the start, which needs the width.
  bool get _alignsAcross =>
      _textAlign != paragraph.TextAlign.start &&
      _textAlign != paragraph.TextAlign.left;

  Color get color => _color;

  set color(Color value) {
    if (value == _color) return;
    _color = value;
    markNeedsPaint();
  }

  double get fontSize => _fontSize;

  set fontSize(double value) {
    if (value == _fontSize) return;
    _fontSize = value;
    _textChanged();
  }

  String? get fontFamily => _fontFamily;

  set fontFamily(String? value) {
    if (value == _fontFamily) return;
    _fontFamily = value;
    _textChanged();
  }

  int get fontWeight => _fontWeight;

  set fontWeight(int value) {
    if (value == _fontWeight) return;
    _fontWeight = value;
    _textChanged();
  }

  /// Upright or italic: which face of the family [font] picks.
  FontStyle get fontStyle => _fontStyle;

  set fontStyle(FontStyle value) {
    if (value == _fontStyle) return;
    _fontStyle = value;
    _textChanged();
  }

  /// Leading as a multiple of [fontSize], or null for the face's own.
  ///
  /// Only wrapped text has leading to place - a single line has nothing to be
  /// spaced from - so this changes the height of a [softWrap] paragraph and
  /// nothing about a label.
  double? get lineHeight => _lineHeight;

  set lineHeight(double? value) {
    if (value == _lineHeight) return;
    _lineHeight = value;
    _textChanged();
  }

  /// Extra pixels after every grapheme cluster; see
  /// `ParagraphTextStyle.letterSpacing`.
  double get letterSpacing => _letterSpacing;

  set letterSpacing(double value) {
    if (value == _letterSpacing) return;
    _letterSpacing = value;
    _textChanged();
  }

  /// Extra pixels after every space.
  double get wordSpacing => _wordSpacing;

  set wordSpacing(double value) {
    if (value == _wordSpacing) return;
    _wordSpacing = value;
    _textChanged();
  }

  // The paint-only fields below still lay out again when they change: they
  // travel in the paragraph's spans, which are part of its cache key. That is
  // a cache lookup when the value comes back, and a decoration that toggles
  // per frame is not a thing interfaces do.

  Color? get backgroundColor => _backgroundColor;

  set backgroundColor(Color? value) {
    if (value == _backgroundColor) return;
    _backgroundColor = value;
    _textChanged();
  }

  TextDecoration get decoration => _decoration;

  set decoration(TextDecoration value) {
    if (value == _decoration) return;
    _decoration = value;
    _textChanged();
  }

  Color? get decorationColor => _decorationColor;

  set decorationColor(Color? value) {
    if (value == _decorationColor) return;
    _decorationColor = value;
    _textChanged();
  }

  TextDecorationStyle get decorationStyle => _decorationStyle;

  set decorationStyle(TextDecorationStyle value) {
    if (value == _decorationStyle) return;
    _decorationStyle = value;
    _textChanged();
  }

  double get decorationThickness => _decorationThickness;

  set decorationThickness(double value) {
    if (value == _decorationThickness) return;
    _decorationThickness = value;
    _textChanged();
  }

  bool get softWrap => _softWrap;

  set softWrap(bool value) {
    if (value == _softWrap) return;
    _softWrap = value;
    _textChanged();
  }

  int? get maxLines => _maxLines;

  set maxLines(int? value) {
    if (value == _maxLines) return;
    if (value != null && value <= 0) {
      throw ArgumentError.value(value, 'maxLines', 'must be positive');
    }
    _maxLines = value;
    _textChanged();
  }

  String? get ellipsis => _ellipsis;

  set ellipsis(String? value) {
    if (value == _ellipsis) return;
    _ellipsis = value;
    _textChanged();
  }

  /// The face this line is drawn in, or null when the machine has none.
  ScaledTypeface? get font => _faceFor(
        _fontSize,
        _fontFamily,
        _fontWeight,
        italic: _fontStyle == FontStyle.italic,
      );

  /// The face for one combination of size, family, weight and slant.
  ///
  /// A family the machine does not have is null here, as it is for [font];
  /// a rich-text leaf that names one falls back to [font] at its own size
  /// rather than to nothing, which is the difference between a missing font
  /// and missing text.
  static ScaledTypeface? _faceFor(
    double size,
    String? family,
    int weight, {
    required bool italic,
  }) {
    if (family == null) {
      return FontRegistry.instance.uiFont(size, weight: weight, italic: italic);
    }
    return FontRegistry.instance
        .faceFor(family, weight: weight, italic: italic)
        ?.atSize(size);
  }

  // --- rich text -----------------------------------------------------------

  /// The paragraph spans for the text, flattened once per change.
  List<paragraph.TextSpan>? _spans;

  /// The face [_spans] was built for. A registry reset changes [font]
  /// without touching any setter, and spans built against the old face
  /// would lay out in it.
  ScaledTypeface? _spansFace;

  /// Leaf ranges whose span has a recognizer, in text order.
  List<({int start, int end, GestureRecognizer recognizer})> _links =
      const <({int start, int end, GestureRecognizer recognizer})>[];

  /// Recognizers this node handed a press to and that may still be
  /// following it.
  ///
  /// The press's later events go to these rather than to whatever [_links]
  /// says now: a link that changes colour while pressed rebuilds the spans,
  /// and a tap whose release went nowhere would never fire. A set, because
  /// one recognizer may serve several leaves and must see each event once.
  final Set<GestureRecognizer> _pressed = <GestureRecognizer>{};

  List<paragraph.TextSpan> _spansFor(ScaledTypeface face) {
    final List<paragraph.TextSpan>? cached = _spans;
    if (cached != null && _spansFace == face) return cached;
    final paragraph.TextStyle base = paragraph.TextStyle(
      font: face,
      syntheticItalic: _shears(face, _fontStyle == FontStyle.italic),
      backgroundColor: _backgroundColor,
      letterSpacing: _letterSpacing,
      wordSpacing: _wordSpacing,
      decoration: _decoration,
      decorationColor: _decorationColor,
      decorationStyle: _decorationStyle,
      decorationThickness: _decorationThickness,
    );
    final List<paragraph.TextSpan> spans = <paragraph.TextSpan>[];
    final links = <({int start, int end, GestureRecognizer recognizer})>[];
    final InlineSpan? root = _span;
    if (root == null) {
      spans.add(paragraph.TextSpan(_text, base));
    } else {
      int offset = 0;
      // Faces resolved per (size, family, weight, slant) for this flattening,
      // so a long document in three styles asks the registry three times.
      final Map<(double, String?, int, bool), ScaledTypeface> faces =
          <(double, String?, int, bool), ScaledTypeface>{};
      void visit(InlineSpan node, TextStyle? inherited) {
        final TextStyle? style = inherited == null
            ? node.style
            : node.style == null
                ? inherited
                : inherited.merge(node.style);
        switch (node) {
          case TextSpan(:final String? text, :final List<InlineSpan>? children):
            if (text != null && text.isNotEmpty) {
              spans.add(paragraph.TextSpan(
                text,
                _resolve(style, face, base, faces),
              ));
              final GestureRecognizer? recognizer = node.recognizer;
              if (recognizer != null) {
                links.add((
                  start: offset,
                  end: offset + text.length,
                  recognizer: recognizer,
                ));
              }
              offset += text.length;
            }
            if (children != null) {
              for (final InlineSpan child in children) {
                visit(child, style);
              }
            }
        }
      }

      visit(root, null);
      // A paragraph needs a style even with no text: an empty rich text
      // still has a line height, as an empty label does.
      if (spans.isEmpty) spans.add(paragraph.TextSpan('', base));
    }
    _links = links;
    _spansFace = face;
    return _spans = spans;
  }

  /// The paragraph style of one leaf: [style] - its ancestors' styles
  /// merged - over this node's own fields, which [base] already carries.
  paragraph.TextStyle _resolve(
    TextStyle? style,
    ScaledTypeface face,
    paragraph.TextStyle base,
    Map<(double, String?, int, bool), ScaledTypeface> faces,
  ) {
    if (style == null) return base;
    final double size = style.fontSize ?? _fontSize;
    final String? family = style.fontFamily ?? _fontFamily;
    final int weight = style.fontWeight?.value ?? _fontWeight;
    final bool italic = (style.fontStyle ?? _fontStyle) == FontStyle.italic;
    final ScaledTypeface leafFace = faces[(size, family, weight, italic)] ??=
        _faceFor(size, family, weight, italic: italic) ??
            (size == face.pixelSize ? face : face.typeface.atSize(size));
    return paragraph.TextStyle(
      font: leafFace,
      syntheticItalic: _shears(leafFace, italic),
      color: style.color,
      backgroundColor: style.backgroundColor ?? _backgroundColor,
      letterSpacing: style.letterSpacing ?? _letterSpacing,
      wordSpacing: style.wordSpacing ?? _wordSpacing,
      decoration: style.decoration ?? _decoration,
      decorationColor: style.decorationColor ?? _decorationColor,
      decorationStyle: style.decorationStyle ?? _decorationStyle,
      decorationThickness: style.decorationThickness ?? _decorationThickness,
    );
  }

  /// Lays the text out through the paragraph engine at [maxWidth].
  ///
  /// Plain text with no style the engine has to carry goes through
  /// `uiTextPainter.layout`, keyed exactly as it was before spans could be
  /// styled, so a wrapped label shares its cache entry with every other
  /// wrapped label of the same text and face.
  paragraph.Paragraph _layoutParagraph(ScaledTypeface face, double maxWidth) {
    final paragraph.ParagraphStyle style = paragraph.ParagraphStyle(
      align: _textAlign,
      breakWords: _breakWords,
      maxLines: _maxLines,
      ellipsis: _ellipsis,
      heightMultiplier: _heightMultiplier,
    );
    if (!_needsSpans) {
      return uiTextPainter.layout(
        _text,
        face,
        maxWidth: maxWidth,
        style: style,
      );
    }
    return uiTextPainter.layoutSpans(
      _spansFor(face),
      maxWidth: maxWidth,
      style: style,
    );
  }

  /// The box this line needs, measured through the same shaper paint uses.
  Size get _naturalSize {
    final ScaledTypeface? face = font;
    // With no face the estimated box is still reserved, so a missing font
    // shows up as blank text rather than as a tree that has collapsed to
    // nothing. See FontRegistry.estimatedSize.
    if (face == null) return FontRegistry.estimatedSize(_text, _fontSize);
    // A fallback face, or a style the paragraph carries, changes the
    // advances, and only the paragraph knows them; measuring the single run
    // would size the box for `.notdef`s or without the spacing.
    if (_needsSpans || (_fallsBack && !_hasHardBreak)) {
      return _layoutParagraph(face, double.infinity).size;
    }
    return uiTextPainter.measure(_text, face);
  }

  @override
  void performLayout() {
    final ScaledTypeface? face = font;
    if (!_usesParagraph || face == null) {
      _paragraph = null;
      size = constraints.constrain(_naturalSize);
      return;
    }
    _paragraph = _layoutParagraph(
      face,
      _layoutWidth(
          constraints.hasBoundedWidth ? constraints.maxWidth : double.infinity),
    );
    // Lines centred or right-aligned were placed across the layout width,
    // so the box is that wide: shrunk to the longest line, the offset would
    // count twice - once in the line, once more where a parent centres the
    // box.
    size = constraints.constrain(_alignsAcross && constraints.hasBoundedWidth
        ? Size(constraints.maxWidth, _paragraph!.size.height)
        : _paragraph!.size);
  }

  // --- intrinsics ---------------------------------------------------------
  //
  // The default single-line path reports its full shaped width. Wrapped text
  // delegates intrinsic measurements to paragraph layout, keeping parent
  // sizing consistent with the lines that will actually be painted.

  @override
  double computeMinIntrinsicWidth(double height) {
    final ScaledTypeface? face = font;
    if (!_usesParagraph || face == null) return _naturalSize.width;
    return _layoutParagraph(face, _layoutWidth(0)).size.width;
  }

  @override
  double computeMaxIntrinsicWidth(double height) {
    final ScaledTypeface? face = font;
    if ((!_hasHardBreak && !_needsSpans) || face == null) {
      return _naturalSize.width;
    }
    // The widest line, not the whole text as one line.
    return _layoutParagraph(face, double.infinity).size.width;
  }

  @override
  double computeMinIntrinsicHeight(double width) => _intrinsicHeightFor(width);

  @override
  double computeMaxIntrinsicHeight(double width) => _intrinsicHeightFor(width);

  double _intrinsicHeightFor(double width) {
    final ScaledTypeface? face = font;
    if (!_usesParagraph || face == null) return _naturalSize.height;
    return _layoutParagraph(face, _layoutWidth(width)).size.height;
  }

  /// The face's ascent: the distance from the top of the line box down to the
  /// line the letters sit on. `paint` below draws the run at exactly this
  /// offset, so what a row aligns to and what is drawn cannot disagree.
  ///
  /// With no face the ascent is estimated from the same 1.2 line-height ratio
  /// `FontRegistry` uses, for the same reason it estimates a box at all: a
  /// missing font must look like a missing font, not like a collapsed layout.
  @override
  double? computeDistanceToActualBaseline(TextBaseline baseline) {
    // A paragraph's first line sits below half its leading: with a line
    // height of 1.45 the letters start lower than the bare ascent, and a row
    // aligning a label to the first line of wrapped text has to know it.
    final laidOut = _paragraph;
    if (_usesParagraph &&
        laidOut != null &&
        laidOut.lines.isNotEmpty &&
        baseline == TextBaseline.alphabetic) {
      return laidOut.lines.first.baseline;
    }
    final ScaledTypeface? face = font;
    final double ascent =
        face?.ascent ?? FontRegistry.estimatedLineHeight(_fontSize) / 1.2;
    // An ideographic baseline sits at the bottom of the em box rather than on
    // the letters' feet. Without an OS/2 baseline table to read, the bottom of
    // the line box is the closest honest answer.
    return baseline == TextBaseline.alphabetic ? ascent : size.height;
  }

  // --- links ---------------------------------------------------------------

  /// The recognizer of the leaf whose glyphs are under [position], or null.
  ///
  /// Asked of the selection boxes rather than of `getPositionForOffset`:
  /// the nearest text position always exists, even far to the right of a
  /// short last line, and a link must not fire from a click on empty space
  /// beside it.
  GestureRecognizer? _recognizerAt(Offset position) {
    final paragraph.Paragraph? laid = _paragraph;
    if (laid == null || _links.isEmpty) return null;
    for (final link in _links) {
      for (final paragraph.TextBox box
          in laid.getBoxesForSelection(link.start, link.end)) {
        if (box.rect.contains(position)) return link.recognizer;
      }
    }
    return null;
  }

  /// Hit only over a link's glyphs - see the class comment.
  @override
  bool hitTestSelf(Offset position) =>
      _links.isNotEmpty && _recognizerAt(position) != null;

  @override
  void handlePointerEvent(PointerEvent event) {
    if (event is PointerDownEvent) {
      final GestureRecognizer? recognizer =
          _recognizerAt(globalToLocal(event.logicalPosition));
      if (recognizer != null && recognizer.addPointer(event)) {
        _pressed.add(recognizer);
      }
      return;
    }
    if (_pressed.isEmpty) return;
    for (final GestureRecognizer recognizer in _pressed.toList()) {
      recognizer.routeEvent(event);
    }
    if (event is PointerUpEvent || event is PointerCancelEvent) {
      _pressed.removeWhere(
        (GestureRecognizer recognizer) => recognizer.trackedPointerCount == 0,
      );
    }
  }

  /// A hand over a link, as Flutter's `TextSpan` defaults it to.
  @override
  SystemCursor? cursorFor(PointerEvent event) =>
      _recognizerAt(globalToLocal(event.logicalPosition)) == null
          ? null
          : SystemCursor.hand;

  @override
  void detach() {
    // A recognizer still seated in an arena for a node that left the tree
    // would hold that arena open, as `RenderGestureDetector.detach` explains.
    for (final GestureRecognizer recognizer in _pressed) {
      recognizer.cancelPending();
    }
    _pressed.clear();
    super.detach();
  }

  @override
  void paint(DisplayList list, Offset offset) {
    final ScaledTypeface? face = font;
    if (_text.isEmpty || face == null) return;
    final int paint = list.addPaint(colorArgb: _color.value, antiAlias: true);
    final laidOut = _paragraph;
    if (_usesParagraph && laidOut != null) {
      final bool clip = _clipsOverflow &&
          (laidOut.size.width > size.width ||
              laidOut.size.height > size.height);
      if (clip) {
        list
          ..save()
          ..clipRectangle(
            Rect.fromLTWH(offset.dx, offset.dy, size.width, size.height),
          );
      }
      uiTextPainter.paintParagraph(list, laidOut, offset, paint);
      if (clip) list.restore();
      return;
    }
    final GlyphRun run = uiTextPainter.shapeRun(_text, face);
    // Clipped to the box layout gave it, which may be narrower than the text
    // asked for: a constrained parent must not have text spill out of it.
    final bool clip = _clipsOverflow && run.width > size.width;
    if (clip) {
      list
        ..save()
        ..clipRectangle(
          Rect.fromLTWH(offset.dx, offset.dy, size.width, size.height),
        );
    }
    uiTextPainter.emitRun(
      list,
      run,
      Offset(offset.dx, offset.dy + face.ascent),
      paint,
    );
    if (clip) list.restore();
  }
}

/// Compatibility name; the implementation is the layout layer's real node.
typedef RenderColoredBox = layout.RenderColoredBox;
