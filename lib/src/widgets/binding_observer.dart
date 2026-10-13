/// `WidgetsBindingObserver`: what a `State` mixes in to hear about the
/// application's lifecycle, its window metrics and the desktop's settings.
library;

import '../foundation/app_lifecycle_state.dart';
import '../foundation/locale.dart';

/// Flutter's `WidgetsBindingObserver`, registered with
/// `WidgetsBinding.instance.addObserver(this)`.
///
/// Every method has an empty default, so a class overrides only what it
/// needs. Which of them dart_ui actually calls:
///
///   * [didChangeAppLifecycleState] - when the application's state changes
///     (see `AppLifecycleState` for the mapping);
///   * [didChangeMetrics] - when the primary window's logical size or pixel
///     ratio changes;
///   * [didChangePlatformBrightness], [didChangeTextScaleFactor] and
///     [didChangeAccessibilityFeatures] - when the desktop's appearance or
///     accessibility settings change.
///
/// Never called here, and why: [didPopRoute] and [didPushRoute]
/// (no system back button or OS route intents on desktop - Escape/Alt+Left
/// go to the `Navigator` directly), [didChangeLocales] (the system locale is
/// not observed yet), [didHaveMemoryPressure] (no platform signal is wired).
abstract mixin class WidgetsBindingObserver {
  /// The system asked to go back. Return true if handled. Not called on
  /// desktop.
  Future<bool> didPopRoute() => Future<bool>.value(false);

  /// The system asked to open [route]. Not called on desktop.
  Future<bool> didPushRoute(String route) => Future<bool>.value(false);

  /// The window's size or pixel ratio changed.
  void didChangeMetrics() {}

  /// The desktop's text scale changed.
  void didChangeTextScaleFactor() {}

  /// The desktop switched between light and dark.
  void didChangePlatformBrightness() {}

  /// The system locales changed. Not called yet.
  void didChangeLocales(List<Locale>? locales) {}

  /// The application moved to [state].
  void didChangeAppLifecycleState(AppLifecycleState state) {}

  /// The system is low on memory. Not called yet.
  void didHaveMemoryPressure() {}

  /// High contrast, reduced motion or bold text changed.
  void didChangeAccessibilityFeatures() {}
}
