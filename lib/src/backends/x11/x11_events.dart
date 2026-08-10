/// Turning X events into framework events without intermediate allocations.
///
/// Section 6.5 forbids avoidable allocations per platform event, and X11 is
/// where that rule bites hardest. A window with PointerMotion selected can
/// receive well over a thousand samples a second. The framework pointer event
/// is necessary; an intermediate native event object is not. ConfigureNotify
/// is coalesced further because a window manager can send one per resize pixel.
///
/// The shape that solves both:
///
///   * [X11RawEvent] is a single mutable record, allocated once per backend
///     and overwritten in place for every event drained. Decoding it reads the
///     32-byte X event through byte indexing on a `Pointer<Uint8>`, which the
///     VM compiles to a raw load - no view, no cast, no box.
///   * [X11PendingWindowEvents] accumulates. Ten thousand MotionNotify set no
///     bits at all; four hundred ConfigureNotify set one bit and overwrite two
///     integers. Framework events are constructed once, when the drain is
///     finished, so a resize drag costs one `WindowResizedEvent` per pump
///     rather than one per X event.
///   * [X11EventTranslator] is pure. It touches no FFI and no connection,
///     which is what makes every rule below testable on a machine with no X
///     server - the only way this code gets covered at all, since the CI
///     runner has Xvfb and no window manager.
///
/// The core mouse bootstrap is normalised here. Keyboard input remains
/// deferred to the module that owns XKB keymaps; XInput2 device state,
/// high-resolution scroll axes, selections/clipboard and XDND are also
/// intentionally deferred.
library;

import 'dart:ffi';

import '../../geometry/offset.dart';
import '../../geometry/rect.dart';
import '../../geometry/size.dart';
import '../../platform/input_events.dart';
import '../../platform/window_events.dart';
import 'x11_libc.dart';
import 'x11_protocol.dart';

/// One X event, decoded into fields. Reused; never retained.
///
/// Only the fields this backend reads are decoded. Everything else stays in
/// the native buffer, which is freed as soon as the decode returns.
final class X11RawEvent {
  /// `response_type & 0x7f`.
  int type = 0;

  /// `response_type & 0x80`: the event came from SendEvent, not the server.
  bool synthetic = false;

  /// Byte 1. `detail` for focus and input events, `format` for ClientMessage,
  /// `error_code` for an error.
  int detail = 0;

  int sequence = 0;

  /// Core input timestamp in server milliseconds (a wrapping uint32).
  int timestamp = 0;

  /// The window the event is *about*. For StructureNotify events this is the
  /// `window` field, not the `event` field, which differ when the notification
  /// arrived through SubstructureNotify on a parent.
  int window = 0;

  int x = 0;
  int y = 0;
  int width = 0;
  int height = 0;

  /// Expose `count`: how many more Expose events are still queued for this
  /// contiguous region. Zero means this is the last one.
  int count = 0;

  /// FocusIn/FocusOut `mode`, PropertyNotify `state`.
  int mode = 0;

  /// ClientMessage `type`, PropertyNotify `atom`.
  int atom = 0;

  /// First word of a ClientMessage payload. For WM_PROTOCOLS this is the
  /// protocol atom, which is the only ClientMessage field this backend reads.
  int data0 = 0;

  /// Error only: the request that failed and the resource it named.
  int errorCode = 0;
  int majorOpcode = 0;
  int minorOpcode = 0;
  int resourceId = 0;

