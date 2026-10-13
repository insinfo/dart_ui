// Portions adapted from Flutter's `widgets/drag_target.dart`:
// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file of the Flutter repository.

/// Flutter's in-app drag and drop: [Draggable], [LongPressDraggable] and
/// [DragTarget].
///
/// A drag inside the window, between widgets, carrying a Dart object. The
/// feedback widget is drawn in the nearest [Overlay] under the pointer, and
/// the targets are found by hit testing the window at the pointer each time
/// it moves - the same model as Flutter's.
///
/// This is not the platform's drag and drop. Dragging files out of the
/// window, or into it from another application, is [DragSource] and
/// [DropTarget] in `drag_drop.dart`, which speak to the operating system;
/// these two families do not see each other's drags.
///
/// ## Differences from Flutter
///
/// * The drag is recognized by this framework's gesture recognizers: a pan
///   (or a horizontal/vertical drag with [Draggable.affinity]) after the
///   pointer moves past the slop, a long press for [LongPressDraggable] -
///   which, as every long press here, needs a `GestureScope` (or a
///   dispatcher) above it. Only the primary button drags.
/// * `HitTestBehavior.translucent`, [DragTarget]'s default, is hit like
///   `opaque`: a target does not let a widget *behind* it (a sibling under
///   it in a `Stack`) be hit too. Its ancestors still are, so nested targets
///   work as in Flutter.
/// * `ignoringFeedbackSemantics`, `dragStartBehavior` and
///   `hapticFeedbackOnStart` are accepted and have no effect.
library;

import '../geometry/offset.dart';
import '../gestures/drag.dart';
import '../gestures/long_press.dart';
import '../gestures/velocity_tracker.dart';
import '../layout/render_box.dart';
import '../layout/render_flex.dart' show Axis;
import '../layout/render_proxy_box.dart';
import '../platform/input_events.dart';
import 'basic.dart';
import 'element.dart';
import 'gesture_detector.dart';
import 'listener.dart';
import 'overlay.dart';
import 'proxy.dart';
import 'widget.dart';

typedef DragTargetWillAccept<T> = bool Function(T? data);
typedef DragTargetWillAcceptWithDetails<T> = bool Function(
    DragTargetDetails<T> details);
typedef DragTargetAccept<T> = void Function(T data);
typedef DragTargetAcceptWithDetails<T> = void Function(
    DragTargetDetails<T> details);
typedef DragTargetBuilder<T> = Widget Function(
  BuildContext context,
  List<T?> candidateData,
  List<dynamic> rejectedData,
);
typedef DragUpdateCallback = void Function(DragUpdateDetails details);
typedef DraggableCanceledCallback = void Function(
    Velocity velocity, Offset offset);
typedef DragEndCallback = void Function(DraggableDetails details);
typedef DragTargetLeave<T> = void Function(T? data);
typedef DragTargetMove<T> = void Function(DragTargetDetails<T> details);

/// Which buttons may start a drag - Flutter's `AllowedButtonsFilter`.
typedef AllowedButtonsFilter = bool Function(int buttons);

/// Where, relative to the pointer, the feedback is drawn: the returned
/// offset is subtracted from the pointer position.
typedef DragAnchorStrategy = Offset Function(
  Draggable<Object> draggable,
  BuildContext context,
  Offset position,
);

/// The first render box of [context]'s widget.
RenderBox? _boxOf(BuildContext context) {
  if (context is! Element) return null;
  if (context is RenderObjectElement) return context.renderObject;
  final List<RenderBox> found = <RenderBox>[];
  context.collectRenderChildren(found);
  return found.isEmpty ? null : found.first;
}

/// The feedback keeps the place the child had under the pointer - the
/// default. Flutter's `childDragAnchorStrategy`.
Offset childDragAnchorStrategy(
  Draggable<Object> draggable,
  BuildContext context,
  Offset position,
) {
  final RenderBox? box = _boxOf(context);
  return box == null ? Offset.zero : box.globalToLocal(position);
}

/// The feedback's top left corner is at the pointer. Flutter's
/// `pointerDragAnchorStrategy`.
Offset pointerDragAnchorStrategy(
  Draggable<Object> draggable,
  BuildContext context,
  Offset position,
) =>
    Offset.zero;

