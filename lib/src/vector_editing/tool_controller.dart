/// Interactive tool controllers for vector creation and editing tools.
///
library;

import '../geometry/offset.dart';
import '../geometry/rect.dart';
import '../graphics/vector/constants.dart';
import '../graphics/vector/doc_methods.dart';
import '../graphics/vector/document.dart';
import '../graphics/vector/document_object.dart';
import '../graphics/vector/primitives.dart';
import '../graphics/vector/selectable_objects.dart';
import '../graphics/vector/structural_objects.dart';
import '../platform/input_events.dart';
import 'selection.dart';
import 'snap_manager.dart';

/// Base class for canvas tool interactions.
abstract class ToolController {
  ToolController({
    required this.doc,
    required this.methods,
    required this.selection,
    required this.snap,
  });

  final VectorDocument doc;
  final DocumentMethods methods;
  final SelectionManager selection;
  final SnapManager snap;

  /// The last document point this controller saw.
  ///
  /// A drag end reports no position of its own - a release carries a velocity,
  /// not a place - so the canvas needs the controller to remember where the
  /// pointer got to.
  Offset? lastPoint;

  /// The keyboard modifiers held as the current pointer event was delivered.
  ///
  /// Set by the canvas before each call, because [PointerEvent] does not carry
  /// them - see `KeyboardRouter.heldModifiers` for why, and for the one case
  /// that cannot answer. Without it there is no Shift+click, no constrained
  /// drag and no proportional resize: the tool simply never learns.
  Set<KeyModifier> modifiers = const <KeyModifier>{};

  /// Device pixels per document unit, as the canvas is currently showing.
  ///
  /// Tools need it for one thing and it matters every time: a *tolerance* is a
  /// screen distance. A handle drawn seven pixels across has to be grabbable
  /// within seven pixels at every zoom, which is `7 / zoom` document units -
  /// not seven document units, which at 20% zoom is a target thirty-five times
  /// too large and at 400% one four times too small.
  double zoom = 1.0;

  /// One device pixel, expressed in document units.
  double get onePixel => zoom == 0 ? 1.0 : 1.0 / zoom;

  bool get isShiftHeld => modifiers.contains(KeyModifier.shift);

  /// Ctrl - or Command, the Mac's: CorelDRAW's constraint key is the one
  /// the platform's shortcuts use.
  bool get isControlHeld =>
      modifiers.contains(KeyModifier.control) ||
      modifiers.contains(KeyModifier.meta);
  bool get isAltHeld => modifiers.contains(KeyModifier.alt);

  /// The object this tool just finished creating, consumed once.
  ///
  /// The controllers mutate the document directly because they have to draw
  /// while the pointer is down; handing the finished object back is what lets
  /// the *editor* record one undo entry for the whole gesture instead of one
  /// per pointer move.
  DocumentObject? _created;

  /// Takes and clears the object created by the gesture that just ended.
  DocumentObject? takeCreatedObject() {
    final created = _created;
    _created = null;
    return created;
  }

  /// Records [object] as this gesture's product.
  void reportCreated(DocumentObject object) => _created = object;

  void onPointerDown(Offset point, VectorPage page);
  void onPointerMove(Offset point, VectorPage page);
  void onPointerUp(Offset point, VectorPage page);
  void onCancel();

  /// The box a creation drag from [start] to [end] describes: Ctrl makes it
  /// square, Shift grows it from [start] as the centre - CorelDRAW's and
  /// Inkscape's modifiers for rectangles and ellipses.
  Rect dragBox(Offset start, Offset end) {
    var dx = end.dx - start.dx;
    var dy = end.dy - start.dy;
    if (isControlHeld) {
      final side = dx.abs() > dy.abs() ? dx.abs() : dy.abs();
      dx = dx < 0 ? -side : side;
      dy = dy < 0 ? -side : side;
    }
    if (isShiftHeld) {
      return Rect.fromLTRB(start.dx - dx.abs(), start.dy - dy.abs(),
          start.dx + dx.abs(), start.dy + dy.abs());
    }
    return Rect.fromPoints(start, Offset(start.dx + dx, start.dy + dy));
  }

  /// The layer the editor has chosen for new objects, if any - the one
  /// highlighted in a layers panel. Ignored when it is not on the page or
  /// cannot be drawn into.
  VectorLayer? preferredLayer;

