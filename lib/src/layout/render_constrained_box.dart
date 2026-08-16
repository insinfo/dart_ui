/// Imposes extra constraints on a child.
library;

import '../geometry/size.dart';
import 'box_constraints.dart';
import 'render_box.dart';

/// Combines its own constraints with [additionalConstraints] before laying the
/// child out.
///
/// The combination is [BoxConstraints.enforce], which means the parent always
/// wins: asking for a 400px minimum inside a 200px parent yields 200, not an
/// overflow and not an exception. That is the right precedence for a
/// constraint node - it expresses a preference about the space it was given,
/// not a claim on space it was not - and it is what keeps a fixed-size box
/// from breaking a window that is smaller than it.
///
/// A node that genuinely wants to exceed its parent overflows on purpose by
/// sizing itself past its constraints, which the layout driver rejects; the
/// way to actually do it is a scrolling or overflow node, which is a different
/// thing and does not exist yet.
final class RenderConstrainedBox extends RenderSingleChildBox {
  RenderConstrainedBox({
    required BoxConstraints additionalConstraints,
    super.child,
  }) : _additionalConstraints = additionalConstraints;

  BoxConstraints _additionalConstraints;

  BoxConstraints get additionalConstraints => _additionalConstraints;

  set additionalConstraints(BoxConstraints value) {
    if (value == _additionalConstraints) return;
    _additionalConstraints = value;
    markNeedsLayout();
  }

  // An intrinsic here is the child's, clamped into the extra constraints. When
  // those are tight on an axis - which is what a `SizedBox(width: 40)` is - the
  // clamp collapses to the fixed extent and the child is never consulted at
  // all, which is both correct and the reason a fixed-size cell in a grid does
  // not drag a whole subtree into the measuring pass.

  @override
  double computeMinIntrinsicWidth(double height) =>
      _additionalConstraints.constrainWidth(
        child?.getMinIntrinsicWidth(height) ?? 0.0,
      );

  @override
  double computeMaxIntrinsicWidth(double height) =>
      _additionalConstraints.constrainWidth(
        child?.getMaxIntrinsicWidth(height) ?? 0.0,
      );

  @override
  double computeMinIntrinsicHeight(double width) =>
      _additionalConstraints.constrainHeight(
        child?.getMinIntrinsicHeight(width) ?? 0.0,
      );

  @override
  double computeMaxIntrinsicHeight(double width) =>
      _additionalConstraints.constrainHeight(
        child?.getMaxIntrinsicHeight(width) ?? 0.0,
      );

  @override
  void performLayout() {
    final BoxConstraints inner = _additionalConstraints.enforce(constraints);
    final RenderBox? child = this.child;
    if (child == null) {
      // No content to measure, so take the smallest size the combination
      // permits rather than the largest: a constrained empty box is a spacer,
      // and a spacer that greedily filled its parent would be a surprise.
      size = inner.constrain(Size.zero);
      return;
    }
    child.layout(inner, parentUsesSize: true);
    size = child.size;
  }
}
