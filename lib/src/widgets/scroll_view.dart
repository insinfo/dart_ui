/// Scroll views: one child, a list, or a grid.
///
/// The arithmetic of scrolling was already here - `ScrollPosition` clamps,
/// chains, pages, reveals and decays - and so was a planner that turns an
/// offset into a set of indices. What was missing was the middle: a widget that
/// **builds only the items the planner names**, and the input that moves the
/// position in the first place.
///
/// ## Three widgets, one mechanism
///
///   * [SingleChildScrollView] scrolls one child that is laid out in full. It
///     is the right answer for a long form: fifty labelled fields are fifty
///     widgets whether or not they are on screen, and virtualizing them would
///     cost more than it saves;
///   * [ListView] and [ListView.builder] realize a window. `builder` is the one
///     that matters - it calls its builder only for the indices in the window,
///     so a list of 100 000 items builds the dozen that are visible plus the
///     declared [ListView.cacheExtent] either side;
///   * [GridView.builder] is [ListView.builder] over *rows*. A grid whose
///     columns are equal is a list of rows, and building it that way means the
///     virtualization here has exactly one implementation rather than two that
///     disagree at the edges.
///
/// ## Input, and the fling that was dead code
///
/// [Scrollable] is the input layer, and it is separate from the viewport on
/// purpose: `RenderViewport` decides geometry and must not also decide what a
/// wheel notch means. It handles three things:
///
///  * **the wheel**, through [PointerSignalResolver]. Two nested lists under
///    the cursor both used to consume the same notch - the innermost now
///    registers first and wins, and hands whatever it could not consume
///    outwards through [ScrollPosition.applyDelta]'s remainder. That is scroll
///    chaining, and it is why an inner list that has hit its end scrolls the
///    page instead of stopping the gesture dead;
///  * **drag**, through the gesture layer's [DragGestureRecognizer]. It shares
///    the arena, so a list inside a scroll view still lets a button be tapped:
///    the drag claims the pointer only once the slop is crossed;
///  * **momentum**, through [ScrollMomentum]. `ScrollPosition.fling` and
///    `tickMomentum` were written long ago and nothing ever called them,
///    because a fling needs two things this framework refuses to invent: a
///    velocity and a clock. The velocity comes from the recognizer's
///    `VelocityTracker` - a least-squares fit, not a two-point difference - and
///    the clock is an injected [UiDispatcher], so a fling is exactly as
///    deterministic in a test as it is smooth in an application.
library;

import '../geometry/offset.dart';
import '../geometry/rect.dart';
import '../geometry/size.dart';
import '../gestures/binding.dart';
import '../gestures/drag.dart';
import '../gestures/pointer_signal_resolver.dart';
import '../graphics/display_list.dart';
import '../layout/box_constraints.dart';
import '../layout/render_box.dart';
import '../layout/render_viewport.dart';
import '../platform/input_events.dart';
import '../scheduler/timer_handle.dart';
import '../scheduler/ui_dispatcher.dart';
import 'basic.dart';
import 'element.dart';
import 'gesture_detector.dart';
import 'pointer_router.dart';
import 'scrollbar.dart';
import 'virtualization.dart';
import 'widget.dart';

/// How much of its speed a fling keeps per momentum step.
///
/// The same default [ScrollPosition.tickMomentum] uses, named here because a
/// caller tuning the feel of a scroll view should not have to pass a magic
/// number that matches an unnamed one somewhere else.
const double defaultScrollFriction = 0.94;

/// How often momentum is advanced. One display frame at 60 Hz.
///
/// The step is fixed rather than measured, which is what makes a fling travel
/// the same distance on a machine dropping frames as on one that is not - and
/// what lets a test assert that distance to the pixel.
const Duration defaultMomentumStep = Duration(milliseconds: 16);

/// The speed below which a fling is over, mirroring the constant inside
/// `ScrollPosition.tickMomentum`.
///
/// It is here only because of the defect [ScrollMomentum] works around; see
/// [ScrollMomentum._tick]. Delete both when the position stops reporting a
/// rounding remainder as an edge.
const double _restVelocity = 8.0;

