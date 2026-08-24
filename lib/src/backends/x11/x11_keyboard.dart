/// The keyboard map, read from the X11 **core protocol**, and everything that
/// turns a `KeyPress` into a keysym.
///
/// ## Why the core protocol and not XKB or libxkbcommon
///
/// Three routes lead to a usable keymap, and the one taken here was chosen for
/// what it costs to *start working*, not for what it could eventually cover:
///
///  1. **Core `GetKeyboardMapping` + `GetModifierMapping`** - two requests that
///     are already in `libxcb.so.1`, which this backend has open anyway. No new
///     library, no new package dependency, no version negotiation, and both
///     replies are flat arrays whose decoding is a pure function over bytes -
///     so every rule in this file is testable on a machine with no X server,
///     which is the only way this backend gets covered at all. **This is what
///     is implemented.**
///  2. **The XKB extension over the wire** (`xkb_get_map`, `xkb_get_names`, or
///     `xkb_get_kbd_by_name` for the keymap as text, which
///     `wayland_keymap.dart` could then parse). More faithful on layouts with
///     several groups, and the only route to `DetectableAutoRepeat`. It needs
///     `libxcb-xkb.so.1` - a *second* library to find, verify and version - and
///     a reply decoder an order of magnitude larger than this file.
///  3. **libxkbcommon by FFI.** Complete, and the roadmap's eventual answer,
///     but it is a third-party runtime dependency and it abandons the posture
///     the rest of this backend takes: speak the protocol, own the state.
///
/// Route 1 delivers a working keyboard - the whole Latin world, with accents,
/// once the Compose engine is attached - for two requests and no new
/// dependency. Routes 2 and 3 remain the answer for what it does not cover,
/// and what it does not cover is stated rather than implied:
///
///   * **Only two groups.** The core map projects an xkb keymap into four
///     keysyms per keycode: group 1 levels 1-2, group 2 levels 1-2. A user with
///     three or four layouts configured reaches the first two from here; the
///     rest need XKB. Group 2 is selected by `Mode_switch`/`ISO_Level3_Shift`,
///     which is how AltGr reaches `ç`, `€` and the dead keys on a Brazilian,
///     German or French layout.
///   * **No layout-switch notification.** `MappingNotify` says the map changed
///     and it is re-read, which covers switching layouts too, but there is no
///     per-event group like xkb's.
///   * **No `DetectableAutoRepeat`.** It is an XKB per-client flag, so repeat is
///     recognised by its classic wire signature instead; see
///     [X11KeyRepeatFilter].
///   * **No IME.** XIM needs Xlib and an input context; CJK stays unavailable
///     on this backend. Dead keys are *not* IME and do work - see
///     `platform/compose_sequences.dart`.
library;

import 'dart:typed_data';

import '../../platform/input_events.dart';
import '../../platform/keysyms.dart';
import 'x11_events.dart';
import 'x11_libc.dart';
import 'x11_protocol.dart';

/// Reads a host-order 32-bit field out of a reply the connection copied.
///
/// Host order, not little-endian: XCB negotiates the client's byte order at
/// connection setup, so a reply arrives already swapped for this machine. The
/// pointer-based readers in `x11_libc.dart` make the same assumption; this one
/// exists because a reply is copied into a [Uint8List] before it is decoded,
/// which is what lets a test build one by hand.
int x11ReadU32(Uint8List bytes, int offset) {
  if (x11HostIsLittleEndian) {
    return bytes[offset] |
        (bytes[offset + 1] << 8) |
        (bytes[offset + 2] << 16) |
        (bytes[offset + 3] << 24);
  }
  return (bytes[offset] << 24) |
      (bytes[offset + 1] << 16) |
      (bytes[offset + 2] << 8) |
      bytes[offset + 3];
}

