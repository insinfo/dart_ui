/// The application follows the desktop's settings while it runs.
///
/// What is pinned here is the whole road from a backend's report to a widget:
/// a [SystemSettingsChangedEvent] on a window's stream becomes
/// [Application.systemSettings], which becomes every window's
/// [MediaQueryData], which rebuilds the widgets that read it - with the
/// application widget itself kept, as it is across a resize. The platform
/// halves (`WM_SETTINGCHANGE`, the macOS host's `SYSTEM_SETTINGS=` line) are
/// tested beside their backends; this file drives the headless backend, whose
/// `changeSystemSettings` delivers to every window the way the real ones do.
library;

import 'dart:async';

import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

const SystemSettings _dark = SystemSettings(brightness: Brightness.dark);

void main() {
  group('startup', () {
    test('a headless application sees the light fallback, not the machine',
        () async {
      final List<MediaQueryData> seen = <MediaQueryData>[];
      final Application application = await _start(root: _Probe(seen.add));
      await application.drawFrame();

      expect(application.systemSettings.value, SystemSettings.fallback);
      expect(seen.last.platformBrightness, Brightness.light);
      expect(seen.last.highContrast, isFalse);
      expect(seen.last.disableAnimations, isFalse);
      expect(seen.last.textScaleFactor, 1.0);

      await _close(application);
    });

    test('a synchronous source mounts the first frame in its settings',
        () async {
      final List<MediaQueryData> seen = <MediaQueryData>[];
      final Application application = await _start(
        root: _Probe(seen.add),
        backend: () => HeadlessWindowingBackend(
          systemSettings: const SystemSettings(
            brightness: Brightness.dark,
            highContrast: true,
            disableAnimations: true,
            textScaleFactor: 1.5,
          ),
        ),
      );
      await application.drawFrame();

      // Every build, not only the last: a light first frame followed by a
      // dark one is exactly the flash a synchronous answer exists to avoid.
      expect(
        seen.map((MediaQueryData data) => data.platformBrightness),
        everyElement(Brightness.dark),
      );
      expect(seen.last.highContrast, isTrue);
      expect(seen.last.disableAnimations, isTrue);
      expect(seen.last.textScaleFactor, 1.5);

      await _close(application);
    });

    test('an asynchronous answer is applied when it lands', () async {
      final _AsyncSettingsBackend backend = _AsyncSettingsBackend();
      final List<MediaQueryData> seen = <MediaQueryData>[];
      final Application application = await _start(
        root: _Probe(seen.add),
        backend: () => backend,
      );
      await application.drawFrame();
      expect(seen.last.platformBrightness, Brightness.light);

      backend.answer.complete(_dark);
      await Future<void>.delayed(Duration.zero);
      await application.drawFrame();

      expect(seen.last.platformBrightness, Brightness.dark);
      await _close(application);
    });

    test('a slow startup answer does not overwrite a newer change', () async {
      final _AsyncSettingsBackend backend = _AsyncSettingsBackend();
      final List<MediaQueryData> seen = <MediaQueryData>[];
      final Application application = await _start(
        root: _Probe(seen.add),
        backend: () => backend,
      );
      final HeadlessWindow window = _native(application);

      // The user switched to high contrast while gsettings was still
      // answering the startup question with "dark".
      const SystemSettings newer = SystemSettings(highContrast: true);
      application.handleEvent(SystemSettingsChangedEvent(
        windowId: window.id,
        generation: window.generation,
        settings: newer,
      ));
      backend.answer.complete(_dark);
      await Future<void>.delayed(Duration.zero);
      await application.drawFrame();

      expect(application.systemSettings.value, newer);
      expect(seen.last.platformBrightness, Brightness.light);
      expect(seen.last.highContrast, isTrue);
      await _close(application);
    });

    test('so does an application override made before it', () async {
      final _AsyncSettingsBackend backend = _AsyncSettingsBackend();
      final Application application = await _start(
        root: const SizedBox(),
        backend: () => backend,
      );
      const SystemSettings chosen = SystemSettings(disableAnimations: true);
      application.systemSettings.value = chosen;
      backend.answer.complete(_dark);
      await Future<void>.delayed(Duration.zero);

      expect(application.systemSettings.value, chosen);
      await _close(application);
    });
  });

  group('a change while running', () {
    test('rebuilds the widgets that read MediaQuery, and keeps their state',
        () async {
      final List<MediaQueryData> seen = <MediaQueryData>[];
      final List<_CounterState> states = <_CounterState>[];
      final HeadlessWindowingBackend backend = HeadlessWindowingBackend();
      final Application application = await _start(
        root: _Counter(states: states, child: _Probe(seen.add)),
        backend: () => backend,
      );
      await application.drawFrame();
      final int buildsBefore = seen.length;
      expect(seen.last.platformBrightness, Brightness.light);

      backend.changeSystemSettings(_dark);
      application.backend.pumpEvents();
      await application.drawFrame();

      expect(seen.length, greaterThan(buildsBefore),
          reason: 'the dependent did not rebuild');
      expect(seen.last.platformBrightness, Brightness.dark);
      expect(application.systemSettings.value, _dark);
      expect(states, hasLength(1),
          reason: 'the application widget must be updated in place, as on '
              'a resize - a remount would throw away every State below it');

      backend.changeSystemSettings(SystemSettings.fallback);
      application.backend.pumpEvents();
      await application.drawFrame();
      expect(seen.last.platformBrightness, Brightness.light);
      expect(states, hasLength(1));

      await _close(application);
    });

    test('keeps the window metrics it already had', () async {
      final List<MediaQueryData> seen = <MediaQueryData>[];
      final HeadlessWindowingBackend backend =
          HeadlessWindowingBackend(renderScale: 2);
      final Application application = await _start(
        root: _Probe(seen.add),
        backend: () => backend,
        size: const Size(30, 20),
      );
      await application.drawFrame();

      backend.changeSystemSettings(_dark);
      application.backend.pumpEvents();
      await application.drawFrame();

      expect(seen.last.size, const Size(30, 20));
      expect(seen.last.devicePixelRatio, 2);
      expect(seen.last.platformBrightness, Brightness.dark);
      await _close(application);
    });

    test('a theme picked from the platform brightness follows it', () async {
      final List<ThemeData> themes = <ThemeData>[];
      final HeadlessWindowingBackend backend = HeadlessWindowingBackend();
      final Application application = await _start(
        root: _FollowsSystemTheme(child: _ThemeProbe(themes.add)),
        backend: () => backend,
      );
      await application.drawFrame();
      expect(themes.last.brightness, Brightness.light);

      backend.changeSystemSettings(_dark);
      application.backend.pumpEvents();
      await application.drawFrame();

      expect(themes.last.brightness, Brightness.dark);
      await _close(application);
    });

    test('reaches every window, and notifies once for the copies', () async {
      final List<MediaQueryData> first = <MediaQueryData>[];
      final List<MediaQueryData> second = <MediaQueryData>[];
      final HeadlessWindowingBackend backend = HeadlessWindowingBackend();
      final Application application = await _start(
        root: _Probe(first.add),
        backend: () => backend,
      );
      await application.openWindow(
        rootWidget: _Probe(second.add),
        title: 'second',
        size: const Size(40, 30),
      );
      await application.drawPendingFrames();

      var notifications = 0;
      application.systemSettings.addListener(() => notifications++);

      // One copy per window, as WM_SETTINGCHANGE and the per-window macOS
      // hosts deliver it.
      backend.changeSystemSettings(_dark);
      expect(backend.pendingEventCount, 2);
      application.backend.pumpEvents();
      await application.drawPendingFrames();

      expect(notifications, 1);
      expect(first.last.platformBrightness, Brightness.dark);
      expect(second.last.platformBrightness, Brightness.dark);
      await _close(application);
    });

    test('is applied even when it names a window that is gone', () async {
      final List<MediaQueryData> seen = <MediaQueryData>[];
      final Application application = await _start(root: _Probe(seen.add));
      await application.drawFrame();

      final bool handled = application.handleEvent(
        const SystemSettingsChangedEvent(
          windowId: NativeWindowId(9999),
          generation: 0,
          settings: _dark,
        ),
      );
      await application.drawFrame();

      expect(handled, isTrue);
      expect(application.eventsDropped, 0);
      expect(seen.last.platformBrightness, Brightness.dark);
      await _close(application);
    });

    test('an identical report rebuilds nothing', () async {
      final List<MediaQueryData> seen = <MediaQueryData>[];
      final HeadlessWindowingBackend backend = HeadlessWindowingBackend();
      final Application application = await _start(
        root: _Probe(seen.add),
        backend: () => backend,
      );
      await application.drawFrame();
      final int builds = seen.length;

      backend.changeSystemSettings(SystemSettings.fallback);
      application.backend.pumpEvents();
      await application.drawFrame();

      expect(seen.length, builds);
      await _close(application);
    });

    test('an application override reaches the windows too', () async {
      final List<MediaQueryData> seen = <MediaQueryData>[];
      final Application application = await _start(root: _Probe(seen.add));
      await application.drawFrame();

      application.systemSettings.value = _dark;
      await application.drawFrame();

      expect(seen.last.platformBrightness, Brightness.dark);
      await _close(application);
    });
  });
}

