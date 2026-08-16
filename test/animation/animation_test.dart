/// The controller and the tweens, driven by a hand-ticked [AnimationClock].
///
/// Nothing here sleeps and nothing reads a wall clock. Time is whatever the
/// test hands to [AnimationClock.tick], which is the entire reason these
/// assertions can be exact equalities instead of tolerances.
library;

import 'package:dart_ui/src/animation/animation.dart';
import 'package:dart_ui/src/animation/clock.dart';
import 'package:dart_ui/src/animation/curves.dart';
import 'package:dart_ui/src/geometry/offset.dart';
import 'package:dart_ui/src/geometry/rect.dart';
import 'package:dart_ui/src/geometry/size.dart';
import 'package:test/test.dart';

const Duration _ms100 = Duration(milliseconds: 100);

void main() {
  group('AnimationController', () {
    late AnimationClock clock;

    setUp(() => clock = AnimationClock());

    test('starts dismissed at the lower bound', () {
      final AnimationController controller =
          AnimationController(clock: clock, duration: _ms100);
      expect(controller.value, 0.0);
      expect(controller.status, AnimationStatus.dismissed);
      expect(controller.isAnimating, isFalse);
    });

    test('the first frame after forward() only establishes the baseline', () {
      // A controller started between two frames must not be charged for the
      // part of the frame it was not alive for, so its first tick consumes no
      // time. This is load-bearing: without it an animation started late in a
      // frame jumps forward by however long the clock had been running.
      final AnimationController controller =
          AnimationController(clock: clock, duration: _ms100)..forward();
      clock.tick(const Duration(milliseconds: 500));
      expect(controller.value, 0.0);
      clock.tick(const Duration(milliseconds: 550));
      expect(controller.value, 0.5);
    });

    test('forward runs to exactly 1.0 and completes', () {
      final AnimationController controller =
          AnimationController(clock: clock, duration: _ms100)..forward();
      clock.tick(Duration.zero);
      clock.tick(const Duration(milliseconds: 50));
      expect(controller.value, 0.5);
      expect(controller.status, AnimationStatus.forward);
      clock.tick(_ms100);
      // Exact, not closeTo: elapsed is kept in integral microseconds so the
      // final division lands on 1.0 with no residue.
      expect(controller.value, 1.0);
      expect(controller.status, AnimationStatus.completed);
      expect(controller.isAnimating, isFalse);
    });

    test('overrunning the duration does not overshoot the bound', () {
      final AnimationController controller =
          AnimationController(clock: clock, duration: _ms100)..forward();
      clock.tick(Duration.zero);
      clock.tick(const Duration(seconds: 10));
      expect(controller.value, 1.0);
      expect(controller.status, AnimationStatus.completed);
    });

    test('reverse runs back to exactly 0.0 and dismisses', () {
      final AnimationController controller = AnimationController(
        clock: clock,
        duration: _ms100,
        initialValue: 1.0,
      );
      expect(controller.status, AnimationStatus.completed);
      controller.reverse();
      clock.tick(Duration.zero);
      clock.tick(const Duration(milliseconds: 25));
      expect(controller.value, 0.75);
      clock.tick(_ms100);
      expect(controller.value, 0.0);
      expect(controller.status, AnimationStatus.dismissed);
    });

    test('status transitions arrive in order, once each', () {
      final List<AnimationStatus> seen = <AnimationStatus>[];
      final AnimationController controller =
          AnimationController(clock: clock, duration: _ms100)
            ..addStatusListener(seen.add);

      controller.forward();
      clock.tick(Duration.zero);
      clock.tick(const Duration(milliseconds: 50));
      clock.tick(_ms100);
      controller.reverse();
      clock.tick(const Duration(milliseconds: 150));
      clock.tick(const Duration(milliseconds: 250));

      expect(seen, <AnimationStatus>[
        AnimationStatus.forward,
        AnimationStatus.completed,
        AnimationStatus.reverse,
        AnimationStatus.dismissed,
      ]);
    });

    test('value listeners fire once per changing tick and not otherwise', () {
      int notifications = 0;
      final AnimationController controller =
          AnimationController(clock: clock, duration: _ms100)
            ..addListener(() => notifications++);

      // Not running: a tick changes nothing and must notify nobody.
      clock.tick(const Duration(milliseconds: 10));
      expect(notifications, 0);

      controller.forward();
      clock.tick(const Duration(milliseconds: 20));
      expect(notifications, 0, reason: 'baseline frame moves nothing');
      clock.tick(const Duration(milliseconds: 30));
      expect(notifications, 1);
      clock.tick(const Duration(milliseconds: 40));
      expect(notifications, 2);

      // A repeated timestamp is a zero-length step and must be a no-op.
      clock.tick(const Duration(milliseconds: 40));
      expect(notifications, 2);
    });

    test('repeat wraps without ever completing', () {
      final List<AnimationStatus> seen = <AnimationStatus>[];
      final AnimationController controller =
          AnimationController(clock: clock, duration: _ms100)
            ..addStatusListener(seen.add)
            ..repeat();

      clock.tick(Duration.zero);
      clock.tick(const Duration(milliseconds: 60));
      expect(controller.value, 0.6);
      clock.tick(const Duration(milliseconds: 130));
      expect(controller.value, closeTo(0.3, 1e-12));
      clock.tick(const Duration(milliseconds: 250));
      expect(controller.value, closeTo(0.5, 1e-12));
      expect(controller.isAnimating, isTrue);
      expect(seen, <AnimationStatus>[AnimationStatus.forward]);
    });

    test('repeat(reverses: true) ping-pongs and flips status each turn', () {
      final List<AnimationStatus> seen = <AnimationStatus>[];
      final AnimationController controller =
          AnimationController(clock: clock, duration: _ms100)
            ..addStatusListener(seen.add)
            ..repeat(reverses: true);

      clock.tick(Duration.zero);
      clock.tick(const Duration(milliseconds: 80));
      expect(controller.value, 0.8);
      clock.tick(const Duration(milliseconds: 120));
      // Bounced off the top: 120 ms in, 20 ms past the turn, so 0.8 again.
      expect(controller.value, closeTo(0.8, 1e-12));
      clock.tick(const Duration(milliseconds: 210));
      // Bounced off the bottom too: 210 = 200 + 10, so 0.1 climbing again.
      expect(controller.value, closeTo(0.1, 1e-12));
      expect(seen, <AnimationStatus>[
        AnimationStatus.forward,
        AnimationStatus.reverse,
        AnimationStatus.forward,
      ]);
    });

    test('stop freezes the value and keeps the direction', () {
      final AnimationController controller =
          AnimationController(clock: clock, duration: _ms100)..forward();
      clock.tick(Duration.zero);
      clock.tick(const Duration(milliseconds: 40));
      controller.stop();
      expect(controller.isAnimating, isFalse);
      expect(controller.status, AnimationStatus.forward,
          reason: 'a controller stopped mid-flight is still logically going '
              'forward; that is what a resume needs to know');
      clock.tick(const Duration(milliseconds: 90));
      expect(controller.value, 0.4);
    });

    test('a stopped controller resumes from where it stopped', () {
      final AnimationController controller =
          AnimationController(clock: clock, duration: _ms100)..forward();
      clock.tick(Duration.zero);
      clock.tick(const Duration(milliseconds: 40));
      controller.stop();
      clock.tick(const Duration(seconds: 5));
      controller.forward();
      clock.tick(const Duration(seconds: 6));
      expect(controller.value, 0.4, reason: 'the idle gap must not be charged');
      clock.tick(const Duration(milliseconds: 6030));
      expect(controller.value, closeTo(0.7, 1e-12));
    });

    test('reset returns to the start and re-announces dismissed', () {
      final List<AnimationStatus> seen = <AnimationStatus>[];
      final AnimationController controller =
          AnimationController(clock: clock, duration: _ms100)
            ..addStatusListener(seen.add)
            ..forward();
      clock.tick(Duration.zero);
      clock.tick(_ms100);
      controller.reset();
      expect(controller.value, 0.0);
      expect(controller.status, AnimationStatus.dismissed);
      expect(seen.last, AnimationStatus.dismissed);
    });

    test('speed scales the rate without teleporting the value', () {
      final AnimationController controller =
          AnimationController(clock: clock, duration: _ms100, speed: 2.0)
            ..forward();
      clock.tick(Duration.zero);
      clock.tick(const Duration(milliseconds: 25));
      expect(controller.value, 0.5);
      controller.speed = 1.0;
      expect(controller.value, 0.5, reason: 'changing speed moves nothing');
      clock.tick(const Duration(milliseconds: 50));
      expect(controller.value, 0.75);
    });

    test('custom bounds interpolate between them', () {
      final AnimationController controller = AnimationController(
        clock: clock,
        duration: _ms100,
        lowerBound: 10.0,
        upperBound: 30.0,
      )..forward();
      clock.tick(Duration.zero);
      clock.tick(const Duration(milliseconds: 50));
      expect(controller.value, 20.0);
      expect(controller.progress, 0.5);
      clock.tick(_ms100);
      expect(controller.value, 30.0);
    });

    test('assigning value stops the run and settles the status', () {
      final AnimationController controller =
          AnimationController(clock: clock, duration: _ms100)..forward();
      clock.tick(Duration.zero);
      controller.value = 1.0;
      expect(controller.isAnimating, isFalse);
      expect(controller.status, AnimationStatus.completed);
      controller.value = 0.0;
      expect(controller.status, AnimationStatus.dismissed);
    });

    test('nonsense construction fails loudly', () {
      expect(
        () => AnimationController(clock: clock, duration: Duration.zero),
        throwsArgumentError,
      );
      expect(
        () => AnimationController(
            clock: clock, duration: _ms100, lowerBound: 1, upperBound: 0),
        throwsArgumentError,
      );
      expect(
        () => AnimationController(clock: clock, duration: _ms100, speed: 0),
        throwsArgumentError,
      );
      expect(
        () => AnimationController(clock: clock, duration: _ms100, speed: -1),
        throwsArgumentError,
      );
    });

    test('use after dispose throws', () {
      final AnimationController controller =
          AnimationController(clock: clock, duration: _ms100)..dispose();
      expect(controller.forward, throwsStateError);
      expect(clock.tickerCount, 0);
    });
  });

  group('CurvedAnimation', () {
    test('shapes the parent without changing it', () {
      final AnimationClock clock = AnimationClock();
      final AnimationController parent =
          AnimationController(clock: clock, duration: _ms100)..forward();
      final CurvedAnimation curved =
          CurvedAnimation(parent: parent, curve: Curves.easeInOut);

      clock.tick(Duration.zero);
      clock.tick(const Duration(milliseconds: 50));
      expect(parent.value, 0.5);
      expect(curved.value, 0.5, reason: 'easeInOut is symmetric');

      parent.reverse();
      clock.tick(const Duration(milliseconds: 50));
      clock.tick(const Duration(milliseconds: 75));
      expect(parent.value, 0.25);
      expect(curved.value, Curves.easeInOut.transform(0.25));
    });

    test('forwards value and status notifications', () {
      final AnimationClock clock = AnimationClock();
      final AnimationController parent =
          AnimationController(clock: clock, duration: _ms100);
      final CurvedAnimation curved =
          CurvedAnimation(parent: parent, curve: Curves.easeOut);
      int values = 0;
      final List<AnimationStatus> statuses = <AnimationStatus>[];
      curved
        ..addListener(() => values++)
        ..addStatusListener(statuses.add);

      parent.forward();
      clock.tick(Duration.zero);
      clock.tick(_ms100);
      expect(values, 1);
      expect(statuses, <AnimationStatus>[
        AnimationStatus.forward,
        AnimationStatus.completed,
      ]);

      curved.dispose();
      parent
        ..reset()
        ..forward();
      clock.tick(const Duration(milliseconds: 200));
      clock.tick(const Duration(milliseconds: 300));
      expect(values, 1, reason: 'a disposed CurvedAnimation is detached');
    });
  });

  group('tweens', () {
    test('double, at both ends and the middle', () {
      const DoubleTween tween = DoubleTween(begin: 10.0, end: 30.0);
      expect(tween.transform(0.0), 10.0);
      expect(tween.transform(0.5), 20.0);
      expect(tween.transform(1.0), 30.0);
    });

    test('offset', () {
      const OffsetTween tween = OffsetTween(
        begin: Offset(0, 10),
        end: Offset(20, 30),
      );
      expect(tween.transform(0.0), const Offset(0, 10));
      expect(tween.transform(0.5), const Offset(10, 20));
      expect(tween.transform(1.0), const Offset(20, 30));
    });

    test('size', () {
      const SizeTween tween = SizeTween(
        begin: Size(100, 50),
        end: Size(200, 150),
      );
      expect(tween.transform(0.0), const Size(100, 50));
      expect(tween.transform(0.5), const Size(150, 100));
      expect(tween.transform(1.0), const Size(200, 150));
    });

    test('rect', () {
      const RectTween tween = RectTween(
        begin: Rect.fromLTRB(0, 0, 10, 10),
        end: Rect.fromLTRB(10, 20, 30, 40),
      );
      expect(tween.transform(0.0), const Rect.fromLTRB(0, 0, 10, 10));
      expect(tween.transform(0.5), const Rect.fromLTRB(5, 10, 20, 25));
      expect(tween.transform(1.0), const Rect.fromLTRB(10, 20, 30, 40));
    });

    test('the endpoints are answered without interpolating', () {
      // t <= 0 and t >= 1 short-circuit, so a completed animation lands on the
      // declared object rather than on a rounded reconstruction of it.
      const ColorTween tween = ColorTween(begin: 0xFF010203, end: 0xFF040506);
      expect(tween.transform(0.0), 0xFF010203);
      expect(tween.transform(1.0), 0xFF040506);
      expect(tween.transform(-1.0), 0xFF010203);
      expect(tween.transform(2.0), 0xFF040506);
    });

    test('a tween can be driven by a controller', () {
      final AnimationClock clock = AnimationClock();
      final AnimationController controller =
          AnimationController(clock: clock, duration: _ms100)..forward();
      final Animation<Offset> position = const OffsetTween(
        begin: Offset.zero,
        end: Offset(100, 0),
      ).animate(controller);

      clock.tick(Duration.zero);
      clock.tick(const Duration(milliseconds: 40));
      expect(position.value, const Offset(40, 0));
      expect(position.status, AnimationStatus.forward);
      clock.tick(_ms100);
      expect(position.value, const Offset(100, 0));
      expect(position.status, AnimationStatus.completed);
    });
  });

  group('colour interpolation is premultiplied', () {
    test('two opaque colours blend channel by channel', () {
      // Both alphas are 255, so premultiplying is the identity and the result
      // is bit-for-bit the straight interpolation.
      expect(ColorTween.interpolate(0xFFFF0000, 0xFF0000FF, 0.5), 0xFF800080);
      expect(ColorTween.interpolate(0xFF000000, 0xFFFFFFFF, 0.5), 0xFF808080);
    });

    test(
        'fading to transparent keeps the hue instead of dragging it to '
        'black', () {
      // The whole argument for premultiplied space. Straight interpolation
      // would give 0x807F0000 here - half-alpha *dark* red, which composites
      // as a grey-brown smear. Premultiplied keeps the red at full
      // saturation and only the alpha falls.
      final int midpoint = ColorTween.interpolate(0xFFFF0000, 0x00000000, 0.5);
      expect((midpoint >> 24) & 0xFF, 128, reason: 'alpha is halfway');
      expect(midpoint & 0x00FFFFFF, 0x00FF0000,
          reason: 'the colour is still fully saturated red');
      expect(midpoint, 0x80FF0000);
    });

    test('a fully transparent result carries no colour', () {
      expect(ColorTween.interpolate(0xFFFF0000, 0x0000FF00, 1.0), 0x0000FF00);
      // Two transparent endpoints: alpha is zero throughout, and there is no
      // defined colour to report, so it reports none rather than dividing by
      // zero.
      expect(ColorTween.interpolate(0x00FF0000, 0x0000FF00, 0.5), 0x00000000);
    });

    test('alpha and colour move together across a partial fade', () {
      // Opaque blue to half-transparent blue: only the alpha may move.
      final int midpoint = ColorTween.interpolate(0xFF0000FF, 0x800000FF, 0.5);
      expect((midpoint >> 24) & 0xFF, 192);
      expect(midpoint & 0x00FFFFFF, 0x000000FF);
    });

    test('every step of a fade stays on the same hue', () {
      for (int i = 0; i <= 20; i++) {
        final int colour =
            ColorTween.interpolate(0xFF00FF00, 0x00000000, i / 20);
        if (((colour >> 24) & 0xFF) == 0) continue;
        expect(colour & 0x00FFFFFF, 0x0000FF00, reason: 'step $i lost the hue');
      }
    });
  });
}
