/// The sizing boxes a migrating layout assumes exist.
///
/// Seven widgets and their render nodes, each of which answers one question
/// `SizedBox` and `Align` cannot: a size expressed as a fraction of the parent
/// ([FractionallySizedBox]), a size taken from the content's own preference
/// ([IntrinsicWidth], [IntrinsicHeight]), a ceiling that applies only where the
/// parent offered none ([LimitedBox]), constraints deliberately different from
/// the parent's ([OverflowBox], [SizedOverflowBox]), and a position expressed
/// relative to the text baseline ([Baseline]).
///
/// The render nodes live here rather than in `src/layout/` for the same reason
/// `RenderText` lives next to `Text` and `RenderButton` next to `Button`: a node
/// with exactly one widget in front of it is easier to keep honest when the two
/// are read together.
library;

import 'dart:math' as math;

import '../geometry/offset.dart';
import '../geometry/size.dart';
import '../layout/alignment.dart';
import '../layout/box_constraints.dart';
import '../layout/render_box.dart';
import '../layout/render_constrained_box.dart';
import 'element.dart';
import 'widget.dart';

// ---------------------------------------------------------------------------
// ConstrainedBox
// ---------------------------------------------------------------------------

/// Imposes extra constraints on its child.
///
/// The widget face of `RenderConstrainedBox`, which `SizedBox` has always used
/// and which had no general spelling until now. Identical to Flutter's,
/// including that the parent wins: asking for a 400 px minimum inside a 200 px
/// parent yields 200 rather than an overflow. See the render node's comment for
/// why that precedence is the right one.
final class ConstrainedBox extends SingleChildRenderObjectWidget {
  const ConstrainedBox({
    super.key,
    required this.constraints,
    super.child,
  });

  final BoxConstraints constraints;

  @override
  RenderConstrainedBox createRenderObject(BuildContext context) =>
      RenderConstrainedBox(additionalConstraints: constraints);

  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderConstrainedBox renderObject,
  ) {
    renderObject.additionalConstraints = constraints;
  }
}

// ---------------------------------------------------------------------------
// FractionallySizedBox
// ---------------------------------------------------------------------------

/// Sizes its child to a fraction of the space this box is given.
///
/// `widthFactor: 0.5` means "half of whatever width my parent offered", which
/// is the one thing a `SizedBox` cannot express because it does not know that
/// number until layout.
///
/// A factor on an **unbounded** axis is a named error rather than an infinite
/// size: half of infinity is infinity, and this framework rejects an infinite
/// extent by name (`InfiniteMeasureError`) precisely so that the failure lands
/// on the node that produced it. Flutter propagates the infinity and fails
/// somewhere further up. Put a bounded ancestor - a `SizedBox`, a scroll
/// viewport's cross axis - above it, or drop the factor for that axis.
final class FractionallySizedBox extends SingleChildRenderObjectWidget {
  const FractionallySizedBox({
    super.key,
    this.alignment = Alignment.center,
    this.widthFactor,
    this.heightFactor,
    super.child,
  });

  /// Where the child sits inside this box when the factors leave room. A
  /// physical [Alignment] rather than Flutter's `AlignmentGeometry`; resolve an
  /// `AlignmentDirectional` above this widget.
  final Alignment alignment;

  final double? widthFactor;
  final double? heightFactor;

  @override
  RenderFractionallySizedBox createRenderObject(BuildContext context) =>
      RenderFractionallySizedBox(
        alignment: alignment,
        widthFactor: widthFactor,
        heightFactor: heightFactor,
      );

  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderFractionallySizedBox renderObject,
  ) {
    renderObject
      ..alignment = alignment
      ..widthFactor = widthFactor
      ..heightFactor = heightFactor;
  }
}

/// Lays a child out under constraints that are a fraction of its own.
final class RenderFractionallySizedBox extends RenderSingleChildBox {
  RenderFractionallySizedBox({
    Alignment alignment = Alignment.center,
    double? widthFactor,
    double? heightFactor,
    super.child,
  })  : _alignment = alignment,
        _widthFactor = _checked('widthFactor', widthFactor),
        _heightFactor = _checked('heightFactor', heightFactor);

  Alignment _alignment;
  double? _widthFactor;
  double? _heightFactor;

  Alignment get alignment => _alignment;

