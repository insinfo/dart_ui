/// Animatable values: the observable, the driver, and the interpolators.
///
/// Section 32.1 names `duration`, `curve`, `implicit` and `explicit` as
/// animation types. This file is the explicit half: an [AnimationController]
/// driven by the frame clock produces a normalized `double`, a [Curve] shapes
/// it, and a [Tween] maps it onto whatever type the property actually holds.
///
/// The split matters. The controller knows about time and nothing about
/// colour; the tween knows about colour and nothing about time. That is why a
/// spring, a keyframe track and a plain duration can all drive the same tween
/// without any of them knowing the others exist.
library;

import '../foundation/change_notifier.dart';
import '../geometry/offset.dart';
import '../geometry/rect.dart';
import '../geometry/size.dart';
import 'clock.dart';
import 'curves.dart';
import 'simulation.dart';
import 'ticker.dart';

/// Where an animation is in its life.
///
/// Four states, and the pair of them that means "at rest" carries *which* end
/// it is resting at. A single `stopped` state would force every listener to
/// re-read the value to find out whether a fade-out had finished or a fade-in
/// had, which is the check everybody forgets.
enum AnimationStatus {
  /// At rest at the lower bound. The starting state of a fresh controller.
  dismissed,

  /// Running towards the upper bound.
  forward,

  /// Running towards the lower bound.
  reverse,

  /// At rest at the upper bound.
  completed;

  /// Running in either direction.
  bool get isAnimating => this == forward || this == reverse;

  /// At rest at the upper bound.
  bool get isCompleted => this == completed;

  /// At rest at the lower bound.
  bool get isDismissed => this == dismissed;

  /// Running towards, or at rest at, the upper bound.
  bool get isForwardOrCompleted => this == forward || this == completed;
}

/// A value that changes over time and says when it changed.
///
/// Deliberately *not* a `Stream`. A stream delivers asynchronously, and an
/// animation value that arrives one microtask after the frame that produced it
/// is a frame of latency on every transition. Listeners here are called
/// synchronously, inside the frame, before layout runs.
abstract class Animation<T> implements Listenable {
  /// The current value.
  T get value;

  /// Where this animation is in its life.
  AnimationStatus get status;

  /// Whether frames are still being consumed.
  bool get isAnimating;

  /// Whether this animation is at rest at its end.
  bool get isCompleted => status == AnimationStatus.completed;

  /// Whether this animation is at rest at its beginning.
  bool get isDismissed => status == AnimationStatus.dismissed;

  /// Whether this animation is running towards, or at rest at, its end.
  bool get isForwardOrCompleted =>
      status == AnimationStatus.forward || status == AnimationStatus.completed;

  /// Called after every change to [value].
  @override
  void addListener(void Function() listener);

  @override
  bool removeListener(void Function() listener);

  /// Called after every change to [status].
  void addStatusListener(void Function(AnimationStatus status) listener);

  bool removeStatusListener(void Function(AnimationStatus status) listener);
}

/// Listener bookkeeping shared by every animation in this file.
///
/// Notification iterates over a *copy* of the listener list, because a
/// listener removing itself - the normal way a one-shot reaction unsubscribes
/// - would otherwise skip its neighbour. The copy is only made when there is
/// at least one listener, so an animation nobody watches costs nothing per
/// frame (section 6.5).
mixin _AnimationListeners on Object {
  final List<void Function()> _listeners = <void Function()>[];
  final List<void Function(AnimationStatus)> _statusListeners =
      <void Function(AnimationStatus)>[];

  void addListener(void Function() listener) => _listeners.add(listener);

  bool removeListener(void Function() listener) => _listeners.remove(listener);

  void addStatusListener(void Function(AnimationStatus status) listener) =>
      _statusListeners.add(listener);

  bool removeStatusListener(void Function(AnimationStatus status) listener) =>
      _statusListeners.remove(listener);

  void notifyListeners() {
    if (_listeners.isEmpty) return;
    for (final void Function() listener
        in List<void Function()>.of(_listeners)) {
      listener();
    }
  }

  void notifyStatusListeners(AnimationStatus status) {
    if (_statusListeners.isEmpty) return;
    for (final void Function(AnimationStatus) listener
        in List<void Function(AnimationStatus)>.of(_statusListeners)) {
      listener(status);
    }
  }
}

