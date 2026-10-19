/// The fourth macOS backend, `appkitEmbedded`: AppKit in this process, on
/// the process main thread, with the Dart runtime as the guest of the
/// application's run loop (`doc/MACOS_TRES_BACKENDS.md`, backend 4).
///
/// What the iOS backend does with UIKit (ADR 0010), for AppKit. The app's
/// executable is the Dart AOT runtime built from source with
/// `tool/mobile/dart_sdk_patches/3.13.5-macos.patch`; it handles the main
/// isolate's messages on the main thread from a `CFRunLoop` source and, when
/// this backend asks, runs `[NSApp run]` on that loop. So:
///
///   * Dart calls AppKit directly, with plain `objc_msgSend`, never from
///     another thread and never by signal - no host process, no pipe;
///   * AppKit calls Dart back synchronously (`NativeCallable.isolateLocal`),
///     for events, delegate questions and notifications;
///   * every window is in one process, so a menu is a child window of its
///     owner (`addChildWindow:ordered:`): z-order and movement follow the
///     owner, and opening one costs a window, not a process;
///   * Dart's own messages keep flowing during a live resize or a menu's
///     tracking: the source is in the common modes.
///
/// The backend never blocks: [pumpEvents] returns at once and the
/// application loop awaits [waitForEvents] instead (EventLoopWaitingBackend),
/// because blocking the isolate would block the run loop it lives on.
///
/// Microtasks: AppKit calls into Dart outside any message, so what a callback
/// schedules - a future's completion, a stream event - would wait for the
/// next message. After every callback this backend sends itself an empty
/// one (`RELATORIO_DART_PURO_ANDROID_IOS.md`, section 2.4), coalesced.
library;

import 'dart:async';
import 'dart:ffi';
import 'dart:isolate';

import '../../../ffi/objc_runtime.dart';
import '../../../foundation/diagnostics.dart';
import '../../../geometry/offset.dart';
import '../../../geometry/rect.dart';
import '../../../platform/native_window.dart';
import '../../../platform/window_events.dart';
import '../../apple/cocoa_ffi.dart';
import '../macos_backend_kind.dart';
import 'embedded_appkit.dart';
import 'embedded_runtime.dart';
import 'embedded_window.dart';

/// The name the resolver registers this backend under.
const String macosEmbeddedBackendName = 'macos-embedded';

