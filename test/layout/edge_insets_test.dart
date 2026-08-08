import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

void main() {
  group('EdgeInsets', () {
    test('all, symmetric and only agree with the positional form', () {
      expect(const EdgeInsets.all(4), const EdgeInsets(4, 4, 4, 4));
      expect(
        const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        const EdgeInsets(8, 2, 8, 2),
      );
      expect(
        const EdgeInsets.only(top: 3, right: 5),
        const EdgeInsets(0, 3, 5, 0),
      );
    });

    test('horizontal and vertical are the sums a layout needs', () {
      const insets = EdgeInsets(1, 2, 4, 8);

      expect(insets.horizontal, 5);
      expect(insets.vertical, 10);
      expect(insets.topLeft, const Offset(1, 2));
    });

    test('deflateRect pulls every edge inward', () {
      final result = const EdgeInsets.all(2)
          .deflateRect(const Rect.fromLTRB(10, 10, 30, 30));

      expect(result, const Rect.fromLTRB(12, 12, 28, 28));
    });

    test('deflateRect leaves an inverted rect visible rather than empty', () {
      final result = const EdgeInsets.all(20)
          .deflateRect(const Rect.fromLTRB(0, 0, 10, 10));

      // Rect refuses to normalise, so the evidence of over-inset survives.
      expect(result.isEmpty, isTrue);
      expect(result.width, -30);
    });

    test('inflateSize is what a padding node reports to its parent', () {
      expect(
        const EdgeInsets(1, 2, 3, 4).inflateSize(const Size(10, 10)),
        const Size(14, 16),
      );
    });

    test('deflateSize clamps at zero, unlike deflateRect', () {
      // A size is handed straight to a child as a constraint, and a negative
      // extent there is unsatisfiable rather than diagnostic.
      expect(
        const EdgeInsets.all(20).deflateSize(const Size(10, 10)),
        Size.zero,
      );
    });

    test('negative insets are allowed and push outward', () {
      final result = const EdgeInsets.all(-2)
          .deflateRect(const Rect.fromLTRB(0, 0, 10, 10));

      expect(result, const Rect.fromLTRB(-2, -2, 12, 12));
    });

    test('equality is by value', () {
      expect(const EdgeInsets.all(3) == const EdgeInsets(3, 3, 3, 3), isTrue);
      expect(const EdgeInsets.all(3) == const EdgeInsets(3, 3, 3, 4), isFalse);
      expect(
        const EdgeInsets.all(3).hashCode,
        const EdgeInsets(3, 3, 3, 3).hashCode,
      );
    });
  });

  group('Alignment', () {
    test('the nine constants land on the nine positions', () {
      const child = Size(20, 10);
      const parent = Size(100, 50);

      expect(Alignment.topLeft.offsetFor(child, parent), Offset.zero);
      expect(Alignment.center.offsetFor(child, parent), const Offset(40, 20));
      expect(
        Alignment.bottomRight.offsetFor(child, parent),
        const Offset(80, 40),
      );
      expect(
        Alignment.centerRight.offsetFor(child, parent),
        const Offset(80, 20),
      );
    });

    test('values outside -1..1 extrapolate rather than clamp', () {
      // A slide-in transition is one animated alignment; clamping would make
      // it stick at the edge.
      expect(
        Alignment(-2, 0).offsetFor(const Size(20, 10), const Size(100, 50)),
        const Offset(-40, 20),
      );
    });

    test('inscribe places a box inside a rect', () {
      expect(
        Alignment.center
            .inscribe(const Size(10, 10), const Rect.fromLTRB(0, 0, 50, 50)),
        const Rect.fromLTRB(20, 20, 30, 30),
      );
    });

    test('NaN is refused, because a box at NaN simply disappears', () {
      expect(() => Alignment(double.nan, 0), throwsA(isA<ArgumentError>()));
    });
  });
}
