// Spike: can a pure-Dart process (no C/C++/ObjC source) own the macOS main
// thread, or otherwise reach a window without it?
//
// Measured baseline (macos-14 arm64, Dart 3.6.0, `dart compile exe`):
// pthread_main_np() = 0, so NSWindow aborts the process. Each probe below
// explores one escape route and is a separate subcommand, because a probe that
// crashes must not hide the results of the others.
//
// ignore_for_file: non_constant_identifier_names, constant_identifier_names

import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:poc_03_appkit_window/appkit_window.dart';
import 'package:poc_03_appkit_window/objc_runtime.dart';

// Darwin signal numbers.
const SIGUSR2 = 31;

// ---------------------------------------------------------------------------
// Extra libSystem / CoreFoundation bindings used only by the probes.
// ---------------------------------------------------------------------------

final pthread_main_thread_np =
    libSystem.lookupFunction<Pointer<Void> Function(), Pointer<Void> Function()>(
        'pthread_main_thread_np');

final pthread_kill = libSystem.lookupFunction<
    Int32 Function(Pointer<Void>, Int32),
    int Function(Pointer<Void>, int)>('pthread_kill');

// signal(int, void (*)(int)) - the handler is just a code address, so any
// exported zero-argument function can be installed as one.
final signal = libSystem.lookupFunction<
    Pointer<Void> Function(Int32, Pointer<Void>),
    Pointer<Void> Function(int, Pointer<Void>)>('signal');

final dispatch_async_f = libSystem.lookupFunction<
    Void Function(Pointer<Void>, Pointer<Void>, Pointer<Void>),
    void Function(Pointer<Void>, Pointer<Void>, Pointer<Void>)>(
    'dispatch_async_f');

final dispatch_semaphore_create = libSystem.lookupFunction<
    Pointer<Void> Function(IntPtr),
    Pointer<Void> Function(int)>('dispatch_semaphore_create');

final dispatch_semaphore_wait = libSystem.lookupFunction<
    IntPtr Function(Pointer<Void>, Uint64),
    int Function(Pointer<Void>, int)>('dispatch_semaphore_wait');

// Used as a dispatch work function: dispatch_async_f calls work(context), and
// dispatch_semaphore_signal(sema) has a compatible one-pointer signature.
final dispatch_semaphore_signal_ptr =
    libSystem.lookup<Void>('dispatch_semaphore_signal');

final dispatch_time = libSystem.lookupFunction<
    Uint64 Function(Uint64, Int64), int Function(int, int)>('dispatch_time');

final DynamicLibrary libCoreFoundation = DynamicLibrary.open(
    '/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation');

final Pointer<Void> cfRunLoopRunPtr = libCoreFoundation.lookup<Void>('CFRunLoopRun');

// Once the main thread is parked in a run loop it never returns, so normal
// shutdown is gone: leave through _exit() instead of waiting for it.
final _exitProcess = libSystem
    .lookupFunction<Void Function(Int32), void Function(int)>('_exit');

// ---------------------------------------------------------------------------
// objc_msgSend shapes needed to drive NSInvocation.
// ---------------------------------------------------------------------------

typedef _MsgSendPointerSelNative = Pointer<ObjCObject> Function(
    Pointer<ObjCObject>, Pointer<ObjCSel>, Pointer<ObjCSel>);
final msgSendPointerSel = objc_msgSend_ptr
    .cast<NativeFunction<_MsgSendPointerSelNative>>()
    .asFunction<
        Pointer<ObjCObject> Function(
            Pointer<ObjCObject>, Pointer<ObjCSel>, Pointer<ObjCSel>)>();

typedef _MsgSendVoidSelNative = Void Function(
    Pointer<ObjCObject>, Pointer<ObjCSel>, Pointer<ObjCSel>);
final msgSendVoidSel = objc_msgSend_ptr
    .cast<NativeFunction<_MsgSendVoidSelNative>>()
    .asFunction<
        void Function(
            Pointer<ObjCObject>, Pointer<ObjCSel>, Pointer<ObjCSel>)>();

