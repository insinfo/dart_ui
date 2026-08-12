/// The render tree: layout, painting and hit testing.
///
/// This is tree number three of the four in section 8.1 of the roadmap. It is
/// the layer that owns *geometry*. It knows nothing about widgets, state or
/// reconciliation - those live above it and rebuild this tree; it knows
/// nothing about pixels either, because painting here means appending to a
/// [DisplayList] that some backend rasterises later.
///
/// Three rules hold the whole thing together:
///
///   1. **Constraints go down, sizes come up, the parent sets position.** A
///      child is never consulted about how big it should be; it is told what
///      range is acceptable and answers with one size. That is what makes
///      layout a single top-down walk.
///   2. **A node may only read the size of a child it laid out with
///      `parentUsesSize: true`.** See [RenderBox.size] for what happens
///      otherwise and why the check exists.
///   3. **Dirt propagates up only as far as a relayout boundary.** See
///      [RenderBox.markNeedsLayout] - that comment is the most important one
///      in this file.
library;

import 'dart:collection';

import 'package:meta/meta.dart';

import '../geometry/offset.dart';
import '../geometry/rect.dart';
import '../geometry/size.dart';
import '../graphics/display_list.dart';
import 'box_constraints.dart';
import 'pipeline.dart';

/// Bookkeeping a parent keeps about one of its children.
///
/// It lives on the child so that a parent with many children needs no side
/// table, but it belongs to the parent: only the parent writes it, and it is
/// discarded the moment the child is removed. Subclasses of this carry
/// per-child layout inputs - a flex factor, a stack position - which is why
/// this class is open for extension while almost everything else here is not.
class BoxParentData {
  /// Where the child's origin sits in the parent's coordinate space.
  Offset offset = Offset.zero;

  @override
  String toString() => 'BoxParentData(offset: $offset)';
}

/// The chain of nodes a hit passed through, deepest first.
///
/// Reusable on purpose. Section 6.5 lists hit testing among the routes that
/// must not allocate per event, so a dispatcher keeps one of these and calls
/// [reset] per pointer event instead of building a list each time.
final class HitTestPath {
  final List<RenderBox> _entries = <RenderBox>[];
  late final List<RenderBox> _view = UnmodifiableListView<RenderBox>(_entries);

  /// The nodes hit, deepest first - which is also the order a pointer event
  /// should be offered to them before it bubbles.
  List<RenderBox> get entries => _view;

  int get length => _entries.length;

  bool get isEmpty => _entries.isEmpty;

  RenderBox operator [](int index) => _entries[index];

  void add(RenderBox node) => _entries.add(node);

  void reset() => _entries.clear();

  @override
  String toString() =>
      'HitTestPath(${_entries.map((RenderBox e) => e.runtimeType).join(' <- ')})';
}

/// A node in the render tree that lays out under [BoxConstraints].
///
/// Subclasses implement [performLayout] and usually [paint]. Everything else
/// here is the protocol that keeps a tree of them consistent.
abstract class RenderBox {
  /// The node whose [performLayout] is currently running, or null outside
  /// layout.
  ///
  /// One static field, because layout is a single-threaded depth-first walk
  /// and there is exactly one such node at a time. It exists so that
  /// [size] can tell "the owner reading its own size" from "a parent reading
  /// a child's size it was not entitled to". Dart cannot inspect its caller,
  /// and this is cheaper than the alternative of passing a witness object
  /// through every layout call.
  static RenderBox? _nodeInLayout;

  RenderBox? _parent;
  PipelineOwner? _owner;
  int _depth = 0;

  BoxConstraints? _constraints;
  Size? _size;
  RenderBox? _relayoutBoundary;
  bool _parentUsesSize = false;
  bool _needsLayout = true;
  bool _needsPaint = true;

  /// Written by the parent when it adopts this node, read by the parent when
  /// it positions and paints it. Null exactly when this node has no parent.
  BoxParentData? parentData;

  RenderBox? get parent => _parent;

  PipelineOwner? get owner => _owner;

  /// Distance from the root. Used only to order the dirty list, so that an
  /// ancestor relayouts before a descendant and the descendant's work is not
  /// done twice.
  int get depth => _depth;

  bool get needsLayout => _needsLayout;

  bool get needsPaint => _needsPaint;

  bool get hasSize => _size != null;

  /// The node that a [markNeedsLayout] from here walks up to and stops at.
  /// Null until this node has been laid out once.
  RenderBox? get relayoutBoundary => _relayoutBoundary;

