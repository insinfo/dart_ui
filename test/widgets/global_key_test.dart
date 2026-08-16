/// Global keys: reaching a [State] from outside its subtree, and moving a
/// subtree without losing it.
///
/// The two properties asserted here are the two a global key exists for. A
/// dialog holding a key can call into a form it has no path to; and a subtree
/// that changes parents keeps its state object, its render objects and its
/// per-child layout configuration, instead of being disposed and rebuilt as if
/// it were a deletion followed by an unrelated insertion.
library;

import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

/// A leaf with observable identity: how many times its state was created, what
/// it currently holds, and how many builds it has run.
final class _Counter extends StatefulWidget {
  const _Counter({super.key, this.width = 10});

  final double width;

  static int created = 0;
  static int disposed = 0;

  @override
  State<_Counter> createState() => _CounterState();
}

final class _CounterState extends State<_Counter> {
  int value = 0;
  int builds = 0;

  @override
  void initState() {
    super.initState();
    _Counter.created++;
  }

  @override
  void dispose() {
    _Counter.disposed++;
    super.dispose();
  }

  void bump() => setState(() => value++);

  @override
  Widget build(BuildContext context) {
    builds++;
    return SizedBox(width: widget.width, height: 10);
  }
}

final class _Ambient extends InheritedWidget {
  const _Ambient({required this.value, required super.child});

  final int value;

  @override
  bool updateShouldNotify(_Ambient oldWidget) => oldWidget.value != value;
}

/// Records the ambient value it saw on each build, so a move can be checked to
/// have re-scoped it rather than left it reading a value it can no longer see.
final class _Reader extends StatefulWidget {
  const _Reader({super.key});

  @override
  State<_Reader> createState() => _ReaderState();
}

final class _ReaderState extends State<_Reader> {
  final List<int> seen = <int>[];

  @override
  Widget build(BuildContext context) {
    seen.add(
      context.dependOnInheritedWidgetOfExactType<_Ambient>()?.value ?? -1,
    );
    return const SizedBox(width: 10, height: 10);
  }
}

