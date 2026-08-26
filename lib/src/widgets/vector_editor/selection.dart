/// Selection management and interactive transform handles for the vector
/// editor.
///
/// Three rules here were wrong, and each of them broke a gesture the user could
/// see:
///
///  * **a handle was grabbable within six *document* units.** At the zoom the
///    editor opens at that is a target smaller than the handle drawn on top of
///    it, and at 20% zoom the handle was a 30-pixel-wide square with a 1-pixel
///    hot spot. A handle is a *screen* affordance and its tolerance has to be a
///    screen distance divided by the zoom - which is exactly how sK1 sizes its
///    own markers, `config.sel_marker_size / (2.0 * canvas.zoom)`.
///  * **a drag accumulated.** Each pointer move applied the delta since the
///    previous move on top of whatever the previous moves had already done, so
///    every rounding error stayed in the document and a resize past its own
///    anchor could not be undone by dragging back. A gesture is now applied
///    against a snapshot taken when the pointer went down - see
///    [SelectionTransaction] - so the document only ever holds
///    *press-state + total delta*.
///  * **the selection could only ever hold what the last click hit.** There was
///    no additive mode reaching it, no rectangle selection and no way to build
///    the multi-object selection that Group needs.
library;

import 'dart:math' as math;

import '../../geometry/offset.dart';
import '../../geometry/path.dart';
import '../../geometry/rect.dart';
import '../../graphics/vector/bezier.dart';
import '../../graphics/vector/primitives.dart';
import '../../graphics/vector/selectable_objects.dart';
import '../../graphics/vector/structural_objects.dart';

/// Types of interactive transform handles.
enum TransformHandle {
  topLeft,
  topCenter,
  topRight,
  midRight,
  bottomRight,
  bottomCenter,
  bottomLeft,
  midLeft,
  rotationCenter,
}

/// What the eight handles around the selection currently do.
///
/// The two-state frame is CorelDRAW's, and sK1 copies it (`trafo_ctrl.py`
/// keeps markers 1-8 for one mode and 9-17 for the other): the first click
/// selects and gives you a *scale* frame, and clicking the same object again
/// swaps that frame for a *rotate* one, where the corners turn the object and
/// the edge handles skew it. It matters because it doubles the number of
/// transforms a mouse can reach without going anywhere near a menu, and
/// because the second frame is where the pivot lives - the thing rotation is
/// actually about, which no scale frame has a use for.
enum SelectionHandleMode {
  /// Corners and edges scale, anchored opposite. The mode a fresh selection
  /// is in.
  scale,

  /// Corners rotate about the pivot, edges skew, and the pivot itself is a
  /// ninth handle that can be dragged anywhere.
  rotate;

  SelectionHandleMode get toggled => this == SelectionHandleMode.scale
      ? SelectionHandleMode.rotate
      : SelectionHandleMode.scale;
}

/// How a rubber band decides what it caught.
///
/// sK1's rule, in `Selection.select_by_rect`: `is_bbox_in_rect` by default and
/// `is_bbox_overlap` when Alt or Ctrl is held. [enclosed] is therefore the
/// default here too, because the reference this editor follows is sK1.
enum MarqueeRule {
  /// Only objects wholly inside the band. sK1's `is_bbox_in_rect`.
  enclosed,

  /// Any object the band touches. sK1's `is_bbox_overlap`, its Alt/Ctrl mode.
  touched,
}

/// One interactive transform, applied against the state the gesture started in.
///
/// The contract is the whole point: [apply] always restores the snapshot first
/// and then applies **one** transform describing the entire gesture so far. A
/// controller therefore computes "where is the pointer now, relative to where
/// it pressed", never "how far did it move since the last event". Drift, and
/// the un-undoable half-resize that comes with it, are impossible by
/// construction rather than by care.
final class SelectionTransaction {
  SelectionTransaction(List<SelectableObject> objects)
      : objects = List<SelectableObject>.unmodifiable(objects),
        _before = <TrafoSnapshot>[
          for (final SelectableObject object in objects)
            object.getTrafoSnapshot(),
        ],
        startBounds = _boundsOf(objects);

  /// The objects this gesture moves, in selection order.
  final List<SelectableObject> objects;

