/// One connection to an X server, and everything that hangs off it.
///
/// The connection owns the display socket, the interned atoms, the wake pipe
/// and the scratch buffers. Windows borrow it; they never open their own. That
/// is not tidiness - two connections to the same display cannot see each
/// other's windows for grabs, selections or focus, and a framework that opened
/// one per window would work until the first popup menu.
///
/// Nothing here allocates during a pump. Every buffer an event drain or a
/// present touches is allocated once, at [X11Connection.open], and reused.
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:io' show pid;

import '../../foundation/diagnostics.dart';
import '../../foundation/lifecycle.dart';
import 'x11_bindings.dart';
import 'x11_events.dart';
import 'x11_libc.dart';
import 'x11_protocol.dart';
import 'x11_scale.dart';

/// The atoms this backend interns up front, in one batch.
///
/// One round trip instead of fifteen. XCB lets every InternAtom request go out
/// before the first reply is read, and roadmap section 15.1 lists exactly that
/// control over round trips as the reason for choosing XCB over Xlib; not
/// using it here would be choosing the API and then throwing away the benefit.
const List<String> x11WellKnownAtoms = <String>[
  'WM_PROTOCOLS',
  'WM_DELETE_WINDOW',
  'WM_STATE',
  'UTF8_STRING',
  '_NET_WM_NAME',
  '_NET_WM_PID',
  '_NET_WM_STATE',
  '_NET_WM_STATE_MAXIMIZED_HORZ',
  '_NET_WM_STATE_MAXIMIZED_VERT',
  '_NET_WM_STATE_FULLSCREEN',
  '_NET_WM_STATE_HIDDEN',
  '_NET_WM_WINDOW_TYPE',
  '_NET_WM_WINDOW_TYPE_NORMAL',
  '_NET_ACTIVE_WINDOW',
  '_MOTIF_WM_HINTS',
];

/// Extensions the probe asks about by name.
///
/// `QueryExtension` needs nothing but core libxcb, so presence can be reported
/// even for extensions this backend does not yet use. RANDR is the clearest
/// example: it is not called anywhere, and saying so in the probe is how the
/// deferred per-monitor DPI work stays visible.
const List<String> x11QueriedExtensions = <String>[
  'MIT-SHM',
  'RANDR',
  'XFIXES',
  'XInputExtension',
  'Present',
  'XKEYBOARD',
];

/// The connection surface the backend itself needs.
///
/// Keeping this smaller than [X11Connection] makes connection ownership and
/// probing testable without loading libxcb in the test process. Windows keep
/// using the concrete connection because they need its protocol operations.
abstract interface class X11BackendConnection implements Disposable {
  bool get isValid;
  Set<String> get extensions;
  X11PhysicalScreen get physicalScreen;
  String? readResourceManager();
  bool signalWake();
}

/// Window and event operations exposed by a production X11 connection.
///
/// No pointer crosses this seam. That keeps [X11Window] and the backend
/// testable on Windows and macOS while [X11Connection] remains the only place
/// that knows about XCB allocation and request encoding.
abstract interface class X11WindowClient implements X11BackendConnection {
  int get root;
  int atom(String name);

  int createTopLevelWindow(X11TopLevelWindowRequest request);
  void destroyTopLevelWindow(int window);
  void mapTopLevelWindow(int window);
  void unmapTopLevelWindow(int window);
  void setTopLevelTitle(int window, String title);
  void configureTopLevelWindow(int window, X11TopLevelBounds bounds);
  void requestTopLevelRedraw(int window, X11RedrawRegion? region);

  bool pollEventInto(X11RawEvent target);
  bool waitForActivity(int timeoutMilliseconds);
  ({int x, int y})? translateToRoot(int window);
  int flush();
  void recordError(String message);
}

/// Device-pixel creation parameters for one top-level X11 window.
final class X11TopLevelWindowRequest {
  const X11TopLevelWindowRequest({
    required this.width,
    required this.height,
    required this.title,
    required this.resizable,
    required this.decorated,
    required this.visible,
    this.x,
    this.y,
  });

  final int width;
  final int height;
  final int? x;
  final int? y;
  final String title;
  final bool resizable;
  final bool decorated;
  final bool visible;
}

final class X11TopLevelBounds {
  const X11TopLevelBounds({
    required this.x,
    required this.y,
    required this.width,
    required this.height,
  });

  final int x;
  final int y;
  final int width;
  final int height;
}

final class X11RedrawRegion {
  const X11RedrawRegion({
    required this.x,
    required this.y,
    required this.width,
    required this.height,
  });

  final int x;
  final int y;
  final int width;
  final int height;
}

