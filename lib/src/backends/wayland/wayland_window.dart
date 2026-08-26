/// One xdg-shell toplevel behind the framework's [NativeWindow] contract.
///
/// Owns the toplevel's protocol objects, the configure/ack cycle and a
/// retained wl_shm surface rebuilt per configure generation - the same
/// replace-not-mutate shape as `X11Window`.
///
/// ## Where Wayland disagrees with the contract, and what is done about it
///
///   * **No positions.** A Wayland client cannot read or choose its toplevel's
///     screen position; the compositor owns placement. [setBounds] therefore
///     applies the *size* only, [screenToClient]/[clientToScreen] are the
///     identity mapping, and no [WindowMovedEvent] is ever emitted.
///   * **No drawing before configure.** The surface list stays empty until the
///     first `xdg_surface.configure` has been acked; presentation code that
///     asks earlier simply finds no surface, which is the honest state.
///   * **Client-side decorations are not drawn.** Without the xdg-decoration
///     extension the compositor may show no title bar (GNOME); the window is
///     still usable. `WindowOptions.decorated: false` is thus the one option
///     every compositor honours exactly.
library;

import 'dart:async';

import '../../foundation/diagnostics.dart';
import '../../foundation/lifecycle.dart';
import '../../geometry/offset.dart';
import '../../geometry/rect.dart';
import '../../geometry/size.dart';
import '../../platform/compose_sequences.dart';
import '../../platform/native_window.dart';
import '../../platform/window_events.dart';
import '../../rendering/renderer.dart';
import '../../widgets/popup.dart';
import 'wayland_connection.dart';
import 'wayland_events.dart';
import 'wayland_positioner.dart';
import 'wayland_shm.dart';

final class WaylandWindow with DisposableMixin implements NativeWindow {
  WaylandWindow._({
    required WaylandWindowClient client,
    required this.toplevelIds,
    required NativeWindowId id,
    required int logicalWidth,
    required int logicalHeight,
    required bool visible,
    required void Function(WaylandWindow window) onClosed,
    this.isPopup = false,
  })  : _client = client,
        _cpuClient =
            client is WaylandCpuClient ? client as WaylandCpuClient : null,
        _id = id,
        _visible = visible,
        _onClosed = onClosed,
        _protocol = WaylandWindowProtocolState(
          surfaceId: toplevelIds.surfaceId,
          xdgSurfaceId: toplevelIds.xdgSurfaceId,
          toplevelId: toplevelIds.toplevelId,
        ) {
    _protocol
      ..width = logicalWidth
      ..height = logicalHeight
      ..bufferScale = client.bufferScaleHint;
  }

  static WaylandWindow create({
    required WaylandWindowClient client,
    required NativeWindowId id,
    required WindowOptions options,
    required void Function(WaylandWindow window) onClosed,
  }) {
    final width = _clampExtent(options.size.width.round());
    final height = _clampExtent(options.size.height.round());
    final minimum = options.minimumSize;
    final maximum = options.maximumSize;

    // A menu, a combo list or a tooltip becomes a real xdg_popup rather than
    // a second toplevel. That is not a nicety on Wayland: a toplevel gets a
    // taskbar entry and its own activation, and there is no way to position
    // one, so a "popup" built from a toplevel would appear in the middle of
    // the screen with a title bar. Popups need a parent; without one there is
    // nothing to anchor to, so the window falls back to a toplevel and says so
    // through the diagnostic the caller can read.
    final owner = options.owner;
    if (options.kind.isDismissable && owner is WaylandWindow) {
      final request = PopupRequest(
        // No screen position exists on Wayland; the framework's requested
        // position is interpreted parent-relative, which is what an anchor
        // rect is. A zero-size rect at that point is the caret-like anchor
        // WaylandPositionerSpec widens to one pixel.
        anchorRect: Rect.fromLTWH(
          options.position?.dx ?? 0,
          options.position?.dy ?? 0,
          0,
          0,
        ),
        size: Size(width.toDouble(), height.toDouble()),
      );
      final popupIds = client.createPopup(WaylandPopupRequest(
        parent: owner.toplevelIds,
        positioner: WaylandPositionerSpec.fromRequest(request),
        // A tooltip must never grab: a grab takes input away from the window
        // under the pointer, and a tooltip is precisely the popup the user is
        // not interacting with.
        grab: options.kind == WindowKind.popup,
      ));
      return WaylandWindow._(
        client: client,
        toplevelIds: popupIds,
        id: id,
        logicalWidth: width,
        logicalHeight: height,
        visible: options.visible,
        onClosed: onClosed,
        isPopup: true,
      );
    }

    final ids = client.createToplevel(WaylandToplevelRequest(
      width: width,
      height: height,
      title: options.title,
      appId: 'dart_ui',
      resizable: options.resizable,
      minimumWidth:
          minimum == null ? null : _clampExtent(minimum.width.round()),
      minimumHeight:
          minimum == null ? null : _clampExtent(minimum.height.round()),
      maximumWidth:
          maximum == null ? null : _clampExtent(maximum.width.round()),
      maximumHeight:
          maximum == null ? null : _clampExtent(maximum.height.round()),
    ));
    // Ask for a server-side frame when the application wanted a decorated
    // window and the compositor speaks xdg-decoration. Without the protocol
    // (GNOME does not implement it) the answer never comes and
    // [hasServerSideDecorations] stays false, which is the framework's signal
    // to draw the frame itself.
    if (options.decorated) client.requestServerSideDecoration(ids);

    return WaylandWindow._(
      client: client,
      toplevelIds: ids,
      id: id,
      logicalWidth: width,
      logicalHeight: height,
      visible: options.visible,
      onClosed: onClosed,
    );
  }

