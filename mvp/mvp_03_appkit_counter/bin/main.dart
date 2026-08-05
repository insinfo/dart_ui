/// MVP-03: CounterApp + CPU framebuffer apresentado por AppKit.
library;

import 'dart:io';

import 'package:mvp_03_appkit_counter/appkit_host.dart';

Future<void> main(List<String> args) async {
  if (!Platform.isMacOS) {
    print('[MVP-03] macOS/AppKit only.');
    return;
  }

  final smokeTest = args.contains('--smoke-test');
  final ok = await AppKitCounterHost().run(smokeTest: smokeTest);
  if (!ok) {
    stderr.writeln('[MVP-03] AppKit smoke failed.');
    exitCode = 1;
    return;
  }
  print('[MVP-03] AppKit Counter presentation OK.');
}
