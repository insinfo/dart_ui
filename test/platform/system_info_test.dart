import 'dart:io';

import 'package:dart_ui/dart_ui.dart';
import 'package:dart_ui/src/platform/system_info_platform_io.dart'
    as system_info_io;
import 'package:test/test.dart';

void main() {
  group('snapshot', () {
    test('answers with the machine facts dart:io already knows', () {
      final SystemInfoData data = SystemInfo.snapshot();
      expect(data.operatingSystem, Platform.operatingSystem);
      expect(data.operatingSystemVersion, isNotEmpty);
      expect(data.hostname, isNotEmpty);
      expect(data.locale, isNotEmpty);
      expect(data.processorCount, greaterThan(0));
      if (Platform.isWindows) {
        expect(data.userName, isNotEmpty,
            reason: 'an interactive Windows session always has %USERNAME%');
      }
    });
  });

  group('dark-mode answer parsing (pure)', () {
    test('AppsUseLightTheme is inverted: 0 means dark', () {
      expect(darkModeFromAppsUseLightTheme(0), isTrue);
      expect(darkModeFromAppsUseLightTheme(1), isFalse);
    });

    test('freedesktop color-scheme answers', () {
      expect(darkModeFromColorScheme("'prefer-dark'\n"), isTrue);
      expect(darkModeFromColorScheme("'prefer-light'"), isFalse);
      expect(darkModeFromColorScheme("'default'"), isFalse);
      expect(darkModeFromColorScheme('no such schema'), isNull);
    });

    test('AppleInterfaceStyle: the key only exists in dark mode', () {
      expect(
        darkModeFromAppleInterfaceStyle(exitCode: 0, stdout: 'Dark\n'),
        isTrue,
      );
      expect(
        darkModeFromAppleInterfaceStyle(
          exitCode: 1,
          stdout: '',
        ),
        isFalse,
        reason: 'a missing default is the light-mode answer',
      );
    });
  });

  group('windows registry (real machine)', () {
    test('AppsUseLightTheme reads as a DWORD or is honestly absent', () {
      if (!Platform.isWindows) return;
      final int? value = system_info_io.readWindowsAppsUseLightTheme();
      // Any Windows 10 1607+ has the value; older is null. Both are legal,
      // but when present it is 0 or 1.
      if (value != null) {
        expect(value, anyOf(0, 1));
      }
    });

    test('isDarkMode agrees with the raw registry value', () async {
      if (!Platform.isWindows) return;
      final int? raw = system_info_io.readWindowsAppsUseLightTheme();
      final bool? dark = await SystemInfo.isDarkMode();
      if (raw == null) {
        expect(dark, isNull);
      } else {
        expect(dark, darkModeFromAppsUseLightTheme(raw));
      }
    });
  });
}
