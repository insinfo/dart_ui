/// The editor's state, and the one place that mutates a document.
///
/// Every bar in the window shows some part of this: the property bar shows the
/// selection, the rulers show the zoom and pan, the status bar shows all three.
/// Keeping it in one object rather than in the widgets is what lets them agree.
library;

import 'package:dart_ui/dart_ui.dart';

import 'document_api.dart';
import 'metrics.dart';

/// One open document, with its own history, selection and viewport.
///
/// sK1 gives each tab its own zoom and scroll position, and so does this: a
/// shared viewport would jump every time the user changed tabs.
class DocumentSession {
  DocumentSession({
    required this.document,
    required this.name,
    this.filePath,
  }) : api = DocumentApi(document);

  final VectorDocument document;
  final DocumentApi api;
  final SelectionManager selection = SelectionManager();
  final SnapManager snap = SnapManager();

  String name;
  String? filePath;

  /// Whether there are unsaved changes - the `*` on the document tab.
  bool modified = false;

  /// Whether the page has been fitted to the window once.
  ///
  /// A document opens fitted, the way sK1 does, but "the window" is only known
  /// after the canvas has been laid out - so the fit is deferred to the first
  /// time the canvas reports its box rather than guessed at construction.
  bool fittedOnce = false;

  /// Device pixels per document point.
  double zoom = 1.0;

  /// Where document (0,0) lands inside the canvas box, in device pixels.
  Offset pan = const Offset(40, 40);

  VectorPage get page => document.getPage(0);

  VectorLayer get layer => page.children
      .whereType<VectorLayer>()
      .firstWhere((layer) => layer.isEditable && layer.isVisible,
          orElse: () => page.children.whereType<VectorLayer>().first);

  /// The tab title, with sK1's unsaved marker.
  String get tabTitle => modified ? '$name*' : name;
}

/// Which side panel is showing, if any.
///
/// The ids are the plugin ids sK1 uses in `plgarea.py`, kept as strings so the
/// collapsed tab strip can be driven by data instead of a switch.
abstract final class PanelIds {
  static const String transform = 'TransformPlugin';
  static const String align = 'AlignPlugin';
  static const String fillStroke = 'FillStrokePlugin';

  static const Map<String, String> names = <String, String>{
    transform: 'Transformations',
    align: 'Align and Distribute',
    fillStroke: 'Fill and Outline',
  };
}

/// The transform sub-modes of sK1's Transformations panel.
enum TransformMode {
  position('Position'),
  resize('Resizing'),
  scale('Scale and mirror'),
  rotate('Rotation'),
  shear('Shearing');

  const TransformMode(this.label);

  final String label;
}

/// What "Align" is relative to. sK1's `Relative to:` combo, in its order.
enum AlignReference {
  page('Page'),
  selection('Selection'),
  firstSelected('First selected'),
  lastSelected('Last selected'),
  largest('Largest object'),
  smallest('Smallest object');

  const AlignReference(this.label);

  final String label;
}

/// Horizontal alignment targets.
enum HorizontalAlign { left, centre, right }

/// Vertical alignment targets.
enum VerticalAlign { top, middle, bottom }

/// The whole editor, minus the widgets.
class EditorModel {
  EditorModel({required this.onChanged});

  /// Called whenever anything a widget shows has changed.
  final void Function() onChanged;

  final List<DocumentSession> documents = <DocumentSession>[];
  int activeIndex = 0;

  ToolMode tool = ToolMode.select;

  /// Ruler and property-bar units. sK1 stores this per document; this editor
  /// keeps one setting, which is a simplification worth naming.
  DocUnit units = DocUnit.mm;

  /// The cursor in document coordinates, or null when it is off the canvas.
  Offset? cursor;

  bool showGrid = true;
  bool showGuides = true;
  bool snapToGrid = true;

  /// Corner count for newly created polygons - sK1's PolygonCfgPlugin.
  int polygonCorners = 5;

