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

  runAppKitWindow();

  print('AppKit event loop finished. Exiting.');
  exit(0);
}