/// A widget that can be dragged to a [DragTarget] - Flutter's `Draggable`.
///
/// While dragged, [feedback] follows the pointer in the [Overlay] and
/// [childWhenDragging] (when given) takes [child]'s place.
class Draggable<T extends Object> extends StatefulWidget {
  const Draggable({
    super.key,
    required this.child,
    required this.feedback,
    this.data,
    this.axis,
    this.childWhenDragging,
    this.feedbackOffset = Offset.zero,
    this.dragAnchorStrategy = childDragAnchorStrategy,
    this.affinity,
    this.maxSimultaneousDrags,
    this.onDragStarted,
    this.onDragUpdate,
    this.onDraggableCanceled,
    this.onDragEnd,
    this.onDragCompleted,
    this.ignoringFeedbackSemantics = true,
    this.ignoringFeedbackPointer = true,
    this.rootOverlay = false,
    this.hitTestBehavior = HitTestBehavior.deferToChild,
    this.allowedButtonsFilter,
  });

  /// What a [DragTarget] receives.
  final T? data;

  /// Restricts the feedback's movement to this axis.
  final Axis? axis;

  final Widget child;

  /// Shown in [child]'s place while a drag is under way.
  final Widget? childWhenDragging;

  /// Drawn under the pointer while dragging.
  final Widget feedback;

  /// Moves where targets are looked for, relative to the pointer.
  final Offset feedbackOffset;

  final DragAnchorStrategy dragAnchorStrategy;

  /// Only a drag along this axis starts a drag: one across it is left to,
  /// say, the list this sits in.
  final Axis? affinity;

  /// How many drags may be under way at once; 0 disables dragging.
  final int? maxSimultaneousDrags;

  final void Function()? onDragStarted;
  final DragUpdateCallback? onDragUpdate;
  final DraggableCanceledCallback? onDraggableCanceled;
  final void Function()? onDragCompleted;
  final DragEndCallback? onDragEnd;
  final bool ignoringFeedbackSemantics;

  /// Whether the feedback ignores the pointer, so the widgets under it are
  /// hit. True, as in Flutter; turning it off makes the feedback hide the
  /// targets from the drag.
  final bool ignoringFeedbackPointer;

  /// Whether the feedback goes in the outermost [Overlay].
  final bool rootOverlay;
  final HitTestBehavior hitTestBehavior;
  final AllowedButtonsFilter? allowedButtonsFilter;

  /// Whether this draggable starts on a long press. [LongPressDraggable]
  /// answers true.
  bool get _longPress => false;

  Duration? get _delay => null;

  @override
  State<Draggable<T>> createState() => _DraggableState<T>();
}

/// A [Draggable] that starts on a long press - Flutter's
/// `LongPressDraggable`.
class LongPressDraggable<T extends Object> extends Draggable<T> {
  const LongPressDraggable({
    super.key,
    required super.child,
    required super.feedback,
    super.data,
    super.axis,
    super.childWhenDragging,
    super.feedbackOffset,
    super.dragAnchorStrategy,
    super.maxSimultaneousDrags,
    super.onDragStarted,
    super.onDragUpdate,
    super.onDraggableCanceled,
    super.onDragEnd,
    super.onDragCompleted,
    this.hapticFeedbackOnStart = true,
    super.ignoringFeedbackSemantics,
    super.ignoringFeedbackPointer,
    this.delay = const Duration(milliseconds: 500),
    super.allowedButtonsFilter,
    super.hitTestBehavior,
    super.rootOverlay,
  });

  /// Accepted for Flutter's signature; there is no haptic engine here.
  final bool hapticFeedbackOnStart;

  /// How long the press must be held.
  final Duration delay;

  @override
  bool get _longPress => true;

  @override
  Duration? get _delay => delay;
}

/// How a drag ended - Flutter's `DraggableDetails`.
class DraggableDetails {
  DraggableDetails({
    this.wasAccepted = false,
    required this.velocity,
    required this.offset,
  });

  final bool wasAccepted;
  final Velocity velocity;

  /// Where the feedback's top left was, in window coordinates.
  final Offset offset;
}

/// What a [DragTarget] is told about a drag - Flutter's
/// `DragTargetDetails`.
class DragTargetDetails<T> {
  DragTargetDetails({required this.data, required this.offset});

  final T data;

  /// Where the feedback's top left is, in window coordinates.
  final Offset offset;
}