  /// The editable layer of [page] a new object belongs on.
  VectorLayer targetLayer(VectorPage page) {
    final VectorLayer? preferred = preferredLayer;
    if (preferred != null &&
        identical(preferred.parent, page) &&
        preferred.isEditable &&
        preferred.isVisible) {
      return preferred;
    }
    return page.children.whereType<VectorLayer>().firstWhere(
        (layer) => layer.isEditable && layer.isVisible && !layer.isGuideLayer,
        orElse: () => page.children.whereType<VectorLayer>().first);
  }
}

// ---------------------------------------------------------------------------
// Select / Transform Tool Controller
// ---------------------------------------------------------------------------

/// What a select-tool drag is currently doing.
enum SelectDrag {
  /// The pointer is down but the gesture has not become a drag.
  none,

  /// Moving the selection.
  move,

  /// Scaling the selection from a handle.
  resize,

  /// Turning the selection about its pivot, or skewing it from an edge.
  rotate,

  /// Dragging the rotation pivot itself. Moves no artwork.
  pivot,

  /// Drawing a rubber band over the page.
  marquee,
}

/// sK1's SELECT, MOVE and RESIZE controllers, as one state machine.
///
/// sK1 splits these across three controller classes and switches the canvas
/// between them on hover (`SelectController` to `MoveController` to
/// `TransformController`). One class here, because the three differ only in
/// what the press landed on, and merging them removes the mode-switching that
/// most of the sK1 code is spent on.
///
/// What a press does, in the order the tests exercise:
///
///  1. **on a handle** - within [SelectionManager.handleGrabPixels] *screen*
///     pixels of one - resizes from the opposite corner;
///  2. **on an object**, with no Shift, selects it if it was not selected and
///     then moves the whole selection;
///  3. **anywhere else, or anywhere with Shift**, draws a rubber band.
///
/// Every drag is computed from the press point, never from the previous event,
/// and applied to a [SelectionTransaction] snapshot. That is what makes
/// dragging back to where you started restore the document exactly, and it is
/// what the old incremental code could not do.
class SelectToolController extends ToolController {
  SelectToolController({
    required super.doc,
    required super.methods,
    required super.selection,
    required super.snap,
  });

  Offset? _pressPoint;
  TransformHandle? _handle;
  SelectDrag _drag = SelectDrag.none;
  Rect? _marquee;
  SelectionTransaction? _transaction;
  SelectionEdit? _edit;

  /// The pivot as it was when a pivot drag started, so the drag is applied to
  /// the press state rather than accumulated - the same rule every other
  /// gesture here follows.
  Offset? _pivotAtPress;

  /// What the current drag is doing.
  SelectDrag get dragKind => _drag;

  /// The handle being dragged, for the cursor and for the canvas' feedback.
  TransformHandle? get activeHandle => _handle;

  /// The rubber band in progress, in document units, or null.
  Rect? get marquee => _marquee;

  /// Takes the undoable transform the gesture just finished, once.
  SelectionEdit? takeEdit() {
    final SelectionEdit? edit = _edit;
    _edit = null;
    return edit;
  }

  /// How close, in document units, a press has to be to an object.
  double get _objectTolerance => SelectionManager.objectGrabPixels * onePixel;

  /// A press and release with no drag in between.
  ///
  /// sK1 decides this by screen distance - `change_x < 5 and change_y < 5` in
  /// `SelectController.do_action` - and so does the canvas; by the time this
  /// is called the decision has been made.
  ///
  /// Shift toggles, which is sK1's `add(objs, xor=True)`: Shift+clicking a
  /// selected object takes it back out, so a mis-click can be corrected
  /// without starting the selection over.
  void click(Offset point, VectorPage page) {
    // Alt reaches *under* what is already selected, and each further Alt+click
    // takes the next object down the stack. Without it an object that is
    // completely covered can only be selected by moving the thing on top of
    // it - which means changing the drawing in order to select something in
    // it.
    if (isAltHeld) {
      final SelectableObject? below = selection.hitTestBelowSelection(
        point,
        page,
        tolerance: _objectTolerance,
      );
      if (below == null) {
        if (!isShiftHeld) selection.deselectAll();
        return;
      }
      selection.select(below, additive: isShiftHeld);
      return;
    }

    final SelectableObject? hit =
        selection.hitTest(point, page, tolerance: _objectTolerance);
    if (hit == null) {
      // Shift+clicking nothing keeps what is selected: the user is building a
      // selection and missed.
      if (!isShiftHeld) selection.deselectAll();
      return;
    }
    // The second click on something already selected swaps the scale frame for
    // the rotate one, and a third swaps it back. Not with Shift, which is
    // building a selection rather than working on one - toggling the frame
    // there would fight the toggle Shift already means.
    if (!isShiftHeld && selection.contains(hit)) {
      selection.toggleHandleMode();
      return;
    }
    selection.select(hit, additive: isShiftHeld);
  }

