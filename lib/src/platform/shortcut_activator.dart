/// Flutter's shortcut activators: what decides whether a key event triggers
/// a shortcut.
///
/// In the platform layer, beside [KeyGesture], because [KeyGesture] is one
/// of them: a map written with `KeyGesture` keys and one written with
/// [SingleActivator] keys are the same `Map<ShortcutActivator, ...>` to the
/// `Shortcuts` and `CallbackShortcuts` widgets.
library;

import 'input_events.dart';
import 'logical_keyboard_key.dart';

/// Something that decides whether a key event activates a shortcut.
abstract class ShortcutActivator {
  const ShortcutActivator();

  /// The keys whose press can activate this, for an index; null means
  /// "any key, ask [accepts]".
  Iterable<LogicalKeyboardKey>? get triggers => null;

  /// Whether [event] activates this, with the keyboard in [state].
  bool accepts(KeyEvent event, HardwareKeyboard state);

  /// Whether [event] activates [activator], with the process's keyboard.
  static bool isActivatedBy(ShortcutActivator activator, KeyEvent event) =>
      (activator.triggers?.contains(LogicalKeyboardKey(event.logicalKey)) ??
          true) &&
      activator.accepts(event, HardwareKeyboard.instance);

  /// The keys, for diagnostics.
  String debugDescribeKeys();
}

/// Whether a lock key must be on, off, or does not matter.
enum LockState { ignored, locked, unlocked }

/// Shared by the activators that name modifiers: exactly these held.
mixin _ModifierMatch {
  bool get control;
  bool get shift;
  bool get alt;
  bool get meta;

  bool modifiersMatch(Set<KeyModifier> held, {bool checkShift = true}) =>
      held.contains(KeyModifier.control) == control &&
      (!checkShift || held.contains(KeyModifier.shift) == shift) &&
      held.contains(KeyModifier.alt) == alt &&
      held.contains(KeyModifier.meta) == meta;
}

/// One key with exactly the modifiers named - Flutter's `SingleActivator`.
///
/// Compared by identity, as in Flutter, so that it can be a key of a
/// `const` shortcut map.
///
/// `SingleActivator(LogicalKeyboardKey.keyS, control: true)` is Ctrl+S and
/// not Ctrl+Shift+S. A repeat (a key held down) activates it unless
/// [includeRepeats] is false. Write [KeyGesture] with `command: true` for a
/// shortcut that is Cmd on a Mac and Ctrl elsewhere.
class SingleActivator extends ShortcutActivator with _ModifierMatch {
  const SingleActivator(
    this.trigger, {
    this.control = false,
    this.shift = false,
    this.alt = false,
    this.meta = false,
    this.numLock = LockState.ignored,
    this.includeRepeats = true,
  });

  final LogicalKeyboardKey trigger;
  @override
  final bool control;
  @override
  final bool shift;
  @override
  final bool alt;
  @override
  final bool meta;
  final LockState numLock;
  final bool includeRepeats;

  @override
  Iterable<LogicalKeyboardKey> get triggers => <LogicalKeyboardKey>[trigger];

  @override
  bool accepts(KeyEvent event, HardwareKeyboard state) {
    if (event is! KeyDownEvent) return false;
    if (event.isRepeat && !includeRepeats) return false;
    if (event.logicalKey != trigger) return false;
    final Set<KeyModifier> held = event.modifiers;
    if (!modifiersMatch(held)) return false;
    return switch (numLock) {
      LockState.ignored => true,
      LockState.locked => held.contains(KeyModifier.numLock),
      LockState.unlocked => !held.contains(KeyModifier.numLock),
    };
  }

  @override
  String debugDescribeKeys() => <String>[
        if (control) 'Control',
        if (alt) 'Alt',
        if (meta) 'Meta',
        if (shift) 'Shift',
        trigger.debugName ?? trigger.keyLabel,
      ].join(' + ');

  @override
  String toString() => 'SingleActivator(${debugDescribeKeys()})';
}

/// A shortcut named by the character it types - Flutter's
/// `CharacterActivator`, so `CharacterActivator('?')` is whatever key makes a
/// question mark.
///
/// **Approximate here.** A [KeyEvent] carries no character: text arrives
/// separately, as a [TextInputEvent], because only the platform's layout
/// knows what a key types. So the character is read from the key as a US
/// keyboard types it - letters, digits, space and the US punctuation, Shift
/// choosing the shifted symbol. On another layout a punctuation shortcut
/// may answer to a different key than the one printed with the character.
/// Shift is not compared, as in Flutter: it is part of the character.
class CharacterActivator extends ShortcutActivator with _ModifierMatch {
  const CharacterActivator(
    this.character, {
    this.alt = false,
    this.control = false,
    this.meta = false,
    this.includeRepeats = true,
  });

  final String character;
  @override
  final bool alt;
  @override
  final bool control;
  @override
  final bool meta;
  @override
  bool get shift => false;
  final bool includeRepeats;

  @override
  bool accepts(KeyEvent event, HardwareKeyboard state) {
    if (event is! KeyDownEvent) return false;
    if (event.isRepeat && !includeRepeats) return false;
    if (!modifiersMatch(event.modifiers, checkShift: false)) return false;
    return usLayoutCharacter(event) == character;
  }

