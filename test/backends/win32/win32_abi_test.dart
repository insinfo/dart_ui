import 'dart:ffi';

import 'package:dart_ui/src/backends/win32/win32_abi.dart';
import 'package:dart_ui/src/backends/win32/win32_structs.dart';
import 'package:test/test.dart';

void main() {
  test('ABI report matches dart:ffi struct layout', () {
    final report = Win32AbiReport.current();

    expect(report.pointerBytes, sizeOf<IntPtr>());
    expect(report.wndClassExBytes, sizeOf<WndClassExW>());
    expect(report.msgBytes, sizeOf<Msg>());
    expect(report.rectBytes, sizeOf<Win32Rect>());
    expect(report.createStructBytes, sizeOf<CreateStructW>());
    expect(report.bitmapInfoBytes, sizeOf<BitmapInfo>());
    expect(report.is64Bit, report.pointerBytes == 8);
  });
}
