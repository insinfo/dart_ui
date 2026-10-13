// Portions adapted from Flutter's `widgets/dismissible.dart`:
// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file of the Flutter repository.

/// Flutter's `Dismissible`: swipe an item away.
///
/// The child slides with the drag, [Dismissible.background] showing in the
/// space it uncovers. Released past the threshold (or flung), it slides out,
/// [Dismissible.confirmDismiss] may still say no, and then the space it took
/// shrinks to nothing over [Dismissible.resizeDuration] before
/// [Dismissible.onDismissed] is called - at which point the parent must take
/// it out of the tree, as in Flutter.
///
/// ## Differences from Flutter
///
/// * The animations run on the [AnimationScope]'s clock. Without one
///   (a tree with no app or navigator above it) every animation jumps to its
///   end: the item still dismisses, at once.
/// * A fling finishes at the normal [Dismissible.movementDuration] speed
///   scaled by the fling's velocity, rather than by a spring simulation.
/// * Still in the tree after [Dismissible.onDismissed], it draws nothing and
///   takes no space; Flutter asserts.
/// * `dragStartBehavior` is accepted and has no effect: drags start where
///   the slop is crossed.
library;

import 'dart:async';

import '../animation/animation.dart';
import '../animation/clock.dart';
import '../animation/curves.dart';
import '../geometry/offset.dart';
import '../geometry/rect.dart';
import '../geometry/size.dart';
import '../gestures/drag.dart';
import '../graphics/display_list.dart';
import '../graphics/display_list_geometry.dart';
import '../layout/render_box.dart';
import '../layout/render_proxy_box.dart';
import '../text/shaper.dart' show TextDirection;
import 'animation_scope.dart';
import 'basic.dart';
import 'directionality.dart';
import 'element.dart';
import 'gesture_detector.dart';
import 'listenable_builders.dart';
import 'proxy.dart';
import 'sizing.dart';
import 'theme.dart';
import 'widget.dart';

const Curve _kResizeTimeCurve = Interval(0.4, 1.0, curve: Curves.ease);
const double _kMinFlingVelocity = 700.0;
const double _kMinFlingVelocityDelta = 400.0;
const double _kFlingVelocityScale = 1.0 / 300.0;
const double _kDismissThreshold = 0.4;

/// Called with the direction an item was dismissed in.
typedef DismissDirectionCallback = void Function(DismissDirection direction);

/// Asked whether to go through with a dismissal - Flutter's
/// `ConfirmDismissCallback`. Null or false puts the item back.
typedef ConfirmDismissCallback = Future<bool?> Function(
    DismissDirection direction);

/// Called as a dismiss drag moves.
typedef DismissUpdateCallback = void Function(DismissUpdateDetails details);

/// The directions a [Dismissible] can be dismissed in.
enum DismissDirection {
  /// Up or down.
  vertical,

  /// Towards the start or the end of the reading direction.
  horizontal,

  /// Towards the start of the reading direction: right to left in English.
  endToStart,

  /// Towards the end of the reading direction: left to right in English.
  startToEnd,

  up,
  down,

  /// Not dismissible.
  none,
}

/// Where a dismiss drag is - Flutter's `DismissUpdateDetails`.
class DismissUpdateDetails {
  DismissUpdateDetails({
    this.direction = DismissDirection.horizontal,
    this.reached = false,
    this.previousReached = false,
    this.progress = 0.0,
  });

  final DismissDirection direction;

  /// Whether the drag is past the threshold now.
  final bool reached;

  /// Whether it was at the previous update.
  final bool previousReached;

  /// How far the item has moved, 0 to 1 of its extent.
  final double progress;
}

/// An item the user can swipe away - Flutter's `Dismissible`. See the
/// library comment.
class Dismissible extends StatefulWidget {
  const Dismissible({
    required Key super.key,
    required this.child,
    this.background,
    this.secondaryBackground,
    this.confirmDismiss,
    this.onResize,
    this.onUpdate,
    this.onDismissed,
    this.direction = DismissDirection.horizontal,
    this.resizeDuration = const Duration(milliseconds: 300),
    this.dismissThresholds = const <DismissDirection, double>{},
    this.movementDuration = const Duration(milliseconds: 200),
    this.crossAxisEndOffset = 0.0,
    this.dragStartBehavior,
    this.behavior = HitTestBehavior.opaque,
  }) : assert(secondaryBackground == null || background != null);

