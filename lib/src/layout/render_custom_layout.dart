/// Children placed by a delegate the application writes - Flutter's
/// `RenderCustomMultiChildLayoutBox` and `MultiChildLayoutDelegate`.
///
/// For a layout no stock widget expresses: a chart whose legend goes
/// wherever the plot leaves room, a toolbar that drops items into an
/// overflow, a header whose title is centred on the window and not on the
/// space between its buttons. The delegate sees the children by the id each
/// one was given, lays each out with constraints it chooses, and puts it
/// where it wants.
library;

import '../geometry/offset.dart';
import '../geometry/size.dart';
import 'box_constraints.dart';
import 'render_box.dart';

/// What a child of a [RenderCustomMultiChildLayoutBox] carries: its id.
final class MultiChildLayoutParentData extends BoxParentData {
  Object? id;

  @override
  String toString() => 'MultiChildLayoutParentData(offset: $offset, id: $id)';
}

/// Lays out the children of a custom multi-child layout.
///
/// Subclass it, implement [performLayout], and in it call [layoutChild] then
/// [positionChild] for each child id - every child exactly once each, which
/// is checked: a child left unlaid would paint at a stale size, and one laid
/// out twice is a delegate measuring by trial and error.
abstract class MultiChildLayoutDelegate {
  MultiChildLayoutDelegate();

  /// The size of the whole layout. The default fills the constraints, as
  /// Flutter's does; a delegate whose size depends on its children cannot
  /// say so here, because children are laid out after.
  Size getSize(BoxConstraints constraints) => constraints.largestFinite;

  /// Lays out and positions the children in a layout [size] large.
  void performLayout(Size size);

  /// Whether a new delegate lays out differently from [oldDelegate].
  bool shouldRelayout(covariant MultiChildLayoutDelegate oldDelegate);

  Map<Object, RenderBox>? _children;
  Set<Object>? _laidOut;

  /// Whether a child with [childId] is present.
  bool hasChild(Object childId) => _children?.containsKey(childId) ?? false;

  /// Lays out the child [childId] and returns its size.
  Size layoutChild(Object childId, BoxConstraints constraints) {
    final RenderBox? child = _children?[childId];
    if (child == null) {
      throw StateError('no child with id $childId; ask hasChild first');
    }
    if (!_laidOut!.add(childId)) {
      throw StateError('child $childId was laid out twice');
    }
    child.layout(constraints, parentUsesSize: true);
    return child.size;
  }

  /// Puts the child [childId] at [offset], from the layout's top left.
  void positionChild(Object childId, Offset offset) {
    final RenderBox? child = _children?[childId];
    if (child == null) {
      throw StateError('no child with id $childId; ask hasChild first');
    }
    child.parentData!.offset = offset;
  }

  void _run(Map<Object, RenderBox> children, Size size) {
    _children = children;
    _laidOut = <Object>{};
    try {
      performLayout(size);
      final Iterable<Object> missed =
          children.keys.where((Object id) => !_laidOut!.contains(id));
      if (missed.isNotEmpty) {
        throw StateError('the delegate did not lay out ${missed.join(', ')}');
      }
    } finally {
      _children = null;
      _laidOut = null;
    }
  }
}

/// Lays its children out with a [MultiChildLayoutDelegate].
final class RenderCustomMultiChildLayoutBox
    extends RenderBoxContainer<MultiChildLayoutParentData> {
  RenderCustomMultiChildLayoutBox({required MultiChildLayoutDelegate delegate})
      : _delegate = delegate;

  MultiChildLayoutDelegate get delegate => _delegate;
  MultiChildLayoutDelegate _delegate;

  set delegate(MultiChildLayoutDelegate value) {
    if (identical(value, _delegate)) return;
    final MultiChildLayoutDelegate old = _delegate;
    _delegate = value;
    if (value.runtimeType != old.runtimeType || value.shouldRelayout(old)) {
      markNeedsLayout();
    }
  }

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! MultiChildLayoutParentData) {
      child.parentData = MultiChildLayoutParentData();
    }
  }

  @override
  void performLayout() {
    size = constraints.constrain(_delegate.getSize(constraints));
    final Map<Object, RenderBox> children = <Object, RenderBox>{};
    for (int i = 0; i < childCount; i++) {
      final RenderBox child = childAt(i);
      final Object? id = (child.parentData! as MultiChildLayoutParentData).id;
      if (id == null) {
        throw StateError('every child of a CustomMultiChildLayout needs a '
            'LayoutId; child $i has none');
      }
      if (children.containsKey(id)) {
        throw StateError('two children share the LayoutId $id');
      }
      children[id] = child;
    }
    _delegate._run(children, size);
  }
}
