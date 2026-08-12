/// Focus: who receives the keyboard, and how that moves.
///
/// Section 27.7 of the roadmap asks for a focus *tree*, not a focused pointer.
/// The difference matters in three places that a single field cannot express:
///
///   * a scope remembers which of its children was focused, so closing a
///     dialog restores the control that opened it rather than the first one;
///   * a modal scope traps traversal, so Tab in a dialog cannot walk into the
///     window behind it;
///   * accessibility focus is a separate cursor from keyboard focus, because a
///     screen reader may explore a tree the keyboard has not moved into.
///
/// Focus here is deliberately independent of the render tree. A node knows its
/// traversal order and its scope; whether it currently paints a focus ring is
/// the control's business, which reads [FocusNode.hasPrimaryFocus].
library;

import '../platform/input_events.dart';
import 'keyboard_router.dart';

/// Why focus moved. A control paints a focus ring for keyboard traversal but
/// usually not for a mouse click, which is the `:focus-visible` distinction in
/// section 28.3.
enum FocusChangeReason {
  /// Explicit `requestFocus`, from code.
  programmatic,

  /// Tab / Shift+Tab / arrow traversal.
  traversal,

  /// A pointer press landed on the control.
  pointer,

  /// A scope restored the child it had remembered.
  restoration,
}

/// A direction for directional (arrow-key) navigation.
enum TraversalDirection { up, down, left, right, next, previous }

/// One focusable location.
///
/// Nodes form a tree that parallels the widget tree but contains only
/// focusable things, so traversal is a walk over what can actually be focused
/// rather than a filtered walk over everything.
class FocusNode {
  FocusNode({
    this.debugLabel,
    bool canRequestFocus = true,
    bool skipTraversal = false,
    KeyboardEventTarget? target,
  })  : _canRequestFocus = canRequestFocus,
        _skipTraversal = skipTraversal,
        _target = target;

  /// Names the node in diagnostics only.
  final String? debugLabel;

  KeyboardEventTarget? _target;

  /// The object that will actually receive key events while this node holds
  /// primary focus. Null for a node that only groups others.
  ///
  /// Mutable, and it has to be: a control's [FocusNode] belongs to its `State`
  /// and outlives the render object that receives the keys. The node is
  /// created first and adopts its target when the render object appears, and
  /// re-points if the render object is replaced.
  KeyboardEventTarget? get target => _target;

  set target(KeyboardEventTarget? value) {
    if (identical(value, _target)) return;
    _target = value;
    // If this node holds focus right now, the router is still pointing at the
    // previous target - which is about to stop receiving keys for a control
    // the user can see is focused.
    if (_hasPrimaryFocus) _manager?._retarget(this);
  }

  final List<FocusNode> _children = <FocusNode>[];
  final List<void Function(FocusNode node)> _listeners =
      <void Function(FocusNode node)>[];

  FocusNode? _parent;
  FocusManager? _manager;
  bool _canRequestFocus;
  bool _skipTraversal;
  bool _hasPrimaryFocus = false;
  FocusChangeReason _reason = FocusChangeReason.programmatic;

  FocusNode? get parent => _parent;

  List<FocusNode> get children => List<FocusNode>.unmodifiable(_children);

  FocusManager? get manager => _manager;

  /// Whether this node is willing to take focus. A disabled control sets this
  /// false, which also removes it from traversal without reordering anything.
  bool get canRequestFocus => _canRequestFocus;

  set canRequestFocus(bool value) {
    if (value == _canRequestFocus) return;
    _canRequestFocus = value;
    if (!value && _hasPrimaryFocus) _manager?._focusChanged(null, _reason);
  }

  /// Whether Tab skips this node. A node can be focusable by click yet not
  /// participate in the tab ring - a text label with a selection, a toolbar
  /// that is reached by arrow keys from its first button.
  bool get skipTraversal => _skipTraversal;

  set skipTraversal(bool value) {
    if (value == _skipTraversal) return;
    _skipTraversal = value;
    _notify();
  }

  /// Whether this exact node holds focus, as opposed to a descendant.
  bool get hasPrimaryFocus => _hasPrimaryFocus;

  /// Whether this node or any descendant holds focus. This is what a container
  /// paints a "contains focus" affordance from.
  bool get hasFocus {
    if (_hasPrimaryFocus) return true;
    for (final FocusNode child in _children) {
      if (child.hasFocus) return true;
    }
    return false;
  }

  /// Why focus last arrived here.
  FocusChangeReason get focusChangeReason => _reason;

