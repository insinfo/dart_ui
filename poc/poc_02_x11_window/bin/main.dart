import 'dart:typed_data';

import 'package:poc_02_x11_window/poc_02_x11_window.dart';

void main(List<String> args) {
  final window = XcbWindow();
  try {
    window.create();
    final pixels = Uint8List(160 * 120 * 4);
    for (var index = 0; index < pixels.length; index += 4) {
      pixels[index] = 180;
      pixels[index + 1] = 90;
      pixels[index + 2] = 30;
      pixels[index + 3] = 255;
    }
    window.putBgra(pixels, 160, 120);
    if (!window.waitForExpose(const Duration(seconds: 2))) {
      throw StateError('XCB_EXPOSE was not received.');
    }
    print('POC-02: XCB connected, window ${window.windowId} mapped.');
    print(
        '✅ Expose event received and BGRA pixels uploaded via xcb_put_image.');
  } finally {
    window.dispose();
  }
}