typedef _MsgSendVoidPointerIntNative = Void Function(
    Pointer<ObjCObject>, Pointer<ObjCSel>, Pointer<Void>, IntPtr);
final msgSendVoidPointerInt = objc_msgSend_ptr
    .cast<NativeFunction<_MsgSendVoidPointerIntNative>>()
    .asFunction<
        void Function(
            Pointer<ObjCObject>, Pointer<ObjCSel>, Pointer<Void>, int)>();

// performSelectorOnMainThread:withObject:waitUntilDone:
typedef _MsgSendPerformOnMainNative = Void Function(Pointer<ObjCObject>,
    Pointer<ObjCSel>, Pointer<ObjCSel>, Pointer<ObjCObject>, Bool);
final msgSendPerformOnMain = objc_msgSend_ptr
    .cast<NativeFunction<_MsgSendPerformOnMainNative>>()
    .asFunction<
        void Function(Pointer<ObjCObject>, Pointer<ObjCSel>, Pointer<ObjCSel>,
            Pointer<ObjCObject>, bool)>();

// ---------------------------------------------------------------------------
// Probe A - which execution mode, if any, gives Dart the process main thread?
// Run the same binary as JIT, dartaotruntime snapshot and AOT exe.
// ---------------------------------------------------------------------------

void probeThread() {
  final owns = pthread_main_np();
  print('pthread_main_np()        = $owns');
  print('pthread_main_thread_np() = ${pthread_main_thread_np().address}');
  print(owns != 0
      ? 'RESULT: Dart OWNS the process main thread - AppKit is reachable.'
      : 'RESULT: Dart does NOT own the process main thread.');
}

// ---------------------------------------------------------------------------
// Probe B - "just call [NSApp run]" (Solucao 1).
// Hypothesis under test: entering the AppKit loop does not change which thread
// is the main thread, so pthread_main_np() stays 0 and NSWindow stays illegal.
// ---------------------------------------------------------------------------

void probeNsAppRun() {
  ensureAppKitLoaded();
  print('before run: pthread_main_np() = ${pthread_main_np()}');

  final app = getClass('NSApplication').msgSend('sharedApplication');
  print('sharedApplication = ${app.address}');
  print('after sharedApplication: pthread_main_np() = ${pthread_main_np()}');

  print('calling [NSApp run] - the CI step timeout is the only way out if it '
      'blocks, which is itself the result.');
  app.msgSend('run');
  print('[NSApp run] RETURNED. pthread_main_np() = ${pthread_main_np()}');
}

// ---------------------------------------------------------------------------
// Probe C - skip AppKit entirely: talk to the WindowServer through the private
// SkyLight/CGS API, which is plain IPC and has no main-thread rule.
// ---------------------------------------------------------------------------

void probeSkyLight() {
  DynamicLibrary lib;
  try {
    lib = DynamicLibrary.open(
        '/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight');
    print('SkyLight.framework loaded.');
  } catch (e) {
    print('RESULT: SkyLight.framework not loadable: $e');
    return;
  }

  const symbols = [
    'SLSMainConnectionID',
    'SLSNewWindow',
    'SLSOrderWindow',
    'SLSSetWindowLevel',
    'SLSNewRegionWithRect',
    'SLSFlushWindowContentRegion',
    'CGSMainConnectionID',
    'CGSNewWindow',
  ];
  final present = <String>[];
  for (final name in symbols) {
    try {
      final p = lib.lookup<Void>(name);
      present.add(name);
      print('  found   $name @ ${p.address}');
    } catch (_) {
      print('  missing $name');
    }
  }

  if (!present.contains('SLSMainConnectionID')) {
    print('RESULT: no usable WindowServer entry point.');
    return;
  }

  // A non-zero connection id means this process can talk to the WindowServer
  // from a non-main thread - the precondition for the whole CGS route.
  final connectionId = lib.lookupFunction<Int32 Function(), int Function()>(
      'SLSMainConnectionID')();
  print('SLSMainConnectionID() = $connectionId '
      '(pthread_main_np() = ${pthread_main_np()})');
  print(connectionId != 0
      ? 'RESULT: WindowServer reachable off the main thread. Window creation '
          'still needs SLSNewWindow ABI work, and input has no NSEvent queue.'
      : 'RESULT: no WindowServer connection from this process.');
}