  /// Whether a focus ring should be painted: keyboard traversal shows one,
  /// a mouse click does not.
  bool get isFocusVisible =>
      _hasPrimaryFocus &&
      (_reason == FocusChangeReason.traversal ||
          _reason == FocusChangeReason.restoration);

  /// The nearest enclosing scope, or null before this node is attached.
  FocusScopeNode? get enclosingScope {
    for (FocusNode? node = _parent; node != null; node = node._parent) {
      if (node is FocusScopeNode) return node;
    }
    return null;
  }

  void addListener(void Function(FocusNode node) listener) =>
      _listeners.add(listener);

  void removeListener(void Function(FocusNode node) listener) =>
      _listeners.remove(listener);

  /// Adds [child] as the last child in traversal order.
  void add(FocusNode child) => insert(child, index: _children.length);

  void insert(FocusNode child, {required int index}) {
    if (identical(child, this)) {
      throw StateError('a FocusNode cannot contain itself');
    }
    if (child._parent != null) {
      throw StateError(
        'FocusNode(${child.debugLabel}) already has a parent; remove it first',
      );
    }
    for (FocusNode? ancestor = this;
        ancestor != null;
        ancestor = ancestor._parent) {
      if (identical(ancestor, child)) {
        throw StateError('inserting FocusNode(${child.debugLabel}) would '
            'create a cycle');
      }
    }
    _children.insert(index, child);
    child._parent = this;
    child._attach(_manager);
  }

  void remove(FocusNode child) {
    if (!_children.remove(child)) {
      throw StateError('FocusNode(${child.debugLabel}) is not a child here');
    }
    child._parent = null;
    child._detach();
  }

  /// Detaches this node from its parent and gives up focus if it held it.
  void dispose() {
    _parent?.remove(this);
    _detach();
    _listeners.clear();
  }

  void _attach(FocusManager? manager) {
    _manager = manager;
    for (final FocusNode child in _children) {
      child._attach(manager);
    }
  }

  void _detach() {
    final FocusManager? manager = _manager;
    if (manager != null && manager.primaryFocus != null) {
      // Only the node that actually holds focus surrenders it; a sibling
      // unmounting must not steal focus away from the node that has it.
      for (FocusNode? node = manager.primaryFocus;
          node != null;
          node = node._parent) {
        if (identical(node, this)) {
          manager._focusChanged(null, FocusChangeReason.programmatic);
          break;
        }
      }
    }
    _manager = null;
    _hasPrimaryFocus = false;
    for (final FocusNode child in _children) {
      child._detach();
    }
  }

  /// Asks the manager to move focus here.
  ///
  /// Returns false when this node refuses focus ([canRequestFocus] false, or
  /// not attached to a manager). Requesting focus on a scope focuses the child
  /// it remembers, or its first focusable descendant.
  bool requestFocus([
    FocusChangeReason reason = FocusChangeReason.programmatic,
  ]) {
    final FocusManager? manager = _manager;
    if (manager == null) return false;
    return manager._requestFocus(this, reason);
  }

  /// Gives up focus, letting the enclosing scope decide where it goes.
  void unfocus() {
    if (!_hasPrimaryFocus) return;
    _manager?._focusChanged(null, FocusChangeReason.programmatic);
  }

  void _notify() {
    for (final void Function(FocusNode) listener
        in List<void Function(FocusNode)>.of(_listeners)) {
      listener(this);
    }
  }

  @override
  String toString() =>
      'FocusNode(${debugLabel ?? 'unnamed'}${_hasPrimaryFocus ? ', focused' : ''})';
}

/// A focus node that also owns a traversal region and a memory.
final class FocusScopeNode extends FocusNode {
  FocusScopeNode({
    super.debugLabel,
    this.modal = false,
    super.canRequestFocus,
    super.skipTraversal = true,
  });

  /// Whether traversal is trapped inside this scope.
  ///
  /// A modal dialog sets this: Tab from the last control wraps to the first
  /// one *of the dialog*, never into the window behind it. This is a
  /// correctness property, not a nicety - keyboard users can otherwise drive
  /// a window that a modal claims to be blocking.
  final bool modal;

  FocusNode? _rememberedChild;

  /// The descendant this scope will restore focus to.
  FocusNode? get rememberedChild => _rememberedChild;

  /// Focuses the remembered child, or the first focusable descendant.
  bool focusRemembered() {
    final FocusNode? remembered = _rememberedChild;
    if (remembered != null &&
        remembered._manager != null &&
        remembered.canRequestFocus) {
      return remembered.requestFocus(FocusChangeReason.restoration);
    }
    final FocusNode? first = _traversableDescendants(this).firstOrNull;
    if (first == null) return false;
    return first.requestFocus(FocusChangeReason.restoration);
  }
}