/// The outcome of trying to open a display.
final class X11ConnectionAttempt {
  const X11ConnectionAttempt({
    required this.connection,
    required this.diagnostics,
  });

  /// Null when the display could not be opened. [diagnostics] then names why.
  final X11BackendConnection? connection;
  final List<BackendDiagnostic> diagnostics;

  bool get succeeded => connection != null;
}

/// A live X display connection.
final class X11Connection with DisposableMixin implements X11WindowClient {
  X11Connection._(this.xcb, this.libc, this._handle);

  /// Opens `$DISPLAY`, or reports exactly what stopped it.
  ///
  /// Never throws. A caller probing three backends needs a report from each,
  /// and an exception from the second would take the third's report with it.
  static X11ConnectionAttempt open({
    required XcbBindings xcb,
    required X11Libc libc,
    String? display,
  }) {
    final diagnostics = <BackendDiagnostic>[];
    final screenNumber = libc.allocateZeroed(4).cast<Int32>();
    if (screenNumber == nullptr) {
      diagnostics.add(const BackendDiagnostic(
        kind: DiagnosticKind.connectionFailed,
        message: 'malloc failed while preparing xcb_connect',
      ));
      return X11ConnectionAttempt(
        connection: null,
        diagnostics: diagnostics,
      );
    }

    Pointer<Uint8> displayName = nullptr;
    if (display != null && display.isNotEmpty) {
      displayName = libc.allocateUtf8(display);
      if (displayName == nullptr) {
        libc.free(screenNumber.cast<Uint8>());
        diagnostics.add(const BackendDiagnostic(
          kind: DiagnosticKind.connectionFailed,
          message: 'malloc failed while encoding DISPLAY for xcb_connect',
        ));
        return X11ConnectionAttempt(
          connection: null,
          diagnostics: diagnostics,
        );
      }
    }

    Pointer<Void> handle;
    try {
      handle = xcb.connect(displayName, screenNumber);
    } on Object catch (error) {
      libc.free(displayName);
      libc.free(screenNumber.cast<Uint8>());
      diagnostics.add(BackendDiagnostic(
        kind: DiagnosticKind.connectionFailed,
        message: 'xcb_connect threw',
        detail: '$error',
      ));
      return X11ConnectionAttempt(connection: null, diagnostics: diagnostics);
    }
    libc.free(displayName);
    final preferredScreen = screenNumber.value;
    libc.free(screenNumber.cast<Uint8>());

    // xcb_connect returns a non-null handle even when it failed, and that
    // handle still has to be disconnected or the socket leaks.
    final error = handle == nullptr ? 1 : xcb.connectionHasError(handle);
    if (error != 0) {
      if (handle != nullptr) xcb.disconnect(handle);
      diagnostics.add(BackendDiagnostic(
        kind: DiagnosticKind.connectionFailed,
        message: 'xcb_connect failed',
        detail: '${xcbConnectionErrorName(error)}; DISPLAY='
            '${display ?? '(inherited)'}',
      ));
      return X11ConnectionAttempt(connection: null, diagnostics: diagnostics);
    }

    final connection = X11Connection._(xcb, libc, handle);
    bool ready;
    try {
      ready = connection._initialise(preferredScreen, diagnostics);
    } on Object catch (error) {
      diagnostics.add(BackendDiagnostic(
        kind: DiagnosticKind.connectionFailed,
        message: 'failed to initialise X11 connection',
        detail: '$error',
      ));
      try {
        connection.dispose();
      } on Object catch (disposeError) {
        diagnostics.add(BackendDiagnostic(
          kind: DiagnosticKind.connectionFailed,
          message: 'failed to close partially initialised X11 connection',
          detail: '$disposeError',
        ));
      }
      return X11ConnectionAttempt(connection: null, diagnostics: diagnostics);
    }
    if (!ready) {
      try {
        connection.dispose();
      } on Object catch (error) {
        diagnostics.add(BackendDiagnostic(
          kind: DiagnosticKind.connectionFailed,
          message: 'failed to close rejected X11 connection',
          detail: '$error',
        ));
      }
      return X11ConnectionAttempt(connection: null, diagnostics: diagnostics);
    }
    diagnostics.addAll(connection._setupDiagnostics);
    return X11ConnectionAttempt(
      connection: connection,
      diagnostics: diagnostics,
    );
  }

  final XcbBindings xcb;
  final X11Libc libc;
  final Pointer<Void> _handle;

  final DisposableBag _bag = DisposableBag();
  final List<BackendDiagnostic> _setupDiagnostics = <BackendDiagnostic>[];

  /// The last few X errors, newest last. Bounded: an application that
  /// generates errors in a loop must not also leak memory recording them.
  final List<String> recentErrors = <String>[];
  static const int _maxRecordedErrors = 32;

