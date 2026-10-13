// Portions of this file are adapted from the Flutter framework
// (packages/flutter/lib/src/widgets/scroll_physics.dart and
// scroll_simulation.dart):
//
// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file of the Flutter repository.

/// How a scroll view answers the user: Flutter's `ScrollPhysics` family.
///
/// A physics decides four things, and the scroll view asks it each time:
///
///  * whether the user may scroll at all ([shouldAcceptUserOffset]) -
///    [NeverScrollableScrollPhysics] says no, [AlwaysScrollableScrollPhysics]
///    says yes even when the content fits;
///  * how a drag maps to movement ([applyPhysicsToUserOffset]) - resistance
///    past an edge for [BouncingScrollPhysics];
///  * how far past an edge the offset may go ([applyBoundaryConditions]) -
///    not at all for [ClampingScrollPhysics];
///  * what happens after the finger lifts ([createBallisticSimulation]) - a
///    fling, a spring back to the edge, a spring to the nearest page.
///
/// Physics chain through [parent], and a scroll view applies the one it is
/// given to the platform default, [ClampingScrollPhysics]: `PageScrollPhysics()`
/// becomes `PageScrollPhysics(parent: ClampingScrollPhysics())`.
///
/// ## Differences from Flutter
///
///  * A scroll view given **no** physics keeps this framework's own scrolling
///    - the same clamping, the same fling (0.94 friction per 16 ms step) - and
///    does not consult a physics object at all. Passing
///    `ClampingScrollPhysics()` gives the same feel through the physics path.
///    The default is clamping on every platform, macOS included, where
///    Flutter bounces.
///  * [Simulation] here takes a [Duration], not seconds; a physics written
///    for Flutter that overrides [createBallisticSimulation] must return one.
///  * [ScrollDecelerationRate.fast] changes the spring, not the friction: the
///    friction simulation has no constant deceleration term.
///  * `adjustPositionForNewDimensions`, `recommendDeferredLoading` and
///    `RangeMaintainingScrollPhysics` are not here; a list that changes
///    length is re-clamped by the position itself.
library;

import 'dart:math' as math;

import '../animation/simulation.dart';
import '../gestures/constants.dart';
import '../layout/scroll_metrics.dart';

/// How quickly a [BouncingScrollPhysics] fling slows down.
enum ScrollDecelerationRate {
  /// The iOS default.
  normal,

  /// Faster, as in a Safari page.
  fast,
}

/// Determines the physics of a scroll view. The base class defers to
/// [parent] for everything and, without one, behaves neutrally: no
/// resistance, no boundary, no fling.
class ScrollPhysics {
  const ScrollPhysics({this.parent});

  /// The physics this one defers to for what it does not decide itself.
  final ScrollPhysics? parent;

  /// [parent] applied to [ancestor], or [ancestor] when there is no parent:
  /// the parent an [applyTo] override passes to its own constructor.
  ScrollPhysics? buildParent(ScrollPhysics? ancestor) =>
      parent?.applyTo(ancestor) ?? ancestor;

  /// This physics with [ancestor] at the end of its [parent] chain.
  ///
  /// Every subclass overrides it to return an instance of itself, which is
  /// what keeps a chain's types: `BouncingScrollPhysics().applyTo(x)` is
  /// still a [BouncingScrollPhysics].
  ScrollPhysics applyTo(ScrollPhysics? ancestor) =>
      ScrollPhysics(parent: buildParent(ancestor));

  /// The movement a user drag of [offset] causes, given [position].
  ///
  /// [offset] is in Flutter's sense: positive towards offset zero (a finger
  /// dragged down a list), so the position moves by `-result`.
  double applyPhysicsToUserOffset(ScrollMetrics position, double offset) =>
      parent?.applyPhysicsToUserOffset(position, offset) ?? offset;

  /// Whether the user may scroll [position] by dragging, the wheel or the
  /// keyboard. By default, only when there is content to reveal.
  bool shouldAcceptUserOffset(ScrollMetrics position) {
    if (!allowUserScrolling) return false;
    final ScrollPhysics? parent = this.parent;
    if (parent == null) {
      return position.pixels != 0.0 ||
          position.minScrollExtent != position.maxScrollExtent;
    }
    return parent.shouldAcceptUserOffset(position);
  }

  /// How much of moving [position] to [value] must not happen: zero to allow
  /// it, the overscroll otherwise.
  double applyBoundaryConditions(ScrollMetrics position, double value) =>
      parent?.applyBoundaryConditions(position, value) ?? 0.0;

  /// The motion after the user lets go at [velocity] pixels per second (in
  /// offset terms), or null for none.
  Simulation? createBallisticSimulation(
    ScrollMetrics position,
    double velocity,
  ) =>
      parent?.createBallisticSimulation(position, velocity);