  final Widget child;

  /// Shown behind the child as it moves; behind a move towards the end (or
  /// down) when [secondaryBackground] is given too.
  final Widget? background;

  /// Shown behind a move towards the start (or up).
  final Widget? secondaryBackground;

  final ConfirmDismissCallback? confirmDismiss;

  /// Called each frame the space shrinks.
  final void Function()? onResize;

  /// Called after the item has gone; take it out of the tree here.
  final DismissDirectionCallback? onDismissed;

  final DismissDirection direction;

  /// How long the space takes to close; null calls [onDismissed] as soon as
  /// the item has slid out, leaving the space.
  final Duration? resizeDuration;

  /// The fraction of the extent past which a release dismisses, per
  /// direction; 0.4 when not given. 1.0 or more never dismisses.
  final Map<DismissDirection, double> dismissThresholds;

  /// How long the slide out (or back) takes.
  final Duration movementDuration;

  /// How far, in fractions of the cross extent, the item drifts sideways
  /// as it slides out.
  final double crossAxisEndOffset;

  final DismissUpdateCallback? onUpdate;

  /// Accepted for Flutter's signature; see the library comment.
  final Object? dragStartBehavior;

  final HitTestBehavior behavior;

  @override
  State<Dismissible> createState() => _DismissibleState();
}

enum _FlingGestureKind { none, forward, reverse }

class _DismissibleState extends State<Dismissible> {
  AnimationClock? _clock;
  AnimationController? _moveController;
  AnimationController? _resizeController;
  double _dragExtent = 0.0;
  bool _dragUnderway = false;
  bool _confirming = false;
  bool _dismissThresholdReached = false;
  bool _dismissed = false;
  Size? _sizePriorToCollapse;
  Size _size = Size.zero;

  AnimationController get _move => _moveController!;

  bool get _directionIsXAxis =>
      widget.direction == DismissDirection.horizontal ||
      widget.direction == DismissDirection.endToStart ||
      widget.direction == DismissDirection.startToEnd;

  bool get _isActive => _dragUnderway || _move.isAnimating;

  double get _overallDragAxisExtent =>
      _directionIsXAxis ? _size.width : _size.height;

  TextDirection get _textDirection =>
      Directionality.maybeOf(context) ?? TextDirection.leftToRight;

  /// Whether there is a running clock, and motion is not reduced.
  bool get _animates =>
      _clock?.scheduler != null && !Theme.of(context).reducedMotion;

  void _ensureControllers() {
    final AnimationClock clock =
        AnimationScope.maybeOf(context) ?? (_clock ?? AnimationClock());
    if (_moveController != null && identical(clock, _clock)) return;
    final double value = _moveController?.value ?? 0.0;
    _moveController?.dispose();
    _clock = clock;
    _moveController = AnimationController(
      clock: clock,
      duration: widget.movementDuration,
      initialValue: value,
    )
      ..addStatusListener(_handleDismissStatusChanged)
      ..addListener(_handleDismissUpdateValueChanged);
  }

  @override
  void dispose() {
    _moveController?.dispose();
    _resizeController?.dispose();
    super.dispose();
  }

  DismissDirection _extentToDirection(double extent) {
    if (extent == 0.0) return DismissDirection.none;
    if (_directionIsXAxis) {
      return switch (_textDirection) {
        TextDirection.rightToLeft => extent < 0
            ? DismissDirection.startToEnd
            : DismissDirection.endToStart,
        TextDirection.leftToRight => extent > 0
            ? DismissDirection.startToEnd
            : DismissDirection.endToStart,
      };
    }
    return extent > 0 ? DismissDirection.down : DismissDirection.up;
  }

  DismissDirection get _dismissDirection => _extentToDirection(_dragExtent);

