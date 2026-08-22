/// One connection to a Wayland compositor, and everything that hangs off it.
///
/// The connection owns the transport, the object id space, the bound globals,
/// the seat devices and the shm pools. Windows borrow it; they never open
/// their own - the registry, the seat focus and the keymap are per-connection
/// state that two connections could not share.
///
/// The protocol work happens in three layers, none of which touch FFI:
///
///   * `wayland_wire.dart` turns messages into bytes and back;
///   * this file knows which object an event belongs to and either consumes
///     it (registry, shm formats, callbacks, ping, keymap, focus bookkeeping)
///     or hands it to the backend as a [WaylandRawEvent];
///   * `wayland_events.dart` turns raw events into framework events.
///
/// Only the injected [WaylandTransport] and [WaylandShmAllocator] are native,
/// which is what makes the whole protocol machine - including the
/// registry handshake and fd passing - testable with an in-memory fake
/// compositor.
library;

import 'dart:typed_data';

import '../../foundation/diagnostics.dart';
import '../../foundation/lifecycle.dart';
import '../../rendering/framebuffer.dart';
import 'wayland_events.dart';
import 'wayland_keymap.dart';
import 'wayland_protocol.dart';
import 'wayland_shm.dart';
import 'wayland_transport.dart';
import 'wayland_wire.dart';

/// The connection surface the backend itself needs; kept smaller than
/// [WaylandConnection] so ownership and probing are testable without a
/// compositor, the same split `X11BackendConnection` draws.
abstract interface class WaylandBackendConnection implements Disposable {
  bool get isValid;

  /// Interface names the registry advertised, for probe diagnostics.
  Set<String> get globalInterfaces;

  bool signalWake();
}

/// Window and event operations exposed by a production Wayland connection.
abstract interface class WaylandWindowClient
    implements WaylandBackendConnection {
  WaylandToplevelIds createToplevel(WaylandToplevelRequest request);
  void destroyToplevel(WaylandToplevelIds ids);
  void setToplevelTitle(WaylandToplevelIds ids, String title);
  void ackConfigure(WaylandToplevelIds ids, int serial);
  void hideToplevel(WaylandToplevelIds ids);

  bool pollEventInto(WaylandRawEvent target);
  bool waitForActivity(int timeoutMilliseconds);
  int flush();
  void recordError(String message);

  /// The active keymap, or null when the compositor sent none yet.
  WaylandXkbKeymap? get keymap;

  /// The live modifier state fed by `wl_keyboard.modifiers`.
  WaylandModifiersState get modifiers;

  /// The integer buffer scale windows should render at: the largest
  /// `wl_output.scale` seen, 1 until any output reports.
  int get bufferScaleHint;
}

/// Everything needed to create one toplevel, in logical (surface) units.
final class WaylandToplevelRequest {
  const WaylandToplevelRequest({
    required this.width,
    required this.height,
    required this.title,
    required this.appId,
    required this.resizable,
    this.minimumWidth,
    this.minimumHeight,
    this.maximumWidth,
    this.maximumHeight,
  });

  final int width;
  final int height;
  final String title;
  final String appId;
  final bool resizable;
  final int? minimumWidth;
  final int? minimumHeight;
  final int? maximumWidth;
  final int? maximumHeight;
}

/// The three protocol objects one toplevel window is made of.
final class WaylandToplevelIds {
  const WaylandToplevelIds({
    required this.surfaceId,
    required this.xdgSurfaceId,
    required this.toplevelId,
  });

  final int surfaceId;
  final int xdgSurfaceId;
  final int toplevelId;

  @override
  String toString() => 'WaylandToplevelIds(surface: $surfaceId, '
      'xdg_surface: $xdgSurfaceId, toplevel: $toplevelId)';
}

/// The outcome of trying to open a display connection.
final class WaylandConnectionAttempt {
  const WaylandConnectionAttempt({
    required this.connection,
    required this.diagnostics,
  });

  final WaylandBackendConnection? connection;
  final List<BackendDiagnostic> diagnostics;

  bool get succeeded => connection != null;
}

/// What kind of protocol object a client-side id currently names.
enum _ObjectKind {
  registry,
  callback,
  compositor,
  shm,
  shmPool,
  buffer,
  surface,
  seat,
  pointer,
  keyboard,
  output,
  xdgWmBase,
  xdgSurface,
  xdgToplevel,
}

