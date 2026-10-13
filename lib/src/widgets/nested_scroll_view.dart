/// `NestedScrollView`: collapsing headers over a body that scrolls on its own.
///
/// A [CustomScrollView] can put a shrinking header above a list, but only when
/// the list is a sliver of the same scroll. A body that is its own scrollable -
/// a `ListView`, a tab of lists, a `CustomScrollView` of its own - is a
/// second position, and plain scroll chaining moves the wrong one first: the
/// list under the cursor takes the wheel, and the header collapses only once
/// the list has hit its end.
///
/// ## One gesture, two positions
///
/// A [NestedScrollView] is an outer [CustomScrollView] of the header slivers
/// followed by the body, sized to fill the viewport. Both the outer position
/// and every inner one get the view's coordinator as their
/// [ScrollPosition.coordinator], so a user delta given to either - wheel,
/// drag, momentum, the keys, paging - is distributed as Flutter does it:
///
///   * towards the end (content moving up): the outer position first, until
///     the headers have collapsed; then the inner;
///   * towards the start: the inner first, back to its top; then the outer,
///     which expands the headers. With [NestedScrollView.floatHeaderSlivers]
///     the outer goes first in this direction too, so a floating header comes
///     back as soon as the user scrolls up from anywhere in the body.
///
/// The body's scrollable is found physically: every scrollable offers its
/// position to the nearest enclosing [NestedScrollHost] when it joins the
/// render tree (see `scroll_view.dart`), and the body is one. The inner list
/// therefore needs no controller and no knowledge that it is nested.
///
/// ## Differences from Flutter
///
///   * `axis:` rather than `scrollDirection:`, and a [ScrollPosition] as the
///     controller - the outer one, as in Flutter;
///   * no `SliverOverlapAbsorber` / `SliverOverlapInjector` and no
///     `sliverOverlapAbsorberHandleFor`. Flutter sizes the body to the whole
///     viewport, so a pinned header covers the top of the inner list and the
///     absorber/injector pair exists to push the list down by that much. Here
///     the body is sized to the viewport **minus the minimum extent of every
///     pinned [SliverPersistentHeader]** before it, and sits just under the
///     pinned headers once they have collapsed - nothing overlaps, so there is
///     nothing to absorb. A pinned header wrapped in another sliver (a
///     `SliverPadding`) is not seen by that sum;
///   * deltas reach every inner position and the outer one, but there is no
///     "ballistic" hand-off of a fling between them beyond what the
///     coordinated deltas already give: a fling runs on the position that was
///     dragged and each of its steps is distributed like any other delta;
///   * a scrollbar is not drawn for the outer view; the body's own scrollable
///     draws its own.
library;

import 'dart:math' as math;

import '../layout/render_box.dart';
import '../layout/render_sliver.dart';
import '../layout/render_viewport.dart';
import '../scheduler/ui_dispatcher.dart';
import 'element.dart';
import 'scroll_view.dart';
import 'scrollbar.dart';
import 'slivers.dart';
import 'widget.dart';

/// Builds the header slivers of a [NestedScrollView].
///
/// [innerBoxIsScrolled] is true while the body's scrollable is scrolled away
/// from its start - the usual reason to give a header a shadow.
typedef NestedScrollViewHeaderSliversBuilder = List<Widget> Function(
  BuildContext context,
  bool innerBoxIsScrolled,
);

/// A scroll view whose header slivers collapse before its body scrolls.
///
/// ```dart
/// NestedScrollView(
///   headerSliverBuilder: (BuildContext context, bool innerBoxIsScrolled) =>
///       <Widget>[
///         SliverPersistentHeader(pinned: true, delegate: MyAppBar()),
///       ],
///   body: ListView.builder(
///     itemCount: 1000,
///     itemExtent: 40,
///     itemBuilder: (BuildContext context, int index) => Text('Row $index'),
///   ),
/// )
/// ```
///
/// See the library comment for how the two positions are coordinated and how
/// this differs from Flutter's widget.
final class NestedScrollView extends StatefulWidget {
  const NestedScrollView({
    super.key,
    this.controller,
    this.axis = ScrollAxis.vertical,
    required this.headerSliverBuilder,
    required this.body,
    this.floatHeaderSlivers = false,
    this.dragEnabled = true,
    this.mouseDragEnabled = true,
    this.dispatcher,
  });

  /// The **outer** position: how far the headers have scrolled. One is
  /// created when this is null; a caller's own wins over [axis].
  final ScrollPosition? controller;

  final ScrollAxis axis;

  /// The header slivers, rebuilt whenever `innerBoxIsScrolled` flips.
  final NestedScrollViewHeaderSliversBuilder headerSliverBuilder;

