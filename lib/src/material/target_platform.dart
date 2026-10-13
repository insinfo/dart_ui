/// Flutter's `TargetPlatform` and `defaultTargetPlatform`.
///
/// In Flutter these are foundation names; they are declared here with the
/// Material layer, which is what reads them (`ThemeData.platform`, the
/// platform's default for `AppBar.centerTitle`).
library;

import '../platform/editing_convention_platform_stub.dart'
    if (dart.library.io) '../platform/editing_convention_platform_io.dart'
    if (dart.library.js_interop) '../platform/editing_convention_platform_web.dart'
    as platform;

/// The operating systems Flutter distinguishes.
enum TargetPlatform { android, fuchsia, iOS, linux, macOS, windows }

/// The platform this program is running on, or [debugDefaultTargetPlatformOverride]
/// when one is set. A program that is not on one of the six (a browser, a
/// test host) is [TargetPlatform.linux].
TargetPlatform get defaultTargetPlatform =>
    debugDefaultTargetPlatformOverride ?? _host;

/// Forces [defaultTargetPlatform], for tests and for previewing another
/// platform's conventions.
TargetPlatform? debugDefaultTargetPlatformOverride;

final TargetPlatform _host = switch (platform.detectedOperatingSystem()) {
  'android' => TargetPlatform.android,
  'fuchsia' => TargetPlatform.fuchsia,
  'ios' => TargetPlatform.iOS,
  'macos' => TargetPlatform.macOS,
  'windows' => TargetPlatform.windows,
  _ => TargetPlatform.linux,
};
