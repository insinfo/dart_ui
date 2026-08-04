/// Win32 Window implementation for POC-01.
///
/// Demonstrates that pure Dart can:
/// - Register a window class with NativeCallable WndProc
/// - Create and manage a Win32 window
/// - Handle messages (paint, resize, close, input)
/// - Present a CPU-rendered framebuffer via GDI DIBSection
library;

import 'dart:ffi';
import 'dart:typed_data';
import 'package:ffi/ffi.dart';

import 'win32_constants.dart';
import 'win32_structs.dart';
import 'win32_functions.dart';

/// Registry that maps HWND → Win32Window instances.
///
/// Uses a generational token stored in GWLP_USERDATA to avoid
/// dangling Dart object references.
class _WindowRegistry {
  static int _nextToken = 1;
  static final Map<int, Win32Window> _windows = {};

  static int attach(Win32Window window) {
    final token = _nextToken++;
    _windows[token] = window;
    return token;
  }

  static Win32Window? resolve(int token) => _windows[token];

  static void detach(int token) {
    _windows.remove(token);
  }
}

/// A basic Win32 window created entirely from Dart via FFI.
class Win32Window {
  /// The native window handle, or 0 if not created/already destroyed.
  int _hwnd = 0;
  int get hwnd => _hwnd;
  bool get isCreated => _hwnd != 0;

  /// Token in the window registry.
  int _token = 0;

  /// Client area size in pixels.
  int _clientWidth = 0;
  int _clientHeight = 0;
  int get clientWidth => _clientWidth;
  int get clientHeight => _clientHeight;

  /// DPI of the window (96 = 100%).
  int _dpi = 96;
  int get dpi => _dpi;
  double get scale => _dpi / 96.0;

  /// CPU framebuffer — BGRA pixel data.
  /// Access this to draw pixels, then call [invalidate] to present.
  Uint8List? _framebuffer;
  Uint8List? get framebuffer => _framebuffer;

  // GDI resources for framebuffer presentation
  int _dibSection = 0;
  int _memDC = 0;

  /// Callbacks for window events.
  void Function(Win32Window window)? onPaint;
  void Function(Win32Window window, int width, int height)? onResize;
  void Function(Win32Window window)? onClose;
  void Function(Win32Window window, int msg, int wParam, int lParam)? onMessage;
  void Function(Win32Window window, int x, int y)? onMouseMove;
  void Function(Win32Window window, int x, int y, int button)? onMouseDown;
  void Function(Win32Window window, int x, int y, int button)? onMouseUp;
  void Function(Win32Window window, int keyCode, bool isDown)? onKey;

  /// Whether this window has been destroyed.
  bool _destroyed = false;
  bool get isDestroyed => _destroyed;

  /// Static: shared WndProc callback (one for all windows).
  static NativeCallable<WNDPROC>? _wndProcCallable;
  static Pointer<Utf16>? _className;
  static int _classAtom = 0;
  static int _hInstance = 0;
  static bool _classRegistered = false;

  /// Initialize the Win32 subsystem. Must be called once before creating windows.
  static void initializeWin32() {
    Win32.initialize();

    // Set DPI awareness before creating any windows
    if (Win32.SetProcessDpiAwarenessContext != null) {
      final result = Win32.SetProcessDpiAwarenessContext!(
        DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2,
      );
      if (result == 0) {
        print('[Win32] SetProcessDpiAwarenessContext failed '
            '(error: ${Win32.GetLastError()})');
      }
    }

    // Get HINSTANCE
    _hInstance = Win32.GetModuleHandleW(nullptr);
  }

  /// Register the window class. Done once for all windows of this framework.
  static void _ensureClassRegistered() {
    if (_classRegistered) return;

    // Create the WndProc callback — CRITICAL: this must stay alive
    // for the entire duration of the program.
    _wndProcCallable = NativeCallable<WNDPROC>.isolateLocal(
      _staticWndProc,
      exceptionalReturn: 0,
    );

    // Allocate class name
    _className = 'DartUiPOC01WindowClass'.toNativeUtf16();

    // Load cursor
    final hCursor = Win32.LoadCursorW(0, IDC_ARROW);

    // Register window class
    final wc = calloc<WNDCLASSEXW>();
    wc.ref.cbSize = sizeOf<WNDCLASSEXW>();
    wc.ref.style = CS_HREDRAW | CS_VREDRAW | CS_DBLCLKS;
    wc.ref.lpfnWndProc = _wndProcCallable!.nativeFunction;
    wc.ref.cbClsExtra = 0;
    wc.ref.cbWndExtra = 0;
    wc.ref.hInstance = _hInstance;
    wc.ref.hIcon = 0;
    wc.ref.hCursor = hCursor;
    wc.ref.hbrBackground = 0; // No background — we paint everything
    wc.ref.lpszMenuName = nullptr;
    wc.ref.lpszClassName = _className!;
    wc.ref.hIconSm = 0;

    _classAtom = Win32.RegisterClassExW(wc);
    calloc.free(wc);

    if (_classAtom == 0) {
      throw StateError(
        'RegisterClassExW failed (error: ${Win32.GetLastError()})',
      );
    }

    _classRegistered = true;
    print('[Win32] Window class registered (atom: $_classAtom)');
  }

