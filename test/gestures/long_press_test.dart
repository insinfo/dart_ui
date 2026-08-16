import 'package:dart_ui/src/geometry/offset.dart';
import 'package:dart_ui/src/gestures/constants.dart';
import 'package:dart_ui/src/gestures/drag.dart';
import 'package:dart_ui/src/gestures/long_press.dart';
import 'package:dart_ui/src/gestures/recognizer.dart';
import 'package:dart_ui/src/gestures/tap.dart';
import 'package:dart_ui/src/platform/input_events.dart';
import 'package:test/test.dart';

import 'gesture_test_support.dart';

void main() {
  group('the deadline', () {
    test('fires at exactly 500 ms of virtual time, and not at 499', () {
      final hand = Hand(kind: PointerKind.touch);
      final harness = RecognizerHarness();
      final log = <String>[];
      harness.add(
        LongPressGestureRecognizer(
          dispatcher: hand.dispatcher,
          arena: harness.arena,
          onLongPress: () => log.add('longPress'),
        ),
      );

      harness.dispatch(hand.down(const Offset(10, 10)));
      hand.advance(const Duration(milliseconds: 499));
      expect(log, isEmpty);

      hand.advance(const Duration(milliseconds: 1));
      expect(log, <String>['longPress']);
      expect(kLongPressTimeout, const Duration(milliseconds: 500));
    });

    test('a custom duration is honoured exactly', () {
      final hand = Hand(kind: PointerKind.touch);
      final harness = RecognizerHarness();
      var fired = 0;
      harness.add(
        LongPressGestureRecognizer(
          dispatcher: hand.dispatcher,
          arena: harness.arena,
          duration: const Duration(milliseconds: 120),
          onLongPress: () => fired++,
        ),
      );

      harness.dispatch(hand.down(const Offset(10, 10)));
      hand.advance(const Duration(milliseconds: 119));
      expect(fired, 0);
      hand.advance(const Duration(milliseconds: 1));
      expect(fired, 1);
    });

    test('start details describe the press, not the deadline', () {
      final hand = Hand(kind: PointerKind.touch);
      final harness = RecognizerHarness();
      LongPressStartDetails? start;
      harness.add(
        LongPressGestureRecognizer(
          dispatcher: hand.dispatcher,
          arena: harness.arena,
          onLongPressStart: (LongPressStartDetails d) => start = d,
        ),
      );

      hand.advance(const Duration(milliseconds: 40));
      harness.dispatch(hand.down(const Offset(7, 9)));
      hand.advance(kLongPressTimeout);

      expect(start!.globalPosition, const Offset(7, 9));
      expect(start!.timestamp, const Duration(milliseconds: 40));
      expect(start!.kind, PointerKind.touch);
    });
  });

  group('stillness', () {
    test('moving past the slop before the deadline cancels it', () {
      final hand = Hand(kind: PointerKind.touch);
      final harness = RecognizerHarness();
      final log = <String>[];
      harness.add(
        LongPressGestureRecognizer(
          dispatcher: hand.dispatcher,
          arena: harness.arena,
          onLongPress: () => log.add('longPress'),
          onLongPressCancel: () => log.add('cancel'),
        ),
      );

      harness.dispatch(hand.down(const Offset(10, 10)));
      hand.advance(const Duration(milliseconds: 100));
      harness.dispatch(hand.move(const Offset(10, 40)));
      expect(log, <String>['cancel']);

      hand.advance(const Duration(seconds: 5));
      expect(
        log,
        <String>['cancel'],
        reason: 'the deadline must have been disarmed, not merely ignored',
      );
      expect(hand.dispatcher.pendingTimerCount, 0);
    });

    test('drifting within the slop keeps the press alive', () {
      final hand = Hand(kind: PointerKind.touch);
      final harness = RecognizerHarness();
      var fired = 0;
      harness.add(
        LongPressGestureRecognizer(
          dispatcher: hand.dispatcher,
          arena: harness.arena,
          onLongPress: () => fired++,
        ),
      );

      harness.dispatch(hand.down(const Offset(10, 10)));
      for (var i = 0; i < 4; i++) {
        hand.advance(const Duration(milliseconds: 100));
        harness.dispatch(hand.move(Offset(10 + (i.isEven ? 4 : -4), 10)));
      }
      hand.advance(const Duration(milliseconds: 200));

      expect(fired, 1);
    });

    test('after recognition, movement is a drag rather than a cancel', () {
      // A reorderable list: hold to pick the item up, then drag it. Applying
      // the slop after recognition would drop the item on the first pixel.
      final hand = Hand(kind: PointerKind.touch);
      final harness = RecognizerHarness();
      final log = <String>[];
      final moves = <Offset>[];
      harness.add(
        LongPressGestureRecognizer(
          dispatcher: hand.dispatcher,
          arena: harness.arena,
          onLongPress: () => log.add('longPress'),
          onLongPressMoveUpdate: (LongPressMoveUpdateDetails d) =>
              moves.add(d.offsetFromOrigin),
          onLongPressEnd: (LongPressEndDetails d) => log.add('end'),
          onLongPressCancel: () => log.add('cancel'),
        ),
      );

      harness.dispatch(hand.down(const Offset(10, 10)));
      hand.advance(kLongPressTimeout);
      hand.advance(const Duration(milliseconds: 16));
      harness.dispatch(hand.move(const Offset(10, 90)));
      hand.advance(const Duration(milliseconds: 16));
      harness.dispatch(hand.move(const Offset(30, 110)));
      hand.advance(const Duration(milliseconds: 16));
      harness.dispatch(hand.up(const Offset(30, 110)));

      expect(log, <String>['longPress', 'end']);
      expect(moves, <Offset>[const Offset(0, 80), const Offset(20, 100)]);
    });
  });

  group('releasing early', () {
    test('a quick tap is cancelled, not a long press', () {
      final hand = Hand(kind: PointerKind.touch);
      final harness = RecognizerHarness();
      final log = <String>[];
      harness.add(
        LongPressGestureRecognizer(
          dispatcher: hand.dispatcher,
          arena: harness.arena,
          onLongPress: () => log.add('longPress'),
          onLongPressCancel: () => log.add('cancel'),
        ),
      );

      harness.dispatch(hand.down(const Offset(10, 10)));
      hand.advance(const Duration(milliseconds: 200));
      harness.dispatch(hand.up(const Offset(10, 10)));

      expect(log, <String>['cancel']);
      expect(harness.arena.openArenaCount, 0);
      expect(hand.dispatcher.pendingTimerCount, 0);
    });

    test('a cancelled pointer disarms the deadline and clears the arena', () {
      final hand = Hand(kind: PointerKind.touch);
      final harness = RecognizerHarness();
      var fired = 0;
      harness.add(
        LongPressGestureRecognizer(
          dispatcher: hand.dispatcher,
          arena: harness.arena,
          onLongPress: () => fired++,
        ),
      );

      harness.dispatch(hand.down(const Offset(10, 10)));
      harness.dispatch(hand.cancel(const Offset(10, 10)));
      hand.advance(const Duration(seconds: 2));

      expect(fired, 0);
      expect(harness.arena.openArenaCount, 0);
      expect(hand.dispatcher.pendingTimerCount, 0);
    });
  });

  group('against the other gestures', () {
    test('a long press beats the tap sharing its target', () {
      final hand = Hand(kind: PointerKind.touch);
      final harness = RecognizerHarness();
      final log = <String>[];
      harness.add(
        TapGestureRecognizer(
          arena: harness.arena,
          onTap: () => log.add('tap'),
        ),
      );
      harness.add(
        LongPressGestureRecognizer(
          dispatcher: hand.dispatcher,
          arena: harness.arena,
          onLongPress: () => log.add('longPress'),
        ),
      );

      harness.dispatch(hand.down(const Offset(10, 10)));
      hand.advance(kLongPressTimeout);
      harness.dispatch(hand.up(const Offset(10, 10)));

      expect(log, <String>['longPress']);
    });

    test('a quick tap still beats the long press sharing its target', () {
      final hand = Hand(kind: PointerKind.touch);
      final harness = RecognizerHarness();
      final log = <String>[];
      harness.add(
        TapGestureRecognizer(
          arena: harness.arena,
          onTap: () => log.add('tap'),
        ),
      );
      harness.add(
        LongPressGestureRecognizer(
          dispatcher: hand.dispatcher,
          arena: harness.arena,
          onLongPress: () => log.add('longPress'),
        ),
      );

      harness.dispatch(hand.down(const Offset(10, 10)));
      hand.advance(const Duration(milliseconds: 80));
      harness.dispatch(hand.up(const Offset(10, 10)));

      expect(log, <String>['tap']);
    });

    test('a scroll that starts slowly is a drag, not a long press', () {
      final hand = Hand(kind: PointerKind.touch);
      final harness = RecognizerHarness();
      final log = <String>[];
      harness.add(
        LongPressGestureRecognizer(
          dispatcher: hand.dispatcher,
          arena: harness.arena,
          onLongPress: () => log.add('longPress'),
        ),
      );
      harness.add(
        VerticalDragGestureRecognizer(
          arena: harness.arena,
          onStart: (DragStartDetails d) => log.add('dragStart'),
        ),
      );

      harness.dispatch(hand.down(const Offset(10, 10)));
      // 300 ms of hesitation, then the finger goes.
      hand.advance(const Duration(milliseconds: 300));
      harness.dispatch(hand.move(const Offset(10, 50)));
      hand.advance(const Duration(seconds: 1));

      expect(log, <String>['dragStart']);
    });
  });

  test('a deadline without a dispatcher is refused at construction', () {
    // The alternatives are both worse: a recognizer that silently never
    // fires, or one that reads a wall clock and makes the suite intermittent.
    expect(_DeadlineWithoutDispatcher.new, throwsA(isA<ArgumentError>()));
  });
}

/// Asks for a deadline and brings nothing to arm it on.
final class _DeadlineWithoutDispatcher extends PrimaryPointerGestureRecognizer {
  _DeadlineWithoutDispatcher()
      : super(deadline: const Duration(milliseconds: 10));

  @override
  void handlePrimaryPointer(PointerEvent event) {}
}
