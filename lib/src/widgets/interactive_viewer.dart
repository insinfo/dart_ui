// Portions adapted from Flutter's `widgets/interactive_viewer.dart`:
// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file of the Flutter repository.

/// Flutter's `InteractiveViewer`: pan and zoom a child.
///
/// A drag pans; a pinch - two fingers, or a trackpad's pinch, which arrives
/// as a [PointerPanZoomEvent] - zooms about the fingers; the mouse wheel
/// zooms about the pointer (with or without Ctrl, as in Flutter); a
/// trackpad's two-finger scroll pans. The child stays inside its boundary
/// (the child's box grown by [InteractiveViewer.boundaryMargin]) and the
/// scale inside [InteractiveViewer.minScale]..[InteractiveViewer.maxScale].
///
/// ## Differences from Flutter
///
/// * The transform is a [Transform2D] - the six numbers of a 2D affine
///   transform - not a `Matrix4`: the display list here is 2D and carries
///   `Transform2D`. [TransformationController.value] is therefore a
///   [Transform2D]; read the scale as `value.a` (Flutter's
///   `getMaxScaleOnAxis()`) and the translation as `value.tx`, `value.ty`
///   (Flutter's `getTranslation()`).
/// * No inertia: a pan stops when the finger lifts.
///   `interactionEndFrictionCoefficient` is accepted and unused.
/// * No `InteractiveViewer.builder` (it hands the builder a `Quad`, a 3D
///   type) and no `clipBehavior`: the viewer always clips to its box.
/// * The scale callbacks get this framework's [ScaleStartDetails] and
///   friends, which carry `focalPoint` in window coordinates and no
///   `localFocalPoint`.
library;

import 'dart:math' as math;

import '../foundation/change_notifier.dart';
import '../geometry/offset.dart';
import '../geometry/rect.dart';
import '../geometry/size.dart';
import '../geometry/transform2d.dart';
import '../gestures/binding.dart';
import '../gestures/scale.dart';
import '../gestures/velocity_tracker.dart';
import '../layout/alignment.dart';
import '../layout/edge_insets.dart';
import '../layout/render_box.dart';
import '../layout/render_flex.dart' show Axis;
import '../layout/render_proxy_box.dart';
import '../platform/input_events.dart';
import 'element.dart';
import 'gesture_detector.dart';
import 'listener.dart';
import 'proxy.dart';
import 'sizing.dart';
import 'widget.dart';

/// Flutter's `kDefaultMouseScrollToScaleFactor`: how many pixels of wheel
/// make the scale change by a factor of e.
const double kDefaultMouseScrollToScaleFactor = 200;

/// Pixels a wheel "line" is worth, for a backend that reports lines.
const double _kLineHeight = 20;

/// Which way a pan may go - Flutter's `PanAxis`.
enum PanAxis {
  /// Any direction.
  free,

  /// Along the axis the pan started on, horizontal or vertical.
  aligned,

  horizontal,
  vertical,
}

/// The transform an [InteractiveViewer] applies to its child - Flutter's
/// `TransformationController`, with a [Transform2D] where Flutter has a
/// `Matrix4` (see the library comment).
///
/// A [ChangeNotifier] with Flutter's `void Function()` listeners.
class TransformationController extends ChangeNotifier {
  TransformationController([Transform2D? value])
      : _value = value ?? Transform2D.identity;

  Transform2D _value;

  /// Maps the child's coordinates (the scene) to the viewer's.
  Transform2D get value => _value;

  set value(Transform2D next) {
    if (next == _value) return;
    _value = next;
    notifyListeners();
  }

  /// The point of the scene under [viewportPoint], a point in the viewer's
  /// box.
  Offset toScene(Offset viewportPoint) {
    final Transform2D? inverse = _value.invert();
    return inverse == null
        ? viewportPoint
        : inverse.transformOffset(viewportPoint);
  }
}

/// Pans and zooms its child - Flutter's `InteractiveViewer`. See the
/// library comment.
class InteractiveViewer extends StatefulWidget {
  const InteractiveViewer({
    super.key,
    this.panAxis = PanAxis.free,
    this.boundaryMargin = EdgeInsets.zero,
    this.constrained = true,
    this.maxScale = 2.5,
    this.minScale = 0.8,
    this.interactionEndFrictionCoefficient = 0.0000135,
    this.onInteractionEnd,
    this.onInteractionStart,
    this.onInteractionUpdate,
    this.panEnabled = true,
    this.scaleEnabled = true,
    this.scaleFactor = kDefaultMouseScrollToScaleFactor,
    this.transformationController,
    this.alignment,
    this.trackpadScrollCausesScale = false,
    required this.child,
  });