  /// Overwrites every field from a 32-byte core X event.
  ///
  /// Field offsets come from the core protocol encoding; they are stable and
  /// have not moved since X11R2. The event is in host byte order because
  /// libxcb converts on the way in.
  void decodeFrom(Pointer<Uint8> event) {
    final responseType = event[0];
    type = responseType & 0x7f;
    synthetic = (responseType & xcbSendEventFlag) != 0;
    detail = event[1];
    sequence = readU16(event, 2);

    // Reset the fields this event type will not write, so a stale value from
    // the previous event cannot be mistaken for a real one.
    x = 0;
    y = 0;
    width = 0;
    height = 0;
    count = 0;
    mode = 0;
    atom = 0;
    data0 = 0;
    timestamp = 0;
    errorCode = 0;
    majorOpcode = 0;
    minorOpcode = 0;
    resourceId = 0;

    switch (type) {
      case xcbError:
        errorCode = detail;
        resourceId = readU32(event, 4);
        minorOpcode = readU16(event, 8);
        majorOpcode = event[10];
        window = resourceId;
      case xcbExpose:
        window = readU32(event, 4);
        x = readI16(event, 8);
        y = readI16(event, 10);
        width = readU16(event, 12);
        height = readU16(event, 14);
        count = readU16(event, 16);
      case xcbConfigureNotify:
        // Byte 4 is `event`, byte 8 is `window`. They differ when the notice
        // arrived via SubstructureNotify on the parent, and the one that
        // identifies whose geometry changed is `window`.
        window = readU32(event, 8);
        x = readI16(event, 16);
        y = readI16(event, 18);
        width = readU16(event, 20);
        height = readU16(event, 22);
      case xcbDestroyNotify:
      case xcbMapNotify:
      case xcbUnmapNotify:
        window = readU32(event, 8);
      case xcbReparentNotify:
        window = readU32(event, 8);
        x = readI16(event, 16);
        y = readI16(event, 18);
      case xcbFocusIn:
      case xcbFocusOut:
        window = readU32(event, 4);
        mode = event[8];
      case xcbPropertyNotify:
        window = readU32(event, 4);
        atom = readU32(event, 8);
        // `state` sits after the 4-byte timestamp at offset 12.
        mode = event[16];
      case xcbClientMessage:
        window = readU32(event, 4);
        atom = readU32(event, 8);
        data0 = readU32(event, 12);
      case xcbMotionNotify:
      case xcbKeyPress:
      case xcbKeyRelease:
      case xcbButtonPress:
      case xcbButtonRelease:
      case xcbEnterNotify:
      case xcbLeaveNotify:
        timestamp = readU32(event, 4);
        window = readU32(event, 12);
        x = readI16(event, 24);
        y = readI16(event, 26);
      default:
        window = readU32(event, 4);
    }
  }

  /// A human-readable line for an error event. Used by the diagnostics ring so
  /// that a failure names the request, not just the code.
  String describeError() => '${x11ErrorName(errorCode)} from '
      '${x11RequestName(majorOpcode)} '
      '(resource 0x${resourceId.toRadixString(16)}, '
      'sequence $sequence, minor $minorOpcode)';
}

/// The per-window protocol state the translator needs, and the geometry it
/// compares against to tell a real change from a repetition.
///
/// Mutable and owned by the window; the translator updates it in place.
final class X11WindowProtocolState {
  X11WindowProtocolState({
    required this.xcbWindow,
    required this.wmProtocols,
    required this.wmDeleteWindow,
    required this.netWmState,
    required this.wmState,
    required this.rootWindow,
  });

  final int xcbWindow;
  final int rootWindow;

  /// Interned atoms. Zero when interning failed, which makes every comparison
  /// against them false - a window whose WM_DELETE_WINDOW could not be
  /// interned simply never reports a close request, rather than reporting one
  /// for every ClientMessage that happens to carry a zero.
  final int wmProtocols;
  final int wmDeleteWindow;
  final int netWmState;
  final int wmState;

  /// Last known client geometry, in device pixels.
  int width = 0;
  int height = 0;
  int originX = 0;
  int originY = 0;

  bool focused = false;
  bool mapped = false;
  bool destroyed = false;

  /// True once the window manager has reparented us. Until then a
  /// non-synthetic ConfigureNotify already carries root-relative coordinates
  /// and no TranslateCoordinates round trip is needed - which is the common
  /// case under Xvfb, where there is no window manager at all.
  bool reparented = false;
}

