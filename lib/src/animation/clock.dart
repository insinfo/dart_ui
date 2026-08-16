/// The animation clock: one monotonic timestamp, handed down from the frame.
///
/// ## Why nothing here may call `DateTime.now`
///
/// `manual_dispatcher.dart` exists so that the entire framework can be driven
/// by a virtual clock: "time only moves when [ManualDispatcher.advance] says
/// it moves". Every determinism guarantee in this repository rests on that.
/// The moment one layer reads the wall clock, a test that pumps two frames
/// stops producing the same numbers on a loaded CI runner as on a developer's
/// machine, and the failure shows up as a flake in some *other* test that
/// merely shares the animation.
///
/// So the rule is absolute and stated here in one place: **no file under
/// `lib/src/animation/` may call `DateTime.now`, `Stopwatch`, or any other
/// ambient clock.** Time enters this layer through exactly one door -
/// [AnimationClock.tick], called once per frame by the scheduler with the
/// timestamp of that frame. In production that timestamp is the backend's
/// vsync stamp; in a test it is [ManualDispatcher.elapsed]. Neither the
/// animations nor their tests can tell the difference, which is the property
/// that makes the whole thing testable.
///
/// ## Monotonicity
///
/// [AnimationClock.tick] rejects a timestamp earlier than the previous one
/// instead of clamping the delta to zero. A backwards stamp means the source
/// is not a monotonic counter - a wall clock adjusted by NTP, or two different
/// time bases mixed - and a silently clamped frame would turn that into an
/// animation that mysteriously stalls once a month. Section 6.6: fail loudly.
///
/// ## The first tick
///
/// A ticker registered mid-frame has no baseline yet. [AnimationClock] hands
/// every ticker the absolute frame timestamp, never a delta, and each ticker
/// decides its own origin. That is deliberate: a delta computed from the
/// clock's previous tick would make an animation started at t=5s jump forward
/// by however long the clock had been running, which is the classic "the
/// dialog finished its fade-in before it was visible" bug.
library;

import '../scheduler/frame_scheduler.dart';

/// Something that wants to be advanced once per frame.
///
/// Implemented by [AnimationController] and by the style transition runner.
/// The contract is deliberately narrow - one method, no return value, no
/// scheduling - because a ticker must not be able to reorder the frame it is
/// running inside.
abstract interface class AnimationTicker {
  /// Advances this ticker to [timestamp].
  ///
  /// [timestamp] is monotonic and comes from the frame, not from a clock the
  /// ticker read itself. Implementations must derive their own elapsed time
  /// from an origin they captured when they started; see the library
  /// documentation for why a shared delta would be wrong.
  void tick(Duration timestamp);

  /// Whether this ticker still needs frames.
  ///
  /// The clock uses this to decide whether to request another frame. A ticker
  /// that answers `false` is left registered but stops driving the loop, so
  /// starting it again does not have to re-register it.
  bool get isTicking;
}

/// Distributes one frame timestamp to every registered [AnimationTicker].
///
/// The clock owns no timer. Section 32.2 is explicit: "an animation asks for a
/// frame, it does not create a timer per property". One clock, one frame
/// callback, N animations - so a screen with forty transitions costs one
/// scheduler entry, not forty.
final class AnimationClock {
  AnimationClock();

  /// Registered tickers, in registration order.
  ///
  /// A plain list walked by index: iteration in [tick] is a hot path and a
  /// `Map` or an `Iterable` would allocate an iterator every frame
  /// (section 6.5).
  final List<AnimationTicker> _tickers = <AnimationTicker>[];

  /// Structural changes requested while [tick] is walking [_tickers].
  ///
  /// A controller that completes inside its own tick will typically remove
  /// itself, and mutating the list underneath the walk would skip its
  /// neighbour. Both buffers are allocated once and only ever cleared, so
  /// deferring costs no per-frame allocation.
  final List<AnimationTicker> _pendingAdditions = <AnimationTicker>[];
  final List<AnimationTicker> _pendingRemovals = <AnimationTicker>[];

  Duration _timestamp = Duration.zero;
  int _tickCount = 0;
  bool _ticking = false;
  bool _hasTicked = false;

  FrameScheduler? _scheduler;

  /// The timestamp of the most recent [tick]. Zero before the first one.
  Duration get timestamp => _timestamp;

  /// How many times [tick] has run. The counter a test uses to assert that a
  /// frame advanced animations exactly once.
  int get tickCount => _tickCount;

  /// How many tickers are registered, ticking or not.
  int get tickerCount => _tickers.length;

  /// Whether any registered ticker still needs frames.
  bool get hasActiveTickers {
    for (int i = 0; i < _tickers.length; i++) {
      if (_tickers[i].isTicking) return true;
    }
    return false;
  }

