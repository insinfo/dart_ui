/// WidgetsBinding over a headless application started by runApp: queued
/// callbacks, post-frame callbacks, a second runApp, lifecycle and metrics
/// observers.
library;

import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

const List<WindowingBackendEntry> _headless = <WindowingBackendEntry>[
  WindowingBackendEntry(name: 'headless', create: HeadlessWindowingBackend.new),
];

final class _Observer with WidgetsBindingObserver {
  final List<AppLifecycleState> states = <AppLifecycleState>[];
  int metrics = 0;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) => states.add(state);

  @override
  void didChangeMetrics() => metrics++;
}

List<String> _texts(Element? root) {
  final List<String> found = <String>[];
  void walk(Element element) {
    final Widget widget = element.widget;
    if (widget is Text) found.add(widget.data ?? '');
    element.visitChildren(walk);
  }

  if (root != null) walk(root);
  return found;
}

void main() {
  test('ensureInitialized returns the one binding, also as SchedulerBinding',
      () {
    final WidgetsBinding binding = WidgetsFlutterBinding.ensureInitialized();
    expect(WidgetsFlutterBinding.ensureInitialized(), same(binding));
    expect(WidgetsBinding.instance, same(binding));
    expect(SchedulerBinding.instance, same(binding));
    expect(() => WidgetsFlutterBinding(), throwsStateError);
  });

  test('callbacks queued before runApp run on its first frame', () async {
    final WidgetsBinding binding = WidgetsFlutterBinding.ensureInitialized();
    expect(binding.application, isNull);
    expect(binding.lifecycleState, isNull);
    expect(binding.rootElement, isNull);
    expect(() => binding.buildOwner, throwsStateError);

    final List<String> events = <String>[];
    binding.addPostFrameCallback((Duration _) {
      events.add('post-frame');
      // Registered from a post-frame callback: waits for the next frame.
      binding.addPostFrameCallback((Duration _) => events.add('next'));
      binding.scheduleFrame();
    });
    int persistent = 0;
    binding.addPersistentFrameCallback((Duration _) => persistent++);
    final _Observer observer = _Observer();
    binding.addObserver(observer);
    addTearDown(() => binding.removeObserver(observer));

    Application? attached;
    final Application app = await runApp(
      const Text('hello'),
      backends: _headless,
      options: const ApplicationOptions(size: Size(40, 20), frameBudget: 3),
      onStarted: (Application application) {
        attached = binding.application;
        expect(binding.buildOwner, same(application.buildOwner));
      },
    );

    expect(attached, same(app));
    expect(events, <String>['post-frame', 'next']);
    expect(persistent, greaterThanOrEqualTo(2));
    expect(observer.states.last, AppLifecycleState.detached);
    expect(binding.lifecycleState, AppLifecycleState.detached);
    expect(binding.application, isNull, reason: 'detached once it ended');
  });

  test('a second runApp replaces the root of the running application',
      () async {
    final WidgetsBinding binding = WidgetsFlutterBinding.ensureInitialized();
    final _Observer observer = _Observer();
    binding.addObserver(observer);
    addTearDown(() => binding.removeObserver(observer));

    final Future<Application> first = runApp(
      const Text('splash'),
      backends: _headless,
      options: const ApplicationOptions(size: Size(40, 20)),
    );
    await binding.endOfFrame;
    expect(_texts(binding.rootElement), <String>['splash']);
    expect(binding.lifecycleState, AppLifecycleState.resumed,
        reason: 'the headless window activates when shown');

    final Future<Application> second = runApp(const Text('app'));
    await binding.endOfFrame;
    expect(_texts(binding.rootElement), <String>['app']);

    // A resize reaches observers as a metrics change.
    final HeadlessWindow window =
        binding.application!.primaryWindow.nativeWindow as HeadlessWindow;
    window.setBounds(const Rect.fromLTWH(0, 0, 60, 30));
    await binding.endOfFrame;
    expect(observer.metrics, 1);

    binding.application!.requestClose();
    final Application closed = await first;
    expect(await second, same(closed));
    expect(observer.states.last, AppLifecycleState.detached);
  });
}