/// Writes a host-order 32-bit field. Tests build replies with it; nothing in
/// production does.
void x11WriteU32(Uint8List bytes, int offset, int value) {
  if (x11HostIsLittleEndian) {
    bytes[offset] = value & 0xff;
    bytes[offset + 1] = (value >> 8) & 0xff;
    bytes[offset + 2] = (value >> 16) & 0xff;
    bytes[offset + 3] = (value >> 24) & 0xff;
    return;
  }
  bytes[offset] = (value >> 24) & 0xff;
  bytes[offset + 1] = (value >> 16) & 0xff;
  bytes[offset + 2] = (value >> 8) & 0xff;
  bytes[offset + 3] = value & 0xff;
}

/// Every X reply begins with the same 32-byte header; variable data follows it.
const int x11ReplyHeaderBytes = 32;

// ---------------------------------------------------------------------------
// The `state` field of a KeyPress/KeyRelease/ButtonPress, and the eight rows of
// a modifier map, are the same eight modifiers in the same order.
// ---------------------------------------------------------------------------

const int x11ModShift = 1 << 0;
const int x11ModLock = 1 << 1;
const int x11ModControl = 1 << 2;
const int x11ModMod1 = 1 << 3;
const int x11ModMod2 = 1 << 4;
const int x11ModMod3 = 1 << 5;
const int x11ModMod4 = 1 << 6;
const int x11ModMod5 = 1 << 7;

/// The eight modifier masks in `GetModifierMapping` row order.
const List<int> x11ModifierMasks = <int>[
  x11ModShift,
  x11ModLock,
  x11ModControl,
  x11ModMod1,
  x11ModMod2,
  x11ModMod3,
  x11ModMod4,
  x11ModMod5,
];

/// `MappingNotify` `request` values (X11 protocol, MappingNotify).
const int x11MappingModifier = 0;
const int x11MappingKeyboard = 1;
const int x11MappingPointer = 2;

/// The keysyms one keycode names, as the core protocol defines them.
///
/// Four, always, after the protocol's own padding rules have been applied - see
/// [X11KeyboardMapping.groupOf]. Group 1 is what an unmodified keyboard
/// produces; group 2 is what `Mode_switch` (AltGr) reaches.
final class X11KeyGroup {
  const X11KeyGroup(this.level1, this.level2);

  static const X11KeyGroup empty = X11KeyGroup(keysymNoSymbol, keysymNoSymbol);

  final int level1;
  final int level2;

  bool get isEmpty => level1 == keysymNoSymbol && level2 == keysymNoSymbol;

  @override
  String toString() => 'X11KeyGroup(0x${level1.toRadixString(16)}, '
      '0x${level2.toRadixString(16)})';
}

/// The reply to `GetKeyboardMapping`, decoded.
///
/// Wire layout (X11 protocol, GetKeyboardMapping):
///
/// ```
///   1   Reply                                  byte 0
///   1   keysyms-per-keycode (n)                byte 1
///   2   sequence number                        bytes 2-3
///   4   reply length = n * count               bytes 4-7
///   24  unused                                 bytes 8-31
///   4n*count  KEYSYMs                          byte 32 onwards
/// ```
///
/// `count` is not in the reply: it is what the *request* asked for, so the
/// caller passes [firstKeycode] and the count is recovered from the length.
final class X11KeyboardMapping {
  X11KeyboardMapping._({
    required this.firstKeycode,
    required this.keysymsPerKeycode,
    required Uint32List keysyms,
  }) : _keysyms = keysyms;

  /// The lowest keycode this mapping describes; below it, nothing is known.
  final int firstKeycode;

  /// How many keysyms the server lists per keycode - `n` in the wire layout.
  /// Two on a bare server, four on anything running xkb, occasionally more.
  final int keysymsPerKeycode;

  final Uint32List _keysyms;

  /// How many keycodes are described.
  int get keycodeCount =>
      keysymsPerKeycode == 0 ? 0 : _keysyms.length ~/ keysymsPerKeycode;

  int get lastKeycode => firstKeycode + keycodeCount - 1;

