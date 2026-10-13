/// The layout widgets Flutter code reaches for and this framework lacked:
/// [Container], [FittedBox], [RotatedBox], [IndexedStack], [Offstage] and
/// [Placeholder] - with Flutter's names and behaviour, so a screen moved
/// from Flutter lays out the same.
library;

import 'dart:math' as math;

import '../geometry/offset.dart';
import '../geometry/path.dart';
import '../geometry/rect.dart';
import '../geometry/size.dart';
import '../geometry/transform2d.dart';
import '../graphics/color.dart';
import '../graphics/display_list.dart';
import '../graphics/display_list_geometry.dart';
import '../graphics/display_list_opcodes.dart';
import '../layout/alignment.dart';
import '../layout/box_constraints.dart';
import '../layout/decoration.dart' show Decoration, DecorationPosition;
import '../layout/edge_insets.dart';
import '../layout/render_box.dart';
import '../layout/render_proxy_box.dart';
import '../layout/render_stack.dart' as layout;
import '../text/shaper.dart' show TextDirection;
import 'basic.dart';
import 'directionality.dart';
import 'element.dart';
import 'image.dart' show BoxFit, FittedSizes, applyBoxFit;
import 'proxy.dart';
import 'sizing.dart';
import 'widget.dart';

/// Padding, a background, a size and an alignment in one widget - the
/// composition Flutter's `Container` is, in the same order: margin outside
/// the decoration, padding inside it, then the constraints, the alignment
/// and the child.
///
/// With no child and nothing that bounds it, a Container fills the space it
/// is given - a coloured panel - and shrinks to nothing where that space is
/// unbounded, as Flutter's does.
///
/// As in Flutter, the [decoration]'s own padding - a border's widths - is
/// added to [padding], so a bordered container's child sits inside the
/// border; [foregroundDecoration] is painted over the child. There is no
/// `clipBehavior`.
final class Container extends StatelessWidget {
  Container({
    super.key,
    this.alignment,
    this.padding,
    this.color,
    this.decoration,
    this.foregroundDecoration,
    double? width,
    double? height,
    BoxConstraints? constraints,
    this.margin,
    this.transform,
    this.transformAlignment,
    this.child,
  })  : assert(color == null || decoration == null,
            'give the colour in the decoration, not both'),
        constraints = (width != null || height != null)
            ? (constraints ?? BoxConstraints())
                .tighten(width: width, height: height)
            : constraints;

  final Alignment? alignment;
  final EdgeInsets? padding;
  final Color? color;
  final Decoration? decoration;
  final Decoration? foregroundDecoration;
  final BoxConstraints? constraints;
  final EdgeInsets? margin;
  final Transform2D? transform;
  final Alignment? transformAlignment;
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    Widget? current = child;
    if (current == null && (constraints == null || !constraints!.isTight)) {
      current = LimitedBox(
        maxWidth: 0,
        maxHeight: 0,
        child: ConstrainedBox(
            constraints: BoxConstraints.expand(), child: const SizedBox()),
      );
    } else if (alignment != null) {
      current = Align(alignment: alignment!, child: current);
    }
    EdgeInsets? effectivePadding = padding;
    final Decoration? decoration = this.decoration;
    if (decoration != null) {
      final EdgeInsets inset = decoration.padding.resolve(
          Directionality.maybeOf(context) ?? TextDirection.leftToRight);
      if (!inset.isZero) {
        effectivePadding =
            effectivePadding == null ? inset : effectivePadding + inset;
      }
    }
    if (effectivePadding != null) {
      current = Padding(padding: effectivePadding, child: current);
    }
    if (color != null) current = ColoredBox(color: color!, child: current);
    if (decoration != null) {
      current = DecoratedBox(decoration: decoration, child: current);
    }
    if (foregroundDecoration != null) {
      current = DecoratedBox(
        decoration: foregroundDecoration!,
        position: DecorationPosition.foreground,
        child: current,
      );
    }
    if (constraints != null) {
      current = ConstrainedBox(constraints: constraints!, child: current);
    }
    if (margin != null) current = Padding(padding: margin!, child: current);
    if (transform != null) {
      current = Transform(
        transform: transform!,
        alignment: transformAlignment,
        child: current,
      );
    }
    return current ?? const SizedBox();
  }
}

