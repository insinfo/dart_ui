/// Children placed at paint time by a delegate - Flutter's `RenderFlow`,
/// `FlowDelegate` and `FlowPaintingContext`.
///
/// [RenderCustomMultiChildLayoutBox] positions children in layout, which is
/// the right place for geometry that other boxes depend on. A flow positions
/// them in *paint*, through a transform per child, and that is the whole point
/// of it: a fan-out menu, a carousel, a radial picker animate every frame, and
/// a position decided in paint changes by repainting only. Nothing is laid out
/// again, no sibling is measured again, and the delegate's `repaint`
/// listenable - usually the animation itself - drives the frame straight to
/// [RenderBox.markNeedsPaint].
///
/// The price is the one Flutter states: the flow's own size cannot depend on
/// where its children end up, because it was fixed in layout, before the
/// delegate decided anything.
///
/// ## The transform is [Transform2D], not a 4x4 matrix
///
/// The display list concatenates 2D affine matrices and nothing else; see
/// `transform2D` in `graphics/display_list_geometry.dart`. So
/// [FlowPaintingContext.paintChild] takes a [Transform2D] where Flutter takes
/// a `Matrix4` - translation, scale, rotation and skew all fit, perspective
/// does not, and there is no third axis to put a child "in front of" another:
/// stacking is the order of the `paintChild` calls, as it is in Flutter.
///
/// ## Children and pointers
///
/// A child is hit through the inverse of the transform it was *painted* with,
/// last painted first, so whatever is on top on screen is what takes the
/// pointer. A child the delegate did not paint in the last frame is not hit
/// at all: it is not on screen, and an invisible control that still swallows
/// clicks is the bug this rule exists to rule out.
///
/// [RenderBox.globalOffset] and its two converters still read offsets only
/// (see the note there), and a flow child's offset is always zero, so they
/// do not know where a flow child was painted - the same limit
/// [RenderTransform] has. Hit testing does not go through them and is exact.
library;

import '../foundation/change_notifier.dart';
import '../geometry/offset.dart';
import '../geometry/rect.dart';
import '../geometry/size.dart';
import '../geometry/transform2d.dart';
import '../graphics/display_list.dart';
import '../graphics/display_list_geometry.dart';
import 'box_constraints.dart';
import 'pipeline.dart';
import 'render_box.dart';

/// What a child of a [RenderFlow] carries: the transform it was last painted
/// with.
final class FlowParentData extends BoxParentData {
  Transform2D? _transform;

  /// The transform this child was painted with in the last paint, from the
  /// child's coordinates into the flow's; null when the delegate did not
  /// paint it. Read by hit testing, and exposed for a test or an inspector
  /// that wants to know where a child went.
  Transform2D? get transform => _transform;

  @override
  String toString() => 'FlowParentData(transform: $_transform)';
}

/// What [FlowDelegate.paintChildren] paints through.
///
/// Valid only for the duration of that call: the context holds the display
/// list of the paint in progress, and a delegate that kept it and painted
/// later would be drawing into a frame that has already been submitted.
abstract interface class FlowPaintingContext {
  /// The flow's size, fixed by layout before painting began.
  Size get size;

  /// How many children the flow has; valid indices are `0..childCount - 1`.
  int get childCount;

  /// The size child [i] was laid out at, or null when there is no such child
  /// - so a delegate can ask without checking [childCount] first.
  Size? getChildSize(int i);

  /// Paints child [i] with [transform], at [opacity].
  ///
  /// [transform] maps the child's own coordinates into the flow's: a
  /// `Transform2D.translation(40, 0)` puts the child's top left corner 40
  /// pixels right of the flow's. A 2D affine matrix, not Flutter's `Matrix4`;
  /// see the library comment for why.
  ///
  /// Each call stacks the child above everything painted before it in this
  /// pass, and each child may be painted once per pass - a second call throws,
  /// as Flutter's assert does, because two copies of one child would leave
  /// hit testing to guess which copy the pointer meant.
  ///
  /// At an [opacity] of 0 nothing is drawn, but the child still counts as
  /// painted and still takes the pointer - Flutter's rule, and the one
  /// [RenderOpacity] follows here, so that a fading item does not stop being
  /// clickable partway through the fade. A delegate that wants it gone leaves
  /// it out instead.
  void paintChild(
    int i, {
    Transform2D transform = Transform2D.identity,
    double opacity = 1.0,
  });
}

