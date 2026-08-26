/// Minimal parsing of the xkb keymap v1 text format `wl_keyboard.keymap`
/// delivers, plus the evdev fallback used when no keymap arrives.
///
/// ## Scope, stated plainly
///
/// A full xkb implementation (types, actions, compat, compose, multiple
/// groups) is what libxkbcommon is for, and binding it remains the roadmap's
/// answer for complete keyboard input (section 16.7). What this file does is
/// the honest subset that makes typing work today without guessing:
///
///   * the `xkb_keycodes` section is parsed for `<NAME> = code;` entries and
///     `alias` lines;
///   * the `xkb_symbols` section is parsed for `key <NAME> { [ a, A ] };`
///     entries, keeping the **first group** and its first two shift levels;
///   * keysyms are resolved for Latin-1, `U+XXXX` names, and a table of the
///     named function/modifier keys a desktop application actually handles.
///
/// What is *not* done - and, per the `TextInputEvent` contract, must not be
/// faked: dead keys, compose sequences, non-first groups (layout switching),
/// level-3 (`AltGr`) symbols and IME. Keys whose symbol cannot be resolved
/// still produce [KeyEvent]s with their keycode; they produce no text.
library;

import '../../platform/compose_sequences.dart';
import 'wayland_protocol.dart';

/// No keysym. Comparisons against it are always false, the same posture the
/// X11 backend takes for atoms that failed to intern.
const int xkbNoSymbol = 0;

// Named keysyms this backend understands (X11/keysymdef.h values).
const int xkbKeysymBackSpace = 0xff08;
const int xkbKeysymTab = 0xff09;
const int xkbKeysymReturn = 0xff0d;
const int xkbKeysymEscape = 0xff1b;
const int xkbKeysymDelete = 0xffff;
const int xkbKeysymHome = 0xff50;
const int xkbKeysymLeft = 0xff51;
const int xkbKeysymUp = 0xff52;
const int xkbKeysymRight = 0xff53;
const int xkbKeysymDown = 0xff54;
const int xkbKeysymPrior = 0xff55;
const int xkbKeysymNext = 0xff56;
const int xkbKeysymEnd = 0xff57;
const int xkbKeysymInsert = 0xff63;
const int xkbKeysymMenu = 0xff67;
const int xkbKeysymF1 = 0xffbe;
const int xkbKeysymShiftL = 0xffe1;
const int xkbKeysymShiftR = 0xffe2;
const int xkbKeysymControlL = 0xffe3;
const int xkbKeysymControlR = 0xffe4;
const int xkbKeysymCapsLock = 0xffe5;
const int xkbKeysymAltL = 0xffe9;
const int xkbKeysymAltR = 0xffea;
const int xkbKeysymSuperL = 0xffeb;
const int xkbKeysymSuperR = 0xffec;

/// The printable text of [keysym], or null when it has none.
///
/// Latin-1 keysyms are their own code points; keysyms above `0x01000000` embed
/// the code point directly (that is how xkb spells every non-legacy Unicode
/// character). Function and modifier keysyms have no text by definition.
String? xkbKeysymToText(int keysym) {
  if (keysym >= 0x20 && keysym <= 0x7e) return String.fromCharCode(keysym);
  if (keysym >= 0xa0 && keysym <= 0xff) return String.fromCharCode(keysym);
  if (keysym >= 0x01000100 && keysym <= 0x0110ffff) {
    return String.fromCharCode(keysym - 0x01000000);
  }
  return null;
}

/// Resolves an xkb symbol *name* - `a`, `exclam`, `U00E7`, `Return` - to its
/// keysym value, or [xkbNoSymbol] when the name is outside the supported
/// subset.
int xkbKeysymFromName(String name) {
  if (name.isEmpty || name == 'NoSymbol' || name == 'VoidSymbol') {
    return xkbNoSymbol;
  }
  if (name.length == 1) {
    final code = name.codeUnitAt(0);
    if (code >= 0x20 && code <= 0x7e) return code;
  }
  // U<hex> spells any Unicode code point; keymaps emitted by xkbcommon use it
  // for everything without a legacy name.
  if ((name.startsWith('U') || name.startsWith('u')) && name.length > 1) {
    final parsed = int.tryParse(name.substring(1), radix: 16);
    if (parsed != null && parsed > 0 && parsed <= 0x10ffff) {
      return parsed < 0x100 ? parsed : 0x01000000 + parsed;
    }
  }
  // 0x-prefixed raw keysym values also appear in generated keymaps.
  if (name.startsWith('0x') || name.startsWith('0X')) {
    final parsed = int.tryParse(name.substring(2), radix: 16);
    if (parsed != null && parsed > 0) return parsed;
  }
  // The dead keys and `Multi_key` come from the Compose table's own name list
  // rather than being duplicated here: a keymap that names `dead_acute` and a
  // Compose file that names `dead_acute` have to agree on its value, and one
  // table is how they agree.
  return _namedKeysyms[name] ?? composeNamedKeysyms[name] ?? xkbNoSymbol;
}

