/// The desktop's appearance and accessibility preferences, as Windows keeps
/// them, and the rule for which window messages mean they moved.
///
/// Windows has no single "settings changed" notification. What it has is
/// three messages that each cover part of the ground:
///
///   * `WM_SETTINGCHANGE`, broadcast to every top-level window after
///     *anything* in `SystemParametersInfo` or a handful of registry areas
///     moved - including the many things this framework does not care about:
///     the environment block, the wheel's lines per notch, the double-click
///     time, the regional format. Which one moved is in `wParam` (the
///     `SPI_SET*` action) and/or `lParam` (a string naming the area);
///   * `WM_THEMECHANGED`, after the visual style changed - which entering or
///     leaving a high-contrast theme does;
///   * `WM_SYSCOLORCHANGE`, after the system colours changed - which a
///     high-contrast theme also does.
///
/// So the backend reacts in two steps. [win32SettingChangeAffectsSystemSettings]
/// decides, from nothing but integers and a string, whether a message is about
/// something [SystemSettings] reports - a pure function, so it is tested on
/// every CI machine and not only on Windows. Only then does
/// [readWin32SystemSettings] re-read every value: a few microseconds of registry
/// and `SystemParametersInfoW`, which is cheaper than working out
/// which of the four values a given message could have moved, and immune to
/// guessing wrong.
library;

import 'dart:ffi';

import '../../ffi/native_memory.dart';
import '../../platform/system_info_platform_io.dart'
    show readWindowsAppsUseLightTheme, readWindowsCurrentUserDword;
import '../../platform/system_settings.dart';
import 'win32_constants.dart';

// --- SystemParametersInfo actions ---------------------------------------------
//
// The `SPI_GET*` half is what this file reads; the `SPI_SET*` half is what
// arrives in `WM_SETTINGCHANGE`'s wParam when someone changed the value.

/// `SPI_GETHIGHCONTRAST` - fills a `HIGHCONTRASTW`.
const int spiGetHighContrast = 0x0042;

/// `SPI_SETHIGHCONTRAST` - a high-contrast theme was entered or left.
const int spiSetHighContrast = 0x0043;

/// `SPI_SETANIMATION` - the minimise/restore animation. Settings' "Animation
/// effects" switch moves it together with [spiSetClientAreaAnimation].
const int spiSetAnimation = 0x0049;

/// `SPI_SETNONCLIENTMETRICS` - the caption, menu and message fonts. Changing
/// Settings' "Text size" rescales them, which makes this the message that
/// accompanies a text-size change: Windows documents no message of its own
/// for `TextScaleFactor`.
const int spiSetNonClientMetrics = 0x002A;

/// `SPI_GETCLIENTAREAANIMATION` - whether applications should animate their
/// content. This is the value behind "Animation effects" (and behind the
/// Ease of Access "Show animations in Windows"), and the one UWP's
/// `UISettings.AnimationsEnabled` reports.
const int spiGetClientAreaAnimation = 0x1042;

/// `SPI_SETCLIENTAREAANIMATION` - [spiGetClientAreaAnimation] changed.
const int spiSetClientAreaAnimation = 0x1043;

/// `HCF_HIGHCONTRASTON` in `HIGHCONTRASTW.dwFlags`.
const int hcfHighContrastOn = 0x00000001;

/// The `lParam` area Windows names when the light/dark "app mode", the
/// "system mode" or the accent colour changed. The string is the whole
/// notification for dark mode: `wParam` is 0.
const String win32ImmersiveColorSetArea = 'ImmersiveColorSet';

/// The `lParam` area of a Windows 10+ theme element change, which a
/// high-contrast switch sends alongside its `SPI_SETHIGHCONTRAST`.
const String win32ThemeElementArea = 'WindowsThemeElement';

/// Whether a window message means [SystemSettings] may have changed.
///
/// [area] is `WM_SETTINGCHANGE`'s `lParam` read as a string, or null when the
/// pointer was null; it is compared without regard to case, as the shell
/// itself does. Every other message - and a `WM_SETTINGCHANGE` about the
/// environment, the mouse or the locale - answers false, which is what keeps
/// a user editing `PATH` from rebuilding every window of every application
/// built on this framework.
bool win32SettingChangeAffectsSystemSettings({
  required int message,
  int wParam = 0,
  String? area,
}) {
  if (message == wmThemechanged || message == wmSyscolorchange) return true;
  if (message != wmSettingchange) return false;
  switch (wParam) {
    case spiSetHighContrast:
    case spiSetClientAreaAnimation:
    case spiSetAnimation:
    case spiSetNonClientMetrics:
      return true;
  }
  if (area == null) return false;
  final String normalized = area.toLowerCase();
  return normalized == win32ImmersiveColorSetArea.toLowerCase() ||
      normalized == win32ThemeElementArea.toLowerCase();
}