  /// Decodes one `GetKeyboardMapping` reply, or null when it is malformed.
  ///
  /// Null rather than an exception, and rather than a partial map: a reply that
  /// does not parse means the keyboard is unknown, and the backend then says so
  /// in a diagnostic instead of typing wrong characters.
  static X11KeyboardMapping? decodeReply(
    Uint8List reply, {
    required int firstKeycode,
  }) {
    if (reply.length < x11ReplyHeaderBytes) return null;
    final int perKeycode = reply[1];
    if (perKeycode == 0) return null;
    final int wordCount = x11ReadU32(reply, 4);
    if (wordCount <= 0 || wordCount % perKeycode != 0) return null;
    final int available = (reply.length - x11ReplyHeaderBytes) ~/ 4;
    if (available < wordCount) return null;
    final keysyms = Uint32List(wordCount);
    for (var i = 0; i < wordCount; i++) {
      keysyms[i] = x11ReadU32(reply, x11ReplyHeaderBytes + i * 4);
    }
    return X11KeyboardMapping._(
      firstKeycode: firstKeycode,
      keysymsPerKeycode: perKeycode,
      keysyms: keysyms,
    );
  }

  /// Builds a mapping directly from keysym lists. The seam tests use, and the
  /// seam a future XKB decoder would fill in without touching anything below.
  factory X11KeyboardMapping.fromLists(
    List<List<int>> perKeycode, {
    required int firstKeycode,
  }) {
    var width = 0;
    for (final List<int> list in perKeycode) {
      if (list.length > width) width = list.length;
    }
    if (width == 0) width = 1;
    final keysyms = Uint32List(perKeycode.length * width);
    for (var k = 0; k < perKeycode.length; k++) {
      final List<int> list = perKeycode[k];
      for (var i = 0; i < list.length; i++) {
        keysyms[k * width + i] = list[i];
      }
    }
    return X11KeyboardMapping._(
      firstKeycode: firstKeycode,
      keysymsPerKeycode: width,
      keysyms: keysyms,
    );
  }

  /// The raw keysym at [index] of [keycode], or [keysymNoSymbol].
  int rawKeysym(int keycode, int index) {
    if (index < 0 || index >= keysymsPerKeycode) return keysymNoSymbol;
    final int slot = keycode - firstKeycode;
    if (slot < 0 || slot >= keycodeCount) return keysymNoSymbol;
    return _keysyms[slot * keysymsPerKeycode + index];
  }

  /// One group of [keycode], with the protocol's padding rules applied.
  ///
  /// The rules are the protocol's own, and every one of them exists because a
  /// server is allowed to list fewer symbols than a client needs:
  ///
  ///   * a list of one, `[K]`, is `[K, NoSymbol]`;
  ///   * a list of two, `[K1, K2]`, repeats into group 2 - which is why a
  ///     keyboard with no AltGr layer still answers group 2 sensibly;
  ///   * a list of three pads the fourth with `NoSymbol`;
  ///   * finally, **in each group**, a second element of `NoSymbol` beside an
  ///     alphabetic first element means the pair is that letter's lower and
  ///     upper case. This is the rule that makes `a`/`A` work on a server that
  ///     lists a single keysym for the key, and skipping it is the classic way
  ///     Shift stops working on half a keyboard.
  X11KeyGroup groupOf(int keycode, {bool second = false}) {
    final int slot = keycode - firstKeycode;
    if (slot < 0 || slot >= keycodeCount) return X11KeyGroup.empty;
    final int base = slot * keysymsPerKeycode;
    final int k1 = _keysyms[base];
    final int k2 = keysymsPerKeycode > 1 ? _keysyms[base + 1] : keysymNoSymbol;
    int k3 = keysymsPerKeycode > 2 ? _keysyms[base + 2] : keysymNoSymbol;
    int k4 = keysymsPerKeycode > 3 ? _keysyms[base + 3] : keysymNoSymbol;
    if (k3 == keysymNoSymbol && k4 == keysymNoSymbol) {
      // "If the list is of length 2, it is treated as [K1, K2, K1, K2]" - the
      // second group repeats the first rather than being empty.
      k3 = k1;
      k4 = k2;
    }
    return second ? _normalize(k3, k4) : _normalize(k1, k2);
  }

