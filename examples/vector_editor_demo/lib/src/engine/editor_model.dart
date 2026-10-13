/// The editor's state, and the one place that mutates a document.
///
/// Every bar in the window shows some part of this: the property bar shows the
/// selection, the rulers show the zoom and pan, the status bar shows all three.
/// Keeping it in one object rather than in the widgets is what lets them agree.
library;

import 'package:dart_ui/dart_ui.dart';

import 'document_api.dart';
import 'zoom.dart';

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

  /// Whether the user has zoomed or panned this tab. Until they do, the
  /// view follows the window: a resize fits the page again.
  bool viewTouched = false;

  /// Device pixels per document point.
  double zoom = 1.0;

  /// Where document (0,0) lands inside the canvas box, in device pixels.
  Offset pan = const Offset(40, 40);

  VectorPage get page => document.getPage(0);

  /// The layer picked in the Objects panel, if it is still usable.
  VectorLayer? _activeLayer;

  /// The layer new objects go on: the one picked in the Objects panel, or
  /// the first that can be drawn into.
  VectorLayer get layer {
    final picked = _activeLayer;
    if (picked != null &&
        page.children.contains(picked) &&
        picked.isEditable &&
        picked.isVisible) {
      return picked;
    }
    return page.children.whereType<VectorLayer>().firstWhere(
        (layer) => layer.isEditable && layer.isVisible && !layer.isGuideLayer,
        orElse: () => page.children.whereType<VectorLayer>().first);
  }

  set layer(VectorLayer value) => _activeLayer = value;

  /// The drawing layers of the page, bottom to top.
  List<VectorLayer> get layers => page.children
      .whereType<VectorLayer>()
      .where((layer) => !layer.isGuideLayer)
      .toList();

  /// The tab title, with sK1's unsaved marker.
  String get tabTitle => modified ? '$name*' : name;
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

  /// Bumped on every change, for widgets outside the main window's tree -
  /// a panel floating in its own window - to rebuild with it.
  final ValueNotifier<int> revision = ValueNotifier<int>(0);

  final List<DocumentSession> documents = <DocumentSession>[];
  int activeIndex = 0;

  ToolMode tool = ToolMode.select;

  /// Ruler and property-bar units. sK1 stores this per document; this editor
  /// keeps one setting, which is a simplification worth naming.
  DocUnit units = DocUnit.mm;

  /// The cursor in document coordinates, or null when it is off the canvas.
  Offset? cursor;

  /// Off by default, as in CorelDRAW: the page is for the artwork.
  bool showGrid = false;
  bool showGuides = true;
  bool snapToGrid = true;

  /// Corner count for newly created polygons - sK1's PolygonCfgPlugin.
  int polygonCorners = 5;

  FillDescriptor currentFill = const FillDescriptor.solid(Color(0xFF2196F3));
  StrokeDescriptor currentStroke = const StrokeDescriptor(
    color: Color(0xFF1A1A1A),
    width: 1.0,
  );

  TransformMode transformMode = TransformMode.position;
  AlignReference alignReference = AlignReference.page;
  HorizontalAlign? horizontalAlign = HorizontalAlign.centre;
  VerticalAlign? verticalAlign = VerticalAlign.middle;
  bool alignAsGroup = true;

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
  SelectableObject? get singleSelection => hasSelection && selection.count == 1
      ? selection.selectedObjects.first
      : null;

  /// Marks the active document dirty and rebuilds the window.
  void touch([String? message]) {
    if (hasDocument) active.modified = true;
    if (message != null) status = message;
    _changed();
  }

  /// Rebuilds without claiming the document changed.
  void refresh([String? message]) {
    if (message != null) status = message;
    _changed();
  }

  void _changed() {
    onChanged();
    revision.value = revision.value + 1;
  }

  // -------------------------------------------------------------------------
  // Documents
  // -------------------------------------------------------------------------

  int _untitled = 0;

  /// The name of the next unnamed drawing: "Untitled 1", "Untitled 2"...
  String nextUntitledName() => 'Untitled ${++_untitled}';

  /// A new, empty drawing in a tab of its own.
  DocumentSession newDocument() {
    final session = DocumentSession(
      document: VectorDocument(docUnits: units),
      name: nextUntitledName(),
    );
    addDocument(session);
    return session;
  }

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
    active.viewTouched = true;
    active.zoom = zoom.clamp(ZoomMetrics.minimum, ZoomMetrics.maximum);
    if (pan != null) active.pan = pan;
    refresh();
  }

  /// Sets [zoom] keeping the centre of a canvas [viewportSize] still.
  void zoomAbout(double zoom, Size viewportSize) {
    if (!hasDocument) return;
    zoomBy(zoom / active.zoom, viewportSize);
  }

  /// Zooms about the centre of a canvas [viewportSize].
  void zoomBy(double factor, Size viewportSize) {
    if (!hasDocument) return;
    active.viewTouched = true;
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
    if (!fitRect(rect, viewportSize)) return;
    refresh('Zoom ${(active.zoom * 100).round()}%');
  }

  /// [zoomToRect] without the rebuild, for callers already building.
  bool fitRect(Rect rect, Size viewportSize) {
    if (!hasDocument || rect.width <= 0 || rect.height <= 0) return false;
    final available = Size(
      viewportSize.width - ZoomMetrics.fitMargin * 2,
      viewportSize.height - ZoomMetrics.fitMargin * 2,
    );
    if (available.width <= 0 || available.height <= 0) return false;
    final scale =
        (available.width / rect.width) < (available.height / rect.height)
            ? available.width / rect.width
            : available.height / rect.height;
    final zoom = scale.clamp(ZoomMetrics.minimum, ZoomMetrics.maximum);
    active.zoom = zoom;
    active.pan = Offset(
      (viewportSize.width - rect.width * zoom) / 2 - rect.left * zoom,
      (viewportSize.height - rect.height * zoom) / 2 - rect.top * zoom,
    );
    return true;
  }

  // -------------------------------------------------------------------------
  // Editing
  // -------------------------------------------------------------------------

  /// Applies [style] to every selected object, as one undoable step.
  void applyToSelection(VectorStyle Function(VectorStyle style) transform) {
    if (!hasSelection) return;
    active.api.restyle(selection.selectedObjects, transform);
    touch('Style applied to ${selection.count} object(s)');
  }

  void setFill(Color? color) {
    currentFill =
        color == null ? FillDescriptor.none : FillDescriptor.solid(color);
    if (!hasSelection) {
      refresh(color == null
          ? 'New objects will have no fill'
          : 'New objects will use this fill');
      return;
    }
    applyToSelection((style) => style.copyWith(fill: currentFill));
  }

  void setStroke(Color? color) {
    currentStroke = color == null
        ? currentStroke.copyWith(width: 0)
        : StrokeDescriptor(
            color: color,
            width: currentStroke.width <= 0 ? 1 : currentStroke.width);
    if (!hasSelection) {
      refresh(color == null
          ? 'New objects will have no outline'
          : 'New objects will use this outline');
      return;
    }
    applyToSelection((style) => style.copyWith(stroke: currentStroke));
  }

  /// Runs [change] on the active document as one undoable step, then
  /// rebuilds. [coalesce] merges consecutive edits of the same thing.
  void edit(String description, void Function() change, {Object? coalesce}) {
    if (!hasDocument) return;
    active.api.record(description, () {
      change();
      active.document.update();
    }, coalesce: coalesce);
    touch(description);
  }

  // --- Layers -------------------------------------------------------------

  void addLayer() {
    if (!hasDocument) return;
    final layer = active.api.record('New layer', () {
      final page = active.page;
      final number = active.layers.length + 1;
      return active.document.addLayer(page, name: 'Layer $number');
    });
    active.layer = layer;
    touch('Added ${layer.name}');
  }

  /// Deletes [layer] and what is on it; the last layer is kept.
  void deleteLayer(VectorLayer layer) {
    if (!hasDocument || active.layers.length <= 1) return;
    active.api
        .record('Delete layer', () => active.api.methods.removeObject(layer));
    _pruneSelection();
    touch('Deleted ${layer.name}');
  }

  /// Moves [layer] one step up (towards the front) or down.
  void moveLayer(VectorLayer layer, {required bool up}) {
    final page = active.page;
    final list = page.children;
    final index = list.indexOf(layer);
    final target = up ? index + 1 : index - 1;
    if (index < 0 || target < 0 || target >= list.length) return;
    if (list[target] is! VectorLayer ||
        (list[target] as VectorLayer).isGuideLayer) {
      return;
    }
    edit(up ? 'Raise layer' : 'Lower layer', () {
      list
        ..removeAt(index)
        ..insert(target, layer);
    });
  }

  void setLayerVisible(VectorLayer layer, bool visible) {
    edit(visible ? 'Show layer' : 'Hide layer',
        () => layer.properties[0] = visible);
    if (!visible) _pruneSelection();
  }

  void setLayerLocked(VectorLayer layer, bool locked) {
    edit(locked ? 'Lock layer' : 'Unlock layer',
        () => layer.properties[1] = !locked);
    if (locked) _pruneSelection();
  }

  void renameLayer(VectorLayer layer, String name) {
    if (name.trim().isEmpty || name == layer.name) return;
    edit('Rename layer', () => layer.name = name.trim(), coalesce: layer);
  }

  void activateLayer(VectorLayer layer) {
    active.layer = layer;
    refresh('${layer.name} is the active layer');
  }

  /// Selects [object] from the Objects panel: alone, or toggled with Shift.
  void pickObject(SelectableObject object, {bool toggle = false}) {
    if (toggle) {
      selection.toggle(object);
    } else {
      selection.select(object);
    }
    final parent = object.parent;
    if (parent is VectorLayer) active.layer = parent;
    refresh('${selection.count} object(s) selected');
  }

  /// What the next gesture does with the current tool, as (gesture,
  /// action) pairs for the status bar - Graphite's bottom-bar hints.
  List<(String, String)> get hints {
    final mod =
        platformEditingConvention == EditingConvention.mac ? '⌘' : 'Ctrl';
    final alt =
        platformEditingConvention == EditingConvention.mac ? '⌥' : 'Alt';
    return switch (tool) {
      ToolMode.select || ToolMode.shaper => hasSelection
          ? <(String, String)>[
              ('Drag', 'Move'),
              ('Shift', 'Extend'),
              ('Click again', 'Rotate/skew'),
              ('$alt+Click', 'Select below'),
              ('Arrows', 'Nudge'),
            ]
          : <(String, String)>[
              ('Click', 'Select'),
              ('Drag', 'Marquee'),
              ('Shift', 'Extend'),
              ('$alt+Click', 'Select below'),
            ],
      ToolMode.rectangle || ToolMode.circle => <(String, String)>[
          ('Drag', 'Draw'),
          (mod, tool == ToolMode.circle ? 'Circle' : 'Square'),
          ('Shift', 'From centre'),
        ],
      ToolMode.polygon => <(String, String)>[
          ('Drag', 'Draw from centre'),
        ],
      ToolMode.curve => <(String, String)>[
          ('Click', 'Corner node'),
          ('Drag', 'Smooth node'),
          ('Click first node', 'Close'),
          ('Enter', 'Finish'),
          ('Esc', 'Cancel'),
        ],
      ToolMode.text => <(String, String)>[
          ('Click', 'Place text'),
          ('Double-click text', 'Edit'),
        ],
      ToolMode.zoom => <(String, String)>[
          ('Click', 'Zoom in'),
          ('Shift+Click', 'Zoom out'),
          ('Drag', 'Zoom to area'),
        ],
      ToolMode.fleur => <(String, String)>[
          ('Drag', 'Pan'),
        ],
    };
  }

  /// The fill the panels and the palette show: the selection's when there
  /// is one (its first object's), the one new objects get otherwise.
  FillDescriptor get shownFill =>
      hasSelection ? selection.selectedObjects.first.style.fill : currentFill;

  /// The outline shown, by the same rule as [shownFill].
  StrokeDescriptor get shownStroke => hasSelection
      ? selection.selectedObjects.first.style.stroke
      : currentStroke;

  /// The style a new object gets: the fill and outline last picked.
  VectorStyle get newObjectStyle =>
      VectorStyle(fill: currentFill, stroke: currentStroke);

  /// Records an object a canvas tool just added, giving it the current
  /// fill and outline - the style the palette shows.
  void objectCreated(SelectableObject object) {
    if (!hasDocument) return;
    if (object is! VectorText) {
      // An open path has no inside: fill it and the pen would draw a wedge.
      final open = object is VectorCurve && !object.isClosed;
      object
        ..style = object.style.copyWith(
          fill: open ? FillDescriptor.none : currentFill,
          stroke: open && currentStroke.width <= 0
              ? const StrokeDescriptor(color: Color(0xFF1A1A1A), width: 1)
              : currentStroke,
        )
        ..update();
    }
    active.api.commit('Create ${_kind(object)}');
    touch('Created ${_kind(object)}');
  }

  static String _kind(SelectableObject object) => switch (object) {
        VectorRectangle() => 'rectangle',
        VectorCircle() => 'ellipse',
        VectorPolygon() => 'polygon',
        VectorCurve() => 'curve',
        VectorText() => 'text',
        _ => 'object',
      };

  void deleteSelection() {
    if (!hasSelection) return;
    final count = selection.count;
    active.api.removeObjects(selection.selectedObjects);
    selection.deselectAll();
    touch('Deleted $count object(s)');
  }

  // --- Clipboard ---------------------------------------------------------

  /// Copies of what Copy or Cut took, shared by every open document the way
  /// a clipboard is.
  List<SelectableObject> _clipboard = const <SelectableObject>[];

  /// How many times the clipboard has been pasted since it was filled, so
  /// each paste lands a step further from the original.
  int _pasteCount = 0;

  bool get canPaste => hasDocument && _clipboard.isNotEmpty;

  void copySelection() {
    if (!hasSelection) return;
    _clipboard = <SelectableObject>[
      for (final object in _inDocumentOrder(selection.selectedObjects))
        object.copy() as SelectableObject,
    ];
    _pasteCount = 0;
    refresh('Copied ${_clipboard.length} object(s)');
  }

  void cutSelection() {
    if (!hasSelection) return;
    copySelection();
    final count = selection.count;
    active.api.removeObjects(selection.selectedObjects);
    selection.deselectAll();
    _pasteCount = -1; // a cut pastes back in place first
    touch('Cut $count object(s)');
  }

  void paste() {
    if (!canPaste) return;
    _pasteCount++;
    final offset = 10.0 * _pasteCount;
    final layer = active.layer;
    final pasted = active.api.record('Paste', () {
      final copies = <SelectableObject>[];
      for (final object in _clipboard) {
        final copy = object.copy() as SelectableObject;
        if (offset != 0) copy.applyTrafo(<double>[1, 0, 0, 1, offset, offset]);
        active.api.methods.addObject(layer, copy);
        copies.add(copy);
      }
      return copies;
    });
    selection.setSelection(pasted);
    touch('Pasted ${pasted.length} object(s)');
  }

  /// Copies the selection in place, a step down and right, and selects the
  /// copies - CorelDRAW's Ctrl+D.
  void duplicateSelection() {
    if (!hasSelection) return;
    final originals = _inDocumentOrder(selection.selectedObjects);
    final copies = active.api.record('Duplicate', () {
      final copies = <SelectableObject>[];
      for (final original in originals) {
        final parent = original.parent;
        if (parent is! VectorLayer) continue;
        final copy = original.copy() as SelectableObject
          ..applyTrafo(const <double>[1, 0, 0, 1, 10, 10]);
        active.api.methods
            .addObject(parent, copy, parent.children.indexOf(original) + 1);
        copies.add(copy);
      }
      return copies;
    });
    selection.setSelection(copies);
    touch('Duplicated ${copies.length} object(s)');
  }

  /// Whether Convert to Curves has something to convert: a shape or a text
  /// in the selection. A curve is already one, and a group is converted by
  /// ungrouping first, as in CorelDRAW.
  bool get canConvertToCurves => selection.selectedObjects.any(
      (o) => o is VectorText || (o is! VectorCurve && o.toCurve() != null));

  /// Replaces every shape and text in the selection by a curve with the same
  /// outline, in the same place in the stacking order - CorelDRAW's Ctrl+Q.
  /// One undo step; the curves are selected afterwards.
  void convertSelectionToCurves() {
    if (!canConvertToCurves) return;
    final originals = _inDocumentOrder(selection.selectedObjects);
    final converted = active.api.record('Convert to curves', () {
      final result = <SelectableObject>[];
      for (final original in originals) {
        final parent = original.parent;
        final DocumentObject? curve = switch (original) {
          VectorText() => VectorTextMetrics.toCurves(original),
          VectorCurve() => null,
          _ => original.toCurve(),
        };
        if (parent is! VectorLayer || curve is! SelectableObject) {
          result.add(original);
          continue;
        }
        final index = parent.children.indexOf(original);
        active.api.methods.removeObject(original);
        active.api.methods.addObject(parent, curve, index);
        result.add(curve);
      }
      return result;
    });
    selection.setSelection(converted);
    touch('Converted ${converted.length} object(s) to curves');
  }

  /// [object]'s outline as curves in document coordinates, or null for
  /// what has none (a group).
  static List<VectorPath>? _documentPaths(SelectableObject object) {
    final DocumentObject? curve = switch (object) {
      VectorText() => VectorTextMetrics.toCurves(object),
      VectorCurve() => object,
      _ => object.toCurve(),
    };
    if (curve is! VectorCurve) return null;
    final List<double> trafo = curve.trafo;
    Offset map(Offset point) => applyTrafoToPoint(point, trafo);
    return <VectorPath>[
      for (final VectorPath path in curve.paths)
        VectorPath(
          start: map(path.start),
          closure: path.closure,
          points: <Object>[
            for (final Object point in path.points)
              switch (point) {
                CurvePoint() => CurvePoint(
                    map(point.control1),
                    map(point.control2),
                    map(point.endpoint),
                    point.nodeType,
                  ),
                Offset() => map(point),
                _ => point,
              },
          ],
        ),
    ];
  }

  /// Whether Combine has two or more objects with an outline to join.
  bool get canCombine =>
      hasSelection &&
      selection.selectedObjects.where((o) => o is! VectorGroup).length >= 2;

  /// CorelDRAW's Combine (Ctrl+L): the selected objects become one curve
  /// with all their outlines, wearing the style of the last one selected,
  /// where the bottom one was. Overlaps become holes, as in CorelDRAW.
  void combineSelection() {
    if (!canCombine) return;
    final List<SelectableObject> objects =
        selection.selectedObjects.where((o) => o is! VectorGroup).toList();
    final SelectableObject styleFrom = objects.last;
    final List<SelectableObject> ordered = _inDocumentOrder(objects);
    final VectorCurve? combined = active.api.record('Combine', () {
      final List<VectorPath> paths = <VectorPath>[
        for (final SelectableObject object in ordered)
          ...?_documentPaths(object),
      ];
      final DocumentObject? bottom = ordered.first.parent;
      if (paths.isEmpty || bottom is! VectorLayer) return null;
      final int index = bottom.children.indexOf(ordered.first);
      final VectorCurve curve = VectorCurve(
        paths: paths,
        style: styleFrom.style.copyWith(
          fill: styleFrom.style.fill.copyWith(fillRule: FillRule.evenOdd),
        ),
      );
      for (final SelectableObject object in ordered) {
        active.api.methods.removeObject(object);
      }
      active.api.methods.addObject(bottom, curve, index);
      curve.update();
      return curve;
    });
    if (combined == null) return;
    selection.setSelection(<SelectableObject>[combined]);
    touch('Combined ${objects.length} objects');
  }

  /// Whether Break Apart has a curve of several outlines to split.
  bool get canBreakApart => selection.selectedObjects
      .any((o) => o is VectorCurve && o.paths.length > 1);

  /// CorelDRAW's Break Apart (Ctrl+K): every curve of several outlines
  /// becomes one curve per outline, in its place, with its style.
  void breakApartSelection() {
    if (!canBreakApart) return;
    final List<SelectableObject> pieces = active.api.record('Break apart', () {
      final List<SelectableObject> result = <SelectableObject>[];
      for (final SelectableObject object
          in _inDocumentOrder(selection.selectedObjects)) {
        final DocumentObject? layer = object.parent;
        if (object is! VectorCurve ||
            object.paths.length < 2 ||
            layer is! VectorLayer) {
          result.add(object);
          continue;
        }
        var index = layer.children.indexOf(object);
        final List<VectorPath> paths = _documentPaths(object)!;
        active.api.methods.removeObject(object);
        for (final VectorPath path in paths) {
          final VectorCurve piece = VectorCurve(
            paths: <VectorPath>[path],
            style: object.style.copyWith(),
          );
          active.api.methods.addObject(layer, piece, index++);
          piece.update();
          result.add(piece);
        }
      }
      return result;
    });
    selection.setSelection(pieces);
    touch('Broke apart into ${pieces.length} objects');
  }

  /// [objects] sorted bottom to top, so copies keep the stacking order.
  List<SelectableObject> _inDocumentOrder(List<SelectableObject> objects) {
    final order = <DocumentObject, int>{};
    var index = 0;
    active.document.visitAll((node) => order[node] = index++);
    return List<SelectableObject>.of(objects)
      ..sort((a, b) => (order[a] ?? 0).compareTo(order[b] ?? 0));
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
    _pruneSelection();
    touch('Undid $description');
  }

  void redo() {
    if (!hasDocument || !active.api.canRedo) return;
    final description = active.api.redoDescription;
    active.api.redo();
    _pruneSelection();
    touch('Redid $description');
  }

  /// Drops objects an undo or redo took out of the document, so the
  /// selection never holds something that is not on the page.
  void _pruneSelection() {
    final live = selection.selectedObjects
        .where((object) => _isInDocument(object) && _isEditable(object))
        .toList();
    if (live.length == selection.count) {
      return;
    }
    selection.deselectAll();
    for (final object in live) {
      selection.toggle(object);
    }
  }

  /// Whether [object] sits on a layer that is visible and unlocked.
  bool _isEditable(DocumentObject object) {
    DocumentObject? node = object.parent;
    while (node != null && node is! VectorLayer) {
      node = node.parent;
    }
    return node is! VectorLayer || (node.isVisible && node.isEditable);
  }

  bool _isInDocument(DocumentObject object) {
    DocumentObject? node = object;
    while (node != null) {
      final parent = node.parent;
      if (parent == null) return identical(node, active.document);
      if (!parent.children.contains(node)) return false;
      node = parent;
    }
    return false;
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
    final members = List<DocumentObject>.of(single.children);
    active.api.ungroupObjects(single);
    selection.setSelection(members.whereType<SelectableObject>());
    touch('Ungrouped');
  }

  /// Moves the selection one step, or all the way, in the z order of each
  /// object's own parent, keeping the selected objects' order among
  /// themselves.
  void reorder({required bool up, required bool toEnd}) {
    if (!hasSelection) return;
    final selected = selection.selectedObjects.toSet();
    var changed = false;
    active.api.record(up ? 'Bring forward' : 'Send backward', () {
      final parents = <DocumentObject>{
        for (final object in selected)
          if (object.parent != null) object.parent!,
      };
      for (final parent in parents) {
        final list = parent.children;
        final before = List<DocumentObject>.of(list);
        if (toEnd) {
          final moving = list.where(selected.contains).toList();
          list.removeWhere(selected.contains);
          if (up) {
            list.addAll(moving);
          } else {
            list.insertAll(0, moving);
          }
        } else if (up) {
          // Walk from the top so a block of selected objects moves as one.
          for (var i = list.length - 2; i >= 0; i--) {
            if (selected.contains(list[i]) && !selected.contains(list[i + 1])) {
              final object = list.removeAt(i);
              list.insert(i + 1, object);
            }
          }
        } else {
          for (var i = 1; i < list.length; i++) {
            if (selected.contains(list[i]) && !selected.contains(list[i - 1])) {
              final object = list.removeAt(i);
              list.insert(i - 1, object);
            }
          }
        }
        for (var i = 0; i < list.length; i++) {
          if (!identical(list[i], before[i])) changed = true;
        }
      }
    });
    touch(changed ? 'Order changed' : 'Already there');
  }

  /// Nudges the selection with an arrow key: [dx], [dy] are -1, 0 or 1 steps
  /// of 1 mm, times ten with Shift and a tenth with the command key -
  /// CorelDRAW's nudge, super nudge and micro nudge. Held keys repeat into
  /// one undo step.
  void nudge(int dx, int dy, {bool big = false, bool small = false}) {
    if (!hasSelection) return;
    final step = DocUnit.mm.toPoints * (big ? 10 : (small ? 0.1 : 1));
    active.api.transform(selection.selectedObjects,
        <double>[1, 0, 0, 1, dx * step, dy * step], 'Nudge');
    touch('Nudged');
  }

  /// Moves the selection by a document-space delta, undoably.
  void moveSelectionBy(double dx, double dy) {
    if (!hasSelection) return;
    active.api.transform(
        selection.selectedObjects, <double>[1, 0, 0, 1, dx, dy], 'Move');
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
    active.api.transform(
        selection.selectedObjects,
        <double>[
          scaleX,
          0,
          0,
          scaleY,
          bounds.left - bounds.left * scaleX,
          bounds.top - bounds.top * scaleY,
        ],
        'Resize');
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
    active.api.transform(
        selection.selectedObjects,
        <double>[
          cosine,
          sine,
          -sine,
          cosine,
          cx - cx * cosine + cy * sine,
          cy - cx * sine - cy * cosine,
        ],
        'Rotate');
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
    active.api.transform(
        selection.selectedObjects,
        <double>[scaleX, 0, 0, scaleY, cx - cx * scaleX, cy - cy * scaleY],
        horizontal ? 'Flip horizontally' : 'Flip vertically');
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

    active.api.record('Align', () {
      if (asGroup) {
        alignOne(selection.selectionBounds, (dx, dy) {
          for (final object in objects) {
            object.applyTrafo(<double>[1, 0, 0, 1, dx, dy]);
          }
        });
      } else {
        for (final object in objects) {
          alignOne(object.cacheBbox, (dx, dy) {
            object.applyTrafo(<double>[1, 0, 0, 1, dx, dy]);
          });
        }
      }
    });
    touch('Aligned ${objects.length} object(s)');
  }

  /// CorelDRAW's align keys (L, R, T, B, C, E, P): with several objects
  /// selected they line up on the last one selected; with one, or with
  /// [toPage], on the page. Each object moves on its own; one undo step.
  void alignTo({
    HorizontalAlign? horizontal,
    VerticalAlign? vertical,
    bool toPage = false,
  }) {
    if (!hasSelection) return;
    final objects = selection.selectedObjects;
    final SelectableObject? anchor =
        !toPage && objects.length > 1 ? objects.last : null;
    final Rect reference = anchor?.cacheBbox ?? active.page.rect;
    var moved = 0;
    active.api.record('Align', () {
      for (final object in objects) {
        if (identical(object, anchor)) continue;
        final Rect bounds = object.cacheBbox;
        final double dx = switch (horizontal) {
          HorizontalAlign.left => reference.left - bounds.left,
          HorizontalAlign.centre => reference.center.dx - bounds.center.dx,
          HorizontalAlign.right => reference.right - bounds.right,
          null => 0,
        };
        final double dy = switch (vertical) {
          VerticalAlign.top => reference.top - bounds.top,
          VerticalAlign.middle => reference.center.dy - bounds.center.dy,
          VerticalAlign.bottom => reference.bottom - bounds.bottom,
          null => 0,
        };
        if (dx == 0 && dy == 0) continue;
        object.applyTrafo(<double>[1, 0, 0, 1, dx, dy]);
        moved++;
      }
    });
    touch('Aligned $moved object(s) to '
        '${anchor == null ? 'the page' : 'the last selected'}');
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
    active.api.record('Distribute', () {
      for (var i = 1; i < objects.length - 1; i++) {
        final centre = objects[i].cacheBbox.center;
        final target = (horizontal ? first.dx : first.dy) + step * i;
        final delta = target - (horizontal ? centre.dx : centre.dy);
        objects[i].applyTrafo(<double>[
          1,
          0,
          0,
          1,
          horizontal ? delta : 0,
          horizontal ? 0 : delta,
        ]);
      }
    });
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
    return value * (1 - x2 / 6 * (1 - x2 / 20 * (1 - x2 / 42 * (1 - x2 / 72))));
  }
}
