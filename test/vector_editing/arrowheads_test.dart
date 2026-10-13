/// Arrowheads: where they sit on a line's end, and how big.
library;

import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

void main() {
  test('a triangle sits with its base on the end and its point beyond', () {
    // A line arriving at (100, 50) heading right; width 2.
    final Path head =
        ArrowHead.triangle.at(const Offset(100, 50), const Offset(1, 0), 2)!;
    final Rect box = head.bounds;
    expect(box.left, closeTo(100, 1e-6), reason: 'the base on the end');
    expect(box.right, closeTo(108, 1e-6), reason: 'four widths long');
    expect(box.top, closeTo(46, 1e-6), reason: 'four widths across');
    expect(box.bottom, closeTo(54, 1e-6));
  });

  test('it turns with the line', () {
    final Path head =
        ArrowHead.triangle.at(const Offset(0, 0), const Offset(0, -3), 1)!;
    expect(head.bounds.top, closeTo(-4, 1e-6), reason: 'pointing up');
  });

  test('none, an unknown index or no direction draw nothing', () {
    expect(ArrowHead.of(null), ArrowHead.none);
    expect(ArrowHead.of(99), ArrowHead.none);
    expect(ArrowHead.of(1), ArrowHead.triangle);
    expect(ArrowHead.none.at(Offset.zero, const Offset(1, 0), 1), isNull);
    expect(ArrowHead.circle.at(Offset.zero, Offset.zero, 1), isNull);
    for (final ArrowHead head in ArrowHead.values.skip(1)) {
      expect(head.at(Offset.zero, const Offset(1, 1), 1), isNotNull,
          reason: head.name);
    }
  });
}
