/// Loading user32/gdi32/kernel32 and binding the symbols this backend calls.
///
/// Two rules shaped this file.
///
/// First, **nothing outside `dart:ffi`**. `package:ffi` would give us `calloc`
/// and `Utf16`, and it is one line of pubspec away, but the framework's own
/// pubspec has no runtime dependency other than `meta` and a windowing backend
/// is not the place to add one. The replacements are small: a process-heap
/// [Allocator] and a UTF-16 marshaller live at the bottom of this file.
///
/// Second, **a missing optional symbol is data, not an exception**. Windows 8.1
/// has `SetProcessDpiAwareness`, Windows 10 1607 has
/// `SetProcessDpiAwarenessContext`, and something older has neither. The probe
/// has to say which one it found, so lookup failures for those symbols are
/// recorded and the field is left null rather than thrown from.
library;

import 'dart:ffi';

import '../../foundation/diagnostics.dart';
import 'win32_constants.dart';
import 'win32_structs.dart';

/// Which process-wide DPI awareness API this machine offers.
///
/// The distinction is not cosmetic: only [perMonitorV2] gives WM_DPICHANGED
/// with a correctly scaled non-client area, [perMonitorV1] gives per-monitor
/// DPI with a caption bar that stays at the boot scale, and [systemOnly] means
/// every secondary monitor is bitmap-stretched by the compositor.
enum Win32DpiAwarenessApi {
  /// `SetProcessDpiAwarenessContext` in user32 (Windows 10 1607+).
  perMonitorV2,

  /// `SetProcessDpiAwareness` in shcore (Windows 8.1+).
  perMonitorV1,

  /// `SetProcessDPIAware` in user32 (Vista+). System DPI only.
  systemOnly,

  /// None of the three. The process is DPI-unaware and everything is
  /// stretched; the backend still runs, at scale 1.0.
  none,
}

/// What [Win32Api.load] found, whether or not it succeeded.
final class Win32LoadResult {
  const Win32LoadResult({required this.api, required this.diagnostics});

  /// Null when a required library or symbol was missing. [diagnostics] then
  /// names it.
  final Win32Api? api;

  final List<BackendDiagnostic> diagnostics;
}

/// The bound Win32 entry points, loaded once per process.
///
/// Fields are lowerCamelCase versions of the native names, which keeps the
/// analyser quiet without making the calls unrecognisable.
final class Win32Api {
  Win32Api._(this._kernel32, this._user32, this._gdi32, this._shcore) {
    _bindKernel32();
    _bindUser32();
    _bindGdi32();
    _bindOptional();
    _heap = _getProcessHeap();
    allocator = _ProcessHeapAllocator(this);
  }

  final DynamicLibrary _kernel32;
  final DynamicLibrary _user32;
  final DynamicLibrary _gdi32;
  final DynamicLibrary? _shcore;

  static Win32LoadResult? _cached;

  /// Loads and binds, or explains what stopped it. Cached: repeated probes are
  /// normal (a selection policy probes every backend) and reopening the same
  /// three DLLs per probe is wasted work.
  static Win32LoadResult load() {
    final cached = _cached;
    if (cached != null) return cached;

    final diagnostics = <BackendDiagnostic>[];
    DynamicLibrary open(String name) => DynamicLibrary.open(name);

    DynamicLibrary kernel32;
    DynamicLibrary user32;
    DynamicLibrary gdi32;
    try {
      kernel32 = open('kernel32.dll');
      user32 = open('user32.dll');
      gdi32 = open('gdi32.dll');
    } on Object catch (error) {
      final result = Win32LoadResult(
        api: null,
        diagnostics: <BackendDiagnostic>[
          BackendDiagnostic.missingLibrary(
            'kernel32.dll / user32.dll / gdi32.dll',
            detail: '$error',
          ),
        ],
      );
      _cached = result;
      return result;
    }

    // shcore is genuinely optional: it does not exist before Windows 8.1, and
    // its absence only narrows the DPI story.
    DynamicLibrary? shcore;
    try {
      shcore = open('shcore.dll');
    } on Object catch (error) {
      diagnostics.add(
        BackendDiagnostic.note(
          'shcore.dll not loadable; SetProcessDpiAwareness unavailable',
          detail: '$error',
        ),
      );
    }

    Win32LoadResult result;
    try {
      final api = Win32Api._(kernel32, user32, gdi32, shcore);
      diagnostics.addAll(api._optionalDiagnostics);
      result = Win32LoadResult(api: api, diagnostics: diagnostics);
    } on ArgumentError catch (error) {
      // A *required* symbol was missing. That is not a supported Windows.
      diagnostics.add(
        BackendDiagnostic.missingSymbol('$error', detail: 'required symbol'),
      );
      result = Win32LoadResult(api: null, diagnostics: diagnostics);
    }
    _cached = result;
    return result;
  }

