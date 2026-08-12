/// Multi-child reconciliation, inherited context, and error attribution.
library;

import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

/// A leaf that records how many times it was created, so a test can tell
/// "reused" from "rebuilt" - which is the whole question reconciliation
/// answers.
final class _Tagged extends StatefulWidget {
  const _Tagged(this.tag, {super.key});

  final String tag;

  static final List<String> created = <String>[];
  static final List<String> disposed = <String>[];

  @override
  State<_Tagged> createState() => _TaggedState();
}

final class _TaggedState extends State<_Tagged> {
  late final String bornAs;

  @override
  void initState() {
    super.initState();
    bornAs = widget.tag;
    _Tagged.created.add(widget.tag);
  }

  @override
  void dispose() {
    _Tagged.disposed.add(widget.tag);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Text(widget.tag);
}

final class _Ambient extends InheritedWidget {
  const _Ambient({required this.value, required super.child});

  final int value;

  static int of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_Ambient>()?.value ?? -1;

  @override
  bool updateShouldNotify(_Ambient oldWidget) => value != oldWidget.value;
}

final class _Reader extends StatelessWidget {
  const _Reader({required this.log});

  final List<int> log;

  @override
  Widget build(BuildContext context) {
    log.add(_Ambient.of(context));
    return const Text('R');
  }
}

final class _Thrower extends StatelessWidget {
  const _Thrower();