  /// The union of the objects' boxes when the pointer went down.
  ///
  /// Held rather than recomputed: a resize changes the bounds it is derived
  /// from, so reading them live would make each move measure against the
  /// previous one - the accumulation this class exists to prevent.
  final Rect startBounds;

  final List<TrafoSnapshot> _before;

  bool get isEmpty => objects.isEmpty;

  /// Puts every object back exactly as it was when the gesture started.
  void reset() {
    for (final TrafoSnapshot snapshot in _before) {
      snapshot.object.setTrafoSnapshot(snapshot);
    }
  }

  /// Sets the document to *press state, then [trafo]*.
  void apply(List<double> trafo) {
    reset();
    for (final SelectableObject object in objects) {
      object.applyTrafo(trafo);
    }
  }

  /// The before/after pair for the undo stack, or null when nothing moved.
  ///
  /// Null rather than an empty edit so a click that merely selected something
  /// does not push a "Transform" entry the user then has to undo twice.
  SelectionEdit? commit() {
    final List<TrafoSnapshot> after = <TrafoSnapshot>[
      for (final SelectableObject object in objects) object.getTrafoSnapshot(),
    ];
    var moved = false;
    for (var i = 0; i < after.length; i++) {
      if (!_sameTrafo(_before[i].trafo, after[i].trafo)) {
        moved = true;
        break;
      }
    }
    if (!moved) return null;
    return SelectionEdit(before: _before, after: after);
  }

  static bool _sameTrafo(List<double> a, List<double> b) {
    for (var i = 0; i < 6; i++) {
      if ((a[i] - b[i]).abs() > 1e-12) return false;
    }
    return true;
  }

  static Rect _boundsOf(List<SelectableObject> objects) {
    Rect bounds = Rect.zero;
    for (final SelectableObject object in objects) {
      final Rect box = object.cacheBbox;
      if (box == Rect.zero) continue;
      bounds = bounds == Rect.zero ? box : bounds.union(box);
    }
    return bounds;
  }
}

/// A completed interactive transform, ready for an undo stack.
final class SelectionEdit {
  const SelectionEdit({required this.before, required this.after});

  final List<TrafoSnapshot> before;
  final List<TrafoSnapshot> after;

  /// The objects this edit touched.
  Iterable<SelectableObject> get objects =>
      before.map((TrafoSnapshot snapshot) => snapshot.object);

  void undo() {
    for (final TrafoSnapshot snapshot in before) {
      snapshot.object.setTrafoSnapshot(snapshot);
    }
  }

  void redo() {
    for (final TrafoSnapshot snapshot in after) {
      snapshot.object.setTrafoSnapshot(snapshot);
    }
  }
}

/// Manages the set of selected objects in the active document.
class SelectionManager {
  final List<SelectableObject> _selectedObjects = [];

  /// How close, **in device pixels**, a press has to be to a handle.
  ///
  /// Pixels, not points: the handle is drawn 7 px across whatever the zoom, so
  /// its target has to be 7-ish px too. Callers divide by the zoom to get the
  /// document-space tolerance [hitTestHandle] wants - which is what sK1 does
  /// with `config.sel_marker_size / (2.0 * canvas.zoom)`.
  static const double handleGrabPixels = 7.0;

  /// How close, in device pixels, a press has to be to an object's box.
  ///
  /// A hairline object is otherwise a one-pixel target. sK1 pads a degenerate
  /// bbox by 4 window pixels for the same reason.
  static const double objectGrabPixels = 4.0;

  /// Whether the frame currently scales or rotates. See
  /// [SelectionHandleMode].
  ///
  /// Reset to [SelectionHandleMode.scale] whenever the selection is *replaced*,
  /// because "click the thing again to rotate it" has to mean the thing you
  /// clicked twice, not whatever happened to be selected when you clicked
  /// something else.
  SelectionHandleMode handleMode = SelectionHandleMode.scale;

  /// Where rotation turns about, or null for the centre of the box.
  ///
  /// Null rather than an eagerly computed centre so the pivot follows the
  /// selection until the user drags it somewhere, and only then stops.
  Offset? rotationPivot;

  /// The point rotation actually turns about.
  Offset get pivot => rotationPivot ?? selectionBounds.center;

  /// The list of currently selected objects.
  List<SelectableObject> get selectedObjects =>
      List.unmodifiable(_selectedObjects);