  set alignment(Alignment value) {
    if (value == _alignment) return;
    _alignment = value;
    markNeedsLayout();
  }

  double? get widthFactor => _widthFactor;

  set widthFactor(double? value) {
    if (value == _widthFactor) return;
    _widthFactor = _checked('widthFactor', value);
    markNeedsLayout();
  }

  double? get heightFactor => _heightFactor;

  set heightFactor(double? value) {
    if (value == _heightFactor) return;
    _heightFactor = _checked('heightFactor', value);
    markNeedsLayout();
  }

  static double? _checked(String name, double? value) {
    if (value != null && (value < 0 || value.isNaN)) {
      throw ArgumentError.value(
        value,
        name,
        'must be null or non-negative; a negative fraction asks for a '
        'negative size, which no constraint can satisfy',
      );
    }
    return value;
  }

  BoxConstraints _innerConstraints(BoxConstraints constraints) {
    double minWidth = constraints.minWidth;
    double maxWidth = constraints.maxWidth;
    final double? widthFactor = _widthFactor;
    if (widthFactor != null) {
      if (!constraints.hasBoundedWidth) {
        throw _unbounded('widthFactor', 'width');
      }
      minWidth = maxWidth = maxWidth * widthFactor;
    }
    double minHeight = constraints.minHeight;
    double maxHeight = constraints.maxHeight;
    final double? heightFactor = _heightFactor;
    if (heightFactor != null) {
      if (!constraints.hasBoundedHeight) {
        throw _unbounded('heightFactor', 'height');
      }
      minHeight = maxHeight = maxHeight * heightFactor;
    }
    return BoxConstraints(
      minWidth: minWidth,
      maxWidth: maxWidth,
      minHeight: minHeight,
      maxHeight: maxHeight,
    );
  }

  StateError _unbounded(String factor, String axis) => StateError(
        'FractionallySizedBox was given a $factor under an unbounded $axis. '
        'A fraction of infinity is infinity, and an infinite extent is not a '
        'size anything can paint or store. Bound the $axis above this widget, '
        'or drop the $factor.',
      );

  @override
  void performLayout() {
    final BoxConstraints constraints = this.constraints;
    final RenderBox? child = this.child;
    if (child == null) {
      // Nothing to measure, so the box takes the space it is allowed rather
      // than a fraction of nothing - the same rule `RenderAlign` follows.
      size = constraints.largestFinite;
      return;
    }
    child.layout(_innerConstraints(constraints), parentUsesSize: true);
    size = constraints.constrain(child.size);
    child.parentData!.offset = _alignment.offsetFor(child.size, size);
  }
}

// ---------------------------------------------------------------------------
// IntrinsicWidth / IntrinsicHeight
// ---------------------------------------------------------------------------

/// Sizes its child to the child's own max-content width.
///
/// The expensive one, and Flutter's warning applies here word for word: an
/// intrinsic query walks the whole subtree, so this is `O(N^2)` when nested and
/// should be reached for only when nothing else expresses the layout - a column
/// of buttons that must all be as wide as the widest label is the canonical
/// case.
///
/// [stepWidth] and [stepHeight] round the result up to a multiple, which is how
/// a grid of cells stays on a rhythm when the content does not.
final class IntrinsicWidth extends SingleChildRenderObjectWidget {
  const IntrinsicWidth({
    super.key,
    this.stepWidth,
    this.stepHeight,
    super.child,
  });

  final double? stepWidth;
  final double? stepHeight;

  @override
  RenderIntrinsicWidth createRenderObject(BuildContext context) =>
      RenderIntrinsicWidth(stepWidth: stepWidth, stepHeight: stepHeight);

  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderIntrinsicWidth renderObject,
  ) {
    renderObject
      ..stepWidth = stepWidth
      ..stepHeight = stepHeight;
  }
}

/// Tightens its own constraints to the child's max-content width.
final class RenderIntrinsicWidth extends RenderSingleChildBox {
  RenderIntrinsicWidth({double? stepWidth, double? stepHeight, super.child})
      : _stepWidth = _checked('stepWidth', stepWidth),
        _stepHeight = _checked('stepHeight', stepHeight);

  double? _stepWidth;
  double? _stepHeight;

  double? get stepWidth => _stepWidth;

