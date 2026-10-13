/// Flutter's `LogicalKeyboardKey` and `HardwareKeyboard`, over the key codes
/// the backends already report.
///
/// In the platform layer, as `logical_keys.dart` is: keys are the backends'
/// numbering, and a shortcut, a command and an engine with no window all
/// name them.
///
/// ## Why an extension type over `int`
///
/// [KeyEvent.logicalKey] is an `int` - the Windows virtual-key value every
/// backend normalizes to - and every backend, test and control constructs
/// events with one. Flutter's `KeyEvent.logicalKey` is a
/// `LogicalKeyboardKey` object. An extension type that `implements int` is
/// both at once and costs nothing at run time, so the code a Flutter app
/// writes compiles and means the same thing:
///
/// ```dart
/// if (event.logicalKey == LogicalKeyboardKey.enter) ...
/// switch (event.logicalKey) { case LogicalKeyboardKey.escape: ... }
/// const SingleActivator(LogicalKeyboardKey.keyS, control: true)
/// ```
///
/// What does not carry over: `event.logicalKey.keyLabel` (the static type of
/// the field is `int`; write `LogicalKeyboardKey(event.logicalKey).keyLabel`),
/// and the distinction between `shiftLeft` and `shiftRight` - the backends
/// report one virtual key for both and put the side in [KeyEvent.location],
/// so both constants are the same key, as Windows has it.
library;

import 'input_events.dart';

/// A key by what it means, independent of where it is on the keyboard -
/// Flutter's `LogicalKeyboardKey`, as the virtual-key code [KeyEvent]
/// carries.
extension type const LogicalKeyboardKey(int keyId) implements int {
  /// The key with [keyId], or null when this table does not name it.
  static LogicalKeyboardKey? findKeyByKeyId(int keyId) =>
      _names.containsKey(keyId) ? LogicalKeyboardKey(keyId) : null;

  /// A short label for the key as printed on a US keyboard: `A`, `Enter`,
  /// `Arrow Up`.
  String get keyLabel => _names[keyId] ?? '';

  /// A longer name, for diagnostics: `Key A`.
  String? get debugName {
    final String? name = _names[keyId];
    if (name == null) return null;
    if ((keyId >= 0x41 && keyId <= 0x5A)) return 'Key $name';
    if ((keyId >= 0x30 && keyId <= 0x39)) return 'Digit $name';
    return name;
  }

  /// Whether this is Shift, Control, Alt or Meta.
  bool get isModifier =>
      keyId == 0x10 ||
      keyId == 0x11 ||
      keyId == 0x12 ||
      keyId == 0x5B ||
      keyId == 0x5C;

  /// The modifier [KeyModifier] this key holds down, or null.
  KeyModifier? get modifier => switch (keyId) {
        0x10 => KeyModifier.shift,
        0x11 => KeyModifier.control,
        0x12 => KeyModifier.alt,
        0x5B || 0x5C => KeyModifier.meta,
        _ => null,
      };

  /// The keys that mean the same as this one with the side ignored - for
  /// [meta], both Windows/Command keys. Empty for a key with no sides.
  Set<LogicalKeyboardKey> get synonyms => switch (keyId) {
        0x5B || 0x5C => <LogicalKeyboardKey>{meta},
        0x10 => <LogicalKeyboardKey>{shift},
        0x11 => <LogicalKeyboardKey>{control},
        0x12 => <LogicalKeyboardKey>{alt},
        _ => const <LogicalKeyboardKey>{},
      };

  /// [input] with each sided key replaced by its synonym.
  static Set<LogicalKeyboardKey> collapseSynonyms(
          Set<LogicalKeyboardKey> input) =>
      <LogicalKeyboardKey>{
        for (final LogicalKeyboardKey key in input)
          key.synonyms.isEmpty ? key : key.synonyms.first,
      };

  /// [input] with each synonym replaced by the sided keys it stands for.
  static Set<LogicalKeyboardKey> expandSynonyms(
          Set<LogicalKeyboardKey> input) =>
      <LogicalKeyboardKey>{
        for (final LogicalKeyboardKey key in input)
          if (key.keyId == 0x5B) ...<LogicalKeyboardKey>[
            metaLeft,
            metaRight
          ] else
            key,
      };