  @override
  Widget build(BuildContext context) => throw StateError('build refused');
}

void main() {
  setUp(() {
    _Tagged.created.clear();
    _Tagged.disposed.clear();
  });

  group('multi-child reconciliation', () {
    test('children reach the render tree in widget order', () {
      final owner = _owner();
      owner.updateRoot(const Column(children: <Widget>[
        Text('A'),
        Text('B'),
        Text('C'),
      ]));
      owner.pipelineOwner.drawFrame(DisplayList());

      expect(_texts(owner), <String>['A', 'B', 'C']);
      owner.dispose();
    });

    test('inserting at the front reuses every existing element', () {
      final owner = _owner();
      owner.updateRoot(const Column(children: <Widget>[
        _Tagged('a', key: ValueKey<String>('a')),
        _Tagged('b', key: ValueKey<String>('b')),
      ]));
      owner.pipelineOwner.drawFrame(DisplayList());
      expect(_Tagged.created, <String>['a', 'b']);

      owner.updateRoot(const Column(children: <Widget>[
        _Tagged('z', key: ValueKey<String>('z')),
        _Tagged('a', key: ValueKey<String>('a')),
        _Tagged('b', key: ValueKey<String>('b')),
      ]));
      owner.pipelineOwner.drawFrame(DisplayList());

      // Only the new one was built: without keys this would have rebuilt every
      // element after the insertion point and lost their state.
      expect(_Tagged.created, <String>['a', 'b', 'z']);
      expect(_Tagged.disposed, isEmpty);
      expect(_texts(owner), <String>['z', 'a', 'b']);
      owner.dispose();
    });

    test('reordering keyed children moves render objects, not state', () {
      final owner = _owner();
      owner.updateRoot(const Column(children: <Widget>[
        _Tagged('a', key: ValueKey<String>('a')),
        _Tagged('b', key: ValueKey<String>('b')),
        _Tagged('c', key: ValueKey<String>('c')),
      ]));
      owner.pipelineOwner.drawFrame(DisplayList());

      owner.updateRoot(const Column(children: <Widget>[
        _Tagged('c', key: ValueKey<String>('c')),
        _Tagged('b', key: ValueKey<String>('b')),
        _Tagged('a', key: ValueKey<String>('a')),
      ]));
      owner.pipelineOwner.drawFrame(DisplayList());

      expect(_Tagged.created, <String>['a', 'b', 'c'], reason: 'no rebuilds');
      expect(_Tagged.disposed, isEmpty);
      expect(_texts(owner), <String>['c', 'b', 'a']);
      owner.dispose();
    });

    test('a removed child is unmounted and detached from the render tree', () {
      final owner = _owner();
      owner.updateRoot(const Column(children: <Widget>[
        _Tagged('a', key: ValueKey<String>('a')),
        _Tagged('b', key: ValueKey<String>('b')),
      ]));
      owner.pipelineOwner.drawFrame(DisplayList());

      owner.updateRoot(const Column(children: <Widget>[
        _Tagged('a', key: ValueKey<String>('a')),
      ]));
      owner.pipelineOwner.drawFrame(DisplayList());

      expect(_Tagged.disposed, <String>['b']);
      expect(_texts(owner), <String>['a']);
      owner.dispose();
    });

    test('an unkeyed list matches positionally', () {
      final owner = _owner();
      owner.updateRoot(const Column(children: <Widget>[
        _Tagged('a'),
        _Tagged('b'),
      ]));
      owner.pipelineOwner.drawFrame(DisplayList());

      owner.updateRoot(const Column(children: <Widget>[
        _Tagged('x'),
        _Tagged('y'),
      ]));
      owner.pipelineOwner.drawFrame(DisplayList());

      // Same type, no key: the elements are reused and only the widget
      // changed, which is why the state remembers the tag it was born with.
      expect(_Tagged.created, <String>['a', 'b']);
      expect(_texts(owner), <String>['x', 'y']);
      owner.dispose();
    });

    test('a component child contributes its subtree render object', () {
      final owner = _owner();
      owner.updateRoot(Column(children: <Widget>[
        const Text('A'),
        Button(label: 'B', onPressed: () {}),
      ]));
      owner.pipelineOwner.drawFrame(DisplayList());

      final RenderBox root = owner.renderRoot!;
      final container = root as RenderBoxContainer;
      expect(container.childCount, 2);
      expect(container.childAt(0), isA<RenderText>());
      expect(container.childAt(1), isA<RenderButton>(),
          reason: 'Button is a component, but its render child takes its slot');
      owner.dispose();
    });

    test('a nested container keeps its own order', () {
      final owner = _owner();
      owner.updateRoot(const Column(children: <Widget>[
        Row(children: <Widget>[Text('A'), Text('B')]),
        Text('C'),
      ]));
      owner.pipelineOwner.drawFrame(DisplayList());

      expect(_texts(owner), <String>['A', 'B', 'C']);
      owner.dispose();
    });

    test('reorderChildren refuses anything that is not a permutation', () {
      final flex = RenderFlex(direction: Axis.vertical);
      final a = RenderText('A');
      final b = RenderText('B');
      flex
        ..add(a)
        ..add(b);

      expect(() => flex.reorderChildren(<RenderBox>[a]), throwsStateError);
      expect(() => flex.reorderChildren(<RenderBox>[a, a]), throwsStateError);
      expect(
        () => flex.reorderChildren(<RenderBox>[a, RenderText('C')]),
        throwsStateError,
      );
    });
  });

  group('inherited context', () {
    test('a descendant reads the nearest value', () {
      final log = <int>[];
      final owner = _owner();
      owner.updateRoot(_Ambient(value: 7, child: _Reader(log: log)));

      expect(log, <int>[7]);
      owner.dispose();
    });

    test('a nested value shadows the outer one', () {
      final log = <int>[];
      final owner = _owner();
      owner.updateRoot(_Ambient(
        value: 1,
        child: _Ambient(value: 2, child: _Reader(log: log)),
      ));

      expect(log, <int>[2]);
      owner.dispose();
    });

    test('changing the value rebuilds only the dependents', () {
      final log = <int>[];
      final owner = _owner();
      owner.updateRoot(_Ambient(value: 1, child: _Reader(log: log)));
      expect(log, <int>[1]);

      owner.updateRoot(_Ambient(value: 2, child: _Reader(log: log)));
      expect(log, <int>[1, 2]);
      owner.dispose();
    });

    test('a reader is registered as a dependent, and notified on demand', () {
      final log = <int>[];
      final owner = _owner();
      final Element root =
          owner.updateRoot(_Ambient(value: 1, child: _Reader(log: log)))!;
      expect(log, <int>[1]);

      final InheritedElement inherited = root as InheritedElement;
      expect(inherited.dependents, hasLength(1));

      // Notifying is what a changed value does; doing it directly separates
      // "the dependency was recorded" from "the ancestor decided to change".
      inherited.notifyDependents();
      owner.buildScope();
      expect(log, <int>[1, 1]);
      owner.dispose();
    });

    test('updateShouldNotify decides whether a change propagates at all', () {
      // The inherited widget's own answer, tested where it is decided. A Theme
      // whose payload is equal must report false, or every ancestor rebuild
      // would cost a full-subtree rebuild.
      final Theme first = Theme(
        data: ThemeData.neutralLight,
        child: const Text('x'),
      );
      final Theme same = Theme(
        data: ThemeData.neutralLight,
        styles: first.styles,
        resources: first.resources,
        templates: first.templates,
        child: const Text('x'),
      );
      final Theme different = Theme(
        data: ThemeData.neutralDark,
        styles: first.styles,
        resources: first.resources,
        templates: first.templates,
        child: const Text('x'),
      );

      expect(same.updateShouldNotify(first), isFalse);
      expect(different.updateShouldNotify(first), isTrue);
    });

    test('a missing ancestor reads as absent rather than throwing', () {
      final log = <int>[];
      final owner = _owner();
      owner.updateRoot(_Reader(log: log));

      expect(log, <int>[-1]);
      owner.dispose();
    });

    test('an unmounted dependent is deregistered', () {
      final log = <int>[];
      final owner = _owner();
      owner.updateRoot(_Ambient(value: 1, child: _Reader(log: log)));
      owner.updateRoot(const _Ambient(value: 1, child: Text('none')));

      // Rebuilding the ancestor must not touch the element that left.
      owner.updateRoot(const _Ambient(value: 2, child: Text('none')));
      expect(log, <int>[1]);
      owner.dispose();
    });

    test('findAncestorWidgetOfExactType walks without creating a dependency',
        () {
      final owner = _owner();
      final Element? root =
          owner.updateRoot(const _Ambient(value: 3, child: Text('x')));

      expect(root, isNotNull);
      expect(root!.findAncestorWidgetOfExactType<Column>(), isNull);
      owner.dispose();
    });
  });

  group('error attribution', () {
    test('a failing build names the widget path and is rethrown by default',
        () {
      final reporter = ErrorReporter(rethrowErrors: true);
      final owner = _owner()..errorReporter = reporter;

      expect(
        () => owner.updateRoot(const Column(children: <Widget>[_Thrower()])),
        throwsStateError,
      );
      expect(reporter.errors, hasLength(1));

      final FrameworkError error = reporter.errors.single;
      expect(error.phase, FrameworkPhase.build);
      expect(error.widgetPath, contains('_Thrower'));
      expect(error.describe(), contains('build refused'));
      expect(error.describe(), contains('_Thrower'));
      owner.dispose();
    });

    test('a containing reporter keeps the rest of the frame alive', () {
      final reporter = ErrorReporter();
      final owner = _owner()..errorReporter = reporter;

      owner.updateRoot(const Column(children: <Widget>[
        Text('A'),
        _Thrower(),
        Text('C'),
      ]));
      owner.pipelineOwner.drawFrame(DisplayList());

      expect(reporter.hasErrors, isTrue);
      // The siblings still built and still painted: one bad widget must not
      // take the window with it.
      expect(_texts(owner), <String>['A', 'C']);
      owner.dispose();
    });

    test('the error log is bounded', () {
      final reporter = ErrorReporter(capacity: 3);
      for (int i = 0; i < 10; i++) {
        reporter.report(FrameworkError(
          phase: FrameworkPhase.build,
          cause: 'error $i',
        ));
      }

      expect(reporter.errors, hasLength(3));
      expect(reporter.errors.last.cause, 'error 9');
    });
  });
}

BuildOwner _owner() => BuildOwner(
      pipelineOwner: PipelineOwner(
        rootConstraints: BoxConstraints.tight(const Size(200, 200)),
      ),
    );

/// The text leaves in the render tree, in paint order.
List<String> _texts(BuildOwner owner) {
  final List<String> result = <String>[];
  void walk(RenderBox node) {
    if (node is RenderText) result.add(node.text);
    node.visitChildren(walk);
  }

  final RenderBox? root = owner.renderRoot;
  if (root != null) walk(root);
  return result;
}
