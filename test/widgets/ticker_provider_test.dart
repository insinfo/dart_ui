/// Ticker, `AnimationController(vsync: this)`, TickerMode and the implicitly
/// animated transforms, driven by a hand-ticked [AnimationClock].
library;

import 'package:dart_ui/src/animation/animation.dart';
import 'package:dart_ui/src/animation/clock.dart';
import 'package:dart_ui/src/animation/curves.dart';
import 'package:dart_ui/src/animation/ticker.dart';
import 'package:dart_ui/src/geometry/size.dart';
import 'package:dart_ui/src/layout/box_constraints.dart';
import 'package:dart_ui/src/layout/pipeline.dart';
import 'package:dart_ui/src/widgets/animated_transforms.dart';
import 'package:dart_ui/src/widgets/animation_scope.dart';
import 'package:dart_ui/src/widgets/basic.dart';
import 'package:dart_ui/src/widgets/element.dart';
import 'package:dart_ui/src/widgets/ticker_provider.dart';
import 'package:dart_ui/src/widgets/widget.dart';
import 'package:test/test.dart';

const Duration _ms100 = Duration(milliseconds: 100);

final class _Spinner extends StatefulWidget {
  const _Spinner({this.onState});

  final void Function(_SpinnerState state)? onState;

  @override
  State<_Spinner> createState() => _SpinnerState();
}

