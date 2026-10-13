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

import 'dart:async';

import '../animation/curves.dart';
import '../animation/simulation.dart';
import '../geometry/offset.dart';
import '../geometry/rect.dart';
import '../geometry/size.dart';
import '../gestures/binding.dart';
import '../gestures/drag.dart';
import '../gestures/pointer_signal_resolver.dart';
import '../graphics/display_list.dart';
import '../layout/box_constraints.dart';
import '../layout/edge_insets.dart';
import '../layout/pipeline.dart';
import '../layout/render_box.dart';
import '../layout/render_flex.dart' show Axis;
import '../layout/render_sliver.dart'
    show
        SliverGridDelegate,
        SliverGridDelegateWithFixedCrossAxisCount,
        SliverGridDelegateWithMaxCrossAxisExtent;
import '../layout/render_viewport.dart';
import '../layout/scroll_metrics.dart';
import '../platform/input_events.dart';
import '../scheduler/timer_handle.dart';
import '../scheduler/ui_dispatcher.dart';
import 'basic.dart';
import 'directionality.dart';
import 'element.dart';
import 'gesture_detector.dart';
import 'pointer_router.dart';
import 'scroll_controller.dart';
import 'scroll_notification.dart';
import 'scroll_physics.dart';
import 'scrollbar.dart';
import 'slivers.dart';
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
///
/// It also runs a physics' ballistic [Simulation] ([runSimulation]) - a
/// spring back from a bounce, a spring to the nearest page - on the same
/// fixed step, and is the position's [ScrollActivityHandle] while it runs:
/// a drag, a `jumpTo` or an `animateTo` cancels it.
final class ScrollMomentum implements ScrollActivityHandle {
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
  Simulation? _simulation;
  ScrollPhysics? _physics;
  Duration _elapsed = Duration.zero;

  /// Whether a fling is currently running.
  bool get isRunning => _timer != null;

  /// How many steps the current or last fling took. For tests and diagnostics.
  int get ticks => _ticks;

  /// Starts a fling at [velocity] pixels per second along the scroll axis.
  ///
  /// Positive moves the offset towards the end, which is the opposite sign to
  /// the pointer's own velocity: dragging a finger *down* scrolls a list *up*.
  void start(double velocity) {
    _halt();
    _ticks = 0;
    if (velocity == 0 || !position.canScroll) {
      position.didEndScroll();
      return;
    }
    position.beginActivity(this);
    position.didStartScroll();
    position.fling(velocity);
    _arm();
  }

  /// Runs [simulation] - a physics' answer to a release - until it is done,
  /// moving the position to `simulation.x(t)` every [step].
  ///
  /// [physics] decides where the motion must stop: its
  /// `applyBoundaryConditions` turns a move past an edge into an overscroll,
  /// which ends the run there. Without a clock this cannot be stepped, so
  /// [settleSimulation] runs it to its end at once instead.
  void runSimulation(Simulation simulation, {ScrollPhysics? physics}) {
    _halt();
    _ticks = 0;
    _simulation = simulation;
    _physics = physics;
    _elapsed = Duration.zero;
    position.beginActivity(this);
    position.didStartScroll();
    _arm();
  }

  /// Stops the fling where it is, leaving the offset alone, and ends the
  /// scroll it was part of.
  void stop() {
    final bool wasRunning = isRunning;
    _halt();
    position.endActivity(this);
    if (wasRunning) position.didEndScroll();
  }

  /// Another activity replaced this one on the position.
  @override
  void cancel() {
    final bool wasRunning = isRunning;
    _halt();
    if (wasRunning) position.didEndScroll();
  }

  void _halt() {
    _timer?.cancel();
    _timer = null;
    _simulation = null;
    if (position.velocity != 0) position.fling(0);
  }

  void _finish() {
    _timer = null;
    _simulation = null;
    position.endActivity(this);
    position.didEndScroll();
  }

  void _arm() => _timer = dispatcher.schedule(step, _tick);

  /// One step of a [runSimulation].
  void _tickSimulation(Simulation simulation) {
    _elapsed += step;
    final bool done = simulation.isDone(_elapsed);
    final double target =
        done ? settledValue(simulation, _elapsed) : simulation.x(_elapsed);
    if (_applySimulated(position, target, _physics)) {
      _finish();
      return;
    }
    if (done) {
      _finish();
      return;
    }
    _arm();
  }

  /// Moves [position] to [value], stopping at the boundary [physics] draws.
  /// Returns true when it hit one.
  static bool _applySimulated(
    ScrollPosition position,
    double value,
    ScrollPhysics? physics,
  ) {
    final double overscroll =
        physics?.applyBoundaryConditions(position, value) ?? 0.0;
    position.forcePixels(value - overscroll);
    if (overscroll != 0) {
      position.didOverscrollBy(overscroll);
      return true;
    }
    return false;
  }

  /// Where [simulation] rests once done: the spring's end exactly, rather
  /// than a value within the tolerance of it.
  static double settledValue(Simulation simulation, Duration time) {
    if (simulation is SpringSimulation) return simulation.end;
    if (simulation is BouncingScrollSimulation) {
      return simulation.restingPosition ?? simulation.x(time);
    }
    return simulation.x(time);
  }

  /// Runs [simulation] to its end at once, for a scroll view with no clock:
  /// a bounce must still come back, and a page view must still land on a
  /// page.
  static void settleSimulation(
    ScrollPosition position,
    Simulation simulation, {
    ScrollPhysics? physics,
    Duration step = defaultMomentumStep,
  }) {
    Duration elapsed = Duration.zero;
    // Ten minutes of frames is a fling that never ends; stop there.
    for (int i = 0; i < 37500; i++) {
      elapsed += step;
      final bool done = simulation.isDone(elapsed);
      final double value =
          done ? settledValue(simulation, elapsed) : simulation.x(elapsed);
      if (_applySimulated(position, value, physics) || done) return;
    }
  }

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
    final Simulation? simulation = _simulation;
    if (simulation != null) {
      _tickSimulation(simulation);
      return;
    }
    final double velocity = position.velocity;
    final double pixels = position.pixels;
    if (position.tickMomentum(step, friction: friction)) {
      _arm();
      return;
    }
    final double wanted =
        velocity * (step.inMicroseconds / Duration.microsecondsPerSecond);
    final bool reachedAnEdge = (position.pixels - pixels - wanted).abs() > 1e-6;
    if (reachedAnEdge) {
      _finish();
      return;
    }
    final double next = velocity * friction;
    if (next.abs() < _restVelocity) {
      _finish();
      return;
    }
    position.fling(next);
    _arm();
  }
}

