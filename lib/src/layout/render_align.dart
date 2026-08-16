/// Positions a child inside a larger box.
library;

import '../geometry/size.dart';
import 'alignment.dart';
import 'box_constraints.dart';
import 'render_box.dart';

/// Loosens its constraints, lets the child pick a size, then places that child
/// according to an [Alignment].
///
/// Its own size follows a rule worth stating: on an axis that is bounded and
/// has no size factor, it takes all the space it is given - there is no point
/// aligning inside a box that shrink-wraps its child, since there would be no
/// leftover space to align in. On an unbounded axis, or one with a factor, it
/// shrink-wraps to the child (times the factor), because "as large as
/// possible" is infinite there and infinity is not a size.
final class RenderAlign extends RenderSingleChildBox {
  RenderAlign({
    Alignment alignment = Alignment.center,
    double? widthFactor,
    double? heightFactor,
    super.child,
  })  : _alignment = alignment,
        _widthFactor = widthFactor,
        _heightFactor = heightFactor {
    _checkFactor('widthFactor', widthFactor);
    _checkFactor('heightFactor', heightFactor);
  }

  Alignment _alignment;
  double? _widthFactor;
  double? _heightFactor;

  Alignment get alignment => _alignment;

  set alignment(Alignment value) {
    if (value == _alignment) return;
    _alignment = value;
    // Alignment moves the child, and position is decided during layout, so
    // this is not a repaint-only change even though nothing resizes.
    markNeedsLayout();
  }

  /// Makes this box a multiple of the child's width instead of filling the
  /// available width. Null means "fill if bounded".
  double? get widthFactor => _widthFactor;

  set widthFactor(double? value) {
    if (value == _widthFactor) return;
    _checkFactor('widthFactor', value);
    _widthFactor = value;
    markNeedsLayout();
  }

  double? get heightFactor => _heightFactor;

  set heightFactor(double? value) {
    if (value == _heightFactor) return;
    _checkFactor('heightFactor', value);
    _heightFactor = value;
    markNeedsLayout();
  }

  static void _checkFactor(String name, double? value) {
    if (value != null && (value < 0 || value.isNaN)) {
      throw ArgumentError.value(
        value,
        name,
        'must be null or non-negative; a negative factor asks for a negative '
        'size, which no constraint can satisfy',
      );
    }
  }

  // The factors are the only thing alignment adds to an intrinsic. Position is
  // not an extent: a child centred in whatever space it is given wants exactly
  // as much content width as it did before it was centred, so the proxy
  // defaults inherited from RenderSingleChildBox are already right without one.

  @override
  double computeMinIntrinsicWidth(double height) =>
      super.computeMinIntrinsicWidth(height) * (_widthFactor ?? 1.0);

  @override
  double computeMaxIntrinsicWidth(double height) =>
      super.computeMaxIntrinsicWidth(height) * (_widthFactor ?? 1.0);

  @override
  double computeMinIntrinsicHeight(double width) =>
      super.computeMinIntrinsicHeight(width) * (_heightFactor ?? 1.0);

  @override
  double computeMaxIntrinsicHeight(double width) =>
      super.computeMaxIntrinsicHeight(width) * (_heightFactor ?? 1.0);

  @override
  void performLayout() {
    final BoxConstraints constraints = this.constraints;
    final bool shrinkWrapWidth =
        _widthFactor != null || !constraints.hasBoundedWidth;
    final bool shrinkWrapHeight =
        _heightFactor != null || !constraints.hasBoundedHeight;

    final RenderBox? child = this.child;
    if (child == null) {
      // Nothing to wrap: an axis that would have shrink-wrapped collapses to
      // its minimum instead of to infinity.
      size = constraints.constrain(
        Size(
          shrinkWrapWidth ? 0.0 : double.infinity,
          shrinkWrapHeight ? 0.0 : double.infinity,
        ),
      );
      return;
    }

    child.layout(constraints.loosen(), parentUsesSize: true);
    final Size childSize = child.size;
    size = constraints.constrain(
      Size(
        shrinkWrapWidth
            ? childSize.width * (_widthFactor ?? 1.0)
            : double.infinity,
        shrinkWrapHeight
            ? childSize.height * (_heightFactor ?? 1.0)
            : double.infinity,
      ),
    );
    child.parentData!.offset = _alignment.offsetFor(childSize, size);
  }
}
