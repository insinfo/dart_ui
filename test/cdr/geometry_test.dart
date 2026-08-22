import 'package:dart_ui/src/cdr/geometry/cdr_bezier_evaluator.dart';
import 'package:test/test.dart';

void main() {
  group('CDR Geometry Subsystem', () {
    test('computeSymmetricalControlPoint calculates mirror vector', () {
      const anchorX = 100.0;
      const anchorY = 100.0;

      const prevCx = 90.0;
      const prevCy = 90.0;

      // Vetor (prev -> anchor) é (+10, +10)
      // O próximo controle deve ser anchor + vetor = (110, 110)
      final nextC = CdrBezierEvaluator.computeSymmetricalControlPoint(
          anchorX, anchorY, prevCx, prevCy);

      expect(nextC[0], closeTo(110.0, 0.001));
      expect(nextC[1], closeTo(110.0, 0.001));
    });

    test('computeSmoothControlPoint maintains angle but applies new length',
        () {
      const anchorX = 100.0;
      const anchorY = 100.0;

      // prev (90, 100), dx=10, dy=0. Normal é (1, 0).
      const prevCx = 90.0;
      const prevCy = 100.0;

      // Nova distância deve ser de 50 pixels a partir do anchorX, na mesma direção (1, 0)
      final nextC = CdrBezierEvaluator.computeSmoothControlPoint(
          anchorX, anchorY, prevCx, prevCy, 50.0);

      expect(nextC[0], closeTo(150.0, 0.001));
      expect(nextC[1], closeTo(100.0, 0.001));
    });
  });
}
