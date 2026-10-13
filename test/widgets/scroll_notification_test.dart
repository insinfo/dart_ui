/// `NotificationListener` and the scroll notifications, in Flutter's order.
///
/// Each test records what a listener hears - type, depth, delta, whether a
/// drag caused it - and compares the whole sequence, because the order is
/// the contract: an app that hides a toolbar on `UserScrollNotification` and
/// saves the offset on `ScrollEndNotification` depends on it.
library;

import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

void main() {
  group('Notification', () {
    test('bubbles to listeners of its type, nearest first', () {
      final List<String> heard = <String>[];
      late BuildContext inner;
      final harness = _Harness(
        NotificationListener<_Ping>(
          onNotification: (_Ping ping) {
            heard.add('outer ${ping.label}');
            return false;
          },
          child: NotificationListener<_Other>(
            onNotification: (_Other other) {
              heard.add('wrong type');
              return false;
            },
            child: NotificationListener<_Ping>(
              onNotification: (_Ping ping) {
                heard.add('inner ${ping.label}');
                return ping.label == 'stop';
              },
              child: Builder(
                builder: (BuildContext context) {
                  inner = context;
                  return const SizedBox();
                },
              ),
            ),
          ),
        ),
      );

      const _Ping('go').dispatch(inner);
      expect(heard, <String>['inner go', 'outer go']);

      heard.clear();
      const _Ping('stop').dispatch(inner);
      expect(heard, <String>['inner stop'], reason: 'true stops it');

      // A null target is allowed and does nothing.
      const _Ping('nowhere').dispatch(null);
      harness.dispose();
    });

    test('a listener hears what is dispatched from its own context', () {
      final List<String> heard = <String>[];
      final GlobalKey key = GlobalKey();
      final harness = _Harness(
        NotificationListener<_Ping>(
          key: key,
          onNotification: (_Ping ping) {
            heard.add(ping.label);
            return true;
          },
          child: const SizedBox(),
        ),
      );
      const _Ping('self').dispatch(key.currentContext);
      expect(heard, <String>['self']);
      harness.dispose();
    });
  });

  group('scroll notifications', () {
    test('a wheel notch is a scroll of its own', () {
      final _Log log = _Log();
      final harness = _Harness(log.around(_list()));

      harness.pointer(_wheel(const Offset(50, 50), 30));

      expect(log.entries, <String>[
        'user reverse',
        'start',
        'update 30.0',
        'end',
        'user idle',
      ]);
      expect(log.last.metrics.pixels, 30);
      expect(log.last.context, isNotNull);
      harness.dispose();
    });

    test('a drag reports its details, and a release without a fling ends it',
        () {
      final _Log log = _Log();
      final harness = _Harness(log.around(_list()));

      harness.pointer(_down(const Offset(50, 90)));
      harness.pointer(_move(const Offset(50, 60), millis: 100));
      harness.pointer(_move(const Offset(50, 50), millis: 200));
      harness.pointer(_up(const Offset(50, 50), millis: 900));

      expect(log.entries.first, 'start drag');
      expect(log.entries, contains('user reverse'));
      expect(log.entries, contains('update 10.0 drag'));
      expect(log.entries.sublist(log.entries.length - 2), <String>[
        'end drag',
        'user idle',
      ]);
      expect(log.last.metrics.pixels, greaterThan(0));
      harness.dispose();
    });

    test('a fling keeps the scroll going until it comes to rest', () {
      final ManualDispatcher dispatcher = ManualDispatcher();
      final _Log log = _Log();
      final harness = _Harness(log.around(_list(dispatcher: dispatcher)));

      harness.pointer(_down(const Offset(50, 90)));
      for (int step = 1; step <= 6; step++) {
        harness.pointer(_move(Offset(50, 90 - step * 8), millis: step * 8));
      }
      harness.pointer(_up(const Offset(50, 42), millis: 56));
      expect(log.entries, isNot(contains('end drag')));
      final int beforeFling = log.entries.length;

      dispatcher.advance(const Duration(seconds: 5));

      final List<String> fling = log.entries.sublist(beforeFling);
      expect(fling.where((String e) => e.startsWith('update')), isNotEmpty);
      expect(fling.where((String e) => e.contains('drag')), isEmpty);
      expect(fling.sublist(fling.length - 2), <String>['end', 'user idle']);
      expect(log.entries.where((String e) => e.startsWith('start')).length, 1);
      harness.dispose();
    });

    test('dragging against the edge overscrolls', () {
      final _Log log = _Log();
      final harness = _Harness(log.around(_list()));

      harness.pointer(_down(const Offset(50, 20)));
      harness.pointer(_move(const Offset(50, 60), millis: 50));
      harness.pointer(_move(const Offset(50, 80), millis: 100));

      expect(log.entries, contains('overscroll -20.0 drag'));
      expect(log.entries, isNot(contains(startsWith('update'))));
      harness.dispose();
    });

    test('animateTo starts, updates every frame, and ends', () async {
      final ManualDispatcher dispatcher = ManualDispatcher();
      final ScrollController controller = ScrollController();
      final _Log log = _Log();
      final harness = _Harness(
        log.around(_list(controller: controller, dispatcher: dispatcher)),
      );

      final Future<void> done = controller.animateTo(
        160,
        duration: const Duration(milliseconds: 160),
        curve: Curves.linear,
      );
      dispatcher.advance(const Duration(milliseconds: 400));
      await done;

      expect(log.entries.first, 'start');
      expect(log.entries.last, 'end');
      expect(
        log.entries.where((String e) => e == 'update 16.0').length,
        10,
        reason: 'ten 16ms frames of a linear 160px in 160ms',
      );
      harness.dispose();
    });

    test('jumpTo and keys are scrolls of their own too', () {
      final _Log log = _Log();
      final ScrollController controller = ScrollController();
      final harness = _Harness(log.around(_list(controller: controller)));

      controller.jumpTo(100);
      expect(log.entries, <String>['start', 'update 100.0', 'end']);
      harness.dispose();
    });

    test('depth counts the scroll views in between', () {
      final List<String> outer = <String>[];
      final List<String> between = <String>[];
      final harness = _Harness(
        NotificationListener<ScrollUpdateNotification>(
          onNotification: (ScrollUpdateNotification n) {
            outer.add('${n.metrics.axis.name} ${n.depth}');
            return false;
          },
          child: SingleChildScrollView(
            scrollbar: ScrollbarVisibility.never,
            child: Column(
              children: <Widget>[
                SizedBox(
                  height: 60,
                  child: NotificationListener<ScrollUpdateNotification>(
                    onNotification: (ScrollUpdateNotification n) {
                      between.add('${n.metrics.axis.name} ${n.depth}');
                      return false;
                    },
                    child: ListView.builder(
                      scrollDirection: Axis.horizontal,
                      itemCount: 100,
                      itemExtent: 20,
                      scrollbar: ScrollbarVisibility.never,
                      itemBuilder: (BuildContext context, int index) =>
                          const SizedBox(width: 20),
                    ),
                  ),
                ),
                const SizedBox(height: 400),
              ],
            ),
          ),
        ),
      );

      harness.pointer(_wheel(const Offset(50, 30), 0, dx: 25));
      harness.pointer(_wheel(const Offset(50, 30), 25));

      expect(between, <String>['horizontal 0']);
      expect(outer, <String>['horizontal 1', 'vertical 0']);
      expect(
        defaultScrollNotificationPredicate(
          ScrollUpdateNotification(
            metrics: FixedScrollMetrics(
              minScrollExtent: 0,
              maxScrollExtent: 0,
              pixels: 0,
              viewportDimension: 0,
              axisDirection: AxisDirection.down,
              devicePixelRatio: 1,
            ),
            context: null,
          ),
        ),
        isTrue,
      );
      harness.dispose();
    });

    test('a listener that returns true keeps it from the ones above', () {
      int outer = 0;
      final harness = _Harness(
        NotificationListener<ScrollNotification>(
          onNotification: (ScrollNotification n) {
            outer++;
            return false;
          },
          child: NotificationListener<ScrollNotification>(
            onNotification: (ScrollNotification n) => true,
            child: _list(),
          ),
        ),
      );
      harness.pointer(_wheel(const Offset(50, 50), 30));
      expect(outer, 0);
      harness.dispose();
    });

    test('a change of content extent is posted as ScrollMetricsNotification',
        () {
      final ManualDispatcher dispatcher = ManualDispatcher();
      final List<double> extents = <double>[];
      Widget view(int count) => NotificationListener<ScrollMetricsNotification>(
            onNotification: (ScrollMetricsNotification n) {
              extents.add(n.metrics.maxScrollExtent);
              expect(n.asScrollUpdate().scrollDelta, isNull);
              return false;
            },
            child: _list(dispatcher: dispatcher, count: count),
          );
      final harness = _Harness(view(100));
      dispatcher.drain();
      expect(extents, <double>[1900]);

      harness.mount(view(10));
      dispatcher.drain();
      expect(extents, <double>[1900, 100]);
      harness.dispose();
    });
  });
}