/// Advances a [ScrollPosition]'s momentum on a dispatcher until it stops.
///
/// This is the consumer `ScrollPosition.fling` never had. The position owns the
/// physics - velocity, friction, the decision that hitting an edge ends the
/// fling - and this owns only the timer, because the position must stay free of
/// clocks and the timer must not re-implement the physics.
final class ScrollMomentum {
  ScrollMomentum({
    required this.position,
    required this.dispatcher,
    this.step = defaultMomentumStep,
    this.friction = defaultScrollFriction,
  });

  final ScrollPosition position;
  final UiDispatcher dispatcher;
  final Duration step;
  final double friction;

  TimerHandle? _timer;
  int _ticks = 0;

  /// Whether a fling is currently running.
  bool get isRunning => _timer != null;

  /// How many steps the current or last fling took. For tests and diagnostics.
  int get ticks => _ticks;

  /// Starts a fling at [velocity] pixels per second along the scroll axis.
  ///
  /// Positive moves the offset towards the end, which is the opposite sign to
  /// the pointer's own velocity: dragging a finger *down* scrolls a list *up*.
  void start(double velocity) {
    stop();
    _ticks = 0;
    if (velocity == 0 || !position.canScroll) return;
    position.fling(velocity);
    _arm();
  }

  /// Stops the fling where it is, leaving the offset alone.
  void stop() {
    _timer?.cancel();
    _timer = null;
    if (position.velocity != 0) position.fling(0);
  }

  void _arm() => _timer = dispatcher.schedule(step, _tick);

  /// One momentum step, plus a workaround for a defect in the position.
  ///
  /// `ScrollPosition.tickMomentum` ends the fling when `applyDelta` reports a
  /// non-zero remainder, and it tests that remainder with `!= 0` on a double.
  /// The remainder is computed as `delta - (clamped - pixels)`, which is
  /// exactly zero only in exact arithmetic: at `pixels = 16` and
  /// `delta = 15.04` the subtraction leaves -1.8e-15, and the fling stops on
  /// the **second step**, having travelled 31 pixels out of 265. That is why
  /// no fling in this framework has ever looked right, and it is not something
  /// a caller can pass its way around.
  ///
  /// So this distinguishes the two reasons the position may report a stop. It
  /// hit an edge if and only if it did not move the whole step; anything else
  /// is the rounding artefact, and the fling continues from the velocity the
  /// position would have had. No physics is duplicated - the step that already
  /// happened is kept, and the decay is the position's own - except for the
  /// resting speed, which has to be mirrored to know when to stop asking.
  ///
  /// The fix belongs in `layout/render_viewport.dart`: `remainder != 0` should
  /// be a tolerance. This file does not own that one.
  void _tick() {
    _timer = null;
    _ticks++;
    final double velocity = position.velocity;
    final double pixels = position.pixels;
    if (position.tickMomentum(step, friction: friction)) {
      _arm();
      return;
    }
    final double wanted =
        velocity * (step.inMicroseconds / Duration.microsecondsPerSecond);
    final bool reachedAnEdge = (position.pixels - pixels - wanted).abs() > 1e-6;
    if (reachedAnEdge) return;
    final double next = velocity * friction;
    if (next.abs() < _restVelocity) return;
    position.fling(next);
    _arm();
  }
}

/// Turns pointer input into movement of [position].
///
/// Wraps a viewport rather than being one, so the same input layer serves a
/// [SingleChildScrollView], a [ListView] and anything else that has an offset.
final class Scrollable extends SingleChildRenderObjectWidget {
  const Scrollable({
    super.key,
    required this.position,
    required Widget super.child,
    this.dragEnabled = true,
    this.mouseDragEnabled = true,
    this.wheelEnabled = true,
    this.dispatcher,
    this.friction = defaultScrollFriction,
    this.momentumStep = defaultMomentumStep,
  });

  final ScrollPosition position;

  /// Whether a press-and-drag scrolls. False for a desktop list that should
  /// only answer the wheel and the scrollbar.
  final bool dragEnabled;

  /// Whether a mouse primary-button drag scrolls. Disabling this while
  /// keeping [dragEnabled] true leaves touch/stylus scrolling available for
  /// surfaces that reserve mouse dragging for selection (such as a PDF page).
  final bool mouseDragEnabled;