  static const LogicalKeyboardKey backspace = LogicalKeyboardKey(0x08);
  static const LogicalKeyboardKey tab = LogicalKeyboardKey(0x09);
  static const LogicalKeyboardKey clear = LogicalKeyboardKey(0x0C);
  static const LogicalKeyboardKey enter = LogicalKeyboardKey(0x0D);

  /// The keypad's Enter: the same virtual key as [enter], with
  /// [KeyLocation.numpad] on the event.
  static const LogicalKeyboardKey numpadEnter = LogicalKeyboardKey(0x0D);
  static const LogicalKeyboardKey shift = LogicalKeyboardKey(0x10);
  static const LogicalKeyboardKey shiftLeft = LogicalKeyboardKey(0x10);
  static const LogicalKeyboardKey shiftRight = LogicalKeyboardKey(0x10);
  static const LogicalKeyboardKey control = LogicalKeyboardKey(0x11);
  static const LogicalKeyboardKey controlLeft = LogicalKeyboardKey(0x11);
  static const LogicalKeyboardKey controlRight = LogicalKeyboardKey(0x11);
  static const LogicalKeyboardKey alt = LogicalKeyboardKey(0x12);
  static const LogicalKeyboardKey altLeft = LogicalKeyboardKey(0x12);
  static const LogicalKeyboardKey altRight = LogicalKeyboardKey(0x12);
  static const LogicalKeyboardKey pause = LogicalKeyboardKey(0x13);
  static const LogicalKeyboardKey capsLock = LogicalKeyboardKey(0x14);
  static const LogicalKeyboardKey escape = LogicalKeyboardKey(0x1B);
  static const LogicalKeyboardKey space = LogicalKeyboardKey(0x20);
  static const LogicalKeyboardKey pageUp = LogicalKeyboardKey(0x21);
  static const LogicalKeyboardKey pageDown = LogicalKeyboardKey(0x22);
  static const LogicalKeyboardKey end = LogicalKeyboardKey(0x23);
  static const LogicalKeyboardKey home = LogicalKeyboardKey(0x24);
  static const LogicalKeyboardKey arrowLeft = LogicalKeyboardKey(0x25);
  static const LogicalKeyboardKey arrowUp = LogicalKeyboardKey(0x26);
  static const LogicalKeyboardKey arrowRight = LogicalKeyboardKey(0x27);
  static const LogicalKeyboardKey arrowDown = LogicalKeyboardKey(0x28);
  static const LogicalKeyboardKey printScreen = LogicalKeyboardKey(0x2C);
  static const LogicalKeyboardKey insert = LogicalKeyboardKey(0x2D);
  static const LogicalKeyboardKey delete = LogicalKeyboardKey(0x2E);
  static const LogicalKeyboardKey digit0 = LogicalKeyboardKey(0x30);
  static const LogicalKeyboardKey digit1 = LogicalKeyboardKey(0x31);
  static const LogicalKeyboardKey digit2 = LogicalKeyboardKey(0x32);
  static const LogicalKeyboardKey digit3 = LogicalKeyboardKey(0x33);
  static const LogicalKeyboardKey digit4 = LogicalKeyboardKey(0x34);
  static const LogicalKeyboardKey digit5 = LogicalKeyboardKey(0x35);
  static const LogicalKeyboardKey digit6 = LogicalKeyboardKey(0x36);
  static const LogicalKeyboardKey digit7 = LogicalKeyboardKey(0x37);
  static const LogicalKeyboardKey digit8 = LogicalKeyboardKey(0x38);
  static const LogicalKeyboardKey digit9 = LogicalKeyboardKey(0x39);
  static const LogicalKeyboardKey keyA = LogicalKeyboardKey(0x41);
  static const LogicalKeyboardKey keyB = LogicalKeyboardKey(0x42);
  static const LogicalKeyboardKey keyC = LogicalKeyboardKey(0x43);
  static const LogicalKeyboardKey keyD = LogicalKeyboardKey(0x44);
  static const LogicalKeyboardKey keyE = LogicalKeyboardKey(0x45);
  static const LogicalKeyboardKey keyF = LogicalKeyboardKey(0x46);
  static const LogicalKeyboardKey keyG = LogicalKeyboardKey(0x47);
  static const LogicalKeyboardKey keyH = LogicalKeyboardKey(0x48);
  static const LogicalKeyboardKey keyI = LogicalKeyboardKey(0x49);
  static const LogicalKeyboardKey keyJ = LogicalKeyboardKey(0x4A);
  static const LogicalKeyboardKey keyK = LogicalKeyboardKey(0x4B);
  static const LogicalKeyboardKey keyL = LogicalKeyboardKey(0x4C);
  static const LogicalKeyboardKey keyM = LogicalKeyboardKey(0x4D);
  static const LogicalKeyboardKey keyN = LogicalKeyboardKey(0x4E);
  static const LogicalKeyboardKey keyO = LogicalKeyboardKey(0x4F);
  static const LogicalKeyboardKey keyP = LogicalKeyboardKey(0x50);
  static const LogicalKeyboardKey keyQ = LogicalKeyboardKey(0x51);
  static const LogicalKeyboardKey keyR = LogicalKeyboardKey(0x52);
  static const LogicalKeyboardKey keyS = LogicalKeyboardKey(0x53);
  static const LogicalKeyboardKey keyT = LogicalKeyboardKey(0x54);
  static const LogicalKeyboardKey keyU = LogicalKeyboardKey(0x55);
  static const LogicalKeyboardKey keyV = LogicalKeyboardKey(0x56);
  static const LogicalKeyboardKey keyW = LogicalKeyboardKey(0x57);
  static const LogicalKeyboardKey keyX = LogicalKeyboardKey(0x58);
  static const LogicalKeyboardKey keyY = LogicalKeyboardKey(0x59);
  static const LogicalKeyboardKey keyZ = LogicalKeyboardKey(0x5A);