  bool get isRelayoutBoundary => identical(_relayoutBoundary, this);

  /// Where this node's origin sits in its parent's coordinate space.
  Offset get offsetFromParent => parentData?.offset ?? Offset.zero;

  /// The constraints the parent passed in the most recent [layout].
  BoxConstraints get constraints {
    final BoxConstraints? value = _constraints;
    if (value == null) {
      throw StateError(
        '$runtimeType has no constraints: layout() has not run on it yet. '
        'Reading constraints outside performLayout means reading whatever the '
        'previous frame left behind.',
      );
    }
    return value;
  }

  /// The size this node settled on.
  ///
  /// Throws when a parent reads it after laying this child out with
  /// `parentUsesSize: false`. That combination is not a style violation, it is
  /// a correctness one: `parentUsesSize: false` is the parent's promise that
  /// its own geometry does not depend on this child, and that promise is what
  /// makes this node a relayout boundary (see [markNeedsLayout]). If the
  /// parent then reads the size anyway, a later relayout of the child stops at
  /// the child - the parent is never re-run, and keeps whatever it computed
  /// from the *old* size. The result is a stale layout that looks correct on
  /// the frame it was introduced and wrong on some later frame, which is about
  /// the worst failure mode a layout system has. Throwing at the read costs
  /// one comparison against a null static field outside layout.
  Size get size {
    final Size? value = _size;
    if (value == null) {
      throw StateError(
        '$runtimeType has no size: layout() has not run on it yet.',
      );
    }
    final RenderBox? active = _nodeInLayout;
    if (active != null &&
        !identical(active, this) &&
        !_parentUsesSize &&
        identical(active, _parent)) {
      throw StateError(
        '${active.runtimeType} read the size of its $runtimeType child after '
        'laying it out with parentUsesSize: false. Either pass '
        'parentUsesSize: true - which gives up this child as a relayout '
        'boundary - or do not depend on the child size.',
      );
    }
    return value;
  }

  /// Set by [performLayout], and only by this node's own [performLayout].
  ///
  /// A parent that could write a child's size would make the size no longer a
  /// function of the constraints, and the caching above would be unsound.
  @protected
  set size(Size value) {
    if (!identical(_nodeInLayout, this)) {
      throw StateError(
        'size was assigned on $runtimeType outside its own performLayout. '
        'Only a node sizes itself; a parent positions.',
      );
    }
    _size = value;
  }

  /// This node's bounds in its own coordinate space.
  Rect get bounds => Rect.fromLTWH(0, 0, size.width, size.height);

  /// This node's origin in the root's coordinate space.
  ///
  /// Walks the parent chain accumulating offsets, so it is O(depth) and meant
  /// for input handling rather than for the paint loop, which already carries
  /// an offset down.
  ///
  /// Offsets only: there is no transform in this tree yet. When
  /// `RenderTransform` arrives this becomes a matrix walk, and every caller
  /// keeps working because none of them does the arithmetic itself.
  Offset get globalOffset {
    double dx = 0;
    double dy = 0;
    for (RenderBox? node = this; node != null; node = node._parent) {
      final Offset offset = node.offsetFromParent;
      dx += offset.dx;
      dy += offset.dy;
    }
    return Offset(dx, dy);
  }

  /// Converts a point in the root's space into this node's own space.
  ///
  /// Deliberately unclamped: a pointer that has been dragged off a slider is
  /// still meaningfully at "-40" on that slider's axis, and clamping here
  /// would throw away the information the control needs to keep tracking it.
  Offset globalToLocal(Offset position) {
    final Offset origin = globalOffset;
    return Offset(position.dx - origin.dx, position.dy - origin.dy);
  }

  /// Converts a point in this node's space into the root's space.
  Offset localToGlobal(Offset position) {
    final Offset origin = globalOffset;
    return Offset(position.dx + origin.dx, position.dy + origin.dy);
  }

  // -----------------------------------------------------------------------
  // Tree structure
  // -----------------------------------------------------------------------

  /// Calls [visitor] for each child, in paint order.
  ///
  /// The default is childless. Overriding this is what makes attach, detach,
  /// depth and relayout-boundary invalidation work for a new container, so it
  /// is the first thing a multi-child subclass must write.
  void visitChildren(void Function(RenderBox child) visitor) {}

