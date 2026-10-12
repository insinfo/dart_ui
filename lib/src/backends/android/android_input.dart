/// Android key codes, meta state and tool types, in the framework's terms.
///
/// Logical keys are the Win32 virtual-key numbers every backend reports (see
/// `macos_input.dart`): letters and digits as their ASCII capitals, the rest
/// from the VK table. Android names keys by position on a reference layout
/// (`AKEYCODE_*`, `android/keycodes.h`), so most of this is one table.
library;

import '../../platform/input_events.dart';
import 'android_host_protocol.dart';

// KeyEvent meta state (android/input.h).
const int _metaShift = 0x1;
const int _metaAlt = 0x2;
const int _metaCtrl = 0x1000;
const int _metaMeta = 0x10000;
const int _metaCapsLock = 0x100000;

/// The `AKEYCODE_BACK` the host turns into [AndroidHostMessage.back]; it
/// never arrives as a key.
const int androidKeyBack = 4;

Set<KeyModifier> androidKeyModifiers(int metaState) => <KeyModifier>{
      if (metaState & _metaShift != 0) KeyModifier.shift,
      if (metaState & _metaCtrl != 0) KeyModifier.control,
      if (metaState & _metaAlt != 0) KeyModifier.alt,
      if (metaState & _metaMeta != 0) KeyModifier.meta,
      if (metaState & _metaCapsLock != 0) KeyModifier.capsLock,
    };

/// The VK for [keyCode], or 0 when the key has none.
int androidLogicalKey(int keyCode) {
  if (keyCode >= 29 && keyCode <= 54) return 0x41 + keyCode - 29; // A-Z
  if (keyCode >= 7 && keyCode <= 16) return 0x30 + keyCode - 7; // 0-9
  if (keyCode >= 131 && keyCode <= 142) return 0x70 + keyCode - 131; // F1-12
  if (keyCode >= 144 && keyCode <= 153) return 0x60 + keyCode - 144; // KP0-9
  return _keys[keyCode] ?? 0;
}

KeyLocation androidKeyLocation(int keyCode) => switch (keyCode) {
      59 || 57 || 113 || 117 => KeyLocation.left,
      60 || 58 || 114 || 118 => KeyLocation.right,
      >= 144 && <= 160 => KeyLocation.numpad,
      _ => KeyLocation.standard,
    };

/// What a key typed, as text, or null for a key that types nothing - the
/// controls Return and Tab included, which an editor handles as keys.
String? androidKeyText(int unicodeChar, int metaState) {
  if (unicodeChar <= 0) return null;
  if (metaState & (_metaCtrl | _metaMeta) != 0) return null;
  if (unicodeChar < 0x20 || (unicodeChar >= 0x7F && unicodeChar <= 0x9F)) {
    return null;
  }
  return String.fromCharCode(unicodeChar);
}

PointerKind androidPointerKind(AndroidToolType tool) => switch (tool) {
      AndroidToolType.mouse => PointerKind.mouse,
      AndroidToolType.stylus || AndroidToolType.eraser => PointerKind.stylus,
      AndroidToolType.finger || AndroidToolType.unknown => PointerKind.touch,
    };

/// The button a press is, from `MotionEvent.getButtonState` for a mouse;
/// a finger or a pen is the primary button.
PointerButton androidPointerButton(AndroidToolType tool, int buttonState) {
  if (tool != AndroidToolType.mouse) return PointerButton.primary;
  if (buttonState & 0x2 != 0) return PointerButton.secondary;
  if (buttonState & 0x4 != 0) return PointerButton.middle;
  if (buttonState & 0x8 != 0) return PointerButton.back;
  if (buttonState & 0x10 != 0) return PointerButton.forward;
  return PointerButton.primary;
}

const Map<int, int> _keys = <int, int>{
  19: 0x26, // DPAD_UP
  20: 0x28, // DPAD_DOWN
  21: 0x25, // DPAD_LEFT
  22: 0x27, // DPAD_RIGHT
  23: 0x0D, // DPAD_CENTER
  24: 0xAF, // VOLUME_UP
  25: 0xAE, // VOLUME_DOWN
  164: 0xAD, // VOLUME_MUTE
  55: 0xBC, // COMMA
  56: 0xBE, // PERIOD
  57: 0x12, // ALT_LEFT
  58: 0x12, // ALT_RIGHT
  59: 0x10, // SHIFT_LEFT
  60: 0x10, // SHIFT_RIGHT
  61: 0x09, // TAB
  62: 0x20, // SPACE
  66: 0x0D, // ENTER
  67: 0x08, // DEL (backspace)
  68: 0xC0, // GRAVE
  69: 0xBD, // MINUS
  70: 0xBB, // EQUALS
  71: 0xDB, // LEFT_BRACKET
  72: 0xDD, // RIGHT_BRACKET
  73: 0xDC, // BACKSLASH
  74: 0xBA, // SEMICOLON
  75: 0xDE, // APOSTROPHE
  76: 0xBF, // SLASH
  92: 0x21, // PAGE_UP
  93: 0x22, // PAGE_DOWN
  111: 0x1B, // ESCAPE
  112: 0x2E, // FORWARD_DEL
  113: 0x11, // CTRL_LEFT
  114: 0x11, // CTRL_RIGHT
  115: 0x14, // CAPS_LOCK
  117: 0x5B, // META_LEFT
  118: 0x5C, // META_RIGHT
  122: 0x24, // MOVE_HOME
  123: 0x23, // MOVE_END
  124: 0x2D, // INSERT
  154: 0x6F, // NUMPAD_DIVIDE
  155: 0x6A, // NUMPAD_MULTIPLY
  156: 0x6D, // NUMPAD_SUBTRACT
  157: 0x6B, // NUMPAD_ADD
  158: 0x6E, // NUMPAD_DOT
  160: 0x0D, // NUMPAD_ENTER
};
