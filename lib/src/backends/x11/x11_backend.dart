/// The X11 windowing backend, per section 15 of the roadmap.
///
/// This is the X11 entry point: it implements [WindowingBackend], opens the
/// XCB connection, resolves the scale (section 6.5 and the precedence in
/// `x11_scale.dart`), owns the display connection and routes core window
/// events and exposes a retained core PutImage CPU framebuffer when the root
/// visual accepts the framework's BGRA layout.
///
/// ## Bootstrap order
///
///   1. Open the XCB connection (or fail with diagnostics).
///   2. Read the screen's physical size and the `RESOURCE_MANAGER` property.
///   3. Resolve the scale via [resolveX11Scale].
///   4. Check for RANDR and other extensions (detected, not required).
///   5. Create windows on demand.
///   6. Pump and coalesce events in [pumpEvents].
///   7. Shutdown: dispose owned resources and disconnect.
///
/// ## What this cannot do yet, said plainly
///
///   * **No RANDR per-monitor.** The scale comes from the core protocol's
///     screen, which is the bounding box of all monitors.  Per-output
///     geometry needs `libxcb-randr` and three chained round trips; the
///     gap is documented in `x11_scale.dart` and is detected here.
///   * **No Xkb extension.** The keyboard *works* - the map comes from the core
///     protocol's own `GetKeyboardMapping` and `GetModifierMapping`, and
///     `x11_keyboard.dart` records why that route was taken - but it is limited
///     to **two layout groups**, has no per-event group and cannot negotiate
///     `DetectableAutoRepeat`, so repeat is deduced from the wire signature
///     instead. `libxcb-xkb` is the answer to those three and is the next
///     extension to add.
///   * **No IME.** XIM has no XCB equivalent: it needs Xlib and an input
///     context, so CJK is unavailable on this backend. Dead keys and AltGr are
///     not IME and do work.
///   * **No INCR selection owner.** The clipboard reads an INCR transfer but
///     cannot serve one; a payload above 200 KiB is refused rather than
///     truncated. `PRIMARY` is deliberately not modelled.
///   * **PutImage copies.** The core CPU path works on compatible TrueColor
///     visuals, but `xcb-shm` would eliminate that copy; it is detected here
///     and is the first performance extension to wire.
library;

import 'dart:io' show Platform;

import '../../foundation/diagnostics.dart';
import '../../geometry/offset.dart';
import '../../platform/clipboard.dart';
import '../../platform/compose_sequences.dart';
import '../../platform/compose_sequences_platform_stub.dart'
    if (dart.library.io) '../../platform/compose_sequences_platform_io.dart'
    as compose_platform;
import '../../platform/drag_drop.dart';
import '../../platform/native_window.dart';
import '../../platform/window_events.dart';
import 'x11_bindings.dart';
import 'x11_clipboard.dart';
import 'x11_connection.dart';
import 'x11_drag_drop.dart';
import 'x11_events.dart';
import 'x11_keyboard.dart';
import 'x11_libc.dart';
import 'x11_protocol.dart';
import 'x11_scale.dart';
import 'x11_surface.dart';
import 'x11_window.dart';

/// Opens one X11 connection for [display].
///
/// This seam is public only because `src/` backends are tested directly. A
/// production caller should use the default supplied by [X11WindowingBackend].
typedef X11ConnectionOpener = X11ConnectionAttempt Function(String display);

