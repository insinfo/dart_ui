/// Flutter's implicitly animated transforms - [AnimatedScale],
/// [AnimatedRotation], [AnimatedSlide] - plus [AnimatedFractionallySizedBox],
/// [AnimatedPositionedDirectional] and the [PositionedDirectional] it builds.
///
/// They follow the rest of the implicit animations (see
/// `implicit_animation.dart`): the clock comes from the nearest
/// `AnimationScope`, a widget with no scope above it or under
/// `ThemeData.reducedMotion` shows its target at once, a change of target in
/// mid-flight continues from where the value is, and only this widget
/// rebuilds per frame - the child is the same instance every tick.
library;

import 'dart:math' as math;

import '../geometry/offset.dart';
import '../graphics/filter_quality.dart';
import '../layout/alignment.dart';
import '../text/shaper.dart' show TextDirection;
import 'basic.dart';
import 'directionality.dart';
import 'implicit_animation.dart';
import 'listenable_builders.dart' show FractionalTranslation;
import 'proxy.dart';
import 'sizing.dart';
import 'widget.dart';

/// Animates the scale of [child] about [alignment] when [scale] changes -
/// Flutter's `AnimatedScale`.
///
/// Layout is untouched, as with [Transform.scale]: a growing child does not
/// push its siblings. [filterQuality] is accepted and has no effect; see
/// [FilterQuality].
final class AnimatedScale extends ImplicitlyAnimatedWidget {
  const AnimatedScale({
    super.key,
    this.child,
    required this.scale,
    this.alignment = Alignment.center,
    this.filterQuality,
    required super.duration,
    super.curve,
    super.onEnd,
  });

  final Widget? child;

  /// 1 is the child's own size, 0 is nothing.
  final double scale;

  /// The fixed point of the scale; the centre by default.
  final Alignment alignment;

  final FilterQuality? filterQuality;

  @override
  ImplicitlyAnimatedWidgetState<AnimatedScale> createState() =>
      _AnimatedScaleState();
}

final class _AnimatedScaleState
    extends ImplicitlyAnimatedWidgetState<AnimatedScale> {
  late final AnimatedProperty<double> _scale =
      AnimatedProperty<double>(widget.scale, lerpDouble);

  @override
  bool retarget(double from) => _scale.retarget(widget.scale, from);

  @override
  Widget build(BuildContext context) => Transform.scale(
        scale: _scale.at(progress),
        alignment: widget.alignment,
        child: widget.child,
      );
}

/// Animates the rotation of [child] about [alignment] when [turns] changes -
/// Flutter's `AnimatedRotation`.
///
/// [turns] is in whole turns, as in Flutter: `0.25` is a quarter turn
/// clockwise. Going from 0 to 1 spins the child once round.
final class AnimatedRotation extends ImplicitlyAnimatedWidget {
  const AnimatedRotation({
    super.key,
    this.child,
    required this.turns,
    this.alignment = Alignment.center,
    this.filterQuality,
    required super.duration,
    super.curve,
    super.onEnd,
  });

  final Widget? child;

  /// The rotation, in turns.
  final double turns;

  final Alignment alignment;

  final FilterQuality? filterQuality;

  @override
  ImplicitlyAnimatedWidgetState<AnimatedRotation> createState() =>
      _AnimatedRotationState();
}

final class _AnimatedRotationState
    extends ImplicitlyAnimatedWidgetState<AnimatedRotation> {
  late final AnimatedProperty<double> _turns =
      AnimatedProperty<double>(widget.turns, lerpDouble);

  @override
  bool retarget(double from) => _turns.retarget(widget.turns, from);

  @override
  Widget build(BuildContext context) => Transform.rotate(
        angle: _turns.at(progress) * 2 * math.pi,
        alignment: widget.alignment,
        child: widget.child,
      );
}

/// Animates the translation of [child] when [offset] changes, in fractions
/// of the child's own size - Flutter's `AnimatedSlide`.
///
/// `Offset(0.25, 0)` moves the child a quarter of its width to the right.
/// Layout is untouched; hit testing follows the painted position.
final class AnimatedSlide extends ImplicitlyAnimatedWidget {
  const AnimatedSlide({
    super.key,
    this.child,
    required this.offset,
    required super.duration,
    super.curve,
    super.onEnd,
  });

  final Widget? child;

  /// The translation, as a fraction of the child's size.
  final Offset offset;

  @override
  ImplicitlyAnimatedWidgetState<AnimatedSlide> createState() =>
      _AnimatedSlideState();
}

final class _AnimatedSlideState
    extends ImplicitlyAnimatedWidgetState<AnimatedSlide> {
  late final AnimatedProperty<Offset> _offset =
      AnimatedProperty<Offset>(widget.offset, _lerpOffset);

  static Offset _lerpOffset(Offset a, Offset b, double t) => Offset(
        a.dx * (1.0 - t) + b.dx * t,
        a.dy * (1.0 - t) + b.dy * t,
      );

  @override
  bool retarget(double from) => _offset.retarget(widget.offset, from);

  @override
  Widget build(BuildContext context) => FractionalTranslation(
        translation: _offset.at(progress),
        child: widget.child,
      );
}

/// Animates a [FractionallySizedBox]'s factors and alignment when they
/// change - Flutter's `AnimatedFractionallySizedBox`.
///
/// A factor that is null on one side of a change has no number to walk from
/// ("as large as the child wants") and snaps at the midpoint, as
/// [AnimatedAlign]'s factors do.
final class AnimatedFractionallySizedBox extends ImplicitlyAnimatedWidget {
  const AnimatedFractionallySizedBox({
    super.key,
    this.alignment = Alignment.center,
    this.child,
    this.heightFactor,
    this.widthFactor,
    required super.duration,
    super.curve,
    super.onEnd,
  });

