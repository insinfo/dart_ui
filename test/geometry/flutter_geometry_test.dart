/// The parts of Flutter's `dart:ui` geometry (`Offset`, `Size`, `Rect`) that
/// app code reaches for, with the values Flutter's own engine gives.
library;

import 'dart:math' as math;

import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

void main() {
  group('Offset', () {
    test('fromDirection and direction', () {
      final Offset o = Offset.fromDirection(math.pi / 2, 10);
      expect(o.dx, closeTo(0, 1e-12));
      expect(o.dy, closeTo(10, 1e-12));
      expect(o.direction, closeTo(math.pi / 2, 1e-12));
      expect(Offset.fromDirection(0).dx, 1);
    });

    test('& makes a Rect, scale and translate', () {
      expect(const Offset(10, 20) & const Size(30, 40),
          const Rect.fromLTWH(10, 20, 30, 40));
      expect(const Offset(2, 3).scale(2, 10), const Offset(4, 30));
      expect(const Offset(2, 3).translate(1, -1), const Offset(3, 2));
      expect(const Offset(7, 9) ~/ 2, const Offset(3, 4));
      expect(const Offset(7, 9) % 4, const Offset(3, 1));
    });

    test('distanceSquared, infinite and finiteness', () {
      expect(const Offset(3, 4).distanceSquared, 25);
      expect(Offset.infinite.isInfinite, isTrue);
      expect(Offset.infinite.isFinite, isFalse);
      expect(const Offset(double.nan, 0).isFinite, isFalse);
      expect(const Offset(1, 2).isFinite, isTrue);
    });

    test('component-wise comparison, against an Offset or a Size', () {
      expect(const Offset(1, 1) < const Offset(2, 2), isTrue);
      expect(const Offset(1, 3) < const Offset(2, 2), isFalse);
      expect(const Offset(2, 2) <= const Offset(2, 2), isTrue);
      expect(const Offset(3, 3) > const Size(2, 2), isTrue);
      expect(const Offset(2, 2) >= const Size(2, 3), isFalse);
    });

    test('lerp takes nulls as Flutter does', () {
      expect(Offset.lerp(null, null, 0.5), isNull);
      expect(
          Offset.lerp(const Offset(10, 20), null, 0.25), const Offset(7.5, 15));
      expect(
          Offset.lerp(null, const Offset(10, 20), 0.25), const Offset(2.5, 5));
    });
  });

  group('Size', () {
    test('Flutter constructors', () {
      expect(const Size.square(5), const Size(5, 5));
      expect(const Size.fromWidth(5), const Size(5, double.infinity));
      expect(const Size.fromHeight(5), const Size(double.infinity, 5));
      expect(const Size.fromRadius(5), const Size(10, 10));
      expect(Size.copy(const Size(1, 2)), const Size(1, 2));
      expect(Size.infinite.isInfinite, isTrue);
    });

    test('sides, aspect ratio and flipped', () {
      const Size size = Size(-30, 20);
      expect(size.shortestSide, 20);
      expect(size.longestSide, 30);
      expect(const Size(30, 20).aspectRatio, 1.5);
      expect(const Size(3, 0).aspectRatio, double.infinity);
      expect(const Size(30, 20).flipped, const Size(20, 30));
    });

    test('anchors relative to an origin', () {
      const Size size = Size(100, 50);
      const Offset origin = Offset(10, 20);
      expect(size.topLeft(origin), origin);
      expect(size.topCenter(origin), const Offset(60, 20));
      expect(size.topRight(origin), const Offset(110, 20));
      expect(size.centerLeft(origin), const Offset(10, 45));
      expect(size.center(origin), const Offset(60, 45));
      expect(size.centerRight(origin), const Offset(110, 45));
      expect(size.bottomLeft(origin), const Offset(10, 70));
      expect(size.bottomCenter(origin), const Offset(60, 70));
      expect(size.bottomRight(origin), const Offset(110, 70));
    });

    test('arithmetic: Size - Size is an Offset, Size - Offset a Size', () {
      expect(const Size(10, 20) - const Size(4, 5), const Offset(6, 15));
      expect(const Size(10, 20) - const Offset(4, 5), const Size(6, 15));
      expect(const Size(10, 20) + const Offset(1, 2), const Size(11, 22));
      expect(const Size(7, 9) ~/ 2, const Size(3, 4));
      expect(const Size(7, 9) % 4, const Size(3, 1));
      expect(const Size(2, 2) < const Size(3, 3), isTrue);
    });

    test('lerp takes nulls as Flutter does', () {
      expect(Size.lerp(null, null, 0.5), isNull);
      expect(Size.lerp(const Size(10, 20), null, 0.5), const Size(5, 10));
      expect(Size.lerp(null, const Size(10, 20), 0.5), const Size(5, 10));
    });
  });

  group('Rect', () {
    test('fromCircle, fromCenter and fromPoints', () {
      expect(Rect.fromCircle(center: const Offset(10, 10), radius: 5),
          const Rect.fromLTRB(5, 5, 15, 15));
      expect(Rect.fromCenter(center: const Offset(10, 10), width: 4, height: 2),
          const Rect.fromLTRB(8, 9, 12, 11));
      expect(Rect.fromPoints(const Offset(10, 0), const Offset(0, 10)),
          const Rect.fromLTRB(0, 0, 10, 10));
    });

    test('the nine anchors and the sides', () {
      const Rect r = Rect.fromLTRB(10, 20, 110, 70);
      expect(r.topLeft, const Offset(10, 20));
      expect(r.topCenter, const Offset(60, 20));
      expect(r.topRight, const Offset(110, 20));
      expect(r.centerLeft, const Offset(10, 45));
      expect(r.center, const Offset(60, 45));
      expect(r.centerRight, const Offset(110, 45));
      expect(r.bottomLeft, const Offset(10, 70));
      expect(r.bottomCenter, const Offset(60, 70));
      expect(r.bottomRight, const Offset(110, 70));
      expect(r.shortestSide, 50);
      expect(r.longestSide, 100);
    });

    test('overlaps, intersect and expandToInclude', () {
      const Rect a = Rect.fromLTRB(0, 0, 10, 10);
      const Rect b = Rect.fromLTRB(5, 5, 15, 15);
      const Rect c = Rect.fromLTRB(10, 0, 20, 10);
      expect(a.overlaps(b), isTrue);
      // Touching edges share no area, as in Flutter.
      expect(a.overlaps(c), isFalse);
      expect(a.intersect(b), const Rect.fromLTRB(5, 5, 10, 10));
      expect(a.expandToInclude(b), const Rect.fromLTRB(0, 0, 15, 15));
      // Unlike union, an empty operand still counts.
      expect(a.expandToInclude(const Rect.fromLTRB(20, 20, 20, 20)),
          const Rect.fromLTRB(0, 0, 20, 20));
    });

    test('inflate, deflate, shift and translate', () {
      const Rect r = Rect.fromLTRB(10, 10, 20, 20);
      expect(r.inflate(2), const Rect.fromLTRB(8, 8, 22, 22));
      expect(r.deflate(2), const Rect.fromLTRB(12, 12, 18, 18));
      expect(r.shift(const Offset(1, 2)), const Rect.fromLTRB(11, 12, 21, 22));
      expect(r.translate(-1, -2), const Rect.fromLTRB(9, 8, 19, 18));
    });

    test('finiteness, NaN and largest', () {
      expect(Rect.largest.isFinite, isTrue);
      expect(Rect.largest.contains(const Offset(1e8, -1e8)), isTrue);
      expect(const Rect.fromLTRB(0, 0, double.infinity, 1).isInfinite, isTrue);
      expect(const Rect.fromLTRB(0, double.nan, 1, 1).hasNaN, isTrue);
    });

    test('lerp takes nulls as Flutter does', () {
      expect(Rect.lerp(null, null, 0.5), isNull);
      expect(Rect.lerp(const Rect.fromLTRB(10, 10, 20, 20), null, 0.5),
          const Rect.fromLTRB(5, 5, 10, 10));
      expect(Rect.lerp(null, const Rect.fromLTRB(10, 10, 20, 20), 0.5),
          const Rect.fromLTRB(5, 5, 10, 10));
    });
  });
}