/// How an [AnimationController] behaves when the platform asks for reduced
/// animations - Flutter's `AnimationBehavior`.
///
/// Accepted for compatibility. This framework honours reduced motion where a
/// transition is *implicit* (`ThemeData.reducedMotion` skips it); an explicit
/// controller always runs at its own speed, which is
/// [AnimationBehavior.preserve] in Flutter's terms.
enum AnimationBehavior {
  /// Shortened when animations are disabled, in Flutter.
  normal,

  /// Always runs at full length.
  preserve,
}

/// Drives a `double` from [lowerBound] to [upperBound] - Flutter's
/// `AnimationController`.
///
/// ## Two ways to give it time
///
/// * `vsync:` - the Flutter way. A [TickerProvider], usually a `State` with
///   `SingleTickerProviderStateMixin` or `TickerProviderStateMixin`, hands
///   out a [Ticker] bound to the nearest `AnimationScope`'s clock:
///
///   ```dart
///   late final AnimationController _controller = AnimationController(
///     vsync: this,
///     duration: const Duration(milliseconds: 300),
///   );
///   ```
/// * `clock:` - this framework's own spelling, for code that holds an
///   [AnimationClock] directly (a render object, a test). Its [duration]
///   defaults to 300 ms, as it always has.
///
/// Give exactly one. A ticker with no clock - a widget mounted with no
/// `AnimationScope` above it - never ticks; a controller driven by one goes
/// straight to where each run was going (a [repeat] stays where it is), the
/// same rule the implicit animations follow.
///
/// ## Exact ends
///
/// Every run is an interpolation from the current value to a target over a
/// time in whole microseconds, and lands on the target itself rather than on
/// an accumulated sum: `controller.value == 1.0` holds after a [forward], not
/// merely `closeTo(1.0, 1e-9)`. The value is clamped to the bounds.
///
/// ## Differences from Flutter, all deliberate
///
/// * Listeners are told about a tick only when the value changed. The first
///   frame of a run (elapsed zero) and a repeated timestamp move nothing and
///   notify nobody - the property that lets a settling frame converge (see
///   `widgets/implicit_animation.dart`).
/// * [speed] (not in Flutter) scales the rate of time, mid-flight included.
/// * [animateWith] and [fling] take this framework's [Simulation], whose time
///   is a [Duration].
/// * [AnimationBehavior] is accepted and changes nothing; see its comment.
final class AnimationController extends Animation<double>
    with _AnimationListeners
    implements AnimationTicker {
  AnimationController({
    double? value,
    Duration? duration,
    this.reverseDuration,
    this.debugLabel,
    this.lowerBound = 0.0,
    this.upperBound = 1.0,
    this.animationBehavior = AnimationBehavior.normal,
    TickerProvider? vsync,
    AnimationClock? clock,
    double? initialValue,
    double speed = 1.0,
  })  : _speed = speed,
        _duration = duration ??
            (clock != null ? const Duration(milliseconds: 300) : null) {
    if (!(upperBound >= lowerBound)) {
      throw ArgumentError(
        'upperBound ($upperBound) must be greater than or equal to '
        'lowerBound ($lowerBound)',
      );
    }
    _checkDuration(_duration, 'duration');
    _checkDuration(reverseDuration, 'reverseDuration');
    _checkSpeed(speed);
    _ticker = _createTicker(vsync, clock);
    _internalSetValue(value ?? initialValue ?? lowerBound);
  }

  /// A controller with no bounds, for a value driven by a [Simulation] - a
  /// scroll offset, a physics position. [forward], [reverse] and [repeat]
  /// have no end to run to and throw; [animateTo] and [animateWith] work.
  AnimationController.unbounded({
    double value = 0.0,
    Duration? duration,
    this.reverseDuration,
    this.debugLabel,
    TickerProvider? vsync,
    AnimationClock? clock,
    this.animationBehavior = AnimationBehavior.preserve,
  })  : lowerBound = double.negativeInfinity,
        upperBound = double.infinity,
        _speed = 1.0,
        _duration = duration {
    _checkDuration(_duration, 'duration');
    _checkDuration(reverseDuration, 'reverseDuration');
    _ticker = _createTicker(vsync, clock);
    _internalSetValue(value);
  }

  Ticker _createTicker(TickerProvider? vsync, AnimationClock? clock) {
    if ((vsync == null) == (clock == null)) {
      throw ArgumentError(
        'AnimationController takes either vsync (a TickerProvider, usually '
        '`this` in a State with SingleTickerProviderStateMixin) or clock (an '
        'AnimationClock), and exactly one of them',
      );
    }
    return vsync != null
        ? vsync.createTicker(_tick)
        : Ticker(_tick, debugLabel: debugLabel, clock: clock);
  }

  static void _checkDuration(Duration? duration, String name) {
    if (duration != null && duration < Duration.zero) {
      throw ArgumentError.value(duration, name, 'must not be negative');
    }
  }

  static void _checkSpeed(double speed) {
    if (!(speed > 0.0)) {
      throw ArgumentError.value(
        speed,
        'speed',
        'must be strictly positive; run an animation backwards with '
            'reverse(), not with a negative speed',
      );
    }
  }

  final double lowerBound;
  final double upperBound;

  /// A name for diagnostics.
  final String? debugLabel;

  /// See [AnimationBehavior].
  final AnimationBehavior animationBehavior;

  /// How long a full sweep from [lowerBound] to [upperBound] takes. May be
  /// null, as in Flutter, if it is set before the first run that needs it.
  Duration? get duration => _duration;
  Duration? _duration;

  set duration(Duration? value) {
    _checkDuration(value, 'duration');
    _duration = value;
  }

  /// How long a full sweep back takes; [duration] when null.
  Duration? reverseDuration;

  /// This controller, typed as a read-only [Animation].
  Animation<double> get view => this;

  late Ticker _ticker;
  bool _disposed = false;

  /// The clock driving this controller, or null when its ticker has none.
  AnimationClock? get clock => _ticker.clock;

  double _speed;

  /// A multiplier on the rate of time - this framework's addition. `2.0`
  /// finishes in half the wall time, and changing it mid-flight does not move
  /// the value.
  double get speed => _speed;

  set speed(double value) {
    _checkSpeed(value);
    _speed = value;
  }

  late double _value;
  late AnimationStatus _status;

  /// Dismissed to begin with, as in Flutter: a controller created at its
  /// upper bound reports `completed` the first time its status is checked.
  AnimationStatus _lastReportedStatus = AnimationStatus.dismissed;
  bool _forward = true;

  _Run? _run;

  /// Simulated microseconds since the run started, after [speed].
  double _runMicros = 0.0;

  /// The ticker's elapsed time at the previous tick of this run.
  Duration _lastTickElapsed = Duration.zero;
  Duration? _lastElapsedDuration;

  @override
  double get value => _value;

  /// Sets the value directly, stopping any run in progress.
  ///
  /// The status follows, as in Flutter: dismissed at [lowerBound], completed
  /// at [upperBound], and forward or reverse - the last direction - between.
  set value(double newValue) {
    _throwIfDisposed('value');
    stop();
    final double before = _value;
    _internalSetValue(newValue);
    if (_value != before) notifyListeners();
    _checkStatusChanged();
  }

  @override
  AnimationStatus get status => _status;

  @override
  bool get isAnimating => !_disposed && _ticker.isActive;

  @override
  bool get isTicking => !_disposed && _ticker.isTicking;

  /// The normalized progress, `0` at [lowerBound] and `1` at [upperBound].
  double get progress {
    final double span = upperBound - lowerBound;
    if (!span.isFinite || span == 0) return 0.0;
    return ((_value - lowerBound) / span).clamp(0.0, 1.0);
  }

  /// The rate of change of [value], in units per second; zero when idle.
  double get velocity {
    final _Run? run = _run;
    if (run == null || !isAnimating) return 0.0;
    return run.dx(_runMicros) * _speed;
  }

  /// The ticker's elapsed time at the last tick of the current run, or null
  /// when nothing is running.
  Duration? get lastElapsedDuration => _lastElapsedDuration;

  /// Runs towards [upperBound], from [from] when given.
  ///
  /// Already being at the upper bound completes at once, as in Flutter.
  TickerFuture forward({double? from}) {
    _throwIfDisposed('forward');
    _requireBounded('forward');
    _requireDuration('forward', reverse: false);
    _forward = true;
    if (from != null) value = from;
    return _animateToInternal(upperBound);
  }

  /// Runs towards [lowerBound], from [from] when given.
  TickerFuture reverse({double? from}) {
    _throwIfDisposed('reverse');
    _requireBounded('reverse');
    _requireDuration('reverse', reverse: true);
    _forward = false;
    if (from != null) value = from;
    return _animateToInternal(lowerBound);
  }

  /// Runs towards whichever bound this controller is not heading for.
  TickerFuture toggle({double? from}) {
    _throwIfDisposed('toggle');
    _requireBounded('toggle');
    final bool goForward = !isForwardOrCompleted;
    _requireDuration('toggle', reverse: !goForward);
    _forward = goForward;
    if (from != null) value = from;
    return _animateToInternal(goForward ? upperBound : lowerBound);
  }

  /// Runs to [target], over [duration] when given and otherwise over the
  /// share of [duration] that the distance is of the whole range, shaped by
  /// [curve]. Ends with [AnimationStatus.completed], wherever [target] is.
  TickerFuture animateTo(
    double target, {
    Duration? duration,
    Curve curve = Curves.linear,
  }) {
    _throwIfDisposed('animateTo');
    if (duration == null) _requireDuration('animateTo', reverse: false);
    _forward = true;
    return _animateToInternal(target, duration: duration, curve: curve);
  }

  /// [animateTo], going backwards: ends with [AnimationStatus.dismissed].
  TickerFuture animateBack(
    double target, {
    Duration? duration,
    Curve curve = Curves.linear,
  }) {
    _throwIfDisposed('animateBack');
    if (duration == null) _requireDuration('animateBack', reverse: true);
    _forward = false;
    return _animateToInternal(target, duration: duration, curve: curve);
  }

  TickerFuture _animateToInternal(
    double target, {
    Duration? duration,
    Curve curve = Curves.linear,
  }) {
    Duration? runDuration = duration;
    if (runDuration == null) {
      final double range = upperBound - lowerBound;
      final double remaining =
          range.isFinite && range > 0 ? (target - _value).abs() / range : 1.0;
      final Duration whole =
          !_forward && reverseDuration != null ? reverseDuration! : _duration!;
      runDuration = whole * remaining;
    } else if (target == _value) {
      runDuration = Duration.zero;
    }
    stop();
    if (runDuration <= Duration.zero || !_ticker.canTick) {
      // Nothing to animate, or no clock to animate with: land at once.
      final double before = _value;
      _value = _clamp(target);
      if (_value != before) notifyListeners();
      _status =
          _forward ? AnimationStatus.completed : AnimationStatus.dismissed;
      _checkStatusChanged();
      return TickerFuture.complete();
    }
    return _startRun(_InterpolationRun(
      _value,
      _clamp(target),
      runDuration.inMicroseconds.toDouble(),
      curve,
    ));
  }

  /// Runs from [min] to [max] (the bounds by default) over [period]
  /// ([duration] by default), over and over: wrapping back to [min], or
  /// turning round when [reverse] is true. [count] periods, when given, end
  /// the run with [AnimationStatus.completed]; otherwise it never completes.
  ///
  /// [reverses] is this framework's older spelling of [reverse].
  TickerFuture repeat({
    double? min,
    double? max,
    bool reverse = false,
    bool reverses = false,
    Duration? period,
    int? count,
  }) {
    _throwIfDisposed('repeat');
    final double low = min ?? lowerBound;
    final double high = max ?? upperBound;
    final Duration? cycle = period ?? _duration;
    if (cycle == null || cycle <= Duration.zero) {
      throw StateError(
        'AnimationController.repeat() called without an explicit period and '
        'with no default duration. Pass period:, or set duration first.',
      );
    }
    if (!low.isFinite || !high.isFinite || high < low) {
      throw ArgumentError(
          'repeat() needs finite min <= max (got min $low, max $high)');
    }
    if (low < lowerBound || high > upperBound) {
      throw ArgumentError('repeat() min and max must lie within the bounds '
          '[$lowerBound, $upperBound]');
    }
    if (count != null && count <= 0) {
      throw ArgumentError.value(count, 'count', 'must be greater than zero');
    }
    stop();
    _forward = true;
    if (!_ticker.canTick) {
      // No clock: a repeating animation has no end to land on, so it stays.
      _status = AnimationStatus.forward;
      _checkStatusChanged();
      return TickerFuture.complete();
    }
    return _startRun(_RepeatingRun(
      initialValue: _value,
      min: low,
      max: high,
      reverse: reverse || reverses,
      periodMicros: cycle.inMicroseconds.toDouble(),
      count: count,
      onDirection: _setDirection,
    ));
  }

  void _setDirection(bool forward) {
    _forward = forward;
    _status = forward ? AnimationStatus.forward : AnimationStatus.reverse;
    _checkStatusChanged();
  }

  /// Flings with a critically damped spring towards [upperBound] (positive
  /// [velocity], in units per second) or [lowerBound] (negative).
  TickerFuture fling({
    double velocity = 1.0,
    SpringDescription? springDescription,
    AnimationBehavior? animationBehavior,
  }) {
    _throwIfDisposed('fling');
    _forward = velocity >= 0.0;
    const double overshoot = 0.01;
    final double target =
        _forward ? upperBound + overshoot : lowerBound - overshoot;
    final SpringSimulation simulation = SpringSimulation(
      spring: springDescription ??
          SpringDescription.withDampingRatio(stiffness: 500.0),
      start: _value,
      end: target,
      velocity: velocity,
      tolerance:
          const Tolerance(velocity: double.infinity, distance: overshoot),
    );
    stop();
    return _startSimulation(simulation);
  }

  /// Drives the value with [simulation] until it is done. Ends with
  /// [AnimationStatus.completed].
  TickerFuture animateWith(Simulation simulation) {
    _throwIfDisposed('animateWith');
    stop();
    _forward = true;
    return _startSimulation(simulation);
  }

  /// [animateWith], ending with [AnimationStatus.dismissed].
  TickerFuture animateBackWith(Simulation simulation) {
    _throwIfDisposed('animateBackWith');
    stop();
    _forward = false;
    return _startSimulation(simulation);
  }

  TickerFuture _startSimulation(Simulation simulation) {
    final _SimulationRun run = _SimulationRun(simulation);
    if (!_ticker.canTick) {
      // No clock: play the simulation out at once, in 16 ms steps.
      double micros = 0;
      const double step = 16000;
      const double limit = 600 * 1000000.0;
      while (!run.isDone(micros) && micros < limit) {
        micros += step;
      }
      final double before = _value;
      _value = _clamp(run.x(micros));
      if (_value != before) notifyListeners();
      _status =
          _forward ? AnimationStatus.completed : AnimationStatus.dismissed;
      _checkStatusChanged();
      return TickerFuture.complete();
    }
    return _startRun(run);
  }

  TickerFuture _startRun(_Run run) {
    _run = run;
    _runMicros = 0.0;
    _lastTickElapsed = Duration.zero;
    _lastElapsedDuration = Duration.zero;
    final double before = _value;
    _value = _clamp(run.x(0.0));
    final TickerFuture future = _ticker.start();
    if (_value != before) notifyListeners();
    _status = _forward ? AnimationStatus.forward : AnimationStatus.reverse;
    _checkStatusChanged();
    return future;
  }

  /// Stops the run in progress, leaving [value] and [status] as they are.
  ///
  /// The status is not reset: a controller halted at 0.4 on its way up is
  /// still logically going forward, which is what a later [forward] resumes.
  /// With [canceled] true - the default, as in Flutter - the run's
  /// [TickerFuture] never completes and its `orCancel` fails; with false it
  /// completes.
  void stop({bool canceled = true}) {
    if (_disposed) return;
    _run = null;
    _lastElapsedDuration = null;
    _ticker.stop(canceled: canceled);
  }

  /// Returns to [lowerBound], which reports [AnimationStatus.dismissed].
  void reset() {
    _throwIfDisposed('reset');
    value = lowerBound;
  }

  /// Moves to a new [TickerProvider] - the widget's ticker mode or clock
  /// changed - keeping the run in progress.
  void resync(TickerProvider vsync) {
    _throwIfDisposed('resync');
    final Ticker old = _ticker;
    _ticker = vsync.createTicker(_tick)..absorbTicker(old);
  }

  /// Releases the ticker. Using the controller afterwards throws.
  void dispose() {
    if (_disposed) return;
    _ticker.dispose();
    _disposed = true;
    _run = null;
    _listeners.clear();
    _statusListeners.clear();
  }

  /// Advances the controller to [timestamp] directly, as its clock would.
  ///
  /// The controller is driven by its [Ticker]; this is the
  /// [AnimationTicker] entry point kept for code that ticks one by hand.
  @override
  void tick(Duration timestamp) {
    if (_disposed) return;
    _ticker.tick(timestamp);
  }

  void _tick(Duration elapsed) {
    final _Run? run = _run;
    if (run == null || _disposed) return;
    _lastElapsedDuration = elapsed;
    final int stepMicros = (elapsed - _lastTickElapsed).inMicroseconds;
    _lastTickElapsed = elapsed;
    if (stepMicros <= 0) return;
    _runMicros += stepMicros * _speed;
    final double before = _value;
    _value = _clamp(run.x(_runMicros));
    final bool done = run.isDone(_runMicros);
    if (done) {
      _status =
          _forward ? AnimationStatus.completed : AnimationStatus.dismissed;
      stop(canceled: false);
    }
    if (_value != before) notifyListeners();
    _checkStatusChanged();
  }

  double _clamp(double value) => value.clamp(lowerBound, upperBound);

  void _internalSetValue(double newValue) {
    _value = _clamp(newValue);
    if (_value == lowerBound) {
      _status = AnimationStatus.dismissed;
    } else if (_value == upperBound) {
      _status = AnimationStatus.completed;
    } else {
      _status = _forward ? AnimationStatus.forward : AnimationStatus.reverse;
    }
  }

  void _checkStatusChanged() {
    final AnimationStatus status = _status;
    if (_lastReportedStatus == status) return;
    _lastReportedStatus = status;
    notifyStatusListeners(status);
  }

  void _requireDuration(String method, {required bool reverse}) {
    if (_duration == null && !(reverse && reverseDuration != null)) {
      throw StateError(
        'AnimationController.$method() called with no default duration. Set '
        'duration${reverse ? ' or reverseDuration' : ''}, in the constructor '
        'or later, before calling $method().',
      );
    }
  }

  void _requireBounded(String method) {
    if (!lowerBound.isFinite || !upperBound.isFinite) {
      throw StateError(
        'AnimationController.$method() needs finite bounds; an unbounded '
        'controller is driven with animateTo() or animateWith()',
      );
    }
  }

  void _throwIfDisposed(String method) {
    if (_disposed) {
      throw StateError(
          'AnimationController.$method() was called after dispose().');
    }
  }

  @override
  String toString() => 'AnimationController(value: ${_value.toStringAsFixed(3)}'
      ', status: ${_status.name}${isAnimating ? '' : '; paused'}'
      '${_disposed ? '; DISPOSED' : _ticker.muted ? '; silenced' : ''}'
      '${debugLabel == null ? '' : '; for $debugLabel'})';
}

