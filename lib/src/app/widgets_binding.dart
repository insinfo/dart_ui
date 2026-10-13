/// `WidgetsBinding`, `WidgetsFlutterBinding` and `SchedulerBinding`: the
/// process-wide entry point Flutter code reaches through `.instance`.
///
/// Flutter has one binding per process because it has one engine and (until
/// recently) one view. dart_ui has an [Application] with any number of
/// windows, each with its own [BuildOwner] and [FrameScheduler] - see
/// `application.dart` for why they cannot be shared. The binding therefore
/// does not *own* the pipeline; it is a facade over the application that
/// `runApp` started, and speaks for its **primary window** wherever Flutter's
/// API assumes there is only one:
///
///   * [SchedulerBinding.addPostFrameCallback], [addPersistentFrameCallback]
///     and [endOfFrame] use the primary window's scheduler;
///   * [WidgetsBinding.buildOwner], [rootElement] and [focusManager] are the
///     primary window's;
///   * [WidgetsBindingObserver.didChangeMetrics] reports the primary window's
///     size and pixel ratio.
///
/// Before `runApp` has started an application, callbacks and frame requests
/// are queued and handed over when it starts, so the usual
///
/// ```dart
/// Future<void> main() async {
///   WidgetsFlutterBinding.ensureInitialized();
///   await loadSettings();
///   runApp(const MyApp());
/// }
/// ```
///
/// works unchanged. An application started with `Application.start` instead
/// of `runApp` is attached with [WidgetsBinding.attachApplication].
///
/// What Flutter's bindings have and this does not: `platformDispatcher`,
/// `window`, `renderView`/`renderViews`, `pipelineOwner` trees, service
/// extensions, `deferFirstFrame`/`allowFirstFrame`, `scheduleWarmUpFrame`,
/// `addTimingsCallback`, task scheduling (`scheduleTask`), restoration and
/// `handleRequestAppExit`. `ServicesBinding`, `GestureBinding`,
/// `RendererBinding`, `PaintingBinding` and `SemanticsBinding` do not exist;
/// their jobs belong to the application and its windows here.
library;

import 'dart:async';

import '../foundation/app_lifecycle_state.dart';
import '../geometry/size.dart';
import '../platform/system_settings.dart';
import '../scheduler/frame_scheduler.dart';
import '../widgets/binding_observer.dart';
import '../widgets/element.dart';
import '../widgets/focus.dart';
import 'application.dart';

/// Flutter's `SchedulerBinding`: frames and frame callbacks.
///
/// [instance] is the same object as [WidgetsBinding.instance]; the split
/// exists so code written against either name compiles.
abstract class SchedulerBinding {
  SchedulerBinding._();

  /// The binding, created on first use.
  ///
  /// Flutter throws until a binding was initialised; this creates one
  /// instead, because a missing `ensureInitialized` in a migrated `main` is
  /// not worth a crash when nothing depends on the order.
  static SchedulerBinding get instance => WidgetsBinding.instance;

  /// Runs [callback] once, after the next frame of the primary window; see
  /// [FrameScheduler.addPostFrameCallback]. Does not request a frame.
  ///
  /// [debugLabel] is accepted for Flutter's signature and ignored.
  void addPostFrameCallback(
    FrameCallback callback, {
    String debugLabel = 'callback',
  });

  /// Runs [callback] at the start of every frame of the primary window, for
  /// as long as that window lives. Cannot be removed, as in Flutter.
  void addPersistentFrameCallback(FrameCallback callback);

  /// Asks every window for a frame.
  void scheduleFrame();

  /// Flutter's name for [scheduleFrame] when something visual changed.
  void ensureVisualUpdate() => scheduleFrame();

  /// Completes after the primary window's next frame, requesting one.
  Future<void> get endOfFrame;

  /// The application's lifecycle state, or null before an application has
  /// started.
  AppLifecycleState? get lifecycleState;
}

/// Flutter's `WidgetsBinding`: the glue between the framework and the
/// application running it.
///
/// A class rather than a mixin, so `class MyBinding with WidgetsBinding` does
/// not compile; `extends WidgetsFlutterBinding` does. See the library
/// comment for what it covers and what it speaks for in a multi-window
/// application.
abstract class WidgetsBinding extends SchedulerBinding {
  /// Registers this object as the process's binding.
  ///
  /// Throws [StateError] when one exists already, as Flutter's does.
  WidgetsBinding() : super._() {
    if (_instance != null) {
      throw StateError(
        'a WidgetsBinding was already initialised; use '
        'WidgetsBinding.instance or WidgetsFlutterBinding.ensureInitialized()',
      );
    }
    _instance = this;
  }

  static WidgetsBinding? _instance;

  /// The binding, created on first use; see [SchedulerBinding.instance].
  static WidgetsBinding get instance =>
      _instance ?? WidgetsFlutterBinding.ensureInitialized();

