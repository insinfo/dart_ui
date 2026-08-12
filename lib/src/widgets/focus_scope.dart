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

import 'actions.dart';
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
        child: _FocusScopeMarker(node: node, child: child),
      );
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
  /// holds it.
  final bool autofocus;

  @override
  State<FocusAttachment> createState() => _FocusAttachmentState();
}

final class _FocusAttachmentState extends State<FocusAttachment> {
  FocusNode? _attachedTo;

  @override
  Widget build(BuildContext context) {
    final FocusScopeNode? scope = FocusScope.of(context);
    _attach(scope ?? _ownerRootScope(context));
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

  void _attach(FocusScopeNode? scope) {
    if (scope == null || identical(_attachedTo, widget.node)) return;
    if (widget.node.parent != null) return;
    scope.add(widget.node);
    _attachedTo = widget.node;
    if (widget.autofocus && scope.manager?.primaryFocus == null) {
      widget.node.requestFocus();
    }
  }

  @override
  void dispose() {
    final FocusNode node = widget.node;
    if (identical(_attachedTo, node) && node.parent != null) {
      node.parent!.remove(node);
    }
    _attachedTo = null;
    super.dispose();
  }
}

/// Binds a shortcut map and an action map to a subtree.
///
/// Chained rather than replaced: an inner [Shortcuts] adds to what an outer one
/// defines, which is what lets a dialog bind Escape without redefining the
/// application's Ctrl+S.
final class Shortcuts extends InheritedWidget {
  const Shortcuts({
    super.key,
    required this.shortcuts,
    required this.actions,
    required super.child,
  });

  final ShortcutMap shortcuts;
  final ActionMap actions;

  static Shortcuts? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<Shortcuts>();

  @override
  bool updateShouldNotify(Shortcuts oldWidget) =>
      !identical(shortcuts, oldWidget.shortcuts) ||
      !identical(actions, oldWidget.actions);
}
