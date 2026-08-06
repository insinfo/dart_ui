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
    default:
      print('unknown probe: $probe');
      print('usage: probe [thread|nsapp-run|skylight|signal-hijack]');
  }
}
