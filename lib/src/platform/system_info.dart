/// What the platform will say about itself: identity, session, and the one
/// appearance preference every desktop now exposes.
///
/// Two kinds of answer live here and their shapes differ on purpose.
/// [SystemInfo.snapshot] is synchronous plain values - name, version,
/// hostname, locale, CPU count - because every target answers those from
/// memory. [SystemInfo.isDarkMode] is asynchronous and tri-state: on Linux
/// and macOS the answer comes from asking another process, and on any
/// platform the honest answers are "dark", "light" and "the platform did not
/// say" - which is `null`, not a guessed `false`.
library;

import 'system_info_platform_stub.dart'
    if (dart.library.io) 'system_info_platform_io.dart'
    if (dart.library.js_interop) 'system_info_platform_web.dart' as platform;
import 'system_info_types.dart';

export 'system_info_types.dart';

/// Read-only facts about the machine and session this process runs in.
abstract final class SystemInfo {
  /// The current facts, captured now.
  static SystemInfoData snapshot() => platform.snapshot();

  /// Whether the platform is currently in dark mode, or null when it does
  /// not say (an older desktop, a Linux without gsettings, a stub target).
  ///
  /// This is the *current* value, not a subscription. To follow the setting
  /// while the application runs, read `MediaQuery.of(context)
  /// .platformBrightness` in a widget, or listen to
  /// `Application.systemSettings`: those are fed by the backends' own change
  /// notifications (`WM_SETTINGCHANGE` on Windows, AppKit's appearance and
  /// accessibility notifications on macOS) and rebuild every window when the
  /// answer moves. On Linux they are still a startup-time read of this same
  /// gsettings answer.
  static Future<bool?> isDarkMode() => platform.isDarkMode();
}
