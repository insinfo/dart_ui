import 'package:dart_ui/src/cdr/fills/cdr_fill.dart';
import 'package:dart_ui/src/cdr/fills/cdr_gradient_fill.dart';
import 'package:dart_ui/src/cdr/fills/cdr_mesh_fill.dart';
import 'package:dart_ui/src/geometry/offset.dart';
import 'package:test/test.dart';

void main() {
  group('CDR Fills & Gradients', () {
    test('CdrSolidFill holds exact ARGB', () {
      const solid = CdrSolidFill(0xFF112233);
      expect(solid.colorArgb, equals(0xFF112233));
    });

    test('CdrGradientFill maps colors and stops', () {
      final gradient = CdrGradientFill(
        type: CdrGradientType.radial,
        stops: [
          const CdrColorStop(1.0, 0xFFFFFFFF),
          const CdrColorStop(0.0, 0xFF000000),
        ],
      );

      // Stops are sorted by constructor
      expect(gradient.stops[0].position, equals(0.0));
      expect(gradient.stops[0].colorArgb, equals(0xFF000000));
      expect(gradient.stops[1].position, equals(1.0));
      expect(gradient.stops[1].colorArgb, equals(0xFFFFFFFF));
    });

    test('CdrMeshFill creates nodes', () {
      final nodes = <CdrMeshNode>[
        const CdrMeshNode(Offset(0, 0), 0xFFFF0000),
        const CdrMeshNode(Offset(10, 0), 0xFF00FF00),
        const CdrMeshNode(Offset(0, 10), 0xFF0000FF),
        const CdrMeshNode(Offset(10, 10), 0xFFFFFF00),
      ];

      final mesh = CdrMeshFill(1, 1, nodes);
      final positions = mesh.getPositions();
      expect(positions.length, equals(4));
    });
  });
}