  final PanAxis panAxis;

  /// How far past the child's edges the view may go. `EdgeInsets.all(
  /// double.infinity)` lets it go anywhere.
  final EdgeInsets boundaryMargin;

  /// Whether the child is laid out at the viewer's size (true) or at its
  /// own, unconstrained (false) - for a child larger than the view.
  final bool constrained;

  final double maxScale;
  final double minScale;

  /// Accepted for Flutter's signature; there is no inertia here.
  final double interactionEndFrictionCoefficient;

  final void Function(ScaleStartDetails details)? onInteractionStart;
  final void Function(ScaleUpdateDetails details)? onInteractionUpdate;
  final void Function(ScaleEndDetails details)? onInteractionEnd;

  final bool panEnabled;
  final bool scaleEnabled;

  /// Wheel pixels per factor of e in scale.
  final double scaleFactor;

  final TransformationController? transformationController;

  /// The pivot of the transform within the child; top left when null.
  final Alignment? alignment;

  /// Whether a trackpad's two-finger scroll zooms instead of panning.
  final bool trackpadScrollCausesScale;

  final Widget child;

  @override
  State<InteractiveViewer> createState() => _InteractiveViewerState();
}

class _InteractiveViewerState extends State<InteractiveViewer> {
  TransformationController? _ownController;
  Size _viewport = Size.zero;
  Size _childSize = Size.zero;
  _RenderSizeProbe? _viewportProbe;

  Offset? _referenceFocalPoint;
  double? _scaleStart;
  double _scaleBase = 1;
  int _pointers = 0;
  bool _scaling = false;
  Axis? _currentAxis;

  TransformationController get _controller =>
      widget.transformationController ??
      (_ownController ??= TransformationController());

  @override
  void initState() {
    super.initState();
    _controller.addListener(_changed);
  }

  @override
  void didUpdateWidget(InteractiveViewer oldWidget) {
    super.didUpdateWidget(oldWidget);
    final TransformationController old =
        oldWidget.transformationController ?? _ownController!;
    if (!identical(old, _controller)) {
      old.removeListener(_changed);
      _controller.addListener(_changed);
    }
  }