  Pointer<Void> get handle => _handle;

  @override
  int root = 0;
  int rootVisual = 0;
  int rootDepth = 0;
  int blackPixel = 0;
  int whitePixel = 0;
  int screenWidthPixels = 0;
  int screenHeightPixels = 0;
  int screenWidthMillimetres = 0;
  int screenHeightMillimetres = 0;

  /// Interned atoms by name. Zero for any that failed to intern, which makes
  /// every comparison against them false rather than accidentally true.
  final Map<String, int> atoms = <String, int>{};

  /// Which of [x11QueriedExtensions] the server reported as present.
  @override
  final Set<String> extensions = <String>{};

  /// Largest request the server will accept, in bytes. PutImage of a full
  /// window exceeds it by an order of magnitude, so the present path splits
  /// into row bands; see `x11_surface.dart`.
  int maximumRequestBytes = 0;

  int _fileDescriptor = -1;
  int _wakeReadFd = -1;
  int _wakeWriteFd = -1;

  /// Scratch, allocated once. Sized for the largest user of each.
  late final Pointer<Uint32> valueScratch;
  late final Pointer<Uint8> eventScratch;
  late final Pointer<Uint8> pollScratch;
  late final Pointer<Uint8> wakeScratch;
  late final Pointer<Pointer<Uint8>> errorScratch;

  @override
  bool get isValid =>
      !isDisposed && _handle != nullptr && xcb.connectionHasError(_handle) == 0;

  /// The file descriptor another isolate writes to in order to wake a blocked
  /// [waitForActivity]. See `X11WindowingBackend.wake` for why it is a pipe.
  int get wakeFileDescriptor => _wakeWriteFd;

  bool _initialise(int preferredScreen, List<BackendDiagnostic> diagnostics) {
    // Registered first, released last: every other resource here is meaningless
    // once the socket is gone, and freeing scratch that an in-flight request
    // still points at is how a teardown becomes a crash.
    _bag.add(_handle, () => xcb.disconnect(_handle));

    if (!_allocateScratch(diagnostics)) return false;
    if (!_readScreen(preferredScreen, diagnostics)) return false;
    if (!_openWakePipe(diagnostics)) return false;

    _fileDescriptor = xcb.getFileDescriptor(_handle);
    // The reply is in 4-byte units and already accounts for BIG-REQUESTS.
    maximumRequestBytes = xcb.maximumRequestLength(_handle) * 4;

    _internWellKnownAtoms();
    _queryExtensions();
    return true;
  }

  bool _allocateScratch(List<BackendDiagnostic> diagnostics) {
    // 32 words covers the longest value list this backend sends
    // (WM_SIZE_HINTS is 18) with room to spare.
    final values = libc.allocateZeroed(32 * 4);
    final event = libc.allocateZeroed(32);
    final poll = libc.allocateZeroed(2 * pollFdSize);
    final wake = libc.allocateZeroed(64);
    final errors = libc.allocateZeroed(sizeOf<Pointer<Uint8>>());
    if (values == nullptr ||
        event == nullptr ||
        poll == nullptr ||
        wake == nullptr ||
        errors == nullptr) {
      libc.free(values);
      libc.free(event);
      libc.free(poll);
      libc.free(wake);
      libc.free(errors);
      diagnostics.add(const BackendDiagnostic(
        kind: DiagnosticKind.connectionFailed,
        message: 'malloc failed while allocating X11 scratch buffers',
      ));
      return false;
    }
    valueScratch = values.cast<Uint32>();
    eventScratch = event;
    pollScratch = poll;
    wakeScratch = wake;
    errorScratch = errors.cast<Pointer<Uint8>>();
    _bag.add(values, () {
      libc.free(values);
      libc.free(event);
      libc.free(poll);
      libc.free(wake);
      libc.free(errors);
    });
    return true;
  }

