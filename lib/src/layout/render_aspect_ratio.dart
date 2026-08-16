/// A box that keeps a fixed width-to-height ratio.
library;

import '../geometry/size.dart';
import 'box_constraints.dart';
import 'render_box.dart';

/// Sizes itself to the largest box with the given ratio that its constraints
/// allow, and gives that box to its child.
///
/// The ratio is `width / height`, so `16 / 9` is a widescreen frame and `1`
/// is a square.
///
/// ## How the size is chosen
///
/// Start from the widest box permitted and derive the height from it. Then
/// correct, in this order: shrink if too wide, shrink if too tall, grow if too
/// narrow, grow if too short. Each correction recomputes the other axis from
/// the ratio, so the ratio survives all four; only the final [BoxConstraints
/// .constrain] can break it, and it only does so when the constraints leave no
/// box of this shape at all - a tight 100x100 under a 2:1 ratio, say. In that
/// case the constraint wins, because reporting a size the parent did not permit
/// would corrupt every layout above this one. The child is then laid out at the
/// resolved size regardless, which is what makes the breakage visible.
///
/// ## Why it does not consult the child
///
/// The child's own preferred size is not part of the calculation. An aspect
/// ratio is a statement about the *frame*, not about what is in it, and a node
/// that let its content argue with the ratio would produce a frame that is
/// nearly-but-not-quite 16:9 - which is the one outcome nobody wants from this
/// widget. The intrinsics below follow the same rule and answer purely from the
/// ratio whenever the cross extent is known.
final class RenderAspectRatio extends RenderSingleChildBox {
  RenderAspectRatio({required double aspectRatio, super.child})
      : _aspectRatio = aspectRatio {
    _check(aspectRatio);
  }

  double _aspectRatio;

  /// Width divided by height.
  double get aspectRatio => _aspectRatio;

  set aspectRatio(double value) {
    if (value == _aspectRatio) return;
    _check(value);
    _aspectRatio = value;
    markNeedsLayout();
  }

  static void _check(double value) {
    if (value.isNaN || value.isInfinite || value <= 0.0) {
      throw ArgumentError.value(
        value,
        'aspectRatio',
        'must be a finite ratio greater than zero; zero or infinity describes '
            'a box with no area, and a negative one has no meaning',
      );
    }
  }

  @override
  double computeMinIntrinsicWidth(double height) => height.isFinite
      ? height * _aspectRatio
      : super.computeMinIntrinsicWidth(height);

  @override
  double computeMaxIntrinsicWidth(double height) => height.isFinite
      ? height * _aspectRatio
      : super.computeMaxIntrinsicWidth(height);

  @override
  double computeMinIntrinsicHeight(double width) => width.isFinite
      ? width / _aspectRatio
      : super.computeMinIntrinsicHeight(width);

  @override
  double computeMaxIntrinsicHeight(double width) => width.isFinite
      ? width / _aspectRatio
      : super.computeMaxIntrinsicHeight(width);

  /// The box this node takes under [constraints].
  ///
  /// Exposed as a pure function so the rule can be tested without a tree, and
  /// so a caller reasoning about a layout can ask the question without running
  /// one.
  Size sizeFor(BoxConstraints constraints) {
    if (constraints.isTight) return constraints.smallest;

    double width = constraints.maxWidth;
    double height;
    if (width.isFinite) {
      height = width / _aspectRatio;
    } else {
      height = constraints.maxHeight;
      if (!height.isFinite) {
        throw StateError(
          'a $runtimeType was given unbounded width *and* unbounded height. '
          'An aspect ratio fixes the shape of a box, not its size: with no '
          'bound on either axis there is no largest box of this shape. Bound '
          'one of them - a scroll viewport bounds the cross axis, which is '
          'usually the one that is missing.',
        );
      }
      width = height * _aspectRatio;
    }

    // Four corrections, each recomputing the other axis so the ratio holds.
    // Order matters: the maxima are applied first because a box that is too
    // big cannot be fixed by growing it, and the minima afterwards because
    // they are the ones a parent insists on.
    if (width > constraints.maxWidth) {
      width = constraints.maxWidth;
      height = width / _aspectRatio;
    }
    if (height > constraints.maxHeight) {
      height = constraints.maxHeight;
      width = height * _aspectRatio;
    }
    if (width < constraints.minWidth) {
      width = constraints.minWidth;
      height = width / _aspectRatio;
    }
    if (height < constraints.minHeight) {
      height = constraints.minHeight;
      width = height * _aspectRatio;
    }
    return constraints.constrain(Size(width, height));
  }

  @override
  void performLayout() {
    size = sizeFor(constraints);
    child?.layout(BoxConstraints.tight(size));
  }
}