  /// The object under [point], for the canvas' double-click and cursor logic.
  SelectableObject? objectAt(Offset point, VectorPage page) =>
      selection.hitTest(point, page, tolerance: _objectTolerance);

  @override
  void onPointerDown(Offset point, VectorPage page) {
    lastPoint = point;
    _pressPoint = point;
    _edit = null;
    _marquee = null;

    final TransformHandle? handle = selection.hitTestHandle(
      point,
      tolerance: SelectionManager.handleGrabPixels * onePixel,
    );
    if (handle == TransformHandle.rotationCenter) {
      _handle = handle;
      _drag = SelectDrag.pivot;
      _pivotAtPress = selection.pivot;
      return;
    }
    if (handle != null) {
      _handle = handle;
      _drag = selection.handleMode == SelectionHandleMode.rotate
          ? SelectDrag.rotate
          : SelectDrag.resize;
      // The pivot is read once, here, and held for the whole gesture. Reading
      // it per move would read `selectionBounds.center` of a box that the
      // previous move already rotated, and the box of a rotating asymmetric
      // shape has a centre that wanders - so the turn would depend on how many
      // pointer events the platform happened to deliver.
      _pivotAtPress = selection.pivot;
      _transaction = selection.beginTransform();
      return;
    }
    _handle = null;

    final SelectableObject? hit =
        selection.hitTest(point, page, tolerance: _objectTolerance);
    // Shift over an object still means "band select": sK1's MoveController
    // hands the gesture straight back to SELECT_MODE when Shift is down.
    if (hit != null && !isShiftHeld) {
      // An object already in the selection keeps the rest of it, so a
      // multi-object selection can be dragged as a unit.
      if (!selection.contains(hit)) selection.select(hit);
      _drag = SelectDrag.move;
      _transaction = selection.beginTransform();
      return;
    }

    _drag = SelectDrag.marquee;
    _marquee = Rect.fromPoints(point, point);
  }

