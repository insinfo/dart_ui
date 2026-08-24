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