  /// Whether the wheel scrolls.
  final bool wheelEnabled;

  /// Where momentum is stepped. Falls back to [GestureScope]; with neither, a
  /// release simply stops instead of coasting, because there is no clock to
  /// coast against.
  final UiDispatcher? dispatcher;

  final double friction;
  final Duration momentumStep;

  @override
  RenderScrollGestures createRenderObject(BuildContext context) =>
      RenderScrollGestures(
        position: position,
        dragEnabled: dragEnabled,
        mouseDragEnabled: mouseDragEnabled,
        wheelEnabled: wheelEnabled,
        dispatcher: dispatcher ?? GestureScope.of(context),
        friction: friction,
        momentumStep: momentumStep,
      );

  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderScrollGestures renderObject,
  ) {
    renderObject
      ..position = position
      ..dragEnabled = dragEnabled
      ..mouseDragEnabled = mouseDragEnabled
      ..wheelEnabled = wheelEnabled
      ..dispatcher = dispatcher ?? GestureScope.of(context)
      ..friction = friction
      ..momentumStep = momentumStep;
  }
}

/// The render endpoint of [Scrollable]: wheel, drag, momentum and chaining.
final class RenderScrollGestures extends RenderSingleChildBox
    implements PointerEventTarget {
  RenderScrollGestures({
    required ScrollPosition position,
    this.dragEnabled = true,
    this.mouseDragEnabled = true,
    this.wheelEnabled = true,
    UiDispatcher? dispatcher,
    double friction = defaultScrollFriction,
    Duration momentumStep = defaultMomentumStep,
    super.child,
  })  : _position = position,
        _dispatcher = dispatcher,
        _friction = friction,
        _momentumStep = momentumStep;

  /// Whether a drag scrolls this view.
  bool dragEnabled;

  /// Whether mouse drags participate in scrolling.
  bool mouseDragEnabled;

  /// Whether the wheel scrolls this view.
  bool wheelEnabled;

  ScrollPosition _position;
  UiDispatcher? _dispatcher;
  double _friction;
  Duration _momentumStep;

  ScrollMomentum? _momentum;
  DragGestureRecognizer? _drag;

  ScrollPosition get position => _position;

  set position(ScrollPosition value) {
    if (identical(value, _position)) return;
    _position = value;
    _discardMomentum();
    _discardDrag();
  }

  UiDispatcher? get dispatcher => _dispatcher;

  set dispatcher(UiDispatcher? value) {
    if (identical(value, _dispatcher)) return;
    _dispatcher = value;
    _discardMomentum();
  }

  double get friction => _friction;

  set friction(double value) {
    if (value == _friction) return;
    _friction = value;
    _discardMomentum();
  }

  Duration get momentumStep => _momentumStep;

  set momentumStep(Duration value) {
    if (value == _momentumStep) return;
    _momentumStep = value;
    _discardMomentum();
  }

  /// The momentum driver, created on first use and only when there is a clock.
  ScrollMomentum? get momentum {
    final UiDispatcher? dispatcher = _dispatcher;
    if (dispatcher == null) return null;
    return _momentum ??= ScrollMomentum(
      position: _position,
      dispatcher: dispatcher,
      step: _momentumStep,
      friction: _friction,
    );
  }

  bool get _vertical => _position.axis == ScrollAxis.vertical;

  @override
  void performLayout() {
    final RenderBox? child = this.child;
    if (child == null) {
      size = constraints.smallest;
      return;
    }
    child.layout(constraints, parentUsesSize: true);
    size = constraints.constrain(child.size);
  }

  // Hittable everywhere inside itself, not only where the child is: the blank
  // space below a short list is still part of the scrollable, and a wheel notch
  // over it must scroll rather than fall through to whatever is behind.
  @override
  bool hitTestSelf(Offset position) => true;

  @override
  void handlePointerEvent(PointerEvent event) {
    if (event is PointerScrollEvent) {
      if (!wheelEnabled) return;
      final GestureBinding? binding = GestureBinding.current;
      // Outside a router's dispatch there is nobody to resolve the signal, so
      // a registration would never be honoured. That happens in unit tests
      // that call this method directly, and applying the notch there is both
      // harmless - there is no second candidate - and what makes such a test
      // mean what it says.
      if (binding == null) {
        applyWheel(event);
        return;
      }
      binding.signalResolver.register(event, applyWheel);
      return;
    }
    if (!dragEnabled ||
        (!mouseDragEnabled && event.kind == PointerKind.mouse)) {
      return;
    }
    _drag ??= _createDrag();
    _drag!.routeEvent(event);
  }

  /// Applies one wheel notch, chaining the remainder outwards.
  ///
  /// Public because it is what the signal resolver calls back into, and
  /// because a backend that synthesizes scrolls has a legitimate reason to
  /// drive it directly.
  void applyWheel(PointerScrollEvent event) {
    _momentum?.stop();
    final double delta =
        _vertical ? event.scrollDelta.dy : event.scrollDelta.dx;
    final double remainder = _position.applyScrollDelta(
      delta,
      inLines: event.scrollDeltaUnit == ScrollDeltaUnit.lines,
    );
    if (remainder != 0) _chain(remainder);
  }

  /// Applies [delta] handed down from an inner scrollable that could not use
  /// all of it, chaining any remainder further out.
  void applyChained(double delta) {
    final double remainder = _position.applyDelta(delta);
    if (remainder != 0) _chain(remainder);
  }

  /// Hands [delta] to the nearest enclosing scrollable on the same axis.
  ///
  /// Walking the render tree rather than an inherited widget is deliberate:
  /// the question is "which scrollable physically contains this one", and that
  /// is a fact about geometry. An inherited value would also be answered by a
  /// scrollable that a portal or an overlay had moved elsewhere on screen.
  void _chain(double delta) {
    for (RenderBox? node = parent; node != null; node = node.parent) {
      if (node is RenderScrollGestures &&
          node.position.axis == _position.axis) {
        node.applyChained(delta);
        return;
      }
    }
  }

  DragGestureRecognizer _createDrag() => DragGestureRecognizer(
        axis: _vertical ? DragAxis.vertical : DragAxis.horizontal,
        debugOwner: this,
      )
        ..onStart = _onDragStart
        ..onUpdate = _onDragUpdate
        ..onEnd = _onDragEnd;

  void _onDragStart(DragStartDetails details) => _momentum?.stop();

  void _onDragUpdate(DragUpdateDetails details) {
    final double delta = _vertical ? details.delta.dy : details.delta.dx;
    // Negated: the content follows the finger, so a finger moving down means a
    // smaller offset. Overscroll is allowed here and settled on release, which
    // is what makes a rubber-band possible for a position that asked for one
    // and changes nothing for the default allowance of zero.
    final double remainder =
        _position.applyDelta(-delta, allowOverscroll: true);
    if (remainder != 0) _chain(remainder);
  }

  void _onDragEnd(DragEndDetails details) {
    if (_position.pixels < 0) {
      _position.jumpTo(0);
      return;
    }
    if (_position.pixels > _position.maxScrollExtent) {
      _position.jumpTo(_position.maxScrollExtent);
      return;
    }
    final double velocity = _vertical
        ? details.velocity.pixelsPerSecond.dy
        : details.velocity.pixelsPerSecond.dx;
    if (velocity == 0) return;
    momentum?.start(-velocity);
  }

  void _discardMomentum() {
    _momentum?.stop();
    _momentum = null;
  }

  void _discardDrag() {
    _drag?.dispose();
    _drag = null;
  }

  @override
  void detach() {
    // A recognizer holding an arena entry from a detached node never resolves
    // it, and an unresolved arena swallows every later press on that pointer.
    _drag?.cancelPending();
    _discardMomentum();
    super.detach();
  }
}

