/// AppKit in this process, on a main thread taken from the Dart VM by a
/// signal.
///
/// The route `exploracao-inicial:poc/poc_03_appkit_window` measured (`doc/MACOS_TRES_BACKENDS.md`,
/// backend 2). A standalone Dart program never runs AppKit: thread 0 sits in
/// `Dart_RunLoop` waiting on a condition variable. Here it is interrupted with
/// SIGUSR2 whose handler is `CFRunLoopRun` itself, so thread 0 parks in the
/// main run loop on its own stack, a keep-alive source keeping that loop from
/// returning at once. Every AppKit call is then an `NSInvocation` performed on
/// the main thread; the Dart thread waits for it.
///
/// **Unsafe by construction**, which is why the backend is experimental and
/// reached only by name: `CFRunLoopRun` is not async-signal-safe and SIGUSR2
/// is process-wide. What makes it work in practice, all measured in the POC:
///
///   * `[NSApp run]` is never called - it traps. `finishLaunching` is enough,
///     and events are pumped with `nextEventMatchingMask:` and handed back
///     with `sendEvent:`;
///   * no call waits blindly: on macOS 27 an AppKit animation can post a
///     `CFRunLoopStop` that lands on the outer loop, thread 0 returns to
///     `Dart_RunLoop`, and a `waitUntilDone:YES` would wait forever. Each call
///     is queued with a marker behind it; when the marker is late and the main
///     loop is not running at all, thread 0 is parked again;
///   * teardown restores the old SIGUSR2 handler, removes the keep-alive
///     source and stops the loop, which returns through the signal frame to
///     `Dart_RunLoop` - no `_exit`.
library;

import 'dart:ffi';
import 'dart:io' show sleep;
import 'dart:isolate';

import '../../../ffi/objc_runtime.dart';
import '../../../foundation/diagnostics.dart';
import '../io_surface.dart' show macosCalloc, macosFree;

typedef _VoidPtr = Pointer<Void>;

const int _sigusr2 = 31;

/// One argument of a main-thread call, written into the invocation by value.
sealed class MainArg {
  const MainArg();
}

/// An object, a selector or any pointer-sized value.
final class PointerArg extends MainArg {
  const PointerArg(this.value);
  PointerArg.object(Pointer<ObjCObject> object) : value = object.address;
  final int value;
}

/// An `NSInteger`/`NSUInteger`-sized integer.
final class IntArg extends MainArg {
  const IntArg(this.value);
  final int value;
}

/// A `BOOL`.
final class BoolArg extends MainArg {
  const BoolArg(this.value);
  final bool value;
}

/// A `double` (`NSTimeInterval`, `CGFloat`).
final class DoubleArg extends MainArg {
  const DoubleArg(this.value);
  final double value;
}

/// A `float`.
final class FloatArg extends MainArg {
  const FloatArg(this.value);
  final double value;
}

/// An `NSSize`, or an `NSPoint` - the same two doubles.
final class SizeArg extends MainArg {
  const SizeArg(this.width, this.height);
  final double width;
  final double height;
}

/// An `NSRect`.
final class RectArg extends MainArg {
  const RectArg(this.x, this.y, this.width, this.height);
  final double x;
  final double y;
  final double width;
  final double height;
}

final class _RunLoopSourceContext extends Struct {
  @Int64()
  external int version;
  external _VoidPtr info;
  external _VoidPtr retain;
  external _VoidPtr release;
  external _VoidPtr copyDescription;
  external _VoidPtr equal;
  external _VoidPtr hash;
  external _VoidPtr schedule;
  external _VoidPtr cancel;
  external _VoidPtr perform;
}

/// The parked main thread and the application object on it.
final class AppKitSignalSession {
  AppKitSignalSession._();

