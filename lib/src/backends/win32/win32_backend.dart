/// The Win32 windowing backend.
///
/// Bootstrap order is the one section 13.2 fixes, and it is not negotiable:
/// DPI awareness must be set before any window exists (a window created by a
/// DPI-unaware process stays bitmap-stretched for its whole life), and the
/// class must be registered before `CreateWindowExW` can name it.
///
///   1. load kernel32 / user32 / gdi32 (+ shcore when present);
///   2. set process DPI awareness;
///   3. take the HINSTANCE and register the class, which also creates the
///      `NativeCallable` the class points at;
///   4. create the message-only wake window;
///   5. create application windows;
///   6. pump;
///   7. destroy windows, destroy the wake window, unregister the class, close
///      the callback - the reverse of the order above.
library;

import 'dart:async';
import 'dart:ffi';
import 'dart:io' show Platform;

import '../../foundation/diagnostics.dart';
import '../../foundation/lifecycle.dart';
import '../../platform/native_window.dart';
import 'win32_api.dart';
import 'win32_constants.dart';
import 'win32_diagnostics.dart';
import 'win32_structs.dart';
import 'win32_window.dart';
import 'win32_window_class.dart';

/// Creates and owns Win32 windows.
final class Win32WindowingBackend implements WindowingBackend {
  Win32WindowingBackend();

  @override
  String get name => 'win32';

  /// Not final: a bag is single-use, and a backend may legitimately be
  /// initialised again after a shutdown (a test suite does it per test).
  DisposableBag _resources = DisposableBag();
  final List<Win32Window> _windows = <Win32Window>[];
  final List<BackendDiagnostic> _diagnostics = <BackendDiagnostic>[];

  Win32Api? _api;
  Win32WindowClass? _windowClass;
  Pointer<Msg>? _message;
  int _wakeHandle = 0;
  bool _initialized = false;
  bool _quitRequested = false;

  /// Everything that went wrong (or was worth noting) since [initialize].
  List<BackendDiagnostic> get diagnostics =>
      List<BackendDiagnostic>.unmodifiable(
        <BackendDiagnostic>[
          ..._diagnostics,
          for (final window in _windows) ...window.diagnostics,
        ],
      );

  /// The class name Windows knows these windows by, once registered.
  String? get windowClassName => _windowClass?.name;

  // ---------------------------------------------------------------------------
  // Probe
  // ---------------------------------------------------------------------------