  /// Drops the cache. Only for tests that want to observe a fresh load.
  static void debugResetCache() => _cached = null;

  final List<BackendDiagnostic> _optionalDiagnostics = <BackendDiagnostic>[];

  late final int _heap;

  /// Allocates from the process heap. Not a general-purpose allocator: it is
  /// here so the backend can build scratch structs once and reuse them.
  late final Allocator allocator;

  // -------------------------------------------------------------------------
  // kernel32
  // -------------------------------------------------------------------------

  late final int Function() getLastError;
  late final int Function(Pointer<Uint16>) getModuleHandleW;
  late final int Function() _getProcessHeap;
  late final Pointer<Void> Function(int, int, int) _heapAlloc;
  late final int Function(int, int, Pointer<Void>) _heapFree;

  void _bindKernel32() {
    getLastError = _kernel32
        .lookupFunction<Uint32 Function(), int Function()>('GetLastError');
    getModuleHandleW = _kernel32.lookupFunction<
        IntPtr Function(Pointer<Uint16>),
        int Function(Pointer<Uint16>)>('GetModuleHandleW');
    _getProcessHeap = _kernel32
        .lookupFunction<IntPtr Function(), int Function()>('GetProcessHeap');
    _heapAlloc = _kernel32.lookupFunction<
        Pointer<Void> Function(IntPtr, Uint32, IntPtr),
        Pointer<Void> Function(int, int, int)>('HeapAlloc');
    _heapFree = _kernel32.lookupFunction<
        Int32 Function(IntPtr, Uint32, Pointer<Void>),
        int Function(int, int, Pointer<Void>)>('HeapFree');
  }

  // -------------------------------------------------------------------------
  // user32
  // -------------------------------------------------------------------------

  late final int Function(Pointer<WndClassExW>) registerClassExW;
  late final int Function(Pointer<Uint16>, int) unregisterClassW;
  late final int Function(int, Pointer<Uint16>, Pointer<WndClassExW>)
      getClassInfoExW;
  late final int Function(
    int dwExStyle,
    Pointer<Uint16> lpClassName,
    Pointer<Uint16> lpWindowName,
    int dwStyle,
    int x,
    int y,
    int nWidth,
    int nHeight,
    int hWndParent,
    int hMenu,
    int hInstance,
    int lpParam,
  ) createWindowExW;
  late final int Function(int) destroyWindow;
  late final int Function(int) isWindow;
  late final int Function(int, int) showWindow;
  late final int Function(int) updateWindow;
  late final int Function(int, int, int, int) defWindowProcW;
  late final int Function(Pointer<Msg>, int, int, int, int) peekMessageW;
  late final int Function(Pointer<Msg>) translateMessage;
  late final int Function(Pointer<Msg>) dispatchMessageW;
  late final int Function(int, int, int, int) postMessageW;
  late final void Function(int) postQuitMessage;
  late final int Function(int, Pointer<Win32Rect>) getClientRect;
  late final int Function(int, Pointer<Win32Rect>) getWindowRect;
  late final int Function(int, Pointer<Win32Point>) clientToScreen;
  late final int Function(int, Pointer<Win32Point>) screenToClient;
  late final int Function(int, Pointer<Win32Rect>, int) invalidateRect;
  late final int Function(int, Pointer<Win32Rect>) validateRect;
  late final int Function(int, Pointer<Win32Rect>, int) getUpdateRect;
  late final int Function(int, Pointer<Uint16>) setWindowTextW;
  late final int Function(int, int, int) setWindowLongPtrW;
  late final int Function(int, int) getWindowLongPtrW;
  late final int Function(int, int, int, int, int, int, int) setWindowPos;
  late final int Function(Pointer<Win32Rect>, int, int, int) adjustWindowRectEx;
  late final int Function(int, int) loadCursorW;
  late final int Function(int) setCursor;
  late final int Function(int) getDC;
  late final int Function(int, int) releaseDC;
  late final int Function(int, Pointer<Uint32>, int, int, int)
      msgWaitForMultipleObjectsEx;
  late final int Function(Pointer<TrackMouseEventStruct>) trackMouseEvent;

