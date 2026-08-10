import 'dart:ffi';
import 'dart:io';

import 'package:dart_ui/src/backends/x11/x11_events.dart';
import 'package:dart_ui/src/backends/x11/x11_libc.dart';
import 'package:dart_ui/src/backends/x11/x11_protocol.dart';
import 'package:dart_ui/src/geometry/offset.dart';
import 'package:dart_ui/src/geometry/rect.dart';
import 'package:dart_ui/src/geometry/size.dart';
import 'package:dart_ui/src/platform/window_events.dart';
import 'package:test/test.dart';

typedef _MallocNative = Pointer<Void> Function(IntPtr);
typedef _MallocDart = Pointer<Void> Function(int);
typedef _FreeNative = Void Function(Pointer<Void>);
typedef _FreeDart = void Function(Pointer<Void>);

final DynamicLibrary _cRuntime = Platform.isWindows
    ? DynamicLibrary.open('ucrtbase.dll')
    : Platform.isMacOS
        ? DynamicLibrary.open('/usr/lib/libSystem.B.dylib')
        : DynamicLibrary.open('libc.so.6');
final _MallocDart _malloc =
    _cRuntime.lookupFunction<_MallocNative, _MallocDart>('malloc');
final _FreeDart _free =
    _cRuntime.lookupFunction<_FreeNative, _FreeDart>('free');

void _withNativeEvent(void Function(Pointer<Uint8> event) body) {
  final allocation = _malloc(32);
  if (allocation == nullptr) {
    throw StateError('malloc failed while preparing an X11 test event');
  }
  final event = allocation.cast<Uint8>();
  for (var index = 0; index < 32; index++) {
    event[index] = 0;
  }
  try {
    body(event);
  } finally {
    _free(allocation);
  }
}

X11WindowProtocolState _windowState({
  int window = 0x11223344,
  int root = 0x01020304,
}) {
  return X11WindowProtocolState(
    xcbWindow: window,
    rootWindow: root,
    wmProtocols: 101,
    wmDeleteWindow: 102,
    netWmState: 103,
    wmState: 104,
  );
}

X11RawEvent _raw({
  required int type,
  int window = 0x11223344,
  bool synthetic = false,
  int detail = 0,
  int x = 0,
  int y = 0,
  int width = 0,
  int height = 0,
  int mode = 0,
  int atom = 0,
  int data0 = 0,
}) {
  return X11RawEvent()
    ..type = type
    ..window = window
    ..synthetic = synthetic
    ..detail = detail
    ..x = x
    ..y = y
    ..width = width
    ..height = height
    ..mode = mode
    ..atom = atom
    ..data0 = data0;
}

