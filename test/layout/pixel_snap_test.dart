/// Pixel snapping - section 25.5.
///
/// The policy lives here as a value type and is applied at the paint boundary;
/// nothing in the layout directory calls it, which is the decision itself. See
/// the library comment of `pixel_snap.dart` for the argument.
library;

import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

void main() {
  group('none', () {
    test('leaves everything exactly where it was', () {
      const snapper = PixelSnapper.none;

      expect(snapper.snapCoordinate(10.4), 10.4);
      expect(snapper.snapExtent(9.2), 9.2);
      expect(snapper.snapBaseline(3.7), 3.7);
      expect(
        snapper.snapRect(const Rect.fromLTRB(10.4, 2.1, 19.6, 8.3)),
        const Rect.fromLTRB(10.4, 2.1, 19.6, 8.3),
      );
      expect(snapper.snapsEdges, isFalse);
      expect(snapper.snapsText, isFalse);
    });
  });

  group('edges', () {
    const snapper = PixelSnapper(policy: PixelSnapPolicy.edges);

    test('rounds a coordinate to the nearest whole pixel', () {
      expect(snapper.snapCoordinate(10.4), 10);
      expect(snapper.snapCoordinate(10.6), 11);
      expect(snapper.snapCoordinate(10.5), 11);
      expect(snapper.snapCoordinate(-10.5), -10);
    });

    test('keeps adjacent boxes adjacent', () {
      // The whole reason snapRect works on edges instead of origin-and-extent.
      // Rounding 10.4 and 9.2 separately would put this box's right edge at 19
      // and the next box's left edge at 20, opening a one-pixel seam.
      final Rect left = snapper.snapRect(const Rect.fromLTWH(10.4, 0, 9.2, 10));
      final Rect right =
          snapper.snapRect(const Rect.fromLTWH(19.6, 0, 9.2, 10));

      expect(left.right, 20);
      expect(right.left, 20);
      expect(left.right, right.left);
      expect(left.width, 10);
      expect(right.width, 9);
    });

    test('a hairline never vanishes', () {
      expect(snapper.snapExtent(0.4), 1);
      expect(snapper.snapExtent(-0.4), -1);
      // A zero that was asked for stays zero.
      expect(snapper.snapExtent(0), 0);
    });

    test('a non-empty rectangle stays non-empty', () {
      final Rect divider =
          snapper.snapRect(const Rect.fromLTWH(4.1, 10.05, 30, 0.4));

      expect(divider.height, 1);
      expect(divider.top, 10);
      expect(divider.bottom, 11);
    });

    test('an empty rectangle stays empty', () {
      final Rect empty =
          snapper.snapRect(const Rect.fromLTRB(4.1, 4.1, 4.1, 4.1));

      expect(empty.width, 0);
      expect(empty.height, 0);
    });

    test('leaves text alone', () {
      expect(snapper.snapBaseline(12.4), 12.4);
      expect(snapper.snapsText, isFalse);
    });

    test('infinities pass through rather than becoming NaN', () {
      expect(snapper.snapCoordinate(double.infinity), double.infinity);
      expect(snapper.snapExtent(double.infinity), double.infinity);
    });
  });

  group('text', () {
    const snapper = PixelSnapper(policy: PixelSnapPolicy.text);

    test('snaps baselines as well as edges', () {
      expect(snapper.snapBaseline(12.4), 12);
      expect(snapper.snapCoordinate(12.4), 12);
      expect(snapper.snapsText, isTrue);
    });
  });

  group('devicePixel', () {
    test('snaps to the display\'s grid, not to the logical one', () {
      const snapper = PixelSnapper(
        policy: PixelSnapPolicy.devicePixel,
        devicePixelRatio: 2,
      );

      expect(snapper.grid, 0.5);
      expect(snapper.snapCoordinate(10.4), 10.5);
      expect(snapper.snapCoordinate(10.2), 10.0);
      expect(snapper.snapExtent(0.1), 0.5);
    });

    test('a fractional ratio keeps the resolution the display has', () {
      const snapper = PixelSnapper(
        policy: PixelSnapPolicy.devicePixel,
        devicePixelRatio: 4,
      );

      expect(snapper.grid, 0.25);
      expect(snapper.snapCoordinate(1.3), 1.25);
    });

    test('a nonsensical ratio falls back to the logical grid', () {
      const snapper = PixelSnapper(
        policy: PixelSnapPolicy.devicePixel,
        devicePixelRatio: 0,
      );

      expect(snapper.grid, 1.0);
      expect(snapper.snapCoordinate(10.4), 10);
    });
  });

  test('two snappers with the same policy and scale are equal', () {
    expect(
      const PixelSnapper(policy: PixelSnapPolicy.edges),
      const PixelSnapper(policy: PixelSnapPolicy.edges),
    );
    expect(
      const PixelSnapper(policy: PixelSnapPolicy.edges),
      isNot(const PixelSnapper(policy: PixelSnapPolicy.text)),
    );
  });
}
