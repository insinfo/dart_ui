/// The user's desktop-wide appearance and accessibility preferences, as one
/// value that can change while the application runs.
///
/// Dark mode, high contrast, "reduce motion" and the text size are not
/// properties of a window, and they are not facts that hold for the life of a
/// process either: a user flips the system to dark at sunset, or turns on
/// high contrast because the screen is in direct sunlight, and every
/// application on the desktop is expected to follow without a restart.
/// [SystemInfo.isDarkMode] answers the question once; this file is the shape
/// of the answer when it has to stay true.
///
/// It lives in `platform` rather than beside [MediaQuery] because the values
/// are *produced* here: a backend reads them from the registry, from AppKit
/// or from gsettings and reports them upwards, and a backend may not name a
/// widget. The widget layer only republishes them, per window, through
/// `MediaQueryData`.
library;

import 'dart:async';

import '../foundation/change_notifier.dart';

/// Whether a palette - the system's, or a theme's - is light or dark.
///
/// One enum for both questions, and deliberately so. Flutter has exactly one
/// (`dart:ui`'s `Brightness`), answering both `MediaQueryData
/// .platformBrightness` and `ThemeData.brightness`, and code ported from it
/// compares the two directly: `theme.brightness ==
/// MediaQuery.of(context).platformBrightness`. Two enums with the same two
/// values would make that line a type error and every port a conversion
/// function. It is declared here, at the lowest layer that needs it, and the
/// theme library re-exports it (with the older `ThemeBrightness` alias), so
/// `package:dart_ui/dart_ui.dart` still exposes a single type.
enum Brightness { light, dark }

/// The desktop-wide preferences the platform reported, captured at one
/// moment.
///
/// Immutable and compared by value. A backend reports a whole value rather
/// than the one field that moved, for two reasons: the native notifications
/// rarely say *what* changed (`WM_SETTINGCHANGE` with `ImmersiveColorSet`
/// covers both dark mode and the accent colour; AppKit's accessibility
/// notification covers every display option at once), and a whole value makes
/// "did anything change?" a single `==` that the application uses to drop the
/// duplicates every window of a multi-window application delivers.
///
/// Each default is the answer for "the platform did not say": a light,
/// standard-contrast, animated desktop at 100% text. That is also what a
/// headless test sees, which keeps tests independent of the machine they run
/// on.
final class SystemSettings {
  const SystemSettings({
    this.brightness = Brightness.light,
    this.highContrast = false,
    this.disableAnimations = false,
    this.boldText = false,
    this.textScaleFactor = 1.0,
  }) : assert(textScaleFactor > 0);

  /// The settings of a desktop that reported nothing.
  static const SystemSettings fallback = SystemSettings();

  /// Light or dark "app mode" - Windows' `AppsUseLightTheme`, macOS's
  /// Appearance, the freedesktop `color-scheme`.
  final Brightness brightness;

  /// The user asked for more contrast: Windows' high-contrast themes, macOS's
  /// "Increase contrast".
  final bool highContrast;

  /// The user asked for less motion: Windows' "Animation effects" off, macOS's
  /// "Reduce motion". Named after Flutter's `disableAnimations` because that is
  /// the [MediaQueryData] field it lands in.
  final bool disableAnimations;

  /// The user asked for bolder text. No desktop backend reports it yet; it is
  /// here so the value carried to `MediaQueryData` is complete.
  final bool boldText;

  /// The user's preferred text size multiplier: Windows' "Text size"
  /// accessibility setting. macOS has no system-wide equivalent and reports 1.
  final double textScaleFactor;

  SystemSettings copyWith({
    Brightness? brightness,
    bool? highContrast,
    bool? disableAnimations,
    bool? boldText,
    double? textScaleFactor,
  }) =>
      SystemSettings(
        brightness: brightness ?? this.brightness,
        highContrast: highContrast ?? this.highContrast,
        disableAnimations: disableAnimations ?? this.disableAnimations,
        boldText: boldText ?? this.boldText,
        textScaleFactor: textScaleFactor ?? this.textScaleFactor,
      );

  @override
  bool operator ==(Object other) =>
      other is SystemSettings &&
      other.brightness == brightness &&
      other.highContrast == highContrast &&
      other.disableAnimations == disableAnimations &&
      other.boldText == boldText &&
      other.textScaleFactor == textScaleFactor;

  @override
  int get hashCode => Object.hash(
        brightness,
        highContrast,
        disableAnimations,
        boldText,
        textScaleFactor,
      );

  @override
  String toString() => 'SystemSettings(${brightness.name}'
      '${highContrast ? ', high contrast' : ''}'
      '${disableAnimations ? ', animations disabled' : ''}'
      '${boldText ? ', bold text' : ''}'
      '${textScaleFactor == 1.0 ? '' : ', text x$textScaleFactor'})';
}

/// A windowing backend that can say what the system settings are *now*.
///
/// Optional, like every other capability interface a backend may implement.
/// It answers the startup question only; changes arrive afterwards as a
/// `SystemSettingsChangedEvent` on a window's event stream, because that is
/// where the platform delivers them (`WM_SETTINGCHANGE` is a window message,
/// and on macOS each window's host process is the one that observes AppKit).
///
/// A backend that does not implement it - a test double, the headless backend
/// when no settings were given to it - leaves the application at
/// [SystemSettings.fallback], which is the point: a test must not see the
/// developer's dark desktop.
abstract interface class SystemSettingsSource {
  /// The current settings, synchronously when the platform can answer from
  /// memory (the Windows registry), or as a future when it has to ask another
  /// process (gsettings, `defaults`). Null - immediately or eventually - means
  /// the platform did not say, and the application keeps what it had.
  FutureOr<SystemSettings?> readSystemSettings();
}

/// The application's current [SystemSettings], observable.
///
/// A [ChangeNotifier] rather than a [ValueNotifier] because a [Listenable] is
/// what `ListenableBuilder` and `AnimatedBuilder` take, and because its
/// listeners run when the settings *changed*, which [value]'s equality check
/// guarantees: every window of a three-window application receives the same
/// `WM_SETTINGCHANGE`, and only the first one moves anything.
final class SystemSettingsNotifier with ChangeNotifier {
  SystemSettingsNotifier([SystemSettings initial = SystemSettings.fallback])
      : _value = initial;

  SystemSettings _value;

  /// The settings in force.
  SystemSettings get value => _value;

  /// Replaces the settings, notifying only when they differ.
  ///
  /// Public so an application can override what the platform said - a "force
  /// dark" debug switch, a screenshot tool - with the understanding that the
  /// next change the platform reports replaces the override again.
  set value(SystemSettings next) {
    if (next == _value) return;
    _value = next;
    notifyListeners();
  }
}
