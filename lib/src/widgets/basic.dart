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
import '../platform/input_events.dart';
import '../rendering/text/font_registry.dart';
import '../text/shaper.dart';
import '../text/typeface.dart';
import 'element.dart';
import 'pointer_router.dart';
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

  @override
  layout.RenderFlex createRenderObject(BuildContext context) =>
      layout.RenderFlex(
        direction: direction,
        mainAxisAlignment: mainAxisAlignment,
        crossAxisAlignment: crossAxisAlignment,
        mainAxisSize: mainAxisSize,
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
      ..mainAxisSize = mainAxisSize;
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
/// placement and spans exist on the render node
/// ([layout.RenderGrid.place]) but have no widget-layer spelling yet: that
/// needs a parent-data widget, which needs the element layer to carry per-child
/// configuration down, and neither is this file's to add.
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

/// Recognizes a primary-button tap inside its child's hit-test region.
final class GestureDetector extends SingleChildRenderObjectWidget {
  const GestureDetector({super.key, this.onTap, required super.child});

  final void Function()? onTap;

  @override
  RenderTapGestureDetector createRenderObject(BuildContext context) =>
      RenderTapGestureDetector(onTap: onTap);

  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderTapGestureDetector renderObject,
  ) {
    renderObject.onTap = onTap;
  }
}

/// Render-tree endpoint for [GestureDetector].
///
/// Hit testing remains delegated to the child, so a detector around a
/// transparent, non-hittable subtree does not invent an interactive region.
final class RenderTapGestureDetector extends RenderSingleChildBox
    implements PointerEventTarget {
  RenderTapGestureDetector({void Function()? onTap}) : _onTap = onTap;

  void Function()? _onTap;
  int? _primaryPointer;

  void Function()? get onTap => _onTap;

  set onTap(void Function()? value) {
    _onTap = value;
    if (value == null) _primaryPointer = null;
  }

  @override
  void performLayout() {
    final RenderBox? child = this.child;
    if (child == null) {
      size = constraints.smallest;
      return;
    }
    child.layout(constraints, parentUsesSize: true);
    size = constraints.constrain(child.size);
  }

  @override
  void handlePointerEvent(PointerEvent event) {
    if (_onTap == null) return;
    switch (event) {
      case PointerDownEvent(button: PointerButton.primary):
        _primaryPointer = event.pointerId;
      case PointerUpEvent(button: PointerButton.primary):
        if (_primaryPointer != event.pointerId) return;
        _primaryPointer = null;
        // The pointer was captured on the press, so this release arrives even
        // when it landed elsewhere. A tap is a press *and* a release on the
        // same thing; dragging away and letting go is how a user takes it back.
        if (!hasSize || !size.contains(globalToLocal(event.logicalPosition))) {
          return;
        }
        _onTap?.call();
      case PointerCancelEvent():
        if (_primaryPointer == event.pointerId) _primaryPointer = null;
      case PointerMoveEvent():
      case PointerScrollEvent():
      case PointerDownEvent():
      case PointerUpEvent():
    }
  }
}

/// Text configuration. Shaping and glyph painting remain a renderer concern.
final class Text extends RenderObjectWidget {
  const Text(this.text, {super.key, this.fontSize});

  final String text;

  /// The pixel size to draw at, or null to take the ambient theme's.
  final double? fontSize;

  @override
  RenderObjectElement createElement() => RenderObjectElement(this);

  @override
  RenderText createRenderObject(BuildContext context) =>
      RenderText(text, fontSize: _sizeFrom(context));

  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderText renderObject,
  ) {
    renderObject
      ..text = text
      ..fontSize = _sizeFrom(context);
  }

  /// The theme's font size, read **without** registering a dependency.
  ///
  /// A render-object element does not build, so subscribing it to the theme
  /// would schedule a rebuild that can never run. Reading it without a
  /// subscription is correct here because a theme swap rebuilds the subtree
  /// that installed it, which reaches this widget through its parent.
  double _sizeFrom(BuildContext context) =>
      fontSize ??
      context.getInheritedWidgetOfExactType<Theme>()?.data.fontSize ??
      kDefaultUiFontSize;
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
  })  : _text = text,
        _color = color,
        _fontSize = fontSize;

  String _text;
  int _color;
  double _fontSize;

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

  /// The face this line is drawn in, or null when the machine has none.
  ScaledTypeface? get font => FontRegistry.instance.uiFont(_fontSize);

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