// ---------------------------------------------------------------------------
// Probe D - hijack the main thread with a signal, no shellcode required.
//
// The main thread is parked inside the VM, so it never drains the libdispatch
// main queue. A signal, though, is delivered *on the target thread*: install
// CFRunLoopRun's address as the SIGUSR2 handler and pthread_kill the main
// thread, and the main thread enters a CoreFoundation run loop - which is
// exactly what drains the main queue. No custom machine code: the handler is
// an already-exported function.
//
// Verified without any Dart callback (NativeCallable would abort when invoked
// from a foreign thread): enqueue dispatch_semaphore_signal itself as the work
// function and see whether the semaphore ever fires.
// ---------------------------------------------------------------------------

void probeSignalHijack() {
  print('pthread_main_np() = ${pthread_main_np()}');

  final mainThread = pthread_main_thread_np();
  print('main pthread_t = ${mainThread.address}');
  print('CFRunLoopRun @ ${cfRunLoopRunPtr.address}');

  final previous = signal(SIGUSR2, cfRunLoopRunPtr);
  print('signal(SIGUSR2, CFRunLoopRun) -> previous handler ${previous.address}');

  final killResult = pthread_kill(mainThread, SIGUSR2);
  print('pthread_kill(main, SIGUSR2) -> $killResult');
  if (killResult != 0) {
    print('RESULT: could not signal the main thread (errno $killResult).');
    return;
  }

  final semaphore = dispatch_semaphore_create(0);
  dispatch_async_f(
      dispatch_get_main_queue(), semaphore, dispatch_semaphore_signal_ptr);

  const threeSeconds = 3000000000;
  final timedOut =
      dispatch_semaphore_wait(semaphore, dispatch_time(0, threeSeconds)) != 0;

  print(timedOut
      ? 'RESULT: main queue still NOT drained - the signal did not give us a '
          'run loop (blocked sigmask, or the handler never ran).'
      : 'RESULT: main queue IS DRAINING. The main thread now runs a CFRunLoop, '
          'so AppKit work can be routed to it via NSInvocation + '
          'performSelectorOnMainThread:.');

  _exitProcess(timedOut ? 1 : 0);
}

/// Parks the process main thread in a CFRunLoop and returns once the main
/// queue is confirmed to be draining. See [probeSignalHijack] for the why.
bool _parkMainThreadInRunLoop() {
  signal(SIGUSR2, cfRunLoopRunPtr);
  final killResult = pthread_kill(pthread_main_thread_np(), SIGUSR2);
  if (killResult != 0) {
    print('pthread_kill(main, SIGUSR2) failed: $killResult');
    return false;
  }

  final semaphore = dispatch_semaphore_create(0);
  dispatch_async_f(
      dispatch_get_main_queue(), semaphore, dispatch_semaphore_signal_ptr);
  const threeSeconds = 3000000000;
  return dispatch_semaphore_wait(semaphore, dispatch_time(0, threeSeconds)) == 0;
}

/// Blocks the calling thread by waiting on a semaphore nobody ever signals.
void _sleepNanos(int nanos) {
  final semaphore = dispatch_semaphore_create(0);
  dispatch_semaphore_wait(semaphore, dispatch_time(0, nanos));
}

/// Builds an NSInvocation bound to [target] and [selector]. Arguments still
/// have to be set by the caller, starting at index 2 (0 is self, 1 is _cmd).
Pointer<ObjCObject> _newInvocation(
    Pointer<ObjCObject> target, Pointer<ObjCSel> selector) {
  final signature =
      msgSendPointerSel(target, sel('methodSignatureForSelector:'), selector);
  if (signature == nullptr) return nullptr;
  final invocation = msgSendPointerPointer(
      getClass('NSInvocation'), sel('invocationWithMethodSignature:'), signature);
  msgSendVoidPointer(invocation, sel('setTarget:'), target);
  msgSendVoidSel(invocation, sel('setSelector:'), selector);
  return invocation;
}