/// The clock each attached scroll view offers its position, for
/// [ScrollPositionAnimation.animateTo]. A position lives below the scheduler
/// and cannot hold one itself.
final Expando<UiDispatcher> _positionDispatchers =
    Expando<UiDispatcher>('ScrollPosition dispatcher');

/// Flutter's `ScrollPosition.animateTo`, on the clock of the scroll view the
/// position is attached to.
extension ScrollPositionAnimation on ScrollPosition {
  /// Animates the offset from where it is to [to], clamped to the scroll
  /// range, over [duration] along [curve].
  ///
  /// It replaces whatever was moving the position, and a drag, a `jumpTo` or
  /// another animation replaces it in turn; the future completes either way.
  /// Without a clock - no scroll view attached, or one without a dispatcher
  /// - and for a zero [duration], it jumps.
  Future<void> animateTo(
    double to, {
    required Duration duration,
    required Curve curve,
  }) {
    if (to.isNaN) {
      throw ArgumentError.value(to, 'to', 'must be a number');
    }
    final UiDispatcher? dispatcher = _positionDispatchers[this];
    final double target = to.clamp(0.0, maxScrollExtent);
    if (dispatcher == null || duration <= Duration.zero || target == pixels) {
      jumpTo(target);
      return Future<void>.value();
    }
    final _ScrollAnimation animation = _ScrollAnimation(
      position: this,
      dispatcher: dispatcher,
      from: pixels,
      to: target,
      duration: duration,
      curve: curve,
    );
    beginActivity(animation);
    didStartScroll();
    animation.start();
    return animation.done;
  }
}

/// An `animateTo` in flight: the offset along [curve] every
/// [defaultMomentumStep], on a fixed step for the reason the fling has one.
final class _ScrollAnimation implements ScrollActivityHandle {
  _ScrollAnimation({
    required this.position,
    required this.dispatcher,
    required this.from,
    required this.to,
    required this.duration,
    required this.curve,
  });

  final ScrollPosition position;
  final UiDispatcher dispatcher;
  final double from;
  final double to;
  final Duration duration;
  final Curve curve;

  final Completer<void> _done = Completer<void>();
  TimerHandle? _timer;
  Duration _elapsed = Duration.zero;

  Future<void> get done => _done.future;

  void start() => _timer = dispatcher.schedule(defaultMomentumStep, _tick);

  void _tick() {
    _timer = null;
    _elapsed += defaultMomentumStep;
    final double t = _elapsed >= duration
        ? 1.0
        : _elapsed.inMicroseconds / duration.inMicroseconds;
    final double value = from + (to - from) * curve.transform(t);
    final double overscroll = position.setPixels(value);
    if (t >= 1.0 || overscroll != 0) {
      position.endActivity(this);
      position.didEndScroll();
      _complete();
      return;
    }
    start();
  }

  @override
  void cancel() {
    _timer?.cancel();
    _timer = null;
    position.didEndScroll();
    _complete();
  }

  void _complete() {
    if (!_done.isCompleted) _done.complete();
  }
}

/// A render object that coordinates the scrollables nested inside it.
///
/// The body of a `NestedScrollView` is one: the list inside it must hand its
/// deltas to a coordinator, and the list does not know it is in a body. So
/// every [RenderScrollGestures], when it joins the tree, walks up to the
/// nearest host and offers its position - the same physical "who contains
/// me" question scroll chaining asks. The walk stops at the first enclosing
/// scrollable on the same axis: a list inside the body's list belongs to that
/// list, not to the body.
abstract interface class NestedScrollHost {
  /// [position] belongs to a scrollable that has just joined the tree inside
  /// this host. The host may ignore it - one on the other axis, say.
  void attachInnerPosition(ScrollPosition position);

  /// [position] has left the tree, or its scrollable was given another one.
  void detachInnerPosition(ScrollPosition position);
}

/// Turns pointer input into movement of [position].
///
/// Wraps a viewport rather than being one, so the same input layer serves a
/// [SingleChildScrollView], a [ListView] and anything else that has an offset.
///
/// It is also where a scroll view's notifications come from: its element is
/// the `context` of every [ScrollNotification] the view sends, and a
/// [NotificationListener] above it hears them.
final class Scrollable extends SingleChildRenderObjectWidget {
  const Scrollable({
    super.key,
    required this.position,
    required Widget super.child,
    this.dragEnabled = true,
    this.mouseDragEnabled = true,
    this.wheelEnabled = true,
    this.reverse = false,
    this.physics,
    this.dispatcher,
    this.friction = defaultScrollFriction,
    this.momentumStep = defaultMomentumStep,
  });

  final ScrollPosition position;

  /// How the view answers the user; see `scroll_physics.dart`. Applied to
  /// [ClampingScrollPhysics] as the platform default, as Flutter applies a
  /// widget's physics to the platform's.
  ///
  /// Null keeps this framework's own scrolling - the drag, the fling and the
  /// clamping it always had - without consulting a physics object.
  final ScrollPhysics? physics;

  /// Whether the content's start is at the bottom (or right) of the view, as
  /// in a `CustomScrollView(reverse: true)`.
  ///
  /// Input is physical - a wheel notch towards the user moves the content up,
  /// a finger dragged down moves it down - and a reversed view maps that to the
  /// opposite change in offset. Without this a chat log scrolled from the
  /// bottom would run backwards under the wheel.
  final bool reverse;

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

  /// [physics] with the platform default at the end of its chain.
  static ScrollPhysics? resolvePhysics(ScrollPhysics? physics) =>
      physics?.applyTo(const ClampingScrollPhysics());