const Map<String, int> _namedKeysyms = <String, int>{
  'space': 0x20,
  'exclam': 0x21,
  'quotedbl': 0x22,
  'numbersign': 0x23,
  'dollar': 0x24,
  'percent': 0x25,
  'ampersand': 0x26,
  'apostrophe': 0x27,
  'parenleft': 0x28,
  'parenright': 0x29,
  'asterisk': 0x2a,
  'plus': 0x2b,
  'comma': 0x2c,
  'minus': 0x2d,
  'period': 0x2e,
  'slash': 0x2f,
  'colon': 0x3a,
  'semicolon': 0x3b,
  'less': 0x3c,
  'equal': 0x3d,
  'greater': 0x3e,
  'question': 0x3f,
  'at': 0x40,
  'bracketleft': 0x5b,
  'backslash': 0x5c,
  'bracketright': 0x5d,
  'asciicircum': 0x5e,
  'underscore': 0x5f,
  'grave': 0x60,
  'braceleft': 0x7b,
  'bar': 0x7c,
  'braceright': 0x7d,
  'asciitilde': 0x7e,
  'exclamdown': 0xa1,
  'cedilla': 0xb8,
  'ccedilla': 0xe7,
  'Ccedilla': 0xc7,
  'ntilde': 0xf1,
  'Ntilde': 0xd1,
  'BackSpace': xkbKeysymBackSpace,
  'Tab': xkbKeysymTab,
  'Return': xkbKeysymReturn,
  'Escape': xkbKeysymEscape,
  'Delete': xkbKeysymDelete,
  'Home': xkbKeysymHome,
  'Left': xkbKeysymLeft,
  'Up': xkbKeysymUp,
  'Right': xkbKeysymRight,
  'Down': xkbKeysymDown,
  'Prior': xkbKeysymPrior,
  'Page_Up': xkbKeysymPrior,
  'Next': xkbKeysymNext,
  'Page_Down': xkbKeysymNext,
  'End': xkbKeysymEnd,
  'Insert': xkbKeysymInsert,
  'Menu': xkbKeysymMenu,
  'F1': xkbKeysymF1,
  'F2': xkbKeysymF1 + 1,
  'F3': xkbKeysymF1 + 2,
  'F4': xkbKeysymF1 + 3,
  'F5': xkbKeysymF1 + 4,
  'F6': xkbKeysymF1 + 5,
  'F7': xkbKeysymF1 + 6,
  'F8': xkbKeysymF1 + 7,
  'F9': xkbKeysymF1 + 8,
  'F10': xkbKeysymF1 + 9,
  'F11': xkbKeysymF1 + 10,
  'F12': xkbKeysymF1 + 11,
  'Shift_L': xkbKeysymShiftL,
  'Shift_R': xkbKeysymShiftR,
  'Control_L': xkbKeysymControlL,
  'Control_R': xkbKeysymControlR,
  'Caps_Lock': xkbKeysymCapsLock,
  'Alt_L': xkbKeysymAltL,
  'Alt_R': xkbKeysymAltR,
  'Super_L': xkbKeysymSuperL,
  'Super_R': xkbKeysymSuperR,
  'ISO_Left_Tab': xkbKeysymTab,
};

/// The two shift levels of one key in the first group.
final class XkbKeyLevels {
  const XkbKeyLevels(this.base, this.shifted);

  final int base;
  final int shifted;
}

/// One parsed keymap: xkb keycode (evdev + 8) to first-group symbol levels.
final class WaylandXkbKeymap {
  WaylandXkbKeymap._(this._levelsByKeycode, {required this.source});

  /// Where this keymap came from, for diagnostics: `xkb-v1` for a compositor
  /// keymap, `evdev-us-fallback` when none was usable.
  final String source;