final class MacosEmbeddedWindowingBackend
    implements
        WindowingBackend,
        EventLoopWaitingBackend,
        ScreenProvider,
        MacosEmbeddedSink {
  MacosEmbeddedWindowingBackend({
    MacosEmbeddedRuntimeStatus Function()? runtimeStatus,
    void Function()? requestRunApplication,
    this.applicationName,
  })  : _runtimeStatus = runtimeStatus ?? (() => MacosEmbeddedRuntime.status),
        _requestRunApplication =
            requestRunApplication ?? MacosEmbeddedRuntime.requestRunApplication;

  final MacosEmbeddedRuntimeStatus Function() _runtimeStatus;

  /// Starts the application loop after delegates and menus are installed.
  /// A supplied adapter must run on the process main thread, deliver the
  /// launch notification and continue native event dispatch without blocking
  /// Dart progress. The default retains the patched SDK runtime's behavior.
  final void Function() _requestRunApplication;

  /// Shown in the application menu's Hide and Quit items; the process name
  /// when null.
  final String? applicationName;

  final List<MacosEmbeddedWindow> _windows = <MacosEmbeddedWindow>[];
  final Completer<void> _launched = Completer<void>();
  MacosEmbeddedClasses? _classes;
  Pointer<ObjCObject> _application = nullptr;
  Pointer<ObjCObject> _applicationDelegate = nullptr;
  Pointer<ObjCObject> _windowDelegate = nullptr;
  RawReceivePort? _kick;
  bool _kickPending = false;
  Completer<void>? _waiter;
  int _nextWindowId = 1;
  bool _initialized = false;
  bool _quitRequested = false;

  /// How long `initialize` took from asking for `[NSApp run]` to
  /// `applicationDidFinishLaunching:`, for the startup measurement.
  Duration? launchDuration;

  @override
  String get name => 'macos.${MacosBackendKind.appkitEmbedded.name}';

  @override
  BackendProbeResult probe() {
    final MacosEmbeddedRuntimeStatus status = _runtimeStatus();
    final bool active = status.isActive;
    final MacosBackendCapabilities capabilities = MacosBackendCapabilities(
      kind: MacosBackendKind.appkitEmbedded,
      canCreateWindow: active,
      hasInput: active,
      hasIme: false,
      hasAccessibility: false,
      hasOrderlyShutdown: active,
      needsHostBinary: false,
      diagnostics: <BackendDiagnostic>[
        if (active)
          BackendDiagnostic.note(status.description)
        else
          BackendDiagnostic(
            kind: status == MacosEmbeddedRuntimeStatus.notMacos
                ? DiagnosticKind.unsupportedPlatform
                : DiagnosticKind.missingSymbol,
            message: 'appkitEmbedded: ${status.description}',
          ),
      ],
    );
    final BackendProbeResult result = capabilities.toProbeResult();
    return BackendProbeResult(
      backendName: name,
      supported: result.supported,
      capabilities: result.capabilities,
      diagnostics: result.diagnostics,
    );
  }

  @override
  Future<void> initialize() async {
    if (_initialized) return;
    final MacosEmbeddedRuntimeStatus status = _runtimeStatus();
    if (!status.isActive) {
      throw UnsupportedCapabilityError(
        backendName: name,
        capability: Capability.window,
        detail: status.description,
      );
    }
    try {
      DynamicLibrary.open('/System/Library/Frameworks/AppKit.framework/AppKit');
      DynamicLibrary.open(
          '/System/Library/Frameworks/QuartzCore.framework/QuartzCore');
      _kick = RawReceivePort(
          (Object? _) => _kickPending = false, 'dart_ui macos embedded')
        // The program ends when its own ports close, not this one.
        ..keepIsolateAlive = false;
      final MacosEmbeddedClasses classes =
          _classes = MacosEmbeddedClasses.register();
      MacosEmbeddedClasses.sink = this;
      ObjCAutoreleasePool.run(() {
        _application = objcRetain(objcSendPointer(
            objcClass('NSApplication'), objcSelector('sharedApplication')));
        // NSApplicationActivationPolicyRegular: a Dock icon and a menu bar.
        objcSendVoid1(_application, objcSelector('setActivationPolicy:'), 0);
        _applicationDelegate =
            objcSendPointer(classes.applicationDelegate, objcSelector('new'));
        objcSendVoid1(_application, objcSelector('setDelegate:'),
            _applicationDelegate.address);
        _windowDelegate =
            objcSendPointer(classes.windowDelegate, objcSelector('new'));
        _installMainMenu();
      });
      final Stopwatch launch = Stopwatch()..start();
      _requestRunApplication();
      // The patched runtime runs [NSApp run] after this message. A supplied
      // adapter may call finishLaunching and notify the delegate synchronously;
      // the completed launch future is valid in either case.
      await _launched.future.timeout(const Duration(seconds: 30));
      launchDuration = launch.elapsed;
      ObjCAutoreleasePool.run(() => objcSendVoid1(
          _application, objcSelector('activateIgnoringOtherApps:'), 1));
      _initialized = true;
    } catch (_) {
      // Initialization may fail after a kick port, callbacks or Objective-C
      // objects were installed. Release those resources even before success.
      await shutdown();
      rethrow;
    }
  }

  /// The application menu - Hide, Quit - and a Window menu - Minimise,
  /// Close - with their standard key equivalents. Quit asks the framework to
  /// close the windows (applicationShouldTerminate: answers Cancel).
  void _installMainMenu() {
    final String app = applicationName ??
        dartString(objcSendPointer(
            objcSendPointer(
                objcClass('NSProcessInfo'), objcSelector('processInfo')),
            objcSelector('processName')));
    Pointer<ObjCObject> item(String title, String action, String key) =>
        objcAutorelease(objcSendPointer3(
          objcSendPointer(objcClass('NSMenuItem'), objcSelector('alloc')),
          objcSelector('initWithTitle:action:keyEquivalent:'),
          nsString(title).address,
          action.isEmpty ? 0 : objcSelector(action).address,
          nsString(key).address,
        ));
    Pointer<ObjCObject> menu(String title, List<Pointer<ObjCObject>> items) {
      final Pointer<ObjCObject> menu = objcAutorelease(objcSendPointer1(
          objcSendPointer(objcClass('NSMenu'), objcSelector('alloc')),
          objcSelector('initWithTitle:'),
          nsString(title).address));
      for (final Pointer<ObjCObject> entry in items) {
        objcSendVoid1(menu, objcSelector('addItem:'), entry.address);
      }
      return menu;
    }

    final Pointer<ObjCObject> bar = menu('', <Pointer<ObjCObject>>[]);
    for (final (String title, List<Pointer<ObjCObject>> items)
        in <(String, List<Pointer<ObjCObject>>)>[
      (
        app,
        <Pointer<ObjCObject>>[
          item('Hide $app', 'hide:', 'h'),
          item('Quit $app', 'terminate:', 'q'),
        ]
      ),
      (
        'Window',
        <Pointer<ObjCObject>>[
          item('Minimize', 'performMiniaturize:', 'm'),
          item('Close', 'performClose:', 'w'),
        ]
      ),
    ]) {
      final Pointer<ObjCObject> holder = item(title, '', '');
      objcSendVoid1(
          holder, objcSelector('setSubmenu:'), menu(title, items).address);
      objcSendVoid1(bar, objcSelector('addItem:'), holder.address);
    }
    objcSendVoid1(_application, objcSelector('setMainMenu:'), bar.address);
  }

  @override
  Future<NativeWindow> createWindow(WindowOptions options) async {
    if (!_initialized) {
      throw StateError('$name.createWindow before initialize()');
    }
    final NativeWindow? owner = options.owner;
    final MacosEmbeddedWindow window = MacosEmbeddedWindow.create(
      classes: _classes!,
      delegate: _windowDelegate,
      id: NativeWindowId(_nextWindowId++),
      options: options,
      owner: owner is MacosEmbeddedWindow ? owner : null,
      onClosed: _windows.remove,
      onEvent: _notify,
    );
    _quitRequested = false;
    _windows.add(window);
    return window;
  }

  @override
  List<NativeWindow> get windows => List<NativeWindow>.unmodifiable(_windows);

  /// The window behind [native] - an `NSWindow` or its content view.
  MacosEmbeddedWindow? windowFor(Pointer<ObjCObject> native) {
    for (final MacosEmbeddedWindow window in _windows) {
      if (window.nativeWindow.address == native.address ||
          window.view.address == native.address) {
        return window;
      }
    }
    return null;
  }

  // -------------------------------------------------------------------------
  // Event loop
  // -------------------------------------------------------------------------

  /// AppKit delivers on this thread between Dart turns: nothing to wait on.
  @override
  bool pumpEvents({Duration timeout = Duration.zero}) => !_quitRequested;

  @override
  Future<void> waitForEvents(Duration timeout) {
    final Completer<void> waiter = _waiter ??= Completer<void>();
    final Timer timer = Timer(timeout, () {
      if (!waiter.isCompleted) waiter.complete();
    });
    return waiter.future.whenComplete(() {
      timer.cancel();
      if (identical(_waiter, waiter)) _waiter = null;
    });
  }

  void _notify() {
    final Completer<void>? waiter = _waiter;
    if (waiter != null && !waiter.isCompleted) waiter.complete();
    _flushMicrotasks();
  }

  /// One empty message to this isolate, so the runtime's loop turns and the
  /// microtasks a native callback scheduled run at the end of it.
  void _flushMicrotasks() {
    final RawReceivePort? kick = _kick;
    if (kick == null || _kickPending) return;
    _kickPending = true;
    kick.sendPort.send(null);
  }

  @override
  void wake() => _notify();

  // -------------------------------------------------------------------------
  // MacosEmbeddedSink - AppKit's calls
  // -------------------------------------------------------------------------

  @override
  void viewEvent(
          Pointer<ObjCObject> view, Pointer<ObjCObject> event, int type) =>
      windowFor(view)?.viewEvent(event, type);

  @override
  void windowNotification(Pointer<ObjCObject> window,
          MacosEmbeddedWindowNotification notification) =>
      windowFor(window)?.notification(notification);

  @override
  void windowCloseRequested(Pointer<ObjCObject> window) =>
      windowFor(window)?.closeRequested();

  @override
  void applicationDidFinishLaunching() {
    if (!_launched.isCompleted) _launched.complete();
  }

  @override
  void applicationTerminateRequested() {
    for (final MacosEmbeddedWindow window
        in List<MacosEmbeddedWindow>.of(_windows)) {
      if (window.kind.isTopLevel) window.closeRequested();
    }
  }

  @override
  void afterNativeCall() => _notify();

  // -------------------------------------------------------------------------
  // Screens
  // -------------------------------------------------------------------------

  @override
  List<ScreenInfo> get screens {
    if (_application == nullptr) return const <ScreenInfo>[];
    return ObjCAutoreleasePool.run(() {
      final Pointer<ObjCObject> list =
          objcSendPointer(objcClass('NSScreen'), objcSelector('screens'));
      final int count = objcSendUnsigned(list, objcSelector('count'));
      if (count == 0) return const <ScreenInfo>[];
      final double primary = macosPrimaryScreenHeight();
      return List<ScreenInfo>.unmodifiable(<ScreenInfo>[
        for (var index = 0; index < count; index++)
          () {
            final Pointer<ObjCObject> screen =
                objcSendPointer1(list, objcSelector('objectAtIndex:'), index);
            return ScreenInfo(
              bounds: macosRectFromAppKit(sendRect(screen, 'frame'), primary),
              workArea: macosRectFromAppKit(
                  sendRect(screen, 'visibleFrame'), primary),
              scale: sendDouble(screen, 'backingScaleFactor'),
              isPrimary: index == 0,
              name: dartString(
                  objcSendPointer(screen, objcSelector('localizedName'))),
            );
          }(),
      ]);
    });
  }

  @override
  ScreenInfo? screenAt(Offset screenPoint) =>
      ScreenInfo.nearest(screens, screenPoint);

  // -------------------------------------------------------------------------
  // Teardown
  // -------------------------------------------------------------------------

  @override
  Future<void> shutdown() async {
    if (!_initialized &&
        _application == nullptr &&
        _kick == null &&
        _classes == null) {
      return;
    }
    _initialized = false;
    _quitRequested = true;
    // Popups before their owners: a child window goes with its parent.
    final List<MacosEmbeddedWindow> windows =
        List<MacosEmbeddedWindow>.of(_windows)
          ..sort((MacosEmbeddedWindow a, MacosEmbeddedWindow b) =>
              (a.owner == null ? 1 : 0) - (b.owner == null ? 1 : 0));
    for (final MacosEmbeddedWindow window in windows) {
      window.dispose();
    }
    _windows.clear();
    if (identical(MacosEmbeddedClasses.sink, this)) {
      MacosEmbeddedClasses.sink = null;
    }
    ObjCAutoreleasePool.run(() {
      objcSendVoid1(_application, objcSelector('setDelegate:'), 0);
    });
    objcRelease(_applicationDelegate);
    objcRelease(_windowDelegate);
    objcRelease(_application);
    _applicationDelegate = nullptr;
    _windowDelegate = nullptr;
    _application = nullptr;
    _classes = null;
    _kick?.close();
    _kick = null;
    final Completer<void>? waiter = _waiter;
    if (waiter != null && !waiter.isCompleted) waiter.complete();
  }

  @override
  String toString() => 'MacosEmbeddedWindowingBackend('
      'initialized: $_initialized, windows: ${_windows.length})';
}

/// The client rect of [window] in screen points, top-left origin - what a
/// probe compares with the window server's own list.
Rect macosEmbeddedClientRect(MacosEmbeddedWindow window) {
  final Offset origin = window.clientToScreen(Offset.zero);
  return Rect.fromLTWH(
      origin.dx, origin.dy, window.clientSize.width, window.clientSize.height);
}
