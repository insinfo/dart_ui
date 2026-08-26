/// The frame loop's policy: when a frame happens, and what it cost.
///
/// ## The two loops this framework has to be, at once
///
/// Everything above `application.dart` was built for an event-driven
/// application: the tree rebuilds when state changes, and a frame is produced
/// because something asked for one. That is the correct shape for a text
/// editor, and it is why an idle `dart_ui` window costs nothing - the loop is
/// asleep inside `MsgWaitForMultipleObjectsEx` and no frame is produced at
/// all.
///
/// Section 1 of the roadmap also names animation editors, video editors and
/// 2D/2.5D games. Those are the other shape: a frame is produced *because time
/// passed*, whether or not anything asked. Nothing invalidates; the world
/// simply moved. A loop that waits to be told to draw cannot serve them, and a
/// loop that always draws is a battery bug on every window that is merely
/// showing a form.
///
/// So both exist, selected by [FrameLoopMode], and the coexistence rule is the
/// important part of this file:
///
///   * **[FrameLoopMode.onDemand] is unchanged and is the default.** A
///     controller in this mode answers "no frame is due" forever, the loop
///     falls through to exactly the invalidation-driven path it had before
///     this file existed, and nothing about idle behaviour, wake-ups or event
///     latency moves.
///   * **[FrameLoopMode.continuous] adds a second reason to draw** and removes
///     none. An invalidation still produces a frame; time passing now produces
///     one too. The two coalesce - a frame that is due *and* invalidated is
///     one frame, because the loop asks a single question ("draw now?") and
///     both sources answer it.
///
/// The mode is per application and switchable at runtime ([setMode]), because
/// the same application is both: an editor's canvas is continuous while a clip
/// is playing and on-demand while the user is typing in a property field, and
/// forcing that choice at startup would make the idle case cost a frame every
/// 16 ms for no reason.
///
/// ## Input before render, and why it is a loop property
///
/// Section 9.4 of the roadmap asks for input priority above render, and
/// `DispatcherPriority` states it: `input` is a more urgent priority than
/// `render`, and `ManualDispatcher` honours it strictly. That covers work
/// *inside* one pipeline drain.
///
/// It does not, on its own, cover the thing a real-time application actually
/// feels, which is the order of two different subsystems: the platform's
/// message pump and the frame producer. A loop that draws first and pumps
/// afterwards computes every frame from input that is one whole frame old, and
/// no dispatcher priority can rescue it, because by the time the events are
/// queued the frame is already on its way to the display.
///
/// `Application.run` therefore pumps, yields to the Dart event loop so the
/// backend's event stream actually delivers, and only then asks this
/// controller whether to draw. [FrameLoopStatistics.inputToFrameLatency]
/// exists to make that order measurable rather than merely asserted.
///
/// ## Why the cost measurement is always on
///
/// A "real-time mode" that cannot be shown to hit its frame time is a claim,
/// not a feature. So [FrameLoopStatistics] is recorded unconditionally and
/// costs, per frame, three clock reads and four integer stores into
/// pre-allocated typed arrays - no allocation, no map, no growth. That is
/// cheap enough that there is no configuration to turn it off, which is
/// deliberate: a diagnostic with an off switch is a diagnostic that is off in
/// the build where the problem happened.
///
/// ## What this file is not, today
///
/// **Nothing in `lib/` builds a [FrameLoopController].** `Application.run`
/// owns the only loop this framework has and drives it from invalidation
/// alone, so [FrameLoopMode.continuous] is a design that has been written and
/// tested and not yet turned on. That is said here rather than left to be
/// discovered, because a reader who finds a complete real-time loop in the
/// tree is entitled to assume it is the one running.
///
/// Wiring it is one seam and it is worth naming, so that whoever takes it does
/// not have to rediscover the shape: `Application.run` would ask
/// [isFrameDue] beside its own `needsFrame`, clamp its wait to
/// [timeUntilNextFrame] while [isContinuous], and bracket the frame it draws
/// with [FrameLoopController.beginFrame] and [FrameLoopController.endFrame].
///
/// **The waiting policy is deliberately not here.** An earlier version of this
/// file carried a `pumpTimeout` that answered "how long may the loop block" -
/// zero when a frame is wanted, the next deadline while continuous, and a flat
/// idle timeout otherwise. It was removed rather than kept, because
/// `Application.run` decides the same thing and decides it differently: its
/// wait is an exponential back-off reset by progress, since the length of the
/// platform wait is the latency of *every* pending piece of Dart work and a
/// flat idle timeout turns an ordinary 16 ms `Timer.periodic` into a 4 Hz
/// stutter. Two answers to one question, in two files, where only one of them
/// runs, is worse than no answer at all: the dead one reads like the policy
/// and is not. What this file keeps is the *deadline* - [timeUntilNextFrame],
/// a fact about the schedule - and the loop keeps the policy about how long to
/// wait for it.
library;