  /// The Windows key, Command on a Mac. [metaLeft] stands for both sides
  /// in a shortcut, as Flutter's `meta` synonym does.
  static const LogicalKeyboardKey meta = LogicalKeyboardKey(0x5B);
  static const LogicalKeyboardKey metaLeft = LogicalKeyboardKey(0x5B);
  static const LogicalKeyboardKey metaRight = LogicalKeyboardKey(0x5C);
  static const LogicalKeyboardKey contextMenu = LogicalKeyboardKey(0x5D);
  static const LogicalKeyboardKey numpad0 = LogicalKeyboardKey(0x60);
  static const LogicalKeyboardKey numpad1 = LogicalKeyboardKey(0x61);
  static const LogicalKeyboardKey numpad2 = LogicalKeyboardKey(0x62);
  static const LogicalKeyboardKey numpad3 = LogicalKeyboardKey(0x63);
  static const LogicalKeyboardKey numpad4 = LogicalKeyboardKey(0x64);
  static const LogicalKeyboardKey numpad5 = LogicalKeyboardKey(0x65);
  static const LogicalKeyboardKey numpad6 = LogicalKeyboardKey(0x66);
  static const LogicalKeyboardKey numpad7 = LogicalKeyboardKey(0x67);
  static const LogicalKeyboardKey numpad8 = LogicalKeyboardKey(0x68);
  static const LogicalKeyboardKey numpad9 = LogicalKeyboardKey(0x69);
  static const LogicalKeyboardKey numpadMultiply = LogicalKeyboardKey(0x6A);
  static const LogicalKeyboardKey numpadAdd = LogicalKeyboardKey(0x6B);
  static const LogicalKeyboardKey numpadSubtract = LogicalKeyboardKey(0x6D);
  static const LogicalKeyboardKey numpadDecimal = LogicalKeyboardKey(0x6E);
  static const LogicalKeyboardKey numpadDivide = LogicalKeyboardKey(0x6F);
  static const LogicalKeyboardKey f1 = LogicalKeyboardKey(0x70);
  static const LogicalKeyboardKey f2 = LogicalKeyboardKey(0x71);
  static const LogicalKeyboardKey f3 = LogicalKeyboardKey(0x72);
  static const LogicalKeyboardKey f4 = LogicalKeyboardKey(0x73);
  static const LogicalKeyboardKey f5 = LogicalKeyboardKey(0x74);
  static const LogicalKeyboardKey f6 = LogicalKeyboardKey(0x75);
  static const LogicalKeyboardKey f7 = LogicalKeyboardKey(0x76);
  static const LogicalKeyboardKey f8 = LogicalKeyboardKey(0x77);
  static const LogicalKeyboardKey f9 = LogicalKeyboardKey(0x78);
  static const LogicalKeyboardKey f10 = LogicalKeyboardKey(0x79);
  static const LogicalKeyboardKey f11 = LogicalKeyboardKey(0x7A);
  static const LogicalKeyboardKey f12 = LogicalKeyboardKey(0x7B);
  static const LogicalKeyboardKey f13 = LogicalKeyboardKey(0x7C);
  static const LogicalKeyboardKey f14 = LogicalKeyboardKey(0x7D);
  static const LogicalKeyboardKey f15 = LogicalKeyboardKey(0x7E);
  static const LogicalKeyboardKey f16 = LogicalKeyboardKey(0x7F);
  static const LogicalKeyboardKey f17 = LogicalKeyboardKey(0x80);
  static const LogicalKeyboardKey f18 = LogicalKeyboardKey(0x81);
  static const LogicalKeyboardKey f19 = LogicalKeyboardKey(0x82);
  static const LogicalKeyboardKey f20 = LogicalKeyboardKey(0x83);
  static const LogicalKeyboardKey f21 = LogicalKeyboardKey(0x84);
  static const LogicalKeyboardKey f22 = LogicalKeyboardKey(0x85);
  static const LogicalKeyboardKey f23 = LogicalKeyboardKey(0x86);
  static const LogicalKeyboardKey f24 = LogicalKeyboardKey(0x87);
  static const LogicalKeyboardKey numLock = LogicalKeyboardKey(0x90);
  static const LogicalKeyboardKey scrollLock = LogicalKeyboardKey(0x91);
  static const LogicalKeyboardKey semicolon = LogicalKeyboardKey(0xBA);
  static const LogicalKeyboardKey equal = LogicalKeyboardKey(0xBB);
  static const LogicalKeyboardKey comma = LogicalKeyboardKey(0xBC);
  static const LogicalKeyboardKey minus = LogicalKeyboardKey(0xBD);
  static const LogicalKeyboardKey period = LogicalKeyboardKey(0xBE);
  static const LogicalKeyboardKey slash = LogicalKeyboardKey(0xBF);
  static const LogicalKeyboardKey backquote = LogicalKeyboardKey(0xC0);
  static const LogicalKeyboardKey bracketLeft = LogicalKeyboardKey(0xDB);
  static const LogicalKeyboardKey backslash = LogicalKeyboardKey(0xDC);
  static const LogicalKeyboardKey bracketRight = LogicalKeyboardKey(0xDD);
  static const LogicalKeyboardKey quote = LogicalKeyboardKey(0xDE);
  static const LogicalKeyboardKey intlBackslash = LogicalKeyboardKey(0xE2);
}

