/// Rebuilding on a [Listenable], and the transitions that animate one
/// property of a child from an [Animation]: Flutter's `ListenableBuilder`,
/// `AnimatedBuilder`, `AnimatedWidget`, `FadeTransition`, `ScaleTransition`,
/// `RotationTransition`, `SlideTransition` and `FractionalTranslation`, with
/// their names and shapes, so code moved from Flutter keeps compiling.
library;

import 'dart:math' as math;

import '../animation/animation.dart';
import '../foundation/change_notifier.dart';
import '../geometry/offset.dart';
import '../graphics/display_list.dart';
import '../layout/alignment.dart';
import '../layout/render_box.dart';
import '../layout/render_flex.dart' show Axis;
import '../layout/render_proxy_box.dart';
import 'basic.dart' show Align;
import 'element.dart';
import 'proxy.dart';
import 'widget.dart';

/// A widget that rebuilds whenever [listenable] notifies.
///
/// Subclass it and implement [build]; [ListenableBuilder] is the version
/// that takes a builder instead.
abstract class AnimatedWidget extends StatefulWidget {
  const AnimatedWidget({super.key, required this.listenable});

  /// What is listened to - an animation, a model.
  final Listenable listenable;

  /// The subtree, as it should look right now.
  Widget build(BuildContext context);

  @override
  State<AnimatedWidget> createState() => _AnimatedState();
}

class _AnimatedState extends State<AnimatedWidget> {
  @override
  void initState() {
    super.initState();
    widget.listenable.addListener(_changed);
  }

  @override
  void didUpdateWidget(AnimatedWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.listenable, widget.listenable)) {
      oldWidget.listenable.removeListener(_changed);
      widget.listenable.addListener(_changed);
    }
  }

  @override
  void dispose() {
    widget.listenable.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) => widget.build(context);
}

/// Builds [builder] again whenever [listenable] notifies; [child] is built
/// once and handed back, for the part of the subtree that does not change.
class ListenableBuilder extends AnimatedWidget {
  const ListenableBuilder({
    super.key,
    required super.listenable,
    required this.builder,
    this.child,
  });

  final Widget Function(BuildContext context, Widget? child) builder;
  final Widget? child;

  @override
  Widget build(BuildContext context) => builder(context, child);
}

/// [ListenableBuilder] under the name animation code uses for it.
class AnimatedBuilder extends ListenableBuilder {
  const AnimatedBuilder({
    super.key,
    required Listenable animation,
    required super.builder,
    super.child,
  }) : super(listenable: animation);

  /// The animation it rebuilds with.
  Listenable get animation => listenable;
}

/// Fades [child] by [opacity]'s value, 0 transparent to 1 opaque.
class FadeTransition extends AnimatedWidget {
  const FadeTransition({
    super.key,
    required Animation<double> opacity,
    this.child,
  }) : super(listenable: opacity);

  Animation<double> get opacity => listenable as Animation<double>;
  final Widget? child;

  @override
  Widget build(BuildContext context) =>
      Opacity(opacity: opacity.value.clamp(0.0, 1.0), child: child);
}

/// Scales [child] by [scale]'s value about [alignment].
class ScaleTransition extends AnimatedWidget {
  const ScaleTransition({
    super.key,
    required Animation<double> scale,
    this.alignment = Alignment.center,
    this.child,
  }) : super(listenable: scale);

  Animation<double> get scale => listenable as Animation<double>;
  final Alignment alignment;
  final Widget? child;

  @override
  Widget build(BuildContext context) =>
      Transform.scale(scale: scale.value, alignment: alignment, child: child);
}

/// Turns [child] by [turns]'s value - in whole turns, as Flutter's does: 0.5
/// is half a turn - about [alignment].
class RotationTransition extends AnimatedWidget {
  const RotationTransition({
    super.key,
    required Animation<double> turns,
    this.alignment = Alignment.center,
    this.child,
  }) : super(listenable: turns);

  Animation<double> get turns => listenable as Animation<double>;
  final Alignment alignment;
  final Widget? child;

  @override
  Widget build(BuildContext context) => Transform.rotate(
      angle: turns.value * 2 * math.pi, alignment: alignment, child: child);
}

/// Moves [child] by [position]'s value, in fractions of its own size: (1, 0)
/// is one width to the right.
class SlideTransition extends AnimatedWidget {
  const SlideTransition({
    super.key,
    required Animation<Offset> position,
    this.transformHitTests = true,
    this.child,
  }) : super(listenable: position);

  Animation<Offset> get position => listenable as Animation<Offset>;
  final bool transformHitTests;
  final Widget? child;

  @override
  Widget build(BuildContext context) => FractionalTranslation(
        translation: position.value,
        transformHitTests: transformHitTests,
        child: child,
      );
}

/// Reveals [child] along [axis] by [sizeFactor]: 0 takes no space, 1 is
/// the child's full extent - what an item appearing in a list grows by.
/// The child is laid out at full size and clipped; [axisAlignment] (-1 to 1)
/// is which part of it shows first, the start by default as in Flutter.
class SizeTransition extends AnimatedWidget {
  const SizeTransition({
    super.key,
    required Animation<double> sizeFactor,
    this.axis = Axis.vertical,
    this.axisAlignment = 0.0,
    this.child,
  }) : super(listenable: sizeFactor);

  Animation<double> get sizeFactor => listenable as Animation<double>;
  final Axis axis;
  final double axisAlignment;
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    final double factor = math.max(sizeFactor.value, 0.0);
    final bool vertical = axis == Axis.vertical;
    return ClipRect(
      child: Align(
        alignment: vertical
            ? Alignment(-1, axisAlignment)
            : Alignment(axisAlignment, -1),
        heightFactor: vertical ? factor : null,
        widthFactor: vertical ? null : factor,
        child: child,
      ),
    );
  }
}

/// Paints [child] moved by [translation] in fractions of its own size,
/// without changing its layout.
final class FractionalTranslation extends SingleChildRenderObjectWidget {
  const FractionalTranslation({
    super.key,
    required this.translation,
    this.transformHitTests = true,
    super.child,
  });

  final Offset translation;

  /// False keeps hit testing where the child was laid out.
  final bool transformHitTests;

  @override
  RenderFractionalTranslation createRenderObject(BuildContext context) =>
      RenderFractionalTranslation(
        translation: translation,
        transformHitTests: transformHitTests,
      );

  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderFractionalTranslation renderObject,
  ) {
    renderObject
      ..translation = translation
      ..transformHitTests = transformHitTests;
  }
}

/// The render object behind [FractionalTranslation].
final class RenderFractionalTranslation extends RenderProxyBox {
  RenderFractionalTranslation({
    required Offset translation,
    this.transformHitTests = true,
  }) : _translation = translation;

  Offset _translation;

  Offset get translation => _translation;

  set translation(Offset value) {
    if (value == _translation) return;
    _translation = value;
    markNeedsPaint();
  }

  bool transformHitTests;

  Offset get _shift =>
      Offset(_translation.dx * size.width, _translation.dy * size.height);

  @override
  RenderBox? hitTest(Offset position, {HitTestPath? path}) {
    final RenderBox? hit = hitTestChildren(position, path: path);
    if (hit == null) return null;
    path?.add(this);
    return hit;
  }

  @override
  RenderBox? hitTestChildren(Offset position, {HitTestPath? path}) =>
      super.hitTestChildren(transformHitTests ? position - _shift : position,
          path: path);

  @override
  void paint(DisplayList list, Offset offset) {
    final RenderBox? child = this.child;
    if (child == null) return;
    paintChild(list, child, offset + _shift);
  }
}
