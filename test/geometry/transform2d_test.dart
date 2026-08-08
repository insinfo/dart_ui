import 'dart:math' as math;

import 'package:dart_ui/src/geometry/offset.dart';
import 'package:dart_ui/src/geometry/rect.dart';
import 'package:dart_ui/src/geometry/transform2d.dart';
import 'package:test/test.dart';

/// Tight enough to catch a wrong coefficient, loose enough for the cos/sin of
/// a right angle, which is never exactly zero in binary floating point.
const double _epsilon = 1e-12;

void _expectOffset(Offset actual, Offset expected) {
  expect(actual.dx, closeTo(expected.dx, _epsilon));
  expect(actual.dy, closeTo(expected.dy, _epsilon));
}

void _expectRect(Rect actual, Rect expected) {
  expect(actual.left, closeTo(expected.left, _epsilon));
  expect(actual.top, closeTo(expected.top, _epsilon));
  expect(actual.right, closeTo(expected.right, _epsilon));
  expect(actual.bottom, closeTo(expected.bottom, _epsilon));
}

void main() {
  group('constructors', () {
    test('identity leaves points where they are', () {
      const point = Offset(3, -7);

      expect(Transform2D.identity.transformOffset(point), point);
      expect(Transform2D.identity.isIdentity, isTrue);
      expect(Transform2D.identity.isTranslationOnly, isTrue);
    });

    test('translation adds and leaves the linear part alone', () {
      const transform = Transform2D.translation(10, -5);

      expect(
          transform.transformOffset(const Offset(1, 1)), const Offset(11, -4));
      expect(transform.isTranslationOnly, isTrue);
      expect(transform.isIdentity, isFalse);
    });

    test('scaling multiplies each axis independently', () {
      const transform = Transform2D.scaling(2, -3);

      expect(
          transform.transformOffset(const Offset(4, 5)), const Offset(8, -15));
      expect(transform.isTranslationOnly, isFalse);
    });

    test('rotation turns the x axis toward the y axis', () {
      final quarter = Transform2D.rotation(math.pi / 2);

      _expectOffset(
        quarter.transformOffset(const Offset(1, 0)),
        const Offset(0, 1),
      );
      _expectOffset(
        quarter.transformOffset(const Offset(0, 1)),
        const Offset(-1, 0),
      );
    });

    test('rotation preserves length', () {
      final oblique = Transform2D.rotation(0.7);
      final rotated = oblique.transformOffset(const Offset(3, 4));

      expect(rotated.distance, closeTo(5, _epsilon));
    });

    test('compose applies scale, then rotation, then translation', () {
      final composed = Transform2D.compose(
        translation: const Offset(100, 200),
        rotation: math.pi / 2,
        scaleX: 2,
        scaleY: 3,
      );
      final byHand = const Transform2D.translation(100, 200)
          .multiply(Transform2D.rotation(math.pi / 2))
          .multiply(const Transform2D.scaling(2, 3));

      _expectOffset(
        composed.transformOffset(const Offset(1, 1)),
        byHand.transformOffset(const Offset(1, 1)),
      );
      _expectOffset(
        composed.transformOffset(const Offset(1, 1)),
        const Offset(97, 202),
      );
    });

    test('compose with no arguments is the identity', () {
      final composed = Transform2D.compose();

      expect(composed.isIdentity, isTrue);
    });
  });

  group('multiply', () {
    final rotate = Transform2D.rotation(math.pi / 2);
    const translate = Transform2D.translation(10, 0);
    const point = Offset(1, 0);

    test('applies the receiver after the argument', () {
      final combined = translate.multiply(rotate);

      _expectOffset(
        combined.transformOffset(point),
        translate.transformOffset(rotate.transformOffset(point)),
      );
      _expectOffset(combined.transformOffset(point), const Offset(10, 1));
    });

    test('is not commutative, which is what makes the order matter', () {
      final other = rotate.multiply(translate);

      _expectOffset(other.transformOffset(point), const Offset(0, 11));
    });

    test('identity is neutral on both sides', () {
      final scale = Transform2D.compose(rotation: 0.3, scaleX: 2, scaleY: 5);

      expect(scale.multiply(Transform2D.identity), scale);
      expect(Transform2D.identity.multiply(scale), scale);
    });

    test('composed translations add', () {
      const first = Transform2D.translation(3, 4);
      const second = Transform2D.translation(-1, 10);

      expect(first.multiply(second), const Transform2D.translation(2, 14));
    });
  });

  group('transformRect', () {
    const unit = Rect.fromLTRB(-1, -1, 1, 1);

    test('a translation moves the box without growing it', () {
      const transform = Transform2D.translation(10, 20);

      _expectRect(
        transform.transformRect(const Rect.fromLTWH(0, 0, 4, 2)),
        const Rect.fromLTWH(10, 20, 4, 2),
      );
    });

    test('a 45 degree rotation grows the box to the diagonal', () {
      final rotated = Transform2D.rotation(math.pi / 4).transformRect(unit);
      final half = math.sqrt(2);

      _expectRect(rotated, Rect.fromLTRB(-half, -half, half, half));
    });

    test('a 90 degree rotation maps the square onto itself', () {
      final rotated = Transform2D.rotation(math.pi / 2).transformRect(unit);

      _expectRect(rotated, unit);
    });

    test('a negative scale still yields a normalised box', () {
      final flipped = const Transform2D.scaling(
        -2,
        1,
      ).transformRect(const Rect.fromLTWH(1, 0, 3, 1));

      _expectRect(flipped, const Rect.fromLTRB(-8, 0, -2, 1));
      expect(flipped.isEmpty, isFalse);
    });

    test('rotating the bounds twice by 45 degrees grows them twice', () {
      final once = Transform2D.rotation(math.pi / 4).transformRect(unit);
      final twice = Transform2D.rotation(math.pi / 4).transformRect(once);

      expect(twice.width, greaterThan(once.width));
    });
  });

  group('determinant and invert', () {
    test('determinant is the area scale factor', () {
      expect(const Transform2D.scaling(2, 3).determinant, closeTo(6, _epsilon));
      expect(Transform2D.rotation(1.2).determinant, closeTo(1, _epsilon));
      expect(
        const Transform2D.translation(50, 50).determinant,
        closeTo(1, _epsilon),
      );
    });

    test('determinant is negative when the transform mirrors', () {
      expect(const Transform2D.scaling(-2, 3).determinant, closeTo(-6, 1e-12));
    });

    test('the inverse undoes the transform for an arbitrary point', () {
      final transform = Transform2D.compose(
        translation: const Offset(17, -3),
        rotation: 0.9,
        scaleX: 2.5,
        scaleY: 0.5,
      );
      const point = Offset(12, -8);

      final inverse = transform.invert();
      expect(inverse, isNotNull);
      _expectOffset(
        inverse!.transformOffset(transform.transformOffset(point)),
        point,
      );
    });

    test('composing a transform with its inverse gives the identity', () {
      const transform = Transform2D(2, 0.5, -1, 3, 40, 9);
      final inverse = transform.invert()!;
      final combined = transform.multiply(inverse);

      expect(combined.a, closeTo(1, _epsilon));
      expect(combined.b, closeTo(0, _epsilon));
      expect(combined.c, closeTo(0, _epsilon));
      expect(combined.d, closeTo(1, _epsilon));
      expect(combined.tx, closeTo(0, _epsilon));
      expect(combined.ty, closeTo(0, _epsilon));
    });

    test('a collapsed axis is singular and answers null, not an exception', () {
      const flat = Transform2D.scaling(0, 5);

      expect(flat.determinant, 0);
      expect(flat.invert(), isNull);
    });

    test('a transform mapping the plane onto a line is singular', () {
      const degenerate = Transform2D(1, 2, 2, 4, 10, 10);

      expect(degenerate.invert(), isNull);
    });

    test('a non-finite determinant is refused rather than spreading NaN', () {
      const overflowing = Transform2D(double.infinity, 0, 0, 1, 0, 0);

      expect(overflowing.invert(), isNull);
    });

    test('the identity inverts to itself', () {
      expect(Transform2D.identity.invert(), Transform2D.identity);
    });

    test('a near-singular transform still inverts, with large coefficients',
        () {
      const nearlyFlat = Transform2D.scaling(1e-9, 1);
      final inverse = nearlyFlat.invert();

      expect(inverse, isNotNull);
      expect(inverse!.a, closeTo(1e9, 1));
    });
  });

  group('equality', () {
    test('equal transforms agree on hashCode', () {
      const one = Transform2D(1, 2, 3, 4, 5, 6);
      const other = Transform2D(1, 2, 3, 4, 5, 6);

      expect(one, other);
      expect(one.hashCode, other.hashCode);
    });

    test('differs when any single coefficient differs', () {
      const base = Transform2D(1, 2, 3, 4, 5, 6);

      expect(base == const Transform2D(0, 2, 3, 4, 5, 6), isFalse);
      expect(base == const Transform2D(1, 0, 3, 4, 5, 6), isFalse);
      expect(base == const Transform2D(1, 2, 0, 4, 5, 6), isFalse);
      expect(base == const Transform2D(1, 2, 3, 0, 5, 6), isFalse);
      expect(base == const Transform2D(1, 2, 3, 4, 0, 6), isFalse);
      expect(base == const Transform2D(1, 2, 3, 4, 5, 0), isFalse);
    });

    test('a zero rotation equals the identity', () {
      expect(Transform2D.rotation(0), Transform2D.identity);
    });
  });

  test('toString lists the six coefficients in storage order', () {
    expect(
      const Transform2D(1, 2, 3, 4, 5, 6).toString(),
      'Transform2D(1.0, 2.0, 3.0, 4.0, 5.0, 6.0)',
    );
  });
}