  @override
  void dispose() {
    _controller.removeListener(_changed);
    _ownController?.dispose();
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  /// The child's box grown by the margin, in scene coordinates.
  Rect get _boundaryRect {
    final EdgeInsets m = widget.boundaryMargin;
    return Rect.fromLTRB(
      -m.left,
      -m.top,
      _childSize.width + m.right,
      _childSize.height + m.bottom,
    );
  }

  Offset _toLocal(Offset global) =>
      _viewportProbe?.globalToLocal(global) ?? global;

  double get _scale => _controller.value.a;

  /// [matrix] scaled by [factor] about the scene origin, kept within the
  /// scale limits and so the boundary still covers the viewport.
  Transform2D _matrixScale(Transform2D matrix, double factor) {
    if (factor == 1.0) return matrix;
    final double current = matrix.a;
    final Rect boundary = _boundaryRect;
    double total = current * factor;
    if (boundary.width.isFinite &&
        boundary.height.isFinite &&
        boundary.width > 0 &&
        boundary.height > 0) {
      total = math.max(
        total,
        math.max(_viewport.width / boundary.width,
            _viewport.height / boundary.height),
      );
    }
    final double clamped = total.clamp(widget.minScale, widget.maxScale);
    return Transform2D(clamped, 0, 0, clamped, matrix.tx, matrix.ty);
  }

  Offset _alignAxis(Offset offset, Axis axis) =>
      axis == Axis.horizontal ? Offset(offset.dx, 0) : Offset(0, offset.dy);

  /// [matrix] moved by [sceneDelta] (in scene units), kept so the boundary
  /// covers the viewport.
  Transform2D _matrixTranslate(Transform2D matrix, Offset sceneDelta) {
    if (sceneDelta == Offset.zero) return matrix;
    Offset delta = sceneDelta;
    final Axis? axis = _currentAxis;
    switch (widget.panAxis) {
      case PanAxis.horizontal:
        delta = _alignAxis(delta, Axis.horizontal);
      case PanAxis.vertical:
        delta = _alignAxis(delta, Axis.vertical);
      case PanAxis.aligned:
        if (axis != null) delta = _alignAxis(delta, axis);
      case PanAxis.free:
        break;
    }
    final double s = matrix.a;
    double tx = matrix.tx + delta.dx * s;
    double ty = matrix.ty + delta.dy * s;
    final Rect b = _boundaryRect;
    // The viewport (0,0)-(w,h) must stay inside the scaled boundary: an axis
    // that cannot fit keeps the translation it had.
    tx = _clampAxis(tx, matrix.tx, b.left, b.right, s, _viewport.width);
    ty = _clampAxis(ty, matrix.ty, b.top, b.bottom, s, _viewport.height);
    return Transform2D(matrix.a, matrix.b, matrix.c, matrix.d, tx, ty);
  }

  double _clampAxis(
    double t,
    double previous,
    double start,
    double end,
    double scale,
    double extent,
  ) {
    if (!start.isFinite || !end.isFinite) return t;
    final double high = -start * scale;
    final double low = extent - end * scale;
    if (low > high + 1e-9) return previous.clamp(high, low);
    return t.clamp(low, high);
  }

  /// Applies the scale and keeps [localFocal]'s scene point under it.
  void _zoomAbout(Offset localFocal, double factor) {
    final Offset before = _controller.toScene(localFocal);
    Transform2D next = _matrixScale(_controller.value, factor);
    _controller.value = next;
    final Offset after = _controller.toScene(localFocal);
    next = _matrixTranslate(next, after - before);
    _controller.value = next;
  }

  // ---- gestures -----------------------------------------------------------

  void _onScaleStart(ScaleStartDetails details) {
    widget.onInteractionStart?.call(details);
    _scaleStart = _scale;
    _scaleBase = 1;
    _pointers = details.pointerCount;
    _scaling = false;
    _currentAxis = null;
    _referenceFocalPoint = _controller.toScene(_toLocal(details.focalPoint));
  }

  void _onScaleUpdate(ScaleUpdateDetails details) {
    final Offset localFocal = _toLocal(details.focalPoint);
    if (details.pointerCount != _pointers) {
      // A finger joined or left: the recognizer re-took its baseline, so
      // the scale it reports starts again from 1.
      _pointers = details.pointerCount;
      _scaleStart = _scale;
      _scaleBase = details.scale;
      _referenceFocalPoint = _controller.toScene(localFocal);
    }
    final Offset? reference = _referenceFocalPoint;
    final double? scaleStart = _scaleStart;
    if (reference == null || scaleStart == null) return;
    if (!_scaling && details.scale != _scaleBase && details.pointerCount > 1) {
      _scaling = true;
    }
    if (_scaling) {
      if (widget.scaleEnabled) {
        final double desired = scaleStart * details.scale / _scaleBase;
        _controller.value = _matrixScale(_controller.value, desired / _scale);
      }
      if (widget.panEnabled || widget.scaleEnabled) {
        // Keep the scene point that was under the fingers under them.
        final Offset now = _controller.toScene(localFocal);
        _controller.value =
            _matrixTranslate(_controller.value, now - reference);
        _referenceFocalPoint = _controller.toScene(localFocal);
      }
    } else {
      if (!widget.panEnabled) return;
      final Offset now = _controller.toScene(localFocal);
      final Offset change = now - reference;
      _currentAxis ??=
          change.dx.abs() >= change.dy.abs() ? Axis.horizontal : Axis.vertical;
      _controller.value = _matrixTranslate(_controller.value, change);
      _referenceFocalPoint = _controller.toScene(localFocal);
    }
    widget.onInteractionUpdate?.call(details);
  }

  void _onScaleEnd(ScaleEndDetails details) {
    _scaleStart = null;
    _referenceFocalPoint = null;
    _currentAxis = null;
    _scaling = false;
    widget.onInteractionEnd?.call(details);
  }

  void _onPointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    final GestureBinding? binding = GestureBinding.current;
    if (binding == null) {
      _receivedPointerSignal(event);
    } else {
      // The innermost zoomable takes the notch, as Flutter's resolver does.
      binding.signalResolver.register(event, _receivedPointerSignal);
    }
  }

