/// The planner on its own: no widgets, no render tree, no clock.
///
/// `test/widgets/list_box_test.dart` already pins the behaviour this file's
/// subject had when it lived inside `list_box.dart`, and those tests were not
/// touched by the extraction. What is here is what the extraction *added*:
/// measured extents, the laziness of the position cache, and the costs both of
/// those are claimed to have.
library;

import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

void main() {
  group('uniform extents', () {
    test('cost nothing to keep: no position cache exists at all', () {
      final virtualization = ListVirtualization(
        itemCount: 100000,
        estimatedExtent: 20,
      );

      expect(virtualization.hasVariableExtents, isFalse);
      expect(virtualization.totalExtent, 2000000);
      expect(virtualization.offsetOf(99999), 1999980);
      expect(virtualization.indexAt(1999980), 99999);
      // Nothing was summed because there is nothing to sum: every answer above
      // was one multiply or one divide.
      expect(virtualization.summedThrough, 100000);
    });

    test('refuse a measurement rather than silently dropping it', () {
      final virtualization =
          ListVirtualization(itemCount: 4, estimatedExtent: 20);

      expect(() => virtualization.setExtent(1, 30), throwsStateError);
    });
  });

  group('variable extents', () {
    test('the position cache is filled only as far as it is asked', () {
      final virtualization = ListVirtualization.estimated(
        itemCount: 100000,
        estimatedExtent: 20,
      );

      expect(virtualization.summedThrough, 0);
      // The whole list has a length before anything is summed, which is what
      // gives a hundred-thousand-item list a scrollbar on its first frame.
      expect(virtualization.totalExtent, 2000000);
      expect(virtualization.summedThrough, 0);

      final RealizedRange range = virtualization.rangeFor(
        scrollOffset: 0,
        viewportExtent: 100,
      );

      expect(range.firstVisible, 0);
      expect(range.lastVisible, 5);
      // Six visible items cost six summed positions, not a hundred thousand.
      expect(virtualization.summedThrough, lessThan(10));
    });

    test('a measurement moves everything after it and nothing before it', () {
      final virtualization = ListVirtualization.estimated(
        itemCount: 10,
        estimatedExtent: 20,
      );
      // Sum the whole thing first, so the invalidation below has something to
      // throw away and the test is not passing by never having cached.
      expect(virtualization.offsetOf(10), 200);
      expect(virtualization.summedThrough, 10);

      expect(virtualization.setExtent(2, 50), isTrue);
      expect(virtualization.setExtent(2, 50), isFalse, reason: 'no change');

      expect(virtualization.summedThrough, 2, reason: 'the suffix was dropped');
      expect(virtualization.offsetOf(2), 40, reason: 'the prefix is untouched');
      expect(virtualization.offsetOf(3), 90);
      expect(virtualization.totalExtent, 230);
      // Re-summed only up to the index that was asked for.
      expect(virtualization.summedThrough, 3);
    });

    test('the visible window is not offset / itemExtent', () {
      // Ten items alternating 10 and 30 px. Every uniform-extent shortcut gives
      // a different - wrong - answer on this list, which is the point of it.
      final virtualization = ListVirtualization(
        itemCount: 10,
        estimatedExtent: 20,
        extents: <double>[
          for (int i = 0; i < 10; i++) i.isEven ? 10.0 : 30.0,
        ],
      );

      expect(virtualization.totalExtent, 200);
      expect(virtualization.offsetOf(3), 50);
      expect(50 ~/ 20, 2, reason: 'the uniform answer, and it is wrong');
      expect(virtualization.indexAt(50), 3);

      final RealizedRange range = virtualization.rangeFor(
        scrollOffset: 50,
        viewportExtent: 100,
      );
      // Item 7 starts at 130 and so is the last one the 50..150 window touches;
      // a uniform list would have said 2..7 for the same offsets.
      expect(range.firstVisible, 3);
      expect(range.lastVisible, 7);
    });

    test('a total survives a hundred measurements without drifting', () {
      final virtualization = ListVirtualization.estimated(
        itemCount: 100,
        estimatedExtent: 20,
      );
      for (int i = 0; i < 100; i++) {
        virtualization.setExtent(i, 25);
      }

      expect(virtualization.totalExtent, closeTo(2500, 1e-9));
      expect(virtualization.offsetOf(100), closeTo(2500, 1e-9));
    });

    test('an out-of-range measurement is an error, not a resize', () {
      final virtualization = ListVirtualization.estimated(
        itemCount: 3,
        estimatedExtent: 20,
      );

      expect(() => virtualization.setExtent(3, 10), throwsRangeError);
    });
  });

  group('the window', () {
    test('a cache extent widens it symmetrically, in pixels', () {
      final virtualization = ListVirtualization(
        itemCount: 1000,
        estimatedExtent: 20,
        cacheExtent: 60,
      );

      final RealizedRange range = virtualization.rangeFor(
        scrollOffset: 200,
        viewportExtent: 100,
      );

      expect(range.firstVisible, 10);
      expect(range.lastVisible, 15);
      expect(range.firstRealized, 7, reason: '60px is three 20px items');
      expect(range.lastRealized, 18);
      expect(range.leadingExtent, 140);
      expect(range.realizedCount, 12);
      expect(range.contains(9), isTrue);
      expect(range.contains(19), isFalse);
    });
  });
}
