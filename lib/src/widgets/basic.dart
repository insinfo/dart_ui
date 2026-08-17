library;

import '../geometry/offset.dart';
import '../geometry/rect.dart';
import '../geometry/size.dart';
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
import '../rendering/text/font_registry.dart';
import '../text/shaper.dart';
import '../text/typeface.dart';
import 'directionality.dart';
import 'element.dart';
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

  final int color;

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
final class Text extends RenderObjectWidget {
  const Text(
    this.text, {
    super.key,
    this.style,
    this.fontSize,
    this.color,
  });

  final String text;

  /// Flutter-compatible style surface. Explicit legacy fields below win.
  final TextStyle? style;

  /// The pixel size to draw at, or null to take the ambient theme's.
  final double? fontSize;

  /// `0xAARRGGBB`, overriding [style] and the ambient text style.
  final int? color;

  @override
  RenderObjectElement createElement() => RenderObjectElement(this);

  @override
  RenderText createRenderObject(BuildContext context) {
    final TextStyle resolved = _styleFrom(context);
    return RenderText(
      text,
      fontSize: resolved.fontSize ?? kDefaultUiFontSize,
      color: resolved.color ?? 0xFF111111,
      fontFamily: resolved.fontFamily,
      fontWeight: resolved.fontWeight?.value ?? 400,
    );
  }

  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderText renderObject,
  ) {
    final TextStyle resolved = _styleFrom(context);
    renderObject
      ..text = text
      ..fontSize = resolved.fontSize ?? kDefaultUiFontSize
      ..color = resolved.color ?? 0xFF111111
      ..fontFamily = resolved.fontFamily
      ..fontWeight = resolved.fontWeight?.value ?? 400;
  }

  /// The theme's font size, read **without** registering a dependency.
  ///
  /// A render-object element does not build, so subscribing it to the theme
  /// would schedule a rebuild that can never run. Reading it without a
  /// subscription is correct here because a theme swap rebuilds the subtree
  /// that installed it, which reaches this widget through its parent.
  TextStyle _styleFrom(BuildContext context) {
    final ThemeData theme =
        context.getInheritedWidgetOfExactType<Theme>()?.data ??
            ThemeData.neutralLight;
    final TextStyle ambient =
        context.getInheritedWidgetOfExactType<DefaultTextStyle>()?.style ??
            theme.textTheme.bodyMedium;
    final TextStyle merged = ambient.merge(style);
    return merged.copyWith(
      color: color ?? merged.color ?? theme.foreground,
      fontSize: fontSize ?? merged.fontSize ?? theme.fontSize,
    );
  }
}

/// A single-line text leaf.
///
/// One line, no wrapping, no alignment: paragraph layout is section 30's and
/// this is the leaf everything else is built on. What it does guarantee is that
/// layout and paint agree - both go through the same shaper, so the box
/// reserved is the box drawn, and a label that measured one width and painted
/// another cannot push the error into every container above it.
final class RenderText extends RenderBox {
  RenderText(
    String text, {
    int color = 0xFF111111,
    double fontSize = kDefaultUiFontSize,
    String? fontFamily,
    int fontWeight = 400,
  })  : _text = text,
        _color = color,
        _fontSize = fontSize,
        _fontFamily = fontFamily,
        _fontWeight = fontWeight;

  String _text;
  int _color;
  double _fontSize;
  String? _fontFamily;
  int _fontWeight;

  String get text => _text;

  set text(String value) {
    if (value == _text) return;
    _text = value;
    markNeedsLayout();
  }

  int get color => _color;

  set color(int value) {
    if (value == _color) return;
    _color = value;
    markNeedsPaint();
  }

  double get fontSize => _fontSize;

  set fontSize(double value) {
    if (value == _fontSize) return;
    _fontSize = value;
    markNeedsLayout();
  }

  String? get fontFamily => _fontFamily;

  set fontFamily(String? value) {
    if (value == _fontFamily) return;
    _fontFamily = value;
    markNeedsLayout();
  }

  int get fontWeight => _fontWeight;

  set fontWeight(int value) {
    if (value == _fontWeight) return;
    _fontWeight = value;
    markNeedsLayout();
  }

  /// The face this line is drawn in, or null when the machine has none.
  ScaledTypeface? get font {
    final String? family = _fontFamily;
    if (family == null) return FontRegistry.instance.uiFont(_fontSize);
    return FontRegistry.instance
        .faceFor(family, weight: _fontWeight)
        ?.atSize(_fontSize);
  }

  /// The box this line needs, measured through the same shaper paint uses.
  Size get _naturalSize {
    final ScaledTypeface? face = font;
    // With no face the estimated box is still reserved, so a missing font
    // shows up as blank text rather than as a tree that has collapsed to
    // nothing. See FontRegistry.estimatedSize.
    return face == null
        ? FontRegistry.estimatedSize(_text, _fontSize)
        : uiTextPainter.measure(_text, face);
  }

  @override
  void performLayout() {
    size = constraints.constrain(_naturalSize);
  }

  // --- intrinsics ---------------------------------------------------------
  //
  // Minimum and maximum are the same number, and that is not laziness. This
  // node does not wrap: whatever width it is given, it lays out the whole
  // string on one line. Reporting a smaller minimum would be a lie a parent
  // acts on - a grid column would size itself to the "longest word", this node
  // would then draw the whole line anyway, and the text would be clipped by
  // `paint` below with no way to tell from the layout that anything was wrong.
  // A shrinkable minimum becomes correct on the day this node wraps, and not a
  // moment sooner; it belongs with the paragraph node of section 30.

  @override
  double computeMinIntrinsicWidth(double height) => _naturalSize.width;

  @override
  double computeMaxIntrinsicWidth(double height) => _naturalSize.width;

  @override
  double computeMinIntrinsicHeight(double width) => _naturalSize.height;

  @override
  double computeMaxIntrinsicHeight(double width) => _naturalSize.height;

  /// The face's ascent: the distance from the top of the line box down to the
  /// line the letters sit on. `paint` below draws the run at exactly this
  /// offset, so what a row aligns to and what is drawn cannot disagree.
  ///
  /// With no face the ascent is estimated from the same 1.2 line-height ratio
  /// `FontRegistry` uses, for the same reason it estimates a box at all: a
  /// missing font must look like a missing font, not like a collapsed layout.
  @override
  double? computeDistanceToActualBaseline(TextBaseline baseline) {
    final ScaledTypeface? face = font;
    final double ascent =
        face?.ascent ?? FontRegistry.estimatedLineHeight(_fontSize) / 1.2;
    // An ideographic baseline sits at the bottom of the em box rather than on
    // the letters' feet. Without an OS/2 baseline table to read, the bottom of
    // the line box is the closest honest answer.
    return baseline == TextBaseline.alphabetic ? ascent : size.height;
  }

  @override
  bool hitTestSelf(Offset position) => false;

  @override
  void paint(DisplayList list, Offset offset) {
    final ScaledTypeface? face = font;
    if (_text.isEmpty || face == null) return;
    final int paint = list.addPaint(colorArgb: _color, antiAlias: true);
    final GlyphRun run = uiTextPainter.shaper.shape(_text, face);
    // Clipped to the box layout gave it, which may be narrower than the text
    // asked for: a constrained parent must not have text spill out of it.
    final bool clip = run.width > size.width;
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
