/// Implicitly animated widgets: change a target, and the widget walks there.
///
/// The explicit half of the animation system - [AnimationController], [Curve],
/// `Tween` - has been here since section 32. What was missing is the half a
/// screen is actually written in: `AnimatedOpacity(opacity: _selected ? 1 : 0)`
/// rather than a controller, a listener, a `dispose` and a `setState` written
/// out by hand at every call site.
///
/// ## Why the ticker does not drive the rebuild naively
///
/// A ticker runs *inside* the frame: `AnimationClock.tick` is a frame callback,
/// so it fires between the build scope and layout. A `setState` from a tick
/// therefore dirties the build of the frame that is already settling, and the
/// window loop answers with "the frame did not settle in 8 passes" if that dirt
/// can regenerate itself. Two properties keep it from doing so here:
///
///   1. **the tick is idempotent within one frame.** Every settle pass pumps
///      the scheduler again, which re-runs the frame callbacks with the *same*
///      timestamp - the dispatcher's clock only moves inside `advance`, never
///      inside `drain`. [AnimationController.tick] turns a zero-length step
///      into a no-op, so the second pass notifies nobody and the loop converges
///      on pass two at the latest;
///   2. **the rebuild stops at this widget.** [State.build] here returns a
///      wrapper around `widget.child`, and `widget.child` is the *same widget
///      instance* on every tick, so `Element.updateChild` takes its
///      `identical` short circuit and the subtree below is not rebuilt at all.
///      A fade over a whole panel therefore costs one element rebuild per
///      frame, not one per descendant.
///
/// The transition is never *started* from a tick, only from
/// [State.didUpdateWidget], which is a build-time event. That is the rule that
/// keeps the cycle out: a tick can change a value, but it can never change
/// what the animation is aiming at.
///
/// ## No ambient clock
///
/// There is no global ticker provider in this framework - see
/// `animation/clock.dart` for why. The clock comes from the nearest
/// [AnimationScope], which `DartUiApp` installs. **With no scope above it, an
/// implicitly animated widget still works and simply does not animate:** every
/// property reads its target immediately. That is what lets a control be
/// mounted alone in a widget test, and it is the same rule
/// `CircularProgressIndicator` already follows.
///
/// [ThemeData.reducedMotion] is honoured for the same reason and by the same
/// mechanism: the transition is skipped, not slowed.
library;

import 'package:meta/meta.dart';

import '../animation/animation.dart';
import '../animation/clock.dart';
import '../animation/curves.dart';
import '../graphics/color.dart';
import '../layout/alignment.dart';
import '../layout/edge_insets.dart';
import 'animation_scope.dart';
import 'basic.dart';
import 'proxy.dart';
import 'theme.dart';
import 'widget.dart';

/// One property being walked from where it was to where it now has to be.
///
/// This exists because `animation/Tween` is immutable and its `begin`/`end` are
/// non-nullable, which is exactly right for an explicit animation - a tween is
/// a pure function from `t` to a value, and a mutable one cannot be shared
/// between two controllers safely. An implicit animation needs the opposite: a
/// single property that is *re-aimed* over and over, from wherever it happens
/// to be at the moment the target changed. Reusing `Tween` would have meant
/// allocating a new one per property per retarget and storing it in a nullable
/// field, which is Flutter's shape and the reason its `forEachTween` visitor is
/// as awkward as it is.
///
/// The lerp is a parameter rather than a subclass hook so that a state class
/// can hold four of these for four different types without four classes.
final class AnimatedProperty<V> {
  /// Starts at rest: `begin` and `end` are both [value], so [at] answers
  /// [value] for every `t` until something retargets it.
  AnimatedProperty(V value, this.lerp)
      : begin = value,
        end = value;

  /// Where this property was when the current transition started.
  V begin;

  /// Where it is going.
  V end;

  /// How to interpolate this property's type.
  final V Function(V a, V b, double t) lerp;

