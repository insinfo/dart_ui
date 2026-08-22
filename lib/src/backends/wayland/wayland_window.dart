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
import '../../platform/native_window.dart';
import '../../platform/window_events.dart';
import '../../rendering/renderer.dart';
import 'wayland_connection.dart';
import 'wayland_events.dart';
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
  })  : _client = client,
        _cpuClient = client is WaylandCpuClient ? client as WaylandCpuClient : null,
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
    final ids = client.createToplevel(WaylandToplevelRequest(
      width: width,
      height: height,
      title: options.title,
      appId: 'dart_ui',
      resizable: options.resizable,
      minimumWidth: minimum == null ? null : _clampExtent(minimum.width.round()),
      minimumHeight:
          minimum == null ? null : _clampExtent(minimum.height.round()),
      maximumWidth: maximum == null ? null : _clampExtent(maximum.width.round()),
      maximumHeight:
          maximum == null ? null : _clampExtent(maximum.height.round()),
    ));
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

  /// The wl_surface/xdg_surface/xdg_toplevel triple this window is made of.
  final WaylandToplevelIds toplevelIds;

  bool _visible;
  bool _closedEventEmitted = false;
  SystemCursor _cursor = SystemCursor.arrow;

  /// The wl_surface protocol id the backend routes raw events by.
  int get surfaceId => toplevelIds.surfaceId;

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
    // The cursor-shape/wl_cursor surface work is deferred; remembering the
    // request keeps the contract deterministic without pretending a native
    // cursor was installed - the same posture the X11 backend takes.
    _cursor = cursor;
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
    final failure = surface.present(damage: damage);
    if (failure != null) _record(failure);
    return failure;
  }

  /// No global coordinates exist on Wayland; the identity mapping is the only
  /// honest answer, and popup positioning must use relative protocols.
  @override
  Offset screenToClient(Offset screenPosition) => screenPosition;

  @override
  Offset clientToScreen(Offset clientPosition) => clientPosition;

  /// Accumulates one decoded event. Called only by the owning backend.
  bool handleRawEvent(WaylandRawEvent raw) {
    if (isDisposed) return false;
    final consumed = WaylandEventTranslator.apply(raw, _protocol, _pending);
    if (!consumed) return false;
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
    );
    if (destroyed) _closedEventEmitted = true;
    _pending.reset();
    if (destroyed) dispose();
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
