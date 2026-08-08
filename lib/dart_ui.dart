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