/// Everything one drain of the event queue decided, before any framework
/// event object exists.
///
/// Every field is a primitive and the object is reused, so accumulating is
/// free. [isEmpty] is the fast exit for the overwhelmingly common case of a
/// pump that saw only input events.
final class X11PendingWindowEvents {
  bool resized = false;
  bool moved = false;
  bool exposed = false;
  bool activationChanged = false;
  bool activated = false;
  bool closeRequested = false;
  bool destroyed = false;

  /// The origin reported by ConfigureNotify was parent-relative, so it has to
  /// be resolved with a TranslateCoordinates round trip before it can be used.
  /// Set at most once per drain, which is the point: roadmap 15.4 says avoid
  /// round trips in input, and this turns one per drag event into one per pump.
  bool originDirty = false;

  /// Something changed that may have changed the scale - the root window's
  /// RESOURCE_MANAGER was rewritten by a settings daemon.
  bool scaleDirty = false;

  /// Union of every Expose rectangle seen this drain, in device pixels.
  int exposeLeft = 0;
  int exposeTop = 0;
  int exposeRight = 0;
  int exposeBottom = 0;

  bool get isEmpty =>
      !resized &&
      !moved &&
      !exposed &&
      !activationChanged &&
      !closeRequested &&
      !destroyed &&
      !originDirty &&
      !scaleDirty;

  void reset() {
    resized = false;
    moved = false;
    exposed = false;
    activationChanged = false;
    activated = false;
    closeRequested = false;
    destroyed = false;
    originDirty = false;
    scaleDirty = false;
    exposeLeft = 0;
    exposeTop = 0;
    exposeRight = 0;
    exposeBottom = 0;
  }

  /// Merges one Expose rectangle into the accumulated union.
  ///
  /// A union rather than a list: X splits an obscured region into up to a
  /// dozen rectangles, and a renderer that repaints their bounding box does
  /// strictly less work than one that allocates a list to describe them
  /// exactly.
  void noteExpose(int x, int y, int width, int height) {
    if (width <= 0 || height <= 0) return;
    if (!exposed) {
      exposed = true;
      exposeLeft = x;
      exposeTop = y;
      exposeRight = x + width;
      exposeBottom = y + height;
      return;
    }
    if (x < exposeLeft) exposeLeft = x;
    if (y < exposeTop) exposeTop = y;
    if (x + width > exposeRight) exposeRight = x + width;
    if (y + height > exposeBottom) exposeBottom = y + height;
  }
}

/// The rules, as pure functions over [X11RawEvent] and the window state.
abstract final class X11EventTranslator {
  /// Normalises the core pointer subset that does not depend on XInput2.
  ///
  /// Core wheel mappings are discrete button pairs. Only the press becomes a
  /// line scroll event; translating the matching release would double every
  /// wheel step. Unknown mappings are consumed by [apply] but do not become a
  /// misleading pointer event.
  static PlatformWindowEvent? translateCorePointer(
    X11RawEvent raw, {
    required NativeWindowId windowId,
    required int generation,
    required double scale,
  }) {
    switch (raw.type) {
      case xcbMotionNotify:
        return PointerMoveEvent(
          windowId: windowId,
          generation: generation,
          timestamp: Duration(milliseconds: raw.timestamp),
          pointerId: 0,
          kind: PointerKind.mouse,
          logicalPosition: Offset(raw.x / scale, raw.y / scale),
        );
      case xcbButtonPress:
      case xcbButtonRelease:
        final scrollDelta =
            raw.type == xcbButtonPress ? _coreScrollDelta(raw.detail) : null;
        if (scrollDelta != null) {
          return PointerScrollEvent(
            windowId: windowId,
            generation: generation,
            timestamp: Duration(milliseconds: raw.timestamp),
            pointerId: 0,
            kind: PointerKind.mouse,
            logicalPosition: Offset(raw.x / scale, raw.y / scale),
            scrollDelta: scrollDelta,
            scrollDeltaUnit: ScrollDeltaUnit.lines,
          );
        }
        final button = _corePointerButton(raw.detail);
        if (button == null) return null;
        return raw.type == xcbButtonPress
            ? PointerDownEvent(
                windowId: windowId,
                generation: generation,
                timestamp: Duration(milliseconds: raw.timestamp),
                pointerId: 0,
                kind: PointerKind.mouse,
                logicalPosition: Offset(raw.x / scale, raw.y / scale),
                button: button,
              )
            : PointerUpEvent(
                windowId: windowId,
                generation: generation,
                timestamp: Duration(milliseconds: raw.timestamp),
                pointerId: 0,
                kind: PointerKind.mouse,
                logicalPosition: Offset(raw.x / scale, raw.y / scale),
                button: button,
              );
      case xcbEnterNotify:
        return WindowPointerEnterEvent(
          windowId: windowId,
          generation: generation,
        );
      case xcbLeaveNotify:
        return WindowPointerLeaveEvent(
          windowId: windowId,
          generation: generation,
        );
      default:
        return null;
    }
  }

