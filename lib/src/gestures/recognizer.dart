/// The contract every gesture recognizer implements, and its lifecycle.
///
/// A recognizer is a small state machine with one job: watch a pointer, and
/// decide whether the motion it produces is *its* gesture. It never decides
/// alone - see `arena.dart` - so the contract is deliberately narrow:
///
///  1. **Offer.** A press arrives at [GestureRecognizer.addPointer]. The
///     recognizer either declines - wrong button, wrong device, already busy -
///     or joins the pointer's arena and starts tracking.
///  2. **Follow.** Every subsequent event for that pointer arrives at
///     [GestureRecognizer.handleEvent]. The recognizer accumulates evidence.
///  3. **Claim or concede.** As soon as the evidence is conclusive it calls
///     [GestureRecognizer.resolve]. Claiming early is how a drag beats a tap;
///     conceding early is how a tap gets out of a drag's way. A recognizer
///     that never does either still gets an answer, by walkover or by sweep.
///  4. **Settle.** Exactly one of [GestureArenaMember.acceptGesture] or
///     [GestureArenaMember.rejectGesture] arrives. Callbacks fire from the
///     first; cleanup happens in both.
///  5. **Release.** The pointer goes up or is cancelled, tracking stops, and
///     the recognizer is ready for the next press.
///
/// Step 4 is the one worth stating twice: **a recognizer must not fire its
/// callback when it decides, only when it wins.** A tap that fired on the
/// release without waiting for the arena would fire inside a scroll.
library;

import 'package:meta/meta.dart';

import '../geometry/offset.dart';
import '../platform/input_events.dart';
import '../scheduler/timer_handle.dart';
import '../scheduler/ui_dispatcher.dart';
import 'arena.dart';
import 'binding.dart';
import 'constants.dart';
import 'velocity_tracker.dart';

/// Base class for every gesture recognizer.
abstract class GestureRecognizer implements GestureArenaMember {
  GestureRecognizer({GestureArenaManager? arena, this.debugOwner})
      : _explicitArena = arena;

  final GestureArenaManager? _explicitArena;

  /// Whatever the owner wants to see in a diagnostic - usually the render
  /// object that created this recognizer.
  final Object? debugOwner;

  /// Seats held in arenas, keyed by pointer.
  ///
  /// This map is also the answer to "am I tracking this pointer": an entry
  /// survives the arena resolving, and is removed by [stopTrackingPointer]
  /// when the gesture itself is over. A recognizer that won on the press still
  /// needs every move that follows.
  final Map<int, GestureArenaEntry> _entries = <int, GestureArenaEntry>{};

  bool _disposed = false;

  /// The arena this recognizer negotiates in.
  ///
  /// The one passed at construction if there was one, otherwise the binding
  /// published by the router currently dispatching - see `binding.dart` for
  /// why that fallback exists and why it is not a global.
  GestureArenaManager get arena =>
      _explicitArena ?? GestureBinding.ambient.arena;

  /// Whether this recognizer is following [pointer].
  bool isTrackingPointer(int pointer) => _entries.containsKey(pointer);

  /// How many pointers this recognizer is following. A pinch needs two; a tap
  /// declines the second.
  int get trackedPointerCount => _entries.length;

  /// Offers a fresh press to this recognizer.
  ///
  /// Returns whether the recognizer took an interest. Implementations that
  /// accept must call [enterArena].
  bool addPointer(PointerDownEvent event);

  /// Delivers a later event for a pointer this recognizer is following.
  ///
  /// Never called for an untracked pointer: [routeEvent] filters first.
  @protected
  void handleEvent(PointerEvent event);

  /// The single entry point an owner uses. Routes a press to [addPointer] and
  /// everything else to [handleEvent], ignoring pointers not being followed.
  void routeEvent(PointerEvent event) {
    if (_disposed) return;
    if (event is PointerDownEvent) {
      addPointer(event);
      return;
    }
    if (!_entries.containsKey(event.pointerId)) return;
    handleEvent(event);
  }

  /// Joins [pointer]'s arena and starts following it.
  @protected
  void enterArena(int pointer) {
    _entries[pointer] = arena.add(pointer, this);
  }

  /// Claims or concedes for every pointer being followed.
  @protected
  void resolve(GestureDisposition disposition) {
    // Snapshotted: resolving calls back into rejectGesture, which usually
    // calls stopTrackingPointer, which mutates the map being walked.
    for (final GestureArenaEntry entry in _entries.values.toList()) {
      entry.resolve(disposition);
    }
  }

  /// Claims or concedes for one pointer only.
  @protected
  void resolvePointer(int pointer, GestureDisposition disposition) {
    _entries[pointer]?.resolve(disposition);
  }

