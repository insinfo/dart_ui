import 'dart:ffi';
import 'dart:io';

import 'package:dart_ui/src/backends/x11/x11_events.dart';
import 'package:dart_ui/src/backends/x11/x11_keyboard.dart';
import 'package:dart_ui/src/backends/x11/x11_libc.dart';
import 'package:dart_ui/src/backends/x11/x11_protocol.dart';
import 'package:dart_ui/src/geometry/offset.dart';
import 'package:dart_ui/src/geometry/rect.dart';
import 'package:dart_ui/src/geometry/size.dart';
import 'package:dart_ui/src/platform/compose_sequences.dart';
import 'package:dart_ui/src/platform/input_events.dart';
import 'package:dart_ui/src/platform/keysyms.dart';
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
  int timestamp = 0,
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
    ..data0 = data0
    ..timestamp = timestamp;
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
        writeU32(event, 4, 1234);
        writeU32(event, 12, 14);
        writeU16(event, 24, -15);
        writeU16(event, 26, 27);
        raw.decodeFrom(event);
      });
      expect(raw.window, 14);
      expect(raw.timestamp, 1234);
      expect(raw.x, -15);
      expect(raw.y, 27);
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
    test('normalises core pointer events into logical coordinates', () {
      final move = X11EventTranslator.translateCorePointer(
        _raw(
          type: xcbMotionNotify,
          x: -30,
          y: 45,
          timestamp: 1234,
        ),
        windowId: const NativeWindowId(7),
        generation: 3,
        scale: 1.5,
      ) as PointerMoveEvent;

      expect(move.windowId, const NativeWindowId(7));
      expect(move.generation, 3);
      expect(move.timestamp, const Duration(milliseconds: 1234));
      expect(move.pointerId, 0);
      expect(move.kind, PointerKind.mouse);
      expect(move.logicalPosition, const Offset(-20, 30));

      final down = X11EventTranslator.translateCorePointer(
        _raw(type: xcbButtonPress, detail: 3, x: 20, y: 10),
        windowId: const NativeWindowId(7),
        generation: 3,
        scale: 2,
      ) as PointerDownEvent;
      expect(down.button, PointerButton.secondary);
      expect(down.logicalPosition, const Offset(10, 5));

      final up = X11EventTranslator.translateCorePointer(
        _raw(type: xcbButtonRelease, detail: 2),
        windowId: const NativeWindowId(7),
        generation: 3,
        scale: 2,
      ) as PointerUpEvent;
      expect(up.button, PointerButton.middle);
    });

    test('normalises crossings and rejects unknown buttons', () {
      expect(
        X11EventTranslator.translateCorePointer(
          _raw(type: xcbEnterNotify),
          windowId: const NativeWindowId(1),
          generation: 0,
          scale: 1,
        ),
        isA<WindowPointerEnterEvent>(),
      );
      expect(
        X11EventTranslator.translateCorePointer(
          _raw(type: xcbLeaveNotify),
          windowId: const NativeWindowId(1),
          generation: 0,
          scale: 1,
        ),
        isA<WindowPointerLeaveEvent>(),
      );
      for (final detail in <int>[10]) {
        expect(
          X11EventTranslator.translateCorePointer(
            _raw(type: xcbButtonPress, detail: detail),
            windowId: const NativeWindowId(1),
            generation: 0,
            scale: 1,
          ),
          isNull,
        );
      }
    });

    test('normalises core wheel presses as line scroll events', () {
      const expectedDeltas = <int, Offset>{
        4: Offset(0, -1),
        5: Offset(0, 1),
        6: Offset(-1, 0),
        7: Offset(1, 0),
      };

      for (final entry in expectedDeltas.entries) {
        final scroll = X11EventTranslator.translateCorePointer(
          _raw(
            type: xcbButtonPress,
            detail: entry.key,
            x: -30,
            y: 45,
            timestamp: 4321,
          ),
          windowId: const NativeWindowId(17),
          generation: 9,
          scale: 1.5,
        ) as PointerScrollEvent;

        expect(scroll.windowId, const NativeWindowId(17));
        expect(scroll.generation, 9);
        expect(scroll.timestamp, const Duration(milliseconds: 4321));
        expect(scroll.pointerId, 0);
        expect(scroll.kind, PointerKind.mouse);
        expect(scroll.logicalPosition, const Offset(-20, 30));
        expect(scroll.scrollDelta, entry.value);
        expect(scroll.scrollDeltaUnit, ScrollDeltaUnit.lines);

        expect(
          X11EventTranslator.translateCorePointer(
            _raw(type: xcbButtonRelease, detail: entry.key),
            windowId: const NativeWindowId(17),
            generation: 9,
            scale: 1.5,
          ),
          isNull,
        );
      }
    });

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

    test('tracks map state and consumes input without pending side effects',
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

  group('X11EventTranslator.translateKey', () {
    // A small map: 38 is `a` listed as a single alphabetic keysym, 46 is
    // `c-cedilla` with a dead acute on the AltGr layer, 50 is Shift_L, 54 is
    // Return, 55 is Alt_L, 56 is Control_L and 57 is ISO_Level3_Shift.
    X11KeyboardState keyboardState() => X11KeyboardState(
          keyboard: X11KeyboardMapping.fromLists(
            <List<int>>[
              <int>[0x61], // 38
              <int>[keysymNoSymbol], // 39
              <int>[keysymNoSymbol], // 40
              <int>[keysymNoSymbol], // 41
              <int>[keysymNoSymbol], // 42
              <int>[keysymNoSymbol], // 43
              <int>[keysymNoSymbol], // 44
              <int>[keysymNoSymbol], // 45
              <int>[0xe7, 0xc7, 0xfe51], // 46
              <int>[keysymNoSymbol], // 47
              <int>[keysymNoSymbol], // 48
              <int>[keysymNoSymbol], // 49
              <int>[keysymShiftL], // 50
              <int>[keysymNoSymbol], // 51
              <int>[keysymNoSymbol], // 52
              <int>[keysymNoSymbol], // 53
              <int>[keysymReturn], // 54
              <int>[keysymAltL], // 55
              <int>[keysymControlL], // 56
              <int>[keysymIsoLevel3Shift], // 57
            ],
            firstKeycode: 38,
          ),
          modifiers: X11ModifierMapping.fromRows(<List<int>>[
            <int>[50], // Shift
            <int>[], // Lock
            <int>[56], // Control
            <int>[55], // Mod1 - Alt
            <int>[], // Mod2
            <int>[], // Mod3
            <int>[], // Mod4
            <int>[57], // Mod5 - AltGr
          ]),
          source: 'core-keyboard-mapping',
        );

    List<PlatformWindowEvent> translate(
      X11RawEvent raw, {
      X11KeyboardState? keyboard,
      ComposeEngine? compose,
    }) {
      final events = <PlatformWindowEvent>[];
      X11EventTranslator.translateKey(
        raw,
        windowId: const NativeWindowId(7),
        generation: 3,
        keyboard: keyboard ?? keyboardState(),
        compose: compose,
        emit: events.add,
      );
      return events;
    }

    /// Builds the 32 bytes of a real `xcb_key_press_event_t`, decodes them the
    /// way the pump does, and translates the result. Bytes in, events out -
    /// the only end-to-end this file can prove with no X server in the room.
    List<PlatformWindowEvent> fromWire({
      required int type,
      required int keycode,
      required int state,
      int time = 4321,
      X11KeyboardState? keyboard,
      ComposeEngine? compose,
    }) {
      late List<PlatformWindowEvent> events;
      _withNativeEvent((event) {
        event[0] = type;
        event[1] = keycode; // detail
        writeU16(event, 2, 0x0042); // sequence
        writeU32(event, 4, time); // time
        writeU32(event, 8, 0x01020304); // root
        writeU32(event, 12, 0x11223344); // event window
        writeU32(event, 16, 0); // child
        writeU16(event, 20, 500); // root_x
        writeU16(event, 22, 400); // root_y
        writeU16(event, 24, 120); // event_x
        writeU16(event, 26, 80); // event_y
        writeU16(event, 28, state); // state
        event[30] = 1; // same_screen
        final raw = X11RawEvent()..decodeFrom(event);
        expect(raw.type, type);
        expect(raw.detail, keycode);
        expect(raw.window, 0x11223344);
        expect(raw.state, state);
        events = translate(raw, keyboard: keyboard, compose: compose);
      });
      return events;
    }

    test('a KeyPress off the wire becomes a KeyDownEvent and its text', () {
      final events = fromWire(type: xcbKeyPress, keycode: 38, state: 0);

      expect(events.length, 2);
      final down = events[0] as KeyDownEvent;
      expect(down.windowId, const NativeWindowId(7));
      expect(down.generation, 3);
      expect(down.physicalKey, 38);
      expect(down.logicalKey, 0x61);
      expect(down.timestamp, const Duration(milliseconds: 4321));
      expect(down.modifiers, isEmpty);
      expect(down.isRepeat, isFalse);
      expect((events[1] as TextInputEvent).text, 'a');
    });

    test('the hardware event always precedes the text event', () {
      // A consumer that saw the text first could not implement a shortcut
      // that suppresses typing.
      final events = fromWire(type: xcbKeyPress, keycode: 38, state: 0);

      expect(events[0], isA<KeyEvent>());
      expect(events[1], isA<TextInputEvent>());
    });

    test('Shift in the state word selects level two and reports the modifier',
        () {
      final events =
          fromWire(type: xcbKeyPress, keycode: 38, state: x11ModShift);

      final down = events[0] as KeyDownEvent;
      expect(down.logicalKey, 0x41);
      expect(down.modifiers, <KeyModifier>{KeyModifier.shift});
      expect((events[1] as TextInputEvent).text, 'A');
    });

    test('a KeyRelease never produces text', () {
      // X carries `state` on both edges; a translator that ignored the edge
      // types every character twice.
      final events =
          fromWire(type: xcbKeyRelease, keycode: 38, state: x11ModShift);

      expect(events.single, isA<KeyUpEvent>());
      expect((events.single as KeyUpEvent).logicalKey, 0x41);
      expect(
        (events.single as KeyUpEvent).modifiers,
        <KeyModifier>{KeyModifier.shift},
      );
    });

    test('Control suppresses the text but not the key event', () {
      // Ctrl+A is a command and the keysym under it is still `a`; emitting
      // text would type an `a` into the document the shortcut acts on.
      final events =
          fromWire(type: xcbKeyPress, keycode: 38, state: x11ModControl);

      expect(events.single, isA<KeyDownEvent>());
      expect((events.single as KeyDownEvent).logicalKey, 0x61);
      expect(
        (events.single as KeyDownEvent).modifiers,
        <KeyModifier>{KeyModifier.control},
      );
    });

    test('Alt suppresses the text', () {
      final events =
          fromWire(type: xcbKeyPress, keycode: 38, state: x11ModMod1);

      expect(events.single, isA<KeyDownEvent>());
    });

    test('AltGr does not suppress the text it exists to reach', () {
      // Mod5 is ISO_Level3_Shift on this map. Suppressing it as if it were
      // Alt would make the whole AltGr layer untypable.
      final events =
          fromWire(type: xcbKeyPress, keycode: 46, state: x11ModMod5);

      expect(events.length, 1); // dead_acute has no text of its own
      expect((events.single as KeyDownEvent).logicalKey, 0xfe51);
    });

    test('AltGr reaches the second group text where the layer has some', () {
      final keyboard = X11KeyboardState(
        keyboard: X11KeyboardMapping.fromLists(
          <List<int>>[
            <int>[0x71, 0x51, 0x2f, keysymNoSymbol], // q Q, AltGr slash
            <int>[keysymIsoLevel3Shift],
          ],
          firstKeycode: 24,
        ),
        modifiers: X11ModifierMapping.fromRows(<List<int>>[
          <int>[], <int>[], <int>[], <int>[], //
          <int>[], <int>[], <int>[], <int>[25],
        ]),
      );

      final events = fromWire(
        type: xcbKeyPress,
        keycode: 24,
        state: x11ModMod5,
        keyboard: keyboard,
      );

      expect((events[1] as TextInputEvent).text, '/');
    });

    test('a keysym that resolves to nothing still emits its KeyEvent', () {
      // The contract: a backend that cannot translate stays silent about text
      // rather than guessing a character from a keycode.
      final events = fromWire(
        type: xcbKeyPress,
        keycode: 200,
        state: 0,
        keyboard: X11KeyboardState(),
      );

      expect(events.single, isA<KeyDownEvent>());
      expect((events.single as KeyDownEvent).physicalKey, 200);
      expect((events.single as KeyDownEvent).logicalKey, keysymNoSymbol);
    });

    test('a control character keysym produces no TextInputEvent', () {
      // Return has a Latin-1 value of 0x0d, and a TextInputEvent must never
      // carry a control character.
      final events = fromWire(type: xcbKeyPress, keycode: 54, state: 0);

      expect(events.single, isA<KeyDownEvent>());
      expect((events.single as KeyDownEvent).logicalKey, keysymReturn);
    });

    test('a modifier key press produces no text', () {
      final events = fromWire(type: xcbKeyPress, keycode: 50, state: 0);

      expect(events.single, isA<KeyDownEvent>());
      expect((events.single as KeyDownEvent).logicalKey, keysymShiftL);
    });

    test('the repeat flag the filter set is carried onto the KeyDownEvent', () {
      final raw = X11RawEvent()
        ..type = xcbKeyPress
        ..detail = 38
        ..timestamp = 900
        ..repeat = true;

      final events = translate(raw);

      expect((events[0] as KeyDownEvent).isRepeat, isTrue);
      // A repeat still types: holding `a` is how `aaaa` gets into a field.
      expect((events[1] as TextInputEvent).text, 'a');
    });

    test('an event that is neither a press nor a release is ignored', () {
      expect(translate(_raw(type: xcbMotionNotify)), isEmpty);
    });

    group('with a Compose engine in front', () {
      ComposeEngine acuteEngine() => ComposeEngine(
            ComposeTable.parse(
              '<dead_acute> <a> : "\u00e1" aacute\n',
            ),
          );

      test('a dead key alone produces a KeyEvent and no text', () {
        final events = fromWire(
          type: xcbKeyPress,
          keycode: 46,
          state: x11ModMod5, // the AltGr layer, which is dead_acute here
          compose: acuteEngine(),
        );

        expect(events.single, isA<KeyDownEvent>());
        expect((events.single as KeyDownEvent).logicalKey, 0xfe51);
      });

      test('dead_acute then a is two keysyms and one character', () {
        final compose = acuteEngine();

        fromWire(
          type: xcbKeyPress,
          keycode: 46,
          state: x11ModMod5,
          compose: compose,
        );
        final events = fromWire(
          type: xcbKeyPress,
          keycode: 38,
          state: 0,
          compose: compose,
        );

        expect(events.length, 2);
        expect(events[0], isA<KeyDownEvent>());
        expect((events[1] as TextInputEvent).text, '\u00e1');
      });

      test('Shift held during a sequence does not break it', () {
        // Shift is held *during* half the sequences in a real table, so the
        // modifier keysym must never reach the engine.
        final compose = ComposeEngine(
          ComposeTable.parse('<dead_acute> <A> : "\u00c1" Aacute\n'),
        );

        fromWire(
          type: xcbKeyPress,
          keycode: 46,
          state: x11ModMod5,
          compose: compose,
        );
        // The Shift_L press itself, with Shift not yet in `state`.
        fromWire(type: xcbKeyPress, keycode: 50, state: 0, compose: compose);
        final events = fromWire(
          type: xcbKeyPress,
          keycode: 38,
          state: x11ModShift,
          compose: compose,
        );

        expect((events[1] as TextInputEvent).text, '\u00c1');
      });

      test('an ordinary key passes straight through the engine', () {
        final events = fromWire(
          type: xcbKeyPress,
          keycode: 38,
          state: 0,
          compose: acuteEngine(),
        );

        expect((events[1] as TextInputEvent).text, 'a');
      });

      test('a sequence that cannot match emits no bare accent', () {
        final compose = acuteEngine();

        fromWire(
          type: xcbKeyPress,
          keycode: 46,
          state: x11ModMod5,
          compose: compose,
        );
        // c-cedilla does not follow dead_acute in the table above.
        final events = fromWire(
          type: xcbKeyPress,
          keycode: 46,
          state: 0,
          compose: compose,
        );

        expect(events.single, isA<KeyDownEvent>());
      });
    });
  });
}