  /// Create and show the window.
  void create({
    String title = 'DartUI POC-01',
    int width = 800,
    int height = 600,
  }) {
    if (_hwnd != 0) {
      throw StateError('Window already created');
    }

    _ensureClassRegistered();

    // Register this window in our registry
    _token = _WindowRegistry.attach(this);

    // Create the window
    final lpTitle = title.toNativeUtf16();
    _hwnd = Win32.CreateWindowExW(
      WS_EX_APPWINDOW,
      _className!,
      lpTitle,
      WS_OVERLAPPEDWINDOW,
      CW_USEDEFAULT,
      CW_USEDEFAULT,
      width,
      height,
      0, // no parent
      0, // no menu
      _hInstance,
      _token, // pass our token as lpParam
    );
    calloc.free(lpTitle);

    if (_hwnd == 0) {
      _WindowRegistry.detach(_token);
      throw StateError(
        'CreateWindowExW failed (error: ${Win32.GetLastError()})',
      );
    }

    // Store our token in the window's user data
    Win32.SetWindowLongPtrW(_hwnd, GWLP_USERDATA, _token);

    // Query DPI
    if (Win32.GetDpiForWindow != null) {
      _dpi = Win32.GetDpiForWindow!(_hwnd);
    }

    // Get initial client size
    _updateClientSize();

    // Create the DIB section for CPU rendering
    _createFramebuffer();

    print('[Win32] Window created (hwnd: 0x${_hwnd.toRadixString(16)}, '
        '${_clientWidth}x$_clientHeight, dpi: $_dpi)');
  }

  /// Show the window.
  void show() {
    if (_hwnd == 0) return;
    Win32.ShowWindow(_hwnd, SW_SHOWNORMAL);
    Win32.UpdateWindow(_hwnd);
  }

  /// Set the window title.
  void setTitle(String title) {
    if (_hwnd == 0) return;
    final lpTitle = title.toNativeUtf16();
    Win32.SetWindowTextW(_hwnd, lpTitle);
    calloc.free(lpTitle);
  }

  /// Mark the window as needing repaint.
  void invalidate() {
    if (_hwnd == 0) return;
    Win32.InvalidateRect(_hwnd, nullptr, 0);
  }

  /// Close the window.
  void close() {
    if (_hwnd == 0) return;
    Win32.DestroyWindow(_hwnd);
  }

  /// Fill the framebuffer with a solid color (BGRA).
  void clearFramebuffer(int b, int g, int r, int a) {
    final fb = _framebuffer;
    if (fb == null) return;
    for (var i = 0; i < fb.length; i += 4) {
      fb[i + 0] = b;
      fb[i + 1] = g;
      fb[i + 2] = r;
      fb[i + 3] = a;
    }
  }

  /// Fill a rectangle in the framebuffer with a solid color (BGRA).
  void fillRect(int x, int y, int w, int h, int b, int g, int r, int a) {
    final fb = _framebuffer;
    if (fb == null) return;
    final cw = _clientWidth;
    final ch = _clientHeight;

    // Clamp
    final x0 = x.clamp(0, cw);
    final y0 = y.clamp(0, ch);
    final x1 = (x + w).clamp(0, cw);
    final y1 = (y + h).clamp(0, ch);

    for (var py = y0; py < y1; py++) {
      final rowOffset = py * cw * 4;
      for (var px = x0; px < x1; px++) {
        final i = rowOffset + px * 4;
        fb[i + 0] = b;
        fb[i + 1] = g;
        fb[i + 2] = r;
        fb[i + 3] = a;
      }
    }
  }

  // ============================================================
  // Framebuffer management
  // ============================================================

