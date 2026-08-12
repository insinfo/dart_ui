/// The semantic tree: what assistive technology sees.
///
/// Section 31.1 is emphatic that this is a *separate* tree, not a projection of
/// the visual one, and the reason shows up immediately: a button drawn as three
/// nested boxes with a label inside is one node here, and a decorative
/// container that exists only to add padding is no node at all. Screen readers
/// read this tree; nothing about it should depend on how many render objects a
/// control happened to need.
///
/// Two properties are load-bearing:
///
///   * **ids are stable across frames.** An assistive client holds an id
///     between calls; regenerating them per frame would make every update look
///     like the entire window was replaced. [SemanticsOwner] keys ids by
///     render-object identity for exactly that reason;
///   * **updates are incremental** (section 31.4). A rebuild reports which
///     nodes changed, so a platform bridge sends one property update instead of
///     a whole tree.
library;

import '../geometry/offset.dart';
import '../geometry/rect.dart';
import '../layout/render_box.dart';

enum SemanticsRole {
  generic,
  button,
  toggleButton,
  checkbox,
  radio,
  slider,
  progressBar,
  textField,
  list,
  listItem,
  menu,
  menuItem,
  dialog,
  tooltip,
  scrollView,
  image,
  text,
}

enum SemanticsState {
  disabled,
  checked,
  mixed,
  selected,
  focused,
  expanded,
  readOnly,
  required,
  invalid,
  modal,
  obscured,
}

enum SemanticsAction {
  focus,
  activate,
  setValue,
  increment,
  decrement,
  scrollUp,
  scrollDown,
  scrollLeft,
  scrollRight,
  dismiss,
  showMenu,
}

/// What one render object declares about itself, before positioning.
///
/// A configuration is not a node: it has no id and no absolute bounds, because
/// a render object knows neither. Keeping the two apart is what lets a control
/// describe itself once and be laid out anywhere.
final class SemanticsConfiguration {
  const SemanticsConfiguration({
    required this.role,
    this.label,
    this.value,
    this.hint,
    this.states = const <SemanticsState>{},
    this.actions = const <SemanticsAction>{},
    this.increasedValue,
    this.decreasedValue,
    this.sortKey,
    this.isBlocking = false,
    this.mergesDescendants = false,
  });

  final SemanticsRole role;
  final String? label;
  final String? value;
  final String? hint;
  final Set<SemanticsState> states;
  final Set<SemanticsAction> actions;

  /// The value an `increment` would produce, which screen readers announce
  /// before performing it.
  final String? increasedValue;
  final String? decreasedValue;

  /// Overrides reading order when it must differ from paint order.
  final int? sortKey;

  /// Whether descendants are hidden from assistive technology, as a modal
  /// dialog hides the window behind it.
  final bool isBlocking;

  /// Whether descendant semantics fold into this node - a button absorbing
  /// its own label rather than exposing it as a separate text node.
  final bool mergesDescendants;
}

/// A render object that contributes a node to the semantic tree.
abstract interface class SemanticsProvider {
  SemanticsConfiguration describeSemantics();
}

/// One node in the semantic tree.
final class SemanticsNode {
  const SemanticsNode({
    required this.id,
    required this.role,
    required this.bounds,
    this.label,
    this.value,
    this.hint,
    this.states = const <SemanticsState>{},
    this.actions = const <SemanticsAction>{},
    this.children = const <SemanticsNode>[],
  });

  final int id;
  final SemanticsRole role;

  /// Bounds in the root's coordinate space, which is what a platform bridge
  /// converts to screen coordinates.
  final Rect bounds;

  final String? label;
  final String? value;
  final String? hint;
  final Set<SemanticsState> states;
  final Set<SemanticsAction> actions;
  final List<SemanticsNode> children;

  /// Whether the two nodes differ in anything a client would need to be told
  /// about, ignoring children - which are diffed separately.
  bool hasSameProperties(SemanticsNode other) =>
      other.role == role &&
      other.bounds == bounds &&
      other.label == label &&
      other.value == value &&
      other.hint == hint &&
      _setEquals(other.states, states) &&
      _setEquals(other.actions, actions);

