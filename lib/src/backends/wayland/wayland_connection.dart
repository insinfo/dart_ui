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

import 'dart:convert';
import 'dart:typed_data';

import '../../foundation/diagnostics.dart';
import '../../foundation/lifecycle.dart';
import '../../geometry/offset.dart';
import '../../platform/clipboard.dart';
import '../../platform/native_window.dart';
import '../../rendering/framebuffer.dart';
import 'wayland_cursor.dart';
import 'wayland_drag_drop.dart';
import 'wayland_events.dart';
import 'wayland_keymap.dart';
import 'wayland_positioner.dart';
import 'wayland_protocol.dart';
import 'wayland_shm.dart';
import 'wayland_text_input.dart';
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

  /// Creates an `xdg_popup` anchored to [request]'s parent.
  ///
  /// Throws [StateError] when the parent is gone or the compositor refused.
  /// The popup is not mapped until it is committed and configured, exactly
  /// like a toplevel.
  WaylandToplevelIds createPopup(WaylandPopupRequest request);

  /// Takes an explicit grab for [ids], so that a click anywhere outside the
  /// popup chain dismisses it with `popup_done`.
  ///
  /// Wayland only grants this to a popup created in response to recent user
  /// input, and only for the serial of that input; a grab requested without
  /// one is a protocol error, so a missing serial means no grab rather than a
  /// killed connection. Returns whether the grab was requested.
  bool grabPopup(WaylandToplevelIds ids);

  /// Whether the compositor offers `zxdg_decoration_manager_v1`, which is
  /// what decides if the framework has to draw the window frame itself.
  bool get supportsServerSideDecorations;

  /// Asks for server-side decorations on [ids]. The answer arrives as a
  /// [WaylandRawEventType.decorationConfigure]; a compositor without the
  /// protocol never answers, which is the documented client-side default.
  void requestServerSideDecoration(WaylandToplevelIds ids);

  /// Installs [cursor] on the pointer, loading it from the user's theme the
  /// first time it is asked for. A no-op when no cursor manager is attached.
  void applyCursor(SystemCursor cursor);

  /// A bare `wl_surface` with no role, for a cursor or a drag icon.
  ///
  /// Returns 0 when the compositor is unavailable. The caller owns it and
  /// must [destroyBareSurface] it.
  int createBareSurface();

  void destroyBareSurface(int surfaceId);

  /// `wl_pointer.set_cursor` with the serial of the pointer enter.
  ///
  /// A [surfaceId] of 0 hides the pointer, which is what the protocol means
  /// by a null surface - there is no separate "hide cursor" request. Returns
  /// false when there is no pointer or no enter serial yet, which is the
  /// normal state before the pointer has ever been over a window.
  bool setPointerCursor({
    required int surfaceId,
    required int hotspotX,
    required int hotspotY,
  });

  /// Asks for one `wl_surface.frame` callback on [surfaceId].
  ///
  /// The compositor answers when it is ready for the *next* frame, which is
  /// the only throttling signal Wayland gives a client: there is no vblank to
  /// query and no swap that blocks. The request must be followed by a commit
  /// to take effect, so [presentShmBuffer] emits it as part of the same
  /// transaction. Returns the callback object id, or 0 when unavailable.
  int requestFrameCallback(int surfaceId);

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

  /// `wl_keyboard.repeat_info`: repeats per second (0 disables) and the
  /// initial hold before the first repeat. The backend's repeat engine reads
  /// these; the compositor never repeats for a Wayland client.
  int get repeatRateHz;
  int get repeatDelayMilliseconds;
}

/// The selection (clipboard) operations a Wayland connection offers.
///
/// A separate interface for the same reason [WaylandCpuClient] is one: the
/// backend pattern-matches for it, and fakes that do not care about the
/// clipboard implement one interface fewer.
abstract interface class WaylandSelectionClient {
  /// Whether `wl_data_device_manager` was bound over a seat, which is what a
  /// working clipboard needs.
  bool get supportsClipboard;

  /// Takes the selection with [text] behind it, serving `send` requests from
  /// other clients until cancelled. Throws [ClipboardException] when the
  /// compositor cannot grant it - no data device, or no input serial yet
  /// (Wayland only hands the selection to a client the user recently
  /// interacted with).
  void setClipboardText(String text);

  /// The selection's text, null when it holds none in any accepted MIME.
  ///
  /// Serving our own selection short-circuits without a round trip - asking
  /// the compositor to pipe our own bytes back through ourselves is the
  /// classic single-threaded clipboard deadlock. Throws [ClipboardException]
  /// when the transfer fails or the owner goes silent past the timeout.
  Future<String?> readClipboardText();
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

/// Everything needed to create one `xdg_popup`.
final class WaylandPopupRequest {
  const WaylandPopupRequest({
    required this.parent,
    required this.positioner,
    this.grab = true,
  });

  /// The parent surface's ids. A submenu passes the *parent popup's* ids,
  /// which is what makes a nested chain: xdg-shell requires each popup in a
  /// chain to be the child of the one before it, and dismissing any of them
  /// dismisses the rest.
  final WaylandToplevelIds parent;

  final WaylandPositionerSpec positioner;

