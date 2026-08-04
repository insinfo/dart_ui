/// Win32 native structs for POC-01.
///
/// Minimal structs needed for window creation, message handling,
/// painting, and DIBSection framebuffer.
library;

import 'dart:ffi';
import 'package:ffi/ffi.dart';

// ============================================================
// WNDCLASSEXW — Window class registration
// ============================================================
final class WNDCLASSEXW extends Struct {
  @Uint32()
  external int cbSize;

  @Uint32()
  external int style;

  external Pointer<NativeFunction<WNDPROC>> lpfnWndProc;

  @Int32()
  external int cbClsExtra;

  @Int32()
  external int cbWndExtra;

  @IntPtr()
  external int hInstance;

  @IntPtr()
  external int hIcon;

  @IntPtr()
  external int hCursor;

  @IntPtr()
  external int hbrBackground;

  external Pointer<Utf16> lpszMenuName;

  external Pointer<Utf16> lpszClassName;

  @IntPtr()
  external int hIconSm;
}

/// WndProc native function type.
typedef WNDPROC = IntPtr Function(
  IntPtr hwnd,
  Uint32 msg,
  IntPtr wParam,
  IntPtr lParam,
);

/// WndProc Dart function type.
typedef WndProcDart = int Function(
  int hwnd,
  int msg,
  int wParam,
  int lParam,
);

// ============================================================
// MSG — Message structure
// ============================================================
final class MSG extends Struct {
  @IntPtr()
  external int hwnd;

  @Uint32()
  external int message;

  @IntPtr()
  external int wParam;

  @IntPtr()
  external int lParam;

  @Uint32()
  external int time;

  // POINT pt (two Int32 values)
  @Int32()
  external int ptX;

  @Int32()
  external int ptY;
}

// ============================================================
// RECT
// ============================================================
final class RECT extends Struct {
  @Int32()
  external int left;

  @Int32()
  external int top;

  @Int32()
  external int right;

  @Int32()
  external int bottom;
}

// ============================================================
// POINT
// ============================================================
final class POINT extends Struct {
  @Int32()
  external int x;

  @Int32()
  external int y;
}

// ============================================================
// PAINTSTRUCT
// ============================================================
final class PAINTSTRUCT extends Struct {
  @IntPtr()
  external int hdc;

  @Int32()
  external int fErase;

  // RECT rcPaint
  @Int32()
  external int rcPaintLeft;

  @Int32()
  external int rcPaintTop;

  @Int32()
  external int rcPaintRight;

  @Int32()
  external int rcPaintBottom;

  @Int32()
  external int fRestore;

  @Int32()
  external int fIncUpdate;

  // BYTE rgbReserved[32]
  @Array(32)
  external Array<Uint8> rgbReserved;
}

// ============================================================
// CREATESTRUCTW — passed to WM_CREATE/WM_NCCREATE
// ============================================================
final class CREATESTRUCTW extends Struct {
  @IntPtr()
  external int lpCreateParams;

  @IntPtr()
  external int hInstance;

  @IntPtr()
  external int hMenu;

  @IntPtr()
  external int hwndParent;

  @Int32()
  external int cy;

  @Int32()
  external int cx;

  @Int32()
  external int y;

  @Int32()
  external int x;

  @Int32()
  external int style;

  external Pointer<Utf16> lpszName;

  external Pointer<Utf16> lpszClass;

  @Uint32()
  external int dwExStyle;
}

// ============================================================
// BITMAPINFOHEADER — for DIBSection
// ============================================================
final class BITMAPINFOHEADER extends Struct {
  @Uint32()
  external int biSize;

  @Int32()
  external int biWidth;

  @Int32()
  external int biHeight;

  @Uint16()
  external int biPlanes;

  @Uint16()
  external int biBitCount;

  @Uint32()
  external int biCompression;

  @Uint32()
  external int biSizeImage;

  @Int32()
  external int biXPelsPerMeter;

  @Int32()
  external int biYPelsPerMeter;

  @Uint32()
  external int biClrUsed;

  @Uint32()
  external int biClrImportant;
}

// ============================================================
// BITMAPINFO — BITMAPINFOHEADER + color table
// ============================================================
final class BITMAPINFO extends Struct {
  external BITMAPINFOHEADER bmiHeader;

  // For BI_RGB with 32-bit, no color table needed,
  // but we include one entry for struct completeness.
  @Uint32()
  external int bmiColors0;
}

// ============================================================
// MINMAXINFO — for WM_GETMINMAXINFO
// ============================================================
final class MINMAXINFO extends Struct {
  // POINT ptReserved
  @Int32()
  external int ptReservedX;
  @Int32()
  external int ptReservedY;

  // POINT ptMaxSize
  @Int32()
  external int ptMaxSizeX;
  @Int32()
  external int ptMaxSizeY;

  // POINT ptMaxPosition
  @Int32()
  external int ptMaxPositionX;
  @Int32()
  external int ptMaxPositionY;

  // POINT ptMinTrackSize
  @Int32()
  external int ptMinTrackSizeX;
  @Int32()
  external int ptMinTrackSizeY;

  // POINT ptMaxTrackSize
  @Int32()
  external int ptMaxTrackSizeX;
  @Int32()
  external int ptMaxTrackSizeY;
}
