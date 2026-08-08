// Spike: can a pure-Dart process (no C/C++/ObjC source) own the macOS main
// thread, or otherwise reach a window without it?
//
// Measured baseline (macos-14 arm64, Dart 3.6.0, `dart compile exe`):
// pthread_main_np() = 0, so NSWindow aborts the process. Each probe below
// explores one escape route and is a separate subcommand, because a probe that
// crashes must not hide the results of the others.
//
// ignore_for_file: non_constant_identifier_names, constant_identifier_names

import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:poc_03_appkit_window/appkit_window.dart';
import 'package:poc_03_appkit_window/objc_runtime.dart';
// The conformance suite lives with the other two backends; backend 2 answers
// the same lines with the same witness code.
import 'package:poc_20_macos_three_backends/poc_20_macos_three_backends.dart'
    as shared;

// Darwin signal numbers.
const SIGUSR2 = 31;

// ---------------------------------------------------------------------------
// Extra libSystem / CoreFoundation bindings used only by the probes.
// ---------------------------------------------------------------------------

final pthread_main_thread_np = libSystem.lookupFunction<
    Pointer<Void> Function(),
    Pointer<Void> Function()>('pthread_main_thread_np');

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
    void Function(
        Pointer<Void>, Pointer<Void>, Pointer<Void>)>('dispatch_async_f');

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

final dispatch_time = libSystem.lookupFunction<Uint64 Function(Uint64, Int64),
    int Function(int, int)>('dispatch_time');

final DynamicLibrary libCoreFoundation = DynamicLibrary.open(
    '/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation');

final DynamicLibrary libFoundation = DynamicLibrary.open(
    '/System/Library/Frameworks/Foundation.framework/Foundation');

final Pointer<Void> cfRunLoopRunPtr =
    libCoreFoundation.lookup<Void>('CFRunLoopRun');

final cfRunLoopStop = libCoreFoundation.lookupFunction<
    Void Function(Pointer<Void>),
    void Function(Pointer<Void>)>('CFRunLoopStop');

final cfRunLoopWakeUp = libCoreFoundation.lookupFunction<
    Void Function(Pointer<Void>),
    void Function(Pointer<Void>)>('CFRunLoopWakeUp');

final cfRunLoopRemoveSource = libCoreFoundation.lookupFunction<
    Void Function(Pointer<Void>, Pointer<Void>, Pointer<Void>),
    void Function(Pointer<Void>, Pointer<Void>, Pointer<Void>)>(
  'CFRunLoopRemoveSource',
);

final cfRelease = libCoreFoundation.lookupFunction<Void Function(Pointer<Void>),
    void Function(Pointer<Void>)>('CFRelease');

// Historical probes deliberately terminate at a precise observation point.
// The graceful-hijack-shutdown probe below instead unwinds CFRunLoopRun and
// returns normally, which is the lifecycle required by a reusable backend.
final _exitProcess =
    libSystem.lookupFunction<Void Function(Int32), void Function(int)>('_exit');

final getpid =
    libSystem.lookupFunction<Int32 Function(), int Function()>('getpid');

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
  print(
      'signal(SIGUSR2, CFRunLoopRun) -> previous handler ${previous.address}');

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
///
/// Line-buffered-ish logging: when stdout is redirected to a file (every CI
/// step that backgrounds a probe), Dart block-buffers it and a kill -9 eats
/// the evidence. stderr stays line-buffered on Darwin.
void _log(String message) {
  print(message);
  stderr.writeln(message);
}

Pointer<ObjCObject> _nsDefaultRunLoopMode() =>
    libFoundation.lookup<Pointer<ObjCObject>>('NSDefaultRunLoopMode').value;

/// The keep-alive source is not optional. Without it CFRunLoopRun drains what
/// is pending, finds no source to justify staying, returns
/// kCFRunLoopRunFinished, and the VM takes the thread back - which is what the
/// probe L stack sample caught and what made F, K, G and O fail against a run
/// loop that was no longer there.
bool _parkMainThreadInRunLoop() {
  if (!_keepMainRunLoopAlive()) {
    _log('WARNING: no keep-alive source; the run loop will exit immediately.');
  }
  _previousSigusr2Handler = signal(SIGUSR2, cfRunLoopRunPtr);
  final killResult = pthread_kill(pthread_main_thread_np(), SIGUSR2);
  if (killResult != 0) {
    _log('pthread_kill(main, SIGUSR2) failed: $killResult');
    return false;
  }

  final semaphore = dispatch_semaphore_create(0);
  dispatch_async_f(
      dispatch_get_main_queue(), semaphore, dispatch_semaphore_signal_ptr);
  const threeSeconds = 3000000000;
  return dispatch_semaphore_wait(semaphore, dispatch_time(0, threeSeconds)) ==
      0;
}

Pointer<Void> _previousSigusr2Handler = nullptr;
Pointer<Void> _hijackedMainRunLoop = nullptr;
Pointer<Void> _mainRunLoopKeepAliveSource = nullptr;
Pointer<Void> _mainRunLoopDefaultMode = nullptr;