  /// The value at curved progress [t].
  ///
  /// The two ends are returned by identity rather than computed. That is not a
  /// micro-optimisation: it is what makes a finished transition land on exactly
  /// the value the caller asked for, with no float drift and - for a value type
  /// compared by `identical`, which is how [DefaultTextStyle] decides whether
  /// to notify - no spurious change once the animation is over.
  V at(double t) {
    if (t <= 0.0) return begin;
    if (t >= 1.0) return end;
    return lerp(begin, end, t);
  }

  /// Re-aims at [target] from the value this property has at [t].
  ///
  /// Returns whether anything moved. Answering false for an unchanged target is
  /// the whole reason a rebuild triggered by something else - a parent's
  /// `setState`, a theme change - does not restart a fade halfway through.
  bool retarget(V target, double t) {
    if (target == end) return false;
    begin = at(t);
    end = target;
    return true;
  }
}

/// Linear interpolation for a plain `double`.
double lerpDouble(double a, double b, double t) => a * (1.0 - t) + b * t;

/// Interpolation for a nullable `double`, as [AnimatedPositioned]'s edges need.
///
/// Null means "this edge is not constrained", which is a structural fact and
/// not a number, so there is nothing between it and `12.0` to interpolate
/// through. The pair therefore snaps at the midpoint instead of being smoothed,
/// and the class comment on [AnimatedPositioned] says so - a silent
/// `null -> 0.0` would slide a child from the stack's edge instead of leaving
/// it where the caller put it.
double? lerpNullableDouble(double? a, double? b, double t) {
  if (a == null || b == null) return t < 0.5 ? a : b;
  return a * (1.0 - t) + b * t;
}

/// Interpolation for a [Color], premultiplied; see `ColorTween.interpolate`.
Color lerpColor(Color a, Color b, double t) =>
    Color(ColorTween.interpolate(a.value, b.value, t));

/// Interpolation for [EdgeInsets], edge by edge.
EdgeInsets lerpEdgeInsets(EdgeInsets a, EdgeInsets b, double t) {
  final double inverse = 1.0 - t;
  return EdgeInsets(
    a.left * inverse + b.left * t,
    a.top * inverse + b.top * t,
    a.right * inverse + b.right * t,
    a.bottom * inverse + b.bottom * t,
  );
}

/// Interpolation for the portable [TextStyle] subset.
///
/// Only the continuous fields move: [TextStyle.color] through the premultiplied
/// colour lerp, [TextStyle.fontSize] and [TextStyle.height] linearly. A font
/// family and a font weight are selections from a set, not points on a line -
/// there is no face halfway between `Inter` and `Roboto` and no registered
/// weight between 400 and 700 that a shaper could ask for - so those two snap at
/// the midpoint, which is what Flutter's `TextStyle.lerp` does for the same
/// reason.
///
/// A field that is null on one side and set on the other snaps too: null means
/// "inherit whatever is above", and inheritance has no numeric value to walk
/// away from.
TextStyle lerpTextStyle(TextStyle a, TextStyle b, double t) {
  final Color? aColor = a.color;
  final Color? bColor = b.color;
  final double? aSize = a.fontSize;
  final double? bSize = b.fontSize;
  final double? aHeight = a.height;
  final double? bHeight = b.height;
  return TextStyle(
    color: aColor == null || bColor == null
        ? (t < 0.5 ? aColor : bColor)
        : lerpColor(aColor, bColor, t),
    fontSize: lerpNullableDouble(aSize, bSize, t),
    fontFamily: t < 0.5 ? a.fontFamily : b.fontFamily,
    fontWeight: t < 0.5 ? a.fontWeight : b.fontWeight,
    height: lerpNullableDouble(aHeight, bHeight, t),
  );
}

