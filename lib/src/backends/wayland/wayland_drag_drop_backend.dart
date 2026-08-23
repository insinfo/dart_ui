/// The shared drag-and-drop port, over the Wayland state machine.
///
/// [WaylandDragDropManager] speaks the protocol and knows about surfaces;
/// `lib/src/platform/drag_drop.dart` speaks about windows and handlers and
/// knows nothing about Wayland. This file is the seam between them, and it is
/// small on purpose - everything with a protocol rule in it stayed in the
/// manager, and what is here is bookkeeping the port asks for and the protocol
/// does not have:
///
///   * **one handler per window, from a manager that has one handler.**
///     `wl_data_device` is per *seat*, not per surface: there is a single
///     stream of enter/motion/leave/drop for the whole client and the surface
///     is a field inside it. The port registers per window, so the router
///     below installs itself as the manager's one handler and fans out.
///   * **surface ids to window ids.** The manager asks the backend to resolve
///     them because it cannot; the registrations are the table.
///   * **a future that completes when a drag this client started ends.**
///     Three different events end a drag and all three reach the manager's
///     teardown, which is why the manager reports it once instead of the
///     backend watching for three.
library;

import 'dart:async';
import 'dart:typed_data';

import '../../platform/drag_drop.dart';
import '../../platform/native_window.dart';
import '../../platform/window_events.dart';
import 'wayland_drag_drop.dart';
import 'wayland_window.dart';

/// Drag and drop for the Wayland backend.
///
/// Handed out by `WaylandWindowingBackend.dragAndDrop` once the compositor has
/// been found to expose a usable `wl_data_device_manager`; when it has not, the
/// backend returns an [UnavailableDragDrop] naming that instead, so a failure
/// keeps its explanation.
final class WaylandDragDropBackend implements DragDropBackend {
  WaylandDragDropBackend(this._manager) {
    _manager
      ..handler = _router
      ..windowIdForSurface = _windowIdForSurface
      ..onSourceDragEnded = _onSourceDragEnded;
  }

  final WaylandDragDropManager _manager;

  late final _WaylandDropRouter _router = _WaylandDropRouter(this);

  /// Live registrations, by the two keys they are looked up under: the surface
  /// the protocol reports, and the window the port names.
  final Map<int, _WaylandDropTargetRegistration> _bySurface =
      <int, _WaylandDropTargetRegistration>{};
  final Map<NativeWindowId, _WaylandDropTargetRegistration> _byWindow =
      <NativeWindowId, _WaylandDropTargetRegistration>{};

  /// The drag this client started, waiting for the compositor to say how it
  /// ended. Null when no drag of ours is in flight.
  Completer<DragAction>? _pendingDrag;

  @override
  String get name => 'wayland';

  @override
  bool get canStartDrag => _manager.supportsDragAndDrop;

  @override
  Future<DropTargetRegistration> registerDropTarget({
    required NativeWindow window,
    required DropTargetHandler handler,
  }) async {
    if (window is! WaylandWindow) {
      throw DragDropException(
        operation: 'registerDropTarget',
        backend: name,
        reason: 'a Wayland drop target is a wl_surface and '
            '${window.runtimeType} has none',
      );
    }
    if (!_manager.supportsDragAndDrop) {
      throw DragDropException(
        operation: 'registerDropTarget',
        backend: name,
        reason: 'the compositor exposes no usable wl_data_device_manager, so '
            'no drop can ever be delivered',
      );
    }
    final int surfaceId = window.surfaceId;
    final _WaylandDropTargetRegistration? existing = _bySurface[surfaceId];
    if (existing != null && existing.isActive) {
      // Named rather than silently replaced: a second registration that
      // shadowed the first would send drops to a handler whose owner believes
      // it is still registered, which is the bug `RegisterDragDrop` refuses
      // with DRAGDROP_E_ALREADYREGISTERED for the same reason.
      throw DragDropException(
        operation: 'registerDropTarget',
        backend: name,
        reason: 'wl_surface $surfaceId already has a drop target; revoke it '
            'before registering another',
      );
    }
    final _WaylandDropTargetRegistration registration =
        _WaylandDropTargetRegistration(
      backend: this,
      windowId: window.id,
      surfaceId: surfaceId,
      handler: handler,
    );
    _bySurface[surfaceId] = registration;
    _byWindow[window.id] = registration;
    return registration;
  }