  double get _dismissThreshold =>
      widget.dismissThresholds[_dismissDirection] ?? _kDismissThreshold;

  void _handleDragStart(DragStartDetails details) {
    if (_confirming) return;
    _dragUnderway = true;
    if (_move.isAnimating) {
      _dragExtent = _move.value * _overallDragAxisExtent * _dragExtent.sign;
      _move.stop();
    } else {
      _dragExtent = 0.0;
      _move.value = 0.0;
    }
    setState(() {});
  }

  void _handleDragUpdate(DragUpdateDetails details) {
    if (!_isActive || _move.isAnimating) return;
    final double delta = details.primaryDelta ??
        (_directionIsXAxis ? details.delta.dx : details.delta.dy);
    final double oldDragExtent = _dragExtent;
    final bool rtl = _textDirection == TextDirection.rightToLeft;
    switch (widget.direction) {
      case DismissDirection.horizontal:
      case DismissDirection.vertical:
        _dragExtent += delta;
      case DismissDirection.up:
        if (_dragExtent + delta < 0) _dragExtent += delta;
      case DismissDirection.down:
        if (_dragExtent + delta > 0) _dragExtent += delta;
      case DismissDirection.endToStart:
        if (rtl ? _dragExtent + delta > 0 : _dragExtent + delta < 0) {
          _dragExtent += delta;
        }
      case DismissDirection.startToEnd:
        if (rtl ? _dragExtent + delta < 0 : _dragExtent + delta > 0) {
          _dragExtent += delta;
        }
      case DismissDirection.none:
        _dragExtent = 0;
    }
    if (oldDragExtent.sign != _dragExtent.sign) setState(() {});
    if (!_move.isAnimating && _overallDragAxisExtent > 0) {
      _move.value =
          (_dragExtent.abs() / _overallDragAxisExtent).clamp(0.0, 1.0);
    }
  }

  void _handleDismissUpdateValueChanged() {
    final DismissUpdateCallback? onUpdate = widget.onUpdate;
    if (onUpdate == null) return;
    final bool old = _dismissThresholdReached;
    _dismissThresholdReached = _move.value > _dismissThreshold;
    onUpdate(DismissUpdateDetails(
      direction: _dismissDirection,
      reached: _dismissThresholdReached,
      previousReached: old,
      progress: _move.value,
    ));
  }

  _FlingGestureKind _describeFlingGesture(Offset velocity) {
    if (_dragExtent == 0.0) return _FlingGestureKind.none;
    final double vx = velocity.dx;
    final double vy = velocity.dy;
    final DismissDirection flingDirection;
    if (_directionIsXAxis) {
      if (vx.abs() - vy.abs() < _kMinFlingVelocityDelta ||
          vx.abs() < _kMinFlingVelocity) {
        return _FlingGestureKind.none;
      }
      flingDirection = _extentToDirection(vx);
    } else {
      if (vy.abs() - vx.abs() < _kMinFlingVelocityDelta ||
          vy.abs() < _kMinFlingVelocity) {
        return _FlingGestureKind.none;
      }
      flingDirection = _extentToDirection(vy);
    }
    return flingDirection == _dismissDirection
        ? _FlingGestureKind.forward
        : _FlingGestureKind.reverse;
  }

  void _handleDragEnd(DragEndDetails details) {
    if (!_isActive || _move.isAnimating) return;
    _dragUnderway = false;
    if (_move.status == AnimationStatus.completed) {
      _handleMoveCompleted();
      return;
    }
    final Offset velocity = details.velocity.pixelsPerSecond;
    final double flingVelocity = _directionIsXAxis ? velocity.dx : velocity.dy;
    switch (_describeFlingGesture(velocity)) {
      case _FlingGestureKind.forward:
        if (_dismissThreshold >= 1.0) {
          _runMove(forward: false);
          break;
        }
        _dragExtent = flingVelocity.sign;
        _runMove(
            forward: true, speed: flingVelocity.abs() * _kFlingVelocityScale);
      case _FlingGestureKind.reverse:
        _dragExtent = flingVelocity.sign;
        _runMove(
            forward: false, speed: flingVelocity.abs() * _kFlingVelocityScale);
      case _FlingGestureKind.none:
        // By value, not status: a value set by the drag leaves this
        // framework's controller in the status it rested in.
        if (_move.value > 0.0) {
          _runMove(forward: _move.value > _dismissThreshold);
        }
    }
    setState(() {});
  }