/// Owns primary focus for one window, and moves it.
final class FocusManager {
  FocusManager({FocusScopeNode? rootScope, KeyboardRouter? router})
      : rootScope = rootScope ?? FocusScopeNode(debugLabel: 'root'),
        _router = router {
    this.rootScope._attach(this);
  }

  /// The scope every other node hangs beneath.
  final FocusScopeNode rootScope;

  final KeyboardRouter? _router;
  final List<void Function(FocusNode? node)> _listeners =
      <void Function(FocusNode? node)>[];

  FocusNode? _primaryFocus;
  bool _windowActive = true;

  /// The node currently receiving key events, if any.
  FocusNode? get primaryFocus => _primaryFocus;

  /// Whether the owning window is active.
  ///
  /// An inactive window keeps its focus *assignment* - so activating it again
  /// restores the same control - but reports `:window-inactive` so controls
  /// can dim their focus ring, per section 28.3.
  bool get isWindowActive => _windowActive;

  set isWindowActive(bool value) {
    if (value == _windowActive) return;
    _windowActive = value;
    _primaryFocus?._notify();
    _notify();
  }

  void addListener(void Function(FocusNode? node) listener) =>
      _listeners.add(listener);

  void removeListener(void Function(FocusNode? node) listener) =>
      _listeners.remove(listener);

  /// Re-points the keyboard router at [node]'s current target.
  void _retarget(FocusNode node) {
    if (!identical(node, _primaryFocus)) return;
    final KeyboardEventTarget? target = node.target;
    if (target == null) return;
    _router?.requestFocus(target);
  }

  bool _requestFocus(FocusNode node, FocusChangeReason reason) {
    if (node is FocusScopeNode) return node.focusRemembered();
    if (!node.canRequestFocus || node._manager == null) return false;
    if (identical(node, _primaryFocus)) {
      node._reason = reason;
      return true;
    }
    if (!_isReachable(node)) return false;
    _focusChanged(node, reason);
    return true;
  }

  /// Whether a modal scope currently blocks focus from reaching [node].
  ///
  /// The innermost modal scope that is an ancestor of the *current* focus wins;
  /// anything outside it is unreachable until the modal goes away.
  bool _isReachable(FocusNode node) {
    final FocusScopeNode? modal = _activeModalScope();
    if (modal == null) return true;
    for (FocusNode? ancestor = node;
        ancestor != null;
        ancestor = ancestor._parent) {
      if (identical(ancestor, modal)) return true;
    }
    return false;
  }

  FocusScopeNode? _activeModalScope() {
    FocusScopeNode? found;
    void visit(FocusNode node) {
      if (node is FocusScopeNode && node.modal) found = node;
      for (final FocusNode child in node._children) {
        visit(child);
      }
    }

    visit(rootScope);
    return found;
  }

  void _focusChanged(FocusNode? node, FocusChangeReason reason) {
    final FocusNode? previous = _primaryFocus;
    if (identical(previous, node)) return;
    if (previous != null) {
      previous._hasPrimaryFocus = false;
      final KeyboardEventTarget? target = previous.target;
      if (target != null) _router?.clearFocus(target);
      previous._notify();
    }
    _primaryFocus = node;
    if (node != null) {
      node
        .._hasPrimaryFocus = true
        .._reason = reason;
      // Every enclosing scope remembers this node, so restoring focus after a
      // dialog closes lands on the control that was actually in use.
      for (FocusNode? ancestor = node._parent;
          ancestor != null;
          ancestor = ancestor._parent) {
        if (ancestor is FocusScopeNode) ancestor._rememberedChild = node;
      }
      final KeyboardEventTarget? target = node.target;
      if (target != null) _router?.requestFocus(target);
      node._notify();
    }
    _notify();
  }

  /// Supplies the visual order that tab order must follow.
  ///
  /// Without this the ring would be in *attachment* order, which is the order
  /// elements happened to build - and builds are ordered by depth, so a
  /// control nested one level deeper than its neighbour attaches later and
  /// would be tabbed to later. That produces a tab order that is stable,
  /// plausible, and wrong: it jumps around the window for no reason the user
  /// can see. The owner sets this to a walk of the render tree, which is in
  /// paint order and therefore in widget order.
  List<KeyboardEventTarget> Function()? traversalOrderProvider;