/// Lays [child] out but neither paints it nor lets it be hit, and takes no
/// space while [offstage] - a page kept alive behind a tab, measured but not
/// shown.
final class Offstage extends StatelessWidget {
  const Offstage({super.key, this.offstage = true, this.child});

  final bool offstage;
  final Widget? child;

  @override
  Widget build(BuildContext context) =>
      Visibility(visible: !offstage, maintainSize: false, child: child);
}

/// A stack that shows one child, [index], and keeps the others laid out and
/// alive - their state, their scroll positions - so switching back is
/// instant. Sized by the largest child.
final class IndexedStack extends StatelessWidget {
  const IndexedStack({
    super.key,
    this.index = 0,
    this.alignment = Alignment.topLeft,
    this.sizing = layout.StackFit.loose,
    this.children = const <Widget>[],
  });

  /// The child shown; null shows none.
  final int? index;
  final Alignment alignment;
  final layout.StackFit sizing;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Stack(
        alignment: alignment,
        fit: sizing,
        children: <Widget>[
          for (var i = 0; i < children.length; i++)
            Visibility(visible: i == index, child: children[i]),
        ],
      );
}

/// A box with a cross through it, standing in for a widget not yet
/// written. Fills its space, or [fallbackWidth] by [fallbackHeight] where
/// that is unbounded.
final class Placeholder extends StatelessWidget {
  const Placeholder({
    super.key,
    this.color = const Color(0xFF455A64),
    this.strokeWidth = 2,
    this.fallbackWidth = 400,
    this.fallbackHeight = 400,
  });

  final Color color;
  final double strokeWidth;
  final double fallbackWidth;
  final double fallbackHeight;

  @override
  Widget build(BuildContext context) => LimitedBox(
        maxWidth: fallbackWidth,
        maxHeight: fallbackHeight,
        child: _PlaceholderPaint(color: color, strokeWidth: strokeWidth),
      );
}

final class _PlaceholderPaint extends SingleChildRenderObjectWidget {
  const _PlaceholderPaint({required this.color, required this.strokeWidth});

  final Color color;
  final double strokeWidth;

  @override
  _RenderPlaceholder createRenderObject(BuildContext context) =>
      _RenderPlaceholder(color, strokeWidth);

  @override
  void updateRenderObject(
      BuildContext context, covariant _RenderPlaceholder renderObject) {
    renderObject
      ..color = color
      ..strokeWidth = strokeWidth
      ..markNeedsPaint();
  }
}

final class _RenderPlaceholder extends RenderProxyBox {
  _RenderPlaceholder(this.color, this.strokeWidth);

  Color color;
  double strokeWidth;

  @override
  void performLayout() => size = constraints.constrain(Size(
        constraints.hasBoundedWidth ? constraints.maxWidth : 0,
        constraints.hasBoundedHeight ? constraints.maxHeight : 0,
      ));

  @override
  void paint(DisplayList list, Offset offset) {
    final Rect box =
        Rect.fromLTWH(offset.dx, offset.dy, size.width, size.height);
    final int paint = list.addPaint(
      colorArgb: color.value,
      style: paintStyleStroke,
      strokeWidth: strokeWidth,
    );
    final double inset = strokeWidth / 2;
    final PathBuilder cross = PathBuilder()
      ..moveTo(box.left, box.top)
      ..lineTo(box.right, box.bottom)
      ..moveTo(box.right, box.top)
      ..lineTo(box.left, box.bottom);
    list
      ..drawRectangle(box.deflate(inset), paint)
      ..drawPath(list.addPath(cross.build()), paint);
  }
}

/// Turns [child] a whole number of quarter turns clockwise *before* layout,
/// so the rotated child takes the space it shows: a vertical label in a
/// table header, a sidebar title.
final class RotatedBox extends SingleChildRenderObjectWidget {
  const RotatedBox({super.key, required this.quarterTurns, super.child});

