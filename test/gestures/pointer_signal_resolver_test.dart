import 'package:dart_ui/src/geometry/offset.dart';
import 'package:dart_ui/src/gestures/pointer_signal_resolver.dart';
import 'package:dart_ui/src/layout/render_viewport.dart';
import 'package:dart_ui/src/platform/input_events.dart';
import 'package:test/test.dart';

import 'gesture_test_support.dart';

void main() {
  group('one notch, one consumer', () {
    test('the first - innermost - registrant wins', () {
      final hand = Hand();
      final resolver = PointerSignalResolver();
      final log = <String>[];
      final PointerScrollEvent event = hand.scroll(const Offset(0, 40));

      // The hit-test path is offered deepest-first, so this is the order the
      // real router produces.
      resolver.register(event, (PointerScrollEvent e) => log.add('inner'));
      resolver.register(event, (PointerScrollEvent e) => log.add('outer'));
      expect(log, isEmpty, reason: 'nothing runs during dispatch');

      expect(resolver.resolve(event), isTrue);
      expect(log, <String>['inner']);
    });

    test('nothing registered means nothing consumed', () {
      final hand = Hand();
      final resolver = PointerSignalResolver();
      expect(resolver.resolve(hand.scroll(const Offset(0, 40))), isFalse);
    });

    test('each event is a fresh round', () {
      final hand = Hand();
      final resolver = PointerSignalResolver();
      final log = <String>[];

      final PointerScrollEvent first = hand.scroll(const Offset(0, 40));
      resolver.register(first, (PointerScrollEvent e) => log.add('a'));
      resolver.resolve(first);

      hand.advance(const Duration(milliseconds: 16));
      final PointerScrollEvent second = hand.scroll(const Offset(0, 40));
      resolver.register(second, (PointerScrollEvent e) => log.add('b'));
      resolver.resolve(second);

      expect(log, <String>['a', 'b']);
      expect(resolver.hasCandidate, isFalse);
    });

    test('registering for a second event while one is pending is an error', () {
      final hand = Hand();
      final resolver = PointerSignalResolver();
      final PointerScrollEvent first = hand.scroll(const Offset(0, 40));
      resolver.register(first, (PointerScrollEvent e) {});

      expect(
        () => resolver.register(
          hand.scroll(const Offset(0, 40)),
          (PointerScrollEvent e) {},
        ),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('the bug it fixes: nested scrollables', () {
    /// A viewport that acts on the wheel directly, as the controls in this
    /// repository still do today.
    void unarbitrated(ScrollPosition position, PointerScrollEvent event) {
      position.applyScrollDelta(
        event.scrollDelta.dy,
        inLines: event.scrollDeltaUnit == ScrollDeltaUnit.lines,
      );
    }

    test('without a resolver, one notch scrolls both lists', () {
      final hand = Hand();
      final inner = ScrollPosition(viewportExtent: 100, contentExtent: 1000);
      final outer = ScrollPosition(viewportExtent: 200, contentExtent: 2000);
      final PointerScrollEvent event = hand.scroll(const Offset(0, 40));

      unarbitrated(inner, event);
      unarbitrated(outer, event);

      expect(inner.pixels, 40);
      expect(outer.pixels, 40, reason: 'this is the bug');
    });

    test('with a resolver, only the innermost one moves', () {
      final hand = Hand();
      final inner = ScrollPosition(viewportExtent: 100, contentExtent: 1000);
      final outer = ScrollPosition(viewportExtent: 200, contentExtent: 2000);
      final resolver = PointerSignalResolver();
      final PointerScrollEvent event = hand.scroll(const Offset(0, 40));

      resolver.register(
          event, (PointerScrollEvent e) => unarbitrated(inner, e));
      resolver.register(
          event, (PointerScrollEvent e) => unarbitrated(outer, e));
      resolver.resolve(event);

      expect(inner.pixels, 40);
      expect(outer.pixels, 0);
    });

    test('the winner may still chain what it could not consume', () {
      // The resolver decides *who* consumes; ScrollPosition.applyDelta already
      // says *how much* was consumed. Together they give the behaviour every
      // desktop has: an inner list at its end hands the rest outward, and
      // nothing is applied twice.
      final hand = Hand();
      final inner = ScrollPosition(viewportExtent: 100, contentExtent: 130);
      final outer = ScrollPosition(viewportExtent: 200, contentExtent: 2000);
      final resolver = PointerSignalResolver();
      final PointerScrollEvent event = hand.scroll(const Offset(0, 50));

      resolver.register(event, (PointerScrollEvent e) {
        final double leftover = inner.applyScrollDelta(e.scrollDelta.dy);
        if (leftover != 0) outer.applyDelta(leftover);
      });
      resolver.register(
          event, (PointerScrollEvent e) => unarbitrated(outer, e));
      resolver.resolve(event);

      expect(inner.pixels, 30, reason: 'the inner list hit its end');
      expect(outer.pixels, 20, reason: 'and passed on exactly the remainder');
    });

    test('lines are converted by the consumer, not by the resolver', () {
      final hand = Hand();
      final position = ScrollPosition(viewportExtent: 100, contentExtent: 1000);
      final resolver = PointerSignalResolver();
      final PointerScrollEvent event = hand.scroll(
        const Offset(0, 3),
        unit: ScrollDeltaUnit.lines,
      );

      resolver.register(
        event,
        (PointerScrollEvent e) => unarbitrated(position, e),
      );
      resolver.resolve(event);

      expect(position.pixels, 3 * defaultLineExtent);
    });
  });
}
