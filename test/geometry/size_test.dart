import 'package:dart_ui/src/geometry/offset.dart';
import 'package:dart_ui/src/geometry/size.dart';
import 'package:test/test.dart';

void main() {
  group('construction', () {
    test('keeps width and height', () {
      const size = Size(4, 3);

      expect(size.width, 4);
      expect(size.height, 3);
      expect(Size.zero, const Size(0, 0));
    });
  });

  group('isEmpty', () {
    test('is true for a zero extent on either axis', () {
      expect(Size.zero.isEmpty, isTrue);
      expect(const Size(10, 0).isEmpty, isTrue);
      expect(const Size(0, 10).isEmpty, isTrue);
    });

    test('treats a negative extent as empty rather than normalising it', () {
      const negative = Size(-10, 5);

      expect(negative.isEmpty, isTrue);
      expect(negative.width, -10);
    });

    test('is false only when both extents are positive', () {
      expect(const Size(1, 1).isEmpty, isFalse);
    });
  });

  group('contains', () {
    const size = Size(10, 20);

    test('includes the origin and excludes the far corner', () {
      expect(size.contains(Offset.zero), isTrue);
      expect(size.contains(const Offset(10, 20)), isFalse);
    });

    test('is half-open, so tiles never both claim a shared edge', () {
      expect(size.contains(const Offset(9.999, 19.999)), isTrue);
      expect(size.contains(const Offset(10, 5)), isFalse);
      expect(size.contains(const Offset(5, 20)), isFalse);
    });

    test('rejects negative coordinates', () {
      expect(size.contains(const Offset(-0.001, 5)), isFalse);
      expect(size.contains(const Offset(5, -0.001)), isFalse);
    });

    test('an empty size contains nothing', () {
      expect(Size.zero.contains(Offset.zero), isFalse);
    });
  });

  group('aspectRatio', () {
    test('is width over height', () {
      expect(const Size(16, 9).aspectRatio, closeTo(16 / 9, 1e-12));
      expect(const Size(4, 8).aspectRatio, closeTo(0.5, 1e-12));
    });

    test('answers a zero height by sign instead of NaN or an exception', () {
      expect(const Size(10, 0).aspectRatio, double.infinity);
      expect(const Size(-10, 0).aspectRatio, double.negativeInfinity);
      expect(Size.zero.aspectRatio, 0);
    });
  });

  group('operators', () {
    const size = Size(10, 20);

    test('scale both extents', () {
      expect(size * 1.5, const Size(15, 30));
      expect(size / 2, const Size(5, 10));
      expect(size * 3 / 3, size);
    });
  });

  group('lerp', () {
    const a = Size(-421.84126030280987, 187.64886234169697);
    const b = Size(345.05805158219437, -494.74767312335786);

    test('hits both endpoints exactly', () {
      expect(Size.lerp(a, b, 0), a);
      expect(Size.lerp(a, b, 1), b);
    });

    test('interpolates each extent independently', () {
      final middle = Size.lerp(const Size(0, 100), const Size(50, 0), 0.25);

      expect(middle.width, closeTo(12.5, 1e-12));
      expect(middle.height, closeTo(75, 1e-12));
    });
  });

  group('equality', () {
    test('equal sizes agree on hashCode', () {
      const one = Size(1.5, 2.5);
      const other = Size(1.5, 2.5);

      expect(one, other);
      expect(one.hashCode, other.hashCode);
    });

    test('does not equal an Offset with the same components', () {
      expect(const Size(1, 2) == const Size(2, 1), isFalse);
      expect(const Size(1, 2), isNot(const Offset(1, 2)));
    });
  });

  test('toString names the type and both extents', () {
    expect(const Size(1.5, 2).toString(), 'Size(1.5, 2.0)');
  });
}