  bool _readScreen(int preferred, List<BackendDiagnostic> diagnostics) {
    final setup = xcb.getSetup(_handle);
    if (setup == nullptr) {
      diagnostics.add(const BackendDiagnostic(
        kind: DiagnosticKind.connectionFailed,
        message: 'xcb_get_setup returned null',
      ));
      return false;
    }
    final iterator = xcb.setupRootsIterator(setup);
    if (iterator.rem <= 0 || iterator.data == nullptr) {
      diagnostics.add(const BackendDiagnostic(
        kind: DiagnosticKind.connectionFailed,
        message: 'X setup reported no screens',
      ));
      return false;
    }
    // Walking to `preferred` by pointer arithmetic rather than by
    // xcb_screen_next, because the screens are not a plain array - each is
    // followed by its depth and visual lists - and the iterator is the only
    // thing that knows the stride. One screen is the overwhelmingly common
    // case, and taking screen 0 when the requested one is out of range is
    // better than refusing to start.
    final screen = iterator.data.ref;
    if (preferred > 0 && preferred < iterator.rem) {
      _setupDiagnostics.add(BackendDiagnostic.note(
        'DISPLAY requested screen $preferred; using screen 0',
        detail: 'multi-screen DISPLAY selection is not implemented',
      ));
    }
    root = screen.root;
    rootVisual = screen.rootVisual;
    rootDepth = screen.rootDepth;
    blackPixel = screen.blackPixel;
    whitePixel = screen.whitePixel;
    screenWidthPixels = screen.widthInPixels;
    screenHeightPixels = screen.heightInPixels;
    screenWidthMillimetres = screen.widthInMillimeters;
    screenHeightMillimetres = screen.heightInMillimeters;
    if (rootDepth != 24 && rootDepth != 32 && rootDepth != 30) {
      _setupDiagnostics.add(BackendDiagnostic.note(
        'root depth is $rootDepth',
        detail: 'the CPU present path assumes 32 bits per pixel; a depth '
            'below 24 will present incorrect colours',
      ));
    }
    return true;
  }

  bool _openWakePipe(List<BackendDiagnostic> diagnostics) {
    final fds = libc.allocateZeroed(8).cast<Int32>();
    if (fds == nullptr) {
      diagnostics.add(const BackendDiagnostic(
        kind: DiagnosticKind.connectionFailed,
        message: 'malloc failed while preparing X11 wake pipe',
      ));
      return false;
    }
    final result = libc.pipe2(fds, oCloexec | oNonblock);
    if (result != 0) {
      diagnostics.add(BackendDiagnostic(
        kind: DiagnosticKind.connectionFailed,
        message: 'pipe2 failed; wake() will not interrupt a blocked pump',
        detail: 'errno=${libc.errno}',
      ));
      libc.free(fds.cast<Uint8>());
      return false;
    }
    _wakeReadFd = fds[0];
    _wakeWriteFd = fds[1];
    libc.free(fds.cast<Uint8>());
    _bag.add(_wakeReadFd, () {
      if (_wakeWriteFd >= 0) libc.closeFd(_wakeWriteFd);
      if (_wakeReadFd >= 0) libc.closeFd(_wakeReadFd);
      _wakeWriteFd = -1;
      _wakeReadFd = -1;
    });
    return true;
  }

  void _internWellKnownAtoms() {
    final count = x11WellKnownAtoms.length;
    final cookies = libc.allocateZeroed(count * 4);
    if (cookies == nullptr) return;
    final cookieArray = cookies.cast<XcbCookie>();
    // Every request first, every reply second. Reading a reply between two
    // requests would serialise them into one round trip each.
    for (var i = 0; i < count; i++) {
      final name = libc.allocateUtf8(x11WellKnownAtoms[i]);
      if (name == nullptr) continue;
      final cookie = xcb.internAtom(
        _handle,
        0,
        x11WellKnownAtoms[i].length,
        name,
      );
      (cookieArray + i).ref.sequence = cookie.sequence;
      libc.free(name);
    }
    for (var i = 0; i < count; i++) {
      final reply = xcb.internAtomReply(
        _handle,
        (cookieArray + i).ref,
        errorScratch,
      );
      if (reply == nullptr) {
        atoms[x11WellKnownAtoms[i]] = 0;
        _drainReplyError('InternAtom(${x11WellKnownAtoms[i]})');
        continue;
      }
      // xcb_intern_atom_reply_t: response_type, pad0, sequence, length, atom.
      atoms[x11WellKnownAtoms[i]] = readU32(reply, 8);
      libc.free(reply);
    }
    libc.free(cookies);
  }

  void _queryExtensions() {
    for (final name in x11QueriedExtensions) {
      final native = libc.allocateUtf8(name);
      if (native == nullptr) continue;
      final cookie = xcb.queryExtension(_handle, name.length, native);
      libc.free(native);
      final reply = xcb.queryExtensionReply(_handle, cookie, errorScratch);
      if (reply == nullptr) {
        _drainReplyError('QueryExtension($name)');
        continue;
      }
      // xcb_query_extension_reply_t: ..., present at byte 8.
      if (reply[8] != 0) extensions.add(name);
      libc.free(reply);
    }
  }

