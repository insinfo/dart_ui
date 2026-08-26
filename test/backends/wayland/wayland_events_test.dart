import 'package:dart_ui/src/backends/wayland/wayland_events.dart';
import 'package:dart_ui/src/backends/wayland/wayland_keymap.dart';
import 'package:dart_ui/src/backends/wayland/wayland_protocol.dart';
import 'package:dart_ui/src/geometry/offset.dart';
import 'package:dart_ui/src/platform/input_events.dart';
import 'package:dart_ui/src/platform/window_events.dart';
import 'package:test/test.dart';

void main() {
  late WaylandWindowProtocolState state;
  late WaylandPendingWindowEvents pending;
  late WaylandRawEvent raw;

  setUp(() {
    state = WaylandWindowProtocolState(
      surfaceId: 3,
      xdgSurfaceId: 4,
      toplevelId: 5,
    )
      ..width = 640
      ..height = 480;
    pending = WaylandPendingWindowEvents();
    raw = WaylandRawEvent();
  });

  void toplevelConfigure(int width, int height, {int stateFlags = 0}) {
    raw
      ..reset()
      ..type = WaylandRawEventType.xdgToplevelConfigure
      ..surfaceId = 3
      ..width = width
      ..height = height
      ..stateFlags = stateFlags;
    expect(WaylandEventTranslator.apply(raw, state, pending), isTrue);
  }

  void surfaceConfigure(int serial) {
    raw
      ..reset()
      ..type = WaylandRawEventType.xdgSurfaceConfigure
      ..surfaceId = 3
      ..serial = serial;
    expect(WaylandEventTranslator.apply(raw, state, pending), isTrue);
  }

  group('the configure cycle', () {
    test('a toplevel configure stages and does not apply', () {
      toplevelConfigure(800, 600);

      expect(state.width, 640, reason: 'size must wait for xdg_surface');
      expect(state.configured, isFalse);
      expect(pending.resized, isFalse);
      expect(pending.ackSerial, -1);
    });

    test('the surface configure latches size, serial and first expose', () {
      toplevelConfigure(800, 600);
      surfaceConfigure(41);

      expect(state.width, 800);
      expect(state.height, 600);
      expect(state.configured, isTrue);
      expect(pending.resized, isTrue);
      expect(pending.exposed, isTrue,
          reason: 'the first configure is the '
              'only paint trigger Wayland has');
      expect(pending.ackSerial, 41);
    });

    test('zero size means the client keeps its own', () {
      toplevelConfigure(0, 0);
      surfaceConfigure(9);

      expect(state.width, 640);
      expect(state.height, 480);
      expect(state.configured, isTrue);
      expect(pending.resized, isFalse);
      expect(pending.ackSerial, 9);
    });

    test('a repeat of the same size acks but does not resize', () {
      toplevelConfigure(800, 600);
      surfaceConfigure(1);
      pending.reset();

      toplevelConfigure(800, 600);
      surfaceConfigure(2);

      expect(pending.resized, isFalse);
      expect(pending.exposed, isFalse,
          reason: 'only the first configure '
              'exposes');
      expect(pending.ackSerial, 2);
    });

    test('several cycles in one pump keep only the newest serial', () {
      toplevelConfigure(800, 600);
      surfaceConfigure(1);
      toplevelConfigure(900, 700);
      surfaceConfigure(2);

      expect(pending.ackSerial, 2);
      expect(state.width, 900);
      expect(state.height, 700);
    });

    test('a bare surface configure (no toplevel half) still acks', () {
      surfaceConfigure(77);

      expect(pending.ackSerial, 77);
      expect(state.width, 640);
      expect(state.configured, isTrue);
    });

    test('activation arrives through the states array', () {
      toplevelConfigure(0, 0, stateFlags: 1 << xdgToplevelStateActivated);
      surfaceConfigure(5);

      expect(state.activated, isTrue);
      expect(pending.activationChanged, isTrue);
      expect(pending.activated, isTrue);

      pending.reset();
      toplevelConfigure(0, 0);
      surfaceConfigure(6);

      expect(state.activated, isFalse);
      expect(pending.activationChanged, isTrue);
      expect(pending.activated, isFalse);
    });

    test('maximized and fullscreen bits update the window state', () {
      toplevelConfigure(1920, 1080, stateFlags: 1 << xdgToplevelStateMaximized);
      surfaceConfigure(8);
      expect(state.maximized, isTrue);
      expect(state.fullscreen, isFalse);

      toplevelConfigure(1920, 1080,
          stateFlags: 1 << xdgToplevelStateFullscreen);
      surfaceConfigure(9);
      expect(state.maximized, isFalse);
      expect(state.fullscreen, isTrue);
    });
  });

  group('routing', () {
    test('events for another surface are not consumed', () {
      raw
        ..reset()
        ..type = WaylandRawEventType.xdgToplevelClose
        ..surfaceId = 99;
      expect(WaylandEventTranslator.apply(raw, state, pending), isFalse);
      expect(pending.isEmpty, isTrue);
    });

    test('close requests set the bit and nothing else', () {
      raw
        ..reset()
        ..type = WaylandRawEventType.xdgToplevelClose
        ..surfaceId = 3;
      expect(WaylandEventTranslator.apply(raw, state, pending), isTrue);
      expect(pending.closeRequested, isTrue);
      expect(pending.resized, isFalse);
    });

    test('a destroyed window consumes nothing further', () {
      state.destroyed = true;
      raw
        ..reset()
        ..type = WaylandRawEventType.xdgSurfaceConfigure
        ..surfaceId = 3
        ..serial = 1;
      expect(WaylandEventTranslator.apply(raw, state, pending), isFalse);
      expect(pending.ackSerial, -1);
    });

    test('display-wide scale changes are consumed by any window', () {
      raw
        ..reset()
        ..type = WaylandRawEventType.scaleChanged;
      expect(WaylandEventTranslator.apply(raw, state, pending), isTrue);
      expect(pending.scaleDirty, isTrue);
    });
  });

  group('pointer translation', () {
    const windowId = NativeWindowId(7);

    test('motion carries surface coordinates as logical units', () {
      raw
        ..reset()
        ..type = WaylandRawEventType.pointerMotion
        ..surfaceId = 3
        ..timeMilliseconds = 1200
        ..x = 32.5
        ..y = 17.25;
      final event = WaylandEventTranslator.translatePointer(
        raw,
        windowId: windowId,
        generation: 2,
      );
      expect(event, isA<PointerMoveEvent>());
      final move = event as PointerMoveEvent;
      expect(move.logicalPosition, const Offset(32.5, 17.25));
      expect(move.timestamp, const Duration(milliseconds: 1200));
      expect(move.generation, 2);
    });

    test('buttons map evdev codes to the framework enum', () {
      raw
        ..reset()
        ..type = WaylandRawEventType.pointerButton
        ..surfaceId = 3
        ..key = btnLeft
        ..state = wlPointerButtonStatePressed;
      final down = WaylandEventTranslator.translatePointer(
        raw,
        windowId: windowId,
        generation: 1,
      );
      expect((down as PointerDownEvent).button, PointerButton.primary);

      raw
        ..key = btnRight
        ..state = wlPointerButtonStateReleased;
      final up = WaylandEventTranslator.translatePointer(
        raw,
        windowId: windowId,
        generation: 1,
      );
      expect((up as PointerUpEvent).button, PointerButton.secondary);
    });

    test('unknown buttons are dropped, not guessed', () {
      raw
        ..reset()
        ..type = WaylandRawEventType.pointerButton
        ..surfaceId = 3
        ..key = 0x100 // BTN_0, not a pointer button this backend maps.
        ..state = wlPointerButtonStatePressed;
      expect(
        WaylandEventTranslator.translatePointer(
          raw,
          windowId: windowId,
          generation: 1,
        ),
        isNull,
      );
    });

    test('axis events become pixel scrolls on the right axis', () {
      raw
        ..reset()
        ..type = WaylandRawEventType.pointerAxis
        ..surfaceId = 3
        ..axis = wlPointerAxisVerticalScroll
        ..axisValue = 10.0;
      final vertical = WaylandEventTranslator.translatePointer(
        raw,
        windowId: windowId,
        generation: 1,
      ) as PointerScrollEvent;
      expect(vertical.scrollDelta, const Offset(0, 10));
      expect(vertical.scrollDeltaUnit, ScrollDeltaUnit.pixels);

      raw.axis = wlPointerAxisHorizontalScroll;
      final horizontal = WaylandEventTranslator.translatePointer(
        raw,
        windowId: windowId,
        generation: 1,
      ) as PointerScrollEvent;
      expect(horizontal.scrollDelta, const Offset(10, 0));
    });

    test('enter and leave become crossing events', () {
      raw
        ..reset()
        ..type = WaylandRawEventType.pointerEnter
        ..surfaceId = 3;
      expect(
        WaylandEventTranslator.translatePointer(
          raw,
          windowId: windowId,
          generation: 1,
        ),
        isA<WindowPointerEnterEvent>(),
      );
      raw.type = WaylandRawEventType.pointerLeave;
      expect(
        WaylandEventTranslator.translatePointer(
          raw,
          windowId: windowId,
          generation: 1,
        ),
        isA<WindowPointerLeaveEvent>(),
      );
    });
  });

  group('keyboard translation', () {
    const windowId = NativeWindowId(7);
    late WaylandXkbKeymap keymap;
    late WaylandModifiersState modifiers;
    late List<PlatformWindowEvent> emitted;

    setUp(() {
      keymap = WaylandXkbKeymap.usFallback();
      modifiers = WaylandModifiersState();
      emitted = <PlatformWindowEvent>[];
    });

    void key(int evdevKey, {bool pressed = true}) {
      raw
        ..reset()
        ..type = WaylandRawEventType.keyboardKey
        ..surfaceId = 3
        ..timeMilliseconds = 99
        ..key = evdevKey
        ..state =
            pressed ? wlKeyboardKeyStatePressed : wlKeyboardKeyStateReleased;
      WaylandEventTranslator.translateKey(
        raw,
        windowId: windowId,
        generation: 1,
        keymap: keymap,
        modifiers: modifiers,
        emit: emitted.add,
      );
    }

    test('a printable press emits KeyDown then TextInput', () {
      key(30); // KEY_A

      expect(emitted, hasLength(2));
      final down = emitted[0] as KeyDownEvent;
      expect(down.physicalKey, 38);
      expect(down.logicalKey, 0x61);
      final text = emitted[1] as TextInputEvent;
      expect(text.text, 'a');
    });

    test('releases emit KeyUp and never text', () {
      key(30, pressed: false);

      expect(emitted.single, isA<KeyUpEvent>());
    });

    test('shift changes both keysym and text', () {
      modifiers.update(depressed: 0x01, latched: 0, locked: 0, group: 0);
      key(30);

      final down = emitted[0] as KeyDownEvent;
      expect(down.modifiers, contains(KeyModifier.shift));
      expect((emitted[1] as TextInputEvent).text, 'A');
    });

    test('control chords stay hardware-only', () {
      modifiers.update(depressed: 0x04, latched: 0, locked: 0, group: 0);
      key(30);

      expect(emitted.single, isA<KeyDownEvent>());
      expect(
        (emitted.single as KeyDownEvent).modifiers,
        contains(KeyModifier.control),
      );
    });

    test('function keys emit no text', () {
      key(28); // KEY_ENTER: Return is a control, not content.

      expect(emitted.single, isA<KeyDownEvent>());
      expect((emitted.single as KeyDownEvent).logicalKey, xkbKeysymReturn);
    });

    test('a missing keymap still reports the hardware key', () {
      keymap = WaylandXkbKeymap.usFallback();
      raw
        ..reset()
        ..type = WaylandRawEventType.keyboardKey
        ..surfaceId = 3
        ..key = 30
        ..state = wlKeyboardKeyStatePressed;
      WaylandEventTranslator.translateKey(
        raw,
        windowId: windowId,
        generation: 1,
        keymap: null,
        modifiers: modifiers,
        emit: emitted.add,
      );

      expect(emitted.single, isA<KeyDownEvent>());
      expect((emitted.single as KeyDownEvent).logicalKey, xkbNoSymbol);
    });
  });

  group('emitPending', () {
    const windowId = NativeWindowId(9);

    test('emits one event per decided fact, in a stable order', () {
      pending
        ..resized = true
        ..exposed = true
        ..activationChanged = true
        ..activated = true
        ..closeRequested = true;
      final events = <PlatformWindowEvent>[];
      WaylandEventTranslator.emitPending(
        pending,
        windowId: windowId,
        generation: 4,
        logicalWidth: 800,
        logicalHeight: 600,
        renderScale: 2,
        emit: events.add,
      );

      expect(events, hasLength(4));
      final resized = events[0] as WindowResizedEvent;
      expect(resized.clientSize.width, 800);
      expect(resized.renderScale, 2);
      final exposed = events[1] as WindowExposedEvent;
      expect(exposed.dirtyRect!.width, 800);
      final activation = events[2] as WindowActivationEvent;
      expect(activation.activation, WindowActivation.activated);
      expect(events[3], isA<WindowCloseRequestedEvent>());
      for (final event in events) {
        expect(event.generation, 4);
        expect(event.windowId, windowId);
      }
    });

    test('an empty pending set emits nothing', () {
      final events = <PlatformWindowEvent>[];
      WaylandEventTranslator.emitPending(
        pending,
        windowId: windowId,
        generation: 1,
        logicalWidth: 10,
        logicalHeight: 10,
        renderScale: 1,
        emit: events.add,
      );
      expect(events, isEmpty);
    });
  });
}