  /// Takes ownership of [child].
  ///
  /// Refuses a node that is already in a tree. A node with two parents gets
  /// laid out twice with different constraints and painted at two positions,
  /// and the second parent silently wins - a shared subtree is the kind of bug
  /// that shows up as one of two identical panels being blank.
  @protected
  void adoptChild(RenderBox child) {
    if (identical(child, this)) {
      throw StateError('$runtimeType cannot be its own child.');
    }
    if (child._parent != null) {
      throw StateError(
        'a ${child.runtimeType} already has a parent '
        '(${child._parent.runtimeType}). Remove it from that tree before '
        'adding it to this one; a node in two trees is laid out twice and '
        'painted in one place.',
      );
    }
    for (RenderBox? ancestor = this;
        ancestor != null;
        ancestor = ancestor._parent) {
      if (identical(ancestor, child)) {
        throw StateError(
          'adding a ${child.runtimeType} to $runtimeType would make a cycle; '
          'it is already an ancestor.',
        );
      }
    }
    child._parent = this;
    setupParentData(child);
    redepthChild(child);
    final PipelineOwner? owner = _owner;
    if (owner != null) child.attach(owner);
    markNeedsLayout();
  }

  /// Gives up ownership of [child], which must currently be a child of this.
  @protected
  void dropChild(RenderBox child) {
    if (!identical(child._parent, this)) {
      throw StateError(
        'a ${child.runtimeType} was dropped by $runtimeType, which is not its '
        'parent.',
      );
    }
    child._parent = null;
    child.parentData = null;
    // The child's cached boundary named a node in the old tree. Leaving it
    // would let a later markNeedsLayout walk into a tree this node is no
    // longer part of.
    child._clearRelayoutBoundarySubtree();
    if (child._owner != null) child.detach();
    markNeedsLayout();
  }

  /// Installs the per-child record this node expects. Containers that need
  /// extra per-child inputs override this to install their own subclass.
  @protected
  void setupParentData(RenderBox child) {
    child.parentData ??= BoxParentData();
  }

  @protected
  void redepthChild(RenderBox child) {
    if (child._depth <= _depth) {
      child._depth = _depth + 1;
      child.visitChildren(child.redepthChild);
    }
  }

  /// Joins [owner]'s pipeline, along with the whole subtree.
  ///
  /// Any dirt accumulated while detached is re-announced here, because
  /// [markNeedsLayout] and [markNeedsPaint] are no-ops for a node that is
  /// already dirty and there was no owner to register with at the time.
  void attach(PipelineOwner owner) {
    final PipelineOwner? existing = _owner;
    if (existing != null && !identical(existing, owner)) {
      throw StateError(
        '$runtimeType is already attached to another PipelineOwner. A node '
        'belongs to one pipeline at a time.',
      );
    }
    _owner = owner;
    if (_needsLayout) {
      _needsLayout = false;
      markNeedsLayout();
    }
    if (_needsPaint) {
      _needsPaint = false;
      markNeedsPaint();
    }
    visitChildren((RenderBox child) => child.attach(owner));
  }

  void detach() {
    _owner = null;
    visitChildren((RenderBox child) => child.detach());
  }

  // -----------------------------------------------------------------------
  // Layout
  // -----------------------------------------------------------------------

