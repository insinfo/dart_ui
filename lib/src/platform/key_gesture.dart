/// Keyboard shortcuts as values: a logical key and the modifiers held.
///
/// In the platform layer because a shortcut is about keys and the platform's
/// conventions - Command on a Mac, Control elsewhere - and nothing about
/// widgets: a command registry, a menu description and an engine with no
/// window all name shortcuts.
library;

import 'editing_convention.dart';
import 'input_events.dart';

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