  static PointerButton? _corePointerButton(int detail) => switch (detail) {
        1 => PointerButton.primary,
        2 => PointerButton.middle,
        3 => PointerButton.secondary,
        8 => PointerButton.back,
        9 => PointerButton.forward,
        _ => null,
      };

  static Offset? _coreScrollDelta(int detail) => switch (detail) {
        4 => const Offset(0, -1),
        5 => const Offset(0, 1),
        6 => const Offset(-1, 0),
        7 => const Offset(1, 0),
        _ => null,
      };

  /// Applies one decoded event. Sets bits on [pending]; allocates nothing.
  ///
  /// Returns false when the event was not for this window and nothing was
  /// consumed, so the caller can count it - an event for a window that has
  /// already been destroyed is normal (the server was told to destroy it after
  /// it queued the event) and is exactly the class of staleness the generation
  /// token exists for.
  static bool apply(
    X11RawEvent raw,
    X11WindowProtocolState state,
    X11PendingWindowEvents pending,
  ) {
    // PropertyNotify on the root window is about the display, not about us.
    if (raw.type == xcbPropertyNotify && raw.window == state.rootWindow) {
      if (raw.atom == xcbAtomResourceManager) {
        pending.scaleDirty = true;
        return true;
      }
      return false;
    }
    if (raw.window != state.xcbWindow) return false;
    if (state.destroyed) return false;

    switch (raw.type) {
      case xcbConfigureNotify:
        _applyConfigure(raw, state, pending);
        return true;

      case xcbExpose:
        pending.noteExpose(raw.x, raw.y, raw.width, raw.height);
        return true;

      case xcbFocusIn:
      case xcbFocusOut:
        _applyFocus(raw, state, pending);
        return true;

      case xcbClientMessage:
        // WM_PROTOCOLS/WM_DELETE_WINDOW is the only ClientMessage this backend
        // answers. XDND and the selection protocols also arrive here and are
        // deliberately dropped until those modules exist.
        if (raw.detail == 32 &&
            state.wmProtocols != 0 &&
            raw.atom == state.wmProtocols &&
            state.wmDeleteWindow != 0 &&
            raw.data0 == state.wmDeleteWindow) {
          pending.closeRequested = true;
        }
        return true;

      case xcbDestroyNotify:
        state.destroyed = true;
        state.mapped = false;
        pending.destroyed = true;
        // A window that is gone cannot be resized, moved or repainted, and
        // emitting those after a close is precisely the late-callback bug the
        // generation token was introduced for. Drop them here rather than
        // relying on every consumer to check.
        pending.resized = false;
        pending.moved = false;
        pending.exposed = false;
        pending.originDirty = false;
        return true;

      case xcbMapNotify:
        state.mapped = true;
        return true;

      case xcbUnmapNotify:
        state.mapped = false;
        return true;

      case xcbReparentNotify:
        // From now on ConfigureNotify x/y are relative to the frame the window
        // manager put around us, so the origin needs a round trip to resolve.
        state.reparented = true;
        pending.originDirty = true;
        return true;

      case xcbPropertyNotify:
        // _NET_WM_STATE and WM_STATE changed: the maximised/fullscreen/iconic
        // answer is now stale. Reading it needs a round trip, so it is done at
        // flush time and only when something asks.
        return raw.atom == state.netWmState || raw.atom == state.wmState;

      case xcbMotionNotify:
      case xcbKeyPress:
      case xcbKeyRelease:
      case xcbButtonPress:
      case xcbButtonRelease:
      case xcbEnterNotify:
      case xcbLeaveNotify:
        // Consumed, nothing allocated. This is the flood path.
        return true;

      default:
        return true;
    }
  }

