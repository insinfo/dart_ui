/// The X11 keysym namespace, which is what both Linux backends speak.
///
/// A *keysym* is not a character and not a scan code: it is the symbol the
/// layout says a key stands for at one shift level, and it is the currency of
/// every keyboard protocol descended from X - the core protocol's
/// `GetKeyboardMapping`, xkb's `xkb_symbols`, and therefore `wl_keyboard` too,
/// since a Wayland compositor hands the client an xkb keymap and nothing else.
///
/// The rules for turning one into text are short, exact and identical on both
/// backends, which is why they live here rather than once per backend:
///
///   * Latin-1 keysyms **are** their code points (`0x20`-`0x7e`, `0xa0`-`0xff`);
///   * `0x01000100`-`0x0110ffff` embed a Unicode code point directly, offset by
///     `0x01000000` - that is how xkb spells everything without a legacy name;
///   * everything else - function keys, modifiers, dead keys, `NoSymbol` - has
///     no text *by definition*, and a backend that invented one for it would be
///     committing the exact error [TextInputEvent] exists to forbid.
///
/// `wayland_keymap.dart` still carries its own copy of the text rule
/// (`xkbKeysymToText`) because it predates this file and belongs to another
/// work stream; the X11↔Wayland parity test in
/// `test/backends/x11/x11_wayland_key_parity_test.dart` asserts the two agree
/// on every keysym class, so a divergence fails a test rather than reaching a
/// user. Folding that function onto [keysymToText] is a one-line follow-up for
/// whoever owns that file next.
library;

import 'input_events.dart';

/// `NoSymbol`. Comparisons against it are always false, which is what makes an
/// unmapped key produce a [KeyEvent] with no text rather than a guess.
const int keysymNoSymbol = 0;

// ---------------------------------------------------------------------------
// Named keysyms (X11/keysymdef.h). Only the ones a desktop application has to
// recognise *by value*: modifiers, locks, and the group/level shifts, since
// those are what decide how every other key is read.
// ---------------------------------------------------------------------------

const int keysymBackSpace = 0xff08;
const int keysymTab = 0xff09;
const int keysymReturn = 0xff0d;
const int keysymEscape = 0xff1b;
const int keysymDelete = 0xffff;

const int keysymHome = 0xff50;
const int keysymLeft = 0xff51;
const int keysymUp = 0xff52;
const int keysymRight = 0xff53;
const int keysymDown = 0xff54;
const int keysymPrior = 0xff55;
const int keysymNext = 0xff56;
const int keysymEnd = 0xff57;
const int keysymInsert = 0xff63;
const int keysymMenu = 0xff67;

/// The keypad block, `KP_Space` to `KP_Equal`.
///
/// It is a *range* and not a list because the core protocol's NumLock rule is
/// stated over the range: a key whose second keysym falls in it is a keypad
/// key, and NumLock inverts which of its two symbols is chosen. See
/// [isKeypadKeysym].
const int keysymKeypadFirst = 0xff80;
const int keysymKeypadEnter = 0xff8d;
const int keysymKeypadLast = 0xffbd;

const int keysymNumLock = 0xff7f;

/// `Mode_switch`, the core protocol's group-two selector. xkb maps a layout's
/// AltGr onto it for the benefit of clients that read the core keyboard map,
/// which is exactly what this framework does.
const int keysymModeSwitch = 0xff7e;

/// `ISO_Level3_Shift`: the modern spelling of AltGr. Present in the core map
/// on layouts xkb generated, alongside or instead of [keysymModeSwitch].
const int keysymIsoLevel3Shift = 0xfe03;
const int keysymIsoLevel5Shift = 0xfe11;

const int keysymF1 = 0xffbe;

const int keysymShiftL = 0xffe1;
const int keysymShiftR = 0xffe2;
const int keysymControlL = 0xffe3;
const int keysymControlR = 0xffe4;
const int keysymCapsLock = 0xffe5;
const int keysymShiftLock = 0xffe6;
const int keysymMetaL = 0xffe7;
const int keysymMetaR = 0xffe8;
const int keysymAltL = 0xffe9;
const int keysymAltR = 0xffea;
const int keysymSuperL = 0xffeb;
const int keysymSuperR = 0xffec;
const int keysymHyperL = 0xffed;
const int keysymHyperR = 0xffee;

