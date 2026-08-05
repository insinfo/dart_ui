/// MVP-02: apresenta o mesmo CounterApp do MVP-01 em X11/XCB.
library;

import 'dart:io';

import 'package:mvp_01_win32_counter/mvp_01_win32_counter.dart';
import 'package:poc_02_x11_window/poc_02_x11_window.dart';

final class X11CounterHost {
  X11CounterHost({this.width = 640, this.height = 480});

  final int width;
  final int height;

  /// Executa uma apresentação única e, em smoke mode, fecha via WM protocol.
  bool run({bool smokeTest = false}) {
    if (!Platform.isLinux) {
      throw UnsupportedError('MVP-02 requires Linux/X11.');
    }

    final frame = HeadlessFrame(width, height);
    frame.renderFull();
    final window = XcbWindow();
    try {
      window.create(width: width, height: height);
      window.putBgra(frame.pixels, width, height);
      final exposed = window.waitForExpose(const Duration(seconds: 3));
      if (!exposed) return false;
      if (smokeTest) {
        window.requestCloseForTest();
        return window.waitForDeleteWindow(const Duration(seconds: 3));
      }
      return true;
    } finally {
      window.dispose();
    }
  }
}
