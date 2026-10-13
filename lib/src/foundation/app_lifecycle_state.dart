/// `AppLifecycleState`, with Flutter's values and meanings.
library;

/// Where an application is in its life, as `WidgetsBindingObserver` hears it.
///
/// The values and their order are Flutter's. How dart_ui's desktop shell
/// maps onto them (see `WidgetsBinding.lifecycleState`):
///
///   * [resumed] - running, and one of its top-level windows is the active
///     one;
///   * [inactive] - running, but no window of the application is active (the
///     user is in another application);
///   * [hidden] - every window is minimised or otherwise not drawable, so the
///     application stopped drawing;
///   * [paused] - not reported on desktop, as in Flutter's own desktop
///     embedders;
///   * [detached] - the application is closing or has closed.
enum AppLifecycleState {
  /// Running without a view, or shutting down.
  detached,

  /// Visible and has input focus.
  resumed,

  /// Visible but without input focus.
  inactive,

  /// Not visible; nothing is drawn.
  hidden,

  /// Not visible and not responding to the user (mobile only).
  paused,
}