  static X11KeyGroup _normalize(int level1, int level2) {
    if (level2 != keysymNoSymbol) return X11KeyGroup(level1, level2);
    if (level1 == keysymNoSymbol) return X11KeyGroup.empty;
    if (!isCasedKeysym(level1)) return X11KeyGroup(level1, keysymNoSymbol);
    return X11KeyGroup(keysymToLower(level1), keysymToUpper(level1));
  }

  /// The keysym [keycode] produces under the given modifier state.
  ///
  /// This is the core protocol's own selection algorithm, in the protocol's own
  /// order, and the order is the point - NumLock is tested *before* CapsLock
  /// because a keypad key under NumLock is a digit whatever CapsLock says.
  int keysymFor(
    int keycode, {
    bool shift = false,
    bool capsLock = false,
    bool numLock = false,
    bool shiftLock = false,
    bool group2 = false,
  }) {
    final X11KeyGroup group = groupOf(keycode, second: group2);
    if (group.isEmpty) return keysymNoSymbol;

    // NumLock, when the group's second symbol is a keypad symbol: NumLock
    // inverts the pair, so an unshifted KP_End is KP_1 and Shift takes it back.
    if (numLock && isKeypadKeysym(group.level2)) {
      if (shift || (capsLock && shiftLock)) return group.level1;
      return group.level2;
    }

    // ShiftLock is not CapsLock: it selects the shifted symbol outright rather
    // than upper-casing the unshifted one. Rare, but the protocol distinguishes
    // them and a layout that uses it is unusable if this collapses them.
    if (shiftLock && !shift) {
      final int selected =
          group.level2 != keysymNoSymbol ? group.level2 : group.level1;
      return selected;
    }

    if (!shift) {
      final int selected = group.level1;
      return capsLock ? keysymToUpper(selected) : selected;
    }
    final int selected =
        group.level2 != keysymNoSymbol ? group.level2 : group.level1;
    return capsLock ? keysymToUpper(selected) : selected;
  }

  /// The text [keycode] produces, or null for a key that produces none.
  String? textFor(
    int keycode, {
    bool shift = false,
    bool capsLock = false,
    bool numLock = false,
    bool shiftLock = false,
    bool group2 = false,
  }) {
    final int keysym = keysymFor(
      keycode,
      shift: shift,
      capsLock: capsLock,
      numLock: numLock,
      shiftLock: shiftLock,
      group2: group2,
    );
    if (keysym == keysymNoSymbol) return null;
    return keysymToText(keysym);
  }

  @override
  String toString() => 'X11KeyboardMapping($keycodeCount keycodes from '
      '$firstKeycode, $keysymsPerKeycode keysyms each)';
}

/// The reply to `GetModifierMapping`, decoded.
///
/// Wire layout (X11 protocol, GetModifierMapping):
///
/// ```
///   1   Reply                                  byte 0
///   1   keycodes-per-modifier (n)              byte 1
///   2   sequence number                        bytes 2-3
///   4   reply length = 2n                      bytes 4-7
///   24  unused                                 bytes 8-31
///   8n  KEYCODEs                               byte 32 onwards
/// ```
///
/// The `8n` bytes are eight rows of `n` keycodes, in the order Shift, Lock,
/// Control, Mod1..Mod5. A zero keycode is an empty slot, not keycode zero.
final class X11ModifierMapping {
  X11ModifierMapping._(this.keycodesPerModifier, this._keycodes);

  final int keycodesPerModifier;
  final Uint8List _keycodes;

  /// An empty map - nothing is bound to anything. What a server that refused
  /// the request leaves behind, and the state in which only Shift, Lock and
  /// Control (whose bits the protocol fixes) can be trusted.
  static final X11ModifierMapping empty = X11ModifierMapping._(0, Uint8List(0));