  FillDescriptor currentFill =
      const FillDescriptor.solid(Color(0xFF2196F3));
  StrokeDescriptor currentStroke = const StrokeDescriptor(
    color: Color(0xFF1A1A1A),
    width: 1.0,
  );

  /// The panels that have been opened at least once, in tab order.
  final List<String> openPanels = <String>[
    PanelIds.transform,
    PanelIds.align,
    PanelIds.fillStroke,
  ];

  /// The expanded panel, or null when the plugin area is collapsed.
  String? activePanel = PanelIds.transform;

  TransformMode transformMode = TransformMode.position;
  AlignReference alignReference = AlignReference.page;
  HorizontalAlign? horizontalAlign = HorizontalAlign.centre;
  VerticalAlign? verticalAlign = VerticalAlign.middle;
  bool alignAsGroup = true;

  /// The menu whose drop-down is open, by index, or -1.
  int openMenu = -1;

  /// The free-text message at the right of the status bar.
  String status = 'Ready';

  // -------------------------------------------------------------------------
  // Access
  // -------------------------------------------------------------------------

  bool get hasDocument => documents.isNotEmpty;

  DocumentSession get active => documents[activeIndex.clamp(
        0,
        documents.length - 1,
      )];

  SelectionManager get selection => active.selection;

  bool get hasSelection => hasDocument && selection.hasSelection;

  /// The single selected object, or null when zero or several are selected.
  SelectableObject? get singleSelection =>
      hasSelection && selection.count == 1 ? selection.selectedObjects.first : null;

  /// Marks the active document dirty and rebuilds the window.
  void touch([String? message]) {
    if (hasDocument) active.modified = true;
    if (message != null) status = message;
    onChanged();
  }

  /// Rebuilds without claiming the document changed.
  void refresh([String? message]) {
    if (message != null) status = message;
    onChanged();
  }

  // -------------------------------------------------------------------------
  // Documents
  // -------------------------------------------------------------------------

  void addDocument(DocumentSession session, {bool activate = true}) {
    documents.add(session);
    if (activate) activeIndex = documents.length - 1;
    refresh('Opened ${session.name}');
  }

  void selectDocument(int index) {
    if (index < 0 || index >= documents.length) return;
    activeIndex = index;
    refresh('${documents[index].name} is current');
  }

  void closeDocument(int index) {
    if (index < 0 || index >= documents.length) return;
    final closed = documents.removeAt(index);
    if (activeIndex >= documents.length) activeIndex = documents.length - 1;
    if (activeIndex < 0) activeIndex = 0;
    refresh('Closed ${closed.name}');
  }

  // -------------------------------------------------------------------------
  // Viewport
  // -------------------------------------------------------------------------

  void setZoom(double zoom, [Offset? pan]) {
    if (!hasDocument) return;
    active.zoom = zoom.clamp(ZoomMetrics.minimum, ZoomMetrics.maximum);
    if (pan != null) active.pan = pan;
    refresh();
  }

  /// Zooms about the centre of a canvas [viewportSize].
  void zoomBy(double factor, Size viewportSize) {
    if (!hasDocument) return;
    final centre = Offset(viewportSize.width / 2, viewportSize.height / 2);
    final before = (centre - active.pan) / active.zoom;
    final zoom =
        (active.zoom * factor).clamp(ZoomMetrics.minimum, ZoomMetrics.maximum);
    active.zoom = zoom;
    active.pan = centre - before * zoom;
    refresh('Zoom ${(zoom * 100).round()}%');
  }

  /// Fits [rect] (document units) into [viewportSize].
  void zoomToRect(Rect rect, Size viewportSize) {
    if (!hasDocument || rect.width <= 0 || rect.height <= 0) return;
    final available = Size(
      viewportSize.width - ZoomMetrics.fitMargin * 2,
      viewportSize.height - ZoomMetrics.fitMargin * 2,
    );
    if (available.width <= 0 || available.height <= 0) return;
    final scale = (available.width / rect.width) < (available.height / rect.height)
        ? available.width / rect.width
        : available.height / rect.height;
    final zoom = scale.clamp(ZoomMetrics.minimum, ZoomMetrics.maximum);
    active.zoom = zoom;
    active.pan = Offset(
      (viewportSize.width - rect.width * zoom) / 2 - rect.left * zoom,
      (viewportSize.height - rect.height * zoom) / 2 - rect.top * zoom,
    );
    refresh('Zoom ${(zoom * 100).round()}%');
  }