/// The base every implicitly animated widget shares.
///
/// Matches Flutter's `ImplicitlyAnimatedWidget` in name and in the three
/// parameters that reach a call site - [duration], [curve] and [onEnd]. What is
/// deliberately different is the state protocol below: Flutter's
/// `forEachTween` visitor exists to work around nullable, mutable `Tween`
/// fields, and this framework's tween is neither, so [AnimatedProperty] and
/// [ImplicitlyAnimatedWidgetState.retarget] take its place. Code that merely
/// *uses* these widgets sees no difference; code that subclassed
/// `ImplicitlyAnimatedWidget` in Flutter has to rewrite one method.
abstract class ImplicitlyAnimatedWidget extends StatefulWidget {
  const ImplicitlyAnimatedWidget({
    super.key,
    this.curve = Curves.linear,
    required this.duration,
    this.onEnd,
  });

  /// Shapes the progress. Applied on top of the linear controller rather than
  /// inside it, per `animation/animation.dart`.
  final Curve curve;

  /// How long a full transition takes.
  ///
  /// [Duration.zero] is legal and means "do not animate": no controller is
  /// created at all, which is the only honest reading and also the one that
  /// cannot divide by zero. `AnimationController` rejects a zero duration for
  /// exactly that reason, so this class never hands it one.
  final Duration duration;

  /// Called once each time a transition reaches its target.
  ///
  /// Not called when the target changes mid-flight - that transition never
  /// ended - and not called when the widget is rebuilt with the value it
  /// already had.
  final void Function()? onEnd;

  @override
  ImplicitlyAnimatedWidgetState<ImplicitlyAnimatedWidget> createState();
}

/// The state that owns the controller and the curved progress.
///
/// A subclass declares its [AnimatedProperty] fields, implements [retarget] to
/// aim them at the new widget's values, and reads them at [progress] in
/// `build`. Everything else - finding the clock, creating and disposing the
/// controller, restarting it, firing [ImplicitlyAnimatedWidget.onEnd] - happens
/// here.
abstract class ImplicitlyAnimatedWidgetState<T extends ImplicitlyAnimatedWidget>
    extends State<T> {
  AnimationController? _controller;

  /// The duration [_controller] was built for, so that changing
  /// [ImplicitlyAnimatedWidget.duration] rebuilds it instead of silently
  /// keeping the old timing. `AnimationController.duration` is final, which is
  /// the right call there and the reason this field exists here.
  Duration? _controllerDuration;

  /// How far through the transition currently in flight, after the curve.
  ///
  /// `1` whenever nothing is running - no clock, zero duration, reduced motion,
  /// or a finished transition - which is what makes every property read its
  /// target value at rest without a second code path for the still case.
  @protected
  double get progress {
    final AnimationController? controller = _controller;
    if (controller == null) return 1.0;
    return widget.curve.transform(controller.value);
  }

  /// Aims every animated property at the targets in [widget], starting from the
  /// value it has at [from].
  ///
  /// Return whether anything moved. Returning false leaves a running transition
  /// alone; returning true restarts the clock from zero. Implementations are
  /// one line per property:
  ///
  /// ```dart
  /// @override
  /// bool retarget(double from) => _opacity.retarget(widget.opacity, from);
  /// ```
  ///
  /// With more than one property, every `retarget` call must run - `||`
  /// short-circuits and would leave the second property aimed at a stale
  /// target while the first animated away from it.
  @protected
  bool retarget(double from);

  @override
  void didUpdateWidget(T oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Read before retargeting: this is where each property currently *is*, and
    // it is what turns a mid-flight change of mind into a course correction
    // rather than a jump back to the old start.
    final double from = progress;
    if (!retarget(from)) return;
    final AnimationController? controller = _ensureController();
    // Null when this subtree has no clock or no time to spend: the properties
    // are already aimed, `progress` reads 1, and the rebuild that follows this
    // callback shows the target.
    controller?.forward(from: 0);
  }

  @override
  void dispose() {
    _disposeController();
    super.dispose();
  }

  /// The controller to drive the transition with, or null when there is none to
  /// have.
  ///
  /// Created on first use rather than in `initState`, because a widget whose
  /// value never changes should not register a ticker with the clock at all -
  /// and a screen is mostly made of those.
  AnimationController? _ensureController() {
    final Duration duration = widget.duration;
    if (duration <= Duration.zero || Theme.of(context).reducedMotion) {
      // Both mean "no transition", and both can become true after a controller
      // already exists - a theme change, a duration driven by a setting. The
      // existing one has to go, or `progress` would keep reading a stale
      // controller that nothing advances.
      _disposeController();
      return null;
    }
    final AnimationController? existing = _controller;
    if (existing != null && _controllerDuration == duration) return existing;
    _disposeController();
    final AnimationClock? clock = AnimationScope.maybeOf(context);
    if (clock == null) return null;
    _controllerDuration = duration;
    return _controller = AnimationController(
      clock: clock,
      duration: duration,
      initialValue: 1,
    )
      ..addListener(_onTick)
      ..addStatusListener(_onStatus);
  }

  void _disposeController() {
    final AnimationController? controller = _controller;
    if (controller == null) return;
    _controller = null;
    _controllerDuration = null;
    controller
      ..removeListener(_onTick)
      ..removeStatusListener(_onStatus)
      ..dispose();
  }

  /// The only place a tick reaches the tree, and it does nothing but rebuild
  /// *this* element; see the library documentation for why that is safe inside
  /// a settling frame.
  void _onTick() {
    if (mounted) setState(() {});
  }

  void _onStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed) widget.onEnd?.call();
  }
}

