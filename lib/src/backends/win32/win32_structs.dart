/// The native structs this backend passes across the FFI boundary.
///
/// Only the ones actually used are here. A struct that is declared but never
/// filled in is a layout bug waiting to happen: nothing checks it until the
/// day someone passes it, and by then the mistake looks like a driver problem.
///
/// Every string field is `Pointer<Uint16>` rather than a `Utf16` typedef,
/// because this package deliberately depends on nothing but `dart:ffi` - the
/// framework must build with an empty `pubspec` dependency list.
library;

import 'dart:ffi';

/// `WNDCLASSEXW`.
final class WndClassExW extends Struct {
  @Uint32()
  external int cbSize;

  @Uint32()
  external int style;

  external Pointer<NativeFunction<WndProcNative>> lpfnWndProc;

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

  external Pointer<Uint16> lpszMenuName;

  external Pointer<Uint16> lpszClassName;

  @IntPtr()
  external int hIconSm;
}

/// The `WNDPROC` signature. `IntPtr` for wParam/lParam because on Win64 they
/// are pointer-sized and carry pointers (WM_NCCREATE, WM_DPICHANGED).
typedef WndProcNative = IntPtr Function(
  IntPtr hwnd,
  Uint32 msg,
  IntPtr wParam,
  IntPtr lParam,
);

/// `MSG`.
final class Msg extends Struct {
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

  @Int32()
  external int ptX;

  @Int32()
  external int ptY;
}

/// `RECT`. Named with the `Win32` prefix so it never shadows the framework's
/// own logical-unit `Rect`, which is a different thing in different units.
final class Win32Rect extends Struct {
  @Int32()
  external int left;

  @Int32()
  external int top;

  @Int32()
  external int right;

  @Int32()
  external int bottom;
}

/// `POINT`.
final class Win32Point extends Struct {
  @Int32()
  external int x;

  @Int32()
  external int y;
}

/// `CREATESTRUCTW`. Only [lpCreateParams] is read - it carries the registry
/// token that turns an HWND back into a Dart object.
final class CreateStructW extends Struct {
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

  external Pointer<Uint16> lpszName;

  external Pointer<Uint16> lpszClass;

  @Uint32()
  external int dwExStyle;
}

/// `BITMAPINFOHEADER`.
final class BitmapInfoHeader extends Struct {
  @Uint32()
  external int biSize;

  @Int32()
  external int biWidth;

  /// Negative for a top-down DIB, which is the only orientation this backend
  /// creates: a bottom-up DIB would make row 0 the last row in memory and turn
  /// every rasteriser loop into a mirror of itself.
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

/// `BITMAPINFO` for the 32-bit BI_RGB case: no colour table is consulted, but
/// the trailing entry keeps the struct the size GDI expects.
final class BitmapInfo extends Struct {
  external BitmapInfoHeader bmiHeader;

  @Uint32()
  external int bmiColors0;
}
