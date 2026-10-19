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
import '../platform/logical_keys.dart';
import 'keyboard_router.dart';
import 'widget.dart' show BuildContext;

export '../platform/logical_keys.dart';

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

/// What a key handler did with a key event - Flutter's `KeyEventResult`.
enum KeyEventResult {
  /// Used: nobody else sees it.
  handled,

  /// Not used: it goes on to the next handler up the focus tree, then to
  /// the application's shortcuts, the window's keys and traversal.
  ignored,

  /// Not used, and nobody else in the focus tree may use it either: the
  /// event leaves the framework unhandled, for the platform.
  skipRemainingHandlers,
}

/// A key handler on a [FocusNode] - Flutter's `FocusOnKeyEventCallback`.
typedef FocusOnKeyEventCallback = KeyEventResult Function(
  FocusNode node,
  KeyEvent event,
);

/// Orders the traversable nodes under a group node; what a
/// `FocusTraversalGroup` installs on its node as its policy.
typedef FocusTraversalSorter = Iterable<FocusNode> Function(
  Iterable<FocusNode> descendants,
  FocusNode currentNode,
);

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
    this.onKeyEvent,
    bool descendantsAreFocusable = true,
    bool descendantsAreTraversable = true,
  })  : _canRequestFocus = canRequestFocus,
        _skipTraversal = skipTraversal,
        _descendantsAreFocusable = descendantsAreFocusable,
        _descendantsAreTraversable = descendantsAreTraversable,
        _target = target;

  /// Names the node in diagnostics only.
  final String? debugLabel;

  /// Offered the key events that reach this node unhandled: the focused
  /// control's own target declined them, and this node holds focus or is an
  /// ancestor of the node that does. Flutter's `FocusNode.onKeyEvent`.
  ///
  /// Handlers run from the focused node up to the root, and the first that
  /// answers [KeyEventResult.handled] or
  /// [KeyEventResult.skipRemainingHandlers] ends the walk.
  FocusOnKeyEventCallback? onKeyEvent;

  /// The widget this node belongs to, set by the widget that attaches it
  /// (`Focus`, or a control's focus attachment). Flutter's
  /// `FocusNode.context`, which `Actions` and `Shortcuts` start their search
  /// from.
  BuildContext? context;

  /// Orders traversal among this node's descendants when set; see
  /// [FocusTraversalSorter].
  FocusTraversalSorter? traversalSorter;

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
    final KeyboardEventTarget? previous = _target;
    _target = value;
    // If this node holds focus right now, the router is still pointing at the
    // previous target - which is about to stop receiving keys for a control
    // the user can see is focused.
    if (_hasPrimaryFocus) {
      if (previous != null) _manager?._router?.clearFocus(previous);
      _manager?._retarget(this);
    }
  }

  final List<FocusNode> _children = <FocusNode>[];
  final List<Function> _listeners = <Function>[];

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
  ///
  /// False also while an ancestor has [descendantsAreFocusable] false, as in
  /// Flutter: that is how `ExcludeFocus` takes a whole subtree out.
  bool get canRequestFocus {
    if (!_canRequestFocus) return false;
    for (FocusNode? node = _parent; node != null; node = node._parent) {
      if (!node._descendantsAreFocusable) return false;
    }
    return true;
  }

  bool _descendantsAreFocusable;
  bool _descendantsAreTraversable;

  /// Whether the nodes below this one may take focus. Turning it off moves
  /// focus out of the subtree if it was inside.
  bool get descendantsAreFocusable => _descendantsAreFocusable;

  set descendantsAreFocusable(bool value) {
    if (value == _descendantsAreFocusable) return;
    _descendantsAreFocusable = value;
    if (!value) {
      final FocusNode? focused = _manager?.primaryFocus;
      if (focused != null && !identical(focused, this)) {
        for (FocusNode? node = focused._parent;
            node != null;
            node = node._parent) {
          if (identical(node, this)) {
            _manager?._focusChanged(null, FocusChangeReason.programmatic);
            break;
          }
        }
      }
    }
    _notify();
  }

  /// Whether Tab may land on the nodes below this one. They stay focusable
  /// by click and by code.
  bool get descendantsAreTraversable => _descendantsAreTraversable;

  set descendantsAreTraversable(bool value) {
    if (value == _descendantsAreTraversable) return;
    _descendantsAreTraversable = value;
    _notify();
  }

  set canRequestFocus(bool value) {
    if (value == _canRequestFocus) return;
    _canRequestFocus = value;
    if (!value && _hasPrimaryFocus) _manager?._focusChanged(null, _reason);
  }

  /// Whether Tab skips this node. A node can be focusable by click yet not
  /// participate in the tab ring - a text label with a selection, a toolbar
  /// that is reached by arrow keys from its first button.
  ///
  /// True also while an ancestor has [descendantsAreTraversable] false.
  bool get skipTraversal {
    if (_skipTraversal) return true;
    for (FocusNode? node = _parent; node != null; node = node._parent) {
      if (!node._descendantsAreTraversable) return true;
    }
    return false;
  }

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

  /// Calls [listener] whenever this node's focus changes - it gains or loses
  /// primary focus, or a descendant does, which changes [hasFocus].
  ///
  /// Takes either shape: `void Function(FocusNode node)`, as written here
  /// before, or Flutter's `void Function()`, as `ChangeNotifier` listeners
  /// are. Anything else is an [ArgumentError].
  void addListener(Function listener) {
    if (listener is! void Function(FocusNode) && listener is! void Function()) {
      throw ArgumentError.value(listener, 'listener',
          'must be a void Function() or a void Function(FocusNode)');
    }
    _listeners.add(listener);
  }

  void removeListener(Function listener) => _listeners.remove(listener);

  /// The nodes above this one, nearest first.
  Iterable<FocusNode> get ancestors sync* {
    for (FocusNode? node = _parent; node != null; node = node._parent) {
      yield node;
    }
  }

  /// Every node below this one, depth first.
  Iterable<FocusNode> get descendants sync* {
    for (final FocusNode child in _children) {
      yield child;
      yield* child.descendants;
    }
  }

  /// The scope this node is in, or this node when it is a scope - Flutter's
  /// `nearestScope`.
  FocusScopeNode? get nearestScope => enclosingScope;

  /// Moves focus to the next node in tab order. Flutter's `nextFocus`.
  bool nextFocus() =>
      _manager?.moveFocus(TraversalDirection.next, from: this) ?? false;

  /// Moves focus to the previous node in tab order.
  bool previousFocus() =>
      _manager?.moveFocus(TraversalDirection.previous, from: this) ?? false;

  /// Moves focus one step in [direction].
  bool focusInDirection(TraversalDirection direction) =>
      _manager?.moveFocus(direction, from: this) ?? false;

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
    if (child.canRequestFocus && !child.skipTraversal) {
      for (FocusNode? ancestor = this;
          ancestor != null;
          ancestor = ancestor._parent) {
        if (ancestor is FocusScopeNode && ancestor._focusOnAttach) {
          ancestor._focusOnAttach = false;
          child.requestFocus(FocusChangeReason.restoration);
          break;
        }
      }
    }
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
    final FocusChangeReason? pending = _focusWhenAttached;
    if (manager != null && pending != null) {
      _focusWhenAttached = null;
      requestFocus(pending);
    }
  }

  /// A [requestFocus] made before this node was in a tree, kept until it is.
  FocusChangeReason? _focusWhenAttached;

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
  ///
  /// A node not attached yet takes focus as it is attached: the field a
  /// "Rename" command is about to show can be asked for the keyboard in the
  /// same breath, with no wait for the frame that mounts it. [unfocus]
  /// withdraws such a request.
  bool requestFocus([
    FocusChangeReason reason = FocusChangeReason.programmatic,
  ]) {
    final FocusManager? manager = _manager;
    if (manager == null) {
      _focusWhenAttached = reason;
      return false;
    }
    return manager._requestFocus(this, reason);
  }

  /// Gives up focus, letting the enclosing scope decide where it goes.
  void unfocus() {
    _focusWhenAttached = null;
    if (!_hasPrimaryFocus) return;
    _manager?._focusChanged(null, FocusChangeReason.programmatic);
  }

  void _notify() {
    for (final Function listener in List<Function>.of(_listeners)) {
      if (listener is void Function(FocusNode)) {
        listener(this);
      } else if (listener is void Function()) {
        listener();
      }
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

  @override
  FocusScopeNode get nearestScope => this;

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

  bool _focusOnAttach = false;

  /// Focuses the first focusable descendant - now, or, when there is none
  /// yet, the first one to attach.
  ///
  /// For a scope whose content is still being built: a dialog that has just
  /// opened, whose controls attach their nodes as their own builds run, later
  /// in the same frame. Waiting for "after the frame" instead would leave a
  /// window in which the first keystroke goes to the window behind.
  void requestFocusOnAttach() {
    if (!focusRemembered()) _focusOnAttach = true;
  }

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
    // The ancestors whose hasFocus flips: those above one of the two nodes
    // and not above both. Told after the change, as Flutter tells them.
    final Set<FocusNode> above = <FocusNode>{
      if (previous != null) ...previous.ancestors,
    };
    final Set<FocusNode> aboveNew = <FocusNode>{
      if (node != null) ...node.ancestors,
    };
    final List<FocusNode> flipped = <FocusNode>[
      ...above.difference(aboveNew),
      ...aboveNew.difference(above),
    ];
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
    for (final FocusNode ancestor in flipped) {
      if (!identical(ancestor, node) && !identical(ancestor, previous)) {
        ancestor._notify();
      }
    }
    _notify();
  }

  /// Offers [event] to the [FocusNode.onKeyEvent] handlers from the focused
  /// node up to the root - Flutter's key-event bubbling.
  ///
  /// Called after the focused control's own target declined the event.
  /// Answers [KeyEventResult.ignored] when there is no focus or no handler
  /// used it.
  KeyEventResult handleKeyEvent(KeyEvent event) {
    for (FocusNode? node = _primaryFocus; node != null; node = node._parent) {
      final FocusOnKeyEventCallback? handler = node.onKeyEvent;
      if (handler == null) continue;
      final KeyEventResult result = handler(node, event);
      if (result != KeyEventResult.ignored) return result;
    }
    return KeyEventResult.ignored;
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
    final List<FocusNode> ring = _visualRing(start);
    if (!_hasSorter(start)) return ring;
    return _groupOrder(start, ring);
  }

  bool _hasSorter(FocusNode root) {
    for (final FocusNode node in root.descendants) {
      if (node.traversalSorter != null) return true;
    }
    return false;
  }

  /// [ring] reordered so that each group with a [FocusNode.traversalSorter]
  /// is visited as one block, in the order its sorter gives.
  ///
  /// A group's members are the traversable nodes whose nearest sorted
  /// ancestor is that group; nested groups are members of the group around
  /// them and expand in place. Groups without a sorter keep the visual order.
  List<FocusNode> _groupOrder(FocusNode root, List<FocusNode> ring) {
    final Map<FocusNode, int> rank = <FocusNode, int>{
      for (int i = 0; i < ring.length; i++) ring[i]: i,
    };
    FocusNode groupOf(FocusNode node) {
      for (FocusNode? a = node._parent; a != null; a = a._parent) {
        if (identical(a, root) || a.traversalSorter != null) return a;
      }
      return root;
    }

    // Members of each group: traversable nodes and the nested groups.
    final Map<FocusNode, List<FocusNode>> members =
        <FocusNode, List<FocusNode>>{};
    final Map<FocusNode, int> firstRank = <FocusNode, int>{};
    for (final FocusNode node in ring) {
      FocusNode item = node;
      FocusNode group = groupOf(node);
      final int r = rank[node]!;
      while (true) {
        final List<FocusNode> list = members.putIfAbsent(group, () => []);
        if (!list.contains(item)) list.add(item);
        if (firstRank[item] == null || r < firstRank[item]!) {
          firstRank[item] = r;
        }
        if (identical(group, root)) break;
        item = group;
        group = groupOf(group);
      }
    }
    final FocusNode current = _primaryFocus ?? root;
    final List<FocusNode> result = <FocusNode>[];
    void expand(FocusNode group) {
      final List<FocusNode> list = members[group] ?? <FocusNode>[];
      list.sort(
          (FocusNode a, FocusNode b) => firstRank[a]!.compareTo(firstRank[b]!));
      final FocusTraversalSorter? sorter = group.traversalSorter;
      final Iterable<FocusNode> ordered =
          sorter == null ? list : sorter(list, current);
      for (final FocusNode item in ordered) {
        if (members.containsKey(item)) {
          // A nested group: itself when it is a stop too, then its members.
          if (rank.containsKey(item)) result.add(item);
          expand(item);
        } else {
          result.add(item);
        }
      }
    }

    expand(root);
    return result;
  }

  /// The traversable nodes under [start] in visual order.
  List<FocusNode> _visualRing(FocusNode start) {
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
  ///
  /// [from] is the node to step from, the focused one by default.
  bool moveFocus(TraversalDirection direction, {FocusNode? from}) {
    final List<FocusNode> ring = traversalRing();
    if (ring.isEmpty) return false;
    final FocusNode? origin = from ?? _primaryFocus;
    final int current = origin == null ? -1 : ring.indexOf(origin);
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

extension _FirstOrNull<T> on List<T> {
  T? get firstOrNull => isEmpty ? null : this[0];
}