  final Map<int, XkbKeyLevels> _levelsByKeycode;

  int get keyCount => _levelsByKeycode.length;

  /// Parses xkb keymap v1 text, or returns null when the two sections this
  /// parser needs cannot be found - the caller then falls back and says so.
  static WaylandXkbKeymap? parse(String text) {
    final keycodes = _extractSection(text, 'xkb_keycodes');
    final symbols = _extractSection(text, 'xkb_symbols');
    if (keycodes == null || symbols == null) return null;

    final codesByName = <String, int>{};
    for (final match in _keycodeEntry.allMatches(keycodes)) {
      codesByName[match.group(1)!] = int.parse(match.group(2)!);
    }
    for (final match in _keycodeAlias.allMatches(keycodes)) {
      final target = codesByName[match.group(2)!];
      if (target != null) codesByName[match.group(1)!] = target;
    }
    if (codesByName.isEmpty) return null;

    final levels = <int, XkbKeyLevels>{};
    for (final match in _symbolsEntry.allMatches(symbols)) {
      final keycode = codesByName[match.group(1)!];
      if (keycode == null) continue;
      final body = match.group(2)!;
      final bracket = _firstSymbolList.firstMatch(body);
      if (bracket == null) continue;
      final names = bracket
          .group(1)!
          .split(',')
          .map((String entry) => entry.trim())
          .where((String entry) => entry.isNotEmpty)
          .toList();
      if (names.isEmpty) continue;
      final base = xkbKeysymFromName(names[0]);
      final shifted =
          names.length > 1 ? xkbKeysymFromName(names[1]) : xkbNoSymbol;
      levels[keycode] = XkbKeyLevels(base, shifted);
    }
    if (levels.isEmpty) return null;
    return WaylandXkbKeymap._(levels, source: 'xkb-v1');
  }