void main() {
  group('X11RawEvent.decodeFrom', () {
    test('decodes an Expose including signed coordinates and send-event flag',
        () {
      _withNativeEvent((event) {
        event[0] = xcbExpose | xcbSendEventFlag;
        event[1] = 7;
        writeU16(event, 2, 0xabcd);
        writeU32(event, 4, 0x11223344);
        writeU16(event, 8, -12);
        writeU16(event, 10, -3);
        writeU16(event, 12, 640);
        writeU16(event, 14, 480);
        writeU16(event, 16, 2);

        final raw = X11RawEvent()..decodeFrom(event);

        expect(raw.type, xcbExpose);
        expect(raw.synthetic, isTrue);
        expect(raw.detail, 7);
        expect(raw.sequence, 0xabcd);
        expect(raw.window, 0x11223344);
        expect(raw.x, -12);
        expect(raw.y, -3);
        expect(raw.width, 640);
        expect(raw.height, 480);
        expect(raw.count, 2);
      });
    });

    test('ConfigureNotify uses the window field and signed client origin', () {
      _withNativeEvent((event) {
        event[0] = xcbConfigureNotify;
        writeU32(event, 4, 0xaaaaaaaa); // The event recipient, not the client.
        writeU32(event, 8, 0xbbbbbbbb);
        writeU16(event, 16, -320);
        writeU16(event, 18, 27);
        writeU16(event, 20, 1280);
        writeU16(event, 22, 720);

        final raw = X11RawEvent()..decodeFrom(event);

        expect(raw.window, 0xbbbbbbbb);
        expect(raw.x, -320);
        expect(raw.y, 27);
        expect(raw.width, 1280);
        expect(raw.height, 720);
      });
    });

    test('decodes focus, property, client-message and input field layouts', () {
      final raw = X11RawEvent();

      _withNativeEvent((event) {
        event[0] = xcbFocusIn;
        event[1] = xcbNotifyDetailPointerRoot;
        writeU32(event, 4, 11);
        event[8] = xcbNotifyModeUngrab;
        raw.decodeFrom(event);
      });
      expect(raw.window, 11);
      expect(raw.detail, xcbNotifyDetailPointerRoot);
      expect(raw.mode, xcbNotifyModeUngrab);

      _withNativeEvent((event) {
        event[0] = xcbPropertyNotify;
        writeU32(event, 4, 12);
        writeU32(event, 8, 99);
        event[16] = 1;
        raw.decodeFrom(event);
      });
      expect(raw.window, 12);
      expect(raw.atom, 99);
      expect(raw.mode, 1);

      _withNativeEvent((event) {
        event[0] = xcbClientMessage;
        event[1] = 32;
        writeU32(event, 4, 13);
        writeU32(event, 8, 101);
        writeU32(event, 12, 102);
        raw.decodeFrom(event);
      });
      expect(raw.window, 13);
      expect(raw.detail, 32);
      expect(raw.atom, 101);
      expect(raw.data0, 102);

      _withNativeEvent((event) {
        event[0] = xcbMotionNotify;
        writeU32(event, 4, 0xdeadbeef);
        writeU32(event, 12, 14);
        raw.decodeFrom(event);
      });
      expect(raw.window, 14);
    });

    test('decodes errors and describes the failed request', () {
      _withNativeEvent((event) {
        event[0] = xcbError;
        event[1] = 8; // BadMatch.
        writeU16(event, 2, 77);
        writeU32(event, 4, 0xcafebabe);
        writeU16(event, 8, 5);
        event[10] = 1; // CreateWindow.

        final raw = X11RawEvent()..decodeFrom(event);

        expect(raw.window, 0xcafebabe);
        expect(raw.resourceId, 0xcafebabe);
        expect(raw.errorCode, 8);
        expect(raw.minorOpcode, 5);
        expect(raw.majorOpcode, 1);
        expect(
          raw.describeError(),
          'BadMatch from CreateWindow '
          '(resource 0xcafebabe, sequence 77, minor 5)',
        );
      });
    });

    test('clears fields that are absent from the next decoded event', () {
      final raw = X11RawEvent();
      _withNativeEvent((event) {
        event[0] = xcbClientMessage;
        event[1] = 32;
        writeU32(event, 4, 91);
        writeU32(event, 8, 92);
        writeU32(event, 12, 93);
        raw.decodeFrom(event);
      });
      expect(raw.atom, 92);
      expect(raw.data0, 93);

      _withNativeEvent((event) {
        event[0] = xcbExpose;
        writeU32(event, 4, 94);
        writeU16(event, 12, 10);
        writeU16(event, 14, 20);
        raw.decodeFrom(event);
      });

      expect(raw.window, 94);
      expect(raw.atom, 0);
      expect(raw.data0, 0);
      expect(raw.mode, 0);
      expect(raw.errorCode, 0);
      expect(raw.resourceId, 0);
    });
  });

  group('X11EventTranslator', () {
    test('coalesces configure events into the final geometry', () {
      final state = _windowState();
      final pending = X11PendingWindowEvents();

      expect(
        X11EventTranslator.apply(
          _raw(
            type: xcbConfigureNotify,
            x: 4,
            y: 8,
            width: 640,
            height: 480,
          ),
          state,
          pending,
        ),
        isTrue,
      );
      X11EventTranslator.apply(
        _raw(
          type: xcbConfigureNotify,
          x: 12,
          y: 16,
          width: 800,
          height: 600,
        ),
        state,
        pending,
      );

      expect(pending.resized, isTrue);
      expect(pending.moved, isTrue);
      expect(state.width, 800);
      expect(state.height, 600);
      expect(state.originX, 12);
      expect(state.originY, 16);
    });

    test('defers a reparented origin but accepts a synthetic root origin', () {
      final state = _windowState();
      final pending = X11PendingWindowEvents();

      X11EventTranslator.apply(
        _raw(type: xcbReparentNotify),
        state,
        pending,
      );
      expect(state.reparented, isTrue);
      expect(pending.originDirty, isTrue);

      pending.reset();
      X11EventTranslator.apply(
        _raw(
          type: xcbConfigureNotify,
          x: 20,
          y: 30,
          width: 400,
          height: 300,
        ),
        state,
        pending,
      );
      expect(pending.originDirty, isTrue);
      expect(pending.moved, isFalse);

      pending.reset();
      X11EventTranslator.apply(
        _raw(
          type: xcbConfigureNotify,
          synthetic: true,
          x: -9,
          y: 31,
          width: 400,
          height: 300,
        ),
        state,
        pending,
      );
      expect(pending.originDirty, isFalse);
      expect(pending.moved, isTrue);
      expect(state.originX, -9);
      expect(state.originY, 31);
    });

    test('unions expose rectangles and ignores empty damage', () {
      final state = _windowState();
      final pending = X11PendingWindowEvents();

      X11EventTranslator.apply(
        _raw(type: xcbExpose, x: 10, y: 20, width: 30, height: 40),
        state,
        pending,
      );
      X11EventTranslator.apply(
        _raw(type: xcbExpose, x: -5, y: 25, width: 20, height: 60),
        state,
        pending,
      );
      X11EventTranslator.apply(
        _raw(type: xcbExpose, x: -100, y: -100, width: 0, height: 5),
        state,
        pending,
      );

      expect(pending.exposed, isTrue);
      expect(pending.exposeLeft, -5);
      expect(pending.exposeTop, 20);
      expect(pending.exposeRight, 40);
      expect(pending.exposeBottom, 85);
    });

    test('filters grab and pointer focus transitions', () {
      final state = _windowState();
      final pending = X11PendingWindowEvents();

      X11EventTranslator.apply(
        _raw(type: xcbFocusIn, mode: xcbNotifyModeGrab),
        state,
        pending,
      );
      X11EventTranslator.apply(
        _raw(type: xcbFocusIn, detail: xcbNotifyDetailPointer),
        state,
        pending,
      );
      expect(state.focused, isFalse);
      expect(pending.activationChanged, isFalse);

      X11EventTranslator.apply(
        _raw(type: xcbFocusIn, mode: xcbNotifyModeNormal),
        state,
        pending,
      );
      expect(state.focused, isTrue);
      expect(pending.activationChanged, isTrue);
      expect(pending.activated, isTrue);

      pending.reset();
      X11EventTranslator.apply(
        _raw(type: xcbFocusOut, mode: xcbNotifyModeNormal),
        state,
        pending,
      );
      expect(state.focused, isFalse);
      expect(pending.activationChanged, isTrue);
      expect(pending.activated, isFalse);
    });

    test('recognises only the exact WM_DELETE_WINDOW client message', () {
      final state = _windowState();
      final pending = X11PendingWindowEvents();

      for (final raw in <X11RawEvent>[
        _raw(
          type: xcbClientMessage,
          detail: 8,
          atom: state.wmProtocols,
          data0: state.wmDeleteWindow,
        ),
        _raw(
          type: xcbClientMessage,
          detail: 32,
          atom: state.wmProtocols + 1,
          data0: state.wmDeleteWindow,
        ),
        _raw(
          type: xcbClientMessage,
          detail: 32,
          atom: state.wmProtocols,
          data0: state.wmDeleteWindow + 1,
        ),
      ]) {
        X11EventTranslator.apply(raw, state, pending);
      }
      expect(pending.closeRequested, isFalse);

      X11EventTranslator.apply(
        _raw(
          type: xcbClientMessage,
          detail: 32,
          atom: state.wmProtocols,
          data0: state.wmDeleteWindow,
        ),
        state,
        pending,
      );
      expect(pending.closeRequested, isTrue);
    });

    test('routes root scale changes and rejects unrelated windows', () {
      final state = _windowState();
      final pending = X11PendingWindowEvents();

      expect(
        X11EventTranslator.apply(
          _raw(
            type: xcbPropertyNotify,
            window: state.rootWindow,
            atom: xcbAtomResourceManager,
          ),
          state,
          pending,
        ),
        isTrue,
      );
      expect(pending.scaleDirty, isTrue);

      expect(
        X11EventTranslator.apply(
          _raw(type: xcbExpose, window: state.xcbWindow + 1),
          state,
          pending,
        ),
        isFalse,
      );
      expect(
        X11EventTranslator.apply(
          _raw(
            type: xcbPropertyNotify,
            atom: state.netWmState,
          ),
          state,
          pending,
        ),
        isTrue,
      );
      expect(
        X11EventTranslator.apply(
          _raw(type: xcbPropertyNotify, atom: 0x9999),
          state,
          pending,
        ),
        isFalse,
      );
    });

    test('destroy cancels stale geometry and rejects every late event', () {
      final state = _windowState()..mapped = true;
      final pending = X11PendingWindowEvents()
        ..resized = true
        ..moved = true
        ..exposed = true
        ..originDirty = true;

      expect(
        X11EventTranslator.apply(
          _raw(type: xcbDestroyNotify),
          state,
          pending,
        ),
        isTrue,
      );
      expect(state.destroyed, isTrue);
      expect(state.mapped, isFalse);
      expect(pending.destroyed, isTrue);
      expect(pending.resized, isFalse);
      expect(pending.moved, isFalse);
      expect(pending.exposed, isFalse);
      expect(pending.originDirty, isFalse);

      expect(
        X11EventTranslator.apply(
          _raw(type: xcbExpose, width: 10, height: 10),
          state,
          pending,
        ),
        isFalse,
      );
      expect(pending.exposed, isFalse);
    });

    test('tracks map state and consumes deferred input without side effects',
        () {
      final state = _windowState();
      final pending = X11PendingWindowEvents();

      X11EventTranslator.apply(
        _raw(type: xcbMapNotify),
        state,
        pending,
      );
      expect(state.mapped, isTrue);
      X11EventTranslator.apply(
        _raw(type: xcbUnmapNotify),
        state,
        pending,
      );
      expect(state.mapped, isFalse);

      for (final type in <int>[
        xcbMotionNotify,
        xcbKeyPress,
        xcbKeyRelease,
        xcbButtonPress,
        xcbButtonRelease,
        xcbEnterNotify,
        xcbLeaveNotify,
      ]) {
        expect(
          X11EventTranslator.apply(
            _raw(type: type),
            state,
            pending,
          ),
          isTrue,
        );
      }
      expect(pending.isEmpty, isTrue);
    });

    test('reset returns the reusable pending record to an empty state', () {
      final pending = X11PendingWindowEvents()
        ..resized = true
        ..moved = true
        ..activationChanged = true
        ..activated = true
        ..closeRequested = true
        ..destroyed = true
        ..originDirty = true
        ..scaleDirty = true;
      pending.noteExpose(1, 2, 3, 4);

      pending.reset();

      expect(pending.isEmpty, isTrue);
      expect(pending.activated, isFalse);
      expect(pending.exposeLeft, 0);
      expect(pending.exposeTop, 0);
      expect(pending.exposeRight, 0);
      expect(pending.exposeBottom, 0);
    });
  });

  group('X11EventTranslator.emitPending', () {
    test('emits one ordered logical event per coalesced category', () {
      final pending = X11PendingWindowEvents()
        ..resized = true
        ..moved = true
        ..activationChanged = true
        ..activated = true
        ..closeRequested = true
        ..destroyed = true;
      pending
        ..noteExpose(10, 20, 20, 30)
        ..noteExpose(0, 10, 15, 10);
      final events = <PlatformWindowEvent>[];

      X11EventTranslator.emitPending(
        pending,
        windowId: const NativeWindowId(42),
        generation: 7,
        scale: 2,
        deviceWidth: 1600,
        deviceHeight: 1200,
        originX: -40,
        originY: 60,
        emit: events.add,
      );

      expect(events, hasLength(6));
      expect(events.map((event) => event.runtimeType), <Type>[
        WindowResizedEvent,
        WindowMovedEvent,
        WindowExposedEvent,
        WindowActivationEvent,
        WindowCloseRequestedEvent,
        WindowClosedEvent,
      ]);
      for (final event in events) {
        expect(event.windowId, const NativeWindowId(42));
        expect(event.generation, 7);
      }

      final resized = events[0] as WindowResizedEvent;
      expect(resized.clientSize, const Size(800, 600));
      expect(resized.renderScale, 2);

      final moved = events[1] as WindowMovedEvent;
      expect(moved.screenPosition, const Offset(-20, 30));

      final exposed = events[2] as WindowExposedEvent;
      expect(exposed.dirtyRect, const Rect.fromLTRB(0, 5, 15, 25));

      final activation = events[3] as WindowActivationEvent;
      expect(activation.activation, WindowActivation.activated);
    });

    test('does not emit anything for an empty drain', () {
      final events = <PlatformWindowEvent>[];

      X11EventTranslator.emitPending(
        X11PendingWindowEvents(),
        windowId: const NativeWindowId(1),
        generation: 0,
        scale: 1,
        deviceWidth: 1,
        deviceHeight: 1,
        originX: 0,
        originY: 0,
        emit: events.add,
      );

      expect(events, isEmpty);
    });
  });
}
