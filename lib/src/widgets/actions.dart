/// Shortcuts, intents and actions.
///
/// Section 27.6 states the constraint plainly: separate the key from the
/// behaviour, so that Ctrl/Command is not hard-coded into every widget. The
/// chain is therefore three links, each replaceable on its own:
///
/// ```
/// ShortcutMap  :  key gesture   -> Intent   (what the user asked for)
/// ActionMap    :  Intent        -> Action   (who can do it here)
/// Action       :  Intent        -> effect
/// ```
///
/// The middle link is the one that pays. A `CopyIntent` means "copy" whether it
/// arrived from Ctrl+C, a menu item, a toolbar button or an accessibility
/// invoke, and the control that implements copying never learns which.
library;

import '../platform/input_events.dart';

/// What the user asked for, independent of how they asked.
abstract class Intent {
  const Intent();
}

/// Activate the focused control: Space/Enter, a click, or an automation
/// invoke all produce this.
final class ActivateIntent extends Intent {
  const ActivateIntent();
}

/// Dismiss the innermost dismissible thing: a popup, a dialog, an edit.
final class DismissIntent extends Intent {
  const DismissIntent();
}

/// Move focus one step.
final class NextFocusIntent extends Intent {
  const NextFocusIntent();
}

final class PreviousFocusIntent extends Intent {
  const PreviousFocusIntent();
}

/// Move a value or a selection by one step, for sliders, lists and spinners.
final class DirectionalIntent extends Intent {
  const DirectionalIntent(this.dx, this.dy);

  final int dx;
  final int dy;

  @override
  bool operator ==(Object other) =>
      other is DirectionalIntent && other.dx == dx && other.dy == dy;

  @override
  int get hashCode => Object.hash(dx, dy);
}

/// Scroll the nearest scrollable by one unit.
final class ScrollIntent extends Intent {
  const ScrollIntent({required this.dx, required this.dy, this.page = false});

  final double dx;
  final double dy;
  final bool page;

  @override
  bool operator ==(Object other) =>
      other is ScrollIntent &&
      other.dx == dx &&
      other.dy == dy &&
      other.page == page;

  @override
  int get hashCode => Object.hash(dx, dy, page);
}

/// Something that can carry out an [Intent].
abstract class Action<T extends Intent> {
  const Action();

  /// Whether this action can run right now. A disabled action lets the
  /// shortcut fall through, which is what keeps Ctrl+C working in the panel
  /// behind an empty selection.
  bool isEnabled(T intent) => true;

  void invoke(T intent);
}

/// An action defined by a closure, for the many one-line cases.
final class CallbackAction<T extends Intent> extends Action<T> {
  const CallbackAction(this._onInvoke, {bool Function(T intent)? isEnabled})
      : _isEnabled = isEnabled;

  final void Function(T intent) _onInvoke;
  final bool Function(T intent)? _isEnabled;

  @override
  bool isEnabled(T intent) => _isEnabled?.call(intent) ?? true;

  @override
  void invoke(T intent) => _onInvoke(intent);
}

/// A key gesture: one logical key plus the modifiers that must be held.
///
/// Equality is by value so a map lookup answers "is this combination bound"
/// in one probe. Lock keys are ignored: a shortcut that stops working because
/// Num Lock is on is a bug report, not a feature.
final class KeyGesture {
  const KeyGesture(
    this.logicalKey, {
    this.control = false,
    this.shift = false,
    this.alt = false,
    this.meta = false,
  });

  /// Builds a gesture from a real event, discarding lock modifiers.
  factory KeyGesture.fromEvent(KeyEvent event) => KeyGesture(
        event.logicalKey,
        control: event.modifiers.contains(KeyModifier.control),
        shift: event.modifiers.contains(KeyModifier.shift),
        alt: event.modifiers.contains(KeyModifier.alt),
        meta: event.modifiers.contains(KeyModifier.meta),
      );

  final int logicalKey;
  final bool control;
  final bool shift;
  final bool alt;
  final bool meta;

