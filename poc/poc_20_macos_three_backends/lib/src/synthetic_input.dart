import 'dart:ffi';

import 'package:ffi/ffi.dart';

import 'core_graphics_types.dart';
import 'mach_clock.dart';

/// Input injected the way real input arrives: through the WindowServer.
///
/// `CGEventPost` needs the HID tap, which the CI runner does not grant, and
/// nothing arrived when the earlier probes tried it. `SLEventPostToPid` hands
/// the event to a specific process's queue instead, so it works headlessly and
/// works for a *different* process - which is how backend 3 gets input while
/// the Dart side stays a worker.
class SyntheticInput {
  SyntheticInput()
      : _coreGraphics = DynamicLibrary.open(
            '/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics'),
        _skyLight = DynamicLibrary.open(
            '/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight'),
        _coreFoundation = DynamicLibrary.open(
            '/System/Library/Frameworks/CoreFoundation.framework/'
            'CoreFoundation');

  final DynamicLibrary _coreGraphics;
  final DynamicLibrary _skyLight;
  final DynamicLibrary _coreFoundation;

  late final _createKey = _coreGraphics.lookupFunction<
      Pointer<Void> Function(Pointer<Void>, Uint16, Bool),
      Pointer<Void> Function(
          Pointer<Void>, int, bool)>('CGEventCreateKeyboardEvent');
  late final _createMouse = _coreGraphics.lookupFunction<
      Pointer<Void> Function(Pointer<Void>, Uint32, CGPointNative, Uint32),
      Pointer<Void> Function(
          Pointer<Void>, int, CGPointNative, int)>('CGEventCreateMouseEvent');
  late final _postToPid = _skyLight.lookupFunction<
      Void Function(Int32, Pointer<Void>),
      void Function(int, Pointer<Void>)>('SLEventPostToPid');
  late final _release = _coreFoundation.lookupFunction<
      Void Function(Pointer<Void>), void Function(Pointer<Void>)>('CFRelease');

  /// One key event, with the mach tick at which it was handed to the
  /// WindowServer. The host stamps the same clock when it dequeues, so the two
  /// halves of the trip can be told apart.
  ({bool posted, int ticks}) postKeyStamped(int pid,
      {int keyCode = 0, bool down = true}) {
    final event = _createKey(nullptr, keyCode, down);
    if (event == nullptr) return (posted: false, ticks: 0);
    final ticks = machNow();
    _postToPid(pid, event);
    _release(event);
    return (posted: true, ticks: ticks);
  }

  /// One key down/up pair plus one pointer move, delivered to [pid].
  bool postTo(int pid, {int keyCode = 0, double x = 400, double y = 400}) {
    final down = _createKey(nullptr, keyCode, true);
    final up = _createKey(nullptr, keyCode, false);
    if (down == nullptr) {
      if (up != nullptr) _release(up);
      return false;
    }
    _postToPid(pid, down);
    if (up != nullptr) _postToPid(pid, up);
    _release(down);
    if (up != nullptr) _release(up);

    final point = calloc<CGPointNative>()
      ..ref.x = x
      ..ref.y = y;
    // 5 == kCGEventMouseMoved.
    final move = _createMouse(nullptr, 5, point.ref, 0);
    calloc.free(point);
    if (move != nullptr) {
      _postToPid(pid, move);
      _release(move);
    }
    return true;
  }
}