  /// Turns the error a `*_reply` call left in [errorScratch] into a recorded
  /// line, and frees it. Silently dropping it is what section 6.6 forbids.
  void _drainReplyError(String request) {
    final error = errorScratch.value;
    if (error == nullptr) {
      recordError('$request: reply was null with no X error');
      return;
    }
    // xcb_generic_error_t: response_type, error_code, sequence, resource_id,
    // minor_code, major_code.
    final code = error[1];
    final resource = readU32(error, 4);
    final minor = readU16(error, 8);
    final major = error[10];
    recordError('$request: ${x11ErrorName(code)} from '
        '${x11RequestName(major)} '
        '(resource 0x${resource.toRadixString(16)}, minor $minor)');
    libc.free(error);
    errorScratch.value = nullptr;
  }

  /// Appends to the bounded error ring.
  @override
  void recordError(String message) {
    recentErrors.add(message);
    if (recentErrors.length > _maxRecordedErrors) {
      recentErrors.removeAt(0);
    }
  }

  @override
  int atom(String name) => atoms[name] ?? 0;

  /// Interns an atom that is not in [x11WellKnownAtoms]. One round trip; use
  /// [atom] for anything on the hot path.
  int internAtom(String name) {
    final cached = atoms[name];
    if (cached != null) return cached;
    final native = libc.allocateUtf8(name);
    if (native == nullptr) return 0;
    final cookie = xcb.internAtom(_handle, 0, name.length, native);
    libc.free(native);
    final reply = xcb.internAtomReply(_handle, cookie, errorScratch);
    if (reply == nullptr) {
      _drainReplyError('InternAtom($name)');
      atoms[name] = 0;
      return 0;
    }
    final value = readU32(reply, 8);
    libc.free(reply);
    atoms[name] = value;
    return value;
  }

  /// Reads a property as bytes, or null when it is absent or unreadable.
  ///
  /// [maxWords] is in 32-bit units, as the protocol counts them.
  Pointer<Uint8>? _getPropertyReply(
    int window,
    int property,
    int type, {
    int maxWords = 16384,
  }) {
    if (property == 0) return null;
    final cookie = xcb.getProperty(
      _handle,
      0,
      window,
      property,
      type,
      0,
      maxWords,
    );
    final reply = xcb.getPropertyReply(_handle, cookie, errorScratch);
    if (reply == nullptr) {
      _drainReplyError('GetProperty(atom $property)');
      return null;
    }
    return reply;
  }

  /// A Latin-1 property value as a Dart string.
  ///
  /// Latin-1 rather than UTF-8 because this reads `RESOURCE_MANAGER`, which
  /// the protocol types as `STRING` (ISO 8859-1). Decoding it as UTF-8 would
  /// throw on a resource file containing a stray high byte, and the only value
  /// this backend reads out of it - `Xft.dpi` - is ASCII either way.
  String? getStringProperty(int window, int property, int type) {
    final reply = _getPropertyReply(window, property, type);
    if (reply == null) return null;
    try {
      final length = xcb.getPropertyValueLength(reply);
      if (length <= 0) return null;
      final value = xcb.getPropertyValue(reply);
      final buffer = StringBuffer();
      for (var i = 0; i < length; i++) {
        buffer.writeCharCode(value[i]);
      }
      return buffer.toString();
    } finally {
      libc.free(reply);
    }
  }

  /// A property holding a list of 32-bit values - `_NET_WM_STATE`, `WM_STATE`.
  ///
  /// Returns an empty list when absent. [into] is filled and returned so a
  /// caller polling on every PropertyNotify can reuse one list.
  List<int> getCardinalProperty(
    int window,
    int property,
    int type,
    List<int> into,
  ) {
    into.clear();
    final reply = _getPropertyReply(window, property, type, maxWords: 64);
    if (reply == null) return into;
    try {
      if (reply[1] != 32) return into;
      final length = xcb.getPropertyValueLength(reply);
      final value = xcb.getPropertyValue(reply);
      for (var offset = 0; offset + 4 <= length; offset += 4) {
        into.add(readU32(value, offset));
      }
      return into;
    } finally {
      libc.free(reply);
    }
  }

  /// The `RESOURCE_MANAGER` string on the root window, which is where
  /// `Xft.dpi` lives. Null when the display has none, which is the normal
  /// state of a bare X server and of Xvfb.
  @override
  String? readResourceManager() =>
      getStringProperty(root, xcbAtomResourceManager, xcbAtomString);

  /// The screen dimensions candidate 6 of the scale order needs.
  @override
  X11PhysicalScreen get physicalScreen => X11PhysicalScreen(
        widthInPixels: screenWidthPixels,
        heightInPixels: screenHeightPixels,
        widthInMillimetres: screenWidthMillimetres,
        heightInMillimetres: screenHeightMillimetres,
      );

