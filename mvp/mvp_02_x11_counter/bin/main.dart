/// MVP-02: CounterApp + CPU framebuffer apresentado por X11/XCB.
library;

import 'dart:io';

import 'package:mvp_02_x11_counter/mvp_02_x11_counter.dart';

void main(List<String> args) {
  if (!Platform.isLinux) {
    print('[MVP-02] Linux/X11 only.');
    return;
  }

  final smokeTest = args.contains('--smoke-test');
  final ok = X11CounterHost().run(smokeTest: smokeTest);
  if (!ok) {
    stderr.writeln('[MVP-02] X11 smoke failed.');
    exitCode = 1;
    return;
  }
  print('[MVP-02] X11 Counter presentation OK.');
}
