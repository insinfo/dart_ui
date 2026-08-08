/// A dispatcher with no clock, no thread and no event loop of its own.
///
/// This is the backbone of the framework's tests and of the future headless
/// backend, so its value is entirely in being *exact*: the same inputs must
/// produce the same interleaving on a fast machine, on a loaded CI runner and
/// under a debugger. Nothing here reads the wall clock. Time only moves when
/// [ManualDispatcher.advance] says it moves.
library;

import 'dart:collection';

import 'dispatcher_priority.dart';
import 'timer_handle.dart';
import 'ui_dispatcher.dart';

/// What a [ManualDispatcher] does with an error escaping a callback, when the
/// owner has chosen to keep pumping instead of letting it propagate.
typedef DispatcherErrorHandler = void Function(
  Object error,
  StackTrace stackTrace,
);

/// A fully deterministic [UiDispatcher] driven by an explicit virtual clock.
///
/// Drive it with [drain] (run what is runnable now), [advance] (let virtual
/// time pass) or [run] (both, to quiescence). It never blocks, never sleeps
/// and never consults `DateTime.now`.
///
/// ## Virtual time
///
/// [elapsed] starts at [Duration.zero] and moves only inside [advance] and
/// [run]. A timer scheduled for 24 hours from now fires in microseconds of
/// real time; a test that takes a second to run does not perturb any
/// scheduling decision. Time never moves backwards - [advance] rejects a
/// negative delta rather than quietly clamping it, because a negative delta
/// is always a bug in the caller's arithmetic and never an intent.
///
/// ## What [advance] runs, and why
///
/// [advance] does not just fire timers; it services the callback queue at
/// every virtual instant it visits - before the first timer, between
/// consecutive timers, and after reaching the target. A real loop between two
/// timer ticks also drains its queue, and a dispatcher that skipped that
/// would let tests observe a state no production backend can ever produce:
/// a timer firing while a callback posted before it is still pending.
///
/// The consequence, stated explicitly because it is the question everyone
/// asks: **work posted or scheduled from inside a callback runs in the same
/// [advance]**, provided it comes due within the window. A timer callback at
/// t=10ms that schedules another timer for +5ms during an `advance(50ms)`
/// sees that second timer fire at t=15ms, in the same call. This is what
/// makes `advance(3s)` equivalent to three `advance(1s)` calls, which is the
/// property that lets a test change its time granularity without changing
/// its expectations.
///
/// ## Errors
///
/// Default policy: **propagate, do not swallow**. A callback that throws
/// aborts the pump and the error reaches the caller of [drain], [advance] or
/// [run] with its original stack trace intact. The queue is not corrupted -
/// every callback is removed from its queue, and every timer marked fired,
/// *before* being invoked - so the failed callback never runs twice and the
/// remaining work stays pending. Calling [drain] or [advance] again resumes
/// from exactly where the failure left off.
///
/// Pass [onError] to keep pumping instead. That reports the error and
/// continues with the next callback; it still never discards it silently,
/// which is the rule this repository's diagnostics layer exists to enforce.
///
/// ## Re-entrancy
///
/// [post], [schedule] and [TimerHandle.cancel] are legal from inside a
/// callback and are the normal way to build a pipeline. [drain], [advance]
/// and [run] are not: calling one from inside a callback throws a
/// [StateError]. A nested pump would run queued work in the middle of a
/// callback that the ordering guarantee says cannot be pre-empted, so the
/// only honest options are to forbid it or to silently break the contract.
final class ManualDispatcher implements UiDispatcher {
  /// Creates a dispatcher with an empty queue and a virtual clock at zero.
  ///
  /// [hasThreadAccess] is a test seam: a manual dispatcher has no real thread
  /// affinity, so it answers whatever the test needs in order to exercise
  /// code that branches on it.
  ///
  /// [runawayLimit] bounds a single pump. See [runawayLimit].
  ManualDispatcher({
    bool hasThreadAccess = true,
    this.onError,
    this.runawayLimit = 100000,
  })  : _hasThreadAccess = hasThreadAccess,
        _queues = List<ListQueue<void Function()>>.generate(
          DispatcherPriority.values.length,
          (_) => ListQueue<void Function()>(),
          growable: false,
        ) {
    if (runawayLimit < 1) {
      throw ArgumentError.value(
        runawayLimit,
        'runawayLimit',
        'must be at least 1',
      );
    }
  }

  /// Where errors escaping a callback go. Null means they propagate to
  /// whoever called [drain], [advance] or [run].
  final DispatcherErrorHandler? onError;

