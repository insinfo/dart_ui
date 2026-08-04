/// Win32 native function bindings for POC-01.
///
/// Loads kernel32.dll, user32.dll, gdi32.dll and exposes the minimal
/// set of functions needed for window creation, message handling,
/// DPI awareness, and DIBSection CPU framebuffer.
library;

import 'dart:ffi';
import 'package:ffi/ffi.dart';
import 'win32_structs.dart';

/// Singleton holder for all loaded Win32 function pointers.
/// Functions are looked up once on initialization and cached.
class Win32 {
  Win32._();

  static bool _initialized = false;
  static late final DynamicLibrary _kernel32;
  static late final DynamicLibrary _user32;
  static late final DynamicLibrary _gdi32;

  /// Initialize by loading DLLs and looking up all function pointers.
  /// Safe to call multiple times — only initializes once.
  static void initialize() {
    if (_initialized) return;

    _kernel32 = DynamicLibrary.open('kernel32.dll');
    _user32 = DynamicLibrary.open('user32.dll');
    _gdi32 = DynamicLibrary.open('gdi32.dll');

    _bindKernel32();
    _bindUser32();
    _bindGdi32();
    _tryBindDpiAwareness();

    _initialized = true;
  }

  // ============================================================
  // kernel32.dll
  // ============================================================

  static late final int Function(Pointer<Utf16> lpModuleName) GetModuleHandleW;

  static late final int Function() GetLastError;

  static void _bindKernel32() {
    GetModuleHandleW = _kernel32.lookupFunction<IntPtr Function(Pointer<Utf16>),
        int Function(Pointer<Utf16>)>('GetModuleHandleW');

    GetLastError = _kernel32
        .lookupFunction<Uint32 Function(), int Function()>('GetLastError');
  }

  // ============================================================
  // user32.dll — Window management
  // ============================================================

  static late final int Function(Pointer<WNDCLASSEXW> lpwcx) RegisterClassExW;

  static late final int Function(Pointer<Utf16> lpClassName, int hInstance)
      UnregisterClassW;

  static late final int Function(
    int dwExStyle,
    Pointer<Utf16> lpClassName,
    Pointer<Utf16> lpWindowName,
    int dwStyle,
    int x,
    int y,
    int nWidth,
    int nHeight,
    int hWndParent,
    int hMenu,
    int hInstance,
    int lpParam,
  ) CreateWindowExW;

  static late final int Function(int hWnd, int nCmdShow) ShowWindow;
  static late final int Function(int hWnd) UpdateWindow;
  static late final int Function(int hWnd) DestroyWindow;

  static late final int Function(int hWnd, int Msg, int wParam, int lParam)
      DefWindowProcW;

  static late final int Function(
          Pointer<MSG> lpMsg, int hWnd, int wMsgFilterMin, int wMsgFilterMax)
      GetMessageW;

  static late final int Function(Pointer<MSG> lpMsg, int hWnd,
      int wMsgFilterMin, int wMsgFilterMax, int wRemoveMsg) PeekMessageW;

  static late final int Function(Pointer<MSG> lpMsg) TranslateMessage;
  static late final int Function(Pointer<MSG> lpMsg) DispatchMessageW;
  static late final void Function(int nExitCode) PostQuitMessage;

  static late final int Function(int hWnd, int Msg, int wParam, int lParam)
      PostMessageW;

  static late final int Function(int hWnd, Pointer<PAINTSTRUCT> lpPaint)
      BeginPaint;

  static late final int Function(int hWnd, Pointer<PAINTSTRUCT> lpPaint)
      EndPaint;

  static late final int Function(int hWnd, Pointer<RECT> lpRect) GetClientRect;

  static late final int Function(int hWnd, Pointer<RECT> lpRect, int bErase)
      InvalidateRect;

  static late final int Function(int hWnd, Pointer<Utf16> lpString)
      SetWindowTextW;

  static late final int Function(
    int hdc,
    Pointer<RECT> lprc,
    int hbr,
  ) FillRect;

  static late final int Function(int type, int cx, int cy, int fuLoad)
      LoadImageW_fromOem;

  static late final int Function(int nIndex) GetSystemMetrics;

  static late final int Function(int hWnd, int nIndex, int dwNewLong)
      SetWindowLongPtrW;

  static late final int Function(int hWnd, int nIndex) GetWindowLongPtrW;

