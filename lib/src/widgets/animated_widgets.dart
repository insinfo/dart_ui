/// More of Flutter's animated widgets: [TweenAnimationBuilder],
/// [AnimatedContainer], [AnimatedSwitcher] and [AnimatedSize].
///
/// The first two are implicit animations on the [ImplicitlyAnimatedWidget]
/// base - the clock from [AnimationScope], nothing animated without one,
/// [ThemeData.reducedMotion] honoured by skipping - and the third keeps its
/// own controllers, one per child it is fading, on the same clock.
library;

import '../animation/animation.dart';
import '../animation/clock.dart';
import '../animation/curves.dart';
import '../geometry/offset.dart';
import '../geometry/rect.dart';
import '../geometry/size.dart';
import '../graphics/color.dart';
import '../graphics/display_list.dart';
import '../graphics/display_list_geometry.dart';
import '../layout/alignment.dart';
import '../layout/box_constraints.dart';
import '../layout/edge_insets.dart';
import '../layout/render_box.dart';
import '../layout/render_stack.dart' show StackFit;
import 'animation_scope.dart';
import 'basic.dart';
import 'element.dart';
import 'implicit_animation.dart';
import 'layout_widgets.dart';
import 'proxy.dart';
import 'theme.dart';
import 'widget.dart';

/// Builds [builder] with a value that animates along [tween] - Flutter's
/// `TweenAnimationBuilder`.
///
/// On the first build the value runs from [Tween.begin] to [Tween.end]. A
/// later tween with a different end runs **from wherever the value is** to
/// the new end, which needs to know how to interpolate the type: [lerp] when
/// given, otherwise the framework's own tweens' (double, [Offset], [Size],
/// [Rect], an ARGB colour). For any other tween the value restarts from the
/// new tween's begin, which is the one thing an immutable [Tween] can promise.
final class TweenAnimationBuilder<T> extends ImplicitlyAnimatedWidget {
  const TweenAnimationBuilder({
    super.key,
    required this.tween,
    required super.duration,
    required this.builder,
    super.curve,
    super.onEnd,
    this.lerp,
    this.child,
  });

  final Tween<T> tween;

  /// Called on every tick with the current value; [child] is passed through
  /// unchanged, for the part of the subtree that does not depend on it.
  final Widget Function(BuildContext context, T value, Widget? child) builder;

  /// How to interpolate two values of [T], for a change of target mid-way.
  final T Function(T a, T b, double t)? lerp;

  final Widget? child;

  @override
  ImplicitlyAnimatedWidgetState<TweenAnimationBuilder<T>> createState() =>
      _TweenAnimationBuilderState<T>();
}

final class _TweenAnimationBuilderState<T>
    extends ImplicitlyAnimatedWidgetState<TweenAnimationBuilder<T>> {
  late AnimatedProperty<T> _value =
      AnimatedProperty<T>(widget.tween.begin, _lerpFor(widget.tween));

  /// The type's interpolation, or null when there is none to know.
  T Function(T a, T b, double t)? get _lerp =>
      widget.lerp ?? _knownLerp(widget.tween);

  static T Function(T a, T b, double t)? _knownLerp<T>(Tween<T> tween) {
    final Object? lerp = switch (tween) {
      DoubleTween() => DoubleTween.interpolate,
      OffsetTween() => Offset.lerp,
      SizeTween() => Size.lerp,
      RectTween() => Rect.lerp,
      ColorTween() => ColorTween.interpolate,
      _ => null,
    };
    return lerp as T Function(T a, T b, double t)?;
  }

  T Function(T a, T b, double t) _lerpFor(Tween<T> tween) =>
      widget.lerp ??
      _knownLerp(tween) ??
      // Between the tween's own ends; only ever asked for those two.
      (T a, T b, double t) => tween.transform(t);

  /// Whether the first build still has to start the tween's own run.
  late bool _startPending = widget.tween.begin != widget.tween.end;

  @override
  void initState() {
    super.initState();
    _value.retarget(widget.tween.end, 0);
  }

  @override
  bool retarget(double from) {
    final T Function(T a, T b, double t)? lerp = _lerp;
    if (lerp == null && widget.tween.end != _value.end) {
      // No way to start from where the value is: restart this tween.
      _value = AnimatedProperty<T>(widget.tween.begin, _lerpFor(widget.tween))
        ..retarget(widget.tween.end, 0);
      return true;
    }
    return _value.retarget(widget.tween.end, from);
  }

  @override
  Widget build(BuildContext context) {
    if (_startPending) {
      // The first build animates the tween itself, begin to end.
      _startPending = false;
      animateFromStart();
    }
    return widget.builder(context, _value.at(progress), widget.child);
  }
}