  /// Lays this node out under [constraints].
  ///
  /// [parentUsesSize] is the caller's declaration about *itself*: true means
  /// the caller's own geometry is computed from this child's resulting size,
  /// so a change here must re-run the caller. False means it is not, and the
  /// caller keeps its promise by never reading [size] - which [size] enforces.
  ///
  /// Returns without calling [performLayout] when nothing that could change
  /// the answer has changed: same constraints, not dirty, same boundary. That
  /// early return is what makes a full top-down walk from the root cheap
  /// enough to be the fallback path.
  void layout(BoxConstraints constraints, {bool parentUsesSize = false}) {
    final RenderBox? parent = _parent;

    // --- the relayout boundary rule ---------------------------------------
    //
    // A relayout boundary is a node whose re-layout provably cannot change
    // anything above it, so dirt is allowed to stop there instead of walking
    // to the root. This node is one when either:
    //
    //   * the constraints are tight - exactly one size satisfies them, so
    //     however this subtree rearranges itself, the size it reports upward
    //     is the same size it reported last time; or
    //   * the parent passed parentUsesSize: false - it has declared that its
    //     own layout does not read this size, so even a different size cannot
    //     move it; or
    //   * there is no parent at all.
    //
    // Otherwise the boundary is inherited from the parent: a size change here
    // can move the parent, so the search for a stopping point continues from
    // where the parent stopped.
    //
    // The payoff is the point of the whole mechanism. Typing in a text field
    // deep inside a fixed-size panel dirties one node; without boundaries the
    // dirty mark reaches the root and every sibling panel in the window is
    // asked to lay out again. With them, the work is proportional to the
    // subtree that actually changed rather than to the size of the window.
    //
    // Deliberately not implemented: the fourth alternative Flutter allows,
    // `sizedByParent`
    // (a node whose size depends only on the constraints, computed in a
    // separate resize pass). It needs performLayout split into two methods on
    // every subclass to buy a boundary in cases that tight constraints already
    // cover most of. When a node appears that genuinely needs it - one that is
    // always as big as it is allowed to be under loose constraints - it can be
    // added here as one more disjunct without changing anything else.
    final RenderBox boundary;
    if (parent == null || !parentUsesSize || constraints.isTight) {
      boundary = this;
    } else {
      boundary = parent._relayoutBoundary ?? parent;
    }

    _parentUsesSize = parentUsesSize;
    if (!_needsLayout &&
        constraints == _constraints &&
        identical(boundary, _relayoutBoundary)) {
      return;
    }

    // A node whose boundary moved invalidates the cached boundaries below it:
    // they were computed by inheriting this one.
    if (_relayoutBoundary != null && !identical(boundary, _relayoutBoundary)) {
      visitChildren(_clearInheritedRelayoutBoundary);
    }
    _constraints = constraints;
    _relayoutBoundary = boundary;
    _runPerformLayout();
  }

  /// Re-runs layout with the constraints already stored.
  ///
  /// Only legal on a relayout boundary, which is exactly where the pipeline
  /// calls it: by definition nothing above it can have changed the
  /// constraints, so re-using them is not a guess.
  @internal
  void layoutWithoutResize() {
    if (_constraints == null) {
      throw StateError(
        '$runtimeType was asked to relayout before it was ever laid out.',
      );
    }
    if (!isRelayoutBoundary) {
      throw StateError(
        '$runtimeType is not a relayout boundary, so its constraints may have '
        'changed and cannot be reused.',
      );
    }
    _runPerformLayout();
  }

  void _runPerformLayout() {
    final RenderBox? previous = _nodeInLayout;
    _nodeInLayout = this;
    try {
      performLayout();
    } finally {
      _nodeInLayout = previous;
    }
    final Size? result = _size;
    if (result == null) {
      throw StateError(
        '$runtimeType.performLayout returned without assigning size. Every '
        'node must answer its parent with exactly one size.',
      );
    }
    // Checked here rather than trusted, because a node that quietly ignores
    // its constraints produces a parent whose own size is wrong, and the
    // report lands on the parent.
    if (!_constraints!.isSatisfiedBy(result)) {
      throw StateError(
        '$runtimeType sized itself $result, which does not satisfy '
        '${_constraints!}. A node must constrain the size it reports even '
        'when its children overflow it.',
      );
    }
    _needsLayout = false;
    markNeedsPaint();
  }

  /// Computes and assigns [size], and positions any children by writing their
  /// [BoxParentData.offset].
  ///
  /// Must lay out every child exactly once, and must assign [size] before
  /// returning.
  @protected
  void performLayout();

  /// Flags this node's layout as out of date.
  ///
  /// The mark travels up only as far as the nearest relayout boundary, which
  /// registers itself with the pipeline as a root of the next layout pass. See
  /// the long comment in [layout] for what makes that sound.
  void markNeedsLayout() {
    if (_needsLayout) return;
    _needsLayout = true;
    final RenderBox? boundary = _relayoutBoundary;
    if (boundary == null) {
      // Never laid out, so there is no boundary to trust yet. The first layout
      // pass will reach this node from above; all that is needed is that the
      // parent knows it has work to do.
      _parent?.markNeedsLayout();
      return;
    }
    if (!identical(boundary, this)) {
      // Not the boundary: the parent's geometry can depend on ours, so keep
      // walking. Each step repeats this test, so the walk stops at the first
      // node for which it does not hold.
      _parent!.markNeedsLayout();
      return;
    }
    _owner?.addNodeNeedingLayout(this);
  }

  static void _clearInheritedRelayoutBoundary(RenderBox child) {
    // A child that is its own boundary did not inherit anything, so its
    // subtree is unaffected and the walk can stop.
    if (child.isRelayoutBoundary) return;
    child._relayoutBoundary = null;
    child.visitChildren(_clearInheritedRelayoutBoundary);
  }

