/// One connection to an X server, and everything that hangs off it.
///
/// The connection owns the display socket, the interned atoms, the wake pipe
/// and the scratch buffers. Windows borrow it; they never open their own. That
/// is not tidiness - two connections to the same display cannot see each
/// other's windows for grabs, selections or focus, and a framework that opened
/// one per window would work until the first popup menu.
///
/// Nothing here allocates during an event pump. Scratch used by decoding and
/// protocol replies is allocated once at [X11Connection.open] and reused;
/// presentation owns a retained native framebuffer per window generation.
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:io' show pid;
import 'dart:typed_data';

import '../../foundation/diagnostics.dart';
import '../../foundation/lifecycle.dart';
import '../../rendering/framebuffer.dart';
import 'x11_bindings.dart';
import 'x11_clipboard.dart';
import 'x11_drag_drop.dart';
import 'x11_events.dart';
import 'x11_keyboard.dart';
import 'x11_libc.dart';
import 'x11_protocol.dart';
import 'x11_put_image_plan.dart';
import 'x11_scale.dart';
import 'x11_surface.dart';

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
  // Drag and drop. Spread rather than spelled out again so that the state
  // machine in `x11_drag_drop.dart` and this batch cannot drift apart - an
  // XDND atom that is in one list and not the other is a drag that silently
  // never starts.
  ...x11XdndAtoms,
  // The clipboard, spread for the same reason: a CLIPBOARD atom that is in one
  // list and not the other is a copy that silently never happens.
  ...x11ClipboardAtoms,
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

/// The two core-protocol requests that describe the keyboard.
///
/// A separate seam, like [X11CpuClient] and [X11DragDropClient], for the same
/// reason: it lets the backend ask "can this connection tell me what the keys
/// mean?" and answer honestly when it cannot, instead of a `null` map that
/// looks like a keyboard with no keys. A test double implements this without
/// implementing presentation or XDND.
///
/// Both methods perform a **round trip**. They are called at startup and again
/// on `MappingNotify` - never per key event.
abstract interface class X11KeyboardClient {
  /// The lowest and highest keycode the server will ever report, from the
  /// connection setup. `GetKeyboardMapping` is asked for exactly this range,
  /// because the request takes a first keycode and a count and the reply does
  /// not say which range it describes.
  int get minKeycode;
  int get maxKeycode;

  /// `GetKeyboardMapping(minKeycode, maxKeycode - minKeycode + 1)`, decoded.
  ///
  /// Null when the server refused or the reply did not parse - the state in
  /// which [X11KeyboardState.hasKeymap] is false, [KeyEvent]s still carry their
  /// keycode, and no text is ever produced.
  X11KeyboardMapping? readKeyboardMapping();