import 'dart:typed_data';

import '../foundation/frame_time.dart';
import '../rendering/present_mode.dart';

/// Why a frame is produced.
enum FrameLoopMode {
  /// A frame happens when something invalidates the tree. The default, and
  /// the whole framework's behaviour before real-time mode existed.
  onDemand,

  /// A frame happens every [FrameLoopOptions.frameInterval], invalidated or
  /// not. Invalidation still works and still coalesces into the same frame.
  continuous,
}

/// Everything the frame loop can be configured with.
///
/// Deliberately a separate type in a separate file from [ApplicationOptions]:
/// real-time policy and window policy change for different reasons and at
/// different times - the mode flips while the application runs, the window
/// title does not.
final class FrameLoopOptions {
  const FrameLoopOptions({
    this.mode = FrameLoopMode.onDemand,
    this.presentMode = PresentMode.fifo,
    this.frameInterval = defaultFrameInterval,
    this.maxTasksPerIteration = 8,
    this.maxCatchUpFrames = 1,
    this.fixedTimeStep,
    this.maxFixedStepsPerFrame = 5,
    this.pacingCapacity = 240,
  });

  /// A continuous loop at the requested rate, with everything else defaulted.
  const FrameLoopOptions.continuous({
    Duration frameInterval = defaultFrameInterval,
    PresentMode presentMode = PresentMode.fifo,
    Duration? fixedTimeStep,
  }) : this(
          mode: FrameLoopMode.continuous,
          frameInterval: frameInterval,
          presentMode: presentMode,
          fixedTimeStep: fixedTimeStep,
        );

  /// 60 Hz. Not a guess about the display - it is the rate a loop paces itself
  /// at when nobody told it the refresh rate, and it is what every platform
  /// this framework targets defaults to.
  ///
  /// A backend that can read the real refresh rate should pass it in;
  /// 16667 microseconds is 59.998 Hz, and a loop paced against that on a
  /// 60.0 Hz display drifts by one frame roughly every 8 hours. That is
  /// invisible in a game and visible in a video editor, which is why the
  /// interval is a parameter rather than a constant in the loop.
  static const Duration defaultFrameInterval = Duration(microseconds: 16667);

  final FrameLoopMode mode;

  /// The presentation policy asked of every window's presenter at startup.
  ///
  /// A *request*. Whether it was honoured is a [PresentModeOutcome], reported
  /// per window; see `present_mode.dart` for why a backend refuses by name
  /// instead of substituting.
  final PresentMode presentMode;

  /// The nominal gap between two continuous frames.
  final Duration frameInterval;

  /// How much work one iteration of the loop may do before it must return to
  /// the platform's message pump.
  ///
  /// This is the roadmap's "limite de tarefas por iteração para não bloquear
  /// mensagens", and the starvation it prevents is concrete: with four windows
  /// open and a continuous loop, drawing every window that owes a frame before
  /// pumping again means the pump waits for four full frames. Under a resize
  /// flood or a burst of pointer moves, the queue then grows faster than it
  /// drains and the window stops responding while still rendering perfectly -
  /// the worst combination to debug, because the application looks alive.
  ///
  /// Counted in *windows drawn*, which is the unit of work the application
  /// loop actually has. Must be at least 1: a budget of zero would mean a loop
  /// that pumps forever and never draws.
  final int maxTasksPerIteration;

  /// How many missed frame deadlines the loop may try to make up before it
  /// gives up and resynchronises to now.
  ///
  /// Zero would mean "never catch up": after a 200 ms stall the loop resumes
  /// on the next interval boundary and 12 frames simply did not happen. That
  /// is the right default for rendering, and it is why this is 1 rather than
  /// 12 - producing 12 frames back to back to "catch up" is the classic death
  /// spiral, where the catch-up work makes the next deadline late too.
  ///
  /// Simulation catch-up is a *different* question with a different answer,
  /// and it lives in [FixedStepAccumulator]: a physics step must not be
  /// skipped just because a frame was, or the world becomes non-deterministic.
  final int maxCatchUpFrames;

