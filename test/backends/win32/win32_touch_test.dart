/// Fingers and pens on a real HWND, through `WM_POINTER*`.
///
/// Two layers. The messages are first handed to the window procedure
/// directly, which pins the translation - a pointer id `GetPointerType` has
/// never heard of is what an injected test message is, and the window must
/// still read it as a finger. Then a real touch goes in through
/// `InjectTouchInput`, which needs no touchscreen: Windows routes it through
/// the same input stack a digitizer uses, so it proves that answering
/// `WM_POINTERDOWN` really does stop the duplicate mouse click.
library;

import 'dart:async';
import 'dart:ffi';
import 'dart:io' show Platform;

import 'package:dart_ui/src/backends/win32/win32_api.dart';
import 'package:dart_ui/src/backends/win32/win32_backend.dart';
import 'package:dart_ui/src/backends/win32/win32_constants.dart';
import 'package:dart_ui/src/backends/win32/win32_window.dart';
import 'package:dart_ui/src/geometry/size.dart';
import 'package:dart_ui/src/platform/input_events.dart';
import 'package:dart_ui/src/platform/native_window.dart';
import 'package:dart_ui/src/platform/window_events.dart';
import 'package:test/test.dart';

const int _pointerFlagInRange = 0x00000002;
const int _pointerFlagInContact = 0x00000004;
const int _pointerFlagDown = 0x00010000;
const int _pointerFlagUpdate = 0x00020000;
const int _pointerFlagUp = 0x00040000;
const int _touchFeedbackNone = 3;

/// `POINTER_TOUCH_INFO` on x64: a 96-byte `POINTER_INFO`, then the touch
/// fields. Only the offsets written below matter; the rest stays zero.
const int _touchInfoSize = 144;