  /// Parks thread 0 in the main run loop and finishes launching
  /// `NSApplication` there, or returns null with [diagnostics] saying why.
  static Future<AppKitSignalSession?> open(
      List<BackendDiagnostic> diagnostics) async {
    try {
      DynamicLibrary.open('/System/Library/Frameworks/AppKit.framework/AppKit');
      DynamicLibrary.open(
          '/System/Library/Frameworks/QuartzCore.framework/QuartzCore');
    } on Object catch (error) {
      diagnostics.add(BackendDiagnostic.missingLibrary('AppKit.framework',
          detail: '$error'));
      return null;
    }
    final AppKitSignalSession session = AppKitSignalSession._();
    if (!session._park()) {
      diagnostics.add(const BackendDiagnostic(
        kind: DiagnosticKind.connectionFailed,
        message: 'AppKit signal: the main thread did not park in its run loop',
      ));
      session._unpark();
      return null;
    }
    // Before the first AppKit call: from here on every call can wait.
    await session._startWatchdog();
    ObjCAutoreleasePool.run(session._launch);
    return session;
  }

  final DynamicLibrary _system =
      DynamicLibrary.open('/usr/lib/libSystem.B.dylib');
  final DynamicLibrary _coreFoundation = DynamicLibrary.open(
      '/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation');

  late final _VoidPtr Function(int, _VoidPtr) _signal = _system.lookupFunction<
      _VoidPtr Function(Int32, _VoidPtr),
      _VoidPtr Function(int, _VoidPtr)>('signal');
  late final int Function(_VoidPtr, int) _pthreadKill = _system.lookupFunction<
      Int32 Function(_VoidPtr, Int32),
      int Function(_VoidPtr, int)>('pthread_kill');
  late final _VoidPtr _mainThread =
      _system.lookupFunction<_VoidPtr Function(), _VoidPtr Function()>(
          'pthread_main_thread_np')();
  late final void Function(_VoidPtr) _cfRelease = _coreFoundation
      .lookupFunction<Void Function(_VoidPtr), void Function(_VoidPtr)>(
          'CFRelease');
  late final _VoidPtr _mainRunLoop =
      _coreFoundation.lookupFunction<_VoidPtr Function(), _VoidPtr Function()>(
          'CFRunLoopGetMain')();
  late final _VoidPtr _defaultMode =
      _coreFoundation.lookup<_VoidPtr>('kCFRunLoopDefaultMode').value;

  _VoidPtr _previousHandler = nullptr;
  _VoidPtr _keepAlive = nullptr;
  bool _parked = false;

  /// `NSApp`, once launched.
  Pointer<ObjCObject> application = nullptr;

  bool _park() {
    final Pointer<_RunLoopSourceContext> context =
        macosCalloc<_RunLoopSourceContext>(sizeOf<_RunLoopSourceContext>());
    try {
      // A version-0 source that never fires: without anything to wait on,
      // CFRunLoopRun returns at once and the VM has thread 0 back.
      _keepAlive = _coreFoundation.lookupFunction<
          _VoidPtr Function(_VoidPtr, Int64, Pointer<_RunLoopSourceContext>),
          _VoidPtr Function(_VoidPtr, int,
              Pointer<_RunLoopSourceContext>)>('CFRunLoopSourceCreate')(
        nullptr,
        0,
        context,
      );
    } finally {
      macosFree(context);
    }
    if (_keepAlive == nullptr) return false;
    _coreFoundation.lookupFunction<Void Function(_VoidPtr, _VoidPtr, _VoidPtr),
        void Function(_VoidPtr, _VoidPtr, _VoidPtr)>('CFRunLoopAddSource')(
      _mainRunLoop,
      _keepAlive,
      _defaultMode,
    );
    _previousHandler =
        _signal(_sigusr2, _coreFoundation.lookup<Void>('CFRunLoopRun'));
    if (_pthreadKill(_mainThread, _sigusr2) != 0) return false;
    _parked = _mainQueueAnswers();
    return _parked;
  }

  /// Whether the main queue drains within three seconds - the proof that
  /// thread 0 is in the run loop and not in `Dart_RunLoop`.
  bool _mainQueueAnswers() {
    final _VoidPtr semaphore = _system.lookupFunction<_VoidPtr Function(IntPtr),
        _VoidPtr Function(int)>('dispatch_semaphore_create')(0);
    _system.lookupFunction<Void Function(_VoidPtr, _VoidPtr, _VoidPtr),
        void Function(_VoidPtr, _VoidPtr, _VoidPtr)>('dispatch_async_f')(
      _system.lookup<Void>('_dispatch_main_q'),
      semaphore,
      _system.lookup<Void>('dispatch_semaphore_signal'),
    );
    final int deadline = _system.lookupFunction<Uint64 Function(Uint64, Int64),
        int Function(int, int)>('dispatch_time')(0, 3000000000);
    return _system.lookupFunction<IntPtr Function(_VoidPtr, Uint64),
            int Function(_VoidPtr, int)>('dispatch_semaphore_wait')(
          semaphore,
          deadline,
        ) ==
        0;
  }