  static X11ModifierMapping? decodeReply(Uint8List reply) {
    if (reply.length < x11ReplyHeaderBytes) return null;
    final int perModifier = reply[1];
    if (perModifier == 0) return X11ModifierMapping.empty;
    final int needed = perModifier * 8;
    if (reply.length < x11ReplyHeaderBytes + needed) return null;
    return X11ModifierMapping._(
      perModifier,
      Uint8List.fromList(
        reply.sublist(x11ReplyHeaderBytes, x11ReplyHeaderBytes + needed),
      ),
    );
  }

  /// Builds a map from eight explicit rows. The seam tests use.
  factory X11ModifierMapping.fromRows(List<List<int>> rows) {
    if (rows.length != 8) {
      throw ArgumentError.value(
        rows.length,
        'rows',
        'a modifier map has exactly eight rows',
      );
    }
    var width = 0;
    for (final List<int> row in rows) {
      if (row.length > width) width = row.length;
    }
    if (width == 0) return X11ModifierMapping.empty;
    final keycodes = Uint8List(width * 8);
    for (var r = 0; r < 8; r++) {
      for (var i = 0; i < rows[r].length; i++) {
        keycodes[r * width + i] = rows[r][i];
      }
    }
    return X11ModifierMapping._(width, keycodes);
  }

  /// The keycodes bound to the modifier at [row], 0 (Shift) to 7 (Mod5).
  Iterable<int> keycodesForRow(int row) sync* {
    if (keycodesPerModifier == 0 || row < 0 || row > 7) return;
    for (var i = 0; i < keycodesPerModifier; i++) {
      final int keycode = _keycodes[row * keycodesPerModifier + i];
      if (keycode != 0) yield keycode;
    }
  }

  /// The modifier mask [keycode] is bound to, or 0 when it is not a modifier.
  int maskOfKeycode(int keycode) {
    if (keycode == 0 || keycodesPerModifier == 0) return 0;
    for (var row = 0; row < 8; row++) {
      for (var i = 0; i < keycodesPerModifier; i++) {
        if (_keycodes[row * keycodesPerModifier + i] == keycode) {
          return x11ModifierMasks[row];
        }
      }
    }
    return 0;
  }

  @override
  String toString() =>
      'X11ModifierMapping($keycodesPerModifier keycodes per modifier)';
}

/// Which of `Mod1`-`Mod5` the *user's* keyboard actually put Alt, Meta, Super,
/// NumLock and AltGr on.
///
/// The protocol fixes only three: Shift, Lock and Control. Everything else is
/// wherever the layout put it, and it genuinely moves - Alt is `Mod1` almost
/// everywhere and Super is `Mod4` on GNOME and KDE, but a Sun keyboard, a
/// remapped `~/.Xmodmap` or a virtual X server can place them anywhere. Xlib
/// clients that hard-code `Mod1 == Alt` are the reason Alt+Tab breaks on
/// unusual setups, so this resolves them by looking at *which keysyms* the
/// keycodes in each row produce.
final class X11ModifierSemantics {
  const X11ModifierSemantics({
    required this.altMask,
    required this.metaMask,
    required this.superMask,
    required this.numLockMask,
    required this.modeSwitchMask,
    required this.lockIsCapsLock,
    required this.lockIsShiftLock,
  });

  /// The state every X server guarantees, used when nothing could be resolved.
  ///
  /// `Mod1` for Alt and `Mod2` for NumLock are the conventional assignments
  /// every desktop uses; taking them when the modifier map could not be read is
  /// a documented guess, not a silent one - the backend says so in a
  /// diagnostic.
  static const X11ModifierSemantics conventional = X11ModifierSemantics(
    altMask: x11ModMod1,
    metaMask: 0,
    superMask: x11ModMod4,
    numLockMask: x11ModMod2,
    modeSwitchMask: x11ModMod5,
    lockIsCapsLock: true,
    lockIsShiftLock: false,
  );