  @override
  BackendProbeResult probe() {
    if (!Platform.isWindows) {
      // The only branch that runs on Linux and macOS CI. It must not throw:
      // `DynamicLibrary.open('user32.dll')` there is not a diagnostic, it is a
      // crash, and a probe that crashes cannot report why it failed.
      return BackendProbeResult.unsupported(
        name,
        BackendDiagnostic(
          kind: DiagnosticKind.unsupportedPlatform,
          message: 'win32 needs Windows',
          detail: 'Platform.operatingSystem=${Platform.operatingSystem}',
        ),
      );
    }

    final loaded = Win32Api.load();
    final api = loaded.api;
    final diagnostics = <BackendDiagnostic>[...loaded.diagnostics];
    if (api == null) {
      return BackendProbeResult(
        backendName: name,
        supported: false,
        diagnostics: diagnostics,
      );
    }

    diagnostics.add(
      BackendDiagnostic.note(
        'windows ${Platform.operatingSystemVersion}',
        detail: 'dpi api: ${api.dpiAwarenessApi.name}',
      ),
    );

    final perMonitor = switch (api.dpiAwarenessApi) {
      Win32DpiAwarenessApi.perMonitorV2 => true,
      Win32DpiAwarenessApi.perMonitorV1 => true,
      Win32DpiAwarenessApi.systemOnly => false,
      Win32DpiAwarenessApi.none => false,
    };
    if (api.dpiAwarenessApi == Win32DpiAwarenessApi.perMonitorV1) {
      diagnostics.add(
        const BackendDiagnostic.note(
          'SetProcessDpiAwarenessContext missing; falling back to shcore '
          'SetProcessDpiAwareness (per-monitor v1: the non-client area does '
          'not rescale)',
        ),
      );
    }
    if (api.dpiAwarenessApi == Win32DpiAwarenessApi.systemOnly) {
      diagnostics.add(
        const BackendDiagnostic.note(
          'neither SetProcessDpiAwarenessContext nor SetProcessDpiAwareness; '
          'using SetProcessDPIAware, so secondary monitors are stretched',
        ),
      );
    }
    if (api.dpiAwarenessApi == Win32DpiAwarenessApi.none) {
      diagnostics.add(
        const BackendDiagnostic.note(
          'no DPI awareness API at all; the process stays DPI-unaware',
        ),
      );
    }
    if (perMonitor && api.getDpiForWindow == null) {
      diagnostics.add(
        const BackendDiagnostic.missingSymbol(
          'GetDpiForWindow',
          detail: 'per-monitor DPI cannot be reported per window',
        ),
      );
    }
    if (api.adjustWindowRectExForDpi == null) {
      diagnostics.add(
        const BackendDiagnostic.missingSymbol(
          'AdjustWindowRectExForDpi',
          detail: 'window frames are sized at the system DPI',
        ),
      );
    }

    diagnostics.add(
      const BackendDiagnostic.note(
        'core mouse and keyboard input are normalized; wheel, IME, clipboard, '
        'drag-and-drop and accessibility are not implemented yet',
      ),
    );
    diagnostics.add(
      const BackendDiagnostic.note(
        'presentation is a GDI BitBlt: DWM composites at vblank but the blit '
        'itself is not paced, so vsync is not claimed',
      ),
    );

    return BackendProbeResult(
      backendName: name,
      supported: true,
      capabilities: <Capability>{
        Capability.window,
        Capability.multipleWindows,
        Capability.cpuPresentation,
        Capability.partialPresent,
        Capability.keyboardInput,
        Capability.pointerInput,
        Capability.orderlyShutdown,
        if (perMonitor && api.getDpiForWindow != null) Capability.perMonitorDpi,
      },
      diagnostics: diagnostics,
    );
  }

  // ---------------------------------------------------------------------------
  // Lifecycle
  // ---------------------------------------------------------------------------

  bool get isInitialized => _initialized;

  @override
  Future<void> initialize() async {
    if (_initialized) return;

    final report = probe();
    if (!report.supported) {
      throw BackendSelectionError(
        requested: name,
        attempts: <BackendProbeResult>[report],
      );
    }
    _diagnostics.addAll(report.diagnostics);
    if (_resources.isDisposed) _resources = DisposableBag();

    final api = Win32Api.load().api!;
    _api = api;
    _applyDpiAwareness(api);

    final message = api.allocator<Msg>();
    _resources.add(message, () => api.allocator.free(message));
    _message = message;

    final windowClass = Win32WindowClass.register(api);
    _diagnostics.addAll(windowClass.diagnostics);
    _resources.add(windowClass, () {
      final failure = windowClass.unregister();
      if (failure != null) _diagnostics.add(failure);
    });
    _windowClass = windowClass;

    _wakeHandle = _createWakeWindow(api, windowClass);
    _resources.add(_wakeHandle, () {
      if (_wakeHandle != 0) api.destroyWindow(_wakeHandle);
      _wakeHandle = 0;
    });

    // Faults reach the owning window's stream from here on. Installed after
    // the class exists so a fault can never arrive before there is anywhere to
    // put it.
    Win32WindowRegistry.onFault = _onHandlerFault;
    _resources.add(this, () => Win32WindowRegistry.onFault = null);

    _initialized = true;
  }

