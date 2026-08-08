import 'package:dart_ui/src/geometry/offset.dart';
import 'package:dart_ui/src/geometry/rect.dart';
import 'package:dart_ui/src/geometry/size.dart';
import 'package:test/test.dart';

void main() {
  group('construction', () {
    test('fromLTWH and fromLTRB describe the same rectangle', () {
      const fromEdges = Rect.fromLTRB(10, 20, 40, 60);
      const fromExtent = Rect.fromLTWH(10, 20, 30, 40);

      expect(fromExtent, fromEdges);
      expect(fromExtent.width, 30);
      expect(fromExtent.height, 40);
    });

    test('fromPoints orders the corners itself', () {
      final rect = Rect.fromPoints(const Offset(40, 60), const Offset(10, 20));

      expect(rect, const Rect.fromLTRB(10, 20, 40, 60));
      expect(rect.isEmpty, isFalse);
    });

    test('fromCenter puts the centre back where it was asked for', () {
      final rect = Rect.fromCenter(
        center: const Offset(100, 50),
        width: 20,
        height: 10,
      );

      expect(rect, const Rect.fromLTRB(90, 45, 110, 55));
      expect(rect.center, const Offset(100, 50));
    });

    test('exposes the origin-and-size view', () {
      const rect = Rect.fromLTWH(10, 20, 30, 40);

      expect(rect.topLeft, const Offset(10, 20));
      expect(rect.bottomRight, const Offset(40, 60));
      expect(rect.size, const Size(30, 40));
      expect(rect.center, const Offset(25, 40));
    });
  });

  group('isEmpty', () {
    test('is true for zero extent on either axis', () {
      expect(Rect.zero.isEmpty, isTrue);
      expect(const Rect.fromLTWH(5, 5, 0, 10).isEmpty, isTrue);
      expect(const Rect.fromLTWH(5, 5, 10, 0).isEmpty, isTrue);
    });

    test('reports an inverted rectangle instead of normalising it', () {
      const inverted = Rect.fromLTRB(40, 20, 10, 60);

      expect(inverted.isEmpty, isTrue);
      expect(inverted.width, -30);
    });
  });

  group('contains', () {
    const rect = Rect.fromLTWH(10, 20, 30, 40);

    test('includes the top-left corner and excludes the bottom-right', () {
      expect(rect.contains(const Offset(10, 20)), isTrue);
      expect(rect.contains(const Offset(40, 60)), isFalse);
    });

    test('is half-open, so abutting rectangles tile without overlap', () {
      const right = Rect.fromLTWH(40, 20, 30, 40);
      const onTheSeam = Offset(40, 30);

      expect(rect.contains(onTheSeam), isFalse);
      expect(right.contains(onTheSeam), isTrue);
    });

    test('rejects points outside on every side', () {
      expect(rect.contains(const Offset(9.999, 30)), isFalse);
      expect(rect.contains(const Offset(25, 19.999)), isFalse);
      expect(rect.contains(const Offset(25, 60)), isFalse);
    });

    test('an empty rectangle contains nothing, not even its own corner', () {
      expect(Rect.zero.contains(Offset.zero), isFalse);
    });
  });

  group('intersects', () {
    const rect = Rect.fromLTWH(0, 0, 10, 10);

    test('is true for genuine overlap and symmetric', () {
      const overlapping = Rect.fromLTWH(5, 5, 10, 10);

      expect(rect.intersects(overlapping), isTrue);
      expect(overlapping.intersects(rect), isTrue);
    });

    test('is false for rectangles that only touch along an edge', () {
      expect(rect.intersects(const Rect.fromLTWH(10, 0, 10, 10)), isFalse);
      expect(rect.intersects(const Rect.fromLTWH(0, 10, 10, 10)), isFalse);
    });

    test('is false when disjoint on either axis alone', () {
      expect(rect.intersects(const Rect.fromLTWH(20, 0, 5, 5)), isFalse);
      expect(rect.intersects(const Rect.fromLTWH(0, 20, 5, 5)), isFalse);
    });
  });

  group('intersect', () {
    const rect = Rect.fromLTWH(0, 0, 10, 10);

    test('returns the overlapping area', () {
      final overlap = rect.intersect(const Rect.fromLTWH(5, 5, 10, 10));

      expect(overlap, const Rect.fromLTRB(5, 5, 10, 10));
      expect(overlap.isEmpty, isFalse);
    });

    test('returns the smaller rectangle when one contains the other', () {
      const inner = Rect.fromLTWH(2, 2, 3, 3);

      expect(rect.intersect(inner), inner);
      expect(inner.intersect(rect), inner);
    });

    test('gives an empty rectangle, never null, for disjoint input', () {
      final disjoint = rect.intersect(const Rect.fromLTWH(100, 100, 10, 10));

      expect(disjoint, Rect.zero);
      expect(disjoint.isEmpty, isTrue);
    });

    test('never reports a negative extent, unlike a raw edge crossing', () {
      final disjoint = rect.intersect(const Rect.fromLTWH(100, 100, 10, 10));

      expect(disjoint.width, 0);
      expect(disjoint.height, 0);
    });

    test('an edge-only touch counts as no overlap', () {
      expect(rect.intersect(const Rect.fromLTWH(10, 0, 10, 10)), Rect.zero);
    });
  });

  group('union', () {
    test('encloses both rectangles', () {
      const a = Rect.fromLTWH(0, 0, 10, 10);
      const b = Rect.fromLTWH(20, 5, 10, 10);

      expect(a.union(b), const Rect.fromLTRB(0, 0, 30, 15));
      expect(a.union(b), b.union(a));
    });

    test('skips an empty operand instead of enclosing the origin', () {
      const far = Rect.fromLTWH(100, 100, 10, 10);

      expect(far.union(Rect.zero), far);
      expect(Rect.zero.union(far), far);
    });

    test('an empty intersection does not drag a later union to the origin', () {
      const a = Rect.fromLTWH(100, 100, 10, 10);
      const b = Rect.fromLTWH(200, 200, 10, 10);

      expect(a.union(a.intersect(b)), a);
    });
  });

  group('inflate and deflate', () {
    const rect = Rect.fromLTWH(10, 10, 20, 20);

    test('inflate grows every edge outward', () {
      expect(rect.inflate(5), const Rect.fromLTRB(5, 5, 35, 35));
    });

    test('deflate is the inverse of inflate', () {
      expect(rect.inflate(5).deflate(5), rect);
    });

    test('over-deflating inverts the rectangle and stays visibly empty', () {
      final collapsed = rect.deflate(15);

      expect(collapsed.isEmpty, isTrue);
      expect(collapsed.width, -10);
    });
  });

  group('shift and translate', () {
    const rect = Rect.fromLTWH(10, 10, 20, 20);

    test('move the rectangle without changing its extent', () {
      final moved = rect.shift(const Offset(5, -5));

      expect(moved, const Rect.fromLTWH(15, 5, 20, 20));
      expect(moved.size, rect.size);
    });

    test('shift and translate agree', () {
      expect(rect.shift(const Offset(3, 4)), rect.translate(3, 4));
    });
  });

  group('lerp', () {
    const a = Rect.fromLTRB(
      -421.84126030280987,
      187.64886234169697,
      377.775355923459,
      76.50956665300734,
    );
    const b = Rect.fromLTRB(
      345.05805158219437,
      -494.74767312335786,
      -386.78264193169787,
      -62.498058191091886,
    );

    test('hits both endpoints exactly', () {
      expect(Rect.lerp(a, b, 0), a);
      expect(Rect.lerp(a, b, 1), b);
    });

    test('holds a shared edge fixed while the rest moves', () {
      const from = Rect.fromLTRB(10, 0, 20, 100);
      const to = Rect.fromLTRB(10, 0, 60, 100);
      final middle = Rect.lerp(from, to, 0.5);

      expect(middle.left, 10);
      expect(middle.right, closeTo(40, 1e-12));
    });
  });

  group('equality', () {
    test('equal rectangles agree on hashCode', () {
      const one = Rect.fromLTWH(1, 2, 3, 4);
      const other = Rect.fromLTRB(1, 2, 4, 6);

      expect(one, other);
      expect(one.hashCode, other.hashCode);
    });

    test('differs when any edge differs', () {
      const rect = Rect.fromLTRB(1, 2, 3, 4);

      expect(rect == const Rect.fromLTRB(0, 2, 3, 4), isFalse);
      expect(rect == const Rect.fromLTRB(1, 0, 3, 4), isFalse);
      expect(rect == const Rect.fromLTRB(1, 2, 0, 4), isFalse);
      expect(rect == const Rect.fromLTRB(1, 2, 3, 0), isFalse);
    });

    test('two differently shaped empty rectangles are not interchangeable', () {
      expect(const Rect.fromLTWH(5, 5, 0, 0) == Rect.zero, isFalse);
    });
  });

  test('toString names the edges, matching the constructor', () {
    expect(
      const Rect.fromLTWH(1, 2, 3, 4).toString(),
      'Rect.fromLTRB(1.0, 2.0, 4.0, 6.0)',
    );
  });
}
