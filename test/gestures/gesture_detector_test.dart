import 'package:dart_ui/src/geometry/offset.dart';
import 'package:dart_ui/src/geometry/size.dart';
import 'package:dart_ui/src/gestures/binding.dart';
import 'package:dart_ui/src/gestures/drag.dart';
import 'package:dart_ui/src/gestures/tap.dart';
import 'package:dart_ui/src/layout/box_constraints.dart';
import 'package:dart_ui/src/layout/pipeline.dart';
import 'package:dart_ui/src/layout/render_box.dart';
import 'package:dart_ui/src/layout/render_colored_box.dart';
import 'package:dart_ui/src/layout/render_constrained_box.dart';
import 'package:dart_ui/src/platform/input_events.dart';
import 'package:dart_ui/src/widgets/gesture_detector.dart';
import 'package:dart_ui/src/widgets/pointer_router.dart';
import 'package:test/test.dart';

import 'gesture_test_support.dart';

/// A tree of one detector wrapping a coloured box, wired to a real router.
///
/// This is the integration the recognizers cannot test on their own: the
/// router is what closes the arena after a press, sweeps it after a release
/// and cancels it when the pointer is taken away, and it is what publishes the
/// binding a detector built with no arena of its own will find.
({PointerRouter router, RenderGestureDetector detector}) mountDetector({
  Size size = const Size(100, 100),
  GestureHitTestBehavior behavior = GestureHitTestBehavior.deferToChild,
  RenderGestureDetector? outer,
}) {
  final detector = RenderGestureDetector(
    behavior: behavior,
    child: RenderConstrainedBox(
      additionalConstraints: BoxConstraints.tight(size),
      child: RenderColoredBox(color: 0xFF000000),
    ),
  );
  final RenderBox root = outer == null ? detector : (outer..child = detector);
  final owner = PipelineOwner(
    rootConstraints: BoxConstraints.tight(const Size(400, 400)),
  )..root = root;
  owner.flushLayout();
  return (router: PointerRouter(), detector: detector);
}