  void _clearRelayoutBoundarySubtree() {
    _relayoutBoundary = null;
    visitChildren((RenderBox child) => child._clearRelayoutBoundarySubtree());
  }

  // -----------------------------------------------------------------------
  // Paint
  // -----------------------------------------------------------------------

  /// Appends this node's drawing commands to [list], with this node's origin
  /// at [offset].
  ///
  /// [offset] is in the coordinate space of whoever is painting, so a node
  /// paints itself at `offset` and its children at `offset + child.offset`.
  /// The default draws nothing, which is right for the many nodes that only
  /// arrange others.
  void paint(DisplayList list, Offset offset) {}

  /// Paints [child] at this node's [offset] plus the child's own.
  @protected
  void paintChild(DisplayList list, RenderBox child, Offset offset) {
    final Offset childOffset = child.offsetFromParent;
    child.paint(
      list,
      Offset(offset.dx + childOffset.dx, offset.dy + childOffset.dy),
    );
  }

  /// Flags this node's drawing as out of date.
  ///
  /// Today this is coarse on purpose: there is no layer tree, so there is no
  /// repaint boundary to stop at and the pipeline re-walks the whole render
  /// tree into a fresh display list. That is honest for a tree that emits into
  /// an arena which is reset per frame anyway - the saving a repaint boundary
  /// buys only exists once retained layers exist to reuse. The dirty set is
  /// still recorded, because it is what a compositor will need and because it
  /// is how a caller can see that a mutation was noticed at all.
  void markNeedsPaint() {
    if (_needsPaint) return;
    _needsPaint = true;
    _owner?.addNodeNeedingPaint(this);
  }

  @internal
  void clearNeedsPaintSubtree() {
    _needsPaint = false;
    visitChildren((RenderBox child) => child.clearNeedsPaintSubtree());
  }

  // -----------------------------------------------------------------------
  // Hit testing
  // -----------------------------------------------------------------------

  /// The deepest node under [position], or null when nothing here is hit.
  ///
  /// [position] is in this node's own coordinate space. When [path] is given
  /// it is filled deepest-first with every node on the way back up, which is
  /// the order an event dispatcher wants; pass a reused instance, since
  /// section 6.5 lists hit testing among the routes that must not allocate per
  /// event.
  ///
  /// One [Offset] per visited node is still allocated by the descent below, to
  /// keep this signature readable. A scalar `hitTestAt(double, double)`
  /// overload removes even that and is the documented next step if pointer
  /// dispatch ever shows up in a profile; tree depth being what it is, this
  /// has not been worth the second API yet.
  RenderBox? hitTest(Offset position, {HitTestPath? path}) {
    if (!size.contains(position)) return null;
    final RenderBox? child = hitTestChildren(position, path: path);
    if (child != null) {
      path?.add(this);
      return child;
    }
    if (hitTestSelf(position)) {
      path?.add(this);
      return this;
    }
    return null;
  }

  /// Whether this node itself absorbs a hit at [position], already known to be
  /// inside [bounds].
  ///
  /// False by default: a node that paints nothing should not swallow an event
  /// that belongs to whatever is behind it. Nodes that fill their box - a
  /// coloured box, a button - override this.
  bool hitTestSelf(Offset position) => false;

  /// The deepest child hit, tested front to back so the topmost wins.
  RenderBox? hitTestChildren(Offset position, {HitTestPath? path}) => null;

  @override
  String toString() => '$runtimeType${_size == null ? '' : '#$_size'}';
}

/// A node with at most one child.
///
/// Holds the adoption bookkeeping that every wrapper (padding, alignment,
/// decoration) would otherwise repeat, and nothing else: [performLayout] is
/// still the subclass's problem, because that is where these differ.
abstract class RenderSingleChildBox extends RenderBox {
  RenderSingleChildBox({RenderBox? child}) {
    this.child = child;
  }

  RenderBox? _child;

  RenderBox? get child => _child;

  set child(RenderBox? value) {
    if (identical(value, _child)) return;
    final RenderBox? previous = _child;
    if (previous != null) {
      // Cleared first so that the markNeedsLayout inside dropChild does not
      // walk into a child that is halfway out of the tree.
      _child = null;
      dropChild(previous);
    }
    if (value != null) {
      adoptChild(value);
      _child = value;
    }
    markNeedsLayout();
  }

