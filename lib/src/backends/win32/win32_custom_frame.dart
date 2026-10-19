/// Optional DWM support for an integrated client title bar.
library;

import 'dart:ffi';

import 'win32_api.dart';

final class _Margins extends Struct {
  @Int32()
  external int left;
  @Int32()
  external int right;
  @Int32()
  external int top;
  @Int32()
  external int bottom;
}

/// Retains the DWM frame and shadow while the application paints its caption.
final class Win32CustomFrame {
  Win32CustomFrame._(this.api, DynamicLibrary dwm) {
    _extend = dwm.lookupFunction<Int32 Function(IntPtr, Pointer<_Margins>),
        int Function(int, Pointer<_Margins>)>('DwmExtendFrameIntoClientArea');
  }

  static Win32CustomFrame? tryCreate(Win32Api api) {
    try {
      final dwm = DynamicLibrary.open('dwmapi.dll');
      final enabled = api.allocator<Int32>();
      try {
        final query = dwm.lookupFunction<Int32 Function(Pointer<Int32>),
            int Function(Pointer<Int32>)>('DwmIsCompositionEnabled');
        if (query(enabled) < 0 || enabled.value == 0) return null;
      } finally {
        api.allocator.free(enabled);
      }
      return Win32CustomFrame._(api, dwm);
    } on ArgumentError {
      return null;
    }
  }

  final Win32Api api;
  late final int Function(int, Pointer<_Margins>) _extend;

  void extend(int hwnd) {
    final margins = api.allocator<_Margins>();
    try {
      margins.ref
        ..left = 0
        ..right = 0
        ..top = 1
        ..bottom = 0;
      _extend(hwnd, margins);
    } finally {
      api.allocator.free(margins);
    }
  }
}