  /// The body. Normally a scrollable (`ListView`, `CustomScrollView`) on the
  /// same [axis]; it is laid out to fill the viewport below the pinned
  /// headers.
  final Widget body;

  /// Whether scrolling towards the start moves the headers back into view
  /// before the body scrolls, for a floating header.
  final bool floatHeaderSlivers;

  /// Whether a drag over the headers scrolls. The body's scrollable decides
  /// for itself.
  final bool dragEnabled;
  final bool mouseDragEnabled;

  /// Where momentum of a drag over the headers is stepped; see
  /// `Scrollable.dispatcher`.
  final UiDispatcher? dispatcher;

  @override
  State<NestedScrollView> createState() => _NestedScrollViewState();
}

final class _NestedScrollViewState extends State<NestedScrollView> {
  late final ScrollPosition _outer =
      widget.controller ?? ScrollPosition(axis: widget.axis);
  late final NestedScrollCoordinator _coordinator = NestedScrollCoordinator(
    outer: _outer,
    floatHeaderSlivers: widget.floatHeaderSlivers,
    onInnerScrolledChanged: _onInnerScrolledChanged,
  );

  @override
  void initState() {
    super.initState();
    _outer.coordinator = _coordinator;
  }

  @override
  void didUpdateWidget(NestedScrollView oldWidget) {
    super.didUpdateWidget(oldWidget);
    _coordinator.floatHeaderSlivers = widget.floatHeaderSlivers;
  }

  @override
  void dispose() {
    if (identical(_outer.coordinator, _coordinator)) _outer.coordinator = null;
    _coordinator.dispose();
    super.dispose();
  }

  void _onInnerScrolledChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) => CustomScrollView(
        controller: _outer,
        scrollbar: ScrollbarVisibility.never,
        dragEnabled: widget.dragEnabled,
        mouseDragEnabled: widget.mouseDragEnabled,
        dispatcher: widget.dispatcher,
        slivers: <Widget>[
          ...widget.headerSliverBuilder(
            context,
            _coordinator.innerBoxIsScrolled,
          ),
          _NestedScrollBody(coordinator: _coordinator, child: widget.body),
        ],
      );
}

/// Shares user deltas between a [NestedScrollView]'s outer position and the
/// positions of the scrollables in its body.
///
/// Public so a test, or a widget that drives the view programmatically, can
/// name it; a [NestedScrollView] creates and owns one.
final class NestedScrollCoordinator implements ScrollDeltaCoordinator {
  NestedScrollCoordinator({
    required this.outer,
    this.floatHeaderSlivers = false,
    this.onInnerScrolledChanged,
  });

  /// The position of the header scroll.
  final ScrollPosition outer;

  /// Whether a delta towards the start goes to [outer] first.
  bool floatHeaderSlivers;

  /// Called when [innerBoxIsScrolled] flips.
  final void Function()? onInnerScrolledChanged;

  final List<ScrollPosition> _inner = <ScrollPosition>[];
  bool _innerBoxIsScrolled = false;

  /// The positions of the body's scrollables, in the order they joined.
  List<ScrollPosition> get innerPositions =>
      List<ScrollPosition>.unmodifiable(_inner);

  /// Whether any inner position is scrolled away from its start.
  bool get innerBoxIsScrolled => _innerBoxIsScrolled;

  /// Starts coordinating [position]. Ignored for another axis than [outer]'s.
  void attachInner(ScrollPosition position) {
    if (position.axis != outer.axis || _inner.contains(position)) return;
    _inner.add(position);
    position
      ..coordinator = this
      ..addListener(_onInnerChanged);
    // Recorded, not announced: this runs while the body is being attached,
    // which is the middle of a build. The next scroll reports a flip.
    _innerBoxIsScrolled = _computeInnerBoxIsScrolled();
  }

  /// Stops coordinating [position].
  void detachInner(ScrollPosition position) {
    if (!_inner.remove(position)) return;
    position.removeListener(_onInnerChanged);
    if (identical(position.coordinator, this)) position.coordinator = null;
    _innerBoxIsScrolled = _computeInnerBoxIsScrolled();
  }

  /// Releases every inner position.
  void dispose() {
    for (final ScrollPosition position in List<ScrollPosition>.of(_inner)) {
      detachInner(position);
    }
  }

  bool _computeInnerBoxIsScrolled() {
    for (final ScrollPosition position in _inner) {
      if (position.pixels > 0) return true;
    }
    return false;
  }

  void _onInnerChanged(ScrollPosition position) {
    final bool scrolled = _computeInnerBoxIsScrolled();
    if (scrolled == _innerBoxIsScrolled) return;
    _innerBoxIsScrolled = scrolled;
    onInnerScrolledChanged?.call();
  }