void _setArgument(
    Pointer<ObjCObject> invocation, Pointer<Void> value, int index) {
  msgSendVoidPointerInt(invocation, sel('setArgument:atIndex:'), value, index);
}

void _invokeOnMain(Pointer<ObjCObject> invocation, {bool wait = true}) {
  invocation.msgSend('retainArguments');
  msgSendPerformOnMain(
      invocation,
      sel('performSelectorOnMainThread:withObject:waitUntilDone:'),
      sel('invoke'),
      nullptr,
      wait);
}

Pointer<ObjCObject> _returnedObject(Pointer<ObjCObject> invocation) {
  final slot = calloc<Pointer<ObjCObject>>();
  msgSendVoidPointer(invocation, sel('getReturnValue:'), slot.cast());
  final value = slot.value;
  calloc.free(slot);
  return value;
}

Pointer<ObjCObject> _nsString(String value) {
  final utf8 = value.toNativeUtf8();
  final string = msgSendPointerPointer(getClass('NSString').msgSend('alloc'),
      sel('initWithUTF8String:'), utf8.cast());
  calloc.free(utf8);
  return string;
}

// ---------------------------------------------------------------------------
// Probe E - the end-to-end claim: an NSWindow created from pure Dart FFI.
//
// Park the main thread (probe D), then package the main-thread-only call as an
// NSInvocation and send it `invoke` through performSelectorOnMainThread:. That
// keeps every step inside the Objective-C runtime: no Dart callback (which
// would abort when invoked from a foreign thread) and no machine code of ours.
// ---------------------------------------------------------------------------

void probeMainThreadWindow() {
  ensureAppKitLoaded();
  print('pthread_main_np() = ${pthread_main_np()}');

  if (!_parkMainThreadInRunLoop()) {
    print('RESULT: could not park the main thread; nothing else to test.');
    _exitProcess(1);
  }
  print('main thread parked in CFRunLoop, main queue draining.');

  final app = getClass('NSApplication').msgSend('sharedApplication');
  print('sharedApplication = ${app.address}');

  final windowClass = getClass('NSWindow');
  final allocated = windowClass.msgSend('alloc');
  print('[NSWindow alloc] = ${allocated.address}');

  final initSelector = sel('initWithContentRect:styleMask:backing:defer:');
  final methodSignature = msgSendPointerSel(
      windowClass, sel('instanceMethodSignatureForSelector:'), initSelector);
  print('NSMethodSignature = ${methodSignature.address}');
  if (methodSignature == nullptr) {
    print('RESULT: no method signature for the NSWindow initializer.');
    _exitProcess(1);
  }

  final invocation = msgSendPointerPointer(getClass('NSInvocation'),
      sel('invocationWithMethodSignature:'), methodSignature);
  print('NSInvocation = ${invocation.address}');

  msgSendVoidPointer(invocation, sel('setTarget:'), allocated);
  msgSendVoidSel(invocation, sel('setSelector:'), initSelector);

  // Argument 0 is self and 1 is _cmd, so the declared arguments start at 2.
  final rect = calloc<NSRect>()
    ..ref.x = 140
    ..ref.y = 140
    ..ref.width = 800
    ..ref.height = 600;
  final styleMask = calloc<Uint64>()
    ..value = NSWindowStyleMaskTitled |
        NSWindowStyleMaskClosable |
        NSWindowStyleMaskResizable;
  final backing = calloc<Uint64>()..value = NSBackingStoreBuffered;
  final deferCreation = calloc<Uint8>()..value = 0;

  final setArgument = sel('setArgument:atIndex:');
  msgSendVoidPointerInt(invocation, setArgument, rect.cast(), 2);
  msgSendVoidPointerInt(invocation, setArgument, styleMask.cast(), 3);
  msgSendVoidPointerInt(invocation, setArgument, backing.cast(), 4);
  msgSendVoidPointerInt(invocation, setArgument, deferCreation.cast(), 5);
  invocation.msgSend('retainArguments');

  print('sending -invoke to the main thread...');
  msgSendPerformOnMain(
      invocation,
      sel('performSelectorOnMainThread:withObject:waitUntilDone:'),
      sel('invoke'),
      nullptr,
      true);
  print('-invoke returned without aborting.');

  final returned = calloc<Pointer<ObjCObject>>();
  msgSendVoidPointer(invocation, sel('getReturnValue:'), returned.cast());
  final window = returned.value;
  print('NSWindow = ${window.address}');

  if (window == nullptr) {
    print('RESULT: the invocation ran on the main thread but returned nil.');
    _exitProcess(1);
  }

  // makeKeyAndOrderFront: takes a single object argument, so it needs no
  // NSInvocation of its own.
  msgSendPerformOnMain(
      window,
      sel('performSelectorOnMainThread:withObject:waitUntilDone:'),
      sel('makeKeyAndOrderFront:'),
      nullptr,
      true);

  print('RESULT: NSWindow CREATED AND ORDERED FRONT from pure Dart FFI - no '
      'native source, no shellcode, no entitlements.');

  calloc.free(rect);
  calloc.free(styleMask);
  calloc.free(backing);
  calloc.free(deferCreation);
  calloc.free(returned);
  _exitProcess(0);
}