  /// Whether to take an explicit grab, which is what makes a click outside
  /// dismiss the popup. Menus want it; a tooltip must not have it, because a
  /// grab steals input from the window under the pointer.
  final bool grab;
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
  xdgPositioner,
  xdgPopup,
  xdgDecorationManager,
  xdgToplevelDecoration,
  frameCallback,
  dataDeviceManager,
  dataDevice,
  dataSource,
  dataOffer,
  textInputManager,
  textInput,
}

/// A live Wayland display connection.
final class WaylandConnection
    with DisposableMixin
    implements
        WaylandWindowClient,
        WaylandCpuClient,
        WaylandSelectionClient,
        WaylandCursorClient,
        WaylandDragDropClient,
        WaylandTextInputClient {
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
  int _dataDeviceManagerId = 0;

  /// The version actually bound. Drag actions and `wl_data_offer.finish`
  /// exist only from version 3.
  int _dataDeviceManagerVersion = 0;
  int _dataDeviceId = 0;

  /// `zwp_text_input_manager_v3` and the single per-seat `zwp_text_input_v3`
  /// it hands out. Zero when the compositor advertises no input method, which
  /// is the whole of the availability test - the protocol has no capability
  /// event of its own.
  int _textInputManagerId = 0;
  int _textInputId = 0;

  /// wl_shm formats the compositor advertised.
  final Set<int> _shmFormats = <int>{};

  // Seat devices.
  int _pointerId = 0;
  int _keyboardId = 0;

  // Input focus, resolved so motion/key events can carry their surface.
  int _pointerFocusSurfaceId = 0;

  /// The serial of the most recent `wl_pointer.enter`, which is the only
  /// serial `set_cursor` accepts.
  int _pointerEnterSerial = 0;
  int _keyboardFocusSurfaceId = 0;
  int _lastInputSerial = 0;
  double _pointerX = 0;
  double _pointerY = 0;

  @override
  WaylandXkbKeymap? keymap;

  /// Why the fallback keymap was chosen, when it was; probe/diagnostic text.
  String? keymapNote;

  @override
  final WaylandModifiersState modifiers = WaylandModifiersState();

  /// Latest settings received through `wl_keyboard.repeat_info`.
  @override
  int repeatRateHz = 0;

  @override
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

  // Frame callbacks in flight, mapped back to the surface that asked.
  final Map<int, int> _surfaceByFrameCallback = <int, int>{};

  // Popup routing and the parent chain, so dismissing one dismisses its
  // descendants the way xdg-shell requires.
  final Map<int, int> _surfaceByPopup = <int, int>{};
  final Map<int, int> _popupParents = <int, int>{};

  // xdg-decoration.
  int _decorationManagerId = 0;
  final Map<int, int> _decorationsByToplevel = <int, int>{};
  final Map<int, int> _surfaceByDecoration = <int, int>{};

  // Clipboard ownership and offers. A data source remains alive after a new
  // source replaces it: the compositor owns that transition and retires the
  // old source with `cancelled`. Destroying it earlier can race an outstanding
  // `send` request from another client.
  final Map<int, String> _clipboardSources = <int, String>{};
  final Map<int, _WaylandDataOffer> _dataOffers = <int, _WaylandDataOffer>{};
  int _activeClipboardSourceId = 0;
  int _selectionOfferId = 0;
  String? _ownedClipboardText;

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
          _compositorVersion = version < wlCompositorBindVersion
              ? version
              : wlCompositorBindVersion;
          _compositorId = _bind(
              name, interface, _compositorVersion, _ObjectKind.compositor);
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
          _wmBaseId = _bind(
              name, interface, xdgWmBaseBindVersion, _ObjectKind.xdgWmBase);
        case wlDataDeviceManagerInterfaceName:
          if (_dataDeviceManagerId != 0) break;
          // Version 3 is what makes drag actions - copy versus move - and
          // wl_data_offer.finish exist at all; below it a drop cannot be
          // negotiated. Binding lower would silently disable half of DnD.
          final bindVersion = version < wlDataDeviceManagerDragBindVersion
              ? version
              : wlDataDeviceManagerDragBindVersion;
          _dataDeviceManagerVersion = bindVersion;
          _dataDeviceManagerId = _bind(
            name,
            interface,
            bindVersion,
            _ObjectKind.dataDeviceManager,
          );
        case zwpTextInputManagerV3InterfaceName:
          if (_textInputManagerId != 0) break;
          _textInputManagerId = _bind(
            name,
            interface,
            zwpTextInputManagerV3BindVersion,
            _ObjectKind.textInputManager,
          );
        case xdgDecorationManagerInterfaceName:
          if (_decorationManagerId != 0) break;
          _decorationManagerId = _bind(
            name,
            interface,
            xdgDecorationManagerBindVersion,
            _ObjectKind.xdgDecorationManager,
          );
      }
    }
    if (_dataDeviceManagerId != 0 && _seatId != 0) {
      _dataDeviceId = _allocateId(_ObjectKind.dataDevice);
      _writer.begin(
        _dataDeviceManagerId,
        wlDataDeviceManagerRequestGetDataDevice,
      );
      _writer.putNewId(_dataDeviceId);
      _writer.putObject(_seatId);
      _queueMessage();
    }
    if (_textInputManagerId != 0 && _seatId != 0) {
      // One `zwp_text_input_v3` for the seat, not one per surface: the object
      // is per-seat by design and its `enter`/`leave` events name which of this
      // client's surfaces the input method is aimed at, exactly as
      // `wl_data_device` does for drags.
      _textInputId = _allocateId(_ObjectKind.textInput);
      _writer.begin(
        _textInputManagerId,
        zwpTextInputManagerV3RequestGetTextInput,
      );
      _writer.putNewId(_textInputId);
      _writer.putObject(_seatId);
      _queueMessage();
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
      case _ObjectKind.frameCallback:
        if (message.opcode != wlCallbackEventDone) return false;
        final surfaceId = _surfaceByFrameCallback.remove(objectId) ?? 0;
        _forgetObject(objectId);
        if (surfaceId == 0) return false;
        return _deliver(into, (WaylandRawEvent event) {
          event
            ..type = WaylandRawEventType.frameDone
            ..surfaceId = surfaceId
            // wl_callback.done carries the compositor's frame time in
            // milliseconds, which is the clock a pacer should measure with.
            ..timeMilliseconds =
                WaylandMessageReader(message.payload).readUint();
        });
      case _ObjectKind.shm:
        if (message.opcode == wlShmEventFormat) {
          _shmFormats.add(WaylandMessageReader(message.payload).readUint());
        }
        return false;
      case _ObjectKind.buffer:
        if (message.opcode == wlBufferEventRelease) {
          final buffer = _buffersById[objectId];
          if (buffer != null) {
            buffer.busy = false;
            if (buffer.released) _finalizeShmBuffer(buffer);
          }
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
      case _ObjectKind.dataDevice:
        _handleDataDeviceEvent(message);
        return false;
      case _ObjectKind.dataSource:
        _handleDataSourceEvent(objectId, message);
        return false;
      case _ObjectKind.dataOffer:
        _handleDataOfferEvent(objectId, message);
        return false;
      case _ObjectKind.textInput:
        _handleTextInputEvent(message);
        return false;
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
      case _ObjectKind.xdgPopup:
        return _handlePopupEvent(objectId, message, into);
      case _ObjectKind.xdgToplevelDecoration:
        if (message.opcode != xdgToplevelDecorationEventConfigure) return false;
        final surfaceId = _surfaceByDecoration[objectId] ?? 0;
        if (surfaceId == 0) return false;
        return _deliver(into, (WaylandRawEvent event) {
          event
            ..type = WaylandRawEventType.decorationConfigure
            ..surfaceId = surfaceId
            ..state = WaylandMessageReader(message.payload).readUint();
        });
      case _ObjectKind.compositor:
      case _ObjectKind.shmPool:
      case _ObjectKind.xdgPositioner:
      case _ObjectKind.xdgDecorationManager:
      case _ObjectKind.dataDeviceManager:
      case _ObjectKind.textInputManager:
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

  bool _handlePopupEvent(
    int popupId,
    WaylandWireMessage message,
    WaylandRawEvent? into,
  ) {
    final surfaceId = _surfaceByPopup[popupId] ?? 0;
    if (surfaceId == 0) return false;
    switch (message.opcode) {
      case xdgPopupEventConfigure:
        final reader = WaylandMessageReader(message.payload);
        final x = reader.readInt();
        final y = reader.readInt();
        final width = reader.readInt();
        final height = reader.readInt();
        return _deliver(into, (WaylandRawEvent event) {
          event
            ..type = WaylandRawEventType.popupConfigure
            ..surfaceId = surfaceId
            ..x = x.toDouble()
            ..y = y.toDouble()
            ..width = width
            ..height = height;
        });
      case xdgPopupEventPopupDone:
        // Dismissing a popup dismisses everything nested below it, and the
        // compositor only names the one it decided on, so the chain is walked
        // here - deepest first, ending with the popup named, which is the
        // order a menu must tear its submenus down in.
        final chain = <int>[
          for (final child in _descendantPopups(popupId))
            if (_surfaceByPopup[child] != null) _surfaceByPopup[child]!,
          surfaceId,
        ];
        var filled = false;
        for (final dismissed in chain) {
          if (!filled && into != null) {
            filled = true;
            into
              ..type = WaylandRawEventType.popupDone
              ..surfaceId = dismissed;
            continue;
          }
          _deliver(null, (WaylandRawEvent event) {
            event
              ..type = WaylandRawEventType.popupDone
              ..surfaceId = dismissed;
          });
        }
        return filled;
      default:
        return false;
    }
  }

  /// Every popup whose parent chain reaches [popupId], deepest first.
  List<int> _descendantPopups(int popupId) {
    final found = <int>[];
    var changed = true;
    while (changed) {
      changed = false;
      for (final entry in _popupParents.entries) {
        if (found.contains(entry.key)) continue;
        if (entry.value == popupId || found.contains(entry.value)) {
          found.add(entry.key);
          changed = true;
        }
      }
    }
    return found.reversed.toList();
  }

  bool _handlePointerEvent(WaylandWireMessage message, WaylandRawEvent? into) {
    final reader = WaylandMessageReader(message.payload);
    switch (message.opcode) {
      case wlPointerEventEnter:
        final serial = reader.readUint();
        _rememberInputSerial(serial);
        // set_cursor must quote the serial of the *enter* that gave us the
        // pointer, not any later input serial: the compositor rejects a
        // cursor set with a stale or unrelated serial.
        _pointerEnterSerial = serial;
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
        _rememberInputSerial(serial);
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
        _rememberInputSerial(serial);
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
        _rememberInputSerial(serial);
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
        _rememberInputSerial(serial);
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
        _rememberInputSerial(serial);
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
        _rememberInputSerial(reader.readUint());
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

  void _rememberInputSerial(int serial) {
    if (serial != 0) _lastInputSerial = serial;
  }

  // -------------------------------------------------------------------------
  // wl_data_device clipboard
  // -------------------------------------------------------------------------

  @override
  bool get supportsClipboard =>
      _dataDeviceManagerId != 0 && _dataDeviceId != 0 && isValid;

  @override
  void setClipboardText(String text) {
    throwIfDisposed();
    if (!supportsClipboard) {
      throw const ClipboardException(
        operation: 'set_selection',
        backend: 'wayland',
        reason: 'the compositor advertised no usable wl_data_device_manager',
      );
    }
    if (_lastInputSerial == 0) {
      throw const ClipboardException(
        operation: 'set_selection',
        backend: 'wayland',
        reason: 'no keyboard or pointer serial has been received; Wayland '
            'requires recent user interaction before taking the selection',
      );
    }

    final sourceId = _allocateId(_ObjectKind.dataSource);
    _writer.begin(
      _dataDeviceManagerId,
      wlDataDeviceManagerRequestCreateDataSource,
    );
    _writer.putNewId(sourceId);
    _queueMessage();
    for (final mime in wlClipboardAcceptedTextMimes) {
      _writer.begin(sourceId, wlDataSourceRequestOffer);
      _writer.putString(mime);
      _queueMessage();
    }
    _writer.begin(_dataDeviceId, wlDataDeviceRequestSetSelection);
    _writer.putObject(sourceId);
    _writer.putUint(_lastInputSerial);
    _queueMessage();

    if (flush() < 0 || !isValid) {
      throw const ClipboardException(
        operation: 'set_selection',
        backend: 'wayland',
        reason: 'the compositor connection failed while publishing the source',
      );
    }
    _clipboardSources[sourceId] = text;
    _activeClipboardSourceId = sourceId;
    _ownedClipboardText = text;
  }

  @override
  Future<String?> readClipboardText() async {
    throwIfDisposed();
    if (!supportsClipboard) {
      throw const ClipboardException(
        operation: 'readText',
        backend: 'wayland',
        reason: 'the compositor advertised no usable wl_data_device_manager',
      );
    }

    // Feeding our bytes through a pipe would require this same single-threaded
    // connection to service wl_data_source.send while blocked reading it.
    final owned = _ownedClipboardText;
    if (_activeClipboardSourceId != 0 && owned != null) return owned;

    final offer = _dataOffers[_selectionOfferId];
    if (offer == null) return null;
    String? mime;
    for (final accepted in wlClipboardAcceptedTextMimes) {
      if (offer.mimeTypes.contains(accepted)) {
        mime = accepted;
        break;
      }
    }
    if (mime == null) return null;

    final pipe = _transport.createPipe();
    if (pipe == null) {
      throw const ClipboardException(
        operation: 'receive',
        backend: 'wayland',
        reason: 'pipe2 failed while preparing the selection transfer',
      );
    }
    var writeOpen = true;
    try {
      _writer.begin(offer.id, wlDataOfferRequestReceive);
      _writer.putString(mime);
      _writer.putFd(pipe.writeFd);
      _queueMessage();
      if (flush() < 0 || !isValid) {
        throw const ClipboardException(
          operation: 'receive',
          backend: 'wayland',
          reason: 'the compositor connection failed while requesting text',
        );
      }
      // sendmsg duplicated the descriptor into the compositor. Keeping our
      // copy open would prevent the read side from ever observing EOF.
      _transport.closeFd(pipe.writeFd);
      writeOpen = false;
      final bytes = _transport.readAllFromFd(pipe.readFd);
      if (bytes == null) {
        throw const ClipboardException(
          operation: 'receive',
          backend: 'wayland',
          reason: 'the selection owner failed, exceeded 64 MiB, or did not '
              'finish within 2s',
        );
      }
      return utf8.decode(bytes, allowMalformed: true);
    } finally {
      if (writeOpen) _transport.closeFd(pipe.writeFd);
      _transport.closeFd(pipe.readFd);
    }
  }

  void _handleDataDeviceEvent(WaylandWireMessage message) {
    final reader = WaylandMessageReader(message.payload);
    switch (message.opcode) {
      case wlDataDeviceEventDataOffer:
        final id = reader.readNewId();
        if (id == 0 || _objects.containsKey(id)) {
          _protocolError = true;
          recordError('wl_data_device.data_offer reused invalid object $id');
          return;
        }
        _objects[id] = _ObjectKind.dataOffer;
        _dataOffers[id] = _WaylandDataOffer(id);
        dragDrop?.onDataOffer(id);
      case wlDataDeviceEventSelection:
        final id = reader.readObject();
        final previous = _selectionOfferId;
        _selectionOfferId = id;
        // Any selection event means the compositor has chosen an owner. If it
        // is not represented by our active source anymore, the local shortcut
        // must not return stale text.
        _activeClipboardSourceId = 0;
        _ownedClipboardText = null;
        if (previous != 0 && previous != id) _destroyDataOffer(previous);
      case wlDataDeviceEventEnter:
        final serial = reader.readUint();
        _rememberInputSerial(serial);
        final surfaceId = reader.readObject();
        final x = reader.readFixed();
        final y = reader.readFixed();
        final offerId = reader.readObject();
        final drag = dragDrop;
        if (drag == null) {
          // Nothing can consume a drop, so retire the offer rather than
          // retaining an object the application will never see.
          if (offerId != 0 && offerId != _selectionOfferId) {
            _destroyDataOffer(offerId);
          }
          return;
        }
        _dragEnterSerial = serial;
        drag.onDragEnter(
          serial: serial,
          surfaceId: surfaceId,
          offerId: offerId,
          position: Offset(x, y),
        );
      case wlDataDeviceEventMotion:
        reader.readUint(); // time
        final x = reader.readFixed();
        final y = reader.readFixed();
        dragDrop?.onDragMotion(Offset(x, y));
      case wlDataDeviceEventLeave:
        dragDrop?.onDragLeave();
      case wlDataDeviceEventDrop:
        dragDrop?.onDrop();
      default:
        break;
    }
  }

  void _handleDataOfferEvent(int offerId, WaylandWireMessage message) {
    final reader = WaylandMessageReader(message.payload);
    switch (message.opcode) {
      case wlDataOfferEventOffer:
        final mime = reader.readString();
        _dataOffers[offerId]?.mimeTypes.add(mime);
        dragDrop?.onOfferMime(offerId, mime);
      case wlDataOfferEventSourceActions:
        dragDrop?.onOfferSourceActions(offerId, reader.readUint());
      case wlDataOfferEventAction:
        dragDrop?.onOfferAction(offerId, reader.readUint());
    }
  }

  void _handleDataSourceEvent(int sourceId, WaylandWireMessage message) {
    switch (message.opcode) {
      case wlDataSourceEventSend:
        final reader = WaylandMessageReader(message.payload, _receivedFds);
        final mime = reader.readString();
        final fd = reader.readFd();
        // A drag source and a clipboard source are both wl_data_source; the
        // drag manager owns the ones it created.
        final drag = dragDrop;
        if (drag != null && drag.isDragging) {
          drag.onSourceSend(sourceId, mime, fd);
          return;
        }
        try {
          final text = _clipboardSources[sourceId];
          if (text != null && wlClipboardAcceptedTextMimes.contains(mime)) {
            if (!_transport.writeAllToFd(
              fd,
              Uint8List.fromList(utf8.encode(text)),
            )) {
              recordError('wl_data_source.send failed for $mime');
            }
          }
        } finally {
          _transport.closeFd(fd);
        }
      case wlDataSourceEventAction:
        dragDrop?.onSourceAction(
          sourceId,
          WaylandMessageReader(message.payload).readUint(),
        );
      case wlDataSourceEventDndDropPerformed:
        dragDrop?.onSourceDropPerformed(sourceId);
      case wlDataSourceEventDndFinished:
        dragDrop?.onSourceFinished(sourceId);
      case wlDataSourceEventCancelled:
        final drag = dragDrop;
        if (drag != null && drag.isDragging) {
          drag.onSourceCancelled(sourceId);
          return;
        }
        _clipboardSources.remove(sourceId);
        if (_activeClipboardSourceId == sourceId) {
          _activeClipboardSourceId = 0;
          _ownedClipboardText = null;
        }
        _writer.begin(sourceId, wlDataSourceRequestDestroy);
        _queueMessage();
        flush();
      default:
        // target is advisory and does not change the bytes this text-only
        // source can serve.
        break;
    }
  }

  void _destroyDataOffer(int id) {
    final offer = _dataOffers.remove(id);
    if (offer == null || isDisposed || !_transport.isOpen) return;
    _writer.begin(id, wlDataOfferRequestDestroy);
    _queueMessage();
    flush();
    // Event-created ids live in the server id range and receive no
    // wl_display.delete_id acknowledgement after their destructor.
    _forgetObject(id);
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
    final isPopup = _surfaceByPopup.containsKey(ids.toplevelId);
    // A decoration object outlives neither its toplevel nor the protocol's
    // ordering rule: it must go before the role object it decorates.
    final decorationId = _decorationsByToplevel.remove(ids.toplevelId);
    if (decorationId != null) {
      _writer.begin(decorationId, xdgToplevelDecorationRequestDestroy);
      _queueMessage();
      _surfaceByDecoration.remove(decorationId);
      _forgetObject(decorationId);
    }
    // Reverse creation order, as xdg-shell requires: role object first.
    _writer.begin(
      ids.toplevelId,
      isPopup ? xdgPopupRequestDestroy : xdgToplevelRequestDestroy,
    );
    _queueMessage();
    if (isPopup) {
      _surfaceByPopup.remove(ids.toplevelId);
      _popupParents.remove(ids.toplevelId);
    }
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
  WaylandToplevelIds createPopup(WaylandPopupRequest request) {
    throwIfDisposed();
    if (!isValid) throw StateError('Wayland connection is not valid');
    if (_wmBaseId == 0) {
      throw StateError('xdg_wm_base is unavailable; popups need xdg-shell');
    }

    // The positioner is a short-lived description, not an object the popup
    // keeps: it is configured, consumed by get_popup and destroyed at once.
    final positionerId = _allocateId(_ObjectKind.xdgPositioner);
    _writer.begin(_wmBaseId, xdgWmBaseRequestCreatePositioner);
    _writer.putNewId(positionerId);
    _queueMessage();
    _configurePositioner(positionerId, request.positioner);

    final surfaceId = _allocateId(_ObjectKind.surface);
    _writer.begin(_compositorId, wlCompositorRequestCreateSurface);
    _writer.putNewId(surfaceId);
    _queueMessage();

    final xdgSurfaceId = _allocateId(_ObjectKind.xdgSurface);
    _writer.begin(_wmBaseId, xdgWmBaseRequestGetXdgSurface);
    _writer.putNewId(xdgSurfaceId);
    _writer.putObject(surfaceId);
    _queueMessage();

    final popupId = _allocateId(_ObjectKind.xdgPopup);
    _writer.begin(xdgSurfaceId, xdgSurfaceRequestGetPopup);
    _writer.putNewId(popupId);
    _writer.putObject(request.parent.xdgSurfaceId);
    _writer.putObject(positionerId);
    _queueMessage();

    _writer.begin(positionerId, xdgPositionerRequestDestroy);
    _queueMessage();
    _forgetObject(positionerId);

    final ids = WaylandToplevelIds(
      surfaceId: surfaceId,
      xdgSurfaceId: xdgSurfaceId,
      toplevelId: popupId,
    );
    _surfaceByXdgSurface[xdgSurfaceId] = surfaceId;
    _surfaceByPopup[popupId] = surfaceId;
    _popupParents[popupId] = request.parent.toplevelId;

    if (request.grab) grabPopup(ids);

    // The empty commit that asks for the first configure, same as a toplevel.
    _writer.begin(surfaceId, wlSurfaceRequestCommit);
    _queueMessage();

    if (flush() < 0 || !isValid) {
      _surfaceByXdgSurface.remove(xdgSurfaceId);
      _surfaceByPopup.remove(popupId);
      _popupParents.remove(popupId);
      throw StateError('Wayland connection failed while creating a popup');
    }
    return ids;
  }

  void _configurePositioner(int positionerId, WaylandPositionerSpec spec) {
    _writer.begin(positionerId, xdgPositionerRequestSetSize);
    _writer.putInt(spec.width);
    _writer.putInt(spec.height);
    _queueMessage();

    _writer.begin(positionerId, xdgPositionerRequestSetAnchorRect);
    _writer.putInt(spec.anchorX);
    _writer.putInt(spec.anchorY);
    _writer.putInt(spec.anchorWidth);
    _writer.putInt(spec.anchorHeight);
    _queueMessage();

    _writer.begin(positionerId, xdgPositionerRequestSetAnchor);
    _writer.putUint(spec.anchor);
    _queueMessage();

    _writer.begin(positionerId, xdgPositionerRequestSetGravity);
    _writer.putUint(spec.gravity);
    _queueMessage();

    _writer.begin(positionerId, xdgPositionerRequestSetConstraintAdjustment);
    _writer.putUint(spec.constraintAdjustment);
    _queueMessage();

    if (spec.offsetX != 0 || spec.offsetY != 0) {
      _writer.begin(positionerId, xdgPositionerRequestSetOffset);
      _writer.putInt(spec.offsetX);
      _writer.putInt(spec.offsetY);
      _queueMessage();
    }
  }

  @override
  bool grabPopup(WaylandToplevelIds ids) {
    if (isDisposed || !isValid) return false;
    // A grab without an input serial is a protocol error that kills the
    // connection, so a popup opened programmatically simply goes ungrabbed.
    if (_lastInputSerial == 0 || _seatId == 0) {
      recordError('xdg_popup.grab skipped: no input serial yet, so the '
          'compositor would reject the grab and close the connection');
      return false;
    }
    _writer.begin(ids.toplevelId, xdgPopupRequestGrab);
    _writer.putObject(_seatId);
    _writer.putUint(_lastInputSerial);
    _queueMessage();
    return true;
  }

  @override
  bool get supportsServerSideDecorations => _decorationManagerId != 0;

  @override
  void requestServerSideDecoration(WaylandToplevelIds ids) {
    if (isDisposed || _decorationManagerId == 0) return;
    if (_decorationsByToplevel.containsKey(ids.toplevelId)) return;
    final decorationId = _allocateId(_ObjectKind.xdgToplevelDecoration);
    _writer.begin(
      _decorationManagerId,
      xdgDecorationManagerRequestGetToplevelDecoration,
    );
    _writer.putNewId(decorationId);
    _writer.putObject(ids.toplevelId);
    _queueMessage();
    _writer.begin(decorationId, xdgToplevelDecorationRequestSetMode);
    _writer.putUint(xdgToplevelDecorationModeServerSide);
    _queueMessage();
    _decorationsByToplevel[ids.toplevelId] = decorationId;
    _surfaceByDecoration[decorationId] = ids.surfaceId;
    flush();
  }

  /// The cursor manager, installed by the backend once the theme is resolved.
  ///
  /// Null when cursors could not be set up at all (no `wl_shm`, no theme on
  /// disk); [applyCursor] is then a no-op and the compositor's own default
  /// pointer stays, which is the correct degradation.
  WaylandCursorManager? cursorManager;

  @override
  void applyCursor(SystemCursor cursor) {
    cursorManager?.apply(cursor);
  }

  /// The drag-and-drop state machine, installed by the backend when the
  /// compositor offers a data device. Null disables drops entirely, and the
  /// offers that arrive anyway are retired rather than leaked.
  WaylandDragDropManager? dragDrop;

  /// The serial of the most recent `wl_data_device.enter`, which `accept` and
  /// `set_actions` must quote.
  int _dragEnterSerial = 0;

  /// The `zwp_text_input_v3` state machine, installed by the backend when the
  /// compositor offers the protocol. Null means the events that arrive anyway
  /// are dropped rather than queued for a manager that will never exist.
  WaylandTextInputManager? textInput;

  // -------------------------------------------------------------------------
  // WaylandTextInputClient
  // -------------------------------------------------------------------------

  @override
  bool get supportsTextInput => _textInputId != 0;

  void _handleTextInputEvent(WaylandWireMessage message) {
    final WaylandTextInputManager? manager = textInput;
    if (manager == null) return;
    final reader = WaylandMessageReader(message.payload);
    switch (message.opcode) {
      case zwpTextInputV3EventEnter:
        manager.onEnter(reader.readObject());
      case zwpTextInputV3EventLeave:
        manager.onLeave(reader.readObject());
      case zwpTextInputV3EventPreeditString:
        // The string is nullable in the XML: a zero-length word means "no
        // preedit", which is not the same as the empty string only because the
        // protocol allows a `done` that says nothing about the preedit at all.
        final String text = reader.readString();
        final int cursorBegin = reader.readInt();
        final int cursorEnd = reader.readInt();
        manager.onPreeditString(text, cursorBegin, cursorEnd);
      case zwpTextInputV3EventCommitString:
        manager.onCommitString(reader.readString());
      case zwpTextInputV3EventDeleteSurroundingText:
        manager.onDeleteSurroundingText(reader.readUint(), reader.readUint());
      case zwpTextInputV3EventDone:
        manager.onDone(reader.readUint());
    }
  }

  @override
  void textInputEnable() {
    if (!_canSendTextInput) return;
    _writer.begin(_textInputId, zwpTextInputV3RequestEnable);
    _queueMessage();
  }

  @override
  void textInputDisable() {
    if (!_canSendTextInput) return;
    _writer.begin(_textInputId, zwpTextInputV3RequestDisable);
    _queueMessage();
  }

  @override
  void textInputSetSurroundingText(
    String text,
    int cursorBytes,
    int anchorBytes,
  ) {
    if (!_canSendTextInput) return;
    _writer.begin(_textInputId, zwpTextInputV3RequestSetSurroundingText);
    _writer.putString(text);
    _writer.putInt(cursorBytes);
    _writer.putInt(anchorBytes);
    _queueMessage();
  }

  @override
  void textInputSetTextChangeCause(int cause) {
    if (!_canSendTextInput) return;
    _writer.begin(_textInputId, zwpTextInputV3RequestSetTextChangeCause);
    _writer.putUint(cause);
    _queueMessage();
  }

  @override
  void textInputSetContentType(int hint, int purpose) {
    if (!_canSendTextInput) return;
    _writer.begin(_textInputId, zwpTextInputV3RequestSetContentType);
    _writer.putUint(hint);
    _writer.putUint(purpose);
    _queueMessage();
  }

  @override
  void textInputSetCursorRectangle(int x, int y, int width, int height) {
    if (!_canSendTextInput) return;
    _writer.begin(_textInputId, zwpTextInputV3RequestSetCursorRectangle);
    _writer.putInt(x);
    _writer.putInt(y);
    // A zero-extent rectangle is legal and useless: a compositor placing a
    // candidate window below it has nothing to place it below. One logical
    // unit is the floor, which is what a collapsed caret actually is.
    _writer.putInt(width < 1 ? 1 : width);
    _writer.putInt(height < 1 ? 1 : height);
    _queueMessage();
  }

  /// `commit`, which is what makes every staged request above take effect.
  ///
  /// Flushed on the spot rather than left in the queue: the compositor's reply
  /// carries the count of commits it has received, and a commit sitting in a
  /// buffer while the input method answers the *previous* state is precisely
  /// the staleness the manager then has to discard.
  @override
  void textInputCommit() {
    if (!_canSendTextInput) return;
    _writer.begin(_textInputId, zwpTextInputV3RequestCommit);
    _queueMessage();
    flush();
  }

  bool get _canSendTextInput => !isDisposed && isValid && _textInputId != 0;

  // -------------------------------------------------------------------------
  // WaylandDragDropClient
  // -------------------------------------------------------------------------

  @override
  bool get supportsDragAndDrop => _dataDeviceId != 0;

  @override
  void acceptOffer(int offerId, int serial, String? mimeType) {
    if (isDisposed || !isValid || offerId == 0) return;
    _writer.begin(offerId, wlDataOfferRequestAccept);
    _writer.putUint(serial == 0 ? _dragEnterSerial : serial);
    if (mimeType == null) {
      // A null string - length word 0, no bytes - is how the protocol spells
      // "I refuse this drag", and it is what makes the cursor say so.
      _writer.putUint(0);
    } else {
      _writer.putString(mimeType);
    }
    _queueMessage();
    flush();
  }

  @override
  void setOfferActions(int offerId, int actions, int preferredAction) {
    if (isDisposed || !isValid || offerId == 0) return;
    _writer.begin(offerId, wlDataOfferRequestSetActions);
    _writer.putUint(actions);
    _writer.putUint(preferredAction);
    _queueMessage();
    flush();
  }

  @override
  Future<Uint8List?> receiveOffer(int offerId, String mimeType) async {
    if (isDisposed || !isValid || offerId == 0) return null;
    final pipe = _transport.createPipe();
    if (pipe == null) return null;
    _writer.begin(offerId, wlDataOfferRequestReceive);
    _writer.putString(mimeType);
    _writer.putFd(pipe.writeFd);
    _queueMessage();
    flush();
    // Our copy of the write end must go before the read: while this process
    // holds it, the pipe never reaches EOF and the read below would block
    // until the timeout even after the peer finished.
    _transport.closeFd(pipe.writeFd);
    try {
      return _transport.readAllFromFd(pipe.readFd);
    } finally {
      _transport.closeFd(pipe.readFd);
    }
  }

  @override
  void finishOffer(int offerId) {
    if (isDisposed || !isValid || offerId == 0) return;
    // finish() does not exist before version 3; sending it there is a
    // protocol error that would kill the connection.
    if (_dataDeviceManagerVersion < wlDataDeviceManagerDragBindVersion) return;
    _writer.begin(offerId, wlDataOfferRequestFinish);
    _queueMessage();
    flush();
  }

  @override
  void destroyOffer(int offerId) => _destroyDataOffer(offerId);

  @override
  int startDrag({
    required int originSurfaceId,
    required int iconSurfaceId,
    required List<String> mimeTypes,
    required int actions,
  }) {
    if (isDisposed || !isValid || _dataDeviceManagerId == 0) return 0;
    if (_dataDeviceId == 0 || _lastInputSerial == 0) {
      recordError('wl_data_device.start_drag needs an input serial; a drag '
          'must begin from a real gesture');
      return 0;
    }
    final sourceId = _allocateId(_ObjectKind.dataSource);
    _writer.begin(
      _dataDeviceManagerId,
      wlDataDeviceManagerRequestCreateDataSource,
    );
    _writer.putNewId(sourceId);
    _queueMessage();
    for (final mime in mimeTypes) {
      _writer.begin(sourceId, wlDataSourceRequestOffer);
      _writer.putString(mime);
      _queueMessage();
    }
    if (_dataDeviceManagerVersion >= wlDataDeviceManagerDragBindVersion) {
      _writer.begin(sourceId, wlDataSourceRequestSetActions);
      _writer.putUint(actions);
      _queueMessage();
    }
    _writer.begin(_dataDeviceId, wlDataDeviceRequestStartDrag);
    _writer.putObject(sourceId);
    _writer.putObject(originSurfaceId);
    _writer.putObject(iconSurfaceId);
    _writer.putUint(_lastInputSerial);
    _queueMessage();
    if (flush() < 0) return 0;
    return sourceId;
  }

  @override
  bool sendDragData(int fd, Uint8List bytes) {
    try {
      if (isDisposed) return false;
      return _transport.writeAllToFd(fd, bytes);
    } finally {
      // Always closed: a writer that leaves the fd open leaves the reader
      // blocked forever, which the user sees as the other application hanging.
      _transport.closeFd(fd);
    }
  }

  @override
  void destroyDataSource(int sourceId) {
    if (isDisposed || sourceId == 0) return;
    _writer.begin(sourceId, wlDataSourceRequestDestroy);
    _queueMessage();
    _forgetObject(sourceId);
    flush();
  }

  @override
  int createBareSurface() {
    if (isDisposed || !isValid || _compositorId == 0) return 0;
    final surfaceId = _allocateId(_ObjectKind.surface);
    _writer.begin(_compositorId, wlCompositorRequestCreateSurface);
    _writer.putNewId(surfaceId);
    _queueMessage();
    return surfaceId;
  }

  @override
  void destroyBareSurface(int surfaceId) {
    if (isDisposed || surfaceId == 0) return;
    _writer.begin(surfaceId, wlSurfaceRequestDestroy);
    _queueMessage();
    _forgetObject(surfaceId);
    flush();
  }

  @override
  bool setPointerCursor({
    required int surfaceId,
    required int hotspotX,
    required int hotspotY,
  }) {
    if (isDisposed || !isValid) return false;
    if (_pointerId == 0 || _pointerEnterSerial == 0) return false;
    _writer.begin(_pointerId, wlPointerRequestSetCursor);
    _writer.putUint(_pointerEnterSerial);
    // A null surface is how the protocol spells "hide the pointer"; there is
    // no separate request for it.
    _writer.putObject(surfaceId);
    _writer.putInt(hotspotX);
    _writer.putInt(hotspotY);
    _queueMessage();
    flush();
    return true;
  }

  @override
  int requestFrameCallback(int surfaceId) {
    if (isDisposed || !isValid || surfaceId == 0) return 0;
    final callbackId = _allocateId(_ObjectKind.frameCallback);
    _surfaceByFrameCallback[callbackId] = surfaceId;
    _writer.begin(surfaceId, wlSurfaceRequestFrame);
    _writer.putNewId(callbackId);
    _queueMessage();
    return callbackId;
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
    if (buffer.busy) return;
    _finalizeShmBuffer(buffer);
  }

  /// Finishes a destroy requested by the surface. A busy `wl_buffer` must
  /// remain alive until `wl_buffer.release`; freeing its mapping earlier lets
  /// the compositor read unmapped memory during resize or shutdown.
  void _finalizeShmBuffer(_WaylandNativeShmBuffer buffer) {
    if (buffer.destroyed) return;
    buffer.destroyed = true;
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
    // Before the buffers: the cursor manager holds some of them, and the drag
    // manager may still be holding an offer whose destroy needs a live socket.
    dragDrop?.dispose();
    dragDrop = null;
    textInput?.dispose();
    textInput = null;
    cursorManager?.dispose();
    cursorManager = null;
    for (final buffer
        in List<_WaylandNativeShmBuffer>.of(_buffersById.values)) {
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

final class _WaylandDataOffer {
  _WaylandDataOffer(this.id);

  final int id;
  final Set<String> mimeTypes = <String>{};
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
  bool destroyed = false;

  /// True between a commit and the compositor's release.
  bool busy = false;

  @override
  bool get isBusy => busy;

  @override
  final Framebuffer framebuffer;
}
