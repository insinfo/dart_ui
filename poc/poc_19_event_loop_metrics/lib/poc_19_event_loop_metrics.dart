/// POC-19 — measures what it costs to host a native Win32 event loop next to
/// the Dart event loop, and what the proposed SDK API would recover.
///
/// See `doc/propostas/04_proposta_dart_sdk_event_loop_nativo_ptbr.md`.
library;

export 'src/clock.dart';
export 'src/cpu_meter.dart';
export 'src/measured_loop.dart';
export 'src/run_config.dart';
export 'src/run_result.dart';
export 'src/stats.dart';
export 'src/timer_quantum.dart';
export 'src/win32_bindings.dart' show timeBeginPeriod, timeEndPeriod;