  void _createFramebuffer() {
    _destroyFramebuffer();
    if (_clientWidth <= 0 || _clientHeight <= 0) return;

    // Allocate Dart-side pixel buffer
    _framebuffer = Uint8List(_clientWidth * _clientHeight * 4);

    print('[Win32] Framebuffer created: ${_clientWidth}x$_clientHeight '
        '(${_framebuffer!.length} bytes)');
  }

  void _destroyFramebuffer() {
    if (_dibSection != 0) {
      Win32.DeleteObject(_dibSection);
      _dibSection = 0;
    }
    if (_memDC != 0) {
      Win32.DeleteDC(_memDC);
      _memDC = 0;
    }
    _framebuffer = null;
  }

  void _updateClientSize() {
    if (_hwnd == 0) return;
    final rc = calloc<RECT>();
    Win32.GetClientRect(_hwnd, rc);
    _clientWidth = rc.ref.right - rc.ref.left;
    _clientHeight = rc.ref.bottom - rc.ref.top;
    calloc.free(rc);
  }

  /// Present the framebuffer to the window via StretchDIBits.
  void _presentFramebuffer(int hdc) {
    final fb = _framebuffer;
    if (fb == null || _clientWidth <= 0 || _clientHeight <= 0) return;

    // Create BITMAPINFO on the stack
    final bmi = calloc<BITMAPINFO>();
    bmi.ref.bmiHeader.biSize = sizeOf<BITMAPINFOHEADER>();
    bmi.ref.bmiHeader.biWidth = _clientWidth;
    bmi.ref.bmiHeader.biHeight = -_clientHeight; // Top-down DIB
    bmi.ref.bmiHeader.biPlanes = 1;
    bmi.ref.bmiHeader.biBitCount = 32;
    bmi.ref.bmiHeader.biCompression = BI_RGB;

    // Copy from Dart Uint8List via Pointer
    final srcPtr = calloc<Uint8>(fb.length);
    srcPtr.asTypedList(fb.length).setAll(0, fb);

    Win32.StretchDIBits(
      hdc,
      0, 0, _clientWidth, _clientHeight, // dest
      0, 0, _clientWidth, _clientHeight, // src
      srcPtr.cast(),
      bmi,
      DIB_RGB_COLORS,
      SRCCOPY,
    );

    calloc.free(srcPtr);
    calloc.free(bmi);
  }

  // ============================================================
  // Static WndProc — dispatches to per-window handler
  // ============================================================

  static int _staticWndProc(int hwnd, int msg, int wParam, int lParam) {
    try {
      // On WM_NCCREATE, extract our token from CREATESTRUCT
      if (msg == WM_NCCREATE) {
        final cs = Pointer<CREATESTRUCTW>.fromAddress(lParam);
        final token = cs.ref.lpCreateParams;
        if (token != 0) {
          Win32.SetWindowLongPtrW(hwnd, GWLP_USERDATA, token);
        }
        return Win32.DefWindowProcW(hwnd, msg, wParam, lParam);
      }

      // Look up the window by its token
      final token = Win32.GetWindowLongPtrW(hwnd, GWLP_USERDATA);
      final window = _WindowRegistry.resolve(token);

      if (window == null) {
        return Win32.DefWindowProcW(hwnd, msg, wParam, lParam);
      }

      return window._handleMessage(hwnd, msg, wParam, lParam);
    } catch (e, st) {
      // CRITICAL: Never let an exception cross the FFI boundary
      print('[WndProc ERROR] $e\n$st');
      return Win32.DefWindowProcW(hwnd, msg, wParam, lParam);
    }
  }

  // ============================================================
  // Instance message handler
  // ============================================================