  /// The simulation step, when the application wants a fixed one. Null - the
  /// default - means the application integrates against [FrameTime.delta].
  ///
  /// See [FixedStepAccumulator] for what this buys and what it costs.
  final Duration? fixedTimeStep;

  /// The most fixed steps one frame may run before the accumulator is clamped.
  final int maxFixedStepsPerFrame;

  /// How many frames of pacing history to keep. A ring, so this is also the
  /// total memory the diagnostics cost.
  final int pacingCapacity;

  FrameLoopOptions copyWith({
    FrameLoopMode? mode,
    PresentMode? presentMode,
    Duration? frameInterval,
    int? maxTasksPerIteration,
    int? maxCatchUpFrames,
    Duration? fixedTimeStep,
    int? maxFixedStepsPerFrame,
    int? pacingCapacity,
  }) =>
      FrameLoopOptions(
        mode: mode ?? this.mode,
        presentMode: presentMode ?? this.presentMode,
        frameInterval: frameInterval ?? this.frameInterval,
        maxTasksPerIteration: maxTasksPerIteration ?? this.maxTasksPerIteration,
        maxCatchUpFrames: maxCatchUpFrames ?? this.maxCatchUpFrames,
        fixedTimeStep: fixedTimeStep ?? this.fixedTimeStep,
        maxFixedStepsPerFrame:
            maxFixedStepsPerFrame ?? this.maxFixedStepsPerFrame,
        pacingCapacity: pacingCapacity ?? this.pacingCapacity,
      );

  @override
  String toString() => 'FrameLoopOptions(${mode.name}, '
      '${frameInterval.inMicroseconds}us, ${presentMode.name})';
}

/// One frame's measured cost, read out of the pacing ring on demand.
///
/// A value produced by [FrameLoopStatistics.sampleAt], never by the frame
/// loop: recording a frame writes four integers into typed arrays, and this
/// object exists only when somebody asks to read one back. That is the whole
/// reason the diagnostics can be always-on.
final class FramePacingSample {
  const FramePacingSample({
    required this.frameNumber,
    required this.cpu,
    required this.present,
    required this.sincePreviousFrame,
    required this.presented,
  });

  final int frameNumber;

  /// Build, layout, paint and display-list encoding: everything from the frame
  /// opening to the moment the pixels were ready to hand over.
  final Duration cpu;

  /// From "pixels ready" to "the present call returned".
  ///
  /// Under [PresentMode.fifo] this is dominated by the wait for the vertical
  /// blank and is *supposed* to be large - a fifo frame that presents in
  /// 0.1 ms means the loop is behind, not that it is fast. Read it together
  /// with [sincePreviousFrame].
  final Duration present;

  /// The gap between this frame's start and the previous frame's start. The
  /// number that actually decides whether motion looks smooth.
  final Duration sincePreviousFrame;

  /// Whether the frame reached the screen. A frame rejected because the
  /// surface moved under it still cost its CPU time and still counts.
  final bool presented;

  Duration get total => cpu + present;

  @override
  String toString() => 'FramePacingSample(#$frameNumber cpu '
      '${cpu.inMicroseconds}us present ${present.inMicroseconds}us '
      'interval ${sincePreviousFrame.inMicroseconds}us'
      '${presented ? '' : ', not presented'})';
}

/// The always-on pacing record.
///
/// Four `Int32List`s and a couple of counters. Microseconds fit in an `int32`
/// up to 35 minutes, which no single frame will ever reach and which the
/// recorder clamps to anyway rather than wrapping into a negative number.
///
/// Complements `FrameStatistics` in `diagnostics/dev_overlay.dart` rather than
/// replacing it: that one measures the *phases* of a frame for the overlay to
/// draw, this one measures the *cadence* of the loop. A frame can have a
/// perfect 4 ms build/layout/paint and still be dropped, and only this one can
/// see that.
final class FrameLoopStatistics {
  FrameLoopStatistics({this.capacity = 240})
      : _cpu = Int32List(capacity),
        _present = Int32List(capacity),
        _interval = Int32List(capacity),
        _numbers = Int32List(capacity),
        _presented = Uint8List(capacity) {
    if (capacity < 1) {
      throw ArgumentError.value(capacity, 'capacity', 'must be at least 1');
    }
  }

