/// The dispatcher contract, per section 9.4 of the roadmap.
library;

import 'dispatcher_priority.dart';
import 'timer_handle.dart';

/// The single point through which work reaches the UI thread.
///
/// Every backend owns one: Win32 pumps `GetMessage`/`DispatchMessage`, AppKit
/// pumps an `NSRunLoop`, X11/Wayland poll a file descriptor, the web driver
/// rides `requestAnimationFrame`, and the headless backend runs a
/// `ManualDispatcher`. They differ in how they *wait*; they do not differ in
/// what they promise, and the promises below are what the widget, layout and
/// render layers are allowed to rely on.
///
/// ## Ordering guarantee
///
/// This is a contract, not an implementation detail. Every implementation
/// commits to it:
///
/// 1. **Strict priority between priorities.** If any callback is pending at a
///    more urgent [DispatcherPriority], no less urgent callback runs. This
///    holds continuously, not just at the moment of posting: a callback
///    posted at [DispatcherPriority.input] from inside a
///    [DispatcherPriority.idle] callback runs before the remaining idle work,
///    not after it.
/// 2. **FIFO within a priority.** Two callbacks posted at the same priority
///    run in the order they were posted. No implementation may reorder them
///    for throughput, batching or deduplication.
/// 3. **No pre-emption.** A callback always runs to completion. A more urgent
///    post arriving while it runs is honoured at the next dispatch point, not
///    by interrupting it. Callbacks therefore never need locks against each
///    other on the UI thread, and the whole frame pipeline gets to assume
///    single-threaded mutation.
/// 4. **Timers are ordered by due time**, and a timer due at or before now
///    ranks against queued callbacks only by when the dispatcher notices it -
///    a timer is a *lower bound* on a delay, never a deadline. Two timers due
///    at the same instant fire in the order they were scheduled.
///
/// Point 3 is what makes points 1 and 2 useful. Without it, "runs before"
/// would say nothing about what state a callback observes.
abstract interface class UiDispatcher {
  /// Whether the calling thread is the one that owns this dispatcher.
  ///
  /// Not a mutex and not advisory. On every platform the framework targets,
  /// the window, its event queue and its message pump have hard thread
  /// affinity: Win32 delivers messages to the thread that created the window,
  /// and AppKit aborts the process outright if `NSWindow` is touched off the
  /// main thread - measured in this repository's POC-03, not assumed.
  ///
  /// So this getter answers exactly one question: *may I call UI methods
  /// directly, right now, or must I go through [post]?* Code that mutates the
  /// tree, the window or the renderer asserts on it. Code that merely wants
  /// to hand work over does not need to ask - it can always [post].
  ///
  /// Note that "thread" and "isolate" are not the same question. A Dart
  /// isolate is not pinned to a thread by the VM, and the main isolate is not
  /// the process main thread; an implementation must answer this with a real
  /// per-platform check, never by comparing isolate identity.
  bool get hasThreadAccess;

  /// Queues [callback] to run on the dispatcher's thread at [priority].
  ///
  /// Legal from any thread and from inside another callback. The queue takes
  /// ownership of the closure; there is no handle and no way to un-post, by
  /// design - a caller that needs to cancel should check a flag it owns.
  ///
  /// Implementations must ensure the loop *notices* the new work. That is the
  /// whole reason [wake] exists: a dispatcher that is idle is not spinning,
  /// it is blocked inside a native wait - `GetMessage`, `CFRunLoopRun`,
  /// `poll` - and a plain enqueue from another thread touches only Dart
  /// memory. The blocked thread has no reason to look at that memory and will
  /// sit there until some *native* event arrives, which for an idle
  /// application may be never. Waking is therefore part of posting, not an
  /// optimisation on top of it.
  void post(
    void Function() callback, {
    DispatcherPriority priority = DispatcherPriority.defaultPriority,
  });

  /// Arms a one-shot timer that runs [callback] no earlier than [delay] from
  /// now, and returns a handle that can cancel it.
  ///
  /// [delay] is a lower bound. A dispatcher servicing a long callback, a
  /// blocking native call or a busy frame will fire late; it must never fire
  /// early. A negative [delay] is treated as [Duration.zero] rather than
  /// rejected, because clamping is what every caller computing
  /// `deadline - now` actually wants.
  ///
  /// The returned [TimerHandle] is safe to cancel twice, after firing, or
  /// from inside the callback itself.
  TimerHandle schedule(Duration delay, void Function() callback);

  /// Forces the loop to leave its native wait and re-examine its queues.
  ///
  /// Callable from any thread - that is the point of it. [post] already wakes
  /// the loop; [wake] is exposed separately for the cases where the thing the
  /// loop must re-examine is not a queued callback: a native event pushed
  /// from a device-notification thread, a timer rearmed from a worker, a
  /// shutdown flag flipped by a signal handler.
  ///
  /// Must be cheap and idempotent. Several wakes collapsing into one pass of
  /// the loop is correct behaviour, not a missed event.
  void wake();

  /// Runs the loop on the calling thread until [stop] is requested.
  ///
  /// Blocks. The calling thread must be the owning thread, and for backends
  /// with main-thread affinity this is the call that never returns until the
  /// application is shutting down.
  void run();

  /// Requests that [run] return.
  ///
  /// Callable from inside a callback and from another thread; idempotent, and
  /// harmless when the loop is not running. It is a *request*: the currently
  /// executing callback is never interrupted, and work already queued is not
  /// silently discarded - it stays queued, so a caller that must flush it can
  /// do so before shutting down.
  void stop();
}