  /// Whether any objects are selected.
  bool get hasSelection => _selectedObjects.isNotEmpty;

  /// Number of selected objects.
  int get count => _selectedObjects.length;

  /// Whether [obj] is part of the current selection.
  bool contains(SelectableObject obj) =>
      _selectedObjects.any((SelectableObject item) => identical(item, obj));

  /// Combined bounding box of all selected objects.
  Rect get selectionBounds {
    if (_selectedObjects.isEmpty) return Rect.zero;

    var bounds = _selectedObjects.first.cacheBbox;
    for (var i = 1; i < _selectedObjects.length; i++) {
      final b = _selectedObjects[i].cacheBbox;
      if (bounds == Rect.zero) {
        bounds = b;
      } else if (b != Rect.zero) {
        bounds = Rect.fromLTRB(
          bounds.left < b.left ? bounds.left : b.left,
          bounds.top < b.top ? bounds.top : b.top,
          bounds.right > b.right ? bounds.right : b.right,
          bounds.bottom > b.bottom ? bounds.bottom : b.bottom,
        );
      }
    }
    return bounds;
  }

  /// Selects [obj]. If [additive] is true, toggles selection; otherwise
  /// replaces it.
  void select(SelectableObject obj, {bool additive = false}) {
    if (!additive) {
      final bool same = _selectedObjects.length == 1 &&
          identical(_selectedObjects.first, obj);
      _selectedObjects
        ..clear()
        ..add(obj);
      if (!same) _resetFrame();
      return;
    }
    toggle(obj);
    _resetFrame();
  }

  /// Puts the frame back into scale mode with the pivot at the box centre.
  void _resetFrame() {
    handleMode = SelectionHandleMode.scale;
    rotationPivot = null;
  }

  /// Swaps the scale frame for the rotate frame, or back.
  ///
  /// The second click on an object that is already selected. Named rather than
  /// assigned so the one place that decides "this click was the second one"
  /// reads as the gesture it is.
  void toggleHandleMode() {
    handleMode = handleMode.toggled;
    if (handleMode == SelectionHandleMode.scale) rotationPivot = null;
  }

  /// Adds [obj] when it is out, removes it when it is in.
  ///
  /// sK1's `add(objs, xor=True)`, which is what Shift+click calls. Toggling
  /// rather than only adding is why Shift+clicking a selected object takes it
  /// back out - the behaviour every editor has and the one users reach for to
  /// correct a mis-click without starting over.
  void toggle(SelectableObject obj) {
    final int index =
        _selectedObjects.indexWhere((SelectableObject i) => identical(i, obj));
    if (index >= 0) {
      _selectedObjects.removeAt(index);
    } else {
      _selectedObjects.add(obj);
    }
  }

  /// Replaces the selection with [objects].
  void setSelection(Iterable<SelectableObject> objects) {
    _selectedObjects
      ..clear()
      ..addAll(objects);
    _resetFrame();
  }

  /// Adds [objects], skipping ones already selected.
  void addAll(Iterable<SelectableObject> objects) {
    for (final SelectableObject object in objects) {
      if (!contains(object)) _selectedObjects.add(object);
    }
    _resetFrame();
  }

  /// Selects all objects on the active [page].
  void selectAll(VectorPage page) {
    _resetFrame();
    _selectedObjects.clear();
    for (final layer in page.children.whereType<VectorLayer>()) {
      if (layer.isEditable) {
        for (final child in layer.children.whereType<SelectableObject>()) {
          _selectedObjects.add(child);
        }
      }
    }
  }

  /// Clears the selection.
  void deselectAll() {
    _selectedObjects.clear();
    _resetFrame();
  }

  /// Hit-tests a point against objects on [page] (topmost object first).
  ///
  /// [tolerance] is in document units and is what a caller converts a few
  /// screen pixels into: a hairline shape is otherwise unclickable at low zoom.
  ///
  /// The test is against the object's **outline**, not its bounding box. That
  /// distinction is the whole difference between clicking a star and clicking
  /// the square it happens to fit in: the gaps between a five-pointed star's
  /// points are more than half of its bounding box, and every click in one of
  /// them used to select the star. A filled object is hit anywhere its fill
  /// would be painted (non-zero winding over the flattened contours); an
  /// unfilled or open one is hit within [tolerance] of its outline, plus half
  /// its own stroke width, so a hairline curve stays as grabbable as it was.
  ///
  /// Objects with no geometry - text, and anything the flattener returns
  /// nothing for - fall back to the box, which for a text run *is* its shape.
  SelectableObject? hitTest(
    Offset point,
    VectorPage page, {
    double tolerance = 0,
  }) {
    final List<SelectableObject> stack =
        hitTestStack(point, page, tolerance: tolerance);
    return stack.isEmpty ? null : stack.first;
  }