/// Shows one window onto a child laid out in full.
final class SingleChildScrollView extends StatefulWidget {
  const SingleChildScrollView({
    super.key,
    required this.child,
    this.axis = ScrollAxis.vertical,
    this.controller,
    this.scrollbar = ScrollbarVisibility.always,
    this.scrollbarThickness = 8.0,
    this.dragEnabled = true,
    this.mouseDragEnabled = true,
    this.dispatcher,
  });

  final Widget child;
  final ScrollAxis axis;

  /// The position to drive. One is created when this is null, and a caller
  /// that wants to read or set the offset passes its own.
  final ScrollPosition? controller;

  final ScrollbarVisibility scrollbar;
  final double scrollbarThickness;
  final bool dragEnabled;
  final bool mouseDragEnabled;
  final UiDispatcher? dispatcher;

  @override
  State<SingleChildScrollView> createState() => _SingleChildScrollViewState();
}

final class _SingleChildScrollViewState extends State<SingleChildScrollView> {
  late final ScrollPosition _position =
      widget.controller ?? ScrollPosition(axis: widget.axis);

  /// The position this view is driving, for a caller holding the widget.
  ScrollPosition get position => _position;

  @override
  Widget build(BuildContext context) {
    final Widget scrollable = Scrollable(
      position: _position,
      dragEnabled: widget.dragEnabled,
      mouseDragEnabled: widget.mouseDragEnabled,
      dispatcher: widget.dispatcher,
      child: _ViewportWidget(position: _position, child: widget.child),
    );
    if (widget.scrollbar == ScrollbarVisibility.never) return scrollable;
    return Scrollbar(
      position: _position,
      visibility: widget.scrollbar,
      thickness: widget.scrollbarThickness,
      dispatcher: widget.dispatcher,
      child: scrollable,
    );
  }
}

