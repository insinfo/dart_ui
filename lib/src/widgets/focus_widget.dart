/// Flutter's `Focus`, `ExcludeFocus` and `KeyboardListener`, over the focus
/// tree in `focus.dart`.
///
/// ## How keys reach a `Focus`
///
/// A key goes first to the focused control's own render target (a text field
/// that types the letter keeps it). Whatever that target declines is offered
/// to [FocusNode.onKeyEvent] from the focused node up to the root - Flutter's
/// bubbling - and only then to the application's shortcuts, the window's
/// keys and Tab traversal. A [Focus] is in that chain because the focus nodes
/// below it attach under its node ([FocusAttachmentParent]).
///
/// ## Differences from Flutter
///
/// * `onKey` (the deprecated `RawKeyEvent` callback) does not exist: there
///   are no raw key events here. Use [Focus.onKeyEvent].
/// * Key repeats arrive as [KeyDownEvent] with `isRepeat`, not as a separate
///   `KeyRepeatEvent` class.
/// * `includeSemantics` is accepted and has no effect yet: the semantic
///   focus flag comes from the control under the [Focus].
library;

import '../geometry/offset.dart';
import '../layout/render_box.dart';
import '../layout/render_proxy_box.dart';
import '../platform/input_events.dart';
import 'element.dart';
import 'focus.dart';
import 'focus_scope.dart';
import 'keyboard_router.dart';
import 'widget.dart';

/// Makes its subtree a place in the focus tree, and lets it handle the keys
/// that reach it - Flutter's `Focus`.
///
/// Without [focusNode] the widget owns a node of its own; with one, the
/// widget configures and attaches the given node and leaves its lifetime to
/// the caller. The `bool?` parameters, when null, leave an external node's
/// own setting alone, as in Flutter.
class Focus extends StatefulWidget {
  const Focus({
    super.key,
    required this.child,
    this.focusNode,
    this.parentNode,
    this.autofocus = false,
    this.onFocusChange,
    FocusOnKeyEventCallback? onKeyEvent,
    bool? canRequestFocus,
    bool? skipTraversal,
    bool? descendantsAreFocusable,
    bool? descendantsAreTraversable,
    this.includeSemantics = true,
    String? debugLabel,
  })  : _onKeyEvent = onKeyEvent,
        _canRequestFocus = canRequestFocus,
        _skipTraversal = skipTraversal,
        _descendantsAreFocusable = descendantsAreFocusable,
        _descendantsAreTraversable = descendantsAreTraversable,
        _debugLabel = debugLabel;

  /// A [Focus] for a node that is configured elsewhere: only its place in
  /// the tree comes from here - Flutter's `Focus.withExternalFocusNode`.
  const factory Focus.withExternalFocusNode({
    Key? key,
    required Widget child,
    required FocusNode focusNode,
    FocusNode? parentNode,
    bool autofocus,
    void Function(bool hasFocus)? onFocusChange,
    bool includeSemantics,
  }) = _FocusWithExternalFocusNode;

  final Widget child;

  /// The node to use; null makes the widget own one.
  final FocusNode? focusNode;

  /// The node to attach under, instead of the nearest enclosing one.
  final FocusNode? parentNode;

  /// Whether to take focus when first attached, if nothing in the enclosing
  /// scope has it.
  final bool autofocus;

  /// Called with `hasFocus` whenever this node, or a node below it, gains or
  /// loses focus.
  final void Function(bool hasFocus)? onFocusChange;

  final FocusOnKeyEventCallback? _onKeyEvent;
  final bool? _canRequestFocus;
  final bool? _skipTraversal;
  final bool? _descendantsAreFocusable;
  final bool? _descendantsAreTraversable;
  final String? _debugLabel;

  /// Accepted for Flutter's signature; see the library comment.
  final bool includeSemantics;

  /// Offered the keys that reach this node unhandled; see the library
  /// comment for the order.
  FocusOnKeyEventCallback? get onKeyEvent =>
      _onKeyEvent ?? focusNode?.onKeyEvent;

  bool get canRequestFocus =>
      _canRequestFocus ?? focusNode?.canRequestFocus ?? true;

  bool get skipTraversal => _skipTraversal ?? focusNode?.skipTraversal ?? false;

  bool get descendantsAreFocusable =>
      _descendantsAreFocusable ?? focusNode?.descendantsAreFocusable ?? true;