  @override
  void onPointerMove(Offset point, VectorPage page) {
    lastPoint = point;
    final Offset? press = _pressPoint;
    if (press == null) return;
    Offset delta = point - press;

    switch (_drag) {
      case SelectDrag.move:
        // Ctrl constrains to one axis, which is sK1's MoveController rule.
        if (isControlHeld) {
          delta = delta.dx.abs() >= delta.dy.abs()
              ? Offset(delta.dx, 0)
              : Offset(0, delta.dy);
        }
        final SelectionTransaction? moving = _transaction;
        if (moving == null) return;
        // The snap corrects the *box*, not the pointer: the box as this delta
        // would leave it is offered to the snap, and whatever nudge comes back
        // is folded into the delta before anything is applied. That is why the
        // object lands on the grid line instead of jumping by however far
        // inside it the user happened to grab it.
        delta += _snapCorrection(moving.startBounds.shift(delta), page, null);
        moving.apply(<double>[1, 0, 0, 1, delta.dx, delta.dy]);
      case SelectDrag.resize:
        final SelectionTransaction? transaction = _transaction;
        final TransformHandle? handle = _handle;
        if (transaction == null || handle == null) return;
        // Snapped the same way, but only on the edges this handle drags: a
        // resize that nudged its anchored edge would not be a resize. The
        // probe is the transform this delta would give, so the snap is offered
        // the box the user is about to see rather than the one they started
        // from.
        final List<double>? probe = selection.trafoForHandle(
          handle,
          transaction.startBounds,
          delta,
          proportional: isShiftHeld,
          aboutCentre: isControlHeld,
        );
        if (probe != null) {
          // Applied and *measured*, not predicted. Transforming the start box
          // is a point off: an object's bounding box includes half its stroke
          // width, and a stroke does not scale with the geometry, so the box a
          // scale actually produces is not the scaled box. The transaction
          // resets before every apply, so asking it and then asking again with
          // the corrected delta costs one extra apply and is exact.
          transaction.apply(probe);
          delta += _snapCorrection(selection.selectionBounds, page, handle);
        }
        final List<double>? trafo = selection.trafoForHandle(
          handle,
          transaction.startBounds,
          delta,
          proportional: isShiftHeld,
          aboutCentre: isControlHeld,
        );
        if (trafo != null) transaction.apply(trafo);
      case SelectDrag.rotate:
        final SelectionTransaction? transaction = _transaction;
        final TransformHandle? handle = _handle;
        if (transaction == null || handle == null) return;
        final List<double>? trafo = selection.trafoForRotateHandle(
          handle,
          transaction.startBounds,
          _pivotAtPress ?? selection.pivot,
          press,
          point,
          // Ctrl turns in 15 degree steps, as CorelDRAW does; Shift too, as
          // Inkscape and Illustrator do.
          constrain: isControlHeld || isShiftHeld,
        );
        if (trafo != null) transaction.apply(trafo);
      case SelectDrag.pivot:
        final Offset? start = _pivotAtPress;
        if (start == null) return;
        final Offset moved = start + delta;
        final Rect asPoint =
            Rect.fromLTRB(moved.dx, moved.dy, moved.dx, moved.dy);
        selection.rotationPivot = moved + _snapCorrection(asPoint, page, null);
      case SelectDrag.marquee:
        _marquee = Rect.fromPoints(press, point);
      case SelectDrag.none:
        break;
    }
  }

  /// The snap nudge for [bounds], or zero when nothing is near enough.
  ///
  /// Whether it fires at all is the [SnapManager]'s own `snapToGrid` /
  /// `snapToGuides`, which is what the editor's Snap switch already sets -
  /// a second switch here would be a second thing to turn off.
  ///
  /// The tolerance is a *screen* distance divided by the zoom, for the reason
  /// every tolerance in this file is: a magnet measured in document units is
  /// too weak to fire when zoomed out and too strong to escape when zoomed in.
  Offset _snapCorrection(
    Rect bounds,
    VectorPage page,
    TransformHandle? handle,
  ) {
    return snap.correctionFor(
      bounds,
      page,
      edges: SnapManager.edgesForHandle(handle),
      tolerance: SnapManager.dragPixels * onePixel,
    );
  }

  @override
  void onPointerUp(Offset point, VectorPage page) {
    switch (_drag) {
      case SelectDrag.marquee:
        final Rect? band = _marquee;
        if (band != null) {
          // sK1's rule and sK1's modifier: enclosure by default,
          // `is_bbox_overlap` when Alt or Ctrl is held.
          final MarqueeRule rule = isControlHeld || isAltHeld
              ? MarqueeRule.touched
              : MarqueeRule.enclosed;
          final List<SelectableObject> caught =
              selection.objectsIn(band, page, rule: rule);
          if (isShiftHeld) {
            selection.addAll(caught);
          } else {
            selection.setSelection(caught);
          }
        }
      case SelectDrag.move:
      case SelectDrag.resize:
      case SelectDrag.rotate:
        _edit = _transaction?.commit();
      case SelectDrag.pivot:
        // Moving the pivot changes no artwork, so there is nothing to undo -
        // and pushing an entry for it would stop Ctrl+Z meaning "undo the last
        // change to the drawing".
        break;
      case SelectDrag.none:
        break;
    }
    _drag = SelectDrag.none;
    _handle = null;
    _marquee = null;
    _transaction = null;
    _pressPoint = null;
    _pivotAtPress = null;
    doc.update();
  }

  @override
  void onCancel() {
    // A cancelled gesture puts the document back where the press found it,
    // which is free now that the press state is a snapshot.
    _transaction?.reset();
    if (_drag == SelectDrag.pivot) selection.rotationPivot = _pivotAtPress;
    _drag = SelectDrag.none;
    _handle = null;
    _marquee = null;
    _transaction = null;
    _pressPoint = null;
    _pivotAtPress = null;
    _edit = null;
  }
}

