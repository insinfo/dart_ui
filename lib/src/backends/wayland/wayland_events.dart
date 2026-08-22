/// Turning Wayland events into framework events without per-event allocation.
///
/// The same architecture as `x11_events.dart`, because the same constraints
/// apply - `wl_pointer.motion` arrives at input-device rate, and section 6.5
/// forbids an allocation per sample:
///
///   * [WaylandRawEvent] is a single mutable record the connection overwrites
///     in place for every decoded message that concerns a window.
///   * [WaylandPendingWindowEvents] accumulates; configure floods collapse to
///     one resize per pump.
///   * [WaylandEventTranslator] is pure - no FFI, no socket - which is what
///     makes the configure/ack cycle testable on a host with no compositor.
///
/// ## The configure cycle, which is the part Wayland gets strict about
///
/// A client must not draw before the first `xdg_surface.configure`, must ack
/// every configure it applies (`ack_configure` with that serial), and commits
/// are transactions. That state machine lives in [WaylandWindowProtocolState]
/// and the translator: an `xdg_toplevel.configure` only *stages* size and
/// state, and the following `xdg_surface.configure` latches them, records the
/// serial to ack and marks the window resized/exposed. The window acks at
/// flush time, before its next commit, which is exactly the order the
/// protocol requires.
library;

import '../../geometry/offset.dart';
import '../../geometry/rect.dart';
import '../../geometry/size.dart';
import '../../platform/input_events.dart';
import '../../platform/window_events.dart';
import 'wayland_keymap.dart';
import 'wayland_protocol.dart';

/// What kind of decoded event a [WaylandRawEvent] currently holds.
enum WaylandRawEventType {
  none,
  xdgToplevelConfigure,
  xdgSurfaceConfigure,
  xdgToplevelClose,
  pointerEnter,
  pointerLeave,
  pointerMotion,
  pointerButton,
  pointerAxis,
  keyboardEnter,
  keyboardLeave,
  keyboardKey,
  keyboardModifiers,
  surfaceEnterOutput,
  scaleChanged,
}

/// One decoded Wayland event, reused across the pump. Never retained.
final class WaylandRawEvent {
  WaylandRawEventType type = WaylandRawEventType.none;

  /// The `wl_surface` protocol id this event is about (resolved through the
  /// pointer/keyboard focus for input events), or 0 for display-wide events.
  int surfaceId = 0;

  int serial = 0;

  /// Input timestamp in compositor milliseconds (a wrapping uint32).
  int timeMilliseconds = 0;

  /// Geometry / key / button payload, meaning depends on [type].
  int width = 0;
  int height = 0;
  int key = 0;
  int state = 0;
  int axis = 0;

  /// Pointer position in surface-local coordinates. Wayland surface
  /// coordinates *are* the framework's logical units - the buffer scale, not
  /// the event stream, carries DPI - so no division happens downstream.
  double x = 0;
  double y = 0;

  /// Scroll length for [WaylandRawEventType.pointerAxis].
  double axisValue = 0;

  /// Bitmask of `xdg_toplevel.state` values for a toplevel configure.
  int stateFlags = 0;

  /// Modifier words for [WaylandRawEventType.keyboardModifiers].
  int modsDepressed = 0;
  int modsLatched = 0;
  int modsLocked = 0;
  int modsGroup = 0;

  void reset() {
    type = WaylandRawEventType.none;
    surfaceId = 0;
    serial = 0;
    timeMilliseconds = 0;
    width = 0;
    height = 0;
    key = 0;
    state = 0;
    axis = 0;
    x = 0;
    y = 0;
    axisValue = 0;
    stateFlags = 0;
    modsDepressed = 0;
    modsLatched = 0;
    modsLocked = 0;
    modsGroup = 0;
  }
}

/// The per-window protocol state the translator updates in place.
final class WaylandWindowProtocolState {
  WaylandWindowProtocolState({
    required this.surfaceId,
    required this.xdgSurfaceId,
    required this.toplevelId,
  });

  final int surfaceId;
  final int xdgSurfaceId;
  final int toplevelId;