  bool get descendantsAreTraversable =>
      _descendantsAreTraversable ??
      focusNode?.descendantsAreTraversable ??
      true;

  String? get debugLabel => _debugLabel ?? focusNode?.debugLabel;

  bool get _usingExternalFocus => false;

  /// The node of the nearest [Focus] - or [FocusScope], with [scopeOk] -
  /// above [context]. Throws when there is none, as Flutter does.
  static FocusNode of(
    BuildContext context, {
    bool scopeOk = false,
    bool createDependency = true,
  }) {
    final FocusNode? node = maybeOf(
      context,
      scopeOk: scopeOk,
      createDependency: createDependency,
    );
    if (node == null) {
      throw StateError(
        'Focus.of() was called with a context that does not contain a Focus '
        'widget${scopeOk ? ' or a FocusScope' : ''}: no Focus is above '
        '${context.widget.runtimeType}.',
      );
    }
    return node;
  }

  /// The node of the nearest [Focus] above [context], or null.
  ///
  /// With [createDependency] the caller rebuilds when that node gains or
  /// loses focus.
  static FocusNode? maybeOf(
    BuildContext context, {
    bool scopeOk = false,
    bool createDependency = true,
  }) {
    if (createDependency) {
      context.dependOnInheritedWidgetOfExactType<_FocusMarker>();
    }
    final FocusNode? node = createDependency
        ? FocusAttachmentParent.of(context)
        : context.getInheritedWidgetOfExactType<FocusAttachmentParent>()?.node;
    if (node == null) return null;
    if (!scopeOk && node is FocusScopeNode) return null;
    return node;
  }

  /// Whether the nearest [Focus] above [context] has focus.
  static bool isAt(BuildContext context) => maybeOf(context)?.hasFocus ?? false;

  @override
  State<Focus> createState() => _FocusState();
}

final class _FocusWithExternalFocusNode extends Focus {
  const _FocusWithExternalFocusNode({
    super.key,
    required super.child,
    required FocusNode super.focusNode,
    super.parentNode,
    super.autofocus,
    super.onFocusChange,
    super.includeSemantics,
  });

  @override
  bool get _usingExternalFocus => true;
}

class _FocusState extends State<Focus> {
  FocusNode? _internalNode;
  bool _hadFocus = false;
  FocusNode? _listeningTo;

  FocusNode get _node => widget.focusNode ?? (_internalNode ??= _createNode());

  FocusNode _createNode() => FocusNode(
        debugLabel: widget.debugLabel,
        canRequestFocus: widget.canRequestFocus,
        skipTraversal: widget.skipTraversal,
        descendantsAreFocusable: widget.descendantsAreFocusable,
        descendantsAreTraversable: widget.descendantsAreTraversable,
        onKeyEvent: widget._onKeyEvent,
      );

  @override
  void initState() {
    super.initState();
    _configure();
  }

  @override
  void didUpdateWidget(Focus oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.focusNode, widget.focusNode)) {
      // The internal node is kept for a later return to it, as in Flutter.
      if (widget.focusNode != null && _internalNode != null) {
        _internalNode!.parent?.remove(_internalNode!);
      }
    }
    _configure();
  }

  void _configure() {
    final FocusNode node = _node;
    if (!widget._usingExternalFocus) {
      final bool internal = widget.focusNode == null;
      if (internal || widget._onKeyEvent != null) {
        node.onKeyEvent = widget._onKeyEvent;
      }
      if (internal || widget._canRequestFocus != null) {
        node.canRequestFocus = widget.canRequestFocus;
      }
      if (internal || widget._skipTraversal != null) {
        node.skipTraversal = widget.skipTraversal;
      }
      if (internal || widget._descendantsAreFocusable != null) {
        node.descendantsAreFocusable = widget.descendantsAreFocusable;
      }
      if (internal || widget._descendantsAreTraversable != null) {
        node.descendantsAreTraversable = widget.descendantsAreTraversable;
      }
    }
    if (!identical(_listeningTo, node)) {
      _listeningTo?.removeListener(_focusChanged);
      _listeningTo = node..addListener(_focusChanged);
      _hadFocus = node.hasFocus;
    }
  }

  void _focusChanged() {
    final bool hasFocus = _node.hasFocus;
    if (hasFocus == _hadFocus) return;
    _hadFocus = hasFocus;
    widget.onFocusChange?.call(hasFocus);
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _listeningTo?.removeListener(_focusChanged);
    _listeningTo = null;
    final FocusNode? internal = _internalNode;
    if (internal != null) {
      internal.parent?.remove(internal);
      internal.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final FocusNode node = _node;
    node.context = context;
    Widget child = _FocusMarker(
      node: node,
      hasFocus: node.hasFocus,
      child: FocusAttachmentParent(node: node, child: widget.child),
    );
    child = _FocusTarget(node: node, child: child);
    final FocusNode? parent = widget.parentNode;
    if (parent != null) {
      child = FocusAttachmentParent(
        node: parent,
        child: FocusAttachment(
          node: node,
          autofocus: widget.autofocus,
          child: child,
        ),
      );
      return child;
    }
    return FocusAttachment(
      node: node,
      autofocus: widget.autofocus,
      child: child,
    );
  }
}