  void _receivedPointerSignal(PointerEvent event) {
    if (event is! PointerScrollEvent) return;
    final double unit =
        event.scrollDeltaUnit == ScrollDeltaUnit.lines ? _kLineHeight : 1;
    final Offset scrollDelta = Offset(
      event.scrollDelta.dx * unit,
      event.scrollDelta.dy * unit,
    );
    final Offset local = _toLocal(event.logicalPosition);
    final ScaleStartDetails start = ScaleStartDetails(
      focalPoint: event.logicalPosition,
      pointerCount: 0,
      timestamp: event.timestamp,
    );
    final bool command = _controlHeld(event);
    final bool pans = event.kind == PointerKind.trackpad &&
        !widget.trackpadScrollCausesScale &&
        !command;
    if (pans || !widget.scaleEnabled) {
      if (!widget.panEnabled) return;
      widget.onInteractionStart?.call(start);
      final Offset from = _controller.toScene(local);
      final Offset to = _controller.toScene(local - scrollDelta);
      _controller.value = _matrixTranslate(_controller.value, to - from);
      widget.onInteractionUpdate?.call(ScaleUpdateDetails(
        focalPoint: event.logicalPosition,
        focalPointDelta: -scrollDelta,
        scale: 1,
        rotation: 0,
        pointerCount: 0,
        timestamp: event.timestamp,
      ));
    } else {
      final double dy = scrollDelta.dy;
      if (dy == 0.0) return;
      final double factor = math.exp(-dy / widget.scaleFactor);
      widget.onInteractionStart?.call(start);
      _zoomAbout(local, factor);
      widget.onInteractionUpdate?.call(ScaleUpdateDetails(
        focalPoint: event.logicalPosition,
        focalPointDelta: Offset.zero,
        scale: factor,
        rotation: 0,
        pointerCount: 0,
        timestamp: event.timestamp,
      ));
    }
    widget.onInteractionEnd?.call(ScaleEndDetails(
      velocity: Velocity.zero,
      pointerCount: 0,
      timestamp: event.timestamp,
    ));
  }

  bool _controlHeld(PointerEvent event) {
    final BuildContext context = this.context;
    if (context is! Element) return false;
    final Set<KeyModifier> held =
        context.owner?.keyModifiers ?? const <KeyModifier>{};
    return held.contains(KeyModifier.control) ||
        held.contains(KeyModifier.meta);
  }

  @override
  Widget build(BuildContext context) {
    Widget child = _SizeProbe(
      onLayout: (_RenderSizeProbe probe) => _childSize = probe.size,
      child: widget.child,
    );
    child = Transform(
      transform: _controller.value,
      alignment: widget.alignment,
      child: child,
    );
    if (!widget.constrained) {
      child = OverflowBox(
        alignment: Alignment.topLeft,
        minWidth: 0,
        minHeight: 0,
        maxWidth: double.infinity,
        maxHeight: double.infinity,
        child: child,
      );
    }
    child = ClipRect(child: child);
    child = _SizeProbe(
      onLayout: (_RenderSizeProbe probe) {
        _viewportProbe = probe;
        _viewport = probe.size;
      },
      child: child,
    );
    return Listener(
      onPointerSignal: _onPointerSignal,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onScaleStart: _onScaleStart,
        onScaleUpdate: _onScaleUpdate,
        onScaleEnd: _onScaleEnd,
        child: child,
      ),
    );
  }
}

/// Tells its owner its size each layout, without a rebuild.
final class _SizeProbe extends SingleChildRenderObjectWidget {
  const _SizeProbe({required this.onLayout, super.child});

  final void Function(_RenderSizeProbe probe) onLayout;

  @override
  RenderBox createRenderObject(BuildContext context) =>
      _RenderSizeProbe(onLayout);

  @override
  void updateRenderObject(
    BuildContext context,
    covariant _RenderSizeProbe renderObject,
  ) =>
      renderObject.onLayout = onLayout;
}

final class _RenderSizeProbe extends RenderProxyBox {
  _RenderSizeProbe(this.onLayout);

  void Function(_RenderSizeProbe probe) onLayout;

  @override
  void performLayout() {
    super.performLayout();
    onLayout(this);
  }
}