  final int capacity;
  final Int32List _cpu;
  final Int32List _present;
  final Int32List _interval;
  final Int32List _numbers;
  final Uint8List _presented;

  int _count = 0;
  int _next = 0;
  int _framesProduced = 0;
  int _framesPresented = 0;
  int _framesDropped = 0;
  int _lateFrames = 0;
  Duration _worstLateness = Duration.zero;
  Duration _inputToFrameLatency = Duration.zero;

  /// Samples currently retained, at most [capacity].
  int get count => _count;

  /// Frames the loop opened, ever - not just the ones still in the ring.
  int get framesProduced => _framesProduced;

  /// Of those, the ones that reached the screen.
  int get framesPresented => _framesPresented;

  /// Frame deadlines that passed with no frame produced for them.
  ///
  /// The honest definition of a dropped frame in a continuous loop: the loop
  /// intended to draw at t, arrived at t + 2.4 intervals, and two display
  /// refreshes therefore showed the previous image. It is counted at the point
  /// the schedule is resynchronised, which is the only place the information
  /// exists.
  int get framesDropped => _framesDropped;

  /// Frames that opened after the deadline they were scheduled for.
  ///
  /// A late frame is not necessarily a dropped one: a frame that starts 2 ms
  /// after its deadline still shows on the same refresh. Counted separately
  /// from [framesDropped] because the two have different causes - lateness is
  /// the loop being busy, a drop is the loop being *a whole interval* busy.
  int get lateFrames => _lateFrames;

  /// The worst gap between when a frame was due and when it started.
  Duration get worstLateness => _worstLateness;

  /// How long the most recent frame waited between the platform event pump
  /// returning and the frame opening.
  ///
  /// This is the number that proves the ordering claim in the library
  /// documentation: input is drained, then the frame opens, and this is the
  /// gap. It is small by construction - it contains only the Dart event-loop
  /// turn that delivers the backend's stream - and a large value means
  /// something is running between the pump and the frame that should not be.
  Duration get inputToFrameLatency => _inputToFrameLatency;

  /// The most recent sample, or null before the first frame completed.
  FramePacingSample? get last => _count == 0 ? null : sampleAt(_count - 1);

  /// Reads sample [index] back out of the ring, oldest first.
  FramePacingSample sampleAt(int index) {
    if (index < 0 || index >= _count) {
      throw RangeError.index(index, this, 'index', null, _count);
    }
    final int slot = _count < capacity ? index : (_next + index) % capacity;
    return FramePacingSample(
      frameNumber: _numbers[slot],
      cpu: Duration(microseconds: _cpu[slot]),
      present: Duration(microseconds: _present[slot]),
      sincePreviousFrame: Duration(microseconds: _interval[slot]),
      presented: _presented[slot] != 0,
    );
  }

  /// Every retained sample, oldest first. Allocates; for reporting only.
  List<FramePacingSample> get samples => <FramePacingSample>[
        for (int i = 0; i < _count; i++) sampleAt(i),
      ];

  /// Mean CPU cost of a frame, in microseconds. Zero with no samples.
  double get averageCpuMicroseconds => _average(_cpu);

  /// Mean present cost, in microseconds.
  double get averagePresentMicroseconds => _average(_present);

  /// Mean gap between frame starts, in microseconds. The reciprocal of the
  /// measured frame rate.
  double get averageIntervalMicroseconds => _average(_interval);

  /// Frames per second over the retained window, or 0 with nothing to measure.
  double get frameRate {
    final double interval = averageIntervalMicroseconds;
    return interval <= 0 ? 0 : 1000000.0 / interval;
  }

  /// The [percentile]th percentile of total frame cost, in microseconds.
  ///
  /// Nearest-rank, matching `FrameStatistics.percentileTotal`, and for the
  /// same reason stated there: the percent-of-range convention hides the one
  /// slow frame the question was about.
  double percentileTotalMicroseconds(double percentile) {
    if (_count == 0) return 0;
    final List<int> totals = <int>[
      for (int i = 0; i < _count; i++) _cpu[i] + _present[i],
    ]..sort();
    final int rank = (percentile / 100 * totals.length).ceil();
    return totals[(rank - 1).clamp(0, totals.length - 1)].toDouble();
  }