  late final int Function(
          int,
          int,
          int,
          Pointer<
              NativeFunction<Void Function(IntPtr, Uint32, IntPtr, Uint32)>>)
      setTimer;
  late final int Function(int, int) killTimer;

  void _bindUser32() {
    registerClassExW = _user32.lookupFunction<
        Uint16 Function(Pointer<WndClassExW>),
        int Function(Pointer<WndClassExW>)>('RegisterClassExW');
    unregisterClassW = _user32.lookupFunction<
        Int32 Function(Pointer<Uint16>, IntPtr),
        int Function(Pointer<Uint16>, int)>('UnregisterClassW');
    getClassInfoExW = _user32.lookupFunction<
        Int32 Function(IntPtr, Pointer<Uint16>, Pointer<WndClassExW>),
        int Function(
            int, Pointer<Uint16>, Pointer<WndClassExW>)>('GetClassInfoExW');
    createWindowExW = _user32.lookupFunction<
        IntPtr Function(Uint32, Pointer<Uint16>, Pointer<Uint16>, Uint32, Int32,
            Int32, Int32, Int32, IntPtr, IntPtr, IntPtr, IntPtr),
        int Function(int, Pointer<Uint16>, Pointer<Uint16>, int, int, int, int,
            int, int, int, int, int)>('CreateWindowExW');
    destroyWindow =
        _user32.lookupFunction<Int32 Function(IntPtr), int Function(int)>(
            'DestroyWindow');
    isWindow = _user32
        .lookupFunction<Int32 Function(IntPtr), int Function(int)>('IsWindow');
    showWindow = _user32.lookupFunction<Int32 Function(IntPtr, Int32),
        int Function(int, int)>('ShowWindow');
    updateWindow =
        _user32.lookupFunction<Int32 Function(IntPtr), int Function(int)>(
            'UpdateWindow');
    defWindowProcW = _user32.lookupFunction<
        IntPtr Function(IntPtr, Uint32, IntPtr, IntPtr),
        int Function(int, int, int, int)>('DefWindowProcW');
    peekMessageW = _user32.lookupFunction<
        Int32 Function(Pointer<Msg>, IntPtr, Uint32, Uint32, Uint32),
        int Function(Pointer<Msg>, int, int, int, int)>('PeekMessageW');
    translateMessage = _user32.lookupFunction<Int32 Function(Pointer<Msg>),
        int Function(Pointer<Msg>)>('TranslateMessage');
    dispatchMessageW = _user32.lookupFunction<IntPtr Function(Pointer<Msg>),
        int Function(Pointer<Msg>)>('DispatchMessageW');
    postMessageW = _user32.lookupFunction<
        Int32 Function(IntPtr, Uint32, IntPtr, IntPtr),
        int Function(int, int, int, int)>('PostMessageW');
    postQuitMessage =
        _user32.lookupFunction<Void Function(Int32), void Function(int)>(
            'PostQuitMessage');
    getClientRect = _user32.lookupFunction<
        Int32 Function(IntPtr, Pointer<Win32Rect>),
        int Function(int, Pointer<Win32Rect>)>('GetClientRect');
    getWindowRect = _user32.lookupFunction<
        Int32 Function(IntPtr, Pointer<Win32Rect>),
        int Function(int, Pointer<Win32Rect>)>('GetWindowRect');
    clientToScreen = _user32.lookupFunction<
        Int32 Function(IntPtr, Pointer<Win32Point>),
        int Function(int, Pointer<Win32Point>)>('ClientToScreen');
    screenToClient = _user32.lookupFunction<
        Int32 Function(IntPtr, Pointer<Win32Point>),
        int Function(int, Pointer<Win32Point>)>('ScreenToClient');
    invalidateRect = _user32.lookupFunction<
        Int32 Function(IntPtr, Pointer<Win32Rect>, Int32),
        int Function(int, Pointer<Win32Rect>, int)>('InvalidateRect');
    validateRect = _user32.lookupFunction<
        Int32 Function(IntPtr, Pointer<Win32Rect>),
        int Function(int, Pointer<Win32Rect>)>('ValidateRect');
    getUpdateRect = _user32.lookupFunction<
        Int32 Function(IntPtr, Pointer<Win32Rect>, Int32),
        int Function(int, Pointer<Win32Rect>, int)>('GetUpdateRect');
    setWindowTextW = _user32.lookupFunction<
        Int32 Function(IntPtr, Pointer<Uint16>),
        int Function(int, Pointer<Uint16>)>('SetWindowTextW');

    // SetWindowLongPtrW only exists on 64-bit; the 32-bit SDK maps the name to
    // SetWindowLongW with a macro, which FFI cannot see.
    try {
      setWindowLongPtrW = _user32.lookupFunction<
          IntPtr Function(IntPtr, Int32, IntPtr),
          int Function(int, int, int)>('SetWindowLongPtrW');
      getWindowLongPtrW = _user32.lookupFunction<IntPtr Function(IntPtr, Int32),
          int Function(int, int)>('GetWindowLongPtrW');
    } on ArgumentError {
      setWindowLongPtrW = _user32.lookupFunction<
          Int32 Function(IntPtr, Int32, Int32),
          int Function(int, int, int)>('SetWindowLongW');
      getWindowLongPtrW = _user32.lookupFunction<Int32 Function(IntPtr, Int32),
          int Function(int, int)>('GetWindowLongW');
      _optionalDiagnostics.add(
        const BackendDiagnostic.note(
          'SetWindowLongPtrW missing; using SetWindowLongW (32-bit Windows)',
        ),
      );
    }

    setWindowPos = _user32.lookupFunction<
        Int32 Function(IntPtr, IntPtr, Int32, Int32, Int32, Int32, Uint32),
        int Function(int, int, int, int, int, int, int)>('SetWindowPos');
    adjustWindowRectEx = _user32.lookupFunction<
        Int32 Function(Pointer<Win32Rect>, Uint32, Int32, Uint32),
        int Function(Pointer<Win32Rect>, int, int, int)>('AdjustWindowRectEx');
    loadCursorW = _user32.lookupFunction<IntPtr Function(IntPtr, IntPtr),
        int Function(int, int)>('LoadCursorW');
    setCursor =
        _user32.lookupFunction<IntPtr Function(IntPtr), int Function(int)>(
            'SetCursor');
    getDC = _user32
        .lookupFunction<IntPtr Function(IntPtr), int Function(int)>('GetDC');
    releaseDC = _user32.lookupFunction<Int32 Function(IntPtr, IntPtr),
        int Function(int, int)>('ReleaseDC');
    msgWaitForMultipleObjectsEx = _user32.lookupFunction<
        Uint32 Function(Uint32, Pointer<Uint32>, Uint32, Uint32, Uint32),
        int Function(int, Pointer<Uint32>, int, int,
            int)>('MsgWaitForMultipleObjectsEx');
    trackMouseEvent = _user32.lookupFunction<
        Int32 Function(Pointer<TrackMouseEventStruct>),
        int Function(Pointer<TrackMouseEventStruct>)>('TrackMouseEvent');
    setTimer = _user32.lookupFunction<
        IntPtr Function(
            IntPtr,
            IntPtr,
            Uint32,
            Pointer<
                NativeFunction<Void Function(IntPtr, Uint32, IntPtr, Uint32)>>),
        int Function(
            int,
            int,
            int,
            Pointer<
                NativeFunction<
                    Void Function(
                        IntPtr, Uint32, IntPtr, Uint32)>>)>('SetTimer');
    killTimer = _user32.lookupFunction<Int32 Function(IntPtr, IntPtr),
        int Function(int, int)>('KillTimer');
  }