final class _ViewportWidget extends SingleChildRenderObjectWidget {
  const _ViewportWidget({required this.position, required Widget super.child});

  final ScrollPosition position;

  @override
  RenderViewport createRenderObject(BuildContext context) =>
      RenderViewport(position: position);

  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderViewport object,
  ) {
    object.position = position;
  }
}

/// A scrolling list that builds only the items it shows.
///
/// The unnamed constructor takes the children eagerly - it is the convenient
/// form for a list that is short enough for the widgets themselves to be
/// cheap - and still realizes only the window, so a long list built this way
/// costs the widget objects but not their elements or render objects.
/// [ListView.builder] is the one that scales: nothing outside the window is
/// even described.
final class ListView extends StatefulWidget {
  ListView({
    super.key,
    required List<Widget> children,
    this.itemExtent,
    this.estimatedItemExtent = 40.0,
    this.cacheExtent = 0.0,
    this.controller,
    this.axis = ScrollAxis.vertical,
    this.scrollbar = ScrollbarVisibility.always,
    this.scrollbarThickness = 8.0,
    this.dragEnabled = true,
    this.mouseDragEnabled = true,
    this.dispatcher,
  })  : itemCount = children.length,
        itemBuilder = _builderOver(children);

  const ListView.builder({
    super.key,
    required this.itemCount,
    required this.itemBuilder,
    this.itemExtent,
    this.estimatedItemExtent = 40.0,
    this.cacheExtent = 0.0,
    this.controller,
    this.axis = ScrollAxis.vertical,
    this.scrollbar = ScrollbarVisibility.always,
    this.scrollbarThickness = 8.0,
    this.dragEnabled = true,
    this.mouseDragEnabled = true,
    this.dispatcher,
  });

  final int itemCount;

  /// Called only for realized indices - the visible window plus [cacheExtent]
  /// either side. A list of 100 000 items calls this a few dozen times per
  /// frame, which is the whole point of the widget.
  final Widget Function(BuildContext context, int index) itemBuilder;

  /// The extent of every item, when they all share one.
  ///
  /// Setting it is the **fast path**: offsets and indices are arithmetic, so
  /// nothing is measured and nothing is cached. Leaving it null makes the list
  /// measure each item as it is laid out and remember it, which costs O(n)
  /// memory for the position cache - see [ListVirtualization].
  final double? itemExtent;

  /// What an unmeasured item is assumed to be, when [itemExtent] is null.
  ///
  /// It is what gives a list a scrollbar and a total height before anything has
  /// been built; the total corrects as items are measured.
  final double estimatedItemExtent;

  /// How far beyond the viewport items are kept realized, in pixels.
  ///
  /// Zero by default, and deliberately: the number of items built is then a
  /// property a caller can predict and a test can assert. A list that wants a
  /// margin against the frame that scrolls declares one - a screenful is the
  /// usual choice.
  final double cacheExtent;

