/// TweenAnimationBuilder, AnimatedContainer and AnimatedSwitcher, as values
/// over a manual clock.
library;

import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

/// A tree under a manual clock, rebuilt from [content] on [settle].
final class _Harness {
  _Harness(this.content, {this.withClock = true}) {
    owner = BuildOwner(
      pipelineOwner: PipelineOwner(
          rootConstraints: BoxConstraints.tight(const Size(300, 300))),
    );
    settle();
  }

  Widget Function() content;
  final bool withClock;
  final AnimationClock clock = AnimationClock();
  final ManualDispatcher dispatcher = ManualDispatcher();
  late final BuildOwner owner;

  Widget _root() {
    final Widget themed = Theme(
      data: ThemeData.neutralLight,
      child: Align(alignment: Alignment.topLeft, child: content()),
    );
    return withClock ? AnimationScope(clock: clock, child: themed) : themed;
  }

  void settle() {
    owner.updateRoot(_root());
    _pump();
  }

  void advance(Duration delta) {
    dispatcher.advance(delta);
    clock.tick(dispatcher.elapsed);
    _pump();
  }

  void tickNow() {
    clock.tick(dispatcher.elapsed);
    _pump();
  }

  void _pump() {
    for (int pass = 0; pass < 8; pass++) {
      owner.buildScope();
      owner.pipelineOwner.drawFrame(DisplayList());
      if (!owner.hasScheduledBuilds) return;
    }
    throw StateError('did not settle');
  }

  List<T> findAll<T extends RenderBox>() {
    final List<T> found = <T>[];
    void walk(RenderBox node) {
      if (node is T) found.add(node);
      node.visitChildren(walk);
    }

    walk(owner.renderRoot!);
    return found;
  }

  void dispose() => owner.dispose();
}

const Duration _ms100 = Duration(milliseconds: 100);

void main() {
  group('TweenAnimationBuilder', () {
    test('runs its tween on the first build, then follows a new end', () {
      double end = 100;
      final List<double> seen = <double>[];
      final _Harness h = _Harness(() => TweenAnimationBuilder<double>(
            tween: DoubleTween(begin: 0, end: end),
            duration: _ms100,
            builder: (BuildContext context, double value, Widget? child) {
              seen.add(value);
              return SizedBox(width: value, height: 10);
            },
          ));
      h.tickNow();
      expect(seen.last, 0, reason: 'starts at begin');
      h.advance(const Duration(milliseconds: 50));
      expect(seen.last, 50);
      h.advance(const Duration(milliseconds: 50));
      expect(seen.last, 100);

      // A new end from where the value is - 100 - not from begin.
      end = 200;
      h
        ..settle()
        ..tickNow()
        ..advance(const Duration(milliseconds: 50));
      expect(seen.last, 150);
      h.dispose();
    });

    test('a custom tween with no lerp restarts from its begin', () {
      String target = 'b';
      final List<String> seen = <String>[];
      final _Harness h = _Harness(() => TweenAnimationBuilder<String>(
            tween: _StepTween(begin: 'a', end: target),
            duration: _ms100,
            builder: (BuildContext context, String value, Widget? child) {
              seen.add(value);
              return const SizedBox();
            },
          ));
      h
        ..tickNow()
        ..advance(_ms100);
      expect(seen.last, 'b');
      target = 'c';
      h
        ..settle()
        ..tickNow();
      expect(seen.last, 'a', reason: 'back to the begin of the new tween');
      h.advance(_ms100);
      expect(seen.last, 'c');
      h.dispose();
    });

    test('without a clock it shows the end at once', () {
      final List<double> seen = <double>[];
      final _Harness h = _Harness(
        () => TweenAnimationBuilder<double>(
          tween: const DoubleTween(begin: 0, end: 40),
          duration: _ms100,
          builder: (BuildContext context, double value, Widget? child) {
            seen.add(value);
            return const SizedBox();
          },
        ),
        withClock: false,
      );
      expect(seen.last, 40);
      h.dispose();
    });
  });

  group('AnimatedContainer', () {
    test('size, colour and padding walk to their targets', () {
      double width = 100;
      Color color = const Color(0xFF000000);
      EdgeInsets padding = EdgeInsets.zero;
      final _Harness h = _Harness(() => AnimatedContainer(
            duration: _ms100,
            width: width,
            height: 50,
            color: color,
            padding: padding,
          ));
      width = 200;
      color = const Color(0xFFFFFFFF);
      padding = const EdgeInsets.all(10);
      h
        ..settle()
        ..tickNow()
        ..advance(const Duration(milliseconds: 50));
      final RenderColoredBox box = h.findAll<RenderColoredBox>().single;
      expect(box.size.width, 150);
      expect(box.color, const Color(0xFF808080));
      expect(
          h.findAll<RenderPadding>().single.padding, const EdgeInsets.all(5));
      h.advance(const Duration(milliseconds: 50));
      expect(h.findAll<RenderColoredBox>().single.size.width, 200);
      h.dispose();
    });

    test('a decoration fades its colour, radius and border', () {
      BoxDecoration decoration =
          const BoxDecoration(color: Color(0xFF000000), radius: 0);
      final _Harness h = _Harness(() => AnimatedContainer(
            duration: _ms100,
            width: 40,
            height: 40,
            decoration: decoration,
          ));
      decoration = const BoxDecoration(
        color: Color(0xFFFF0000),
        radius: 10,
        border: BoxBorder(color: Color(0xFF00FF00), width: 2),
      );
      h
        ..settle()
        ..tickNow()
        ..advance(const Duration(milliseconds: 50));
      final BoxDecoration now =
          h.findAll<RenderDecoratedBox>().single.decoration;
      expect(now.radius, 5);
      expect(now.border!.width, 1, reason: 'grows from nothing');
      expect(now.color, const Color(0xFF800000));
      h.dispose();
    });
  });

  group('AnimatedSwitcher', () {
    test('a new key cross-fades; the same key just updates', () {
      int value = 1;
      final _Harness h = _Harness(() => AnimatedSwitcher(
            duration: _ms100,
            child: SizedBox(
                key: ValueKey<int>(value), width: value * 10.0, height: 10),
          ));
      expect(h.findAll<RenderOpacity>().single.opacity, 1,
          reason: 'the first child is simply there');

      value = 2;
      h
        ..settle()
        ..tickNow()
        ..advance(const Duration(milliseconds: 50));
      final List<RenderOpacity> fades = h.findAll<RenderOpacity>();
      expect(fades, hasLength(2), reason: 'both during the fade');
      expect(fades.map((RenderOpacity o) => o.opacity),
          containsAll(<double>[0.5, 0.5]));

      h.advance(const Duration(milliseconds: 60));
      final List<RenderOpacity> after = h.findAll<RenderOpacity>();
      expect(after, hasLength(1), reason: 'the old child is gone');
      expect(after.single.opacity, 1);
      h.dispose();
    });

    test('without a clock it switches at once', () {
      int value = 1;
      final _Harness h = _Harness(
        () => AnimatedSwitcher(
          duration: _ms100,
          child: SizedBox(key: ValueKey<int>(value), width: 10, height: 10),
        ),
        withClock: false,
      );
      value = 2;
      h.settle();
      expect(h.findAll<RenderOpacity>(), hasLength(1));
      h.dispose();
    });
  });
}

/// A tween over a type with no interpolation the framework knows.
final class _StepTween extends Tween<String> {
  const _StepTween({required super.begin, required super.end});

  @override
  String lerp(double t) => t < 0.5 ? begin : end;
}
