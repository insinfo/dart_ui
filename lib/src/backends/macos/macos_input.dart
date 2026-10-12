/// AppKit input, as the framework's input events.
///
/// The host reports every `NSEvent` its window receives as an `INPUT=` line
/// (see [HostInputDetail]) and the characters a key press produced as a
/// `TEXT_INPUT=` line. This file turns those into [PointerEvent]s,
/// [KeyEvent]s and [TextInputEvent]s, and is pure: no AppKit, no process,
/// nothing a test on Linux cannot run.
///
/// ## Which number a key gets
///
/// `focus.dart` states the rule: [KeyEvent.logicalKey] is a **Windows
/// virtual-key code** on every backend, because that is what the widgets
/// compare against (`TextField` matches `0x43` for C, `0x25` for the left
/// arrow). So a macOS key has to arrive as the VK the same key would have on
/// Windows, and there are two different answers depending on the key:
///
///   * **keys that are not characters** - arrows, Return, Delete, the function
///     row, the modifiers, the keypad - are positional and layout independent
///     on both platforms, so they map by hardware key code (`kVK_*`);
///   * **keys that are characters** take the letter the *layout* puts there,
///     from `charactersIgnoringModifiers`, because a Windows VK for a letter is
///     the letter too: Cmd+Z on an AZERTY keyboard is the key labelled Z, not
///     the key in the US Z position. Only when the layout produces something
///     with no VK of its own (`ç` on ABNT2, `ñ` on Spanish) does the key fall
///     back to the VK of the US key in that physical position.
///
/// [KeyEvent.physicalKey] keeps the `kVK_*` code itself.
///
/// ## Modifiers say what was held, not what it usually means
///
/// Command is [KeyModifier.meta] and Control is [KeyModifier.control], as on
/// the web backend. Reporting Command as Control would make Cmd+C reach a
/// widget that only knows Ctrl+C, and would also make the real Control key -
/// which a Mac text field uses for Emacs-style movement - indistinguishable
/// from it. Mapping the platform's shortcut modifier is the widgets' job.
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:io' show Platform;

import '../../ffi/native_memory.dart';
import '../../geometry/offset.dart';
import '../../platform/input_events.dart';
import '../../platform/window_events.dart';
import 'host_protocol.dart';

// NSEventModifierFlags (AppKit/NSEvent.h).
const int _nsCapsLock = 1 << 16;
const int _nsShift = 1 << 17;
const int _nsControl = 1 << 18;
const int _nsOption = 1 << 19;
const int _nsCommand = 1 << 20;

/// The modifiers [modifierFlags] (`NSEvent.modifierFlags`) says were held.
Set<KeyModifier> macosKeyModifiers(int modifierFlags) => <KeyModifier>{
      if (modifierFlags & _nsShift != 0) KeyModifier.shift,
      if (modifierFlags & _nsControl != 0) KeyModifier.control,
      if (modifierFlags & _nsOption != 0) KeyModifier.alt,
      if (modifierFlags & _nsCommand != 0) KeyModifier.meta,
      if (modifierFlags & _nsCapsLock != 0) KeyModifier.capsLock,
    };

/// `NSEvent.buttonNumber` as a [PointerButton], or null for one this
/// framework does not name.
PointerButton? macosPointerButton(int buttonNumber) => switch (buttonNumber) {
      0 => PointerButton.primary,
      1 => PointerButton.secondary,
      2 => PointerButton.middle,
      3 => PointerButton.back,
      4 => PointerButton.forward,
      _ => null,
    };

