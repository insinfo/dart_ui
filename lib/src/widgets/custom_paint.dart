/// Drawing of your own: a box whose picture is a function of its size - an
/// icon that is not a font glyph, a chart, a thumbnail placeholder.
library;

import '../geometry/offset.dart';
import '../geometry/size.dart';
import '../graphics/display_list.dart';
import '../layout/render_box.dart';
import 'element.dart';
import 'widget.dart';

/// Draws into a [DisplayList] in the box's own coordinates.
typedef BoxPainter = void Function(DisplayList list, Size size);

/// A leaf that paints with [painter].
///
/// It takes [size] when the constraints leave it free and the constraints'
/// size otherwise. [painter] is called with the origin at the box's top
/// left, so it draws from (0, 0) to `size` whatever the box's place on
/// screen. Every rebuild repaints: a painter is a closure, and two closures
/// cannot be compared for "draws the same".
final class CustomPaint extends RenderObjectWidget {
  const CustomPaint({
    super.key,
    required this.painter,
    this.size = Size.zero,
  });

  final BoxPainter painter;
  final Size size;

  @override
  RenderObjectElement createElement() => RenderObjectElement(this);

  @override
  RenderCustomPaint createRenderObject(BuildContext context) =>
      RenderCustomPaint(painter: painter, preferredSize: size);

  @override
  void updateRenderObject(
      BuildContext context, covariant RenderCustomPaint renderObject) {
    renderObject
      ..painter = painter
      ..preferredSize = size;
  }
}

/// The render node behind [CustomPaint].
final class RenderCustomPaint extends RenderBox {
  RenderCustomPaint(
      {required BoxPainter painter, Size preferredSize = Size.zero})
      : _painter = painter,
        _preferredSize = preferredSize;

  BoxPainter _painter;
  Size _preferredSize;

  BoxPainter get painter => _painter;

  set painter(BoxPainter value) {
    _painter = value;
    markNeedsPaint();
  }

  Size get preferredSize => _preferredSize;

  set preferredSize(Size value) {
    if (value == _preferredSize) return;
    _preferredSize = value;
    markNeedsLayout();
  }

  @override
  void performLayout() {
    size = constraints.constrain(_preferredSize);
  }

  @override
  double computeMinIntrinsicWidth(double height) => _preferredSize.width;

  @override
  double computeMaxIntrinsicWidth(double height) => _preferredSize.width;

  @override
  double computeMinIntrinsicHeight(double width) => _preferredSize.height;

  @override
  double computeMaxIntrinsicHeight(double width) => _preferredSize.height;

  @override
  void paint(DisplayList list, Offset offset) {
    if (size.isEmpty) return;
    list
      ..save()
      ..transform(1, 0, 0, 1, offset.dx, offset.dy);
    _painter(list, size);
    list.restore();
  }
}