/// Creates and owns X11 windows.
final class X11WindowingBackend
    implements WindowingBackend, DragDropProvider, ClipboardProvider {
  X11WindowingBackend({
    bool? isLinux,
    String? operatingSystem,
    Map<String, String>? environment,
    X11ConnectionOpener? connectionOpener,
  })  : _isLinux = isLinux ?? Platform.isLinux,
        _operatingSystem = operatingSystem ?? Platform.operatingSystem,
        _environment = Map<String, String>.unmodifiable(
          environment ?? Platform.environment,
        ),
        _connectionOpener = connectionOpener ?? _openNativeConnection;

  @override
  String get name => 'x11';

  final List<X11Window> _windows = <X11Window>[];
  final Map<int, X11Window> _windowsByXid = <int, X11Window>{};
  final List<BackendDiagnostic> _diagnostics = <BackendDiagnostic>[];
  final bool _isLinux;
  final String _operatingSystem;
  final Map<String, String> _environment;
  final X11ConnectionOpener _connectionOpener;

  X11WindowClient? _connection;
  X11DragDropManager? _dragDropManager;
  X11XdndSource? _dragSource;
  X11DragDropBackend? _dragDrop;
  X11ScaleResolution? _scale;
  final X11RawEvent _rawEvent = X11RawEvent();

  /// The keyboard map, shared by every window on this connection.
  ///
  /// One per *connection* because that is what it describes: the X server's
  /// keyboard. Two windows holding two copies would disagree the moment the
  /// user switches layout and only one of them re-read the map.
  final X11KeyboardState _keyboard = X11KeyboardState();

  /// Turns the server's release/press repeat pairs back into repeats.
  ///
  /// Owned here rather than per window because it defers *one* event across
  /// the whole drain, and two filters draining the same queue would each see
  /// half the pairs. See [X11KeyRepeatFilter].
  final X11KeyRepeatFilter _keyRepeat = X11KeyRepeatFilter();

  /// The machine's own Compose table, read once at initialize.
  ComposeTable _composeTable = ComposeTable.empty;

  /// Whether the server answered `GetKeyboardMapping`.
  bool _supportsKeyboard = false;

  X11ClipboardManager? _clipboardManager;
  Clipboard? _clipboard;
  int _nextWindowId = 1;
  bool _initialized = false;
  bool _quitRequested = false; // ignore: prefer_final_fields
  bool _serverDisconnected = false;

  // Extension detection flags — set during initialize, available for diagnostics.
  // ignore: prefer_final_fields
  bool _hasRandr = false;
  // ignore: prefer_final_fields
  bool _hasShm = false;
  // ignore: prefer_final_fields
  bool _hasXkb = false;
  bool _supportsCpuPresentation = false;
  bool _supportsDragAndDrop = false;
  bool _supportsClipboard = false;

  /// Whether the server answered `GetKeyboardMapping` with a map this backend
  /// could decode, available after [probe] or [initialize].
  ///
  /// False is a *degraded* state, not a broken one: [KeyEvent]s still go out
  /// with their physical keycode and no text is ever produced. Public because
  /// `tool/x11_backend_smoke.dart` is the only place the FFI half of the
  /// keymap read is ever executed, and it has to be able to report on it.
  bool get hasKeyboardMap => _supportsKeyboard;

  /// The resolved scale, available after [probe] or [initialize].
  X11ScaleResolution? get scale => _scale;

  /// Everything worth noting since probe/init.
  List<BackendDiagnostic> get diagnostics =>
      List<BackendDiagnostic>.unmodifiable(_diagnostics);

  // ---------------------------------------------------------------------------
  // Probe
  // ---------------------------------------------------------------------------

  @override
  BackendProbeResult probe() {
    if (!_isLinux) {
      return _recordProbe(BackendProbeResult.unsupported(
        name,
        BackendDiagnostic(
          kind: DiagnosticKind.unsupportedPlatform,
          message: 'x11 needs Linux',
          detail: 'Platform.operatingSystem=$_operatingSystem',
        ),
      ));
    }

    final diagnostics = <BackendDiagnostic>[];
    final display = _getDisplay();
    if (display == null) {
      diagnostics.add(const BackendDiagnostic(
        kind: DiagnosticKind.connectionFailed,
        message: 'DISPLAY not set',
        detail: 'X11 requires a running X server; '
            'set DISPLAY or use the Wayland backend',
      ));
      _resolveScale(null, diagnostics);
      return _recordProbe(_probeResult(false, diagnostics));
    }

    diagnostics.add(BackendDiagnostic.note('DISPLAY=$display'));
    final attempt = _tryOpen(display);
    diagnostics.addAll(attempt.diagnostics);
    final connection = attempt.connection;
    var supported = false;
    try {
      final initiallyValid = connection != null && connection.isValid;
      if (initiallyValid) {
        _inspectConnection(connection, diagnostics);
        if (connection.isValid) {
          supported = connection is X11WindowClient;
          diagnostics.add(
            supported
                ? const BackendDiagnostic.note(
                    'X11 core window lifecycle is available',
                  )
                : const BackendDiagnostic(
                    kind: DiagnosticKind.rejectedByPolicy,
                    message: 'X11 connection has no window protocol client',
                  ),
          );
        } else {
          diagnostics.add(const BackendDiagnostic(
            kind: DiagnosticKind.connectionFailed,
            message: 'X11 connection became invalid after probe inspection',
          ));
        }
      } else {
        if (connection != null) {
          diagnostics.add(const BackendDiagnostic(
            kind: DiagnosticKind.connectionFailed,
            message: 'X11 connection became invalid during probe',
          ));
        }
        _resolveScale(null, diagnostics);
      }
    } on Object catch (error) {
      diagnostics.add(BackendDiagnostic(
        kind: DiagnosticKind.connectionFailed,
        message: 'failed to inspect X11 connection',
        detail: '$error',
      ));
      _resolveScale(null, diagnostics);
    } finally {
      try {
        connection?.dispose();
      } on Object catch (error) {
        supported = false;
        diagnostics.add(BackendDiagnostic(
          kind: DiagnosticKind.connectionFailed,
          message: 'failed to close X11 probe connection',
          detail: '$error',
        ));
      }
    }

    return _recordProbe(_probeResult(supported, diagnostics));
  }

  // ---------------------------------------------------------------------------
  // Initialize / Shutdown
  // ---------------------------------------------------------------------------

  @override
  Future<void> initialize() async {
    if (_initialized) return;

    if (!_isLinux || _getDisplay() == null) {
      final result = probe();
      throw BackendSelectionError(
          requested: name, attempts: <BackendProbeResult>[result]);
    }

    final display = _getDisplay()!;
    final diagnostics = <BackendDiagnostic>[
      BackendDiagnostic.note('DISPLAY=$display'),
    ];
    final attempt = _tryOpen(display);
    diagnostics.addAll(attempt.diagnostics);
    final candidate = attempt.connection;
    final connection = candidate is X11WindowClient ? candidate : null;
    if (connection == null || !connection.isValid) {
      candidate?.dispose();
      if (candidate != null) {
        diagnostics.add(const BackendDiagnostic(
          kind: DiagnosticKind.rejectedByPolicy,
          message: 'X11 connection cannot create top-level windows',
        ));
      }
      _resolveScale(null, diagnostics);
      final result = _recordProbe(_probeResult(false, diagnostics));
      throw BackendSelectionError(
          requested: name, attempts: <BackendProbeResult>[result]);
    }

    bool stillValid;
    try {
      _inspectConnection(connection, diagnostics);
      stillValid = connection.isValid;
    } on Object catch (error) {
      connection.dispose();
      diagnostics.add(BackendDiagnostic(
        kind: DiagnosticKind.connectionFailed,
        message: 'failed to initialize X11 connection',
        detail: '$error',
      ));
      final result = _recordProbe(_probeResult(false, diagnostics));
      throw BackendSelectionError(
          requested: name, attempts: <BackendProbeResult>[result]);
    }

    if (!stillValid) {
      connection.dispose();
      diagnostics.add(const BackendDiagnostic(
        kind: DiagnosticKind.connectionFailed,
        message:
            'X11 connection became invalid after initialization inspection',
      ));
      final result = _recordProbe(_probeResult(false, diagnostics));
      throw BackendSelectionError(
          requested: name, attempts: <BackendProbeResult>[result]);
    }

    diagnostics.add(const BackendDiagnostic.note(
      'X11 window lifecycle initialized',
      detail: 'core PutImage presentation is used on compatible visuals',
    ));
    _connection = connection;
    _installDragAndDrop(connection, diagnostics);
    _installClipboard(connection, diagnostics);
    _initialized = true;
    _quitRequested = false;
    _serverDisconnected = false;
    _replaceDiagnostics(diagnostics);
  }

  @override
  Future<void> shutdown() async {
    if (!_initialized && _connection == null) return;
    _initialized = false;
    // A deferred release for a window that is about to be destroyed is the
    // late-callback bug the generation token exists for.
    _keyRepeat.cancel();

    // Before the windows: a pending selection transfer holds a Completer that
    // nothing will ever answer once the socket is gone, and a drop handler
    // awaiting it would never see its future complete.
    _dragDropManager?.dispose();
    _dragDropManager = null;
    // Same reason: a paste awaiting a `SelectionNotify` that will never arrive
    // now that the socket is going is a future nothing would ever answer.
    _clipboardManager?.dispose();
    _clipboardManager = null;
    _clipboard = null;
    _dragSource?.dispose();
    _dragSource = null;
    _dragDrop = null;

    Object? firstError;
    StackTrace? firstStack;
    for (final window in List<X11Window>.of(_windows).reversed) {
      try {
        window.dispose();
      } on Object catch (error, stack) {
        firstError ??= error;
        firstStack ??= stack;
      }
    }
    _windows.clear();
    _windowsByXid.clear();

    final connection = _connection;
    _connection = null;
    try {
      connection?.dispose();
    } on Object catch (error, stack) {
      firstError ??= error;
      firstStack ??= stack;
    }
    if (firstError != null) {
      Error.throwWithStackTrace(firstError, firstStack!);
    }
  }

  // ---------------------------------------------------------------------------
  // Windows
  // ---------------------------------------------------------------------------

  @override
  List<NativeWindow> get windows => List<NativeWindow>.unmodifiable(_windows);

  @override
  Future<NativeWindow> createWindow(WindowOptions options) async {
    _requireInitialized('createWindow');
    final connection = _connection!;
    final scaleResolution = _scale;
    final resolvedScale = scaleResolution?.scale ?? 1.0;
    final window = X11Window.create(
      client: connection,
      id: NativeWindowId(_nextWindowId++),
      options: options,
      scale: resolvedScale,
      desktopScale: scaleResolution?.effectiveDesktopScale ?? resolvedScale,
      onClosed: _onWindowClosed,
    );
    window.keyboardState = _keyboard;
    // Dead keys, from this machine's own Compose table, and one engine per
    // window so that a half-typed sequence cannot finish in another one.
    //
    // Unconditional here, unlike Wayland: there is no input method on this
    // backend to compose them already (XIM is not implemented), so nothing can
    // apply the accent twice.
    if (!_composeTable.isEmpty) {
      window.composeEngine = ComposeEngine(_composeTable);
    }
    if (_windowsByXid.containsKey(window.xcbWindow)) {
      window.dispose();
      throw StateError(
        'XCB reused live window id 0x${window.xcbWindow.toRadixString(16)}',
      );
    }
    _windows.add(window);
    _windowsByXid[window.xcbWindow] = window;
    _quitRequested = false;
    return window;
  }

  // ---------------------------------------------------------------------------
  // Event pump
  // ---------------------------------------------------------------------------

  @override
  bool pumpEvents({Duration timeout = Duration.zero}) {
    _requireInitialized('pumpEvents');
    if (_quitRequested) return false;
    final connection = _connection!;
    var drained = _drainQueuedEvents(connection);
    if (drained == 0 && timeout != Duration.zero) {
      final milliseconds = timeout.isNegative
          ? -1
          : timeout.inMicroseconds == 0
              ? 0
              : (timeout.inMicroseconds / 1000).ceil();
      connection.waitForActivity(milliseconds);
      drained += _drainQueuedEvents(connection);
    }
    if (!connection.isValid) {
      if (!_serverDisconnected) {
        _serverDisconnected = true;
        _diagnostics.add(const BackendDiagnostic(
          kind: DiagnosticKind.connectionFailed,
          message: 'X11 server connection was lost during event pump',
        ));
      }
      _quitRequested = true;
      return false;
    }
    if (drained > 0) {
      for (final window in List<X11Window>.of(_windows)) {
        window.flushPendingEvents();
      }
    }
    return !_quitRequested;
  }

  int _drainQueuedEvents(X11WindowClient connection) {
    // A fixed budget prevents a producer flooding MotionNotify from starving
    // Dart tasks forever. Remaining events stay queued for the next pump.
    const budget = 4096;
    var drained = 0;
    while (drained < budget && connection.pollEventInto(_rawEvent)) {
      drained++;
      if (_rawEvent.type == xcbError) {
        connection.recordError(_rawEvent.describeError());
        continue;
      }
      // Offered to XDND before anything is routed by window. A SelectionNotify
      // is addressed to a window but is *about* a transfer, so `_windowsByXid`
      // is the wrong index for it, and an XDND ClientMessage consumed here must
      // not also reach the window's WM_PROTOCOLS handling.
      if (_offerToDragAndDrop(_rawEvent)) continue;
      // Every routed event goes through the repeat filter, not only the key
      // ones: the filter holds a `KeyRelease` back until the next event says
      // what it was, and an event that skipped the filter would overtake the
      // release it is meant to follow.
      if (_offerToClipboard(_rawEvent)) continue;
      _keyRepeat.accept(_rawEvent, _routeRawEvent);
    }
    // A key released as the last event of a pump must not wait for the next
    // one to be delivered - that is a keyboard that feels stuck.
    _keyRepeat.flush(_routeRawEvent);
    return drained;
  }

  /// Delivers one decoded event to whatever owns it.
  ///
  /// Separate from the drain loop because [X11KeyRepeatFilter] calls it too,
  /// with a release it held back, and that release has to take the same route.
  void _routeRawEvent(X11RawEvent raw) {
    final connection = _connection;
    if (connection == null) return;
    if (raw.type == xcbMappingNotify) {
      _handleMappingNotify(raw);
      return;
    }
    if (raw.type == xcbPropertyNotify && raw.window == connection.root) {
      for (final window in _windows) {
        window.handleRawEvent(raw);
      }
      return;
    }
    _windowsByXid[raw.window]?.handleRawEvent(raw);
  }

  /// Re-reads the keyboard map after the user changed their layout.
  ///
  /// The whole map, not the range the event names: merging a partial reply
  /// into an existing map means reconciling two replies that may have
  /// different `keysyms-per-keycode`, and the event arrives when a human
  /// pressed a layout-switch key - a round trip there is free. A pointer
  /// mapping change is not this backend's business and is ignored by name
  /// rather than by falling through.
  void _handleMappingNotify(X11RawEvent raw) {
    if (raw.mode == x11MappingPointer) return;
    final connection = _connection;
    if (connection is! X11KeyboardClient) return;
    // A repeat pair straddling a remap would be matched against a keycode that
    // now means something else.
    _keyRepeat.cancel();
    _readKeyboardMap(connection as X11KeyboardClient, null);
  }

  /// Reads both halves of the keyboard map into [_keyboard].
  ///
  /// [diagnostics] is null when this is a re-read after `MappingNotify`: the
  /// probe report is a startup document, and appending a line to it on every
  /// layout switch would make it grow without bound in a long-running process.
  /// A *failure* is still recorded, on the connection's bounded error ring.
  void _readKeyboardMap(
    X11KeyboardClient client,
    List<BackendDiagnostic>? diagnostics,
  ) {
    final X11KeyboardMapping? keyboard = client.readKeyboardMapping();
    final X11ModifierMapping? modifiers = client.readModifierMapping();
    if (keyboard == null) {
      _supportsKeyboard = false;
      diagnostics?.add(const BackendDiagnostic(
        kind: DiagnosticKind.note,
        message: 'GetKeyboardMapping produced no usable keyboard map',
        detail: 'KeyEvents still carry their physical keycode; no text is '
            'produced, because guessing a character from a keycode is the one '
            'thing a backend that cannot translate must not do',
      ));
      return;
    }
    _supportsKeyboard = true;
    _keyboard.adopt(
      keyboard: keyboard,
      modifiers: modifiers,
      source: 'core-keyboard-mapping',
    );
    diagnostics?.add(BackendDiagnostic.note(
      'keyboard: ${keyboard.keycodeCount} keycodes from '
      '${keyboard.firstKeycode}, ${keyboard.keysymsPerKeycode} keysyms each',
      detail: 'modifiers resolved by keysym: ${_keyboard.semantics.describe()}',
    ));
  }

  void _onWindowClosed(X11Window window) {
    _windowsByXid.remove(window.xcbWindow);
    _windows.remove(window);
    // The XdndAware property dies with the window, but the manager's session
    // does not: a drag that was over this window has to stop being tracked, or
    // the next `XdndPosition` would be answered on behalf of a dead target.
    _dragDropManager?.unregisterWindow(window.xcbWindow);
    if (_initialized && _windows.isEmpty) _quitRequested = true;
  }

  // ---------------------------------------------------------------------------
  // Drag and drop
  // ---------------------------------------------------------------------------

  /// Never null: a connection that cannot speak XDND answers with an
  /// [UnavailableDragDrop] carrying the reason, so a registration fails where
  /// the caller can see it instead of producing a drop that never arrives.
  @override
  DragDropBackend get dragAndDrop =>
      _dragDrop ??
      UnavailableDragDrop(
        name: 'xdnd',
        reason: _initialized
            ? 'this X11 connection does not implement the XDND client seam'
            : 'x11.dragAndDrop before initialize()',
      );

  void _installDragAndDrop(
    X11WindowClient connection,
    List<BackendDiagnostic> diagnostics,
  ) {
    if (connection is! X11DragDropClient) {
      // A note, not a failure: the windowing backend is perfectly usable
      // without drag and drop, and `dragAndDrop` already names the reason at
      // the moment a caller tries to register a target.
      diagnostics.add(const BackendDiagnostic.note(
        'XDND is unavailable on this X11 connection',
        detail: 'the connection does not implement X11DragDropClient',
      ));
      return;
    }
    final manager = X11DragDropManager(
      connection as X11DragDropClient,
      rootToClient: _rootToClient,
      scaleOf: _windowScale,
    );
    final source = X11XdndSource(connection as X11DragDropClient);
    _dragDropManager = manager;
    _dragSource = source;
    _dragDrop = X11DragDropBackend(
      manager: manager,
      xcbWindowOf: _xcbWindowOf,
    )
      ..source = source
      ..rootWindow = connection.root
      ..currentTime = () => _lastEventTime;
    diagnostics.add(const BackendDiagnostic.note(
      'XDND is available in both directions',
      detail: 'protocol version $xdndVersion, sources from '
          '$xdndMinimumVersion up; a drag started here owns XdndSelection and '
          'serves the payload from SelectionRequest',
    ));
  }

  // ---------------------------------------------------------------------------
  // Clipboard
  // ---------------------------------------------------------------------------

  /// Never null: a connection whose clipboard is unavailable answers with an
  /// [UnavailableClipboard] carrying the reason, so a Ctrl+V fails where the
  /// caller can see why instead of collapsing into "no clipboard configured".
  @override
  Clipboard get clipboard =>
      _clipboard ??
      UnavailableClipboard(
        _initialized
            ? 'this X11 connection does not implement the selection requests '
                'a clipboard needs'
            : 'x11.clipboard before initialize()',
      );

  void _installClipboard(
    X11WindowClient connection,
    List<BackendDiagnostic> diagnostics,
  ) {
    if (connection is! X11ClipboardClient) {
      diagnostics.add(const BackendDiagnostic.note(
        'the clipboard is unavailable on this X11 connection',
        detail: 'the connection does not implement X11ClipboardClient',
      ));
      return;
    }
    final manager = X11ClipboardManager(
      connection as X11ClipboardClient,
      // A selection needs one of our windows to hang properties on. The first
      // one is as good as any and the choice is re-made per call, so a
      // clipboard operation after the original window closed uses a live one.
      windowOf: () => _windows.isEmpty ? xcbNone : _windows.first.xcbWindow,
      timeOf: () => _lastEventTime,
    );
    _clipboardManager = manager;
    _clipboard = X11Clipboard(manager);
    diagnostics.add(const BackendDiagnostic.note(
      'the clipboard reads and writes CLIPBOARD as UTF8_STRING',
      detail: 'STRING is accepted as a fallback on read and offered on write; '
          'an INCR transfer is assembled on read but not served on write, and '
          'PRIMARY is deliberately not modelled as a second clipboard',
    ));
  }

  /// Gives one decoded event to the clipboard. True when it was consumed.
  ///
  /// After the XDND offer, never before: a drag started here owns
  /// `XdndSelection`, and the arbitration between the two is by selection atom
  /// - each machine answers false for a selection that is not its own.
  bool _offerToClipboard(X11RawEvent raw) {
    final manager = _clipboardManager;
    if (manager == null) return false;
    switch (raw.type) {
      case xcbSelectionNotify:
        return manager.handleSelectionNotify(
          requestor: raw.window,
          selection: raw.selection,
          target: raw.target,
          property: raw.property,
        );
      case xcbSelectionRequest:
        return manager.handleSelectionRequest(
          requestor: raw.requestor,
          selection: raw.selection,
          target: raw.target,
          property: raw.property,
          time: raw.timestamp,
        );
      case xcbSelectionClear:
        return manager.handleSelectionClear(raw.selection);
      case xcbPropertyNotify:
        // Only an INCR transfer in flight consumes one; every other
        // PropertyNotify still reaches the window that selected for it.
        return manager.handlePropertyNotify(
          window: raw.window,
          atom: raw.atom,
          state: raw.mode,
        );
      default:
        return false;
    }
  }

  /// The newest server timestamp seen, which every XDND message must carry.
  ///
  /// X refuses a `SetSelectionOwner` with a stale time and ignores an
  /// `XdndDrop` that carries one, so guessing - or worse, sending
  /// `CurrentTime` - is how a drag silently fails to take its own selection.
  /// Updated from every event that carries a time; see [_recordEventTime].
  int _lastEventTime = 0;

  /// Remembers the newest server time an event carried.
  void _recordEventTime(X11RawEvent raw) {
    if (raw.timestamp > _lastEventTime) _lastEventTime = raw.timestamp;
  }

  /// Gives one decoded event to the XDND machines. True when it was consumed.
  ///
  /// The **source** is offered every event first, and that order is the whole
  /// of the arbitration between the two halves: a drag started here owns the
  /// `XdndStatus`, `XdndFinished`, `SelectionRequest` and `SelectionClear` that
  /// answer it, while everything else belongs to the destination. Offering them
  /// to the destination first would let a status meant for our own drag be
  /// mistaken for a message from a foreign source.
  bool _offerToDragAndDrop(X11RawEvent raw) {
    _recordEventTime(raw);
    final source = _dragSource;
    if (source != null) {
      switch (raw.type) {
        case xcbClientMessage:
          if (source.handleClientMessage(
            type: raw.atom,
            window: raw.window,
            data: <int>[raw.data0, raw.data1, raw.data2, raw.data3, raw.data4],
          )) {
            return true;
          }
        case xcbSelectionRequest:
          if (source.handleSelectionRequest(
            requestor: raw.requestor,
            selection: raw.selection,
            target: raw.target,
            property: raw.property,
            time: raw.timestamp,
          )) {
            return true;
          }
        case xcbSelectionClear:
          if (source.handleSelectionClear(raw.selection)) return true;
        default:
          break;
      }
    }
    final manager = _dragDropManager;
    if (manager == null) return false;
    switch (raw.type) {
      case xcbClientMessage:
        return manager.handleClientMessage(
          window: raw.window,
          messageType: raw.atom,
          format: raw.detail,
          data0: raw.data0,
          data1: raw.data1,
          data2: raw.data2,
          data3: raw.data3,
          data4: raw.data4,
        );
      case xcbSelectionNotify:
        return manager.handleSelectionNotify(
          requestor: raw.window,
          selection: raw.selection,
          target: raw.target,
          property: raw.property,
        );
      default:
        return false;
    }
  }

  /// `XdndPosition` reports root-window device pixels; a handler hit-tests in
  /// the same logical client-area units a `PointerEvent` carries.
  Offset _rootToClient(int xcbWindow, int rootX, int rootY) {
    final window = _windowsByXid[xcbWindow];
    if (window == null) {
      return Offset(rootX.toDouble(), rootY.toDouble());
    }
    final scale = window.renderScale;
    return window.screenToClient(Offset(rootX / scale, rootY / scale));
  }

  double _windowScale(int xcbWindow) =>
      _windowsByXid[xcbWindow]?.renderScale ?? _scale?.scale ?? 1.0;

  int _xcbWindowOf(NativeWindow window) {
    for (final candidate in _windows) {
      if (identical(candidate, window)) return candidate.xcbWindow;
    }
    return 0;
  }

  @override
  void wake() {
    _connection?.signalWake();
  }

  // ---------------------------------------------------------------------------
  // Internals
  // ---------------------------------------------------------------------------

  static X11ConnectionAttempt _openNativeConnection(String display) {
    final diagnostics = <BackendDiagnostic>[];
    final xcb = XcbBindings.load(diagnostics);
    if (xcb == null) {
      return X11ConnectionAttempt(connection: null, diagnostics: diagnostics);
    }
    final libc = X11Libc.open(diagnostics);
    if (libc == null) {
      return X11ConnectionAttempt(connection: null, diagnostics: diagnostics);
    }
    final attempt = X11Connection.open(xcb: xcb, libc: libc, display: display);
    return X11ConnectionAttempt(
      connection: attempt.connection,
      diagnostics: <BackendDiagnostic>[
        ...diagnostics,
        ...attempt.diagnostics,
      ],
    );
  }

  X11ConnectionAttempt _tryOpen(String display) {
    try {
      return _connectionOpener(display);
    } on Object catch (error) {
      return X11ConnectionAttempt(
        connection: null,
        diagnostics: <BackendDiagnostic>[
          BackendDiagnostic(
            kind: DiagnosticKind.connectionFailed,
            message: 'X11 connection opener threw',
            detail: '$error',
          ),
        ],
      );
    }
  }

  void _inspectConnection(
    X11BackendConnection connection,
    List<BackendDiagnostic> diagnostics,
  ) {
    final extensions = connection.extensions;
    _hasRandr = extensions.contains('RANDR');
    _hasShm = extensions.contains('MIT-SHM');
    _hasXkb = extensions.contains('XKEYBOARD');
    final cpuClient =
        connection is X11CpuClient ? connection as X11CpuClient : null;
    _supportsCpuPresentation = cpuClient?.supportsBgraPutImage ?? false;
    // XDND rides on the core protocol, so there is no extension to detect: the
    // only question is whether this connection exposes the requests the state
    // machine needs, which is exactly what the seam says.
    _supportsDragAndDrop = connection is X11DragDropClient;
    // Selections are core protocol too: the only question is whether this
    // connection exposes the requests, which is what the seam says.
    _supportsClipboard = connection is X11ClipboardClient;
    _supportsKeyboard = false;
    if (connection is X11KeyboardClient) {
      _readKeyboardMap(connection as X11KeyboardClient, diagnostics);
    } else {
      diagnostics.add(const BackendDiagnostic.note(
        'this X11 connection does not expose the keyboard map requests',
        detail: 'KeyEvents carry their physical keycode and no text is '
            'produced; Capability.keyboardInput is not claimed',
      ));
    }
    _composeTable = _supportsKeyboard
        ? compose_platform.loadSystemComposeTable()
        : ComposeTable.empty;
    _resolveScale(connection, diagnostics);
    diagnostics.add(BackendDiagnostic.note(
      'extensions: randr=${_hasRandr ? "yes" : "no"}, '
      'shm=${_hasShm ? "yes" : "no"}, xkb=${_hasXkb ? "yes" : "no"}',
    ));
    diagnostics.add(BackendDiagnostic.note(
      _supportsCpuPresentation
          ? 'core BGRA PutImage presentation is available'
          : 'core BGRA PutImage presentation is unavailable',
    ));
    diagnostics.add(BackendDiagnostic.note(
      _supportsDragAndDrop
          ? 'XDND drop targets are available; dragging out is not implemented'
          : 'XDND is unavailable on this connection',
    ));
    diagnostics.add(BackendDiagnostic.note(
      'core mouse motion, buttons, crossings and wheel are normalized; '
      'keyboard is ${_supportsKeyboard ? 'the core protocol map '
          '(GetKeyboardMapping and GetModifierMapping)' : 'unavailable'}',
      detail: _supportsKeyboard
          ? 'XKB is detected but not used: the core map covers two groups and '
              'has no DetectableAutoRepeat, so repeat is recognised from the '
              'release/press pair instead. See x11_keyboard.dart for what that '
              'costs and what it does not cover.'
          : null,
    ));
    diagnostics.add(BackendDiagnostic.note(
      _composeTable.isEmpty
          ? 'no X11 Compose table was found; dead keys will not compose'
          : 'dead keys compose from the X11 Compose table '
              '(${_composeTable.sequenceCount} sequences, '
              '${_composeTable.skippedSequences} lines not understood)',
    ));
    diagnostics.add(const BackendDiagnostic.note(
      'no input method: XIM is not implemented, so CJK is unavailable here',
      detail: 'dead keys and AltGr are not IME and do work - they are the '
          'keymap plus platform/compose_sequences.dart. Full composition needs '
          'XIM (which needs Xlib and an input context) or ibus over its own '
          'protocol; see doc/architecture/overview.md.',
    ));
  }

  void _resolveScale(
    X11BackendConnection? connection,
    List<BackendDiagnostic> diagnostics,
  ) {
    _scale = resolveX11Scale(
      dartUiScaleEnvironment: _env('DART_UI_SCALE'),
      gdkScaleEnvironment: _env('GDK_SCALE'),
      qtScaleFactorEnvironment: _env('QT_SCALE_FACTOR'),
      resourceDatabase: connection?.readResourceManager(),
      screen: connection?.physicalScreen,
    );
    diagnostics.add(_scale!.toDiagnostic());
  }

  BackendProbeResult _probeResult(
    bool supported,
    List<BackendDiagnostic> diagnostics,
  ) {
    return BackendProbeResult(
      backendName: name,
      supported: supported,
      capabilities: supported
          ? <Capability>{
              Capability.window,
              Capability.multipleWindows,
              Capability.pointerInput,
              Capability.scrollInput,
              Capability.orderlyShutdown,
              if (_supportsKeyboard) Capability.keyboardInput,
              if (_supportsCpuPresentation) Capability.cpuPresentation,
              if (_supportsDragAndDrop) Capability.dragAndDrop,
              if (_supportsClipboard) Capability.clipboardText,
            }
          : const <Capability>{},
      diagnostics: diagnostics,
    );
  }

  BackendProbeResult _recordProbe(BackendProbeResult result) {
    _replaceDiagnostics(result.diagnostics);
    return result;
  }

  void _replaceDiagnostics(Iterable<BackendDiagnostic> diagnostics) {
    _diagnostics
      ..clear()
      ..addAll(diagnostics);
  }

  String? _getDisplay() {
    final display = _env('DISPLAY');
    return display == null || display.trim().isEmpty ? null : display;
  }

  String? _env(String name) => _environment[name];

  void _requireInitialized(String operation) {
    if (!_initialized) {
      throw StateError('$name.$operation before initialize()');
    }
  }

  @override
  String toString() => 'X11WindowingBackend(initialized: $_initialized, '
      'windows: ${_windows.length}, scale: ${_scale?.scale})';
}
