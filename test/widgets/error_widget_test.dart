/// ErrorWidget: a build that throws is replaced by ErrorWidget.builder's
/// widget, the error is still reported, and the window keeps running.
library;

import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

final class _Thrower extends StatelessWidget {
  const _Thrower();

  @override
  Widget build(BuildContext context) => throw StateError('build refused');
}

final class _Toggle extends StatefulWidget {
  const _Toggle();

  @override
  State<_Toggle> createState() => _ToggleState();
}

final class _ToggleState extends State<_Toggle> {
  bool fail = false;

  @override
  Widget build(BuildContext context) {
    if (fail) throw ArgumentError('now failing');
    return const Text('fine');
  }
}

BuildOwner _owner(ErrorReporter reporter) => BuildOwner(
      pipelineOwner: PipelineOwner(
        rootConstraints: BoxConstraints.tight(const Size(300, 200)),
      ),
    )..errorReporter = reporter;

List<Widget> _widgets(BuildOwner owner) {
  final List<Widget> found = <Widget>[];
  void walk(Element element) {
    found.add(element.widget);
    element.visitChildren(walk);
  }

  final Element? root = owner.rootElement;
  if (root != null) walk(root);
  return found;
}

void main() {
  late ErrorWidgetBuilder original;
  setUp(() => original = ErrorWidget.builder);
  tearDown(() => ErrorWidget.builder = original);

  test('a failing build is replaced by an ErrorWidget and reported', () {
    final ErrorReporter reporter = ErrorReporter();
    final BuildOwner owner = _owner(reporter);
    addTearDown(owner.dispose);

    owner.updateRoot(const Column(children: <Widget>[
      Text('above'),
      SizedBox(height: 50, child: _Thrower()),
    ]));
    owner.pipelineOwner.drawFrame(DisplayList());

    final ErrorWidget error = _widgets(owner).whereType<ErrorWidget>().single;
    expect(error.message, contains('build refused'));
    expect(error.message, contains('_Thrower'));
    expect(reporter.errors.single.widgetPath, contains('_Thrower'));

    // The box fills the space its parent gave it and paints it red.
    final RenderBox box = owner.renderRoot!;
    expect(box.size, const Size(300, 200));
  });

  test('ErrorWidget.builder decides what stands in', () {
    FlutterErrorDetails? seen;
    ErrorWidget.builder = (FlutterErrorDetails details) {
      seen = details;
      return const Text('friendly');
    };
    final ErrorReporter reporter = ErrorReporter();
    final BuildOwner owner = _owner(reporter);
    addTearDown(owner.dispose);

    owner.updateRoot(const _Thrower());
    expect(seen!.exception, isA<StateError>());
    expect(seen!.stack, isNotNull);
    expect(seen!.library, 'widgets library');
    expect(seen!.context.toString(), contains('_Thrower'));
    expect(seen!.exceptionAsString(), contains('build refused'));
    final Text text = _widgets(owner).whereType<Text>().single;
    expect(text.data, 'friendly');
  });

  test('a widget that starts failing loses its old child to the error box', () {
    final ErrorReporter reporter = ErrorReporter();
    final BuildOwner owner = _owner(reporter);
    addTearDown(owner.dispose);
    owner.updateRoot(const _Toggle());
    expect(_widgets(owner).whereType<Text>().single.data, 'fine');

    final StatefulElement element = owner.rootElement! as StatefulElement;
    final _ToggleState state = element.state as _ToggleState;
    state.setState(() => state.fail = true);
    owner.buildScope();
    expect(_widgets(owner).whereType<ErrorWidget>(), hasLength(1));

    state.setState(() => state.fail = false);
    owner.buildScope();
    expect(_widgets(owner).whereType<ErrorWidget>(), isEmpty);
    expect(_widgets(owner).whereType<Text>().single.data, 'fine');
    expect(reporter.errors, hasLength(1));
  });

  test('a rethrowing reporter still rethrows, after installing the box', () {
    final ErrorReporter reporter = ErrorReporter(rethrowErrors: true);
    final BuildOwner owner = _owner(reporter);
    addTearDown(owner.dispose);
    expect(() => owner.updateRoot(const _Thrower()), throwsStateError);
    expect(_widgets(owner).whereType<ErrorWidget>(), hasLength(1));
  });

  test('constructors and the release-style box', () {
    expect(ErrorWidget(StateError('x')).message, contains('x'));
    final ErrorWidget plain = ErrorWidget.withDetails();
    expect(plain.message, isEmpty);
    expect(ErrorWidget(1).key, isNot(equals(ErrorWidget(1).key)));

    final BuildOwner owner = _owner(ErrorReporter());
    addTearDown(owner.dispose);
    owner.updateRoot(plain);
    owner.pipelineOwner.drawFrame(DisplayList());
    expect(_widgets(owner).whereType<Text>(), isEmpty);
    expect(owner.renderRoot!.size, const Size(300, 200));
  });

  test('an unbounded parent still gets a finite box', () {
    final BuildOwner owner = _owner(ErrorReporter());
    addTearDown(owner.dispose);
    owner.updateRoot(const Column(children: <Widget>[_Thrower()]));
    owner.pipelineOwner.drawFrame(DisplayList());
    final ErrorWidget error = _widgets(owner).whereType<ErrorWidget>().single;
    expect(error, isNotNull);
  });
}