  static final SpringDescription _kDefaultSpring =
      SpringDescription.withDampingRatio(
    mass: 0.5,
    stiffness: 100.0,
    ratio: 1.1,
  );

  /// The spring ballistic simulations use.
  SpringDescription get spring => parent?.spring ?? _kDefaultSpring;

  /// When a simulation counts as settled.
  Tolerance toleranceFor(ScrollMetrics metrics) =>
      parent?.toleranceFor(metrics) ??
      Tolerance(
        velocity: 1.0 / (0.050 * metrics.devicePixelRatio),
        distance: 1.0 / metrics.devicePixelRatio,
      );

  /// The shortest drag that counts as a fling.
  double get minFlingDistance => parent?.minFlingDistance ?? kTouchSlop;

  /// The slowest release that counts as a fling, in pixels per second.
  double get minFlingVelocity => parent?.minFlingVelocity ?? kMinFlingVelocity;

  /// The fastest fling, in pixels per second.
  double get maxFlingVelocity => parent?.maxFlingVelocity ?? kMaxFlingVelocity;

  /// The velocity a new drag inherits from a fling it interrupts.
  double carriedMomentum(double existingVelocity) =>
      parent?.carriedMomentum(existingVelocity) ?? 0.0;

  /// How far a drag must move before it starts scrolling, past the slop.
  double? get dragStartDistanceMotionThreshold =>
      parent?.dragStartDistanceMotionThreshold;

  /// Whether a scroll view may scroll by itself to reveal something, as
  /// focus traversal does.
  bool get allowImplicitScrolling => true;

  /// Whether the user may scroll at all. False only for
  /// [NeverScrollableScrollPhysics], anywhere in the chain.
  bool get allowUserScrolling => parent?.allowUserScrolling ?? true;

  @override
  String toString() =>
      parent == null ? '$runtimeType' : '$runtimeType -> $parent';
}

/// Lets the content be pulled past an edge, with resistance, and springs it
/// back on release: the iOS and macOS feel.
class BouncingScrollPhysics extends ScrollPhysics {
  const BouncingScrollPhysics({
    this.decelerationRate = ScrollDecelerationRate.normal,
    super.parent,
  });

  final ScrollDecelerationRate decelerationRate;

  @override
  BouncingScrollPhysics applyTo(ScrollPhysics? ancestor) =>
      BouncingScrollPhysics(
        parent: buildParent(ancestor),
        decelerationRate: decelerationRate,
      );

  /// The resistance a drag meets when [overscrollFraction] of the viewport
  /// is already past the edge.
  double frictionFactor(double overscrollFraction) {
    return switch (decelerationRate) {
      ScrollDecelerationRate.fast => 0.26 * math.pow(1 - overscrollFraction, 2),
      ScrollDecelerationRate.normal =>
        0.52 * math.pow(1 - overscrollFraction, 2),
    }
        .toDouble();
  }

  @override
  double applyPhysicsToUserOffset(ScrollMetrics position, double offset) {
    if (!position.outOfRange) return offset;
    final double overscrollPastStart =
        math.max(position.minScrollExtent - position.pixels, 0.0);
    final double overscrollPastEnd =
        math.max(position.pixels - position.maxScrollExtent, 0.0);
    final double overscrollPast =
        math.max(overscrollPastStart, overscrollPastEnd);
    final bool easing = (overscrollPastStart > 0.0 && offset < 0.0) ||
        (overscrollPastEnd > 0.0 && offset > 0.0);
    final double viewport =
        position.viewportDimension <= 0 ? 1.0 : position.viewportDimension;
    final double friction = easing
        ? frictionFactor((overscrollPast - offset.abs()) / viewport)
        : frictionFactor(overscrollPast / viewport);
    final double direction = offset.sign;
    if (easing && decelerationRate == ScrollDecelerationRate.fast) {
      return direction * offset.abs();
    }
    return direction * _applyFriction(overscrollPast, offset.abs(), friction);
  }

  static double _applyFriction(
    double extentOutside,
    double absDelta,
    double gamma,
  ) {
    if (absDelta == 0 || gamma <= 0) return 0.0;
    double total = 0.0;
    if (extentOutside > 0) {
      final double deltaToLimit = extentOutside / gamma;
      if (absDelta < deltaToLimit) return absDelta * gamma;
      total += extentOutside;
      absDelta -= deltaToLimit;
    }
    return total + absDelta;
  }

  @override
  double applyBoundaryConditions(ScrollMetrics position, double value) => 0.0;