// ---------------------------------------------------------------------------
// Probe F - is there an event queue? Creating a window proves nothing if input
// never arrives.
//
// A headless runner has no real keyboard or mouse, so the honest test is the
// machinery itself: post a synthetic NSEvent through the app and pump it back
// with nextEventMatchingMask: on the hijacked main thread. If the very object
// posted comes back out, the queue works and the manual-pump architecture
// (the POC-10 pattern, but for AppKit) is viable.
// ---------------------------------------------------------------------------

const NSEventTypeApplicationDefined = 15;
const NSEventMaskAny = 0xFFFFFFFFFFFFFFFF;

void probeEventPump() {
  ensureAppKitLoaded();
  if (!_parkMainThreadInRunLoop()) {
    print('RESULT: could not park the main thread.');
    _exitProcess(1);
  }
  print('main thread parked, main queue draining.');

  final app = getClass('NSApplication').msgSend('sharedApplication');

  final policyInvocation = _newInvocation(app, sel('setActivationPolicy:'));
  final policy = calloc<Int64>()..value = NSApplicationActivationPolicyRegular;
  _setArgument(policyInvocation, policy.cast(), 2);
  _invokeOnMain(policyInvocation);
  print('activation policy set on the main thread.');

  final location = calloc<NSPoint>()
    ..ref.x = 0
    ..ref.y = 0;
  final posted = msgSendDummyEvent(
      getClass('NSEvent'),
      sel('otherEventWithType:location:modifierFlags:timestamp:windowNumber:'
          'context:subtype:data1:data2:'),
      NSEventTypeApplicationDefined,
      location.ref,
      0,
      0.0,
      0,
      nullptr,
      1,
      0xBEEF,
      0);
  print('synthetic NSEvent = ${posted.address}');
  if (posted == nullptr) {
    print('RESULT: could not build an NSEvent.');
    _exitProcess(1);
  }

  final postInvocation = _newInvocation(app, sel('postEvent:atStart:'));
  final eventArgument = calloc<Pointer<ObjCObject>>()..value = posted;
  final atStart = calloc<Uint8>()..value = 1;
  _setArgument(postInvocation, eventArgument.cast(), 2);
  _setArgument(postInvocation, atStart.cast(), 3);
  _invokeOnMain(postInvocation);
  print('event posted on the main thread.');

  final pumpInvocation = _newInvocation(
      app, sel('nextEventMatchingMask:untilDate:inMode:dequeue:'));
  final mask = calloc<Uint64>()..value = NSEventMaskAny;
  final untilDate = calloc<Pointer<ObjCObject>>()
    ..value = getClass('NSDate').msgSend('distantPast');
  final mode = calloc<Pointer<ObjCObject>>()
    ..value = _nsString('kCFRunLoopDefaultMode');
  final dequeue = calloc<Uint8>()..value = 1;
  _setArgument(pumpInvocation, mask.cast(), 2);
  _setArgument(pumpInvocation, untilDate.cast(), 3);
  _setArgument(pumpInvocation, mode.cast(), 4);
  _setArgument(pumpInvocation, dequeue.cast(), 5);
  _invokeOnMain(pumpInvocation);

  final pumped = _returnedObject(pumpInvocation);
  print('nextEventMatchingMask: -> ${pumped.address}');

  if (pumped == posted) {
    print('RESULT: the exact event posted came back out of the queue. AppKit '
        'event dispatch works on the hijacked main thread.');
    _exitProcess(0);
  }
  print(pumped == nullptr
      ? 'RESULT: queue returned nil - the event never made it through.'
      : 'RESULT: a DIFFERENT event came back (${pumped.address}); the queue is '
          'alive but identity is unproven.');
  _exitProcess(1);
}

