/// The frame's own time: one monotonic stamp, one delta, one number.
///
/// ## Why this type exists at all
///
/// `animation/clock.dart` already hands every ticker a `Duration timestamp`
/// and forbids the layers above it from reading a clock. That is exactly right
/// for a widget animation, whose whole job is to be a pure function of the
/// frame stamp. It is *not* enough for the workloads section 1 of the roadmap
/// names next to a text editor - an animation editor, a video editor, a 2D
/// game - because those have a second consumer that a bare timestamp cannot
/// serve: a simulation step, which needs to know **how much time this frame
/// covers**, not merely when it started.
///
/// Deriving the delta at each consumer looks free and is not. Every consumer
/// that remembers "the previous stamp" has to answer, alone, what happens on
/// the first frame, what happens when a frame is skipped, what happens when a
/// consumer is registered mid-frame and what happens when the loop is paused.
/// Four consumers means four subtly different answers to each, and the symptom
/// is always the same: something moves at the wrong speed after a stall, in a
/// build nobody can reproduce. One value computed once, by whoever produced
/// the frame, removes the question.
///
/// ## Monotonic, and what that costs
///
/// [MonotonicClock] is the only door time comes through. The production
/// implementation is [StopwatchClock], because `Stopwatch` on every platform
/// this framework targets is backed by a counter that cannot be moved by the
/// user, by NTP or by a daylight-saving transition - `QueryPerformanceCounter`
/// on Windows, `clock_gettime(CLOCK_MONOTONIC)` on Linux,
/// `mach_absolute_time` on macOS. `DateTime.now()` is none of those, and a
/// real-time loop driven by it stalls for an hour twice a year.
///
/// Tests inject [ManualClock] instead and move time by hand, which is the same
/// bargain `ManualDispatcher` makes and for the same reason: a pacing
/// assertion that reads a real clock is a flake waiting for a loaded CI
/// runner.
library;

/// A clock that never goes backwards and is unaffected by wall-clock changes.
///
/// Deliberately one getter. A frame loop needs to ask what time it is; it must
/// not be able to ask what *day* it is, because a frame that branches on the
/// calendar is not reproducible.
abstract interface class MonotonicClock {
  /// Time since some fixed, unspecified origin.
  ///
  /// Only differences between two readings are meaningful. Implementations
  /// must guarantee that a later call never returns a smaller value.
  Duration get now;
}

/// The production clock: a `Stopwatch` started when it was constructed.
///
/// Zero at construction, which makes the first frame's timestamp the time
/// since the loop was set up rather than an arbitrary large number. That
/// matters for readability of a pacing log more than for correctness, but a
/// diagnostic nobody can read is a diagnostic nobody uses.
final class StopwatchClock implements MonotonicClock {
  StopwatchClock() : _stopwatch = (Stopwatch()..start());

  final Stopwatch _stopwatch;

  @override
  Duration get now => _stopwatch.elapsed;

  @override
  String toString() => 'StopwatchClock($now)';
}

/// A clock a test moves by hand.
///
/// The counterpart of `ManualDispatcher` for the wall-clock-facing half of the
/// loop: the dispatcher owns *virtual* time inside one window's pipeline, this
/// owns the time the loop paces against. A test that wants "three frames at
/// 16 ms" advances this three times and asserts exact numbers.
///
/// [advance] rejects a negative delta rather than clamping, for the reason
/// `ManualDispatcher.advance` does: a negative delta is always an arithmetic
/// bug in the caller and never an intent.
final class ManualClock implements MonotonicClock {
  ManualClock([Duration initial = Duration.zero]) : _now = initial;

  Duration _now;

  @override
  Duration get now => _now;

  /// Moves time forward by [delta].
  void advance(Duration delta) {
    if (delta.isNegative) {
      throw ArgumentError.value(
        delta,
        'delta',
        'a monotonic clock cannot move backwards',
      );
    }
    _now += delta;
  }

  /// Jumps to an absolute instant. Rejects a jump into the past.
  set now(Duration value) {
    if (value < _now) {
      throw ArgumentError.value(
        value,
        'now',
        'a monotonic clock cannot move backwards; it is at $_now',
      );
    }
    _now = value;
  }

  @override
  String toString() => 'ManualClock($_now)';
}

/// Everything one frame knows about its own place in time.
///
/// Handed to a per-frame painter and to a simulation step. Immutable and
/// cheap: a frame allocates exactly one of these, which is the allocation
/// budget section 6.5 leaves for a value the whole frame reads.
final class FrameTime {
  const FrameTime({
    required this.timestamp,
    required this.delta,
    required this.frameNumber,
    this.interpolation = 1.0,
  });

  /// The frame with nothing before it: stamp zero, no elapsed time.
  ///
  /// What a painter sees when it is asked to draw outside a driven loop - a
  /// golden test, a one-shot screenshot, a window drawn once and never again.
  /// A painter that animates from this reads a zero delta and therefore does
  /// not move, which is the honest answer rather than a jump.
  static const FrameTime zero = FrameTime(
    timestamp: Duration.zero,
    delta: Duration.zero,
    frameNumber: 0,
  );

  /// Monotonic time since the loop started producing frames.
  ///
  /// The same value `AnimationClock.tick` receives, so a painter and an
  /// `AnimationController` in the same window agree about when *now* is.
  final Duration timestamp;

  /// How much time this frame covers - [timestamp] minus the previous frame's.
  ///
  /// Zero on the first frame, by definition and not by accident: there is no
  /// previous frame to have elapsed from, and inventing one nominal interval
  /// is what makes an object visibly jump on its first drawn frame.
  final Duration delta;

  /// How many frames the loop has produced, this one included. Starts at 1 for
  /// the first real frame; [zero] carries 0 because it is not a frame.
  final int frameNumber;

  /// Where between two fixed simulation steps this frame should be drawn,
  /// in `[0, 1]`.
  ///
  /// 1.0 - the default - means "draw the current state", which is exactly
  /// right when no fixed step is in use. See `FixedStepAccumulator`: with a
  /// fixed step the simulation is generally *ahead* of the frame by a
  /// fraction of a step, and rendering the raw state produces the stutter that
  /// makes fixed-step physics look worse than the variable-step version it
  /// replaced.
  final double interpolation;

  /// [delta] in seconds, which is the unit velocity is written in.
  double get deltaSeconds => delta.inMicroseconds / 1000000.0;

  /// [timestamp] in seconds.
  double get seconds => timestamp.inMicroseconds / 1000000.0;

  /// The instantaneous rate this frame's [delta] corresponds to, or 0 when
  /// there is no delta to derive one from.
  ///
  /// Instantaneous on purpose: an averaged frame rate hides exactly the single
  /// long frame a dropped-frame report is about. Average it at the point of
  /// display, not here.
  double get instantaneousFrameRate =>
      delta <= Duration.zero ? 0 : 1000000.0 / delta.inMicroseconds;

  FrameTime copyWith({double? interpolation}) => FrameTime(
        timestamp: timestamp,
        delta: delta,
        frameNumber: frameNumber,
        interpolation: interpolation ?? this.interpolation,
      );

  @override
  String toString() => 'FrameTime(#$frameNumber at ${timestamp.inMicroseconds}'
      'us, +${delta.inMicroseconds}us)';
}
