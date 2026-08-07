import 'dart:ffi';

import 'package:ffi/ffi.dart';

import 'win32_bindings.dart';

/// Process CPU consumption, sampled two ways.
///
/// `GetProcessTimes` is the familiar metric but its granularity is the
/// scheduler tick (~15.6 ms on default Windows timer settings), which is far
/// too coarse to separate a loop that wakes twice a second from one that wakes
/// twenty times a second.
///
/// `QueryProcessCycleTime` counts actual CPU cycles across every thread in the
/// process, so it resolves those differences. Cycle counts are reported raw
/// rather than converted to seconds: modern CPUs vary their clock, so a
/// cycles-to-time conversion would be fiction. As a relative comparison
/// between configurations measured back to back, cycles are the honest number.
final class CpuMeter {
  CpuMeter()
      : _startTimes = _sampleTimes(),
        _startCycles = _sampleCycles();

  final _CpuSample _startTimes;
  final int _startCycles;

  /// CPU milliseconds consumed since construction (user + kernel).
  double elapsedMs() {
    final now = _sampleTimes();
    final ticks =
        (now.user - _startTimes.user) + (now.kernel - _startTimes.kernel);
    // FILETIME counts 100 ns units.
    return ticks / 10000.0;
  }

  /// CPU cycles consumed since construction, across all process threads.
  int elapsedCycles() => _sampleCycles() - _startCycles;

  static int _sampleCycles() {
    final slot = calloc<Uint64>();
    try {
      if (queryProcessCycleTime(getCurrentProcess(), slot) == 0) {
        throw StateError('QueryProcessCycleTime failed.');
      }
      return slot.value;
    } finally {
      calloc.free(slot);
    }
  }

  static _CpuSample _sampleTimes() {
    final slots = calloc<Uint64>(4);
    try {
      final ok = getProcessTimes(
        getCurrentProcess(),
        slots,
        slots + 1,
        slots + 2,
        slots + 3,
      );
      if (ok == 0) {
        throw StateError('GetProcessTimes failed.');
      }
      return _CpuSample(kernel: slots[2], user: slots[3]);
    } finally {
      calloc.free(slots);
    }
  }
}

final class _CpuSample {
  const _CpuSample({required this.kernel, required this.user});

  final int kernel;
  final int user;
}
