# [vm/standalone][ffi] Expose a supported process-main-thread takeover API

## Summary

Standalone Dart currently has no supported way to execute native or Dart/FFI
work on the **process main thread**.

This prevents pure Dart standalone applications from safely using APIs such as
AppKit, even when all Objective-C runtime and ABI bindings are implemented with
`dart:ffi`.

I propose adding an opt-in, low-level API that lets the standalone embedder call
a native ABI entry point directly from the process' first native thread:

```dart
typedef ProcessMainThreadEntryNative =
    IntPtr Function(Pointer<Void> context);

abstract final class ProcessMainThread {
  static bool get isSupported;
  static bool get isCurrent;

  static Future<int> runNative(
    Pointer<NativeFunction<ProcessMainThreadEntryNative>> entryPoint,
    Pointer<Void> context,
  );
}
```

Naming and library placement are intentionally provisional.

The important semantic requirement is that the entry point is called directly
by the native launcher, outside a `CFRunLoopSource`, libdispatch work item,
`NSTimer`, or other platform-event-loop callback. This allows the entry point to
install and run the platform's top-level event loop.

## Related work

This proposal builds on:

- https://github.com/dart-lang/sdk/issues/38315
- https://github.com/dart-lang/sdk/issues/52106
- https://github.com/dart-lang/sdk/issues/46943
- https://github.com/dart-lang/sdk/issues/56841
- https://github.com/dart-lang/language/blob/main/working/333%20-%20shared%20memory%20multithreading/shared_native_memory.md

The current SDK `main` branch already contains major building blocks:

```dart
NativeCallable.isolateGroupBound
Isolate.create
Isolate.runSync
Isolate.shutdownSync
Isolate.pinToCurrentThread
Isolate.isPinnedToCurrentThread
Isolate.runEventLoopSync
Isolate.onEvent
Isolate.handleEvent
```

The current VM patch implements the first group of `Isolate` APIs, while
`onEvent` and `handleEvent` still throw `UnsupportedError`.

## Measured behavior

A macOS arm64 spike is available here:

- repository: https://github.com/insinfo/dart_ui
- document: `doc/SPIKE_MACOS_MAIN_THREAD.md`
- probe: `poc/poc_03_appkit_window/bin/probe.dart`
- workflow run: https://github.com/insinfo/dart_ui/actions/runs/31078303894
- tested SHA: `20d3e3aa4f9f158a52918902f77c4cc3fd3dc8d9`

All three execution modes run Dart code off the process main thread:

```text
dart run:
pthread_main_np() = 0

dartaotruntime snapshot:
pthread_main_np() = 0

AOT executable:
pthread_main_np() = 0
```

The process main thread remains alive.

The spike then established:

| Probe | Result |
|---|---|
| Dispatch to an undrained main queue | blocks |
| Reach WindowServer off the main thread | works |
| Force the first thread into `CFRunLoopRun` | works experimentally |
| Create `NSWindow` there through `NSInvocation` | works |
| Create a WindowServer window with `SLSNewWindow` | works |
| Keep Dart timers, async I/O and isolates alive | works |
| Deliver a call from the UI thread to Dart | works |
| Run `[NSApplication run]` from the hijacked-loop callback | aborts with `SIGTRAP` |
| Manually pump `nextEventMatchingMask:` | unresolved |

The signal approach is a proof only. It is not suitable for production because
the function type is incompatible with a signal handler,
`CFRunLoopRun` is not async-signal-safe, the interrupted context is
uncontrolled, and normal process shutdown is lost.

## Why this belongs in the standalone embedder

The native entry point is already under SDK control:

```cpp
int main(int argc, char** argv) {
  dart::bin::main(argc, argv);
  UNREACHABLE();
}
```

`RunMainIsolate` eventually calls `Dart_RunLoop()`.

The current `Dart_RunLoop()` implementation:

1. exits the current isolate;
2. starts the isolate message handler on the isolate group's thread pool;
3. waits on a native monitor;
4. re-enters the isolate only after the message loop finishes.

Conceptually:

```cpp
Dart_ExitIsolate();

isolate->message_handler()->Run(
    isolate->group()->thread_pool(),
    RunLoopDone,
    &data);

while (!data.done) {
  monitor.Wait();
}

Dart_EnterIsolate(isolate);
```

This explains why Dart code is not on the first thread while that thread remains
alive and mostly idle.

It also provides a natural implementation point: wake the monitor for either
isolate completion or a pending process-main-thread request.

## Proposed semantics

```dart
Future<int> ProcessMainThread.runNative(
  Pointer<NativeFunction<ProcessMainThreadEntryNative>> entryPoint,
  Pointer<Void> context,
)
```

- The requesting isolate remains on VM-managed threads.
- The returned future completes when the native entry point returns.
- The entry point runs with no current Dart isolate on the process main thread.
- At most one entry point may be active.
- The entry point may remain blocked in a platform event loop.
- The request keeps the process and relevant runtime state alive.
- The entry point must eventually return for normal VM shutdown.
- Embedders without an implementation expose `isSupported == false`.
- `NativeCallable.isolateLocal` is not valid as the entry point.
- `NativeCallable.isolateGroupBound` is the intended pure-Dart bridge.

Example:

```dart
typedef MainEntryNative =
    IntPtr Function(Pointer<Void> context);

int appKitMain(Pointer<Void> context) {
  if (!ProcessMainThread.isCurrent) {
    return -1;
  }

  initializeNSApplication(context);
  createInitialWindow(context);

  // A top-level call from the launcher, not a run-loop callback.
  runNSApplication();
  return 0;
}

Future<void> startUi(Pointer<Void> context) async {
  final entry =
      NativeCallable<MainEntryNative>.isolateGroupBound(
        appKitMain,
        exceptionalReturn: -2,
      );

  try {
    final result = await ProcessMainThread.runNative(
      entry.nativeFunction,
      context,
    );
    if (result != 0) {
      throw StateError('Platform main loop failed: $result');
    }
  } finally {
    entry.close();
  }
}
```

The normal `isolateGroupBound` restrictions apply. Ordinary non-shared static
state cannot be accessed from the bootstrap callback. State can be passed in
native memory or through future shared-state APIs.

## Why a top-level takeover is needed

A main-thread task executor based only on:

- `dispatch_async`;
- `CFRunLoopSource`;
- `performSelectorOnMainThread:`;
- `NSTimer`;

is insufficient for bootstrapping arbitrary UI toolkits.

Those mechanisms run a task as a callout of an already-running loop. The spike
successfully created an `NSWindow` that way, but `[NSApplication run]` aborted
when entered from the hijacked-loop callback.

The SDK should therefore guarantee:

```text
native main()
  -> process-main-thread entry point
     -> platform main loop
```

rather than merely:

```text
native main()
  -> generic loop
     -> scheduled callback
        -> platform main loop
```

## Standalone implementation sketch

The `Dart_RunLoop()` wait path could coordinate both isolate completion and
main-thread requests:

```cpp
while (!isolate_done) {
  monitor.WaitUntil([&] {
    return isolate_done || main_thread_requests.HasPending();
  });

  if (main_thread_requests.HasPending()) {
    auto request = main_thread_requests.Take();

    monitor.Exit();
    const intptr_t result = request.entry(request.context);
    monitor.Enter();

    request.Complete(result);
  }
}
```

A real implementation needs a process-lifetime coordinator rather than a
stack-local request queue.

An embedder hook may be appropriate to preserve layering:

```c
typedef bool (*Dart_ProcessMainThreadRunner)(
    Dart_ProcessMainThreadEntry entry,
    void* context,
    Dart_Port completion_port);

DART_EXPORT void Dart_SetProcessMainThreadRunner(
    Dart_ProcessMainThreadRunner runner);
```

The standalone embedder installs the default implementation. Other embedders
may install their own or report unsupported.

## Interaction with external isolate event loops

Once `Isolate.onEvent` and `Isolate.handleEvent` are implemented, a full UI
isolate can be integrated with the platform loop:

```text
process main thread
  platform event loop
    -> receives isolate notification
    -> calls uiIsolate.handleEvent()

UI isolate
  Isolate.create()
  runSync(initialization)
  pinToCurrentThread()
  onEvent(wake platform loop)
```

`onEvent` must only notify the external loop. It must not call `handleEvent`
directly, matching the current API documentation.

## Communication after startup

### Dart to UI

Once the platform loop is active, the package can use the platform's normal
mechanisms, such as the main dispatch queue or
`performSelectorOnMainThread:`.

### UI to Dart, asynchronous

`NativeCallable.listener` can deliver `void` callbacks to the original isolate.

### UI to Dart, synchronous

`NativeCallable.isolateGroupBound` can support synchronous return values, subject
to shared-state restrictions.

## Alternatives

### Start the main isolate on the first thread

This may still be useful as a separate mode, but it does not solve event-loop
integration by itself. A blocking platform loop prevents the isolate's regular
event queue from progressing unless additional integration is provided.

### Dedicated isolate thread

A dedicated thread solves affinity and TLS use cases, but on macOS a newly
created thread is not the process main thread.

### `@Native(runOnMainThread: true)`

This could be future syntactic sugar for short calls, but requires the underlying
executor/takeover infrastructure and does not define lifecycle.

### Private WindowServer APIs

They are unstable, unsuitable for App Store applications, and do not provide the
full AppKit event/input/accessibility stack.

### Custom embedder

This works today, and the in-progress Dart Engine API is a useful foundation.
However, every consumer must then build and distribute native launcher code.
The standalone embedder can solve the common case once.

## Acceptance criteria

### Runtime

- JIT, AOT snapshot, and AOT executable.
- macOS arm64 and x64.
- Callback observes `pthread_main_np() == 1`.
- No signal hijacking or executable-memory tricks.
- Existing CLI behavior is unchanged when unused.
- Concurrent and nested requests have defined behavior.

### AppKit integration

- `NSApplication` initializes.
- `[NSApplication run]` starts without aborting.
- An `NSWindow` can be shown, focused, and closed.
- Keyboard and mouse events are delivered.
- Menu, activation, and IME behavior are functional.

### Dart health

- Timers, async I/O, spawned isolates, GC, VM Service and profiler continue to
  operate while the platform loop owns the first thread.
- Bidirectional communication works.

### Shutdown

- No `_exit()`.
- The entry point returns.
- VM cleanup and normal process exit run.
- `SIGINT` and `SIGTERM` keep defined behavior.

## Suggested staging

1. Discuss API and lifecycle in `#38315` or a linked design issue.
2. Add an experimental standalone macOS implementation.
3. Add thread-identity and lifecycle tests.
4. Add an AppKit integration test on a bot with a logged-in graphical session.
5. Implement `Isolate.onEvent` and `Isolate.handleEvent`.
6. Add Windows and Linux embedder implementations where useful.
