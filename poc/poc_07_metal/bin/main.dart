import 'dart:io';

import 'package:poc_07_metal/metal_clear_render.dart';

void main(List<String> args) {
  print('-------------------------------------------------');
  print('  POC-07: Metal via Objective-C Runtime FFI     ');
  print('  No C/C++/Swift shim, just dart:ffi + Metal    ');
  print('-------------------------------------------------\n');

  if (!Platform.isMacOS) {
    print('Error: POC-07 only runs on macOS. '
        'Validation happens in the macos-14 CI job.');
    exit(1);
  }

  // The smoke-test flag is accepted for parity with the other POCs even though
  // the clear-render flow terminates synchronously — no run loop is required.
  final smokeTest = args.contains('--smoke-test');

  runMetalClearRender(width: 800, height: 600);

  if (smokeTest) {
    print('[POC-07] Smoke-test mode: exiting after a single frame.');
  }
  exit(0);
}