  /// Retained frames whose total cost exceeded [budget].
  int framesOverBudget(Duration budget) {
    final int limit = budget.inMicroseconds;
    int over = 0;
    for (int i = 0; i < _count; i++) {
      if (_cpu[i] + _present[i] > limit) over++;
    }
    return over;
  }

  void reset() {
    _count = 0;
    _next = 0;
    _framesProduced = 0;
    _framesPresented = 0;
    _framesDropped = 0;
    _lateFrames = 0;
    _worstLateness = Duration.zero;
    _inputToFrameLatency = Duration.zero;
  }

  double _average(Int32List source) {
    if (_count == 0) return 0;
    int sum = 0;
    for (int i = 0; i < _count; i++) {
      sum += source[i];
    }
    return sum / _count;
  }

  void _record({
    required int frameNumber,
    required int cpuMicroseconds,
    required int presentMicroseconds,
    required int intervalMicroseconds,
    required bool presented,
  }) {
    final int slot = _count < capacity ? _count : _next;
    _numbers[slot] = frameNumber;
    _cpu[slot] = _clamp(cpuMicroseconds);
    _present[slot] = _clamp(presentMicroseconds);
    _interval[slot] = _clamp(intervalMicroseconds);
    _presented[slot] = presented ? 1 : 0;
    if (_count < capacity) {
      _count++;
      _next = _count % capacity;
    } else {
      _next = (_next + 1) % capacity;
    }
    if (presented) _framesPresented++;
  }

  /// Microseconds are stored in an `int32`; clamping rather than wrapping
  /// means a pathological 40-minute frame reports as 35 minutes instead of as
  /// a negative number, which is wrong in a way a reader can see.
  static int _clamp(int microseconds) {
    if (microseconds < 0) return 0;
    return microseconds > 0x7FFFFFFF ? 0x7FFFFFFF : microseconds;
  }
}

/// The fixed-step accumulator, for a simulation that must be deterministic.
///
/// A game that integrates against the frame delta produces a different world
/// on a 60 Hz laptop and a 144 Hz desktop, and a *different* one again on the
/// same machine after a stall. That is fine for a fade-in and fatal for
/// physics, for a replay file, and for anything two machines have to agree
/// about.
///
/// The remedy is the standard one: accumulate real time, run the simulation in
/// whole steps of a fixed size, and render the leftover fraction as an
/// interpolation between the last two states. The three details that are
/// usually got wrong, and how this handles them:
///
///   * **The spiral of death.** If a step costs more than the step's own
///     duration, the accumulator grows faster than it drains and the frame
///     never ends. [maxStepsPerFrame] bounds the steps taken per frame and
///     [drop] reports the simulated time that was abandoned, so the
///     application can slow the world down deliberately instead of hanging.
///   * **The leftover.** [alpha] is the fraction of a step still in the
///     accumulator after stepping, which is what a renderer must interpolate
///     by. Ignoring it is what makes fixed-step motion look *worse* than
///     variable-step motion at any refresh rate that is not a multiple of the
///     step.
///   * **The first frame.** A first frame with a zero delta runs zero steps,
///     which is correct: nothing has elapsed yet.
final class FixedStepAccumulator {
  FixedStepAccumulator({
    required this.step,
    this.maxStepsPerFrame = 5,
  }) {
    if (step <= Duration.zero) {
      throw ArgumentError.value(step, 'step', 'must be strictly positive');
    }
    if (maxStepsPerFrame < 1) {
      throw ArgumentError.value(
        maxStepsPerFrame,
        'maxStepsPerFrame',
        'must be at least 1; a frame that may take no step can never advance '
            'the simulation',
      );
    }
  }

  /// The simulation's tick. Every step advances the world by exactly this.
  final Duration step;

  final int maxStepsPerFrame;

  Duration _accumulated = Duration.zero;
  Duration _dropped = Duration.zero;
  int _stepsTaken = 0;

  /// Simulated time waiting to be consumed, always less than [step] after
  /// [advance] returns normally.
  Duration get pending => _accumulated;