  void _launch() {
    // sharedApplication on thread 0: created from any other thread it binds
    // the main event queue there and AppKit later dies on it.
    application =
        objcRetain(callObject(objcClass('NSApplication'), 'sharedApplication'));
    call(application, 'setActivationPolicy:', args: const <MainArg>[IntArg(0)]);
    call(application, 'finishLaunching');
    call(application, 'activateIgnoringOtherApps:',
        args: const <MainArg>[BoolArg(true)]);
  }

  /// Brings this process to the front, as clicking its window would.
  ///
  /// `activateIgnoringOtherApps:` is refused for a process another one
  /// launched in the background - a terminal, an editor - and an inactive
  /// AppKit application has the first click on its window eaten by the
  /// activation the click asks for. SkyLight's front-process call is what
  /// the Dock uses; [userGenerated] marks it as the user's doing.
  bool bringToFront() {
    try {
      final DynamicLibrary skyLight = DynamicLibrary.open(
          '/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight');
      final DynamicLibrary services = DynamicLibrary.open('/System/Library/'
          'Frameworks/ApplicationServices.framework/ApplicationServices');
      final Pointer<Uint32> psn = macosCalloc<Uint32>(8);
      try {
        services.lookupFunction<Int16 Function(Pointer<Uint32>),
            int Function(Pointer<Uint32>)>('GetCurrentProcess')(psn);
        return skyLight.lookupFunction<
                Int32 Function(Pointer<Uint32>, Uint32, Uint32),
                int Function(Pointer<Uint32>, int,
                    int)>('_SLPSSetFrontProcessWithOptions')(
              psn,
              0,
              0x200, // kCPSUserGenerated
            ) ==
            0;
      } finally {
        macosFree(psn);
      }
    } on Object {
      return false;
    }
  }

  // -------------------------------------------------------------------------
  // Main-thread calls
  // -------------------------------------------------------------------------

  /// `[target selector args...]` on the main thread, waiting for it, and
  /// its result when [returns] asks for one.
  ///
  /// Pointer and integer results come back as the integer, doubles through
  /// [callDouble] and rects through [callRect].
  int call(
    Pointer<ObjCObject> target,
    String selector, {
    List<MainArg> args = const <MainArg>[],
    MainReturn returns = MainReturn.none,
  }) {
    final Pointer<ObjCObject> invocation = _invocation(target, selector, args);
    _invokeOnMain(invocation);
    if (returns == MainReturn.none) return 0;
    final Pointer<IntPtr> slot = macosCalloc<IntPtr>(8);
    try {
      objcSendVoid1(invocation, objcSelector('getReturnValue:'), slot.address);
      return returns == MainReturn.boolean
          ? slot.cast<Uint8>().value
          : slot.value;
    } finally {
      macosFree(slot);
    }
  }

  /// [call] for a method that returns an object.
  Pointer<ObjCObject> callObject(Pointer<ObjCObject> target, String selector,
          {List<MainArg> args = const <MainArg>[]}) =>
      Pointer<ObjCObject>.fromAddress(
          call(target, selector, args: args, returns: MainReturn.object));

  /// [call] for a `CGFloat` result.
  double callDouble(Pointer<ObjCObject> target, String selector) {
    final Pointer<ObjCObject> invocation =
        _invocation(target, selector, const <MainArg>[]);
    _invokeOnMain(invocation);
    final Pointer<Double> slot = macosCalloc<Double>(8);
    try {
      objcSendVoid1(invocation, objcSelector('getReturnValue:'), slot.address);
      return slot.value;
    } finally {
      macosFree(slot);
    }
  }