class _DraggableState<T extends Object> extends State<Draggable<T>> {
  int _activeCount = 0;
  _DragAvatar<T>? _avatar;
  Offset? _downPosition;
  bool _buttonAllowed = true;

  bool get _canDrag =>
      widget.maxSimultaneousDrags == null ||
      _activeCount < widget.maxSimultaneousDrags!;

  void _onPointerDown(PointerDownEvent event) {
    _downPosition = event.logicalPosition;
    _buttonAllowed = widget.allowedButtonsFilter?.call(event.buttons) ?? true;
  }

  OverlayState _overlay() {
    OverlayState overlay = Overlay.of(context);
    if (widget.rootOverlay) {
      while (true) {
        final BuildContext overlayContext = overlay.context;
        final OverlayState? outer = Overlay.maybeOf(overlayContext);
        if (outer == null || identical(outer, overlay)) break;
        overlay = outer;
      }
    }
    return overlay;
  }

  void _start(Offset pointer, Offset recognizedAt, Duration timestamp) {
    if (!_canDrag || !_buttonAllowed || _avatar != null || !mounted) return;
    final BuildOwner? owner = (context as Element).owner;
    if (owner == null) return;
    final Offset anchor = widget.dragAnchorStrategy(widget, context, pointer);
    setState(() => _activeCount += 1);
    final _DragAvatar<T> avatar = _DragAvatar<T>(
      owner: owner,
      overlayState: _overlay(),
      data: widget.data,
      axis: widget.axis,
      initialPosition: pointer,
      dragStartPoint: anchor,
      feedback: widget.feedback,
      feedbackOffset: widget.feedbackOffset,
      ignoringFeedbackPointer: widget.ignoringFeedbackPointer,
      onDragEnd: _ended,
    );
    _avatar = avatar;
    widget.onDragStarted?.call();
    // The pointer is already past the slop: catch the feedback up.
    if (recognizedAt != pointer) {
      avatar.update(
        DragUpdateDetails(
          globalPosition: recognizedAt,
          delta: recognizedAt - pointer,
          primaryDelta: null,
          timestamp: timestamp,
        ),
        _report,
      );
    }
  }

  void _report(DragUpdateDetails details) {
    if (mounted) widget.onDragUpdate?.call(details);
  }

  void _ended(Velocity velocity, Offset offset, bool wasAccepted) {
    _avatar = null;
    if (mounted) {
      setState(() => _activeCount -= 1);
    } else {
      _activeCount -= 1;
    }
    if (mounted) {
      widget.onDragEnd?.call(DraggableDetails(
        wasAccepted: wasAccepted,
        velocity: velocity,
        offset: offset,
      ));
    }
    if (wasAccepted) widget.onDragCompleted?.call();
    if (!wasAccepted) widget.onDraggableCanceled?.call(velocity, offset);
  }

  // ---- pan / axis drag ----------------------------------------------------

  void _dragStart(DragStartDetails details) => _start(
      _downPosition ?? details.globalPosition,
      details.globalPosition,
      details.timestamp);

  void _dragUpdate(DragUpdateDetails details) =>
      _avatar?.update(details, _report);

  void _dragEnd(DragEndDetails details) => _avatar?.end(details.velocity);

  void _dragCancel() => _avatar?.cancel();

  // ---- long press ---------------------------------------------------------

  Offset? _longPressLast;

  void _longPressStart(LongPressStartDetails details) {
    _longPressLast = details.globalPosition;
    _start(details.globalPosition, details.globalPosition, details.timestamp);
  }

  void _longPressMove(LongPressMoveUpdateDetails details) {
    final Offset last = _longPressLast ?? details.globalPosition;
    _longPressLast = details.globalPosition;
    _avatar?.update(
      DragUpdateDetails(
        globalPosition: details.globalPosition,
        delta: details.globalPosition - last,
        primaryDelta: null,
        timestamp: details.timestamp,
      ),
      _report,
    );
  }

  void _longPressEnd(LongPressEndDetails details) {
    _longPressLast = null;
    _avatar?.end(details.velocity);
  }