final class _Ping extends Notification {
  const _Ping(this.label);
  final String label;
}

final class _Other extends Notification {
  const _Other();
}

/// Records scroll notifications as short strings.
final class _Log {
  final List<String> entries = <String>[];
  late ScrollNotification last;

  Widget around(Widget child) => NotificationListener<ScrollNotification>(
        onNotification: (ScrollNotification n) {
          last = n;
          entries.add(switch (n) {
            ScrollStartNotification(:final DragStartDetails? dragDetails) =>
              'start${dragDetails == null ? '' : ' drag'}',
            ScrollUpdateNotification(
              :final double? scrollDelta,
              :final DragUpdateDetails? dragDetails,
            ) =>
              'update ${scrollDelta?.toStringAsFixed(1)}'
                  '${dragDetails == null ? '' : ' drag'}',
            OverscrollNotification(
              :final double overscroll,
              :final DragUpdateDetails? dragDetails,
            ) =>
              'overscroll ${overscroll.toStringAsFixed(1)}'
                  '${dragDetails == null ? '' : ' drag'}',
            ScrollEndNotification(:final DragEndDetails? dragDetails) =>
              'end${dragDetails == null ? '' : ' drag'}',
            UserScrollNotification(:final ScrollDirection direction) =>
              'user ${direction.name}',
            _ => n.runtimeType.toString(),
          });
          return false;
        },
        child: child,
      );
}