  // -------------------------------------------------------------------------
  // Top-level windows
  // -------------------------------------------------------------------------

  @override
  int createTopLevelWindow(X11TopLevelWindowRequest request) {
    throwIfDisposed();
    final window = xcb.generateId(_handle);
    if (window == 0) {
      throw StateError('xcb_generate_id returned zero for a top-level window');
    }

    const eventMask = xcbEventMaskExposure |
        xcbEventMaskStructureNotify |
        xcbEventMaskFocusChange |
        xcbEventMaskPropertyChange |
        xcbEventMaskKeyPress |
        xcbEventMaskKeyRelease |
        xcbEventMaskButtonPress |
        xcbEventMaskButtonRelease |
        xcbEventMaskEnterWindow |
        xcbEventMaskLeaveWindow |
        xcbEventMaskPointerMotion;
    const valueMask = xcbCwBackPixmap |
        xcbCwBorderPixel |
        xcbCwBitGravity |
        xcbCwWinGravity |
        xcbCwEventMask;
    valueScratch[0] = xcbBackPixmapNone;
    valueScratch[1] = blackPixel;
    valueScratch[2] = xcbGravityNorthWest;
    valueScratch[3] = xcbGravityNorthWest;
    valueScratch[4] = eventMask;

    final x = _clampI16(request.x ?? 0);
    final y = _clampI16(request.y ?? 0);
    final width = _clampU16Extent(request.width);
    final height = _clampU16Extent(request.height);
    final createCookie = xcb.createWindowChecked(
      _handle,
      rootDepth,
      window,
      root,
      x,
      y,
      width,
      height,
      0,
      xcbWindowClassInputOutput,
      rootVisual,
      valueMask,
      valueScratch,
    );
    final creationError = checkRequest(
      createCookie,
      'CreateWindow(0x${window.toRadixString(16)})',
    );
    if (creationError != null) throw StateError(creationError);

    try {
      _configureTopLevelProtocols(window);
      setTopLevelTitle(window, request.title);
      _configureTopLevelIdentity(window);
      _configureTopLevelHints(window, request, width, height, x, y);
      if (request.visible) xcb.mapWindow(_handle, window);
      if (xcb.flush(_handle) <= 0 || !isValid) {
        throw StateError('X11 connection failed while publishing window '
            '0x${window.toRadixString(16)}');
      }
      return window;
    } on Object {
      xcb.destroyWindow(_handle, window);
      xcb.flush(_handle);
      rethrow;
    }
  }

  void _configureTopLevelProtocols(int window) {
    final wmProtocols = atom('WM_PROTOCOLS');
    final wmDeleteWindow = atom('WM_DELETE_WINDOW');
    if (wmProtocols == 0 || wmDeleteWindow == 0) {
      throw StateError('WM_PROTOCOLS/WM_DELETE_WINDOW atoms are unavailable');
    }
    valueScratch[0] = wmDeleteWindow;
    xcb.changeProperty(
      _handle,
      xcbPropModeReplace,
      window,
      wmProtocols,
      xcbAtomAtom,
      32,
      1,
      valueScratch.cast<Uint8>(),
    );
  }

  void _configureTopLevelIdentity(int window) {
    final pidAtom = atom('_NET_WM_PID');
    if (pidAtom != 0) {
      valueScratch[0] = pid;
      xcb.changeProperty(
        _handle,
        xcbPropModeReplace,
        window,
        pidAtom,
        xcbAtomCardinal,
        32,
        1,
        valueScratch.cast<Uint8>(),
      );
    }

    final typeAtom = atom('_NET_WM_WINDOW_TYPE');
    final normalAtom = atom('_NET_WM_WINDOW_TYPE_NORMAL');
    if (typeAtom != 0 && normalAtom != 0) {
      valueScratch[0] = normalAtom;
      xcb.changeProperty(
        _handle,
        xcbPropModeReplace,
        window,
        typeAtom,
        xcbAtomAtom,
        32,
        1,
        valueScratch.cast<Uint8>(),
      );
    }

    _changePropertyBytes(
      window,
      xcbAtomWmClass,
      xcbAtomString,
      <int>[...ascii.encode('dart_ui'), 0, ...ascii.encode('DartUi'), 0],
    );
  }