  /// Current size in surface (logical) coordinates.
  int width = 0;
  int height = 0;

  /// Integer buffer scale currently applied to commits.
  int bufferScale = 1;

  /// Staged by `xdg_toplevel.configure`, latched by `xdg_surface.configure`.
  /// Zero means "the client decides", which keeps the current size.
  int pendingWidth = 0;
  int pendingHeight = 0;
  int pendingStateFlags = 0;
  bool hasPendingToplevelConfigure = false;

  /// Whether the initial configure has been received; drawing before it is a
  /// protocol violation, so the surface is only built once this is true.
  bool configured = false;

  bool activated = false;
  bool maximized = false;
  bool fullscreen = false;
  bool destroyed = false;
}

/// Everything one pump decided, before any framework event object exists.
final class WaylandPendingWindowEvents {
  bool resized = false;
  bool exposed = false;
  bool activationChanged = false;
  bool activated = false;
  bool closeRequested = false;
  bool destroyed = false;
  bool scaleDirty = false;

  /// The configure serial to `ack_configure` before the next commit, or -1.
  /// Later configures overwrite earlier ones within a pump: acking the newest
  /// is the protocol's own collapsing rule.
  int ackSerial = -1;

  bool get isEmpty =>
      !resized &&
      !exposed &&
      !activationChanged &&
      !closeRequested &&
      !destroyed &&
      !scaleDirty &&
      ackSerial < 0;

  void reset() {
    resized = false;
    exposed = false;
    activationChanged = false;
    activated = false;
    closeRequested = false;
    destroyed = false;
    scaleDirty = false;
    ackSerial = -1;
  }
}

/// The rules, as pure functions over [WaylandRawEvent] and the window state.
abstract final class WaylandEventTranslator {
  /// Applies one decoded event. Sets bits on [pending]; allocates nothing.
  ///
  /// Returns false when the event was not for this window, so the caller can
  /// route it elsewhere or count it as stale.
  static bool apply(
    WaylandRawEvent raw,
    WaylandWindowProtocolState state,
    WaylandPendingWindowEvents pending,
  ) {
    if (raw.type == WaylandRawEventType.scaleChanged) {
      pending.scaleDirty = true;
      return true;
    }
    if (raw.surfaceId != state.surfaceId) return false;
    if (state.destroyed) return false;

    switch (raw.type) {
      case WaylandRawEventType.xdgToplevelConfigure:
        // Stages only. The size is not final until xdg_surface.configure
        // arrives - the protocol allows several toplevel configures per cycle
        // and only the last one before the surface configure counts.
        state.pendingWidth = raw.width;
        state.pendingHeight = raw.height;
        state.pendingStateFlags = raw.stateFlags;
        state.hasPendingToplevelConfigure = true;
        return true;

      case WaylandRawEventType.xdgSurfaceConfigure:
        _latchConfigure(raw.serial, state, pending);
        return true;

      case WaylandRawEventType.xdgToplevelClose:
        pending.closeRequested = true;
        return true;

      case WaylandRawEventType.surfaceEnterOutput:
        pending.scaleDirty = true;
        return true;

      case WaylandRawEventType.pointerEnter:
      case WaylandRawEventType.pointerLeave:
      case WaylandRawEventType.pointerMotion:
      case WaylandRawEventType.pointerButton:
      case WaylandRawEventType.pointerAxis:
      case WaylandRawEventType.keyboardEnter:
      case WaylandRawEventType.keyboardLeave:
      case WaylandRawEventType.keyboardKey:
      case WaylandRawEventType.keyboardModifiers:
        // Input is translated separately; nothing to coalesce here.
        return true;

      case WaylandRawEventType.none:
      case WaylandRawEventType.scaleChanged:
        // scaleChanged is display-wide and already consumed above; reaching
        // it here would mean the guard changed, so refuse rather than guess.
        return false;
    }
  }