  final List<WidgetsBindingObserver> _observers = <WidgetsBindingObserver>[];
  final List<FrameCallback> _pendingPostFrame = <FrameCallback>[];
  final List<FrameCallback> _pendingPersistent = <FrameCallback>[];
  bool _pendingFrameRequest = false;

  Application? _application;
  Future<Application>? _whenDone;
  FrameScheduler? _primaryScheduler;
  AppLifecycleState? _lifecycleState;
  Size? _metricsSize;
  double? _metricsScale;
  SystemSettings? _settings;

  /// The application this binding speaks for, or null before `runApp` has
  /// started one (and after it ended).
  Application? get application => _application;

  /// Completes with the running application once it has closed; null when
  /// none is attached. What a second `runApp` returns.
  Future<Application>? get whenApplicationDone => _whenDone;

  /// Whether an application is attached and not closing.
  bool get hasRunningApplication {
    final Application? app = _application;
    if (app == null || app.isDisposed) return false;
    return app.state != ApplicationLifecycleState.closing &&
        app.state != ApplicationLifecycleState.closed;
  }

  /// Makes this binding speak for [application]. `runApp` calls it; call it
  /// yourself after `Application.start` to use the binding with a hand-driven
  /// application. [whenDone], if given, is what [whenApplicationDone] returns.
  ///
  /// Hands over the callbacks queued before there was an application.
  void attachApplication(
    Application application, {
    Future<Application>? whenDone,
  }) {
    final Application? previous = _application;
    if (previous != null && !identical(previous, application)) {
      detachApplication(previous);
    }
    _application = application;
    _whenDone = whenDone;
    application.addLifecycleListener(_handleLifecycle);
    application.systemSettings.addListener(_handleSettings);
    _settings = application.systemSettings.value;
    _lifecycleState = _lifecycleOf(application);

    final ApplicationWindow primary = application.primaryWindow;
    final FrameScheduler scheduler = primary.scheduler;
    _primaryScheduler = scheduler;
    _metricsSize = primary.host.logicalSize;
    _metricsScale = primary.host.renderScale;
    scheduler.addFrameCallback(_checkMetrics);
    for (final FrameCallback callback in _pendingPersistent) {
      scheduler.addFrameCallback(callback);
    }
    _pendingPersistent.clear();
    for (final FrameCallback callback in _pendingPostFrame) {
      scheduler.addPostFrameCallback(callback);
    }
    _pendingPostFrame.clear();
    if (_pendingFrameRequest) {
      _pendingFrameRequest = false;
      scheduleFrame();
    }
  }

  /// Stops speaking for [application], if this binding does. `runApp` calls
  /// it once the application has ended. Observers stay registered.
  void detachApplication(Application application) {
    if (!identical(_application, application)) return;
    application.removeLifecycleListener(_handleLifecycle);
    if (!application.isDisposed) {
      application.systemSettings.removeListener(_handleSettings);
    }
    final FrameScheduler? scheduler = _primaryScheduler;
    if (scheduler != null) scheduler.removeFrameCallback(_checkMetrics);
    _primaryScheduler = null;
    _application = null;
    _whenDone = null;
  }

  // --------------------------------------------------------------------------
  // Scheduling
  // --------------------------------------------------------------------------

  @override
  void addPostFrameCallback(
    FrameCallback callback, {
    String debugLabel = 'callback',
  }) {
    final FrameScheduler? scheduler = _liveScheduler;
    if (scheduler == null) {
      _pendingPostFrame.add(callback);
    } else {
      scheduler.addPostFrameCallback(callback);
    }
  }

  @override
  void addPersistentFrameCallback(FrameCallback callback) {
    final FrameScheduler? scheduler = _liveScheduler;
    if (scheduler == null) {
      _pendingPersistent.add(callback);
    } else {
      scheduler.addFrameCallback(callback);
    }
  }

  @override
  void scheduleFrame() {
    final Application? app = _application;
    if (app == null || app.isDisposed) {
      _pendingFrameRequest = true;
      return;
    }
    app.requestFrame();
    // The loop may be parked in a native wait for up to its idle timeout;
    // waking it is what makes the frame prompt.
    app.backend.wake();
  }

  @override
  Future<void> get endOfFrame {
    final Completer<void> completer = Completer<void>();
    addPostFrameCallback((Duration _) => completer.complete());
    scheduleFrame();
    return completer.future;
  }

  @override
  AppLifecycleState? get lifecycleState => _lifecycleState;

  FrameScheduler? get _liveScheduler {
    final Application? app = _application;
    if (app == null || app.isDisposed) return null;
    return _primaryScheduler;
  }

  // --------------------------------------------------------------------------
  // The primary window's tree
  // --------------------------------------------------------------------------