/// The Windows virtual-key code for a macOS key. See the library comment.
///
/// [keyCode] is the `kVK_*` hardware code; [keyChar] is the first code point
/// of `charactersIgnoringModifiers`, or 0. Returns 0 for a key with no VK.
int macosLogicalKey(int keyCode, int keyChar) {
  final int? positional = _positionalKeys[keyCode];
  if (positional != null) return positional;
  if (keyChar >= 0x61 && keyChar <= 0x7A) return keyChar - 0x20; // a-z
  if (keyChar >= 0x41 && keyChar <= 0x5A) return keyChar; // A-Z
  if (keyChar >= 0x30 && keyChar <= 0x39) return keyChar; // 0-9
  final int? punctuation = _punctuationKeys[keyChar];
  if (punctuation != null) return punctuation;
  return _ansiPositions[keyCode] ?? 0;
}

/// Which copy of a duplicated key [keyCode] is.
KeyLocation macosKeyLocation(int keyCode) {
  if (_rightKeys.contains(keyCode)) return KeyLocation.right;
  if (_leftKeys.contains(keyCode)) return KeyLocation.left;
  if (_keypadKeys.contains(keyCode)) return KeyLocation.numpad;
  return KeyLocation.standard;
}

/// The text a `TEXT_INPUT=` line carries, or null when nothing in it is text.
///
/// Drops what AppKit puts in `NSEvent.characters` that is not content: the
/// C0/C1 controls (Return is `\r`, Delete is U+007F, Escape is U+001B), and
/// the private-use range U+F700-U+F8FF that AppKit uses for the arrow and
/// function keys (`NSUpArrowFunctionKey` is U+F700). Those keys still arrive
/// as [KeyEvent]s, which is where an editor handles them.
String? macosTextInput(String base64Text) {
  final String decoded;
  try {
    decoded = utf8.decode(base64.decode(base64Text));
  } on FormatException {
    return null;
  }
  final StringBuffer kept = StringBuffer();
  for (final int rune in decoded.runes) {
    if (rune < 0x20 || (rune >= 0x7F && rune <= 0x9F)) continue;
    if (rune >= 0xF700 && rune <= 0xF8FF) continue;
    kept.writeCharCode(rune);
  }
  return kept.isEmpty ? null : kept.toString();
}

/// Turns one host input record into framework events, through [emit].
///
/// Emits nothing for a kind it does not model (`other`) and for a mouse
/// button it cannot name, rather than guessing one.
void translateMacosInput(
  HostInputDetail detail, {
  required NativeWindowId windowId,
  required int generation,
  required void Function(PlatformWindowEvent event) emit,
}) {
  final Duration timestamp = macosMachTimeToDuration(detail.machTime);
  final Offset position = Offset(detail.x, detail.y);
  switch (detail.kind) {
    case HostInputKind.pointerDown || HostInputKind.pointerUp:
      final PointerButton? button = macosPointerButton(detail.button);
      if (button == null) return;
      emit(detail.kind == HostInputKind.pointerDown
          ? PointerDownEvent(
              windowId: windowId,
              generation: generation,
              timestamp: timestamp,
              pointerId: 0,
              kind: PointerKind.mouse,
              logicalPosition: position,
              button: button,
              clickCount: detail.clickCount < 1 ? 1 : detail.clickCount,
            )
          : PointerUpEvent(
              windowId: windowId,
              generation: generation,
              timestamp: timestamp,
              pointerId: 0,
              kind: PointerKind.mouse,
              logicalPosition: position,
              button: button,
            ));
    case HostInputKind.pointerMove:
      emit(PointerMoveEvent(
        windowId: windowId,
        generation: generation,
        timestamp: timestamp,
        pointerId: 0,
        kind: PointerKind.mouse,
        logicalPosition: position,
      ));
    case HostInputKind.scroll:
      if (detail.deltaX == 0 && detail.deltaY == 0) return;
      // AppKit's sign is the content's direction - a positive deltaY moves
      // the content down, which is scrolling *up* - and the framework's is
      // the offset's. Natural scrolling is already folded into AppKit's sign,
      // so negating is right whichever way the user set it.
      emit(PointerScrollEvent(
        windowId: windowId,
        generation: generation,
        timestamp: timestamp,
        pointerId: 0,
        kind: PointerKind.mouse,
        logicalPosition: position,
        scrollDelta: Offset(-detail.deltaX, -detail.deltaY),
        scrollDeltaUnit: detail.hasPreciseScrollingDeltas
            ? ScrollDeltaUnit.pixels
            : ScrollDeltaUnit.lines,
      ));
    case HostInputKind.keyDown || HostInputKind.keyUp:
      final int logicalKey = macosLogicalKey(detail.keyCode, detail.keyChar);
      final Set<KeyModifier> modifiers =
          macosKeyModifiers(detail.modifierFlags);
      final KeyLocation location = macosKeyLocation(detail.keyCode);
      emit(detail.kind == HostInputKind.keyDown
          ? KeyDownEvent(
              windowId: windowId,
              generation: generation,
              timestamp: timestamp,
              physicalKey: detail.keyCode,
              logicalKey: logicalKey,
              modifiers: modifiers,
              isRepeat: detail.isRepeat,
              location: location,
            )
          : KeyUpEvent(
              windowId: windowId,
              generation: generation,
              timestamp: timestamp,
              physicalKey: detail.keyCode,
              logicalKey: logicalKey,
              modifiers: modifiers,
              location: location,
            ));
    case HostInputKind.other:
      return;
  }
}