const Map<int, String> _names = <int, String>{
  0x08: 'Backspace',
  0x09: 'Tab',
  0x0C: 'Clear',
  0x0D: 'Enter',
  0x10: 'Shift',
  0x11: 'Control',
  0x12: 'Alt',
  0x13: 'Pause',
  0x14: 'Caps Lock',
  0x1B: 'Escape',
  0x20: ' ',
  0x21: 'Page Up',
  0x22: 'Page Down',
  0x23: 'End',
  0x24: 'Home',
  0x25: 'Arrow Left',
  0x26: 'Arrow Up',
  0x27: 'Arrow Right',
  0x28: 'Arrow Down',
  0x2C: 'Print Screen',
  0x2D: 'Insert',
  0x2E: 'Delete',
  0x30: '0',
  0x31: '1',
  0x32: '2',
  0x33: '3',
  0x34: '4',
  0x35: '5',
  0x36: '6',
  0x37: '7',
  0x38: '8',
  0x39: '9',
  0x41: 'A',
  0x42: 'B',
  0x43: 'C',
  0x44: 'D',
  0x45: 'E',
  0x46: 'F',
  0x47: 'G',
  0x48: 'H',
  0x49: 'I',
  0x4A: 'J',
  0x4B: 'K',
  0x4C: 'L',
  0x4D: 'M',
  0x4E: 'N',
  0x4F: 'O',
  0x50: 'P',
  0x51: 'Q',
  0x52: 'R',
  0x53: 'S',
  0x54: 'T',
  0x55: 'U',
  0x56: 'V',
  0x57: 'W',
  0x58: 'X',
  0x59: 'Y',
  0x5A: 'Z',
  0x5B: 'Meta Left',
  0x5C: 'Meta Right',
  0x5D: 'Context Menu',
  0x60: 'Numpad 0',
  0x61: 'Numpad 1',
  0x62: 'Numpad 2',
  0x63: 'Numpad 3',
  0x64: 'Numpad 4',
  0x65: 'Numpad 5',
  0x66: 'Numpad 6',
  0x67: 'Numpad 7',
  0x68: 'Numpad 8',
  0x69: 'Numpad 9',
  0x6A: 'Numpad Multiply',
  0x6B: 'Numpad Add',
  0x6D: 'Numpad Subtract',
  0x6E: 'Numpad Decimal',
  0x6F: 'Numpad Divide',
  0x70: 'F1',
  0x71: 'F2',
  0x72: 'F3',
  0x73: 'F4',
  0x74: 'F5',
  0x75: 'F6',
  0x76: 'F7',
  0x77: 'F8',
  0x78: 'F9',
  0x79: 'F10',
  0x7A: 'F11',
  0x7B: 'F12',
  0x7C: 'F13',
  0x7D: 'F14',
  0x7E: 'F15',
  0x7F: 'F16',
  0x80: 'F17',
  0x81: 'F18',
  0x82: 'F19',
  0x83: 'F20',
  0x84: 'F21',
  0x85: 'F22',
  0x86: 'F23',
  0x87: 'F24',
  0x90: 'Num Lock',
  0x91: 'Scroll Lock',
  0xBA: ';',
  0xBB: '=',
  0xBC: ',',
  0xBD: '-',
  0xBE: '.',
  0xBF: '/',
  0xC0: '`',
  0xDB: '[',
  0xDC: r'\',
  0xDD: ']',
  0xDE: "'",
  0xE2: r'\',
};

