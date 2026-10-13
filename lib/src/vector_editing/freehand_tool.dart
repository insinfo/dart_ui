/// CorelDRAW's Freehand tool (F5): drag, and the trail becomes a curve.
library;

import '../geometry/offset.dart';
import '../graphics/vector/constants.dart';
import '../graphics/vector/primitives.dart';
import '../graphics/vector/structural_objects.dart';
import 'curve_fitting.dart';
import 'tool_controller.dart';

/// The Freehand tool as a state machine of pointer events.
///
/// While the pointer is down the trail is drawn as it is, point by point, so
/// the stroke follows the hand with no lag; on release it is replaced by the
/// few Béziers [CurveFitting] finds for it. A stroke that ends where it
/// began is closed. A press with no drag draws nothing.
class FreehandToolController extends ToolController {
  FreehandToolController({
    required super.doc,
    required super.methods,
    required super.selection,
    required super.snap,
    this.smoothing = 50,
  });

  /// CorelDRAW's Freehand smoothing, 0 to 100: how far, in screen pixels
  /// scaled from half a pixel to six, the curve may stray from the trail.
  double smoothing;

  /// How close, in screen pixels, the end must come to the start to close.
  static const double closePixels = 7.0;

  /// The fitting tolerance, in document units at the current zoom.
  double get fitError => (0.5 + smoothing.clamp(0, 100) / 100 * 5.5) * onePixel;

  VectorCurve? _curve;
  final List<Offset> _trail = <Offset>[];

  /// Whether a stroke is being drawn.
  bool get isDrawing => _curve != null;

  @override
  void onPointerDown(Offset point, VectorPage page) {
    final Offset start = snap.snapPoint(point, page);
    lastPoint = start;
    _trail
      ..clear()
      ..add(start);
    final VectorCurve curve = VectorCurve(
      paths: <VectorPath>[VectorPath(start: start)],
      style: doc.defaultStyle,
    );
    _curve = curve;
    methods.addObject(targetLayer(page), curve);
    selection.select(curve);
    curve.update();
  }

  @override
  void onPointerMove(Offset point, VectorPage page) {
    final VectorCurve? curve = _curve;
    if (curve == null) return;
    lastPoint = point;
    // A sample closer than a pixel to the last adds nothing but work.
    if ((point - _trail.last).distance < onePixel) return;
    _trail.add(point);
    curve.paths.single.points.add(point);
    curve.update();
  }

  @override
  void onPointerUp(Offset point, VectorPage page) {
    onPointerMove(point, page);
    final VectorCurve? curve = _curve;
    _curve = null;
    if (curve == null) return;
    if (_trail.length < 2) {
      methods.removeObject(curve);
      selection.deselectAll();
      _trail.clear();
      return;
    }
    final bool closes = _trail.length > 3 &&
        (_trail.last - _trail.first).distance <= closePixels * onePixel;
    if (closes) _trail[_trail.length - 1] = _trail.first;
    final List<CurvePoint> segments = CurveFitting.fit(_trail, fitError);
    final VectorPath path = curve.paths.single
      ..points = <Object>[...segments]
      ..closure = closes ? PathClosure.closed : PathClosure.opened;
    if (path.points.isEmpty) {
      methods.removeObject(curve);
      selection.deselectAll();
    } else {
      curve.update();
      reportCreated(curve);
    }
    _trail.clear();
    doc.update();
  }

  @override
  void onCancel() {
    final VectorCurve? curve = _curve;
    if (curve != null) methods.removeObject(curve);
    _curve = null;
    _trail.clear();
  }
}