/// Lets `Focus.of` callers rebuild when the node's focus changes.
final class _FocusMarker extends InheritedWidget {
  const _FocusMarker({
    required this.node,
    required this.hasFocus,
    required super.child,
  });

  final FocusNode node;
  final bool hasFocus;

  @override
  bool updateShouldNotify(_FocusMarker oldWidget) =>
      !identical(node, oldWidget.node) || hasFocus != oldWidget.hasFocus;
}

/// Gives a [Focus] node a place in the render tree: where it is in tab
/// order, and the box `ReadingOrderTraversalPolicy` measures. It declines
/// every key, so a key the [Focus] node is offered goes to its
/// [FocusNode.onKeyEvent] handler chain.
final class _FocusTarget extends SingleChildRenderObjectWidget {
  const _FocusTarget({required this.node, super.child});

  final FocusNode node;

  @override
  RenderBox createRenderObject(BuildContext context) =>
      _RenderFocusTarget(node);

  @override
  void updateRenderObject(
    BuildContext context,
    covariant _RenderFocusTarget renderObject,
  ) =>
      renderObject.node = node;
}

final class _RenderFocusTarget extends RenderProxyBox
    implements KeyboardEventTarget {
  _RenderFocusTarget(this._node) {
    _node.target ??= this;
  }

  FocusNode _node;

  set node(FocusNode value) {
    if (identical(value, _node)) return;
    if (identical(_node.target, this)) _node.target = null;
    _node = value..target ??= this;
  }

  @override
  void detach() {
    // The render object goes before the State does, and a node that kept
    // pointing here would route keys to a box that is not in the tree.
    if (identical(_node.target, this)) _node.target = null;
    super.detach();
  }

  @override
  bool handleKeyEvent(KeyEvent event) => false;

  @override
  bool hitTestSelf(Offset position) => false;
}

/// Takes its subtree out of focus: nothing below can be focused, by click,
/// by Tab or by code, while [excluding] - Flutter's `ExcludeFocus`.
class ExcludeFocus extends StatelessWidget {
  const ExcludeFocus({super.key, this.excluding = true, required this.child});

  final bool excluding;
  final Widget child;

  @override
  Widget build(BuildContext context) => Focus(
        canRequestFocus: false,
        skipTraversal: true,
        includeSemantics: false,
        descendantsAreFocusable: !excluding,
        child: child,
      );
}

/// Calls [onKeyEvent] for the keys that reach [focusNode], without using
/// them - Flutter's `KeyboardListener`.
///
/// The node must have focus, or contain it, for keys to arrive. Every key
/// is reported and then passed on ([KeyEventResult.ignored]).
class KeyboardListener extends StatelessWidget {
  const KeyboardListener({
    super.key,
    required this.focusNode,
    this.autofocus = false,
    this.includeSemantics = true,
    this.onKeyEvent,
    required this.child,
  });

  final FocusNode focusNode;
  final bool autofocus;
  final bool includeSemantics;
  final void Function(KeyEvent event)? onKeyEvent;
  final Widget child;

  @override
  Widget build(BuildContext context) => Focus(
        focusNode: focusNode,
        autofocus: autofocus,
        includeSemantics: includeSemantics,
        onKeyEvent: (FocusNode node, KeyEvent event) {
          onKeyEvent?.call(event);
          return KeyEventResult.ignored;
        },
        child: child,
      );
}