  // -------------------------------------------------------------------------
  // gdi32
  // -------------------------------------------------------------------------

  late final int Function(int) createCompatibleDC;
  late final int Function(int) deleteDC;
  late final int Function(
    int hdc,
    Pointer<BitmapInfo> pbmi,
    int usage,
    Pointer<Pointer<Void>> ppvBits,
    int hSection,
    int offset,
  ) createDIBSection;
  late final int Function(int) deleteObject;
  late final int Function(int, int) selectObject;
  late final int Function(int, int, int, int, int, int, int, int, int) bitBlt;
  late final int Function(int, int) getDeviceCaps;

  void _bindGdi32() {
    createCompatibleDC =
        _gdi32.lookupFunction<IntPtr Function(IntPtr), int Function(int)>(
            'CreateCompatibleDC');
    deleteDC = _gdi32
        .lookupFunction<Int32 Function(IntPtr), int Function(int)>('DeleteDC');
    createDIBSection = _gdi32.lookupFunction<
        IntPtr Function(IntPtr, Pointer<BitmapInfo>, Uint32,
            Pointer<Pointer<Void>>, IntPtr, Uint32),
        int Function(int, Pointer<BitmapInfo>, int, Pointer<Pointer<Void>>, int,
            int)>('CreateDIBSection');
    deleteObject =
        _gdi32.lookupFunction<Int32 Function(IntPtr), int Function(int)>(
            'DeleteObject');
    selectObject = _gdi32.lookupFunction<IntPtr Function(IntPtr, IntPtr),
        int Function(int, int)>('SelectObject');
    bitBlt = _gdi32.lookupFunction<
        Int32 Function(
            IntPtr, Int32, Int32, Int32, Int32, IntPtr, Int32, Int32, Uint32),
        int Function(int, int, int, int, int, int, int, int, int)>('BitBlt');
    getDeviceCaps = _gdi32.lookupFunction<Int32 Function(IntPtr, Int32),
        int Function(int, int)>('GetDeviceCaps');
  }

