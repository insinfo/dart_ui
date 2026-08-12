/// Runtime ABI facts for the Win32 FFI boundary.
library;

import 'dart:ffi';

import 'win32_structs.dart';

/// Sizes and pointer width recorded by the running Dart VM.
final class Win32AbiReport {
  const Win32AbiReport({
    required this.pointerBytes,
    required this.wndClassExBytes,
    required this.msgBytes,
    required this.rectBytes,
    required this.createStructBytes,
    required this.bitmapInfoBytes,
  });

  factory Win32AbiReport.current() => Win32AbiReport(
        pointerBytes: sizeOf<IntPtr>(),
        wndClassExBytes: sizeOf<WndClassExW>(),
        msgBytes: sizeOf<Msg>(),
        rectBytes: sizeOf<Win32Rect>(),
        createStructBytes: sizeOf<CreateStructW>(),
        bitmapInfoBytes: sizeOf<BitmapInfo>(),
      );

  final int pointerBytes;
  final int wndClassExBytes;
  final int msgBytes;
  final int rectBytes;
  final int createStructBytes;
  final int bitmapInfoBytes;

  bool get is64Bit => pointerBytes == 8;

  @override
  String toString() => 'Win32AbiReport(pointer: $pointerBytes, '
      'WNDCLASSEXW: $wndClassExBytes, MSG: $msgBytes, RECT: $rectBytes, '
      'CREATESTRUCTW: $createStructBytes, BITMAPINFO: $bitmapInfoBytes)';
}
