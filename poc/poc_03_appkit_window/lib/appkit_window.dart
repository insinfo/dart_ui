// Objective-C constants and native vocabulary mirror Cocoa documentation.
// ignore_for_file: constant_identifier_names

import 'dart:ffi';

import 'package:ffi/ffi.dart';

import 'objc_runtime.dart';

// Constants
const NSApplicationActivationPolicyRegular = 0;
const NSWindowStyleMaskTitled = 1 << 0;
const NSWindowStyleMaskClosable = 1 << 1;
const NSWindowStyleMaskResizable = 1 << 3;
const NSBackingStoreBuffered = 2;

bool _didFinishLaunching = false;
bool _didCreateWindow = false;
bool _didStopApplication = false;

bool runAppKitWindow() {
  _didFinishLaunching = false;
  _didCreateWindow = false;
  _didStopApplication = false;

  print('[AppKit] Initializing NSApplication...');
  final nsAppClass = getClass('NSApplication');
  final sharedApp = nsAppClass.msgSend('sharedApplication');

  msgSendVoidIntPtr(sharedApp, sel('setActivationPolicy:'),
      NSApplicationActivationPolicyRegular);

  // Allocate and initialize NSWindow
  final nsWindow = getClass('NSWindow');
  final alloc = nsWindow.msgSend('alloc');

  final rectPtr = calloc<NSRect>();
  rectPtr.ref.x = 100;
  rectPtr.ref.y = 100;
  rectPtr.ref.width = 800;
  rectPtr.ref.height = 600;

  final window = msgSendPointerRectIntIntBool(
    alloc,
    sel('initWithContentRect:styleMask:backing:defer:'),
    rectPtr.ref,
    NSWindowStyleMaskTitled |
        NSWindowStyleMaskClosable |
        NSWindowStyleMaskResizable,
    NSBackingStoreBuffered,
    false,
  );
  calloc.free(rectPtr);

  if (window == nullptr) {
    print('[AppKit] Failed to create NSWindow.');
    return false;
  }

  msgSendVoidPointer(window, sel('makeKeyAndOrderFront:'), nullptr);

  final titleUtf8 = 'Dart AppKit Window'.toNativeUtf8();
  final nsString = getClass('NSString').msgSend('alloc');
  final titleObj = msgSendPointerPointer(
      nsString, sel('initWithUTF8String:'), titleUtf8.cast());
  calloc.free(titleUtf8);

  msgSendVoidPointer(window, sel('setTitle:'), titleObj);

  _didCreateWindow = true;
  _didFinishLaunching = true;
  print('[AppKit] Window created.');

  // Schedule a timer to stop NSApplication after 1 second for CI smoke test
  final nsTimerClass = getClass('NSTimer');
  msgSendTimer(
      nsTimerClass,
      sel('scheduledTimerWithTimeInterval:target:selector:userInfo:repeats:'),
      1.0,
      sharedApp,
      sel('stop:'),
      nullptr,
      false);

  print('[AppKit] Running application...');
  sharedApp.msgSend('run');
  print('[AppKit] Application run loop exited.');

  _didStopApplication = true;
  return _didFinishLaunching && _didCreateWindow && _didStopApplication;
}
