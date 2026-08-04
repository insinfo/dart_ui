@TestOn('linux')
library;

import 'dart:typed_data';

import 'package:poc_02_x11_window/poc_02_x11_window.dart';
import 'package:test/test.dart';

void main() {
  test('connects, maps a window, receives Expose and uploads pixels', () {
    final window = XcbWindow();
    addTearDown(window.dispose);
    window.create(width: 32, height: 32);
    window.putBgra(
        Uint8List(32 * 32 * 4)..fillRange(3, 32 * 32 * 4, 255), 32, 32);

    expect(window.windowId, isNot(0));
    expect(window.waitForExpose(const Duration(seconds: 2)), isTrue);

    window.requestCloseForTest();
    expect(
      window.waitForDeleteWindow(const Duration(seconds: 2)),
      isTrue,
    );
  });
}