  /// Every object under [point], topmost first.
  ///
  /// The list Alt+click walks. One click takes the top of it, and each
  /// subsequent Alt+click takes the next one down - which is the only way to
  /// reach an object that is completely covered without hiding or moving the
  /// thing on top of it. CorelDRAW and Inkscape both bind exactly this.
  List<SelectableObject> hitTestStack(
    Offset point,
    VectorPage page, {
    double tolerance = 0,
  }) {
    final List<SelectableObject> found = <SelectableObject>[];
    final layers = page.children.whereType<VectorLayer>().toList();

    // Layers top-to-bottom, and objects within a layer likewise, so the list
    // is in exactly the order a click walks down through the drawing.
    for (var i = layers.length - 1; i >= 0; i--) {
      final layer = layers[i];
      if (!layer.isVisible || !layer.isEditable) continue;

      for (var j = layer.children.length - 1; j >= 0; j--) {
        final obj = layer.children[j];
        if (obj is! SelectableObject) continue;
        if (hits(obj, point, tolerance)) found.add(obj);
      }
    }
    return found;
  }

  /// The object an Alt+click should reach next, given what is selected now.
  ///
  /// Walks *down* the stack from whatever is selected and wraps at the bottom,
  /// so repeated Alt+clicks in one spot cycle through everything under the
  /// pointer and come back round. Returns null when nothing is there at all.
  SelectableObject? hitTestBelowSelection(
    Offset point,
    VectorPage page, {
    double tolerance = 0,
  }) {
    final List<SelectableObject> stack =
        hitTestStack(point, page, tolerance: tolerance);
    if (stack.isEmpty) return null;
    for (var i = 0; i < stack.length; i++) {
      if (contains(stack[i])) return stack[(i + 1) % stack.length];
    }
    return stack.first;
  }

  /// Whether [object] is under [point], within [tolerance] document units.
  static bool hits(SelectableObject object, Offset point, double tolerance) {
    // The box is the cheap rejection, and it is exact for the objects that
    // have no contours to test.
    if (!object.cacheBbox.inflate(tolerance).contains(point)) return false;
    return _outlineHits(object, point, tolerance) ?? true;
  }

  /// Whether [point] is inside or on [object]'s real outline.
  ///
  /// Null means "this object cannot answer" - no contours came back - and the
  /// caller falls back to the box.
  static bool? _outlineHits(
    SelectableObject object,
    Offset point,
    double tolerance,
  ) {
    if (object is VectorGroup) {
      // A group is hit where one of its members is hit, not across the
      // rectangle that spans them: two shapes at opposite corners of a page
      // make a group whose box is the page.
      var answered = false;
      for (final child in object.children) {
        if (child is! SelectableObject) continue;
        if (!child.cacheBbox.inflate(tolerance).contains(point)) {
          answered = true;
          continue;
        }
        final bool? hit = _outlineHits(child, point, tolerance);
        if (hit == null) return null;
        if (hit) return true;
        answered = true;
      }
      return answered ? false : null;
    }
    if (object is! PrimitiveObject) return null;
    final List<VectorPath>? paths = object.cachePaths;
    if (paths == null || paths.isEmpty) return null;

    final Path path = pathFromVectorPaths(paths, object.trafo);
    if (path.isEmpty) return null;
    final FlattenedPath flat = path.flatten(_flattenTolerance);
    if (flat.contourCount == 0) return null;

    final bool filled = !object.style.fill.isNone;
    if (filled && _windingContains(flat, point)) return true;

    // The outline itself, always: the edge of a filled shape is grabbable too,
    // and it is the only thing an unfilled one offers.
    final double stroke =
        object.style.stroke.isNone ? 0.0 : object.style.stroke.width / 2;
    return _nearOutline(flat, point, tolerance + stroke);
  }