  @override
  void visitChildren(void Function(RenderBox child) visitor) {
    final RenderBox? child = _child;
    if (child != null) visitor(child);
  }

  @override
  void paint(DisplayList list, Offset offset) {
    final RenderBox? child = _child;
    if (child != null) paintChild(list, child, offset);
  }

  @override
  RenderBox? hitTestChildren(Offset position, {HitTestPath? path}) {
    final RenderBox? child = _child;
    if (child == null) return null;
    final Offset childOffset = child.offsetFromParent;
    return child.hitTest(
      Offset(position.dx - childOffset.dx, position.dy - childOffset.dy),
      path: path,
    );
  }
}

/// A node with an ordered list of children, painted first to last.
///
/// [T] is the per-child record type the subclass installs, so `childParentData`
/// hands back the flex factor or stack position without a cast at every use
/// site.
abstract class RenderBoxContainer<T extends BoxParentData> extends RenderBox {
  final List<RenderBox> _children = <RenderBox>[];
  late final List<RenderBox> _childrenView =
      UnmodifiableListView<RenderBox>(_children);

  /// The children in paint order. A view, not a copy - and not the list layout
  /// walks, which uses [childAt] to avoid allocating an iterator per frame.
  List<RenderBox> get children => _childrenView;

  int get childCount => _children.length;

  RenderBox childAt(int index) => _children[index];

  T childParentData(RenderBox child) => child.parentData! as T;

  void add(RenderBox child) => insert(child, index: _children.length);

  void insert(RenderBox child, {required int index}) {
    if (index < 0 || index > _children.length) {
      throw RangeError.range(index, 0, _children.length, 'index');
    }
    // Adopted first: it throws when the child already has a parent, and doing
    // that before the insert keeps the list untouched on failure.
    adoptChild(child);
    _children.insert(index, child);
  }

  void remove(RenderBox child) {
    if (!_children.remove(child)) {
      throw StateError('a ${child.runtimeType} is not a child of $runtimeType');
    }
    dropChild(child);
  }

  void removeAll() {
    while (_children.isNotEmpty) {
      dropChild(_children.removeLast());
    }
  }

  /// Permutes the existing children into [order].
  ///
  /// A permutation, not an assignment: [order] must contain exactly the
  /// current children. That restriction is what lets this skip the
  /// drop/adopt cycle - no parent link, parent data or attachment changes, so
  /// a widget list that merely reordered does not tear down and rebuild the
  /// render nodes it kept. A caller that got the set wrong is rejected here
  /// rather than silently orphaning a node.
  void reorderChildren(List<RenderBox> order) {
    if (order.length != _children.length) {
      throw StateError(
        'reorderChildren expects a permutation: got ${order.length} nodes for '
        '${_children.length} children of $runtimeType',
      );
    }
    bool sameOrder = true;
    for (int i = 0; i < order.length; i++) {
      if (!identical(order[i], _children[i])) {
        sameOrder = false;
        break;
      }
    }
    if (sameOrder) return;
    final Set<RenderBox> seen = Set<RenderBox>.identity();
    for (final RenderBox child in order) {
      if (!identical(child._parent, this)) {
        throw StateError(
          'reorderChildren was given a ${child.runtimeType} that is not a '
          'child of $runtimeType',
        );
      }
      if (!seen.add(child)) {
        // A repeated node would displace another one, which would then still
        // point at this parent while no longer being in the list.
        throw StateError(
          'reorderChildren was given the same ${child.runtimeType} twice',
        );
      }
    }
    _children
      ..clear()
      ..addAll(order);
    markNeedsLayout();
  }

  @override
  void visitChildren(void Function(RenderBox child) visitor) {
    for (int i = 0; i < _children.length; i++) {
      visitor(_children[i]);
    }
  }

  @override
  void paint(DisplayList list, Offset offset) {
    for (int i = 0; i < _children.length; i++) {
      paintChild(list, _children[i], offset);
    }
  }

  @override
  RenderBox? hitTestChildren(Offset position, {HitTestPath? path}) {
    // Back to front: the last child painted is the one on top, so it is the
    // one that gets the pointer.
    for (int i = _children.length - 1; i >= 0; i--) {
      final RenderBox child = _children[i];
      final Offset childOffset = child.offsetFromParent;
      final RenderBox? hit = child.hitTest(
        Offset(position.dx - childOffset.dx, position.dy - childOffset.dy),
        path: path,
      );
      if (hit != null) return hit;
    }
    return null;
  }
}