// ---------------------------------------------------------------------------
// Probe G - hand the hijacked main thread to [NSApp run], the standard AppKit
// loop. `run` never returns, so it goes with waitUntilDone:NO; the questions
// are whether the app reports itself running and whether the main queue keeps
// draining afterwards (i.e. whether we can still route work to it).
// ---------------------------------------------------------------------------

void probeNsAppRunOnMain() {
  ensureAppKitLoaded();
  if (!_parkMainThreadInRunLoop()) {
    print('RESULT: could not park the main thread.');
    _exitProcess(1);
  }

  final app = getClass('NSApplication').msgSend('sharedApplication');
  final policyInvocation = _newInvocation(app, sel('setActivationPolicy:'));
  final policy = calloc<Int64>()..value = NSApplicationActivationPolicyRegular;
  _setArgument(policyInvocation, policy.cast(), 2);
  _invokeOnMain(policyInvocation);

  print('sending -run to the main thread (waitUntilDone: NO)...');
  _invokeOnMain(_newInvocation(app, sel('run')), wait: false);

  const twoSeconds = 2000000000;
  _sleepNanos(twoSeconds);

  final semaphore = dispatch_semaphore_create(0);
  dispatch_async_f(
      dispatch_get_main_queue(), semaphore, dispatch_semaphore_signal_ptr);
  const threeSeconds = 3000000000;
  final stillDraining =
      dispatch_semaphore_wait(semaphore, dispatch_time(0, threeSeconds)) == 0;
  print('main queue still draining under [NSApp run]: $stillDraining');

  final isRunningInvocation = _newInvocation(app, sel('isRunning'));
  _invokeOnMain(isRunningInvocation);
  final isRunning = calloc<Uint8>();
  msgSendVoidPointer(
      isRunningInvocation, sel('getReturnValue:'), isRunning.cast());
  print('[NSApp isRunning] = ${isRunning.value}');

  final ok = stillDraining && isRunning.value != 0;
  print(ok
      ? 'RESULT: the AppKit event loop is running on the hijacked main thread '
          'and work can still be routed to it.'
      : 'RESULT: [NSApp run] did not take over cleanly.');
  _exitProcess(ok ? 0 : 1);
}

void main(List<String> args) {
  final probe = args.isEmpty ? 'thread' : args.first;
  print('=== probe: $probe ===');
  switch (probe) {
    case 'thread':
      probeThread();
    case 'nsapp-run':
      probeNsAppRun();
    case 'skylight':
      probeSkyLight();
    case 'signal-hijack':
      probeSignalHijack();
    case 'mainthread-window':
      probeMainThreadWindow();
    case 'event-pump':
      probeEventPump();
    case 'nsapp-run-main':
      probeNsAppRunOnMain();
    default:
      print('unknown probe: $probe');
      print('usage: probe [thread|nsapp-run|skylight|signal-hijack'
          '|mainthread-window|event-pump|nsapp-run-main]');
  }
}
