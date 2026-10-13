/// WidgetsApp: home, routes, initialRoute, builder, navigatorKey,
/// pageRouteBuilder, title and localizations, on dart_ui's Navigator.
library;

import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

const Duration _frame = Duration(milliseconds: 10);
const Color _black = Color(0xFF000000);

final class _FakeWindow implements WindowController {
  final List<String> titles = <String>[];

  @override
  void setTitle(String title) => titles.add(title);

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

final class _Harness {
  _Harness() {
    pipeline = PipelineOwner(
        rootConstraints: BoxConstraints.tight(const Size(300, 300)));
    final FrameScheduler scheduler = FrameScheduler(
      dispatcher: dispatcher,
      pipelineOwner: pipeline,
      frameInterval: _frame,
      onFrame: (DisplayList list) {},
    );
    clock = AnimationClock()..attachTo(scheduler);
    owner = BuildOwner(
      pipelineOwner: pipeline,
      onBuildScheduled: scheduler.scheduleFrame,
    );
  }

  final ManualDispatcher dispatcher = ManualDispatcher();
  final _FakeWindow window = _FakeWindow();
  late final PipelineOwner pipeline;
  late final BuildOwner owner;
  late final AnimationClock clock;

  void mount(Widget app) {
    owner.updateRoot(WindowScope(
      controller: window,
      child: AnimationScope(clock: clock, child: app),
    ));
    pump();
  }

  void pump([int frames = 30]) {
    for (int i = 0; i < frames; i++) {
      dispatcher.advance(_frame);
      owner.buildScope();
      pipeline.flushLayout();
    }
  }

  /// The strings of every Text currently in the element tree.
  List<String> texts() {
    final List<String> found = <String>[];
    void walk(Element element) {
      final Widget widget = element.widget;
      if (widget is Text) found.add(widget.data ?? '');
      element.visitChildren(walk);
    }

    final Element? root = owner.rootElement;
    if (root != null) walk(root);
    return found;
  }

  void dispose() => owner.dispose();
}

void main() {
  late _Harness harness;
  setUp(() => harness = _Harness());
  tearDown(() => harness.dispose());

  test('home is the "/" route and the navigator is reachable by key', () {
    final GlobalKey<NavigatorState> key = GlobalKey<NavigatorState>();
    harness.mount(WidgetsApp(
      navigatorKey: key,
      color: _black,
      home: const Text('home'),
      routes: <String, WidgetBuilder>{
        '/detail': (BuildContext context) => const Text('detail'),
      },
    ));
    expect(harness.texts(), <String>['home']);

    key.currentState!.pushNamed('/detail');
    harness.pump();
    expect(harness.texts(), contains('detail'));

    key.currentState!.pop<Object?>();
    harness.pump();
    expect(harness.texts(), <String>['home']);
  });

  test('initialRoute and onGenerateRoute', () {
    harness.mount(WidgetsApp(
      color: _black,
      initialRoute: '/generated',
      onGenerateRoute: (RouteSettings settings) => PageRouteBuilder<Object?>(
        settings: settings,
        pageBuilder:
            (BuildContext context, Animation<double> a, Animation<double> b) =>
                Text('generated ${settings.name}'),
      ),
    ));
    expect(harness.texts(), <String>['generated /generated']);
  });

  test('builder wraps the navigator, or builds the app alone', () {
    harness.mount(WidgetsApp(
      color: _black,
      home: const Text('home'),
      builder: (BuildContext context, Widget? child) =>
          Column(children: <Widget>[const Text('chrome'), child!]),
    ));
    expect(harness.texts(), <String>['chrome', 'home']);

    final _Harness alone = _Harness();
    addTearDown(alone.dispose);
    Widget? navigator = const Text('unset');
    alone.mount(WidgetsApp(
      color: _black,
      builder: (BuildContext context, Widget? child) {
        navigator = child;
        return const Text('no navigator');
      },
    ));
    expect(navigator, isNull);
    expect(alone.texts(), <String>['no navigator']);
  });

  test('pageRouteBuilder makes the routes for home and routes', () {
    final List<String?> built = <String?>[];
    harness.mount(WidgetsApp(
      color: _black,
      home: const Text('home'),
      pageRouteBuilder: <T>(RouteSettings settings, WidgetBuilder builder) {
        built.add(settings.name);
        return PageRouteBuilder<T>(
          settings: settings,
          pageBuilder: (BuildContext context, Animation<double> a,
                  Animation<double> b) =>
              builder(context),
        );
      },
    ));
    expect(built, <String?>['/']);
    expect(harness.texts(), <String>['home']);
  });

  test('the title goes to the window, generated under the app', () {
    harness.mount(const WidgetsApp(
      color: _black,
      title: 'My App',
      home: Text('home'),
    ));
    expect(harness.window.titles, <String>['My App']);

    final _Harness generated = _Harness();
    addTearDown(generated.dispose);
    generated.mount(WidgetsApp(
      color: _black,
      locale: Locale('pt', null, 'BR'),
      onGenerateTitle: (BuildContext context) =>
          'App ${Localizations.localeOf(context).toLanguageTag()}',
      home: const Text('home'),
    ));
    expect(generated.window.titles, <String>['App pt-BR']);
  });

  test('an empty title leaves the window title alone', () {
    harness.mount(const WidgetsApp(color: _black, home: Text('home')));
    expect(harness.window.titles, isEmpty);
  });

  test('locale resolution callbacks pick the installed locale', () {
    Locale? seen;
    harness.mount(WidgetsApp(
      color: _black,
      supportedLocales: <Locale>[Locale('en'), Locale('pt')],
      localeResolutionCallback:
          (Locale? requested, Iterable<Locale> supported) => supported.last,
      home: Builder(builder: (BuildContext context) {
        seen = Localizations.localeOf(context);
        return const Text('home');
      }),
    ));
    expect(seen, Locale('pt'));
  });

  test('textStyle becomes the default text style', () {
    TextStyle? seen;
    harness.mount(WidgetsApp(
      color: _black,
      textStyle: const TextStyle(fontSize: 31),
      home: Builder(builder: (BuildContext context) {
        seen = DefaultTextStyle.of(context);
        return const Text('home');
      }),
    ));
    expect(seen!.fontSize, 31);
  });

  test('nothing to show is a named error, not a blank window', () {
    final ErrorReporter reporter = ErrorReporter();
    harness.owner.errorReporter = reporter;
    harness.mount(const WidgetsApp(color: _black));
    expect(reporter.errors.single.cause, isA<StateError>());
    expect('${reporter.errors.single.cause}', contains('home, routes'));
  });

  test('home together with a "/" route is refused', () {
    final ErrorReporter reporter = ErrorReporter();
    harness.owner.errorReporter = reporter;
    harness.mount(WidgetsApp(
      color: _black,
      home: const Text('home'),
      routes: <String, WidgetBuilder>{
        '/': (BuildContext context) => const Text('root'),
      },
    ));
    expect(reporter.errors.single.cause, isA<ArgumentError>());
  });
}