  // -------------------------------------------------------------------------
  // Editing
  // -------------------------------------------------------------------------

  /// Applies [style] to every selected object, as one undoable step each.
  void applyToSelection(VectorStyle Function(VectorStyle style) transform) {
    if (!hasSelection) return;
    for (final object in selection.selectedObjects) {
      active.api.setObjectStyle(object, transform(object.style));
    }
    touch('Style applied to ${selection.count} object(s)');
  }

  void setFill(Color? color) {
    currentFill =
        color == null ? FillDescriptor.none : FillDescriptor.solid(color);
    if (!hasSelection) {
      refresh(color == null ? 'Default fill cleared' : 'Default fill set');
      return;
    }
    applyToSelection((style) => style.copyWith(fill: currentFill));
  }

  void setStroke(Color? color) {
    currentStroke = color == null
        ? currentStroke.copyWith(width: 0)
        : StrokeDescriptor(color: color, width: currentStroke.width <= 0 ? 1 : currentStroke.width);
    if (!hasSelection) {
      refresh(color == null ? 'Default outline cleared' : 'Default outline set');
      return;
    }
    applyToSelection((style) => style.copyWith(stroke: currentStroke));
  }

  void deleteSelection() {
    if (!hasSelection) return;
    final count = selection.count;
    for (final object in List<SelectableObject>.of(selection.selectedObjects)) {
      active.api.removeObject(object);
    }
    selection.deselectAll();
    touch('Deleted $count object(s)');
  }

  void selectAll() {
    if (!hasDocument) return;
    selection.selectAll(active.page);
    refresh('${selection.count} object(s) selected');
  }

  void deselect() {
    if (!hasDocument) return;
    selection.deselectAll();
    refresh('Nothing selected');
  }

  /// Records a drag the canvas has already applied, so one drag is one undo.
  void commitTransform(SelectionEdit edit) {
    if (!hasDocument) return;
    active.api.applySelectionEdit(edit);
    touch(edit.before.length == 1
        ? 'Transformed 1 object'
        : 'Transformed ${edit.before.length} objects');
  }

  /// Records an in-canvas text edit.
  void commitTextEdit(VectorText object, String before, String after) {
    if (!hasDocument) return;
    active.api.setTextContent(object, before, after);
    touch('Text edited');
  }

  void undo() {
    if (!hasDocument || !active.api.canUndo) return;
    final description = active.api.undoDescription;
    active.api.undo();
    active.document.update();
    touch('Undid $description');
  }

  void redo() {
    if (!hasDocument || !active.api.canRedo) return;
    final description = active.api.redoDescription;
    active.api.redo();
    active.document.update();
    touch('Redid $description');
  }

  void group() {
    if (selection.count < 2) return;
    final group = active.api.groupObjects(selection.selectedObjects);
    selection.select(group);
    touch('Grouped');
  }

  void ungroup() {
    final single = singleSelection;
    if (single is! VectorGroup) return;
    active.api.ungroupObjects(single);
    selection.deselectAll();
    touch('Ungrouped');
  }

  /// Moves the selection one step, or all the way, in the z order.
  void reorder({required bool up, required bool toEnd}) {
    if (!hasSelection) return;
    final layerChildren = active.layer.children;
    for (final object in selection.selectedObjects) {
      final index = layerChildren.indexOf(object);
      if (index < 0) continue;
      final target = toEnd
          ? (up ? layerChildren.length - 1 : 0)
          : (up ? index + 1 : index - 1);
      if (target < 0 || target >= layerChildren.length || target == index) {
        continue;
      }
      layerChildren
        ..removeAt(index)
        ..insert(target, object);
    }
    active.document.update();
    touch('Order changed');
  }