/// Decides how big a [RenderFlow] is, how its children are laid out, and
/// where - and in what order - each is painted.
///
/// Subclass it and implement [paintChildren] and [shouldRepaint]. Pass the
/// animation that moves the children as [repaint], and read its value in
/// [paintChildren]: the flow then repaints on every tick without being laid
/// out again, which is what makes a flow cheap to animate.
abstract class FlowDelegate {
  const FlowDelegate({Listenable? repaint}) : _repaint = repaint;

  final Listenable? _repaint;

  /// The flow's size under [constraints]; the result is constrained again by
  /// the caller.
  ///
  /// The default fills the constraints - but, unlike Flutter's
  /// `constraints.biggest`, falls back to the minimum on an unbounded axis,
  /// which is what [MultiChildLayoutDelegate.getSize] does here too. An
  /// infinite size cannot be clipped, painted or hit tested, and a flow in a
  /// scrolling column would otherwise be one.
  Size getSize(BoxConstraints constraints) => constraints.largestFinite;

  /// The constraints child [i] is laid out under, given the flow's own
  /// [constraints]. The default passes them through unchanged.
  BoxConstraints getConstraintsForChild(int i, BoxConstraints constraints) =>
      constraints;

  /// Paints the children, in the order they should stack, through
  /// [context].
  ///
  /// Children not painted here are not on screen and cannot be hit. Read the
  /// animation here rather than in [getSize] or [getConstraintsForChild]:
  /// only this method runs again when [repaint] fires.
  void paintChildren(FlowPaintingContext context);

  /// Whether a new delegate needs layout run again. Defaults to false: a
  /// delegate that only moves children changes paint, not geometry.
  bool shouldRelayout(covariant FlowDelegate oldDelegate) => false;

  /// Whether a new delegate paints differently from [oldDelegate].
  bool shouldRepaint(covariant FlowDelegate oldDelegate);

  @override
  String toString() => '$runtimeType';
}

/// The context a [RenderFlow] hands its delegate.
///
/// A separate object rather than the render object itself, as it is in
/// Flutter, for two reasons: [RenderBox.paintChild] already exists here with a
/// different meaning, and a delegate holding the render object could reach
/// layout from paint.
final class _FlowPaintingContext implements FlowPaintingContext {
  _FlowPaintingContext(this._flow);

  final RenderFlow _flow;
  DisplayList? _list;
  Offset _offset = Offset.zero;

  @override
  Size get size => _flow.size;

  @override
  int get childCount => _flow.childCount;

  @override
  Size? getChildSize(int i) {
    if (i < 0 || i >= _flow.childCount) return null;
    return _flow.childAt(i).size;
  }

  @override
  void paintChild(
    int i, {
    Transform2D transform = Transform2D.identity,
    double opacity = 1.0,
  }) {
    final DisplayList? list = _list;
    if (list == null) {
      throw StateError(
        'FlowPaintingContext.paintChild was called outside '
        'FlowDelegate.paintChildren; the context is only valid during it',
      );
    }
    _flow._paintChildAt(list, _offset, i, transform, opacity);
  }
}

/// Lays its children out with a [FlowDelegate] and paints each wherever, in
/// whatever order and at whatever opacity the delegate says.
///
/// Always clips to its own box, which is Flutter's default for a flow
/// (`Clip.hardEdge`); this framework has no `Clip` enum to make it optional.
/// The clip is also what makes the bounds check in [RenderBox.hitTest] honest:
/// nothing outside the box is visible, so nothing outside it is hit.
final class RenderFlow extends RenderBoxContainer<FlowParentData> {
  RenderFlow({required FlowDelegate delegate}) : _delegate = delegate {
    _context = _FlowPaintingContext(this);
  }

  late final _FlowPaintingContext _context;

