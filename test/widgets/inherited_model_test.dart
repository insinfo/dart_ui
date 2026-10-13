/// InheritedNotifier and InheritedModel, with Flutter's semantics, and the
/// two BuildContext lookups they rest on.
library;

import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

BuildOwner _owner() => BuildOwner(
      pipelineOwner: PipelineOwner(
        rootConstraints: BoxConstraints.tight(const Size(200, 200)),
      ),
    );

final class _Counter extends ChangeNotifier {
  int value = 0;

  void increment() {
    value++;
    notifyListeners();
  }
}

final class _CounterScope extends InheritedNotifier<_Counter> {
  const _CounterScope({required super.notifier, required super.child});

  static int of(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<_CounterScope>()!
      .notifier!
      .value;
}

/// Records each build and what it read.
final class _Probe extends StatelessWidget {
  const _Probe(this.read, this.log);

  final Object? Function(BuildContext context) read;
  final List<Object?> log;

  @override
  Widget build(BuildContext context) {
    log.add(read(context));
    return const SizedBox(width: 1, height: 1);
  }
}

/// A model with two aspects, 'a' and 'b'.
final class _Pair extends InheritedModel<String> {
  const _Pair({required this.a, required this.b, required super.child});

  final int a;
  final int b;

  @override
  bool updateShouldNotify(_Pair oldWidget) =>
      a != oldWidget.a || b != oldWidget.b;

  @override
  bool updateShouldNotifyDependent(_Pair oldWidget, Set<String> aspects) =>
      (aspects.contains('a') && a != oldWidget.a) ||
      (aspects.contains('b') && b != oldWidget.b);
}

/// Supports only aspect 'outer'-less lookups: claims 'x' only.
final class _Partial extends InheritedModel<String> {
  const _Partial(
      {required this.tag, required this.supports, required super.child});

  final String tag;
  final Set<String> supports;

  @override
  bool isSupportedAspect(Object aspect) => supports.contains(aspect);

  @override
  bool updateShouldNotify(_Partial oldWidget) => tag != oldWidget.tag;

  @override
  bool updateShouldNotifyDependent(_Partial oldWidget, Set<String> aspects) =>
      true;
}

void main() {
  group('InheritedNotifier', () {
    test('a notification rebuilds the dependents once per build scope', () {
      final _Counter counter = _Counter();
      final List<Object?> log = <Object?>[];
      final BuildOwner owner = _owner();
      addTearDown(owner.dispose);

      owner.updateRoot(_CounterScope(
        notifier: counter,
        child: _Probe(_CounterScope.of, log),
      ));
      expect(log, <Object?>[0]);

      counter
        ..increment()
        ..increment();
      expect(owner.hasScheduledBuilds, isTrue);
      owner.buildScope();
      expect(log, <Object?>[0, 2]);

      owner.buildScope();
      expect(log, <Object?>[0, 2], reason: 'nothing changed since');
    });

    test('swapping the notifier moves the subscription', () {
      final _Counter first = _Counter();
      final _Counter second = _Counter()..value = 10;
      final List<Object?> log = <Object?>[];
      final BuildOwner owner = _owner();
      addTearDown(owner.dispose);
      final _Probe probe = _Probe(_CounterScope.of, log);

      owner.updateRoot(_CounterScope(notifier: first, child: probe));
      owner.updateRoot(_CounterScope(notifier: second, child: probe));
      expect(log.last, 10);

      first.increment();
      expect(owner.hasScheduledBuilds, isFalse,
          reason: 'the old notifier is no longer listened to');
      second.increment();
      owner.buildScope();
      expect(log.last, 11);
    });

    test('unmounting stops listening', () {
      final _Counter counter = _Counter();
      final BuildOwner owner = _owner();
      addTearDown(owner.dispose);
      owner.updateRoot(_CounterScope(
        notifier: counter,
        child: const SizedBox(width: 1, height: 1),
      ));
      owner.updateRoot(const SizedBox(width: 1, height: 1));
      owner.buildScope();
      counter.increment();
      expect(owner.hasScheduledBuilds, isFalse);
    });
  });

  group('InheritedModel', () {
    test('a dependent rebuilds only for the aspects it asked for', () {
      final List<Object?> aLog = <Object?>[];
      final List<Object?> bLog = <Object?>[];
      final List<Object?> allLog = <Object?>[];
      final Widget children = Column(children: <Widget>[
        _Probe(
          (BuildContext c) =>
              InheritedModel.inheritFrom<_Pair>(c, aspect: 'a')!.a,
          aLog,
        ),
        _Probe(
          (BuildContext c) =>
              InheritedModel.inheritFrom<_Pair>(c, aspect: 'b')!.b,
          bLog,
        ),
        _Probe(
          (BuildContext c) => InheritedModel.inheritFrom<_Pair>(c)!.a,
          allLog,
        ),
      ]);
      final BuildOwner owner = _owner();
      addTearDown(owner.dispose);

      owner.updateRoot(_Pair(a: 1, b: 1, child: children));
      expect(<List<Object?>>[
        aLog,
        bLog,
        allLog
      ], <List<Object?>>[
        <Object?>[1],
        <Object?>[1],
        <Object?>[1],
      ]);

      owner.updateRoot(_Pair(a: 2, b: 1, child: children));
      expect(aLog, <Object?>[1, 2]);
      expect(bLog, <Object?>[1], reason: 'b did not change');
      expect(allLog, <Object?>[1, 2], reason: 'no aspect means every aspect');

      owner.updateRoot(_Pair(a: 2, b: 5, child: children));
      expect(aLog, <Object?>[1, 2]);
      expect(bLog, <Object?>[1, 5]);
      expect(allLog, hasLength(3));
    });

    test('inheritFrom skips a nearer model that does not support the aspect',
        () {
      Object? found;
      final BuildOwner owner = _owner();
      addTearDown(owner.dispose);
      owner.updateRoot(_Partial(
        tag: 'outer',
        supports: const <String>{'x'},
        child: _Partial(
          tag: 'inner',
          supports: const <String>{'y'},
          child: Builder(builder: (BuildContext context) {
            found =
                InheritedModel.inheritFrom<_Partial>(context, aspect: 'x')?.tag;
            return const SizedBox(width: 1, height: 1);
          }),
        ),
      ));
      expect(found, 'outer');
    });

    test('inheritFrom answers null when no model is above', () {
      Object? found = 'unset';
      final BuildOwner owner = _owner();
      addTearDown(owner.dispose);
      owner.updateRoot(Builder(builder: (BuildContext context) {
        found = InheritedModel.inheritFrom<_Pair>(context, aspect: 'a');
        return const SizedBox(width: 1, height: 1);
      }));
      expect(found, isNull);
    });
  });

  test('getElementForInheritedWidgetOfExactType creates no dependency', () {
    final List<Object?> log = <Object?>[];
    final BuildOwner owner = _owner();
    addTearDown(owner.dispose);
    final Widget probe = _Probe(
      (BuildContext c) =>
          (c.getElementForInheritedWidgetOfExactType<_Pair>()!.widget as _Pair)
              .a,
      log,
    );
    owner.updateRoot(_Pair(a: 1, b: 1, child: probe));
    owner.updateRoot(_Pair(a: 2, b: 1, child: probe));
    expect(log, <Object?>[1], reason: 'read without subscribing');
  });
}
