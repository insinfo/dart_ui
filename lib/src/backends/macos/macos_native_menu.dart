/// The menu bar description the macOS host turns into `NSMenu`s.
library;

import 'dart:convert';

import '../../platform/input_events.dart';
import '../../platform/native_menu.dart';

/// [menus] as the JSON `MENU_SET` installs.
///
/// A list of menus; each entry is `{"t":"menu","l":label,"c":[...]}`,
/// `{"t":"item","id":n,"l":label,"e":enabled,"x":checked,"k":key,"m":mask}`
/// or `{"t":"sep"}`. `k` is an `NSMenuItem.keyEquivalent`, and the mask is
/// 1 Shift, 2 Control, 4 Option, 8 Command - the host maps it onto
/// `NSEventModifierFlags`.
String encodeMacosMenus(List<NativeMenu> menus) =>
    jsonEncode(<Object?>[for (final NativeMenu menu in menus) _entry(menu)]);

Map<String, Object?> _entry(NativeMenuEntry entry) {
  switch (entry) {
    case NativeMenu(:final String label, :final List<NativeMenuEntry> children):
      return <String, Object?>{
        't': 'menu',
        'l': label,
        'c': <Object?>[
          for (final NativeMenuEntry child in children) _entry(child),
        ],
      };
    case NativeMenuItem():
      final String? key = macosKeyEquivalent(entry.key, entry.modifiers);
      return <String, Object?>{
        't': 'item',
        'id': entry.id,
        'l': entry.label,
        'e': entry.enabled,
        'x': entry.checked,
        if (key != null) 'k': key,
        if (key != null) 'm': _mask(entry.modifiers),
      };
    case NativeMenuSeparator():
      return const <String, Object?>{'t': 'sep'};
  }
}

int _mask(Set<KeyModifier> modifiers) =>
    (modifiers.contains(KeyModifier.shift) ? 1 : 0) |
    (modifiers.contains(KeyModifier.control) ? 2 : 0) |
    (modifiers.contains(KeyModifier.alt) ? 4 : 0) |
    (modifiers.contains(KeyModifier.meta) ? 8 : 0);

/// The `NSMenuItem.keyEquivalent` for logical [key] held with [modifiers],
/// or null when the menu should show none.
///
/// None for a key that types text unless Command or Control is held: the
/// host routes the keys a menu shows to the window, but an item that shows
/// `V` alone would read as if pressing V anywhere ran it, which in a text
/// field it does not. Function keys type nothing and are shown bare.
String? macosKeyEquivalent(int? key, Set<KeyModifier> modifiers) {
  if (key == null) return null;
  final bool chord = modifiers.contains(KeyModifier.meta) ||
      modifiers.contains(KeyModifier.control);
  if (key >= 0x70 && key <= 0x87) {
    return String.fromCharCode(0xF704 + key - 0x70);
  }
  final String? character = switch (key) {
    >= 0x30 && <= 0x39 => String.fromCharCode(key),
    >= 0x41 && <= 0x5A => String.fromCharCode(key + 0x20),
    0x08 => '\b',
    0x09 => '\t',
    0x0D => '\r',
    0x1B => '\x1B',
    0x20 => ' ',
    0x21 => '\uF72C',
    0x22 => '\uF72D',
    0x23 => '\uF72B',
    0x24 => '\uF729',
    0x25 => '\uF702',
    0x26 => '\uF700',
    0x27 => '\uF703',
    0x28 => '\uF701',
    0x2E => '\uF728',
    0x6B => '+',
    0xBB => '=',
    0x6D || 0xBD => '-',
    0xBC => ',',
    0xBE => '.',
    0xBF => '/',
    _ => null,
  };
  return chord ? character : null;
}
