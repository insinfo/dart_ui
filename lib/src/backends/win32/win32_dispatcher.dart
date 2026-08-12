/// Win32 message pump integrated with the `UiDispatcher` contract.
///
/// The Win32 message loop is fundamentally a blocking loop: `GetMessage`
/// sleeps until a message arrives, then `TranslateMessage`/`DispatchMessage`
/// deliver it synchronously to the `WndProc`.  Everything this dispatcher
/// does exists to marry that blocking loop to Dart's priority queue and
/// timer model without starving either side.
///
/// ## Wake strategy
///
/// When Dart code posts a callback from the same isolate, the message loop
/// must leave its native wait and re-examine the Dart queues.  The mechanism
/// is `PostMessage` to a message-only window — not `PostThreadMessage`,
/// for the reason documented in `Win32WindowingBackend.wake`.  The wake
/// message is `WM_APP + 1` (`wmAppWake`) and carries no data; its only
/// purpose is to bump `GetMessage` out of its sleep.
///
/// ## Timer strategy
///
/// `UiDispatcher.schedule` arms a Dart-side entry with a due time.  The
/// dispatcher does NOT use `SetTimer` for each one: `SetTimer` fires
/// `WM_TIMER` at `WM_TIMER` priority, which is lower than posted messages,
/// and a timer that is always outranked by input violates the priority
/// contract.  Instead, the dispatcher arms *one* native timer set to the
/// nearest due time, and when it fires, drains every timer that is at or
/// past its due time in due-time order.  `KillTimer` cleans up in
/// [stop] and [TimerHandle.cancel].
///
/// ## Frame interleaving
///
/// One pass of the loop:
///   1. Drain Dart queues at priorities above `normal` (immediate, input,
///      animation, layout, render).
///   2. Pump up to N native messages (default 32) — this is where `WndProc`
///      runs, and where input events turn into Dart callbacks.
///   3. Drain Dart queues again (the input just posted work).
///   4. If nothing is pending, enter `MsgWaitForMultipleObjectsEx` with
///      the timeout of the nearest timer.
///
/// The cap on native messages per pass is a starvation guard: a resize
/// flood generates hundreds of `WM_SIZE`/`WM_PAINT` per second, and without
/// a limit the Dart queue would never drain.
library;

import 'dart:collection';
import 'dart:ffi';

import '../../scheduler/dispatcher_priority.dart';
import '../../scheduler/timer_handle.dart';
import '../../scheduler/ui_dispatcher.dart';
import 'win32_api.dart';
import 'win32_constants.dart';
import 'win32_structs.dart';

/// A Win32-aware [UiDispatcher].
///
/// Owns the priority queues, the timer heap and the wake window.  Does NOT
/// own application windows — those belong to [Win32WindowingBackend].
final class Win32Dispatcher implements UiDispatcher {
  Win32Dispatcher({
    required Win32Api api,
    required int wakeWindowHandle,
    this.maxNativeMessagesPerPass = 32,
  })  : _api = api,
        _wakeHandle = wakeWindowHandle,
        _ownerThreadId = api.getCurrentThreadId();

  final Win32Api _api;
  final int _wakeHandle;
  final int _ownerThreadId;
  final Stopwatch _clock = Stopwatch()..start();

  /// How many native messages to dispatch before re-examining Dart queues.
  final int maxNativeMessagesPerPass;

  // One FIFO queue per priority.
  final List<Queue<void Function()>> _queues =
      List<Queue<void Function()>>.generate(
    DispatcherPriority.values.length,
    (_) => Queue<void Function()>(),
    growable: false,
  );

  // Timers ordered by due time.  A SplayTreeMap keyed by (dueTime, sequence)
  // ensures deterministic ordering when two timers are due at the same
  // instant.
  int _timerSequence = 0;
  final SplayTreeMap<_TimerKey, _TimerEntry> _timers =
      SplayTreeMap<_TimerKey, _TimerEntry>();

  bool _running = false;
  bool _stopRequested = false;

  /// The native timer id for the one coalesced timer, or 0.
  int _nativeTimerId = 0;

  // ---------------------------------------------------------------------------
  // UiDispatcher
  // ---------------------------------------------------------------------------

  @override
  bool get hasThreadAccess {
    // Win32 messages are delivered to the thread that created the window. The
    // dispatcher may be idle between pumps, so running state is not affinity.
    return _api.getCurrentThreadId() == _ownerThreadId;
  }

  @override
  void post(
    void Function() callback, {
    DispatcherPriority priority = DispatcherPriority.defaultPriority,
  }) {
    _queues[priority.index].add(callback);
    // Wake the loop so it sees the new work.  PostMessage is documented as
    // safe from any thread, so this is legal even from a worker isolate
    // that somehow got a reference to this dispatcher.
    if (_running) {
      _api.postMessageW(_wakeHandle, wmAppWake, 0, 0);
    }
  }

  @override
  TimerHandle schedule(Duration delay, void Function() callback) {
    final now = _now();
    final dueTime = now + (delay.isNegative ? Duration.zero : delay);
    final key = _TimerKey(dueTime, _timerSequence++);
    final handle = TimerHandle(onCancel: (h) => _cancelTimer(key));
    _timers[key] = _TimerEntry(callback: callback, handle: handle);
    _updateNativeTimer();
    return handle;
  }