  void _applyDpiAwareness(Win32Api api) {
    switch (api.dpiAwarenessApi) {
      case Win32DpiAwarenessApi.perMonitorV2:
        final ok = api.setProcessDpiAwarenessContext!(
          dpiAwarenessContextPerMonitorAwareV2,
        );
        if (ok == 0) {
          // ERROR_ACCESS_DENIED here means the value was already set - by an
          // application manifest, or by an earlier initialize() in the same
          // process. That is not a failure, and reporting it as one would make
          // every manifest-aware host look broken.
          _diagnostics.add(
            win32CallFailed(
              'SetProcessDpiAwarenessContext',
              api.getLastError(),
              kind: DiagnosticKind.note,
              context: 'awareness was probably already set for this process',
            ),
          );
        }
      case Win32DpiAwarenessApi.perMonitorV1:
        final result = api.setProcessDpiAwareness!(processPerMonitorDpiAware);
        if (result != 0) {
          _diagnostics.add(
            BackendDiagnostic(
              kind: DiagnosticKind.note,
              message: 'SetProcessDpiAwareness did not take effect',
              detail: 'HRESULT=0x${result.toRadixString(16)}',
            ),
          );
        }
      case Win32DpiAwarenessApi.systemOnly:
        if (api.setProcessDpiAware!() == 0) {
          _diagnostics.add(
            win32CallFailed(
              'SetProcessDPIAware',
              api.getLastError(),
              kind: DiagnosticKind.note,
            ),
          );
        }
      case Win32DpiAwarenessApi.none:
        break;
    }
  }

  /// A message-only window, created solely so [wake] has a stable target.
  ///
  /// `HWND_MESSAGE` keeps it out of the compositor, the taskbar and Alt+Tab
  /// while still giving it a place in this thread's message queue.
  int _createWakeWindow(Win32Api api, Win32WindowClass windowClass) {
    final title = api.toUtf16('dart_ui.wake');
    try {
      final handle = api.createWindowExW(
        wsExToolwindow,
        windowClass.namePointer,
        title,
        wsOverlapped,
        0,
        0,
        0,
        0,
        hwndMessage,
        0,
        windowClass.instanceHandle,
        0, // No token: the router sends its messages to DefWindowProcW.
      );
      if (handle == 0) {
        throw Win32Failure(
          win32CallFailed(
            'CreateWindowExW',
            api.getLastError(),
            context: 'message-only wake window',
          ),
        );
      }
      return handle;
    } finally {
      api.heapRelease(title);
    }
  }

  @override
  Future<void> shutdown() async {
    if (!_initialized) {
      // Idempotent by contract: callers tear down on both the success and the
      // failure path, and making them remember which one ran is how leaks get
      // written.
      _resources.dispose();
      return;
    }
    _initialized = false;

    // Windows first, and by hand rather than through the bag: UnregisterClassW
    // fails with ERROR_CLASS_HAS_WINDOWS while one is still alive.
    for (final window in List<Win32Window>.of(_windows)) {
      window.dispose();
    }
    _windows.clear();

    _resources.dispose();
    _windowClass = null;
    _message = null;
    _api = null;
  }

  // ---------------------------------------------------------------------------
  // Windows
  // ---------------------------------------------------------------------------

  @override
  List<NativeWindow> get windows => List<NativeWindow>.unmodifiable(_windows);

  @override
  Future<NativeWindow> createWindow(WindowOptions options) async {
    _requireInitialized('createWindow');
    final window = Win32Window.create(
      api: _api!,
      windowClass: _windowClass!,
      options: options,
      onClosed: _windows.remove,
      onSessionEnding: () => _quitRequested = true,
    );
    _windows.add(window);
    return window;
  }

  // ---------------------------------------------------------------------------
  // Message loop
  // ---------------------------------------------------------------------------