  /// The traversal ring, in tab order.
  ///
  /// Trapped inside the innermost modal scope when one exists, which is what
  /// makes Tab in a dialog wrap rather than escape.
  List<FocusNode> traversalRing() {
    final FocusNode start = _activeModalScope() ?? rootScope;
    final List<FocusNode> nodes = _traversableDescendants(start);
    final List<KeyboardEventTarget>? order = traversalOrderProvider?.call();
    if (order == null || order.isEmpty) return nodes;

    final Map<KeyboardEventTarget, int> position =
        Map<KeyboardEventTarget, int>.identity();
    for (int i = 0; i < order.length; i++) {
      position[order[i]] = i;
    }
    // A node with no target, or one whose target is not in the tree yet, keeps
    // its attachment order after everything that is placed - dropping it would
    // silently remove a control from the keyboard.
    final int unplaced = order.length;
    final List<({FocusNode node, int rank, int tiebreak})> decorated =
        <({FocusNode node, int rank, int tiebreak})>[
      for (int i = 0; i < nodes.length; i++)
        (
          node: nodes[i],
          rank: position[nodes[i].target] ?? (unplaced + i),
          tiebreak: i,
        ),
    ];
    decorated.sort((({FocusNode node, int rank, int tiebreak}) a,
        ({FocusNode node, int rank, int tiebreak}) b) {
      final int byRank = a.rank.compareTo(b.rank);
      return byRank != 0 ? byRank : a.tiebreak.compareTo(b.tiebreak);
    });
    return <FocusNode>[
      for (final ({FocusNode node, int rank, int tiebreak}) entry in decorated)
        entry.node,
    ];
  }

  /// Moves focus one step in [direction].
  ///
  /// Returns false when there is nowhere to go, which the caller may use to
  /// let the platform move focus out of the window entirely.
  bool moveFocus(TraversalDirection direction) {
    final List<FocusNode> ring = traversalRing();
    if (ring.isEmpty) return false;
    final int current =
        _primaryFocus == null ? -1 : ring.indexOf(_primaryFocus!);
    final bool backwards = direction == TraversalDirection.previous ||
        direction == TraversalDirection.up ||
        direction == TraversalDirection.left;
    final int next;
    if (current < 0) {
      next = backwards ? ring.length - 1 : 0;
    } else {
      // Wraps deliberately: inside a modal this keeps the user in the dialog,
      // and outside one it matches every platform's tab ring.
      next = (current + (backwards ? -1 : 1) + ring.length) % ring.length;
    }
    return _requestFocus(ring[next], FocusChangeReason.traversal);
  }

  /// Interprets [event] as a traversal command, returning true when it was.
  ///
  /// Called *after* the focused control has declined the event, so a text
  /// field still receives its own Tab if it wants one.
  bool handleTraversalKey(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    if (event.logicalKey != logicalKeyTab) return false;
    final bool backwards = event.modifiers.contains(KeyModifier.shift);
    return moveFocus(
      backwards ? TraversalDirection.previous : TraversalDirection.next,
    );
  }

  void _notify() {
    for (final void Function(FocusNode?) listener
        in List<void Function(FocusNode?)>.of(_listeners)) {
      listener(_primaryFocus);
    }
  }

  void dispose() {
    _primaryFocus = null;
    _listeners.clear();
    rootScope._detach();
  }
}

/// Depth-first, in insertion order: the tab order of a node's subtree.
List<FocusNode> _traversableDescendants(FocusNode root) {
  final List<FocusNode> result = <FocusNode>[];
  void visit(FocusNode node) {
    for (final FocusNode child in node._children) {
      if (child.canRequestFocus && !child.skipTraversal) result.add(child);
      visit(child);
    }
  }

  visit(root);
  return result;
}

/// Virtual-key codes the framework interprets itself.
///
/// These are the Windows virtual-key values, which every backend normalizes
/// to; a physical-to-logical key table is a Fase 7 concern, and inventing a
/// second numbering before that table exists would only have to be undone.
const int logicalKeyBackspace = 0x08;
const int logicalKeyTab = 0x09;
const int logicalKeyEnter = 0x0D;
const int logicalKeyEscape = 0x1B;
const int logicalKeySpace = 0x20;
const int logicalKeyEnd = 0x23;
const int logicalKeyHome = 0x24;
const int logicalKeyArrowLeft = 0x25;
const int logicalKeyArrowUp = 0x26;
const int logicalKeyArrowRight = 0x27;
const int logicalKeyArrowDown = 0x28;
const int logicalKeyDelete = 0x2E;
const int logicalKeyPageUp = 0x21;
const int logicalKeyPageDown = 0x22;

extension _FirstOrNull<T> on List<T> {
  T? get firstOrNull => isEmpty ? null : this[0];
}
