import 'dart:math' as math;

import 'package:dart_ui/src/geometry/offset.dart';
import 'package:dart_ui/src/gestures/scale.dart';
import 'package:dart_ui/src/platform/input_events.dart';
import 'package:test/test.dart';

import 'gesture_test_support.dart';

void main() {
  group('two fingers', () {
    test('spreading from 100 px to 200 px is a scale of exactly 2', () {
      final first = Hand(kind: PointerKind.touch);
      final second = first.withPointer(1);
      final harness = RecognizerHarness();
      ScaleStartDetails? start;
      final updates = <ScaleUpdateDetails>[];
      harness.add(
        ScaleGestureRecognizer(
          arena: harness.arena,
          onStart: (ScaleStartDetails d) => start = d,
          onUpdate: updates.add,
        ),
      );

      harness.dispatch(first.down(const Offset(0, 0)));
      harness.dispatch(second.down(const Offset(100, 0)));
      expect(start, isNull, reason: 'two fingers resting is not yet a pinch');

      first.advance(const Duration(milliseconds: 16));
      harness.dispatch(second.move(const Offset(200, 0)));

      expect(start, isNotNull);
      expect(updates.single.scale, closeTo(2.0, 1e-9));
      expect(updates.single.focalPoint, const Offset(100, 0));
      expect(updates.single.pointerCount, 2);
      expect(start!.focalPoint, const Offset(100, 0));
    });

    test('pinching in halves the scale', () {
      final first = Hand(kind: PointerKind.touch);
      final second = first.withPointer(1);
      final harness = RecognizerHarness();
      final scales = <double>[];
      harness.add(
        ScaleGestureRecognizer(
          arena: harness.arena,
          onUpdate: (ScaleUpdateDetails d) => scales.add(d.scale),
        ),
      );

      harness.dispatch(first.down(const Offset(0, 0)));
      harness.dispatch(second.down(const Offset(200, 0)));
      first.advance(const Duration(milliseconds: 16));
      harness.dispatch(second.move(const Offset(100, 0)));

      expect(scales.single, closeTo(0.5, 1e-9));
    });

    test('rotating one finger a quarter turn reports pi/2 radians', () {
      final first = Hand(kind: PointerKind.touch);
      final second = first.withPointer(1);
      final harness = RecognizerHarness();
      final updates = <ScaleUpdateDetails>[];
      harness.add(
        ScaleGestureRecognizer(arena: harness.arena, onUpdate: updates.add),
      );

      // Baseline: the two contacts lie along +x.
      harness.dispatch(first.down(const Offset(0, 0)));
      harness.dispatch(second.down(const Offset(100, 0)));
      first.advance(const Duration(milliseconds: 16));
      // The second contact swings onto +y, keeping the same distance.
      harness.dispatch(second.move(const Offset(0, 100)));

      expect(updates.last.rotation, closeTo(math.pi / 2, 1e-9));
      expect(
        updates.last.scale,
        closeTo(1.0, 1e-9),
        reason: 'a pure rotation must not zoom',
      );
    });

    test('rotation stays small when it crosses the atan2 branch cut', () {
      final first = Hand(kind: PointerKind.touch);
      final second = first.withPointer(1);
      final harness = RecognizerHarness();
      final updates = <ScaleUpdateDetails>[];
      harness.add(
        ScaleGestureRecognizer(arena: harness.arena, onUpdate: updates.add),
      );

      // The contacts start 300 px apart along -x, where atan2 reports +pi.
      harness.dispatch(first.down(const Offset(0, 0)));
      harness.dispatch(second.down(const Offset(-300, 0)));
      first.advance(const Duration(milliseconds: 16));
      // Half a radian further round, where atan2 has wrapped to -(pi - 0.5).
      harness.dispatch(
        second.move(Offset(-300 * math.cos(0.5), -300 * math.sin(0.5))),
      );

      expect(
        updates.last.rotation,
        closeTo(0.5, 1e-9),
        reason: 'the raw angle difference would be -5.78 radians',
      );
    });

    test('the focal point follows both fingers moving together', () {
      final first = Hand(kind: PointerKind.touch);
      final second = first.withPointer(1);
      final harness = RecognizerHarness();
      final updates = <ScaleUpdateDetails>[];
      ScaleStartDetails? start;
      harness.add(
        ScaleGestureRecognizer(
          arena: harness.arena,
          onStart: (ScaleStartDetails d) => start = d,
          onUpdate: updates.add,
        ),
      );

      harness.dispatch(first.down(const Offset(0, 0)));
      harness.dispatch(second.down(const Offset(100, 0)));
      first.advance(const Duration(milliseconds: 16));
      harness.dispatch(first.move(const Offset(0, 50)));
      harness.dispatch(second.move(const Offset(100, 50)));
      first.advance(const Duration(milliseconds: 16));
      harness.dispatch(first.move(const Offset(0, 80)));
      harness.dispatch(second.move(const Offset(100, 80)));

      final ScaleUpdateDetails last = updates.last;
      expect(last.focalPoint, const Offset(50, 80));
      expect(last.scale, closeTo(1.0, 1e-9), reason: 'a pure two-finger pan');
      // The deltas add up to the travel since the gesture was recognized -
      // which is what a consumer translating a canvas needs them to do.
      expect(
        updates.map((ScaleUpdateDetails d) => d.focalPointDelta).reduce(
              (Offset a, Offset b) => a + b,
            ),
        last.focalPoint - start!.focalPoint,
      );
    });
  });

  group('claiming the arena', () {
    test('two fingers that barely move do not claim it', () {
      final first = Hand(kind: PointerKind.touch);
      final second = first.withPointer(1);
      final harness = RecognizerHarness();
      var starts = 0;
      harness.add(
        ScaleGestureRecognizer(
          arena: harness.arena,
          onStart: (ScaleStartDetails d) => starts++,
        ),
      );

      harness.dispatch(first.down(const Offset(0, 0)));
      harness.dispatch(second.down(const Offset(100, 0)));
      first.advance(const Duration(milliseconds: 16));
      // 10 px of spread: inside the 18 px scale slop for a finger.
      harness.dispatch(second.move(const Offset(110, 0)));

      expect(starts, 0);
    });

    test('a baseline is re-taken when a third finger lands', () {
      // Without it, `scale` would jump discontinuously the instant the third
      // contact changes the mean distance, and the image would visibly snap.
      final first = Hand(kind: PointerKind.touch);
      final second = first.withPointer(1);
      final third = first.withPointer(2);
      final harness = RecognizerHarness();
      final scales = <double>[];
      harness.add(
        ScaleGestureRecognizer(
          arena: harness.arena,
          onUpdate: (ScaleUpdateDetails d) => scales.add(d.scale),
        ),
      );

      harness.dispatch(first.down(const Offset(0, 0)));
      harness.dispatch(second.down(const Offset(100, 0)));
      first.advance(const Duration(milliseconds: 16));
      harness.dispatch(second.move(const Offset(200, 0)));
      expect(scales.last, closeTo(2.0, 1e-9));

      harness.dispatch(third.down(const Offset(100, 0)));
      first.advance(const Duration(milliseconds: 16));
      harness.dispatch(third.move(const Offset(100, 1)));

      expect(
        scales.last,
        closeTo(1.0, 0.05),
        reason: 'the new baseline makes the scale continuous, not doubled',
      );
    });
  });

  group('ending', () {
    test('lifting the last finger ends the gesture with its velocity', () {
      final first = Hand(kind: PointerKind.touch);
      final second = first.withPointer(1);
      final harness = RecognizerHarness();
      ScaleEndDetails? end;
      harness.add(
        ScaleGestureRecognizer(
          arena: harness.arena,
          onEnd: (ScaleEndDetails d) => end = d,
        ),
      );

      harness.dispatch(first.down(const Offset(0, 0)));
      harness.dispatch(second.down(const Offset(100, 0)));
      // Both fingers travel down together at 1000 px/s.
      for (var i = 1; i <= 6; i++) {
        first.advance(const Duration(milliseconds: 16));
        harness.dispatch(first.move(Offset(0, 16.0 * i)));
        harness.dispatch(second.move(Offset(100, 16.0 * i)));
      }
      first.advance(const Duration(milliseconds: 16));
      harness.dispatch(second.up(const Offset(100, 112)));
      expect(end, isNull, reason: 'one finger is still down');

      harness.dispatch(first.up(const Offset(0, 112)));
      expect(end, isNotNull);
      expect(end!.pointerCount, 0);
      expect(end!.velocity.pixelsPerSecond.dy, closeTo(1000, 1.0));
      expect(harness.arena.openArenaCount, 0);
    });

    test('a cancelled pinch ends with no velocity and no arena left', () {
      final first = Hand(kind: PointerKind.touch);
      final second = first.withPointer(1);
      final harness = RecognizerHarness();
      ScaleEndDetails? end;
      harness.add(
        ScaleGestureRecognizer(
          arena: harness.arena,
          onEnd: (ScaleEndDetails d) => end = d,
        ),
      );

      harness.dispatch(first.down(const Offset(0, 0)));
      harness.dispatch(second.down(const Offset(100, 0)));
      first.advance(const Duration(milliseconds: 16));
      harness.dispatch(second.move(const Offset(200, 0)));
      harness.dispatch(second.cancel(const Offset(200, 0)));
      harness.dispatch(first.cancel(const Offset(0, 0)));

      expect(end!.velocity.pixelsPerSecond, Offset.zero);
      expect(harness.arena.openArenaCount, 0);
    });

    test('two fingers that never pinched leave nothing pending', () {
      final first = Hand(kind: PointerKind.touch);
      final second = first.withPointer(1);
      final harness = RecognizerHarness();
      harness.add(ScaleGestureRecognizer(arena: harness.arena));

      harness.dispatch(first.down(const Offset(0, 0)));
      harness.dispatch(second.down(const Offset(100, 0)));
      harness.dispatch(second.up(const Offset(100, 0)));
      harness.dispatch(first.up(const Offset(0, 0)));

      expect(harness.arena.openArenaCount, 0);
    });
  });
}