  /// Simulated time abandoned because [maxStepsPerFrame] was reached.
  ///
  /// Non-zero means the simulation could not keep up. It is exposed rather
  /// than swallowed because "the world is running slow" is a fact the
  /// application must be able to act on - by reducing detail, by pausing, or
  /// by telling the user - and a silently clamped accumulator turns it into a
  /// mystery.
  Duration get dropped => _dropped;

  /// Total steps run since construction.
  int get stepsTaken => _stepsTaken;

  /// Where between the previous step and the next one a render should place
  /// the world, in `[0, 1)`.
  double get alpha => _accumulated.inMicroseconds / step.inMicroseconds;

  /// Adds [delta] and returns how many whole steps are due.
  ///
  /// The caller runs the simulation that many times, then renders with
  /// [alpha]. Rejects a negative delta for the reason `ManualClock` does.
  int advance(Duration delta) {
    if (delta.isNegative) {
      throw ArgumentError.value(
        delta,
        'delta',
        'a simulation cannot step backwards',
      );
    }
    _accumulated += delta;
    int steps = 0;
    while (_accumulated >= step && steps < maxStepsPerFrame) {
      _accumulated -= step;
      steps++;
    }
    if (_accumulated >= step) {
      // Clamped rather than looped: see the class documentation for the
      // spiral this prevents, and note that the abandoned time is *reported*.
      final int abandonedSteps =
          _accumulated.inMicroseconds ~/ step.inMicroseconds;
      final Duration abandoned = step * abandonedSteps;
      _accumulated -= abandoned;
      _dropped += abandoned;
    }
    _stepsTaken += steps;
    return steps;
  }

  void reset() {
    _accumulated = Duration.zero;
    _dropped = Duration.zero;
    _stepsTaken = 0;
  }

  @override
  String toString() => 'FixedStepAccumulator(${step.inMicroseconds}us, '
      'pending ${_accumulated.inMicroseconds}us, alpha '
      '${alpha.toStringAsFixed(3)})';
}

/// Decides when a frame happens and records what it cost.
///
/// Owns no window, no pipeline and no dispatcher - it is a schedule and a
/// stopwatch, which is what makes it testable with an injected [ManualClock]
/// and no application at all. `Application.run` consults it; nothing here
/// calls back into the application.
///
/// ## The frame protocol
///
/// One frame is exactly this sequence, and the controller enforces it:
///
/// ```dart
/// if (controller.isFrameDue) {
///   final FrameTime time = controller.beginFrame();
///   ... build, layout, paint ...
///   controller.markCpuComplete();
///   ... present ...
///   controller.endFrame(presented: result.isSuccess);
/// }
/// ```
///
/// Out of order is a [StateError] rather than a wrong number, because a
/// pacing statistic that is quietly wrong is worse than none: it is the
/// evidence every later decision rests on.
final class FrameLoopController {
  FrameLoopController({
    FrameLoopOptions options = const FrameLoopOptions(),
    MonotonicClock? clock,
  })  : _options = options,
        clock = clock ?? StopwatchClock(),
        statistics = FrameLoopStatistics(capacity: options.pacingCapacity),
        simulation = options.fixedTimeStep == null
            ? null
            : FixedStepAccumulator(
                step: options.fixedTimeStep!,
                maxStepsPerFrame: options.maxFixedStepsPerFrame,
              ) {
    if (options.frameInterval <= Duration.zero) {
      throw ArgumentError.value(
        options.frameInterval,
        'frameInterval',
        'must be strictly positive; a zero interval means a frame is always '
            'due, which is a spin rather than a loop',
      );
    }
    if (options.maxTasksPerIteration < 1) {
      throw ArgumentError.value(
        options.maxTasksPerIteration,
        'maxTasksPerIteration',
        'must be at least 1; a budget of zero would pump forever and never '
            'draw',
      );
    }
    if (options.maxCatchUpFrames < 0) {
      throw ArgumentError.value(
        options.maxCatchUpFrames,
        'maxCatchUpFrames',
        'must not be negative',
      );
    }
    _mode = options.mode;
    _frameInterval = options.frameInterval;
    _origin = this.clock.now;
    _nextDue = _origin;
  }

  /// The clock everything here is measured against. Injected in tests.
  final MonotonicClock clock;

  /// Always-on pacing record. See [FrameLoopStatistics].
  final FrameLoopStatistics statistics;

