/// Window-class registration and WndProc routing (roadmap 13.3).
///
/// ## Why a token and not a pointer
///
/// The obvious implementation stores the Dart object's address in
/// `GWLP_USERDATA`. It is also the one that crashes: Windows keeps delivering
/// messages to an HWND after the Dart object that owned it is unreachable, and
/// a stale address is indistinguishable from a live one. A monotonic token
/// resolved through a map is one lookup more expensive and cannot dangle - the
/// map either has the entry or it does not.
///
/// ## The WndProc exception policy
///
/// A Dart exception must never unwind through the native frame. The FFI
/// callback would return its `exceptionalReturn` and the OS would carry on with
/// a window whose handler silently did nothing - which is the worst of both
/// worlds, because the error is gone *and* the window is broken.
///
/// So every message is handled inside a `try`, and a fault is:
///
///   1. recorded in [Win32WindowRegistry.faults] (bounded - a handler that
///      throws on every WM_MOUSEMOVE must not become the memory leak);
///   2. handed to [Win32WindowRegistry.onFault] when the backend installed
///      one, which routes it to the owning window's event stream so an
///      application listener sees it as a stream error;
///   3. otherwise raised through `Zone.current.handleUncaughtError`, so an
///      unconsumed fault behaves like any other unhandled asynchronous error -
///      it fails the test, it prints in production. Never swallowed.
///
/// The message itself then falls through to `DefWindowProcW`, so the window
/// keeps behaving the way an unhandled message would.
library;

import 'dart:async';
import 'dart:ffi';

import '../../foundation/diagnostics.dart';
import 'win32_api.dart';
import 'win32_constants.dart';
import 'win32_diagnostics.dart';
import 'win32_structs.dart';
import 'win32_window.dart';

/// HWND to Dart window, through a token that can never dangle.
final class Win32WindowRegistry {
  Win32WindowRegistry._();

  static int _nextToken = 1;
  static final Map<int, Win32Window> _windows = <int, Win32Window>{};

  /// Faults are kept for post-mortem, oldest dropped first.
  static const int _maxFaults = 32;
  static final List<Win32HandlerFault> _faults = <Win32HandlerFault>[];

  /// Installed by the backend so faults reach the window's event stream.
  static void Function(Win32HandlerFault fault)? onFault;

  static int attach(Win32Window window) {
    final token = _nextToken++;
    _windows[token] = window;
    return token;
  }

  static Win32Window? resolve(int token) => _windows[token];

  static void detach(int token) => _windows.remove(token);

  /// How many windows are still routable. The teardown test asserts this is
  /// zero, which is a stronger statement than "dispose() returned".
  static int get attachedCount => _windows.length;

  static List<Win32HandlerFault> get faults =>
      List<Win32HandlerFault>.unmodifiable(_faults);

  static void clearFaults() => _faults.clear();

  static void reportFault(Win32HandlerFault fault) {
    if (_faults.length >= _maxFaults) _faults.removeAt(0);
    _faults.add(fault);
    final sink = onFault;
    if (sink == null) {
      Zone.current.handleUncaughtError(fault.error, fault.stackTrace);
      return;
    }
    try {
      sink(fault);
    } on Object catch (error, stack) {
      // A reporter that throws must not recurse back into reporting.
      Zone.current.handleUncaughtError(error, stack);
    }
  }
}

/// The single window class every window of this backend uses.
///
/// One class, not one per window: `RegisterClassExW` allocates in the window
/// station, and a per-window class turns a thousand-window stress run (the
/// 13.2 acceptance gate) into a thousand leaked registrations.
final class Win32WindowClass {
  Win32WindowClass._({
    required Win32Api api,
    required this.name,
    required this.atom,
    required this.instanceHandle,
    required Pointer<Uint16> namePointer,
    required NativeCallable<WndProcNative> callable,
    required this.diagnostics,
  })  : _api = api,
        _namePointer = namePointer,
        _callable = callable;

  /// The base class name. A suffix is appended only if this one is somehow
  /// already taken - see [register].
  static const String baseName = 'DartUiWindow';

  static int _suffix = 0;