  @override
  void dispose() {
    // A drag outlives the widget that started it, as in Flutter: the avatar
    // keeps following the pointer, which its recognizer still owns.
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (Overlay.maybeOf(context) == null) {
      throw StateError(
        'No Overlay widget found above ${widget.runtimeType}: a Draggable '
        'draws its feedback in an Overlay. A Navigator, or an app widget, '
        'installs one.',
      );
    }
    final bool enabled = _canDrag || _avatar != null;
    final bool showChild =
        _activeCount == 0 || widget.childWhenDragging == null;
    final Widget shown = showChild ? widget.child : widget.childWhenDragging!;
    final Widget detector;
    if (widget._longPress) {
      detector = GestureDetector(
        behavior: widget.hitTestBehavior,
        longPressDuration: widget._delay,
        onLongPressStart: enabled ? _longPressStart : null,
        onLongPressMoveUpdate: enabled ? _longPressMove : null,
        onLongPressEnd: enabled ? _longPressEnd : null,
        onLongPressCancel: enabled ? () => _avatar?.cancel() : null,
        child: shown,
      );
    } else {
      final Axis? affinity = widget.affinity;
      detector = GestureDetector(
        behavior: widget.hitTestBehavior,
        onPanStart: enabled && affinity == null ? _dragStart : null,
        onPanUpdate: enabled && affinity == null ? _dragUpdate : null,
        onPanEnd: enabled && affinity == null ? _dragEnd : null,
        onPanCancel: enabled && affinity == null ? _dragCancel : null,
        onHorizontalDragStart:
            enabled && affinity == Axis.horizontal ? _dragStart : null,
        onHorizontalDragUpdate:
            enabled && affinity == Axis.horizontal ? _dragUpdate : null,
        onHorizontalDragEnd:
            enabled && affinity == Axis.horizontal ? _dragEnd : null,
        onHorizontalDragCancel:
            enabled && affinity == Axis.horizontal ? _dragCancel : null,
        onVerticalDragStart:
            enabled && affinity == Axis.vertical ? _dragStart : null,
        onVerticalDragUpdate:
            enabled && affinity == Axis.vertical ? _dragUpdate : null,
        onVerticalDragEnd:
            enabled && affinity == Axis.vertical ? _dragEnd : null,
        onVerticalDragCancel:
            enabled && affinity == Axis.vertical ? _dragCancel : null,
        child: shown,
      );
    }
    return Listener(
      behavior: widget.hitTestBehavior,
      onPointerDown: _onPointerDown,
      child: detector,
    );
  }
}

/// A widget that receives a [Draggable]'s data when it is dropped on it -
/// Flutter's `DragTarget`.
///
/// [builder] is told the data of the drags hovering over it: the ones it
/// would accept ([onWillAcceptWithDetails] said yes, or there is no such
/// callback) and the ones it would not.
class DragTarget<T extends Object> extends StatefulWidget {
  const DragTarget({
    super.key,
    required this.builder,
    @Deprecated('Use onWillAcceptWithDetails instead.') this.onWillAccept,
    this.onWillAcceptWithDetails,
    @Deprecated('Use onAcceptWithDetails instead.') this.onAccept,
    this.onAcceptWithDetails,
    this.onLeave,
    this.onMove,
    this.hitTestBehavior = HitTestBehavior.translucent,
  });

  final DragTargetBuilder<T> builder;
  final DragTargetWillAccept<T>? onWillAccept;
  final DragTargetWillAcceptWithDetails<T>? onWillAcceptWithDetails;
  final DragTargetAccept<T>? onAccept;
  final DragTargetAcceptWithDetails<T>? onAcceptWithDetails;
  final DragTargetLeave<T>? onLeave;
  final DragTargetMove<T>? onMove;
  final HitTestBehavior hitTestBehavior;

  @override
  State<DragTarget<T>> createState() => _DragTargetState<T>();
}

List<D?> _mapAvatarsToData<D extends Object>(
        List<_DragAvatar<Object>> avatars) =>
    <D?>[for (final _DragAvatar<Object> avatar in avatars) avatar.data as D?];

class _DragTargetState<T extends Object> extends State<DragTarget<T>> {
  final List<_DragAvatar<Object>> _candidateAvatars = <_DragAvatar<Object>>[];
  final List<_DragAvatar<Object>> _rejectedAvatars = <_DragAvatar<Object>>[];

  bool isExpectedDataType(Object? data) => data is T?;