  /// The evdev/US fallback used when the compositor sends no usable keymap.
  /// Correct only for a US layout; that limitation is what [source] reports.
  factory WaylandXkbKeymap.usFallback() {
    final levels = <int, XkbKeyLevels>{};
    void put(int evdevCode, int base, [int shifted = xkbNoSymbol]) {
      levels[evdevCode + evdevToXkbKeycodeOffset] = XkbKeyLevels(base, shifted);
    }

    void putChars(int evdevCode, String base, String shifted) {
      put(evdevCode, base.codeUnitAt(0), shifted.codeUnitAt(0));
    }

    put(1, xkbKeysymEscape);
    const digitRow = '1234567890';
    const digitShift = r'!@#$%^&*()';
    for (var i = 0; i < 10; i++) {
      putChars(2 + i, digitRow[i], digitShift[i]);
    }
    putChars(12, '-', '_');
    putChars(13, '=', '+');
    put(14, xkbKeysymBackSpace);
    put(15, xkbKeysymTab);
    const rowQ = 'qwertyuiop';
    for (var i = 0; i < rowQ.length; i++) {
      putChars(16 + i, rowQ[i], rowQ[i].toUpperCase());
    }
    putChars(26, '[', '{');
    putChars(27, ']', '}');
    put(28, xkbKeysymReturn);
    put(29, xkbKeysymControlL);
    const rowA = 'asdfghjkl';
    for (var i = 0; i < rowA.length; i++) {
      putChars(30 + i, rowA[i], rowA[i].toUpperCase());
    }
    putChars(39, ';', ':');
    putChars(40, "'", '"');
    putChars(41, '`', '~');
    put(42, xkbKeysymShiftL);
    putChars(43, r'\', '|');
    const rowZ = 'zxcvbnm';
    for (var i = 0; i < rowZ.length; i++) {
      putChars(44 + i, rowZ[i], rowZ[i].toUpperCase());
    }
    putChars(51, ',', '<');
    putChars(52, '.', '>');
    putChars(53, '/', '?');
    put(54, xkbKeysymShiftR);
    put(56, xkbKeysymAltL);
    put(57, 0x20, 0x20);
    put(58, xkbKeysymCapsLock);
    for (var i = 0; i < 10; i++) {
      put(59 + i, xkbKeysymF1 + i);
    }
    put(87, xkbKeysymF1 + 10);
    put(88, xkbKeysymF1 + 11);
    put(97, xkbKeysymControlR);
    put(100, xkbKeysymAltR);
    put(102, xkbKeysymHome);
    put(103, xkbKeysymUp);
    put(104, xkbKeysymPrior);
    put(105, xkbKeysymLeft);
    put(106, xkbKeysymRight);
    put(107, xkbKeysymEnd);
    put(108, xkbKeysymDown);
    put(109, xkbKeysymNext);
    put(110, xkbKeysymInsert);
    put(111, xkbKeysymDelete);
    put(125, xkbKeysymSuperL);
    put(126, xkbKeysymSuperR);
    put(127, xkbKeysymMenu);
    return WaylandXkbKeymap._(levels, source: 'evdev-us-fallback');
  }

  /// The keysym for [xkbKeycode] with the given modifier state.
  ///
  /// CapsLock upper-cases letters only, which is what real caps behaviour is
  /// for the alphabetic key types this parser keeps.
  int keysymFor(int xkbKeycode, {bool shift = false, bool capsLock = false}) {
    final levels = _levelsByKeycode[xkbKeycode];
    if (levels == null) return xkbNoSymbol;
    var keysym =
        shift && levels.shifted != xkbNoSymbol ? levels.shifted : levels.base;
    if (capsLock && !shift) {
      final text = xkbKeysymToText(keysym);
      if (text != null) {
        final upper = text.toUpperCase();
        if (upper != text && upper.length == 1) {
          final upperSym = upper.codeUnitAt(0);
          keysym = upperSym < 0x100 ? upperSym : 0x01000000 + upperSym;
        }
      }
    }
    return keysym;
  }

  /// The text this key produces under the given modifiers, or null for
  /// function/modifier keys and unresolved symbols.
  String? textFor(int xkbKeycode, {bool shift = false, bool capsLock = false}) {
    final keysym = keysymFor(xkbKeycode, shift: shift, capsLock: capsLock);
    if (keysym == xkbNoSymbol) return null;
    return xkbKeysymToText(keysym);
  }

  static final RegExp _keycodeEntry =
      RegExp(r'<([A-Za-z0-9_+\-]+)>\s*=\s*(\d+)\s*;');
  static final RegExp _keycodeAlias =
      RegExp(r'alias\s*<([A-Za-z0-9_+\-]+)>\s*=\s*<([A-Za-z0-9_+\-]+)>\s*;');
  static final RegExp _symbolsEntry = RegExp(
    r'key\s*<([A-Za-z0-9_+\-]+)>\s*\{([^}]*)\}',
    dotAll: true,
  );
  static final RegExp _firstSymbolList = RegExp(r'\[([^\]]*)\]');

  /// Extracts the balanced-brace body of `keyword "optional name" { ... }`.
  static String? _extractSection(String text, String keyword) {
    final start = text.indexOf(keyword);
    if (start < 0) return null;
    final open = text.indexOf('{', start);
    if (open < 0) return null;
    var depth = 0;
    for (var i = open; i < text.length; i++) {
      final char = text.codeUnitAt(i);
      if (char == 0x7b) depth++;
      if (char == 0x7d) {
        depth--;
        if (depth == 0) return text.substring(open + 1, i);
      }
    }
    return null;
  }
}

/// The `wl_keyboard.modifiers` state, interpreted with the conventional xkb
/// real-modifier bit positions (Shift=0, Lock=1, Control=2, Mod1=3, Mod4=6).
///
/// Reading the *actual* positions requires parsing the keymap's types and
/// modifier maps; every keymap xkbcommon emits uses the conventional ones, so
/// this is the documented approximation until libxkbcommon is bound.
final class WaylandModifiersState {
  int depressed = 0;
  int latched = 0;
  int locked = 0;
  int group = 0;

  int get _effective => depressed | latched | locked;

  bool get shift => (_effective & 0x01) != 0;
  bool get capsLock => (_effective & 0x02) != 0;
  bool get control => (_effective & 0x04) != 0;
  bool get alt => (_effective & 0x08) != 0;
  bool get numLock => (_effective & 0x10) != 0;
  bool get meta => (_effective & 0x40) != 0;

  void update({
    required int depressed,
    required int latched,
    required int locked,
    required int group,
  }) {
    this.depressed = depressed;
    this.latched = latched;
    this.locked = locked;
    this.group = group;
  }

  void reset() {
    depressed = 0;
    latched = 0;
    locked = 0;
    group = 0;
  }
}
