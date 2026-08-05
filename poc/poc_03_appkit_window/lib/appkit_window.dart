// Objective-C constants and the `_cmd` callback parameter intentionally mirror
// the Cocoa runtime vocabulary used in Apple's native documentation.
// ignore_for_file: constant_identifier_names, no_leading_underscores_for_local_identifiers

import 'dart:ffi';

import 'package:ffi/ffi.dart';

import 'objc_runtime.dart';

// Constants
const NSApplicationActivationPolicyRegular = 0;
const NSWindowStyleMaskTitled = 1 << 0;
const NSWindowStyleMaskClosable = 1 << 1;
const NSWindowStyleMaskResizable = 1 << 3;
const NSBackingStoreBuffered = 2;

// Callbacks
typedef AppCallbackNative = Void Function(Pointer<ObjCObject> self,
    Pointer<ObjCSel> _cmd, Pointer<ObjCObject> notification);

void _onFinishLaunching(Pointer<ObjCObject> self, Pointer<ObjCSel> _cmd,
    Pointer<ObjCObject> notification) {
  _didFinishLaunching = true;
  print('[AppKit] applicationDidFinishLaunching:');

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

  msgSendVoidPointer(window, sel('makeKeyAndOrderFront:'), nullptr);

  final titleUtf8 = 'Dart AppKit Window'.toNativeUtf8();
  final nsString = getClass('NSString').msgSend('alloc');
  final titleObj = msgSendPointerPointer(
      nsString, sel('initWithUTF8String:'), titleUtf8.cast());
  calloc.free(titleUtf8);

  msgSendVoidPointer(window, sel('setTitle:'), titleObj);

  _didCreateWindow = true;
  print('[AppKit] Window created.');

  // Schedule a timer to close the app after 3 seconds for the smoke test
  final nsTimerClass = getClass('NSTimer');
  msgSendTimer(
      nsTimerClass,
      sel('scheduledTimerWithTimeInterval:target:selector:userInfo:repeats:'),
      3.0,
      self,
      sel('stopApp:'),
      nullptr,
      false);
}

void _stopApp(Pointer<ObjCObject> self, Pointer<ObjCSel> _cmd,
    Pointer<ObjCObject> timer) {
  _didStopApplication = true;
  print('[AppKit] stopApp: called. Terminating NSApplication...');
  final nsAppClass = getClass('NSApplication');
  final sharedApp = nsAppClass.msgSend('sharedApplication');
  msgSendVoidPointer(sharedApp, sel('terminate:'), self);
}

late NativeCallable<AppCallbackNative> finishCallback;
late NativeCallable<AppCallbackNative> stopCallback;
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

  final delegateClassName = 'DartAppDelegate'.toNativeUtf8();
  final nsObjectClass = getClass('NSObject');
  final delegateClass =
      objc_allocateClassPair(nsObjectClass, delegateClassName, 0);
  calloc.free(delegateClassName);

  if (delegateClass == nullptr) {
    print('[AppKit] Failed to allocate delegate class.');
    return false;
  }

  final typesUtf8 = 'v@:@'.toNativeUtf8();

  final didFinishSel = sel('applicationDidFinishLaunching:');
  finishCallback =
      NativeCallable<AppCallbackNative>.isolateLocal(_onFinishLaunching);
  final didAddFinish = class_addMethod(delegateClass, didFinishSel,
      finishCallback.nativeFunction.cast<Void>(), typesUtf8);

  final stopSel = sel('stopApp:');
  stopCallback = NativeCallable<AppCallbackNative>.isolateLocal(_stopApp);
  final didAddStop = class_addMethod(delegateClass, stopSel,
      stopCallback.nativeFunction.cast<Void>(), typesUtf8);

  calloc.free(typesUtf8);

  if (didAddFinish == 0 || didAddStop == 0) {
    print('[AppKit] Failed to install Dart delegate methods.');
    finishCallback.close();
    stopCallback.close();
    return false;
  }

  objc_registerClassPair(delegateClass);

  final delegateInstance = delegateClass.msgSend('alloc').msgSend('init');

  msgSendVoidPointer(sharedApp, sel('setDelegate:'), delegateInstance);

  print('[AppKit] Running application...');
  sharedApp.msgSend('run');
  print('[AppKit] Application run loop exited.');
  finishCallback.close();
  stopCallback.close();

  return _didFinishLaunching && _didCreateWindow && _didStopApplication;
}
