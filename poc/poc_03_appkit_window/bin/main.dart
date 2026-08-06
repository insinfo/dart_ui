import 'dart:io';
import 'package:poc_03_appkit_window/appkit_window.dart';

void main(List<String> args) {
  print('╔══════════════════════════════════════════════════╗');
  print('║  POC-03: AppKit Window via Objective-C Runtime  ║');
  print('║  No C/C++ wrapper, no Flutter, just dart:ffi    ║');
  print('╚══════════════════════════════════════════════════╝\n');

  if (!Platform.isMacOS) {
    print('Error: POC-03 only works on macOS.');
    exit(1);
  }

  // --smoke-test asserts only what a headless CI process can prove: that pure
  // Dart FFI reaches the Objective-C runtime and AppKit. Presenting a window
  // additionally requires the process main thread, which the Dart VM keeps.
  final smokeTest = args.contains('--smoke-test');
  final passed = smokeTest ? runAppKitBindingSmokeTest() : runAppKitWindow();

  if (!passed) {
    stderr.writeln(smokeTest
        ? 'AppKit binding smoke test failed.'
        : 'AppKit window creation failed.');
    exit(1);
  }

  print(smokeTest
      ? 'AppKit bindings validated. Exiting.'
      : 'AppKit event loop finished. Exiting.');
  exit(0);
}