  final WaylandWindowClient _client;
  final WaylandCpuClient? _cpuClient;
  final NativeWindowId _id;
  final void Function(WaylandWindow window) _onClosed;
  final GenerationToken _generation = GenerationToken();
  final StreamController<PlatformWindowEvent> _events =
      StreamController<PlatformWindowEvent>.broadcast();
  final WaylandPendingWindowEvents _pending = WaylandPendingWindowEvents();
  final WaylandWindowProtocolState _protocol;
  final List<BackendDiagnostic> _diagnostics = <BackendDiagnostic>[];

  WaylandShmSurface? _surface;

  /// The wl_surface/xdg_surface/xdg_toplevel (or xdg_popup) triple this
  /// window is made of.
  final WaylandToplevelIds toplevelIds;

  /// Whether the role object is an `xdg_popup` rather than an
  /// `xdg_toplevel`. A popup has a position, no title and no decorations,
  /// and is dismissed by the compositor rather than closed by the user.
  final bool isPopup;

  bool _visible;
  bool _closedEventEmitted = false;
  SystemCursor _cursor = SystemCursor.arrow;

  /// Whether the pointer is currently over this window, which is what decides
  /// whether this window may set the cursor.
  bool _pointerInside = false;

  /// True between a commit that asked for a `wl_surface.frame` callback and
  /// that callback firing. See [present].
  bool _frameCallbackPending = false;

  /// Damage coalesced while throttled, or null when none is pending.
  Rect? _throttledDamage;

  /// Set when a throttled present asked for a full repaint, which no
  /// rectangle can narrow.
  bool _throttledDamageIsFull = false;

  /// Set by a frame callback that found coalesced damage waiting; emitted as
  /// one expose after the surface for this generation exists.
  bool _replayThrottledExpose = false;
  Rect? _throttledExposeDamage;

  /// The wl_surface protocol id the backend routes raw events by.
  int get surfaceId => toplevelIds.surfaceId;

  /// Whether the compositor draws this window's frame.
  ///
  /// False means the framework must draw its own title bar and borders - the
  /// state on every compositor without `zxdg_decoration_manager_v1`, and on
  /// those that have it but chose client-side mode. It is deliberately a
  /// question the window answers rather than an assumption, because getting it
  /// wrong produces either two title bars or none.
  bool get hasServerSideDecorations => _protocol.serverSideDecorated;

  @override
  NativeWindowId get id => _id;

  @override
  int get generation => _generation.current;

  @override
  Size get clientSize => Size(
        _protocol.width.toDouble(),
        _protocol.height.toDouble(),
      );

  ({int width, int height}) get pixelSize => (
        width: _protocol.width * _protocol.bufferScale,
        height: _protocol.height * _protocol.bufferScale,
      );