  static void _applyConfigure(
    X11RawEvent raw,
    X11WindowProtocolState state,
    X11PendingWindowEvents pending,
  ) {
    if (raw.width != state.width || raw.height != state.height) {
      state.width = raw.width;
      state.height = raw.height;
      pending.resized = true;
    }
    // ICCCM 4.2.3: a window manager that moves a window must send a synthetic
    // ConfigureNotify whose x/y are root-relative. The server's own
    // ConfigureNotify is parent-relative, which is the same thing right up
    // until a reparenting window manager wraps us in a frame.
    if (raw.synthetic || !state.reparented) {
      if (raw.x != state.originX || raw.y != state.originY) {
        state.originX = raw.x;
        state.originY = raw.y;
        pending.moved = true;
      }
      return;
    }
    pending.originDirty = true;
  }

  static void _applyFocus(
    X11RawEvent raw,
    X11WindowProtocolState state,
    X11PendingWindowEvents pending,
  ) {
    // A grab is not a focus change: a menu grabbing the keyboard would
    // otherwise make the window under it flash inactive and back.
    if (raw.mode == xcbNotifyModeGrab || raw.mode == xcbNotifyModeUngrab) {
      return;
    }
    // Pointer-driven notifications describe the pointer, not the keyboard
    // focus, and reporting them as activation makes a window under a
    // focus-follows-mouse policy toggle on every crossing.
    if (raw.detail == xcbNotifyDetailPointer ||
        raw.detail == xcbNotifyDetailPointerRoot) {
      return;
    }
    final focused = raw.type == xcbFocusIn;
    if (focused == state.focused) return;
    state.focused = focused;
    pending.activationChanged = true;
    pending.activated = focused;
  }

  /// Builds the framework events for one drain and hands each to [emit].
  ///
  /// A callback rather than a returned list: the list would be the one
  /// allocation per pump that is easy to avoid, and the caller invariably just
  /// iterates it.
  ///
  /// [generation] is stamped on every event. The caller must have already
  /// invalidated and re-read it if [X11PendingWindowEvents.resized] is set, so
  /// that the resize event carries the generation of the surfaces that were
  /// recreated for it and not the ones it destroyed.
  static void emitPending(
    X11PendingWindowEvents pending, {
    required NativeWindowId windowId,
    required int generation,
    required double scale,
    required int deviceWidth,
    required int deviceHeight,
    required int originX,
    required int originY,
    required void Function(PlatformWindowEvent event) emit,
  }) {
    if (pending.resized) {
      emit(WindowResizedEvent(
        windowId: windowId,
        generation: generation,
        clientSize: Size(deviceWidth / scale, deviceHeight / scale),
        renderScale: scale,
      ));
    }
    if (pending.moved) {
      emit(WindowMovedEvent(
        windowId: windowId,
        generation: generation,
        screenPosition: Offset(originX / scale, originY / scale),
      ));
    }
    if (pending.exposed) {
      emit(WindowExposedEvent(
        windowId: windowId,
        generation: generation,
        dirtyRect: Rect.fromLTRB(
          pending.exposeLeft / scale,
          pending.exposeTop / scale,
          pending.exposeRight / scale,
          pending.exposeBottom / scale,
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