void main() {
  setUpAll(() {
    expect(
      FontRegistry.instance.useFontFile('test/fonts/Roboto-Regular.ttf'),
      isTrue,
    );
  });
  tearDownAll(FontRegistry.instance.reset);

  setUp(() {
    _Counter.created = 0;
    _Counter.disposed = 0;
  });

  BuildOwner ownerFor(Size viewport) => BuildOwner(
        pipelineOwner: PipelineOwner(
          rootConstraints: BoxConstraints.tight(viewport),
        ),
      );

  RenderFlex rowAt(BuildOwner owner, int index) =>
      (owner.renderRoot! as RenderFlex).childAt(index) as RenderFlex;

  group('reach', () {
    test('a key held anywhere finds the state it names', () {
      final GlobalKey<_CounterState> key = GlobalKey<_CounterState>();
      final BuildOwner owner = ownerFor(const Size(200, 50));
      owner.updateRoot(
        Row(
          children: <Widget>[
            const SizedBox(width: 5, height: 5),
            Column(children: <Widget>[_Counter(key: key)]),
          ],
        ),
      );

      final _CounterState? state = key.currentState;
      expect(state, isNotNull);
      expect(key.currentWidget, isA<_Counter>());
      expect(key.currentContext, isNotNull);
      expect(key.currentContext!.mounted, isTrue);

      state!.bump();
      owner.buildScope();
      expect(key.currentState!.value, 1);
    });

    test('a key whose element is gone answers null', () {
      final GlobalKey<_CounterState> key = GlobalKey<_CounterState>();
      final BuildOwner owner = ownerFor(const Size(200, 50));
      owner.updateRoot(Row(children: <Widget>[_Counter(key: key)]));
      expect(key.currentState, isNotNull);

      owner.updateRoot(const Row(children: <Widget>[SizedBox()]));

      expect(key.currentElement, isNull);
      expect(key.currentState, isNull);
      expect(key.currentContext, isNull);
      expect(_Counter.disposed, 1);
    });

    test('two keys are never equal, and one is always itself', () {
      final GlobalKey<_CounterState> first = GlobalKey<_CounterState>();
      final GlobalKey<_CounterState> second = GlobalKey<_CounterState>();
      expect(first == second, isFalse);
      expect(first == first, isTrue);
      expect(GlobalKey<_CounterState>(debugLabel: 'form').toString(),
          contains('form'));
    });
  });

  group('move', () {
    test('a subtree moved to a later sibling keeps its state', () {
      final GlobalKey<_CounterState> key = GlobalKey<_CounterState>();
      final BuildOwner owner = ownerFor(const Size(200, 100));

      Widget build({required bool second}) => Column(
            children: <Widget>[
              Row(
                children:
                    second ? const <Widget>[] : <Widget>[_Counter(key: key)],
              ),
              Row(
                children:
                    second ? <Widget>[_Counter(key: key)] : const <Widget>[],
              ),
            ],
          );

      owner.updateRoot(build(second: false));
      final _CounterState state = key.currentState!;
      state.bump();
      state.bump();
      owner.buildScope();
      expect(state.value, 2);
      expect(rowAt(owner, 0).childCount, 1);
      final RenderBox render = rowAt(owner, 0).childAt(0);
      final int buildsBefore = state.builds;

      owner.updateRoot(build(second: true));

      // Same state object, same value, same render object - the subtree was
      // reparented, not recreated.
      expect(key.currentState, same(state));
      expect(state.value, 2);
      expect(_Counter.created, 1);
      expect(_Counter.disposed, 0);
      expect(rowAt(owner, 0).childCount, 0);
      expect(rowAt(owner, 1).childCount, 1);
      expect(rowAt(owner, 1).childAt(0), same(render));
      // Exactly one rebuild, because the widget instance changed - not the
      // full teardown a positional match would have caused.
      expect(state.builds, buildsBefore + 1);
    });

    test('a subtree moved to an earlier sibling keeps its state', () {
      // The other direction, which takes the other code path: the destination
      // is reconciled before the source, so the element is still live in the
      // tree and has to be taken away from a parent that has not yet noticed.
      final GlobalKey<_CounterState> key = GlobalKey<_CounterState>();
      final BuildOwner owner = ownerFor(const Size(200, 100));

      Widget build({required bool second}) => Column(
            children: <Widget>[
              Row(
                children:
                    second ? const <Widget>[] : <Widget>[_Counter(key: key)],
              ),
              Row(
                children:
                    second ? <Widget>[_Counter(key: key)] : const <Widget>[],
              ),
            ],
          );

      owner.updateRoot(build(second: true));
      final _CounterState state = key.currentState!;
      state.bump();
      owner.buildScope();
      final RenderBox render = rowAt(owner, 1).childAt(0);

      owner.updateRoot(build(second: false));

      expect(key.currentState, same(state));
      expect(state.value, 1);
      expect(_Counter.created, 1);
      expect(_Counter.disposed, 0);
      expect(rowAt(owner, 0).childCount, 1);
      expect(rowAt(owner, 0).childAt(0), same(render));
      expect(rowAt(owner, 1).childCount, 0);
    });

    test('a subtree that changes depth keeps its state', () {
      final GlobalKey<_CounterState> key = GlobalKey<_CounterState>();
      final BuildOwner owner = ownerFor(const Size(200, 100));

      Widget build({required bool nested}) => Column(
            children: <Widget>[
              Row(
                children:
                    nested ? <Widget>[_Counter(key: key)] : const <Widget>[],
              ),
              if (!nested) _Counter(key: key),
            ],
          );

      owner.updateRoot(build(nested: true));
      final _CounterState state = key.currentState!;
      state.bump();
      owner.buildScope();
      final RenderBox render = rowAt(owner, 0).childAt(0);

      owner.updateRoot(build(nested: false));

      final RenderFlex column = owner.renderRoot! as RenderFlex;
      expect(key.currentState, same(state));
      expect(state.value, 1);
      expect(_Counter.disposed, 0);
      expect(column.childCount, 2);
      // Promoted one level: it is now the column's own child.
      expect(column.childAt(1), same(render));
      expect(rowAt(owner, 0).childCount, 0);
    });

    test('a moved parent-data widget keeps its flex', () {
      // Reattaching a render object under a new flex resets its parent data to
      // the container's defaults, so the move has to write it back.
      final GlobalKey<State<StatefulWidget>> key =
          GlobalKey<State<StatefulWidget>>();
      final BuildOwner owner = ownerFor(const Size(200, 100));

      Widget build({required bool second}) => Column(
            children: <Widget>[
              Row(
                children: second
                    ? const <Widget>[]
                    : <Widget>[
                        Expanded(
                          key: key,
                          flex: 5,
                          child: const SizedBox(height: 10),
                        ),
                      ],
              ),
              Row(
                children: second
                    ? <Widget>[
                        Expanded(
                          key: key,
                          flex: 5,
                          child: const SizedBox(height: 10),
                        ),
                      ]
                    : const <Widget>[],
              ),
            ],
          );

      owner.updateRoot(build(second: false));
      owner.pipelineOwner.flushLayout();
      final RenderBox render = rowAt(owner, 0).childAt(0);
      expect(render.size.width, 200);

      owner.updateRoot(build(second: true));
      owner.pipelineOwner.flushLayout();

      final RenderFlex destination = rowAt(owner, 1);
      expect(destination.childCount, 1);
      expect(destination.childAt(0), same(render));
      expect(destination.childParentData(render).flex, 5);
      expect(destination.childParentData(render).fit, FlexFit.tight);
      expect(render.size.width, 200);
    });

    test('a move re-scopes the inherited widgets the subtree can see', () {
      final GlobalKey<_ReaderState> key = GlobalKey<_ReaderState>();
      final BuildOwner owner = ownerFor(const Size(200, 100));

      Widget build({required bool second}) => Column(
            children: <Widget>[
              _Ambient(
                value: 1,
                child: Row(
                  children:
                      second ? const <Widget>[] : <Widget>[_Reader(key: key)],
                ),
              ),
              _Ambient(
                value: 2,
                child: Row(
                  children:
                      second ? <Widget>[_Reader(key: key)] : const <Widget>[],
                ),
              ),
            ],
          );

      owner.updateRoot(build(second: false));
      final _ReaderState state = key.currentState!;
      expect(state.seen, <int>[1]);

      owner.updateRoot(build(second: true));

      // Same state object, but it is now reading the ambient it actually sits
      // under. A move that only relinked the render tree would have left it
      // holding 1 forever.
      expect(key.currentState, same(state));
      expect(state.seen, <int>[1, 2]);
    });

    test('a reorder inside one parent needs no move at all', () {
      // The two-ended scan matches these by key in the middle pass; the global
      // key registry is never consulted, and nothing is detached.
      final GlobalKey<_CounterState> first = GlobalKey<_CounterState>();
      final GlobalKey<_CounterState> second = GlobalKey<_CounterState>();
      final BuildOwner owner = ownerFor(const Size(200, 50));

      Widget build({required bool swapped}) => Row(
            children: swapped
                ? <Widget>[
                    _Counter(key: second, width: 20),
                    _Counter(key: first, width: 10),
                  ]
                : <Widget>[
                    _Counter(key: first, width: 10),
                    _Counter(key: second, width: 20),
                  ],
          );

      owner.updateRoot(build(swapped: false));
      owner.pipelineOwner.flushLayout();
      final _CounterState firstState = first.currentState!;
      final _CounterState secondState = second.currentState!;
      firstState.bump();
      owner.buildScope();

      owner.updateRoot(build(swapped: true));
      owner.pipelineOwner.flushLayout();

      final RenderFlex row = owner.renderRoot! as RenderFlex;
      expect(first.currentState, same(firstState));
      expect(second.currentState, same(secondState));
      expect(firstState.value, 1);
      expect(_Counter.created, 2);
      expect(_Counter.disposed, 0);
      // The wide one is now first, so the narrow one starts 20px in.
      expect(row.childAt(0).size.width, 20);
      expect(row.childAt(1).offsetFromParent.dx, 20);
    });
  });

  group('duplicates', () {
    test('two siblings claiming one key is a named error', () {
      final GlobalKey<_CounterState> key = GlobalKey<_CounterState>();
      final BuildOwner owner = ownerFor(const Size(200, 50));

      Object? thrown;
      try {
        owner.updateRoot(
          Row(
            children: <Widget>[
              _Counter(key: key),
              _Counter(key: key),
            ],
          ),
        );
      } catch (error) {
        thrown = error;
      }

      expect(thrown, isA<DuplicateGlobalKeyError>());
      final DuplicateGlobalKeyError error = thrown! as DuplicateGlobalKeyError;
      expect(error.key, same(key));
      expect(error.firstPath, contains('_Counter'));
      expect(error.secondPath, contains('_Counter'));
      expect(error.message, contains('two widgets'));
      expect(error.toString(), startsWith('DuplicateGlobalKeyError: '));
    });

    test('two different parents claiming one key is a named error', () {
      final GlobalKey<_CounterState> key = GlobalKey<_CounterState>();
      final BuildOwner owner = ownerFor(const Size(200, 100));

      expect(
        () => owner.updateRoot(
          Column(
            children: <Widget>[
              Row(children: <Widget>[_Counter(key: key)]),
              Row(children: <Widget>[_Counter(key: key)]),
            ],
          ),
        ),
        throwsA(isA<DuplicateGlobalKeyError>()),
      );
    });

    test('a second widget of a different type under one key still throws', () {
      final GlobalKey<_CounterState> key = GlobalKey<_CounterState>();
      final BuildOwner owner = ownerFor(const Size(200, 50));

      expect(
        () => owner.updateRoot(
          Row(
            children: <Widget>[
              _Counter(key: key),
              SizedBox(key: key, width: 5, height: 5),
            ],
          ),
        ),
        throwsA(isA<DuplicateGlobalKeyError>()),
      );
    });

    test('reusing a key after its first holder is gone is fine', () {
      final GlobalKey<_CounterState> key = GlobalKey<_CounterState>();
      final BuildOwner owner = ownerFor(const Size(200, 50));

      owner.updateRoot(Row(children: <Widget>[_Counter(key: key)]));
      final _CounterState first = key.currentState!;
      owner.updateRoot(const Row(children: <Widget>[SizedBox()]));
      expect(key.currentState, isNull);

      owner.updateRoot(Row(children: <Widget>[_Counter(key: key)]));

      expect(key.currentState, isNotNull);
      expect(key.currentState, isNot(same(first)));
      expect(_Counter.created, 2);
      expect(_Counter.disposed, 1);
    });
  });

  group('detached elements survive the scope that detached them', () {
    test('a removal that nobody claims still disposes within the scope', () {
      final BuildOwner owner = ownerFor(const Size(200, 50));
      owner.updateRoot(const Row(children: <Widget>[_Counter()]));
      final Element child =
          (owner.rootElement! as MultiChildRenderObjectElement).children.single;
      expect(child.lifecycle, ElementLifecycle.active);

      owner.updateRoot(const Row(children: <Widget>[]));

      // Parked for the scope, unmounted by the end of it: nothing observable
      // outside a build sees an inactive element.
      expect(child.lifecycle, ElementLifecycle.defunct);
      expect(_Counter.disposed, 1);
    });
  });
}
