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

typedef DispatchWorkNative = Void Function(Pointer<Void> context);

bool _didCreateWindowSuccess = false;

void _createAppKitWindowOnMainThread(Pointer<Void> context) {
  print('[AppKit] Executing on main OS thread...');
  final nsAppClass = getClass('NSApplication');
  print('[AppKit] nsAppClass pointer: ${nsAppClass.address}');
  if (nsAppClass == nullptr) {
    print('[AppKit] Failed to resolve NSApplication class.');
    return;
  }

  final sharedApp = nsAppClass.msgSend('sharedApplication');
  print('[AppKit] sharedApp pointer: ${sharedApp.address}');

  if (sharedApp == nullptr) {
    print('[AppKit] Failed to get sharedApplication.');
    return;
  }

  msgSendVoidIntPtr(sharedApp, sel('setActivationPolicy:'),
      NSApplicationActivationPolicyRegular);

  // Allocate and initialize NSWindow on the main thread
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
    print('[AppKit] Failed to create NSWindow on main thread.');
    return;
  }

  msgSendVoidPointer(window, sel('makeKeyAndOrderFront:'), nullptr);

  final titleUtf8 = 'Dart AppKit Window'.toNativeUtf8();
  final nsString = getClass('NSString').msgSend('alloc');
  final titleObj = msgSendPointerPointer(
      nsString, sel('initWithUTF8String:'), titleUtf8.cast());
  calloc.free(titleUtf8);

  msgSendVoidPointer(window, sel('setTitle:'), titleObj);
  print('[AppKit] NSWindow created successfully on main thread (${window.address}).');

  // Activate application
  msgSendVoidBool(sharedApp, sel('activateIgnoringOtherApps:'), true);
  _didCreateWindowSuccess = true;
}

bool runAppKitWindow() {
  _didCreateWindowSuccess = false;
  print('[AppKit] Initializing NSApplication...');
  ensureAppKitLoaded();

  final mainQueue = dispatch_get_main_queue();
  final workCallable =
      NativeCallable<DispatchWorkNative>.isolateLocal(_createAppKitWindowOnMainThread);

  dispatch_sync_f(mainQueue, nullptr, workCallable.nativeFunction);

  workCallable.close();

  print('[AppKit] AppKit window lifecycle validation result: $_didCreateWindowSuccess');
  return _didCreateWindowSuccess;
}