  final ScrollPosition? controller;
  final ScrollAxis axis;
  final ScrollbarVisibility scrollbar;
  final double scrollbarThickness;
  final bool dragEnabled;
  final bool mouseDragEnabled;
  final UiDispatcher? dispatcher;

  static Widget Function(BuildContext, int) _builderOver(
    List<Widget> children,
  ) =>
      (BuildContext context, int index) => children[index];

  @override
  State<ListView> createState() => _ListViewState();
}

final class _ListViewState extends State<ListView> {
  /// How many items to assume fit on screen before the first layout has said.
  ///
  /// Only ever used for one build: the viewport reports its real extent during
  /// layout and the list rebuilds against it. Guessing high would build items
  /// that are immediately discarded; guessing low would paint a partly empty
  /// list for one frame.
  static const int _initialWindowItems = 8;

  late final ScrollPosition _position =
      widget.controller ?? ScrollPosition(axis: widget.axis);
  ListVirtualization? _plan;

  @override
  void initState() {
    super.initState();
    _position.addListener(_onScrolled);
  }

  @override
  void dispose() {
    _position.removeListener(_onScrolled);
    super.dispose();
  }

  // Scrolling changes which items exist, so it is a rebuild and not merely a
  // repaint - that difference is what virtualization *is*. The same listener
  // covers the viewport being measured for the first time and the offset being
  // re-clamped by a list that shrank, both of which change the window too.
  void _onScrolled(ScrollPosition position) {
    if (mounted) setState(() {});
  }

  double get _estimate => widget.itemExtent ?? widget.estimatedItemExtent;

  ListVirtualization get _virtualization {
    final ListVirtualization? current = _plan;
    if (current != null &&
        current.itemCount == widget.itemCount &&
        current.estimatedExtent == _estimate &&
        current.cacheExtent == widget.cacheExtent &&
        current.hasVariableExtents == (widget.itemExtent == null)) {
      return current;
    }
    // Kept across builds rather than rebuilt, because for a measured list it
    // holds the measurements: a planner recreated every frame would forget each
    // item extent it had learned and the scrollbar would twitch.
    return _plan = widget.itemExtent != null
        ? ListVirtualization(
            itemCount: widget.itemCount,
            estimatedExtent: widget.itemExtent!,
            cacheExtent: widget.cacheExtent,
          )
        : ListVirtualization.estimated(
            itemCount: widget.itemCount,
            estimatedExtent: widget.estimatedItemExtent,
            cacheExtent: widget.cacheExtent,
          );
  }

  double get _viewportExtent {
    final double measured = _position.viewportExtent;
    return measured > 0 ? measured : _estimate * _initialWindowItems;
  }

  @override
  Widget build(BuildContext context) {
    final ListVirtualization virtualization = _virtualization;
    final RealizedRange range = virtualization.rangeFor(
      scrollOffset: _position.pixels,
      viewportExtent: _viewportExtent,
    );
    final Widget scrollable = Scrollable(
      position: _position,
      dragEnabled: widget.dragEnabled,
      mouseDragEnabled: widget.mouseDragEnabled,
      dispatcher: widget.dispatcher,
      child: _VirtualList(
        position: _position,
        virtualization: virtualization,
        range: range,
        itemExtent: widget.itemExtent,
        onExtentsMeasured: _onExtentsMeasured,
        children: <Widget>[
          for (int index = range.firstRealized;
              index <= range.lastRealized && index < widget.itemCount;
              index++)
            // Keyed by item index, which is what makes the element for item 41
            // be found again after a scroll instead of being rebuilt from
            // whatever now sits in the same slot - and what keeps focus on an
            // item that scrolls out and back.
            _ListViewItem(
              key: ValueKey<int>(index),
              child: widget.itemBuilder(context, index),
            ),
        ],
      ),
    );
    if (widget.scrollbar == ScrollbarVisibility.never) return scrollable;
    return Scrollbar(
      position: _position,
      visibility: widget.scrollbar,
      thickness: widget.scrollbarThickness,
      dispatcher: widget.dispatcher,
      child: scrollable,
    );
  }