  @override
  Simulation? createBallisticSimulation(
    ScrollMetrics position,
    double velocity,
  ) {
    final Tolerance tolerance = toleranceFor(position);
    if (velocity.abs() >= tolerance.velocity || position.outOfRange) {
      return BouncingScrollSimulation(
        spring: spring,
        position: position.pixels,
        velocity: velocity,
        leadingExtent: position.minScrollExtent,
        trailingExtent: position.maxScrollExtent,
        tolerance: tolerance,
      );
    }
    return null;
  }

  @override
  double get minFlingVelocity => kMinFlingVelocity * 2.0;

  @override
  double carriedMomentum(double existingVelocity) =>
      existingVelocity.sign *
      math.min(
        0.000816 * math.pow(existingVelocity.abs(), 1.967).toDouble(),
        40000.0,
      );

  @override
  double get dragStartDistanceMotionThreshold => 3.5;

  @override
  double get maxFlingVelocity => switch (decelerationRate) {
        ScrollDecelerationRate.fast => kMaxFlingVelocity * 8.0,
        ScrollDecelerationRate.normal => super.maxFlingVelocity,
      };

  @override
  SpringDescription get spring => switch (decelerationRate) {
        ScrollDecelerationRate.fast => SpringDescription.withDampingRatio(
            mass: 0.3,
            stiffness: 75.0,
            ratio: 1.3,
          ),
        ScrollDecelerationRate.normal => super.spring,
      };
}

/// Stops the content at its edges: the Windows, Linux and Android feel, and
/// the default here.
class ClampingScrollPhysics extends ScrollPhysics {
  const ClampingScrollPhysics({super.parent});

  @override
  ClampingScrollPhysics applyTo(ScrollPhysics? ancestor) =>
      ClampingScrollPhysics(parent: buildParent(ancestor));

  @override
  double applyBoundaryConditions(ScrollMetrics position, double value) {
    if (value < position.pixels &&
        position.pixels <= position.minScrollExtent) {
      return value - position.pixels; // Underscroll.
    }
    if (position.maxScrollExtent <= position.pixels &&
        position.pixels < value) {
      return value - position.pixels; // Overscroll.
    }
    if (value < position.minScrollExtent &&
        position.minScrollExtent < position.pixels) {
      return value - position.minScrollExtent; // Hit the top edge.
    }
    if (position.pixels < position.maxScrollExtent &&
        position.maxScrollExtent < value) {
      return value - position.maxScrollExtent; // Hit the bottom edge.
    }
    return 0.0;
  }

  @override
  Simulation? createBallisticSimulation(
    ScrollMetrics position,
    double velocity,
  ) {
    final Tolerance tolerance = toleranceFor(position);
    if (position.outOfRange) {
      final double end = position.pixels > position.maxScrollExtent
          ? position.maxScrollExtent
          : position.minScrollExtent;
      return SpringSimulation(
        spring: spring,
        start: position.pixels,
        end: end,
        velocity: math.min(0.0, velocity),
        tolerance: tolerance,
      );
    }
    if (velocity.abs() < tolerance.velocity) return null;
    if (velocity > 0.0 && position.pixels >= position.maxScrollExtent) {
      return null;
    }
    if (velocity < 0.0 && position.pixels <= position.minScrollExtent) {
      return null;
    }
    return ClampingScrollSimulation(
      position: position.pixels,
      velocity: velocity,
    );
  }
}

/// Lets the user scroll even when the content fits, so a short list still
/// bounces (with [BouncingScrollPhysics]) or still sends drag notifications.
class AlwaysScrollableScrollPhysics extends ScrollPhysics {
  const AlwaysScrollableScrollPhysics({super.parent});

  @override
  AlwaysScrollableScrollPhysics applyTo(ScrollPhysics? ancestor) =>
      AlwaysScrollableScrollPhysics(parent: buildParent(ancestor));

  @override
  bool shouldAcceptUserOffset(ScrollMetrics position) => true;
}

/// The user cannot scroll: no drag, no wheel, no keys. The program still
/// can, with a controller's `jumpTo` and `animateTo`.
class NeverScrollableScrollPhysics extends ScrollPhysics {
  const NeverScrollableScrollPhysics({super.parent});

  @override
  NeverScrollableScrollPhysics applyTo(ScrollPhysics? ancestor) =>
      NeverScrollableScrollPhysics(parent: buildParent(ancestor));

  @override
  bool get allowUserScrolling => false;

  @override
  bool get allowImplicitScrolling => false;
}

/// The fling of [ClampingScrollPhysics]: the same decay as this framework's
/// default fling - a fixed fraction of the speed lost every 16 ms step - in
/// closed form, so it is identical however the frames are spaced.
///
/// Flutter's class of the same name models Android's spline instead; the
/// constructor takes the same arguments, and `friction` is the fraction of
/// speed kept per step rather than Android's coefficient.
class ClampingScrollSimulation implements Simulation {
  ClampingScrollSimulation({
    required this.position,
    required this.velocity,
    this.friction = 0.94,
    this.step = const Duration(milliseconds: 16),
    this.restVelocity = 8.0,
  }) {
    if (!(friction > 0 && friction < 1)) {
      throw ArgumentError.value(friction, 'friction', 'must be in (0, 1)');
    }
    if (step <= Duration.zero) {
      throw ArgumentError.value(step, 'step', 'must be positive');
    }
  }