  /// How finely a contour is flattened before a point is tested against it.
  ///
  /// A quarter of a document unit: below the tolerance a click already
  /// carries, so the flattening error cannot be what decides a hit.
  static const double _flattenTolerance = 0.25;

  /// Non-zero winding, the same rule the filler uses.
  ///
  /// The same rule matters more than which rule: a hit test that used even-odd
  /// against a filler that uses non-zero would disagree with the picture
  /// exactly where the two rules differ, which is inside every
  /// self-overlapping shape.
  static bool _windingContains(FlattenedPath flat, Offset point) {
    var winding = 0;
    for (var c = 0; c < flat.contourCount; c++) {
      final int start = flat.contourStarts[c];
      final int end = flat.contourStarts[c + 1];
      if (end - start < 2) continue;
      for (var i = start; i < end; i++) {
        final int next = i + 1 == end ? start : i + 1;
        final double x0 = flat.pointX(i);
        final double y0 = flat.pointY(i);
        final double x1 = flat.pointX(next);
        final double y1 = flat.pointY(next);
        if (y0 <= point.dy) {
          if (y1 > point.dy && _isLeft(x0, y0, x1, y1, point) > 0) winding++;
        } else {
          if (y1 <= point.dy && _isLeft(x0, y0, x1, y1, point) < 0) winding--;
        }
      }
    }
    return winding != 0;
  }

  static double _isLeft(double x0, double y0, double x1, double y1, Offset p) =>
      (x1 - x0) * (p.dy - y0) - (p.dx - x0) * (y1 - y0);

  /// Whether [point] is within [tolerance] of any flattened segment.
  static bool _nearOutline(
    FlattenedPath flat,
    Offset point,
    double tolerance,
  ) {
    final double limit = tolerance <= 0 ? 0.5 : tolerance;
    final double limitSquared = limit * limit;
    for (var c = 0; c < flat.contourCount; c++) {
      final int start = flat.contourStarts[c];
      final int end = flat.contourStarts[c + 1];
      if (end - start < 2) continue;
      final bool closed = flat.contourClosed[c] != 0;
      final int last = closed ? end : end - 1;
      for (var i = start; i < last; i++) {
        final int next = i + 1 == end ? start : i + 1;
        if (_distanceSquaredToSegment(
              point,
              flat.pointX(i),
              flat.pointY(i),
              flat.pointX(next),
              flat.pointY(next),
            ) <=
            limitSquared) {
          return true;
        }
      }
    }
    return false;
  }

  static double _distanceSquaredToSegment(
    Offset p,
    double x0,
    double y0,
    double x1,
    double y1,
  ) {
    final double dx = x1 - x0;
    final double dy = y1 - y0;
    final double lengthSquared = dx * dx + dy * dy;
    double t = 0;
    if (lengthSquared > 0) {
      t = ((p.dx - x0) * dx + (p.dy - y0) * dy) / lengthSquared;
      t = t < 0 ? 0 : (t > 1 ? 1 : t);
    }
    final double cx = x0 + t * dx;
    final double cy = y0 + t * dy;
    final double ex = p.dx - cx;
    final double ey = p.dy - cy;
    return ex * ex + ey * ey;
  }

  /// Every object of [page] that [band] catches under [rule].
  ///
  /// Bottom-to-top within a layer and layer by layer, which is the z order the
  /// document is drawn in - so a grouped selection keeps its stacking.
  List<SelectableObject> objectsIn(
    Rect band,
    VectorPage page, {
    MarqueeRule rule = MarqueeRule.enclosed,
  }) {
    final Rect normalized = Rect.fromLTRB(
      band.left < band.right ? band.left : band.right,
      band.top < band.bottom ? band.top : band.bottom,
      band.left < band.right ? band.right : band.left,
      band.top < band.bottom ? band.bottom : band.top,
    );
    final List<SelectableObject> found = <SelectableObject>[];
    for (final VectorLayer layer in page.children.whereType<VectorLayer>()) {
      if (!layer.isVisible || !layer.isEditable) continue;
      for (final Object child in layer.children) {
        if (child is! SelectableObject) continue;
        final Rect box = child.cacheBbox;
        if (box == Rect.zero) continue;
        final bool caught = rule == MarqueeRule.enclosed
            ? _encloses(normalized, box)
            : _overlaps(normalized, box);
        if (caught) found.add(child);
      }
    }
    return found;
  }