  final int altMask;
  final int metaMask;
  final int superMask;
  final int numLockMask;

  /// The modifier that selects group 2 - `Mode_switch` or `ISO_Level3_Shift`,
  /// which is to say AltGr.
  final int modeSwitchMask;

  final bool lockIsCapsLock;
  final bool lockIsShiftLock;

  /// Resolves the semantics of a modifier map by reading the keysyms its
  /// keycodes produce.
  ///
  /// Only level 1 of group 1 is consulted, because a modifier key has one
  /// symbol; consulting the shifted level would find whatever the layout put
  /// on an unused level and bind a modifier to it.
  static X11ModifierSemantics resolve(
    X11ModifierMapping modifiers,
    X11KeyboardMapping? keyboard,
  ) {
    if (keyboard == null || modifiers.keycodesPerModifier == 0) {
      return conventional;
    }
    var alt = 0;
    var meta = 0;
    var superMod = 0;
    var numLock = 0;
    var modeSwitch = 0;
    var lockIsCaps = false;
    var lockIsShift = false;

    for (var row = 0; row < 8; row++) {
      final int mask = x11ModifierMasks[row];
      for (final int keycode in modifiers.keycodesForRow(row)) {
        // Every level, not only the first: a keyboard whose AltGr is
        // `ISO_Level3_Shift` at level 1 and `Multi_key` at level 2 still binds
        // the modifier, and a `Mode_switch` parked at level 2 of the same key
        // is how several stock layouts spell AltGr for core clients.
        for (var level = 0; level < keyboard.keysymsPerKeycode; level++) {
          switch (keyboard.rawKeysym(keycode, level)) {
            case keysymAltL:
            case keysymAltR:
              if (mask != x11ModShift &&
                  mask != x11ModLock &&
                  mask != x11ModControl) {
                alt |= mask;
              }
            case keysymMetaL:
            case keysymMetaR:
              if (mask != x11ModShift &&
                  mask != x11ModLock &&
                  mask != x11ModControl) {
                meta |= mask;
              }
            case keysymSuperL:
            case keysymSuperR:
            case keysymHyperL:
            case keysymHyperR:
              if (mask != x11ModShift &&
                  mask != x11ModLock &&
                  mask != x11ModControl) {
                superMod |= mask;
              }
            case keysymNumLock:
              numLock |= mask;
            case keysymModeSwitch:
            case keysymIsoLevel3Shift:
              modeSwitch |= mask;
            case keysymCapsLock:
              if (mask == x11ModLock) lockIsCaps = true;
            case keysymShiftLock:
              if (mask == x11ModLock) lockIsShift = true;
          }
        }
      }
    }
    return X11ModifierSemantics(
      altMask: alt,
      metaMask: meta,
      superMask: superMod,
      numLockMask: numLock,
      modeSwitchMask: modeSwitch,
      // A Lock row that names neither keysym is treated as CapsLock, which is
      // what it is on every keyboard made since the protocol was written.
      lockIsCapsLock: lockIsCaps || !lockIsShift,
      lockIsShiftLock: lockIsShift,
    );
  }

  /// A line for the probe report: which physical modifier ended up where.
  String describe() {
    String name(int mask) {
      if (mask == 0) return 'none';
      final parts = <String>[];
      const names = <String>[
        'Shift',
        'Lock',
        'Control',
        'Mod1',
        'Mod2',
        'Mod3',
        'Mod4',
        'Mod5',
      ];
      for (var i = 0; i < 8; i++) {
        if ((mask & x11ModifierMasks[i]) != 0) parts.add(names[i]);
      }
      return parts.join('+');
    }

    return 'alt=${name(altMask)}, meta=${name(metaMask)}, '
        'super=${name(superMask)}, numlock=${name(numLockMask)}, '
        'altgr=${name(modeSwitchMask)}, '
        'lock=${lockIsShiftLock ? 'ShiftLock' : 'CapsLock'}';
  }
}

