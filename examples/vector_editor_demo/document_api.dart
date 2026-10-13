/// The editing operations of one document, every one of them undoable.
///
/// Undo is [DocumentHistory]'s: each operation is the document before and
/// after, so a change that touches many objects is one step, and nothing here
/// has to know how to reverse itself - the bug class that once left a group
/// un-redoable and a reorder un-undoable cannot recur.
library;

import 'package:dart_ui/dart_ui.dart';

/// Operations on a [VectorDocument], each recorded in its [history].
class DocumentApi {
  DocumentApi(this.doc)
      : methods = DocumentMethods(doc),
        history = DocumentHistory(doc);

  final VectorDocument doc;
  final DocumentMethods methods;
  final DocumentHistory history;

  bool get canUndo => history.canUndo;
  bool get canRedo => history.canRedo;
  String? get undoDescription => history.undoLabel;
  String? get redoDescription => history.redoLabel;

  void undo() => history.undo();
  void redo() => history.redo();

  /// Runs [change] as one undoable step.
  T record<T>(String description, T Function() change, {Object? coalesce}) =>
      history.record(description, change, coalesce: coalesce);

  /// Records a change something else already made - a drag the canvas
  /// applied live, an object a tool created, a text edited in place.
  void commit(String description) => history.commit(description);

  // --- Named operations ---

  /// Adds [obj] to [layer] (at [index], or on top).
  void addObject(VectorLayer layer, DocumentObject obj, [int index = -1]) =>
      record('Add ${_name(obj)}', () => methods.addObject(layer, obj, index));

  /// Removes [objects] from wherever they are.
  void removeObjects(Iterable<DocumentObject> objects) {
    final List<DocumentObject> list = objects.toList();
    if (list.isEmpty) return;
    record(list.length == 1 ? 'Delete ${_name(list.first)}' : 'Delete',
        () => list.forEach(methods.removeObject));
  }

  void removeObject(DocumentObject obj) => removeObjects(<DocumentObject>[obj]);

  /// Gives every object in [objects] the style [restyle] returns for it.
  void restyle(Iterable<SelectableObject> objects,
      VectorStyle Function(VectorStyle style) restyle) {
    record('Change style', () {
      for (final SelectableObject object in objects) {
        object.style = restyle(object.style);
        object.update();
      }
    });
  }

  void setObjectStyle(SelectableObject obj, VectorStyle newStyle) =>
      restyle(<SelectableObject>[obj], (_) => newStyle);

  /// Groups [objects], returning the new group.
  VectorGroup groupObjects(List<SelectableObject> objects) => record(
      'Group ${objects.length} objects', () => methods.groupObjects(objects));

  void ungroupObjects(VectorGroup group) =>
      record('Ungroup', () => methods.ungroupObjects(group));

  /// Applies [trafo] (document space) to each of [objects], as one step.
  void transform(Iterable<SelectableObject> objects, List<double> trafo,
      [String description = 'Transform']) {
    record(description, () {
      for (final SelectableObject object in objects) {
        object.applyTrafo(trafo);
      }
    });
  }

  void transformObject(SelectableObject obj, List<double> trafo) =>
      transform(<SelectableObject>[obj], trafo);

  /// Records an interactive move or resize that has already happened.
  void applySelectionEdit(SelectionEdit edit) => commit('Transform');

  /// Records an in-canvas text edit that has already happened.
  void setTextContent(VectorText object, String before, String after) {
    if (before == after) return;
    if (object.textContent != after) {
      object
        ..textContent = after
        ..update();
    }
    commit('Edit text');
  }

  static String _name(DocumentObject obj) => switch (obj) {
        VectorRectangle() => 'rectangle',
        VectorCircle() => 'ellipse',
        VectorPolygon() => 'polygon',
        VectorCurve() => 'curve',
        VectorText() => 'text',
        VectorGroup() => 'group',
        _ => 'object',
      };
}