  static void _bindUser32() {
    RegisterClassExW = _user32.lookupFunction<
        Uint16 Function(Pointer<WNDCLASSEXW>),
        int Function(Pointer<WNDCLASSEXW>)>('RegisterClassExW');

    UnregisterClassW = _user32.lookupFunction<
        Int32 Function(Pointer<Utf16>, IntPtr),
        int Function(Pointer<Utf16>, int)>('UnregisterClassW');

    CreateWindowExW = _user32.lookupFunction<
        IntPtr Function(Uint32, Pointer<Utf16>, Pointer<Utf16>, Uint32, Int32,
            Int32, Int32, Int32, IntPtr, IntPtr, IntPtr, IntPtr),
        int Function(int, Pointer<Utf16>, Pointer<Utf16>, int, int, int, int,
            int, int, int, int, int)>('CreateWindowExW');

    ShowWindow = _user32.lookupFunction<Int32 Function(IntPtr, Int32),
        int Function(int, int)>('ShowWindow');

    UpdateWindow =
        _user32.lookupFunction<Int32 Function(IntPtr), int Function(int)>(
            'UpdateWindow');

    DestroyWindow =
        _user32.lookupFunction<Int32 Function(IntPtr), int Function(int)>(
            'DestroyWindow');

    DefWindowProcW = _user32.lookupFunction<
        IntPtr Function(IntPtr, Uint32, IntPtr, IntPtr),
        int Function(int, int, int, int)>('DefWindowProcW');

    GetMessageW = _user32.lookupFunction<
        Int32 Function(Pointer<MSG>, IntPtr, Uint32, Uint32),
        int Function(Pointer<MSG>, int, int, int)>('GetMessageW');

    PeekMessageW = _user32.lookupFunction<
        Int32 Function(Pointer<MSG>, IntPtr, Uint32, Uint32, Uint32),
        int Function(Pointer<MSG>, int, int, int, int)>('PeekMessageW');

    TranslateMessage = _user32.lookupFunction<Int32 Function(Pointer<MSG>),
        int Function(Pointer<MSG>)>('TranslateMessage');

    DispatchMessageW = _user32.lookupFunction<IntPtr Function(Pointer<MSG>),
        int Function(Pointer<MSG>)>('DispatchMessageW');

    PostQuitMessage =
        _user32.lookupFunction<Void Function(Int32), void Function(int)>(
            'PostQuitMessage');

    PostMessageW = _user32.lookupFunction<
        Int32 Function(IntPtr, Uint32, IntPtr, IntPtr),
        int Function(int, int, int, int)>('PostMessageW');

    BeginPaint = _user32.lookupFunction<
        IntPtr Function(IntPtr, Pointer<PAINTSTRUCT>),
        int Function(int, Pointer<PAINTSTRUCT>)>('BeginPaint');

    EndPaint = _user32.lookupFunction<
        Int32 Function(IntPtr, Pointer<PAINTSTRUCT>),
        int Function(int, Pointer<PAINTSTRUCT>)>('EndPaint');

    GetClientRect = _user32.lookupFunction<
        Int32 Function(IntPtr, Pointer<RECT>),
        int Function(int, Pointer<RECT>)>('GetClientRect');

    InvalidateRect = _user32.lookupFunction<
        Int32 Function(IntPtr, Pointer<RECT>, Int32),
        int Function(int, Pointer<RECT>, int)>('InvalidateRect');

    SetWindowTextW = _user32.lookupFunction<
        Int32 Function(IntPtr, Pointer<Utf16>),
        int Function(int, Pointer<Utf16>)>('SetWindowTextW');

    FillRect = _user32.lookupFunction<
        Int32 Function(IntPtr, Pointer<RECT>, IntPtr),
        int Function(int, Pointer<RECT>, int)>('FillRect');

    // LoadImage with null hInst (OEM resources)
    final loadImageW = _user32.lookupFunction<
        IntPtr Function(IntPtr, IntPtr, Uint32, Int32, Int32, Uint32),
        int Function(int, int, int, int, int, int)>('LoadImageW');
    LoadImageW_fromOem = (int type, int cx, int cy, int fuLoad) =>
        loadImageW(0, type, 1, cx, cy, fuLoad);

    GetSystemMetrics =
        _user32.lookupFunction<Int32 Function(Int32), int Function(int)>(
            'GetSystemMetrics');

    SetWindowLongPtrW = _user32.lookupFunction<
        IntPtr Function(IntPtr, Int32, IntPtr),
        int Function(int, int, int)>('SetWindowLongPtrW');

    GetWindowLongPtrW = _user32.lookupFunction<IntPtr Function(IntPtr, Int32),
        int Function(int, int)>('GetWindowLongPtrW');
  }

