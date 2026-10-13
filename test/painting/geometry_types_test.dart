/// Radius, RRect and BorderRadius with Flutter's constructors, arithmetic and
/// semantics.
library;

import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

void main() {
  group('Radius', () {
    test('circular, elliptical and zero', () {
      expect(const Radius.circular(4), const Radius.elliptical(4, 4));
      expect(Radius.zero.x, 0);
      expect(const Radius.elliptical(2, 3).y, 3);
      expect(const Radius.circular(2).toString(), 'Radius.circular(2.0)');
      expect(const Radius.elliptical(2, 3).toString(),
          'Radius.elliptical(2.0, 3.0)');
    });

    test('arithmetic', () {
      const Radius a = Radius.elliptical(4, 6);
      const Radius b = Radius.elliptical(1, 2);
      expect(a + b, const Radius.elliptical(5, 8));
      expect(a - b, const Radius.elliptical(3, 4));
      expect(-a, const Radius.elliptical(-4, -6));
      expect(a * 2, const Radius.elliptical(8, 12));
      expect(a / 2, const Radius.elliptical(2, 3));
      expect(a ~/ 4, const Radius.elliptical(1, 1));
      expect(a % 4, const Radius.elliptical(0, 2));
    });

    test('clamp and lerp', () {
      expect(const Radius.elliptical(-1, 9).clamp(minimum: Radius.zero),
          const Radius.elliptical(0, 9));
      expect(const Radius.circular(9).clampValues(maximumX: 4),
          const Radius.elliptical(4, 9));
      expect(Radius.lerp(Radius.zero, const Radius.circular(10), 0.25),
          const Radius.circular(2.5));
      expect(Radius.lerp(null, const Radius.circular(10), 0.5),
          const Radius.circular(5));
      expect(Radius.lerp(null, null, 0.5), isNull);
    });
  });

  group('RRect', () {
    test('constructors agree', () {
      const Rect r = Rect.fromLTRB(0, 0, 20, 10);
      final RRect a = RRect.fromRectAndRadius(r, const Radius.circular(3));
      expect(a, RRect.fromLTRBR(0, 0, 20, 10, const Radius.circular(3)));
      expect(a, const RRect.fromLTRBXY(0, 0, 20, 10, 3, 3));
      expect(a, RRect.fromRectXY(r, 3, 3));
      expect(
          a,
          RRect.fromRectAndCorners(r,
              topLeft: const Radius.circular(3),
              topRight: const Radius.circular(3),
              bottomLeft: const Radius.circular(3),
              bottomRight: const Radius.circular(3)));
      expect(a.outerRect, r);
      expect(a.width, 20);
      expect(a.height, 10);
      expect(a.center, const Offset(10, 5));
      expect(RRect.zero.isEmpty, isTrue);
    });

    test('inflate and deflate move edges and radii, never below zero', () {
      final RRect r = RRect.fromLTRBR(10, 10, 30, 30, const Radius.circular(4));
      final RRect out = r.inflate(2);
      expect(out.outerRect, const Rect.fromLTRB(8, 8, 32, 32));
      expect(out.tlRadius, const Radius.circular(6));
      final RRect inner = r.deflate(5);
      expect(inner.outerRect, const Rect.fromLTRB(15, 15, 25, 25));
      expect(inner.tlRadius, Radius.zero);
      expect(r.shift(const Offset(1, 2)).left, 11);
    });

    test('contains follows the corner arcs', () {
      final RRect r = RRect.fromLTRBR(0, 0, 20, 20, const Radius.circular(6));
      expect(r.contains(const Offset(10, 0.5)), isTrue);
      expect(r.contains(const Offset(0.5, 0.5)), isFalse);
      expect(r.contains(const Offset(1.76, 1.76)), isTrue);
      expect(r.contains(const Offset(1.75, 1.75)), isFalse);
      expect(r.contains(const Offset(20, 10)), isFalse,
          reason: 'right edge is exclusive, as in Flutter');
    });

    test('scaleRadii applies the CSS overrun rule', () {
      final RRect r = RRect.fromLTRBR(0, 0, 20, 10, const Radius.circular(500));
      final RRect s = r.scaleRadii();
      expect(s.tlRadiusX, closeTo(5, 1e-9));
      expect(s.tlRadiusY, closeTo(5, 1e-9));
      expect(r.contains(const Offset(10, 5)), isTrue);
      expect(r.contains(const Offset(0.2, 0.2)), isFalse);
    });

    test('shape predicates', () {
      expect(RRect.fromLTRBR(0, 0, 10, 10, Radius.zero).isRect, isTrue);
      expect(RRect.fromLTRBR(0, 0, 10, 10, const Radius.circular(5)).isCircle,
          isTrue);
      expect(RRect.fromLTRBR(0, 0, 20, 10, const Radius.circular(5)).isStadium,
          isTrue);
      expect(const RRect.fromLTRBXY(0, 0, 20, 10, 10, 5).isEllipse, isTrue);
    });

    test('lerp and toString', () {
      final RRect a = RRect.fromLTRBR(0, 0, 10, 10, Radius.zero);
      final RRect b = RRect.fromLTRBR(10, 10, 30, 30, const Radius.circular(4));
      final RRect mid = RRect.lerp(a, b, 0.5)!;
      expect(mid.outerRect, const Rect.fromLTRB(5, 5, 20, 20));
      expect(mid.tlRadius, const Radius.circular(2));
      expect(b.toString(), 'RRect.fromLTRBR(10.0, 10.0, 30.0, 30.0, 4.0)');
    });
  });

  group('BorderRadius', () {
    test('all, circular, only, vertical, horizontal and zero', () {
      expect(
          BorderRadius.circular(4), const BorderRadius.all(Radius.circular(4)));
      const BorderRadius v = BorderRadius.vertical(top: Radius.circular(3));
      expect(v.topLeft, const Radius.circular(3));
      expect(v.topRight, const Radius.circular(3));
      expect(v.bottomLeft, Radius.zero);
      const BorderRadius h = BorderRadius.horizontal(right: Radius.circular(2));
      expect(h.topRight, const Radius.circular(2));
      expect(h.bottomRight, const Radius.circular(2));
      expect(h.topLeft, Radius.zero);
      const BorderRadius o = BorderRadius.only(bottomLeft: Radius.circular(9));
      expect(o.bottomLeft, const Radius.circular(9));
      expect(o.topLeft, Radius.zero);
      expect(BorderRadius.zero, const BorderRadius.all(Radius.zero));
      expect(BorderRadius.circular(4).copyWith(topLeft: Radius.zero).topLeft,
          Radius.zero);
    });

    test('toRRect puts each corner where it belongs, clamping negatives', () {
      const BorderRadius r = BorderRadius.only(
        topLeft: Radius.circular(1),
        topRight: Radius.circular(2),
        bottomRight: Radius.circular(3),
        bottomLeft: Radius.elliptical(-4, 4),
      );
      final RRect rr = r.toRRect(const Rect.fromLTRB(0, 0, 50, 40));
      expect(rr.tlRadiusX, 1);
      expect(rr.trRadiusX, 2);
      expect(rr.brRadiusX, 3);
      expect(rr.blRadiusX, 0);
      expect(rr.blRadiusY, 4);
    });

    test('arithmetic and lerp', () {
      final BorderRadius a = BorderRadius.circular(4);
      final BorderRadius b = BorderRadius.circular(2);
      expect(a + b, BorderRadius.circular(6));
      expect(a - b, BorderRadius.circular(2));
      expect(a * 2, BorderRadius.circular(8));
      expect(a / 2, BorderRadius.circular(2));
      expect(BorderRadius.lerp(a, b, 0.5), BorderRadius.circular(3));
      expect(BorderRadius.lerp(null, a, 0.5), BorderRadius.circular(2));
    });

    test('directional radii resolve with the reading direction', () {
      const BorderRadiusDirectional d =
          BorderRadiusDirectional.only(topStart: Radius.circular(5));
      expect(d.resolve(TextDirection.leftToRight).topLeft,
          const Radius.circular(5));
      expect(d.resolve(TextDirection.rightToLeft).topRight,
          const Radius.circular(5));
      expect(d.resolve(null).topLeft, const Radius.circular(5),
          reason: 'no direction reads left to right instead of throwing');
      final BorderRadiusGeometry mixed = BorderRadius.circular(1).add(d);
      expect(mixed.resolve(TextDirection.rightToLeft).topRight,
          const Radius.circular(6));
    });
  });
}