  @override
  String debugDescribeKeys() => <String>[
        if (control) 'Control',
        if (alt) 'Alt',
        if (meta) 'Meta',
        "'$character'",
      ].join(' + ');

  @override
  String toString() => 'CharacterActivator(${debugDescribeKeys()})';
}

/// The character [event]'s key types on a US keyboard, or null. See
/// [CharacterActivator] for why this is a guess.
String? usLayoutCharacter(KeyEvent event) {
  final int key = event.logicalKey;
  final bool shift = event.modifiers.contains(KeyModifier.shift);
  if (key >= 0x41 && key <= 0x5A) {
    final bool upper = shift != event.modifiers.contains(KeyModifier.capsLock);
    final String letter = String.fromCharCode(key);
    return upper ? letter : letter.toLowerCase();
  }
  if (key >= 0x30 && key <= 0x39) {
    return shift ? ')!@#\$%^&*('[key - 0x30] : String.fromCharCode(key);
  }
  if (key >= 0x60 && key <= 0x69) return String.fromCharCode(key - 0x30);
  return switch (key) {
    0x20 => ' ',
    0x6A => '*',
    0x6B => '+',
    0x6D => '-',
    0x6E => '.',
    0x6F => '/',
    0xBA => shift ? ':' : ';',
    0xBB => shift ? '+' : '=',
    0xBC => shift ? '<' : ',',
    0xBD => shift ? '_' : '-',
    0xBE => shift ? '>' : '.',
    0xBF => shift ? '?' : '/',
    0xC0 => shift ? '~' : '`',
    0xDB => shift ? '{' : '[',
    0xDC => shift ? '|' : r'\',
    0xDD => shift ? '}' : ']',
    0xDE => shift ? '"' : "'",
    _ => null,
  };
}

/// A set of keys pressed together - Flutter's `LogicalKeySet`.
///
/// Order does not matter, and a sided modifier stands for both sides:
/// `LogicalKeySet(LogicalKeyboardKey.control, LogicalKeyboardKey.keyC)` is
/// Ctrl+C with either Control. Exactly these keys: Ctrl+Shift+C does not
/// activate it. Flutter recommends [SingleActivator] for new code, and so
/// does this one.
class LogicalKeySet extends ShortcutActivator {
  LogicalKeySet(
    LogicalKeyboardKey key1, [
    LogicalKeyboardKey? key2,
    LogicalKeyboardKey? key3,
    LogicalKeyboardKey? key4,
  ]) : keys = <LogicalKeyboardKey>{
          key1,
          if (key2 != null) key2,
          if (key3 != null) key3,
          if (key4 != null) key4,
        };

  LogicalKeySet.fromSet(Set<LogicalKeyboardKey> keys)
      : keys = Set<LogicalKeyboardKey>.of(keys) {
    if (keys.isEmpty) {
      throw ArgumentError.value(keys, 'keys', 'a key set needs a key');
    }
  }

  /// The keys, as given.
  final Set<LogicalKeyboardKey> keys;

  Set<KeyModifier> get _modifiers => <KeyModifier>{
        for (final LogicalKeyboardKey key in keys)
          if (key.modifier != null) key.modifier!,
      };

  Set<LogicalKeyboardKey> get _others => <LogicalKeyboardKey>{
        for (final LogicalKeyboardKey key in keys)
          if (!key.isModifier) key,
      };

  @override
  Iterable<LogicalKeyboardKey> get triggers {
    final Set<LogicalKeyboardKey> others = _others;
    return others.isEmpty ? keys : others;
  }

  @override
  bool accepts(KeyEvent event, HardwareKeyboard state) {
    if (event is! KeyDownEvent) return false;
    final LogicalKeyboardKey key = LogicalKeyboardKey(event.logicalKey);
    if (!triggers.contains(key)) return false;
    const Set<KeyModifier> sided = <KeyModifier>{
      KeyModifier.shift,
      KeyModifier.control,
      KeyModifier.alt,
      KeyModifier.meta,
    };
    final Set<KeyModifier> held = event.modifiers.intersection(sided).toSet();
    final Set<KeyModifier> wanted = _modifiers;
    // A modifier being pressed is itself the trigger: it is in the set and
    // may not be reported as held yet by the press that holds it.
    if (key.modifier != null) held.add(key.modifier!);
    if (held.length != wanted.length || !held.containsAll(wanted)) {
      return false;
    }
    for (final LogicalKeyboardKey other in _others) {
      if (other == key) continue;
      if (!state.isLogicalKeyPressed(other)) return false;
    }
    return true;
  }

  @override
  String debugDescribeKeys() =>
      keys.map((LogicalKeyboardKey k) => k.debugName ?? k.keyLabel).join(' + ');

  @override
  bool operator ==(Object other) =>
      other is LogicalKeySet &&
      other.keys.length == keys.length &&
      other.keys.containsAll(keys);

  @override
  int get hashCode => Object.hashAllUnordered(keys);

  @override
  String toString() => 'LogicalKeySet(${debugDescribeKeys()})';
}