  /// Stops following [pointer]. Idempotent.
  @protected
  void stopTrackingPointer(int pointer) {
    _entries.remove(pointer);
  }

  @override
  void acceptGesture(int pointer) {}

  @override
  void rejectGesture(int pointer) {
    stopTrackingPointer(pointer);
  }

  /// Concedes every pointer currently being followed, keeping the recognizer
  /// usable afterwards.
  ///
  /// For an owner that has to abandon a gesture in progress without going
  /// away itself - a render object detached from the pipeline, a control that
  /// lost the window's capture.
  void cancelPending() {
    if (_disposed) return;
    resolve(GestureDisposition.rejected);
  }

  /// Releases the recognizer, conceding anything still open.
  ///
  /// A recognizer whose render object left the tree must do this. An arena
  /// entry held by a detached node blocks the arena from ever resolving, which
  /// swallows every later press on that pointer - the same class of bug that
  /// `PointerRouter.releaseCaptureFor` exists to prevent on the capture side.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    resolve(GestureDisposition.rejected);
    _entries.clear();
  }

  /// Whether [dispose] has been called.
  bool get isDisposed => _disposed;

  @override
  String toString() =>
      '$runtimeType${debugOwner == null ? '' : '(owner: $debugOwner)'}';
}

/// A recognizer that follows exactly one pointer at a time.
///
/// Taps, long presses and single-finger drags all share the same three
/// mechanics, and they are here so that the three subclasses differ only where
/// they actually differ:
///
///  * **one pointer wins the recognizer.** A second finger arriving while the
///    first is being followed is declined outright rather than merged. Two
///    fingers on one button is not two taps and not a double tap;
///  * **slop from the press position**, measured with the threshold that
///    belongs to the device the press came from ([touchSlopForKind]);
///  * **an optional deadline**, armed on the press and disarmed by anything
///    that settles the gesture first.
abstract class PrimaryPointerGestureRecognizer extends GestureRecognizer {
  PrimaryPointerGestureRecognizer({
    super.arena,
    super.debugOwner,
    UiDispatcher? dispatcher,
    this.deadline,
    double? slop,
    PointerButton button = PointerButton.primary,
  })  : _dispatcher = dispatcher,
        _slopOverride = slop,
        _button = button {
    if (deadline != null && dispatcher == null) {
      throw ArgumentError.value(
        deadline,
        'deadline',
        'a deadline needs a UiDispatcher to arm it on; pass one explicitly or '
            'give the owning GestureBinding one. Reading a clock here instead '
            'would make every test that involves a long press intermittent.',
      );
    }
  }

  /// How long the press has to survive before [didExceedDeadline] runs, or
  /// null for a recognizer with no timeout.
  final Duration? deadline;

  final UiDispatcher? _dispatcher;
  final double? _slopOverride;
  final PointerButton _button;

  int? _primaryPointer;
  Offset _initialPosition = Offset.zero;
  Duration _initialTime = Duration.zero;
  PointerKind _kind = PointerKind.touch;
  TimerHandle? _timer;
  bool _hasWon = false;

  /// Whether a release at this global position still counts as landing on the
  /// target.
  ///
  /// The pointer is captured on the press, so the release arrives here even
  /// when it happened somewhere else entirely - which is exactly how a user
  /// takes back a tap they no longer want. A recognizer owned by a render
  /// object is given the object's own bounds test; one used standalone accepts
  /// a release anywhere.
  bool Function(Offset globalPosition)? targetContains;

  /// The pointer being followed, or null.
  int? get primaryPointer => _primaryPointer;

  /// Where the press landed.
  Offset get initialPosition => _initialPosition;

  /// When the press landed, as the platform timestamped it.
  Duration get initialTime => _initialTime;

  /// The device the press came from.
  PointerKind get pointerKind => _kind;

  /// The only button this recognizer answers to.
  PointerButton get button => _button;

  /// Whether this recognizer has already won its arena.
  bool get hasWonArena => _hasWon;

  /// The slop the owner insisted on, or null to use the device's default.
  @protected
  double? get slopOverride => _slopOverride;

  /// The distance this recognizer treats as "did not move".
  double get slop => _slopOverride ?? touchSlopForKind(_kind);

  @override
  bool addPointer(PointerDownEvent event) {
    if (_primaryPointer != null) return false;
    if (event.button != _button) return false;
    if (!shouldAcceptPress(event)) return false;
    _primaryPointer = event.pointerId;
    _initialPosition = event.logicalPosition;
    _initialTime = event.timestamp;
    _kind = event.kind;
    _hasWon = false;
    enterArena(event.pointerId);
    final Duration? deadline = this.deadline;
    if (deadline != null) {
      _timer = _dispatcher!.schedule(deadline, _onDeadline);
    }
    didPressDown(event);
    return true;
  }

