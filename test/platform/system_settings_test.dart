import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

void main() {
  group('SystemSettings', () {
    test('defaults to the desktop that reported nothing', () {
      const SystemSettings settings = SystemSettings();
      expect(settings, SystemSettings.fallback);
      expect(settings.brightness, Brightness.light);
      expect(settings.highContrast, isFalse);
      expect(settings.disableAnimations, isFalse);
      expect(settings.boldText, isFalse);
      expect(settings.textScaleFactor, 1.0);
    });

    test('compares by value, every field', () {
      const SystemSettings base = SystemSettings();
      final List<SystemSettings> variants = <SystemSettings>[
        base.copyWith(brightness: Brightness.dark),
        base.copyWith(highContrast: true),
        base.copyWith(disableAnimations: true),
        base.copyWith(boldText: true),
        base.copyWith(textScaleFactor: 1.25),
      ];
      for (final SystemSettings variant in variants) {
        expect(variant, isNot(base), reason: '$variant');
        expect(variant, variant.copyWith(), reason: '$variant');
        expect(variant.hashCode, variant.copyWith().hashCode);
      }
    });

    test('the theme brightness and the platform one are the same type', () {
      // The line every port from Flutter writes; a second enum would make it
      // a type error.
      const MediaQueryData media =
          MediaQueryData(platformBrightness: Brightness.dark);
      expect(
          ThemeData.neutralDark.brightness == media.platformBrightness, isTrue);
      const ThemeBrightness alias = Brightness.dark;
      expect(alias, media.platformBrightness);
    });
  });

  group('SystemSettingsNotifier', () {
    test('notifies only when the value changes', () {
      final SystemSettingsNotifier notifier = SystemSettingsNotifier();
      var calls = 0;
      notifier.addListener(() => calls++);

      notifier.value = SystemSettings.fallback;
      expect(calls, 0);

      notifier.value = const SystemSettings(brightness: Brightness.dark);
      notifier.value = const SystemSettings(brightness: Brightness.dark);
      expect(calls, 1);
      expect(notifier.value.brightness, Brightness.dark);

      notifier.dispose();
    });
  });
}