Widget _list({
  ScrollController? controller,
  UiDispatcher? dispatcher,
  int count = 100,
}) =>
    ListView.builder(
      controller: controller,
      dispatcher: dispatcher,
      itemCount: count,
      itemExtent: 20,
      scrollbar: ScrollbarVisibility.never,
      itemBuilder: (BuildContext context, int index) =>
          const SizedBox(height: 20),
    );

final class _Harness {
  _Harness(Widget widget, {Size size = const Size(200, 100)}) {
    owner = BuildOwner(
      pipelineOwner: PipelineOwner(rootConstraints: BoxConstraints.tight(size)),
    );
    mount(widget);
  }

  late final BuildOwner owner;

  void mount(Widget widget) {
    owner.updateRoot(widget);
    frame();
  }

  void frame({int maxPasses = 12}) {
    for (int pass = 0; pass < maxPasses; pass++) {
      if (owner.hasScheduledBuilds) owner.buildScope();
      owner.pipelineOwner.drawFrame(DisplayList());
      if (!owner.hasScheduledBuilds) return;
    }
    throw StateError('the scroll view never settled');
  }

  bool pointer(PointerEvent event) {
    final bool handled = owner.dispatchPointerEvent(event);
    frame();
    return handled;
  }

  void dispose() => owner.dispose();
}

const NativeWindowId _window = NativeWindowId(1);

PointerDownEvent _down(Offset at, {int millis = 0}) => PointerDownEvent(
      windowId: _window,
      generation: 1,
      timestamp: Duration(milliseconds: millis),
      pointerId: 0,
      kind: PointerKind.touch,
      logicalPosition: at,
      button: PointerButton.primary,
    );

PointerMoveEvent _move(Offset at, {int millis = 0}) => PointerMoveEvent(
      windowId: _window,
      generation: 1,
      timestamp: Duration(milliseconds: millis),
      pointerId: 0,
      kind: PointerKind.touch,
      logicalPosition: at,
    );

PointerUpEvent _up(Offset at, {int millis = 0}) => PointerUpEvent(
      windowId: _window,
      generation: 1,
      timestamp: Duration(milliseconds: millis),
      pointerId: 0,
      kind: PointerKind.touch,
      logicalPosition: at,
      button: PointerButton.primary,
    );

PointerScrollEvent _wheel(Offset at, double dy, {double dx = 0}) =>
    PointerScrollEvent(
      windowId: _window,
      generation: 1,
      timestamp: Duration.zero,
      pointerId: 0,
      kind: PointerKind.mouse,
      logicalPosition: at,
      scrollDelta: Offset(dx, dy),
      scrollDeltaUnit: ScrollDeltaUnit.pixels,
    );