/// One run of an [AnimationController], in simulated microseconds.
abstract class _Run {
  double x(double micros);

  /// Units per second.
  double dx(double micros);

  bool isDone(double micros);
}

/// From one value to another over a time, through a curve.
final class _InterpolationRun implements _Run {
  _InterpolationRun(this.begin, this.end, this.durationMicros, this.curve);

  final double begin;
  final double end;
  final double durationMicros;
  final Curve curve;

  @override
  double x(double micros) {
    final double t = (micros / durationMicros).clamp(0.0, 1.0);
    if (t == 0.0) return begin;
    if (t == 1.0) return end;
    return begin + (end - begin) * curve.transform(t);
  }

  @override
  double dx(double micros) {
    const double epsilon = 1000.0;
    return (x(micros + epsilon) - x(micros - epsilon)) / (2 * epsilon) * 1e6;
  }

  @override
  bool isDone(double micros) => micros >= durationMicros;
}

/// Between two values, round and round.
final class _RepeatingRun implements _Run {
  _RepeatingRun({
    required double initialValue,
    required this.min,
    required this.max,
    required this.reverse,
    required this.periodMicros,
    required this.count,
    required this.onDirection,
  }) : initialMicros = max == min
            ? 0.0
            : (initialValue.clamp(min, max) - min) / (max - min) * periodMicros;