  final int quarterTurns;

  @override
  RenderRotatedBox createRenderObject(BuildContext context) =>
      RenderRotatedBox(quarterTurns);

  @override
  void updateRenderObject(
          BuildContext context, covariant RenderRotatedBox renderObject) =>
      renderObject.quarterTurns = quarterTurns;
}

/// The render object behind [RotatedBox].
final class RenderRotatedBox extends RenderProxyBox with _TransformedPaint {
  RenderRotatedBox(int quarterTurns) : _quarterTurns = quarterTurns;

  int _quarterTurns;

  int get quarterTurns => _quarterTurns;

  set quarterTurns(int value) {
    if (value == _quarterTurns) return;
    _quarterTurns = value;
    markNeedsLayout();
  }

  int get _turns => _quarterTurns % 4;
  bool get _sideways => _turns.isOdd;

  @override
  void performLayout() {
    final RenderBox? child = this.child;
    if (child == null) {
      size = constraints.smallest;
      return;
    }
    final BoxConstraints c = constraints;
    child.layout(
      _sideways
          ? BoxConstraints(
              minWidth: c.minHeight,
              maxWidth: c.maxHeight,
              minHeight: c.minWidth,
              maxHeight: c.maxWidth,
            )
          : c,
      parentUsesSize: true,
    );
    final Size s = child.size;
    size = _sideways ? Size(s.height, s.width) : s;
  }

  /// Child space to this box's space.
  Transform2D get _transform => switch (_turns) {
        1 => Transform2D.translation(size.width, 0)
            .multiply(Transform2D.rotation(math.pi / 2)),
        2 => Transform2D.translation(size.width, size.height)
            .multiply(Transform2D.rotation(math.pi)),
        3 => Transform2D.translation(0, size.height)
            .multiply(Transform2D.rotation(3 * math.pi / 2)),
        _ => Transform2D.identity,
      };

  @override
  RenderBox? hitTest(Offset position, {HitTestPath? path}) {
    if (!size.contains(position)) return null;
    final RenderBox? hit = hitTestChildren(position, path: path);
    if (hit == null) return null;
    path?.add(this);
    return hit;
  }

  @override
  RenderBox? hitTestChildren(Offset position, {HitTestPath? path}) {
    final Transform2D? inverse = _transform.invert();
    if (inverse == null) return null;
    return super.hitTestChildren(inverse.transformOffset(position), path: path);
  }

  @override
  void paint(DisplayList list, Offset offset) {
    final RenderBox? child = this.child;
    if (child == null) return;
    _paintTransformed(list, offset, _transform, child);
  }
}

/// Scales and places [child] inside itself by [fit] and [alignment] - a
/// logo that fills whatever box it is given, text that shrinks to fit.
final class FittedBox extends SingleChildRenderObjectWidget {
  const FittedBox({
    super.key,
    this.fit = BoxFit.contain,
    this.alignment = Alignment.center,
    super.child,
  });

  final BoxFit fit;
  final Alignment alignment;

  @override
  RenderFittedBox createRenderObject(BuildContext context) =>
      RenderFittedBox(fit: fit, alignment: alignment);

  @override
  void updateRenderObject(
      BuildContext context, covariant RenderFittedBox renderObject) {
    renderObject
      ..fit = fit
      ..alignment = alignment;
  }
}

/// The render object behind [FittedBox].
final class RenderFittedBox extends RenderProxyBox with _TransformedPaint {
  RenderFittedBox({required BoxFit fit, required Alignment alignment})
      : _fit = fit,
        _alignment = alignment;

  BoxFit _fit;
  Alignment _alignment;

  BoxFit get fit => _fit;

  set fit(BoxFit value) {
    if (value == _fit) return;
    _fit = value;
    markNeedsLayout();
  }

  Alignment get alignment => _alignment;

  set alignment(Alignment value) {
    if (value == _alignment) return;
    _alignment = value;
    markNeedsPaint();
  }