  /// Where the fling starts.
  final double position;

  /// The speed it starts at, in pixels per second.
  final double velocity;

  /// The fraction of the speed kept per [step].
  final double friction;

  /// The length of one decay step.
  final Duration step;

  /// The speed below which the fling is over.
  final double restVelocity;

  double get _stepSeconds => step.inMicroseconds / 1000000.0;

  double _steps(Duration time) => time.inMicroseconds / step.inMicroseconds;

  @override
  double x(Duration time) =>
      position +
      velocity *
          _stepSeconds *
          (1 - math.pow(friction, _steps(time))) /
          (1 - friction);

  @override
  double dx(Duration time) => velocity * math.pow(friction, _steps(time));

  @override
  bool isDone(Duration time) => dx(time).abs() < restVelocity;

  @override
  String toString() =>
      'ClampingScrollSimulation(position: $position, velocity: $velocity)';
}

/// A fling that slows by friction and, past an edge, springs back to it.
class BouncingScrollSimulation implements Simulation {
  BouncingScrollSimulation({
    required double position,
    required double velocity,
    required this.leadingExtent,
    required this.trailingExtent,
    required this.spring,
    this.tolerance = Tolerance.defaultTolerance,
  }) {
    if (leadingExtent > trailingExtent) {
      throw ArgumentError(
        'leadingExtent ($leadingExtent) must not exceed trailingExtent '
        '($trailingExtent)',
      );
    }
    if (position < leadingExtent) {
      _springSimulation = _spring(position, leadingExtent, velocity);
      _springTime = null;
    } else if (position > trailingExtent) {
      _springSimulation = _spring(position, trailingExtent, velocity);
      _springTime = null;
    } else {
      // UIScrollView's normal deceleration rate: 0.998 per millisecond.
      final FrictionSimulation friction = FrictionSimulation(
        drag: 0.135,
        position: position,
        velocity: velocity,
        tolerance: tolerance,
      );
      _frictionSimulation = friction;
      final double finalX = friction.finalX;
      final double? edge = velocity > 0.0 && finalX > trailingExtent
          ? trailingExtent
          : velocity < 0.0 && finalX < leadingExtent
              ? leadingExtent
              : null;
      final Duration? at = edge == null ? null : friction.timeAtX(edge);
      if (edge != null && at != null) {
        _springTime = at;
        _springSimulation = _spring(
          edge,
          edge,
          math.min(friction.dx(at), maxSpringTransferVelocity),
        );
      } else {
        _springTime = _never;
      }
    }
  }

  /// The fastest motion handed from the friction to the spring.
  static const double maxSpringTransferVelocity = 5000.0;

  static const Duration _never = Duration(days: 365);

  final double leadingExtent;
  final double trailingExtent;
  final SpringDescription spring;
  final Tolerance tolerance;

  FrictionSimulation? _frictionSimulation;
  Simulation? _springSimulation;

  /// When the friction hands over to the spring; null when the spring runs
  /// from the start (the fling began out of range).
  Duration? _springTime;

  Simulation _spring(double start, double end, double velocity) =>
      SpringSimulation(
        spring: spring,
        start: start,
        end: end,
        velocity: velocity,
        tolerance: tolerance,
      );

  /// The simulation running at [time], and the time to ask it.
  (Simulation, Duration) _at(Duration time) {
    final Duration? springTime = _springTime;
    if (springTime == null) return (_springSimulation!, time);
    if (time > springTime && _springSimulation != null) {
      return (_springSimulation!, time - springTime);
    }
    return (_frictionSimulation!, time);
  }

  @override
  double x(Duration time) {
    final (Simulation simulation, Duration local) = _at(time);
    return simulation.x(local);
  }

  @override
  double dx(Duration time) {
    final (Simulation simulation, Duration local) = _at(time);
    return simulation.dx(local);
  }

  @override
  bool isDone(Duration time) {
    final (Simulation simulation, Duration local) = _at(time);
    return simulation.isDone(local);
  }

  /// Where the motion comes to rest, when it is a spring to an edge.
  double? get restingPosition {
    final Simulation? spring = _springSimulation;
    if (spring is SpringSimulation && _springTime != _never) return spring.end;
    return null;
  }

  @override
  String toString() => 'BouncingScrollSimulation(leadingExtent: '
      '$leadingExtent, trailingExtent: $trailingExtent)';
}
