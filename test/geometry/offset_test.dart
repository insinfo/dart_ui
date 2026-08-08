import 'package:dart_ui/src/geometry/offset.dart';
import 'package:test/test.dart';

void main() {
  group('construction', () {
    test('keeps the components it was given', () {
      const offset = Offset(3, -4);

      expect(offset.dx, 3);
      expect(offset.dy, -4);
    });

    test('zero is the additive identity', () {
      const offset = Offset(3, -4);

      expect(Offset.zero, const Offset(0, 0));
      expect(offset + Offset.zero, offset);
      expect(offset - Offset.zero, offset);
    });
  });

  group('operators', () {
    const a = Offset(3, -4);
    const b = Offset(1, 2);

    test('add and subtract are componentwise and inverse', () {
      expect(a + b, const Offset(4, -2));
      expect(a - b, const Offset(2, -6));
      expect(a + b - b, a);
    });

    test('negation flips both components', () {
      expect(-a, const Offset(-3, 4));
      expect(a + -a, Offset.zero);
    });

    test('scaling by a factor and its reciprocal round trips', () {
      expect(a * 2, const Offset(6, -8));
      expect(a / 2, const Offset(1.5, -2));
      expect(a * 4 / 4, a);
    });

    test('dividing by zero yields infinities rather than throwing', () {
      final divided = const Offset(1, -1) / 0;

      expect(divided.dx, double.infinity);
      expect(divided.dy, double.negativeInfinity);
    });
  });

  group('distance', () {
    test('measures the hypotenuse from the origin', () {
      expect(const Offset(3, -4).distance, 5);
      expect(const Offset(3, -4).distanceSquared, 25);
    });

    test('distanceSquared orders magnitudes the same way distance does', () {
      const near = Offset(1, 2);
      const far = Offset(3, 1);

      expect(near.distanceSquared < far.distanceSquared, isTrue);
      expect(near.distance < far.distance, isTrue);
    });
  });

  group('lerp', () {
    // Values chosen because the shorter `a + (b - a) * t` form lands one ulp
    // short of `b` for them: the endpoint assertion below would fail.
    const a = Offset(-421.84126030280987, 187.64886234169697);
    const b = Offset(345.05805158219437, -494.74767312335786);

    test('hits both endpoints exactly', () {
      expect(Offset.lerp(a, b, 0), a);
      expect(Offset.lerp(a, b, 1), b);
    });

    test('halfway is the midpoint', () {
      final middle = Offset.lerp(const Offset(0, 10), const Offset(10, 20), .5);

      expect(middle.dx, closeTo(5, 1e-12));
      expect(middle.dy, closeTo(15, 1e-12));
    });

    test('extrapolates past the endpoints, for overshooting curves', () {
      final beyond = Offset.lerp(Offset.zero, const Offset(10, -10), 1.5);

      expect(beyond.dx, closeTo(15, 1e-12));
      expect(beyond.dy, closeTo(-15, 1e-12));
    });
  });

  group('equality', () {
    test('equal offsets agree on hashCode', () {
      const one = Offset(1.5, 2.5);
      const other = Offset(1.5, 2.5);

      expect(one, other);
      expect(one.hashCode, other.hashCode);
    });

    test('differs when either component differs', () {
      expect(const Offset(1, 2) == const Offset(1, 3), isFalse);
      expect(const Offset(1, 2) == const Offset(2, 2), isFalse);
      expect(const Offset(1, 2) == Object(), isFalse);
    });

    test('follows IEEE-754: -0.0 equals 0.0, and so must their hashes', () {
      const negativeZero = Offset(-0.0, -0.0);

      expect(negativeZero, Offset.zero);
      expect(negativeZero.hashCode, Offset.zero.hashCode);
    });

    test('an offset holding NaN is not equal to itself', () {
      const notANumber = Offset(double.nan, 0);

      expect(notANumber == notANumber, isFalse);
    });
  });

  test('toString names the type and both components', () {
    expect(const Offset(1.5, -2).toString(), 'Offset(1.5, -2.0)');
  });
}