  /// Wayland surface coordinates are logical units; DPI rides on the integer
  /// buffer scale, so both scales are that factor.
  @override
  double get renderScale => _protocol.bufferScale.toDouble();

  @override
  double get desktopScale => _protocol.bufferScale.toDouble();

  @override
  WindowState get state => _protocol.fullscreen
      ? WindowState.fullscreen
      : _protocol.maximized
          ? WindowState.maximised
          : WindowState.normal;

  @override
  List<NativeSurfaceDescriptor> get surfaces {
    final surface = _surface;
    return surface == null
        ? const <NativeSurfaceDescriptor>[]
        : <NativeSurfaceDescriptor>[surface];
  }

  WaylandShmSurface? get cpuSurface => _surface;

  List<BackendDiagnostic> get diagnostics =>
      List<BackendDiagnostic>.unmodifiable(_diagnostics);

  @override
  Stream<PlatformWindowEvent> get events => _events.stream;

  /// Records a renderer-side failure against this window.
  void recordRenderDiagnostic(BackendDiagnostic diagnostic) =>
      _record(diagnostic);

  /// Surfaces an asynchronous presenter failure on the window event stream.
  void reportError(Object error, StackTrace stackTrace) {
    if (!_events.isClosed) _events.addError(error, stackTrace);
  }

  SystemCursor get cursor => _cursor;

  @override
  void show() {
    throwIfDisposed();
    if (_visible) return;
    _visible = true;
    // Mapping again means committing a buffer after a fresh configure; asking
    // for a repaint is what produces that commit.
    _pending.exposed = true;
    flushPendingEvents();
  }

  @override
  void hide() {
    throwIfDisposed();
    if (!_visible) return;
    _visible = false;
    _client.hideToplevel(toplevelIds);
  }

  @override
  void close() => dispose();

  @override
  void setTitle(String value) {
    throwIfDisposed();
    // xdg_popup has no title: the request would be an error on the role
    // object, and a menu has nowhere to show one anyway.
    if (isPopup) return;
    _client.setToplevelTitle(toplevelIds, value);
  }

  @override
  void setBounds(Rect bounds) {
    throwIfDisposed();
    // Only the size half is expressible; see the library comment. The client
    // resizes itself by committing a buffer of the new size.
    final width = _clampExtent(bounds.width.round());
    final height = _clampExtent(bounds.height.round());
    if (width == _protocol.width && height == _protocol.height) return;
    _protocol.width = width;
    _protocol.height = height;
    _pending
      ..resized = true
      ..exposed = true;
    flushPendingEvents();
  }

  @override
  void setCursor(SystemCursor cursor) {
    throwIfDisposed();
    _cursor = cursor;
    // Only the window the pointer is actually in may set the cursor: a
    // background window doing so would fight the foreground one for a
    // per-pointer piece of state.
    if (_pointerInside) _client.applyCursor(cursor);
  }

  @override
  void requestRedraw([Rect? dirtyRect]) {
    throwIfDisposed();
    if (!_protocol.configured) return;
    // Wayland has no server-side expose; a redraw request is answered locally
    // by the same event a compositor-driven damage would produce.
    _emit(WindowExposedEvent(
      windowId: id,
      generation: generation,
      dirtyRect: dirtyRect,
    ));
  }

  /// Commits the retained CPU framebuffer to the compositor.
  /// Commits the retained CPU framebuffer, unless the compositor has not yet
  /// released the frame throttle.
  ///
  /// Wayland gives a client exactly one pacing signal - the `wl_surface.frame`
  /// callback, which fires when the compositor wants the *next* frame - and no
  /// blocking swap to hide behind. Committing faster than that signal does not
  /// draw faster: the extra buffers are discarded by the compositor, having
  /// cost a full rasterisation each. So a present that arrives while a frame
  /// callback is still in flight is *coalesced*, not dropped: its damage is
  /// unioned into [_throttledDamage] and replayed as one expose when
  /// [WaylandRawEventType.frameDone] arrives. Nothing is silently lost, and a
  /// mouse-move storm costs one frame per compositor tick.
  BackendDiagnostic? present({Rect? damage}) {
    throwIfDisposed();
    final surface = _surface;
    if (surface == null) {
      const failure = BackendDiagnostic(
        kind: DiagnosticKind.surfaceCreationFailed,
        message: 'no Wayland shm surface to present',
      );
      _record(failure);
      return failure;
    }
    if (_frameCallbackPending) {
      _noteThrottledDamage(damage);
      throttledFrameCount++;
      return null;
    }
    final failure = surface.present(damage: damage);
    if (failure != null) {
      _record(failure);
      return failure;
    }
    // The request only takes effect on a commit, and `present` just made one;
    // asking now attaches the callback to the frame that was committed.
    if (_client.requestFrameCallback(surfaceId) != 0) {
      _frameCallbackPending = true;
      _client.flush();
    }
    return null;
  }

