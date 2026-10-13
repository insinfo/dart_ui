/// Reading an `NSEvent` into the [MacosRawEvent] that
/// `macos_event_translation.dart` turns into framework events.
///
/// Shared by the two backends that receive `NSEvent`s in this process: the
/// AppKit signal hijack (`appkit_signal/`), which dequeues them from another
/// thread, and the embedded runtime (`embedded/`), whose views receive them
/// on the main thread. Moved out of `appkit_signal_window.dart` for the second.
library;

import 'dart:ffi';

import '../../ffi/objc_runtime.dart';
import 'macos_event_translation.dart';

final class _NSPoint extends Struct {
  @Double()
  external double x;
  @Double()
  external double y;
}

final DynamicLibrary _objc = DynamicLibrary.open('/usr/lib/libobjc.A.dylib');

// NSEvent getters with a struct or floating-point result: the strict shapes
// of objc_runtime.dart refuse aggregate returns, and these two are the only
// ones this file needs. A two-double struct and a double come back in
// floating-point registers on both arm64 and x86_64, through plain
// objc_msgSend.
final _NSPoint Function(Pointer<ObjCObject>, Pointer<ObjCSelector>) _sendPoint =
    _objc.lookupFunction<
        _NSPoint Function(Pointer<ObjCObject>, Pointer<ObjCSelector>),
        _NSPoint Function(
            Pointer<ObjCObject>, Pointer<ObjCSelector>)>('objc_msgSend');
final double Function(Pointer<ObjCObject>, Pointer<ObjCSelector>) _sendDouble =
    _objc.lookupFunction<
        Double Function(Pointer<ObjCObject>, Pointer<ObjCSelector>),
        double Function(
            Pointer<ObjCObject>, Pointer<ObjCSelector>)>('objc_msgSend');

/// The characters each key last typed, by key code, for its key-up.
final Map<int, String> _typedByKey = <int, String>{};

/// Reads the fields of an `NSEvent` the translation needs. Getters only, on
/// the calling thread: an event is a value by the time it is dequeued.
///
/// Except `characters`, which [characters] fetches: it consults the keyboard
/// input source for dead keys, and HIToolbox asserts that happens on the main
/// queue - called from the Dart thread it aborts the process.
MacosRawEvent decodeNSEvent(
  Pointer<ObjCObject> event,
  int type, {
  required Pointer<ObjCObject> Function(Pointer<ObjCObject> event) characters,
}) {
  int unsigned(String selector) =>
      objcSendUnsigned(event, objcSelector(selector));
  final bool key = type == 10 || type == 11;
  final bool scroll = type == 22;
  final _NSPoint location = _sendPoint(event, objcSelector('locationInWindow'));
  final double deltaX =
      scroll ? _sendDouble(event, objcSelector('scrollingDeltaX')) : 0;
  final double deltaY =
      scroll ? _sendDouble(event, objcSelector('scrollingDeltaY')) : 0;
  final bool precise = scroll &&
      (objcSendUnsigned(event, objcSelector('hasPreciseScrollingDeltas')) &
              0xFF) !=
          0;
  String typed = '';
  // keyUp reuses what its keyDown typed: `characters` on a key-up that
  // carries none - a synthesized one does not - raises inside AppKit.
  if (type == 11) typed = _typedByKey[unsigned('keyCode') & 0xFFFF] ?? '';
  if (type == 10) {
    final Pointer<ObjCObject> text = characters(event);
    if (text != nullptr) {
      final Pointer<ObjCObject> utf8 =
          objcSendPointer(text, objcSelector('UTF8String'));
      if (utf8 != nullptr) typed = objcReadCString(utf8.cast());
    }
  }
  if (type == 10) _typedByKey[unsigned('keyCode') & 0xFFFF] = typed;
  return MacosRawEvent(
    type: type,
    screenX: location.x,
    screenY: location.y,
    windowUnderPointer: unsigned('windowNumber'),
    flags: unsigned('modifierFlags'),
    timestampNanos:
        (_sendDouble(event, objcSelector('timestamp')) * 1e9).round(),
    keyCode: key || type == 12 ? unsigned('keyCode') & 0xFFFF : 0,
    characters: typed,
    clickCount: key || scroll || type == 12 ? 0 : unsigned('clickCount'),
    buttonNumber: key || scroll || type == 12 ? 0 : unsigned('buttonNumber'),
    scrollPointsX: deltaX,
    scrollPointsY: deltaY,
    // A wheel without precise deltas reports lines in the same getters.
    scrollLinesX: deltaX,
    scrollLinesY: deltaY,
    continuousScroll: precise,
  );
}