  @override
  void performLayout() {
    final RenderBox? child = this.child;
    if (child == null) {
      size = constraints.smallest;
      return;
    }
    // The child at its own size, whatever that is; the fit scales it.
    child.layout(BoxConstraints(), parentUsesSize: true);
    final Size natural = child.size;
    size = _fitInto(natural, constraints);
  }

  /// The largest size [constraints] allow that keeps [natural]'s aspect,
  /// where they allow a choice: Flutter's
  /// `constrainSizeAndAttemptToPreserveAspectRatio`.
  static Size _fitInto(Size natural, BoxConstraints constraints) {
    if (constraints.isTight) return constraints.smallest;
    if (natural.width <= 0 || natural.height <= 0) {
      return constraints.constrain(natural);
    }
    double width = natural.width;
    double height = natural.height;
    final double aspect = width / height;
    if (width > constraints.maxWidth) {
      width = constraints.maxWidth;
      height = width / aspect;
    }
    if (height > constraints.maxHeight) {
      height = constraints.maxHeight;
      width = height * aspect;
    }
    if (width < constraints.minWidth) {
      width = constraints.minWidth;
      height = width / aspect;
    }
    if (height < constraints.minHeight) {
      height = constraints.minHeight;
      width = height * aspect;
    }
    return constraints.constrain(Size(width, height));
  }

  /// Child space to this box's space, and whether it spills over the box.
  (Transform2D, bool) get _transform {
    final RenderBox child = this.child!;
    final Size natural = child.size;
    final FittedSizes sizes = applyBoxFit(_fit, natural, size);
    if (sizes.source.width <= 0 || sizes.source.height <= 0) {
      return (Transform2D.identity, false);
    }
    final double sx = sizes.destination.width / sizes.source.width;
    final double sy = sizes.destination.height / sizes.source.height;
    final Offset source = _alignment.offsetFor(sizes.source, natural);
    final Offset destination = _alignment.offsetFor(sizes.destination, size);
    final Transform2D transform =
        Transform2D.translation(destination.dx, destination.dy)
            .multiply(Transform2D.scaling(sx, sy))
            .multiply(Transform2D.translation(-source.dx, -source.dy));
    final bool spills = natural.width * sx > size.width + 1e-6 ||
        natural.height * sy > size.height + 1e-6;
    return (transform, spills);
  }

  @override
  RenderBox? hitTest(Offset position, {HitTestPath? path}) {
    if (!size.contains(position)) return null;
    final RenderBox? hit = hitTestChildren(position, path: path);
    if (hit == null) return null;
    path?.add(this);
    return hit;
  }

  @override
  RenderBox? hitTestChildren(Offset position, {HitTestPath? path}) {
    if (child == null) return null;
    final Transform2D? inverse = _transform.$1.invert();
    if (inverse == null) return null;
    return super.hitTestChildren(inverse.transformOffset(position), path: path);
  }

  @override
  void paint(DisplayList list, Offset offset) {
    final RenderBox? child = this.child;
    if (child == null || size.isEmpty) return;
    final (Transform2D transform, bool spills) = _transform;
    if (spills) {
      list
        ..save()
        ..clipRectangle(
            Rect.fromLTWH(offset.dx, offset.dy, size.width, size.height));
    }
    _paintTransformed(list, offset, transform, child);
    if (spills) list.restore();
  }
}

/// Painting a child through a matrix about the box's own origin, with the
/// box at some offset: the conjugation `RenderTransform` does.
mixin _TransformedPaint on RenderProxyBox {
  void _paintTransformed(
      DisplayList list, Offset offset, Transform2D local, RenderBox child) {
    if (local.isIdentity) {
      paintChild(list, child, offset);
      return;
    }
    final double determinant = local.determinant;
    if (determinant == 0 || !determinant.isFinite) return;
    list
      ..save()
      ..transform2D(Transform2D.translation(offset.dx, offset.dy)
          .multiply(local)
          .multiply(Transform2D.translation(-offset.dx, -offset.dy)));
    paintChild(list, child, offset);
    list.restore();
  }
}