  /// Moves the selection by a document-space delta, undoably.
  void moveSelectionBy(double dx, double dy) {
    if (!hasSelection) return;
    for (final object in selection.selectedObjects) {
      active.api.transformObject(object, <double>[1, 0, 0, 1, dx, dy]);
    }
    active.document.update();
    touch('Moved');
  }

  /// Scales the selection to [width] x [height] document points.
  void resizeSelectionTo({double? width, double? height}) {
    if (!hasSelection) return;
    final bounds = selection.selectionBounds;
    if (bounds.width <= 0 || bounds.height <= 0) return;
    final scaleX = width == null || width <= 0 ? 1.0 : width / bounds.width;
    final scaleY = height == null || height <= 0 ? 1.0 : height / bounds.height;
    if (scaleX == 1 && scaleY == 1) return;
    for (final object in selection.selectedObjects) {
      active.api.transformObject(object, <double>[
        scaleX,
        0,
        0,
        scaleY,
        bounds.left - bounds.left * scaleX,
        bounds.top - bounds.top * scaleY,
      ]);
    }
    active.document.update();
    touch('Resized');
  }

  /// Rotates the selection about its centre by [degrees].
  void rotateSelection(double degrees) {
    if (!hasSelection || degrees == 0) return;
    final bounds = selection.selectionBounds;
    final radians = degrees * 3.141592653589793 / 180.0;
    final cosine = _cos(radians);
    final sine = _sin(radians);
    final cx = bounds.center.dx;
    final cy = bounds.center.dy;
    for (final object in selection.selectedObjects) {
      active.api.transformObject(object, <double>[
        cosine,
        sine,
        -sine,
        cosine,
        cx - cx * cosine + cy * sine,
        cy - cx * sine - cy * cosine,
      ]);
    }
    active.document.update();
    touch('Rotated ${degrees.toStringAsFixed(1)} degrees');
  }

  /// Mirrors the selection about its own centre.
  void flipSelection({required bool horizontal}) {
    if (!hasSelection) return;
    final bounds = selection.selectionBounds;
    final scaleX = horizontal ? -1.0 : 1.0;
    final scaleY = horizontal ? 1.0 : -1.0;
    final cx = bounds.center.dx;
    final cy = bounds.center.dy;
    for (final object in selection.selectedObjects) {
      active.api.transformObject(object, <double>[
        scaleX,
        0,
        0,
        scaleY,
        cx - cx * scaleX,
        cy - cy * scaleY,
      ]);
    }
    active.document.update();
    touch(horizontal ? 'Flipped horizontally' : 'Flipped vertically');
  }

  /// Aligns the selection, sK1's Align panel Apply.
  void applyAlign() {
    if (!hasSelection) return;
    final reference = _referenceRect();
    if (reference == null) return;
    final objects = selection.selectedObjects;
    final asGroup = alignAsGroup && alignReference == AlignReference.page;

    void alignOne(Rect bounds, void Function(double dx, double dy) move) {
      var dx = 0.0;
      var dy = 0.0;
      switch (horizontalAlign) {
        case HorizontalAlign.left:
          dx = reference.left - bounds.left;
        case HorizontalAlign.centre:
          dx = reference.center.dx - bounds.center.dx;
        case HorizontalAlign.right:
          dx = reference.right - bounds.right;
        case null:
          break;
      }
      switch (verticalAlign) {
        case VerticalAlign.top:
          dy = reference.top - bounds.top;
        case VerticalAlign.middle:
          dy = reference.center.dy - bounds.center.dy;
        case VerticalAlign.bottom:
          dy = reference.bottom - bounds.bottom;
        case null:
          break;
      }
      if (dx != 0 || dy != 0) move(dx, dy);
    }

    if (asGroup) {
      alignOne(selection.selectionBounds, (dx, dy) {
        for (final object in objects) {
          active.api.transformObject(object, <double>[1, 0, 0, 1, dx, dy]);
        }
      });
    } else {
      for (final object in objects) {
        alignOne(object.cacheBbox, (dx, dy) {
          active.api.transformObject(object, <double>[1, 0, 0, 1, dx, dy]);
        });
      }
    }
    active.document.update();
    touch('Aligned ${objects.length} object(s)');
  }