void main() {
  group('touch on a real Win32 window', () {
    late Win32WindowingBackend backend;
    late Win32Window window;
    late List<PointerEvent> events;
    late StreamSubscription<PlatformWindowEvent> subscription;
    final DynamicLibrary user32 =
        Platform.isWindows ? DynamicLibrary.open('user32.dll') : _none();
    // The backend's own process-heap allocator: no package:ffi dependency.
    final Allocator allocator =
        Platform.isWindows ? Win32Api.load().api!.allocator : _NoAllocator();

    /// The client point (x, y) in physical screen pixels.
    (int, int) screenPoint(int x, int y) {
      final clientToScreen = user32.lookupFunction<
          Int32 Function(IntPtr, Pointer<Int32>),
          int Function(int, Pointer<Int32>)>('ClientToScreen');
      final Pointer<Int32> point = allocator<Int32>(2);
      try {
        point[0] = x;
        point[1] = y;
        clientToScreen(window.handle, point);
        return (point[0], point[1]);
      } finally {
        allocator.free(point);
      }
    }

    int lParamAt(int x, int y) {
      final (int sx, int sy) = screenPoint(x, y);
      return ((sy & 0xFFFF) << 16) | (sx & 0xFFFF);
    }

    setUp(() async {
      backend = Win32WindowingBackend();
      await backend.initialize();
      window = await backend.createWindow(const WindowOptions(
        title: 'touch',
        size: Size(320, 240),
      )) as Win32Window;
      events = <PointerEvent>[];
      subscription = window.events.listen((PlatformWindowEvent event) {
        if (event is PointerEvent) events.add(event);
      });
    });

    tearDown(() async {
      await subscription.cancel();
      window.close();
      await backend.shutdown();
    });

    test('a finger is a touch pointer that is never the mouse', () async {
      const int pointer = 77;
      window
        ..handleMessage(window.handle, wmPointerdown, pointer, lParamAt(40, 50))
        ..handleMessage(
            window.handle, wmPointerupdate, pointer, lParamAt(60, 70))
        ..handleMessage(window.handle, wmPointerup, pointer, lParamAt(60, 70));
      await Future<void>.delayed(Duration.zero);

      expect(events.map((PointerEvent e) => e.runtimeType), <Type>[
        PointerDownEvent,
        PointerMoveEvent,
        PointerUpEvent,
      ]);
      for (final PointerEvent event in events) {
        expect(event.kind, PointerKind.touch);
        expect(event.pointerId, Win32Window.contactPointerId(pointer));
        expect(event.pointerId, isNot(0));
      }
      expect(events.first.logicalPosition.dx, closeTo(40, 1));
      expect(events.last.logicalPosition.dy, closeTo(70, 1));
    });

    test('a cancelled contact and a lost capture end in a cancel', () async {
      window
        ..handleMessage(window.handle, wmPointerdown, 5, lParamAt(10, 10))
        ..handleMessage(window.handle, wmPointerup,
            5 | (pointerMessageFlagCanceled << 16), lParamAt(10, 10))
        ..handleMessage(window.handle, wmPointerdown, 6, lParamAt(20, 20))
        ..handleMessage(window.handle, wmPointercapturechanged, 6, 0)
        // Already ended: nothing more.
        ..handleMessage(window.handle, wmPointerup, 6, lParamAt(20, 20));
      await Future<void>.delayed(Duration.zero);

      expect(events.map((PointerEvent e) => e.runtimeType), <Type>[
        PointerDownEvent,
        PointerCancelEvent,
        PointerDownEvent,
        PointerCancelEvent,
      ]);
    });

    test('an injected touch arrives once, as a touch and not as a click',
        () async {
      final initialize = user32.lookupFunction<Int32 Function(Uint32, Uint32),
          int Function(int, int)>('InitializeTouchInjection');
      final inject = user32.lookupFunction<Int32 Function(Uint32, Pointer),
          int Function(int, Pointer)>('InjectTouchInput');
      final setForeground =
          user32.lookupFunction<Int32 Function(IntPtr), int Function(int)>(
              'SetForegroundWindow');
      if (initialize(1, _touchFeedbackNone) == 0) {
        print('WIN32_TOUCH_INJECTION=SKIP initialize refused');
        markTestSkipped('InitializeTouchInjection refused in this session');
        return;
      }
      setForeground(window.handle);
      await _pump(backend, const Duration(milliseconds: 200));
      events.clear();

      final Pointer<Uint8> info = allocator<Uint8>(_touchInfoSize);
      try {
        final ByteDataView view = ByteDataView(info, _touchInfoSize);
        bool send(int flags, int x, int y) {
          final (int sx, int sy) = screenPoint(x, y);
          view
            ..setUint32(0, 2) // PT_TOUCH
            ..setUint32(4, 0) // pointerId
            ..setUint32(12, flags)
            ..setInt32(32, sx) // ptPixelLocation
            ..setInt32(36, sy);
          return inject(1, info) != 0;
        }

        final bool sent = send(
                _pointerFlagDown | _pointerFlagInRange | _pointerFlagInContact,
                100,
                100) &&
            send(
                _pointerFlagUpdate |
                    _pointerFlagInRange |
                    _pointerFlagInContact,
                110,
                105) &&
            send(_pointerFlagUp, 110, 105);
        if (!sent) {
          print('WIN32_TOUCH_INJECTION=SKIP inject refused');
          markTestSkipped('InjectTouchInput refused in this session');
          return;
        }
      } finally {
        allocator.free(info);
      }
      await _pump(backend, const Duration(milliseconds: 500));

      // A hosted runner's cursor drifts over the window and posts mouse
      // moves of its own; they say nothing about the touch. What does is a
      // touch-kind event, or a press or release of any kind - a click the
      // system synthesized from the touch is exactly what must not appear.
      final List<PointerEvent> contact = <PointerEvent>[
        for (final PointerEvent e in events)
          if (e.kind == PointerKind.touch ||
              e is PointerDownEvent ||
              e is PointerUpEvent)
            e,
      ];
      // Evidence for the CI log: what a real injected contact turned into.
      final String seen = events
          .map((PointerEvent e) => '${e.runtimeType}/${e.kind.name}')
          .join(',');
      if (contact.isEmpty) {
        print('WIN32_TOUCH_INJECTION=SKIP no contact reached the window: '
            '$seen');
        markTestSkipped('no injected contact reached the window');
        return;
      }
      print('WIN32_TOUCH_INJECTION=RAN $seen');
      expect(contact.whereType<PointerDownEvent>(), hasLength(1),
          reason: 'one press: the touch, not also a synthesized click');
      expect(contact.every((PointerEvent e) => e.kind == PointerKind.touch),
          isTrue,
          reason: seen);
      expect(contact.whereType<PointerUpEvent>(), hasLength(1));
    });
  }, skip: Platform.isWindows ? false : 'needs a real Win32 window');
}

DynamicLibrary _none() => DynamicLibrary.process();

/// Never called: the group is skipped off Windows.
final class _NoAllocator implements Allocator {
  @override
  Pointer<T> allocate<T extends NativeType>(int byteCount, {int? alignment}) =>
      throw UnsupportedError('no Win32 heap here');

  @override
  void free(Pointer<NativeType> pointer) {}
}

Future<void> _pump(Win32WindowingBackend backend, Duration duration) async {
  final DateTime deadline = DateTime.now().add(duration);
  while (DateTime.now().isBefore(deadline)) {
    backend.pumpEvents(timeout: const Duration(milliseconds: 10));
    await Future<void>.delayed(Duration.zero);
  }
}

/// A little-endian view over native memory, for the one struct written here.
final class ByteDataView {
  ByteDataView(this._bytes, this._length);

  final Pointer<Uint8> _bytes;
  final int _length;

  void setUint32(int offset, int value) {
    assert(offset + 4 <= _length);
    (_bytes + offset).cast<Uint32>().value = value;
  }

  void setInt32(int offset, int value) {
    assert(offset + 4 <= _length);
    (_bytes + offset).cast<Int32>().value = value;
  }
}