  /// The fixed-step accumulator, when [FrameLoopOptions.fixedTimeStep] asked
  /// for one. Null otherwise, and null is the common case.
  final FixedStepAccumulator? simulation;

  FrameLoopOptions _options;
  late FrameLoopMode _mode;
  late Duration _frameInterval;
  late Duration _origin;
  late Duration _nextDue;

  Duration _lastFrameStart = Duration.zero;
  Duration _pumpReturned = Duration.zero;
  bool _hasPumped = false;
  bool _hasFrame = false;
  int _frameNumber = 0;

  // Frame-in-flight bookkeeping. Nullable rather than flagged so that a
  // protocol violation is a named error instead of a plausible-looking zero.
  Duration? _frameOpenedAt;
  Duration? _cpuCompleteAt;
  FrameTime _lastFrameTime = FrameTime.zero;

  FrameLoopOptions get options => _options;

  FrameLoopMode get mode => _mode;

  bool get isContinuous => _mode == FrameLoopMode.continuous;

  /// The interval continuous frames are paced at.
  Duration get frameInterval => _frameInterval;

  /// The frame currently in flight, or the last one produced.
  FrameTime get lastFrameTime => _lastFrameTime;

  /// Frames opened by this controller.
  int get frameNumber => _frameNumber;

  /// Whether a frame is open - between [beginFrame] and [endFrame].
  bool get isFrameInFlight => _frameOpenedAt != null;

  /// The presentation policy requested. Applying it is the application's job,
  /// because only it holds the presenters.
  PresentMode get presentMode => _options.presentMode;

  /// How many windows one loop iteration may draw before returning to the
  /// pump. See [FrameLoopOptions.maxTasksPerIteration].
  int get maxTasksPerIteration => _options.maxTasksPerIteration;

  /// Switches mode at runtime.
  ///
  /// Switching *into* continuous resets the schedule to now, so the first
  /// continuous frame is due immediately rather than at whatever stale
  /// deadline was left over from a previous continuous stretch - which,
  /// after an idle minute, would be a minute in the past and would count as
  /// thousands of dropped frames.
  void setMode(FrameLoopMode value) {
    if (_mode == value) return;
    _mode = value;
    if (value == FrameLoopMode.continuous) {
      _nextDue = clock.now;
    }
  }

  /// Changes the pacing interval at runtime; a 144 Hz display, a 24 fps
  /// timeline preview, a deliberately throttled background window.
  ///
  /// Rebases the schedule from now so the change takes effect on the next
  /// frame rather than after the old interval has run out.
  void setFrameInterval(Duration value) {
    if (value <= Duration.zero) {
      throw ArgumentError.value(
        value,
        'frameInterval',
        'must be strictly positive',
      );
    }
    if (_frameInterval == value) return;
    _frameInterval = value;
    _options = _options.copyWith(frameInterval: value);
    _nextDue = clock.now + value;
  }

  /// Records that the platform pump has just returned and input has been
  /// delivered. Optional; it is what makes
  /// [FrameLoopStatistics.inputToFrameLatency] meaningful.
  void notePumpComplete() {
    _pumpReturned = clock.now;
    _hasPumped = true;
  }

  /// Whether a continuous frame is due now.
  ///
  /// Always false in [FrameLoopMode.onDemand]. That is the coexistence
  /// guarantee in one line: an on-demand application asks this every
  /// iteration, always gets false, and falls through to the invalidation path
  /// unchanged.
  bool get isFrameDue => isContinuous && clock.now >= _nextDue;

  /// How long until the next continuous frame is due; [Duration.zero] when one
  /// already is, and [Duration.zero] in on-demand mode - where the caller must
  /// not consult it, because there is no next frame to wait for.
  Duration get timeUntilNextFrame {
    if (!isContinuous) return Duration.zero;
    final Duration remaining = _nextDue - clock.now;
    return remaining.isNegative ? Duration.zero : remaining;
  }