  @override
  RenderScrollGestures createRenderObject(BuildContext context) =>
      RenderScrollGestures(
        position: position,
        dragEnabled: dragEnabled,
        mouseDragEnabled: mouseDragEnabled,
        wheelEnabled: wheelEnabled,
        reverse: reverse,
        physics: resolvePhysics(physics),
        dispatcher: dispatcher ?? GestureScope.of(context),
        friction: friction,
        momentumStep: momentumStep,
      )..notificationContext = context;

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
      ..reverse = reverse
      ..physics = resolvePhysics(physics)
      ..dispatcher = dispatcher ?? GestureScope.of(context)
      ..friction = friction
      ..momentumStep = momentumStep
      ..notificationContext = context;
  }
}

/// The render endpoint of [Scrollable]: wheel, drag, momentum and chaining.
///
/// It is also the [ScrollActivityListener] of its position, turning what the
/// position reports into the [ScrollNotification]s Flutter sends, dispatched
/// from [notificationContext].
final class RenderScrollGestures extends RenderSingleChildBox
    implements PointerEventTarget, ScrollActivityListener {
  RenderScrollGestures({
    required ScrollPosition position,
    this.dragEnabled = true,
    this.mouseDragEnabled = true,
    this.wheelEnabled = true,
    bool reverse = false,
    this.physics,
    UiDispatcher? dispatcher,
    double friction = defaultScrollFriction,
    Duration momentumStep = defaultMomentumStep,
    super.child,
  })  : _position = position,
        _reverse = reverse,
        _dispatcher = dispatcher,
        _friction = friction,
        _momentumStep = momentumStep;

  /// The physics, already applied to the default; null for the framework's
  /// own scrolling. See [Scrollable.physics].
  ScrollPhysics? physics;

  /// Where notifications are dispatched from: the [Scrollable]'s element.
  BuildContext? notificationContext;

  /// Whether a drag scrolls this view.
  bool dragEnabled;

  /// Whether mouse drags participate in scrolling.
  bool mouseDragEnabled;

  /// Whether the wheel scrolls this view.
  bool wheelEnabled;

  /// Whether a physical movement towards the end decreases the offset; see
  /// [Scrollable.reverse].
  bool get reverse => _reverse;
  bool _reverse;

  set reverse(bool value) {
    if (value == _reverse) return;
    _reverse = value;
    if (owner != null) _publishAxisDirection();
  }

  void _publishAxisDirection() {
    final bool vertical = _position.axis == ScrollAxis.vertical;
    _position.updateAxisDirection(
      vertical
          ? (_reverse ? AxisDirection.up : AxisDirection.down)
          : (_reverse ? AxisDirection.left : AxisDirection.right),
    );
  }

  /// [delta] converted between physical direction and offset direction. The
  /// conversion is its own inverse, so one helper serves both ways.
  double _directed(double delta) => reverse ? -delta : delta;

  ScrollPosition _position;
  UiDispatcher? _dispatcher;
  double _friction;
  Duration _momentumStep;

  ScrollMomentum? _momentum;
  DragGestureRecognizer? _drag;

  ScrollPosition get position => _position;

  set position(ScrollPosition value) {
    if (identical(value, _position)) return;
    _nestedHost?.detachInnerPosition(_position);
    if (owner != null) _releasePosition(_position);
    _position = value;
    if (owner != null) _claimPosition(value);
    _nestedHost?.attachInnerPosition(value);
    _discardMomentum();
    _discardDrag();
  }

  void _claimPosition(ScrollPosition position) {
    position.addActivityListener(this);
    final UiDispatcher? dispatcher = _dispatcher;
    if (dispatcher != null) _positionDispatchers[position] = dispatcher;
    _publishAxisDirection();
  }

  void _releasePosition(ScrollPosition position) {
    position.removeActivityListener(this);
    if (identical(_positionDispatchers[position], _dispatcher)) {
      _positionDispatchers[position] = null;
    }
  }

  /// The [NestedScrollHost] this scrollable's position was offered to.
  NestedScrollHost? _nestedHost;

  UiDispatcher? get dispatcher => _dispatcher;

  set dispatcher(UiDispatcher? value) {
    if (identical(value, _dispatcher)) return;
    if (owner != null) _releasePosition(_position);
    _dispatcher = value;
    if (owner != null) _claimPosition(_position);
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

  /// Whether [physics] lets the user move the position right now. Always
  /// true without a physics, which is the framework's own behaviour.
  bool get _acceptsUserOffset =>
      physics?.shouldAcceptUserOffset(_position) ?? true;

  @override
  void handlePointerEvent(PointerEvent event) {
    if (event is PointerScrollEvent) {
      if (!wheelEnabled) return;
      // As Flutter's Scrollable: a notch along the other axis, or one over a
      // view the user may not scroll, is not this view's to claim - the view
      // around it gets the chance instead. Claiming it would win the
      // resolver and then move nothing: a vertical wheel over a horizontal
      // strip inside a vertical page would never reach the page.
      final double delta =
          _vertical ? event.scrollDelta.dy : event.scrollDelta.dx;
      if (delta == 0 || !_acceptsUserOffset) return;
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
    // A wheel notch also stops an animation, as Flutter's pointerScroll goes
    // idle first.
    _position.beginActivity(null);
    final double delta =
        _vertical ? event.scrollDelta.dy : event.scrollDelta.dx;
    final double pixelDelta = _directed(delta);
    if (pixelDelta != 0) {
      _position.updateUserScrollDirection(
        pixelDelta < 0 ? ScrollDirection.forward : ScrollDirection.reverse,
      );
    }
    final double remainder = _position.applyScrollDelta(
      pixelDelta,
      inLines: event.scrollDeltaUnit == ScrollDeltaUnit.lines,
    );
    if (!_position.isScrolling) {
      _position.updateUserScrollDirection(ScrollDirection.idle);
    }
    if (remainder != 0) _chain(_directed(remainder));
  }

  /// Applies [delta] handed down from an inner scrollable that could not use
  /// all of it, chaining any remainder further out.
  ///
  /// [delta] is physical - in the sense of an unreversed view - so that a
  /// reversed list nested in an ordinary page hands the page the movement the
  /// user made rather than its own mirror image.
  void applyChained(double delta) {
    final double remainder = _position.applyDelta(_directed(delta));
    if (remainder != 0) _chain(_directed(remainder));
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
        ..onEnd = _onDragEnd
        ..onCancel = _onDragCancel;

  /// Whether the drag under way is moving this view. False for one the
  /// physics refused when it started, which then only chains.
  bool _dragAccepted = true;

  void _onDragStart(DragStartDetails details) {
    _momentum?.stop();
    _position.beginActivity(null);
    _dragAccepted = _acceptsUserOffset;
    if (_dragAccepted) _position.didStartScroll(details);
  }

  void _onDragUpdate(DragUpdateDetails details) {
    final double delta = _vertical ? details.delta.dy : details.delta.dx;
    if (delta == 0) return;
    // Flutter's user offset: positive towards offset zero, which is the
    // finger's own direction on an unreversed view.
    final double userOffset = _directed(delta);
    if (!_dragAccepted) {
      _chain(_directed(-userOffset));
      return;
    }
    _position.updateUserScrollDirection(
      userOffset > 0 ? ScrollDirection.forward : ScrollDirection.reverse,
    );
    _position.userDetails = details;
    try {
      final ScrollPhysics? physics = this.physics;
      if (physics == null || _position.coordinator != null) {
        // Negated: the content follows the finger, so a finger moving down
        // means a smaller offset. Overscroll is allowed here and settled on
        // release, which is what makes a rubber-band possible for a position
        // that asked for one and changes nothing for the default allowance of
        // zero.
        final double pixelDelta = physics == null
            ? -userOffset
            : -physics.applyPhysicsToUserOffset(_position, userOffset);
        final double remainder =
            _position.applyDelta(pixelDelta, allowOverscroll: true);
        if (remainder != 0) _chain(_directed(remainder));
        return;
      }
      final double target = _position.pixels -
          physics.applyPhysicsToUserOffset(_position, userOffset);
      final double overscroll =
          physics.applyBoundaryConditions(_position, target);
      _position.forcePixels(target - overscroll);
      if (overscroll != 0) {
        _position.didOverscrollBy(overscroll);
        _chain(_directed(overscroll));
      }
    } finally {
      _position.userDetails = null;
    }
  }

  void _onDragEnd(DragEndDetails details) {
    if (!_dragAccepted) return;
    final double velocity = _vertical
        ? details.velocity.pixelsPerSecond.dy
        : details.velocity.pixelsPerSecond.dx;
    final ScrollPhysics? physics = this.physics;
    if (physics != null) {
      _goBallistic(physics, _directed(-velocity), details);
      return;
    }
    if (_position.pixels < 0) {
      _position.setPixels(0);
      _position.didEndScroll(details);
      return;
    }
    if (_position.pixels > _position.maxScrollExtent) {
      _position.setPixels(_position.maxScrollExtent);
      _position.didEndScroll(details);
      return;
    }
    final ScrollMomentum? momentum = this.momentum;
    if (velocity == 0 || momentum == null) {
      _position.didEndScroll(details);
      return;
    }
    momentum.start(_directed(-velocity));
  }

  void _onDragCancel() {
    if (!_dragAccepted) return;
    final ScrollPhysics? physics = this.physics;
    if (physics != null) {
      _goBallistic(physics, 0, null);
      return;
    }
    _position.didEndScroll();
  }

  /// Hands the position to [physics] after a release at [velocity] (in
  /// offset terms): a fling, a spring back, a spring to a page - or nothing.
  void _goBallistic(ScrollPhysics physics, double velocity, Object? details) {
    final double clamped = velocity.abs() < physics.minFlingVelocity
        ? 0.0
        : velocity.clamp(-physics.maxFlingVelocity, physics.maxFlingVelocity);
    final Simulation? simulation =
        physics.createBallisticSimulation(_position, clamped);
    if (simulation == null) {
      _position.didEndScroll(details);
      return;
    }
    final ScrollMomentum? momentum = this.momentum;
    if (momentum == null) {
      ScrollMomentum.settleSimulation(
        _position,
        simulation,
        physics: physics,
        step: _momentumStep,
      );
      _position.didEndScroll(details);
      return;
    }
    momentum.runSimulation(simulation, physics: physics);
  }

  /// Settles the position the way [physics] would after a programmatic or
  /// keyboard move left it between pages or past an edge - Flutter's
  /// `goBallistic(0)`. Does nothing without a physics.
  void goBallistic([double velocity = 0]) {
    final ScrollPhysics? physics = this.physics;
    if (physics == null) return;
    _goBallistic(physics, velocity, null);
  }

  // ---------------------------------------------------------------------------
  // ScrollActivityListener: the position's events as Flutter's notifications
  // ---------------------------------------------------------------------------

  BuildContext? get _context {
    final BuildContext? context = notificationContext;
    return context != null && context.mounted ? context : null;
  }

  @override
  void didStartScroll(ScrollPosition position, Object? details) {
    final BuildContext? context = _context;
    if (context == null) return;
    ScrollStartNotification(
      metrics: position.copyWith(),
      context: context,
      dragDetails: details is DragStartDetails ? details : null,
    ).dispatch(context);
  }

  @override
  void didUpdateScrollPositionBy(
    ScrollPosition position,
    double delta,
    Object? details,
  ) {
    final BuildContext? context = _context;
    if (context == null) return;
    ScrollUpdateNotification(
      metrics: position.copyWith(),
      context: context,
      scrollDelta: delta,
      dragDetails: details is DragUpdateDetails ? details : null,
    ).dispatch(context);
  }

  @override
  void didOverscrollBy(
    ScrollPosition position,
    double overscroll,
    Object? details,
  ) {
    final BuildContext? context = _context;
    if (context == null) return;
    OverscrollNotification(
      metrics: position.copyWith(),
      context: context,
      overscroll: overscroll,
      velocity: position.velocity,
      dragDetails: details is DragUpdateDetails ? details : null,
    ).dispatch(context);
  }

  @override
  void didEndScroll(ScrollPosition position, Object? details) {
    final BuildContext? context = _context;
    if (context == null) return;
    ScrollEndNotification(
      metrics: position.copyWith(),
      context: context,
      dragDetails: details is DragEndDetails ? details : null,
    ).dispatch(context);
  }

  @override
  void didUpdateScrollDirection(
    ScrollPosition position,
    ScrollDirection direction,
  ) {
    final BuildContext? context = _context;
    if (context == null) return;
    UserScrollNotification(
      metrics: position.copyWith(),
      context: context,
      direction: direction,
    ).dispatch(context);
  }

  bool _metricsPosted = false;

  /// Posted, not sent: the change is found during layout, and a listener
  /// that rebuilds in answer must not do it in the middle of one. Without a
  /// dispatcher there is nowhere to post it, and none is sent.
  @override
  void didChangeMetrics(ScrollPosition position) {
    final UiDispatcher? dispatcher = _dispatcher;
    if (_metricsPosted || dispatcher == null || _context == null) return;
    _metricsPosted = true;
    dispatcher.post(() {
      _metricsPosted = false;
      final BuildContext? context = _context;
      if (context == null || owner == null) return;
      ScrollMetricsNotification(
        metrics: _position.copyWith(),
        context: context,
      ).dispatch(context);
    });
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
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _claimPosition(_position);
    _nestedHost = _findNestedHost();
    _nestedHost?.attachInnerPosition(_position);
  }

  /// The nearest [NestedScrollHost] above, unless a scrollable on the same
  /// axis is nearer - this one is then nested in *that* one.
  NestedScrollHost? _findNestedHost() {
    for (RenderBox? node = parent; node != null; node = node.parent) {
      if (node is NestedScrollHost) return node as NestedScrollHost;
      if (node is RenderScrollGestures &&
          node.position.axis == _position.axis) {
        return null;
      }
    }
    return null;
  }

  @override
  void detach() {
    // A recognizer holding an arena entry from a detached node never resolves
    // it, and an unresolved arena swallows every later press on that pointer.
    _drag?.cancelPending();
    _discardMomentum();
    _releasePosition(_position);
    _nestedHost?.detachInnerPosition(_position);
    _nestedHost = null;
    super.detach();
  }
}

/// Shows one window onto a child laid out in full.
///
/// Takes Flutter's parameters as well as this framework's: `scrollDirection`
/// is the same value as `axis` (the one given wins), `controller` takes a
/// `ScrollController` or a [ScrollPosition], and `reverse`, `padding` and
/// `physics` behave as in Flutter. `primary` is accepted and has no effect:
/// there is no `PrimaryScrollController` here. Along an unbounded axis the
/// view is as long as its child, as in Flutter.
final class SingleChildScrollView extends StatefulWidget {
  const SingleChildScrollView({
    super.key,
    this.child,
    ScrollAxis axis = ScrollAxis.vertical,
    Axis? scrollDirection,
    this.reverse = false,
    this.padding,
    this.primary,
    this.physics,
    this.controller,
    this.scrollbar = ScrollbarVisibility.always,
    this.scrollbarThickness,
    this.contentAlignment = ScrollContentAlignment.start,
    this.dragEnabled = true,
    this.mouseDragEnabled = true,
    this.dispatcher,
  }) : axis = scrollDirection ?? axis;

  final Widget? child;
  final ScrollAxis axis;

  /// Flutter's name for [axis].
  Axis get scrollDirection => axis;

  /// Whether offset zero shows the end of the child (its bottom, or right).
  final bool reverse;

  /// Space around the child, inside the scroll: it scrolls with the child.
  final EdgeInsetsGeometry? padding;

  /// Accepted for Flutter compatibility; has no effect here.
  final bool? primary;

  /// How the view answers the user. Null keeps the framework's own
  /// scrolling; see [Scrollable.physics].
  final ScrollPhysics? physics;

  /// What drives the offset: a `ScrollController`, or a [ScrollPosition].
  /// One is created when this is null.
  final ScrollPositionSource? controller;

  final ScrollbarVisibility scrollbar;
  final double? scrollbarThickness;
  final ScrollContentAlignment contentAlignment;
  final bool dragEnabled;
  final bool mouseDragEnabled;
  final UiDispatcher? dispatcher;

  @override
  State<SingleChildScrollView> createState() => _SingleChildScrollViewState();
}

final class _SingleChildScrollViewState extends State<SingleChildScrollView> {
  final ScrollPositionAttachment _attachment = ScrollPositionAttachment();

  /// The position this view is driving, for a caller holding the widget.
  ScrollPosition get position => _attachment.position;

  @override
  void dispose() {
    _attachment.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ScrollPosition position =
        _attachment.update(widget.controller, widget.axis);
    final EdgeInsetsGeometry? padding = widget.padding;
    Widget? child = widget.child;
    if (padding != null) {
      child = Padding(padding: _resolvePadding(padding, context), child: child);
    }
    final Widget scrollable = Scrollable(
      position: position,
      reverse: widget.reverse,
      physics: widget.physics,
      dragEnabled: widget.dragEnabled,
      mouseDragEnabled: widget.mouseDragEnabled,
      dispatcher: widget.dispatcher,
      child: _ViewportWidget(
        position: position,
        contentAlignment: widget.contentAlignment,
        reverse: widget.reverse,
        child: child ?? const SizedBox(),
      ),
    );
    if (widget.scrollbar == ScrollbarVisibility.never) return scrollable;
    return Scrollbar(
      position: position,
      visibility: widget.scrollbar,
      thickness: widget.scrollbarThickness,
      dispatcher: widget.dispatcher,
      reverse: widget.reverse,
      child: scrollable,
    );
  }
}

/// [padding] made physical. Only a directional padding needs a
/// [Directionality]; a physical one is used as it is.
EdgeInsets _resolvePadding(EdgeInsetsGeometry padding, BuildContext context) =>
    padding is EdgeInsets
        ? padding
        : padding.resolve(Directionality.of(context));

final class _ViewportWidget extends SingleChildRenderObjectWidget {
  const _ViewportWidget({
    required this.position,
    required this.contentAlignment,
    required this.reverse,
    required Widget super.child,
  });

  final ScrollPosition position;
  final ScrollContentAlignment contentAlignment;
  final bool reverse;

  @override
  RenderViewport createRenderObject(BuildContext context) => RenderViewport(
        position: position,
        contentAlignment: contentAlignment,
        reverse: reverse,
      );

  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderViewport object,
  ) {
    object
      ..position = position
      ..contentAlignment = contentAlignment
      ..reverse = reverse;
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
///
/// ## Flutter's parameters
///
/// `scrollDirection` is the same value as `axis` (the one given wins);
/// `controller` takes a `ScrollController` or a [ScrollPosition]; `physics`,
/// `reverse`, `padding` and `shrinkWrap` behave as in Flutter, and
/// [ListView.separated] is here. `primary` is accepted and has no effect.
/// A list with `reverse`, `padding` or `shrinkWrap` is built from slivers -
/// a [CustomScrollView] with a [SliverList] - since that is what those
/// options are made of; without them it is this file's own virtual list.
///
/// Differences: `itemCount` is required (there is no endless list, because
/// the content's extent has to be known for the scrollbar), an item builder
/// that returns null leaves an empty slot rather than ending the list, and
/// `cacheExtent` defaults to zero.
final class ListView extends StatefulWidget {
  ListView({
    super.key,
    List<Widget> children = const <Widget>[],
    this.itemExtent,
    this.estimatedItemExtent = 40.0,
    this.cacheExtent = 0.0,
    this.controller,
    ScrollAxis axis = ScrollAxis.vertical,
    Axis? scrollDirection,
    this.reverse = false,
    this.padding,
    this.primary,
    this.physics,
    this.shrinkWrap = false,
    this.scrollbar = ScrollbarVisibility.always,
    this.scrollbarThickness,
    this.dragEnabled = true,
    this.mouseDragEnabled = true,
    this.dispatcher,
  })  : axis = scrollDirection ?? axis,
        itemCount = children.length,
        itemBuilder = _builderOver(children);

  const ListView.builder({
    super.key,
    required this.itemCount,
    required this.itemBuilder,
    this.itemExtent,
    this.estimatedItemExtent = 40.0,
    this.cacheExtent = 0.0,
    this.controller,
    ScrollAxis axis = ScrollAxis.vertical,
    Axis? scrollDirection,
    this.reverse = false,
    this.padding,
    this.primary,
    this.physics,
    this.shrinkWrap = false,
    this.scrollbar = ScrollbarVisibility.always,
    this.scrollbarThickness,
    this.dragEnabled = true,
    this.mouseDragEnabled = true,
    this.dispatcher,
  }) : axis = scrollDirection ?? axis;

  /// [itemCount] items with a separator between each two: the separators are
  /// items of the list too, built by [separatorBuilder] for the gap after
  /// item `index`.
  ListView.separated({
    super.key,
    required int itemCount,
    required Widget? Function(BuildContext context, int index) itemBuilder,
    required Widget Function(BuildContext context, int index) separatorBuilder,
    this.estimatedItemExtent = 40.0,
    this.cacheExtent = 0.0,
    this.controller,
    ScrollAxis axis = ScrollAxis.vertical,
    Axis? scrollDirection,
    this.reverse = false,
    this.padding,
    this.primary,
    this.physics,
    this.shrinkWrap = false,
    this.scrollbar = ScrollbarVisibility.always,
    this.scrollbarThickness,
    this.dragEnabled = true,
    this.mouseDragEnabled = true,
    this.dispatcher,
  })  : axis = scrollDirection ?? axis,
        itemExtent = null,
        itemCount = itemCount <= 0 ? 0 : itemCount * 2 - 1,
        itemBuilder = ((BuildContext context, int index) => index.isEven
            ? itemBuilder(context, index ~/ 2)
            : separatorBuilder(context, index ~/ 2));

  final int itemCount;

  /// Called only for realized indices - the visible window plus [cacheExtent]
  /// either side. A list of 100 000 items calls this a few dozen times per
  /// frame, which is the whole point of the widget. A null answer leaves the
  /// slot empty.
  final Widget? Function(BuildContext context, int index) itemBuilder;

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

  /// What drives the offset: a `ScrollController`, or a [ScrollPosition].
  /// One is created when this is null.
  final ScrollPositionSource? controller;
  final ScrollAxis axis;

  /// Flutter's name for [axis].
  Axis get scrollDirection => axis;

  /// Whether the list starts at the bottom (or right) and grows upwards.
  final bool reverse;

  /// Space around the items, inside the scroll.
  final EdgeInsetsGeometry? padding;

  /// Accepted for Flutter compatibility; has no effect here.
  final bool? primary;

  /// How the list answers the user; null keeps the framework's own
  /// scrolling. See [Scrollable.physics].
  final ScrollPhysics? physics;

  /// Whether the list is as long as its items (up to the space it is given)
  /// rather than as long as it is allowed to be - what lets a list sit in a
  /// column without an `Expanded`.
  final bool shrinkWrap;

  final ScrollbarVisibility scrollbar;
  final double? scrollbarThickness;
  final bool dragEnabled;
  final bool mouseDragEnabled;
  final UiDispatcher? dispatcher;

  /// Whether this list is built from slivers; see the class documentation.
  bool get _usesSlivers => reverse || padding != null || shrinkWrap;

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
  /// layout and the list rebuilds against it inside the same settle loop, so
  /// the guess never reaches the screen. Guessing high builds items that are
  /// immediately discarded; guessing low costs one extra settle pass.
  static const int _initialWindowItems = 8;

  /// The ceiling on that guess, in pixels.
  ///
  /// Eight items is a plausible screenful of 40-pixel rows, but the estimate
  /// scales with the items and not with the screen: eight 860-pixel PDF pages
  /// are seven thousand pixels of items built, painted once and immediately
  /// discarded - which was the dominant cost of a freshly opened document's
  /// first frame. No screen is assumed taller than this until one has been
  /// measured.
  static const double _initialViewportCeiling = 1024;

  final ScrollPositionAttachment _attachment = ScrollPositionAttachment();
  ScrollPosition? _listened;
  ListVirtualization? _plan;

  ScrollPosition get _position => _attachment.position;

  /// Attaches the position for the current widget, and listens to it.
  ScrollPosition _resolvePosition() {
    final ScrollPosition position =
        _attachment.update(widget.controller, widget.axis);
    if (!identical(position, _listened)) {
      _listened?.removeListener(_onScrolled);
      position.addListener(_onScrolled);
      _listened = position;
    }
    return position;
  }

  @override
  void dispose() {
    _listened?.removeListener(_onScrolled);
    _listened = null;
    _attachment.dispose();
    super.dispose();
  }

  // Scrolling changes which items exist, so it is a rebuild and not merely a
  // repaint - that difference is what virtualization *is*. The same listener
  // covers the viewport being measured for the first time and the offset being
  // re-clamped by a list that shrank, both of which change the window too.
  // A sliver-built list realizes its window during layout and needs none.
  void _onScrolled(ScrollPosition position) {
    if (mounted && !widget._usesSlivers) setState(() {});
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
    if (measured > 0) return measured;
    final double guessed = _estimate * _initialWindowItems;
    if (guessed <= _initialViewportCeiling) return guessed;
    // At least one full item, so a list of items taller than the ceiling
    // still realizes something to measure.
    return _estimate > _initialViewportCeiling
        ? _estimate
        : _initialViewportCeiling;
  }

  Widget _item(BuildContext context, int index) =>
      widget.itemBuilder(context, index) ?? const SizedBox();

  @override
  Widget build(BuildContext context) {
    final ScrollPosition position = _resolvePosition();
    if (widget._usesSlivers) return _buildFromSlivers(context, position);
    final ListVirtualization virtualization = _virtualization;
    final RealizedRange range = virtualization.rangeFor(
      scrollOffset: position.pixels,
      viewportExtent: _viewportExtent,
    );
    final Widget scrollable = Scrollable(
      position: position,
      physics: widget.physics,
      dragEnabled: widget.dragEnabled,
      mouseDragEnabled: widget.mouseDragEnabled,
      dispatcher: widget.dispatcher,
      child: _VirtualList(
        position: position,
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
              child: _item(context, index),
            ),
        ],
      ),
    );
    if (widget.scrollbar == ScrollbarVisibility.never) return scrollable;
    return Scrollbar(
      position: position,
      visibility: widget.scrollbar,
      thickness: widget.scrollbarThickness,
      dispatcher: widget.dispatcher,
      child: scrollable,
    );
  }

  /// The list as a [CustomScrollView] of one [SliverList], for the options
  /// that are sliver features: reverse, padding, shrink-wrapping.
  Widget _buildFromSlivers(BuildContext context, ScrollPosition position) {
    final SliverChildBuilderDelegate delegate = SliverChildBuilderDelegate(
      _item,
      childCount: widget.itemCount,
    );
    final double? itemExtent = widget.itemExtent;
    Widget sliver = itemExtent != null
        ? SliverFixedExtentList(delegate: delegate, itemExtent: itemExtent)
        : SliverList(
            delegate: delegate,
            estimatedItemExtent: widget.estimatedItemExtent,
          );
    final EdgeInsetsGeometry? padding = widget.padding;
    if (padding != null) {
      sliver = SliverPadding(
        padding: _resolvePadding(padding, context),
        sliver: sliver,
      );
    }
    return CustomScrollView(
      controller: position,
      axis: position.axis,
      reverse: widget.reverse,
      physics: widget.physics,
      shrinkWrap: widget.shrinkWrap,
      cacheExtent: widget.cacheExtent,
      scrollbar: widget.scrollbar,
      scrollbarThickness: widget.scrollbarThickness,
      dragEnabled: widget.dragEnabled,
      mouseDragEnabled: widget.mouseDragEnabled,
      focusable: false,
      dispatcher: widget.dispatcher,
      slivers: <Widget>[sliver],
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

/// A scrolling grid.
///
/// Flutter's constructors build it from slivers - a [CustomScrollView] with
/// one [SliverGrid] laid out by a [SliverGridDelegate]:
///
/// ```dart
/// GridView.count(crossAxisCount: 3, children: tiles)
/// GridView.extent(maxCrossAxisExtent: 160, children: tiles)
/// GridView.builder(
///   gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
///     crossAxisCount: 4),
///   itemCount: photos.length,
///   itemBuilder: (BuildContext context, int index) => Photo(photos[index]),
/// )
/// ```
///
/// [GridView.builder] also keeps this framework's older form, with
/// [crossAxisCount] and [rowExtent] and no delegate: equal cells in rows of a
/// fixed height, built as a [ListView.builder] of rows.
///
/// Differences from Flutter: `itemCount` is required; `primary` is accepted
/// and has no effect.
final class GridView extends StatelessWidget {
  /// A grid of [children] laid out by [gridDelegate].
  GridView({
    super.key,
    required SliverGridDelegate this.gridDelegate,
    List<Widget> children = const <Widget>[],
    this.cacheExtent = 0.0,
    this.controller,
    ScrollAxis axis = ScrollAxis.vertical,
    Axis? scrollDirection,
    this.reverse = false,
    this.padding,
    this.primary,
    this.physics,
    this.shrinkWrap = false,
    this.scrollbar = ScrollbarVisibility.always,
    this.dragEnabled = true,
    this.dispatcher,
  })  : axis = scrollDirection ?? axis,
        itemCount = children.length,
        itemBuilder = ((BuildContext context, int index) => children[index]),
        crossAxisCount = null,
        rowExtent = null;

  /// A grid whose cells are built on demand: by [gridDelegate], or - this
  /// framework's older form - in rows of [crossAxisCount] cells [rowExtent]
  /// high.
  const GridView.builder({
    super.key,
    required this.itemCount,
    required this.itemBuilder,
    this.gridDelegate,
    this.crossAxisCount,
    this.rowExtent,
    this.cacheExtent = 0.0,
    this.controller,
    ScrollAxis axis = ScrollAxis.vertical,
    Axis? scrollDirection,
    this.reverse = false,
    this.padding,
    this.primary,
    this.physics,
    this.shrinkWrap = false,
    this.scrollbar = ScrollbarVisibility.always,
    this.dragEnabled = true,
    this.dispatcher,
  }) : axis = scrollDirection ?? axis;

  /// A fixed number of columns ([crossAxisCount]) of cells
  /// [childAspectRatio] wide per unit of height.
  GridView.count({
    super.key,
    required int crossAxisCount,
    double mainAxisSpacing = 0.0,
    double crossAxisSpacing = 0.0,
    double childAspectRatio = 1.0,
    List<Widget> children = const <Widget>[],
    this.cacheExtent = 0.0,
    this.controller,
    ScrollAxis axis = ScrollAxis.vertical,
    Axis? scrollDirection,
    this.reverse = false,
    this.padding,
    this.primary,
    this.physics,
    this.shrinkWrap = false,
    this.scrollbar = ScrollbarVisibility.always,
    this.dragEnabled = true,
    this.dispatcher,
  })  : axis = scrollDirection ?? axis,
        gridDelegate = SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: crossAxisCount,
          mainAxisSpacing: mainAxisSpacing,
          crossAxisSpacing: crossAxisSpacing,
          childAspectRatio: childAspectRatio,
        ),
        itemCount = children.length,
        itemBuilder = ((BuildContext context, int index) => children[index]),
        crossAxisCount = null,
        rowExtent = null;

  /// As many columns as fit at no more than [maxCrossAxisExtent] each.
  GridView.extent({
    super.key,
    required double maxCrossAxisExtent,
    double mainAxisSpacing = 0.0,
    double crossAxisSpacing = 0.0,
    double childAspectRatio = 1.0,
    List<Widget> children = const <Widget>[],
    this.cacheExtent = 0.0,
    this.controller,
    ScrollAxis axis = ScrollAxis.vertical,
    Axis? scrollDirection,
    this.reverse = false,
    this.padding,
    this.primary,
    this.physics,
    this.shrinkWrap = false,
    this.scrollbar = ScrollbarVisibility.always,
    this.dragEnabled = true,
    this.dispatcher,
  })  : axis = scrollDirection ?? axis,
        gridDelegate = SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: maxCrossAxisExtent,
          mainAxisSpacing: mainAxisSpacing,
          crossAxisSpacing: crossAxisSpacing,
          childAspectRatio: childAspectRatio,
        ),
        itemCount = children.length,
        itemBuilder = ((BuildContext context, int index) => children[index]),
        crossAxisCount = null,
        rowExtent = null;

  final int itemCount;

  /// Called only for the cells being shown. A null answer leaves the cell
  /// empty.
  final Widget? Function(BuildContext context, int index) itemBuilder;

  /// How the cells are laid out. Null only for the older
  /// [crossAxisCount]/[rowExtent] form of [GridView.builder].
  final SliverGridDelegate? gridDelegate;

  /// How many cells fit across the grid, in the older form. The cross axis
  /// is divided equally.
  final int? crossAxisCount;

  /// The height of one row, in the older form.
  final double? rowExtent;

  final double cacheExtent;

  /// What drives the offset: a `ScrollController`, or a [ScrollPosition].
  final ScrollPositionSource? controller;
  final ScrollAxis axis;

  /// Flutter's name for [axis].
  Axis get scrollDirection => axis;

  final bool reverse;
  final EdgeInsetsGeometry? padding;

  /// Accepted for Flutter compatibility; has no effect here.
  final bool? primary;
  final ScrollPhysics? physics;
  final bool shrinkWrap;
  final ScrollbarVisibility scrollbar;
  final bool dragEnabled;
  final UiDispatcher? dispatcher;

  /// How many rows the items make up in the older form, the trailing partial
  /// row included.
  int get rowCount {
    final int columns = crossAxisCount ?? 1;
    return (itemCount + columns - 1) ~/ columns;
  }

  Widget _cell(BuildContext context, int index) =>
      itemBuilder(context, index) ?? const SizedBox();

  @override
  Widget build(BuildContext context) {
    final SliverGridDelegate? gridDelegate = this.gridDelegate;
    if (gridDelegate != null) {
      Widget sliver = SliverGrid(
        gridDelegate: gridDelegate,
        delegate: SliverChildBuilderDelegate(_cell, childCount: itemCount),
      );
      final EdgeInsetsGeometry? padding = this.padding;
      if (padding != null) {
        sliver = SliverPadding(
          padding: _resolvePadding(padding, context),
          sliver: sliver,
        );
      }
      return CustomScrollView(
        controller: controller,
        axis: axis,
        reverse: reverse,
        physics: physics,
        shrinkWrap: shrinkWrap,
        cacheExtent: cacheExtent,
        scrollbar: scrollbar,
        dragEnabled: dragEnabled,
        focusable: false,
        dispatcher: dispatcher,
        slivers: <Widget>[sliver],
      );
    }
    final int? columns = crossAxisCount;
    final double? rowExtent = this.rowExtent;
    if (columns == null || rowExtent == null) {
      throw ArgumentError(
        'GridView.builder needs a gridDelegate, or both crossAxisCount and '
        'rowExtent',
      );
    }
    if (columns <= 0) {
      throw ArgumentError.value(
        columns,
        'crossAxisCount',
        'a grid needs at least one column',
      );
    }
    return ListView.builder(
      itemCount: rowCount,
      itemExtent: rowExtent,
      cacheExtent: cacheExtent,
      controller: controller,
      axis: axis,
      reverse: reverse,
      padding: padding,
      physics: physics,
      shrinkWrap: shrinkWrap,
      scrollbar: scrollbar,
      dragEnabled: dragEnabled,
      dispatcher: dispatcher,
      itemBuilder: (BuildContext context, int row) {
        final List<Widget> cells = <Widget>[
          for (int column = 0; column < columns; column++)
            Expanded(
              // The trailing row is padded with empty cells rather than
              // being narrower: a last row whose two items stretched across
              // the whole width would not line up with the columns above it.
              child: row * columns + column < itemCount
                  ? _cell(context, row * columns + column)
                  : const SizedBox(),
            ),
        ];
        return axis == ScrollAxis.vertical
            ? Row(children: cells)
            : Column(children: cells);
      },
    );
  }
}
