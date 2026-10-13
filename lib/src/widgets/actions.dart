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

import '../platform/editing_convention.dart';
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
///
/// ## Writing a shortcut once for every platform
///
/// Save is Ctrl+S on Windows and Linux and Cmd+S on a Mac. Write it with
/// [command] and it is both:
///
/// ```dart
/// const KeyGesture(0x53 /* S */, command: true)
/// ```
///
/// [command] means "the platform's command modifier" - [KeyModifier.meta]
/// (Command) under [EditingConvention.mac], [KeyModifier.control] under
/// [EditingConvention.pc]. Everything that matches gestures goes through
/// [resolved] first, and [label] prints the platform's own notation: `⌘S`
/// on a Mac, `Ctrl+S` elsewhere. Write [control] or [meta] only for a chord
/// that really is that key on every platform.
final class KeyGesture {
  const KeyGesture(
    this.logicalKey, {
    this.control = false,
    this.shift = false,
    this.alt = false,
    this.meta = false,
    this.command = false,
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

  /// The platform's command modifier: Command on a Mac, Control elsewhere.
  final bool command;

  /// This gesture with [command] replaced by the key [convention] uses for
  /// it - what a real event is compared against.
  KeyGesture resolved([EditingConvention? convention]) {
    if (!command) return this;
    final bool mac =
        (convention ?? platformEditingConvention) == EditingConvention.mac;
    return KeyGesture(
      logicalKey,
      control: control || !mac,
      shift: shift,
      alt: alt,
      meta: meta || mac,
    );
  }

  /// Whether [event] is a press of this gesture.
  bool matches(KeyEvent event, [EditingConvention? convention]) =>
      event is KeyDownEvent &&
      KeyGesture.fromEvent(event) == resolved(convention);

  /// How a menu or a tooltip shows this gesture to the person at this
  /// machine: `⇧⌘Z` on a Mac, `Ctrl+Shift+Z` elsewhere.
  String label([EditingConvention? convention]) {
    final EditingConvention used = convention ?? platformEditingConvention;
    final KeyGesture plain = resolved(used);
    final String key = _keyLabel(logicalKey, used);
    if (used == EditingConvention.mac) {
      // Apple's order: Control, Option, Shift, Command.
      return '${plain.control ? '⌃' : ''}${plain.alt ? '⌥' : ''}'
          '${plain.shift ? '⇧' : ''}${plain.meta ? '⌘' : ''}$key';
    }
    return <String>[
      if (plain.control) 'Ctrl',
      if (plain.alt) 'Alt',
      if (plain.shift) 'Shift',
      if (plain.meta) 'Win',
      key,
    ].join('+');
  }

  static String _keyLabel(int key, EditingConvention convention) {
    final bool mac = convention == EditingConvention.mac;
    if ((key >= 0x30 && key <= 0x39) || (key >= 0x41 && key <= 0x5A)) {
      return String.fromCharCode(key);
    }
    if (key >= 0x70 && key <= 0x87) return 'F${key - 0x6F}';
    return switch (key) {
      0x08 => mac ? '⌫' : 'Backspace',
      0x09 => mac ? '⇥' : 'Tab',
      0x0D => mac ? '↩' : 'Enter',
      0x1B => mac ? '⎋' : 'Esc',
      0x20 => 'Space',
      0x21 => mac ? '⇞' : 'PageUp',
      0x22 => mac ? '⇟' : 'PageDown',
      0x23 => mac ? '↘' : 'End',
      0x24 => mac ? '↖' : 'Home',
      0x25 => '←',
      0x26 => '↑',
      0x27 => '→',
      0x28 => '↓',
      0x2D => 'Ins',
      0x2E => mac ? '⌦' : 'Del',
      0x6B || 0xBB => '+',
      0x6D || 0xBD => '-',
      0xBC => ',',
      0xBE => '.',
      0xBF => '/',
      _ => '0x${key.toRadixString(16)}',
    };
  }

  @override
  bool operator ==(Object other) =>
      other is KeyGesture &&
      other.logicalKey == logicalKey &&
      other.control == control &&
      other.shift == shift &&
      other.alt == alt &&
      other.meta == meta &&
      other.command == command;

  @override
  int get hashCode =>
      Object.hash(logicalKey, control, shift, alt, meta, command);

  @override
  String toString() {
    final StringBuffer buffer = StringBuffer();
    if (command) buffer.write('Command+');
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