  void _handleDragCancel() {
    if (!_dragUnderway) return;
    _dragUnderway = false;
    _runMove(forward: false);
  }

  /// Slides out ([forward]) or back. [speed] above 1 is a fling.
  void _runMove({required bool forward, double speed = 1.0}) {
    if (!_animates) {
      _move.value = forward ? 1.0 : 0.0;
      return;
    }
    _move.speed = speed < 1.0 ? 1.0 : speed;
    if (forward) {
      _move.forward();
    } else {
      _move.reverse();
    }
  }

  void _handleDismissStatusChanged(AnimationStatus status) {
    if (status == AnimationStatus.completed && !_dragUnderway) {
      _handleMoveCompleted();
    }
  }

  void _handleMoveCompleted() {
    if (_dismissThreshold >= 1.0) {
      _runMove(forward: false);
      return;
    }
    final ConfirmDismissCallback? confirm = widget.confirmDismiss;
    if (confirm == null) {
      _startResizeAnimation();
      return;
    }
    _confirming = true;
    final DismissDirection direction = _dismissDirection;
    unawaited(confirm(direction).then((bool? result) {
      _confirming = false;
      if (!mounted) return;
      if (result ?? false) {
        _startResizeAnimation();
      } else {
        _runMove(forward: false);
      }
    }, onError: (Object error, StackTrace stack) {
      _confirming = false;
      if (mounted) _runMove(forward: false);
      Zone.current.handleUncaughtError(error, stack);
    }));
  }

  void _startResizeAnimation() {
    if (!mounted || _dismissed || _resizeController != null) return;
    final DismissDirection direction = _dismissDirection;
    final Duration? duration = widget.resizeDuration;
    if (duration == null) {
      _dismissed = true;
      widget.onDismissed?.call(direction);
      return;
    }
    final AnimationController resize = AnimationController(
      clock: _clock!,
      duration: duration,
    );
    _resizeController = resize;
    _sizePriorToCollapse = _size;
    resize
      ..addListener(() {
        if (resize.status != AnimationStatus.completed) widget.onResize?.call();
      })
      ..addStatusListener((AnimationStatus status) {
        if (status == AnimationStatus.completed && !_dismissed) {
          _dismissed = true;
          widget.onDismissed?.call(direction);
        }
      });
    setState(() {});
    if (_animates) {
      resize.forward();
    } else {
      resize.value = 1.0;
    }
  }

  Offset get _slideEnd {
    final double end = _dragExtent.sign;
    return _directionIsXAxis
        ? Offset(end, widget.crossAxisEndOffset)
        : Offset(widget.crossAxisEndOffset, end);
  }

  Widget? get _background {
    if (_dismissDirection == DismissDirection.endToStart ||
        _dismissDirection == DismissDirection.up) {
      return widget.secondaryBackground ?? widget.background;
    }
    return widget.background;
  }