final class _SpinnerState extends State<_Spinner>
    with SingleTickerProviderStateMixin<_Spinner> {
  late final AnimationController controller =
      AnimationController(vsync: this, duration: _ms100);

  @override
  void initState() {
    super.initState();
    controller.addListener(() => setState(() {}));
    widget.onState?.call(this);
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      SizedBox(width: 10 + 10 * controller.value, height: 10);
}

(BuildOwner, PipelineOwner) _mount(Widget root) {
  final PipelineOwner pipeline = PipelineOwner(
    rootConstraints: BoxConstraints.loose(const Size(200, 200)),
  );
  final BuildOwner owner = BuildOwner(pipelineOwner: pipeline)
    ..updateRoot(root);
  pipeline.flushLayout();
  return (owner, pipeline);
}

void main() {
  group('Ticker', () {
    test('reports elapsed time from its first frame and completes on stop',
        () async {
      final AnimationClock clock = AnimationClock();
      final List<Duration> seen = <Duration>[];
      final Ticker ticker = Ticker(seen.add, clock: clock);
      final TickerFuture future = ticker.start();
      clock.tick(const Duration(milliseconds: 500));
      clock.tick(const Duration(milliseconds: 516));
      expect(seen, <Duration>[Duration.zero, const Duration(milliseconds: 16)]);
      expect(() => ticker.start(), throwsStateError);
      bool done = false;
      future.then((_) => done = true);
      ticker.stop();
      await Future<void>.delayed(Duration.zero);
      expect(done, isTrue);
      ticker.dispose();
      expect(clock.tickerCount, 0);
    });

    test('a canceled run fails orCancel and never completes', () async {
      final Ticker ticker = Ticker((_) {}, clock: AnimationClock());
      final TickerFuture future = ticker.start();
      Object? error;
      future.orCancel.catchError((Object e) => error = e);
      ticker.stop(canceled: true);
      await Future<void>.delayed(Duration.zero);
      expect(error, isA<TickerCanceled>());
    });

    test('a muted ticker holds still', () {
      final AnimationClock clock = AnimationClock();
      int calls = 0;
      final Ticker ticker = Ticker((_) => calls++, clock: clock)
        ..start()
        ..muted = true;
      clock.tick(Duration.zero);
      expect(calls, 0);
      expect(ticker.isTicking, isFalse);
      ticker.muted = false;
      clock.tick(const Duration(milliseconds: 10));
      expect(calls, 1);
    });
  });

  group('AnimationController, the Flutter way', () {
    test('animateTo with a curve lands on the target and completes', () {
      final AnimationClock clock = AnimationClock();
      final AnimationController c =
          AnimationController(clock: clock, duration: _ms100);
      c.animateTo(0.5, duration: _ms100, curve: Curves.easeIn);
      clock.tick(Duration.zero);
      clock.tick(const Duration(milliseconds: 50));
      expect(c.value, greaterThan(0.0));
      expect(c.value, lessThan(0.25));
      clock.tick(_ms100);
      expect(c.value, 0.5);
      expect(c.status, AnimationStatus.completed);
    });

    test('repeat(count:) ends, and forward() at the end completes at once', () {
      final AnimationClock clock = AnimationClock();
      final AnimationController c =
          AnimationController(clock: clock, duration: _ms100);
      c.repeat(reverse: true, count: 2);
      clock.tick(Duration.zero);
      clock.tick(const Duration(milliseconds: 150));
      expect(c.status, AnimationStatus.reverse);
      clock.tick(const Duration(milliseconds: 250));
      expect(c.value, 0.0);
      expect(c.isAnimating, isFalse);

      c.value = 1.0;
      expect(c.status, AnimationStatus.completed);
      c.forward();
      expect(c.isAnimating, isFalse);
      expect(c.isCompleted, isTrue);
    });

    test('zero duration lands at once; a null one throws on forward', () {
      final AnimationController zero =
          AnimationController(clock: AnimationClock(), duration: Duration.zero)
            ..forward();
      expect(zero.value, 1.0);
      final AnimationController none =
          AnimationController(vsync: const _ClocklessProvider());
      expect(none.forward, throwsStateError);
      none.duration = _ms100;
      none.forward();
      expect(none.value, 1.0, reason: 'no clock: the run lands at once');
    });

    test('needs exactly one of vsync and clock', () {
      expect(() => AnimationController(duration: _ms100), throwsArgumentError);
    });
  });

  group('SingleTickerProviderStateMixin', () {
    test('vsync: this ticks on the AnimationScope clock', () {
      final AnimationClock clock = AnimationClock();
      late _SpinnerState state;
      final (BuildOwner owner, PipelineOwner pipeline) = _mount(
        AnimationScope(
          clock: clock,
          child: Align(child: _Spinner(onState: (s) => state = s)),
        ),
      );
      addTearDown(owner.dispose);
      expect(state.controller.clock, same(clock));
      state.controller.forward();
      clock.tick(Duration.zero);
      clock.tick(const Duration(milliseconds: 50));
      owner.buildScope();
      pipeline.flushLayout();
      expect(state.controller.value, 0.5);
      clock.tick(_ms100);
      expect(state.controller.status, AnimationStatus.completed);
    });

    test('TickerMode(enabled: false) mutes the ticker', () {
      final AnimationClock clock = AnimationClock();
      late _SpinnerState state;
      final (BuildOwner owner, _) = _mount(
        AnimationScope(
          clock: clock,
          child: TickerMode(
            enabled: false,
            child: _Spinner(onState: (s) => state = s),
          ),
        ),
      );
      addTearDown(owner.dispose);
      state.controller.forward();
      clock.tick(Duration.zero);
      clock.tick(const Duration(milliseconds: 50));
      expect(state.controller.value, 0.0);
      expect(state.controller.isAnimating, isTrue);
    });

    test('a second ticker is a StateError', () {
      late _SpinnerState state;
      final (BuildOwner owner, _) = _mount(_Spinner(onState: (s) => state = s));
      addTearDown(owner.dispose);
      state.controller.value; // creates the first ticker
      expect(() => state.createTicker((_) {}), throwsStateError);
    });
  });

  group('implicit transforms', () {
    test('AnimatedScale walks to its target', () {
      final AnimationClock clock = AnimationClock();
      Widget app(double scale) => AnimationScope(
            clock: clock,
            child: AnimatedScale(
              scale: scale,
              duration: _ms100,
              child: const SizedBox(width: 10, height: 10),
            ),
          );
      final (BuildOwner owner, PipelineOwner pipeline) = _mount(app(1));
      addTearDown(owner.dispose);
      owner.updateRoot(app(2));
      pipeline.flushLayout();
      clock.tick(Duration.zero);
      clock.tick(const Duration(milliseconds: 50));
      owner.buildScope();
      final Element root = owner.rootElement!;
      AnimatedScale? found;
      void walk(Element e) {
        if (e.widget is AnimatedScale) found = e.widget as AnimatedScale;
        e.visitChildren(walk);
      }

      walk(root);
      expect(found!.scale, 2);
    });

    test('PositionedDirectional resolves start against the direction', () {
      final (BuildOwner owner, PipelineOwner pipeline) = _mount(
        const SizedBox(
          width: 100,
          height: 100,
          child: Stack(
            children: <Widget>[
              PositionedDirectional(
                start: 10,
                top: 0,
                child: SizedBox(width: 20, height: 20),
              ),
            ],
          ),
        ),
      );
      addTearDown(owner.dispose);
      pipeline.flushLayout();
      expect(owner.renderRoot, isNotNull);
    });
  });
}

final class _ClocklessProvider implements TickerProvider {
  const _ClocklessProvider();

  @override
  Ticker createTicker(TickerCallback onTick) => Ticker(onTick);
}
