/// A box that fills itself with one colour.
///
/// The smallest node that actually draws, which makes it the one every test of
/// a layer above uses to see where a box ended up.
library;

import '../geometry/offset.dart';
import '../geometry/rect.dart';
import '../graphics/color.dart';
import '../graphics/display_list.dart';
import '../graphics/display_list_geometry.dart';
import 'render_box.dart';

/// Paints an opaque (or translucent) rectangle behind its child, if any.
///
/// Sizing has two cases: with a child it is exactly the child's size, so the
/// colour is a background rather than a box of its own; without one it fills
/// whatever it is given, because that is the only sensible reading of "a
/// coloured area with no content".
final class RenderColoredBox extends RenderSingleChildBox {
  RenderColoredBox({required Color color, super.child}) : _color = color;

  Color _color;

  Color get color => _color;

  set color(Color value) {
    if (value == _color) return;
    _color = value;
    // Colour cannot move anything, so layout stays clean. This is the one
    // property change in the whole tree that is purely a repaint.
    markNeedsPaint();
  }

  @override
  void performLayout() {
    final RenderBox? child = this.child;
    if (child == null) {
      size = constraints.largestFinite;
      return;
    }
    child.layout(constraints, parentUsesSize: true);
    size = child.size;
  }

  /// A filled area absorbs pointers. A transparent colour still does: what is
  /// painted and what is interactive are separate decisions, and a node that
  /// stopped taking events at alpha 0 would make a fade-out silently change
  /// behaviour halfway through.
  @override
  bool hitTestSelf(Offset position) => true;

  @override
  void paint(DisplayList list, Offset offset) {
    final int paintId = list.addPaint(colorArgb: _color.value);
    list.drawRectangle(
      Rect.fromLTWH(offset.dx, offset.dy, size.width, size.height),
      paintId,
    );
    super.paint(list, offset);
  }
}