  /// The scheduler this clock is attached to, or null.
  FrameScheduler? get scheduler => _scheduler;

  /// Registers [ticker]. Registering the same ticker twice is an error, not a
  /// no-op: a double registration would advance it twice per frame, which is
  /// exactly the bug the once-per-frame test exists to catch.
  void addTicker(AnimationTicker ticker) {
    if (_contains(ticker)) {
      throw StateError(
        'this AnimationTicker is already registered; a second registration '
        'would advance it twice per frame',
      );
    }
    if (_ticking) {
      _pendingAdditions.add(ticker);
    } else {
      _tickers.add(ticker);
    }
    requestFrame();
  }

  /// Unregisters [ticker]. Returns whether it was registered.
  bool removeTicker(AnimationTicker ticker) {
    if (!_contains(ticker)) return false;
    if (_ticking) {
      _pendingRemovals.add(ticker);
    } else {
      _tickers.removeWhere((AnimationTicker other) => identical(other, ticker));
    }
    return true;
  }

  bool _contains(AnimationTicker ticker) {
    for (int i = 0; i < _tickers.length; i++) {
      if (identical(_tickers[i], ticker)) {
        return !_pendingRemovals
            .any((AnimationTicker r) => identical(r, ticker));
      }
    }
    return _pendingAdditions.any((AnimationTicker a) => identical(a, ticker));
  }

  /// Binds this clock to [scheduler] so it is ticked once per frame, before
  /// build/layout/paint.
  ///
  /// The direction of this dependency matters: the *clock* reaches into the
  /// scheduler, not the other way round. The scheduler stays a generic pulse
  /// coordinator that knows nothing about animation, which is what keeps the
  /// `scheduler` layer below `animation` in the dependency order.
  void attachTo(FrameScheduler scheduler) {
    if (_scheduler != null) {
      throw StateError(
          'this AnimationClock is already attached to a scheduler');
    }
    _scheduler = scheduler;
    scheduler.addFrameCallback(tick);
    if (hasActiveTickers) scheduler.scheduleNextFrame();
  }

  /// Unbinds from the scheduler. Safe to call when not attached.
  void detach() {
    _scheduler?.removeFrameCallback(tick);
    _scheduler = null;
  }

  /// Asks the attached scheduler for another frame, if any ticker needs one.
  ///
  /// Called after every tick and on every registration, so an animation that
  /// is still running keeps the loop alive and one that finished lets it go
  /// quiet. Without a scheduler this is a no-op: a clock driven manually by a
  /// test simply gets ticked by the test.
  void requestFrame() {
    if (!hasActiveTickers) return;
    _scheduler?.scheduleNextFrame();
  }

  /// Advances every registered ticker to [timestamp].
  ///
  /// Rejects a non-monotonic [timestamp]; see the library documentation. A
  /// repeated timestamp is *allowed* - two frames can legitimately carry the
  /// same stamp when a frame is produced without time having moved - and
  /// produces a zero-length step, which every ticker must handle as a no-op.
  void tick(Duration timestamp) {
    if (_hasTicked && timestamp < _timestamp) {
      throw ArgumentError.value(
        timestamp,
        'timestamp',
        'the animation clock is monotonic and the previous frame was at '
            '$_timestamp; a backwards timestamp means the time source is not '
            'a monotonic counter',
      );
    }
    if (_ticking) {
      throw StateError(
        'AnimationClock.tick() was called from inside a tick. A nested tick '
        'would advance some animations twice for one frame.',
      );
    }
    _timestamp = timestamp;
    _hasTicked = true;
    _tickCount++;
    _ticking = true;
    try {
      // Length is re-read each step on purpose only for removals-by-deferral;
      // additions never land in `_tickers` during the walk, so a ticker
      // registered from inside a tick first runs on the *next* frame. That is
      // the honest behaviour: it has no baseline for this one.
      for (int i = 0; i < _tickers.length; i++) {
        _tickers[i].tick(timestamp);
      }
    } finally {
      _ticking = false;
      _flushPending();
    }
    requestFrame();
  }

  void _flushPending() {
    if (_pendingRemovals.isNotEmpty) {
      for (int i = 0; i < _pendingRemovals.length; i++) {
        final AnimationTicker ticker = _pendingRemovals[i];
        _tickers.removeWhere((AnimationTicker o) => identical(o, ticker));
      }
      _pendingRemovals.clear();
    }
    if (_pendingAdditions.isNotEmpty) {
      _tickers.addAll(_pendingAdditions);
      _pendingAdditions.clear();
    }
  }
}