  /// Whether a commit would be coalesced rather than sent right now.
  bool get isFrameThrottled => _frameCallbackPending;

  /// How many presents have been coalesced by the throttle. A diagnostic
  /// counter rather than a silent behaviour, per section 6.6.
  int throttledFrameCount = 0;

  void _noteThrottledDamage(Rect? damage) {
    // A null damage means "everything", and it absorbs every rectangle.
    if (damage == null) {
      _throttledDamageIsFull = true;
      _throttledDamage = null;
      return;
    }
    if (_throttledDamageIsFull) return;
    final existing = _throttledDamage;
    _throttledDamage = existing == null ? damage : existing.union(damage);
  }

  /// No global coordinates exist on Wayland; the identity mapping is the only
  /// honest answer, and popup positioning must use relative protocols.
  @override
  Offset screenToClient(Offset screenPosition) => screenPosition;

  @override
  Offset clientToScreen(Offset clientPosition) => clientPosition;

  /// Dead-key and Compose handling for this window's keyboard, or null.
  ///
  /// Installed by the backend from the machine's own X11 Compose table. Null on
  /// a machine with none, which is the state every keystroke was already in:
  /// the keymap subset produces the character directly and no sequence is ever
  /// pending.
  ///
  /// Per window rather than per connection, because a half-typed sequence must
  /// not survive the keyboard moving to another of this application's windows -
  /// the second half of that dead key was aimed somewhere else.
  ComposeEngine? composeEngine;

  /// Accumulates one decoded event. Called only by the owning backend.
  bool handleRawEvent(WaylandRawEvent raw) {
    if (isDisposed) return false;
    final consumed = WaylandEventTranslator.apply(raw, _protocol, _pending);
    if (!consumed) return false;
    if (raw.type == WaylandRawEventType.pointerEnter) {
      _pointerInside = true;
      // The cursor is per-enter state: a pointer that re-entered without a
      // set_cursor shows the compositor's default, so this window's choice is
      // re-asserted on every crossing.
      _client.applyCursor(_cursor);
    } else if (raw.type == WaylandRawEventType.pointerLeave) {
      _pointerInside = false;
    }
    final pointerEvent = WaylandEventTranslator.translatePointer(
      raw,
      windowId: id,
      generation: generation,
    );
    if (pointerEvent != null) _emit(pointerEvent);
    if (raw.type == WaylandRawEventType.keyboardKey) {
      WaylandEventTranslator.translateKey(
        raw,
        windowId: id,
        generation: generation,
        keymap: _client.keymap,
        modifiers: _client.modifiers,
        emit: _emit,
        compose: composeEngine,
      );
    }
    return true;
  }

