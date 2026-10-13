/// The one animation primitive the Material widgets share: a number that
/// eases towards a target on the window's animation clock.
///
/// Not exported. Each Material widget that moves (the drawer sliding in, a
/// snack bar rising, a tab indicator, an ink ripple) holds one or more of
/// these instead of an `AnimationController`, for two reasons: it can start
/// from wherever it is now (`animateTo` mid-flight is a course correction,
/// not a jump back), and with no clock above - a widget mounted alone in a
/// test - it simply arrives, so the widget still works without animating.
library;

import '../animation/clock.dart';
import '../animation/curves.dart';
import '../foundation/change_notifier.dart';
import '../widgets/animation_scope.dart';
import '../widgets/theme.dart' as dui;
import '../widgets/widget.dart';

/// A value in motion; listeners hear every step.
final class Motion extends ChangeNotifier implements AnimationTicker {
  Motion([double value = 0]) : _value = value;

  double _value;
  double _from = 0;
  double _to = 0;
  Duration _duration = Duration.zero;
  Curve _curve = Curves.linear;
  Duration? _origin;
  bool _running = false;
  void Function()? _onDone;
  AnimationClock? _clock;
  bool _reducedMotion = false;
  bool _disposed = false;

  double get value => _value;

  /// Where the value is heading (its value when at rest).
  double get target => _running ? _to : _value;

  bool get isAnimating => _running;

  @override
  bool get isTicking => _running && !_disposed;

  /// Takes the clock (and the reduced-motion preference) from [context]'s
  /// ambient scope; call from `didChangeDependencies` or `build`.
  void bindTo(BuildContext context) {
    _reducedMotion = dui.Theme.of(context).reducedMotion;
    bind(AnimationScope.maybeOf(context));
  }

  /// Registers with [clock] (null: no clock, every change is immediate).
  void bind(AnimationClock? clock) {
    if (identical(clock, _clock) || _disposed) return;
    _clock?.removeTicker(this);
    _clock = clock;
    clock?.addTicker(this);
    if (clock == null && _running) _finish();
  }

  /// Moves to [target] over [duration] along [curve], from where it is now.
  void animateTo(
    double target, {
    required Duration duration,
    Curve curve = Curves.fastOutSlowIn,
    void Function()? onDone,
  }) {
    if (_disposed) return;
    final AnimationClock? clock = _clock;
    if (clock == null ||
        _reducedMotion ||
        duration <= Duration.zero ||
        target == _value) {
      _running = false;
      _onDone = null;
      final bool changed = target != _value;
      _value = target;
      if (changed) notifyListeners();
      onDone?.call();
      return;
    }
    _from = _value;
    _to = target;
    _duration = duration;
    _curve = curve;
    _origin = null;
    _onDone = onDone;
    _running = true;
    clock.requestFrame();
  }

  /// Sets the value at once, stopping any motion.
  void jumpTo(double value) {
    if (_disposed) return;
    _running = false;
    _onDone = null;
    if (value == _value) return;
    _value = value;
    notifyListeners();
  }

  @override
  void tick(Duration timestamp) {
    if (!_running || _disposed) return;
    final Duration origin = _origin ??= timestamp;
    final double t =
        ((timestamp - origin).inMicroseconds / _duration.inMicroseconds)
            .clamp(0.0, 1.0);
    if (t >= 1.0) {
      _finish();
      return;
    }
    _value = _from + (_to - _from) * _curve.transform(t);
    notifyListeners();
  }

  void _finish() {
    _running = false;
    _value = _to;
    final void Function()? done = _onDone;
    _onDone = null;
    notifyListeners();
    done?.call();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _clock?.removeTicker(this);
    _clock = null;
    super.dispose();
  }
}

/// Material 3's standard easing (`Easing.standard`).
const Curve kStandardEasing = Cubic(0.2, 0.0, 0.0, 1.0);

/// Material 3's emphasized deceleration, for things arriving.
const Curve kEmphasizedDecelerate = Cubic(0.05, 0.7, 0.1, 1.0);

/// Material 3's emphasized acceleration, for things leaving.
const Curve kEmphasizedAccelerate = Cubic(0.3, 0.0, 0.8, 0.15);
