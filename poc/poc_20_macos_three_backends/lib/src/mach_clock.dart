import 'dart:ffi';

import 'package:ffi/ffi.dart';

// ---------------------------------------------------------------------------
// The one clock both sides of the boundary can read.
//
// Measuring input latency from Dart alone gives a single number that mixes two
// very different things: how long the WindowServer and AppKit took to deliver
// the event to the host, and how long the host took to hand it to Dart. Only
// the second is what an in-process embedder would remove.
//
// mach_absolute_time is system-wide, so a timestamp taken in the host and one
// taken here are directly comparable - no clock synchronisation needed.
// ---------------------------------------------------------------------------

final DynamicLibrary _libSystem = DynamicLibrary.process();

final _machAbsoluteTime = _libSystem
    .lookupFunction<Uint64 Function(), int Function()>('mach_absolute_time');

final class _MachTimebase extends Struct {
  @Uint32()
  external int numer;
  @Uint32()
  external int denom;
}

final _machTimebaseInfo = _libSystem.lookupFunction<
    Int32 Function(Pointer<_MachTimebase>),
    int Function(Pointer<_MachTimebase>)>('mach_timebase_info');

/// Ticks are nanoseconds on arm64 Macs (numer == denom == 1), but the ratio is
/// documented as machine-dependent, so it is read rather than assumed.
final ({int numer, int denom}) _timebase = () {
  final info = calloc<_MachTimebase>();
  try {
    if (_machTimebaseInfo(info) != 0 || info.ref.denom == 0) {
      return (numer: 1, denom: 1);
    }
    return (numer: info.ref.numer, denom: info.ref.denom);
  } finally {
    calloc.free(info);
  }
}();

int machNow() => _machAbsoluteTime();

double machTicksToMicroseconds(int ticks) =>
    ticks * _timebase.numer / _timebase.denom / 1000.0;

String get machTimebaseDescription => '${_timebase.numer}/${_timebase.denom}';