/// `mach_absolute_time` ticks as a [Duration].
///
/// The ratio is read with `mach_timebase_info` rather than assumed: it is
/// 1/1 on some Macs and 125/3 on others, and documented as machine-dependent.
/// Off macOS - a unit test on the Linux leg - the ticks are taken as
/// nanoseconds, which is all a timestamp there can mean.
Duration macosMachTimeToDuration(int ticks) =>
    Duration(microseconds: ticks * _timebase.$1 ~/ _timebase.$2 ~/ 1000);

final (int, int) _timebase = () {
  if (!Platform.isMacOS) return (1, 1);
  final Pointer<Uint32> info = NativeAllocator.instance.allocate<Uint32>(8);
  try {
    final int status = DynamicLibrary.process().lookupFunction<
        Int32 Function(Pointer<Uint32>),
        int Function(Pointer<Uint32>)>('mach_timebase_info')(info);
    if (status != 0 || info[1] == 0) return (1, 1);
    return (info[0], info[1]);
  } on Object {
    return (1, 1);
  } finally {
    NativeAllocator.instance.free(info);
  }
}();

/// Keys whose VK does not depend on the layout, by `kVK_*` code.
const Map<int, int> _positionalKeys = <int, int>{
  0x24: 0x0D, // Return
  0x30: 0x09, // Tab
  0x31: 0x20, // Space
  0x33: 0x08, // Delete (Backspace)
  0x35: 0x1B, // Escape
  0x37: 0x5B, // Command -> VK_LWIN
  0x36: 0x5C, // Right Command -> VK_RWIN
  0x38: 0x10, // Shift
  0x3C: 0x10, // Right Shift
  0x39: 0x14, // Caps Lock
  0x3A: 0x12, // Option -> VK_MENU
  0x3D: 0x12, // Right Option
  0x3B: 0x11, // Control
  0x3E: 0x11, // Right Control
  0x72: 0x2D, // Help, where Insert is on a PC keyboard
  0x73: 0x24, // Home
  0x74: 0x21, // Page Up
  0x75: 0x2E, // Forward Delete
  0x77: 0x23, // End
  0x79: 0x22, // Page Down
  0x7B: 0x25, // Left
  0x7C: 0x27, // Right
  0x7D: 0x28, // Down
  0x7E: 0x26, // Up
  0x7A: 0x70, // F1
  0x78: 0x71, // F2
  0x63: 0x72, // F3
  0x76: 0x73, // F4
  0x60: 0x74, // F5
  0x61: 0x75, // F6
  0x62: 0x76, // F7
  0x64: 0x77, // F8
  0x65: 0x78, // F9
  0x6D: 0x79, // F10
  0x67: 0x7A, // F11
  0x6F: 0x7B, // F12
  0x69: 0x7C, // F13
  0x6B: 0x7D, // F14
  0x71: 0x7E, // F15
  0x6A: 0x7F, // F16
  0x40: 0x80, // F17
  0x4F: 0x81, // F18
  0x50: 0x82, // F19
  0x5A: 0x83, // F20
  0x4A: 0xAD, // Mute
  0x49: 0xAE, // Volume Down
  0x48: 0xAF, // Volume Up
  0x52: 0x60, // Keypad 0
  0x53: 0x61, // Keypad 1
  0x54: 0x62, // Keypad 2
  0x55: 0x63, // Keypad 3
  0x56: 0x64, // Keypad 4
  0x57: 0x65, // Keypad 5
  0x58: 0x66, // Keypad 6
  0x59: 0x67, // Keypad 7
  0x5B: 0x68, // Keypad 8
  0x5C: 0x69, // Keypad 9
  0x41: 0x6E, // Keypad .
  0x43: 0x6A, // Keypad *
  0x45: 0x6B, // Keypad +
  0x4E: 0x6D, // Keypad -
  0x4B: 0x6F, // Keypad /
  0x4C: 0x0D, // Keypad Enter
  0x47: 0x0C, // Keypad Clear, where Num Lock is on a PC keyboard
  0x51: 0xBB, // Keypad =
};

