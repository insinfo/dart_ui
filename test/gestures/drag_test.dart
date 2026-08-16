import 'package:dart_ui/src/geometry/offset.dart';
import 'package:dart_ui/src/gestures/constants.dart';
import 'package:dart_ui/src/gestures/drag.dart';
import 'package:dart_ui/src/gestures/tap.dart';
import 'package:dart_ui/src/layout/render_viewport.dart';
import 'package:dart_ui/src/platform/input_events.dart';
import 'package:test/test.dart';

import 'gesture_test_support.dart';

void main() {
  group('a vertical drag', () {
    test('starts where the slop was crossed, not where the press landed', () {
      // Starting at the press position would make the dragged object jump
      // backwards by the slop the instant it is picked up.
      final hand = Hand(kind: PointerKind.touch);
      final harness = RecognizerHarness();
      DragStartDetails? start;
      final updates = <double>[];
      harness.add(
        VerticalDragGestureRecognizer(
          arena: harness.arena,
          onStart: (DragStartDetails d) => start = d,
          onUpdate: (DragUpdateDetails d) => updates.add(d.primaryDelta!),
        ),
      );

      harness.dispatch(hand.down(const Offset(100, 100)));
      hand.advance(const Duration(milliseconds: 16));
      harness.dispatch(hand.move(const Offset(100, 110)));
      expect(start, isNull, reason: '10 px is inside the 18 px touch slop');

      hand.advance(const Duration(milliseconds: 16));
      harness.dispatch(hand.move(const Offset(100, 120)));
      expect(start, isNotNull);
      expect(start!.globalPosition, const Offset(100, 120));
      expect(updates, isEmpty, reason: 'the start is not also an update');

      hand.advance(const Duration(milliseconds: 16));
      harness.dispatch(hand.move(const Offset(100, 135)));
      hand.advance(const Duration(milliseconds: 16));
      harness.dispatch(hand.move(const Offset(100, 140)));

      expect(updates, <double>[15, 5]);
    });

    test('ignores movement that is not on its axis', () {
      final hand = Hand(kind: PointerKind.touch);
      final harness = RecognizerHarness();
      var starts = 0;
      harness.add(
        VerticalDragGestureRecognizer(
          arena: harness.arena,
          onStart: (DragStartDetails d) => starts++,
        ),
      );

      harness.dispatch(hand.down(const Offset(100, 100)));
      hand.advance(const Duration(milliseconds: 16));
      harness.dispatch(hand.move(const Offset(200, 100)));
      hand.advance(const Duration(milliseconds: 16));
      harness.dispatch(hand.up(const Offset(200, 100)));

      expect(starts, 0, reason: '100 px sideways is not a vertical drag');
    });

    test('a press and a release that never moved is not a drag at all', () {
      final hand = Hand(kind: PointerKind.touch);
      final harness = RecognizerHarness();
      final log = <String>[];
      harness.add(
        VerticalDragGestureRecognizer(
          arena: harness.arena,
          onStart: (DragStartDetails d) => log.add('start'),
          onEnd: (DragEndDetails d) => log.add('end'),
        ),
      );

      harness.dispatch(hand.down(const Offset(10, 10)));
      hand.advance(const Duration(milliseconds: 200));
      harness.dispatch(hand.up(const Offset(10, 10)));

      expect(log, isEmpty);
      expect(harness.arena.openArenaCount, 0);
    });

    test('a cancelled pointer cancels an active drag and clears the arena', () {
      final hand = Hand(kind: PointerKind.touch);
      final harness = RecognizerHarness();
      final log = <String>[];
      harness.add(
        VerticalDragGestureRecognizer(
          arena: harness.arena,
          onStart: (DragStartDetails d) => log.add('start'),
          onEnd: (DragEndDetails d) => log.add('end'),
          onCancel: () => log.add('cancel'),
        ),
      );

      harness.dispatch(hand.down(const Offset(10, 10)));
      hand.advance(const Duration(milliseconds: 16));
      harness.dispatch(hand.move(const Offset(10, 60)));
      harness.dispatch(hand.cancel(const Offset(10, 60)));

      expect(log, <String>['start', 'cancel']);
      expect(harness.arena.openArenaCount, 0);
    });
  });

  group('a pan moves on both axes', () {
    test('reports two-dimensional deltas and no primary delta', () {
      final hand = Hand(kind: PointerKind.touch);
      final harness = RecognizerHarness();
      final deltas = <Offset>[];
      DragStartDetails? start;
      harness.add(
        PanGestureRecognizer(
          arena: harness.arena,
          onStart: (DragStartDetails d) => start = d,
          onUpdate: (DragUpdateDetails d) {
            deltas.add(d.delta);
            expect(d.primaryDelta, isNull, reason: 'a pan has no axis');
          },
        ),
      );

      harness.dispatch(hand.down(const Offset(0, 0)));
      hand.advance(const Duration(milliseconds: 16));
      // 40 px diagonally is 56.6 px of travel, past the 36 px pan slop.
      harness.dispatch(hand.move(const Offset(40, 40)));
      expect(start!.globalPosition, const Offset(40, 40));

      hand.advance(const Duration(milliseconds: 16));
      harness.dispatch(hand.move(const Offset(55, 30)));
      hand.advance(const Duration(milliseconds: 16));
      harness.dispatch(hand.move(const Offset(50, 35)));

      expect(deltas, <Offset>[const Offset(15, -10), const Offset(-5, 5)]);
    });

    test('a pan needs twice the slop of an axis drag', () {
      expect(panSlopForKind(PointerKind.touch), 2 * kTouchSlop);
      expect(panSlopForKind(PointerKind.mouse), 2 * kPrecisePointerSlop);

      final hand = Hand(kind: PointerKind.touch);
      final harness = RecognizerHarness();
      var starts = 0;
      harness.add(
        PanGestureRecognizer(
          arena: harness.arena,
          onStart: (DragStartDetails d) => starts++,
        ),
      );

      harness.dispatch(hand.down(Offset.zero));
      hand.advance(const Duration(milliseconds: 16));
      harness.dispatch(hand.move(const Offset(0, 25)));
      expect(starts, 0, reason: '25 px would start a vertical drag, not a pan');

      hand.advance(const Duration(milliseconds: 16));
      harness.dispatch(hand.move(const Offset(0, 37)));
      expect(starts, 1);
    });
  });

  group('tap and drag on the same target', () {
    ({TapGestureRecognizer tap, DragGestureRecognizer drag, List<String> log})
        build(RecognizerHarness harness) {
      final log = <String>[];
      // Added in hit-test order: the tap is the inner recognizer.
      final tap = harness.add(
        TapGestureRecognizer(
          arena: harness.arena,
          onTap: () => log.add('tap'),
          onTapCancel: () => log.add('tapCancel'),
        ),
      );
      final drag = harness.add(
        VerticalDragGestureRecognizer(
          arena: harness.arena,
          onStart: (DragStartDetails d) => log.add('dragStart'),
          onEnd: (DragEndDetails d) => log.add('dragEnd'),
        ),
      );
      return (tap: tap, drag: drag, log: log);
    }

    test('under the slop the tap wins, and the drag never starts', () {
      final hand = Hand(kind: PointerKind.touch);
      final harness = RecognizerHarness();
      final result = build(harness);

      harness.dispatch(hand.down(const Offset(10, 10)));
      hand.advance(const Duration(milliseconds: 16));
      harness.dispatch(hand.move(const Offset(10, 25)));
      hand.advance(const Duration(milliseconds: 16));
      harness.dispatch(hand.up(const Offset(10, 25)));

      expect(result.log, <String>['tap']);
      expect(harness.arena.openArenaCount, 0);
    });

    test('past the slop the drag claims it, and the tap is told it lost', () {
      final hand = Hand(kind: PointerKind.touch);
      final harness = RecognizerHarness();
      final result = build(harness);

      harness.dispatch(hand.down(const Offset(10, 10)));
      hand.advance(const Duration(milliseconds: 16));
      harness.dispatch(hand.move(const Offset(10, 40)));

      expect(
        result.log,
        <String>['dragStart'],
        reason: 'the tap never reported a down, so there is nothing to cancel',
      );

      hand.advance(const Duration(milliseconds: 16));
      harness.dispatch(hand.up(const Offset(10, 40)));

      expect(result.log, <String>['dragStart', 'dragEnd']);
      expect(result.log, isNot(contains('tap')));
    });

    test('the threshold is exact: 18 px taps, 18.5 px drags', () {
      for (final (double distance, String expected) in <(double, String)>[
        (18.0, 'tap'),
        (18.5, 'dragStart'),
      ]) {
        final hand = Hand(kind: PointerKind.touch);
        final harness = RecognizerHarness();
        final result = build(harness);

        harness.dispatch(hand.down(const Offset(10, 10)));
        hand.advance(const Duration(milliseconds: 16));
        harness.dispatch(hand.move(Offset(10, 10 + distance)));
        hand.advance(const Duration(milliseconds: 16));
        harness.dispatch(hand.up(Offset(10, 10 + distance)));

        expect(result.log.first, expected, reason: 'moved $distance px');
      }
    });
  });

  group('the fling', () {
    test('a drag at 1024 px/s reports 1024 px/s', () {
      final hand = Hand(kind: PointerKind.touch);
      final harness = RecognizerHarness();
      DragEndDetails? end;
      harness.add(
        VerticalDragGestureRecognizer(
          arena: harness.arena,
          onEnd: (DragEndDetails d) => end = d,
        ),
      );

      // 16 px every 15.625 ms is exactly 1024 px/s.
      const step = Duration(microseconds: 15625);
      harness.dispatch(hand.down(const Offset(0, 0)));
      for (var i = 1; i <= 8; i++) {
        hand.advance(step);
        harness.dispatch(hand.move(Offset(0, 16.0 * i)));
      }
      hand.advance(step);
      harness.dispatch(hand.up(const Offset(0, 144)));

      expect(end, isNotNull);
      expect(end!.primaryVelocity, closeTo(1024, 1e-6));
      expect(end!.velocity.pixelsPerSecond.dx, closeTo(0, 1e-9));
    });

    test('a slow release reports zero rather than a twitch', () {
      final hand = Hand(kind: PointerKind.touch);
      final harness = RecognizerHarness();
      DragEndDetails? end;
      harness.add(
        VerticalDragGestureRecognizer(
          arena: harness.arena,
          onEnd: (DragEndDetails d) => end = d,
        ),
      );

      harness.dispatch(hand.down(const Offset(0, 0)));
      // Past the slop quickly, then crawling at 40 px/s for the last 100 ms.
      hand.advance(const Duration(milliseconds: 16));
      harness.dispatch(hand.move(const Offset(0, 30)));
      for (var i = 1; i <= 5; i++) {
        hand.advance(const Duration(milliseconds: 20));
        harness.dispatch(hand.move(Offset(0, 30 + 0.8 * i)));
      }
      hand.advance(const Duration(milliseconds: 20));
      harness.dispatch(hand.up(const Offset(0, 34.8)));

      expect(kMinFlingVelocity, 50.0);
      expect(end!.velocity, isNotNull);
      expect(
        end!.primaryVelocity,
        0.0,
        reason: '40 px/s is below the fling threshold',
      );
    });

    test('a wild sample cannot fling further than kMaxFlingVelocity', () {
      final hand = Hand(kind: PointerKind.touch);
      final harness = RecognizerHarness();
      DragEndDetails? end;
      harness.add(
        VerticalDragGestureRecognizer(
          arena: harness.arena,
          onEnd: (DragEndDetails d) => end = d,
        ),
      );

      // 400 px every 4 ms is 100 000 px/s: a real number a real driver emits
      // when it coalesces, and one that teleports an unclamped simulation.
      harness.dispatch(hand.down(const Offset(0, 0)));
      for (var i = 1; i <= 5; i++) {
        hand.advance(const Duration(milliseconds: 4));
        harness.dispatch(hand.move(Offset(0, 400.0 * i)));
      }
      hand.advance(const Duration(milliseconds: 4));
      harness.dispatch(hand.up(const Offset(0, 2400)));

      expect(end!.velocity.magnitude, closeTo(kMaxFlingVelocity, 1e-9));
    });

    test('drives ScrollPosition.fling, which had no caller until now', () {
      final hand = Hand(kind: PointerKind.touch);
      final harness = RecognizerHarness();
      final position = ScrollPosition(viewportExtent: 200, contentExtent: 5000);
      harness.add(
        VerticalDragGestureRecognizer(
          arena: harness.arena,
          onUpdate: (DragUpdateDetails d) =>
              position.applyDelta(-d.primaryDelta!),
          onEnd: (DragEndDetails d) => position.fling(-d.primaryVelocity!),
        ),
      );

      const step = Duration(microseconds: 15625);
      harness.dispatch(hand.down(const Offset(0, 300)));
      for (var i = 1; i <= 8; i++) {
        hand.advance(step);
        harness.dispatch(hand.move(Offset(0, 300 - 16.0 * i)));
      }
      hand.advance(step);
      harness.dispatch(hand.up(const Offset(0, 156)));

      // The drag itself scrolled by the movement after the slop was crossed:
      // 128 px of finger travel, minus the 32 px consumed reaching the slop.
      expect(position.pixels, closeTo(96, 1e-6));
      expect(position.velocity, closeTo(1024, 1e-6));

      final double atRelease = position.pixels;
      var frames = 0;
      while (position.tickMomentum(step) && frames < 200) {
        frames++;
      }
      expect(
        position.pixels - atRelease,
        greaterThan(15),
        reason: 'momentum carried the list past where the finger left it',
      );
    });

    test('a known velocity travels a known distance under momentum', () {
      // Exact arithmetic on purpose: 1024 px/s, 1/64 s steps and a friction of
      // 0.5 keep every intermediate value a power of two, so the expected
      // total is a number and not a tolerance. The series is
      // 16 + 8 + 4 + 2 + 1 + 0.5 + 0.25 + 0.125 = 31.875 px over 8 frames,
      // ending when the speed drops below the 8 px/s floor.
      final position = ScrollPosition(viewportExtent: 200, contentExtent: 5000);
      position.fling(1024);

      const step = Duration(microseconds: 15625);
      var frames = 0;
      while (position.tickMomentum(step, friction: 0.5)) {
        frames++;
        expect(frames, lessThan(50), reason: 'must terminate');
      }

      expect(position.pixels, 31.875);
      expect(frames, 7);
      expect(position.velocity, 0);
    });
  });
}