// ---------------------------------------------------------------------------
// Rectangle Creator Tool
// ---------------------------------------------------------------------------

class RectangleToolController extends ToolController {
  RectangleToolController({
    required super.doc,
    required super.methods,
    required super.selection,
    required super.snap,
  });

  Offset? _startPoint;
  VectorRectangle? _currentRect;

  @override
  void onPointerDown(Offset point, VectorPage page) {
    final snapped = snap.snapPoint(point, page);
    _startPoint = snapped;

    lastPoint = snapped;
    final layer = targetLayer(page);
    _currentRect = methods.createRectangle(
      x: snapped.dx,
      y: snapped.dy,
      width: 1.0,
      height: 1.0,
    );
    methods.addObject(layer, _currentRect!);
    selection.select(_currentRect!);
  }

  @override
  void onPointerMove(Offset point, VectorPage page) {
    if (_startPoint == null || _currentRect == null) return;
    lastPoint = point;
    final Rect box = dragBox(_startPoint!, snap.snapPoint(point, page));
    _currentRect!.startX = box.left;
    _currentRect!.startY = box.top;
    _currentRect!.rectWidth = box.width.clamp(1.0, double.infinity);
    _currentRect!.rectHeight = box.height.clamp(1.0, double.infinity);
    _currentRect!.update();
  }

  @override
  void onPointerUp(Offset point, VectorPage page) {
    final rect = _currentRect;
    if (rect != null) reportCreated(rect);
    _startPoint = null;
    _currentRect = null;
    doc.update();
  }

  @override
  void onCancel() {
    if (_currentRect != null) {
      methods.removeObject(_currentRect!);
      _currentRect = null;
    }
    _startPoint = null;
  }
}

// ---------------------------------------------------------------------------
// Circle / Ellipse Creator Tool
// ---------------------------------------------------------------------------

class CircleToolController extends ToolController {
  CircleToolController({
    required super.doc,
    required super.methods,
    required super.selection,
    required super.snap,
  });

  Offset? _startPoint;
  VectorCircle? _currentCircle;

  @override
  void onPointerDown(Offset point, VectorPage page) {
    final snapped = snap.snapPoint(point, page);
    _startPoint = snapped;

    lastPoint = snapped;
    final layer = targetLayer(page);
    _currentCircle = methods.createCircle(
      cx: snapped.dx,
      cy: snapped.dy,
      rx: 1.0,
      ry: 1.0,
    );
    methods.addObject(layer, _currentCircle!);
    selection.select(_currentCircle!);
  }

  @override
  void onPointerMove(Offset point, VectorPage page) {
    if (_startPoint == null || _currentCircle == null) return;
    lastPoint = point;
    final Rect box = dragBox(_startPoint!, snap.snapPoint(point, page));
    // The unit circle fills (0,0)-(1,1): size and top-left corner.
    _currentCircle!.trafo = <double>[
      box.width.clamp(1.0, double.infinity),
      0.0,
      0.0,
      box.height.clamp(1.0, double.infinity),
      box.left,
      box.top,
    ];
    _currentCircle!.initialTrafo = List<double>.of(_currentCircle!.trafo);
    _currentCircle!.update();
  }

  @override
  void onPointerUp(Offset point, VectorPage page) {
    final circle = _currentCircle;
    if (circle != null) reportCreated(circle);
    _startPoint = null;
    _currentCircle = null;
    doc.update();
  }

  @override
  void onCancel() {
    if (_currentCircle != null) {
      methods.removeObject(_currentCircle!);
      _currentCircle = null;
    }
    _startPoint = null;
  }
}

// ---------------------------------------------------------------------------
// Pen / Bézier Tool
// ---------------------------------------------------------------------------