/// The keyboard as this backend knows it: a map, a modifier map, and the rules
/// that read one `state` word.
///
/// Pure. It holds no connection and no pointer, which is what makes every rule
/// below reachable from a test on a machine with no X server.
final class X11KeyboardState {
  X11KeyboardState({
    X11KeyboardMapping? keyboard,
    X11ModifierMapping? modifiers,
    X11ModifierSemantics? semantics,
    this.source = 'none',
  })  : _keyboard = keyboard,
        _modifiers = modifiers ?? X11ModifierMapping.empty,
        _semantics = semantics ??
            X11ModifierSemantics.resolve(
              modifiers ?? X11ModifierMapping.empty,
              keyboard,
            );

  X11KeyboardMapping? _keyboard;
  X11ModifierMapping _modifiers;
  X11ModifierSemantics _semantics;

  /// Where the map came from, for diagnostics: `core-keyboard-mapping` when the
  /// server answered, `none` when it did not.
  String source;

  X11KeyboardMapping? get keyboard => _keyboard;
  X11ModifierMapping get modifiers => _modifiers;
  X11ModifierSemantics get semantics => _semantics;

  /// True when a keysym can be resolved at all. False means [KeyEvent]s still
  /// go out with their keycode and no text is ever produced - the honest state
  /// for a server that refused `GetKeyboardMapping`.
  bool get hasKeymap => _keyboard != null;

  /// Replaces the map after a `MappingNotify` or at startup.
  void adopt({
    X11KeyboardMapping? keyboard,
    X11ModifierMapping? modifiers,
    String? source,
  }) {
    if (keyboard != null) _keyboard = keyboard;
    if (modifiers != null) _modifiers = modifiers;
    if (source != null) this.source = source;
    _semantics = X11ModifierSemantics.resolve(_modifiers, _keyboard);
  }

  bool shiftOf(int state) => (state & x11ModShift) != 0;
  bool controlOf(int state) => (state & x11ModControl) != 0;

  bool capsLockOf(int state) =>
      _semantics.lockIsCapsLock && (state & x11ModLock) != 0;

  bool shiftLockOf(int state) =>
      _semantics.lockIsShiftLock && (state & x11ModLock) != 0;

  bool numLockOf(int state) =>
      _semantics.numLockMask != 0 && (state & _semantics.numLockMask) != 0;

  bool altOf(int state) =>
      _semantics.altMask != 0 && (state & _semantics.altMask) != 0;

  bool metaOf(int state) =>
      _semantics.metaMask != 0 && (state & _semantics.metaMask) != 0;

  bool superOf(int state) =>
      _semantics.superMask != 0 && (state & _semantics.superMask) != 0;

  bool group2Of(int state) =>
      _semantics.modeSwitchMask != 0 &&
      (state & _semantics.modeSwitchMask) != 0;

  /// The keysym [keycode] produces under [state], or [keysymNoSymbol].
  int keysymFor(int keycode, int state) {
    final X11KeyboardMapping? keyboard = _keyboard;
    if (keyboard == null) return keysymNoSymbol;
    return keyboard.keysymFor(
      keycode,
      shift: shiftOf(state),
      capsLock: capsLockOf(state),
      numLock: numLockOf(state),
      shiftLock: shiftLockOf(state),
      group2: group2Of(state),
    );
  }

  /// The text [keycode] produces under [state], or null.
  String? textFor(int keycode, int state) {
    final int keysym = keysymFor(keycode, state);
    if (keysym == keysymNoSymbol) return null;
    return keysymToText(keysym);
  }

