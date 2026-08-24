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

import '../../geometry/offset.dart';
import '../../geometry/rect.dart';
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
      _selectedObjects
        ..clear()
        ..add(obj);
      return;
    }
    toggle(obj);
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
  }

  /// Adds [objects], skipping ones already selected.
  void addAll(Iterable<SelectableObject> objects) {
    for (final SelectableObject object in objects) {
      if (!contains(object)) _selectedObjects.add(object);
    }
  }

  /// Selects all objects on the active [page].
  void selectAll(VectorPage page) {
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
  }

  /// Hit-tests a point against objects on [page] (topmost object first).
  ///
  /// [tolerance] is in document units and is what a caller converts a few
  /// screen pixels into: a hairline shape is otherwise unclickable at low zoom.
  ///
  /// The test is against the object's bounding box, not its outline. sK1 walks
  /// a real hit surface and can tell the hole in a doughnut from the doughnut;
  /// this cannot, and a click inside the bounding box but outside the shape
  /// selects it anyway. Named rather than hidden - it is the next thing to fix
  /// here, and it needs the rasterizer.
  SelectableObject? hitTest(
    Offset point,
    VectorPage page, {
    double tolerance = 0,
  }) {
    final layers = page.children.whereType<VectorLayer>().toList();

    // Iterate layers in reverse (top-to-bottom)
    for (var i = layers.length - 1; i >= 0; i--) {
      final layer = layers[i];
      if (!layer.isVisible || !layer.isEditable) continue;

      for (var j = layer.children.length - 1; j >= 0; j--) {
        final obj = layer.children[j];
        if (obj is SelectableObject) {
          if (obj.cacheBbox.inflate(tolerance).contains(point)) {
            return obj;
          }
        }
      }
    }

    return null;
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
  TransformHandle? hitTestHandle(Offset point, {double tolerance = 6.0}) {
    if (!hasSelection) return null;
    final Rect bounds = selectionBounds;
    if (bounds == Rect.zero) return null;
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