  /// A last veto on a press before any state is taken. True by default.
  @protected
  bool shouldAcceptPress(PointerDownEvent event) => true;

  /// Runs once the press has been taken and the arena joined.
  @protected
  void didPressDown(PointerDownEvent event) {}

  /// Runs when [deadline] elapses with the gesture still undecided.
  @protected
  void didExceedDeadline() {}

  /// Runs for every event after the press, for the followed pointer.
  @protected
  void handlePrimaryPointer(PointerEvent event);

  @override
  void handleEvent(PointerEvent event) {
    if (event.pointerId != _primaryPointer) return;
    handlePrimaryPointer(event);
  }

  @override
  void acceptGesture(int pointer) {
    if (pointer != _primaryPointer) return;
    _hasWon = true;
  }

  @override
  void rejectGesture(int pointer) {
    if (pointer == _primaryPointer) _reset();
    super.rejectGesture(pointer);
  }

  /// Gives up on the pointer being followed, and stops following it.
  ///
  /// Conceding is two things, and doing only the first is a bug that shows up
  /// exactly once the recognizer is used *alone*: a lone recognizer wins its
  /// arena by walkover on the press, so by the time it decides to give up the
  /// arena no longer exists and [resolve] is a no-op. Without the second half
  /// the recognizer would keep following a gesture it has already disowned -
  /// a tap dragged forty pixels off the button would still fire.
  @protected
  void concede() {
    final int? pointer = primaryPointer;
    if (pointer == null) return;
    resolvePointer(pointer, GestureDisposition.rejected);
    // Unchanged means the arena had already resolved and nobody called
    // rejectGesture, so the same cleanup has to happen here.
    if (primaryPointer == pointer) rejectGesture(pointer);
  }

  /// How far the pointer is from where it pressed.
  @protected
  double distanceFromOrigin(Offset position) =>
      (position - _initialPosition).distance;

  /// Disarms the deadline and forgets the pointer.
  @protected
  void stopTracking() {
    final int? pointer = _primaryPointer;
    if (pointer != null) stopTrackingPointer(pointer);
    _reset();
  }

  void _reset() {
    _timer?.cancel();
    _timer = null;
    _primaryPointer = null;
    _hasWon = false;
  }

  void _onDeadline() {
    _timer = null;
    if (_primaryPointer == null) return;
    didExceedDeadline();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _timer = null;
    super.dispose();
  }
}

/// A recognizer that measures speed, for anything that can end in a fling.
///
/// One tracker per pointer, reused across gestures. Kept here rather than in
/// `drag.dart` because a scale gesture flings too - a two-finger pan that
/// releases with momentum is the same physics with a different focal point.
mixin VelocityTrackingRecognizer on GestureRecognizer {
  final Map<int, VelocityTracker> _trackers = <int, VelocityTracker>{};

  /// The tracker for [pointer], created on first use.
  @protected
  VelocityTracker trackerFor(int pointer, PointerKind kind) =>
      _trackers.putIfAbsent(pointer, () => VelocityTracker(kind: kind));

  /// Records [event]'s position against its own timestamp.
  ///
  /// This is the hot path - one call per `PointerMoveEvent`, which is one per
  /// mouse movement the OS reports - and it allocates nothing after the
  /// tracker exists.
  @protected
  void trackVelocity(PointerEvent event) {
    _trackers[event.pointerId]?.addPosition(
      event.timestamp,
      event.logicalPosition,
    );
  }

  /// The velocity for [pointer] as of [now], clamped into the range a fling
  /// simulation can survive, and zeroed below [kMinFlingVelocity].
  @protected
  Velocity flingVelocityFor(int pointer, Duration now) {
    final VelocityTracker? tracker = _trackers[pointer];
    if (tracker == null) return Velocity.zero;
    final VelocityEstimate? estimate = tracker.estimateAt(now);
    if (estimate == null) return Velocity.zero;
    final Velocity velocity = Velocity(
      pixelsPerSecond: estimate.pixelsPerSecond,
    );
    if (velocity.magnitude < kMinFlingVelocity) return Velocity.zero;
    return velocity.clampMagnitude(0, kMaxFlingVelocity);
  }

  /// Drops the tracker for [pointer] once its gesture is over.
  @protected
  void forgetVelocity(int pointer) {
    _trackers.remove(pointer);
  }
}