/// CorelDRAW's Bézier tool and Inkscape's pen, as one controller.
///
///  * **click** places a corner node;
///  * **press and drag** places a smooth node whose handles follow the drag -
///    the outgoing handle under the pointer, the incoming one mirrored;
///  * a **rubber segment** follows the pointer from the last node
///    ([onHover]), so the next segment is visible before it is placed;
///  * **clicking the first node** closes the path and finishes it;
///  * **Enter**, a **double click** or changing tool finish it open
///    ([finish]); **Escape** abandons it ([onCancel]).
///
/// The curve lives in the document while it is drawn, so it renders with
/// everything else; [finish] reports it once, as one created object - one
/// undo step for the whole path.
class CurveToolController extends ToolController {
  CurveToolController({
    required super.doc,
    required super.methods,
    required super.selection,
    required super.snap,
  });

  /// How close, in screen pixels, a click must be to the first node to
  /// close the path.
  static const double closePixels = 7.0;

  VectorCurve? _curve;
  VectorPath? _path;

  /// Whether the path's last point is the rubber segment, not a placed one.
  bool _rubber = false;

  /// The outgoing handle of the last placed node, when it is smooth.
  Offset? _handleOut;

  /// The node the current press placed, for the drag that shapes it.
  Offset? _pressNode;

  /// Whether a path is being drawn.
  bool get isDrawing => _curve != null;

  Offset get _lastNode {
    final VectorPath path = _path!;
    final int placed = path.points.length - (_rubber ? 1 : 0);
    if (placed == 0) return path.start;
    return _endOf(path.points[placed - 1]);
  }

  static Offset _endOf(Object segment) =>
      segment is CurvePoint ? segment.endpoint : segment as Offset;

  int get _placedSegments =>
      _path == null ? 0 : _path!.points.length - (_rubber ? 1 : 0);

  void _dropRubber() {
    if (_rubber) {
      _path!.points.removeLast();
      _rubber = false;
    }
  }

  /// The segment from the last node to [end], honouring a smooth node's
  /// outgoing handle.
  Object _segmentTo(Offset end, {Offset? control2}) {
    final Offset? out = _handleOut;
    if (out == null && control2 == null) return end;
    return CurvePoint(out ?? _lastNode, control2 ?? end, end);
  }

  /// Moves the rubber segment's end to [point].
  void onHover(Offset point, VectorPage page) {
    final VectorPath? path = _path;
    if (path == null) return;
    final Offset snapped = snap.snapPoint(point, page);
    lastPoint = snapped;
    final Object segment = _segmentTo(snapped);
    if (_rubber) {
      path.points.last = segment;
    } else {
      path.points.add(segment);
      _rubber = true;
    }
    _curve!.update();
  }

  @override
  void onPointerDown(Offset point, VectorPage page) {
    final Offset snapped = snap.snapPoint(point, page);
    lastPoint = snapped;
    final VectorPath? path = _path;
    if (path == null) {
      final VectorPath first = VectorPath(start: snapped);
      _path = first;
      _curve = VectorCurve(paths: <VectorPath>[first], style: doc.defaultStyle);
      methods.addObject(targetLayer(page), _curve!);
      selection.select(_curve!);
      _handleOut = null;
      _pressNode = snapped;
      _curve!.update();
      return;
    }
    _dropRubber();
    final double tolerance = closePixels * onePixel;
    // A second click on the node just placed is the double click that ends
    // the path; it must not add a zero-length segment.
    if (_placedSegments > 0 && (snapped - _lastNode).distance <= tolerance) {
      _pressNode = null;
      finish();
      return;
    }
    if (_placedSegments >= 2 && (snapped - path.start).distance <= tolerance) {
      path.points.add(_segmentTo(path.start));
      path.closure = PathClosure.closed;
      _pressNode = null;
      finish();
      return;
    }
    path.points.add(_segmentTo(snapped));
    _handleOut = null;
    _pressNode = snapped;
    _curve!.update();
  }

  @override
  void onPointerMove(Offset point, VectorPage page) {
    final Offset? node = _pressNode;
    final VectorPath? path = _path;
    if (node == null || path == null) return;
    lastPoint = point;
    // Dragging out of a node shapes it: the handle under the pointer leads
    // into the next segment, its mirror shapes the one just placed.
    final Offset out = point;
    final Offset into = node * 2 - point;
    _handleOut = out;
    if (path.points.isNotEmpty) {
      final Object last = path.points.last;
      final Offset previous = path.points.length >= 2
          ? _endOf(path.points[path.points.length - 2])
          : path.start;
      path.points.last = last is CurvePoint
          ? CurvePoint(last.control1, into, node, NodeType.symmetrical)
          : CurvePoint(previous, into, node, NodeType.symmetrical);
    }
    _curve!.update();
  }