  static bool _encloses(Rect band, Rect box) =>
      box.left >= band.left &&
      box.top >= band.top &&
      box.right <= band.right &&
      box.bottom <= band.bottom;

  static bool _overlaps(Rect band, Rect box) =>
      box.right >= band.left &&
      box.left <= band.right &&
      box.bottom >= band.top &&
      box.top <= band.bottom;

  /// The eight handle centres of the current selection, in draw order.
  ///
  /// The same order [TransformHandle] declares, so the index of a handle in
  /// this list is its enum index - which is what keeps hit testing and painting
  /// describing the same eight squares.
  List<Offset> get handleCentres {
    final bounds = selectionBounds;
    return <Offset>[
      Offset(bounds.left, bounds.top),
      Offset(bounds.center.dx, bounds.top),
      Offset(bounds.right, bounds.top),
      Offset(bounds.right, bounds.center.dy),
      Offset(bounds.right, bounds.bottom),
      Offset(bounds.center.dx, bounds.bottom),
      Offset(bounds.left, bounds.bottom),
      Offset(bounds.left, bounds.center.dy),
    ];
  }

  /// Hit-tests an interactive transform handle on the selection bounding box.
  ///
  /// [tolerance] is in **document units**; pass
  /// `SelectionManager.handleGrabPixels / zoom`. The default is only useful at
  /// 1:1 and exists so a caller that forgets is merely imprecise rather than
  /// broken.
  ///
  /// A square target, not a round one: that is the shape the handle is drawn
  /// as, and a circular hot spot inside a square handle means the four corners
  /// of every handle do nothing.
  ///
  /// In [SelectionHandleMode.rotate] the pivot is a ninth handle and it is
  /// tested **first**, because it sits at the centre of the box by default and
  /// the centre is nowhere near the other eight - but a user who has dragged it
  /// onto a corner still expects to be able to pick it up again, and losing the
  /// pivot under a scale handle is a state with no way out.
  TransformHandle? hitTestHandle(Offset point, {double tolerance = 6.0}) {
    if (!hasSelection) return null;
    final Rect bounds = selectionBounds;
    if (bounds == Rect.zero) return null;
    if (handleMode == SelectionHandleMode.rotate) {
      final Offset centre = pivot;
      if ((point.dx - centre.dx).abs() <= tolerance &&
          (point.dy - centre.dy).abs() <= tolerance) {
        return TransformHandle.rotationCenter;
      }
    }
    final centres = handleCentres;
    for (var i = 0; i < centres.length; i++) {
      final Offset centre = centres[i];
      if ((point.dx - centre.dx).abs() <= tolerance &&
          (point.dy - centre.dy).abs() <= tolerance) {
        return TransformHandle.values[i];
      }
    }
    return null;
  }

  /// Whether [handle] is one of the four corners.
  static bool isCorner(TransformHandle handle) =>
      handle == TransformHandle.topLeft ||
      handle == TransformHandle.topRight ||
      handle == TransformHandle.bottomRight ||
      handle == TransformHandle.bottomLeft;