  @override
  void wake() {
    if (_wakeHandle != 0) {
      _api.postMessageW(_wakeHandle, wmAppWake, 0, 0);
    }
  }

  @override
  void run() {
    if (_running) throw StateError('Win32Dispatcher.run: already running');
    _running = true;
    _stopRequested = false;
    try {
      _loop();
    } finally {
      _running = false;
      _killNativeTimer();
    }
  }

  @override
  void stop() {
    _stopRequested = true;
    wake();
  }

  // ---------------------------------------------------------------------------
  // Loop
  // ---------------------------------------------------------------------------

  void _loop() {
    while (!_stopRequested) {
      // 1. Drain Dart queues — frame-stage priorities first.
      _drainQueues();

      // 2. Fire due timers.
      _fireDueTimers();

      // 3. Pump native messages, capped.
      _pumpNative();

      // 4. Drain again — the native messages may have posted Dart work.
      _drainQueues();
      _fireDueTimers();

      if (_stopRequested) break;

      // 5. If nothing is pending, wait for the next event or timer.
      if (!_hasPendingWork()) {
        final timeoutMs = _nextTimerTimeout();
        _api.msgWaitForMultipleObjectsEx(
          0,
          nullptr,
          timeoutMs,
          qsAllinput,
          mwmoInputavailable | mwmoAlertable,
        );
      }
    }
  }

  void _drainQueues() {
    for (var priority = 0; priority < _queues.length; priority++) {
      final queue = _queues[priority];
      while (queue.isNotEmpty) {
        final callback = queue.removeFirst();
        callback();
        if (_stopRequested) return;
      }
    }
  }

  void _pumpNative() {
    var count = 0;
    while (count < maxNativeMessagesPerPass) {
      final msg = _api.allocator<Msg>();
      try {
        final hasMessage = _api.peekMessageW(
          msg,
          0,
          0,
          0,
          pmRemove,
        );
        if (hasMessage == 0) break;
        _api.translateMessage(msg);
        _api.dispatchMessageW(msg);
      } finally {
        _api.allocator.free(msg);
      }
      count++;
    }
  }

  void _fireDueTimers() {
    final now = _now();
    while (_timers.isNotEmpty) {
      final firstKey = _timers.firstKey()!;
      if (firstKey.dueTime > now) break;
      final entry = _timers.remove(firstKey)!;
      if (entry.handle.isActive) {
        entry.handle.markFired();
        entry.callback();
        if (_stopRequested) return;
      }
    }
    _updateNativeTimer();
  }

  bool _hasPendingWork() {
    for (final queue in _queues) {
      if (queue.isNotEmpty) return true;
    }
    if (_timers.isNotEmpty) {
      final firstKey = _timers.firstKey()!;
      if (firstKey.dueTime <= _now()) return true;
    }
    return false;
  }

  int _nextTimerTimeout() {
    if (_timers.isEmpty) return 100; // Idle poll interval.
    final next = _timers.firstKey()!.dueTime;
    final delta = next - _now();
    final ms = delta.inMilliseconds;
    return ms < 1 ? 1 : ms;
  }

  void _cancelTimer(_TimerKey key) {
    _timers.remove(key);
    _updateNativeTimer();
  }

  void _updateNativeTimer() {
    if (_timers.isEmpty) {
      _killNativeTimer();
      return;
    }
    final next = _timers.firstKey()!.dueTime;
    final delta = next - _now();
    final ms = delta.inMilliseconds;
    final clampedMs = ms < 1 ? 1 : ms;

    if (_wakeHandle != 0) {
      _nativeTimerId = _api.setTimer(
        _wakeHandle,
        1, // Timer id — we only use one.
        clampedMs,
        nullptr,
      );
    }
  }

  void _killNativeTimer() {
    if (_nativeTimerId != 0 && _wakeHandle != 0) {
      _api.killTimer(_wakeHandle, 1);
      _nativeTimerId = 0;
    }
  }

  Duration _now() => _clock.elapsed;

  @override
  String toString() => 'Win32Dispatcher(running: $_running, '
      'pending: ${_queues.where((q) => q.isNotEmpty).length} queues, '
      'timers: ${_timers.length})';
}

/// Key for the timer tree: ordered by due time, then by insertion order
/// for stability.
final class _TimerKey implements Comparable<_TimerKey> {
  const _TimerKey(this.dueTime, this.sequence);
  final Duration dueTime;
  final int sequence;

  @override
  int compareTo(_TimerKey other) {
    final cmp = dueTime.compareTo(other.dueTime);
    return cmp != 0 ? cmp : sequence.compareTo(other.sequence);
  }

  @override
  bool operator ==(Object other) =>
      other is _TimerKey &&
      dueTime == other.dueTime &&
      sequence == other.sequence;

  @override
  int get hashCode => Object.hash(dueTime, sequence);
}

final class _TimerEntry {
  _TimerEntry({required this.callback, required this.handle});
  final void Function() callback;
  final TimerHandle handle;
}