/// Animates [Opacity.opacity] when it changes.
///
/// Flutter's `alwaysIncludeSemantics` is deliberately absent: it exists there
/// because `Opacity` drops its subtree from the semantic tree at alpha 0, and
/// this framework's `RenderOpacity` never does - semantics are built from the
/// render tree's structure, which a paint property does not change. A parameter
/// that could only ever be given its default value would be a promise the class
/// does not keep.
final class AnimatedOpacity extends ImplicitlyAnimatedWidget {
  const AnimatedOpacity({
    super.key,
    required this.opacity,
    required super.duration,
    super.curve,
    super.onEnd,
    this.child,
  });

  /// 0 is invisible, 1 is untouched. Out-of-range values are rejected by
  /// `RenderOpacity` rather than clamped, and a curve that overshoots - an
  /// elastic or a back curve - will produce one, so those curves are not usable
  /// here. That is inherited from the render node on purpose; see its comment.
  final double opacity;

  final Widget? child;

  @override
  ImplicitlyAnimatedWidgetState<AnimatedOpacity> createState() =>
      _AnimatedOpacityState();
}

final class _AnimatedOpacityState
    extends ImplicitlyAnimatedWidgetState<AnimatedOpacity> {
  late final AnimatedProperty<double> _opacity =
      AnimatedProperty<double>(widget.opacity, lerpDouble);

  @override
  bool retarget(double from) => _opacity.retarget(widget.opacity, from);

  @override
  Widget build(BuildContext context) => Opacity(
        opacity: _opacity.at(progress),
        child: widget.child,
      );
}

/// Animates [Align.alignment] and its size factors when they change.
///
/// Flutter takes an `AlignmentGeometry` here, so a right-to-left subtree can be
/// animated in logical coordinates. This framework's [Align] takes a physical
/// [Alignment]; `AlignmentDirectional` exists but is resolved by the caller.
/// Animating a resolved alignment is correct in both locales - the resolution
/// is a negation of one axis and therefore linear - but the resolution has to
/// happen above this widget, with a `Directionality` in scope.
final class AnimatedAlign extends ImplicitlyAnimatedWidget {
  const AnimatedAlign({
    super.key,
    required this.alignment,
    required super.duration,
    super.curve,
    super.onEnd,
    this.widthFactor,
    this.heightFactor,
    this.child,
  });

  final Alignment alignment;