  int _handleMessage(int hwnd, int msg, int wParam, int lParam) {
    switch (msg) {
      case WM_PAINT:
        return _onPaint(hwnd);

      case WM_SIZE:
        final w = lParam & 0xFFFF;
        final h = (lParam >> 16) & 0xFFFF;
        return _onSize(hwnd, w, h);

      case WM_DPICHANGED:
        final newDpi = wParam & 0xFFFF;
        return _onDpiChanged(hwnd, newDpi, lParam);

      case WM_CLOSE:
        onClose?.call(this);
        Win32.DestroyWindow(hwnd);
        return 0;

      case WM_DESTROY:
        _onDestroy();
        Win32.PostQuitMessage(0);
        return 0;

      case WM_NCDESTROY:
        _onNcDestroy();
        return 0;

      case WM_ERASEBKGND:
        return 1; // We handle all painting

      case WM_MOUSEMOVE:
        final x = _loWord(lParam);
        final y = _hiWord(lParam);
        onMouseMove?.call(this, x, y);
        return 0;

      case WM_LBUTTONDOWN:
        final x = _loWord(lParam);
        final y = _hiWord(lParam);
        onMouseDown?.call(this, x, y, 0);
        return 0;

      case WM_LBUTTONUP:
        final x = _loWord(lParam);
        final y = _hiWord(lParam);
        onMouseUp?.call(this, x, y, 0);
        return 0;

      case WM_RBUTTONDOWN:
        final x = _loWord(lParam);
        final y = _hiWord(lParam);
        onMouseDown?.call(this, x, y, 1);
        return 0;

      case WM_RBUTTONUP:
        final x = _loWord(lParam);
        final y = _hiWord(lParam);
        onMouseUp?.call(this, x, y, 1);
        return 0;

      case WM_KEYDOWN:
      case WM_SYSKEYDOWN:
        onKey?.call(this, wParam, true);
        // Forward key messages we don't consume
        onMessage?.call(this, msg, wParam, lParam);
        return Win32.DefWindowProcW(hwnd, msg, wParam, lParam);

      case WM_KEYUP:
      case WM_SYSKEYUP:
        onKey?.call(this, wParam, false);
        onMessage?.call(this, msg, wParam, lParam);
        return Win32.DefWindowProcW(hwnd, msg, wParam, lParam);

      default:
        onMessage?.call(this, msg, wParam, lParam);
        return Win32.DefWindowProcW(hwnd, msg, wParam, lParam);
    }
  }

  int _onPaint(int hwnd) {
    final ps = calloc<PAINTSTRUCT>();
    final hdc = Win32.BeginPaint(hwnd, ps);

    // Call user paint callback to update framebuffer
    onPaint?.call(this);

    // Present framebuffer to window
    _presentFramebuffer(hdc);

    Win32.EndPaint(hwnd, ps);
    calloc.free(ps);
    return 0;
  }

  int _onSize(int hwnd, int width, int height) {
    if (width <= 0 || height <= 0) return 0;

    _clientWidth = width;
    _clientHeight = height;
    _createFramebuffer();

    onResize?.call(this, width, height);

    // Request repaint
    invalidate();
    return 0;
  }

  int _onDpiChanged(int hwnd, int newDpi, int _) {
    final oldDpi = _dpi;
    _dpi = newDpi;
    print(
        '[Win32] DPI changed: $oldDpi → $newDpi (scale: ${scale.toStringAsFixed(2)})');

    // We could use SetWindowPos here; for now, just invalidate
    invalidate();
    return 0;
  }

  void _onDestroy() {
    _destroyFramebuffer();
    _destroyed = true;
    print('[Win32] Window destroyed');
  }

  void _onNcDestroy() {
    // Final cleanup — remove from registry
    if (_token != 0) {
      _WindowRegistry.detach(_token);
      _token = 0;
    }
    _hwnd = 0;
    print('[Win32] WM_NCDESTROY — registry cleaned');
  }

  // ============================================================
  // Utility
  // ============================================================

  static int _loWord(int value) {
    final v = value & 0xFFFF;
    return v > 0x7FFF ? v - 0x10000 : v; // Sign extend for negative coords
  }

  static int _hiWord(int value) {
    final v = (value >> 16) & 0xFFFF;
    return v > 0x7FFF ? v - 0x10000 : v;
  }

  /// Cleanup static resources. Call when completely done with Win32 windows.
  static void shutdownWin32() {
    if (_classRegistered && _className != null) {
      Win32.UnregisterClassW(_className!, _hInstance);
      _classRegistered = false;
      print('[Win32] Window class unregistered');
    }
    if (_wndProcCallable != null) {
      _wndProcCallable!.close();
      _wndProcCallable = null;
      print('[Win32] WndProc callback closed');
    }
    if (_className != null) {
      calloc.free(_className!);
      _className = null;
    }
  }
}

// ============================================================
// Message loop
// ============================================================

/// Run the Win32 message loop. Blocks until WM_QUIT.
///
/// Returns the exit code from WM_QUIT.
int runMessageLoop() {
  final msg = calloc<MSG>();
  var exitCode = 0;

  while (true) {
    final result = Win32.GetMessageW(msg, 0, 0, 0);
    if (result == 0) {
      // WM_QUIT received
      exitCode = msg.ref.wParam;
      break;
    }
    if (result == -1) {
      // Error
      print('[Win32] GetMessage error: ${Win32.GetLastError()}');
      break;
    }

    Win32.TranslateMessage(msg);
    Win32.DispatchMessageW(msg);
  }

  calloc.free(msg);
  return exitCode;
}
