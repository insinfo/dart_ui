/// Undo and redo for a vector document, by state rather than by command.
library;

import 'document_object.dart';

/// The state of a document tree at one moment: who is whose child, in what
/// order, and every node's own fields.
///
/// Restoring puts the **same objects** back - a selection, a text editor or a
/// panel holding a reference to a node keeps a valid reference across undo.
/// That is the reason this records fields with [DocumentObject.copyFields]
/// into detached copies instead of deep-copying the tree: a deep copy would
/// hand back new objects, and every holder of an old one would be pointing
/// at something no longer in the document.
final class DocumentState {
  DocumentState._(this._root, this._children, this._parents, this._fields);

  /// Captures [root] and everything under it.
  factory DocumentState.capture(DocumentObject root) {
    final Map<DocumentObject, List<DocumentObject>> children =
        <DocumentObject, List<DocumentObject>>{};
    final Map<DocumentObject, DocumentObject?> parents =
        <DocumentObject, DocumentObject?>{};
    final Map<DocumentObject, DocumentObject> fields =
        <DocumentObject, DocumentObject>{};
    root.visitAll((DocumentObject node) {
      children[node] = List<DocumentObject>.of(node.children);
      parents[node] = node.parent;
      final DocumentObject copy = node.createEmpty();
      node.copyFields(copy);
      fields[node] = copy;
    });
    return DocumentState._(root, children, parents, fields);
  }

  final DocumentObject _root;
  final Map<DocumentObject, List<DocumentObject>> _children;
  final Map<DocumentObject, DocumentObject?> _parents;
  final Map<DocumentObject, DocumentObject> _fields;

  /// Whether [node] is part of this state's tree.
  bool contains(DocumentObject node) => _parents.containsKey(node);

  /// Puts the tree back as it was, then recomputes every cache.
  void restore() {
    _children.forEach((DocumentObject node, List<DocumentObject> list) {
      node.children
        ..clear()
        ..addAll(list);
    });
    _parents.forEach((DocumentObject node, DocumentObject? parent) {
      node.parent = parent;
    });
    _fields.forEach((DocumentObject node, DocumentObject saved) {
      saved.copyFields(node);
    });
    _root.update();
  }
}

/// One step of [DocumentHistory]: what it was called and the two ends.
final class _HistoryStep {
  _HistoryStep(this.label, this.before, this.after);

  final String label;
  final DocumentState before;
  final DocumentState after;
}

/// Undo and redo for everything that happens to a document.
///
/// Every step is the state before and the state after, so *any* change is
/// undoable - a move, a reorder, a group, an object a tool created, a drag
/// the canvas already applied live - without each operation having to know
/// how to reverse itself. Operations that touch many objects are one step,
/// because a step is a span of time and not an object.
///
/// Two ways to make a step:
///
/// * [record] runs a change and records it;
/// * [commit] records whatever changed since the previous step - for changes
///   something else already made, such as a drag applied as the pointer
///   moved.
///
/// The history keeps the state after the last step as its baseline, so a
/// change made without either call is folded into the next step rather than
/// lost. Call [reset] after replacing the document's content wholesale (a
/// load), so that is not undoable into an empty page.
final class DocumentHistory {
  DocumentHistory(this.root, {this.limit = 100})
      : _baseline = DocumentState.capture(root);

  final DocumentObject root;

  /// How many steps are kept; older ones are forgotten.
  final int limit;

  final List<_HistoryStep> _undo = <_HistoryStep>[];
  final List<_HistoryStep> _redo = <_HistoryStep>[];
  DocumentState _baseline;

  bool get canUndo => _undo.isNotEmpty;
  bool get canRedo => _redo.isNotEmpty;
  String? get undoLabel => _undo.isEmpty ? null : _undo.last.label;
  String? get redoLabel => _redo.isEmpty ? null : _redo.last.label;

  /// Runs [change] and records it as one step named [label].
  ///
  /// See [commit] for [coalesce].
  T record<T>(String label, T Function() change, {Object? coalesce}) {
    final T result = change();
    commit(label, coalesce: coalesce);
    return result;
  }

  /// Records everything that changed since the previous step.
  ///
  /// Consecutive commits with the same non-null [coalesce] key become one
  /// step - typing into a field is one undo, not one per key.
  void commit(String label, {Object? coalesce}) {
    // Inside [group] the steps are folded into the group's one: the baseline
    // stays where the group began, and [group] commits once at its end.
    if (_groupDepth > 0) {
      _groupChanged = true;
      return;
    }
    final DocumentState after = DocumentState.capture(root);
    if (coalesce != null &&
        coalesce == _lastCoalesce &&
        _undo.isNotEmpty &&
        _redo.isEmpty) {
      _undo[_undo.length - 1] = _HistoryStep(label, _undo.last.before, after);
    } else {
      _undo.add(_HistoryStep(label, _baseline, after));
      if (_undo.length > limit) _undo.removeAt(0);
    }
    _lastCoalesce = coalesce;
    _redo.clear();
    _baseline = after;
  }

  Object? _lastCoalesce;

  int _groupDepth = 0;

  /// Whether anything inside the running group recorded a step.
  bool _groupChanged = false;

  /// Whether a [group] is running.
  bool get isGrouping => _groupDepth > 0;

  /// Runs [body] as **one** step named [label], however many steps the
  /// operations inside it record - a batch of commands, a script, a macro.
  ///
  /// Groups nest; only the outermost commits. Nothing is recorded when no
  /// operation inside recorded anything. Undo and redo are refused while a group runs:
  /// they would move the baseline the group is measured from.
  T group<T>(String label, T Function() body) {
    if (_groupDepth == 0) _groupChanged = false;
    _groupDepth++;
    try {
      return body();
    } finally {
      _groupDepth--;
      if (_groupDepth == 0) _commitIfChanged(label);
    }
  }

  void _commitIfChanged(String label) {
    if (!_groupChanged) return;
    _groupChanged = false;
    _lastCoalesce = null;
    commit(label);
  }

  /// Puts the document back to the previous step; false when there is none.
  bool undo() {
    if (_undo.isEmpty || _groupDepth > 0) return false;
    final _HistoryStep step = _undo.removeLast();
    _lastCoalesce = null;
    step.before.restore();
    _baseline = step.before;
    _redo.add(step);
    return true;
  }

  /// Re-applies the step [undo] took back; false when there is none.
  bool redo() {
    if (_redo.isEmpty || _groupDepth > 0) return false;
    final _HistoryStep step = _redo.removeLast();
    _lastCoalesce = null;
    step.after.restore();
    _baseline = step.after;
    _undo.add(step);
    return true;
  }

  /// Whether [node] is in the document as of the last step - what a
  /// selection asks after an undo removed an object it was holding.
  bool isLive(DocumentObject node) => _baseline.contains(node);

  /// Forgets every step and takes the current document as the start.
  void reset() {
    _undo.clear();
    _redo.clear();
    _baseline = DocumentState.capture(root);
  }
}