/// The [SystemSettings] the raw Windows values describe.
///
/// Every argument is nullable because every source can be missing - a
/// Windows before 1607 has no `AppsUseLightTheme`, `TextScaleFactor` exists
/// only once the user has moved the slider - and a missing value is the
/// default, never a guess:
///
///   * [appsUseLightTheme] is inverted - 0 is *dark* - which is why it goes
///     through `darkModeFromAppsUseLightTheme`'s rule rather than a cast;
///   * [highContrastFlags] is `HIGHCONTRASTW.dwFlags`;
///   * [clientAreaAnimation] is the `BOOL` of [spiGetClientAreaAnimation];
///   * [textScalePercent] is `HKCU\Software\Microsoft\Accessibility
///     !TextScaleFactor`, 100 to 225. Anything outside that range is not a
///     value Settings can write and is ignored rather than trusted.
SystemSettings systemSettingsFromWin32({
  int? appsUseLightTheme,
  int? highContrastFlags,
  int? clientAreaAnimation,
  int? textScalePercent,
}) =>
    SystemSettings(
      brightness: appsUseLightTheme == 0 ? Brightness.dark : Brightness.light,
      highContrast: highContrastFlags != null &&
          highContrastFlags & hcfHighContrastOn != 0,
      disableAnimations: clientAreaAnimation == 0,
      textScaleFactor: textScalePercent != null &&
              textScalePercent >= 100 &&
              textScalePercent <= 225
          ? textScalePercent / 100
          : 1.0,
    );

/// Reads every value [SystemSettings] reports from this Windows session.
///
/// Synchronous and cheap - two registry reads and two
/// `SystemParametersInfoW` calls - which is what lets the backend answer the
/// application's startup question before the first window mounts, and
/// re-read everything on each relevant message instead of tracking deltas.
SystemSettings readWin32SystemSettings() => systemSettingsFromWin32(
      appsUseLightTheme: readWindowsAppsUseLightTheme(),
      highContrastFlags: _readHighContrastFlags(),
      clientAreaAnimation: _readSpiBool(spiGetClientAreaAnimation),
      textScalePercent: readWindowsCurrentUserDword(
        r'Software\Microsoft\Accessibility',
        'TextScaleFactor',
      ),
    );

/// `WM_SETTINGCHANGE`'s `lParam` as a string, or null for a null pointer.
///
/// Bounded at 64 code units: every area name Windows sends is a short word,
/// and a bound means a sender that passed something other than a terminated
/// string costs a wrong comparison rather than a read off the end of a page.
String? readWin32SettingArea(int lParam) {
  if (lParam == 0) return null;
  return readNativeUtf16(Pointer<Uint16>.fromAddress(lParam), limit: 64);
}

// --- FFI -----------------------------------------------------------------------

/// `HIGHCONTRASTW`. `cbSize` must be set to the structure's own size or the
/// call fails, which is why it is filled from `sizeOf` rather than a literal.
final class _HighContrastW extends Struct {
  @Uint32()
  external int cbSize;

  @Uint32()
  external int dwFlags;

  external Pointer<Uint16> lpszDefaultScheme;
}

typedef _SystemParametersInfoWNative = Int32 Function(
  Uint32 action,
  Uint32 param,
  Pointer<Void> value,
  Uint32 winIni,
);
typedef _SystemParametersInfoWDart = int Function(
  int action,
  int param,
  Pointer<Void> value,
  int winIni,
);

_SystemParametersInfoWDart? _systemParametersInfo;
bool _spiBindAttempted = false;

/// Bound on first use and on its own, rather than as a field of `Win32Api`:
/// it is needed before any window exists (the startup read) and by nothing
/// that draws, and a failure to bind it must cost the settings - which then
/// stay at their defaults - and never the backend.
_SystemParametersInfoWDart? _bindSystemParametersInfo() {
  if (_spiBindAttempted) return _systemParametersInfo;
  _spiBindAttempted = true;
  try {
    _systemParametersInfo = DynamicLibrary.open('user32.dll').lookupFunction<
        _SystemParametersInfoWNative,
        _SystemParametersInfoWDart>('SystemParametersInfoW');
  } on Object {
    _systemParametersInfo = null;
  }
  return _systemParametersInfo;
}

int? _readHighContrastFlags() {
  final _SystemParametersInfoWDart? spi = _bindSystemParametersInfo();
  if (spi == null) return null;
  return using((NativeArena arena) {
    final Pointer<_HighContrastW> info = arena<_HighContrastW>();
    final int size = sizeOf<_HighContrastW>();
    info.ref
      ..cbSize = size
      ..dwFlags = 0
      ..lpszDefaultScheme = nullptr;
    final int ok = spi(spiGetHighContrast, size, info.cast<Void>(), 0);
    return ok == 0 ? null : info.ref.dwFlags;
  });
}

int? _readSpiBool(int action) {
  final _SystemParametersInfoWDart? spi = _bindSystemParametersInfo();
  if (spi == null) return null;
  return using((NativeArena arena) {
    final Pointer<Int32> value = arena<Int32>();
    value.value = 1;
    final int ok = spi(action, 0, value.cast<Void>(), 0);
    return ok == 0 ? null : value.value;
  });
}