  static void _latchConfigure(
    int serial,
    WaylandWindowProtocolState state,
    WaylandPendingWindowEvents pending,
  ) {
    pending.ackSerial = serial;
    if (state.hasPendingToplevelConfigure) {
      state.hasPendingToplevelConfigure = false;
      final flags = state.pendingStateFlags;
      final activated = (flags & (1 << xdgToplevelStateActivated)) != 0;
      state.maximized = (flags & (1 << xdgToplevelStateMaximized)) != 0;
      state.fullscreen = (flags & (1 << xdgToplevelStateFullscreen)) != 0;
      if (activated != state.activated) {
        state.activated = activated;
        pending.activationChanged = true;
        pending.activated = activated;
      }
      // Zero means the client picks; keeping the current size is that pick.
      if (state.pendingWidth > 0 && state.pendingHeight > 0) {
        if (state.pendingWidth != state.width ||
            state.pendingHeight != state.height) {
          state.width = state.pendingWidth;
          state.height = state.pendingHeight;
          pending.resized = true;
        }
      }
    }
    if (!state.configured) {
      state.configured = true;
      // The first configure is what makes drawing legal at all, so the first
      // frame is requested here - Wayland has no Expose event to do it.
      pending.exposed = true;
    }
  }

  /// Normalises one pointer event, or returns null for kinds that produce no
  /// framework event (axis frames, unknown buttons).
  static PlatformWindowEvent? translatePointer(
    WaylandRawEvent raw, {
    required NativeWindowId windowId,
    required int generation,
  }) {
    switch (raw.type) {
      case WaylandRawEventType.pointerEnter:
        return WindowPointerEnterEvent(
          windowId: windowId,
          generation: generation,
        );
      case WaylandRawEventType.pointerLeave:
        return WindowPointerLeaveEvent(
          windowId: windowId,
          generation: generation,
        );
      case WaylandRawEventType.pointerMotion:
        return PointerMoveEvent(
          windowId: windowId,
          generation: generation,
          timestamp: Duration(milliseconds: raw.timeMilliseconds),
          pointerId: 0,
          kind: PointerKind.mouse,
          logicalPosition: Offset(raw.x, raw.y),
        );
      case WaylandRawEventType.pointerButton:
        final button = _pointerButton(raw.key);
        if (button == null) return null;
        return raw.state == wlPointerButtonStatePressed
            ? PointerDownEvent(
                windowId: windowId,
                generation: generation,
                timestamp: Duration(milliseconds: raw.timeMilliseconds),
                pointerId: 0,
                kind: PointerKind.mouse,
                logicalPosition: Offset(raw.x, raw.y),
                button: button,
              )
            : PointerUpEvent(
                windowId: windowId,
                generation: generation,
                timestamp: Duration(milliseconds: raw.timeMilliseconds),
                pointerId: 0,
                kind: PointerKind.mouse,
                logicalPosition: Offset(raw.x, raw.y),
                button: button,
              );
      case WaylandRawEventType.pointerAxis:
        // wl_fixed axis lengths are in surface-local units, which are logical
        // pixels - unlike X11's discrete wheel clicks.
        final delta = raw.axis == wlPointerAxisHorizontalScroll
            ? Offset(raw.axisValue, 0)
            : Offset(0, raw.axisValue);
        return PointerScrollEvent(
          windowId: windowId,
          generation: generation,
          timestamp: Duration(milliseconds: raw.timeMilliseconds),
          pointerId: 0,
          kind: PointerKind.mouse,
          logicalPosition: Offset(raw.x, raw.y),
          scrollDelta: delta,
          scrollDeltaUnit: ScrollDeltaUnit.pixels,
        );
      default:
        return null;
    }
  }