  set stepWidth(double? value) {
    if (value == _stepWidth) return;
    _stepWidth = _checked('stepWidth', value);
    markNeedsLayout();
  }

  double? get stepHeight => _stepHeight;

  set stepHeight(double? value) {
    if (value == _stepHeight) return;
    _stepHeight = _checked('stepHeight', value);
    markNeedsLayout();
  }

  static double? _checked(String name, double? value) {
    if (value != null && !(value > 0)) {
      throw ArgumentError.value(
        value,
        name,
        'must be null or strictly positive; a zero step divides by zero and a '
        'negative one rounds down forever',
      );
    }
    return value;
  }

  static double _applyStep(double input, double? step) =>
      step == null ? input : (input / step).ceil() * step;

  // Both width questions answer the same number, because that is the whole
  // claim this node makes: whatever the content wants at most, that is the
  // width, and there is no narrower arrangement it will accept.

  @override
  double computeMinIntrinsicWidth(double height) =>
      computeMaxIntrinsicWidth(height);

  @override
  double computeMaxIntrinsicWidth(double height) {
    final RenderBox? child = this.child;
    if (child == null) return 0.0;
    return _applyStep(child.getMaxIntrinsicWidth(height), _stepWidth);
  }

  @override
  double computeMinIntrinsicHeight(double width) =>
      _heightAt(width, max: false);

  @override
  double computeMaxIntrinsicHeight(double width) => _heightAt(width, max: true);

  /// The child's height demand, measured at the width this node would give it.
  ///
  /// The `isFinite` branch is the one that matters: asking "how tall at
  /// unlimited width" of a node that is about to be pinned to its content width
  /// would measure a paragraph as one long line. Substituting the width this
  /// node actually imposes is what makes the intrinsic agree with the layout.
  double _heightAt(double width, {required bool max}) {
    final RenderBox? child = this.child;
    if (child == null) return 0.0;
    final double at =
        width.isFinite ? width : computeMaxIntrinsicWidth(double.infinity);
    return _applyStep(
      max ? child.getMaxIntrinsicHeight(at) : child.getMinIntrinsicHeight(at),
      _stepHeight,
    );
  }

  @override
  void performLayout() {
    final RenderBox? child = this.child;
    if (child == null) {
      size = constraints.smallest;
      return;
    }
    BoxConstraints inner = constraints;
    if (!inner.hasTightWidth) {
      // Already tight means the answer is decided and the query would be a
      // whole-subtree walk whose result is thrown away.
      final double width = child.getMaxIntrinsicWidth(inner.maxHeight);
      inner = inner.tighten(width: _applyStep(width, _stepWidth));
    }
    if (_stepHeight != null) {
      final double height = child.getMaxIntrinsicHeight(inner.maxWidth);
      inner = inner.tighten(height: _applyStep(height, _stepHeight));
    }
    child.layout(inner, parentUsesSize: true);
    size = child.size;
  }
}

/// Sizes its child to the child's own max-content height.
///
/// The row-shaped twin of [IntrinsicWidth], with the same cost warning: this is
/// what makes two cards in a `Row` share the height of the taller one.
final class IntrinsicHeight extends SingleChildRenderObjectWidget {
  const IntrinsicHeight({super.key, super.child});

  @override
  RenderIntrinsicHeight createRenderObject(BuildContext context) =>
      RenderIntrinsicHeight();
}

/// Tightens its own constraints to the child's max-content height.
final class RenderIntrinsicHeight extends RenderSingleChildBox {
  RenderIntrinsicHeight({super.child});

  // The mirror of [RenderIntrinsicWidth]'s pair, for the same reason.

  @override
  double computeMinIntrinsicHeight(double width) =>
      computeMaxIntrinsicHeight(width);

  @override
  double computeMinIntrinsicWidth(double height) =>
      _widthAt(height, max: false);

  @override
  double computeMaxIntrinsicWidth(double height) => _widthAt(height, max: true);

  /// The child's width demand, measured at the height this node would give it.
  double _widthAt(double height, {required bool max}) {
    final RenderBox? child = this.child;
    if (child == null) return 0.0;
    final double at =
        height.isFinite ? height : child.getMaxIntrinsicHeight(double.infinity);
    return max
        ? child.getMaxIntrinsicWidth(at)
        : child.getMinIntrinsicWidth(at);
  }