  /// Registers the class, or throws [Win32Failure] naming the failure.
  static Win32WindowClass register(Win32Api api) {
    final instanceHandle = api.getModuleHandleW(nullptr);
    if (instanceHandle == 0) {
      throw Win32Failure(
        win32CallFailed(
          'GetModuleHandleW',
          api.getLastError(),
          kind: DiagnosticKind.missingLibrary,
        ),
      );
    }

    // isolateLocal is correct and not a limitation: DispatchMessage runs the
    // WndProc on the very thread that pumped the message, which is this
    // isolate's thread. A callback that could be invoked from a foreign thread
    // would need `NativeCallable.listener`, and a listener cannot return the
    // LRESULT the OS is waiting for.
    final callable = NativeCallable<WndProcNative>.isolateLocal(
      _routeMessage,
      exceptionalReturn: 0,
    );

    final diagnostics = <BackendDiagnostic>[];
    final cursor = api.loadCursorW(0, idcArrow);

    var name = baseName;
    var namePointer = api.toUtf16(name);
    var atom = 0;
    var lastError = 0;
    for (var attempt = 0; attempt < 8; attempt++) {
      final descriptor = api.allocator<WndClassExW>();
      try {
        descriptor.ref
          ..cbSize = sizeOf<WndClassExW>()
          ..style = csHredraw | csVredraw | csDblclks
          ..lpfnWndProc = callable.nativeFunction
          ..cbClsExtra = 0
          ..cbWndExtra = 0
          ..hInstance = instanceHandle
          ..hIcon = 0
          // The class cursor is null so that WM_SETCURSOR is ours: with a class
          // cursor, Windows resets the pointer on every move and setCursor()
          // would flicker back to an arrow.
          ..hCursor = 0
          // No background brush: every pixel comes from the framebuffer, and a
          // brush would paint over it between the erase and the present.
          ..hbrBackground = 0
          ..lpszMenuName = nullptr
          ..lpszClassName = namePointer
          ..hIconSm = 0;
        atom = api.registerClassExW(descriptor);
        lastError = atom == 0 ? api.getLastError() : 0;
      } finally {
        api.allocator.free(descriptor);
      }
      if (atom != 0) break;
      if (lastError != 1410) break; // Only ERROR_CLASS_ALREADY_EXISTS retries.

      // A previous run left the class behind - a process that crashed with a
      // window open, or a hot restart. Take a fresh name rather than failing.
      api.heapRelease(namePointer);
      name = '$baseName.${++_suffix}';
      namePointer = api.toUtf16(name);
      diagnostics.add(
        BackendDiagnostic.note(
          'window class $baseName already registered; using $name',
          detail: 'GetLastError=1410 (ERROR_CLASS_ALREADY_EXISTS)',
        ),
      );
    }

    if (atom == 0) {
      api.heapRelease(namePointer);
      callable.close();
      throw Win32Failure(
        win32CallFailed(
          'RegisterClassExW',
          lastError,
          context: 'class "$name"',
        ),
      );
    }

    return Win32WindowClass._(
      api: api,
      name: name,
      atom: atom,
      instanceHandle: instanceHandle,
      namePointer: namePointer,
      callable: callable,
      diagnostics: diagnostics,
    )..defaultCursor = cursor;
  }

  final Win32Api _api;
  final Pointer<Uint16> _namePointer;
  final NativeCallable<WndProcNative> _callable;

  final String name;
  final int atom;
  final int instanceHandle;

  /// Notes worth carrying into the probe result - a renamed class, mostly.
  final List<BackendDiagnostic> diagnostics;

  /// `IDC_ARROW`, loaded once. System cursors are shared and must not be
  /// destroyed.
  int defaultCursor = 0;

  Pointer<Uint16> get namePointer => _namePointer;

  bool _unregistered = false;

  /// Whether a class of [className] exists for this module.
  ///
  /// Asks Windows rather than a Dart flag: the teardown test is only worth
  /// anything if it questions the OS.
  static bool isRegistered(Win32Api api, String className, int instanceHandle) {
    final namePointer = api.toUtf16(className);
    final descriptor = api.allocator<WndClassExW>();
    try {
      descriptor.ref.cbSize = sizeOf<WndClassExW>();
      return api.getClassInfoExW(instanceHandle, namePointer, descriptor) != 0;
    } finally {
      api.allocator.free(descriptor);
      api.heapRelease(namePointer);
    }
  }

  /// Unregisters the class and closes the callback, in that order.
  ///
  /// The order is the whole point: `UnregisterClassW` fails with
  /// ERROR_CLASS_HAS_WINDOWS while any window of the class is alive, and
  /// closing the callable first would leave those windows pointing at a freed
  /// trampoline. Idempotent, because a backend disposes on both paths.
  ///
  /// Returns a diagnostic when Windows refused, so a leak is reported instead
  /// of guessed at.
  BackendDiagnostic? unregister() {
    if (_unregistered) return null;
    _unregistered = true;
    BackendDiagnostic? failure;
    if (_api.unregisterClassW(_namePointer, instanceHandle) == 0) {
      failure = win32CallFailed(
        'UnregisterClassW',
        _api.getLastError(),
        context: 'class "$name"; a window of this class is probably still open',
      );
    }
    _callable.close();
    _api.heapRelease(_namePointer);
    return failure;
  }
}

/// The one WndProc for every window of this backend.
///
/// Static because `NativeCallable.isolateLocal` needs a function it can point
/// at for the process's lifetime, and because per-window callbacks would mean
/// one trampoline per window.
int _routeMessage(int hwnd, int msg, int wParam, int lParam) {
  final api = Win32Api.load().api;
  if (api == null) return 0; // Unreachable: no window exists without the API.
  try {
    if (msg == wmNccreate) {
      // The only message that arrives before GWLP_USERDATA is set, which is
      // why the token travels in CREATESTRUCT.lpCreateParams.
      final create = Pointer<CreateStructW>.fromAddress(lParam);
      final token = create.ref.lpCreateParams;
      if (token != 0) {
        api.setWindowLongPtrW(hwnd, gwlpUserdata, token);
        Win32WindowRegistry.resolve(token)?.attachHandle(hwnd);
      }
      return api.defWindowProcW(hwnd, msg, wParam, lParam);
    }

    final token = api.getWindowLongPtrW(hwnd, gwlpUserdata);
    final window = token == 0 ? null : Win32WindowRegistry.resolve(token);
    if (window == null) {
      // The wake window, and any message that arrives after WM_NCDESTROY.
      return api.defWindowProcW(hwnd, msg, wParam, lParam);
    }
    return window.handleMessage(hwnd, msg, wParam, lParam);
  } on Object catch (error, stackTrace) {
    Win32WindowRegistry.reportFault(
      Win32HandlerFault(
        hwnd: hwnd,
        message: msg,
        wParam: wParam,
        lParam: lParam,
        error: error,
        stackTrace: stackTrace,
      ),
    );
    // Give the OS the behaviour it would have had without us. Returning 0
    // blindly would, for WM_NCCREATE, abort window creation.
    return api.defWindowProcW(hwnd, msg, wParam, lParam);
  }
}