  // -------------------------------------------------------------------------
  // Optional, version-dependent symbols
  // -------------------------------------------------------------------------

  int Function(int)? setProcessDpiAwarenessContext;
  int Function()? setProcessDpiAware;
  int Function(int)? setProcessDpiAwareness;
  int Function(int)? getDpiForWindow;
  int Function()? getDpiForSystem;
  int Function(Pointer<Win32Rect>, int, int, int, int)?
      adjustWindowRectExForDpi;

  /// Which awareness API to call. Decided once, reported by the probe.
  late final Win32DpiAwarenessApi dpiAwarenessApi;

  void _bindOptional() {
    T? tryLookup<T extends Function>(
      DynamicLibrary? library,
      String symbol,
      T Function(DynamicLibrary) bind,
    ) {
      if (library == null) return null;
      try {
        return bind(library);
      } on ArgumentError {
        _optionalDiagnostics.add(BackendDiagnostic.missingSymbol(symbol));
        return null;
      }
    }

    setProcessDpiAwarenessContext = tryLookup(
      _user32,
      'SetProcessDpiAwarenessContext',
      (library) =>
          library.lookupFunction<Int32 Function(IntPtr), int Function(int)>(
              'SetProcessDpiAwarenessContext'),
    );
    setProcessDpiAwareness = tryLookup(
      _shcore,
      'SetProcessDpiAwareness',
      (library) =>
          library.lookupFunction<Int32 Function(Int32), int Function(int)>(
              'SetProcessDpiAwareness'),
    );
    setProcessDpiAware = tryLookup(
      _user32,
      'SetProcessDPIAware',
      (library) => library.lookupFunction<Int32 Function(), int Function()>(
          'SetProcessDPIAware'),
    );
    getDpiForWindow = tryLookup(
      _user32,
      'GetDpiForWindow',
      (library) =>
          library.lookupFunction<Uint32 Function(IntPtr), int Function(int)>(
              'GetDpiForWindow'),
    );
    getDpiForSystem = tryLookup(
      _user32,
      'GetDpiForSystem',
      (library) => library
          .lookupFunction<Uint32 Function(), int Function()>('GetDpiForSystem'),
    );
    adjustWindowRectExForDpi = tryLookup(
      _user32,
      'AdjustWindowRectExForDpi',
      (library) => library.lookupFunction<
          Int32 Function(Pointer<Win32Rect>, Uint32, Int32, Uint32, Uint32),
          int Function(Pointer<Win32Rect>, int, int, int,
              int)>('AdjustWindowRectExForDpi'),
    );

    dpiAwarenessApi = setProcessDpiAwarenessContext != null
        ? Win32DpiAwarenessApi.perMonitorV2
        : setProcessDpiAwareness != null
            ? Win32DpiAwarenessApi.perMonitorV1
            : setProcessDpiAware != null
                ? Win32DpiAwarenessApi.systemOnly
                : Win32DpiAwarenessApi.none;
  }

