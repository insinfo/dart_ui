# [vm][isolate] Implement `Isolate.onEvent` and `Isolate.handleEvent` for external event loops

## Summary

Dart's `main` branch already declares the two primitives needed to host an
isolate inside a native platform event loop:

```dart
@Since("3.13")
external void set Isolate.onEvent(void Function(Isolate) callback);

@Since("3.13")
external void Isolate.handleEvent();
```

Their public contract says that `onEvent` notifies an external loop from an
arbitrary thread and that the external loop later calls `handleEvent`, which
handles at most one pending event. In the VM patch library both methods still
throw `UnsupportedError`.

Audit baseline: [`dart-lang/sdk@741e464`](https://github.com/dart-lang/sdk/commit/741e4646241d0d1940ccb67c428a24e06357d4a7),
the `main` HEAD inspected on August 7, 2026.

Please implement these existing APIs for the Dart VM and specify their
ownership, teardown, timer, and reentrancy semantics. This would let packages
integrate Win32, X11, Wayland, and AppKit loops without fixed-interval polling
or a custom native embedder.

## Why this is needed

A native UI process has two independent queues:

- the platform queue (`WM_*`, XCB/Wayland events, `NSEvent`);
- the Dart isolate queue (ports, timers, microtasks, async I/O).

The platform wait must be allowed to block when both queues are idle, but it
must wake as soon as either queue has work. Today a pure-Dart FFI package cannot
ask the VM to notify the native wait. It therefore uses a fixed timeout and an
artificial asynchronous yield:

```dart
while (running) {
  drainNativeEvents();
  nativeWait(timeout: const Duration(milliseconds: 50));
  drainNativeEvents();
  await Future<void>.delayed(Duration.zero);
}
```

An infinite native wait starves Dart timers and messages. A short timeout wastes
idle wakeups. A long timeout adds latency and reduces effective timer frequency.

`Isolate.runEventLoopSync` does not solve this composition problem. Its current
contract runs the isolate synchronously on the current thread and returns only
when the isolate has no keep-alive receive ports. A UI isolate normally keeps
ports alive for the lifetime of the application, so control is not returned to
the native loop between turns.

## Experimental evidence

[`poc_19_event_loop_metrics`](../../poc/poc_19_event_loop_metrics) compares the
current fixed-polling pattern with an oracle that has a kernel wakeup whenever
Dart work becomes ready. On Windows 11, Dart 3.6.2, three-second samples:

| Metric | Fixed polling, 50 ms | Wakeup oracle | Pure-Dart baseline |
|---|---:|---:|---:|
| Effective rate of a 60 Hz timer | 16.0 Hz | 59.2 Hz | 61.0 Hz |
| Cross-isolate message latency, p95 | 63.02 ms | 0.54 ms | 0.23 ms |
| Idle wakeups per second | 14.0 | 0.3 | 0 |

The exact values vary with the Windows timer quantum. The structural result is
stable: no fixed timeout simultaneously provides low latency, accurate frame
timers, and zero idle polling. Run the benchmark with:

```text
cd poc/poc_19_event_loop_metrics
dart run bin/main.dart
```

The repository also has working pure-Dart FFI windows on Win32 and X11. On
macOS, a separate problem is obtaining the process main thread for AppKit; a
SkyLight/CGS probe independently demonstrated window creation, drawing, and
input outside AppKit. Main-thread ownership and event-loop composition are
orthogonal issues.

## Requested behavior

No new public abstraction is required for the first implementation. Please
make the already-declared methods functional with the documented division of
responsibility:

1. `onEvent` is invoked once for every event the isolate must handle.
2. It can run on an arbitrary thread and outside any isolate.
3. It only signals the external loop; it must not call `handleEvent`.
4. The host loop later calls `handleEvent` on its owner thread.
5. Each `handleEvent` call handles at most one pending event and does not wait
   for new work.

Conceptually:

```dart
final isolate = Isolate.create(debugName: 'native-ui');
isolate.onEvent = (_) => incrementCounterAndWakeNativeLoop();

while (running) {
  nativeWaitForPlatformInputOrDartWake();
  drainPlatformEvents();

  pendingDartEvents += takeWakeCount();
  while (pendingDartEvents > 0) {
    pendingDartEvents--;
    isolate.handleEvent();
  }
}
```

The counter is intentional: `onEvent` promises one notification per new event
and `handleEvent` processes at most one. A coalesced boolean wakeup could lose
the number of required calls.

Platform wake mechanisms remain package policy:

- Win32: increment an atomic counter and `PostThreadMessage`;
- X11/Wayland: write to an `eventfd` included in `poll`;
- macOS: signal a `CFRunLoopSource` and call `CFRunLoopWakeUp`.

## Semantics that need to be explicit

- **Ownership:** when does the external loop become responsible for scheduling
  the created isolate, and can the VM also schedule it concurrently?
- **Replacement/removal:** how is an `onEvent` callback replaced or removed?
- **Timers:** does `onEvent` fire when a timer becomes ready even if there are
  no port messages or I/O completions? This is required to eliminate polling.
- **Accounting:** is every `onEvent` notification paired with at most one
  successful `handleEvent`, including events produced while handling another?
- **Reentrancy:** what happens if a modal native loop attempts to call
  `handleEvent` while another call is active?
- **Errors and shutdown:** how are uncaught errors delivered, and what happens
  to queued notifications after `shutdownSync`?

A next-deadline query may be useful later for native APIs that cannot be woken
by a callback, but it is not required if timer readiness reliably triggers
`onEvent`.

## Acceptance criteria

- A Win32 loop can wait indefinitely and is woken for ports, timers, and async
  I/O without fixed polling.
- A 16 ms timer has drift comparable to a normally scheduled Dart isolate.
- With no native input and no Dart work, the host performs zero periodic
  wakeups.
- Cross-isolate messages wake the host and are handled without timeout-bound
  latency.
- Notification accounting remains correct under bursts and nested native
  loops.
- JIT and AOT behave consistently on x64 and arm64.
- Existing isolates are unaffected when the API is not used.

## Related work

- `dart-lang/sdk#46943` — thread pinning; a June 2026 maintainer comment says
  the required functionality exists behind flags but is not ready to ship.
- `dart-lang/sdk#56841` — shared native memory multithreading.
- `dart-lang/sdk#38315` — macOS FFI and process-main-thread limitation.
- Working document 333 — shared memory multithreading.

## Primary references

- [`sdk/lib/isolate/isolate.dart`](https://github.com/dart-lang/sdk/blob/main/sdk/lib/isolate/isolate.dart)
- [`sdk/lib/_internal/vm/lib/isolate_patch.dart`](https://github.com/dart-lang/sdk/blob/main/sdk/lib/_internal/vm/lib/isolate_patch.dart)
- [`tests/ffi/threading_runeventloop_test.dart`](https://github.com/dart-lang/sdk/blob/main/tests/ffi/threading_runeventloop_test.dart)
- [`dart-lang/sdk#46943`](https://github.com/dart-lang/sdk/issues/46943)
- [`dart-lang/sdk#56841`](https://github.com/dart-lang/sdk/issues/56841)
- [Working document 333](https://github.com/dart-lang/language/tree/main/working/333%20-%20shared%20memory%20multithreading)