  /// Animated like the alignment when both ends are set. A factor that turns
  /// null - "fill the axis" - has nothing numeric on the other side of it and
  /// snaps at the midpoint; see [lerpNullableDouble].
  final double? widthFactor;
  final double? heightFactor;

  final Widget? child;

  @override
  ImplicitlyAnimatedWidgetState<AnimatedAlign> createState() =>
      _AnimatedAlignState();
}

final class _AnimatedAlignState
    extends ImplicitlyAnimatedWidgetState<AnimatedAlign> {
  late final AnimatedProperty<Alignment> _alignment =
      AnimatedProperty<Alignment>(widget.alignment, Alignment.lerp);
  late final AnimatedProperty<double?> _widthFactor =
      AnimatedProperty<double?>(widget.widthFactor, lerpNullableDouble);
  late final AnimatedProperty<double?> _heightFactor =
      AnimatedProperty<double?>(widget.heightFactor, lerpNullableDouble);

  @override
  bool retarget(double from) {
    // Three statements rather than `a || b || c`: short-circuit evaluation
    // would skip the later retargets whenever an earlier one answered true,
    // leaving those properties aimed at the previous frame's target while the
    // first one animated away from it.
    final bool alignment = _alignment.retarget(widget.alignment, from);
    final bool width = _widthFactor.retarget(widget.widthFactor, from);
    final bool height = _heightFactor.retarget(widget.heightFactor, from);
    return alignment || width || height;
  }

  @override
  Widget build(BuildContext context) {
    final double t = progress;
    return Align(
      alignment: _alignment.at(t),
      widthFactor: _widthFactor.at(t),
      heightFactor: _heightFactor.at(t),
      child: widget.child,
    );
  }
}

/// Animates [Padding.padding] when it changes.
///
/// Flutter takes an `EdgeInsetsGeometry`; this framework's [Padding] takes a
/// physical [EdgeInsets], so an `EdgeInsetsDirectional` is resolved by the
/// caller against the `Directionality` in scope before it gets here.
final class AnimatedPadding extends ImplicitlyAnimatedWidget {
  const AnimatedPadding({
    super.key,
    required this.padding,
    required super.duration,
    super.curve,
    super.onEnd,
    this.child,
  });

  final EdgeInsets padding;

  final Widget? child;

  @override
  ImplicitlyAnimatedWidgetState<AnimatedPadding> createState() =>
      _AnimatedPaddingState();
}

final class _AnimatedPaddingState
    extends ImplicitlyAnimatedWidgetState<AnimatedPadding> {
  late final AnimatedProperty<EdgeInsets> _padding =
      AnimatedProperty<EdgeInsets>(widget.padding, lerpEdgeInsets);

  @override
  bool retarget(double from) => _padding.retarget(widget.padding, from);

  @override
  Widget build(BuildContext context) => Padding(
        padding: _padding.at(progress),
        child: widget.child,
      );
}

/// Animates a [Positioned] child's edges inside a [Stack].
///
/// Only useful as a direct child of a [Stack], exactly as in Flutter: it builds
/// a [Positioned], and a `Positioned` outside a stack is a named error from the
/// parent-data machinery rather than something this class can check.
///
/// **An edge that is null on one side of the change snaps at the midpoint.**
/// Null does not mean zero; it means the edge is unconstrained and the opposite
/// edge plus the size decide the position. There is no geometry between "pinned
/// 12 px from the left" and "not pinned to the left at all", so animating from
/// one to the other would have to invent one. Flutter has the same limitation
/// for the same reason - it builds a null tween and the value jumps - and it is
/// stated here because the failure is invisible: the child simply teleports
/// mid-animation. Give both ends the same set of non-null edges.
final class AnimatedPositioned extends ImplicitlyAnimatedWidget {
  const AnimatedPositioned({
    super.key,
    required this.child,
    this.left,
    this.top,
    this.right,
    this.bottom,
    this.width,
    this.height,
    required super.duration,
    super.curve,
    super.onEnd,
  });