  void _configureTopLevelHints(
    int window,
    X11TopLevelWindowRequest request,
    int width,
    int height,
    int x,
    int y,
  ) {
    if (!request.resizable || request.x != null || request.y != null) {
      for (var i = 0; i < icccmSizeHintsWordCount; i++) {
        valueScratch[i] = 0;
      }
      var flags = 0;
      if (request.x != null || request.y != null) {
        flags |= icccmSizeHintUsPosition;
        valueScratch[1] = x & 0xffffffff;
        valueScratch[2] = y & 0xffffffff;
      }
      if (!request.resizable) {
        flags |= icccmSizeHintPMinSize | icccmSizeHintPMaxSize;
        valueScratch[5] = width;
        valueScratch[6] = height;
        valueScratch[7] = width;
        valueScratch[8] = height;
      }
      valueScratch[0] = flags;
      xcb.changeProperty(
        _handle,
        xcbPropModeReplace,
        window,
        xcbAtomWmNormalHints,
        xcbAtomWmSizeHints,
        32,
        icccmSizeHintsWordCount,
        valueScratch.cast<Uint8>(),
      );
    }

    if (!request.decorated) {
      final motif = atom('_MOTIF_WM_HINTS');
      if (motif != 0) {
        for (var i = 0; i < motifHintsWordCount; i++) {
          valueScratch[i] = 0;
        }
        valueScratch[0] = motifHintFlagDecorations;
        valueScratch[2] = 0;
        xcb.changeProperty(
          _handle,
          xcbPropModeReplace,
          window,
          motif,
          motif,
          32,
          motifHintsWordCount,
          valueScratch.cast<Uint8>(),
        );
      }
    }
  }

  @override
  void destroyTopLevelWindow(int window) {
    if (isDisposed || window == 0) return;
    xcb.destroyWindow(_handle, window);
    xcb.flush(_handle);
  }

  @override
  void mapTopLevelWindow(int window) {
    throwIfDisposed();
    xcb.mapWindow(_handle, window);
    xcb.flush(_handle);
  }

  @override
  void unmapTopLevelWindow(int window) {
    throwIfDisposed();
    xcb.unmapWindow(_handle, window);
    xcb.flush(_handle);
  }

  @override
  void setTopLevelTitle(int window, String title) {
    throwIfDisposed();
    final utf8Title = utf8.encode(title);
    final netWmName = atom('_NET_WM_NAME');
    final utf8String = atom('UTF8_STRING');
    if (netWmName != 0 && utf8String != 0) {
      _changePropertyBytes(window, netWmName, utf8String, utf8Title);
    }
    final legacyTitle = <int>[
      for (final rune in title.runes) rune <= 0xff ? rune : 0x3f,
    ];
    _changePropertyBytes(
      window,
      xcbAtomWmName,
      xcbAtomString,
      legacyTitle,
    );
  }

  void _changePropertyBytes(
    int window,
    int property,
    int type,
    List<int> bytes,
  ) {
    if (property == 0 || type == 0) return;
    final storage = libc.allocateZeroed(bytes.isEmpty ? 1 : bytes.length);
    if (storage == nullptr) {
      throw StateError('malloc failed while encoding X11 property $property');
    }
    try {
      if (bytes.isNotEmpty) storage.asTypedList(bytes.length).setAll(0, bytes);
      xcb.changeProperty(
        _handle,
        xcbPropModeReplace,
        window,
        property,
        type,
        8,
        bytes.length,
        storage,
      );
    } finally {
      libc.free(storage);
    }
  }

  @override
  void configureTopLevelWindow(int window, X11TopLevelBounds bounds) {
    throwIfDisposed();
    valueScratch[0] = bounds.x & 0xffffffff;
    valueScratch[1] = bounds.y & 0xffffffff;
    valueScratch[2] = _clampU16Extent(bounds.width);
    valueScratch[3] = _clampU16Extent(bounds.height);
    xcb.configureWindow(
      _handle,
      window,
      xcbConfigWindowX |
          xcbConfigWindowY |
          xcbConfigWindowWidth |
          xcbConfigWindowHeight,
      valueScratch,
    );
    xcb.flush(_handle);
  }

  @override
  void requestTopLevelRedraw(int window, X11RedrawRegion? region) {
    throwIfDisposed();
    xcb.clearArea(
      _handle,
      1,
      window,
      _clampI16(region?.x ?? 0),
      _clampI16(region?.y ?? 0),
      region == null ? 0 : _clampU16(region.width),
      region == null ? 0 : _clampU16(region.height),
    );
    xcb.flush(_handle);
  }

  @override
  bool pollEventInto(X11RawEvent target) {
    throwIfDisposed();
    final event = pollForEvent();
    if (event == nullptr) return false;
    try {
      target.decodeFrom(event);
      return true;
    } finally {
      freeEvent(event);
    }
  }

  static int _clampI16(int value) => value < -32768
      ? -32768
      : value > 32767
          ? 32767
          : value;

  static int _clampU16(int value) => value < 0
      ? 0
      : value > 65535
          ? 65535
          : value;