  // ============================================================
  // user32.dll — DPI awareness (optional, Win10 1703+)
  // ============================================================

  /// May be null if running on older Windows.
  static int Function(int value)? SetProcessDpiAwarenessContext;
  static int Function(int hwnd)? GetDpiForWindow;

  static void _tryBindDpiAwareness() {
    try {
      SetProcessDpiAwarenessContext =
          _user32.lookupFunction<Int32 Function(IntPtr), int Function(int)>(
              'SetProcessDpiAwarenessContext');
    } catch (_) {
      SetProcessDpiAwarenessContext = null;
    }

    try {
      GetDpiForWindow =
          _user32.lookupFunction<Uint32 Function(IntPtr), int Function(int)>(
              'GetDpiForWindow');
    } catch (_) {
      GetDpiForWindow = null;
    }
  }

  // ============================================================
  // user32.dll — Cursor loading
  // ============================================================

  static late final int Function(int hInstance, int lpCursorName) LoadCursorW;

  // Note: LoadCursorW is bound after the main block
  // We add it inline at the end of _bindUser32
  // Actually let's bind it in _bindUser32:

  // ============================================================
  // gdi32.dll
  // ============================================================

  static late final int Function(int color) CreateSolidBrush;
  static late final int Function(int hObject) DeleteObject;
  static late final int Function(int hdc) CreateCompatibleDC;
  static late final int Function(int hdc) DeleteDC;
  static late final int Function(int hdc, int hObject) SelectObject;

  static late final int Function(
    int hdc,
    Pointer<BITMAPINFO> pbmi,
    int usage,
    Pointer<Pointer<Void>> ppvBits,
    int hSection,
    int offset,
  ) CreateDIBSection;

  static late final int Function(
    int hdc,
    int x,
    int y,
    int cx,
    int cy,
    int hdcSrc,
    int x1,
    int y1,
    int rop,
  ) BitBlt;

  static late final int Function(
    int hdc,
    int xDest,
    int yDest,
    int DestWidth,
    int DestHeight,
    int xSrc,
    int ySrc,
    int SrcWidth,
    int SrcHeight,
    Pointer<Void> lpBits,
    Pointer<BITMAPINFO> lpbmi,
    int iUsage,
    int rop,
  ) StretchDIBits;

  static void _bindGdi32() {
    CreateSolidBrush =
        _gdi32.lookupFunction<IntPtr Function(Uint32), int Function(int)>(
            'CreateSolidBrush');

    DeleteObject =
        _gdi32.lookupFunction<Int32 Function(IntPtr), int Function(int)>(
            'DeleteObject');

    CreateCompatibleDC =
        _gdi32.lookupFunction<IntPtr Function(IntPtr), int Function(int)>(
            'CreateCompatibleDC');

    DeleteDC = _gdi32
        .lookupFunction<Int32 Function(IntPtr), int Function(int)>('DeleteDC');

    SelectObject = _gdi32.lookupFunction<IntPtr Function(IntPtr, IntPtr),
        int Function(int, int)>('SelectObject');

    CreateDIBSection = _gdi32.lookupFunction<
        IntPtr Function(IntPtr, Pointer<BITMAPINFO>, Uint32,
            Pointer<Pointer<Void>>, IntPtr, Uint32),
        int Function(int, Pointer<BITMAPINFO>, int, Pointer<Pointer<Void>>, int,
            int)>('CreateDIBSection');

    BitBlt = _gdi32.lookupFunction<
        Int32 Function(
            IntPtr, Int32, Int32, Int32, Int32, IntPtr, Int32, Int32, Uint32),
        int Function(int, int, int, int, int, int, int, int, int)>('BitBlt');

    StretchDIBits = _gdi32.lookupFunction<
        Int32 Function(IntPtr, Int32, Int32, Int32, Int32, Int32, Int32, Int32,
            Int32, Pointer<Void>, Pointer<BITMAPINFO>, Uint32, Uint32),
        int Function(int, int, int, int, int, int, int, int, int, Pointer<Void>,
            Pointer<BITMAPINFO>, int, int)>('StretchDIBits');

    // Bind LoadCursorW here
    LoadCursorW = _user32.lookupFunction<IntPtr Function(IntPtr, IntPtr),
        int Function(int, int)>('LoadCursorW');
  }
}
