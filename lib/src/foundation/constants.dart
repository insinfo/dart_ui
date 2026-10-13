/// Build-mode constants with Flutter's names: `kDebugMode`, `kReleaseMode`,
/// `kProfileMode`, `kIsWeb`.
///
/// Flutter derives the mode from the engine build. dart_ui has no engine, so
/// the mode comes from how the Dart program was compiled:
///
///   * [kReleaseMode] is true for an AOT executable (`dart compile exe`),
///     where `dart.vm.product` is defined, and when the program is compiled
///     with `-Ddart.vm.product=true`;
///   * [kProfileMode] is true only with `-Ddart.vm.profile=true`, which no
///     dart_ui tool sets for you - there is no separate profile runtime;
///   * [kDebugMode] is everything else: `dart run`, `dart test`, JIT.
///
/// Exactly one of the three is true, as in Flutter. Code that wrapped
/// diagnostics in `if (kDebugMode)` keeps doing so; asserts are a separate
/// switch (`--enable-asserts`) and are not implied by [kDebugMode] here,
/// which is a difference from Flutter, where debug mode always runs asserts.
library;

/// True in an AOT-compiled (product) program.
const bool kReleaseMode = bool.fromEnvironment('dart.vm.product');

/// True when compiled with `-Ddart.vm.profile=true`.
const bool kProfileMode =
    bool.fromEnvironment('dart.vm.profile') && !kReleaseMode;

/// True when neither [kReleaseMode] nor [kProfileMode] is.
const bool kDebugMode = !kReleaseMode && !kProfileMode;

/// True when the program was compiled for a browser (JavaScript or
/// WebAssembly) - the same definition Flutter uses.
const bool kIsWeb = bool.fromEnvironment('dart.library.js_interop');