  void _onExtentsMeasured() {
    if (mounted) setState(() {});
  }
}

/// A keyed wrapper, and nothing else.
///
/// The key has to be on a widget this list owns: an item builder may return
/// anything, including a widget that already carries a key of its own, and
/// overwriting that would break whatever the caller was using it for.
final class _ListViewItem extends StatelessWidget {
  const _ListViewItem({required super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => child;
}

final class _VirtualList extends MultiChildRenderObjectWidget {
  const _VirtualList({
    required this.position,
    required this.virtualization,
    required this.range,
    required this.itemExtent,
    required this.onExtentsMeasured,
    required super.children,
  });

  final ScrollPosition position;
  final ListVirtualization virtualization;
  final RealizedRange range;
  final double? itemExtent;
  final void Function() onExtentsMeasured;

  @override
  RenderVirtualList createRenderObject(BuildContext context) =>
      RenderVirtualList(
        position: position,
        virtualization: virtualization,
        range: range,
        itemExtent: itemExtent,
        onExtentsMeasured: onExtentsMeasured,
      );

  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderVirtualList object,
  ) {
    object
      ..position = position
      ..virtualization = virtualization
      ..range = range
      ..itemExtent = itemExtent
      ..onExtentsMeasured = onExtentsMeasured;
  }
}

/// Lays out the realized items at their true content offsets.
///
/// It is **not** a [RenderViewport]: the children are already only the realized
/// ones, so this positions them where they belong in the whole content and
/// clips, rather than translating a child that contains everything.
final class RenderVirtualList extends RenderBoxContainer<BoxParentData> {
  RenderVirtualList({
    required ScrollPosition position,
    required ListVirtualization virtualization,
    required RealizedRange range,
    required double? itemExtent,
    required this.onExtentsMeasured,
  })  : _position = position,
        _virtualization = virtualization,
        _range = range,
        _itemExtent = itemExtent {
    _position.addListener(_onScrolled);
  }

  ScrollPosition _position;
  ListVirtualization _virtualization;
  RealizedRange _range;
  double? _itemExtent;

  /// Called after layout when an item turned out not to be the size the
  /// planner assumed. The owner rebuilds; the extents are already recorded.
  void Function() onExtentsMeasured;

  ScrollPosition get position => _position;

  set position(ScrollPosition value) {
    if (identical(value, _position)) return;
    _position.removeListener(_onScrolled);
    _position = value..addListener(_onScrolled);
    markNeedsLayout();
  }

  ListVirtualization get virtualization => _virtualization;

  set virtualization(ListVirtualization value) {
    if (identical(value, _virtualization)) return;
    _virtualization = value;
    markNeedsLayout();
  }

  RealizedRange get range => _range;

  set range(RealizedRange value) {
    if (value == _range) return;
    _range = value;
    markNeedsLayout();
  }

  double? get itemExtent => _itemExtent;

  set itemExtent(double? value) {
    if (value == _itemExtent) return;
    _itemExtent = value;
    markNeedsLayout();
  }

  bool get _vertical => _position.axis == ScrollAxis.vertical;

