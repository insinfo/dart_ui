import 'constants.dart';
import 'document.dart';
import 'document_object.dart';
import 'primitives.dart';
import 'selectable_objects.dart';
import 'structural_objects.dart';
import 'style.dart';

/// High-level operations on a [VectorDocument].
///
/// Encapsulates common editing tasks: page management, object manipulation,
/// z-order changes, and style operations.
class DocumentMethods {
  DocumentMethods(this.doc);

  final VectorDocument doc;

  // --- Page operations ---

  /// Returns all pages.
  List<VectorPage> getPages() => doc.pageList;

  /// Returns the page at [index].
  VectorPage getPage([int index = 0]) => doc.getPage(index);

  /// Returns the number of pages.
  int get pageCount => doc.pageCount;

  /// Adds a new page.
  VectorPage addPage({String? name, PageFormat? format}) =>
      doc.addPage(name: name, format: format);

  /// Removes a page by index.
  void removePage(int index) => doc.removePage(index);

  /// Sets the page format for a specific page.
  void setPageFormat(VectorPage page, PageFormat format) {
    page.pageFormat = format;
  }

  /// Reorders pages.
  void movePageTo(int fromIndex, int toIndex) {
    final pages = doc.pages.children;
    if (fromIndex < 0 || fromIndex >= pages.length) return;
    if (toIndex < 0 || toIndex >= pages.length) return;
    final page = pages.removeAt(fromIndex);
    pages.insert(toIndex, page);
  }

  // --- Layer operations ---

  /// Returns all layers of the given [page].
  List<VectorLayer> getLayers(VectorPage page) => doc.getPageLayers(page);

  /// Returns the active (editable) layers for a page.
  List<VectorLayer> getActiveLayers(VectorPage page) =>
      doc.getEditableLayers(page);

  /// Returns a specific layer of a page.
  VectorLayer getLayer(VectorPage page, [int index = 0]) {
    final layers = getLayers(page);
    if (index < 0 || index >= layers.length) {
      throw RangeError.range(index, 0, layers.length - 1, 'index');
    }
    return layers[index];
  }

  /// Adds a new layer to [page].
  VectorLayer addLayer(VectorPage page, {String? name}) =>
      doc.addLayer(page, name: name);

  /// Removes a layer from its page.
  void removeLayer(VectorLayer layer) {
    layer.parent?.children.remove(layer);
  }

  /// Sets layer visibility.
  void setLayerVisible(VectorLayer layer, bool visible) {
    if (layer.properties.isNotEmpty) layer.properties[0] = visible;
  }

  /// Sets layer editability.
  void setLayerEditable(VectorLayer layer, bool editable) {
    if (layer.properties.length > 1) layer.properties[1] = editable;
  }

  // --- Document properties ---

  /// Sets the document units.
  void setDocUnits(DocUnit units) {
    doc.docUnits = units;
  }

  /// Sets the document origin.
  void setDocOrigin(DocOrigin origin) {
    doc.docOrigin = origin;
  }

  // --- Object operations ---

  /// Adds an object to a layer.
  void addObject(VectorLayer layer, DocumentObject obj, [int index = -1]) {
    obj.parent = layer;
    if (index < 0 || index >= layer.children.length) {
      layer.children.add(obj);
    } else {
      layer.children.insert(index, obj);
    }
    obj.update();
  }

  /// Removes an object from its parent.
  void removeObject(DocumentObject obj) {
    obj.parent?.children.remove(obj);
    obj.parent = null;
  }

  /// Moves an object to a different layer.
  void moveObjectToLayer(DocumentObject obj, VectorLayer targetLayer,
      [int index = -1]) {
    removeObject(obj);
    addObject(targetLayer, obj, index);
  }

  // --- Z-order ---

  /// Raises object one step in its parent's children list.
  void raiseObject(DocumentObject obj) {
    final parent = obj.parent;
    if (parent == null) return;
    final idx = parent.children.indexOf(obj);
    if (idx < 0 || idx >= parent.children.length - 1) return;
    parent.children.removeAt(idx);
    parent.children.insert(idx + 1, obj);
  }

  /// Lowers object one step in its parent's children list.
  void lowerObject(DocumentObject obj) {
    final parent = obj.parent;
    if (parent == null) return;
    final idx = parent.children.indexOf(obj);
    if (idx <= 0) return;
    parent.children.removeAt(idx);
    parent.children.insert(idx - 1, obj);
  }

  /// Moves object to the top of its parent's children list.
  void raiseToTop(DocumentObject obj) {
    final parent = obj.parent;
    if (parent == null) return;
    parent.children.remove(obj);
    parent.children.add(obj);
  }

