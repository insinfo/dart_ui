/// The policy every blocking wait in this layer obeys, in one file.
///
/// Two rules, and both of them exist because of a specific failure:
///
///   * **No wait is unbounded.** `AcquireSRWLockExclusive`,
///     `pthread_mutex_lock` and the `INFINITE` form of
///     `SleepConditionVariableSRW` all hang forever when the isolate that held
///     the lock died inside its critical section. A native lock is not a Dart
///     object: nothing reclaims it, nothing notices, and the application stops
///     with no message. Section 68.4.4 of the roadmap already documents what
///     that looks like from the outside - the Win32 modal loop that froze the
///     window - and the conclusion there applies here: a bounded wait that
///     fails by name beats a correct wait that can hang.
///   * **A blocking wait refuses to run on the isolate that services the UI.**
///     Blocking there is not slow, it is a dead application: no frames, no
///     input, no repaint, until the producer happens to deliver.
library;

import 'dart:isolate';

/// How long a wait runs before it gives up and says so.
///
/// Five seconds is far beyond any legitimate frame handoff - the ring holds
/// three slots at 25 frames a second, so a consumer that has waited more than
/// a tenth of a second is already in trouble - and short enough that a stuck
/// pipeline surfaces while somebody is still watching it. Callers with a real
/// deadline should pass their own.
const Duration defaultBlockingWaitTimeout = Duration(seconds: 5);

/// How long [NativeMutex.acquire] waits for a lock that is held.
///
/// Every critical section in this layer copies a handful of integers, so the
/// honest expectation is nanoseconds. Two seconds is not a budget, it is the
/// point at which "the holder is still running" stops being credible.
const Duration defaultLockTimeout = Duration(seconds: 2);

/// The longest single native wait, in milliseconds.
///
/// A wait is chopped into slices of at most this length and the slices are
/// counted against a Dart [Stopwatch] rather than against the deadline the
/// operating system was given. That buys two things:
///
///   * **A monotonic deadline.** `pthread_cond_timedwait` measures against
///     `CLOCK_REALTIME`, so somebody setting the system clock backwards would
///     otherwise extend a wait without bound.
///   * **A pulse.** A consumer parked on a producer that has died wakes four
///     times a second, notices nothing has changed, and eventually reports the
///     timeout. It is still *blocking* - four syscalls a second is not a spin
///     loop, and `BlockingSlotMailbox.nativeWaitCount` is exposed so a test can
///     tell the difference.
const int maxNativeWaitSliceMilliseconds = 250;

/// A bounded wait that ran out of time.
///
/// Deliberately not a [StateError]: running out of time is a thing callers
/// recover from - drop the frame, retry, report a stalled decoder - and it must
/// be catchable without also catching a programming error.
final class BlockingWaitTimeout implements Exception {
  const BlockingWaitTimeout(this.operation, this.waited);

  /// What was being waited for, spelled the way the call site spells it.
  final String operation;

  final Duration waited;

  @override
  String toString() =>
      'BlockingWaitTimeout: $operation did not complete within '
      '${waited.inMilliseconds} ms';
}

/// A blocking wait was attempted on the isolate that runs the event loop.
///
/// An [Error] and not an [Exception], because there is no recovery: the code
/// that called it is in the wrong place, and catching this to retry would only
/// freeze the window a second time.
final class BlockingWaitOnRootIsolateError extends Error {
  BlockingWaitOnRootIsolateError(this.operation);

  final String operation;

  @override
  String toString() =>
      'BlockingWaitOnRootIsolateError: $operation parks the calling thread, '
      'and it was called on the root isolate. On the isolate that services '
      'the UI that is not a slow frame, it is a frozen window - no repaint, '
      'no input, nothing - for as long as the producer takes. Use the '
      'non-blocking form (tryTake/tryPut) here and keep the blocking form in '
      'a spawned isolate, or call '
      'BlockingWaitPolicy.allowOnThisIsolate() if this isolate really does '
      'not drive a window.';
}

/// Decides whether the calling isolate may park itself.
///
/// ## How the root isolate is recognised, and what that check cannot do
///
/// `Isolate.current.debugName` is `'main'` on the root isolate of a Dart VM,
/// and on a spawned isolate it is the name passed to `Isolate.spawn` or, when
/// none was passed, the name of the entry point function. Both halves were
/// measured on SDK 3.6.2 rather than assumed.
///
/// So the check has exactly one blind spot: an isolate spawned over a function
/// that is itself called `main` is misread as the root. That is a false
/// *positive* - it refuses a wait that would have been legal - which is the
/// direction a guard should fail in, and [allowOnThisIsolate] is the way out.
///
/// This is a guard against a mistake, not a security boundary. It exists
/// because "do not block on the UI isolate" is a rule that is obeyed for
/// months and then broken by one convenient call.
final class BlockingWaitPolicy {
  BlockingWaitPolicy._();

  /// Static state is per-isolate in Dart, which is exactly the scope wanted:
  /// permission granted in a worker says nothing about the root isolate.
  static bool _allowed = false;

  static bool get isRootIsolate => Isolate.current.debugName == 'main';

  /// Declares that this isolate drives no window and may park.
  ///
  /// For a worker whose entry point happens to be named `main`, and for a test
  /// that deliberately exercises the blocking path in the test runner's own
  /// isolate.
  static void allowOnThisIsolate() => _allowed = true;

  /// Restores the refusal. Pairs with [allowOnThisIsolate] in a test.
  static void refuseOnThisIsolate() => _allowed = false;

  /// Throws [BlockingWaitOnRootIsolateError] unless parking is allowed here.
  static void check(String operation) {
    if (_allowed || !isRootIsolate) return;
    throw BlockingWaitOnRootIsolateError(operation);
  }
}

/// The whole timeout in whole milliseconds, rounded up.
///
/// Rounded up rather than truncated because `Duration(microseconds: 500)`
/// truncates to zero, and a zero-millisecond native wait returns instantly -
/// which would turn a short timeout into the spin loop this layer exists to
/// avoid. Zero stays zero: it is the documented "poll once" spelling.
int millisecondsCeil(Duration timeout) {
  final int microseconds = timeout.inMicroseconds;
  if (microseconds <= 0) return 0;
  return (microseconds + 999) ~/ 1000;
}