  final double min;
  final double max;
  final bool reverse;
  final double periodMicros;
  final int? count;
  final void Function(bool forward) onDirection;
  final double initialMicros;

  late final double _exitMicros = count! * periodMicros - initialMicros;

  @override
  double x(double micros) {
    final int? count = this.count;
    if (count != null && micros >= _exitMicros) {
      return reverse && count.isEven ? min : max;
    }
    final double total = micros + initialMicros;
    final double cycles = total / periodMicros;
    final int turns = cycles.floor();
    final double t = cycles - turns;
    if (reverse && turns.isOdd) {
      onDirection(false);
      return max * (1.0 - t) + min * t;
    }
    onDirection(true);
    return min * (1.0 - t) + max * t;
  }

  @override
  double dx(double micros) => (max - min) / periodMicros * 1e6;

  @override
  bool isDone(double micros) => count != null && micros >= _exitMicros;
}

/// A [Simulation], with its time in microseconds.
final class _SimulationRun implements _Run {
  _SimulationRun(this.simulation);

  final Simulation simulation;

  static Duration _at(double micros) => Duration(microseconds: micros.round());

  @override
  double x(double micros) => simulation.x(_at(micros));

  @override
  double dx(double micros) => simulation.dx(_at(micros));

  @override
  bool isDone(double micros) => simulation.isDone(_at(micros));
}