  @override
  void onPointerUp(Offset point, VectorPage page) {
    _pressNode = null;
  }

  /// Ends the path where it is. A path with no segment is removed rather
  /// than left as an invisible dot.
  void finish() {
    final VectorCurve? curve = _curve;
    if (curve == null) return;
    _dropRubber();
    if (_placedSegments == 0) {
      methods.removeObject(curve);
      selection.deselectAll();
    } else {
      curve.update();
      reportCreated(curve);
    }
    _curve = null;
    _path = null;
    _handleOut = null;
    _pressNode = null;
    doc.update();
  }

  @override
  void onCancel() {
    final VectorCurve? curve = _curve;
    if (curve != null) {
      methods.removeObject(curve);
      selection.deselectAll();
    }
    _curve = null;
    _path = null;
    _rubber = false;
    _handleOut = null;
    _pressNode = null;
  }
}

// ---------------------------------------------------------------------------
// Polygon / Star Creator Tool
// ---------------------------------------------------------------------------

/// Drags out a regular polygon, centred on the press point.
///
/// sK1 takes the corner count from a config plugin on the property bar rather
/// than from the drag, so [corners] is a parameter and not a gesture.
class PolygonToolController extends ToolController {
  PolygonToolController({
    required super.doc,
    required super.methods,
    required super.selection,
    required super.snap,
    this.corners = 5,
  });

  /// Corners of the next polygon; the canvas keeps it current with the
  /// property bar, so a change applies to the very next drag.
  int corners;

  Offset? _centre;
  VectorPolygon? _current;

  @override
  void onPointerDown(Offset point, VectorPage page) {
    final snapped = snap.snapPoint(point, page);
    _centre = snapped;
    lastPoint = snapped;
    _current = methods.createPolygon(
      cx: snapped.dx,
      cy: snapped.dy,
      radius: 1.0,
      cornersNum: corners.clamp(3, 1000),
    );
    methods.addObject(targetLayer(page), _current!);
    selection.select(_current!);
  }

  @override
  void onPointerMove(Offset point, VectorPage page) {
    final centre = _centre;
    final polygon = _current;
    if (centre == null || polygon == null) return;
    lastPoint = point;
    final radius = (snap.snapPoint(point, page) - centre)
        .distance
        .clamp(1.0, double.infinity);
    // The unit polygon is centred on (0.5, 0.5).
    polygon.trafo = <double>[
      radius * 2,
      0.0,
      0.0,
      radius * 2,
      centre.dx - radius,
      centre.dy - radius,
    ];
    polygon.initialTrafo = List<double>.of(polygon.trafo);
    polygon.update();
  }

  @override
  void onPointerUp(Offset point, VectorPage page) {
    final polygon = _current;
    if (polygon != null) reportCreated(polygon);
    _centre = null;
    _current = null;
    doc.update();
  }

  @override
  void onCancel() {
    final polygon = _current;
    if (polygon != null) methods.removeObject(polygon);
    _centre = null;
    _current = null;
  }
}

// ---------------------------------------------------------------------------
// Text Creator Tool
// ---------------------------------------------------------------------------

/// Drops an artistic text object where the canvas is clicked.
///
/// The framework has no in-canvas text caret yet, so this creates a placeholder
/// string and selects it; the property bar edits the content. That is a
/// deliberate divergence from sK1's TEXT_EDIT_MODE, recorded rather than hidden.
class TextToolController extends ToolController {
  TextToolController({
    required super.doc,
    required super.methods,
    required super.selection,
    required super.snap,
    this.placeholder = 'Text',
  });

  final String placeholder;

  @override
  void onPointerDown(Offset point, VectorPage page) {
    lastPoint = point;
    final text = methods.createText(
      text: placeholder,
      x: point.dx,
      y: point.dy,
    );
    methods.addObject(targetLayer(page), text);
    selection.select(text);
    reportCreated(text);
  }

  @override
  void onPointerMove(Offset point, VectorPage page) => lastPoint = point;

  @override
  void onPointerUp(Offset point, VectorPage page) => doc.update();

  @override
  void onCancel() {}
}