  /// [call] for an `NSRect` result: x, y, width, height.
  List<double> callRect(Pointer<ObjCObject> target, String selector) {
    final Pointer<ObjCObject> invocation =
        _invocation(target, selector, const <MainArg>[]);
    _invokeOnMain(invocation);
    final Pointer<Double> slot = macosCalloc<Double>(32);
    try {
      objcSendVoid1(invocation, objcSelector('getReturnValue:'), slot.address);
      return <double>[slot[0], slot[1], slot[2], slot[3]];
    } finally {
      macosFree(slot);
    }
  }

  Pointer<ObjCObject> _invocation(
      Pointer<ObjCObject> target, String selector, List<MainArg> args) {
    final Pointer<ObjCSelector> sel = objcSelector(selector);
    final Pointer<ObjCObject> signature = objcSendPointer1(
        target, objcSelector('methodSignatureForSelector:'), sel.address);
    if (signature == nullptr) {
      throw StateError('no method signature for $selector');
    }
    final Pointer<ObjCObject> invocation = objcSendPointer1(
        objcClass('NSInvocation'),
        objcSelector('invocationWithMethodSignature:'),
        signature.address);
    objcSendVoid1(invocation, objcSelector('setTarget:'), target.address);
    objcSendVoid1(invocation, objcSelector('setSelector:'), sel.address);
    final Pointer<Uint8> value = macosCalloc<Uint8>(32);
    try {
      for (var i = 0; i < args.length; i++) {
        final MainArg arg = args[i];
        switch (arg) {
          case PointerArg():
            value.cast<IntPtr>().value = arg.value;
          case IntArg():
            value.cast<Int64>().value = arg.value;
          case BoolArg():
            value.value = arg.value ? 1 : 0;
          case DoubleArg():
            value.cast<Double>().value = arg.value;
          case FloatArg():
            value.cast<Float>().value = arg.value;
          case SizeArg():
            final Pointer<Double> size = value.cast<Double>();
            size[0] = arg.width;
            size[1] = arg.height;
          case RectArg():
            final Pointer<Double> rect = value.cast<Double>();
            rect[0] = arg.x;
            rect[1] = arg.y;
            rect[2] = arg.width;
            rect[3] = arg.height;
        }
        // Copied by the invocation; the scratch is reused for the next one.
        objcSendVoid2(invocation, objcSelector('setArgument:atIndex:'),
            value.address, i + 2);
      }
    } finally {
      macosFree(value);
    }
    objcSendVoid(invocation, objcSelector('retainArguments'));
    return invocation;
  }

  /// Performs [invocation] on the main thread and waits for exactly it.
  ///
  /// `waitUntilDone:YES`, not a marker queued behind it: AppKit spins the
  /// run loop inside `nextEventMatchingMask:`, and a marker queued after the
  /// call ran *inside* it, nested, before the call itself had finished - the
  /// Dart side then read results and reused buffers the main thread was
  /// still using, and the heap broke in `-[NSInvocation setArgument:]`.
  ///
  /// What waiting gives up is the stopped-loop case: if thread 0 leaves the
  /// run loop while the call is queued, nothing would ever run it. That is
  /// the watchdog's job - see [_startWatchdog].
  void _invokeOnMain(Pointer<ObjCObject> invocation) {
    // After dispose thread 0 is back in Dart_RunLoop and nothing will ever
    // run a queued call: waiting for one is a hang, not a slow call. A late
    // orderOut or present from a teardown that raced this one is dropped.
    if (_disposed || !_parked) {
      throw StateError('AppKit signal session is closed; main-thread call '
          'dropped');
    }
    _inFlight.value = 1;
    try {
      objcSendVoid3(
        invocation,
        objcSelector('performSelectorOnMainThread:withObject:waitUntilDone:'),
        objcSelector('invoke').address,
        0,
        1,
      );
    } finally {
      _inFlight.value = 0;
    }
  }

  /// 1 while a main-thread call is waiting, 0 between calls, -1 to stop the
  /// watchdog. Native memory, so the watchdog isolate reads it directly.
  late final Pointer<Int32> _inFlight = macosCalloc<Int32>(4);
  Isolate? _watchdog;