  @override
  void performLayout() {
    final double width = constraints.hasBoundedWidth
        ? constraints.maxWidth
        : constraints.minWidth;
    final double height = constraints.hasBoundedHeight
        ? constraints.maxHeight
        : constraints.minHeight;
    size = constraints.constrain(Size(width, height));

    final bool vertical = _vertical;
    final double viewport = vertical ? size.height : size.width;
    final double cross = vertical ? size.width : size.height;

    // The position is told the *whole* list's extent, estimate included, not
    // the extent of the realized window: a scrollbar that described only what
    // is built would grow and shrink as the user scrolled.
    _position.applyViewportGeometry(
      viewportExtent: viewport,
      contentExtent: _virtualization.totalExtent,
    );

    final double? fixed = _itemExtent;
    final BoxConstraints itemConstraints = vertical
        ? BoxConstraints(
            minWidth: cross,
            maxWidth: cross,
            minHeight: fixed ?? 0,
            maxHeight: fixed ?? double.infinity,
          )
        : BoxConstraints(
            minHeight: cross,
            maxHeight: cross,
            minWidth: fixed ?? 0,
            maxWidth: fixed ?? double.infinity,
          );

    double cursor = _range.leadingExtent - _position.pixels;
    bool remeasured = false;
    for (int i = 0; i < childCount; i++) {
      final RenderBox child = childAt(i);
      child.layout(itemConstraints, parentUsesSize: true);
      final double extent = vertical ? child.size.height : child.size.width;
      if (_virtualization.hasVariableExtents &&
          _virtualization.setExtent(_range.firstRealized + i, extent)) {
        remeasured = true;
      }
      child.parentData!.offset =
          vertical ? Offset(0, cursor) : Offset(cursor, 0);
      cursor += extent;
    }
    if (remeasured) {
      // The content is a different length than it was at the top of this
      // method, and the position was told the old one. Telling it again here
      // is what keeps the scrollbar honest and what re-clamps an offset that
      // the new, shorter content no longer reaches.
      _position.applyViewportGeometry(
        viewportExtent: viewport,
        contentExtent: _virtualization.totalExtent,
      );
      // The window itself is decided during build, not here, so the owner is
      // asked for one. Recomputing it in place would mean building widgets in
      // the middle of a layout.
      onExtentsMeasured();
    }
  }

  @override
  void paint(DisplayList list, Offset offset) {
    final Rect bounds = Rect.fromLTWH(
      offset.dx,
      offset.dy,
      size.width,
      size.height,
    );
    // The realized window reaches past the viewport by the cache extent, so
    // without a clip the cached items paint over whatever is next to the list.
    list.save();
    list.clipRect(bounds.left, bounds.top, bounds.right, bounds.bottom);
    super.paint(list, offset);
    list.restore();
  }

  @override
  RenderBox? hitTestChildren(Offset position, {HitTestPath? path}) {
    if (!size.contains(position)) return null;
    return super.hitTestChildren(position, path: path);
  }

  void _onScrolled(ScrollPosition position) => markNeedsLayout();

  @override
  void detach() {
    _position.removeListener(_onScrolled);
    super.detach();
  }
}

/// A scrolling grid of equal cells, virtualized by row.
///
/// A grid whose columns are equal *is* a list of rows, so this builds one:
/// [crossAxisCount] cells per row, each row an item of a [ListView.builder] of
/// height [rowExtent]. Nothing about the virtualization is duplicated, which is
/// the only way the two can be guaranteed to agree about which items exist.
final class GridView extends StatelessWidget {
  const GridView.builder({
    super.key,
    required this.itemCount,
    required this.itemBuilder,
    required this.crossAxisCount,
    required this.rowExtent,
    this.cacheExtent = 0.0,
    this.controller,
    this.scrollbar = ScrollbarVisibility.always,
    this.dragEnabled = true,
    this.dispatcher,
  }) : assert(crossAxisCount > 0, 'a grid needs at least one column');

  final int itemCount;
  final Widget Function(BuildContext context, int index) itemBuilder;

  /// How many cells fit across the grid. The cross axis is divided equally.
  final int crossAxisCount;

  /// The height of one row.
  final double rowExtent;

  final double cacheExtent;
  final ScrollPosition? controller;
  final ScrollbarVisibility scrollbar;
  final bool dragEnabled;
  final UiDispatcher? dispatcher;

  /// How many rows the items make up, the trailing partial row included.
  int get rowCount => (itemCount + crossAxisCount - 1) ~/ crossAxisCount;

  @override
  Widget build(BuildContext context) => ListView.builder(
        itemCount: rowCount,
        itemExtent: rowExtent,
        cacheExtent: cacheExtent,
        controller: controller,
        scrollbar: scrollbar,
        dragEnabled: dragEnabled,
        dispatcher: dispatcher,
        itemBuilder: (BuildContext context, int row) => Row(
          children: <Widget>[
            for (int column = 0; column < crossAxisCount; column++)
              Expanded(
                // The trailing row is padded with empty cells rather than
                // being narrower: a last row whose two items stretched across
                // the whole width would not line up with the columns above it.
                child: row * crossAxisCount + column < itemCount
                    ? itemBuilder(context, row * crossAxisCount + column)
                    : const SizedBox(),
              ),
          ],
        ),
      );
}
