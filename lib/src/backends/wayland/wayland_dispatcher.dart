/// Wayland event loop integrated with the `UiDispatcher` contract.
///
/// Structurally identical to `X11Dispatcher`, because the platforms share the
/// event model that matters here: events arrive on one file descriptor, there
/// is no thread affinity, and everything runs on the isolate's thread. The
/// wake strategy is the same self-pipe (owned by the transport), and timers
/// are the same Dart-side sorted tree with the poll timeout set to the nearest
/// due time.
///
/// The roadmap's canonical Wayland loop (section 16.4) maps onto one pass:
///
///   1. drain Dart queues (dispatch_pending);
///   2. fire due timers;
///   3. poll the display fd and the wake pipe, then read and translate
///      whatever arrived (`prepare_read`/`read_events` collapse into the
///      injected [_pollEvents], because this client is single-threaded and
///      no other reader can race the socket);
///   4. drain Dart queues again;
///   5. fire due timers again.
library;

import 'dart:collection';

import '../../scheduler/dispatcher_priority.dart';
import '../../scheduler/timer_handle.dart';
import '../../scheduler/ui_dispatcher.dart';

/// A Wayland-aware [UiDispatcher].
///
/// The event poll and the wake writer are injected so this class can be
/// tested with no display, exactly like its X11 twin.
final class WaylandDispatcher implements UiDispatcher {
  WaylandDispatcher({
    required void Function() pollEvents,
    required void Function() wakeWriter,
  })  : _pollEvents = pollEvents,
        _wakeWriter = wakeWriter;

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
    if (_running) throw StateError('WaylandDispatcher.run: already running');
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
      _drainQueues();
      if (_stopRequested) break;

      _fireDueTimers();
      if (_stopRequested) break;

      // The injected poll reads the connection and posts callbacks at the
      // appropriate priority.
      _pollEvents();

      _drainQueues();
      if (_stopRequested) break;

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

  /// The timeout to pass to `poll(2)`, in milliseconds. Exposed so the
  /// backend can use it when blocking on the display fd.
  int get nextPollTimeoutMs {
    for (final queue in _queues) {
      if (queue.isNotEmpty) return 0;
    }
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
  String toString() => 'WaylandDispatcher(running: $_running, '
      'pending: ${_queues.where((q) => q.isNotEmpty).length} queues, '
      'timers: ${_timers.length})';
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
