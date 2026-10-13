/// CorelDRAW's Shape tool (F10): pick a curve, then its nodes, and drag
/// them, their handles, or a band around several.
library;

import '../geometry/offset.dart';
import '../geometry/rect.dart';
import '../graphics/vector/primitives.dart';
import '../graphics/vector/selectable_objects.dart';
import '../graphics/vector/structural_objects.dart';
import 'node_editing.dart';
import 'selection.dart';
import 'tool_controller.dart';

/// What a Shape-tool drag is doing.
enum ShapeDrag { none, nodes, handle, segment, marquee }

/// The Shape tool as a state machine of pointer events.
///
/// A press on a selected curve's node picks it (Shift adds or removes) and a
/// drag moves every picked node; a press on a picked node's handle drags
/// that handle, keeping a smooth node smooth; a press on a segment bends it
/// under the pointer; a press anywhere else bands
/// nodes. Clicking another curve edits that one instead. A double click
/// adds a node on a segment, or removes the node under the pointer.
///
/// Every drag is computed from the press, against a copy of the paths taken
/// then, so dragging back restores the curve exactly - the select tool's
/// rule.
class ShapeToolController extends ToolController {
  ShapeToolController({
    required super.doc,
    required super.methods,
    required super.selection,
    required super.snap,
  });

  NodeSelection get nodes => selection.nodes;

  ShapeDrag _drag = ShapeDrag.none;
  ShapeDrag get drag => _drag;

  Offset? _press;
  NodeHandleRef? _handle;
  SegmentHit? _segment;
  List<VectorPath>? _snapshot;
  bool _edited = false;

  /// The band being drawn, in document coordinates.
  Rect? marquee;

  /// Whether the gesture that just ended changed the curve - the cue to
  /// record an undo step. Consumed once.
  bool takeEdited() {
    final bool edited = _edited;
    _edited = false;
    return edited;
  }

  double get _grab => SelectionManager.handleGrabPixels * onePixel;

  /// The curve under [point] on [page], if the top object there is one.
  VectorCurve? _curveAt(Offset point, VectorPage page) {
    final SelectableObject? hit = selection.hitTest(point, page,
        tolerance: SelectionManager.objectGrabPixels * onePixel);
    return hit is VectorCurve ? hit : null;
  }

  List<VectorPath> _copy(VectorCurve curve) => <VectorPath>[
        for (final VectorPath path in curve.paths)
          path.copyWith(points: List<Object>.of(path.points)),
      ];

  void _restore(VectorCurve curve) {
    final List<VectorPath>? snapshot = _snapshot;
    if (snapshot == null) return;
    curve.paths = _copy(VectorCurve(paths: snapshot));
  }

  @override
  void onPointerDown(Offset point, VectorPage page) {
    lastPoint = point;
    _press = point;
    _handle = null;
    _segment = null;
    _snapshot = null;
    marquee = null;
    final VectorCurve? curve = selection.syncNodeCurve();
    final Offset? local =
        curve == null ? null : NodeEditing.toLocal(curve, point);
    if (curve != null && local != null) {
      final double tolerance = _grab * NodeEditing.localScale(curve);
      final NodeHandleRef? handle =
          NodeEditing.handleAt(curve, nodes.nodes, local, tolerance);
      if (handle != null) {
        _handle = handle;
        _snapshot = _copy(curve);
        _drag = ShapeDrag.handle;
        return;
      }
      final PathNode? node = NodeEditing.nodeAt(curve, local, tolerance);
      if (node != null) {
        if (!nodes.nodes.contains(node)) {
          nodes.select(<PathNode>[node], additive: isShiftHeld);
        }
        _snapshot = _copy(curve);
        _drag = ShapeDrag.nodes;
        return;
      }
      final SegmentHit? segment =
          NodeEditing.segmentAt(curve, local, tolerance);
      if (segment != null) {
        _segment = segment;
        _snapshot = _copy(curve);
        _drag = ShapeDrag.segment;
        return;
      }
    }
    _drag = ShapeDrag.marquee;
    marquee = Rect.fromPoints(point, point);
  }