  /// Spreads the selection evenly. sK1 needs three objects for this and so do
  /// we: two objects are already "distributed", whatever the mode says.
  void applyDistribute({required bool horizontal}) {
    if (selection.count < 3) return;
    final objects = List<SelectableObject>.of(selection.selectedObjects)
      ..sort((a, b) => horizontal
          ? a.cacheBbox.center.dx.compareTo(b.cacheBbox.center.dx)
          : a.cacheBbox.center.dy.compareTo(b.cacheBbox.center.dy));
    final first = objects.first.cacheBbox.center;
    final last = objects.last.cacheBbox.center;
    final span = horizontal ? last.dx - first.dx : last.dy - first.dy;
    final step = span / (objects.length - 1);
    for (var i = 1; i < objects.length - 1; i++) {
      final centre = objects[i].cacheBbox.center;
      final target = (horizontal ? first.dx : first.dy) + step * i;
      final delta = target - (horizontal ? centre.dx : centre.dy);
      active.api.transformObject(objects[i], <double>[
        1,
        0,
        0,
        1,
        horizontal ? delta : 0,
        horizontal ? 0 : delta,
      ]);
    }
    active.document.update();
    touch('Distributed ${objects.length} objects');
  }

  Rect? _referenceRect() {
    switch (alignReference) {
      case AlignReference.page:
        return active.page.rect;
      case AlignReference.selection:
        return selection.selectionBounds;
      case AlignReference.firstSelected:
        return selection.selectedObjects.first.cacheBbox;
      case AlignReference.lastSelected:
        return selection.selectedObjects.last.cacheBbox;
      case AlignReference.largest:
      case AlignReference.smallest:
        if (selection.count < 2) return null;
        var best = selection.selectedObjects.first.cacheBbox;
        for (final object in selection.selectedObjects.skip(1)) {
          final bounds = object.cacheBbox;
          final area = bounds.width * bounds.height;
          final bestArea = best.width * best.height;
          final wins = alignReference == AlignReference.largest
              ? area > bestArea
              : area < bestArea;
          if (wins) best = bounds;
        }
        return best;
    }
  }

  // -------------------------------------------------------------------------
  // Panels
  // -------------------------------------------------------------------------

  /// Clicking a collapsed tab opens it; clicking the open one collapses the
  /// area, which is what makes the strip a space saver rather than a switcher.
  void togglePanel(String id) {
    activePanel = activePanel == id ? null : id;
    refresh(activePanel == null
        ? 'Panels collapsed'
        : '${PanelIds.names[id]} shown');
  }

  void closePanel(String id) {
    openPanels.remove(id);
    if (activePanel == id) {
      activePanel = openPanels.isEmpty ? null : openPanels.first;
    }
    refresh('${PanelIds.names[id]} closed');
  }

  // Small local trig, so the model does not pull in dart:math for two calls
  // that a table would serve just as well.
  static double _sin(double radians) => _taylorSin(radians);

  static double _cos(double radians) =>
      _taylorSin(radians + 1.5707963267948966);

  static double _taylorSin(double x) {
    // Reduce to [-pi, pi] first: the series is accurate near zero and useless
    // at 40 radians.
    const twoPi = 6.283185307179586;
    var value = x % twoPi;
    if (value > 3.141592653589793) value -= twoPi;
    if (value < -3.141592653589793) value += twoPi;
    final x2 = value * value;
    return value *
        (1 -
            x2 /
                6 *
                (1 - x2 / 20 * (1 - x2 / 42 * (1 - x2 / 72))));
  }
}