  /// Diagnostics gathered while binding: missing optional symbols, fallbacks
  /// taken. Copied into every probe result so the log explains the machine.
  List<BackendDiagnostic> get bindingDiagnostics =>
      List<BackendDiagnostic>.unmodifiable(_optionalDiagnostics);

  // -------------------------------------------------------------------------
  // Derived helpers
  // -------------------------------------------------------------------------

  /// The DPI the desktop as a whole is configured at.
  ///
  /// GetDpiForSystem is Windows 10 1607; before that the screen DC's
  /// LOGPIXELSX is the same number for a system-aware process.
  int systemDpi() {
    final direct = getDpiForSystem;
    if (direct != null) return direct();
    final screenDc = getDC(0);
    if (screenDc == 0) return defaultScreenDpi;
    final dpi = getDeviceCaps(screenDc, logPixelsX);
    releaseDC(0, screenDc);
    return dpi <= 0 ? defaultScreenDpi : dpi;
  }

  /// Grows [rect] from a client rectangle to the window rectangle that
  /// contains it, honouring the per-monitor variant when it exists. Without
  /// the ForDpi variant the frame is computed at the *system* DPI, which is
  /// visibly wrong on a secondary monitor - hence the diagnostic note.
  int adjustWindowRect(
    Pointer<Win32Rect> rect,
    int style,
    int exStyle,
    int dpi,
  ) {
    final forDpi = adjustWindowRectExForDpi;
    if (forDpi != null) return forDpi(rect, style, 0, exStyle, dpi);
    return adjustWindowRectEx(rect, style, 0, exStyle);
  }

  // -------------------------------------------------------------------------
  // Memory
  // -------------------------------------------------------------------------

  /// Allocates [byteCount] zeroed bytes from the process heap.
  Pointer<Void> heapAllocate(int byteCount) =>
      _heapAlloc(_heap, heapZeroMemory, byteCount);

  void heapRelease(Pointer<NativeType> pointer) {
    if (pointer == nullptr) return;
    _heapFree(_heap, 0, pointer.cast());
  }

  /// Copies [value] into a null-terminated UTF-16 buffer.
  ///
  /// Dart strings are already UTF-16 code units, surrogate pairs included, so
  /// this is a copy and not a transcode. The caller owns the result and must
  /// pass it to [heapRelease].
  Pointer<Uint16> toUtf16(String value) {
    final units = value.codeUnits;
    final pointer = heapAllocate((units.length + 1) * 2).cast<Uint16>();
    if (pointer == nullptr) {
      throw StateError('HeapAlloc failed for a ${units.length}-unit string');
    }
    final view = pointer.asTypedList(units.length + 1);
    view.setRange(0, units.length, units);
    view[units.length] = 0;
    return pointer;
  }
}

/// [Allocator] over the process heap, so scratch structs can be built with
/// `sizeOf<T>()` and released in reverse order like every other resource.
final class _ProcessHeapAllocator implements Allocator {
  const _ProcessHeapAllocator(this._api);

  final Win32Api _api;

  @override
  Pointer<T> allocate<T extends NativeType>(int byteCount, {int? alignment}) {
    final pointer = _api.heapAllocate(byteCount);
    if (pointer == nullptr) {
      throw StateError('HeapAlloc failed for $byteCount bytes');
    }
    // The process heap returns 16-byte aligned blocks on x64 and 8 on x86,
    // which covers every struct here; a stricter request would be a bug.
    return pointer.cast<T>();
  }

  @override
  void free(Pointer<NativeType> pointer) => _api.heapRelease(pointer);
}