  /// Opens a frame and returns its time.
  ///
  /// Advances the schedule by exactly one [frameInterval]; if that still
  /// leaves the next deadline in the past, the loop is behind and the missed
  /// deadlines are counted as dropped frames before the schedule is
  /// resynchronised. That accounting is the only place a dropped frame can be
  /// observed, because a frame that never happened leaves no other trace.
  FrameTime beginFrame() {
    if (_frameOpenedAt != null) {
      throw StateError(
        'FrameLoopController.beginFrame() while a frame is still open. Every '
        'beginFrame must be closed by endFrame, or the pacing record measures '
        'two frames as one.',
      );
    }
    final Duration now = clock.now;
    final Duration delta = _hasFrame ? now - _lastFrameStart : Duration.zero;

    if (isContinuous) {
      final Duration lateness = now - _nextDue;
      if (lateness > Duration.zero) {
        statistics._lateFrames++;
        if (lateness > statistics._worstLateness) {
          statistics._worstLateness = lateness;
        }
      }
      _nextDue += _frameInterval;
      if (_nextDue <= now) {
        // Every deadline still in the past went by with no frame drawn for
        // it. Walk to the first one in the future, counting them.
        int behind = 0;
        while (_nextDue <= now) {
          _nextDue += _frameInterval;
          behind++;
        }
        // Of those, the policy allows making up `makeUp` by leaving the
        // schedule due again immediately, which produces that many back-to-
        // back catch-up frames. The rest are dropped and counted: see
        // FrameLoopOptions.maxCatchUpFrames for why the number is small.
        final int allowed = _options.maxCatchUpFrames;
        final int makeUp = behind < allowed ? behind : allowed;
        if (makeUp > 0) _nextDue -= _frameInterval * makeUp;
        statistics._framesDropped += behind - makeUp;
      }
    }

    _frameNumber++;
    _lastFrameStart = now;
    _hasFrame = true;
    _frameOpenedAt = now;
    _cpuCompleteAt = null;
    statistics._framesProduced++;
    if (_hasPumped) {
      statistics._inputToFrameLatency = now - _pumpReturned;
    }

    double interpolation = 1.0;
    final FixedStepAccumulator? sim = simulation;
    if (sim != null) {
      sim.advance(delta);
      interpolation = sim.alpha;
    }

    _lastFrameTime = FrameTime(
      timestamp: now - _origin,
      delta: delta,
      frameNumber: _frameNumber,
      interpolation: interpolation,
    );
    return _lastFrameTime;
  }

  /// Marks the end of the CPU half of the frame: the display list is finished
  /// and nothing is left but handing it to the platform.
  ///
  /// Separate from [endFrame] because the two halves fail differently and are
  /// fixed by different people. A 12 ms CPU frame is a widget-tree problem; a
  /// 12 ms present is a driver, a compositor or a vsync wait.
  void markCpuComplete() {
    final Duration? opened = _frameOpenedAt;
    if (opened == null) {
      throw StateError(
        'FrameLoopController.markCpuComplete() outside a frame.',
      );
    }
    _cpuCompleteAt ??= clock.now;
  }

  /// Closes the frame and records it.
  ///
  /// [presented] is whether the pixels reached the screen. A frame rejected
  /// for a stale generation is still recorded - it cost exactly as much CPU as
  /// a successful one, and hiding it would make a resize storm look free.
  void endFrame({required bool presented}) {
    final Duration? opened = _frameOpenedAt;
    if (opened == null) {
      throw StateError(
        'FrameLoopController.endFrame() without a matching beginFrame().',
      );
    }
    final Duration now = clock.now;
    final Duration cpuDone = _cpuCompleteAt ?? now;
    statistics._record(
      frameNumber: _frameNumber,
      cpuMicroseconds: (cpuDone - opened).inMicroseconds,
      presentMicroseconds: (now - cpuDone).inMicroseconds,
      intervalMicroseconds: _lastFrameTime.delta.inMicroseconds,
      presented: presented,
    );
    _frameOpenedAt = null;
    _cpuCompleteAt = null;
  }

  /// Forgets an open frame without recording it.
  ///
  /// For the one case where a frame is opened and then cannot be drawn at all
  /// - the window became unpresentable between the decision and the attempt.
  /// Recording it would put a zero-cost frame in the pacing record and make
  /// the average lie in the flattering direction.
  void abandonFrame() {
    _frameOpenedAt = null;
    _cpuCompleteAt = null;
  }

  @override
  String toString() => 'FrameLoopController(${_mode.name}, '
      '${_frameInterval.inMicroseconds}us, frame $_frameNumber, '
      'dropped ${statistics.framesDropped})';
}