  @override
  void performLayout() {
    final RenderBox? child = this.child;
    if (child == null) {
      size = constraints.smallest;
      return;
    }
    BoxConstraints inner = constraints;
    if (!inner.hasTightHeight) {
      inner =
          inner.tighten(height: child.getMaxIntrinsicHeight(inner.maxWidth));
    }
    child.layout(inner, parentUsesSize: true);
    size = child.size;
  }
}

// ---------------------------------------------------------------------------
// LimitedBox
// ---------------------------------------------------------------------------

/// Caps its child's size, but **only on an axis the parent left unbounded**.
///
/// The distinction is the whole widget and it is the one everybody gets wrong:
/// inside a `Column`, a `LimitedBox(maxHeight: 100)` does nothing at all,
/// because the column already bounded the height. It exists for the other case
/// - a child of a scroll viewport, whose main axis is infinite - where it is
/// what stops an image or a wrapping paragraph from asking for infinity.
/// Identical to Flutter's, including the surprise.
final class LimitedBox extends SingleChildRenderObjectWidget {
  const LimitedBox({
    super.key,
    this.maxWidth = double.infinity,
    this.maxHeight = double.infinity,
    super.child,
  });

  final double maxWidth;
  final double maxHeight;

  @override
  RenderLimitedBox createRenderObject(BuildContext context) =>
      RenderLimitedBox(maxWidth: maxWidth, maxHeight: maxHeight);

  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderLimitedBox renderObject,
  ) {
    renderObject
      ..maxWidth = maxWidth
      ..maxHeight = maxHeight;
  }
}

/// Applies a ceiling to an unbounded axis and leaves a bounded one alone.
final class RenderLimitedBox extends RenderSingleChildBox {
  RenderLimitedBox({
    double maxWidth = double.infinity,
    double maxHeight = double.infinity,
    super.child,
  })  : _maxWidth = _checked('maxWidth', maxWidth),
        _maxHeight = _checked('maxHeight', maxHeight);

  double _maxWidth;
  double _maxHeight;

  double get maxWidth => _maxWidth;

  set maxWidth(double value) {
    if (value == _maxWidth) return;
    _maxWidth = _checked('maxWidth', value);
    markNeedsLayout();
  }

  double get maxHeight => _maxHeight;

  set maxHeight(double value) {
    if (value == _maxHeight) return;
    _maxHeight = _checked('maxHeight', value);
    markNeedsLayout();
  }

  static double _checked(String name, double value) {
    if (value < 0 || value.isNaN) {
      throw ArgumentError.value(
        value,
        name,
        'must be non-negative; a negative ceiling is unsatisfiable',
      );
    }
    return value;
  }

  BoxConstraints _limit(BoxConstraints constraints) => BoxConstraints(
        minWidth: constraints.minWidth,
        maxWidth: constraints.hasBoundedWidth
            ? constraints.maxWidth
            : constraints.constrainWidth(_maxWidth),
        minHeight: constraints.minHeight,
        maxHeight: constraints.hasBoundedHeight
            ? constraints.maxHeight
            : constraints.constrainHeight(_maxHeight),
      );

  @override
  void performLayout() {
    final BoxConstraints constraints = this.constraints;
    final RenderBox? child = this.child;
    if (child == null) {
      size = _limit(constraints).constrain(Size.zero);
      return;
    }
    child.layout(_limit(constraints), parentUsesSize: true);
    size = constraints.constrain(child.size);
  }
}

// ---------------------------------------------------------------------------
// OverflowBox / SizedOverflowBox
// ---------------------------------------------------------------------------

/// Gives its child constraints of its own, and lets the result overflow.
///
/// Each of [minWidth], [maxWidth], [minHeight] and [maxHeight] replaces the
/// corresponding incoming constraint when it is non-null and passes it through
/// when it is null. The box itself still reports the size its own parent
/// allowed, so a child that came back larger paints outside it - which is the
/// entire point, and also why nothing here clips.
///
/// **One honest difference from Flutter:** an unbounded axis collapses to its
/// minimum instead of asserting. Flutter's `OverflowBox` is `sizedByParent` and
/// takes `constraints.biggest`, which is infinite under an unbounded parent and
/// trips an assertion; this framework has a name for that answer -
/// `BoxConstraints.largestFinite` - and uses it, so an `OverflowBox` inside a
/// scroll viewport collapses on the scroll axis rather than failing.
final class OverflowBox extends SingleChildRenderObjectWidget {
  const OverflowBox({
    super.key,
    this.alignment = Alignment.center,
    this.minWidth,
    this.maxWidth,
    this.minHeight,
    this.maxHeight,
    super.child,
  });