  /// Pins all four edges, so the child animates as the stack's box inset.
  const AnimatedPositioned.fill({
    super.key,
    required this.child,
    this.left = 0,
    this.top = 0,
    this.right = 0,
    this.bottom = 0,
    required super.duration,
    super.curve,
    super.onEnd,
  })  : width = null,
        height = null;

  final Widget child;
  final double? left;
  final double? top;
  final double? right;
  final double? bottom;
  final double? width;
  final double? height;

  @override
  ImplicitlyAnimatedWidgetState<AnimatedPositioned> createState() =>
      _AnimatedPositionedState();
}

final class _AnimatedPositionedState
    extends ImplicitlyAnimatedWidgetState<AnimatedPositioned> {
  late final AnimatedProperty<double?> _left =
      AnimatedProperty<double?>(widget.left, lerpNullableDouble);
  late final AnimatedProperty<double?> _top =
      AnimatedProperty<double?>(widget.top, lerpNullableDouble);
  late final AnimatedProperty<double?> _right =
      AnimatedProperty<double?>(widget.right, lerpNullableDouble);
  late final AnimatedProperty<double?> _bottom =
      AnimatedProperty<double?>(widget.bottom, lerpNullableDouble);
  late final AnimatedProperty<double?> _width =
      AnimatedProperty<double?>(widget.width, lerpNullableDouble);
  late final AnimatedProperty<double?> _height =
      AnimatedProperty<double?>(widget.height, lerpNullableDouble);

  @override
  bool retarget(double from) {
    // Every call runs; see the note in [_AnimatedAlignState.retarget].
    final bool left = _left.retarget(widget.left, from);
    final bool top = _top.retarget(widget.top, from);
    final bool right = _right.retarget(widget.right, from);
    final bool bottom = _bottom.retarget(widget.bottom, from);
    final bool width = _width.retarget(widget.width, from);
    final bool height = _height.retarget(widget.height, from);
    return left || top || right || bottom || width || height;
  }

  @override
  Widget build(BuildContext context) {
    final double t = progress;
    return Positioned(
      left: _left.at(t),
      top: _top.at(t),
      right: _right.at(t),
      bottom: _bottom.at(t),
      width: _width.at(t),
      height: _height.at(t),
      child: widget.child,
    );
  }
}

/// Animates the [TextStyle] published by a [DefaultTextStyle].
///
/// Flutter's version also carries `textAlign`, `softWrap`, `overflow`,
/// `maxLines`, `textWidthBasis` and `textHeightBehavior`, because its
/// `DefaultTextStyle` publishes all of them. This framework's
/// [DefaultTextStyle] publishes a style and nothing else, so those parameters
/// are absent rather than accepted and ignored - none of them is animatable
/// anyway, and a widget that takes an argument it cannot honour is worse than
/// one that does not take it.
///
/// Which fields actually move is [lerpTextStyle]'s contract: colour, size and
/// line height interpolate; family and weight snap at the midpoint.
final class AnimatedDefaultTextStyle extends ImplicitlyAnimatedWidget {
  const AnimatedDefaultTextStyle({
    super.key,
    required this.child,
    required this.style,
    required super.duration,
    super.curve,
    super.onEnd,
  });

  final Widget child;
  final TextStyle style;

  @override
  ImplicitlyAnimatedWidgetState<AnimatedDefaultTextStyle> createState() =>
      _AnimatedDefaultTextStyleState();
}

final class _AnimatedDefaultTextStyleState
    extends ImplicitlyAnimatedWidgetState<AnimatedDefaultTextStyle> {
  late final AnimatedProperty<TextStyle> _style =
      AnimatedProperty<TextStyle>(widget.style, lerpTextStyle);

  @override
  bool retarget(double from) => _style.retarget(widget.style, from);

  @override
  Widget build(BuildContext context) => DefaultTextStyle(
        style: _style.at(progress),
        child: widget.child,
      );
}