  /// The children the last paint painted, bottom first.
  ///
  /// Nodes rather than indices, unlike Flutter: an index outlives a removal
  /// that shifts the list under it, and would then hit test one child at the
  /// stacking position of another.
  final List<RenderBox> _lastPaintOrder = <RenderBox>[];

  FlowDelegate get delegate => _delegate;
  FlowDelegate _delegate;

  set delegate(FlowDelegate value) {
    if (identical(value, _delegate)) return;
    final FlowDelegate old = _delegate;
    _delegate = value;
    if (value.runtimeType != old.runtimeType || value.shouldRelayout(old)) {
      // Layout ends in a repaint, so this covers both.
      markNeedsLayout();
    } else if (value.shouldRepaint(old)) {
      markNeedsPaint();
    }
    if (owner != null) {
      old._repaint?.removeListener(markNeedsPaint);
      value._repaint?.addListener(markNeedsPaint);
    }
  }

  /// The indices of the children the last paint painted, bottom first.
  ///
  /// Exposed because "which children are on screen, and which is on top" is
  /// what a test of a delegate wants to assert, and the display list only
  /// answers it indirectly.
  /// A child removed since that paint is left out.
  List<int> get lastPaintOrder => List<int>.unmodifiable(<int>[
        for (final RenderBox child in _lastPaintOrder)
          if (identical(child.parent, this)) children.indexOf(child),
      ]);

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! FlowParentData) {
      child.parentData = FlowParentData();
    }
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _delegate._repaint?.addListener(markNeedsPaint);
  }

  @override
  void detach() {
    _delegate._repaint?.removeListener(markNeedsPaint);
    super.detach();
  }

  // --- layout -------------------------------------------------------------

  Size _sizeFor(BoxConstraints constraints) =>
      constraints.constrain(_delegate.getSize(constraints));

  @override
  void performLayout() {
    final BoxConstraints constraints = this.constraints;
    size = _sizeFor(constraints);
    for (int i = 0; i < childCount; i++) {
      final RenderBox child = childAt(i);
      // parentUsesSize: the delegate may read the size in paint, through
      // getChildSize, and a child relayout that stopped at the child would
      // leave it reading a size from a frame ago.
      child.layout(
        _delegate.getConstraintsForChild(i, constraints),
        parentUsesSize: true,
      );
      child.parentData!.offset = Offset.zero;
    }
  }

  // The intrinsics are what getSize says under the one axis fixed, as in
  // Flutter: a flow's size never depends on its children, so there is nothing
  // else to ask.

  double _finiteOrZero(double value) => value.isFinite ? value : 0.0;

  static BoxConstraints _tightHeight(double height) => height.isFinite
      ? BoxConstraints(minHeight: height, maxHeight: height)
      : BoxConstraints();

  static BoxConstraints _tightWidth(double width) => width.isFinite
      ? BoxConstraints(minWidth: width, maxWidth: width)
      : BoxConstraints();

  @override
  double computeMinIntrinsicWidth(double height) =>
      _finiteOrZero(_sizeFor(_tightHeight(height)).width);

  @override
  double computeMaxIntrinsicWidth(double height) =>
      _finiteOrZero(_sizeFor(_tightHeight(height)).width);

  @override
  double computeMinIntrinsicHeight(double width) =>
      _finiteOrZero(_sizeFor(_tightWidth(width)).height);

  @override
  double computeMaxIntrinsicHeight(double width) =>
      _finiteOrZero(_sizeFor(_tightWidth(width)).height);

  /// None: children are not at their layout offsets, so the inherited
  /// "first child's baseline" would name a line that is not where the text
  /// is. Flutter's flow has no baseline either.
  @override
  double? computeDistanceToActualBaseline(TextBaseline baseline) => null;

  // --- paint --------------------------------------------------------------

  @override
  void paint(DisplayList list, Offset offset) {
    // Forgotten before anything else, including the empty case: a child the
    // delegate stops painting must stop being hittable on this frame, not on
    // the next one that happens to paint something.
    _lastPaintOrder.clear();
    for (int i = 0; i < childCount; i++) {
      (childAt(i).parentData! as FlowParentData)._transform = null;
    }
    final Size size = this.size;
    if (size.isEmpty) return;

    list
      ..save()
      ..clipRectangle(
        Rect.fromLTWH(offset.dx, offset.dy, size.width, size.height),
      );
    _context
      .._list = list
      .._offset = offset;
    try {
      _delegate.paintChildren(_context);
    } finally {
      _context._list = null;
      list.restore();
    }
  }

  void _paintChildAt(
    DisplayList list,
    Offset offset,
    int i,
    Transform2D transform,
    double opacity,
  ) {
    if (i < 0 || i >= childCount) {
      throw RangeError.range(i, 0, childCount - 1, 'i');
    }
    if (!(opacity >= 0.0 && opacity <= 1.0)) {
      throw ArgumentError.value(opacity, 'opacity', 'must be in 0..1');
    }
    final RenderBox child = childAt(i);
    final FlowParentData parentData = child.parentData! as FlowParentData;
    if (parentData._transform != null) {
      throw StateError(
        'FlowDelegate.paintChildren painted child $i twice; each child may '
        'be painted once per pass',
      );
    }
    // Recorded before anything can return early: an invisible or collapsed
    // child was still painted as far as the delegate is concerned, and hit
    // testing decides for itself what a singular matrix can be hit at
    // (nothing).
    parentData._transform = transform;
    _lastPaintOrder.add(child);

    // The same quantisation RenderOpacity uses, so a flow child and an
    // Opacity at the same value composite to the same pixels.
    final int alpha = (opacity * 255).round().clamp(0, 255);
    if (alpha == 0) return;

    final bool translationOnly = transform.isTranslationOnly;
    if (!translationOnly) {
      final double determinant = transform.determinant;
      // Collapsed onto a line or a point: nothing to see, and a degenerate
      // matrix is not something to hand a rasterizer.
      if (determinant == 0 || !determinant.isFinite) return;
    }

    // A translation is an offset, and an offset costs no save/restore pair -
    // the common case, since most flows only slide their children. Anything
    // else is conjugated by the flow's own offset, as RenderTransform does:
    // the display list concatenates in frame space, and `transform` is about
    // the flow's origin.
    final Offset childOffset = translationOnly
        ? Offset(offset.dx + transform.tx, offset.dy + transform.ty)
        : offset;
    if (!translationOnly) {
      list
        ..save()
        ..transform2D(
          Transform2D.translation(offset.dx, offset.dy)
              .multiply(transform)
              .multiply(Transform2D.translation(-offset.dx, -offset.dy)),
        );
    }
    if (alpha == 255) {
      paintChild(list, child, childOffset);
    } else {
      // White with the layer's alpha, as in RenderOpacity: only the alpha of
      // the paint is read when the layer is composited back. The layer is in
      // the transformed space, so its bounds are the child's own box.
      final Size childSize = child.size;
      final int paintId = list.addPaint(colorArgb: (alpha << 24) | 0x00FFFFFF);
      list.saveLayer(
        childOffset.dx,
        childOffset.dy,
        childOffset.dx + childSize.width,
        childOffset.dy + childSize.height,
        paintId,
      );
      paintChild(list, child, childOffset);
      list.restore();
    }
    if (!translationOnly) list.restore();
  }

  // --- hit testing ----------------------------------------------------------

  @override
  RenderBox? hitTestChildren(Offset position, {HitTestPath? path}) {
    // Topmost first: the last child painted is the one on top. Only children
    // the last paint painted are candidates, each through the inverse of the
    // transform it was painted with.
    for (int k = _lastPaintOrder.length - 1; k >= 0; k--) {
      final RenderBox child = _lastPaintOrder[k];
      // A child removed since the last paint; the next paint forgets it.
      if (!identical(child.parent, this)) continue;
      final Transform2D? transform =
          (child.parentData! as FlowParentData)._transform;
      if (transform == null) continue;
      final Transform2D? inverse = transform.invert();
      if (inverse == null) continue;
      final RenderBox? hit =
          child.hitTest(inverse.transformOffset(position), path: path);
      if (hit != null) return hit;
    }
    return null;
  }
}
