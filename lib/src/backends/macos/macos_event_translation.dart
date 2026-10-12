/// Translation of WindowServer and AppKit events into framework events.
library;

import '../../geometry/offset.dart';
import '../../platform/input_events.dart';
import '../../platform/window_events.dart';
import 'macos_input.dart';

/// One CGEvent or NSEvent, decoded enough to route and translate.
///
/// The two share their type numbers - `NSEventType` is `CGEventType` for
/// everything here - so SkyLight and AppKit both fill this and one function
/// turns it into framework events.
final class MacosRawEvent {
  MacosRawEvent({
    required this.type,
    required this.screenX,
    required this.screenY,
    required this.windowUnderPointer,
    required this.flags,
    required this.timestampNanos,
    this.keyCode = 0,
    this.characters = '',
    this.clickCount = 0,
    this.buttonNumber = 0,
    this.scrollLinesX = 0,
    this.scrollLinesY = 0,
    this.scrollPointsX = 0,
    this.scrollPointsY = 0,
    this.continuousScroll = false,
  });

  /// `CGEventType`: 1/2 left down/up, 3/4 right down/up, 5 moved, 6/7/27
  /// dragged, 10/11 key down/up, 12 flags changed, 22 scroll, 25/26 other
  /// down/up.
  final int type;

  /// Global position in points, origin at the top left of the main display.
  final double screenX;
  final double screenY;

  /// The SkyLight window id under the pointer, 0 for keyboard events.
  final int windowUnderPointer;

  /// `CGEventFlags`.
  final int flags;
  final int timestampNanos;
  final int keyCode;

  /// What the key types, from `CGEventKeyboardGetUnicodeString`.
  final String characters;
  final int clickCount;
  final int buttonNumber;
  final double scrollLinesX;
  final double scrollLinesY;
  final double scrollPointsX;
  final double scrollPointsY;
  final bool continuousScroll;
}

/// Turns [event] into framework events through [emit], with [local] the
/// event's position in the window's client area, top-left origin, in points.
void translateMacosRawEvent(
  MacosRawEvent event, {
  required Offset local,
  required NativeWindowId windowId,
  required int generation,
  required void Function(PlatformWindowEvent event) emit,
}) {
  final Duration timestamp =
      Duration(microseconds: event.timestampNanos ~/ 1000);
  void pointer(PointerEvent Function() build) => emit(build());
  switch (event.type) {
    case 1 || 3 || 25:
      final PointerButton? button = _button(event);
      if (button == null) return;
      pointer(() => PointerDownEvent(
            windowId: windowId,
            generation: generation,
            timestamp: timestamp,
            pointerId: 0,
            kind: PointerKind.mouse,
            logicalPosition: local,
            button: button,
            clickCount: event.clickCount < 1 ? 1 : event.clickCount,
          ));
    case 2 || 4 || 26:
      final PointerButton? button = _button(event);
      if (button == null) return;
      pointer(() => PointerUpEvent(
            windowId: windowId,
            generation: generation,
            timestamp: timestamp,
            pointerId: 0,
            kind: PointerKind.mouse,
            logicalPosition: local,
            button: button,
          ));
    case 5 || 6 || 7 || 27:
      pointer(() => PointerMoveEvent(
            windowId: windowId,
            generation: generation,
            timestamp: timestamp,
            pointerId: 0,
            kind: PointerKind.mouse,
            logicalPosition: local,
          ));
    case 22:
      final bool precise = event.continuousScroll;
      final double dx = precise ? event.scrollPointsX : event.scrollLinesX;
      final double dy = precise ? event.scrollPointsY : event.scrollLinesY;
      if (dx == 0 && dy == 0) return;
      // The WindowServer's sign is the content's direction; the
      // framework's is the offset's, as for AppKit's deltas.
      pointer(() => PointerScrollEvent(
            windowId: windowId,
            generation: generation,
            timestamp: timestamp,
            pointerId: 0,
            kind: PointerKind.mouse,
            logicalPosition: local,
            scrollDelta: Offset(-dx, -dy),
            scrollDeltaUnit:
                precise ? ScrollDeltaUnit.pixels : ScrollDeltaUnit.lines,
          ));
    case 10 || 11:
      _emitKey(event,
          down: event.type == 10,
          timestamp: timestamp,
          windowId: windowId,
          generation: generation,
          emit: emit);
    case 12:
      final bool? down = _modifierDown(event);
      if (down != null) {
        _emitKey(event,
            down: down,
            timestamp: timestamp,
            windowId: windowId,
            generation: generation,
            emit: emit);
      }
  }
}

PointerButton? _button(MacosRawEvent event) => switch (event.type) {
      1 || 2 => PointerButton.primary,
      3 || 4 => PointerButton.secondary,
      _ => macosPointerButton(event.buttonNumber),
    };

/// Whether a flags-changed event is its modifier going down or up, from
/// the flag that key controls; null for a key this cannot tell.
bool? _modifierDown(MacosRawEvent event) {
  final int? mask = switch (event.keyCode) {
    56 || 60 => 1 << 17, // shift
    59 || 62 => 1 << 18, // control
    58 || 61 => 1 << 19, // option
    55 || 54 => 1 << 20, // command
    57 => 1 << 16, // caps lock
    _ => null,
  };
  return mask == null ? null : (event.flags & mask) != 0;
}

void _emitKey(
  MacosRawEvent event, {
  required bool down,
  required Duration timestamp,
  required NativeWindowId windowId,
  required int generation,
  required void Function(PlatformWindowEvent event) emit,
}) {
  final String characters = event.characters;
  final int keyChar = characters.isEmpty ? 0 : characters.codeUnitAt(0);
  final int logicalKey = macosLogicalKey(event.keyCode, keyChar);
  final Set<KeyModifier> modifiers = macosKeyModifiers(event.flags);
  final KeyLocation location = macosKeyLocation(event.keyCode);
  emit(down
      ? KeyDownEvent(
          windowId: windowId,
          generation: generation,
          timestamp: timestamp,
          physicalKey: event.keyCode,
          logicalKey: logicalKey,
          modifiers: modifiers,
          location: location,
        )
      : KeyUpEvent(
          windowId: windowId,
          generation: generation,
          timestamp: timestamp,
          physicalKey: event.keyCode,
          logicalKey: logicalKey,
          modifiers: modifiers,
          location: location,
        ));
  if (!down) return;
  // Text, as macosTextInput filters it: no controls, no function keys,
  // and nothing typed while Command or Control turns it into a shortcut.
  if (modifiers.contains(KeyModifier.meta) ||
      modifiers.contains(KeyModifier.control)) {
    return;
  }
  final StringBuffer text = StringBuffer();
  for (final int rune in characters.runes) {
    if (rune < 0x20 || (rune >= 0x7F && rune <= 0x9F)) continue;
    if (rune >= 0xF700 && rune <= 0xF8FF) continue;
    text.writeCharCode(rune);
  }
  if (text.isEmpty) return;
  emit(TextInputEvent(
    windowId: windowId,
    generation: generation,
    timestamp: timestamp,
    text: text.toString(),
  ));
}
