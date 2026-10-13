import 'dart:math' as math;

import 'package:dart_ui/vector.dart';
import 'package:test/test.dart';

/// The largest distance from any of [stroke]'s points to the fitted curve,
/// measured densely along it.
double deviation(List<Offset> stroke, Offset start, List<CurvePoint> fit) {
  final List<Offset> dense = <Offset>[];
  Offset from = start;
  for (final CurvePoint c in fit) {
    for (var i = 0; i <= 400; i++) {
      final double t = i / 400;
      final double u = 1 - t;
      dense.add(from * (u * u * u) +
          c.control1 * (3 * u * u * t) +
          c.control2 * (3 * u * t * t) +
          c.endpoint * (t * t * t));
    }
    from = c.endpoint;
  }
  var worst = 0.0;
  for (final Offset p in stroke) {
    var best = double.infinity;
    for (final Offset q in dense) {
      best = math.min(best, (p - q).distance);
    }
    worst = math.max(worst, best);
  }
  return worst;
}

void main() {
  group('CurveFitting', () {
    test('a stroke traced along one cubic fits as one segment', () {
      const CurvePoint source =
          CurvePoint(Offset(30, -60), Offset(120, 80), Offset(150, 0));
      final List<Offset> stroke = <Offset>[
        for (var i = 0; i <= 60; i++)
          () {
            final double t = i / 60;
            final double u = 1 - t;
            return source.control1 * (3 * u * u * t) +
                source.control2 * (3 * u * t * t) +
                source.endpoint * (t * t * t);
          }(),
      ];
      final List<CurvePoint> fit = CurveFitting.fit(stroke, 0.5);
      expect(fit, hasLength(1));
      expect(fit.single.endpoint, const Offset(150, 0));
      expect(deviation(stroke, Offset.zero, fit), lessThan(0.5));
    });

    test('a wobbly circle fits in a few smooth segments within the error', () {
      final math.Random random = math.Random(3);
      final List<Offset> stroke = <Offset>[
        for (var i = 0; i <= 300; i++)
          Offset(
              100 * math.cos(i * 2 * math.pi / 300) + random.nextDouble() * .4,
              100 * math.sin(i * 2 * math.pi / 300) + random.nextDouble() * .4),
      ];
      final List<CurvePoint> fit = CurveFitting.fit(stroke, 2);
      expect(fit.length, inInclusiveRange(2, 10));
      expect(deviation(stroke, stroke.first, fit), lessThan(2.01));
      // Every node between two fitted halves is smooth; only the end is not.
      expect(fit.take(fit.length - 1).map((c) => c.nodeType),
          everyElement(NodeType.smooth));
    });

    test('a corner stays a cusp node on the corner', () {
      final List<Offset> stroke = <Offset>[
        for (var i = 0; i <= 100; i++) Offset(i.toDouble(), 0),
        for (var i = 1; i <= 100; i++) Offset(100, i.toDouble()),
      ];
      final List<CurvePoint> fit = CurveFitting.fit(stroke, 1);
      expect(fit.map((c) => c.endpoint), contains(const Offset(100, 0)));
      final CurvePoint corner =
          fit.firstWhere((c) => c.endpoint == const Offset(100, 0));
      expect(corner.nodeType, NodeType.cusp);
      expect(deviation(stroke, Offset.zero, fit), lessThan(1.01));
    });

    test('fewer than two distinct points fit to nothing', () {
      expect(CurveFitting.fit(const <Offset>[Offset(1, 1), Offset(1, 1)], 1),
          isEmpty);
    });
  });

  group('FreehandToolController', () {
    late VectorDocument doc;
    late VectorPage page;
    late VectorLayer layer;
    late FreehandToolController tool;

    setUp(() {
      doc = VectorDocument();
      page = doc.getPage(0);
      layer = doc.getPageLayers(page).first;
      tool = FreehandToolController(
        doc: doc,
        methods: DocumentMethods(doc),
        selection: SelectionManager(),
        snap: SnapManager()..snapToGrid = false,
      );
    });

    List<VectorCurve> curves() =>
        layer.children.whereType<VectorCurve>().toList();

    test('a drag becomes a fitted curve with few nodes', () {
      tool.onPointerDown(const Offset(10, 10), page);
      for (var i = 1; i <= 200; i++) {
        tool.onPointerMove(
            Offset(10 + i.toDouble(), 10 + 30 * math.sin(i / 30)), page);
      }
      expect(curves().single.paths.single.points, hasLength(200),
          reason: 'the trail is drawn as it is while dragging');
      tool.onPointerUp(Offset(210, 10 + 30 * math.sin(200 / 30)), page);
      final VectorPath path = curves().single.paths.single;
      expect(path.points.length, lessThan(8));
      expect(path.points, everyElement(isA<CurvePoint>()));
      expect(path.isOpen, isTrue);
      expect(tool.takeCreatedObject(), curves().single);
    });

    test('a stroke ending where it began is closed', () {
      tool.onPointerDown(const Offset(100, 0), page);
      for (var i = 1; i <= 120; i++) {
        tool.onPointerMove(
            Offset(
                100 * math.cos(i * 2 * math.pi / 120) + 2 * (i == 120 ? 1 : 0),
                100 * math.sin(i * 2 * math.pi / 120)),
            page);
      }
      tool.onPointerUp(const Offset(102, 1), page);
      final VectorPath path = curves().single.paths.single;
      expect(path.isClosed, isTrue);
      expect((path.points.last as CurvePoint).endpoint, path.start);
    });

    test('cancelling removes the stroke', () {
      tool.onPointerDown(const Offset(10, 10), page);
      tool.onPointerMove(const Offset(50, 50), page);
      tool.onCancel();
      expect(curves(), isEmpty);
    });
  });
}
