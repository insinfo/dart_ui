/// X11 event loop integrated with the `UiDispatcher` contract.
///
/// The X11 event model is simpler than Win32's: events arrive on a file
/// descriptor (the XCB connection's fd), and the application calls
/// `xcb_poll_for_event` or `xcb_wait_for_event` to retrieve them.  There
/// is no thread affinity — any thread can read the connection — but
/// everything in this backend runs on one thread, which is the isolate's
/// thread.
///
/// ## Wake strategy
///
/// A self-pipe: `pipe(2)` creates a pair of file descriptors, the waker
/// writes one byte to the write end, and `poll(2)` watches both the XCB fd
/// and the read end.  When Dart code posts a callback, it writes to the
/// pipe, which unblocks `poll`, which re-examines the Dart queues.  The
/// byte is drained on every wake; multiple writes before the drain are
/// harmless.
///
/// An eventfd would be slightly cheaper (one fd instead of two, a counter
/// instead of a byte) but is Linux-only, and this code runs on any POSIX
/// system where XCB exists.
///
/// ## Timer strategy
///
/// Same as Win32Dispatcher: a Dart-side sorted tree of entries, and the
/// `poll` timeout is set to the nearest due time.  No X11 timer mechanism
/// is used.
///
/// ## Frame interleaving
///
/// One pass:
///   1. Drain Dart queues (immediate → idle).
///   2. Poll the XCB fd and the wake pipe with the nearest-timer timeout.
///   3. Read all available X11 events and translate them into Dart callbacks
///      posted at [DispatcherPriority.input].
///   4. Drain Dart queues again.
///   5. Fire due timers.
library;

import 'dart:collection';

import '../../scheduler/dispatcher_priority.dart';
import '../../scheduler/timer_handle.dart';
import '../../scheduler/ui_dispatcher.dart';

/// An X11/XCB-aware [UiDispatcher].
///
/// The connection fd and the event translator are injected so this class can
/// be tested with a mock fd and no display.
final class X11Dispatcher implements UiDispatcher {
  X11Dispatcher({
    required int connectionFd,
    required void Function() pollEvents,
    required void Function() wakeWriter,
  })  : _connectionFd = connectionFd,
        _pollEvents = pollEvents,
        _wakeWriter = wakeWriter;

  final int _connectionFd;
  final void Function() _pollEvents;
  final void Function() _wakeWriter;

  // One FIFO queue per priority.
  final List<Queue<void Function()>> _queues =
      List<Queue<void Function()>>.generate(
    DispatcherPriority.values.length,
    (_) => Queue<void Function()>(),
    growable: false,
  );

  // Timers ordered by due time.
  int _timerSequence = 0;
  final SplayTreeMap<_TimerKey, _TimerEntry> _timers =
      SplayTreeMap<_TimerKey, _TimerEntry>();

  bool _running = false;
  bool _stopRequested = false;

  // ---------------------------------------------------------------------------
  // UiDispatcher
  // ---------------------------------------------------------------------------

  @override
  bool get hasThreadAccess => _running;

  @override
  void post(
    void Function() callback, {
    DispatcherPriority priority = DispatcherPriority.defaultPriority,
  }) {
    _queues[priority.index].add(callback);
    if (_running) wake();
  }

  @override
  TimerHandle schedule(Duration delay, void Function() callback) {
    final now = _now();
    final dueTime = now + (delay.isNegative ? Duration.zero : delay);
    final key = _TimerKey(dueTime, _timerSequence++);
    final handle = TimerHandle(onCancel: (h) => _timers.remove(key));
    _timers[key] = _TimerEntry(callback: callback, handle: handle);
    return handle;
  }

  @override
  void wake() => _wakeWriter();

  @override
  void run() {
    if (_running) throw StateError('X11Dispatcher.run: already running');
    _running = true;
    _stopRequested = false;
    try {
      _loop();
    } finally {
      _running = false;
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
      // 1. Drain Dart queues.
      _drainQueues();
      if (_stopRequested) break;

      // 2. Fire due timers.
      _fireDueTimers();
      if (_stopRequested) break;

      // 3. Poll X11 events and the wake pipe.
      //    The injected _pollEvents reads the connection and posts callbacks
      //    at the appropriate priority.
      _pollEvents();

      // 4. Drain again — X11 events may have posted Dart work.
      _drainQueues();
      if (_stopRequested) break;

      // 5. Fire due timers again.
      _fireDueTimers();
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
  }

  /// The timeout to pass to `poll(2)`, in milliseconds.  Exposed so the
  /// backend can use it when calling the native poll.
  int get nextPollTimeoutMs {
    // If there is pending Dart work, don't block.
    for (final queue in _queues) {
      if (queue.isNotEmpty) return 0;
    }
    // If there are due timers, don't block.
    if (_timers.isNotEmpty) {
      final next = _timers.firstKey()!.dueTime;
      final delta = next - _now();
      final ms = delta.inMilliseconds;
      return ms < 0 ? 0 : ms;
    }
    // Nothing pending: block for up to 100ms (idle poll interval).
    return 100;
  }

  Duration _now() => Duration(
        microseconds: DateTime.now().microsecondsSinceEpoch,
      );

  @override
  String toString() => 'X11Dispatcher(running: $_running, '
      'pending: ${_queues.where((q) => q.isNotEmpty).length} queues, '
      'timers: ${_timers.length}, fd: $_connectionFd)';
}

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
