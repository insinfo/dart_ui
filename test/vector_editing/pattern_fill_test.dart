/// Pattern and texture fills: marks cut to the shape, textures that are the
/// same every time, and SVG that keeps both.
library;

import 'dart:math' as math;

import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

void main() {
  final List<VectorPath> square = <VectorPath>[
    VectorPath(
      start: Offset.zero,
      points: const <Object>[
        Offset(100, 0),
        Offset(100, 100),
        Offset(0, 100),
        Offset.zero,
      ],
      closure: PathClosure.closed,
    ),
  ];

  Iterable<Offset> pointsOf(List<VectorPath> paths) sync* {
    for (final VectorPath path in paths) {
      yield path.start;
      for (final Object point in path.points) {
        if (point is CurvePoint) {
          yield point.endpoint;
        } else if (point is Offset) {
          yield point;
        }
      }
    }
  }

  test('every kind cuts marks that stay inside the shape', () {
    for (final String kind in VectorPatterns.kinds) {
      final List<VectorPath> marks =
          VectorPatterns.cut(square, kind, size: 10, angle: 30);
      expect(marks, isNotEmpty, reason: kind);
      for (final Offset p in pointsOf(marks)) {
        expect(p.dx, inInclusiveRange(-1e-6, 100 + 1e-6), reason: kind);
        expect(p.dy, inInclusiveRange(-1e-6, 100 + 1e-6), reason: kind);
      }
    }
  });

  test('a finer pattern has more marks', () {
    expect(VectorPatterns.cut(square, 'dots', size: 5).length,
        greaterThan(VectorPatterns.cut(square, 'dots', size: 20).length));
  });

  test('a huge shape is capped, not cut into a million marks', () {
    final List<VectorPath> big = <VectorPath>[
      VectorPath(
        start: Offset.zero,
        points: const <Object>[
          Offset(100000, 0),
          Offset(100000, 100000),
          Offset(0, 100000),
          Offset.zero,
        ],
        closure: PathClosure.closed,
      ),
    ];
    expect(VectorPatterns.cut(big, 'dots', size: 1).length,
        lessThan(200 * 200 * 2));
  });

  test('textures are deterministic, in 0..1 and not flat', () {
    for (final String kind in VectorPatterns.textures) {
      final List<double> values = <double>[
        for (int i = 0; i < 50; i++)
          VectorPatterns.textureAt(kind, i * 3.7, i * 1.3),
      ];
      expect(
          values,
          <double>[
            for (int i = 0; i < 50; i++)
              VectorPatterns.textureAt(kind, i * 3.7, i * 1.3),
          ],
          reason: kind);
      for (final double v in values) {
        expect(v, inInclusiveRange(0, 1), reason: kind);
      }
      expect(
          values.reduce(math.max) - values.reduce(math.min), greaterThan(0.05),
          reason: '$kind varies');
    }
    expect(VectorPatterns.isTexture('clouds'), isTrue);
    expect(VectorPatterns.isTexture('hatch'), isFalse);
  });

  test('the size is in document units, whatever the object\'s scale', () {
    // A polygon is a unit shape scaled by its transformation: its pattern
    // must not be scaled with it into one mark covering everything.
    final VectorPolygon polygon = DocumentMethods(VectorDocument())
        .createPolygon(cx: 500, cy: 500, radius: 100, cornersNum: 6);
    polygon
      ..style = polygon.style.copyWith(
          fill: const FillDescriptor(
              fillType: FillType.pattern, patternId: 'dots', patternSize: 10))
      ..update();
    final List<VectorPath> marks = VectorPatterns.marksOf(polygon);
    expect(marks.length, greaterThan(200), reason: 'about 20 dots across');
    for (final Offset p in pointsOf(marks)) {
      expect((p - const Offset(500, 500)).distance, lessThan(100 + 1e-6));
    }
    expect(VectorPatterns.anchorOf(polygon)!.dx, closeTo(500, 1e-6));
  });

  test('a texture has no marks to cut', () {
    final VectorDocument doc = VectorDocument();
    final VectorRectangle rect =
        DocumentMethods(doc).createRectangle(x: 0, y: 0, width: 50, height: 20);
    rect
      ..style = rect.style.copyWith(
          fill: const FillDescriptor(
              fillType: FillType.pattern, patternId: 'clouds'))
      ..update();
    expect(VectorPatterns.marksOf(rect), isEmpty);
  });

  VectorDocument withFill(FillDescriptor fill) {
    final VectorDocument doc = VectorDocument();
    final DocumentMethods methods = DocumentMethods(doc);
    final VectorRectangle rect =
        methods.createRectangle(x: 0, y: 0, width: 50, height: 20);
    rect
      ..style = rect.style.copyWith(fill: fill)
      ..update();
    methods.addObject(doc.getPageLayers(doc.getPage(0)).first, rect);
    return doc;
  }

  FillDescriptor fillOf(VectorDocument doc) => doc
      .getPageLayers(doc.getPage(0))
      .first
      .children
      .whereType<SelectableObject>()
      .single
      .style
      .fill;

  test('SVG keeps a pattern, and draws it for other readers', () {
    final String svg = VectorSvgCodec.exportToSvg(withFill(
      const FillDescriptor(
        fillType: FillType.pattern,
        color: Color(0xFF102030),
        patternId: 'crosshatch',
        patternBackground: Color(0xFFFFEEDD),
        patternSize: 6,
        patternAngle: 45,
      ),
    ));
    expect(svg, contains('<pattern'));
    expect(svg, contains('url(#'));
    final FillDescriptor read = fillOf(VectorSvgCodec.importFromSvg(svg));
    expect(read.isPattern, isTrue);
    expect(read.patternId, 'crosshatch');
    expect(read.color, const Color(0xFF102030));
    expect(read.patternBackground, const Color(0xFFFFEEDD));
    expect(read.patternSize, closeTo(6, 1e-6));
    expect(read.patternAngle, closeTo(45, 1e-6));
  });

  test('SVG keeps a see-through texture', () {
    final FillDescriptor read = fillOf(VectorSvgCodec.importFromSvg(
      VectorSvgCodec.exportToSvg(withFill(const FillDescriptor(
        fillType: FillType.pattern,
        color: Color(0xFF336699),
        patternId: 'paper',
        patternSize: 12,
      ))),
    ));
    expect(read.patternId, 'paper');
    expect(read.patternBackground, isNull);
    expect(read.patternSize, closeTo(12, 1e-6));
  });
}
