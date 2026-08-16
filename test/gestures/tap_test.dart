import 'package:dart_ui/src/geometry/offset.dart';
import 'package:dart_ui/src/gestures/constants.dart';
import 'package:dart_ui/src/gestures/tap.dart';
import 'package:dart_ui/src/platform/input_events.dart';
import 'package:test/test.dart';

import 'gesture_test_support.dart';

void main() {
  group('a plain tap', () {
    test('fires on the release, having won the arena on the press', () {
      final hand = Hand();
      final harness = RecognizerHarness();
      final log = <String>[];
      harness.add(
        TapGestureRecognizer(
          arena: harness.arena,
          onTapDown: (TapDetails d) => log.add('down@${d.tapCount}'),
          onTapUp: (TapDetails d) => log.add('up@${d.globalPosition.dx}'),
          onTap: () => log.add('tap'),
        ),
      );

      harness.dispatch(hand.down(const Offset(10, 10)));
      expect(
        log,
        <String>['down@1'],
        reason: 'a lone recognizer wins by walkover on the press itself',
      );

      hand.advance(const Duration(milliseconds: 30));
      harness.dispatch(hand.up(const Offset(10, 10)));

      expect(log, <String>['down@1', 'up@10.0', 'tap']);
      expect(harness.arena.openArenaCount, 0);
    });

    test('a release somewhere else is the user taking the tap back', () {
      final hand = Hand();
      final harness = RecognizerHarness();
      var taps = 0;
      var cancels = 0;
      harness.add(
        TapGestureRecognizer(
          arena: harness.arena,
          onTap: () => taps++,
          onTapCancel: () => cancels++,
        )..targetContains = (Offset p) => p.dx < 50,
      );

      harness.dispatch(hand.down(const Offset(10, 10)));
      harness.dispatch(hand.up(const Offset(80, 10)));

      expect(taps, 0);
      expect(cancels, 1);
      expect(harness.arena.openArenaCount, 0);
    });

    test('a cancelled pointer cancels the tap and empties the arena', () {
      final hand = Hand();
      final harness = RecognizerHarness();
      var taps = 0;
      var cancels = 0;
      harness.add(
        TapGestureRecognizer(
          arena: harness.arena,
          onTap: () => taps++,
          onTapCancel: () => cancels++,
        ),
      );

      harness.dispatch(hand.down(const Offset(10, 10)));
      harness.dispatch(hand.cancel(const Offset(10, 10)));
      harness.dispatch(hand.up(const Offset(10, 10)));

      expect(taps, 0);
      expect(cancels, 1);
      expect(harness.arena.openArenaCount, 0);
    });

    test('only the configured button', () {
      final hand = Hand();
      final harness = RecognizerHarness();
      var taps = 0;
      harness.add(
        TapGestureRecognizer(arena: harness.arena, onTap: () => taps++),
      );

      harness.dispatch(
        hand.down(const Offset(10, 10), button: PointerButton.secondary),
      );
      harness.dispatch(
        hand.up(const Offset(10, 10), button: PointerButton.secondary),
      );

      expect(taps, 0);
      expect(harness.arena.openArenaCount, 0, reason: 'never joined at all');
    });
  });

  group('the slop is what separates a tap from a drag', () {
    test('a mouse gives up after 4 logical pixels, not 18', () {
      // kPrecisePointerSlop is Win32's SM_CXDRAG default. A mouse does not
      // wander, and swallowing 18 pixels of deliberate mouse travel would make
      // a short drag impossible.
      expect(kPrecisePointerSlop, 4.0);
      expect(touchSlopForKind(PointerKind.mouse), 4.0);

      for (final (double distance, bool expectTap) in <(double, bool)>[
        (4.0, true), // exactly at the threshold is still a tap
        (4.1, false),
      ]) {
        final hand = Hand();
        final harness = RecognizerHarness();
        var taps = 0;
        harness.add(
          TapGestureRecognizer(arena: harness.arena, onTap: () => taps++),
        );

        harness.dispatch(hand.down(const Offset(10, 10)));
        hand.advance(const Duration(milliseconds: 10));
        harness.dispatch(hand.move(Offset(10 + distance, 10)));
        harness.dispatch(hand.up(Offset(10 + distance, 10)));

        expect(taps, expectTap ? 1 : 0, reason: 'moved $distance px');
      }
    });

    test('a finger is allowed 18, because a fingertip wanders', () {
      expect(kTouchSlop, 18.0);
      expect(touchSlopForKind(PointerKind.touch), 18.0);

      for (final (double distance, bool expectTap) in <(double, bool)>[
        (17.0, true),
        (18.0, true),
        (18.5, false),
      ]) {
        final hand = Hand(kind: PointerKind.touch);
        final harness = RecognizerHarness();
        var taps = 0;
        harness.add(
          TapGestureRecognizer(arena: harness.arena, onTap: () => taps++),
        );

        harness.dispatch(hand.down(const Offset(50, 50)));
        hand.advance(const Duration(milliseconds: 10));
        harness.dispatch(hand.move(Offset(50, 50 + distance)));
        harness.dispatch(hand.up(Offset(50, 50 + distance)));

        expect(taps, expectTap ? 1 : 0, reason: 'moved $distance px');
      }
    });
  });

  group('two taps, or one double tap', () {
    test('close in time and place: counts 1 then 2, and both fire onTap', () {
      final hand = Hand();
      final harness = RecognizerHarness();
      final counts = <int>[];
      var taps = 0;
      var doubles = 0;
      harness.add(
        TapGestureRecognizer(
          arena: harness.arena,
          onTapUp: (TapDetails d) => counts.add(d.tapCount),
          onTap: () => taps++,
          onDoubleTap: (TapDetails d) => doubles++,
        ),
      );

      for (var i = 0; i < 2; i++) {
        harness.dispatch(hand.down(const Offset(10, 10)));
        hand.advance(const Duration(milliseconds: 20));
        harness.dispatch(hand.up(const Offset(10, 10)));
        hand.advance(const Duration(milliseconds: 80));
      }

      expect(counts, <int>[1, 2]);
      expect(doubles, 1);
      expect(
        taps,
        2,
        reason: 'the first click is never withheld, as on every desktop',
      );
    });

    test('separated by time: 501 ms apart is two single taps', () {
      final hand = Hand();
      final harness = RecognizerHarness();
      final counts = <int>[];
      var doubles = 0;
      harness.add(
        TapGestureRecognizer(
          arena: harness.arena,
          onTapUp: (TapDetails d) => counts.add(d.tapCount),
          onDoubleTap: (TapDetails d) => doubles++,
        ),
      );

      harness.dispatch(hand.down(const Offset(10, 10)));
      harness.dispatch(hand.up(const Offset(10, 10)));
      hand.advance(kDoubleTapTimeout + const Duration(milliseconds: 1));
      harness.dispatch(hand.down(const Offset(10, 10)));
      harness.dispatch(hand.up(const Offset(10, 10)));

      expect(counts, <int>[1, 1]);
      expect(doubles, 0);
    });

    test('separated by distance: opposite corners are two single taps', () {
      final hand = Hand();
      final harness = RecognizerHarness();
      final counts = <int>[];
      harness.add(
        TapGestureRecognizer(
          arena: harness.arena,
          onTapUp: (TapDetails d) => counts.add(d.tapCount),
        ),
      );

      harness.dispatch(hand.down(const Offset(10, 10)));
      harness.dispatch(hand.up(const Offset(10, 10)));
      hand.advance(const Duration(milliseconds: 50));
      // 5 px is past kPreciseDoubleTapSlop, which is SM_CXDOUBLECLK's default.
      harness.dispatch(hand.down(const Offset(15, 10)));
      harness.dispatch(hand.up(const Offset(15, 10)));

      expect(counts, <int>[1, 1]);
    });

    test('the platform count wins over the framework interval', () {
      // The Win32 rule this repository already follows in
      // RenderTextField._countClick: GetDoubleClickTime() is an accessibility
      // setting, and a user who raised it to 900 ms must not find that the
      // double click they configured stops working inside the framework.
      final hand = Hand();
      final harness = RecognizerHarness();
      final counts = <int>[];
      var doubles = 0;
      harness.add(
        TapGestureRecognizer(
          arena: harness.arena,
          onTapUp: (TapDetails d) => counts.add(d.tapCount),
          onDoubleTap: (TapDetails d) => doubles++,
        ),
      );

      harness.dispatch(hand.down(const Offset(10, 10)));
      harness.dispatch(hand.up(const Offset(10, 10)));
      hand.advance(const Duration(milliseconds: 900));
      harness.dispatch(hand.down(const Offset(10, 10), clickCount: 2));
      harness.dispatch(hand.up(const Offset(10, 10)));

      expect(counts, <int>[1, 2]);
      expect(doubles, 1);
    });

    test('a fourth tap starts the run again at one, as Windows does', () {
      final hand = Hand();
      final harness = RecognizerHarness();
      final counts = <int>[];
      harness.add(
        TapGestureRecognizer(
          arena: harness.arena,
          onTapUp: (TapDetails d) => counts.add(d.tapCount),
        ),
      );

      for (var i = 0; i < 4; i++) {
        harness.dispatch(hand.down(const Offset(10, 10)));
        hand.advance(const Duration(milliseconds: 20));
        harness.dispatch(hand.up(const Offset(10, 10)));
        hand.advance(const Duration(milliseconds: 30));
      }

      expect(counts, <int>[1, 2, 3, 1]);
    });

    test('a tap that lost its arena does not make the next one a double', () {
      final hand = Hand();
      final harness = RecognizerHarness();
      final counts = <int>[];
      harness.add(
        TapGestureRecognizer(
          arena: harness.arena,
          onTapUp: (TapDetails d) => counts.add(d.tapCount),
        ),
      );

      // First press: dragged away, so it is not a tap at all.
      harness.dispatch(hand.down(const Offset(10, 10)));
      hand.advance(const Duration(milliseconds: 10));
      harness.dispatch(hand.move(const Offset(40, 10)));
      harness.dispatch(hand.up(const Offset(40, 10)));
      hand.advance(const Duration(milliseconds: 50));

      harness.dispatch(hand.down(const Offset(10, 10)));
      harness.dispatch(hand.up(const Offset(10, 10)));

      expect(counts, <int>[1]);
    });

    test('a finger gets 100 px of double-tap slop, a mouse gets 4', () {
      expect(doubleTapSlopForKind(PointerKind.touch), kTouchDoubleTapSlop);
      expect(doubleTapSlopForKind(PointerKind.mouse), kPreciseDoubleTapSlop);

      final hand = Hand(kind: PointerKind.touch);
      final harness = RecognizerHarness();
      final counts = <int>[];
      harness.add(
        TapGestureRecognizer(
          arena: harness.arena,
          onTapUp: (TapDetails d) => counts.add(d.tapCount),
        ),
      );

      harness.dispatch(hand.down(const Offset(10, 10)));
      harness.dispatch(hand.up(const Offset(10, 10)));
      hand.advance(const Duration(milliseconds: 50));
      // 40 px apart: two separate finger contacts aimed at the same target.
      harness.dispatch(hand.down(const Offset(50, 10)));
      harness.dispatch(hand.up(const Offset(50, 10)));

      expect(counts, <int>[1, 2]);
    });
  });

  group('MultiTapCounter matches RenderTextField._countClick', () {
    test('peeking does not advance the run', () {
      final counter = MultiTapCounter();
      expect(
        counter.countTapAt(
          timestamp: Duration.zero,
          position: Offset.zero,
          kind: PointerKind.mouse,
        ),
        1,
      );
      for (var i = 0; i < 3; i++) {
        expect(
          counter.peekTapAt(
            timestamp: const Duration(milliseconds: 100),
            position: Offset.zero,
            kind: PointerKind.mouse,
          ),
          2,
        );
      }
      expect(counter.count, 1);
    });

    test('a timestamp that went backwards starts a new run', () {
      // A negative interval is never a continuation; it means the stream is
      // not monotonic, and guessing would produce a double click out of two
      // unrelated presses.
      final counter = MultiTapCounter();
      counter.countTapAt(
        timestamp: const Duration(milliseconds: 500),
        position: Offset.zero,
        kind: PointerKind.mouse,
      );
      expect(
        counter.countTapAt(
          timestamp: const Duration(milliseconds: 400),
          position: Offset.zero,
          kind: PointerKind.mouse,
        ),
        1,
      );
    });

    test('reset forgets the run', () {
      final counter = MultiTapCounter();
      counter.countTapAt(
        timestamp: Duration.zero,
        position: Offset.zero,
        kind: PointerKind.mouse,
      );
      counter.reset();
      expect(
        counter.countTapAt(
          timestamp: const Duration(milliseconds: 10),
          position: Offset.zero,
          kind: PointerKind.mouse,
        ),
        1,
      );
    });
  });

  group('DoubleTapGestureRecognizer', () {
    test('fires only on the second tap', () {
      final hand = Hand();
      final harness = RecognizerHarness();
      var doubles = 0;
      harness.add(
        DoubleTapGestureRecognizer(
          arena: harness.arena,
          onDoubleTap: (TapDetails d) => doubles++,
        ),
      );

      harness.dispatch(hand.down(const Offset(10, 10)));
      harness.dispatch(hand.up(const Offset(10, 10)));
      expect(doubles, 0);

      hand.advance(const Duration(milliseconds: 50));
      harness.dispatch(hand.down(const Offset(10, 10)));
      harness.dispatch(hand.up(const Offset(10, 10)));
      expect(doubles, 1);
    });
  });
}