  @override
  bool operator ==(Object other) =>
      other is KeyGesture &&
      other.logicalKey == logicalKey &&
      other.control == control &&
      other.shift == shift &&
      other.alt == alt &&
      other.meta == meta;

  @override
  int get hashCode => Object.hash(logicalKey, control, shift, alt, meta);

  @override
  String toString() {
    final StringBuffer buffer = StringBuffer();
    if (control) buffer.write('Ctrl+');
    if (alt) buffer.write('Alt+');
    if (shift) buffer.write('Shift+');
    if (meta) buffer.write('Meta+');
    buffer.write('0x${logicalKey.toRadixString(16)}');
    return buffer.toString();
  }
}

/// Key gestures bound to intents, with an optional parent to fall back to.
///
/// Chaining maps is how a dialog can override Escape without redefining every
/// other shortcut the application has.
final class ShortcutMap {
  ShortcutMap(Map<KeyGesture, Intent> bindings, {this.parent})
      : _bindings = Map<KeyGesture, Intent>.of(bindings);

  final Map<KeyGesture, Intent> _bindings;
  final ShortcutMap? parent;

  Map<KeyGesture, Intent> get bindings =>
      Map<KeyGesture, Intent>.unmodifiable(_bindings);

  void bind(KeyGesture gesture, Intent intent) => _bindings[gesture] = intent;

  void unbind(KeyGesture gesture) => _bindings.remove(gesture);

  /// The intent bound to [event], searching this map before its parent.
  Intent? resolve(KeyEvent event) {
    if (event is! KeyDownEvent) return null;
    final KeyGesture gesture = KeyGesture.fromEvent(event);
    return _bindings[gesture] ?? parent?.resolve(event);
  }
}

/// Intents mapped to the actions that carry them out here.
///
/// Also chained: an action map is looked up from the focused control outward,
/// so the innermost handler wins and an unhandled intent keeps travelling.
final class ActionMap {
  ActionMap([Map<Type, Action<Intent>>? actions, this.parent])
      : _actions = <Type, Action<Intent>>{...?actions};

  final Map<Type, Action<Intent>> _actions;
  final ActionMap? parent;

  /// Registers [action] for intents of exactly type [T].
  void register<T extends Intent>(Action<T> action) {
    _actions[T] = _ActionAdapter<T>(action);
  }

  void unregister<T extends Intent>() => _actions.remove(T);

  /// The action bound to [intent]'s runtime type, innermost map first.
  Action<Intent>? find(Intent intent) =>
      _actions[intent.runtimeType] ?? parent?.find(intent);

  /// Runs the action for [intent] when one is bound and enabled.
  ///
  /// Returns false when nothing handled it, which callers use to keep looking
  /// - up an action map chain, then at the platform.
  bool invoke(Intent intent) {
    for (ActionMap? map = this; map != null; map = map.parent) {
      final Action<Intent>? action = map._actions[intent.runtimeType];
      if (action == null) continue;
      if (!action.isEnabled(intent)) continue;
      action.invoke(intent);
      return true;
    }
    return false;
  }
}

/// Restores the static type an [ActionMap] erases when it stores actions by
/// intent type.
final class _ActionAdapter<T extends Intent> extends Action<Intent> {
  const _ActionAdapter(this._inner);

  final Action<T> _inner;

  @override
  bool isEnabled(Intent intent) => intent is T && _inner.isEnabled(intent);

  @override
  void invoke(Intent intent) {
    if (intent is T) _inner.invoke(intent);
  }
}

/// Resolves a key event to an intent and dispatches it to an action.
///
/// The single place that knows the chain exists; controls see intents, and
/// backends see key events.
final class ShortcutDispatcher {
  ShortcutDispatcher({required this.shortcuts, required this.actions});

  ShortcutMap shortcuts;
  ActionMap actions;

  /// Returns true when [event] resolved to an intent that an action handled.
  bool dispatch(KeyEvent event) {
    final Intent? intent = shortcuts.resolve(event);
    if (intent == null) return false;
    return actions.invoke(intent);
  }
}