  /// A physical [Alignment] rather than Flutter's `AlignmentGeometry`.
  final Alignment alignment;

  final double? minWidth;
  final double? maxWidth;
  final double? minHeight;
  final double? maxHeight;

  @override
  RenderOverflowBox createRenderObject(BuildContext context) =>
      RenderOverflowBox(
        alignment: alignment,
        minWidth: minWidth,
        maxWidth: maxWidth,
        minHeight: minHeight,
        maxHeight: maxHeight,
      );

  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderOverflowBox renderObject,
  ) {
    renderObject
      ..alignment = alignment
      ..minWidth = minWidth
      ..maxWidth = maxWidth
      ..minHeight = minHeight
      ..maxHeight = maxHeight;
  }
}

/// Replaces some of its incoming constraints before laying the child out.
final class RenderOverflowBox extends RenderSingleChildBox {
  RenderOverflowBox({
    Alignment alignment = Alignment.center,
    double? minWidth,
    double? maxWidth,
    double? minHeight,
    double? maxHeight,
    super.child,
  })  : _alignment = alignment,
        _minWidth = minWidth,
        _maxWidth = maxWidth,
        _minHeight = minHeight,
        _maxHeight = maxHeight;

  Alignment _alignment;
  double? _minWidth;
  double? _maxWidth;
  double? _minHeight;
  double? _maxHeight;

  Alignment get alignment => _alignment;

  set alignment(Alignment value) {
    if (value == _alignment) return;
    _alignment = value;
    markNeedsLayout();
  }

  double? get minWidth => _minWidth;

  set minWidth(double? value) {
    if (value == _minWidth) return;
    _minWidth = value;
    markNeedsLayout();
  }

  double? get maxWidth => _maxWidth;

  set maxWidth(double? value) {
    if (value == _maxWidth) return;
    _maxWidth = value;
    markNeedsLayout();
  }

  double? get minHeight => _minHeight;

  set minHeight(double? value) {
    if (value == _minHeight) return;
    _minHeight = value;
    markNeedsLayout();
  }

  double? get maxHeight => _maxHeight;

  set maxHeight(double? value) {
    if (value == _maxHeight) return;
    _maxHeight = value;
    markNeedsLayout();
  }

  BoxConstraints _innerConstraints(BoxConstraints constraints) =>
      BoxConstraints(
        minWidth: _minWidth ?? constraints.minWidth,
        maxWidth: _maxWidth ?? constraints.maxWidth,
        minHeight: _minHeight ?? constraints.minHeight,
        maxHeight: _maxHeight ?? constraints.maxHeight,
      );

  @override
  void performLayout() {
    final BoxConstraints constraints = this.constraints;
    // This node's own size never depends on the child's: that is what makes it
    // an *overflow* box rather than a wrapper, and it is also why the child is
    // laid out with `parentUsesSize` still true - the alignment below reads the
    // size even though the size above does not.
    size = constraints.largestFinite;
    final RenderBox? child = this.child;
    if (child == null) return;
    child.layout(_innerConstraints(constraints), parentUsesSize: true);
    child.parentData!.offset = _alignment.offsetFor(child.size, size);
  }
}

/// Reports one size to its parent and lays its child out under the *parent's*
/// constraints.
///
/// The asymmetry is the point: the box claims `size` worth of space in the
/// layout, while the child is measured against what the grandparent offered and
/// may be larger. A 200 px-wide banner that occupies 40 px of a toolbar is this
/// widget. Identical to Flutter's.
final class SizedOverflowBox extends SingleChildRenderObjectWidget {
  const SizedOverflowBox({
    super.key,
    required this.size,
    this.alignment = Alignment.center,
    super.child,
  });

  /// The size this box asks its parent for, subject to its own constraints.
  final Size size;

  /// A physical [Alignment] rather than Flutter's `AlignmentGeometry`.
  final Alignment alignment;