  bool didEnter(_DragAvatar<Object> avatar) {
    final DragTargetWillAccept<T>? willAccept =
        // ignore: deprecated_member_use_from_same_package
        widget.onWillAccept;
    final DragTargetWillAcceptWithDetails<T>? withDetails =
        widget.onWillAcceptWithDetails;
    final bool accepted = (willAccept == null && withDetails == null) ||
        (willAccept != null && willAccept(avatar.data as T?)) ||
        (withDetails != null &&
            avatar.data != null &&
            withDetails(DragTargetDetails<T>(
              data: avatar.data! as T,
              offset: avatar._lastOffset!,
            )));
    setState(() {
      (accepted ? _candidateAvatars : _rejectedAvatars).add(avatar);
    });
    return accepted;
  }

  void didLeave(_DragAvatar<Object> avatar) {
    if (!mounted) return;
    setState(() {
      _candidateAvatars.remove(avatar);
      _rejectedAvatars.remove(avatar);
    });
    widget.onLeave?.call(avatar.data as T?);
  }

  void didDrop(_DragAvatar<Object> avatar) {
    if (!mounted) return;
    setState(() => _candidateAvatars.remove(avatar));
    final Object? data = avatar.data;
    if (data != null) {
      // ignore: deprecated_member_use_from_same_package
      widget.onAccept?.call(data as T);
      widget.onAcceptWithDetails?.call(
        DragTargetDetails<T>(data: data as T, offset: avatar._lastOffset!),
      );
    }
  }

  void didMove(_DragAvatar<Object> avatar) {
    final Object? data = avatar.data;
    if (!mounted || data == null) return;
    widget.onMove?.call(
      DragTargetDetails<T>(data: data as T, offset: avatar._lastOffset!),
    );
  }

  @override
  Widget build(BuildContext context) => _DragTargetMeta(
        state: this,
        behavior: widget.hitTestBehavior,
        child: widget.builder(
          context,
          _mapAvatarsToData<T>(_candidateAvatars),
          _mapAvatarsToData<Object>(_rejectedAvatars),
        ),
      );
}

final class _DragTargetMeta extends SingleChildRenderObjectWidget {
  const _DragTargetMeta({
    required this.state,
    required this.behavior,
    super.child,
  });

  final _DragTargetState<Object> state;
  final HitTestBehavior behavior;

  @override
  RenderBox createRenderObject(BuildContext context) =>
      _RenderDragTargetMeta(state, behavior);

  @override
  void updateRenderObject(
    BuildContext context,
    covariant _RenderDragTargetMeta renderObject,
  ) {
    renderObject
      ..state = state
      ..behavior = behavior;
  }
}

/// Marks a [DragTarget] in the render tree, where the drag's hit test
/// finds it.
final class _RenderDragTargetMeta extends RenderProxyBox {
  _RenderDragTargetMeta(this.state, this.behavior);

  _DragTargetState<Object> state;
  HitTestBehavior behavior;

  @override
  void performLayout() {
    final RenderBox? child = this.child;
    if (child == null) {
      size = constraints.smallest;
      return;
    }
    super.performLayout();
  }

  @override
  bool hitTestSelf(Offset position) => behavior != HitTestBehavior.deferToChild;
}

enum _DragEndKind { dropped, canceled }

typedef _OnDragEnd = void Function(
    Velocity velocity, Offset offset, bool wasAccepted);

/// One drag under way: the feedback in the overlay, and the targets it is
/// over.
final class _DragAvatar<T extends Object> {
  _DragAvatar({
    required this.owner,
    required this.overlayState,
    this.data,
    this.axis,
    required Offset initialPosition,
    this.dragStartPoint = Offset.zero,
    required this.feedback,
    this.feedbackOffset = Offset.zero,
    required this.ignoringFeedbackPointer,
    this.onDragEnd,
  }) : _position = initialPosition {
    _entry = OverlayEntry(builder: _build);
    overlayState.insert(_entry!);
    _updateDrag(initialPosition);
  }

  final BuildOwner owner;
  final OverlayState overlayState;
  final T? data;
  final Axis? axis;
  final Offset dragStartPoint;
  final Widget feedback;
  final Offset feedbackOffset;
  final bool ignoringFeedbackPointer;
  final _OnDragEnd? onDragEnd;

  _DragTargetState<Object>? _activeTarget;
  final List<_DragTargetState<Object>> _enteredTargets =
      <_DragTargetState<Object>>[];
  Offset _position;
  Offset? _lastOffset;
  Offset _overlayOffset = Offset.zero;
  OverlayEntry? _entry;