  /// This node and every descendant, in reading order.
  Iterable<SemanticsNode> get flattened sync* {
    yield this;
    for (final SemanticsNode child in children) {
      yield* child.flattened;
    }
  }

  @override
  bool operator ==(Object other) =>
      other is SemanticsNode &&
      other.id == id &&
      hasSameProperties(other) &&
      _listEquals(other.children, children);

  @override
  int get hashCode => Object.hash(
        id,
        role,
        bounds,
        label,
        value,
        hint,
        Object.hashAllUnordered(states),
        Object.hashAllUnordered(actions),
        Object.hashAll(children),
      );

  @override
  String toString() =>
      'SemanticsNode($id, ${role.name}${label == null ? '' : ', "$label"'})';
}

/// A whole tree at one point in time.
final class SemanticsSnapshot {
  const SemanticsSnapshot(this.root);

  final SemanticsNode? root;

  /// Every node, in reading order.
  List<SemanticsNode> get nodes =>
      root == null ? const <SemanticsNode>[] : root!.flattened.toList();

  /// The node with [id], or null.
  SemanticsNode? nodeById(int id) {
    for (final SemanticsNode node in nodes) {
      if (node.id == id) return node;
    }
    return null;
  }
}

/// What changed between two snapshots.
final class SemanticsUpdate {
  const SemanticsUpdate({
    required this.added,
    required this.updated,
    required this.removed,
  });

  final List<SemanticsNode> added;
  final List<SemanticsNode> updated;
  final List<int> removed;

  bool get isEmpty => added.isEmpty && updated.isEmpty && removed.isEmpty;

  @override
  String toString() => 'SemanticsUpdate(+${added.length}, '
      '~${updated.length}, -${removed.length})';
}

/// Builds and diffs the semantic tree for one render tree.
///
/// Owning the id table is the whole job: an owner hands the same id to the
/// same render object for as long as that object lives, and reuses an id only
/// after the object it belonged to is gone.
final class SemanticsOwner {
  final Map<RenderBox, int> _ids = Map<RenderBox, int>.identity();
  int _nextId = 1;

  SemanticsSnapshot _last = const SemanticsSnapshot(null);

  /// The most recently built tree.
  SemanticsSnapshot get snapshot => _last;

  /// The id assigned to [node], allocating one on first sight.
  int idFor(RenderBox node) => _ids[node] ??= _nextId++;

  /// Walks [root] and produces the current tree.
  ///
  /// Render objects that do not implement [SemanticsProvider] are transparent:
  /// their children attach to the nearest ancestor that does. That is what
  /// keeps padding and alignment out of a screen reader's way.
  SemanticsSnapshot build(RenderBox? root) {
    if (root == null || !root.hasSize) {
      _last = const SemanticsSnapshot(null);
      return _last;
    }
    final List<SemanticsNode> top = <SemanticsNode>[];
    _visit(root, Offset.zero, top);
    _applySortKeys(top);
    final SemanticsNode? rootNode;
    if (top.length == 1) {
      rootNode = top.single;
    } else {
      // A synthetic root keeps the tree single-rooted without inventing an id
      // that could collide with a render object's.
      rootNode = SemanticsNode(
        id: 0,
        role: SemanticsRole.generic,
        bounds: Rect.fromLTWH(0, 0, root.size.width, root.size.height),
        children: top,
      );
    }
    _last = SemanticsSnapshot(rootNode);
    _prune(root);
    return _last;
  }