/// The first and last keysym of the modifier block, `Shift_L` to `Hyper_R`.
const int keysymModifierFirst = keysymShiftL;
const int keysymModifierLast = keysymHyperR;

/// The printable text of [keysym], or null when it has none.
///
/// Identical, by contract, to `xkbKeysymToText` in `wayland_keymap.dart`; see
/// the library comment for why there are two and what keeps them equal.
String? keysymToText(int keysym) {
  if (keysym >= 0x20 && keysym <= 0x7e) return String.fromCharCode(keysym);
  if (keysym >= 0xa0 && keysym <= 0xff) return String.fromCharCode(keysym);
  if (keysym >= 0x01000100 && keysym <= 0x0110ffff) {
    return String.fromCharCode(keysym - 0x01000000);
  }
  return null;
}

/// The keysym for the character [text], or [keysymNoSymbol].
///
/// The inverse of [keysymToText] and the reason case conversion below can be
/// expressed in characters rather than in a transliteration table: Dart's
/// `toUpperCase` already knows Unicode's case mapping, and re-encoding the
/// answer as a keysym is one comparison.
int keysymFromCharacter(String text) {
  if (text.length != 1) return keysymNoSymbol;
  final int code = text.codeUnitAt(0);
  if (code < 0x100) return code;
  return 0x01000000 + code;
}

/// [keysym] upper-cased the way `XConvertCase` would, or [keysym] unchanged.
///
/// Used for the core protocol's CapsLock rule, which upper-cases the *symbol*
/// rather than selecting a different level - a distinction that matters on a
/// layout where the shifted level of a letter key is not that letter's capital.
int keysymToUpper(int keysym) {
  final String? text = keysymToText(keysym);
  if (text == null) return keysym;
  final String upper = text.toUpperCase();
  if (upper == text || upper.length != 1) return keysym;
  return keysymFromCharacter(upper);
}

/// [keysym] lower-cased, for the "alphabetic key with an implied capital" rule
/// the core protocol applies when a keycode names only one symbol.
int keysymToLower(int keysym) {
  final String? text = keysymToText(keysym);
  if (text == null) return keysym;
  final String lower = text.toLowerCase();
  if (lower == text || lower.length != 1) return keysym;
  return keysymFromCharacter(lower);
}

/// Whether [keysym] has distinct upper and lower cases - the protocol's
/// "alphabetic" test, expressed over Unicode rather than over Latin-1.
bool isCasedKeysym(int keysym) {
  final String? text = keysymToText(keysym);
  if (text == null) return false;
  return text.toUpperCase() != text.toLowerCase();
}

/// Whether [keysym] is a modifier, which a Compose sequence must never see.
///
/// The modifier block is `Shift_L`-`Hyper_R`; `ISO_Level3_Shift` is the AltGr a
/// Brazilian, German or French layout uses to *reach* half the dead keys, and
/// `Mode_switch` is its core-protocol equivalent, so both are excluded too.
/// Feeding any of them to a [ComposeEngine] would break the sequence the user
/// is in the middle of, because Shift is held *during* `<dead_tilde> <A>`.
///
/// The set is deliberately the same one `wayland_events.dart` excludes, plus
/// `Mode_switch` and `ISO_Level5_Shift` - not an extension of it. `Mode_switch`
/// is what the *core* protocol calls the key a Wayland client sees as
/// `ISO_Level3_Shift`, so excluding it is what keeps the two backends
/// equivalent rather than what makes them differ. `Num_Lock` is deliberately
/// *not* here: Wayland feeds it, and the two must agree.
bool isModifierKeysym(int keysym) =>
    (keysym >= keysymModifierFirst && keysym <= keysymModifierLast) ||
    keysym == keysymIsoLevel3Shift ||
    keysym == keysymIsoLevel5Shift ||
    keysym == keysymModeSwitch;

