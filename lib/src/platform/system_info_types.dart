/// The shared vocabulary of [SystemInfo], plus the answer-parsing that is
/// pure string work.
library;

/// A snapshot of what the platform says about itself and the session.
///
/// Plain values, captured at one moment: nothing here updates itself, and a
/// caller that needs a fresh answer takes a fresh snapshot. Fields that a
/// target genuinely cannot answer are empty strings rather than null - "the
/// browser does not say" is an answer, and an empty string keeps every caller
/// out of the null-check business for data that is only ever displayed.
final class SystemInfoData {
  const SystemInfoData({
    required this.operatingSystem,
    required this.operatingSystemVersion,
    required this.hostname,
    required this.userName,
    required this.locale,
    required this.processorCount,
  });

  /// `windows`, `linux`, `macos`, `web`, ...
  final String operatingSystem;

  /// The platform's own version string, verbatim - a build string on
  /// Windows, `uname` output on Linux, the user-agent on the web. Verbatim
  /// because every scheme for normalising these ages badly.
  final String operatingSystemVersion;

  final String hostname;

  /// The session's user name, from the platform's environment. Empty on the
  /// web, which does not have one.
  final String userName;

  /// A BCP 47-ish locale tag such as `pt_BR` or `en-US`, in the platform's
  /// own spelling.
  final String locale;

  final int processorCount;

  @override
  String toString() => 'SystemInfoData($operatingSystem '
      '$operatingSystemVersion, host: $hostname, user: $userName, '
      'locale: $locale, cpus: $processorCount)';
}

/// Whether the Windows `AppsUseLightTheme` registry value means dark mode.
///
/// The value is "apps use *light* theme", so 0 is dark - inverted enough to
/// deserve one named function and one test.
bool darkModeFromAppsUseLightTheme(int value) => value == 0;

/// Whether a freedesktop `color-scheme` answer means dark mode.
///
/// `gsettings get org.gnome.desktop.interface color-scheme` answers a quoted
/// GVariant string: `'prefer-dark'`, `'prefer-light'` or `'default'`.
/// Null means the answer named no preference either way.
bool? darkModeFromColorScheme(String answer) {
  final String normalized = answer.trim().toLowerCase();
  if (normalized.contains('prefer-dark')) return true;
  if (normalized.contains('prefer-light')) return false;
  if (normalized.contains('default')) return false;
  return null;
}

/// Whether `defaults read -g AppleInterfaceStyle` output means dark mode.
///
/// macOS only writes the key when dark mode is on; the command failing
/// (nonzero [exitCode]) *is* the light-mode answer.
bool darkModeFromAppleInterfaceStyle({
  required int exitCode,
  required String stdout,
}) =>
    exitCode == 0 && stdout.trim().toLowerCase() == 'dark';