/// A `double` animation with a [Curve] applied on top of a parent.
///
/// Separate from the controller on purpose: two properties driven by one
/// controller can use different curves, which is impossible if the curve lives
/// in the driver.
final class CurvedAnimation extends Animation<double> with _AnimationListeners {
  CurvedAnimation({
    required this.parent,
    required this.curve,
    Curve? reverseCurve,
  }) : reverseCurve = reverseCurve ?? curve {
    parent.addListener(notifyListeners);
    parent.addStatusListener(notifyStatusListeners);
  }

  final Animation<double> parent;
  final Curve curve;

  /// The curve used while the parent runs backwards.
  ///
  /// A transition that eases *out* on the way in should ease *in* on the way
  /// back, or the two directions feel like different animations.
  final Curve reverseCurve;

  @override
  double get value {
    final double t = parent.value;
    final Curve active =
        parent.status == AnimationStatus.reverse ? reverseCurve : curve;
    return active.transform(t.clamp(0.0, 1.0));
  }

  @override
  AnimationStatus get status => parent.status;

  @override
  bool get isAnimating => parent.isAnimating;

  /// Detaches from the parent. Required, or the parent keeps this alive and
  /// keeps notifying a listener nobody reads.
  void dispose() {
    parent.removeListener(notifyListeners);
    parent.removeStatusListener(notifyStatusListeners);
  }
}

