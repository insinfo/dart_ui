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
import '../../platform/clipboard.dart';
import '../../platform/drag_drop.dart';
import '../../platform/native_window.dart';
import '../../platform/text_input.dart';
import 'win32_abi.dart';
import 'win32_api.dart';
import 'win32_clipboard.dart';
import 'win32_constants.dart';
import 'win32_diagnostics.dart';
import 'win32_drag_drop.dart';
import 'win32_ime.dart';
import 'win32_ole.dart';
import 'win32_structs.dart';
import 'win32_window.dart';
import 'win32_window_class.dart';

/// Creates and owns Win32 windows.
final class Win32WindowingBackend
    implements
        WindowingBackend,
        ClipboardProvider,
        DragDropProvider,
        TextInputProvider {
  Win32WindowingBackend();

  @override
  String get name => 'win32';

  /// The Windows clipboard, over the same `Win32Api` the windows use.
  ///
  /// This is the seam that makes Ctrl+C and Ctrl+V work in an application that
  /// configured nothing: the shell asks the backend it selected, and this is
  /// the backend answering. See [ClipboardProvider].
  ///
  /// Two honest refusals rather than a null, so the reason survives to
  /// `RenderTextField.lastClipboardError`:
  ///
  ///  * before [initialize] there is no loaded API to talk to;
  ///  * a Windows build without the user32/kernel32 clipboard symbols has no
  ///    clipboard at all, and `Capability.clipboardText` is correspondingly
  ///    absent from [probe].
  @override
  Clipboard get clipboard {
    final api = _api;
    if (api == null) {
      return const UnavailableClipboard(
        'the win32 backend has not been initialized, so no clipboard has been '
        'opened yet',
      );
    }
    if (!api.clipboardSupported) {
      return const UnavailableClipboard(
        'this Windows build exposes no Unicode clipboard symbols; the win32 '
        'backend does not report Capability.clipboardText either',
      );
    }
    return Win32Clipboard(api);
  }

  /// OLE drag and drop, over ole32 loaded on demand.
  ///
  /// The same seam as [clipboard], with the same two honest refusals: no API
  /// before [initialize], and an [UnavailableDragDrop] naming ole32 when the
  /// drag-and-drop entry points could not be bound. Built once and kept,
  /// because it owns the `IDropTarget` vtables and the OLE apartment
  /// reference - one set for every window of this backend.
  @override
  DragDropBackend get dragAndDrop {
    final existing = _dragAndDrop;
    if (existing != null) return existing;
    final api = _api;
    if (api == null) {
      return const UnavailableDragDrop(
        name: 'win32',
        reason: 'the win32 backend has not been initialized, so ole32 has not '
            'been loaded and no window can be registered yet',
      );
    }
    final created = Win32DragDropBackend.create(api);
    for (final diagnostic in created.diagnostics) {
      _diagnostics.add(diagnostic);
    }
    return _dragAndDrop = created.backend;
  }

  DragDropBackend? _dragAndDrop;

  /// IMM32 composition, over imm32 loaded on demand.
  ///
  /// The same seam as [clipboard] and [dragAndDrop], with the same two honest
  /// refusals: no API before [initialize], and an [UnavailableTextInput]
  /// naming imm32 when it could not be bound. Built once and kept, because a
  /// `TextInputScope` publishes it to every tree and its `updateShouldNotify`
  /// is an identity check - a fresh object per call would notify every text
  /// field in the window that nothing had changed.
  ///
  /// **Losing this is not losing typing.** Plain text comes from `WM_CHAR`,
  /// which the window handles whether or not imm32 ever loaded; what is lost
  /// is composition, which is CJK and the framework-drawn preedit.
  @override
  TextInputBackend get textInput {
    final TextInputBackend? existing = _textInput;
    if (existing != null) return existing;
    final api = _api;
    if (api == null) {
      return const UnavailableTextInput(
        name: 'win32',
        reason: 'the win32 backend has not been initialized, so imm32 has not '
            'been loaded and no window can be composed into yet',
      );
    }
    final created = Win32TextInputBackend.create(api);
    for (final diagnostic in created.diagnostics) {
      _diagnostics.add(diagnostic);
    }
    return _textInput = created.backend;
  }

  TextInputBackend? _textInput;

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
    diagnostics.add(
      BackendDiagnostic.note(
        'FFI ABI layout',
        detail: Win32AbiReport.current().toString(),
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
    if (api.clipboardSupported) {
      diagnostics.add(
        const BackendDiagnostic.note('Unicode clipboard is available'),
      );
    }

    // Probed rather than assumed: ole32 is always present on a real Windows
    // install, and the one place that stops being true - a stripped container
    // image, a Nano Server host - is exactly where a capability claimed on
    // faith turns into a drop that silently never arrives.
    final oleResult = Win32OleApi.load();
    final oleLoaded = oleResult.api != null;
    diagnostics.addAll(oleResult.diagnostics);
    if (oleLoaded) {
      diagnostics.add(
        const BackendDiagnostic.note(
          'ole32 drag-and-drop entry points are available; windows can be '
          'registered as OLE drop targets',
        ),
      );
    }

    // Probed for ole32's reason: imm32 is present on every real Windows
    // install and absent exactly where a capability claimed on faith turns
    // into a text field that mysteriously cannot type Japanese.
    final immResult = Imm32Api.load();
    final immLoaded = immResult.api != null;
    diagnostics.addAll(immResult.diagnostics);
    if (immLoaded) {
      diagnostics.add(
        const BackendDiagnostic.note(
          'imm32 composition entry points are available; WM_IME_* is handled '
          'and the preedit is drawn by the framework rather than by the IME',
        ),
      );
    }

    diagnostics.add(
      BackendDiagnostic.note(
        'core mouse, wheel and keyboard input, the Unicode clipboard, OLE '
        'drag and drop in both directions and IMM32 composition are '
        'normalized; the IME cannot read surrounding text '
        '(WM_IME_REQUEST/IMR_DOCUMENTFEED is unanswered) and accessibility is '
        'partial${immLoaded ? '' : '; imm32 did not load, so there is no '
            'composition at all'}',
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
        if (api.clipboardSupported) Capability.clipboardText,
        // Both halves: `IDropTarget` receives a drop and `DoDragDrop` starts
        // one. The capability is claimed on ole32 having loaded, because that
        // is the single thing either half needs and the only thing that can
        // actually be missing on a stripped Windows image.
        if (oleLoaded) Capability.dragAndDrop,
        // Claimed on imm32 having bound, because that is the single thing
        // composition needs and the only thing that can actually be missing.
        if (immLoaded) Capability.textComposition,
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

    // Drop targets go with the windows, and before the class: RevokeDragDrop
    // on a destroyed HWND answers DRAGDROP_E_NOTREGISTERED and leaves the OLE
    // runtime holding a pointer into this process. `Win32Window.dispose` above
    // has already destroyed the handles, so this is the *application's* last
    // chance to have revoked them - which is why the registration also lives
    // in the window's own disposable bag, and this is only the backstop.
    if (_dragAndDrop case final Win32DragDropBackend backend) {
      await backend.dispose();
    }
    _dragAndDrop = null;

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
