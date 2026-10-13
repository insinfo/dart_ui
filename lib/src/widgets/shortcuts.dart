/// Flutter's `Shortcuts`: key combinations bound to intents for a subtree.
///
/// A [Shortcuts] is a [Focus] that cannot itself take focus. The keys the
/// focused control below declined bubble to it; when one matches a
/// [ShortcutActivator] in the map, the [Intent] is invoked through the
/// [Actions] found from the focused widget outward - so the same Ctrl+C
/// copies text in a field and files in a list, each by its own action.
///
/// The activators are Flutter's ([SingleActivator], [CharacterActivator],
/// [LogicalKeySet]) and this framework's [KeyGesture], which is one too:
/// `KeyGesture(0x53, command: true)` is Cmd+S on a Mac and Ctrl+S
/// elsewhere.
///
/// ## Differences from Flutter
///
/// * Nothing answers while nothing has focus: there is no focused node to
///   bubble from. Flutter's root scope is focusable and here a scope is not,
///   so give a widget below focus (`Focus(autofocus: true)`), or use
///   [CallbackShortcuts], which listens at the window.
/// * This replaces an earlier `Shortcuts(shortcuts: ShortcutMap, actions:
///   ActionMap)` inherited widget that nothing read; a window-wide map is
///   still `BuildOwner.shortcuts` ([ShortcutDispatcher]).
library;

import '../foundation/change_notifier.dart';
import '../platform/input_events.dart';
import '../platform/shortcut_activator.dart';
import 'actions.dart';
import 'actions_widget.dart';
import 'element.dart';
import 'focus.dart';
import 'focus_widget.dart';
import 'widget.dart';

/// Finds the intent for a key and invokes it - Flutter's
/// `ShortcutManager`.
class ShortcutManager extends ChangeNotifier {
  ShortcutManager({
    Map<ShortcutActivator, Intent> shortcuts =
        const <ShortcutActivator, Intent>{},
    this.modal = false,
  }) : _shortcuts = Map<ShortcutActivator, Intent>.of(shortcuts);

  /// Whether a key this manager does not bind stops here, unhandled, instead
  /// of reaching the shortcuts further out.
  final bool modal;

  Map<ShortcutActivator, Intent> _shortcuts;

  Map<ShortcutActivator, Intent> get shortcuts =>
      Map<ShortcutActivator, Intent>.unmodifiable(_shortcuts);

  set shortcuts(Map<ShortcutActivator, Intent> value) {
    _shortcuts = Map<ShortcutActivator, Intent>.of(value);
    notifyListeners();
  }

  /// The intent bound to [event], or null.
  Intent? _find(KeyEvent event) {
    for (final MapEntry<ShortcutActivator, Intent> entry
        in _shortcuts.entries) {
      if (ShortcutActivator.isActivatedBy(entry.key, event)) {
        return entry.value;
      }
    }
    return null;
  }

  /// Handles [event] for the [Shortcuts] at [context]: invokes the bound
  /// intent's action, found from the focused widget (or from [context] when
  /// the focused node has none).
  KeyEventResult handleKeypress(BuildContext context, KeyEvent event) {
    final Intent? intent = _find(event);
    if (intent != null) {
      final BuildContext start = _focusedContext(context) ?? context;
      final Action<Intent>? action =
          Actions.maybeFind<Intent>(start, intent: intent);
      if (action != null) {
        final (bool enabled, Object? result) =
            Actions.of(start).invokeActionIfEnabled(action, intent, start);
        if (enabled) return action.toKeyEventResult(intent, result);
      }
    }
    return modal
        ? KeyEventResult.skipRemainingHandlers
        : KeyEventResult.ignored;
  }

  /// The focused widget of [context]'s window.
  BuildContext? _focusedContext(BuildContext context) {
    final BuildContext? focused = context is Element
        ? context.owner?.focusManager.primaryFocus?.context
        : null;
    return focused != null && focused.mounted ? focused : null;
  }
}

/// Binds key combinations to intents for the subtree - Flutter's
/// `Shortcuts`. See the library comment.
class Shortcuts extends StatefulWidget {
  const Shortcuts({
    super.key,
    required Map<ShortcutActivator, Intent> shortcuts,
    required this.child,
    this.debugLabel,
    this.includeSemantics = true,
  })  : _shortcuts = shortcuts,
        manager = null;

  /// A [Shortcuts] whose bindings are [manager]'s.
  const Shortcuts.manager({
    super.key,
    required ShortcutManager this.manager,
    required this.child,
    this.debugLabel,
    this.includeSemantics = true,
  }) : _shortcuts = const <ShortcutActivator, Intent>{};

  final ShortcutManager? manager;
  final Map<ShortcutActivator, Intent> _shortcuts;
  final Widget child;
  final String? debugLabel;
  final bool includeSemantics;

  /// The bindings.
  Map<ShortcutActivator, Intent> get shortcuts =>
      manager?.shortcuts ?? _shortcuts;

  @override
  State<Shortcuts> createState() => _ShortcutsState();
}

class _ShortcutsState extends State<Shortcuts> {
  ShortcutManager? _internal;

  ShortcutManager get _manager => widget.manager ?? _internal!;

  @override
  void initState() {
    super.initState();
    if (widget.manager == null) {
      _internal = ShortcutManager(shortcuts: widget._shortcuts);
    }
  }

  @override
  void didUpdateWidget(Shortcuts oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.manager == null) {
      _internal ??= ShortcutManager();
      if (!identical(widget._shortcuts, oldWidget._shortcuts) ||
          oldWidget.manager != null) {
        _internal!.shortcuts = widget._shortcuts;
      }
    }
  }

  @override
  void dispose() {
    _internal?.dispose();
    super.dispose();
  }

  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    final BuildContext? context = node.context;
    if (context == null || !context.mounted) return KeyEventResult.ignored;
    return _manager.handleKeypress(context, event);
  }

  @override
  Widget build(BuildContext context) => Focus(
        debugLabel: widget.debugLabel ?? 'Shortcuts',
        canRequestFocus: false,
        skipTraversal: true,
        onKeyEvent: _onKeyEvent,
        child: widget.child,
      );
}