/// Maps normalized progress onto a value of type [T].
///
/// [transform] answers the endpoints without interpolating, so an animation
/// that runs to completion lands on exactly the object it declared as [end] -
/// including for types where interpolation cannot be exact, such as a rounded
/// integer colour channel.
abstract base class Tween<T> {
  const Tween({required this.begin, required this.end});

  final T begin;
  final T end;

  /// The value strictly between the endpoints. Implementations may assume
  /// `0 < t < 1`, and may be called with `t` outside `[0, 1]` only if the
  /// caller deliberately extrapolates via [lerp].
  T lerp(double t);

  /// The value at [t], with the endpoints answered exactly.
  T transform(double t) {
    if (t <= 0.0) return begin;
    if (t >= 1.0) return end;
    return lerp(t);
  }

  /// This tween driven by [animation].
  Animation<T> animate(Animation<double> animation) =>
      _TweenAnimation<T>(parent: animation, tween: this);

  /// The value this tween has at [animation]'s current progress.
  T evaluate(Animation<double> animation) => transform(animation.value);
}

/// A [Tween] over `double`.
final class DoubleTween extends Tween<double> {
  const DoubleTween({required super.begin, required super.end});

  /// Weighted on both ends rather than `begin + (end - begin) * t`, for the
  /// same reason [Offset.lerp] is: the weighted form is exact at the
  /// endpoints.
  @override
  double lerp(double t) => begin * (1.0 - t) + end * t;