/// A [Container] whose size, spacing, colour, decoration and alignment
/// animate when they change - Flutter's `AnimatedContainer`.
///
/// [width] and [height] animate when both ends are numbers and snap when one
/// is null (unconstrained has no number to walk from). A decoration animates
/// its colour, its corner radius and its border's colour and width; a border
/// that appears or disappears grows from, or shrinks to, nothing.
/// [constraints] and [transform] are set, not animated.
final class AnimatedContainer extends ImplicitlyAnimatedWidget {
  const AnimatedContainer({
    super.key,
    required super.duration,
    super.curve,
    super.onEnd,
    this.alignment,
    this.padding,
    this.color,
    this.decoration,
    this.width,
    this.height,
    this.constraints,
    this.margin,
    this.child,
  }) : assert(color == null || decoration == null,
            'give the colour in the decoration, not both');

  final Alignment? alignment;
  final EdgeInsets? padding;
  final Color? color;
  final BoxDecoration? decoration;
  final double? width;
  final double? height;
  final BoxConstraints? constraints;
  final EdgeInsets? margin;
  final Widget? child;

  @override
  ImplicitlyAnimatedWidgetState<AnimatedContainer> createState() =>
      _AnimatedContainerState();
}

final class _AnimatedContainerState
    extends ImplicitlyAnimatedWidgetState<AnimatedContainer> {
  late final AnimatedProperty<Alignment?> _alignment =
      AnimatedProperty<Alignment?>(widget.alignment, _lerpAlignment);
  late final AnimatedProperty<EdgeInsets?> _padding =
      AnimatedProperty<EdgeInsets?>(widget.padding, _lerpInsets);
  late final AnimatedProperty<EdgeInsets?> _margin =
      AnimatedProperty<EdgeInsets?>(widget.margin, _lerpInsets);
  late final AnimatedProperty<Color?> _color =
      AnimatedProperty<Color?>(widget.color, _lerpColor);
  late final AnimatedProperty<BoxDecoration?> _decoration =
      AnimatedProperty<BoxDecoration?>(widget.decoration, _lerpDecoration);
  late final AnimatedProperty<double?> _width =
      AnimatedProperty<double?>(widget.width, lerpNullableDouble);
  late final AnimatedProperty<double?> _height =
      AnimatedProperty<double?>(widget.height, lerpNullableDouble);

  static Alignment? _lerpAlignment(Alignment? a, Alignment? b, double t) =>
      a == null || b == null ? (t < 0.5 ? a : b) : Alignment.lerp(a, b, t);

  static EdgeInsets? _lerpInsets(EdgeInsets? a, EdgeInsets? b, double t) =>
      a == null && b == null
          ? null
          : lerpEdgeInsets(a ?? EdgeInsets.zero, b ?? EdgeInsets.zero, t);

  static Color? _lerpColor(Color? a, Color? b, double t) =>
      a == null && b == null
          ? null
          : lerpColor(
              a ?? const Color(0x00000000), b ?? const Color(0x00000000), t);

  static BoxDecoration? _lerpDecoration(
      BoxDecoration? a, BoxDecoration? b, double t) {
    if (a == null && b == null) return null;
    const BoxDecoration none = BoxDecoration();
    final BoxDecoration from = a ?? none;
    final BoxDecoration to = b ?? none;
    final BoxBorder? border = from.border == null && to.border == null
        ? null
        : BoxBorder(
            color: _lerpColor(from.border?.color ?? to.border!.color,
                to.border?.color ?? from.border!.color, t)!,
            width:
                lerpDouble(from.border?.width ?? 0, to.border?.width ?? 0, t),
          );
    return BoxDecoration(
      color: _lerpColor(from.color, to.color, t),
      border: border,
      radius: lerpDouble(from.radius, to.radius, t),
    );
  }

  @override
  bool retarget(double from) {
    // Every property, no short circuit: see AnimatedAlign.
    final List<bool> moved = <bool>[
      _alignment.retarget(widget.alignment, from),
      _padding.retarget(widget.padding, from),
      _margin.retarget(widget.margin, from),
      _color.retarget(widget.color, from),
      _decoration.retarget(widget.decoration, from),
      _width.retarget(widget.width, from),
      _height.retarget(widget.height, from),
    ];
    return moved.contains(true);
  }

  @override
  Widget build(BuildContext context) {
    final double t = progress;
    return Container(
      alignment: _alignment.at(t),
      padding: _padding.at(t),
      color: _color.at(t),
      decoration: _decoration.at(t),
      width: _width.at(t),
      height: _height.at(t),
      constraints: widget.constraints,
      margin: _margin.at(t),
      child: widget.child,
    );
  }
}