  /// Translates one `wl_keyboard.key` into a [KeyEvent], and possibly the
  /// [TextInputEvent] its keysym produces. Events go to [emit] in order:
  /// hardware first, text second, the same order Win32 delivers
  /// `WM_KEYDOWN`/`WM_CHAR`.
  ///
  /// A key whose symbol the keymap subset cannot resolve still emits its
  /// [KeyEvent]; it emits no text, per the [TextInputEvent] contract - a
  /// backend that cannot translate must stay silent rather than guess.
  static void translateKey(
    WaylandRawEvent raw, {
    required NativeWindowId windowId,
    required int generation,
    required WaylandXkbKeymap? keymap,
    required WaylandModifiersState modifiers,
    required void Function(PlatformWindowEvent event) emit,
  }) {
    if (raw.type != WaylandRawEventType.keyboardKey) return;
    final xkbKeycode = raw.key + evdevToXkbKeycodeOffset;
    final keysym = keymap?.keysymFor(
          xkbKeycode,
          shift: modifiers.shift,
          capsLock: modifiers.capsLock,
        ) ??
        xkbNoSymbol;
    final timestamp = Duration(milliseconds: raw.timeMilliseconds);
    final modifierSet = _modifierSet(modifiers);
    final pressed = raw.state == wlKeyboardKeyStatePressed;
    emit(pressed
        ? KeyDownEvent(
            windowId: windowId,
            generation: generation,
            timestamp: timestamp,
            physicalKey: xkbKeycode,
            logicalKey: keysym,
            modifiers: modifierSet,
          )
        : KeyUpEvent(
            windowId: windowId,
            generation: generation,
            timestamp: timestamp,
            physicalKey: xkbKeycode,
            logicalKey: keysym,
            modifiers: modifierSet,
          ));
    if (!pressed || modifiers.control || modifiers.alt || modifiers.meta) {
      return;
    }
    final text = keymap?.textFor(
      xkbKeycode,
      shift: modifiers.shift,
      capsLock: modifiers.capsLock,
    );
    if (text == null || text.isEmpty) return;
    if (text.length == 1 && isTextInputControlUnit(text.codeUnitAt(0))) return;
    emit(TextInputEvent(
      windowId: windowId,
      generation: generation,
      timestamp: timestamp,
      text: text,
    ));
  }

  static Set<KeyModifier> _modifierSet(WaylandModifiersState modifiers) {
    if (modifiers.depressed == 0 &&
        modifiers.latched == 0 &&
        modifiers.locked == 0) {
      return const <KeyModifier>{};
    }
    return <KeyModifier>{
      if (modifiers.shift) KeyModifier.shift,
      if (modifiers.control) KeyModifier.control,
      if (modifiers.alt) KeyModifier.alt,
      if (modifiers.meta) KeyModifier.meta,
      if (modifiers.capsLock) KeyModifier.capsLock,
      if (modifiers.numLock) KeyModifier.numLock,
    };
  }

  static PointerButton? _pointerButton(int evdevButton) =>
      switch (evdevButton) {
        btnLeft => PointerButton.primary,
        btnRight => PointerButton.secondary,
        btnMiddle => PointerButton.middle,
        btnSide => PointerButton.back,
        btnExtra => PointerButton.forward,
        _ => null,
      };

  /// Builds the framework events for one pump and hands each to [emit].
  ///
  /// [generation] must already reflect any surface rebuild a resize caused,
  /// the same contract `X11EventTranslator.emitPending` documents.
  static void emitPending(
    WaylandPendingWindowEvents pending, {
    required NativeWindowId windowId,
    required int generation,
    required int logicalWidth,
    required int logicalHeight,
    required double renderScale,
    required void Function(PlatformWindowEvent event) emit,
  }) {
    if (pending.resized) {
      emit(WindowResizedEvent(
        windowId: windowId,
        generation: generation,
        clientSize: Size(logicalWidth.toDouble(), logicalHeight.toDouble()),
        renderScale: renderScale,
      ));
    }
    if (pending.exposed) {
      emit(WindowExposedEvent(
        windowId: windowId,
        generation: generation,
        dirtyRect: Rect.fromLTWH(
          0,
          0,
          logicalWidth.toDouble(),
          logicalHeight.toDouble(),
        ),
      ));
    }
    if (pending.activationChanged) {
      emit(WindowActivationEvent(
        windowId: windowId,
        generation: generation,
        activation: pending.activated
            ? WindowActivation.activated
            : WindowActivation.deactivated,
      ));
    }
    if (pending.closeRequested) {
      emit(WindowCloseRequestedEvent(
        windowId: windowId,
        generation: generation,
      ));
    }
    if (pending.destroyed) {
      emit(WindowClosedEvent(windowId: windowId, generation: generation));
    }
  }
}
