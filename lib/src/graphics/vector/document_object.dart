import '../../geometry/rect.dart';


/// Base class for all nodes in the vector document tree.
///
/// The tree is doubly-linked: each node has a [parent] pointer and a [children]
/// list. The root [VectorDocument] has `parent == null`.
abstract class DocumentObject {
  DocumentObject({this.parent, List<DocumentObject>? children})
      : children = children ?? [];

  /// The parent node, or `null` for the root [VectorDocument].
  DocumentObject? parent;

  /// Child nodes in draw order (first painted first, i.e. bottom to top).
  final List<DocumentObject> children;

  /// Cached bounding box in local coordinates, updated by [updateBbox].
  Rect cacheBbox = Rect.zero;

  // --- Type flags (overridden by subclasses) ---

  bool get isLayer => false;
  bool get isGuideLayer => false;
  bool get isGridLayer => false;
  bool get isGuide => false;
  bool get isPrimitive => false;
  bool get isCurve => false;
  bool get isRect => false;
  bool get isPixmap => false;
  bool get isCircle => false;
  bool get isPolygon => false;
  bool get isText => false;
  bool get isGroup => false;
  bool get isTPGroup => false;
  bool get isContainer => false;
  bool get isSelectable => false;

  /// Human-readable class name for debug / tree inspectors.
  String get className => runtimeType.toString();

  /// Resolve for tree view: `(isLeaf, displayName, info)`.
  (bool, String, String) resolve([String name = '']) {
    final n = name.isEmpty ? className : name;
    if (isSelectable || isPrimitive) {
      return (true, n, '');
    }
    return (false, n, '${children.length}');
  }

  // --- Deep copy ---

  /// Creates a deep copy of this object (and all children).
  ///
  /// Subclasses must override [copyFields] to clone their own fields.
  DocumentObject copy() {
    final clone = createEmpty();
    copyFields(clone);
    for (final child in children) {
      final childClone = child.copy();
      childClone.parent = clone;
      clone.children.add(childClone);
    }
    return clone;
  }

  /// Factory that creates an uninitialised instance of the same type.
  DocumentObject createEmpty();

  /// Copies mutable fields (except [children] and [parent]) into [target].
  void copyFields(DocumentObject target) {
    target.cacheBbox = cacheBbox;
  }

  // --- Updates ---

  /// Recalculates caches (bounding box, etc.) for this node and descendants.
  void update() {
    for (final child in children) {
      child.update();
    }
  }

  /// Clears any cached colour images (e.g. pattern thumbnails).
  void clearColorCache() {
    for (final child in children) {
      child.clearColorCache();
    }
  }

  /// Recalculate the bounding box from children.
  void updateBbox() {
    if (children.isEmpty) {
      cacheBbox = Rect.zero;
      return;
    }
    var bbox = children.first.cacheBbox;
    for (var i = 1; i < children.length; i++) {
      bbox = _unionRect(bbox, children[i].cacheBbox);
    }
    cacheBbox = bbox;
  }

  // --- Tree queries ---

  /// Walk the tree depth-first, calling [visitor] for each node.
  void visitAll(void Function(DocumentObject node) visitor) {
    visitor(this);
    for (final child in children) {
      child.visitAll(visitor);
    }
  }

  /// Find all descendants where [test] returns true.
  List<DocumentObject> findAll(bool Function(DocumentObject) test) {
    final results = <DocumentObject>[];
    visitAll((node) {
      if (test(node)) results.add(node);
    });
    return results;
  }

  /// Returns the depth (distance from root) of this node.
  int get depth {
    var d = 0;
    var node = parent;
    while (node != null) {
      d++;
      node = node.parent;
    }
    return d;
  }

  @override
  String toString() => '$className(children: ${children.length})';
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

Rect _unionRect(Rect a, Rect b) {
  if (a == Rect.zero) return b;
  if (b == Rect.zero) return a;
  return Rect.fromLTRB(
    a.left < b.left ? a.left : b.left,
    a.top < b.top ? a.top : b.top,
    a.right > b.right ? a.right : b.right,
    a.bottom > b.bottom ? a.bottom : b.bottom,
  );
}
