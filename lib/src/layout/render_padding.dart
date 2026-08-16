/// Insets a child inside its parent.
library;

import 'dart:math' as math;

import '../geometry/size.dart';
import 'box_constraints.dart';
import 'edge_insets.dart';
import 'render_box.dart';

/// Shrinks the constraints by [padding], then grows its own size back by the
/// same amount.
///
/// The two halves have different failure modes and are handled differently.
/// The constraint side clamps (see [BoxConstraints.deflate]): padding wider
/// than the space available leaves the child nothing, which is a legitimate
/// state when a window shrinks. The size side does not clamp the padding
/// away - the node reports child-plus-padding, constrained - so a padded box
/// that no longer fits reports the largest size it is allowed and its child
/// stays where the padding put it, rather than the padding silently
/// evaporating on one side.
final class RenderPadding extends RenderSingleChildBox {
  RenderPadding({required EdgeInsets padding, super.child})
      : _padding = padding;

  EdgeInsets _padding;

  EdgeInsets get padding => _padding;

  set padding(EdgeInsets value) {
    if (value == _padding) return;
    _padding = value;
    markNeedsLayout();
  }

  // The insets are added on both sides of every intrinsic, and subtracted from
  // the cross extent handed to the child: a label asked "how tall are you at
  // 100px wide" inside 8px of horizontal padding only has 84px to work with.
  // Subtracting nothing from an unbounded cross extent is deliberate -
  // `infinity - 8` is still infinity, which is the honest answer.

  @override
  double computeMinIntrinsicWidth(double height) =>
      _padding.horizontal +
      (child?.getMinIntrinsicWidth(_less(height, _padding.vertical)) ?? 0.0);

  @override
  double computeMaxIntrinsicWidth(double height) =>
      _padding.horizontal +
      (child?.getMaxIntrinsicWidth(_less(height, _padding.vertical)) ?? 0.0);

  @override
  double computeMinIntrinsicHeight(double width) =>
      _padding.vertical +
      (child?.getMinIntrinsicHeight(_less(width, _padding.horizontal)) ?? 0.0);

  @override
  double computeMaxIntrinsicHeight(double width) =>
      _padding.vertical +
      (child?.getMaxIntrinsicHeight(_less(width, _padding.horizontal)) ?? 0.0);

  static double _less(double extent, double inset) =>
      extent.isFinite ? math.max(0.0, extent - inset) : extent;

  @override
  void performLayout() {
    final BoxConstraints constraints = this.constraints;
    final RenderBox? child = this.child;
    if (child == null) {
      size = constraints.constrain(_padding.inflateSize(Size.zero));
      return;
    }
    child.layout(constraints.deflate(_padding), parentUsesSize: true);
    child.parentData!.offset = _padding.topLeft;
    size = constraints.constrain(_padding.inflateSize(child.size));
  }
}