  /// The document-space transform a rotate-frame drag describes.
  ///
  /// The rotate frame gives the same eight handles two new jobs, which is the
  /// CorelDRAW arrangement sK1 copies:
  ///
  ///  * **a corner turns the selection** about [pivot]. The angle is measured
  ///    from the pivot to the press point and from the pivot to the pointer now
  ///    - not accumulated between moves - so the transform always describes the
  ///    whole gesture and dragging back to where you started restores the
  ///    document exactly.
  ///  * **an edge skews it**, along the edge, anchored on the opposite edge.
  ///    That anchoring is what makes a skew feel like pushing the top of a
  ///    stack of paper sideways rather than like a shear about nothing.
  ///
  /// [constrain] (Shift) snaps to [rotationStepDegrees], which is CorelDRAW's
  /// own constrained-rotation step.
  ///
  /// Returns null when the gesture cannot describe a transform: a zero-sized
  /// box, or a press exactly on the pivot, where there is no angle to measure.
  List<double>? trafoForRotateHandle(
    TransformHandle handle,
    Rect bounds,
    Offset pivotPoint,
    Offset pressPoint,
    Offset currentPoint, {
    bool constrain = false,
  }) {
    if (bounds.width <= 0 || bounds.height <= 0) return null;

    if (isCorner(handle)) {
      final Offset from = pressPoint - pivotPoint;
      final Offset to = currentPoint - pivotPoint;
      // Under a pixel of lever arm there is no angle worth reading, and
      // atan2 of a near-zero vector is noise.
      if (from.distance < 1e-6 || to.distance < 1e-6) return null;
      var angle = math.atan2(to.dy, to.dx) - math.atan2(from.dy, from.dx);
      if (constrain) {
        const double step = rotationStepDegrees * math.pi / 180.0;
        angle = (angle / step).roundToDouble() * step;
      }
      return rotationTrafo(angle, pivotPoint);
    }

    // Edges skew. Each one moves along itself and is anchored on the far side,
    // so the factor is "how far the dragged edge travelled" over "how far it is
    // from the edge that is standing still".
    final Offset delta = currentPoint - pressPoint;
    switch (handle) {
      case TransformHandle.topCenter:
      case TransformHandle.bottomCenter:
        final double span = handle == TransformHandle.topCenter
            ? bounds.top - bounds.bottom
            : bounds.bottom - bounds.top;
        if (span == 0) return null;
        final double anchor =
            handle == TransformHandle.topCenter ? bounds.bottom : bounds.top;
        var factor = delta.dx / span;
        if (constrain) factor = _snapSkew(factor);
        return <double>[1, 0, factor, 1, -factor * anchor, 0];
      case TransformHandle.midLeft:
      case TransformHandle.midRight:
        final double span = handle == TransformHandle.midLeft
            ? bounds.left - bounds.right
            : bounds.right - bounds.left;
        if (span == 0) return null;
        final double anchor =
            handle == TransformHandle.midLeft ? bounds.right : bounds.left;
        var factor = delta.dy / span;
        if (constrain) factor = _snapSkew(factor);
        return <double>[1, factor, 0, 1, 0, -factor * anchor];
      case TransformHandle.topLeft:
      case TransformHandle.topRight:
      case TransformHandle.bottomRight:
      case TransformHandle.bottomLeft:
      case TransformHandle.rotationCenter:
        return null;
    }
  }

  /// The step constrained rotation snaps to, in degrees. CorelDRAW's 15.
  static const double rotationStepDegrees = 15.0;

  /// A rotation of [angle] radians about [about].
  ///
  /// Composed as `T(about) . R(angle) . T(-about)` and written out, because
  /// the alternative - three matrix multiplies per pointer move - buys nothing
  /// and hides which of the six numbers the pivot ends up in.
  static List<double> rotationTrafo(double angle, Offset about) {
    final double c = math.cos(angle);
    final double s = math.sin(angle);
    return <double>[
      c,
      s,
      -s,
      c,
      about.dx - about.dx * c + about.dy * s,
      about.dy - about.dx * s - about.dy * c,
    ];
  }

  /// Snaps a skew factor to the same 15 degree ladder rotation uses.
  static double _snapSkew(double factor) {
    const double step = rotationStepDegrees * math.pi / 180.0;
    final double angle = math.atan(factor);
    return math.tan((angle / step).roundToDouble() * step);
  }

  /// Opens a transaction over the current selection.
  SelectionTransaction beginTransform() =>
      SelectionTransaction(List<SelectableObject>.of(_selectedObjects));

  /// Moves all selected objects by [dx], [dy].
  void moveSelection(double dx, double dy) {
    for (final obj in _selectedObjects) {
      obj.applyTrafo([1.0, 0.0, 0.0, 1.0, dx, dy]);
    }
  }