  @override
  RenderSizedOverflowBox createRenderObject(BuildContext context) =>
      RenderSizedOverflowBox(requestedSize: size, alignment: alignment);

  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderSizedOverflowBox renderObject,
  ) {
    renderObject
      ..requestedSize = size
      ..alignment = alignment;
  }
}

/// Sizes itself to a requested extent while measuring the child against the
/// incoming constraints.
final class RenderSizedOverflowBox extends RenderSingleChildBox {
  RenderSizedOverflowBox({
    required Size requestedSize,
    Alignment alignment = Alignment.center,
    super.child,
  })  : _requestedSize = requestedSize,
        _alignment = alignment;

  Size _requestedSize;
  Alignment _alignment;

  Size get requestedSize => _requestedSize;

  set requestedSize(Size value) {
    if (value == _requestedSize) return;
    _requestedSize = value;
    markNeedsLayout();
  }

  Alignment get alignment => _alignment;

  set alignment(Alignment value) {
    if (value == _alignment) return;
    _alignment = value;
    markNeedsLayout();
  }

  @override
  double computeMinIntrinsicWidth(double height) => _requestedSize.width;

  @override
  double computeMaxIntrinsicWidth(double height) => _requestedSize.width;

  @override
  double computeMinIntrinsicHeight(double width) => _requestedSize.height;

  @override
  double computeMaxIntrinsicHeight(double width) => _requestedSize.height;

  @override
  void performLayout() {
    final BoxConstraints constraints = this.constraints;
    size = constraints.constrain(_requestedSize);
    final RenderBox? child = this.child;
    if (child == null) return;
    child.layout(constraints, parentUsesSize: true);
    child.parentData!.offset = _alignment.offsetFor(child.size, size);
  }
}

// ---------------------------------------------------------------------------
// Baseline
// ---------------------------------------------------------------------------

/// Positions its child so the child's text baseline lands [baseline] pixels
/// from the top of this box.
///
/// What lines a caption up with the body text next to it when the two are in
/// different faces and different sizes, and the only widget in this set that
/// reads `RenderBox.getDistanceToBaseline`. A child with no text in it reports
/// its bottom edge as its baseline - see that method - so this still does
/// something sensible around an icon.
///
/// Identical to Flutter's, including that the box grows downward: its height is
/// the child's height plus however far the child had to be pushed down.
final class Baseline extends SingleChildRenderObjectWidget {
  const Baseline({
    super.key,
    required this.baseline,
    required this.baselineType,
    super.child,
  });

  /// Distance from this box's top edge to the child's baseline.
  final double baseline;

  final TextBaseline baselineType;

  @override
  RenderBaseline createRenderObject(BuildContext context) =>
      RenderBaseline(baseline: baseline, baselineType: baselineType);

  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderBaseline renderObject,
  ) {
    renderObject
      ..baseline = baseline
      ..baselineType = baselineType;
  }
}

/// Shifts its child down so its baseline lands at a fixed distance.
final class RenderBaseline extends RenderSingleChildBox {
  RenderBaseline({
    required double baseline,
    required TextBaseline baselineType,
    super.child,
  })  : _baseline = baseline,
        _baselineType = baselineType;

  double _baseline;
  TextBaseline _baselineType;

  double get baseline => _baseline;

  set baseline(double value) {
    if (value == _baseline) return;
    _baseline = value;
    markNeedsLayout();
  }

  TextBaseline get baselineType => _baselineType;

  set baselineType(TextBaseline value) {
    if (value == _baselineType) return;
    _baselineType = value;
    markNeedsLayout();
  }

  @override
  void performLayout() {
    final BoxConstraints constraints = this.constraints;
    final RenderBox? child = this.child;
    if (child == null) {
      size = constraints.smallest;
      return;
    }
    child.layout(constraints.loosen(), parentUsesSize: true);
    // Never null with `onlyReal` left false: a node with no text answers with
    // its own bottom edge, which is what keeps an icon in a row of labels on
    // the same line instead of jumping to the top.
    final double childBaseline = child.getDistanceToBaseline(_baselineType)!;
    // Clamped at zero: a child whose baseline is already lower than the target
    // would need a negative offset, and pulling it above this box's top edge
    // would put it outside the box its parent reserved for it.
    final double top = math.max(0.0, _baseline - childBaseline);
    child.parentData!.offset = Offset(0, top);
    size = constraints.constrain(
      Size(child.size.width, top + child.size.height),
    );
  }
}
