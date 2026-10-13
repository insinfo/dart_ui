/// Transactional document editing API with Undo/Redo history stack.
library;

import 'package:dart_ui/dart_ui.dart';

/// An undoable/redoable document mutation action.
abstract class DocumentAction {
  String get description;
  void execute();
  void undo();
}

/// Generic action wrapping an execute callback and an undo callback.
class GenericAction extends DocumentAction {
  GenericAction({
    required this.description,
    required this.onExecute,
    required this.onUndo,
  });

  @override
  final String description;
  final void Function() onExecute;
  final void Function() onUndo;

  @override
  void execute() => onExecute();

  @override
  void undo() => onUndo();
}

/// Transactional API and command history manager for [VectorDocument].
class DocumentApi {
  DocumentApi(this.doc) : methods = DocumentMethods(doc);

  final VectorDocument doc;
  final DocumentMethods methods;

  final List<DocumentAction> _undoStack = [];
  final List<DocumentAction> _redoStack = [];
  static const int maxHistory = 100;

  bool get canUndo => _undoStack.isNotEmpty;
  bool get canRedo => _redoStack.isNotEmpty;

  String? get undoDescription =>
      _undoStack.isNotEmpty ? _undoStack.last.description : null;
  String? get redoDescription =>
      _redoStack.isNotEmpty ? _redoStack.last.description : null;

  /// Applies and records an action.
  void apply(DocumentAction action) {
    action.execute();
    _undoStack.add(action);
    _redoStack.clear();
    if (_undoStack.length > maxHistory) {
      _undoStack.removeAt(0);
    }
  }

  /// Undoes the last action.
  void undo() {
    if (!canUndo) return;
    final action = _undoStack.removeLast();
    action.undo();
    _redoStack.add(action);
  }

  /// Redoes the previously undone action.
  void redo() {
    if (!canRedo) return;
    final action = _redoStack.removeLast();
    action.execute();
    _undoStack.add(action);
  }

  // --- High-level transactional commands ---

  /// Adds an object to the active layer with undo support.
  void addObject(VectorLayer layer, DocumentObject obj) {
    apply(GenericAction(
      description: 'Add ${obj.runtimeType}',
      onExecute: () => methods.addObject(layer, obj),
      onUndo: () => methods.removeObject(obj),
    ));
  }

  /// Removes an object with undo support.
  void removeObject(DocumentObject obj) {
    final parent = obj.parent;
    if (parent is! VectorLayer) return;
    final index = parent.children.indexOf(obj);

    apply(GenericAction(
      description: 'Delete ${obj.runtimeType}',
      onExecute: () => methods.removeObject(obj),
      onUndo: () => methods.addObject(parent, obj, index),
    ));
  }

  /// Changes the style of an object with undo support.
  void setObjectStyle(SelectableObject obj, VectorStyle newStyle) {
    final oldStyle = obj.style;
    apply(GenericAction(
      description: 'Change style',
      onExecute: () => methods.setObjectStyle(obj, newStyle),
      onUndo: () => methods.setObjectStyle(obj, oldStyle),
    ));
  }

  /// Groups [objects] with undo support, and returns the new group.
  VectorGroup groupObjects(List<SelectableObject> objects) {
    final members = List<DocumentObject>.of(objects);
    final parent = members.first.parent;
    final group = methods.groupObjects(objects);
    final index = parent?.children.indexOf(group) ?? -1;
    apply(GenericAction(
      description: 'Group ${members.length} objects',
      // The first `execute` finds the group already built; a redo rebuilds
      // it from the same members, where the undo scattered them.
      onExecute: () {
        if (parent is VectorLayer && !parent.children.contains(group)) {
          _regroup(group, members, parent, index);
        }
      },
      onUndo: () => methods.ungroupObjects(group),
    ));
    return group;
  }

  /// Ungroups [group] with undo support.
  void ungroupObjects(VectorGroup group) {
    final parent = group.parent;
    final index = parent?.children.indexOf(group) ?? -1;
    final members = List<DocumentObject>.of(group.children);
    methods.ungroupObjects(group);
    apply(GenericAction(
      description: 'Ungroup',
      // Already ungrouped the first time; a redo does it again.
      onExecute: () {
        if (parent != null && parent.children.contains(group)) {
          methods.ungroupObjects(group);
        }
      },
      onUndo: () {
        if (parent is VectorLayer) _regroup(group, members, parent, index);
      },
    ));
  }

  /// Puts [members] back into [group] and the group back at [index].
  ///
  /// `DocumentMethods.ungroupObjects` leaves the group's `parent` pointing at
  /// the layer it left, so whether a group is in the document is asked of
  /// the layer's children, never of `group.parent`.
  void _regroup(
    VectorGroup group,
    List<DocumentObject> members,
    VectorLayer parent,
    int index,
  ) {
    for (final member in members) {
      methods.removeObject(member);
    }
    group.children
      ..clear()
      ..addAll(members);
    for (final member in members) {
      member.parent = group;
    }
    methods.addObject(parent, group, index);
    group.update();
  }

  /// Records an interactive move or resize that has *already happened*.
  ///
  /// The canvas applies a drag live, because the user has to see the shape
  /// follow the pointer; what the history needs is not the operation but its
  /// two ends. [SelectionEdit] carries both, so one drag - however many pointer
  /// events it took - is one entry, and the first `execute` is a no-op replay
  /// of the state the document is already in.
  void applySelectionEdit(SelectionEdit edit) {
    apply(GenericAction(
      description: 'Transform',
      onExecute: edit.redo,
      onUndo: edit.undo,
    ));
  }

  /// Records an in-canvas text edit as one undoable step.
  void setTextContent(VectorText object, String before, String after) {
    apply(GenericAction(
      description: 'Edit text',
      onExecute: () => object
        ..textContent = after
        ..update(),
      onUndo: () => object
        ..textContent = before
        ..update(),
    ));
  }

  /// Transforms an object with undo support.
  void transformObject(SelectableObject obj, List<double> trafo) {
    final oldTrafo = List<double>.from(obj.trafo);
    apply(GenericAction(
      description: 'Transform',
      onExecute: () => obj.applyTrafo(trafo),
      onUndo: () {
        obj.trafo = List.from(oldTrafo);
        obj.update();
      },
    ));
  }
}