/// Whether [keysym] belongs to the keypad block, per the core protocol's
/// NumLock rule.
bool isKeypadKeysym(int keysym) =>
    keysym >= keysymKeypadFirst && keysym <= keysymKeypadLast;

// ---------------------------------------------------------------------------
// The key the widgets compare against
// ---------------------------------------------------------------------------

/// The Windows virtual-key code for [keysym], which is what
/// [KeyEvent.logicalKey] carries on every backend.
///
/// `focus.dart` states the contract - "the Windows virtual-key values, which
/// every backend normalizes to" - and the widgets are written against it:
/// `TextField` matches `0x43` for Ctrl+C and `0x25` for the left arrow, focus
/// traversal matches `0x09` for Tab. Both Linux backends used to put the
/// keysym itself there, so on X11 and Wayland Tab was `0xff09`, the arrows
/// `0xff51`-`0xff54` and Ctrl+C `0x63`, and none of them reached a widget.
/// Text was unaffected, because text arrives as a [TextInputEvent].
///
/// The answer follows what Windows itself does with a layout:
///
///   * a **Latin letter or digit** is that letter or digit, upper-cased,
///     whatever shift level produced it - Ctrl+C and Ctrl+Shift+C are both
///     `0x43`;
///   * a key that is **not a character** - arrows, Return, the function row,
///     the modifiers, the keypad - has a fixed VK;
///   * a keysym with **no VK of its own** - `ccedilla`, `Cyrillic_es`, a dead
///     key - takes the VK of the US key in the same physical position, from
///     [xkbKeycode]. That is why Ctrl+C still copies on a Russian layout: the
///     key that types `с` is where C is.
///
/// [xkbKeycode] is the X keycode, which is the evdev code plus 8 under xkb on
/// both X11 and Wayland. Returns 0 when nothing applies.
int keysymToVirtualKey(int keysym, {int xkbKeycode = 0}) {
  if (keysym >= 0x61 && keysym <= 0x7A) return keysym - 0x20; // a-z
  if (keysym >= 0x41 && keysym <= 0x5A) return keysym; // A-Z
  if (keysym >= 0x30 && keysym <= 0x39) return keysym; // 0-9
  if (keysym == 0x20) return 0x20; // space
  if (keysym >= keysymF1 && keysym <= keysymF1 + 23) {
    return 0x70 + keysym - keysymF1; // F1-F24
  }
  final int? named =
      _keysymVirtualKeys[keysym] ?? _punctuationVirtualKeys[keysym];
  if (named != null) return named;
  return _evdevUsVirtualKeys[xkbKeycode - 8] ?? 0;
}

/// Which copy of a duplicated key [keysym] names.
///
/// The keysym already says it - `Shift_R`, `KP_1` - and a VK does not, so
/// once [KeyEvent.logicalKey] is a VK the side has to travel in
/// [KeyEvent.location], as it does on Windows.
KeyLocation keysymLocation(int keysym) {
  switch (keysym) {
    case keysymShiftL || keysymControlL || keysymAltL || keysymSuperL:
    case keysymMetaL:
      return KeyLocation.left;
    case keysymShiftR || keysymControlR || keysymAltR || keysymSuperR:
    case keysymMetaR || keysymIsoLevel3Shift:
      return KeyLocation.right;
  }
  if (isKeypadKeysym(keysym)) return KeyLocation.numpad;
  return KeyLocation.standard;
}

