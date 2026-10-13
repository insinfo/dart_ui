/// Application shortcuts bound to callbacks, the same on every platform.
library;

import '../platform/input_events.dart';
import 'actions.dart';
import 'dialogs.dart';
import 'element.dart';
import 'widget.dart';

/// Runs a callback when its key gesture is pressed anywhere in the window,
/// while this widget is mounted.
///
/// The menu commands of a desktop application - New, Open, Save, Undo,
/// Group - are what this is for. Write each gesture once with
/// [KeyGesture.command] and it is Cmd on a Mac and Ctrl elsewhere; show the
/// same gesture in the menu with [KeyGesture.label], and the menu advertises
/// exactly the chord that works.
///
/// ```dart
/// CallbackShortcuts(
///   bindings: <KeyGesture, void Function()?>{
///     const KeyGesture(0x53, command: true): save,          // ⌘S / Ctrl+S
///     const KeyGesture(0x5A, command: true, shift: true): redo,
///     const KeyGesture(0x47, command: true): canGroup ? group : null,
///   },
///   child: editor,
/// )
/// ```
///
/// The focused control sees the key first, so Cmd+C in a text field copies
/// the field's text and never reaches a binding here; a key nothing consumed
/// falls through to these bindings. A null callback is a command that is
/// unavailable right now: the key passes on as if unbound.
///
/// Flutter's widget of this name only answers while focus is inside it;
/// this one listens at the window, because an application's menu
/// commands must work whichever panel was clicked last.
final class CallbackShortcuts extends StatefulWidget {
  const CallbackShortcuts({
    super.key,
    required this.bindings,
    required this.child,
  });

  final Map<KeyGesture, void Function()?> bindings;
  final Widget child;

  @override
  State<CallbackShortcuts> createState() => _CallbackShortcutsState();
}

final class _CallbackShortcutsState extends State<CallbackShortcuts> {
  BuildOwner? _owner;
  Map<KeyGesture, void Function()?> _resolved =
      const <KeyGesture, void Function()?>{};

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  @override
  void didUpdateWidget(CallbackShortcuts oldWidget) {
    super.didUpdateWidget(oldWidget);
    _resolve();
  }

  void _resolve() {
    _resolved = <KeyGesture, void Function()?>{
      for (final MapEntry<KeyGesture, void Function()?> entry
          in widget.bindings.entries)
        entry.key.resolved(): entry.value,
    };
  }

  bool _handle(KeyEvent event) {
    if (!mounted || event is! KeyDownEvent) return false;
    final void Function()? callback = _resolved[KeyGesture.fromEvent(event)];
    if (callback == null) return false;
    callback();
    return true;
  }

  @override
  void dispose() {
    _owner?.removeWindowKeyHandler(_handle);
    _owner = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_owner == null && context is Element) {
      // Inside a dialog, at its depth: the dialog's shortcuts answer while
      // it is open, the window's behind it do not.
      _owner = context.owner
        ?..addWindowKeyHandler(_handle, modalDepth: modalDepthOf(context));
    }
    return widget.child;
  }
}
