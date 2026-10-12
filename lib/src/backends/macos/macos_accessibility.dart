/// The framework's semantic tree, published to AppKit's accessibility API.
///
/// The `NSWindow` lives in the host process (ADR 0001), so the tree crosses
/// the pipe: the host's view is an accessibility group whose children are
/// `NSAccessibilityElement`s built from `A11Y_NODE` lines, and VoiceOver reads
/// those. Nothing is walked or sent until a client asks the view for its
/// children - the host then says `A11Y_REQUESTED`, and from that point the
/// window pumps the tree after each frame, sending it again only when the
/// diff is not empty. A press, an increment or a decrement on an element
/// comes back as `A11Y_ACTION` and reaches the render object through
/// [SemanticsOwner.performAction].
///
/// The same contract as the Windows UI Automation bridge
/// (`backends/win32/uia/`): [AccessibilityHost.register] costs a map entry,
/// and a window nobody reads pays nothing per frame.
library;

import 'dart:convert';

import '../../semantics/accessibility.dart';
import '../../semantics/semantics.dart';

/// The window side the bridge needs. [MacosWindow] implements it.
abstract interface class MacosAccessibilityWindow {
  /// Sends one `A11Y_` command line to the window's host.
  bool sendAccessibilityCommand(String command);

  /// Where the window routes `A11Y_REQUESTED` and `A11Y_ACTION`.
  MacosWindowAccessibility? get accessibility;
  set accessibility(MacosWindowAccessibility? value);
}

/// [AccessibilityHost] for the AppKit backend.
final class MacosAccessibilityHost implements AccessibilityHost {
  MacosAccessibilityHost(this._windowFor);

  /// The window behind a handle, or null when it is gone.
  final MacosAccessibilityWindow? Function(int handle) _windowFor;

  final Map<int, MacosWindowAccessibility> _connections =
      <int, MacosWindowAccessibility>{};

  @override
  String get apiName => 'NSAccessibility';

  @override
  void register(int nativeHandle, AccessibilityTreeSource source) {
    final MacosAccessibilityWindow? window = _windowFor(nativeHandle);
    if (window == null) return;
    final MacosWindowAccessibility connection =
        MacosWindowAccessibility(window, source);
    _connections[nativeHandle] = connection;
    window.accessibility = connection;
  }

  @override
  WindowAccessibility? forWindow(int nativeHandle) {
    final MacosWindowAccessibility? connection = _connections[nativeHandle];
    return connection != null && connection.isRequested ? connection : null;
  }

  @override
  void unregister(int nativeHandle) {
    final MacosWindowAccessibility? connection =
        _connections.remove(nativeHandle);
    if (connection != null &&
        identical(connection._window.accessibility, connection)) {
      connection._window.accessibility = null;
    }
  }
}

/// One window's published tree.
final class MacosWindowAccessibility implements WindowAccessibility {
  MacosWindowAccessibility(this._window, this._source);

  final MacosAccessibilityWindow _window;
  final AccessibilityTreeSource _source;

  bool _requested = false;

  /// Whether a client has asked the host for this window's tree.
  bool get isRequested => _requested;

  /// How many times the tree was sent, for a test.
  int get publishCount => _publishes;
  int _publishes = 0;

  /// The host said `A11Y_REQUESTED`: publish now, and on every changed frame.
  void onRequested() {
    _requested = true;
    republish();
  }

  @override
  void pump() {
    if (!_requested) return;
    final SemanticsUpdate update = _source.owner.update(_source.root());
    if (update.isEmpty) return;
    _publish();
  }

  @override
  void republish() {
    _source.owner.build(_source.root());
    _publish();
  }

  /// `A11Y_ACTION=<node>:<action>` from the host. Returns whether the render
  /// object performed it.
  bool onAction(int node, String action) {
    final SemanticsAction? semantic = switch (action) {
      'activate' => SemanticsAction.activate,
      'increment' => SemanticsAction.increment,
      'decrement' => SemanticsAction.decrement,
      'focus' => SemanticsAction.focus,
      _ => null,
    };
    if (semantic == null) return false;
    return _source.owner.performAction(node, semantic);
  }

  void _publish() {
    final SemanticsNode? root = _source.owner.snapshot.root;
    if (!_window.sendAccessibilityCommand(macosA11yBegin())) return;
    if (root != null) {
      // The root is the window itself, which the host's view already is; its
      // children are the top-level elements.
      for (final SemanticsNode child in root.children) {
        _send(child, 0);
      }
    }
    _window.sendAccessibilityCommand(macosA11yEnd());
    _publishes++;
  }

  void _send(SemanticsNode node, int parent) {
    _window.sendAccessibilityCommand(macosA11yNode(node, parent));
    for (final SemanticsNode child in node.children) {
      _send(child, node.id);
    }
  }
}

String macosA11yBegin() => 'A11Y_BEGIN\n';

String macosA11yEnd() => 'A11Y_END\n';

/// One `A11Y_NODE` line: id, parent, role, label, value, the rectangle in
/// the window's points, then [SemanticsState] and [SemanticsAction] as bits
/// of their indices. Label and value are base64 of UTF-8, `-` when empty.
String macosA11yNode(SemanticsNode node, int parent) {
  String text(String? value) =>
      value == null || value.isEmpty ? '-' : base64.encode(utf8.encode(value));
  String number(double value) => value.toStringAsFixed(2);
  var states = 0;
  for (final SemanticsState state in node.states) {
    states |= 1 << state.index;
  }
  var actions = 0;
  for (final SemanticsAction action in node.actions) {
    actions |= 1 << action.index;
  }
  final String label = <String?>[node.label, node.hint]
      .whereType<String>()
      .where((String part) => part.isNotEmpty)
      .join(', ');
  return 'A11Y_NODE ${node.id} $parent ${node.role.name} ${text(label)} '
      '${text(node.value)} ${number(node.bounds.left)} '
      '${number(node.bounds.top)} ${number(node.bounds.width)} '
      '${number(node.bounds.height)} $states $actions\n';
}