  ApplicationWindow get _primaryWindow {
    final Application? app = _application;
    if (app == null) {
      throw StateError(
        'no application is running yet; runApp() starts one, and the '
        'binding speaks for its primary window',
      );
    }
    return app.primaryWindow;
  }

  /// The primary window's build owner.
  BuildOwner get buildOwner => _primaryWindow.buildOwner;

  /// The primary window's focus manager.
  FocusManager get focusManager => buildOwner.focusManager;

  /// The root element of the primary window, or null before its first frame
  /// (or when no application is running).
  Element? get rootElement {
    final Application? app = _application;
    if (app == null || app.isDisposed) return null;
    return app.primaryWindow.buildOwner.rootElement;
  }

  // --------------------------------------------------------------------------
  // Observers
  // --------------------------------------------------------------------------

  /// Starts telling [observer] about lifecycle, metrics and settings changes.
  void addObserver(WidgetsBindingObserver observer) => _observers.add(observer);

  /// Stops telling [observer]; returns whether it was registered.
  bool removeObserver(WidgetsBindingObserver observer) =>
      _observers.remove(observer);

  /// Notifies observers that the application moved to [state]. Called by the
  /// binding itself; public because Flutter's is.
  void handleAppLifecycleStateChanged(AppLifecycleState state) {
    if (_lifecycleState == state) return;
    _lifecycleState = state;
    _notify((WidgetsBindingObserver o) => o.didChangeAppLifecycleState(state));
  }

  /// Notifies observers that the primary window's metrics changed.
  void handleMetricsChanged() =>
      _notify((WidgetsBindingObserver o) => o.didChangeMetrics());

  /// Notifies observers that the desktop's brightness changed.
  void handlePlatformBrightnessChanged() =>
      _notify((WidgetsBindingObserver o) => o.didChangePlatformBrightness());

  /// Notifies observers that the desktop's text scale changed.
  void handleTextScaleFactorChanged() =>
      _notify((WidgetsBindingObserver o) => o.didChangeTextScaleFactor());

  /// Notifies observers that an accessibility setting changed.
  void handleAccessibilityFeaturesChanged() =>
      _notify((WidgetsBindingObserver o) => o.didChangeAccessibilityFeatures());

  void _notify(void Function(WidgetsBindingObserver observer) call) {
    // A copy, because an observer commonly removes itself in response.
    for (final WidgetsBindingObserver observer
        in List<WidgetsBindingObserver>.of(_observers)) {
      call(observer);
    }
  }

  void _handleLifecycle() {
    final Application? app = _application;
    if (app == null) return;
    handleAppLifecycleStateChanged(_lifecycleOf(app));
  }

  void _handleSettings() {
    final Application? app = _application;
    if (app == null || app.isDisposed) return;
    final SystemSettings now = app.systemSettings.value;
    final SystemSettings? before = _settings;
    _settings = now;
    if (before == null) return;
    if (before.brightness != now.brightness) handlePlatformBrightnessChanged();
    if (before.textScaleFactor != now.textScaleFactor) {
      handleTextScaleFactorChanged();
    }
    if (before.highContrast != now.highContrast ||
        before.disableAnimations != now.disableAnimations ||
        before.boldText != now.boldText) {
      handleAccessibilityFeaturesChanged();
    }
  }

  /// A persistent frame callback on the primary window: a resize or a DPI
  /// change always ends in a frame, so comparing at the top of each frame is
  /// enough to see every change without a second event subscription.
  void _checkMetrics(Duration _) {
    final Application? app = _application;
    if (app == null || app.isDisposed) return;
    final ApplicationWindow window = app.primaryWindow;
    if (window.isDisposed) return;
    final Size size = window.host.logicalSize;
    final double scale = window.host.renderScale;
    if (size == _metricsSize && scale == _metricsScale) return;
    _metricsSize = size;
    _metricsScale = scale;
    handleMetricsChanged();
  }

  static AppLifecycleState _lifecycleOf(Application app) {
    switch (app.state) {
      case ApplicationLifecycleState.closing:
      case ApplicationLifecycleState.closed:
        return AppLifecycleState.detached;
      case ApplicationLifecycleState.suspended:
        return AppLifecycleState.hidden;
      case ApplicationLifecycleState.starting:
      case ApplicationLifecycleState.running:
        if (app.isDisposed) return AppLifecycleState.detached;
        final bool active = app.keyboardFocusWindow != null ||
            app.windows.any((ApplicationWindow w) => w.isActive);
        return active ? AppLifecycleState.resumed : AppLifecycleState.inactive;
    }
  }
}

/// Flutter's concrete binding; [ensureInitialized] is the call a `main`
/// makes before doing asynchronous work ahead of `runApp`.
class WidgetsFlutterBinding extends WidgetsBinding {
  WidgetsFlutterBinding();

  /// The binding, created if there is none yet.
  static WidgetsBinding ensureInitialized() =>
      WidgetsBinding._instance ?? WidgetsFlutterBinding();
}