  @override
  void onPointerMove(Offset point, VectorPage page) {
    lastPoint = point;
    final Offset? press = _press;
    final VectorCurve? curve = nodes.curve;
    switch (_drag) {
      case ShapeDrag.marquee:
        if (press != null) marquee = Rect.fromPoints(press, point);
      case ShapeDrag.nodes:
        if (curve == null || press == null) return;
        final Offset? from = NodeEditing.toLocal(curve, press);
        final Offset? to = NodeEditing.toLocal(curve, point);
        if (from == null || to == null) return;
        _restore(curve);
        NodeEditing.moveNodes(curve, nodes.nodes, to - from);
        _edited = true;
      case ShapeDrag.handle:
        final NodeHandleRef? handle = _handle;
        final Offset? to =
            curve == null ? null : NodeEditing.toLocal(curve, point);
        if (curve == null || handle == null || to == null) return;
        _restore(curve);
        NodeEditing.moveHandle(curve, handle, to);
        _edited = true;
      case ShapeDrag.segment:
        final SegmentHit? segment = _segment;
        if (curve == null || press == null || segment == null) return;
        final Offset? from = NodeEditing.toLocal(curve, press);
        final Offset? to = NodeEditing.toLocal(curve, point);
        if (from == null || to == null) return;
        _restore(curve);
        if (to == from) return;
        NodeEditing.dragSegment(curve, segment, to - from);
        _edited = true;
      case ShapeDrag.none:
        break;
    }
  }

  @override
  void onPointerUp(Offset point, VectorPage page) {
    onPointerMove(point, page);
    if (_drag == ShapeDrag.marquee) {
      final Rect? band = marquee;
      final VectorCurve? curve = nodes.curve;
      if (band != null && curve != null) {
        nodes.select(
          <PathNode>[
            for (final PathNode node in NodeEditing.nodesOf(curve))
              if (band.contains(NodeEditing.toDocument(curve,
                  NodeEditing.nodePoint(curve.paths[node.path], node.index))))
                node,
          ],
          additive: isShiftHeld,
        );
      }
    }
    marquee = null;
    _snapshot = null;
    _drag = ShapeDrag.none;
  }

  @override
  void onCancel() {
    final VectorCurve? curve = nodes.curve;
    if (curve != null && _drag != ShapeDrag.marquee) _restore(curve);
    _edited = false;
    marquee = null;
    _snapshot = null;
    _drag = ShapeDrag.none;
  }

  /// A click (no drag) at [point]; [clicks] is 2 for a double click.
  ///
  /// Returns a hint for the status bar, or null.
  String? click(Offset point, VectorPage page, {int clicks = 1}) {
    lastPoint = point;
    final VectorCurve? current = selection.syncNodeCurve();
    final Offset? local =
        current == null ? null : NodeEditing.toLocal(current, point);
    if (current != null && local != null) {
      final double tolerance = _grab * NodeEditing.localScale(current);
      final PathNode? node = NodeEditing.nodeAt(current, local, tolerance);
      if (node != null) {
        if (clicks >= 2) {
          if (!NodeEditing.deleteNodes(current, <PathNode>[node])) {
            methods.removeObject(current);
            selection.deselectAll();
          }
          nodes.prune();
          _edited = true;
          return 'Node deleted';
        }
        if (isShiftHeld) {
          nodes.toggle(node);
        } else {
          nodes.select(<PathNode>[node]);
        }
        return null;
      }
      final SegmentHit? segment =
          NodeEditing.segmentAt(current, local, tolerance);
      if (segment != null) {
        if (clicks >= 2) {
          nodes.select(<PathNode>[NodeEditing.insertNode(current, segment)]);
          _edited = true;
          return 'Node added';
        }
        return null;
      }
    }
    // Not on the edited curve: pick another one, or nothing.
    final VectorCurve? other = _curveAt(point, page);
    if (other != null) {
      selection.select(other);
      selection.syncNodeCurve();
      return 'Editing nodes - drag a node, double-click a segment to add one';
    }
    final SelectableObject? shape = selection.hitTest(point, page,
        tolerance: SelectionManager.objectGrabPixels * onePixel);
    if (shape != null) {
      selection.select(shape);
      selection.syncNodeCurve();
      return 'Only curves have nodes - Convert to Curves (Ctrl+Q) first';
    }
    nodes.clearNodes();
    return null;
  }
}