/// A live Wayland display connection.
final class WaylandConnection
    with DisposableMixin
    implements WaylandWindowClient, WaylandCpuClient {
  WaylandConnection._(this._transport, this._allocator);

  /// Performs the registry handshake, or reports exactly what stopped it.
  ///
  /// Never throws. Two roundtrips: one to enumerate globals, one to settle
  /// the binds (shm formats, seat capabilities, output scales).
  static WaylandConnectionAttempt open({
    required WaylandTransport transport,
    required WaylandShmAllocator allocator,
  }) {
    final diagnostics = <BackendDiagnostic>[];
    final connection = WaylandConnection._(transport, allocator);
    bool ready;
    try {
      ready = connection._initialise(diagnostics);
    } on Object catch (error) {
      diagnostics.add(BackendDiagnostic(
        kind: DiagnosticKind.connectionFailed,
        message: 'failed to initialise Wayland connection',
        detail: '$error',
      ));
      ready = false;
    }
    if (!ready) {
      try {
        connection.dispose();
      } on Object catch (error) {
        diagnostics.add(BackendDiagnostic(
          kind: DiagnosticKind.connectionFailed,
          message: 'failed to close rejected Wayland connection',
          detail: '$error',
        ));
      }
      return WaylandConnectionAttempt(
        connection: null,
        diagnostics: diagnostics,
      );
    }
    return WaylandConnectionAttempt(
      connection: connection,
      diagnostics: diagnostics,
    );
  }

  final WaylandTransport _transport;
  final WaylandShmAllocator _allocator;

  final WaylandMessageWriter _writer = WaylandMessageWriter();
  final WaylandWireDecoder _decoder = WaylandWireDecoder();
  final WaylandWireMessage _message = WaylandWireMessage();
  final List<int> _receivedFds = <int>[];

  /// The last few protocol errors, newest last. Bounded, like the X11 ring.
  final List<String> recentErrors = <String>[];
  static const int _maxRecordedErrors = 32;

  // Object id space. Ids are recycled only after the server confirms them
  // gone via wl_display.delete_id - reusing earlier races the confirmation.
  int _nextId = wlClientIdMinimum;
  final List<int> _freeIds = <int>[];
  final Map<int, _ObjectKind> _objects = <int, _ObjectKind>{};

  // Globals, as advertised by the registry.
  final Map<int, ({String interface, int version})> _globalsByName =
      <int, ({String interface, int version})>{};
  @override
  final Set<String> globalInterfaces = <String>{};

  int _registryId = 0;
  int _compositorId = 0;
  int _compositorVersion = 0;
  int _shmId = 0;
  int _seatId = 0;
  int _wmBaseId = 0;

  /// wl_shm formats the compositor advertised.
  final Set<int> _shmFormats = <int>{};

  // Seat devices.
  int _pointerId = 0;
  int _keyboardId = 0;

  // Input focus, resolved so motion/key events can carry their surface.
  int _pointerFocusSurfaceId = 0;
  int _keyboardFocusSurfaceId = 0;
  double _pointerX = 0;
  double _pointerY = 0;

  @override
  WaylandXkbKeymap? keymap;

  /// Why the fallback keymap was chosen, when it was; probe/diagnostic text.
  String? keymapNote;

  @override
  final WaylandModifiersState modifiers = WaylandModifiersState();

  /// `wl_keyboard.repeat_info`, stored for a future repeat timer. No repeat
  /// events are synthesised yet; that limitation is documented in the backend.
  int repeatRateHz = 0;
  int repeatDelayMilliseconds = 0;

  // Outputs and their integer scales.
  final Map<int, int> _outputScales = <int, int>{};

  // Toplevel routing: every xdg object resolves back to its wl_surface.
  final Map<int, int> _surfaceByXdgSurface = <int, int>{};
  final Map<int, int> _surfaceByToplevel = <int, int>{};

  // Live shm buffers by wl_buffer id.
  final Map<int, _WaylandNativeShmBuffer> _buffersById =
      <int, _WaylandNativeShmBuffer>{};

  // Callbacks whose done event arrived.
  final Set<int> _completedCallbacks = <int>{};

  // Window-relevant events decoded while something else was being waited for
  // (a roundtrip during init or resize). Drained first by [pollEventInto].
  final List<WaylandRawEvent> _queuedEvents = <WaylandRawEvent>[];

  bool _protocolError = false;

  @override
  bool get isValid => !isDisposed && !_protocolError && _transport.isOpen;

  int get compositorVersion => _compositorVersion;

  Set<int> get shmFormats => Set<int>.unmodifiable(_shmFormats);

  @override
  int get bufferScaleHint {
    var scale = 1;
    for (final value in _outputScales.values) {
      if (value > scale) scale = value;
    }
    return scale;
  }

  // -------------------------------------------------------------------------
  // Bootstrap
  // -------------------------------------------------------------------------

  bool _initialise(List<BackendDiagnostic> diagnostics) {
    _registryId = _allocateId(_ObjectKind.registry);
    _writer.begin(wlDisplayObjectId, wlDisplayRequestGetRegistry);
    _writer.putNewId(_registryId);
    _queueMessage();

    if (!_roundtrip()) {
      diagnostics.add(const BackendDiagnostic(
        kind: DiagnosticKind.connectionFailed,
        message: 'Wayland registry roundtrip failed',
        detail: 'the compositor closed or never answered wl_display.sync',
      ));
      return false;
    }

    _bindGlobals(diagnostics);
    if (_compositorId == 0 || _wmBaseId == 0) {
      diagnostics.add(BackendDiagnostic(
        kind: DiagnosticKind.connectionFailed,
        message: 'compositor lacks required globals',
        detail: 'wl_compositor=${_compositorId != 0}, '
            'xdg_wm_base=${_wmBaseId != 0}; advertised: '
            '${(globalInterfaces.toList()..sort()).join(', ')}',
      ));
      return false;
    }

    // Settle the binds: shm formats, seat capabilities, output scales.
    if (!_roundtrip()) {
      diagnostics.add(const BackendDiagnostic(
        kind: DiagnosticKind.connectionFailed,
        message: 'Wayland bind roundtrip failed',
      ));
      return false;
    }

    diagnostics.add(BackendDiagnostic.note(
      'Wayland globals bound',
      detail: 'compositor v$_compositorVersion, '
          'shm=${_shmId != 0 ? "yes" : "no"}, seat=${_seatId != 0 ? "yes" : "no"}, '
          'outputs=${_outputScales.length}, scale=$bufferScaleHint',
    ));
    diagnostics.add(BackendDiagnostic.note(
      supportsShmPresentation
          ? 'wl_shm ARGB8888 presentation is available'
          : 'wl_shm ARGB8888 presentation is unavailable',
      detail: _shmId == 0
          ? 'wl_shm was not advertised'
          : !_allocator.isAvailable
              ? 'anonymous shared memory (memfd_create) is unavailable'
              : 'formats=${(_shmFormats.toList()..sort()).join(',')}',
    ));
    if (keymapNote != null) {
      diagnostics.add(BackendDiagnostic.note(keymapNote!));
    }
    return true;
  }

  void _bindGlobals(List<BackendDiagnostic> diagnostics) {
    for (final entry in _globalsByName.entries) {
      final name = entry.key;
      final interface = entry.value.interface;
      final version = entry.value.version;
      switch (interface) {
        case wlCompositorInterfaceName:
          if (_compositorId != 0) break;
          _compositorVersion =
              version < wlCompositorBindVersion ? version : wlCompositorBindVersion;
          _compositorId =
              _bind(name, interface, _compositorVersion, _ObjectKind.compositor);
        case wlShmInterfaceName:
          if (_shmId != 0) break;
          _shmId = _bind(name, interface, wlShmBindVersion, _ObjectKind.shm);
        case wlSeatInterfaceName:
          if (_seatId != 0) break;
          final bindVersion =
              version < wlSeatBindVersion ? version : wlSeatBindVersion;
          _seatId = _bind(name, interface, bindVersion, _ObjectKind.seat);
        case wlOutputInterfaceName:
          final bindVersion =
              version < wlOutputBindVersion ? version : wlOutputBindVersion;
          final outputId =
              _bind(name, interface, bindVersion, _ObjectKind.output);
          _outputScales[outputId] = 1;
        case xdgWmBaseInterfaceName:
          if (_wmBaseId != 0) break;
          _wmBaseId =
              _bind(name, interface, xdgWmBaseBindVersion, _ObjectKind.xdgWmBase);
      }
    }
    if (_seatId == 0) {
      diagnostics.add(const BackendDiagnostic.note(
        'compositor advertised no wl_seat; no input will arrive',
      ));
    }
  }

  int _bind(int name, String interface, int version, _ObjectKind kind) {
    final id = _allocateId(kind);
    _writer.begin(_registryId, wlRegistryRequestBind);
    _writer.putUint(name);
    _writer.putString(interface);
    _writer.putUint(version);
    _writer.putNewId(id);
    _queueMessage();
    return id;
  }

  // -------------------------------------------------------------------------
  // Object ids
  // -------------------------------------------------------------------------

  int _allocateId(_ObjectKind kind) {
    final id = _freeIds.isNotEmpty ? _freeIds.removeLast() : _nextId++;
    if (id > wlClientIdMaximum) {
      throw StateError('Wayland client object id space exhausted');
    }
    _objects[id] = kind;
    return id;
  }

  void _forgetObject(int id) {
    _objects.remove(id);
  }

  // -------------------------------------------------------------------------
  // Sync / roundtrip
  // -------------------------------------------------------------------------

  /// Sends `wl_display.sync` and pumps until its callback fires. Window
  /// events decoded meanwhile are queued, not lost.
  bool _roundtrip({int timeoutMilliseconds = 5000}) {
    final callbackId = _allocateId(_ObjectKind.callback);
    _writer.begin(wlDisplayObjectId, wlDisplayRequestSync);
    _writer.putNewId(callbackId);
    _queueMessage();
    if (flush() < 0) return false;

    final deadline =
        DateTime.now().add(Duration(milliseconds: timeoutMilliseconds));
    while (!_completedCallbacks.remove(callbackId)) {
      if (!isValid) return false;
      if (_decoder.nextMessage(_message)) {
        _dispatchMessage(_message, null);
        continue;
      }
      final received = _transport.receive(_decoder, _receivedFds);
      if (received < 0) return false;
      if (received == 0) {
        final remaining = deadline.difference(DateTime.now()).inMilliseconds;
        if (remaining <= 0) {
          recordError('wl_display.sync timed out after '
              '${timeoutMilliseconds}ms');
          return false;
        }
        _transport.waitForActivity(remaining > 50 ? 50 : remaining);
      }
    }
    return true;
  }

  // -------------------------------------------------------------------------
  // Event pump
  // -------------------------------------------------------------------------

  @override
  bool pollEventInto(WaylandRawEvent target) {
    throwIfDisposed();
    if (_queuedEvents.isNotEmpty) {
      _copyEvent(_queuedEvents.removeAt(0), target);
      return true;
    }
    while (true) {
      if (_decoder.nextMessage(_message)) {
        target.reset();
        if (_dispatchMessage(_message, target)) return true;
        continue;
      }
      final received = _transport.receive(_decoder, _receivedFds);
      if (received <= 0) return false;
    }
  }

  @override
  bool waitForActivity(int timeoutMilliseconds) {
    if (isDisposed) return false;
    if (_decoder.bufferedBytes > 0 || _queuedEvents.isNotEmpty) return false;
    return _transport.waitForActivity(timeoutMilliseconds);
  }

  @override
  int flush() {
    if (isDisposed) return -1;
    return _transport.flush() ? 1 : -1;
  }

  @override
  bool signalWake() => _transport.signalWake();

  @override
  void recordError(String message) {
    recentErrors.add(message);
    if (recentErrors.length > _maxRecordedErrors) {
      recentErrors.removeAt(0);
    }
  }

  void _copyEvent(WaylandRawEvent from, WaylandRawEvent to) {
    to
      ..type = from.type
      ..surfaceId = from.surfaceId
      ..serial = from.serial
      ..timeMilliseconds = from.timeMilliseconds
      ..width = from.width
      ..height = from.height
      ..key = from.key
      ..state = from.state
      ..axis = from.axis
      ..x = from.x
      ..y = from.y
      ..axisValue = from.axisValue
      ..stateFlags = from.stateFlags
      ..modsDepressed = from.modsDepressed
      ..modsLatched = from.modsLatched
      ..modsLocked = from.modsLocked
      ..modsGroup = from.modsGroup;
  }

  /// Routes one decoded message. Returns true when [into] was filled with a
  /// window-relevant event; internal events are consumed and return false.
  /// With a null [into], window-relevant events are queued instead.
  bool _dispatchMessage(WaylandWireMessage message, WaylandRawEvent? into) {
    final objectId = message.objectId;
    if (objectId == wlDisplayObjectId) {
      _handleDisplayEvent(message);
      return false;
    }
    final kind = _objects[objectId];
    if (kind == null) {
      // Events race object destruction by design; a message for an id we
      // already forgot is normal, not an error.
      return false;
    }
    switch (kind) {
      case _ObjectKind.registry:
        _handleRegistryEvent(message);
        return false;
      case _ObjectKind.callback:
        if (message.opcode == wlCallbackEventDone) {
          _completedCallbacks.add(objectId);
          _forgetObject(objectId);
        }
        return false;
      case _ObjectKind.shm:
        if (message.opcode == wlShmEventFormat) {
          _shmFormats.add(WaylandMessageReader(message.payload).readUint());
        }
        return false;
      case _ObjectKind.buffer:
        if (message.opcode == wlBufferEventRelease) {
          _buffersById[objectId]?.busy = false;
        }
        return false;
      case _ObjectKind.seat:
        _handleSeatEvent(message);
        return false;
      case _ObjectKind.output:
        return _handleOutputEvent(objectId, message, into);
      case _ObjectKind.xdgWmBase:
        if (message.opcode == xdgWmBaseEventPing) {
          final serial = WaylandMessageReader(message.payload).readUint();
          _writer.begin(_wmBaseId, xdgWmBaseRequestPong);
          _writer.putUint(serial);
          _queueMessage();
          flush();
        }
        return false;
      case _ObjectKind.pointer:
        return _handlePointerEvent(message, into);
      case _ObjectKind.keyboard:
        return _handleKeyboardEvent(message, into);
      case _ObjectKind.surface:
        return _handleSurfaceEvent(objectId, message, into);
      case _ObjectKind.xdgSurface:
        if (message.opcode == xdgSurfaceEventConfigure) {
          final surfaceId = _surfaceByXdgSurface[objectId] ?? 0;
          if (surfaceId == 0) return false;
          return _deliver(into, (WaylandRawEvent event) {
            event
              ..type = WaylandRawEventType.xdgSurfaceConfigure
              ..surfaceId = surfaceId
              ..serial = WaylandMessageReader(message.payload).readUint();
          });
        }
        return false;
      case _ObjectKind.xdgToplevel:
        return _handleToplevelEvent(objectId, message, into);
      case _ObjectKind.compositor:
      case _ObjectKind.shmPool:
        return false;
    }
  }

  void _handleDisplayEvent(WaylandWireMessage message) {
    switch (message.opcode) {
      case wlDisplayEventError:
        final reader = WaylandMessageReader(message.payload);
        final objectId = reader.readObject();
        final code = reader.readUint();
        final text = reader.readString();
        _protocolError = true;
        recordError('wl_display.error on object $objectId: '
            '${wlDisplayErrorName(code)}: $text');
      case wlDisplayEventDeleteId:
        final id = WaylandMessageReader(message.payload).readUint();
        _forgetObject(id);
        _freeIds.add(id);
    }
  }

  void _handleRegistryEvent(WaylandWireMessage message) {
    switch (message.opcode) {
      case wlRegistryEventGlobal:
        final reader = WaylandMessageReader(message.payload);
        final name = reader.readUint();
        final interface = reader.readString();
        final version = reader.readUint();
        _globalsByName[name] = (interface: interface, version: version);
        globalInterfaces.add(interface);
      case wlRegistryEventGlobalRemove:
        final name = WaylandMessageReader(message.payload).readUint();
        final removed = _globalsByName.remove(name);
        if (removed != null && removed.interface == wlOutputInterfaceName) {
          // The output object itself dies with the global; drop its scale.
          // Which output id belonged to that name is not tracked per-name, so
          // conservatively nothing else is forgotten here.
        }
    }
  }

  void _handleSeatEvent(WaylandWireMessage message) {
    if (message.opcode != wlSeatEventCapabilities) return;
    final capabilities = WaylandMessageReader(message.payload).readUint();
    final hasPointer = (capabilities & wlSeatCapabilityPointer) != 0;
    final hasKeyboard = (capabilities & wlSeatCapabilityKeyboard) != 0;
    if (hasPointer && _pointerId == 0) {
      _pointerId = _allocateId(_ObjectKind.pointer);
      _writer.begin(_seatId, wlSeatRequestGetPointer);
      _writer.putNewId(_pointerId);
      _queueMessage();
    }
    if (hasKeyboard && _keyboardId == 0) {
      _keyboardId = _allocateId(_ObjectKind.keyboard);
      _writer.begin(_seatId, wlSeatRequestGetKeyboard);
      _writer.putNewId(_keyboardId);
      _queueMessage();
    }
  }

  bool _handleOutputEvent(
    int outputId,
    WaylandWireMessage message,
    WaylandRawEvent? into,
  ) {
    if (message.opcode != wlOutputEventScale) return false;
    final factor = WaylandMessageReader(message.payload).readInt();
    final scale = factor < 1 ? 1 : factor;
    if (_outputScales[outputId] == scale) return false;
    _outputScales[outputId] = scale;
    return _deliver(into, (WaylandRawEvent event) {
      event.type = WaylandRawEventType.scaleChanged;
    });
  }

  bool _handleSurfaceEvent(
    int surfaceId,
    WaylandWireMessage message,
    WaylandRawEvent? into,
  ) {
    if (message.opcode != wlSurfaceEventEnter) return false;
    return _deliver(into, (WaylandRawEvent event) {
      event
        ..type = WaylandRawEventType.surfaceEnterOutput
        ..surfaceId = surfaceId;
    });
  }

  bool _handleToplevelEvent(
    int toplevelId,
    WaylandWireMessage message,
    WaylandRawEvent? into,
  ) {
    final surfaceId = _surfaceByToplevel[toplevelId] ?? 0;
    if (surfaceId == 0) return false;
    switch (message.opcode) {
      case xdgToplevelEventConfigure:
        final reader = WaylandMessageReader(message.payload);
        final width = reader.readInt();
        final height = reader.readInt();
        final states = reader.readArray();
        var flags = 0;
        final stateData = ByteData.sublistView(states);
        for (var offset = 0; offset + 4 <= states.length; offset += 4) {
          final state = stateData.getUint32(offset, waylandWireEndian);
          if (state < 31) flags |= 1 << state;
        }
        return _deliver(into, (WaylandRawEvent event) {
          event
            ..type = WaylandRawEventType.xdgToplevelConfigure
            ..surfaceId = surfaceId
            ..width = width
            ..height = height
            ..stateFlags = flags;
        });
      case xdgToplevelEventClose:
        return _deliver(into, (WaylandRawEvent event) {
          event
            ..type = WaylandRawEventType.xdgToplevelClose
            ..surfaceId = surfaceId;
        });
      default:
        return false;
    }
  }

  bool _handlePointerEvent(WaylandWireMessage message, WaylandRawEvent? into) {
    final reader = WaylandMessageReader(message.payload);
    switch (message.opcode) {
      case wlPointerEventEnter:
        final serial = reader.readUint();
        final surfaceId = reader.readObject();
        _pointerFocusSurfaceId = surfaceId;
        _pointerX = reader.readFixed();
        _pointerY = reader.readFixed();
        return _deliver(into, (WaylandRawEvent event) {
          event
            ..type = WaylandRawEventType.pointerEnter
            ..surfaceId = surfaceId
            ..serial = serial
            ..x = _pointerX
            ..y = _pointerY;
        });
      case wlPointerEventLeave:
        final serial = reader.readUint();
        final surfaceId = reader.readObject();
        if (_pointerFocusSurfaceId == surfaceId) _pointerFocusSurfaceId = 0;
        return _deliver(into, (WaylandRawEvent event) {
          event
            ..type = WaylandRawEventType.pointerLeave
            ..surfaceId = surfaceId
            ..serial = serial;
        });
      case wlPointerEventMotion:
        if (_pointerFocusSurfaceId == 0) return false;
        final time = reader.readUint();
        _pointerX = reader.readFixed();
        _pointerY = reader.readFixed();
        return _deliver(into, (WaylandRawEvent event) {
          event
            ..type = WaylandRawEventType.pointerMotion
            ..surfaceId = _pointerFocusSurfaceId
            ..timeMilliseconds = time
            ..x = _pointerX
            ..y = _pointerY;
        });
      case wlPointerEventButton:
        if (_pointerFocusSurfaceId == 0) return false;
        final serial = reader.readUint();
        final time = reader.readUint();
        final button = reader.readUint();
        final state = reader.readUint();
        return _deliver(into, (WaylandRawEvent event) {
          event
            ..type = WaylandRawEventType.pointerButton
            ..surfaceId = _pointerFocusSurfaceId
            ..serial = serial
            ..timeMilliseconds = time
            ..key = button
            ..state = state
            ..x = _pointerX
            ..y = _pointerY;
        });
      case wlPointerEventAxis:
        if (_pointerFocusSurfaceId == 0) return false;
        final time = reader.readUint();
        final axis = reader.readUint();
        final value = reader.readFixed();
        return _deliver(into, (WaylandRawEvent event) {
          event
            ..type = WaylandRawEventType.pointerAxis
            ..surfaceId = _pointerFocusSurfaceId
            ..timeMilliseconds = time
            ..axis = axis
            ..axisValue = value
            ..x = _pointerX
            ..y = _pointerY;
        });
      default:
        // frame, axis_source, axis_stop, axis_discrete: consumed. Coalescing
        // by frame is a refinement the translator does not need yet.
        return false;
    }
  }

  bool _handleKeyboardEvent(WaylandWireMessage message, WaylandRawEvent? into) {
    final reader = WaylandMessageReader(message.payload, _receivedFds);
    switch (message.opcode) {
      case wlKeyboardEventKeymap:
        final format = reader.readUint();
        final fd = reader.readFd();
        final size = reader.readUint();
        _adoptKeymap(format, fd, size);
        return false;
      case wlKeyboardEventEnter:
        final serial = reader.readUint();
        final surfaceId = reader.readObject();
        _keyboardFocusSurfaceId = surfaceId;
        return _deliver(into, (WaylandRawEvent event) {
          event
            ..type = WaylandRawEventType.keyboardEnter
            ..surfaceId = surfaceId
            ..serial = serial;
        });
      case wlKeyboardEventLeave:
        final serial = reader.readUint();
        final surfaceId = reader.readObject();
        if (_keyboardFocusSurfaceId == surfaceId) _keyboardFocusSurfaceId = 0;
        modifiers.reset();
        return _deliver(into, (WaylandRawEvent event) {
          event
            ..type = WaylandRawEventType.keyboardLeave
            ..surfaceId = surfaceId
            ..serial = serial;
        });
      case wlKeyboardEventKey:
        if (_keyboardFocusSurfaceId == 0) return false;
        final serial = reader.readUint();
        final time = reader.readUint();
        final key = reader.readUint();
        final state = reader.readUint();
        return _deliver(into, (WaylandRawEvent event) {
          event
            ..type = WaylandRawEventType.keyboardKey
            ..surfaceId = _keyboardFocusSurfaceId
            ..serial = serial
            ..timeMilliseconds = time
            ..key = key
            ..state = state;
        });
      case wlKeyboardEventModifiers:
        reader.readUint(); // serial
        modifiers.update(
          depressed: reader.readUint(),
          latched: reader.readUint(),
          locked: reader.readUint(),
          group: reader.readUint(),
        );
        return false;
      case wlKeyboardEventRepeatInfo:
        repeatRateHz = reader.readInt();
        repeatDelayMilliseconds = reader.readInt();
        return false;
      default:
        return false;
    }
  }

  void _adoptKeymap(int format, int fd, int size) {
    String? failure;
    if (format == wlKeyboardKeymapFormatXkbV1 && fd >= 0 && size > 0) {
      final bytes = _allocator.readSharedMemory(fd, size);
      if (bytes != null) {
        // The mapping is NUL-terminated; drop the terminator before decoding.
        var length = bytes.length;
        while (length > 0 && bytes[length - 1] == 0) {
          length--;
        }
        final text = String.fromCharCodes(bytes, 0, length);
        final parsed = WaylandXkbKeymap.parse(text);
        if (parsed != null) {
          keymap = parsed;
          keymapNote = 'xkb keymap parsed: ${parsed.keyCount} keys '
              '(first group, two levels; dead keys/compose/IME deferred)';
        } else {
          failure = 'xkb keymap text was not understood by the minimal parser';
        }
      } else {
        failure = 'keymap fd could not be mapped';
      }
    } else {
      failure = 'keymap format $format is not xkb_v1';
    }
    if (fd >= 0) _transport.closeFd(fd);
    if (keymap == null) {
      keymap = WaylandXkbKeymap.usFallback();
      keymapNote = '$failure; using the evdev US fallback layout';
      recordError('wl_keyboard.keymap: $keymapNote');
    }
  }

  /// Fills [into] via [fill], or queues a copy when nobody is polling.
  bool _deliver(
    WaylandRawEvent? into,
    void Function(WaylandRawEvent event) fill,
  ) {
    if (into != null) {
      fill(into);
      return true;
    }
    final queued = WaylandRawEvent();
    fill(queued);
    _queuedEvents.add(queued);
    return false;
  }

  // -------------------------------------------------------------------------
  // Toplevels
  // -------------------------------------------------------------------------

  @override
  WaylandToplevelIds createToplevel(WaylandToplevelRequest request) {
    throwIfDisposed();
    if (!isValid) {
      throw StateError('Wayland connection is not valid');
    }

    final surfaceId = _allocateId(_ObjectKind.surface);
    _writer.begin(_compositorId, wlCompositorRequestCreateSurface);
    _writer.putNewId(surfaceId);
    _queueMessage();

    final xdgSurfaceId = _allocateId(_ObjectKind.xdgSurface);
    _writer.begin(_wmBaseId, xdgWmBaseRequestGetXdgSurface);
    _writer.putNewId(xdgSurfaceId);
    _writer.putObject(surfaceId);
    _queueMessage();

    final toplevelId = _allocateId(_ObjectKind.xdgToplevel);
    _writer.begin(xdgSurfaceId, xdgSurfaceRequestGetToplevel);
    _writer.putNewId(toplevelId);
    _queueMessage();

    final ids = WaylandToplevelIds(
      surfaceId: surfaceId,
      xdgSurfaceId: xdgSurfaceId,
      toplevelId: toplevelId,
    );
    _surfaceByXdgSurface[xdgSurfaceId] = surfaceId;
    _surfaceByToplevel[toplevelId] = surfaceId;

    _writer.begin(toplevelId, xdgToplevelRequestSetTitle);
    _writer.putString(request.title);
    _queueMessage();
    _writer.begin(toplevelId, xdgToplevelRequestSetAppId);
    _writer.putString(request.appId);
    _queueMessage();

    if (!request.resizable) {
      _setSizeBounds(toplevelId, request.width, request.height, request.width,
          request.height);
    } else {
      final minW = request.minimumWidth ?? 0;
      final minH = request.minimumHeight ?? 0;
      final maxW = request.maximumWidth ?? 0;
      final maxH = request.maximumHeight ?? 0;
      if (minW > 0 || minH > 0 || maxW > 0 || maxH > 0) {
        _setSizeBounds(toplevelId, minW, minH, maxW, maxH);
      }
    }

    // The initial commit with no buffer is what asks for the first configure;
    // attaching pixels before that configure is a protocol violation.
    _writer.begin(surfaceId, wlSurfaceRequestCommit);
    _queueMessage();

    if (flush() < 0 || !isValid) {
      _surfaceByXdgSurface.remove(xdgSurfaceId);
      _surfaceByToplevel.remove(toplevelId);
      throw StateError('Wayland connection failed while creating a toplevel');
    }
    return ids;
  }

  void _setSizeBounds(int toplevelId, int minW, int minH, int maxW, int maxH) {
    if (minW > 0 || minH > 0) {
      _writer.begin(toplevelId, xdgToplevelRequestSetMinSize);
      _writer.putInt(minW);
      _writer.putInt(minH);
      _queueMessage();
    }
    if (maxW > 0 || maxH > 0) {
      _writer.begin(toplevelId, xdgToplevelRequestSetMaxSize);
      _writer.putInt(maxW);
      _writer.putInt(maxH);
      _queueMessage();
    }
  }

  @override
  void destroyToplevel(WaylandToplevelIds ids) {
    if (isDisposed) return;
    // Reverse creation order, as xdg-shell requires: role object first.
    _writer.begin(ids.toplevelId, xdgToplevelRequestDestroy);
    _queueMessage();
    _writer.begin(ids.xdgSurfaceId, xdgSurfaceRequestDestroy);
    _queueMessage();
    _writer.begin(ids.surfaceId, wlSurfaceRequestDestroy);
    _queueMessage();
    flush();
    _surfaceByXdgSurface.remove(ids.xdgSurfaceId);
    _surfaceByToplevel.remove(ids.toplevelId);
    if (_pointerFocusSurfaceId == ids.surfaceId) _pointerFocusSurfaceId = 0;
    if (_keyboardFocusSurfaceId == ids.surfaceId) _keyboardFocusSurfaceId = 0;
  }

  @override
  void setToplevelTitle(WaylandToplevelIds ids, String title) {
    throwIfDisposed();
    _writer.begin(ids.toplevelId, xdgToplevelRequestSetTitle);
    _writer.putString(title);
    _queueMessage();
    flush();
  }

  @override
  void ackConfigure(WaylandToplevelIds ids, int serial) {
    throwIfDisposed();
    _writer.begin(ids.xdgSurfaceId, xdgSurfaceRequestAckConfigure);
    _writer.putUint(serial);
    _queueMessage();
  }

  @override
  void hideToplevel(WaylandToplevelIds ids) {
    throwIfDisposed();
    // Attaching a null buffer unmaps an xdg_toplevel; the next commit with a
    // buffer maps it again after a fresh configure cycle.
    _writer.begin(ids.surfaceId, wlSurfaceRequestAttach);
    _writer.putObject(0);
    _writer.putInt(0);
    _writer.putInt(0);
    _queueMessage();
    _writer.begin(ids.surfaceId, wlSurfaceRequestCommit);
    _queueMessage();
    flush();
  }

  // -------------------------------------------------------------------------
  // wl_shm CPU presentation
  // -------------------------------------------------------------------------

  @override
  bool get supportsShmPresentation =>
      _shmId != 0 &&
      _allocator.isAvailable &&
      _shmFormats.contains(wlShmFormatArgb8888);

  @override
  WaylandShmBufferHandle createShmBuffer({
    required int pixelWidth,
    required int pixelHeight,
  }) {
    throwIfDisposed();
    if (!supportsShmPresentation) {
      throw StateError('wl_shm ARGB8888 presentation is unavailable');
    }
    final plan = WaylandShmPoolPlan(
      pixelWidth: pixelWidth,
      pixelHeight: pixelHeight,
    );
    final memory = _allocator.allocate(plan.byteLength);
    try {
      final poolId = _allocateId(_ObjectKind.shmPool);
      _writer.begin(_shmId, wlShmRequestCreatePool);
      _writer.putNewId(poolId);
      _writer.putFd(memory.fd);
      _writer.putInt(plan.byteLength);
      _queueMessage();

      final bufferId = _allocateId(_ObjectKind.buffer);
      _writer.begin(poolId, wlShmPoolRequestCreateBuffer);
      _writer.putNewId(bufferId);
      _writer.putInt(0);
      _writer.putInt(plan.pixelWidth);
      _writer.putInt(plan.pixelHeight);
      _writer.putInt(plan.strideBytes);
      _writer.putUint(plan.format);
      _queueMessage();

      // The buffer keeps its own reference to the pool's memory; the pool
      // object itself can go immediately, which is the canonical single-buffer
      // pattern from the protocol documentation.
      _writer.begin(poolId, wlShmPoolRequestDestroy);
      _queueMessage();

      if (flush() < 0 || !isValid) {
        throw StateError('Wayland connection failed while creating an shm '
            'buffer');
      }
      final buffer = _WaylandNativeShmBuffer(
        owner: this,
        bufferId: bufferId,
        memory: memory,
        plan: plan,
      );
      _buffersById[bufferId] = buffer;
      return buffer;
    } on Object {
      memory.dispose();
      rethrow;
    }
  }

  @override
  void destroyShmBuffer(WaylandShmBufferHandle buffer) {
    if (buffer is! _WaylandNativeShmBuffer || !identical(buffer.owner, this)) {
      throw ArgumentError.value(buffer, 'buffer', 'not owned by this client');
    }
    if (buffer.released) return;
    buffer.released = true;
    _buffersById.remove(buffer.bufferId);
    try {
      if (!isDisposed && _transport.isOpen) {
        _writer.begin(buffer.bufferId, wlBufferRequestDestroy);
        _queueMessage();
        flush();
      }
    } finally {
      buffer.memory.dispose();
    }
  }

  @override
  BackendDiagnostic? presentShmBuffer({
    required int surfaceId,
    required WaylandShmBufferHandle buffer,
    required WaylandCpuDamage damage,
    required int bufferScale,
  }) {
    if (isDisposed || !isValid) {
      return const BackendDiagnostic(
        kind: DiagnosticKind.connectionFailed,
        message: 'Wayland connection is unavailable during commit',
      );
    }
    final native = _ownedShmBuffer(buffer);
    if (native == null) {
      return const BackendDiagnostic(
        kind: DiagnosticKind.incompatibleDevice,
        message: 'Wayland shm buffer does not belong to this live connection',
      );
    }

    if (bufferScale > 1 && _compositorVersion >= 3) {
      _writer.begin(surfaceId, wlSurfaceRequestSetBufferScale);
      _writer.putInt(bufferScale);
      _queueMessage();
    }
    _writer.begin(surfaceId, wlSurfaceRequestAttach);
    _writer.putObject(native.bufferId);
    _writer.putInt(0);
    _writer.putInt(0);
    _queueMessage();
    if (_compositorVersion >= 4) {
      _writer.begin(surfaceId, wlSurfaceRequestDamageBuffer);
      _writer.putInt(damage.x);
      _writer.putInt(damage.y);
      _writer.putInt(damage.width);
      _writer.putInt(damage.height);
      _queueMessage();
    } else {
      // Pre-v4 surfaces only understand surface-coordinate damage; the
      // outward-rounded division keeps the region covering.
      _writer.begin(surfaceId, wlSurfaceRequestDamage);
      _writer.putInt(damage.x ~/ bufferScale);
      _writer.putInt(damage.y ~/ bufferScale);
      _writer.putInt((damage.width + bufferScale - 1) ~/ bufferScale);
      _writer.putInt((damage.height + bufferScale - 1) ~/ bufferScale);
      _queueMessage();
    }
    _writer.begin(surfaceId, wlSurfaceRequestCommit);
    _queueMessage();
    native.busy = true;
    if (flush() < 0 || !isValid) {
      return const BackendDiagnostic(
        kind: DiagnosticKind.connectionFailed,
        message: 'Wayland connection failed while committing an shm buffer',
      );
    }
    return null;
  }

  _WaylandNativeShmBuffer? _ownedShmBuffer(WaylandShmBufferHandle buffer) {
    if (buffer is! _WaylandNativeShmBuffer ||
        !identical(buffer.owner, this) ||
        buffer.released) {
      return null;
    }
    return buffer;
  }

  void _queueMessage() {
    final fds = List<int>.of(_writer.fds);
    _transport.queueMessage(_writer.take(), fds);
  }

  @override
  void onDispose() {
    for (final buffer in List<_WaylandNativeShmBuffer>.of(_buffersById.values)) {
      buffer.released = true;
      buffer.memory.dispose();
    }
    _buffersById.clear();
    for (final fd in _receivedFds) {
      _transport.closeFd(fd);
    }
    _receivedFds.clear();
    _transport.dispose();
  }
}

final class _WaylandNativeShmBuffer implements WaylandShmBufferHandle {
  _WaylandNativeShmBuffer({
    required this.owner,
    required this.bufferId,
    required this.memory,
    required WaylandShmPoolPlan plan,
  }) : framebuffer = Framebuffer.wrap(
          memory.bytes,
          width: plan.pixelWidth,
          height: plan.pixelHeight,
          bytesPerRow: plan.strideBytes,
        );

  final WaylandConnection owner;
  final int bufferId;
  final WaylandShmMemory memory;
  bool released = false;

  /// True between a commit and the compositor's release. A commit while busy
  /// is tolerated (the compositor copies shm buffers promptly in practice);
  /// a second buffer per surface is the future fix, not a guess here.
  bool busy = false;

  @override
  final Framebuffer framebuffer;
}
