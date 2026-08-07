import 'dart:ffi';

import 'package:ffi/ffi.dart';

import 'win32_bindings.dart';

/// System-wide monotonic clock backed by `QueryPerformanceCounter`.
///
/// QPC is consistent across threads, isolates and processes on every Windows
/// version this project supports, so a timestamp taken in the sender isolate
/// is directly comparable with one taken in the loop isolate. That is what
/// makes the message latency figures meaningful.
final class Clock {
  Clock._();

  static final Pointer<Int64> _scratch = calloc<Int64>();
  static final int _frequency = _readFrequency();

  static int _readFrequency() {
    final slot = calloc<Int64>();
    try {
      if (queryPerformanceFrequency(slot) == 0) {
        throw StateError('QueryPerformanceFrequency failed.');
      }
      return slot.value;
    } finally {
      calloc.free(slot);
    }
  }

  /// Microseconds since boot, on the shared QPC timebase.
  ///
  /// The split multiply avoids overflowing 64 bits: a raw 10 MHz counter on a
  /// machine with long uptime would overflow `raw * 1000000` directly.
  static int nowUs() {
    if (queryPerformanceCounter(_scratch) == 0) {
      throw StateError('QueryPerformanceCounter failed.');
    }
    final raw = _scratch.value;
    final seconds = raw ~/ _frequency;
    final remainder = raw % _frequency;
    return seconds * 1000000 + (remainder * 1000000) ~/ _frequency;
  }
}
