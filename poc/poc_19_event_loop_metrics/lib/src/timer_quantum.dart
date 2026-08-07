import 'dart:ffi';

import 'clock.dart';
import 'win32_bindings.dart';

/// Measures what a 1 ms native wait actually costs.
///
/// Windows rounds waitable timeouts up to the current system timer
/// resolution, ~15.6 ms by default. Every measurement in this POC is subject
/// to it, so it is reported rather than hidden: without it, a row labelled
/// "polling 4ms" looks like it polls at 4 ms when it really polls at ~15.6 ms.
///
/// Returns the median observed duration in microseconds.
int measureWaitQuantumUs({int samples = 15}) {
  final observed = <int>[];
  for (var i = 0; i < samples; i++) {
    final before = Clock.nowUs();
    msgWaitForMultipleObjectsEx(0, nullptr, 1, qsAllInput, mwmoInputAvailable);
    observed.add(Clock.nowUs() - before);
  }
  observed.sort();
  return observed[observed.length ~/ 2];
}