Future<Application> _start({
  required Widget root,
  WindowingBackend Function()? backend,
  Size size = const Size(20, 10),
}) =>
    Application.start(
      rootWidget: root,
      backends: <WindowingBackendEntry>[
        WindowingBackendEntry(
          name: 'headless',
          create: backend ?? HeadlessWindowingBackend.new,
        ),
      ],
      options: ApplicationOptions(title: 'settings', size: size),
    );

Future<void> _close(Application application) async {
  application.dispose();
  await application.closed;
}

HeadlessWindow _native(Application application) =>
    application.primaryWindow.nativeWindow as HeadlessWindow;

final class _Probe extends StatelessWidget {
  const _Probe(this.onBuild);

  final void Function(MediaQueryData data) onBuild;

  @override
  Widget build(BuildContext context) {
    onBuild(MediaQuery.of(context));
    return const SizedBox();
  }
}

/// A stateful root that records each State it creates, so a remount - a new
/// State where the old one should have been updated - is countable.
final class _Counter extends StatefulWidget {
  const _Counter({required this.states, required this.child});

  final List<_CounterState> states;
  final Widget child;

  @override
  State<_Counter> createState() => _CounterState();
}

final class _CounterState extends State<_Counter> {
  @override
  void initState() {
    super.initState();
    widget.states.add(this);
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// What an application that follows the system theme writes.
final class _FollowsSystemTheme extends StatelessWidget {
  const _FollowsSystemTheme({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Theme(
        data: MediaQuery.platformBrightnessOf(context) == Brightness.dark
            ? ThemeData.neutralDark
            : ThemeData.neutralLight,
        child: child,
      );
}

final class _ThemeProbe extends StatelessWidget {
  const _ThemeProbe(this.onBuild);

  final void Function(ThemeData theme) onBuild;

  @override
  Widget build(BuildContext context) {
    onBuild(Theme.of(context));
    return const SizedBox();
  }
}

/// The headless backend, answering the startup question the way gsettings
/// does: later.
final class _AsyncSettingsBackend
    implements WindowingBackend, SystemSettingsSource {
  final HeadlessWindowingBackend _delegate = HeadlessWindowingBackend();
  final Completer<SystemSettings?> answer = Completer<SystemSettings?>();

  @override
  Future<SystemSettings?> readSystemSettings() => answer.future;

  @override
  String get name => _delegate.name;

  @override
  BackendProbeResult probe() => _delegate.probe();

  @override
  Future<void> initialize() => _delegate.initialize();

  @override
  Future<void> shutdown() => _delegate.shutdown();

  @override
  Future<NativeWindow> createWindow(WindowOptions options) =>
      _delegate.createWindow(options);

  @override
  List<NativeWindow> get windows => _delegate.windows;

  @override
  bool pumpEvents({Duration timeout = Duration.zero}) => _delegate.pumpEvents();

  @override
  void wake() => _delegate.wake();
}