  final Widget? child;

  /// A fraction of the incoming height, or null to let the child choose.
  final double? heightFactor;

  /// A fraction of the incoming width, or null to let the child choose.
  final double? widthFactor;

  /// Where the child sits in the box. A physical [Alignment]; resolve an
  /// `AlignmentDirectional` above this widget.
  final Alignment alignment;

  @override
  ImplicitlyAnimatedWidgetState<AnimatedFractionallySizedBox> createState() =>
      _AnimatedFractionallySizedBoxState();
}

final class _AnimatedFractionallySizedBoxState
    extends ImplicitlyAnimatedWidgetState<AnimatedFractionallySizedBox> {
  late final AnimatedProperty<Alignment> _alignment =
      AnimatedProperty<Alignment>(widget.alignment, Alignment.lerp);
  late final AnimatedProperty<double?> _widthFactor =
      AnimatedProperty<double?>(widget.widthFactor, lerpNullableDouble);
  late final AnimatedProperty<double?> _heightFactor =
      AnimatedProperty<double?>(widget.heightFactor, lerpNullableDouble);

  @override
  bool retarget(double from) {
    // Every call runs; see the note in `_AnimatedAlignState.retarget`.
    final bool alignment = _alignment.retarget(widget.alignment, from);
    final bool width = _widthFactor.retarget(widget.widthFactor, from);
    final bool height = _heightFactor.retarget(widget.heightFactor, from);
    return alignment || width || height;
  }

  @override
  Widget build(BuildContext context) {
    final double t = progress;
    return FractionallySizedBox(
      alignment: _alignment.at(t),
      widthFactor: _widthFactor.at(t),
      heightFactor: _heightFactor.at(t),
      child: widget.child,
    );
  }
}

/// A [Positioned] whose horizontal edges are [start] and [end], resolved
/// against the ambient [Directionality] - Flutter's `PositionedDirectional`.
///
/// In a left-to-right subtree [start] is the left edge; in a right-to-left
/// one it is the right edge. Only meaningful as a child of a [Stack].
final class PositionedDirectional extends StatelessWidget {
  const PositionedDirectional({
    super.key,
    this.start,
    this.top,
    this.end,
    this.bottom,
    this.width,
    this.height,
    required this.child,
  });

  final double? start;
  final double? top;
  final double? end;
  final double? bottom;
  final double? width;
  final double? height;
  final Widget child;

  @override
  Widget build(BuildContext context) => _positioned(
        Directionality.maybeOf(context) ?? TextDirection.leftToRight,
        start: start,
        top: top,
        end: end,
        bottom: bottom,
        width: width,
        height: height,
        child: child,
      );
}

Positioned _positioned(
  TextDirection direction, {
  required double? start,
  required double? top,
  required double? end,
  required double? bottom,
  required double? width,
  required double? height,
  required Widget child,
}) {
  final bool ltr = direction == TextDirection.leftToRight;
  return Positioned(
    left: ltr ? start : end,
    top: top,
    right: ltr ? end : start,
    bottom: bottom,
    width: width,
    height: height,
    child: child,
  );
}

/// [AnimatedPositioned] in reading-direction terms: [start] and [end] are
/// resolved against the ambient [Directionality] - Flutter's
/// `AnimatedPositionedDirectional`.
///
/// An edge that is null on one side of a change snaps at the midpoint; see
/// [AnimatedPositioned] for why.
final class AnimatedPositionedDirectional extends ImplicitlyAnimatedWidget {
  const AnimatedPositionedDirectional({
    super.key,
    required this.child,
    this.start,
    this.top,
    this.end,
    this.bottom,
    this.width,
    this.height,
    required super.duration,
    super.curve,
    super.onEnd,
  });

  final Widget child;
  final double? start;
  final double? top;
  final double? end;
  final double? bottom;
  final double? width;
  final double? height;

  @override
  ImplicitlyAnimatedWidgetState<AnimatedPositionedDirectional> createState() =>
      _AnimatedPositionedDirectionalState();
}

final class _AnimatedPositionedDirectionalState
    extends ImplicitlyAnimatedWidgetState<AnimatedPositionedDirectional> {
  late final AnimatedProperty<double?> _start =
      AnimatedProperty<double?>(widget.start, lerpNullableDouble);
  late final AnimatedProperty<double?> _top =
      AnimatedProperty<double?>(widget.top, lerpNullableDouble);
  late final AnimatedProperty<double?> _end =
      AnimatedProperty<double?>(widget.end, lerpNullableDouble);
  late final AnimatedProperty<double?> _bottom =
      AnimatedProperty<double?>(widget.bottom, lerpNullableDouble);
  late final AnimatedProperty<double?> _width =
      AnimatedProperty<double?>(widget.width, lerpNullableDouble);
  late final AnimatedProperty<double?> _height =
      AnimatedProperty<double?>(widget.height, lerpNullableDouble);

  @override
  bool retarget(double from) {
    final bool start = _start.retarget(widget.start, from);
    final bool top = _top.retarget(widget.top, from);
    final bool end = _end.retarget(widget.end, from);
    final bool bottom = _bottom.retarget(widget.bottom, from);
    final bool width = _width.retarget(widget.width, from);
    final bool height = _height.retarget(widget.height, from);
    return start || top || end || bottom || width || height;
  }

  @override
  Widget build(BuildContext context) {
    final double t = progress;
    return _positioned(
      Directionality.maybeOf(context) ?? TextDirection.leftToRight,
      start: _start.at(t),
      top: _top.at(t),
      end: _end.at(t),
      bottom: _bottom.at(t),
      width: _width.at(t),
      height: _height.at(t),
      child: widget.child,
    );
  }
}