  /// The framework's modifier set for one `state` word.
  ///
  /// `Meta` covers both the `Super` keys (what every modern desktop calls the
  /// Windows/Command key) and the historical `Meta` keysym, because the
  /// framework has one [KeyModifier.meta] and a shortcut bound to it must fire
  /// for whichever of the two the user's keyboard reports.
  Set<KeyModifier> modifierSetOf(int state) {
    if (state == 0) return const <KeyModifier>{};
    final bool shift = shiftOf(state);
    final bool control = controlOf(state);
    final bool alt = altOf(state);
    final bool meta = metaOf(state) || superOf(state);
    final bool caps = capsLockOf(state);
    final bool num = numLockOf(state);
    if (!shift && !control && !alt && !meta && !caps && !num) {
      return const <KeyModifier>{};
    }
    return <KeyModifier>{
      if (shift) KeyModifier.shift,
      if (control) KeyModifier.control,
      if (alt) KeyModifier.alt,
      if (meta) KeyModifier.meta,
      if (caps) KeyModifier.capsLock,
      if (num) KeyModifier.numLock,
    };
  }

  @override
  String toString() => 'X11KeyboardState(source: $source, '
      'keys: ${_keyboard?.keycodeCount ?? 0})';
}

/// Recognises the X server's auto-repeat, which arrives as a *release*.
///
/// With `DetectableAutoRepeat` off - the default, and the only state reachable
/// without `libxcb-xkb` - a held key does not repeat `KeyPress`. It repeats the
/// pair: `KeyRelease` immediately followed by `KeyPress`, on the same keycode,
/// **with the same server timestamp**, because the server stamps both from the
/// same repeat tick. A client that believes the release types `aaaa` as four
/// separate presses with three spurious releases in between, and any widget
/// tracking which keys are held sees the key come up and go down forty times a
/// second.
///
/// The fix needs one event of lookahead, and the cheapest honest way to get it
/// is to *defer*: a `KeyRelease` is held rather than delivered, and the next
/// event decides what it was. A matching `KeyPress` cancels it and is marked as
/// a repeat; anything else releases it first, in order. The delay is one event,
/// never a clock, so nothing here is timing-dependent and all of it is testable.
///
/// [detectableAutoRepeat] exists for the day `xcb_xkb_per_client_flags` is
/// bound: with it set, the server stops sending the synthetic release and this
/// filter becomes a pass-through, which is what the flag is worth.
final class X11KeyRepeatFilter {
  X11KeyRepeatFilter({this.detectableAutoRepeat = false});

  /// Set once XKB's `DetectableAutoRepeat` has been negotiated. Until then the
  /// deferral below is what stands in for it.
  bool detectableAutoRepeat;

  final X11RawEvent _held = X11RawEvent();
  bool _hasHeld = false;

  /// Whether a release is currently deferred. Diagnostics and tests.
  bool get isHolding => _hasHeld;

  /// Feeds one decoded event, delivering zero, one or two events to [deliver].
  ///
  /// The event object handed to [deliver] is reused; a callee must not retain
  /// it, which is the same contract [X11RawEvent] already carries.
  void accept(X11RawEvent raw, void Function(X11RawEvent event) deliver) {
    if (_hasHeld) {
      if (raw.type == xcbKeyPress &&
          raw.detail == _held.detail &&
          raw.timestamp == _held.timestamp &&
          raw.window == _held.window) {
        // The release never happened: this is the server repeating.
        _hasHeld = false;
        raw.repeat = true;
        deliver(raw);
        return;
      }
      _hasHeld = false;
      deliver(_held);
    }
    if (raw.type == xcbKeyRelease && !detectableAutoRepeat) {
      _held.copyFrom(raw);
      _hasHeld = true;
      return;
    }
    deliver(raw);
  }

  /// Delivers a deferred release. Called when the pump has run dry, so that a
  /// key released as the last event of a pump is not held until the next one.
  void flush(void Function(X11RawEvent event) deliver) {
    if (!_hasHeld) return;
    _hasHeld = false;
    deliver(_held);
  }

  /// Forgets a deferred release without delivering it - the window died, or
  /// the connection did. Delivering a release for a window that is gone is the
  /// late-callback bug the generation token exists for.
  void cancel() => _hasHeld = false;

  @override
  String toString() => 'X11KeyRepeatFilter(detectable: $detectableAutoRepeat, '
      'holding: $_hasHeld)';
}