/// Fades from one child to the next when the child changes - Flutter's
/// `AnimatedSwitcher`.
///
/// "Changes" is [Widget.canUpdate]'s answer: a different type or key. A
/// counter that should cross-fade on every value gives its [Text] a
/// `ValueKey` of the value. The outgoing child fades out while the new one
/// fades in, both stacked; a child that changes again mid-fade joins the
/// queue of outgoing ones from where its fade has got to.
///
/// With no [AnimationScope] above it, or under reduced motion, it switches
/// at once.
final class AnimatedSwitcher extends StatefulWidget {
  const AnimatedSwitcher({
    super.key,
    required this.duration,
    this.reverseDuration,
    this.switchInCurve = Curves.linear,
    this.switchOutCurve = Curves.linear,
    this.child,
  });

  final Duration duration;

  /// How long the outgoing child takes to fade; [duration] when null.
  final Duration? reverseDuration;

  final Curve switchInCurve;
  final Curve switchOutCurve;

  final Widget? child;

  @override
  State<AnimatedSwitcher> createState() => _AnimatedSwitcherState();
}

/// One child the switcher shows, with its own fade.
final class _SwitcherEntry {
  _SwitcherEntry(this.child, this.controller, this.serial);

  Widget child;
  final AnimationController? controller;

  /// Keys the entry's subtree, so a child that leaves keeps its state while
  /// it fades.
  final int serial;
}

final class _AnimatedSwitcherState extends State<AnimatedSwitcher> {
  _SwitcherEntry? _current;
  final List<_SwitcherEntry> _outgoing = <_SwitcherEntry>[];
  int _serial = 0;

  @override
  void initState() {
    super.initState();
    final Widget? child = widget.child;
    // The first child is simply there: nothing was switched.
    if (child != null) _current = _SwitcherEntry(child, null, _serial++);
  }

  @override
  void didUpdateWidget(AnimatedSwitcher oldWidget) {
    super.didUpdateWidget(oldWidget);
    final Widget? next = widget.child;
    final _SwitcherEntry? current = _current;
    if (current != null &&
        next != null &&
        Widget.canUpdate(current.child, next)) {
      current.child = next;
      return;
    }
    if (current == null && next == null) return;
    if (current != null) _retire(current);
    _current = next == null ? null : _enter(next);
  }

  AnimationClock? get _clock =>
      Theme.of(context).reducedMotion ? null : AnimationScope.maybeOf(context);

  _SwitcherEntry _enter(Widget child) {
    final AnimationClock? clock = _clock;
    if (clock == null || widget.duration <= Duration.zero) {
      return _SwitcherEntry(child, null, _serial++);
    }
    final AnimationController controller = AnimationController(
      clock: clock,
      duration: widget.duration,
    )..addListener(_tick);
    controller.forward(from: 0);
    return _SwitcherEntry(child, controller, _serial++);
  }

  void _retire(_SwitcherEntry entry) {
    final AnimationClock? clock = _clock;
    final Duration duration = widget.reverseDuration ?? widget.duration;
    AnimationController? controller = entry.controller;
    if (clock == null || duration <= Duration.zero) {
      controller?.dispose();
      return;
    }
    // A child that came in without a fade - the first one - fades out on a
    // controller of its own, from fully shown.
    controller ??= AnimationController(
      clock: clock,
      duration: duration,
      initialValue: 1,
    )..addListener(_tick);
    final _SwitcherEntry leaving =
        _SwitcherEntry(entry.child, controller, entry.serial);
    _outgoing.add(leaving);
    controller.addStatusListener((AnimationStatus status) {
      if (status != AnimationStatus.dismissed) return;
      if (!_outgoing.remove(leaving)) return;
      controller!
        ..removeListener(_tick)
        ..dispose();
      if (mounted) setState(() {});
    });
    controller.reverse();
  }

  void _tick() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    for (final _SwitcherEntry entry in <_SwitcherEntry>[
      ..._outgoing,
      if (_current != null) _current!,
    ]) {
      entry.controller
        ?..removeListener(_tick)
        ..dispose();
    }
    _outgoing.clear();
    super.dispose();
  }

  Widget _faded(_SwitcherEntry entry, Curve curve) {
    final AnimationController? controller = entry.controller;
    final double opacity =
        controller == null ? 1 : curve.transform(controller.value);
    return Opacity(
      key: ValueKey<int>(entry.serial),
      opacity: opacity.clamp(0.0, 1.0),
      child: entry.child,
    );
  }

  @override
  Widget build(BuildContext context) {
    final _SwitcherEntry? current = _current;
    if (_outgoing.isEmpty) {
      return current == null
          ? const SizedBox()
          : _faded(current, widget.switchInCurve);
    }
    return Stack(
      fit: StackFit.passthrough,
      alignment: Alignment.center,
      children: <Widget>[
        for (final _SwitcherEntry entry in _outgoing)
          _faded(entry, widget.switchOutCurve),
        if (current != null) _faded(current, widget.switchInCurve),
      ],
    );
  }
}

