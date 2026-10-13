/// Which Windows messages mean the desktop settings moved, and what the raw
/// values mean - both pure, so they are checked on every CI machine.
///
/// The message itself going through a real `WndProc` is pinned in
/// `win32_message_coverage_test.dart`, on Windows only.
library;

import 'package:dart_ui/src/backends/win32/win32_constants.dart';
import 'package:dart_ui/src/backends/win32/win32_system_settings.dart';
import 'package:dart_ui/src/platform/system_settings.dart';
import 'package:test/test.dart';

void main() {
  group('win32SettingChangeAffectsSystemSettings', () {
    bool affects(int message, {int wParam = 0, String? area}) =>
        win32SettingChangeAffectsSystemSettings(
          message: message,
          wParam: wParam,
          area: area,
        );

    test('the message numbers and SPI actions match the SDK', () {
      expect(wmSettingchange, 0x001A);
      expect(wmSyscolorchange, 0x0015);
      expect(wmThemechanged, 0x031A);
      expect(spiGetHighContrast, 0x0042);
      expect(spiSetHighContrast, 0x0043);
      expect(spiSetAnimation, 0x0049);
      expect(spiSetNonClientMetrics, 0x002A);
      expect(spiGetClientAreaAnimation, 0x1042);
      expect(spiSetClientAreaAnimation, 0x1043);
      expect(hcfHighContrastOn, 1);
    });

    test('dark mode is the ImmersiveColorSet area, in any case', () {
      // What Settings sends when "Choose your app mode" moves: wParam 0, the
      // area in lParam, and nothing else.
      expect(affects(wmSettingchange, area: 'ImmersiveColorSet'), isTrue);
      expect(affects(wmSettingchange, area: 'immersivecolorset'), isTrue);
      expect(affects(wmSettingchange, area: 'WindowsThemeElement'), isTrue);
    });

    test('high contrast, animation and text size are SPI actions', () {
      expect(affects(wmSettingchange, wParam: spiSetHighContrast), isTrue);
      expect(
          affects(wmSettingchange, wParam: spiSetClientAreaAnimation), isTrue);
      expect(affects(wmSettingchange, wParam: spiSetAnimation), isTrue);
      expect(affects(wmSettingchange, wParam: spiSetNonClientMetrics), isTrue);
    });

    test('a theme or system colour change always re-reads', () {
      expect(affects(wmThemechanged), isTrue);
      expect(affects(wmSyscolorchange), isTrue);
    });

    test('everything else WM_SETTINGCHANGE carries is not ours', () {
      // Editing PATH, the regional format, the mouse - the messages that
      // would otherwise rebuild every window for nothing.
      expect(affects(wmSettingchange, area: 'Environment'), isFalse);
      expect(affects(wmSettingchange, area: 'intl'), isFalse);
      expect(affects(wmSettingchange, area: 'Policy'), isFalse);
      expect(affects(wmSettingchange), isFalse);
      // SPI_SETWHEELSCROLLLINES and SPI_SETDOUBLECLICKTIME.
      expect(affects(wmSettingchange, wParam: 0x0069), isFalse);
      expect(affects(wmSettingchange, wParam: 0x0020), isFalse);
    });

    test('and so is every other message', () {
      expect(affects(wmSize, wParam: spiSetHighContrast), isFalse);
      expect(affects(wmPaint, area: 'ImmersiveColorSet'), isFalse);
    });
  });

  group('systemSettingsFromWin32', () {
    test('nothing known is the fallback', () {
      expect(systemSettingsFromWin32(), SystemSettings.fallback);
    });

    test('AppsUseLightTheme is inverted: 0 is dark', () {
      expect(systemSettingsFromWin32(appsUseLightTheme: 0).brightness,
          Brightness.dark);
      expect(systemSettingsFromWin32(appsUseLightTheme: 1).brightness,
          Brightness.light);
    });

    test('high contrast is the HCF_HIGHCONTRASTON bit, not the whole word', () {
      expect(
          systemSettingsFromWin32(highContrastFlags: 0).highContrast, isFalse);
      // HCF_AVAILABLE (2) and HCF_HOTKEYACTIVE (4) are set on every machine
      // that has the feature; only bit 0 means it is on.
      expect(systemSettingsFromWin32(highContrastFlags: 0x6).highContrast,
          isFalse);
      expect(
          systemSettingsFromWin32(highContrastFlags: 0x7).highContrast, isTrue);
    });

    test('animations are disabled only by an explicit FALSE', () {
      expect(systemSettingsFromWin32(clientAreaAnimation: 0).disableAnimations,
          isTrue);
      expect(systemSettingsFromWin32(clientAreaAnimation: 1).disableAnimations,
          isFalse);
      expect(systemSettingsFromWin32().disableAnimations, isFalse);
    });

    test('text size is a percentage within what Settings can write', () {
      expect(
          systemSettingsFromWin32(textScalePercent: 100).textScaleFactor, 1.0);
      expect(
          systemSettingsFromWin32(textScalePercent: 150).textScaleFactor, 1.5);
      expect(
          systemSettingsFromWin32(textScalePercent: 225).textScaleFactor, 2.25);
      expect(systemSettingsFromWin32(textScalePercent: 0).textScaleFactor, 1.0);
      expect(
          systemSettingsFromWin32(textScalePercent: 900).textScaleFactor, 1.0);
    });
  });
}