  /// Free-standing interpolation for callers that have two values and a `t`
  /// but no tween object to hold.
  static double interpolate(double a, double b, double t) =>
      a * (1.0 - t) + b * t;
}

/// A [Tween] over [Offset].
final class OffsetTween extends Tween<Offset> {
  const OffsetTween({required super.begin, required super.end});

  @override
  Offset lerp(double t) => Offset.lerp(begin, end, t)!;
}

/// A [Tween] over [Size].
final class SizeTween extends Tween<Size> {
  const SizeTween({required super.begin, required super.end});

  @override
  Size lerp(double t) => Size.lerp(begin, end, t)!;
}

/// A [Tween] over [Rect].
final class RectTween extends Tween<Rect> {
  const RectTween({required super.begin, required super.end});

  @override
  Rect lerp(double t) => Rect.lerp(begin, end, t)!;
}

/// A [Tween] over an `0xAARRGGBB` colour, interpolated in **premultiplied**
/// alpha space.
///
/// ## Why premultiplied, stated in full because getting it wrong is invisible
/// until it is ugly
///
/// The framework stores colours straight (non-premultiplied): the RGB channels
/// are the colour, the A channel is separately how much of it to apply. That
/// storage is right - it round-trips, and it is what a theme file wants to
/// contain - but it is the wrong space to *interpolate* in whenever the two
/// alphas differ.
///
/// Consider fading an opaque red `0xFFFF0000` out to `0x00000000`, which is
/// how "transparent" is spelled essentially everywhere. Interpolating the four
/// channels straight gives, at the halfway point, `0x807F0000`: alpha 50% as
/// wanted, but the RGB has been dragged halfway to black. Composited over a
/// light background that reads as a **grey-brown smear**, not as red getting
/// fainter. Every channel of the destination is meaningless in straight space,
/// because when alpha is zero the colour is not "black", it is *nothing* - and
/// straight interpolation has no way to know that.
///
/// In premultiplied space the same fade is exact. Premultiplying folds the
/// alpha into the channels first (`r * a`), so the transparent endpoint is
/// genuinely the origin, `(0, 0, 0, 0)`, and interpolating towards it scales
/// the colour down in lockstep with its own alpha. Unpremultiplying at the end
/// recovers `0x80FF0000` - fully saturated red at half alpha, which is what
/// "fading out" means.
///
/// The choice costs nothing in the common case: when both endpoints are
/// opaque, premultiplying by `1.0` is the identity and the result is bit-for-
/// bit the straight interpolation.
///
/// ## Declared limits
///
/// * This is **not** perceptual interpolation. Channels are treated as linear
///   in their sRGB-encoded values, matching the rest of the rasterizer, which
///   also blends in encoded space. A red-to-green fade therefore passes
///   through a darker midpoint than a Lab-space blend would. Fixing that means
///   changing the *rasterizer's* blend space too, and doing it here alone
///   would make a tween disagree with the compositor.
/// * Rounding is to nearest, half away from zero, per channel, once, at the
///   end. Interpolating in integers throughout would accumulate a channel of
///   error over a long fade.
final class ColorTween extends Tween<int> {
  const ColorTween({required super.begin, required super.end});