  /// `GetModifierMapping`, decoded. Null on the same terms.
  X11ModifierMapping? readModifierMapping();
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
final class X11Connection
    with DisposableMixin
    implements
        X11WindowClient,
        X11CpuClient,
        X11DragDropClient,
        X11KeyboardClient,
        X11ClipboardClient {
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
  int imageByteOrder = -1;

  /// The keycode range the server reports, from the connection setup.
  ///
  /// Defaults are the values every X server has used since the protocol was
  /// written; they are overwritten from the setup reply in [_readScreen] and
  /// exist only so that a connection that failed before the setup was read
  /// asks for a sane range instead of `0..0`.
  @override
  int minKeycode = 8;
  @override
  int maxKeycode = 255;
  int rootBitsPerPixel = 0;
  int rootScanlinePad = 0;
  int rootVisualClass = -1;
  int rootRedMask = 0;
  int rootGreenMask = 0;
  int rootBlueMask = 0;
  int blackPixel = 0;
  int whitePixel = 0;
  int screenWidthPixels = 0;
  int screenHeightPixels = 0;
  int screenWidthMillimetres = 0;
  int screenHeightMillimetres = 0;

  /// Interned atoms by name. Zero for any that failed to intern, which makes
  /// every comparison against them false rather than accidentally true.
  final Map<String, int> atoms = <String, int>{};

  /// The reverse map, filled by [atomName].
  ///
  /// XDND names the types a source offers by atom, and this framework's
  /// contract names them by MIME string, so every drag from an application
  /// that offers something unusual needs the server to spell an atom back.
  /// An empty string is cached for an atom the server does not know, so a
  /// nonexistent atom costs one round trip rather than one per position event.
  final Map<int, String> atomNames = <int, String>{};

  /// Which of [x11QueriedExtensions] the server reported as present.
  @override
  final Set<String> extensions = <String>{};

  /// Largest request the server will accept, in bytes. PutImage of a full
  /// window exceeds it by an order of magnitude, so the present path splits
  /// into row bands; see `x11_surface.dart`.
  int maximumRequestBytes = 0;
  int maximumRequestUnits = 0;

  /// Whether the root window accepts the framework's tightly-packed BGRA
  /// framebuffer without conversion.
  ///
  /// The deliberately conservative first version accepts the ubiquitous
  /// depth-24 TrueColor visual transported as 32 LSB-first bits. Depth 30,
  /// bpp24 and server-specific masks remain available to a later conversion
  /// path, but are never misreported as CPU presentation today.
  @override
  bool get supportsBgraPutImage =>
      rootDepth == 24 &&
      rootBitsPerPixel == 32 &&
      rootScanlinePad == 32 &&
      imageByteOrder == 0 &&
      rootVisualClass == 4 &&
      rootRedMask == 0x00ff0000 &&
      rootGreenMask == 0x0000ff00 &&
      rootBlueMask == 0x000000ff &&
      maximumRequestBytes > 24;

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
    maximumRequestUnits = xcb.maximumRequestLength(_handle);
    maximumRequestBytes = maximumRequestUnits * 4;
    _setupDiagnostics.add(BackendDiagnostic.note(
      supportsBgraPutImage
          ? 'root visual supports BGRA PutImage'
          : 'root visual cannot use direct BGRA PutImage',
      detail: 'depth=$rootDepth, bpp=$rootBitsPerPixel, '
          'pad=$rootScanlinePad, byteOrder=$imageByteOrder, '
          'class=$rootVisualClass, '
          'masks=${rootRedMask.toRadixString(16)}/'
          '${rootGreenMask.toRadixString(16)}/'
          '${rootBlueMask.toRadixString(16)}',
    ));

    _internWellKnownAtoms();
    _queryExtensions();
    return true;
  }

  /// Words in [valueScratch]. Covers the longest value list this backend sends
  /// (WM_SIZE_HINTS is 18) with room to spare.
  static const int _valueScratchWords = 32;

  bool _allocateScratch(List<BackendDiagnostic> diagnostics) {
    final values = libc.allocateZeroed(_valueScratchWords * 4);
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
    final screenPointer = iterator.data;
    final screen = screenPointer.ref;
    if (preferred > 0 && preferred < iterator.rem) {
      _setupDiagnostics.add(BackendDiagnostic.note(
        'DISPLAY requested screen $preferred; using screen 0',
        detail: 'multi-screen DISPLAY selection is not implemented',
      ));
    }
    root = screen.root;
    rootVisual = screen.rootVisual;
    rootDepth = screen.rootDepth;
    final XcbSetup setupFields = setup.cast<XcbSetup>().ref;
    imageByteOrder = setupFields.imageByteOrder;
    // A server that reports a reversed or empty range would make
    // `GetKeyboardMapping` fail with a Value error, so the protocol's own
    // defaults stand in rather than the nonsense being forwarded.
    if (setupFields.maxKeycode >= setupFields.minKeycode &&
        setupFields.minKeycode > 0) {
      minKeycode = setupFields.minKeycode;
      maxKeycode = setupFields.maxKeycode;
    }
    blackPixel = screen.blackPixel;
    whitePixel = screen.whitePixel;
    screenWidthPixels = screen.widthInPixels;
    screenHeightPixels = screen.heightInPixels;
    screenWidthMillimetres = screen.widthInMillimeters;
    screenHeightMillimetres = screen.heightInMillimeters;
    _readRootPixmapFormat(setup);
    _readRootVisual(screenPointer);
    return true;
  }