  @override
  double applyUserDelta(
    ScrollPosition source,
    double delta, {
    bool allowOverscroll = false,
  }) {
    if (delta == 0) return 0;
    if (_inner.isEmpty) {
      return outer.applyOwnDelta(delta, allowOverscroll: allowOverscroll);
    }
    if (delta > 0) {
      // Towards the end: collapse the headers, then scroll the body.
      final double rest = outer.applyOwnDelta(delta);
      return _applyToInner(rest, allowOverscroll: allowOverscroll);
    }
    // Towards the start: the body back to its top, then the headers out -
    // or, for floating headers, the headers first.
    double rest = delta;
    if (floatHeaderSlivers) rest = outer.applyOwnDelta(rest);
    rest = _applyToInner(rest, allowOverscroll: false);
    return outer.applyOwnDelta(rest, allowOverscroll: allowOverscroll);
  }

  /// Gives [delta] to every inner position and returns the largest
  /// remainder, which is what none of them could use.
  double _applyToInner(double delta, {required bool allowOverscroll}) {
    if (delta == 0) return 0;
    double remainder = 0;
    for (final ScrollPosition position in List<ScrollPosition>.of(_inner)) {
      final double left =
          position.applyOwnDelta(delta, allowOverscroll: allowOverscroll);
      if (left.abs() > remainder.abs()) remainder = left;
    }
    return remainder;
  }
}

/// The body sliver: one box, as tall as the viewport less the pinned headers.
final class _NestedScrollBody extends SingleChildRenderObjectWidget {
  const _NestedScrollBody({required this.coordinator, required super.child});

  final NestedScrollCoordinator coordinator;

  @override
  RenderNestedScrollBody createRenderObject(BuildContext context) =>
      RenderNestedScrollBody(coordinator: coordinator);

  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderNestedScrollBody renderObject,
  ) {
    renderObject.coordinator = coordinator;
  }
}

/// The last sliver of a [NestedScrollView]'s outer viewport.
///
/// Its extent is the viewport's, less the minimum extent of every pinned
/// [RenderSliverPersistentHeader] before it, and it does not change with the
/// scroll offset - a body whose height followed the headers would relayout
/// the inner list on every step of the collapse and move the outer position's
/// maximum while it was being scrolled. With the headers collapsed, it sits
/// exactly between the pinned headers and the trailing edge.
///
/// It is also the [NestedScrollHost] the inner scrollables find.
final class RenderNestedScrollBody extends RenderSingleChildBox
    with RenderSliver
    implements NestedScrollHost {
  RenderNestedScrollBody({
    required NestedScrollCoordinator coordinator,
    super.child,
  }) : _coordinator = coordinator;

  NestedScrollCoordinator _coordinator;

  NestedScrollCoordinator get coordinator => _coordinator;

  set coordinator(NestedScrollCoordinator value) {
    if (identical(value, _coordinator)) return;
    final List<ScrollPosition> moved = _coordinator.innerPositions;
    for (final ScrollPosition position in moved) {
      _coordinator.detachInner(position);
    }
    _coordinator = value;
    moved.forEach(value.attachInner);
  }

  @override
  void attachInnerPosition(ScrollPosition position) =>
      _coordinator.attachInner(position);

  @override
  void detachInnerPosition(ScrollPosition position) =>
      _coordinator.detachInner(position);

  /// What the pinned headers before this sliver keep painting once collapsed.
  double get pinnedExtent {
    final RenderBox? parent = this.parent;
    if (parent is! RenderSliverViewport) return 0;
    double extent = 0;
    for (final RenderSliver sliver in parent.slivers) {
      if (identical(sliver, this)) break;
      if (sliver is RenderSliverPersistentHeader && sliver.pinned) {
        extent += sliver.minExtent;
      }
    }
    return extent;
  }

  @override
  SliverGeometry performSliverLayout() {
    final SliverConstraints constraints = sliverConstraints;
    final double extent =
        math.max(0.0, constraints.viewportMainAxisExtent - pinnedExtent);
    final RenderBox? child = this.child;
    child?.layout(
      constraints.asBoxConstraints(minExtent: extent, maxExtent: extent),
      parentUsesSize: true,
    );
    final double paintExtent = calculatePaintOffset(from: 0, to: extent);
    if (child != null) {
      child.parentData!.offset = childBoxOffset(
        mainAxisPosition: -constraints.scrollOffset,
        childMainAxisExtent: extent,
        paintExtent: paintExtent,
      );
    }
    return SliverGeometry(
      scrollExtent: extent,
      paintExtent: paintExtent,
      maxPaintExtent: extent,
      cacheExtent: calculateCacheOffset(from: 0, to: extent),
      hasVisualOverflow: extent > constraints.remainingPaintExtent ||
          constraints.scrollOffset > 0,
    );
  }
}
