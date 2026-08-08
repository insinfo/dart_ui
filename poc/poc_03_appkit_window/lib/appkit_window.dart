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

bool _didCreateWindowSuccess = false;

void _createAppKitWindow() {
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
  print(
      '[AppKit] NSWindow created successfully on main thread (${window.address}).');

  // Activate application
  msgSendVoidBool(sharedApp, sel('activateIgnoringOtherApps:'), true);
  _didCreateWindowSuccess = true;
}

/// Validates that pure Dart FFI reaches the Objective-C runtime and AppKit:
/// every class this POC drives resolves through `objc_getClass`.
///
/// Deliberately stops short of `sharedApplication` and of NSWindow, so it stays
/// valid on any thread - see [runAppKitWindow] for why that matters.
bool runAppKitBindingSmokeTest() {
  print('[AppKit] Loading AppKit bindings...');
  ensureAppKitLoaded();

  final classes = {
    for (final name in ['NSObject', 'NSString', 'NSApplication', 'NSWindow'])
      name: getClass(name),
  };
  classes.forEach((name, cls) => print('[AppKit] $name: ${cls.address}'));

  final success = classes.values.every((cls) => cls != nullptr);
  print('[AppKit] Objective-C/AppKit binding smoke test: $success');

  if (!isMainThread()) {
    print('[AppKit] NOTE: window creation is NOT covered by this run - the '
        'Dart isolate does not own the process main thread.');
  }
  return success;
}

/// Creates and presents a real NSWindow. Requires the process main thread.
bool runAppKitWindow() {
  _didCreateWindowSuccess = false;
  print('[AppKit] Initializing NSApplication...');
  ensureAppKitLoaded();

  if (!isMainThread()) {
    // Measured on macOS CI: a `dart compile exe` binary runs the isolate off
    // the process main thread, so both routes to AppKit are closed.
    print('[AppKit] pthread_main_np() = 0: the Dart isolate is NOT on the '
        'process main thread.');
    print('[AppKit] Refusing to instantiate NSWindow here - AppKit kills the '
        'process with "NSWindow should only be instantiated on the main '
        'thread!".');
    print('[AppKit] Refusing to hand the work to dispatch_sync_f either: no '
        'NSApplicationMain, dispatch_main or CFRunLoop is draining the main '
        'queue, so the call would never return. Even if one were, the work '
        'item is a NativeCallable.isolateLocal, which aborts when invoked '
        'from any thread other than the isolate that created it.');
    print('[AppKit] A real window needs the process main thread to own the '
        'AppKit event loop: a minimal native host as main(), or a custom '
        'launcher that keeps the main thread free for Cocoa.');
    return false;
  }

  print('[AppKit] pthread_main_np() = 1: running on the process main thread.');
  _createAppKitWindow();

  print(
      '[AppKit] AppKit window lifecycle validation result: $_didCreateWindowSuccess');
  return _didCreateWindowSuccess;
}