  void _readRootPixmapFormat(Pointer<Void> setup) {
    final storage = libc.allocateZeroed(sizeOf<XcbFormatIterator>());
    if (storage == nullptr) return;
    final iterator = storage.cast<XcbFormatIterator>();
    try {
      final value = xcb.setupPixmapFormatsIterator(setup);
      iterator.ref
        ..data = value.data
        ..rem = value.rem
        ..index = value.index;
      while (iterator.ref.rem > 0 && iterator.ref.data != nullptr) {
        final format = iterator.ref.data.ref;
        if (format.depth == rootDepth) {
          rootBitsPerPixel = format.bitsPerPixel;
          rootScanlinePad = format.scanlinePad;
          return;
        }
        xcb.formatNext(iterator);
      }
    } finally {
      libc.free(storage);
    }
  }

  void _readRootVisual(Pointer<XcbScreen> screen) {
    final depthsStorage = libc.allocateZeroed(sizeOf<XcbDepthIterator>());
    final visualsStorage = libc.allocateZeroed(sizeOf<XcbVisualTypeIterator>());
    if (depthsStorage == nullptr || visualsStorage == nullptr) {
      libc.free(depthsStorage);
      libc.free(visualsStorage);
      return;
    }
    final depths = depthsStorage.cast<XcbDepthIterator>();
    final visuals = visualsStorage.cast<XcbVisualTypeIterator>();
    try {
      final depthValue = xcb.screenAllowedDepthsIterator(screen);
      depths.ref
        ..data = depthValue.data
        ..rem = depthValue.rem
        ..index = depthValue.index;
      while (depths.ref.rem > 0 && depths.ref.data != nullptr) {
        final visualValue = xcb.depthVisualsIterator(depths.ref.data);
        visuals.ref
          ..data = visualValue.data
          ..rem = visualValue.rem
          ..index = visualValue.index;
        while (visuals.ref.rem > 0 && visuals.ref.data != nullptr) {
          final visual = visuals.ref.data.ref;
          if (visual.visualId == rootVisual) {
            rootVisualClass = visual.visualClass;
            rootRedMask = visual.redMask;
            rootGreenMask = visual.greenMask;
            rootBlueMask = visual.blueMask;
            return;
          }
          xcb.visualTypeNext(visuals);
        }
        xcb.depthNext(depths);
      }
    } finally {
      libc.free(visualsStorage);
      libc.free(depthsStorage);
    }
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

  /// The name of an interned atom, or null when the server does not know it.
  ///
  /// One round trip on a miss, none on a hit. The forward map is filled in as
  /// well: a source that drags `application/x-my-thing` gives us the atom
  /// first, and without this the [atom] lookup for the same name would answer
  /// zero and the drop would be refused for a type we can see it offering.
  @override
  String? atomName(int value) {
    if (value == 0) return null;
    final cached = atomNames[value];
    if (cached != null) return cached.isEmpty ? null : cached;
    final cookie = xcb.getAtomName(_handle, value);
    final reply = xcb.getAtomNameReply(_handle, cookie, errorScratch);
    if (reply == nullptr) {
      _drainReplyError('GetAtomName($value)');
      atomNames[value] = '';
      return null;
    }
    try {
      final length = xcb.getAtomNameLength(reply);
      if (length <= 0) {
        atomNames[value] = '';
        return null;
      }
      final bytes = xcb.getAtomNameName(reply);
      // Atom names are ISO 8859-1 by the protocol, and every one that matters
      // here is ASCII; decoding as UTF-8 would throw on a stray high byte from
      // some other client's private atom.
      final buffer = StringBuffer();
      for (var index = 0; index < length; index++) {
        buffer.writeCharCode(bytes[index]);
      }
      final name = buffer.toString();
      atomNames[value] = name;
      final existing = atoms[name];
      if (existing == null || existing == 0) atoms[name] = value;
      return name;
    } finally {
      libc.free(reply);
    }
  }

  // -------------------------------------------------------------------------
  // Properties and selections (XDND; see `x11_drag_drop.dart`)
  // -------------------------------------------------------------------------

  @override
  void setWindowProperty32(
    int window,
    int property,
    int type,
    List<int> values,
  ) {
    throwIfDisposed();
    if (window == 0 || property == 0 || type == 0) return;
    if (values.length > _valueScratchWords) {
      throw ArgumentError.value(
        values.length,
        'values',
        'the X11 property scratch buffer holds $_valueScratchWords words',
      );
    }
    for (var index = 0; index < values.length; index++) {
      valueScratch[index] = values[index] & 0xffffffff;
    }
    xcb.changeProperty(
      _handle,
      xcbPropModeReplace,
      window,
      property,
      type,
      32,
      values.length,
      valueScratch.cast<Uint8>(),
    );
  }

  @override
  void deleteWindowProperty(int window, int property) {
    if (isDisposed || window == 0 || property == 0) return;
    xcb.deleteProperty(_handle, window, property);
  }

  /// Encodes a 32-byte `ClientMessage` into [eventScratch] and sends it.
  ///
  /// Propagate is false and the event mask is empty, which is what makes the
  /// server deliver the event to [destination] itself instead of walking up to
  /// whichever ancestor happens to have selected for something.
  @override
  void sendClientMessage({
    required int destination,
    required int window,
    required int type,
    required List<int> data,
  }) {
    throwIfDisposed();
    if (destination == 0 || type == 0) return;
    for (var index = 0; index < 32; index++) {
      eventScratch[index] = 0;
    }
    eventScratch[0] = xcbClientMessage;
    eventScratch[1] = xdndClientMessageFormat;
    writeU32(eventScratch, 4, window);
    writeU32(eventScratch, 8, type);
    for (var index = 0; index < xdndClientMessageWordCount; index++) {
      writeU32(
        eventScratch,
        12 + index * 4,
        index < data.length ? data[index] & 0xffffffff : 0,
      );
    }
    xcb.sendEvent(_handle, 0, destination, 0, eventScratch);
  }

  @override
  void convertSelection({
    required int requestor,
    required int selection,
    required int target,
    required int property,
    required int time,
  }) {
    throwIfDisposed();
    if (requestor == 0 || selection == 0 || target == 0) return;
    xcb.convertSelection(
      _handle,
      requestor,
      selection,
      target,
      property,
      time,
    );
  }

  @override
  X11PropertyValue? readPropertyBytes(
    int window,
    int property, {
    required int type,
    bool delete = false,
  }) {
    final reply = _getPropertyReply(
      window,
      property,
      type,
      maxWords: _selectionMaxWords,
      delete: delete,
    );
    if (reply == null) return null;
    try {
      final length = xcb.getPropertyValueLength(reply);
      final value = xcb.getPropertyValue(reply);
      final bytes = Uint8List(length < 0 ? 0 : length);
      for (var index = 0; index < bytes.length; index++) {
        bytes[index] = value[index];
      }
      return X11PropertyValue(
        // xcb_get_property_reply_t: response_type, format, sequence, length,
        // type, bytes_after, value_len.
        type: readU32(reply, 8),
        format: reply[1],
        bytes: bytes,
      );
    } finally {
      libc.free(reply);
    }
  }

  @override
  List<int> readPropertyCardinals(
    int window,
    int property, {
    required int type,
  }) =>
      getCardinalProperty(window, property, type, <int>[]);

  @override
  X11KeyboardMapping? readKeyboardMapping() {
    throwIfDisposed();
    final int first = minKeycode;
    final int count = maxKeycode - first + 1;
    if (count <= 0 || count > 255) return null;
    final cookie = xcb.getKeyboardMapping(_handle, first, count);
    final reply = xcb.getKeyboardMappingReply(_handle, cookie, errorScratch);
    if (reply == nullptr) {
      _drainReplyError('GetKeyboardMapping($first, $count)');
      return null;
    }
    try {
      return X11KeyboardMapping.decodeReply(
        _copyReply(reply),
        firstKeycode: first,
      );
    } finally {
      libc.free(reply);
    }
  }

  @override
  X11ModifierMapping? readModifierMapping() {
    throwIfDisposed();
    final cookie = xcb.getModifierMapping(_handle);
    final reply = xcb.getModifierMappingReply(_handle, cookie, errorScratch);
    if (reply == nullptr) {
      _drainReplyError('GetModifierMapping');
      return null;
    }
    try {
      return X11ModifierMapping.decodeReply(_copyReply(reply));
    } finally {
      libc.free(reply);
    }
  }

  /// Copies a reply out of XCB's buffer into Dart memory.
  ///
  /// The whole reply, header included, because the decoders in
  /// `x11_keyboard.dart` read the header fields - `keysyms-per-keycode` lives
  /// in byte 1 and the length in bytes 4-7 - and take a [Uint8List] precisely
  /// so that a test can build one by hand with no X server in the room. The
  /// length field counts 32-bit words *after* the 32-byte header, which is
  /// what makes the total size computable without a second XCB accessor.
  Uint8List _copyReply(Pointer<Uint8> reply) {
    final int words = readU32(reply, 4);
    final int total = x11ReplyHeaderBytes + (words < 0 ? 0 : words * 4);
    final out = Uint8List(total);
    out.setAll(0, reply.asTypedList(total));
    return out;
  }

  @override
  int getSelectionOwner(int selection) {
    throwIfDisposed();
    if (selection == 0) return xcbNone;
    final cookie = xcb.getSelectionOwner(_handle, selection);
    final reply = xcb.getSelectionOwnerReply(_handle, cookie, errorScratch);
    if (reply == nullptr) {
      _drainReplyError('GetSelectionOwner($selection)');
      return xcbNone;
    }
    try {
      return readU32(reply, 8);
    } finally {
      libc.free(reply);
    }
  }

  @override
  void setSelectionOwner(int owner, int selection, int time) {
    throwIfDisposed();
    if (selection == 0) return;
    xcb.setSelectionOwner(_handle, owner, selection, time);
  }

  /// `ChangeProperty` with format 8, for a selection owner handing over bytes.
  ///
  /// Allocated per call rather than written into [valueScratch]: a dropped
  /// file list is routinely longer than the 128 bytes that buffer holds, and
  /// silently truncating a payload is the worst of the available failures -
  /// the destination gets a valid-looking `text/uri-list` with the last path
  /// cut in half.
  @override
  void setWindowPropertyBytes(
    int window,
    int property,
    int type,
    Uint8List bytes,
  ) {
    throwIfDisposed();
    if (window == 0 || property == 0 || type == 0) return;
    final buffer = libc.allocateZeroed(bytes.isEmpty ? 1 : bytes.length);
    if (buffer == nullptr) {
      recordError('malloc failed for a ${bytes.length}-byte selection value');
      return;
    }
    try {
      if (bytes.isNotEmpty) {
        buffer.asTypedList(bytes.length).setAll(0, bytes);
      }
      xcb.changeProperty(
        _handle,
        xcbPropModeReplace,
        window,
        property,
        type,
        8,
        bytes.length,
        buffer,
      );
      // Flushed before the buffer is freed: `xcb_change_property` copies into
      // the connection's own output queue, but the flush is what guarantees the
      // request is out before the SelectionNotify that announces it.
      xcb.flush(_handle);
    } finally {
      libc.free(buffer);
    }
  }

  /// `SendEvent` of a 32-byte `SelectionNotify`.
  ///
  /// The layout is fixed by the core protocol: type at 0, then pad, sequence,
  /// time at 4, requestor at 8, selection at 12, target at 16, property at 20.
  /// A property of [xcbNone] is the refusal, and sending it is required - see
  /// [X11XdndSource.handleSelectionRequest].
  @override
  void sendSelectionNotify({
    required int requestor,
    required int selection,
    required int target,
    required int property,
    required int time,
  }) {
    throwIfDisposed();
    if (requestor == 0) return;
    for (var index = 0; index < 32; index++) {
      eventScratch[index] = 0;
    }
    eventScratch[0] = xcbSelectionNotify;
    writeU32(eventScratch, 4, time);
    writeU32(eventScratch, 8, requestor);
    writeU32(eventScratch, 12, selection);
    writeU32(eventScratch, 16, target);
    writeU32(eventScratch, 20, property);
    xcb.sendEvent(_handle, 0, requestor, 0, eventScratch);
  }

  /// `QueryPointer`, for the source half's descent through the window tree.
  ///
  /// Null when the reply failed or the pointer is on another screen - the
  /// `same_screen` byte at offset 1. Both mean "there is no target here", and
  /// treating a cross-screen pointer as a hit would send XDND messages to a
  /// window the user is not over.
  @override
  X11PointerLocation? queryPointer(int window) {
    throwIfDisposed();
    if (window == 0) return null;
    final cookie = xcb.queryPointer(_handle, window);
    final reply = xcb.queryPointerReply(_handle, cookie, errorScratch);
    if (reply == nullptr) {
      _drainReplyError('QueryPointer($window)');
      return null;
    }
    try {
      if (reply[1] == 0) return null;
      return X11PointerLocation(
        child: readU32(reply, 12),
        rootX: readI16(reply, 16),
        rootY: readI16(reply, 18),
      );
    } finally {
      libc.free(reply);
    }
  }

  /// The largest `GetProperty` this connection may ask for, in 32-bit words.
  ///
  /// `long_length` is counted in words and the reply cannot exceed the server's
  /// maximum request length, so asking for more is how a large drop comes back
  /// silently truncated with no error anywhere.
  int get _selectionMaxWords {
    const replyHeaderWords = 8;
    final limit = maximumRequestUnits - replyHeaderWords;
    return limit > 0 ? limit : 16384;
  }

  /// Reads a property as bytes, or null when it is absent or unreadable.
  ///
  /// [maxWords] is in 32-bit units, as the protocol counts them.
  Pointer<Uint8>? _getPropertyReply(
    int window,
    int property,
    int type, {
    int maxWords = 16384,
    bool delete = false,
  }) {
    if (property == 0) return null;
    final cookie = xcb.getProperty(
      _handle,
      delete ? 1 : 0,
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

  // -------------------------------------------------------------------------
  // Core PutImage CPU surfaces
  // -------------------------------------------------------------------------

  @override
  X11CpuBuffer createCpuBuffer({
    required int xcbWindow,
    required int pixelWidth,
    required int pixelHeight,
  }) {
    throwIfDisposed();
    if (!supportsBgraPutImage) {
      throw StateError('root visual does not support direct BGRA PutImage');
    }
    if (xcbWindow == 0 || pixelWidth <= 0 || pixelHeight <= 0) {
      throw ArgumentError('invalid X11 CPU buffer geometry or window');
    }
    if (pixelWidth > 0x7fff || pixelHeight > 0x7fff) {
      throw RangeError(
        'core PutImage CPU buffers are limited to 32767x32767 pixels',
      );
    }
    final byteLength = pixelWidth * pixelHeight * 4;
    final pixels = libc.allocateZeroed(byteLength);
    if (pixels == nullptr) {
      throw StateError(
        'malloc failed for a ${pixelWidth}x$pixelHeight X11 CPU buffer',
      );
    }
    final gc = xcb.generateId(_handle);
    if (gc == 0) {
      libc.free(pixels);
      throw StateError('xcb_generate_id returned zero for a graphics context');
    }
    final cookie = xcb.createGcChecked(
      _handle,
      gc,
      xcbWindow,
      0,
      valueScratch,
    );
    final error = checkRequest(
      cookie,
      'CreateGC(0x${gc.toRadixString(16)})',
    );
    if (error != null) {
      libc.free(pixels);
      throw StateError(error);
    }
    try {
      return _X11NativeCpuBuffer(
        owner: this,
        xcbWindow: xcbWindow,
        gc: gc,
        pixels: pixels,
        pixelWidth: pixelWidth,
        pixelHeight: pixelHeight,
      );
    } on Object {
      // Creating the Dart view can still fail after malloc/GC succeeded (for
      // example, an address-space limit on an unusually large window).
      xcb.freeGc(_handle, gc);
      xcb.flush(_handle);
      libc.free(pixels);
      rethrow;
    }
  }

  @override
  BackendDiagnostic? presentCpuBuffer({
    required int xcbWindow,
    required X11CpuBuffer buffer,
    required X11CpuDamage damage,
  }) {
    if (isDisposed || !isValid) {
      return const BackendDiagnostic(
        kind: DiagnosticKind.connectionFailed,
        message: 'X11 connection is unavailable during PutImage',
      );
    }
    final native = _ownedCpuBuffer(buffer, xcbWindow);
    if (native == null) {
      return const BackendDiagnostic(
        kind: DiagnosticKind.incompatibleDevice,
        message: 'X11 CPU buffer does not belong to this live window',
      );
    }
    X11PutImagePlan plan;
    try {
      plan = X11PutImagePlan.create(
        pixelWidth: native.framebuffer.width,
        pixelHeight: native.framebuffer.height,
        bytesPerRow: native.framebuffer.bytesPerRow,
        maximumRequestUnits: maximumRequestUnits,
        left: damage.x,
        top: damage.y,
        width: damage.width,
        height: damage.height,
      );
    } on Object catch (error) {
      return BackendDiagnostic(
        kind: DiagnosticKind.incompatibleDevice,
        message: 'X11 PutImage request cannot represent the damage region',
        detail: '$error',
      );
    }

    for (final segment in plan.segments) {
      xcb.putImage(
        _handle,
        xcbImageFormatZPixmap,
        xcbWindow,
        native.gc,
        segment.width,
        segment.height,
        segment.x,
        segment.y,
        0,
        rootDepth,
        segment.byteLength,
        native.pixels + segment.sourceOffset,
      );
    }
    if (xcb.flush(_handle) <= 0 || !isValid) {
      return BackendDiagnostic(
        kind: DiagnosticKind.connectionFailed,
        message: 'X11 connection failed while flushing PutImage',
        detail: '${plan.segments.length} request(s), '
            '${plan.totalPayloadBytes} payload bytes',
      );
    }
    return null;
  }

  @override
  void destroyCpuBuffer(X11CpuBuffer buffer) {
    if (buffer is! _X11NativeCpuBuffer || !identical(buffer.owner, this)) {
      throw ArgumentError.value(buffer, 'buffer', 'not owned by this client');
    }
    if (buffer.released) return;
    buffer.released = true;
    try {
      if (!isDisposed && _handle != nullptr) {
        xcb.freeGc(_handle, buffer.gc);
        xcb.flush(_handle);
      }
    } finally {
      libc.free(buffer.pixels);
    }
  }

  _X11NativeCpuBuffer? _ownedCpuBuffer(
    X11CpuBuffer buffer,
    int xcbWindow,
  ) {
    if (buffer is! _X11NativeCpuBuffer ||
        !identical(buffer.owner, this) ||
        buffer.released ||
        buffer.xcbWindow != xcbWindow) {
      return null;
    }
    return buffer;
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

final class _X11NativeCpuBuffer implements X11CpuBuffer {
  _X11NativeCpuBuffer({
    required this.owner,
    required this.xcbWindow,
    required this.gc,
    required this.pixels,
    required int pixelWidth,
    required int pixelHeight,
  }) : framebuffer = Framebuffer.wrap(
          pixels.asTypedList(pixelWidth * pixelHeight * 4),
          width: pixelWidth,
          height: pixelHeight,
          bytesPerRow: pixelWidth * 4,
        );

  final X11Connection owner;
  final int xcbWindow;
  final int gc;
  final Pointer<Uint8> pixels;
  bool released = false;

  @override
  final Framebuffer framebuffer;
}
