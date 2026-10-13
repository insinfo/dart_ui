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
import '../platform/key_gesture.dart';
import 'focus.dart' show KeyEventResult;

export '../platform/key_gesture.dart';

/// What the user asked for, independent of how they asked.
abstract class Intent {
  const Intent();

  /// An intent nothing acts on, bound to a key to take it from the
  /// shortcuts further out - Flutter's `Intent.doNothing`.
  static const DoNothingIntent doNothing = DoNothingIntent._();
}

/// Activate the focused control: Space/Enter, a click, or an automation
/// invoke all produce this.
class ActivateIntent extends Intent {
  const ActivateIntent();
}

/// Activate a button - Flutter's `ButtonActivateIntent`, which Space sends
/// where Enter sends [ActivateIntent].
class ButtonActivateIntent extends Intent {
  const ButtonActivateIntent();
}

/// Dismiss the innermost dismissible thing: a popup, a dialog, an edit.
class DismissIntent extends Intent {
  const DismissIntent();
}

/// Move focus one step.
class NextFocusIntent extends Intent {
  const NextFocusIntent();
}

class PreviousFocusIntent extends Intent {
  const PreviousFocusIntent();
}

/// An intent that does nothing: bound to a key, it is handled by
/// `DoNothingAction` and the key is used up - Flutter's `DoNothingIntent`.
class DoNothingIntent extends Intent {
  const factory DoNothingIntent() = DoNothingIntent._;

  const DoNothingIntent._();
}

/// Like [DoNothingIntent], but the key goes on to the platform: no handler
/// in the framework sees it - Flutter's `DoNothingAndStopPropagationIntent`.
class DoNothingAndStopPropagationIntent extends Intent {
  const factory DoNothingAndStopPropagationIntent() =
      DoNothingAndStopPropagationIntent._;

  const DoNothingAndStopPropagationIntent._();
}

/// An intent that carries the code to run - Flutter's `VoidCallbackIntent`,
/// handled by `VoidCallbackAction`.
class VoidCallbackIntent extends Intent {
  const VoidCallbackIntent(this.callback);

  final void Function() callback;
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

/// Called by an [Action] whose enabled state may have changed.
typedef ActionListenerCallback = void Function(Action<Intent> action);

/// The listeners of each action, kept outside it so that an action can
/// still be `const`.
final Expando<List<ActionListenerCallback>> _actionListeners =
    Expando<List<ActionListenerCallback>>('Action listeners');

/// Something that can carry out an [Intent].
abstract class Action<T extends Intent> {
  const Action();

  /// Whether this action can run right now. A disabled action lets the
  /// shortcut fall through, which is what keeps Ctrl+C working in the panel
  /// behind an empty selection.
  ///
  /// [isActionEnabled] by default, as in Flutter.
  bool isEnabled(T intent) => isActionEnabled;

  /// Whether this action is enabled whatever the intent.
  bool get isActionEnabled => true;

  /// Whether a key that invoked this is used up. False lets the key go on
  /// to the platform after the action ran - Flutter's `consumesKey`.
  bool consumesKey(T intent) => true;

  /// What a shortcut answers after invoking this - Flutter's
  /// `Action.toKeyEventResult`.
  KeyEventResult toKeyEventResult(T intent, Object? invokeResult) =>
      consumesKey(intent)
          ? KeyEventResult.handled
          : KeyEventResult.skipRemainingHandlers;

  /// The intent type this action is for.
  Type get intentType => T;

  /// Carries out [intent]. Returns whatever the action wants its invoker to
  /// see - Flutter's `Object?`; most actions return nothing.
  Object? invoke(T intent);

  /// Calls [listener] when [notifyActionListeners] says the enabled state
  /// may have changed.
  void addActionListener(ActionListenerCallback listener) =>
      (_actionListeners[this] ??= <ActionListenerCallback>[]).add(listener);

  void removeActionListener(ActionListenerCallback listener) =>
      _actionListeners[this]?.remove(listener);

  /// Tells the listeners this action's enabled state may have changed.
  void notifyActionListeners() {
    final List<ActionListenerCallback>? listeners = _actionListeners[this];
    if (listeners == null) return;
    for (final ActionListenerCallback listener
        in List<ActionListenerCallback>.of(listeners)) {
      listener(this);
    }
  }
}

/// The code a [CallbackAction] runs - Flutter's `OnInvokeCallback`.
typedef OnInvokeCallback<T extends Intent> = Object? Function(T intent);

/// An action defined by a closure, for the many one-line cases - Flutter's
/// `CallbackAction(onInvoke: ...)`.
///
/// [isEnabled] is this framework's addition: a disabled callback lets the
/// key through as an unbound one would.
class CallbackAction<T extends Intent> extends Action<T> {
  const CallbackAction({
    required this.onInvoke,
    bool Function(T intent)? isEnabled,
  }) : _isEnabled = isEnabled;

  /// What invoking this runs.
  final OnInvokeCallback<T> onInvoke;
  final bool Function(T intent)? _isEnabled;

  @override
  bool isEnabled(T intent) => _isEnabled?.call(intent) ?? true;

  @override
  Object? invoke(T intent) => onInvoke(intent);
}

/// Runs the callback a [VoidCallbackIntent] carries.
class VoidCallbackAction extends Action<VoidCallbackIntent> {
  VoidCallbackAction();

  @override
  Object? invoke(VoidCallbackIntent intent) {
    intent.callback();
    return null;
  }
}

/// Does nothing, and uses up the key unless [consumesKey] is false -
/// Flutter's `DoNothingAction`.
class DoNothingAction extends Action<Intent> {
  DoNothingAction({bool consumesKey = true}) : _consumesKey = consumesKey;

  final bool _consumesKey;

  @override
  bool consumesKey(Intent intent) => _consumesKey;

  @override
  void invoke(Intent intent) {}
}

/// Key gestures bound to intents, with an optional parent to fall back to.
///
/// Chaining maps is how a dialog can override Escape without redefining every
/// other shortcut the application has.
final class ShortcutMap {
  ShortcutMap(Map<KeyGesture, Intent> bindings, {this.parent})
      : _bindings = <KeyGesture, Intent>{
          for (final MapEntry<KeyGesture, Intent> entry in bindings.entries)
            entry.key.resolved(): entry.value,
        };

  final Map<KeyGesture, Intent> _bindings;
  final ShortcutMap? parent;

  Map<KeyGesture, Intent> get bindings =>
      Map<KeyGesture, Intent>.unmodifiable(_bindings);

  void bind(KeyGesture gesture, Intent intent) =>
      _bindings[gesture.resolved()] = intent;

  void unbind(KeyGesture gesture) => _bindings.remove(gesture.resolved());

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
  Object? invoke(Intent intent) => intent is T ? _inner.invoke(intent) : null;
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
