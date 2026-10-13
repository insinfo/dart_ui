/// The key family with Flutter's names: UniqueKey, ObjectKey,
/// GlobalObjectKey, LabeledGlobalKey, PageStorageKey, KeyedSubtree and
/// PageStorage.
library;

import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

BuildOwner _owner() => BuildOwner(
      pipelineOwner: PipelineOwner(
        rootConstraints: BoxConstraints.tight(const Size(200, 200)),
      ),
    );

final class _Counter extends StatefulWidget {
  const _Counter({super.key, required this.label});

  final String label;

  @override
  State<_Counter> createState() => _CounterState();
}

final class _CounterState extends State<_Counter> {
  int count = 0;

  @override
  Widget build(BuildContext context) => Text('${widget.label}:$count');
}

/// Every [_CounterState] mounted under [owner], in tree order.
List<_CounterState> _counters(BuildOwner owner) {
  final List<_CounterState> found = <_CounterState>[];
  void walk(Element element) {
    if (element is StatefulElement && element.state is _CounterState) {
      found.add(element.state as _CounterState);
    }
    element.visitChildren(walk);
  }

  final Element? root = owner.rootElement;
  if (root != null) walk(root);
  return found;
}

void main() {
  group('local keys', () {
    test('UniqueKey equals only itself and is a LocalKey', () {
      final UniqueKey a = UniqueKey();
      final UniqueKey b = UniqueKey();
      expect(a, equals(a));
      expect(a, isNot(equals(b)));
      expect(a, isA<LocalKey>());
      expect(a.toString(), startsWith('[#'));
    });

    test('ObjectKey compares the wrapped object by identity', () {
      final List<int> list = <int>[1];
      expect(ObjectKey(list), equals(ObjectKey(list)));
      expect(ObjectKey(list).hashCode, ObjectKey(list).hashCode);
      expect(ObjectKey(List<int>.filled(1, 1)),
          isNot(equals(ObjectKey(List<int>.filled(1, 1)))));
      expect(const ValueKey<int>(1), isA<LocalKey>());
    });

    test('PageStorageKey is a ValueKey distinct from a plain ValueKey', () {
      expect(const PageStorageKey<String>('a'),
          equals(const PageStorageKey<String>('a')));
      expect(const PageStorageKey<String>('a'), isA<ValueKey<String>>());
      expect(const PageStorageKey<String>('a'),
          isNot(equals(const ValueKey<String>('a'))));
    });

    test('ObjectKey keeps state with its object across a reorder', () {
      final Object first = Object();
      final Object second = Object();
      final BuildOwner owner = _owner();
      addTearDown(owner.dispose);

      owner.updateRoot(Column(children: <Widget>[
        _Counter(key: ObjectKey(first), label: 'first'),
        _Counter(key: ObjectKey(second), label: 'second'),
      ]));
      _counters(owner).first.count = 7;

      owner.updateRoot(Column(children: <Widget>[
        _Counter(key: ObjectKey(second), label: 'second'),
        _Counter(key: ObjectKey(first), label: 'first'),
      ]));
      final List<_CounterState> states = _counters(owner);
      expect(states.last.widget.label, 'first');
      expect(states.last.count, 7);
    });

    test('a fresh UniqueKey forces a fresh state', () {
      final BuildOwner owner = _owner();
      addTearDown(owner.dispose);
      owner.updateRoot(_Counter(key: UniqueKey(), label: 'x'));
      _counters(owner).single.count = 3;
      owner.updateRoot(_Counter(key: UniqueKey(), label: 'x'));
      owner.buildScope();
      expect(_counters(owner).single.count, 0);
    });
  });

  group('global keys', () {
    test('GlobalObjectKey: two const keys on one object are one key', () {
      const Symbol identity = #form;
      const GlobalObjectKey<_CounterState> a =
          GlobalObjectKey<_CounterState>(identity);
      const GlobalObjectKey<_CounterState> b =
          GlobalObjectKey<_CounterState>(identity);
      expect(a, equals(b));

      final BuildOwner owner = _owner();
      addTearDown(owner.dispose);
      owner.updateRoot(const _Counter(key: a, label: 'g'));
      expect(b.currentState, isA<_CounterState>());
      expect(b.currentState!.widget.label, 'g');
      expect(a.currentContext, isNotNull);
    });

    test('LabeledGlobalKey is a GlobalKey with a label', () {
      final LabeledGlobalKey<_CounterState> key =
          LabeledGlobalKey<_CounterState>('counter');
      expect(key, isA<GlobalKey<_CounterState>>());
      expect(key.debugLabel, 'counter');
      expect(key, isNot(equals(LabeledGlobalKey<_CounterState>('counter'))));
    });
  });

  group('KeyedSubtree', () {
    test('wrap uses the child key or the index', () {
      const Text keyed = Text('a', key: ValueKey<String>('a'));
      expect(KeyedSubtree.wrap(keyed, 3).key, const ValueKey<String>('a'));
      expect(KeyedSubtree.wrap(const Text('b'), 3).key, const ValueKey<int>(3));
    });

    test('ensureUniqueKeysForList keys only lists that need it', () {
      final List<Widget> keyed = <Widget>[
        const Text('a', key: ValueKey<int>(1)),
      ];
      expect(identical(KeyedSubtree.ensureUniqueKeysForList(keyed), keyed),
          isTrue);
      final List<Widget> wrapped = KeyedSubtree.ensureUniqueKeysForList(
        <Widget>[const Text('a'), const Text('b')],
        baseIndex: 5,
      );
      expect(wrapped.map((Widget w) => w.key),
          <Key>[const ValueKey<int>(5), const ValueKey<int>(6)]);
    });

    test('a keyed subtree carries its state through a reorder', () {
      final BuildOwner owner = _owner();
      addTearDown(owner.dispose);
      owner.updateRoot(const Column(children: <Widget>[
        KeyedSubtree(key: ValueKey<int>(1), child: _Counter(label: 'one')),
        KeyedSubtree(key: ValueKey<int>(2), child: _Counter(label: 'two')),
      ]));
      _counters(owner).first.count = 9;
      owner.updateRoot(const Column(children: <Widget>[
        KeyedSubtree(key: ValueKey<int>(2), child: _Counter(label: 'two')),
        KeyedSubtree(key: ValueKey<int>(1), child: _Counter(label: 'one')),
      ]));
      expect(_counters(owner).last.count, 9);
    });
  });

  group('PageStorage', () {
    test('entries are filed under the PageStorageKey chain', () {
      final PageStorageBucket bucket = PageStorageBucket();
      final List<BuildContext> contexts = <BuildContext>[];
      Widget probe() => Builder(builder: (BuildContext context) {
            contexts.add(context);
            return const SizedBox(width: 1, height: 1);
          });

      final BuildOwner owner = _owner();
      addTearDown(owner.dispose);
      owner.updateRoot(PageStorage(
        bucket: bucket,
        child: Column(children: <Widget>[
          KeyedSubtree(key: const PageStorageKey<String>('a'), child: probe()),
          KeyedSubtree(key: const PageStorageKey<String>('b'), child: probe()),
        ]),
      ));
      expect(contexts, hasLength(2));
      expect(PageStorage.of(contexts.first), same(bucket));

      bucket.writeState(contexts[0], 120.0);
      bucket.writeState(contexts[1], 40.0);
      expect(bucket.readState(contexts[0]), 120.0);
      expect(bucket.readState(contexts[1]), 40.0);
      bucket.writeState(contexts[0], 'x', identifier: 'explicit');
      expect(bucket.readState(contexts[1], identifier: 'explicit'), 'x');
    });

    test('of throws a named error without a PageStorage', () {
      final BuildOwner owner = _owner();
      addTearDown(owner.dispose);
      BuildContext? seen;
      owner.updateRoot(Builder(builder: (BuildContext context) {
        seen = context;
        return const SizedBox(width: 1, height: 1);
      }));
      expect(PageStorage.maybeOf(seen!), isNull);
      expect(() => PageStorage.of(seen!), throwsStateError);
    });
  });
}