  static int _clampU16Extent(int value) {
    final clamped = _clampU16(value);
    return clamped == 0 ? 1 : clamped;
  }

  /// Position of [window]'s origin in root coordinates, or null on failure.
  ///
  /// One round trip, so callers coalesce: see
  /// `X11PendingWindowEvents.originDirty`.
  @override
  ({int x, int y})? translateToRoot(int window) {
    final cookie = xcb.translateCoordinates(_handle, window, root, 0, 0);
    final reply = xcb.translateCoordinatesReply(_handle, cookie, errorScratch);
    if (reply == nullptr) {
      _drainReplyError('TranslateCoordinates');
      return null;
    }
    try {
      return (x: readI16(reply, 8), y: readI16(reply, 10));
    } finally {
      libc.free(reply);
    }
  }

  /// Current geometry of [window] in device pixels, or null on failure.
  ({int x, int y, int width, int height})? geometryOf(int window) {
    final cookie = xcb.getGeometry(_handle, window);
    final reply = xcb.getGeometryReply(_handle, cookie, errorScratch);
    if (reply == nullptr) {
      _drainReplyError('GetGeometry');
      return null;
    }
    try {
      return (
        x: readI16(reply, 12),
        y: readI16(reply, 14),
        width: readU16(reply, 16),
        height: readU16(reply, 18),
      );
    } finally {
      libc.free(reply);
    }
  }

  /// Sends a request whose failure must be seen now rather than as an
  /// asynchronous error event later. Returns null on success, else the error.
  ///
  /// Costs a round trip, so it is used only where the answer changes what
  /// happens next - attaching a shared memory segment, which fails on a remote
  /// display and must fall back rather than corrupt the window.
  String? checkRequest(XcbCookie cookie, String description) {
    final error = xcb.requestCheck(_handle, cookie);
    if (error == nullptr) return null;
    final code = error[1];
    final major = error[10];
    final message = '$description failed: ${x11ErrorName(code)} from '
        '${x11RequestName(major)}';
    libc.free(error);
    recordError(message);
    return message;
  }

  @override
  int flush() => xcb.flush(_handle);

  /// The next queued event, or `nullptr`. The caller must [freeEvent] it.
  Pointer<Uint8> pollForEvent() => xcb.pollForEvent(_handle);

  /// Like [pollForEvent] but never touches the socket, so it cannot block and
  /// cannot notice a server that went away.
  Pointer<Uint8> pollForQueuedEvent() => xcb.pollForQueuedEvent(_handle);

  void freeEvent(Pointer<Uint8> event) => libc.free(event);

  /// Blocks until the display or the wake pipe has something, or [timeout]
  /// milliseconds pass. Returns true when the wake pipe fired.
  ///
  /// A negative [timeout] blocks indefinitely, which is what `poll` already
  /// means and what an idle application wants.
  @override
  bool waitForActivity(int timeout) {
    if (_fileDescriptor < 0) return false;
    writeU32(pollScratch, 0, _fileDescriptor);
    writeU16(pollScratch, 4, pollIn);
    writeU16(pollScratch, 6, 0);
    var count = 1;
    if (_wakeReadFd >= 0) {
      writeU32(pollScratch, pollFdSize, _wakeReadFd);
      writeU16(pollScratch, pollFdSize + 4, pollIn);
      writeU16(pollScratch, pollFdSize + 6, 0);
      count = 2;
    }
    final ready = libc.poll(pollScratch, count, timeout);
    if (ready <= 0) return false;
    if (count < 2) return false;
    final wakeRevents = readU16(pollScratch, pollFdSize + 6);
    if ((wakeRevents & pollIn) == 0) return false;
    _drainWakePipe();
    return true;
  }

  /// Empties the wake pipe. Reads until it would block, so that a burst of
  /// wakes collapses into one - the pipe is a doorbell, not a queue.
  void _drainWakePipe() {
    if (_wakeReadFd < 0) return;
    while (true) {
      final read = libc.read(_wakeReadFd, wakeScratch, 64);
      if (read < 64) return;
    }
  }

  /// Rings the doorbell. Safe from any thread or isolate: `write(2)` on a
  /// pipe is atomic for a single byte and needs no lock this side of libc.
  ///
  /// A full pipe means an unread wake is already pending, so `EAGAIN` is a
  /// success, not a failure.
  @override
  bool signalWake() {
    if (_wakeWriteFd < 0) return false;
    wakeScratch[0] = 1;
    final written = libc.write(_wakeWriteFd, wakeScratch, 1);
    if (written == 1) return true;
    return libc.errno == eagain;
  }

  @override
  void onDispose() {
    _bag.dispose();
  }
}