  void _visit(RenderBox node, Offset offset, List<SemanticsNode> into) {
    if (!node.hasSize) return;
    final SemanticsConfiguration? config = node is SemanticsProvider
        ? (node as SemanticsProvider).describeSemantics()
        : null;
    if (config == null) {
      // Transparent: the children attach to whatever the caller is filling,
      // so they are *not* sorted here - reading order is decided by the
      // nearest node that actually owns them.
      node.visitChildren((RenderBox child) {
        final Offset childOffset = child.offsetFromParent;
        _visit(
          child,
          Offset(offset.dx + childOffset.dx, offset.dy + childOffset.dy),
          into,
        );
      });
      return;
    }
    final List<SemanticsNode> children = <SemanticsNode>[];
    if (!config.mergesDescendants) {
      node.visitChildren((RenderBox child) {
        final Offset childOffset = child.offsetFromParent;
        _visit(
          child,
          Offset(offset.dx + childOffset.dx, offset.dy + childOffset.dy),
          children,
        );
      });
      _applySortKeys(children);
    }
    final int id = idFor(node);
    if (config.sortKey != null) _sortKeys[id] = config.sortKey;
    into.add(SemanticsNode(
      id: id,
      role: config.role,
      bounds: Rect.fromLTWH(
        offset.dx,
        offset.dy,
        node.size.width,
        node.size.height,
      ),
      label: config.label,
      value: config.value,
      hint: config.hint,
      states: config.states,
      actions: config.actions,
      children: children,
    ));
  }

  final Map<int, int?> _sortKeys = <int, int?>{};

  /// Reorders [nodes] by their declared sort keys.
  ///
  /// Reading order is paint order unless something asked otherwise, which is
  /// the only case worth a sort. Nodes without a key keep their relative
  /// position by sorting as key 0 with a stable tiebreak on the original
  /// index - Dart's sort is not stable, and an unstable reading order would
  /// move a screen reader's cursor for no reason between frames.
  void _applySortKeys(List<SemanticsNode> nodes) {
    if (!nodes.any((SemanticsNode node) => _sortKeys[node.id] != null)) return;
    final List<(SemanticsNode, int, int)> decorated =
        <(SemanticsNode, int, int)>[
      for (int i = 0; i < nodes.length; i++)
        (nodes[i], _sortKeys[nodes[i].id] ?? 0, i),
    ]..sort(((SemanticsNode, int, int) a, (SemanticsNode, int, int) b) {
            final int byKey = a.$2.compareTo(b.$2);
            return byKey != 0 ? byKey : a.$3.compareTo(b.$3);
          });
    for (int i = 0; i < nodes.length; i++) {
      nodes[i] = decorated[i].$1;
    }
  }

  /// Builds the tree and reports what changed against the previous build.
  ///
  /// The diff is by id, so a node that moved in the tree but kept its identity
  /// is an update rather than a remove-plus-add - which is what an assistive
  /// client needs to keep its cursor where the user left it.
  SemanticsUpdate update(RenderBox? root) {
    final Map<int, SemanticsNode> before = <int, SemanticsNode>{
      for (final SemanticsNode node in _last.nodes) node.id: node,
    };
    final SemanticsSnapshot after = build(root);
    final List<SemanticsNode> added = <SemanticsNode>[];
    final List<SemanticsNode> updated = <SemanticsNode>[];
    final Set<int> survivors = <int>{};
    for (final SemanticsNode node in after.nodes) {
      survivors.add(node.id);
      final SemanticsNode? previous = before[node.id];
      if (previous == null) {
        added.add(node);
      } else if (!previous.hasSameProperties(node)) {
        updated.add(node);
      }
    }
    final List<int> removed = <int>[
      for (final int id in before.keys)
        if (!survivors.contains(id)) id,
    ];
    return SemanticsUpdate(added: added, updated: updated, removed: removed);
  }

  /// Forgets ids for render objects no longer in the tree, so a long-running
  /// application does not accumulate one entry per control it ever showed.
  void _prune(RenderBox root) {
    final Set<RenderBox> live = Set<RenderBox>.identity();
    void walk(RenderBox node) {
      live.add(node);
      node.visitChildren(walk);
    }

    walk(root);
    _ids.removeWhere((RenderBox node, int id) {
      if (live.contains(node)) return false;
      _sortKeys.remove(id);
      return true;
    });
  }

  void reset() {
    _ids.clear();
    _sortKeys.clear();
    _last = const SemanticsSnapshot(null);
    _nextId = 1;
  }
}

bool _setEquals<T>(Set<T> a, Set<T> b) =>
    a.length == b.length && a.containsAll(b);

bool _listEquals<T>(List<T> a, List<T> b) {
  if (a.length != b.length) return false;
  for (int i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
