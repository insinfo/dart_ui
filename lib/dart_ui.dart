/// dart_ui — framework de interface grafica multiplataforma em 100% Dart.
///
/// This is the public surface. Everything under `lib/src` is private by
/// convention: if a type is not exported here, it is not part of the contract
/// and may change without notice.
///
/// The layering follows section 8 of
/// `doc/ROTEIRO_FRAMEWORK_MULTIPLATAFORMA_100_PURO_DART.md`, and the
/// dependency rule from section 8.2 is enforced by which directory a file
/// lives in:
///
///   foundation  <- depends on nothing
///   geometry    <- depends on nothing
///   scheduler   <- foundation
///   graphics    <- foundation, geometry
///   platform    <- foundation, geometry, scheduler
///
/// No layer here may import a backend, and no backend may be referenced by
/// name from common code.
library;

export 'src/foundation/diagnostics.dart';
export 'src/foundation/lifecycle.dart';
export 'src/geometry/offset.dart';
export 'src/geometry/rect.dart';
export 'src/geometry/size.dart';
export 'src/geometry/transform2d.dart';
export 'src/graphics/display_list.dart';
export 'src/graphics/display_list_debug.dart';
export 'src/graphics/display_list_geometry.dart';
export 'src/graphics/display_list_opcodes.dart';
export 'src/graphics/display_list_reader.dart';
export 'src/platform/window_events.dart';
export 'src/scheduler/dispatcher_priority.dart';
export 'src/scheduler/manual_dispatcher.dart';
export 'src/scheduler/timer_handle.dart';
export 'src/scheduler/ui_dispatcher.dart';