  @override
  int lerp(double t) => interpolate(begin, end, t);

  /// Interpolates two `0xAARRGGBB` colours. Exposed free-standing so a
  /// property transition can use it without allocating a tween per frame.
  static int interpolate(int a, int b, double t) {
    if (t <= 0.0) return a;
    if (t >= 1.0) return b;

    final int alphaA = (a >> 24) & 0xFF;
    final int alphaB = (b >> 24) & 0xFF;

    // Normalized alpha, so the premultiplied channels stay on the 0..255
    // scale and the unpremultiply at the end is a plain division.
    final double fa = alphaA / 255.0;
    final double fb = alphaB / 255.0;

    final double alpha = alphaA + (alphaB - alphaA) * t;
    final double alphaScale = alpha / 255.0;

    final int channels = _lerpChannel(a, b, 16, fa, fb, t, alphaScale) << 16 |
        _lerpChannel(a, b, 8, fa, fb, t, alphaScale) << 8 |
        _lerpChannel(a, b, 0, fa, fb, t, alphaScale);

    return (_toByte(alpha) << 24) | channels;
  }

  static int _lerpChannel(
    int a,
    int b,
    int shift,
    double alphaA,
    double alphaB,
    double t,
    double alphaOut,
  ) {
    final double premultipliedA = ((a >> shift) & 0xFF) * alphaA;
    final double premultipliedB = ((b >> shift) & 0xFF) * alphaB;
    final double premultiplied =
        premultipliedA + (premultipliedB - premultipliedA) * t;
    // A fully transparent result carries no colour. Reporting zero rather
    // than dividing by zero is the only defined answer, and it matches how a
    // transparent pixel is stored everywhere else in the framework.
    if (alphaOut == 0.0) return 0;
    return _toByte(premultiplied / alphaOut);
  }

  static int _toByte(double value) {
    final int rounded = value.round();
    return rounded < 0 ? 0 : (rounded > 255 ? 255 : rounded);
  }
}

/// An [Animation] whose value is a [Tween] read at a parent's progress.
final class _TweenAnimation<T> extends Animation<T> with _AnimationListeners {
  _TweenAnimation({required this.parent, required this.tween}) {
    parent.addListener(notifyListeners);
    parent.addStatusListener(notifyStatusListeners);
  }

  final Animation<double> parent;
  final Tween<T> tween;

  @override
  T get value => tween.transform(parent.value);

  @override
  AnimationStatus get status => parent.status;

  @override
  bool get isAnimating => parent.isAnimating;
}