  @override
  Widget build(BuildContext context) {
    _ensureControllers();
    if (_dismissed) return const SizedBox(width: 0, height: 0);

    final AnimationController? resize = _resizeController;
    if (resize != null) {
      final Size before = _sizePriorToCollapse ?? _size;
      return ListenableBuilder(
        listenable: resize,
        builder: (BuildContext context, Widget? child) {
          final double factor = 1.0 - _kResizeTimeCurve.transform(resize.value);
          return ClipRect(
            child: SizedBox(
              width: _directionIsXAxis ? before.width : before.width * factor,
              height:
                  _directionIsXAxis ? before.height * factor : before.height,
              child: OverflowBox(
                minWidth: before.width,
                maxWidth: before.width,
                minHeight: before.height,
                maxHeight: before.height,
                child: child,
              ),
            ),
          );
        },
        child: _background,
      );
    }

    final Widget content = ListenableBuilder(
      listenable: _move,
      builder: (BuildContext context, Widget? child) {
        final double t = _move.value;
        final Widget? background = _background;
        final Widget slid = FractionalTranslation(
          translation: Offset(_slideEnd.dx * t, _slideEnd.dy * t),
          child: child,
        );
        if (background == null || t == 0.0) return slid;
        return Stack(
          children: <Widget>[
            Positioned.fill(
              child: _RevealClip(
                horizontal: _directionIsXAxis,
                fromStart: _dragExtent >= 0,
                fraction: t,
                child: background,
              ),
            ),
            slid,
          ],
        );
      },
      child: widget.child,
    );

    final Widget measured = _Measure(
      onSize: (Size size) => _size = size,
      child: content,
    );
    if (widget.direction == DismissDirection.none) return measured;
    final bool x = _directionIsXAxis;
    return GestureDetector(
      behavior: widget.behavior,
      onHorizontalDragStart: x ? _handleDragStart : null,
      onHorizontalDragUpdate: x ? _handleDragUpdate : null,
      onHorizontalDragEnd: x ? _handleDragEnd : null,
      onHorizontalDragCancel: x ? _handleDragCancel : null,
      onVerticalDragStart: x ? null : _handleDragStart,
      onVerticalDragUpdate: x ? null : _handleDragUpdate,
      onVerticalDragEnd: x ? null : _handleDragEnd,
      onVerticalDragCancel: x ? null : _handleDragCancel,
      child: measured,
    );
  }
}

/// Reports its size after layout, without a rebuild.
final class _Measure extends SingleChildRenderObjectWidget {
  const _Measure({required this.onSize, super.child});

  final void Function(Size size) onSize;

  @override
  RenderBox createRenderObject(BuildContext context) => _RenderMeasure(onSize);

  @override
  void updateRenderObject(
    BuildContext context,
    covariant _RenderMeasure renderObject,
  ) =>
      renderObject.onSize = onSize;
}

final class _RenderMeasure extends RenderProxyBox {
  _RenderMeasure(this.onSize);

  void Function(Size size) onSize;

  @override
  void performLayout() {
    super.performLayout();
    onSize(size);
  }
}

/// Paints its child clipped to the part a sliding item has uncovered:
/// [fraction] of the box, from the start edge or the end edge.
final class _RevealClip extends SingleChildRenderObjectWidget {
  const _RevealClip({
    required this.horizontal,
    required this.fromStart,
    required this.fraction,
    super.child,
  });

  final bool horizontal;
  final bool fromStart;
  final double fraction;

  @override
  RenderBox createRenderObject(BuildContext context) =>
      _RenderRevealClip(horizontal, fromStart, fraction);

  @override
  void updateRenderObject(
    BuildContext context,
    covariant _RenderRevealClip renderObject,
  ) {
    renderObject
      ..horizontal = horizontal
      ..fromStart = fromStart
      ..fraction = fraction
      ..markNeedsPaint();
  }
}

final class _RenderRevealClip extends RenderProxyBox {
  _RenderRevealClip(this.horizontal, this.fromStart, this.fraction);

  bool horizontal;
  bool fromStart;
  double fraction;

  @override
  void paint(DisplayList list, Offset offset) {
    final RenderBox? child = this.child;
    if (child == null) return;
    final Size s = size;
    final double f = fraction.clamp(0.0, 1.0);
    if (f == 0.0 || s.isEmpty) return;
    final Rect clip;
    if (horizontal) {
      final double w = s.width * f;
      clip = fromStart
          ? Rect.fromLTWH(offset.dx, offset.dy, w, s.height)
          : Rect.fromLTWH(offset.dx + s.width - w, offset.dy, w, s.height);
    } else {
      final double h = s.height * f;
      clip = fromStart
          ? Rect.fromLTWH(offset.dx, offset.dy, s.width, h)
          : Rect.fromLTWH(offset.dx, offset.dy + s.height - h, s.width, h);
    }
    list
      ..save()
      ..clipRectangle(clip);
    paintChild(list, child, offset);
    list.restore();
  }
}