  /// The document-space transform a [handle] drag describes.
  ///
  /// [bounds] is the selection box **when the gesture started**, and [delta] is
  /// the pointer's total travel since it pressed - not since the last event.
  /// The result is the whole gesture, so applying it to the press-state
  /// snapshot reproduces the drag exactly however many events it took.
  ///
  /// Modifiers, and where they come from:
  ///
  ///  * [proportional] (Shift) keeps the aspect ratio. This is the CorelDRAW /
  ///    Inkscape convention and the one the editor's own brief asks for. sK1
  ///    puts the same thing on Ctrl and uses Shift for scale-about-centre; the
  ///    two are swapped here deliberately, and [aboutCentre] is what sK1 calls
  ///    Shift.
  ///  * [aboutCentre] (Ctrl) anchors the opposite *centre* instead of the
  ///    opposite corner, so the selection grows both ways at once.
  ///
  /// Returns null when the drag would collapse or invert the selection past
  /// recovery: a zero scale destroys the box the next drag would be measured
  /// against, and there is no gesture that brings it back.
  List<double>? trafoForHandle(
    TransformHandle handle,
    Rect bounds,
    Offset delta, {
    bool proportional = false,
    bool aboutCentre = false,
  }) {
    if (bounds.width <= 0 || bounds.height <= 0) return null;

    final bool movesLeft = handle == TransformHandle.topLeft ||
        handle == TransformHandle.midLeft ||
        handle == TransformHandle.bottomLeft;
    final bool movesRight = handle == TransformHandle.topRight ||
        handle == TransformHandle.midRight ||
        handle == TransformHandle.bottomRight;
    final bool movesTop = handle == TransformHandle.topLeft ||
        handle == TransformHandle.topCenter ||
        handle == TransformHandle.topRight;
    final bool movesBottom = handle == TransformHandle.bottomLeft ||
        handle == TransformHandle.bottomCenter ||
        handle == TransformHandle.bottomRight;

    // Dragging about the centre moves both edges, so the same pointer travel
    // has to change the box by twice as much.
    final double gain = aboutCentre ? 2.0 : 1.0;

    var scaleX = 1.0;
    var anchorX = aboutCentre ? bounds.center.dx : bounds.left;
    if (movesRight) {
      scaleX = (bounds.width + delta.dx * gain) / bounds.width;
    } else if (movesLeft) {
      scaleX = (bounds.width - delta.dx * gain) / bounds.width;
      if (!aboutCentre) anchorX = bounds.right;
    }

    var scaleY = 1.0;
    var anchorY = aboutCentre ? bounds.center.dy : bounds.top;
    if (movesBottom) {
      scaleY = (bounds.height + delta.dy * gain) / bounds.height;
    } else if (movesTop) {
      scaleY = (bounds.height - delta.dy * gain) / bounds.height;
      if (!aboutCentre) anchorY = bounds.bottom;
    }

    if (proportional) {
      // Whichever axis the user pushed harder wins, and drives both. An edge
      // handle drives the axis it has no control over as well, which is what
      // makes Shift on a middle handle a uniform scale rather than a no-op.
      final double byX = (scaleX - 1).abs();
      final double byY = (scaleY - 1).abs();
      final double uniform = byX >= byY ? scaleX : scaleY;
      scaleX = uniform;
      scaleY = uniform;
    }

    const double minimum = 0.01;
    if (scaleX.abs() < minimum || scaleY.abs() < minimum) return null;

    return <double>[
      scaleX,
      0.0,
      0.0,
      scaleY,
      anchorX - anchorX * scaleX,
      anchorY - anchorY * scaleY,
    ];
  }

  /// Drags [handle] by [dx], [dy], scaling the selection about the opposite
  /// corner - which is what makes a corner handle feel anchored.
  ///
  /// Incremental, and kept for callers that drive a resize a step at a time -
  /// the property bar's spin buttons. An interactive drag must use
  /// [trafoForHandle] against a [SelectionTransaction] instead: applying step
  /// after step is what let a resize drift away from the pointer.
  void resizeSelection(TransformHandle handle, double dx, double dy) {
    if (_selectedObjects.isEmpty) return;
    final List<double>? trafo =
        trafoForHandle(handle, selectionBounds, Offset(dx, dy));
    if (trafo == null) return;
    for (final SelectableObject object in _selectedObjects) {
      object.applyTrafo(trafo);
    }
  }

  /// Scales every selected object about [anchor].
  void scaleAbout(Offset anchor, double scaleX, double scaleY) {
    for (final obj in _selectedObjects) {
      obj.applyTrafo(<double>[
        scaleX,
        0.0,
        0.0,
        scaleY,
        anchor.dx - anchor.dx * scaleX,
        anchor.dy - anchor.dy * scaleY,
      ]);
    }
  }
}