/// Grows and shrinks to its child's size over [duration] when the child's
/// size changes - Flutter's `AnimatedSize`.
///
/// The child is laid out at its own size at once, and this box walks from
/// its old size to the new one, aligning the child by [alignment] and
/// clipping it while the box is smaller. With no [AnimationScope] above it,
/// or under reduced motion, it takes the new size at once.
final class AnimatedSize extends SingleChildRenderObjectWidget {
  const AnimatedSize({
    super.key,
    required this.duration,
    this.curve = Curves.linear,
    this.alignment = Alignment.center,
    super.child,
  });

  final Duration duration;
  final Curve curve;
  final Alignment alignment;

  @override
  RenderAnimatedSize createRenderObject(BuildContext context) =>
      RenderAnimatedSize(
        clock: Theme.of(context).reducedMotion
            ? null
            : AnimationScope.maybeOf(context),
        duration: duration,
        curve: curve,
        alignment: alignment,
      );

  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderAnimatedSize renderObject,
  ) {
    renderObject
      ..clock = Theme.of(context).reducedMotion
          ? null
          : AnimationScope.maybeOf(context)
      ..duration = duration
      ..curve = curve
      ..alignment = alignment;
  }
}

/// The render object behind [AnimatedSize]. It owns its controller: the
/// size it animates to is only known in layout, and the animation is of
/// layout, so nothing above it needs to rebuild per frame.
final class RenderAnimatedSize extends RenderSingleChildBox {
  RenderAnimatedSize({
    AnimationClock? clock,
    required Duration duration,
    Curve curve = Curves.linear,
    Alignment alignment = Alignment.center,
    super.child,
  })  : _clock = clock,
        _duration = duration,
        _curve = curve,
        _alignment = alignment;

  AnimationClock? _clock;
  Duration _duration;
  Curve _curve;
  Alignment _alignment;
  AnimationController? _controller;

  /// The size the last transition started from and the one it is going to.
  Size? _from;
  Size? _to;

  set clock(AnimationClock? value) {
    if (identical(value, _clock)) return;
    _clock = value;
    _disposeController();
    markNeedsLayout();
  }

  set duration(Duration value) {
    if (value == _duration) return;
    _duration = value;
    _disposeController();
  }

  set curve(Curve value) {
    if (identical(value, _curve)) return;
    _curve = value;
    markNeedsLayout();
  }

  Alignment get alignment => _alignment;

  set alignment(Alignment value) {
    if (value == _alignment) return;
    _alignment = value;
    markNeedsLayout();
  }

  /// Whether a transition is running.
  bool get isAnimating =>
      (_controller?.isAnimating ?? false) && _from != null && _to != null;

  AnimationController? _ensureController() {
    final AnimationClock? clock = _clock;
    if (clock == null || _duration <= Duration.zero) return null;
    return _controller ??= AnimationController(
      clock: clock,
      duration: _duration,
      initialValue: 1,
    )..addListener(markNeedsLayout);
  }

  void _disposeController() {
    _controller
      ?..removeListener(markNeedsLayout)
      ..dispose();
    _controller = null;
  }

  @override
  void detach() {
    _disposeController();
    super.detach();
  }

  @override
  void performLayout() {
    final RenderBox? child = this.child;
    if (child == null) {
      size = constraints.smallest;
      _from = _to = null;
      return;
    }
    child.layout(constraints.loosen(), parentUsesSize: true);
    final Size target = constraints.constrain(child.size);
    final Size? current = _to == null ? null : _currentSize();
    if (_to != target) {
      final AnimationController? controller = _ensureController();
      if (current == null || controller == null) {
        // First layout, or no clock: the size is simply the child's.
        _from = _to = target;
      } else {
        _from = current;
        _to = target;
        controller.forward(from: 0);
      }
    }
    size = constraints.constrain(_currentSize());
    child.parentData!.offset = _alignment.offsetFor(child.size, size);
  }

  Size _currentSize() {
    final Size from = _from ?? Size.zero;
    final Size to = _to ?? Size.zero;
    final AnimationController? controller = _controller;
    final double t =
        controller == null ? 1 : _curve.transform(controller.value);
    return Size.lerp(from, to, t);
  }

  @override
  void paint(DisplayList list, Offset offset) {
    final RenderBox? child = this.child;
    if (child == null) return;
    final bool clips = child.size.width > size.width + 0.5 ||
        child.size.height > size.height + 0.5;
    if (!clips) {
      super.paint(list, offset);
      return;
    }
    list
      ..save()
      ..clipRectangle(
          Rect.fromLTWH(offset.dx, offset.dy, size.width, size.height));
    super.paint(list, offset);
    list.restore();
  }
}
