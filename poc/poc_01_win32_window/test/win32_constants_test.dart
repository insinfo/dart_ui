@TestOn('windows')
library;

import 'package:poc_01_win32_window/src/win32_constants.dart';
import 'package:test/test.dart';

void main() {
  test('uses the expected Win32 message and keyboard constants', () {
    expect(WM_PAINT, 0x000f);
    expect(WM_DPICHANGED, 0x02e0);
    expect(VK_ESCAPE, 0x1b);
  });
}
