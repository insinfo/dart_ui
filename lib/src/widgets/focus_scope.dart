/// The widget face of the focus tree.
///
/// A control owns a [FocusNode] but must not own the *tree*: the tab order is a
/// property of where the control sits, and only the widget tree knows that.
/// [FocusScope] publishes a scope node through the inherited mechanism, and
/// [FocusAttachment] inserts a control's node into whichever scope encloses it.
///
/// The consequence worth stating: tab order is widget order, and it stays
/// correct when a subtree is moved, wrapped or conditionally shown, because
/// nothing anywhere hard-codes an index.
library;

import 'element.dart';
import 'focus.dart';
import 'widget.dart';

/// Publishes a [FocusScopeNode] to its subtree, and joins it to the focus
/// tree.
///
/// Both halves are necessary and they are easy to confuse. Publishing alone
/// would give descendants a scope object that no [FocusManager] owns - every
/// `requestFocus` would silently return false and the keyboard would appear to
/// be ignored. So a scope attaches itself to the *enclosing* scope first
/// (which, at the top, is the owner's root), and only then publishes itself to
/// what is below.
final class FocusScope extends StatelessWidget {
  const FocusScope({super.key, required this.node, required this.child});

  final FocusScopeNode node;
  final Widget child;

  /// The nearest scope, or null outside any.
  static FocusScopeNode? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_FocusScopeMarker>()?.node;

  @override
  Widget build(BuildContext context) => FocusAttachment(
        node: node,
        child: _FocusScopeMarker(
          node: node,
          child: FocusAttachmentParent(node: node, child: child),
        ),
      );
}

/// Publishes the node that the focus nodes attached below join as children.
///
/// [FocusScope] publishes its scope, and Flutter's `Focus` widget its own
/// node, so a control inside a `Focus` is that node's child in the focus
/// tree: the `Focus` sees the control's focus in `hasFocus` and gets the
/// keys the control declined, which is what Flutter's key bubbling and
/// `Shortcuts` are built on.
final class FocusAttachmentParent extends InheritedWidget {
  const FocusAttachmentParent({
    super.key,
    required this.node,
    required super.child,
  });

  final FocusNode node;

  /// The nearest published node, or null.
  static FocusNode? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<FocusAttachmentParent>()?.node;

  @override
  bool updateShouldNotify(FocusAttachmentParent oldWidget) =>
      !identical(node, oldWidget.node);
}

/// Carries the scope down. Separate from [FocusScope] so that the attachment
/// above it resolves the *enclosing* scope rather than finding itself.
final class _FocusScopeMarker extends InheritedWidget {
  const _FocusScopeMarker({required this.node, required super.child});

  final FocusScopeNode node;

  @override
  bool updateShouldNotify(_FocusScopeMarker oldWidget) =>
      !identical(node, oldWidget.node);
}

/// Installs [node] into the enclosing scope for as long as this is mounted.
///
/// A [StatefulWidget] because the attachment has a lifetime: mounting inserts
/// the node into the scope, and unmounting must remove it - a focus tree that
/// kept nodes for unmounted controls would let Tab move to a button that is no
/// longer on screen.
final class FocusAttachment extends StatefulWidget {
  const FocusAttachment({
    super.key,
    required this.node,
    required this.child,
    this.autofocus = false,
  });

  final FocusNode node;
  final Widget child;

  /// Whether this node takes focus when it is first attached and nothing else
  /// in its scope holds it - so a control in a popup that just opened takes
  /// the keyboard from the button that opened it.
  final bool autofocus;

  @override
  State<FocusAttachment> createState() => _FocusAttachmentState();
}

final class _FocusAttachmentState extends State<FocusAttachment> {
  FocusNode? _attachedTo;

  /// The context given to the node, kept because [context] cannot be read
  /// once the element is unmounting.
  BuildContext? _context;

  @override
  Widget build(BuildContext context) {
    final FocusNode? parent = FocusAttachmentParent.of(context) ??
        FocusScope.of(context) ??
        _ownerRootScope(context);
    _context = context;
    widget.node.context ??= context;
    _attach(parent);
    return widget.child;
  }

  /// Falls back to the owner's root scope so a control mounted without an
  /// explicit [FocusScope] is still reachable by Tab. Focus that only works
  /// inside a scope would be a trap: the failure is silent and looks like the
  /// keyboard being ignored.
  FocusScopeNode? _ownerRootScope(BuildContext context) {
    final Element? element = context is Element ? context : null;
    return element?.owner?.focusManager.rootScope;
  }

  void _attach(FocusNode? parent) {
    if (parent == null || identical(_attachedTo, widget.node)) return;
    final FocusNode? previous = _attachedTo;
    if (previous != null) {
      // The widget was given another node: the old one leaves the tree.
      previous.parent?.remove(previous);
      if (identical(previous.context, _context)) previous.context = null;
      _attachedTo = null;
    }
    if (widget.node.parent != null) return;
    parent.add(widget.node);
    _attachedTo = widget.node;
    final FocusNode scope = widget.node.enclosingScope ?? parent;
    if (widget.autofocus && !scope.hasFocus) {
      widget.node.requestFocus();
    }
  }

  @override
  void dispose() {
    final FocusNode node = widget.node;
    if (identical(_attachedTo, node) && node.parent != null) {
      node.parent!.remove(node);
    }
    if (identical(node.context, _context)) node.context = null;
    _context = null;
    _attachedTo = null;
    super.dispose();
  }
}