  @override
  bool pumpEvents({Duration timeout = Duration.zero}) {
    _requireInitialized('pumpEvents');
    final api = _api!;
    final message = _message!;

    if (timeout > Duration.zero && !_quitRequested) {
      final milliseconds = timeout.inMilliseconds;
      api.msgWaitForMultipleObjectsEx(
        0,
        nullptr,
        milliseconds <= 0 ? 1 : milliseconds,
        qsAllinput,
        // INPUTAVAILABLE closes the race where a message is posted between the
        // previous drain and this wait: without it the wait would sleep
        // through a message that is already queued.
        mwmoInputavailable | mwmoAlertable,
      );
    }

    while (api.peekMessageW(message, 0, 0, 0, pmRemove) != 0) {
      if (message.ref.message == wmQuit) {
        // Never PostQuitMessage from this backend: deciding to stop is the
        // application's job (section 9.3). This only reports that somebody
        // else decided.
        _quitRequested = true;
        break;
      }
      api.translateMessage(message);
      api.dispatchMessageW(message);
    }
    return !_quitRequested;
  }

  /// Whether a WM_QUIT or a session end has been seen.
  bool get isQuitRequested => _quitRequested;

  /// Wakes a blocked [pumpEvents], from this isolate or any other.
  ///
  /// **PostMessage to the wake window, not PostThreadMessage.** Both would
  /// wake the queue, and PostThreadMessage even avoids needing a window - but
  /// a thread-posted message is delivered to the queue of *whichever thread id
  /// was captured*, and a Dart isolate is not pinned to an OS thread. Capture
  /// the wrong thread and the wake vanishes with no error anywhere. A window's
  /// messages always go to the queue of the thread that created the window,
  /// which is by construction the thread this backend pumps on, so PostMessage
  /// cannot be aimed at the wrong queue.
  ///
  /// From another isolate, send [wakeHandle] (a plain int) through a SendPort
  /// and call [wakeHandleFromAnyIsolate]. Posting is documented as safe from
  /// any thread; nothing in this call touches Dart state belonging to the
  /// owning isolate.
  @override
  void wake() {
    final api = _api;
    if (api == null || _wakeHandle == 0) return;
    if (api.postMessageW(_wakeHandle, wmAppWake, 0, 0) == 0) {
      _diagnostics.add(win32CallFailed('PostMessageW', api.getLastError()));
    }
  }

  /// The HWND [wake] posts to. Sendable to another isolate: it is an integer,
  /// and the window it names outlives every isolate that could hold it because
  /// this backend owns it.
  int get wakeHandle => _wakeHandle;

  /// [wake], callable from an isolate that has no access to this object.
  ///
  /// Loads user32 in the calling isolate - `DynamicLibrary.open` is per
  /// isolate, cheap, and the module is already resident in the process.
  /// Returns false when the post failed, which on a dead handle it will.
  static bool wakeHandleFromAnyIsolate(int wakeHandle) {
    if (wakeHandle == 0) return false;
    final api = Win32Api.load().api;
    if (api == null) return false;
    return api.postMessageW(wakeHandle, wmAppWake, 0, 0) != 0;
  }

  // ---------------------------------------------------------------------------
  // Faults
  // ---------------------------------------------------------------------------

  /// See the policy in `win32_window_class.dart`. This end of it decides where
  /// a fault is *shown*: on the owning window's stream when somebody is
  /// listening, and as an uncaught asynchronous error when nobody is.
  void _onHandlerFault(Win32HandlerFault fault) {
    _diagnostics.add(fault.diagnostic);
    for (final window in _windows) {
      if (window.handle == fault.hwnd && window.hasEventListener) {
        window.reportError(fault, fault.stackTrace);
        return;
      }
    }
    Zone.current.handleUncaughtError(fault.error, fault.stackTrace);
  }

  void _requireInitialized(String operation) {
    if (!_initialized) {
      throw StateError('$name.$operation before initialize()');
    }
  }

  @override
  String toString() => 'Win32WindowingBackend(initialized: $_initialized, '
      'windows: ${_windows.length}, class: ${_windowClass?.name})';
}