void main() {
  group('a detector in a real tree', () {
    test('a press and a release on it is a tap', () {
      final hand = Hand();
      final mounted = mountDetector();
      var taps = 0;
      mounted.detector.configure(onTap: () => taps++);

      expect(
        mounted.router.route(
          hand.down(const Offset(50, 50)),
          root: mounted.detector,
        ),
        isTrue,
      );
      expect(taps, 0, reason: 'a tap is a press and a release');

      hand.advance(const Duration(milliseconds: 30));
      mounted.router.route(
        hand.up(const Offset(50, 50)),
        root: mounted.detector,
      );

      expect(taps, 1);
      expect(mounted.router.gestureArena.openArenaCount, 0);
    });

    test('the router publishes its own arena to the recognizers', () {
      // A detector built with no arena of its own must land in the arena of
      // the window whose router delivered the event, not in a global one.
      final hand = Hand();
      final mounted = mountDetector();
      mounted.detector.configure(onTap: () {});

      mounted.router.route(
        hand.down(const Offset(50, 50)),
        root: mounted.detector,
      );
      // Resolved by walkover the moment the router closed the arena.
      expect(mounted.router.gestureArena.openArenaCount, 0);
      expect(GestureBinding.current, isNull, reason: 'ambient only in flight');
    });

    test('a release outside the bounds is not a tap', () {
      final hand = Hand();
      final mounted = mountDetector();
      var taps = 0;
      mounted.detector.configure(onTap: () => taps++);

      mounted.router.route(
        hand.down(const Offset(50, 50)),
        root: mounted.detector,
      );
      // The press captured the pointer, so this still reaches the detector.
      mounted.router.route(
        hand.up(const Offset(450, 50)),
        root: mounted.detector,
      );

      expect(taps, 0);
      expect(mounted.router.gestureArena.openArenaCount, 0);
    });

    test('a cancelled pointer resolves the arena rather than leaking it', () {
      final hand = Hand();
      final mounted = mountDetector();
      final log = <String>[];
      mounted.detector.configure(
        onTap: () => log.add('tap'),
        onTapCancel: () => log.add('cancel'),
        onVerticalDragStart: (DragStartDetails d) => log.add('drag'),
      );

      mounted.router.route(
        hand.down(const Offset(50, 50)),
        root: mounted.detector,
      );
      expect(mounted.router.gestureArena.openArenaCount, 1);

      mounted.router.route(
        hand.cancel(const Offset(50, 50)),
        root: mounted.detector,
      );

      expect(log, isEmpty, reason: 'nothing was reported, so nothing cancels');
      expect(
        mounted.router.gestureArena.openArenaCount,
        0,
        reason: 'an arena left pending swallows the next press on this pointer',
      );

      // And the next press is unaffected.
      hand.advance(const Duration(milliseconds: 200));
      mounted.router.route(
        hand.down(const Offset(50, 50)),
        root: mounted.detector,
      );
      mounted.router.route(
        hand.up(const Offset(50, 50)),
        root: mounted.detector,
      );
      expect(log, <String>['tap']);
    });

    test('detaching the render object takes its recognizers out of the arena',
        () {
      final hand = Hand();
      final mounted = mountDetector();
      mounted.detector.configure(
        onTap: () {},
        onVerticalDragStart: (DragStartDetails d) {},
      );

      mounted.router.route(
        hand.down(const Offset(50, 50)),
        root: mounted.detector,
      );
      expect(mounted.router.gestureArena.openArenaCount, 1);

      mounted.detector.detach();
      expect(mounted.router.gestureArena.openArenaCount, 0);
    });

    test('an opaque detector is hittable where its child is not', () {
      final hand = Hand();
      final transparent = RenderGestureDetector(
        behavior: GestureHitTestBehavior.opaque,
      );
      PipelineOwner(
        rootConstraints: BoxConstraints.tight(const Size(100, 100)),
      )
        ..root = transparent
        ..flushLayout();
      var taps = 0;
      transparent.configure(onTap: () => taps++);

      final router = PointerRouter();
      router.route(hand.down(const Offset(20, 20)), root: transparent);
      router.route(hand.up(const Offset(20, 20)), root: transparent);

      expect(taps, 1);
    });

    test('a deferToChild detector with no child invents no hit region', () {
      final hand = Hand();
      final empty = RenderGestureDetector();
      PipelineOwner(
        rootConstraints: BoxConstraints.tight(const Size(100, 100)),
      )
        ..root = empty
        ..flushLayout();
      var taps = 0;
      empty.configure(onTap: () => taps++);

      final router = PointerRouter();
      expect(
        router.route(hand.down(const Offset(20, 20)), root: empty),
        isFalse,
      );
      router.route(hand.up(const Offset(20, 20)), root: empty);
      expect(taps, 0);
    });
  });

  group('two detectors, one inside the other', () {
    ({
      PointerRouter router,
      RenderGestureDetector inner,
      RenderGestureDetector outer,
    }) mountNested() {
      final inner = RenderGestureDetector(
        child: RenderConstrainedBox(
          additionalConstraints: BoxConstraints.tight(const Size(100, 100)),
          child: RenderColoredBox(color: 0xFF000000),
        ),
      );
      final outer = RenderGestureDetector(child: inner);
      PipelineOwner(
        rootConstraints: BoxConstraints.tight(const Size(400, 400)),
      )
        ..root = outer
        ..flushLayout();
      return (router: PointerRouter(), inner: inner, outer: outer);
    }

    test('the inner one wins a plain tap', () {
      // The hit-test path is deepest-first, so the inner detector's tap joins
      // the arena first and the sweep awards the first member.
      final hand = Hand();
      final tree = mountNested();
      final log = <String>[];
      tree.inner.configure(onTap: () => log.add('inner'));
      tree.outer.configure(onTap: () => log.add('outer'));

      tree.router.route(hand.down(const Offset(50, 50)), root: tree.outer);
      hand.advance(const Duration(milliseconds: 20));
      tree.router.route(hand.up(const Offset(50, 50)), root: tree.outer);

      expect(log, <String>['inner']);
      expect(tree.router.gestureArena.openArenaCount, 0);
    });

    test('but not always: an outer drag past the slop takes it', () {
      // Position is only the tie-break. The outer recognizer has evidence the
      // inner one does not, and evidence wins - which is exactly the rule that
      // lets a button live inside a scrollable list.
      final hand = Hand(kind: PointerKind.touch);
      final tree = mountNested();
      final log = <String>[];
      tree.inner.configure(
        onTap: () => log.add('tap'),
        onTapCancel: () => log.add('tapCancel'),
      );
      tree.outer.configure(
        onVerticalDragStart: (DragStartDetails d) => log.add('dragStart'),
        onVerticalDragEnd: (DragEndDetails d) => log.add('dragEnd'),
      );

      tree.router.route(hand.down(const Offset(50, 50)), root: tree.outer);
      hand.advance(const Duration(milliseconds: 16));
      tree.router.route(hand.move(const Offset(50, 90)), root: tree.outer);
      hand.advance(const Duration(milliseconds: 16));
      tree.router.route(hand.up(const Offset(50, 130)), root: tree.outer);

      expect(log, <String>['dragStart', 'dragEnd']);
      expect(tree.router.gestureArena.openArenaCount, 0);
    });

    test('a press that never leaves the slop still goes to the inner tap', () {
      final hand = Hand(kind: PointerKind.touch);
      final tree = mountNested();
      final log = <String>[];
      tree.inner.configure(onTap: () => log.add('tap'));
      tree.outer.configure(
        onVerticalDragStart: (DragStartDetails d) => log.add('dragStart'),
      );

      tree.router.route(hand.down(const Offset(50, 50)), root: tree.outer);
      hand.advance(const Duration(milliseconds: 16));
      tree.router.route(hand.move(const Offset(50, 60)), root: tree.outer);
      hand.advance(const Duration(milliseconds: 16));
      tree.router.route(hand.up(const Offset(50, 60)), root: tree.outer);

      expect(log, <String>['tap']);
    });
  });

  group('configuration', () {
    test('a recognizer is built only for the callbacks that are set', () {
      final mounted = mountDetector();
      expect(mounted.detector.recognizers, isEmpty);

      mounted.detector.configure(onTap: () {});
      expect(mounted.detector.recognizers.single, isA<TapGestureRecognizer>());

      mounted.detector.configure(
        onTap: () {},
        onPanUpdate: (DragUpdateDetails d) {},
      );
      expect(mounted.detector.recognizers.length, 2);

      mounted.detector.configure();
      expect(mounted.detector.recognizers, isEmpty);
    });

    test('reconfiguring mid-gesture keeps the recognizer, and the gesture', () {
      final hand = Hand(kind: PointerKind.touch);
      final mounted = mountDetector();
      final log = <String>[];
      mounted.detector.configure(
        onVerticalDragStart: (DragStartDetails d) => log.add('start'),
        onVerticalDragUpdate: (DragUpdateDetails d) => log.add('update'),
      );
      final Object recognizer = mounted.detector.recognizers.single;

      mounted.router.route(
        hand.down(const Offset(50, 50)),
        root: mounted.detector,
      );
      hand.advance(const Duration(milliseconds: 16));
      mounted.router.route(
        hand.move(const Offset(50, 90)),
        root: mounted.detector,
      );

      // A rebuild in the middle of the drag, as a setState would produce.
      mounted.detector.configure(
        onVerticalDragStart: (DragStartDetails d) => log.add('start2'),
        onVerticalDragUpdate: (DragUpdateDetails d) => log.add('update2'),
      );
      expect(
          identical(mounted.detector.recognizers.single, recognizer), isTrue);

      hand.advance(const Duration(milliseconds: 16));
      mounted.router.route(
        hand.move(const Offset(50, 120)),
        root: mounted.detector,
      );

      expect(log, <String>['start', 'update2']);
    });

    test('a long press without a dispatcher is refused, loudly', () {
      final mounted = mountDetector();
      expect(
        () => mounted.detector.configure(onLongPress: () {}),
        throwsA(isA<StateError>()),
      );
    });

    test('a long press with a dispatcher fires on the virtual clock', () {
      final hand = Hand(kind: PointerKind.touch);
      final mounted = mountDetector();
      mounted.detector.dispatcher = hand.dispatcher;
      var fired = 0;
      mounted.detector.configure(onLongPress: () => fired++);

      mounted.router.route(
        hand.down(const Offset(50, 50)),
        root: mounted.detector,
      );
      hand.advance(const Duration(milliseconds: 499));
      expect(fired, 0);
      hand.advance(const Duration(milliseconds: 1));
      expect(fired, 1);
    });
  });
}
