import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

void main() {
  group('Bézier Operations and Geometry Tests', () {
    test('evaluateCubic computes points on standard cubic curve', () {
      const p0 = Offset(0, 0);
      const p1 = Offset(0, 100);
      const p2 = Offset(100, 100);
      const p3 = Offset(100, 0);

      final start = evaluateCubic(p0, p1, p2, p3, 0.0);
      expect(start.dx, closeTo(0.0, 1e-6));
      expect(start.dy, closeTo(0.0, 1e-6));

      final mid = evaluateCubic(p0, p1, p2, p3, 0.5);
      expect(mid.dx, closeTo(50.0, 1e-6));
      expect(mid.dy, closeTo(75.0, 1e-6));

      final end = evaluateCubic(p0, p1, p2, p3, 1.0);
      expect(end.dx, closeTo(100.0, 1e-6));
      expect(end.dy, closeTo(0.0, 1e-6));
    });

    test('splitCubic (De Casteljau) halves curve accurately at t=0.5', () {
      const p0 = Offset(0, 0);
      const p1 = Offset(0, 100);
      const p2 = Offset(100, 100);
      const p3 = Offset(100, 0);

      final (left, right) = splitCubic(p0, p1, p2, p3, 0.5);

      // Left starts at p0, right ends at p3
      expect(left[0], equals(p0));
      expect(right[3], equals(p3));
      // Junction point equals evaluateCubic at t=0.5
      expect(left[3], equals(right[0]));
      expect(left[3].dx, closeTo(50.0, 1e-6));
      expect(left[3].dy, closeTo(75.0, 1e-6));
    });

    test('cubicTightBounds finds exact extrema', () {
      const p0 = Offset(0, 0);
      const p1 = Offset(0, 100);
      const p2 = Offset(100, 100);
      const p3 = Offset(100, 0);

      final bounds = cubicTightBounds(p0, p1, p2, p3);
      expect(bounds.left, closeTo(0.0, 1e-6));
      expect(bounds.right, closeTo(100.0, 1e-6));
      expect(bounds.top, closeTo(0.0, 1e-6));
      expect(bounds.bottom, closeTo(75.0, 1e-6));
    });

    test('flattenCubic produces continuous polyline', () {
      const p0 = Offset(0, 0);
      const p1 = Offset(0, 100);
      const p2 = Offset(100, 100);
      const p3 = Offset(100, 0);

      final output = <Offset>[p0];
      flattenCubic(p0, p1, p2, p3, output, tolerance: 0.5);

      expect(output.length, greaterThan(3));
      expect(output.first, equals(p0));
      expect(output.last, equals(p3));
    });

    test('bidirectional conversion between VectorPath and Path', () {
      final vPaths = [
        VectorPath(
          start: const Offset(10, 10),
          points: [
            const Offset(100, 10),
            const CurvePoint(
              Offset(100, 50),
              Offset(50, 100),
              Offset(10, 100),
              NodeType.smooth,
            ),
          ],
          closure: PathClosure.closed,
        ),
      ];

      final enginePath = pathFromVectorPaths(vPaths);
      expect(enginePath.isEmpty, isFalse);
      expect(enginePath.verbCount, greaterThan(0));

      final convertedBack = vectorPathsFromPath(enginePath);
      expect(convertedBack.isNotEmpty, isTrue);
      expect(convertedBack.first.start, equals(const Offset(10, 10)));
      expect(convertedBack.first.isClosed, isTrue);
    });
  });
}