  @override
  Future<DragAction> startDrag(DragRequest request) async {
    final NativeWindow window = request.window;
    if (window is! WaylandWindow) {
      throw DragDropException(
        operation: 'startDrag',
        backend: name,
        reason: 'wl_data_device.start_drag needs the origin wl_surface and '
            '${window.runtimeType} has none',
      );
    }
    if (!_manager.supportsDragAndDrop) {
      throw DragDropException(
        operation: 'startDrag',
        backend: name,
        reason: 'the compositor exposes no usable wl_data_device_manager',
      );
    }

    // Every format is materialised here, before the drag exists.
    // `wl_data_source.send` hands over a file descriptor and expects this
    // process to write and close it there and then; a provider that awaited
    // would leave the destination blocked on a pipe with no writer for as long
    // as the transfer took, which the user sees as the *other* application
    // hanging. A DragData that is expensive to produce pays for it once, here,
    // instead of on the input path.
    final Map<String, Uint8List> payload = <String, Uint8List>{};
    for (final String format in request.data.formats) {
      final Uint8List? bytes = await request.data.readBytes(format);
      if (bytes != null) payload[format] = bytes;
    }
    if (payload.isEmpty) {
      throw DragDropException(
        operation: 'startDrag',
        backend: name,
        reason: 'none of the ${request.data.formats.length} offered format(s) '
            'produced any bytes, so there is nothing to drag',
      );
    }

    // TODO(wayland): DragRequest.feedback is not honoured. A drag icon is a
    // wl_surface with an shm buffer committed to it, which needs the
    // compositor and shm seams the drag client interface does not expose;
    // iconSurfaceId stays 0 and the compositor draws its own cursor. Ignoring
    // it is the documented degradation, not a silent one.
    final bool started = _manager.startDrag(
      originSurfaceId: window.surfaceId,
      mimeTypes: payload.keys.toList(growable: false),
      provider: (String mime) => payload[mime],
      actions: request.allowedActions,
    );
    if (!started) {
      throw DragDropException(
        operation: 'startDrag',
        backend: name,
        reason: 'the compositor refused start_drag; a Wayland drag must begin '
            'from a real gesture, so there must be an input serial',
      );
    }
    final Completer<DragAction> completer = Completer<DragAction>();
    _pendingDrag = completer;
    return completer.future;
  }

  NativeWindowId _windowIdForSurface(int surfaceId) =>
      _bySurface[surfaceId]?.windowId ?? NativeWindowId(surfaceId);

  _WaylandDropTargetRegistration? _registrationFor(NativeWindowId windowId) {
    final _WaylandDropTargetRegistration? registration = _byWindow[windowId];
    return registration != null && registration.isActive ? registration : null;
  }

  void _forget(_WaylandDropTargetRegistration registration) {
    if (identical(_bySurface[registration.surfaceId], registration)) {
      _bySurface.remove(registration.surfaceId);
    }
    if (identical(_byWindow[registration.windowId], registration)) {
      _byWindow.remove(registration.windowId);
    }
    if (identical(_router.active, registration)) _router.active = null;
  }

  void _onSourceDragEnded(DragAction action) {
    final Completer<DragAction>? pending = _pendingDrag;
    _pendingDrag = null;
    if (pending != null && !pending.isCompleted) pending.complete(action);
  }

  @override
  String toString() =>
      'WaylandDragDropBackend(${_bySurface.length} drop target(s))';
}

/// The manager's single handler, fanned out to one handler per window.
final class _WaylandDropRouter implements DropTargetHandler {
  _WaylandDropRouter(this._backend);

  final WaylandDragDropBackend _backend;

  /// The registration the current drag entered, remembered because `motion`,
  /// `leave` and `drop` do not name a surface - only `enter` does.
  _WaylandDropTargetRegistration? active;

  @override
  DropResponse onDragEnter(DragSessionEvent event) {
    final _WaylandDropTargetRegistration? registration =
        _backend._registrationFor(event.windowId);
    active = registration;
    if (registration == null) return const DropResponse.reject();
    return registration.handler.onDragEnter(event);
  }

  @override
  DropResponse onDragOver(DragSessionEvent event) {
    final _WaylandDropTargetRegistration? registration = active;
    if (registration == null || !registration.isActive) {
      return const DropResponse.reject();
    }
    return registration.handler.onDragOver(event);
  }

  @override
  void onDragLeave() {
    final _WaylandDropTargetRegistration? registration = active;
    active = null;
    if (registration != null && registration.isActive) {
      registration.handler.onDragLeave();
    }
  }

  @override
  Future<DragAction> onDrop(DragSessionEvent event) async {
    final _WaylandDropTargetRegistration? registration = active;
    active = null;
    if (registration == null || !registration.isActive) return DragAction.none;
    return registration.handler.onDrop(event);
  }
}

final class _WaylandDropTargetRegistration implements DropTargetRegistration {
  _WaylandDropTargetRegistration({
    required this.backend,
    required this.windowId,
    required this.surfaceId,
    required this.handler,
  });

  final WaylandDragDropBackend backend;

  @override
  final NativeWindowId windowId;

  /// The `wl_surface` the compositor names in `enter`.
  final int surfaceId;

  final DropTargetHandler handler;

  bool _active = true;

  @override
  bool get isActive => _active;

  @override
  Future<void> revoke() async {
    // Idempotent: a window teardown and an explicit revoke race by design, and
    // the port says so.
    if (!_active) return;
    _active = false;
    backend._forget(this);
  }

  @override
  String toString() => 'WaylandDropTargetRegistration(window '
      '${windowId.value}, wl_surface $surfaceId, '
      '${_active ? "active" : "revoked"})';
}