bool _stopHijackedMainRunLoop() {
  if (_hijackedMainRunLoop == nullptr) return false;

  // Restore signal disposition first, so a later SIGUSR2 cannot re-enter the
  // backend while teardown is in progress.
  signal(SIGUSR2, _previousSigusr2Handler);
  if (_mainRunLoopKeepAliveSource != nullptr) {
    cfRunLoopRemoveSource(
      _hijackedMainRunLoop,
      _mainRunLoopKeepAliveSource,
      _mainRunLoopDefaultMode,
    );
    cfRelease(_mainRunLoopKeepAliveSource);
    _mainRunLoopKeepAliveSource = nullptr;
  }
  cfRunLoopStop(_hijackedMainRunLoop);
  cfRunLoopWakeUp(_hijackedMainRunLoop);
  return true;
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
  final invocation = msgSendPointerPointer(getClass('NSInvocation'),
      sel('invocationWithMethodSignature:'), signature);
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

/// Builds the nextEventMatchingMask: invocation with the real
/// NSDefaultRunLoopMode global and distantPast. Shared by F/K/L/O/V.
Pointer<ObjCObject> _newPumpInvocation(Pointer<ObjCObject> app) {
  final pumpInvocation = _newInvocation(
      app, sel('nextEventMatchingMask:untilDate:inMode:dequeue:'));
  final mask = calloc<Uint64>()..value = NSEventMaskAny;
  final untilDate = calloc<Pointer<ObjCObject>>()
    ..value = getClass('NSDate').msgSend('distantPast');
  final mode = calloc<Pointer<ObjCObject>>()..value = _nsDefaultRunLoopMode();
  final dequeue = calloc<Uint8>()..value = 1;
  _setArgument(pumpInvocation, mask.cast(), 2);
  _setArgument(pumpInvocation, untilDate.cast(), 3);
  _setArgument(pumpInvocation, mode.cast(), 4);
  _setArgument(pumpInvocation, dequeue.cast(), 5);
  pumpInvocation.msgSend('retainArguments');
  return pumpInvocation;
}

Pointer<ObjCObject> _newSyntheticAppEvent() {
  final location = calloc<NSPoint>()
    ..ref.x = 0
    ..ref.y = 0;
  return msgSendDummyEvent(
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
}

void _postEventOnMain(Pointer<ObjCObject> app, Pointer<ObjCObject> event) {
  final postInvocation = _newInvocation(app, sel('postEvent:atStart:'));
  final eventArgument = calloc<Pointer<ObjCObject>>()..value = event;
  final atStart = calloc<Uint8>()..value = 1;
  _setArgument(postInvocation, eventArgument.cast(), 2);
  _setArgument(postInvocation, atStart.cast(), 3);
  _invokeOnMain(postInvocation);
}

Future<void> probeEventPump() async {
  ensureAppKitLoaded();
  if (!_parkMainThreadInRunLoop()) {
    _log('RESULT: could not park the main thread.');
    _exitProcess(1);
  }
  _log('main thread parked, main queue draining.');

  // sharedApplication + finishLaunching only on the parked main thread - see
  // _sharedAppOnMain. Creating NSApp on the Dart thread is what made O hit
  // NSCrashOnBackgroundThreadMainEventQueue.
  final app = _finishLaunchingOnMain();
  if (app == nullptr || _isSentinel(app)) {
    _log('RESULT: could not finishLaunching on the main thread.');
    _exitProcess(1);
  }
  _log('[NSApp finishLaunching] on main; app=${app.address}');

  final probeChannel = _newInvocation(app, sel('isRunning'));
  _invokeOnMain(probeChannel);
  final running = calloc<Uint8>();
  msgSendVoidPointer(probeChannel, sel('getReturnValue:'), running.cast());
  _log('channel alive after finishLaunching: [NSApp isRunning] = '
      '${running.value}');

  final posted = _newSyntheticAppEvent();
  _log('synthetic NSEvent = ${posted.address}');
  if (posted == nullptr) {
    _log('RESULT: could not build an NSEvent.');
    _exitProcess(1);
  }

  _log('building pump invocation before post...');
  final pumpInvocation = _newPumpInvocation(app);
  _writeSentinel(pumpInvocation);

  final postInvocation = _newInvocation(app, sel('postEvent:atStart:'));
  final eventArgument = calloc<Pointer<ObjCObject>>()..value = posted;
  final atStart = calloc<Uint8>()..value = 1;
  _setArgument(postInvocation, eventArgument.cast(), 2);
  _setArgument(postInvocation, atStart.cast(), 3);
  _invokeOnMain(postInvocation, wait: false);
  _log('event post dispatched (async).');

  _scheduleOneShot(pumpInvocation, 0.1, wait: false);
  _log('one-shot pump scheduled (async); waiting up to 2s...');

  await Future<void>.delayed(const Duration(seconds: 2));

  final pumped = _returnedObject(pumpInvocation);
  _log('nextEventMatchingMask: -> ${pumped.address}');

  if (_isSentinel(pumped)) {
    _log('RESULT: pump never completed - nextEventMatchingMask: blocked even '
        'with distantPast, driven from an NSTimer on the parked run loop.');
    _exitProcess(1);
  }
  if (pumped == posted) {
    _log('RESULT: the exact event posted came back out of the queue. AppKit '
        'event dispatch works on the hijacked main thread '
        '(sharedApplication was created ON main).');
    _exitProcess(0);
  }
  _log(pumped == nullptr
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

// ---------------------------------------------------------------------------
// Probe H - route C to the end: a window straight from the WindowServer, with
// no AppKit and therefore no main-thread rule at all.
//
// ABI per the long-standing CGSInternal reverse-engineered headers:
//   CGError CGSNewRegionWithRect(const CGRect *rect, CGSRegionRef *out);
//   CGError SLSNewWindow(CGSConnectionID cid, CGSBackingType backing,
//                        float x, float y, CGSRegionRef shape,
//                        CGSWindowID *outWID);
// Note x/y are 32-bit floats there, not CGFloat - one of the reasons this ABI
// needs measuring rather than trusting.
// ---------------------------------------------------------------------------

const kCGSBackingStoreBuffered = 2;

typedef _NewRegionWithRectNative = Int32 Function(
    Pointer<NSRect> rect, Pointer<Pointer<Void>> outRegion);
typedef _SlsNewWindowNative = Int32 Function(Int32 cid, Int32 backing, Float x,
    Float y, Pointer<Void> shape, Pointer<Uint32> outWindowId);
typedef _SlsOrderWindowNative = Int32 Function(
    Int32 cid, Uint32 windowId, Int32 order, Uint32 relativeTo);
typedef _SlsSetWindowLevelNative = Int32 Function(
    Int32 cid, Uint32 windowId, Int32 level);

Pointer<T>? _tryLookup<T extends NativeType>(DynamicLibrary lib, String name) {
  try {
    return lib.lookup<T>(name);
  } catch (_) {
    return null;
  }
}

void probeSkyLightWindow() {
  final DynamicLibrary lib;
  try {
    lib = DynamicLibrary.open(
        '/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight');
  } catch (e) {
    print('RESULT: SkyLight.framework not loadable: $e');
    _exitProcess(1);
    return;
  }

  // SLSNewRegionWithRect is absent on this OS, so hunt for the current name
  // instead of hardcoding one.
  const regionCandidates = [
    'CGSNewRegionWithRect',
    'SLSNewRegionWithRect',
    'CGSNewRegionWithRectList',
    'SLSNewRegionWithRectList',
    'CGSNewEmptyRegion',
    'SLSNewEmptyRegion',
    'CGRegionCreateWithRect',
    'SLSRegionCreateWithRect',
  ];
  String? regionSymbol;
  for (final candidate in regionCandidates) {
    if (_tryLookup<Void>(lib, candidate) != null) {
      print('  found   $candidate');
      regionSymbol ??= candidate;
    } else {
      print('  missing $candidate');
    }
  }
  if (regionSymbol == null || !regionSymbol.endsWith('NewRegionWithRect')) {
    print('RESULT: no rect-shaped region constructor found '
        '(best match: $regionSymbol). Window shape cannot be built yet.');
    _exitProcess(1);
  }

  final connectionId = lib.lookupFunction<Int32 Function(), int Function()>(
      'SLSMainConnectionID')();
  print('SLSMainConnectionID() = $connectionId '
      '(pthread_main_np() = ${pthread_main_np()})');

  final newRegionWithRect = lib.lookupFunction<_NewRegionWithRectNative,
      int Function(Pointer<NSRect>, Pointer<Pointer<Void>>)>(regionSymbol!);
  final rect = calloc<NSRect>()
    ..ref.x = 160
    ..ref.y = 160
    ..ref.width = 640
    ..ref.height = 480;
  final regionSlot = calloc<Pointer<Void>>();
  final regionError = newRegionWithRect(rect, regionSlot);
  print(
      '$regionSymbol -> CGError $regionError, region ${regionSlot.value.address}');
  if (regionError != 0 || regionSlot.value == nullptr) {
    print('RESULT: could not build the window shape.');
    _exitProcess(1);
  }

  final newWindow = lib.lookupFunction<
      _SlsNewWindowNative,
      int Function(int, int, double, double, Pointer<Void>,
          Pointer<Uint32>)>('SLSNewWindow');
  final windowIdSlot = calloc<Uint32>();
  final windowError = newWindow(connectionId, kCGSBackingStoreBuffered, 160.0,
      160.0, regionSlot.value, windowIdSlot);
  final windowId = windowIdSlot.value;
  print('SLSNewWindow -> CGError $windowError, CGSWindowID $windowId');

  if (windowError != 0 || windowId == 0) {
    print('RESULT: WindowServer refused the window (CGError $windowError). '
        'The guessed ABI is the prime suspect.');
    _exitProcess(1);
  }

  final setLevel =
      lib.lookupFunction<_SlsSetWindowLevelNative, int Function(int, int, int)>(
          'SLSSetWindowLevel');
  print('SLSSetWindowLevel -> ${setLevel(connectionId, windowId, 0)}');

  final orderWindow = lib.lookupFunction<_SlsOrderWindowNative,
      int Function(int, int, int, int)>('SLSOrderWindow');
  final orderError = orderWindow(connectionId, windowId, 1, 0);
  print('SLSOrderWindow -> CGError $orderError');

  print('RESULT: WindowServer window $windowId created and ordered WITHOUT '
      'AppKit, from a non-main thread. Still needs a drawing context and has '
      'no NSEvent queue.');
  _exitProcess(0);
}

// ---------------------------------------------------------------------------
// Probe I - does the Dart runtime survive losing thread 0?
//
// The hijack parks the process main thread forever. The isolate runs on a VM
// pool thread and should be untouched, but "should" is not a measurement:
// check that timers still fire, that file I/O completes, that a spawned
// isolate still runs, and that UI work can still be routed to the parked
// thread while all of that happens.
// ---------------------------------------------------------------------------

Future<void> probeVmHealthUnderHijack() async {
  ensureAppKitLoaded();
  if (!_parkMainThreadInRunLoop()) {
    print('RESULT: could not park the main thread.');
    _exitProcess(1);
  }
  print('main thread parked; the isolate keeps its own thread.');

  var healthy = true;

  final timer = Stopwatch()..start();
  await Future<void>.delayed(const Duration(milliseconds: 250));
  final elapsed = timer.elapsedMilliseconds;
  final timersWork = elapsed >= 200 && elapsed < 2000;
  print('timer fired after ${elapsed}ms -> $timersWork');
  healthy &= timersWork;

  final file = File('${Directory.systemTemp.path}/probe_io_under_hijack.txt');
  await file.writeAsString('io works under hijack');
  final readBack = await file.readAsString();
  final ioWorks = readBack == 'io works under hijack';
  print('async file I/O round trip -> $ioWorks');
  healthy &= ioWorks;

  final spawned = await Isolate.run(() => 6 * 7);
  final isolatesWork = spawned == 42;
  print('Isolate.run -> $spawned ($isolatesWork)');
  healthy &= isolatesWork;

  // And the UI channel must still be open after all that async traffic.
  final app = getClass('NSApplication').msgSend('sharedApplication');
  final isRunningInvocation = _newInvocation(app, sel('isRunning'));
  _invokeOnMain(isRunningInvocation);
  final isRunning = calloc<Uint8>();
  msgSendVoidPointer(
      isRunningInvocation, sel('getReturnValue:'), isRunning.cast());
  print('UI channel still answers: [NSApp isRunning] = ${isRunning.value}');

  print(healthy
      ? 'RESULT: the VM is unharmed by the hijack - timers, I/O and isolates '
          'all work while the main thread belongs to AppKit.'
      : 'RESULT: the hijack DAMAGED the Dart runtime; see the failures above.');
  _exitProcess(healthy ? 0 : 1);
}

// ---------------------------------------------------------------------------
// Probe J - the reverse channel: can a call that ORIGINATES on the AppKit main
// thread reach Dart safely?
//
// Dart -> UI is proven (NSInvocation + performSelectorOnMainThread:). This is
// the other direction, and it is what delegates, event handlers and callbacks
// all need. NativeCallable.isolateLocal aborts when invoked from a foreign
// thread; .listener exists for exactly this case - it accepts calls from any
// thread and posts a message to the isolate's event loop.
//
// So: register a real Objective-C class from Dart, give one of its methods a
// .listener as its IMP, and invoke that method from the hijacked main thread.
// ---------------------------------------------------------------------------

typedef _HandleValueNative = Void Function(
    Pointer<ObjCObject> self, Pointer<ObjCSel> cmd, Int64 value);

Future<void> probeReverseChannel() async {
  ensureAppKitLoaded();
  if (!_parkMainThreadInRunLoop()) {
    print('RESULT: could not park the main thread.');
    _exitProcess(1);
  }
  print('main thread parked, main queue draining.');

  final delivered = Completer<int>();
  final callable = NativeCallable<_HandleValueNative>.listener(
      (Pointer<ObjCObject> self, Pointer<ObjCSel> cmd, int value) {
    // Runs on the Dart isolate, not on the thread that called the method.
    print('Dart received $value (pthread_main_np() = ${pthread_main_np()})');
    if (!delivered.isCompleted) delivered.complete(value);
  });

  final className = 'DartUiProbeReceiver'.toNativeUtf8();
  final receiverClass =
      objc_allocateClassPair(getClass('NSObject'), className, 0);
  calloc.free(className);
  if (receiverClass == nullptr) {
    print('RESULT: objc_allocateClassPair failed.');
    _exitProcess(1);
  }

  // "v@:q" = returns void, takes self, _cmd and a long long.
  final types = 'v@:q'.toNativeUtf8();
  final added = class_addMethod(receiverClass, sel('handleValue:'),
      callable.nativeFunction.cast(), types);
  calloc.free(types);
  objc_registerClassPair(receiverClass);
  print('class registered, class_addMethod -> $added');

  final receiver = receiverClass.msgSend('alloc').msgSend('init');
  print('receiver instance = ${receiver.address}');

  final invocation = _newInvocation(receiver, sel('handleValue:'));
  final value = calloc<Int64>()..value = 0xC0FFEE;
  _setArgument(invocation, value.cast(), 2);

  // waitUntilDone MUST be false: the listener delivers through this isolate's
  // event loop, so blocking this thread on the main thread would deadlock the
  // very mechanism under test.
  _invokeOnMain(invocation, wait: false);
  print('invocation dispatched to the main thread (waitUntilDone: NO).');

  final received = await delivered.future
      .timeout(const Duration(seconds: 5), onTimeout: () => -1);
  callable.close();

  if (received == 0xC0FFEE) {
    print('RESULT: a call made ON the AppKit main thread was delivered to the '
        'Dart isolate. The UI -> Dart channel works; delegates and event '
        'handlers can be written in Dart.');
    _exitProcess(0);
  }
  print('RESULT: nothing reached Dart (got $received).');
  _exitProcess(1);
}

// ---------------------------------------------------------------------------
// Probe K - why does nextEventMatchingMask: hang, and can a timer dodge it?
//
// Probe F proved the UI channel is alive after -finishLaunching and that
// -postEvent:atStart: works; only nextEventMatchingMask: never returns. One
// suspect is re-entrancy: performSelectorOnMainThread: delivers through a run
// loop source, so the pump would be running a nested run loop from inside a
// run loop callback.
//
// +[NSTimer scheduledTimerWithTimeInterval:invocation:repeats:] dodges that -
// the timer fires the NSInvocation directly on the main thread, off the timer
// source, with no performSelector in the path and no callback into Dart.
// ---------------------------------------------------------------------------

Future<void> probePumpViaTimer() async {
  ensureAppKitLoaded();
  if (!_parkMainThreadInRunLoop()) {
    _log('RESULT: could not park the main thread.');
    _exitProcess(1);
  }

  // A witness timer, needed to read the result at all: a nil from the pump
  // means "queue was empty" only if timers fire in the first place. Without
  // this, a nil is indistinguishable from a timer that never ran.
  // Schedule the witness BEFORE the pump: if nextEventMatchingMask: blocks the
  // main thread, a witness scheduled after it never gets a chance to fire and
  // falsely reports "timers dead".
  var ticks = 0;
  final witness = NativeCallable<_HandleValueNative>.listener(
      (Pointer<ObjCObject> self, Pointer<ObjCSel> cmd, int value) => ticks++);
  final className = 'DartUiTimerWitness'.toNativeUtf8();
  final witnessClass =
      objc_allocateClassPair(getClass('NSObject'), className, 0);
  calloc.free(className);
  final types = 'v@:q'.toNativeUtf8();
  class_addMethod(
      witnessClass, sel('handleValue:'), witness.nativeFunction.cast(), types);
  calloc.free(types);
  objc_registerClassPair(witnessClass);
  final witnessObject = witnessClass.msgSend('alloc').msgSend('init');

  // Witness BEFORE touching NSApp, so we can tell "loop dead" from "NSApp
  // broke the loop".
  final timerClass = getClass('NSTimer');
  final interval = calloc<Double>()..value = 0.05;
  final repeats = calloc<Uint8>()..value = 1;

  final witnessInvocation = _newInvocation(witnessObject, sel('handleValue:'));
  final witnessValue = calloc<Int64>()..value = 1;
  _setArgument(witnessInvocation, witnessValue.cast(), 2);
  witnessInvocation.msgSend('retainArguments');
  final scheduleWitness = _newInvocation(
      timerClass, sel('scheduledTimerWithTimeInterval:invocation:repeats:'));
  final witnessArgument = calloc<Pointer<ObjCObject>>()
    ..value = witnessInvocation;
  _setArgument(scheduleWitness, interval.cast(), 2);
  _setArgument(scheduleWitness, witnessArgument.cast(), 3);
  _setArgument(scheduleWitness, repeats.cast(), 4);
  _invokeOnMain(scheduleWitness);
  _log('witness timer scheduled on the main run loop FIRST.');

  await Future<void>.delayed(const Duration(milliseconds: 400));
  _log('witness ticks before NSApp: $ticks');

  final app = _finishLaunchingOnMain();
  if (app == nullptr || _isSentinel(app)) {
    _log('RESULT: finishLaunching on main failed.');
    _exitProcess(1);
  }
  _log('[NSApp finishLaunching] on main; app=${app.address}');

  await Future<void>.delayed(const Duration(milliseconds: 400));
  _log('witness ticks after NSApp: $ticks');

  _log('building pump invocation...');
  final pumpInvocation = _newPumpInvocation(app);
  _writeSentinel(pumpInvocation);
  _log('pump invocation ready, sentinel written.');

  final posted = _newSyntheticAppEvent();
  _log('posting event ${posted.address} (waitUntilDone: NO)...');
  final postInvocation = _newInvocation(app, sel('postEvent:atStart:'));
  final eventArgument = calloc<Pointer<ObjCObject>>()..value = posted;
  final atStart = calloc<Uint8>()..value = 1;
  _setArgument(postInvocation, eventArgument.cast(), 2);
  _setArgument(postInvocation, atStart.cast(), 3);
  _invokeOnMain(postInvocation, wait: false);
  _log('post dispatched.');

  // One-shot pump; schedule without waiting on the main thread.
  _scheduleOneShot(pumpInvocation, 0.1, wait: false);
  _log('one-shot pump scheduled (async); waiting 2s...');

  await Future<void>.delayed(const Duration(seconds: 2));
  witness.close();

  final pumped = _returnedObject(pumpInvocation);
  _log('witness timer fired $ticks times total');
  _log('pump returned: ${pumped.address} sentinel=${_isSentinel(pumped)}');

  if (ticks == 0) {
    _log('RESULT: the parked run loop never serviced a timer, so the pump '
        'never ran. CFRunLoopRun inside a signal handler is the suspect, not '
        'nextEventMatchingMask:.');
    _exitProcess(1);
  }

  if (_isSentinel(pumped)) {
    _log('RESULT: timers fire ($ticks) but the pump never completed - '
        'nextEventMatchingMask: blocked the main thread. That is why the '
        'earlier witness-after-pump setup saw zero ticks.');
    _exitProcess(1);
  }

  if (pumped == posted) {
    _log('RESULT: the timer pumped our event off the main thread run loop. '
        'A timer-driven pump is the way to feed AppKit event dispatch.');
    _exitProcess(0);
  }
  _log(pumped == nullptr
      ? 'RESULT: timers DO fire on the parked run loop ($ticks times) and the '
          'pump still returned nil - so nextEventMatchingMask: returns '
          'normally here and the queue is simply empty.'
      : 'RESULT: a different object came back (${pumped.address}).');
  _exitProcess(1);
}

// ---------------------------------------------------------------------------
// Probe M - finish route C: draw actual pixels into the WindowServer window.
//
// The export dump surfaced SLWindowContextCreate, the piece this route was
// missing. If it hands back a CGContext, route C has a window AND a drawing
// surface with no AppKit anywhere - and no main-thread rule on either.
// ---------------------------------------------------------------------------

typedef _WindowContextCreateNative = Pointer<Void> Function(
    Int32 cid, Uint32 windowId, Pointer<Void> options);
typedef _SetRgbFillColorNative = Void Function(
    Pointer<Void> context, Double r, Double g, Double b, Double a);
typedef _FillRectNative = Void Function(Pointer<Void> context, NSRect rect);
typedef _ContextFlushNative = Void Function(Pointer<Void> context);

void probeSkyLightDraw() {
  final DynamicLibrary skyLight;
  try {
    skyLight = DynamicLibrary.open(
        '/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight');
  } catch (e) {
    print('RESULT: SkyLight.framework not loadable: $e');
    _exitProcess(1);
    return;
  }

  final connectionId =
      skyLight.lookupFunction<Int32 Function(), int Function()>(
          'SLSMainConnectionID')();
  final newRegionWithRect = skyLight.lookupFunction<
      _NewRegionWithRectNative,
      int Function(
          Pointer<NSRect>, Pointer<Pointer<Void>>)>('CGSNewRegionWithRect');
  final rect = calloc<NSRect>()
    ..ref.x = 200
    ..ref.y = 200
    ..ref.width = 480
    ..ref.height = 320;
  final regionSlot = calloc<Pointer<Void>>();
  newRegionWithRect(rect, regionSlot);

  final newWindow = skyLight.lookupFunction<
      _SlsNewWindowNative,
      int Function(int, int, double, double, Pointer<Void>,
          Pointer<Uint32>)>('SLSNewWindow');
  final windowIdSlot = calloc<Uint32>();
  final windowError = newWindow(connectionId, kCGSBackingStoreBuffered, 200.0,
      200.0, regionSlot.value, windowIdSlot);
  final windowId = windowIdSlot.value;
  print('SLSNewWindow -> CGError $windowError, CGSWindowID $windowId');
  if (windowError != 0 || windowId == 0) {
    print('RESULT: no window to draw into.');
    _exitProcess(1);
  }

  final windowContextCreate = skyLight.lookupFunction<
      _WindowContextCreateNative,
      Pointer<Void> Function(int, int, Pointer<Void>)>('SLWindowContextCreate');
  final context = windowContextCreate(connectionId, windowId, nullptr);
  print('SLWindowContextCreate -> ${context.address} '
      '(pthread_main_np() = ${pthread_main_np()})');
  if (context == nullptr) {
    print('RESULT: no drawing context; route C stops at an empty window.');
    _exitProcess(1);
  }

  final coreGraphics = DynamicLibrary.open(
      '/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics');
  final setFillColor = coreGraphics.lookupFunction<
      _SetRgbFillColorNative,
      void Function(Pointer<Void>, double, double, double,
          double)>('CGContextSetRGBFillColor');
  final fillRect = coreGraphics.lookupFunction<_FillRectNative,
      void Function(Pointer<Void>, NSRect)>('CGContextFillRect');
  final flush = coreGraphics.lookupFunction<_ContextFlushNative,
      void Function(Pointer<Void>)>('CGContextFlush');

  final fill = calloc<NSRect>()
    ..ref.x = 0
    ..ref.y = 0
    ..ref.width = 480
    ..ref.height = 320;
  setFillColor(context, 0.1, 0.5, 0.9, 1.0);
  fillRect(context, fill.ref);
  flush(context);
  print('filled 480x320 and flushed the context.');

  final orderWindow = skyLight.lookupFunction<_SlsOrderWindowNative,
      int Function(int, int, int, int)>('SLSOrderWindow');
  print('SLSOrderWindow -> ${orderWindow(connectionId, windowId, 1, 0)}');

  print('RESULT: route C draws. Window $windowId has a CGContext and painted '
      'pixels, entirely off the main thread, with no AppKit involved.');
  _exitProcess(0);
}

// ---------------------------------------------------------------------------
// Probes N/O/P - verification from OUTSIDE the process.
//
// Everything so far is self-reported: the probe says it made a window and the
// same probe says it worked. An external witness settles it. screencapture(1)
// can photograph a window by its CGSWindowID, which only succeeds if the
// WindowServer really has that window - and a second process can inject real
// keyboard and mouse events through CGEventPost.
//
// The holders print their window id in a grep-friendly form and stay alive so
// the outside world has something to look at.
// ---------------------------------------------------------------------------

int _returnedInt(Pointer<ObjCObject> invocation) {
  final slot = calloc<Int64>();
  msgSendVoidPointer(invocation, sel('getReturnValue:'), slot.cast());
  final value = slot.value;
  calloc.free(slot);
  return value;
}

void probeHoldSkyLightWindow(int seconds) {
  final skyLight = DynamicLibrary.open(
      '/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight');
  final connectionId =
      skyLight.lookupFunction<Int32 Function(), int Function()>(
          'SLSMainConnectionID')();

  final rect = calloc<NSRect>()
    ..ref.x = 200
    ..ref.y = 200
    ..ref.width = 480
    ..ref.height = 320;
  final regionSlot = calloc<Pointer<Void>>();
  skyLight.lookupFunction<
      _NewRegionWithRectNative,
      int Function(Pointer<NSRect>,
          Pointer<Pointer<Void>>)>('CGSNewRegionWithRect')(rect, regionSlot);

  final windowIdSlot = calloc<Uint32>();
  final error = skyLight.lookupFunction<
          _SlsNewWindowNative,
          int Function(int, int, double, double, Pointer<Void>,
              Pointer<Uint32>)>('SLSNewWindow')(connectionId,
      kCGSBackingStoreBuffered, 200.0, 200.0, regionSlot.value, windowIdSlot);
  final windowId = windowIdSlot.value;
  if (error != 0 || windowId == 0) {
    print('RESULT: SLSNewWindow failed with CGError $error');
    _exitProcess(1);
  }

  final context = skyLight.lookupFunction<_WindowContextCreateNative,
          Pointer<Void> Function(int, int, Pointer<Void>)>(
      'SLWindowContextCreate')(connectionId, windowId, nullptr);
  print('SLWindowContextCreate -> ${context.address}');
  if (context != nullptr) {
    final coreGraphics = DynamicLibrary.open(
        '/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics');
    final fill = calloc<NSRect>()
      ..ref.x = 0
      ..ref.y = 0
      ..ref.width = 480
      ..ref.height = 320;
    coreGraphics.lookupFunction<
        _SetRgbFillColorNative,
        void Function(Pointer<Void>, double, double, double,
            double)>('CGContextSetRGBFillColor')(context, 0.1, 0.5, 0.9, 1.0);
    coreGraphics
        .lookupFunction<_FillRectNative, void Function(Pointer<Void>, NSRect)>(
            'CGContextFillRect')(context, fill.ref);
    coreGraphics.lookupFunction<_ContextFlushNative,
        void Function(Pointer<Void>)>('CGContextFlush')(context);
    print('painted 480x320 into the window context.');
  }

  skyLight
      .lookupFunction<_SlsOrderWindowNative, int Function(int, int, int, int)>(
          'SLSOrderWindow')(connectionId, windowId, 1, 0);

  // Grep-friendly: the workflow reads this to aim screencapture.
  print('WINDOW_ID=$windowId');
  print('holding for ${seconds}s so another process can look at it...');
  _sleepNanos(seconds * 1000000000);
  print('RESULT: held window $windowId for ${seconds}s.');
  _exitProcess(0);
}

Pointer<ObjCObject> _createAndFrontNSWindow(
    {Pointer<ObjCObject>? windowClass, int width = 800, int height = 600}) {
  final effectiveClass = windowClass ?? getClass('NSWindow');
  final allocated = effectiveClass.msgSend('alloc');
  final initSelector = sel('initWithContentRect:styleMask:backing:defer:');
  final invocation = _newInvocation(allocated, initSelector);
  final rect = calloc<NSRect>()
    ..ref.x = 140
    ..ref.y = 140
    ..ref.width = width.toDouble()
    ..ref.height = height.toDouble();
  final styleMask = calloc<Uint64>()
    ..value = NSWindowStyleMaskTitled |
        NSWindowStyleMaskClosable |
        NSWindowStyleMaskResizable;
  final backing = calloc<Uint64>()..value = NSBackingStoreBuffered;
  final deferCreation = calloc<Uint8>()..value = 0;
  _setArgument(invocation, rect.cast(), 2);
  _setArgument(invocation, styleMask.cast(), 3);
  _setArgument(invocation, backing.cast(), 4);
  _setArgument(invocation, deferCreation.cast(), 5);
  _invokeOnMain(invocation);
  final window = _returnedObject(invocation);
  if (window == nullptr) return nullptr;

  msgSendPerformOnMain(
      window,
      sel('performSelectorOnMainThread:withObject:waitUntilDone:'),
      sel('makeKeyAndOrderFront:'),
      nullptr,
      true);
  return window;
}

/// NSApplication MUST be born on the process main thread. Calling
/// +sharedApplication from the Dart thread makes AppKit attach the main event
/// queue to the wrong thread; later nextEventMatchingMask: then dies with
/// NSAssertMainEventQueueIsCurrentEventQueue / NSCrashOnBackgroundThreadMainEventQueue
/// (lldb on probe O). Always go through the parked main thread.
Pointer<ObjCObject> _sharedAppOnMain() {
  final inv =
      _newInvocation(getClass('NSApplication'), sel('sharedApplication'));
  _writeSentinel(inv);
  _invokeOnMain(inv);
  final app = _returnedObject(inv);
  if (_isSentinel(app) || app == nullptr) {
    _log('WARNING: sharedApplication on main returned ${app.address}');
  }
  return app;
}

Pointer<ObjCObject> _finishLaunchingOnMain() {
  final app = _sharedAppOnMain();
  if (app == nullptr || _isSentinel(app)) return nullptr;
  final policyInvocation = _newInvocation(app, sel('setActivationPolicy:'));
  final policy = calloc<Int64>()..value = NSApplicationActivationPolicyRegular;
  _setArgument(policyInvocation, policy.cast(), 2);
  _invokeOnMain(policyInvocation);
  _invokeOnMain(_newInvocation(app, sel('finishLaunching')));
  return app;
}

Future<void> probeHoldAppKitWindow(int seconds) async {
  ensureAppKitLoaded();
  if (!_parkMainThreadInRunLoop()) {
    _log('RESULT: could not park the main thread.');
    _exitProcess(1);
  }

  final app = _finishLaunchingOnMain();
  if (app == nullptr || _isSentinel(app)) {
    _log('RESULT: finishLaunching on main failed.');
    _exitProcess(1);
  }

  final window = _createAndFrontNSWindow();
  _log('NSWindow = ${window.address}');
  if (window == nullptr) {
    _log('RESULT: no window.');
    _exitProcess(1);
  }

  final numberInvocation = _newInvocation(window, sel('windowNumber'));
  _invokeOnMain(numberInvocation);
  _log('WINDOW_ID=${_returnedInt(numberInvocation)}');

  // Pump on a timer (probe K's mechanism) and count what comes out, so an
  // externally injected key press has somewhere to land.
  final pumpInvocation = _newPumpInvocation(app);
  final timerClass = getClass('NSTimer');
  final scheduleInvocation = _newInvocation(
      timerClass, sel('scheduledTimerWithTimeInterval:invocation:repeats:'));
  final interval = calloc<Double>()..value = 0.02;
  final invocationArgument = calloc<Pointer<ObjCObject>>()
    ..value = pumpInvocation;
  final repeats = calloc<Uint8>()..value = 1;
  _setArgument(scheduleInvocation, interval.cast(), 2);
  _setArgument(scheduleInvocation, invocationArgument.cast(), 3);
  _setArgument(scheduleInvocation, repeats.cast(), 4);
  _invokeOnMain(scheduleInvocation);
  _log('pump timer running; holding for ${seconds}s...');

  final seen = <int>{};
  for (var i = 0; i < seconds * 5; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 200));
    final event = _returnedObject(pumpInvocation);
    if (event != nullptr && !_isSentinel(event) && seen.add(event.address)) {
      _log('pumped an NSEvent: ${event.address}');
    }
  }

  _log('distinct events pumped: ${seen.length}');
  _log(seen.isEmpty
      ? 'RESULT: no events reached the queue in ${seconds}s.'
      : 'RESULT: ${seen.length} event(s) came through the pump.');
  _exitProcess(seen.isEmpty ? 1 : 0);
}

// ---------------------------------------------------------------------------
// Probe U - does the NSWindow itself crash, or only the pump?
//
// Probe O creates a window and immediately starts a repeating nextEvent pump,
// then dies with the same Trace/BPT trap as [NSApp run] (probe G). Bisect:
// hold the window with only a witness timer and the keep-alive source - no
// nextEventMatchingMask: at all. Survive => the pump is the killer. Crash =>
// the window (or makeKeyAndOrderFront:) cannot live on the hijacked thread.
// ---------------------------------------------------------------------------

Future<void> probeHoldAppKitNoPump(int seconds) async {
  ensureAppKitLoaded();
  if (!_parkMainThreadInRunLoop()) {
    _log('RESULT: could not park the main thread.');
    _exitProcess(1);
  }
  _log('main thread parked.');

  var ticks = 0;
  final witness = NativeCallable<_HandleValueNative>.listener(
      (Pointer<ObjCObject> self, Pointer<ObjCSel> cmd, int value) => ticks++);
  final className = 'DartUiHoldNoPumpWitness'.toNativeUtf8();
  final witnessClass =
      objc_allocateClassPair(getClass('NSObject'), className, 0);
  calloc.free(className);
  final types = 'v@:q'.toNativeUtf8();
  class_addMethod(
      witnessClass, sel('handleValue:'), witness.nativeFunction.cast(), types);
  calloc.free(types);
  objc_registerClassPair(witnessClass);
  final witnessObject = witnessClass.msgSend('alloc').msgSend('init');
  final witnessInvocation = _newInvocation(witnessObject, sel('handleValue:'));
  final value = calloc<Int64>()..value = 1;
  _setArgument(witnessInvocation, value.cast(), 2);
  witnessInvocation.msgSend('retainArguments');
  final schedule = _newInvocation(getClass('NSTimer'),
      sel('scheduledTimerWithTimeInterval:invocation:repeats:'));
  final interval = calloc<Double>()..value = 0.05;
  final target = calloc<Pointer<ObjCObject>>()..value = witnessInvocation;
  final repeats = calloc<Uint8>()..value = 1;
  _setArgument(schedule, interval.cast(), 2);
  _setArgument(schedule, target.cast(), 3);
  _setArgument(schedule, repeats.cast(), 4);
  _invokeOnMain(schedule);

  final app = _finishLaunchingOnMain();
  _log('finishLaunching on main done; app=${app.address} ticks so far=$ticks');

  final window = _createAndFrontNSWindow();
  _log('NSWindow = ${window.address}');
  if (window == nullptr) {
    _log('RESULT: no window.');
    _exitProcess(1);
  }
  final numberInvocation = _newInvocation(window, sel('windowNumber'));
  _invokeOnMain(numberInvocation);
  _log('WINDOW_ID=${_returnedInt(numberInvocation)}');
  _log('holding window with NO nextEvent pump for ${seconds}s...');

  for (var i = 0; i < seconds; i++) {
    await Future<void>.delayed(const Duration(seconds: 1));
    _log('t=${i + 1}s ticks=$ticks alive');
  }
  witness.close();

  _log(ticks > 0
      ? 'RESULT: NSWindow survived ${seconds}s without a pump ($ticks timer '
          'ticks). The Trace/BPT trap in probe O is the pump, not the window.'
      : 'RESULT: window path killed the run loop (0 ticks). The crash is not '
          'unique to nextEventMatchingMask:.');
  _exitProcess(ticks > 0 ? 0 : 1);
}

// kCGHIDEventTap = 0, kCGEventMouseMoved = 5.
void probePostInput() {
  final ok = probePostInputBody();
  if (!ok) {
    _log('RESULT: could not synthesize a keyboard event.');
    _exitProcess(1);
  }
  _log('RESULT: CGEventPost accepted synthetic input. Whether anything '
      'RECEIVES it is the holder process to answer - and on a runner without '
      'an Aqua session, or without accessibility permission, it will not.');
  _exitProcess(0);
}

// ---------------------------------------------------------------------------
// Probe P - close route C: pull input straight from the WindowServer.
//
// The export dump handed over the whole event API. AppKit has no privileged
// channel: it pulls events from the same CGS connection we already opened.
//   CGEventRef SLEventCreateNextEvent(CGSConnectionID cid);
// SLEvent* mirrors CGEvent* (there is an SLEventCreateKeyboardEvent next to
// CGEventCreateKeyboardEvent), so the returned object is inspectable with
// SLEventGetType / SLEventGetLocation.
// ---------------------------------------------------------------------------

// Current JankyBorders consumes this exact one-argument ABI, but only after the
// mach port returned by SLSGetEventPort signals. Our earlier allocator-first
// guess put nullptr in x0, so SkyLight read connection 0 and the result was not
// evidence about event delivery.
typedef _EventCreateNextNative = Pointer<Void> Function(Int32 cid);
typedef _EventGetTypeNative = Uint32 Function(Pointer<Void> event);

typedef _MachPortCallbackNative = Void Function(Pointer<Void> port,
    Pointer<Void> message, IntPtr size, Pointer<Void> context);
typedef _SlsNotifyCallbackNative = Void Function(
    Uint32 event, Pointer<Void> data, IntPtr size, Pointer<Void> context);

/// Installs the event port on the current thread's CFRunLoop and drains it only
/// when signalled. This mirrors JankyBorders' working sequence:
/// SLSGetEventPort -> CFMachPort -> CFRunLoopSource -> SLEventCreateNextEvent.
int _consumeSkyLightEventPort(
    DynamicLibrary skyLight, int connectionId, int seconds) {
  // These notification registrations are used by JankyBorders immediately
  // before it asks for the event port. AppKit/HIServices additionally
  // registers the process with flavor 3. Earlier probes tested each half in
  // isolation; keep both here so input can be routed before the first drain.
  var notifications = 0;
  final notifyCallback = NativeCallable<_SlsNotifyCallbackNative>.isolateLocal(
      (int event, Pointer<Void> data, int size, Pointer<Void> context) {
    notifications++;
  });
  final registerNotify = skyLight.lookupFunction<
      Int32 Function(Pointer<NativeFunction<_SlsNotifyCallbackNative>>, Uint32,
          Pointer<Void>),
      int Function(Pointer<NativeFunction<_SlsNotifyCallbackNative>>, int,
          Pointer<Void>)>('SLSRegisterNotifyProc');
  const notificationTypes = <int>[
    723,
    804,
    806,
    807,
    808,
    811,
    815,
    816,
    1322,
    1325,
    1326,
    1401,
    1508
  ];
  final registrationResults = <int>[];
  for (final eventType in notificationTypes) {
    registrationResults
        .add(registerNotify(notifyCallback.nativeFunction, eventType, nullptr));
  }
  _log('SLSRegisterNotifyProc x${notificationTypes.length} -> '
      '$registrationResults');

  final eventPortOut = calloc<Uint32>();
  final getEventPort = skyLight.lookupFunction<
      Int32 Function(Int32, Pointer<Uint32>),
      int Function(int, Pointer<Uint32>)>('SLSGetEventPort');
  final getEventPortRc = getEventPort(connectionId, eventPortOut);
  final eventPort = eventPortOut.value;
  calloc.free(eventPortOut);
  _log('SLSGetEventPort(cid=$connectionId) -> '
      'rc=$getEventPortRc port=$eventPort');
  if (getEventPortRc != 0 || eventPort == 0) return -1;

  final createNextEvent = skyLight.lookupFunction<_EventCreateNextNative,
      Pointer<Void> Function(int)>('SLEventCreateNextEvent');
  final getType =
      skyLight.lookupFunction<_EventGetTypeNative, int Function(Pointer<Void>)>(
          'SLEventGetType');
  final cfRelease = libCoreFoundation.lookupFunction<
      Void Function(Pointer<Void>), void Function(Pointer<Void>)>('CFRelease');

  var callbacks = 0;
  var received = 0;
  final sampledTypes = <int>[];
  final callback = NativeCallable<_MachPortCallbackNative>.isolateLocal(
      (Pointer<Void> port, Pointer<Void> message, int size,
          Pointer<Void> context) {
    callbacks++;
    _log('event-port callback #$callbacks: messageSize=$size; reading one');
    final pool = objc_autoreleasePoolPush();
    try {
      // One Mach message produced one readable event on macOS 14 arm64. Do not
      // probe for exhaustion here: unlike the JankyBorders host process, this
      // bare CGS client blocks on that extra read instead of returning null.
      final event = createNextEvent(connectionId);
      if (event != nullptr) {
        received++;
        if (sampledTypes.length < 64) sampledTypes.add(getType(event));
        cfRelease(event);
        _log('event-port callback #$callbacks: received event #$received');
      } else {
        _log('event-port callback #$callbacks: no event');
      }
    } finally {
      objc_autoreleasePoolPop(pool);
    }
  });

  final createMachPort = libCoreFoundation.lookupFunction<
      Pointer<Void> Function(
          Pointer<Void>,
          Uint32,
          Pointer<NativeFunction<_MachPortCallbackNative>>,
          Pointer<Void>,
          Pointer<Bool>),
      Pointer<Void> Function(
          Pointer<Void>,
          int,
          Pointer<NativeFunction<_MachPortCallbackNative>>,
          Pointer<Void>,
          Pointer<Bool>)>('CFMachPortCreateWithPort');
  final setMachPortOptions = libCoreFoundation.lookupFunction<
      Void Function(Pointer<Void>, Int32),
      void Function(Pointer<Void>, int)>('_CFMachPortSetOptions');
  final createSource = libCoreFoundation.lookupFunction<
      Pointer<Void> Function(Pointer<Void>, Pointer<Void>, IntPtr),
      Pointer<Void> Function(
          Pointer<Void>, Pointer<Void>, int)>('CFMachPortCreateRunLoopSource');
  final getCurrentRunLoop = libCoreFoundation.lookupFunction<
      Pointer<Void> Function(),
      Pointer<Void> Function()>('CFRunLoopGetCurrent');
  final addSource = libCoreFoundation.lookupFunction<
      Void Function(Pointer<Void>, Pointer<Void>, Pointer<Void>),
      void Function(
          Pointer<Void>, Pointer<Void>, Pointer<Void>)>('CFRunLoopAddSource');
  final runInMode = libCoreFoundation.lookupFunction<
      Int32 Function(Pointer<Void>, Double, Bool),
      int Function(Pointer<Void>, double, bool)>('CFRunLoopRunInMode');
  final defaultMode =
      libCoreFoundation.lookup<Pointer<Void>>('kCFRunLoopDefaultMode').value;

  final machPort = createMachPort(nullptr, eventPort, callback.nativeFunction,
      nullptr, nullptr.cast<Bool>());
  _log('CFMachPortCreateWithPort -> ${machPort.address}');
  if (machPort == nullptr) return -1;
  setMachPortOptions(machPort, 0x40);

  final source = createSource(nullptr, machPort, 0);
  final runLoop = getCurrentRunLoop();
  _log('CFMachPortCreateRunLoopSource -> ${source.address}; '
      'CFRunLoopGetCurrent -> ${runLoop.address}');
  if (source == nullptr || runLoop == nullptr) return -1;
  addSource(runLoop, source, defaultMode);

  // Seed the queue before the first source dispatch. Runs Z2-Z9 entered the
  // run loop first; its initial port signal then called into an empty queue and
  // SLEventCreateNextEvent waited in mach_msg forever. The one successful Y
  // run posted input before installing/pumping the consumer.
  probePostInputBody(skyLight: skyLight);

  // Pump synchronously in bounded slices on the same OS thread/run loop where
  // the isolateLocal callback was created. No await is allowed in this loop:
  // resuming the isolate on another worker would pump a different CFRunLoop.
  for (var i = 0; i < seconds * 20; i++) {
    if (i == 1 || (i > 1 && i % 40 == 0)) {
      probePostInputBody(skyLight: skyLight);
    }
    runInMode(defaultMode, 0.05, true);
  }
  _log('event-port summary: callbacks=$callbacks events=$received '
      'notifications=$notifications sampledTypes=$sampledTypes');
  return received;
}

Future<void> probeSkyLightEvents(int seconds) async {
  final skyLight = DynamicLibrary.open(
      '/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight');
  final connectionId =
      skyLight.lookupFunction<Int32 Function(), int Function()>(
          'SLSMainConnectionID')();
  print('SLSMainConnectionID() = $connectionId '
      '(pthread_main_np() = ${pthread_main_np()})');

  // AppKit/HIServices registers the process before creating its first window.
  // Doing this inside the consumer was too late and alternated between 0 and
  // paramErr (-50), with event delivery present only in successful runs.
  // Registration is not reliably idempotent on the first try: the macOS 14
  // disassembly shows SLPSRegisterWithServer asking LaunchServices for this
  // process (_LSASNCreateWithPid, _LSCopyApplicationInformationItem) and
  // returning paramErr when the answer is not ready. Retry instead of
  // treating a flaky -50 as a route failure.
  final registerWithServer =
      skyLight.lookupFunction<Int32 Function(Int32), int Function(int)>(
          'SLPSRegisterWithServer');
  var processRegistrationRc = -50;
  for (var attempt = 1; attempt <= 12; attempt++) {
    processRegistrationRc = registerWithServer(3);
    _log('SLPSRegisterWithServer(flavor=3, before window) attempt $attempt -> '
        '$processRegistrationRc');
    if (processRegistrationRc == 0) break;
    sleep(const Duration(milliseconds: 150));
  }

  // A window gives the WindowServer somewhere to aim events.
  final rect = calloc<NSRect>()
    ..ref.x = 200
    ..ref.y = 200
    ..ref.width = 480
    ..ref.height = 320;
  final regionSlot = calloc<Pointer<Void>>();
  skyLight.lookupFunction<
      _NewRegionWithRectNative,
      int Function(Pointer<NSRect>,
          Pointer<Pointer<Void>>)>('CGSNewRegionWithRect')(rect, regionSlot);
  final windowIdSlot = calloc<Uint32>();
  skyLight.lookupFunction<
          _SlsNewWindowNative,
          int Function(int, int, double, double, Pointer<Void>,
              Pointer<Uint32>)>('SLSNewWindow')(connectionId,
      kCGSBackingStoreBuffered, 200.0, 200.0, regionSlot.value, windowIdSlot);
  final windowId = windowIdSlot.value;
  final context = skyLight.lookupFunction<_WindowContextCreateNative,
          Pointer<Void> Function(int, int, Pointer<Void>)>(
      'SLWindowContextCreate')(connectionId, windowId, nullptr);
  if (context != nullptr) {
    final coreGraphics = DynamicLibrary.open(
        '/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics');
    final fill = calloc<NSRect>()
      ..ref.width = 480
      ..ref.height = 320;
    coreGraphics.lookupFunction<
        _SetRgbFillColorNative,
        void Function(Pointer<Void>, double, double, double,
            double)>('CGContextSetRGBFillColor')(context, 0.9, 0.3, 0.1, 1.0);
    coreGraphics
        .lookupFunction<_FillRectNative, void Function(Pointer<Void>, NSRect)>(
            'CGContextFillRect')(context, fill.ref);
    coreGraphics.lookupFunction<_ContextFlushNative,
        void Function(Pointer<Void>)>('CGContextFlush')(context);
  }
  skyLight
      .lookupFunction<_SlsOrderWindowNative, int Function(int, int, int, int)>(
          'SLSOrderWindow')(connectionId, windowId, 1, 0);
  print('WINDOW_ID=$windowId');

  final received = _consumeSkyLightEventPort(skyLight, connectionId, seconds);

  print('events received: $received');
  print(received > 0
      ? 'RESULT: input arrives straight from the WindowServer, off the main '
          'thread, with no AppKit. Route C is complete: window, pixels and '
          'input in pure Dart FFI.'
      : 'RESULT: the event port delivered no events (count=$received). Test '
          'foreground/PSN registration only after confirming the port callback '
          'was installed and signalled.');
  _exitProcess(received > 0 ? 0 : 1);
}

// ---------------------------------------------------------------------------
// Probe L - probe K without the ambiguities, per doc/propostas/03.
//
// K was inconclusive on two counts. Its pump timer used repeats:YES, and an
// NSInvocation keeps only the LAST return value, so a later firing that found
// an empty queue would overwrite an earlier one that got the event. And a
// return buffer that was never written is indistinguishable from one written
// with nil.
//
// Fixes: post the event before scheduling, one-shot timers, a sentinel written
// into the return buffer up front, a harmless marker timer scheduled ahead of
// the pump, and the real NSDefaultRunLoopMode global instead of a string built
// by hand. The workflow samples the main thread's stack while this runs.
//
//   0x1        -> the invocation never completed
//   0x0        -> it completed and returned nil
//   event ptr  -> the synthetic event came back
// ---------------------------------------------------------------------------

// A real NSObject, never 0x1: writing a fake pointer as the return value made
// NSInvocation / the runtime message address 1 (CI: SEGV si_addr=0x1 on K/F).
Pointer<ObjCObject>? _sentinelObject;

Pointer<ObjCObject> _completionSentinel() {
  final existing = _sentinelObject;
  if (existing != null) return existing;
  final obj = getClass('NSObject').msgSend('alloc').msgSend('init');
  // Keep it alive for the whole process; probes compare by address.
  obj.msgSend('retain');
  _sentinelObject = obj;
  return obj;
}

void _writeSentinel(Pointer<ObjCObject> invocation) {
  final sentinel = calloc<Pointer<ObjCObject>>()..value = _completionSentinel();
  msgSendVoidPointer(invocation, sel('setReturnValue:'), sentinel.cast());
  calloc.free(sentinel);
}

bool _isSentinel(Pointer<ObjCObject> value) =>
    value == _completionSentinel() || value.address == 1;

void _scheduleOneShot(Pointer<ObjCObject> invocation, double delaySeconds,
    {bool wait = false}) {
  // Default wait:false - after an NSEvent is posted, AppKit may busy the main
  // run loop; waitUntilDone:YES then deadlocks the Dart thread (CI hung K
  // right after "posted event" with no further log line).
  final schedule = _newInvocation(getClass('NSTimer'),
      sel('scheduledTimerWithTimeInterval:invocation:repeats:'));
  final interval = calloc<Double>()..value = delaySeconds;
  final target = calloc<Pointer<ObjCObject>>()..value = invocation;
  final repeats = calloc<Uint8>()..value = 0; // one-shot
  _setArgument(schedule, interval.cast(), 2);
  _setArgument(schedule, target.cast(), 3);
  _setArgument(schedule, repeats.cast(), 4);
  _invokeOnMain(schedule, wait: wait);
}

Future<void> probePumpTimerDiagnostic() async {
  ensureAppKitLoaded();
  if (!_parkMainThreadInRunLoop()) {
    _log('RESULT: could not park the main thread.');
    _exitProcess(1);
  }
  _log('main thread parked, main queue draining.');

  final app = _finishLaunchingOnMain();
  if (app == nullptr || _isSentinel(app)) {
    _log('RESULT: finishLaunching on main failed.');
    _exitProcess(1);
  }
  _log('[NSApp finishLaunching] on main; app=${app.address}');

  // 1. Post first, so the queue is already non-empty when the pump fires.
  final posted = _newSyntheticAppEvent();
  _postEventOnMain(app, posted);
  _log('posted event ${posted.address} BEFORE scheduling anything.');

  // 2. Marker: a harmless +[NSDate date] at 20ms. If its sentinel survives,
  //    the problem is the timer or the run loop mode, not the pump.
  final markerInvocation = _newInvocation(getClass('NSDate'), sel('date'));
  _writeSentinel(markerInvocation);
  _scheduleOneShot(markerInvocation, 0.02);
  _log('marker scheduled at 20ms.');

  // 3. The pump at 100ms, with the REAL NSDefaultRunLoopMode global.
  _log('NSDefaultRunLoopMode global = ${_nsDefaultRunLoopMode().address}');
  final pumpInvocation = _newPumpInvocation(app);
  _writeSentinel(pumpInvocation);
  _scheduleOneShot(pumpInvocation, 0.1);
  _log('marker at 20ms and pump at 100ms scheduled, both one-shot.');

  await Future<void>.delayed(const Duration(seconds: 3));

  final marker = _returnedObject(markerInvocation);
  final pumped = _returnedObject(pumpInvocation);
  final sentinelAddr = _completionSentinel().address;
  String describe(Pointer<ObjCObject> value) {
    if (_isSentinel(value)) return 'SENTINEL (never completed)';
    if (value == nullptr) return 'nil';
    return '0x${value.address.toRadixString(16)}';
  }

  _log('completion sentinel object = $sentinelAddr');
  _log('marker returned: ${describe(marker)}');
  _log('pump returned:   ${describe(pumped)}');

  if (_isSentinel(marker)) {
    _log('RESULT: the marker never ran either - one-shot timers are not '
        'delivered on the parked run loop at all. The problem is the run loop, '
        'not nextEventMatchingMask:.');
    _exitProcess(1);
  }
  if (_isSentinel(pumped)) {
    _log('RESULT: the marker ran but the pump did not complete - '
        'nextEventMatchingMask: blocked. Check the stack sample for '
        '_DPSNextEvent / mach_msg.');
    _exitProcess(1);
  }
  if (pumped == posted) {
    _log('RESULT: the synthetic event came back through a timer-driven pump. '
        'Event dispatch works on the parked main thread.');
    _exitProcess(0);
  }
  _log('RESULT: timers fire and the pump completed, returning '
      '${describe(pumped)} instead of our event.');
  _exitProcess(1);
}

// ---------------------------------------------------------------------------
// Probe Q - register as a foreground application, then ask for events again.
//
// Probe P got zero events because the WindowServer routes input to the FRONT
// PROCESS, identified by PSN, and ours never registered as one. The export dump
// has the whole layer: SLPSGetCurrentProcess, SLPSEnableForegroundOperation
// (the modern name of the classic CPSEnableForegroundOperation trick that turns
// a CLI process into a real foreground app), SLPSSetFrontProcess and
// SLPSStealKeyFocus.
//
// Every signature here is a guess against private API, so each call prints
// immediately after it returns: if one of them crashes, the log says which.
// ---------------------------------------------------------------------------

final class ProcessSerialNumber extends Struct {
  @Uint32()
  external int high;
  @Uint32()
  external int low;
}

typedef _PsnOnlyNative = Int32 Function(Pointer<ProcessSerialNumber> psn);
typedef _EnableForegroundNative = Int32 Function(
    Pointer<ProcessSerialNumber> psn, Uint32 a, Uint32 b, Uint32 c, Uint32 d);

Future<void> probeSkyLightForeground(int seconds) async {
  final skyLight = DynamicLibrary.open(
      '/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight');
  final connectionId =
      skyLight.lookupFunction<Int32 Function(), int Function()>(
          'SLSMainConnectionID')();
  print('SLSMainConnectionID() = $connectionId');

  final psn = calloc<ProcessSerialNumber>();
  final getCurrentProcess = skyLight.lookupFunction<_PsnOnlyNative,
      int Function(Pointer<ProcessSerialNumber>)>('SLPSGetCurrentProcess');
  print('SLPSGetCurrentProcess -> ${getCurrentProcess(psn)} '
      'psn=(${psn.ref.high}, ${psn.ref.low})');

  // The magic arguments are the ones the CPS-era snippets have used for two
  // decades; there is no header to check them against.
  final enableForeground = skyLight.lookupFunction<
      _EnableForegroundNative,
      int Function(Pointer<ProcessSerialNumber>, int, int, int,
          int)>('SLPSEnableForegroundOperation');
  print('SLPSEnableForegroundOperation -> '
      '${enableForeground(psn, 0x03, 0x3C, 0x2C, 0x1103)}');

  final setFrontProcess = skyLight.lookupFunction<_PsnOnlyNative,
      int Function(Pointer<ProcessSerialNumber>)>('SLPSSetFrontProcess');
  print('SLPSSetFrontProcess -> ${setFrontProcess(psn)}');

  final rect = calloc<NSRect>()
    ..ref.x = 260
    ..ref.y = 260
    ..ref.width = 480
    ..ref.height = 320;
  final regionSlot = calloc<Pointer<Void>>();
  skyLight.lookupFunction<
      _NewRegionWithRectNative,
      int Function(Pointer<NSRect>,
          Pointer<Pointer<Void>>)>('CGSNewRegionWithRect')(rect, regionSlot);
  final windowIdSlot = calloc<Uint32>();
  skyLight.lookupFunction<
          _SlsNewWindowNative,
          int Function(int, int, double, double, Pointer<Void>,
              Pointer<Uint32>)>('SLSNewWindow')(connectionId,
      kCGSBackingStoreBuffered, 260.0, 260.0, regionSlot.value, windowIdSlot);
  final windowId = windowIdSlot.value;
  final context = skyLight.lookupFunction<_WindowContextCreateNative,
          Pointer<Void> Function(int, int, Pointer<Void>)>(
      'SLWindowContextCreate')(connectionId, windowId, nullptr);
  if (context != nullptr) {
    final coreGraphics = DynamicLibrary.open(
        '/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics');
    final fill = calloc<NSRect>()
      ..ref.width = 480
      ..ref.height = 320;
    coreGraphics.lookupFunction<
        _SetRgbFillColorNative,
        void Function(Pointer<Void>, double, double, double,
            double)>('CGContextSetRGBFillColor')(context, 0.2, 0.8, 0.3, 1.0);
    coreGraphics
        .lookupFunction<_FillRectNative, void Function(Pointer<Void>, NSRect)>(
            'CGContextFillRect')(context, fill.ref);
    coreGraphics.lookupFunction<_ContextFlushNative,
        void Function(Pointer<Void>)>('CGContextFlush')(context);
  }
  skyLight
      .lookupFunction<_SlsOrderWindowNative, int Function(int, int, int, int)>(
          'SLSOrderWindow')(connectionId, windowId, 1, 0);
  print('WINDOW_ID=$windowId');

  final stealKeyFocus = skyLight.lookupFunction<_PsnOnlyNative,
      int Function(Pointer<ProcessSerialNumber>)>('SLPSStealKeyFocus');
  print('SLPSStealKeyFocus -> ${stealKeyFocus(psn)}');

  print(
      'registered as foreground; consuming the event port for ${seconds}s...');
  final received = _consumeSkyLightEventPort(skyLight, connectionId, seconds);

  print('events received: $received');
  print(received > 0
      ? 'RESULT: registering as a foreground process opened the input path. '
          'Route C is complete in pure Dart FFI: window, pixels and input.'
      : 'RESULT: still no events after foreground registration. Either one of '
          'the guessed signatures is a no-op, or delivery needs more of the '
          'PSN handshake (SLPSRegisterWithServer, '
          'SLPSSetMainApplicationConnection).');
  _exitProcess(received > 0 ? 0 : 1);
}

// ---------------------------------------------------------------------------
// Probe X - TransformProcessType, the PUBLIC way to become a foreground app.
//
// Probe Q guessed private SLPS* signatures and got success codes with zero
// events. TransformProcessType / GetCurrentProcess are documented HIServices
// APIs (ApplicationServices) that Carbon/Cocoa apps have used for decades to
// turn a bg CLI into a real UI process. If this still yields zero events, the
// blocker is deeper than "not frontmost" (bundle / LaunchServices / event
// port registration).
// ---------------------------------------------------------------------------

const kProcessTransformToForegroundApplication = 1;

Future<void> probeTransformProcess(int seconds) async {
  // HIServices lives inside ApplicationServices on modern macOS.
  DynamicLibrary hiServices;
  try {
    hiServices = DynamicLibrary.open(
        '/System/Library/Frameworks/ApplicationServices.framework/'
        'Frameworks/HIServices.framework/HIServices');
  } catch (_) {
    hiServices = DynamicLibrary.open(
        '/System/Library/Frameworks/ApplicationServices.framework/'
        'ApplicationServices');
  }

  final getCurrentProcess = hiServices.lookupFunction<
      Int32 Function(Pointer<ProcessSerialNumber>),
      int Function(Pointer<ProcessSerialNumber>)>('GetCurrentProcess');
  final transformProcessType = hiServices.lookupFunction<
      Int32 Function(Pointer<ProcessSerialNumber>, Int32),
      int Function(Pointer<ProcessSerialNumber>, int)>('TransformProcessType');
  final setFrontProcess = hiServices.lookupFunction<
      Int32 Function(Pointer<ProcessSerialNumber>),
      int Function(Pointer<ProcessSerialNumber>)>('SetFrontProcess');

  final psn = calloc<ProcessSerialNumber>();
  final getRc = getCurrentProcess(psn);
  _log('GetCurrentProcess -> $getRc psn=(${psn.ref.high}, ${psn.ref.low})');
  final transformRc =
      transformProcessType(psn, kProcessTransformToForegroundApplication);
  _log('TransformProcessType(ForegroundApplication) -> $transformRc');
  final frontRc = setFrontProcess(psn);
  _log('SetFrontProcess -> $frontRc');

  final skyLight = DynamicLibrary.open(
      '/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight');
  final connectionId =
      skyLight.lookupFunction<Int32 Function(), int Function()>(
          'SLSMainConnectionID')();
  _log('SLSMainConnectionID() = $connectionId');

  final rect = calloc<NSRect>()
    ..ref.x = 300
    ..ref.y = 300
    ..ref.width = 480
    ..ref.height = 320;
  final regionSlot = calloc<Pointer<Void>>();
  skyLight.lookupFunction<
      _NewRegionWithRectNative,
      int Function(Pointer<NSRect>,
          Pointer<Pointer<Void>>)>('CGSNewRegionWithRect')(rect, regionSlot);
  final windowIdSlot = calloc<Uint32>();
  skyLight.lookupFunction<
          _SlsNewWindowNative,
          int Function(int, int, double, double, Pointer<Void>,
              Pointer<Uint32>)>('SLSNewWindow')(connectionId,
      kCGSBackingStoreBuffered, 300.0, 300.0, regionSlot.value, windowIdSlot);
  final windowId = windowIdSlot.value;
  final context = skyLight.lookupFunction<_WindowContextCreateNative,
          Pointer<Void> Function(int, int, Pointer<Void>)>(
      'SLWindowContextCreate')(connectionId, windowId, nullptr);
  if (context != nullptr) {
    final coreGraphics = DynamicLibrary.open(
        '/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics');
    final fill = calloc<NSRect>()
      ..ref.width = 480
      ..ref.height = 320;
    coreGraphics.lookupFunction<
        _SetRgbFillColorNative,
        void Function(Pointer<Void>, double, double, double,
            double)>('CGContextSetRGBFillColor')(context, 0.8, 0.2, 0.8, 1.0);
    coreGraphics
        .lookupFunction<_FillRectNative, void Function(Pointer<Void>, NSRect)>(
            'CGContextFillRect')(context, fill.ref);
    coreGraphics.lookupFunction<_ContextFlushNative,
        void Function(Pointer<Void>)>('CGContextFlush')(context);
  }
  skyLight
      .lookupFunction<_SlsOrderWindowNative, int Function(int, int, int, int)>(
          'SLSOrderWindow')(connectionId, windowId, 1, 0);
  _log('WINDOW_ID=$windowId');

  final received = _consumeSkyLightEventPort(skyLight, connectionId, seconds);

  _log('events received: $received');
  _log(received > 0
      ? 'RESULT: TransformProcessType opened the input path. Route C has '
          'window, pixels and input via public process APIs + private '
          'SkyLight drawing/events.'
      : 'RESULT: still no events after TransformProcessType '
          '(get=$getRc transform=$transformRc front=$frontRc). Foreground '
          'status alone is not enough - need event-port / bundle registration.');
  _exitProcess(received > 0 ? 0 : 1);
}

/// Body of post-input without _exit, so other probes can inject from inside.
/// Returns false if the keyboard event could not be created.
bool probePostInputBody({DynamicLibrary? skyLight}) {
  final coreGraphics = DynamicLibrary.open(
      '/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics');

  final createKeyboardEvent = coreGraphics.lookupFunction<
      Pointer<Void> Function(Pointer<Void>, Uint16, Bool),
      Pointer<Void> Function(
          Pointer<Void>, int, bool)>('CGEventCreateKeyboardEvent');
  final createMouseEvent = coreGraphics.lookupFunction<
      Pointer<Void> Function(Pointer<Void>, Uint32, NSPoint, Uint32),
      Pointer<Void> Function(
          Pointer<Void>, int, NSPoint, int)>('CGEventCreateMouseEvent');
  final post = coreGraphics.lookupFunction<Void Function(Uint32, Pointer<Void>),
      void Function(int, Pointer<Void>)>('CGEventPost');
  final postToPid = skyLight?.lookupFunction<
      Void Function(Int32, Pointer<Void>),
      void Function(int, Pointer<Void>)>('SLEventPostToPid');
  final cfRelease = libCoreFoundation.lookupFunction<
      Void Function(Pointer<Void>), void Function(Pointer<Void>)>('CFRelease');

  final down = createKeyboardEvent(nullptr, 0, true);
  final up = createKeyboardEvent(nullptr, 0, false);
  _log('CGEventCreateKeyboardEvent -> down ${down.address}, up ${up.address}');
  if (down == nullptr) {
    if (up != nullptr) cfRelease(up);
    return false;
  }
  if (postToPid != null) {
    final pid = getpid();
    postToPid(pid, down);
    if (up != nullptr) postToPid(pid, up);
    _log('SLEventPostToPid(pid=$pid): key down/up for keycode 0.');
  } else {
    post(0, down);
    if (up != nullptr) post(0, up);
    _log('CGEventPost: key down/up for keycode 0.');
  }
  cfRelease(down);
  if (up != nullptr) cfRelease(up);

  final point = calloc<NSPoint>()
    ..ref.x = 400
    ..ref.y = 400;
  final move = createMouseEvent(nullptr, 5, point.ref, 0);
  _log('CGEventCreateMouseEvent -> ${move.address}');
  if (move != nullptr) {
    if (postToPid != null) {
      postToPid(getpid(), move);
      _log('SLEventPostToPid: mouse move to (400, 400).');
    } else {
      post(0, move);
      _log('CGEventPost: mouse move to (400, 400).');
    }
    cfRelease(move);
  }
  calloc.free(point);
  return true;
}

// ---------------------------------------------------------------------------
// Probe Y - full PSN/event-port handshake from the 2016 SkyLight nm dump
// (referencias/skylight.txt = gist erica/skylight). The interesting symbols
// are still T-exported on modern macOS:
//
//   SLPSRegisterWithServer          - register this process with WindowServer
//   SLPSSetMainApplicationConnection - bind our CGS connection as the app's
//   SLSGetEventPort                 - mach port the event stream arrives on
//
// Q/X proved foreground alone is not enough. This is the missing middle of
// the classic CPS/CGS app bring-up that AppKit does inside finishLaunching.
// ---------------------------------------------------------------------------

Future<void> probeSkyLightRegister(int seconds) async {
  final skyLight = DynamicLibrary.open(
      '/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight');

  final connectionId =
      skyLight.lookupFunction<Int32 Function(), int Function()>(
          'SLSMainConnectionID')();
  _log('SLSMainConnectionID() = $connectionId');

  // SLSGetEventPort: two crashes proved `port = f(cid)` dereferences cid
  // (si_addr == cid). So the ABI is out-parameter style:
  //   CGError SLSGetEventPort(CGSConnectionID cid, mach_port_t *out);
  final eventPortOut = calloc<Uint32>();
  _log('calling SLSGetEventPort(cid=$connectionId, &out)...');
  final getEventPortRc = skyLight.lookupFunction<
      Int32 Function(Int32, Pointer<Uint32>),
      int Function(
          int, Pointer<Uint32>)>('SLSGetEventPort')(connectionId, eventPortOut);
  final eventPort = eventPortOut.value;
  _log('SLSGetEventPort -> rc=$getEventPortRc port=$eventPort');

  // ABI lesson from run 31150976455: SLPSSetMainApplicationConnection(cid, 0)
  // returned -600 (procNotFoundErr). Every other SLPS/CPS function in the
  // ecosystem (CGSInternal, yabai) takes a ProcessSerialNumber* - the cid was
  // being reinterpreted as a bogus PSN pointer. Try the PSN-pointer ABI first.
  final psn = calloc<ProcessSerialNumber>();
  skyLight.lookupFunction<_PsnOnlyNative,
      int Function(Pointer<ProcessSerialNumber>)>('SLPSGetCurrentProcess')(psn);
  _log('PSN = (${psn.ref.high}, ${psn.ref.low})');

  final registerWithServer = skyLight.lookupFunction<
      Int32 Function(Pointer<ProcessSerialNumber>),
      int Function(Pointer<ProcessSerialNumber>)>('SLPSRegisterWithServer');
  final setMain = skyLight.lookupFunction<
      Int32 Function(Pointer<ProcessSerialNumber>, Int32),
      int Function(Pointer<ProcessSerialNumber>,
          int)>('SLPSSetMainApplicationConnection');

  _log('calling SLPSRegisterWithServer(psn)...');
  final regRc = registerWithServer(psn);
  _log('SLPSRegisterWithServer(psn) -> $regRc');

  // Bind our CGS connection as the process's main application connection so
  // the WindowServer routes input to it.
  _log('calling SLPSSetMainApplicationConnection(psn, cid=$connectionId)...');
  final mainRc = setMain(psn, connectionId);
  _log('SLPSSetMainApplicationConnection(psn, cid) -> $mainRc');

  // Fallback: the numeric variants from the previous run, in case the PSN
  // ABI is wrong on both (they must be -600/0 to confirm the pointer ABI).
  if (mainRc != 0) {
    final setMainNumeric = skyLight.lookupFunction<Int32 Function(Int32, Int32),
        int Function(int, int)>('SLPSSetMainApplicationConnection');
    final numericRc = setMainNumeric(connectionId, 0);
    _log('SLPSSetMainApplicationConnection(cid, 0) -> $numericRc (retry)');
    if (numericRc != 0) {
      final registerNumeric =
          skyLight.lookupFunction<Int32 Function(Uint32), int Function(int)>(
              'SLPSRegisterWithServer');
      if (getEventPortRc == 0 && eventPort != 0) {
        final regNumericRc = registerNumeric(eventPort);
        _log('SLPSRegisterWithServer(eventPort=$eventPort) -> $regNumericRc '
            '(retry)');
      }
    }
  }

  // Public foreground transform on top of the private registration.
  try {
    final hi = DynamicLibrary.open(
        '/System/Library/Frameworks/ApplicationServices.framework/'
        'Frameworks/HIServices.framework/HIServices');
    final psn = calloc<ProcessSerialNumber>();
    final getRc = hi.lookupFunction<
        Int32 Function(Pointer<ProcessSerialNumber>),
        int Function(Pointer<ProcessSerialNumber>)>('GetCurrentProcess')(psn);
    final transformRc = hi.lookupFunction<
            Int32 Function(Pointer<ProcessSerialNumber>, Int32),
            int Function(Pointer<ProcessSerialNumber>, int)>(
        'TransformProcessType')(psn, kProcessTransformToForegroundApplication);
    final frontRc = hi.lookupFunction<
        Int32 Function(Pointer<ProcessSerialNumber>),
        int Function(Pointer<ProcessSerialNumber>)>('SetFrontProcess')(psn);
    _log('GetCurrentProcess=$getRc Transform=$transformRc Front=$frontRc '
        'psn=(${psn.ref.high},${psn.ref.low})');
  } catch (e) {
    _log('HIServices foreground path failed: $e');
  }

  // Also the private front/focus path that Q already measured as "success, no
  // events" - cheap to re-run after real registration.
  final psn2 = calloc<ProcessSerialNumber>();
  skyLight.lookupFunction<
      _PsnOnlyNative,
      int Function(
          Pointer<ProcessSerialNumber>)>('SLPSGetCurrentProcess')(psn2);
  final enableFg = skyLight.lookupFunction<
      _EnableForegroundNative,
      int Function(Pointer<ProcessSerialNumber>, int, int, int,
          int)>('SLPSEnableForegroundOperation');
  _log('SLPSEnableForegroundOperation -> '
      '${enableFg(psn2, 0x03, 0x3C, 0x2C, 0x1103)}');
  _log(
      'SLPSSetFrontProcess -> ${skyLight.lookupFunction<_PsnOnlyNative, int Function(Pointer<ProcessSerialNumber>)>('SLPSSetFrontProcess')(psn2)}');
  _log(
      'SLPSStealKeyFocus -> ${skyLight.lookupFunction<_PsnOnlyNative, int Function(Pointer<ProcessSerialNumber>)>('SLPSStealKeyFocus')(psn2)}');

  // Visible window so the server has a target.
  final rect = calloc<NSRect>()
    ..ref.x = 320
    ..ref.y = 320
    ..ref.width = 480
    ..ref.height = 320;
  final regionSlot = calloc<Pointer<Void>>();
  skyLight.lookupFunction<
      _NewRegionWithRectNative,
      int Function(Pointer<NSRect>,
          Pointer<Pointer<Void>>)>('CGSNewRegionWithRect')(rect, regionSlot);
  final windowIdSlot = calloc<Uint32>();
  skyLight.lookupFunction<
          _SlsNewWindowNative,
          int Function(int, int, double, double, Pointer<Void>,
              Pointer<Uint32>)>('SLSNewWindow')(connectionId,
      kCGSBackingStoreBuffered, 320.0, 320.0, regionSlot.value, windowIdSlot);
  final windowId = windowIdSlot.value;
  final context = skyLight.lookupFunction<_WindowContextCreateNative,
          Pointer<Void> Function(int, int, Pointer<Void>)>(
      'SLWindowContextCreate')(connectionId, windowId, nullptr);
  if (context != nullptr) {
    final coreGraphics = DynamicLibrary.open(
        '/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics');
    final fill = calloc<NSRect>()
      ..ref.width = 480
      ..ref.height = 320;
    coreGraphics.lookupFunction<
        _SetRgbFillColorNative,
        void Function(Pointer<Void>, double, double, double,
            double)>('CGContextSetRGBFillColor')(context, 0.1, 0.7, 0.9, 1.0);
    coreGraphics
        .lookupFunction<_FillRectNative, void Function(Pointer<Void>, NSRect)>(
            'CGContextFillRect')(context, fill.ref);
    coreGraphics.lookupFunction<_ContextFlushNative,
        void Function(Pointer<Void>)>('CGContextFlush')(context);
  }
  skyLight
      .lookupFunction<_SlsOrderWindowNative, int Function(int, int, int, int)>(
          'SLSOrderWindow')(connectionId, windowId, 1, 0);
  _log('WINDOW_ID=$windowId');

  probePostInputBody();

  _log('handshake done (reg=$regRc main=$mainRc port=$eventPort); '
      'consuming the event port for ${seconds}s...');
  final received = _consumeSkyLightEventPort(skyLight, connectionId, seconds);

  _log('events received: $received');
  _log(received > 0
      ? 'RESULT: full handshake opened input. Route C is complete: window, '
          'pixels and events via pure Dart FFI + private SkyLight.'
      : 'RESULT: still 0 events after RegisterWithServer+SetMainApplication'
          'Connection (reg=$regRc main=$mainRc port=$eventPort). Either the '
          'signatures are still wrong, or a .app bundle / LaunchServices '
          'registration is mandatory.');
  _exitProcess(received > 0 ? 0 : 1);
}

// ---------------------------------------------------------------------------
// Probe R - the fix the stack sample pointed at.
//
// sample(1) caught the main thread with 612 of 612 samples inside
// Dart_RunLoop -> pthread_cond_wait. It was never parked in CFRunLoopRun at
// all: the handler's CFRunLoopRun drained what was pending, found no persistent
// source to keep it alive, returned kCFRunLoopRunFinished, and the VM took the
// thread back. Everything else follows - D and E worked inside that brief
// window, F/K/L came after it closed.
//
// CFRunLoopRun only returns when the loop has no sources or timers at all. So
// add an unsignalled version-0 source first: it never fires, it just keeps the
// loop from finishing. CFRunLoopAddSource is thread-safe, so this can be done
// from the Dart thread before the signal.
// ---------------------------------------------------------------------------

// {version, info, retain, release, copyDescription, equal, hash, schedule,
// cancel, perform} - all zero, since the source is never signalled.
final class CFRunLoopSourceContext extends Struct {
  @Int64()
  external int version;
  external Pointer<Void> info;
  external Pointer<Void> retain;
  external Pointer<Void> release;
  external Pointer<Void> copyDescription;
  external Pointer<Void> equal;
  external Pointer<Void> hash;
  external Pointer<Void> schedule;
  external Pointer<Void> cancel;
  external Pointer<Void> perform;
}

bool _keepMainRunLoopAlive() {
  final getMain = libCoreFoundation.lookupFunction<Pointer<Void> Function(),
      Pointer<Void> Function()>('CFRunLoopGetMain');
  final sourceCreate = libCoreFoundation.lookupFunction<
      Pointer<Void> Function(
          Pointer<Void>, Int64, Pointer<CFRunLoopSourceContext>),
      Pointer<Void> Function(Pointer<Void>, int,
          Pointer<CFRunLoopSourceContext>)>('CFRunLoopSourceCreate');
  final addSource = libCoreFoundation.lookupFunction<
      Void Function(Pointer<Void>, Pointer<Void>, Pointer<Void>),
      void Function(
          Pointer<Void>, Pointer<Void>, Pointer<Void>)>('CFRunLoopAddSource');
  final defaultMode =
      libCoreFoundation.lookup<Pointer<Void>>('kCFRunLoopDefaultMode').value;

  final context = calloc<CFRunLoopSourceContext>();
  final source = sourceCreate(nullptr, 0, context);
  calloc.free(context);
  print('CFRunLoopSourceCreate -> ${source.address}');
  if (source == nullptr) return false;

  final mainRunLoop = getMain();
  print('CFRunLoopGetMain -> ${mainRunLoop.address}, '
      'kCFRunLoopDefaultMode -> ${defaultMode.address}');
  addSource(mainRunLoop, source, defaultMode);
  _hijackedMainRunLoop = mainRunLoop;
  _mainRunLoopKeepAliveSource = source;
  _mainRunLoopDefaultMode = defaultMode;
  return true;
}

// ---------------------------------------------------------------------------
// Probe S - can the signal backend unwind instead of calling _exit?
//
// CFRunLoopStop is thread-safe. Removing the synthetic keep-alive source,
// stopping and waking the main loop should make CFRunLoopRun return from the
// signal handler to the VM launcher frame it interrupted. The process then
// exits through normal Dart shutdown. LLDB's step-out capture verifies the
// otherwise invisible return boundary.
// ---------------------------------------------------------------------------

Future<void> probeGracefulHijackShutdown() async {
  ensureAppKitLoaded();
  if (!_parkMainThreadInRunLoop()) {
    throw StateError('could not park the process main thread');
  }
  _log('graceful shutdown: main queue is draining');

  final beforeStop = dispatch_semaphore_create(0);
  dispatch_async_f(
    dispatch_get_main_queue(),
    beforeStop,
    dispatch_semaphore_signal_ptr,
  );
  const oneSecond = 1000000000;
  if (dispatch_semaphore_wait(
        beforeStop,
        dispatch_time(0, oneSecond),
      ) !=
      0) {
    throw StateError('main queue stopped before teardown began');
  }

  if (!_stopHijackedMainRunLoop()) {
    throw StateError('main run loop ownership was not recorded');
  }
  _log('graceful shutdown: stop + wake requested; returning from Dart main');
  await Future<void>.delayed(const Duration(milliseconds: 250));
  _log('NORMAL_SHUTDOWN=PASS');
}

Future<void> probeKeepAliveHijack() async {
  ensureAppKitLoaded();

  // _parkMainThreadInRunLoop attaches the keep-alive source itself now; this
  // probe stays as the dedicated demonstration of why it has to.
  if (!_parkMainThreadInRunLoop()) {
    print('RESULT: main queue never drained, so the hijack itself failed.');
    _exitProcess(1);
  }
  print('main queue draining.');

  // The real test is whether the loop is STILL running later. A timer proves
  // it: probe K showed timers never fire on a loop that has already exited.
  var ticks = 0;
  final witness = NativeCallable<_HandleValueNative>.listener(
      (Pointer<ObjCObject> self, Pointer<ObjCSel> cmd, int value) => ticks++);
  final className = 'DartUiKeepAliveWitness'.toNativeUtf8();
  final witnessClass =
      objc_allocateClassPair(getClass('NSObject'), className, 0);
  calloc.free(className);
  final types = 'v@:q'.toNativeUtf8();
  class_addMethod(
      witnessClass, sel('handleValue:'), witness.nativeFunction.cast(), types);
  calloc.free(types);
  objc_registerClassPair(witnessClass);
  final witnessObject = witnessClass.msgSend('alloc').msgSend('init');

  final witnessInvocation = _newInvocation(witnessObject, sel('handleValue:'));
  final value = calloc<Int64>()..value = 1;
  _setArgument(witnessInvocation, value.cast(), 2);
  witnessInvocation.msgSend('retainArguments');

  final schedule = _newInvocation(getClass('NSTimer'),
      sel('scheduledTimerWithTimeInterval:invocation:repeats:'));
  final interval = calloc<Double>()..value = 0.05;
  final target = calloc<Pointer<ObjCObject>>()..value = witnessInvocation;
  final repeats = calloc<Uint8>()..value = 1;
  _setArgument(schedule, interval.cast(), 2);
  _setArgument(schedule, target.cast(), 3);
  _setArgument(schedule, repeats.cast(), 4);
  _invokeOnMain(schedule);
  print('repeating timer scheduled.');

  await Future<void>.delayed(const Duration(seconds: 3));
  witness.close();

  print('timer fired $ticks times in 3s');
  print(ticks > 0
      ? 'RESULT: the keep-alive source holds the main thread in CFRunLoopRun. '
          'It is a REAL run loop now - timers fire, so AppKit event dispatch '
          'finally has somewhere to live.'
      : 'RESULT: still no timers. The loop exits despite the source, or the '
          'signal handler never entered CFRunLoopRun at all.');
  _exitProcess(ticks > 0 ? 0 : 1);
}

// ---------------------------------------------------------------------------
// Probe T - which AppKit call kills the run loop?
//
// Probe R parked the thread and saw 34 timer ticks in 3s. Probe K parked it the
// same way and saw zero. The only difference is what happens in between:
// sharedApplication, setActivationPolicy: and finishLaunching. So the hijack is
// not what breaks the loop - one of those does.
//
// A tick counter runs continuously while each call is made in turn. The step
// after which ticks stop is the culprit. Note that the earlier probes called
// sharedApplication from the DART thread, not through the main thread, which is
// itself a candidate.
// ---------------------------------------------------------------------------

Future<void> probeAppKitBisect() async {
  ensureAppKitLoaded();
  if (!_parkMainThreadInRunLoop()) {
    print('RESULT: could not park the main thread.');
    _exitProcess(1);
  }

  var ticks = 0;
  final witness = NativeCallable<_HandleValueNative>.listener(
      (Pointer<ObjCObject> self, Pointer<ObjCSel> cmd, int value) => ticks++);
  final className = 'DartUiBisectWitness'.toNativeUtf8();
  final witnessClass =
      objc_allocateClassPair(getClass('NSObject'), className, 0);
  calloc.free(className);
  final types = 'v@:q'.toNativeUtf8();
  class_addMethod(
      witnessClass, sel('handleValue:'), witness.nativeFunction.cast(), types);
  calloc.free(types);
  objc_registerClassPair(witnessClass);
  final witnessObject = witnessClass.msgSend('alloc').msgSend('init');

  final witnessInvocation = _newInvocation(witnessObject, sel('handleValue:'));
  final value = calloc<Int64>()..value = 1;
  _setArgument(witnessInvocation, value.cast(), 2);
  witnessInvocation.msgSend('retainArguments');

  final schedule = _newInvocation(getClass('NSTimer'),
      sel('scheduledTimerWithTimeInterval:invocation:repeats:'));
  final interval = calloc<Double>()..value = 0.05;
  final target = calloc<Pointer<ObjCObject>>()..value = witnessInvocation;
  final repeats = calloc<Uint8>()..value = 1;
  _setArgument(schedule, interval.cast(), 2);
  _setArgument(schedule, target.cast(), 3);
  _setArgument(schedule, repeats.cast(), 4);
  _invokeOnMain(schedule);

  var previous = 0;
  Future<bool> measure(String label) async {
    await Future<void>.delayed(const Duration(milliseconds: 800));
    final delta = ticks - previous;
    previous = ticks;
    print('$label -> +$delta ticks');
    return delta > 0;
  }

  if (!await measure('baseline, no AppKit touched')) {
    print('RESULT: the loop was already dead before any AppKit call.');
    _exitProcess(1);
  }

  final app = getClass('NSApplication').msgSend('sharedApplication');
  print('sharedApplication (from the DART thread) = ${app.address}');
  if (!await measure('after sharedApplication on the Dart thread')) {
    print('RESULT: [NSApplication sharedApplication] called off the main '
        'thread is what kills the run loop.');
    _exitProcess(1);
  }

  final policyInvocation = _newInvocation(app, sel('setActivationPolicy:'));
  final policy = calloc<Int64>()..value = NSApplicationActivationPolicyRegular;
  _setArgument(policyInvocation, policy.cast(), 2);
  _invokeOnMain(policyInvocation);
  if (!await measure('after setActivationPolicy:')) {
    print('RESULT: setActivationPolicy: is what kills the run loop.');
    _exitProcess(1);
  }

  _invokeOnMain(_newInvocation(app, sel('finishLaunching')));
  if (!await measure('after finishLaunching')) {
    print('RESULT: [NSApp finishLaunching] is what kills the run loop - it '
        'takes the loop over and expects [NSApp run] to drive it.');
    _exitProcess(1);
  }

  witness.close();
  print('RESULT: the loop survived every AppKit initialisation step. The '
      'earlier failures came from somewhere else.');
  _exitProcess(0);
}

// ---------------------------------------------------------------------------
// Probe W - backend 2's full input path, without the postEvent wedge.
//
// Three measured facts from CI motivate this shape:
//   1. hold-appkit fired its repeating distantPast pump ~1000 times over 20s
//      with no block and no crash, so the periodic non-blocking
//      nextEventMatchingMask: is NOT the wedge.
//   2. F/K/L show nothing scheduled after postEvent:atStart: ever runs, and
//      the pre-existing repeating witness stops too: posting ON the parked
//      loop is what kills run-loop delivery, not the pump.
//   3. skylight-events received 3 events injected with
//      SLEventPostToPid(getpid()), while hold-appkit saw none of the
//      CGEventPost HID-tap injections (runner permissions). WindowServer-
//      directed injection is the usable path on CI.
//
// So this probe never calls postEvent:atStart:. Phase A dispatches retained
// synthetic NSEvents straight into [NSApp sendEvent:] and expects a Dart IMP
// on a custom NSWindow subclass to receive keyDown:/mouseDown:. Phase B runs
// the periodic pump while SLEventPostToPid feeds the queue, with a witness
// timer proving the loop stays alive. Phase C unwinds the hijack and returns
// normally - no _exit anywhere on this path.
// ---------------------------------------------------------------------------

typedef _EventHandlerNative = Void Function(
    Pointer<ObjCObject> self, Pointer<ObjCSel> cmd, Pointer<ObjCObject> event);

const NSEventTypeLeftMouseDown = 1;
const NSEventTypeKeyDown = 10;

Pointer<ObjCObject> _retainedNSString(String value) {
  final cString = value.toNativeUtf8();
  final string = msgSendPointerPointer(
      getClass('NSString'), sel('stringWithUTF8String:'), cString.cast());
  calloc.free(cString);
  return string.msgSend('retain');
}

void _scheduleRepeatingTimer(
    Pointer<ObjCObject> invocation, double intervalSeconds) {
  final schedule = _newInvocation(getClass('NSTimer'),
      sel('scheduledTimerWithTimeInterval:invocation:repeats:'));
  final interval = calloc<Double>()..value = intervalSeconds;
  final target = calloc<Pointer<ObjCObject>>()..value = invocation;
  final repeats = calloc<Uint8>()..value = 1;
  _setArgument(schedule, interval.cast(), 2);
  _setArgument(schedule, target.cast(), 3);
  _setArgument(schedule, repeats.cast(), 4);
  _invokeOnMain(schedule);
}

/// A repeating NSTimer whose Dart listener only counts firings. The witness
/// answers "is the run loop still delivering timers?" without trusting the
/// code under test.
(NativeCallable<_HandleValueNative>, int Function()) _startWitnessTimer(
    String className, double intervalSeconds) {
  var ticks = 0;
  final witness = NativeCallable<_HandleValueNative>.listener(
      (Pointer<ObjCObject> self, Pointer<ObjCSel> cmd, int value) => ticks++);
  final name = className.toNativeUtf8();
  final witnessClass = objc_allocateClassPair(getClass('NSObject'), name, 0);
  calloc.free(name);
  final types = 'v@:q'.toNativeUtf8();
  class_addMethod(
      witnessClass, sel('handleValue:'), witness.nativeFunction.cast(), types);
  calloc.free(types);
  objc_registerClassPair(witnessClass);
  final witnessObject = witnessClass.msgSend('alloc').msgSend('init');

  final witnessInvocation = _newInvocation(witnessObject, sel('handleValue:'));
  final value = calloc<Int64>()..value = 1;
  _setArgument(witnessInvocation, value.cast(), 2);
  witnessInvocation.msgSend('retainArguments');
  _scheduleRepeatingTimer(witnessInvocation, intervalSeconds);
  return (witness, () => ticks);
}

Future<void> probeDispatchLoop() async {
  ensureAppKitLoaded();
  if (!_parkMainThreadInRunLoop()) {
    _log('RESULT: could not park the main thread.');
    _exitProcess(1);
  }
  _log('main thread parked.');

  final app = _finishLaunchingOnMain();
  if (app == nullptr || _isSentinel(app)) {
    _log('RESULT: finishLaunching on main failed.');
    _exitProcess(1);
  }

  // keyDown:/mouseDown: reach Dart through probe J's reverse channel: the IMP
  // is a NativeCallable.listener, so the AppKit main thread posts to the
  // isolate instead of calling into it.
  final keyDown = Completer<void>();
  final mouseDown = Completer<void>();
  final keyImp = NativeCallable<_EventHandlerNative>.listener(
      (Pointer<ObjCObject> self, Pointer<ObjCSel> cmd,
          Pointer<ObjCObject> event) {
    if (!keyDown.isCompleted) keyDown.complete();
  });
  final mouseImp = NativeCallable<_EventHandlerNative>.listener(
      (Pointer<ObjCObject> self, Pointer<ObjCSel> cmd,
          Pointer<ObjCObject> event) {
    if (!mouseDown.isCompleted) mouseDown.complete();
  });

  final className = 'DartUiDispatchWindow'.toNativeUtf8();
  final windowClass =
      objc_allocateClassPair(getClass('NSWindow'), className, 0);
  calloc.free(className);
  final types = 'v@:@'.toNativeUtf8();
  class_addMethod(
      windowClass, sel('keyDown:'), keyImp.nativeFunction.cast(), types);
  class_addMethod(
      windowClass, sel('mouseDown:'), mouseImp.nativeFunction.cast(), types);
  calloc.free(types);
  objc_registerClassPair(windowClass);

  final window = _createAndFrontNSWindow(windowClass: windowClass);
  if (window == nullptr) {
    _log('RESULT: no window.');
    _exitProcess(1);
  }
  final numberInvocation = _newInvocation(window, sel('windowNumber'));
  _invokeOnMain(numberInvocation);
  final windowNumber = _returnedInt(numberInvocation);
  _log('WINDOW_ID=$windowNumber');

  // Key events only go somewhere if the app treats itself as active.
  final activate = _newInvocation(app, sel('activateIgnoringOtherApps:'));
  final yes = calloc<Uint8>()..value = 1;
  _setArgument(activate, yes.cast(), 2);
  _invokeOnMain(activate);
  calloc.free(yes);

  // --- phase A: dispatch -----------------------------------------------------
  //
  // sendEvent: never touches the event queue, so this half cannot wedge the
  // loop. The events are retained: nothing here depends on an autorelease
  // pool staying out of the way.
  final characters = _retainedNSString('a');
  final location = calloc<NSPoint>()
    ..ref.x = 400
    ..ref.y = 400;
  final keyEvent = msgSendKeyEvent(
      getClass('NSEvent'),
      sel('keyEventWithType:location:modifierFlags:timestamp:windowNumber:'
          'context:characters:charactersIgnoringModifiers:isARepeat:keyCode:'),
      NSEventTypeKeyDown,
      location.ref,
      0,
      0.0,
      windowNumber,
      nullptr,
      characters,
      characters,
      false,
      0);
  final mouseEvent = msgSendMouseEvent(
      getClass('NSEvent'),
      sel('mouseEventWithType:location:modifierFlags:timestamp:windowNumber:'
          'context:eventNumber:clickCount:pressure:'),
      NSEventTypeLeftMouseDown,
      location.ref,
      0,
      0.0,
      windowNumber,
      nullptr,
      1,
      1,
      1.0);
  calloc.free(location);
  keyEvent.msgSend('retain');
  mouseEvent.msgSend('retain');
  _log('synthetic keyEvent=${keyEvent.address} '
      'mouseEvent=${mouseEvent.address} (both retained)');

  void sendEventOnMain(Pointer<ObjCObject> event) {
    final invocation = _newInvocation(app, sel('sendEvent:'));
    final argument = calloc<Pointer<ObjCObject>>()..value = event;
    _setArgument(invocation, argument.cast(), 2);
    _invokeOnMain(invocation);
    calloc.free(argument);
  }

  sendEventOnMain(keyEvent);
  sendEventOnMain(mouseEvent);
  _log('sendEvent: keyDown + mouseDown performed on main.');

  var keyDelivered = true;
  await keyDown.future.timeout(const Duration(seconds: 3), onTimeout: () {
    keyDelivered = false;
  });
  var mouseDelivered = true;
  await mouseDown.future.timeout(const Duration(seconds: 3), onTimeout: () {
    mouseDelivered = false;
  });
  _log('KEYDOWN_DELIVERED=${keyDelivered ? 1 : 0}');
  _log('MOUSEDOWN_DELIVERED=${mouseDelivered ? 1 : 0}');
  _log('DISPATCH_LOOP=${keyDelivered || mouseDelivered ? 'PASS' : 'FAIL'}');

  // --- phase B: pump + WindowServer-directed input ---------------------------
  //
  // The pump fires every 50ms and Dart polls every 20ms, so each dequeued
  // event is observed more than once before the next firing overwrites the
  // return buffer. No postEvent:atStart: anywhere - input arrives through the
  // WindowServer, the way real keyboard/mouse input would.
  final (witness, ticks) = _startWitnessTimer('DartUiDispatchWitness', 0.05);
  final pumpInvocation = _newPumpInvocation(app);
  _scheduleRepeatingTimer(pumpInvocation, 0.05);
  _log('witness + repeating pump timers scheduled; injecting input via '
      'SLEventPostToPid...');

  final skyLight = DynamicLibrary.open(
      '/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight');
  final injected = probePostInputBody(skyLight: skyLight);
  _log('SLEventPostToPid injection attempted: $injected');

  final seen = <int>{};
  final ticksBefore = ticks();
  for (var i = 0; i < 150; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
    final event = _returnedObject(pumpInvocation);
    if (event != nullptr && !_isSentinel(event) && seen.add(event.address)) {
      _log('pumped an NSEvent: ${event.address}');
    }
    if (i == 50) {
      probePostInputBody(skyLight: skyLight);
    }
  }
  final livenessTicks = ticks() - ticksBefore;
  _log('PUMPED_FROM_WINDOWSERVER=${seen.length}');
  _log(livenessTicks > 0
      ? 'PUMP_LIVENESS=PASS (+$livenessTicks witness ticks while pumping)'
      : 'PUMP_LIVENESS=FAIL (witness stopped once the pump started)');

  // --- phase C: normal shutdown ----------------------------------------------
  //
  // Stop the loop BEFORE closing the callables: a timer firing into a closed
  // NativeCallable would jump into a freed trampoline.
  if (!_stopHijackedMainRunLoop()) {
    _log('NORMAL_SHUTDOWN=FAIL (run loop ownership was not recorded)');
    _exitProcess(1);
  }
  await Future<void>.delayed(const Duration(milliseconds: 250));
  witness.close();
  keyImp.close();
  mouseImp.close();
  _log('NORMAL_SHUTDOWN=PASS');
}

// ---------------------------------------------------------------------------
// Backend 2 conformance - the same six lines the other two backends answer.
//
// dispatch-loop already showed input and normal shutdown on the hijacked main
// thread. What was missing was presentation: a CPU framebuffer that an outside
// process can photograph. AppKit owns this window's backing store, so the frame
// goes in as a CGImage on the content view's layer rather than through a CGS
// window context.
// ---------------------------------------------------------------------------

final DynamicLibrary libCoreGraphics = DynamicLibrary.open(
    '/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics');

/// Wraps BGRA bytes in a CGImage. The buffer is handed to a data provider and
/// must outlive the image, so it is deliberately never freed here.
Pointer<Void> _cgImageFromBgra(List<int> pixels, int width, int height) {
  final buffer = calloc<Uint8>(pixels.length);
  buffer.asTypedList(pixels.length).setAll(0, pixels);
  final provider = libCoreGraphics.lookupFunction<
      Pointer<Void> Function(Pointer<Void>, Pointer<Void>, IntPtr,
          Pointer<Void>),
      Pointer<Void> Function(Pointer<Void>, Pointer<Void>, int,
          Pointer<Void>)>('CGDataProviderCreateWithData')(
    nullptr,
    buffer.cast(),
    pixels.length,
    nullptr,
  );
  final colorSpace = libCoreGraphics
      .lookupFunction<Pointer<Void> Function(), Pointer<Void> Function()>(
          'CGColorSpaceCreateDeviceRGB')();
  // kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little => BGRA.
  const bitmapInfo = 2 | (2 << 12);
  return libCoreGraphics.lookupFunction<
      Pointer<Void> Function(IntPtr, IntPtr, IntPtr, IntPtr, IntPtr,
          Pointer<Void>, Uint32, Pointer<Void>, Pointer<Void>, Bool, Int32),
      Pointer<Void> Function(int, int, int, int, int, Pointer<Void>, int,
          Pointer<Void>, Pointer<Void>, bool, int)>('CGImageCreate')(
    width,
    height,
    8,
    32,
    width * 4,
    colorSpace,
    bitmapInfo,
    provider,
    nullptr,
    false,
    0,
  );
}

/// Puts [image] on the window's content-view layer, entirely on the parked
/// main thread. Nearest-neighbour filtering keeps the witness reading the pixel
/// that was sent instead of a resample of its neighbours.
bool _setLayerContentsOnMain(
    Pointer<ObjCObject> window, Pointer<Void> image) {
  final contentInvocation = _newInvocation(window, sel('contentView'));
  _invokeOnMain(contentInvocation);
  final contentView = _returnedObject(contentInvocation);
  if (contentView == nullptr || _isSentinel(contentView)) return false;

  final wantsLayer = _newInvocation(contentView, sel('setWantsLayer:'));
  final yes = calloc<Uint8>()..value = 1;
  _setArgument(wantsLayer, yes.cast(), 2);
  _invokeOnMain(wantsLayer);
  calloc.free(yes);

  final layerInvocation = _newInvocation(contentView, sel('layer'));
  _invokeOnMain(layerInvocation);
  final layer = _returnedObject(layerInvocation);
  if (layer == nullptr || _isSentinel(layer)) return false;

  final nearest = _retainedNSString('nearest');
  for (final selector in const ['setMagnificationFilter:', 'setMinificationFilter:']) {
    final invocation = _newInvocation(layer, sel(selector));
    final argument = calloc<Pointer<ObjCObject>>()..value = nearest;
    _setArgument(invocation, argument.cast(), 2);
    _invokeOnMain(invocation);
    calloc.free(argument);
  }

  final contents = _newInvocation(layer, sel('setContents:'));
  final argument = calloc<Pointer<ObjCObject>>()..value = image.cast();
  _setArgument(contents, argument.cast(), 2);
  _invokeOnMain(contents);
  calloc.free(argument);

  // Without an explicit flush the frame waits for the next implicit
  // transaction, which the capture can easily beat.
  _invokeOnMain(_newInvocation(getClass('CATransaction'), sel('flush')));
  return true;
}

Future<void> probeSignalConformance() async {
  const width = 480;
  const height = 320;
  const expected = shared.PixelSample(120, 220, 20);
  _log('CONFORMANCE_BACKEND=appkitSignal');

  var failures = 0;
  void check(bool condition, String failure) {
    if (!condition) {
      failures++;
      _log('FAILURE: $failure');
    }
  }

  _log('PHASE=park');
  ensureAppKitLoaded();
  if (!_parkMainThreadInRunLoop()) {
    _log('FAILURE: could not park the main thread.');
    _log('CONFORMANCE=FAIL (1)');
    exitCode = 1;
    return;
  }
  final app = _finishLaunchingOnMain();
  if (app == nullptr || _isSentinel(app)) {
    _log('FAILURE: finishLaunching on main failed.');
    _log('CONFORMANCE=FAIL (1)');
    exitCode = 1;
    return;
  }

  // Input reaches Dart the same way probe J does: the IMP is a listener, so
  // AppKit posts to the isolate instead of calling into it.
  final keyDown = Completer<void>();
  final keyImp = NativeCallable<_EventHandlerNative>.listener(
      (Pointer<ObjCObject> self, Pointer<ObjCSel> cmd,
          Pointer<ObjCObject> event) {
    if (!keyDown.isCompleted) keyDown.complete();
  });
  final className = 'DartUiConformanceWindow'.toNativeUtf8();
  final windowClass = objc_allocateClassPair(getClass('NSWindow'), className, 0);
  calloc.free(className);
  final types = 'v@:@'.toNativeUtf8();
  class_addMethod(
      windowClass, sel('keyDown:'), keyImp.nativeFunction.cast(), types);
  calloc.free(types);
  objc_registerClassPair(windowClass);

  _log('PHASE=window');
  final window = _createAndFrontNSWindow(
      windowClass: windowClass, width: width, height: height);
  check(window != nullptr, 'no NSWindow');
  final numberInvocation = _newInvocation(window, sel('windowNumber'));
  _invokeOnMain(numberInvocation);
  final windowNumber = _returnedInt(numberInvocation);
  _log('WINDOW_ID=$windowNumber');
  check(windowNumber > 0, 'no window number');

  final activate = _newInvocation(app, sel('activateIgnoringOtherApps:'));
  final yes = calloc<Uint8>()..value = 1;
  _setArgument(activate, yes.cast(), 2);
  _invokeOnMain(activate);
  calloc.free(yes);

  // --- present ---------------------------------------------------------------
  final pixels = List<int>.filled(width * height * 4, 0);
  for (var i = 0; i < pixels.length; i += 4) {
    pixels[i] = expected.blue;
    pixels[i + 1] = expected.green;
    pixels[i + 2] = expected.red;
    pixels[i + 3] = 255;
  }
  _log('PHASE=present');
  final image = _cgImageFromBgra(pixels, width, height);
  _log('CGImageCreate -> ${image.address}');
  final presented = image != nullptr && _setLayerContentsOnMain(window, image);
  _log(presented ? 'PRESENT=PASS' : 'PRESENT=FAIL');
  check(presented, 'the frame did not reach the layer');
  await Future<void>.delayed(const Duration(milliseconds: 500));

  // --- outside witness -------------------------------------------------------
  _log('PHASE=witness');
  final witness = shared.WindowPixelWitness(
          workDirectory:
              Platform.environment['CONFORMANCE_SHOTS'] ?? '/tmp/shots')
      .capture(windowNumber, label: 'appkit-signal');
  final centre = witness.centre;
  if (centre != null && centre.matches(expected)) {
    _log('PIXEL_WITNESS=PASS centre=$centre '
        'size=${witness.width}x${witness.height}');
  } else {
    _log('PIXEL_WITNESS=FAIL centre=$centre '
        'size=${witness.width}x${witness.height} expected=$expected '
        'failure=${witness.failure}');
    failures++;
  }

  // --- input -----------------------------------------------------------------
  _log('PHASE=input');
  final (witnessTimer, ticks) =
      _startWitnessTimer('DartUiConformanceWitness', 0.05);
  final pumpInvocation = _newPumpInvocation(app);
  _scheduleRepeatingTimer(pumpInvocation, 0.05);
  final skyLight = DynamicLibrary.open(
      '/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight');
  probePostInputBody(skyLight: skyLight);

  final seen = <int>{};
  final ticksBefore = ticks();
  for (var i = 0; i < 120; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
    final event = _returnedObject(pumpInvocation);
    if (event != nullptr && !_isSentinel(event)) seen.add(event.address);
    if (i == 40) probePostInputBody(skyLight: skyLight);
  }
  final livenessTicks = ticks() - ticksBefore;
  _log('INPUT_EVENTS=${seen.length}');
  _log('PUMP_LIVENESS=${livenessTicks > 0 ? 'PASS' : 'FAIL'} '
      '(+$livenessTicks witness ticks)');
  _log('KEYDOWN_DELIVERED=${keyDown.isCompleted ? 1 : 0}');
  check(seen.isNotEmpty, 'the pump dequeued no NSEvent');
  check(livenessTicks > 0, 'the run loop stopped delivering timers');

  // --- teardown --------------------------------------------------------------
  //
  // Nothing here may wait on the main thread. Once the hijacked run loop stops,
  // thread 0 goes back to Dart_RunLoop and stops draining the main queue, so a
  // performSelectorOnMainThread: with waitUntilDone:YES would block forever -
  // which is exactly what a blocking [window close] did in run 31242939984.
  // Order the window out asynchronously, give the main thread a turn to do it,
  // and only then take the loop back.
  _log('PHASE=teardown.orderout');
  final failuresBeforeTeardown = failures;
  final orderOut = _newInvocation(window, sel('orderOut:'));
  final nilSender = calloc<Pointer<ObjCObject>>()..value = nullptr;
  _setArgument(orderOut, nilSender.cast(), 2);
  _invokeOnMain(orderOut, wait: false);
  await Future<void>.delayed(const Duration(milliseconds: 300));
  calloc.free(nilSender);

  _log('PHASE=teardown.stop');
  check(_stopHijackedMainRunLoop(), 'the hijacked run loop did not stop');
  // Stop first, close the callables second: a timer firing into a closed
  // NativeCallable would jump into a freed trampoline.
  _log('PHASE=teardown.drain');
  await Future<void>.delayed(const Duration(milliseconds: 250));
  _log('PHASE=teardown.callables');
  witnessTimer.close();
  keyImp.close();
  _log(failures == failuresBeforeTeardown ? 'TEARDOWN=PASS' : 'TEARDOWN=FAIL');

  _log(failures == 0 ? 'CONFORMANCE=PASS' : 'CONFORMANCE=FAIL ($failures)');
  if (failures != 0) exitCode = 1;
}

Future<void> main(List<String> args) async {
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
      await probeEventPump();
    case 'nsapp-run-main':
      probeNsAppRunOnMain();
    case 'skylight-window':
      probeSkyLightWindow();
    case 'vm-health':
      await probeVmHealthUnderHijack();
    case 'reverse-channel':
      await probeReverseChannel();
    case 'pump-timer':
      await probePumpViaTimer();
    case 'skylight-draw':
      probeSkyLightDraw();
    case 'hold-skylight':
      probeHoldSkyLightWindow(
          int.tryParse(args.elementAtOrNull(1) ?? '') ?? 12);
    case 'hold-appkit':
      await probeHoldAppKitWindow(
          int.tryParse(args.elementAtOrNull(1) ?? '') ?? 12);
    case 'hold-appkit-nopump':
      await probeHoldAppKitNoPump(
          int.tryParse(args.elementAtOrNull(1) ?? '') ?? 12);
    case 'post-input':
      probePostInput();
    case 'skylight-events':
      await probeSkyLightEvents(
          int.tryParse(args.elementAtOrNull(1) ?? '') ?? 12);
    case 'pump-timer-diagnostic':
      await probePumpTimerDiagnostic();
    case 'appkit-bisect':
      await probeAppKitBisect();
    case 'keepalive-hijack':
      await probeKeepAliveHijack();
    case 'graceful-hijack-shutdown':
      await probeGracefulHijackShutdown();
    case 'dispatch-loop':
      await probeDispatchLoop();
    case 'conformance-signal':
      await probeSignalConformance();
    case 'skylight-foreground':
      await probeSkyLightForeground(
          int.tryParse(args.elementAtOrNull(1) ?? '') ?? 12);
    case 'transform-process':
      await probeTransformProcess(
          int.tryParse(args.elementAtOrNull(1) ?? '') ?? 12);
    case 'skylight-register':
      await probeSkyLightRegister(
          int.tryParse(args.elementAtOrNull(1) ?? '') ?? 12);
    default:
      _log('unknown probe: $probe');
      _log('usage: probe [thread|nsapp-run|skylight|signal-hijack'
          '|mainthread-window|event-pump|nsapp-run-main|skylight-window'
          '|vm-health|reverse-channel|pump-timer|hold-appkit-nopump'
          '|transform-process|appkit-bisect|keepalive-hijack'
          '|graceful-hijack-shutdown|dispatch-loop|conformance-signal]');
  }
}