/// Keysyms that are not characters, and their fixed VKs.
const Map<int, int> _keysymVirtualKeys = <int, int>{
  keysymBackSpace: 0x08,
  keysymTab: 0x09,
  0xfe20: 0x09, // ISO_Left_Tab, what Shift+Tab produces
  keysymReturn: 0x0D,
  keysymEscape: 0x1B,
  keysymDelete: 0x2E,
  keysymHome: 0x24,
  keysymLeft: 0x25,
  keysymUp: 0x26,
  keysymRight: 0x27,
  keysymDown: 0x28,
  keysymPrior: 0x21,
  keysymNext: 0x22,
  keysymEnd: 0x23,
  keysymInsert: 0x2D,
  keysymMenu: 0x5D, // VK_APPS, the context-menu key
  0xff13: 0x13, // Pause
  0xff14: 0x91, // Scroll_Lock
  0xff61: 0x2C, // Print
  0xff7f: 0x90, // Num_Lock
  keysymShiftL: 0x10,
  keysymShiftR: 0x10,
  keysymControlL: 0x11,
  keysymControlR: 0x11,
  keysymAltL: 0x12,
  keysymAltR: 0x12,
  keysymIsoLevel3Shift: 0x12, // AltGr, as Windows reports it
  keysymMetaL: 0x5B,
  keysymMetaR: 0x5C,
  keysymSuperL: 0x5B,
  keysymSuperR: 0x5C,
  0xffe5: 0x14, // Caps_Lock
  // The keypad, both with NumLock on (the digits) and off (navigation).
  0xff8d: 0x0D, // KP_Enter
  0xff95: 0x24, 0xff96: 0x25, 0xff97: 0x26, 0xff98: 0x27, 0xff99: 0x28, //
  0xff9a: 0x21, 0xff9b: 0x22, 0xff9c: 0x23, 0xff9d: 0x0C, 0xff9e: 0x2D, //
  0xff9f: 0x2E, //
  0xffaa: 0x6A, 0xffab: 0x6B, 0xffac: 0x6C, 0xffad: 0x6D, 0xffae: 0x6E, //
  0xffaf: 0x6F, //
  0xffb0: 0x60, 0xffb1: 0x61, 0xffb2: 0x62, 0xffb3: 0x63, 0xffb4: 0x64, //
  0xffb5: 0x65, 0xffb6: 0x66, 0xffb7: 0x67, 0xffb8: 0x68, 0xffb9: 0x69, //
};

/// The US OEM VKs, by the Latin-1 keysym (which is the character).
const Map<int, int> _punctuationVirtualKeys = <int, int>{
  0x3B: 0xBA, 0x3A: 0xBA, // ; :
  0x3D: 0xBB, 0x2B: 0xBB, // = +
  0x2C: 0xBC, 0x3C: 0xBC, // , <
  0x2D: 0xBD, 0x5F: 0xBD, // - _
  0x2E: 0xBE, 0x3E: 0xBE, // . >
  0x2F: 0xBF, 0x3F: 0xBF, // / ?
  0x60: 0xC0, 0x7E: 0xC0, // ` ~
  0x5B: 0xDB, 0x7B: 0xDB, // [ {
  0x5C: 0xDC, 0x7C: 0xDC, // \ |
  0x5D: 0xDD, 0x7D: 0xDD, // ] }
  0x27: 0xDE, 0x22: 0xDE, // ' "
};

/// The VK of the US key at each evdev code, for a keysym with none.
const Map<int, int> _evdevUsVirtualKeys = <int, int>{
  2: 0x31, 3: 0x32, 4: 0x33, 5: 0x34, 6: 0x35, 7: 0x36, 8: 0x37, 9: 0x38, //
  10: 0x39, 11: 0x30, 12: 0xBD, 13: 0xBB, //
  16: 0x51, 17: 0x57, 18: 0x45, 19: 0x52, 20: 0x54, 21: 0x59, 22: 0x55, //
  23: 0x49, 24: 0x4F, 25: 0x50, 26: 0xDB, 27: 0xDD, //
  30: 0x41, 31: 0x53, 32: 0x44, 33: 0x46, 34: 0x47, 35: 0x48, 36: 0x4A, //
  37: 0x4B, 38: 0x4C, 39: 0xBA, 40: 0xDE, 41: 0xC0, 43: 0xDC, //
  44: 0x5A, 45: 0x58, 46: 0x43, 47: 0x56, 48: 0x42, 49: 0x4E, 50: 0x4D, //
  51: 0xBC, 52: 0xBE, 53: 0xBF, //
  86: 0xE2, // the ISO key between left Shift and Z
};