/// The OEM VKs of a US layout, by the character the layout produced.
const Map<int, int> _punctuationKeys = <int, int>{
  0x3B: 0xBA, // ;
  0x3D: 0xBB, // =
  0x2C: 0xBC, // ,
  0x2D: 0xBD, // -
  0x2E: 0xBE, // .
  0x2F: 0xBF, // /
  0x60: 0xC0, // `
  0x5B: 0xDB, // [
  0x5C: 0xDC, // backslash
  0x5D: 0xDD, // ]
  0x27: 0xDE, // '
};

/// The VK of the US key in each ANSI position, for a layout character that
/// has no VK of its own.
const Map<int, int> _ansiPositions = <int, int>{
  0x00: 0x41, 0x0B: 0x42, 0x08: 0x43, 0x02: 0x44, 0x0E: 0x45, 0x03: 0x46, //
  0x05: 0x47, 0x04: 0x48, 0x22: 0x49, 0x26: 0x4A, 0x28: 0x4B, 0x25: 0x4C, //
  0x2E: 0x4D, 0x2D: 0x4E, 0x1F: 0x4F, 0x23: 0x50, 0x0C: 0x51, 0x0F: 0x52, //
  0x01: 0x53, 0x11: 0x54, 0x20: 0x55, 0x09: 0x56, 0x0D: 0x57, 0x07: 0x58, //
  0x10: 0x59, 0x06: 0x5A, //
  0x1D: 0x30, 0x12: 0x31, 0x13: 0x32, 0x14: 0x33, 0x15: 0x34, 0x17: 0x35, //
  0x16: 0x36, 0x1A: 0x37, 0x1C: 0x38, 0x19: 0x39, //
  0x29: 0xBA, 0x18: 0xBB, 0x2B: 0xBC, 0x1B: 0xBD, 0x2F: 0xBE, 0x2C: 0xBF, //
  0x32: 0xC0, 0x21: 0xDB, 0x2A: 0xDC, 0x1E: 0xDD, 0x27: 0xDE, //
  0x0A: 0xE2, // the ISO key between left Shift and Z
};

const Set<int> _leftKeys = <int>{0x37, 0x38, 0x3A, 0x3B};
const Set<int> _rightKeys = <int>{0x36, 0x3C, 0x3D, 0x3E};
const Set<int> _keypadKeys = <int>{
  0x52, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5B, 0x5C, //
  0x41, 0x43, 0x45, 0x4E, 0x4B, 0x4C, 0x47, 0x51,
};