  /// A second isolate - its own OS thread, running while this one is blocked
  /// in a main-thread call - that re-parks thread 0 when a call is waiting
  /// and the main run loop is not running at all.
  ///
  /// On macOS 27 an AppKit animation can post a `CFRunLoopStop` that lands on
  /// the outer loop (lldb, 2026-10-12): thread 0 returns to `Dart_RunLoop`
  /// with our call still queued, and `waitUntilDone:YES` would wait forever.
  /// "Not running" is `CFRunLoopCopyCurrentMode` answering NULL; a loop busy
  /// in a drag or a live resize answers its mode and is left alone.
  Future<void> _startWatchdog() async {
    _watchdog = await Isolate.spawn<List<int>>(_watch, <int>[
      _inFlight.address,
      _mainRunLoop.address,
      _mainThread.address,
    ]);
  }

  static void _watch(List<int> addresses) {
    final Pointer<Int32> inFlight = Pointer<Int32>.fromAddress(addresses[0]);
    final _VoidPtr runLoop = _VoidPtr.fromAddress(addresses[1]);
    final _VoidPtr mainThread = _VoidPtr.fromAddress(addresses[2]);
    final DynamicLibrary cf = DynamicLibrary.open(
        '/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation');
    final copyMode = cf.lookupFunction<_VoidPtr Function(_VoidPtr),
        _VoidPtr Function(_VoidPtr)>('CFRunLoopCopyCurrentMode');
    final release =
        cf.lookupFunction<Void Function(_VoidPtr), void Function(_VoidPtr)>(
            'CFRelease');
    final kill = DynamicLibrary.open('/usr/lib/libSystem.B.dylib')
        .lookupFunction<Int32 Function(_VoidPtr, Int32),
            int Function(_VoidPtr, int)>('pthread_kill');
    var stoppedFor = 0;
    while (inFlight.value >= 0) {
      sleep(const Duration(milliseconds: 5));
      if (inFlight.value != 1) {
        stoppedFor = 0;
        continue;
      }
      final _VoidPtr mode = copyMode(runLoop);
      if (mode != nullptr) {
        release(mode);
        stoppedFor = 0;
        continue;
      }
      // Two consecutive looks, 5 ms apart: a loop between two iterations
      // answers NULL for an instant without having stopped.
      if (++stoppedFor < 2) continue;
      stoppedFor = 0;
      kill(mainThread, _sigusr2);
    }
  }

  // -------------------------------------------------------------------------
  // Teardown
  // -------------------------------------------------------------------------

  bool _disposed = false;

  /// Returns thread 0 to the VM. Windows must be ordered out before this:
  /// once the loop stops, nothing on the main queue runs again.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    // The flag ends the watchdog's loop at its next look; the kill is for
    // a watchdog that is mid-sleep when the process wants to exit. The flag
    // itself is never freed - the watchdog may still read it once.
    _inFlight.value = -1;
    _watchdog?.kill(priority: Isolate.immediate);
    _watchdog = null;
    _unpark();
  }

  void _unpark() {
    // The old handler first, so no SIGUSR2 re-enters during teardown.
    if (_previousHandler != nullptr || _parked) {
      _signal(_sigusr2, _previousHandler);
    }
    if (_keepAlive != nullptr) {
      _coreFoundation.lookupFunction<
          Void Function(_VoidPtr, _VoidPtr, _VoidPtr),
          void Function(_VoidPtr, _VoidPtr, _VoidPtr)>('CFRunLoopRemoveSource')(
        _mainRunLoop,
        _keepAlive,
        _defaultMode,
      );
      _cfRelease(_keepAlive);
      _keepAlive = nullptr;
    }
    _coreFoundation.lookupFunction<Void Function(_VoidPtr),
        void Function(_VoidPtr)>('CFRunLoopStop')(_mainRunLoop);
    _coreFoundation.lookupFunction<Void Function(_VoidPtr),
        void Function(_VoidPtr)>('CFRunLoopWakeUp')(_mainRunLoop);
    _parked = false;
  }
}

/// What a main-thread [AppKitSignalSession.call] returns.
enum MainReturn { none, object, integer, boolean }