  /// Resolves coalesced state: acks the newest configure, rebuilds the shm
  /// surface when geometry or scale changed, and emits at most one event of
  /// each kind.
  void flushPendingEvents() {
    if (isDisposed || _pending.isEmpty) return;
    if (_pending.scaleDirty) {
      final scale = _client.bufferScaleHint;
      if (scale != _protocol.bufferScale) {
        _protocol.bufferScale = scale;
        _pending
          ..resized = true
          ..exposed = true;
        _emitScaleChange = true;
      }
      _pending.scaleDirty = false;
    }
    if (_pending.ackSerial >= 0) {
      _client.ackConfigure(toplevelIds, _pending.ackSerial);
      _pending.ackSerial = -1;
    }
    if (_pending.frameDone) {
      _pending.frameDone = false;
      _frameCallbackPending = false;
      // Whatever was coalesced while throttled becomes one expose, which is
      // what the presenter already knows how to answer with a re-commit.
      if (_throttledDamageIsFull || _throttledDamage != null) {
        _replayThrottledExpose = true;
        _throttledExposeDamage =
            _throttledDamageIsFull ? null : _throttledDamage;
        _throttledDamage = null;
        _throttledDamageIsFull = false;
      }
    }
    final destroyed = _pending.destroyed;
    final needsSurface = _protocol.configured &&
        _surface == null &&
        !destroyed &&
        (_pending.resized || _pending.exposed);
    if (_pending.resized || needsSurface || destroyed) {
      _generation.invalidate();
      if (destroyed) {
        _releaseSurface();
      } else {
        _rebuildSurface();
      }
    }
    if (_emitScaleChange) {
      _emitScaleChange = false;
      _emit(WindowScaleChangedEvent(
        windowId: id,
        generation: generation,
        renderScale: renderScale,
        desktopScale: desktopScale,
      ));
    }
    WaylandEventTranslator.emitPending(
      _pending,
      windowId: id,
      generation: generation,
      logicalWidth: _protocol.width,
      logicalHeight: _protocol.height,
      renderScale: renderScale,
      emit: _emit,
      popupX: _protocol.popupX,
      popupY: _protocol.popupY,
    );
    // popup_done means the surface is already unmapped by the compositor, so
    // the window follows it into teardown rather than lingering as a live
    // object nothing can present to.
    final dismissed = _pending.popupDismissed;
    if (dismissed) _closedEventEmitted = true;
    if (_replayThrottledExpose && !destroyed) {
      final damage = _throttledExposeDamage;
      _replayThrottledExpose = false;
      _throttledExposeDamage = null;
      _emit(WindowExposedEvent(
        windowId: id,
        generation: generation,
        dirtyRect: damage,
      ));
    }
    if (destroyed) _closedEventEmitted = true;
    _pending.reset();
    if (destroyed || dismissed) dispose();
  }

  bool _emitScaleChange = false;

  void _emit(PlatformWindowEvent event) {
    if (!_events.isClosed) _events.add(event);
  }

  void _rebuildSurface() {
    _releaseSurface();
    final client = _cpuClient;
    if (client == null || !client.supportsShmPresentation || isDisposed) return;
    if (!_protocol.configured ||
        _protocol.destroyed ||
        _protocol.width <= 0 ||
        _protocol.height <= 0) {
      return;
    }
    try {
      _surface = WaylandShmSurface.create(
        client: client,
        surfaceId: surfaceId,
        pixelWidth: _protocol.width * _protocol.bufferScale,
        pixelHeight: _protocol.height * _protocol.bufferScale,
        scale: renderScale,
        bufferScale: _protocol.bufferScale,
        generation: generation,
      );
    } on Object catch (error) {
      _record(BackendDiagnostic(
        kind: DiagnosticKind.surfaceCreationFailed,
        message: 'failed to create Wayland shm surface',
        detail: '$error',
      ));
    }
  }

  void _releaseSurface() {
    _surface?.dispose();
    _surface = null;
  }

  void _record(BackendDiagnostic diagnostic) {
    if (_diagnostics.length >= 64) _diagnostics.removeAt(0);
    _diagnostics.add(diagnostic);
  }

  @override
  void onDispose() {
    _releaseSurface();
    if (!_protocol.destroyed) {
      _generation.invalidate();
      _client.destroyToplevel(toplevelIds);
      _protocol.destroyed = true;
    }
    if (!_closedEventEmitted) {
      _closedEventEmitted = true;
      _emit(WindowClosedEvent(windowId: id, generation: generation));
    }
    _events.close();
    _onClosed(this);
  }

  @override
  String toString() => 'WaylandWindow(id: ${id.value}, '
      'surface: $surfaceId, '
      '${_protocol.width}x${_protocol.height} @ ${_protocol.bufferScale}x)';

  /// xdg_toplevel sizes are signed 32-bit, but anything beyond the shm buffer
  /// ceiling could never be presented; one clamp serves both.
  static int _clampExtent(int value) => value < 1
      ? 1
      : value > 0x7fff
          ? 0x7fff
          : value;
}