  /// Moves object to the bottom of its parent's children list.
  void lowerToBottom(DocumentObject obj) {
    final parent = obj.parent;
    if (parent == null) return;
    parent.children.remove(obj);
    parent.children.insert(0, obj);
  }

  // --- Grouping ---

  /// Groups a list of objects into a [VectorGroup].
  VectorGroup groupObjects(List<SelectableObject> objects) {
    if (objects.isEmpty) throw ArgumentError('Cannot group empty list');
    final parent = objects.first.parent;
    final group = VectorGroup(parent: parent);

    // Find insertion index (position of the first selected object).
    final insertIdx = parent?.children.indexOf(objects.first) ?? 0;

    for (final obj in objects) {
      obj.parent?.children.remove(obj);
      obj.parent = group;
      group.children.add(obj);
    }

    parent?.children.insert(insertIdx, group);
    group.update();
    return group;
  }

  /// Ungroups a [VectorGroup], placing its children in the parent.
  List<DocumentObject> ungroupObjects(VectorGroup group) {
    final parent = group.parent;
    if (parent == null) return [];

    final insertIdx = parent.children.indexOf(group);
    parent.children.remove(group);

    final ungrouped = <DocumentObject>[];
    for (var i = 0; i < group.children.length; i++) {
      final child = group.children[i];
      child.parent = parent;
      parent.children.insert(insertIdx + i, child);
      ungrouped.add(child);
    }
    group.children.clear();
    return ungrouped;
  }

  // --- Transform ---

  /// Applies an affine transform to an object.
  void applyTrafo(SelectableObject obj, List<double> trafo) {
    obj.applyTrafo(trafo);
  }

  /// Moves an object by [dx], [dy] points.
  void moveObject(SelectableObject obj, double dx, double dy) {
    obj.applyTrafo([1.0, 0.0, 0.0, 1.0, dx, dy]);
  }

  // --- Style ---

  /// Sets the style of an object.
  void setObjectStyle(SelectableObject obj, VectorStyle style) {
    obj.style = style;
    obj.update();
  }

  /// Sets only the fill of an object.
  void setObjectFill(SelectableObject obj, FillDescriptor fill) {
    obj.style = obj.style.copyWith(fill: fill);
    obj.update();
  }

  /// Sets only the stroke of an object.
  void setObjectStroke(SelectableObject obj, StrokeDescriptor stroke) {
    obj.style = obj.style.copyWith(stroke: stroke);
    obj.update();
  }

  // --- Convenience creators ---

  /// Creates a rectangle object.
  VectorRectangle createRectangle({
    required double x,
    required double y,
    required double width,
    required double height,
    VectorStyle? style,
    List<double>? corners,
  }) {
    final rect = VectorRectangle(
      startX: x,
      startY: y,
      rectWidth: width,
      rectHeight: height,
      style: style ?? doc.defaultStyle,
      corners: corners,
    );
    rect.update();
    return rect;
  }

  /// Creates a circle/ellipse object.
  VectorCircle createCircle({
    required double cx,
    required double cy,
    required double rx,
    required double ry,
    VectorStyle? style,
    double angle1 = 0,
    double angle2 = 0,
    ArcType arcType = ArcType.chord,
  }) {
    return VectorCircle.fromRect(
      [cx, cy, rx * 2, ry * 2],
      angle1: angle1,
      angle2: angle2,
      arcType: arcType,
      style: style ?? doc.defaultStyle,
    )..update();
  }

  /// Creates a polygon/star object.
  VectorPolygon createPolygon({
    required double cx,
    required double cy,
    required double radius,
    int cornersNum = 5,
    double coef1 = 1.0,
    double coef2 = 1.0,
    VectorStyle? style,
  }) {
    final polygon = VectorPolygon(
      cornersNum: cornersNum,
      coef1: coef1,
      coef2: coef2,
      trafo: [radius * 2, 0.0, 0.0, radius * 2, cx, cy],
      style: style ?? doc.defaultStyle,
    );
    polygon.initialTrafo = List.of(polygon.trafo);
    polygon.update();
    return polygon;
  }

  /// Creates a curve from paths.
  VectorCurve createCurve({
    required List<VectorPath> paths,
    VectorStyle? style,
  }) {
    final curve = VectorCurve(
      paths: paths,
      style: style ?? doc.defaultStyle,
    );
    curve.update();
    return curve;
  }

  /// Creates a text object.
  VectorText createText({
    required String text,
    required double x,
    required double y,
    double width = kTextBlockWidth,
    VectorStyle? style,
  }) {
    final textObj = VectorText(
      textContent: text,
      trafo: [1.0, 0.0, 0.0, 1.0, x, y],
      width: width,
      style: style ?? doc.defaultTextStyle,
    );
    textObj.initialTrafo = List.of(textObj.trafo);
    textObj.update();
    return textObj;
  }
}