  /// How many callbacks or timer firings one pump may perform before it is
  /// declared a runaway and throws a [StateError].
  ///
  /// This is not a scheduling policy - no correct program comes near it. It
  /// exists because virtual time makes one failure mode uniquely nasty: a
  /// timer that reschedules itself with [Duration.zero] is due again at the
  /// same virtual instant it just fired, and unlike a real clock, this one
  /// will not save you by moving on. Under a real loop that program spins
  /// hot; here it hangs forever and CI reports a timeout with no stack. A
  /// named error at a fixed budget is strictly better evidence.
  final int runawayLimit;

  final bool _hasThreadAccess;
  final List<ListQueue<void Function()>> _queues;
  final List<_ScheduledTimer> _timers = <_ScheduledTimer>[];

  Duration _elapsed = Duration.zero;
  int _wakeCount = 0;
  bool _pumping = false;
  bool _running = false;
  bool _stopRequested = false;

  /// Virtual time since construction. Moves only in [advance] and [run].
  Duration get elapsed => _elapsed;

  /// When the next pending timer comes due, in [elapsed] terms, or null if no
  /// timer is armed.
  Duration? get nextTimerDue => _timers.isEmpty ? null : _timers.first.dueAt;

  /// Callbacks posted and not yet run, across all priorities.
  int get pendingCallbackCount =>
      _queues.fold<int>(0, (total, queue) => total + queue.length);

  /// Timers armed and neither fired nor cancelled.
  int get pendingTimerCount => _timers.length;

  /// How many times [wake] has been called.
  ///
  /// A manual dispatcher never blocks, so there is nothing to wake and [wake]
  /// does no work. The count is kept so a test can assert that code under
  /// test follows the cross-thread protocol - that it wakes the loop after
  /// touching state the loop cannot otherwise notice. [post] and [schedule]
  /// deliberately do *not* bump it: this counter measures explicit wakes.
  int get wakeCount => _wakeCount;

  /// Whether [run] is currently pumping.
  bool get isRunning => _running;

  @override
  bool get hasThreadAccess => _hasThreadAccess;

  @override
  void post(
    void Function() callback, {
    DispatcherPriority priority = DispatcherPriority.defaultPriority,
  }) {
    _queues[priority.index].addLast(callback);
  }

  @override
  TimerHandle schedule(Duration delay, void Function() callback) {
    final handle = TimerHandle(onCancel: _forgetTimer);
    final dueAt = delay.isNegative ? _elapsed : _elapsed + delay;
    _arm(_ScheduledTimer(dueAt: dueAt, callback: callback, handle: handle));
    return handle;
  }

  @override
  void wake() {
    _wakeCount++;
  }

  /// Runs every queued callback, in priority then FIFO order, until the queue
  /// is empty.
  ///
  /// Callbacks posted while draining are part of the same drain - "until
  /// empty" means empty, not "until the callbacks present on entry are
  /// done" - and a post at a more urgent priority jumps ahead of the work
  /// still queued below it.
  ///
  /// Virtual time does not move, so timers do not fire here even if one is
  /// already due; use [advance] or [run] for that.
  void drain() {
    _beginPump('drain');
    try {
      _drainQueues();
    } finally {
      _pumping = false;
    }
  }

  /// Moves virtual time forward by [delta], firing every timer that comes due
  /// in that window in time order and draining the callback queue at each
  /// instant visited.
  ///
  /// Timers due at the same instant fire in the order they were scheduled.
  /// [elapsed] is set to each timer's due time *before* its callback runs, so
  /// a timer that schedules another timer computes its delay from the right
  /// origin rather than from the end of the window.
  ///
  /// If a callback throws and no [onError] is set, the error propagates and
  /// [elapsed] is left at the instant of the failed callback, with the
  /// remaining timers still armed. The window can be finished with a second
  /// [advance] of the remainder.
  void advance(Duration delta) {
    if (delta.isNegative) {
      throw ArgumentError.value(
        delta,
        'delta',
        'virtual time cannot move backwards',
      );
    }
    _beginPump('advance');
    try {
      _pumpUntil(_elapsed + delta);
    } finally {
      _pumping = false;
    }
  }