  void update(
    DragUpdateDetails details,
    void Function(DragUpdateDetails details) report,
  ) {
    final Offset old = _position;
    _position += _restrictAxis(details.delta);
    _updateDrag(_position);
    if (_position != old) report(details);
  }

  void end(Velocity velocity) =>
      _finish(_DragEndKind.dropped, _restrictVelocity(velocity));

  void cancel() => _finish(_DragEndKind.canceled);

  Offset _restrictAxis(Offset offset) => switch (axis) {
        null => offset,
        Axis.horizontal => Offset(offset.dx, 0),
        Axis.vertical => Offset(0, offset.dy),
      };

  Velocity _restrictVelocity(Velocity velocity) => axis == null
      ? velocity
      : Velocity(pixelsPerSecond: _restrictAxis(velocity.pixelsPerSecond));

  void _updateDrag(Offset globalPosition) {
    _lastOffset = globalPosition - dragStartPoint;
    if (overlayState.mounted) {
      final RenderBox? box = _boxOf(overlayState.context);
      final Offset local =
          box == null ? globalPosition : box.globalToLocal(globalPosition);
      _overlayOffset = local - dragStartPoint;
      _entry?.markNeedsBuild();
    }

    final List<_DragTargetState<Object>> targets =
        _targetsAt(globalPosition + feedbackOffset);

    bool listsMatch = false;
    if (targets.length >= _enteredTargets.length &&
        _enteredTargets.isNotEmpty) {
      listsMatch = true;
      for (int i = 0; i < _enteredTargets.length; i++) {
        if (!identical(targets[i], _enteredTargets[i])) {
          listsMatch = false;
          break;
        }
      }
    }
    if (listsMatch &&
        (_activeTarget != null || targets.length == _enteredTargets.length)) {
      for (final _DragTargetState<Object> target in _enteredTargets) {
        target.didMove(this);
      }
      return;
    }

    _leaveAllEntered();
    _DragTargetState<Object>? newTarget;
    for (final _DragTargetState<Object> target in targets) {
      _enteredTargets.add(target);
      if (target.didEnter(this)) {
        newTarget = target;
        break;
      }
    }
    for (final _DragTargetState<Object> target in _enteredTargets) {
      target.didMove(this);
    }
    _activeTarget = newTarget;
  }

  /// The drag targets under [position], innermost first, that take this
  /// drag's data type.
  List<_DragTargetState<Object>> _targetsAt(Offset position) {
    final RenderBox? root = owner.renderRoot;
    if (root == null) return const <_DragTargetState<Object>>[];
    final HitTestPath path = HitTestPath();
    Offset at = position;
    // The root is laid out at the window's origin; hit testing is in its
    // coordinates.
    final Offset origin = root.localToGlobal(Offset.zero);
    at = Offset(at.dx - origin.dx, at.dy - origin.dy);
    root.hitTest(at, path: path);
    return <_DragTargetState<Object>>[
      for (final RenderBox entry in path.entries)
        if (entry is _RenderDragTargetMeta &&
            entry.state.mounted &&
            entry.state.isExpectedDataType(data))
          entry.state,
    ];
  }

  void _leaveAllEntered() {
    for (final _DragTargetState<Object> target in _enteredTargets) {
      target.didLeave(this);
    }
    _enteredTargets.clear();
  }

  void _finish(_DragEndKind kind, [Velocity? velocity]) {
    if (_entry == null) return;
    bool wasAccepted = false;
    if (kind == _DragEndKind.dropped && _activeTarget != null) {
      _activeTarget!.didDrop(this);
      wasAccepted = true;
      _enteredTargets.remove(_activeTarget);
    }
    _leaveAllEntered();
    _activeTarget = null;
    if (_entry!.isInserted) _entry!.remove();
    _entry = null;
    onDragEnd?.call(velocity ?? Velocity.zero, _lastOffset!, wasAccepted);
  }

  Widget _build(BuildContext context) => Stack(
        children: <Widget>[
          Positioned(
            left: _overlayOffset.dx,
            top: _overlayOffset.dy,
            child: IgnorePointer(
              ignoring: ignoringFeedbackPointer,
              child: feedback,
            ),
          ),
        ],
      );
}