/// A callback [HardwareKeyboard] offers every key event to.
typedef KeyEventCallback = bool Function(KeyEvent event);

/// The keyboard's state as the key events have reported it - Flutter's
/// `HardwareKeyboard`.
///
/// One for the process, as in Flutter, fed by every window's key dispatch
/// (`BuildOwner.dispatchKeyEvent`) before anything else sees the event.
/// Modifiers are read from the event's own modifier set, which the platform
/// sampled, so [isShiftPressed] is right even for a Shift pressed before the
/// window had focus, from the first event after it.
///
/// Physical keys are not modelled: [KeyEvent.physicalKey] is the platform's
/// scan code and there is no `PhysicalKeyboardKey` table here.
final class HardwareKeyboard {
  HardwareKeyboard._();

  /// The process's keyboard.
  static final HardwareKeyboard instance = HardwareKeyboard._();

  final Set<LogicalKeyboardKey> _pressed = <LogicalKeyboardKey>{};
  Set<KeyModifier> _modifiers = const <KeyModifier>{};
  final List<KeyEventCallback> _handlers = <KeyEventCallback>[];

  /// The keys held down now, by logical key.
  Set<LogicalKeyboardKey> get logicalKeysPressed =>
      Set<LogicalKeyboardKey>.unmodifiable(_pressed);

  /// Whether [key] is held.
  bool isLogicalKeyPressed(LogicalKeyboardKey key) => _pressed.contains(key);

  bool get isShiftPressed => _modifiers.contains(KeyModifier.shift);
  bool get isControlPressed => _modifiers.contains(KeyModifier.control);
  bool get isAltPressed => _modifiers.contains(KeyModifier.alt);
  bool get isMetaPressed => _modifiers.contains(KeyModifier.meta);

  /// The modifiers the last key event reported held.
  Set<KeyModifier> get modifiers => _modifiers;

  /// Adds a handler offered every key event of every window, whatever has
  /// focus. Its answer is or-ed into whether the event was handled; it
  /// cannot stop the focus system from seeing the event, as in Flutter.
  void addHandler(KeyEventCallback handler) => _handlers.add(handler);

  void removeHandler(KeyEventCallback handler) => _handlers.remove(handler);

  /// Records [event] and offers it to the handlers. Called by the key
  /// dispatch; returns whether a handler claimed it.
  bool handleKeyEvent(KeyEvent event) {
    _modifiers = event.modifiers;
    final LogicalKeyboardKey key = LogicalKeyboardKey(event.logicalKey);
    switch (event) {
      case KeyDownEvent():
        _pressed.add(key);
      case KeyUpEvent():
        _pressed.remove(key);
    }
    bool handled = false;
    for (final KeyEventCallback handler
        in List<KeyEventCallback>.of(_handlers)) {
      handled = handler(event) || handled;
    }
    return handled;
  }

  /// Forgets every held key - the window lost focus and the releases will
  /// go elsewhere. Also what a test calls between cases.
  void clearState() {
    _pressed.clear();
    _modifiers = const <KeyModifier>{};
  }
}
