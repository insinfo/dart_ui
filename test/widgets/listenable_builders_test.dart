/// ChangeNotifier, the builders that rebuild on a Listenable, and the
/// transitions driven by an Animation.
library;

import 'dart:async';

import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

final class _Counter extends ChangeNotifier {
  int value = 0;

  void increment() {
    value++;
    notifyListeners();
  }
}

void main() {
  late BuildOwner owner;

  void mount(Widget root) {
    owner = BuildOwner(
      pipelineOwner: PipelineOwner(
        rootConstraints: BoxConstraints.tight(const Size(200, 100)),
      ),
    )..updateRoot(
        Directionality(textDirection: TextDirection.leftToRight, child: root));
  }

  void frame() {
    for (var i = 0; i < 8; i++) {
      owner.buildScope();
      owner.pipelineOwner.drawFrame(DisplayList());
      if (!owner.hasScheduledBuilds) return;
    }
  }

  List<String> texts() {
    final List<String> out = <String>[];
    void walk(RenderBox node) {
      if (node is RenderText) out.add(node.text);
      node.visitChildren(walk);
    }

    walk(owner.renderRoot!);
    return out;
  }

  tearDown(() => owner.dispose());

  group('ChangeNotifier', () {
    test('notifies in order; a listener removing itself skips nobody', () {
      final _Counter counter = _Counter();
      final List<String> calls = <String>[];
      late void Function() once;
      once = () {
        calls.add('once');
        counter.removeListener(once);
      };
      counter
        ..addListener(once)
        ..addListener(() => calls.add('always'))
        ..increment()
        ..increment();
      expect(calls, <String>['once', 'always', 'always']);
      counter.dispose();
      expect(() => counter.addListener(() {}), throwsStateError);
      owner = BuildOwner(pipelineOwner: PipelineOwner());
    });

    test('a throwing listener does not starve the others', () {
      final _Counter counter = _Counter();
      var reached = false;
      counter
        ..addListener(() => throw StateError('broken'))
        ..addListener(() => reached = true);
      expect(counter.increment, throwsStateError);
      expect(reached, isTrue);
      owner = BuildOwner(pipelineOwner: PipelineOwner());
    });

    test('Listenable.merge notifies for any of them', () {
      final _Counter a = _Counter();
      final _Counter b = _Counter();
      var calls = 0;
      final Listenable both = Listenable.merge(<Listenable?>[a, null, b]);
      void listener() => calls++;
      both.addListener(listener);
      a.increment();
      b.increment();
      both.removeListener(listener);
      a.increment();
      expect(calls, 2);
      owner = BuildOwner(pipelineOwner: PipelineOwner());
    });
  });

  test('ListenableBuilder rebuilds on a change, its child once', () {
    final _Counter counter = _Counter();
    var childBuilds = 0;
    mount(ListenableBuilder(
      listenable: counter,
      builder: (BuildContext context, Widget? child) => Column(
        children: <Widget>[Text('count ${counter.value}'), child!],
      ),
      child: Builder(builder: (BuildContext context) {
        childBuilds++;
        return const Text('static');
      }),
    ));
    frame();
    expect(texts(), contains('count 0'));
    counter.increment();
    frame();
    expect(texts(), contains('count 1'));
    expect(childBuilds, 1);
  });

  test('FadeTransition follows its animation', () {
    final AnimationController controller =
        AnimationController(clock: AnimationClock());
    mount(FadeTransition(opacity: controller, child: const Text('x')));
    frame();
    RenderOpacity opacity() {
      RenderOpacity? found;
      void walk(RenderBox node) {
        if (node is RenderOpacity) found = node;
        node.visitChildren(walk);
      }

      walk(owner.renderRoot!);
      return found!;
    }

    expect(opacity().opacity, 0);
    controller.value = 0.25;
    frame();
    expect(opacity().opacity, 0.25);
  });

  test('FutureBuilder: waiting, then the value; a newer future wins', () async {
    final Completer<String> first = Completer<String>();
    final Completer<String> second = Completer<String>();
    Widget build(Future<String> future) => FutureBuilder<String>(
          future: future,
          builder: (BuildContext context, AsyncSnapshot<String> s) =>
              Text(s.connectionState == ConnectionState.waiting
                  ? 'loading'
                  : s.hasError
                      ? 'error ${s.error}'
                      : s.data!),
        );
    mount(build(first.future));
    frame();
    expect(texts(), <String>['loading']);
    owner.updateRoot(Directionality(
        textDirection: TextDirection.leftToRight, child: build(second.future)));
    frame();
    first.complete('stale');
    second.complete('fresh');
    await Future<void>.delayed(Duration.zero);
    frame();
    expect(texts(), <String>['fresh'],
        reason: 'the replaced future is ignored');
  });

  test('StreamBuilder: each value, an error, then done', () async {
    final StreamController<int> stream = StreamController<int>();
    final List<ConnectionState> states = <ConnectionState>[];
    mount(StreamBuilder<int>(
      stream: stream.stream,
      initialData: 0,
      builder: (BuildContext context, AsyncSnapshot<int> s) {
        states.add(s.connectionState);
        return Text(s.hasError ? 'error' : '${s.data}');
      },
    ));
    frame();
    expect(texts(), <String>['0'], reason: 'initialData while waiting');
    stream.add(7);
    await Future<void>.delayed(Duration.zero);
    frame();
    expect(texts(), <String>['7']);
    stream.addError('bad');
    await Future<void>.delayed(Duration.zero);
    frame();
    expect(texts(), <String>['error']);
    await stream.close();
    await Future<void>.delayed(Duration.zero);
    frame();
    expect(states.last, ConnectionState.done);
  });
}