  /// Pumps callbacks and timers until [stop] is requested or the dispatcher
  /// falls quiescent.
  ///
  /// A backend's `run` blocks in a native wait and returns only on [stop].
  /// There is nothing here to wait *for*: no thread will ever post to this
  /// dispatcher while it spins, so waiting would be a deadlock dressed up as
  /// a loop. Instead this one fast-forwards - it drains the queue, then jumps
  /// [elapsed] straight to the next timer's due time and fires it, and
  /// repeats. It returns when [stop] is requested or when the queue is empty
  /// and no timer is armed.
  ///
  /// That makes `run()` the "settle this dispatcher completely" call: it is
  /// [advance] with the window chosen for you. Note it therefore *does* move
  /// virtual time, and that a timer which reschedules itself keeps it running
  /// forever - by design, since that is a live application, and [stop] is how
  /// a live application ends.
  ///
  /// [stop] takes effect after the running callback finishes; work still
  /// queued at that point stays queued.
  @override
  void run() {
    _beginPump('run');
    _running = true;
    _stopRequested = false;
    try {
      while (!_stopRequested) {
        _drainQueues();
        if (_stopRequested || _timers.isEmpty) break;
        _fireNextTimer();
      }
    } finally {
      _running = false;
      _stopRequested = false;
      _pumping = false;
    }
  }

  @override
  void stop() {
    _stopRequested = true;
  }

  void _beginPump(String caller) {
    if (_pumping) {
      throw StateError(
        'ManualDispatcher.$caller() was called from inside a callback. '
        'A nested pump would run queued work in the middle of a callback '
        'that the dispatcher contract says cannot be pre-empted. Post the '
        'work instead; it will run in this same pump.',
      );
    }
    _pumping = true;
  }

  void _pumpUntil(Duration target) {
    var firings = 0;
    _drainQueues();
    while (_timers.isNotEmpty && _timers.first.dueAt <= target) {
      if (++firings > runawayLimit) {
        throw StateError(
          'ManualDispatcher.advance() fired $runawayLimit timers without '
          'reaching the end of the window. A timer is almost certainly '
          'rescheduling itself at the same virtual instant, which virtual '
          'time cannot escape on its own.',
        );
      }
      _fireNextTimer();
      _drainQueues();
    }
    _elapsed = target;
    _drainQueues();
  }

  /// Fires the earliest armed timer, moving [elapsed] to its due time first
  /// so the callback observes the instant it was scheduled for.
  void _fireNextTimer() {
    final timer = _timers.removeAt(0);
    _elapsed = timer.dueAt;
    timer.handle.markFired();
    _invoke(timer.callback);
  }

  void _drainQueues() {
    var executed = 0;
    for (var callback = _takeNext(); callback != null; callback = _takeNext()) {
      if (++executed > runawayLimit) {
        throw StateError(
          'ManualDispatcher ran $runawayLimit callbacks without emptying '
          'the queue. A callback is almost certainly re-posting itself.',
        );
      }
      _invoke(callback);
    }
  }

  /// The most urgent pending callback, oldest first within its priority.
  ///
  /// Re-read on every iteration rather than snapshotted, which is what makes
  /// an urgent post from inside a callback overtake the work queued below it.
  void Function()? _takeNext() {
    for (final queue in _queues) {
      if (queue.isNotEmpty) return queue.removeFirst();
    }
    return null;
  }

  /// Runs [callback] under the configured error policy.
  ///
  /// The no-handler path has no `try` at all, so the error reaches the caller
  /// exactly as it was thrown - same object, same stack trace, no rethrow
  /// frame in the middle of it.
  void _invoke(void Function() callback) {
    final handler = onError;
    if (handler == null) {
      callback();
      return;
    }
    try {
      callback();
    } catch (error, stackTrace) {
      handler(error, stackTrace);
    }
  }

  /// Inserts at the upper bound of its due time, so timers due at the same
  /// instant keep scheduling order without carrying a sequence number.
  void _arm(_ScheduledTimer timer) {
    var low = 0;
    var high = _timers.length;
    while (low < high) {
      final mid = (low + high) >> 1;
      if (_timers[mid].dueAt > timer.dueAt) {
        high = mid;
      } else {
        low = mid + 1;
      }
    }
    _timers.insert(low, timer);
  }

  void _forgetTimer(TimerHandle handle) {
    _timers.removeWhere((timer) => identical(timer.handle, handle));
  }
}

final class _ScheduledTimer {
  _ScheduledTimer({
    required this.dueAt,
    required this.callback,
    required this.handle,
  });

  /// Absolute virtual time, not a delay - a pending timer must not shift when
  /// the clock moves.
  final Duration dueAt;
  final void Function() callback;
  final TimerHandle handle;
}
