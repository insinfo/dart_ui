import 'dart:math' as math;

import 'package:dart_ui/vector.dart';
import 'package:test/test.dart';

/// A closed square, drawn the way a rectangle converts.
List<VectorPath> square(double x, double y, double size) => <VectorPath>[
      VectorPath(
        start: Offset(x, y),
        points: <Object>[
          Offset(x + size, y),
          Offset(x + size, y + size),
          Offset(x, y + size),
        ],
        closure: PathClosure.closed,
      ),
    ];

/// A circle of four Béziers, the way an ellipse converts.
List<VectorPath> circle(double cx, double cy, double r) {
  const double k = 0.5522847498;
  final double h = r * k;
  return <VectorPath>[
    VectorPath(
      start: Offset(cx + r, cy),
      points: <Object>[
        CurvePoint(
            Offset(cx + r, cy + h), Offset(cx + h, cy + r), Offset(cx, cy + r)),
        CurvePoint(
            Offset(cx - h, cy + r), Offset(cx - r, cy + h), Offset(cx - r, cy)),
        CurvePoint(
            Offset(cx - r, cy - h), Offset(cx - h, cy - r), Offset(cx, cy - r)),
        CurvePoint(
            Offset(cx + h, cy - r), Offset(cx + r, cy - h), Offset(cx + r, cy)),
      ],
      closure: PathClosure.closed,
    ),
  ];
}

/// The filled area, from the signed areas of the contours: every contour
/// of a result winds the same way round its inside, so holes subtract.
double area(List<VectorPath> paths) {
  var total = 0.0;
  for (final VectorPath path in paths) {
    final List<Offset> polygon = <Offset>[path.start];
    Offset from = path.start;
    for (final Object point in path.points) {
      if (point is CurvePoint) {
        for (var i = 1; i <= 200; i++) {
          final double t = i / 200;
          final double u = 1 - t;
          polygon.add(from * (u * u * u) +
              point.control1 * (3 * u * u * t) +
              point.control2 * (3 * u * t * t) +
              point.endpoint * (t * t * t));
        }
        from = point.endpoint;
      } else {
        polygon.add(point as Offset);
        from = point;
      }
    }
    for (var i = 0; i < polygon.length; i++) {
      final Offset p = polygon[i];
      final Offset q = polygon[(i + 1) % polygon.length];
      total += p.dx * q.dy - q.dx * p.dy;
    }
  }
  return (total / 2).abs();
}

/// Distinct nodes of a single-contour result.
int nodes(List<VectorPath> paths) {
  final VectorPath path = paths.single;
  final Object last = path.points.last;
  final Offset end = last is CurvePoint ? last.endpoint : last as Offset;
  return path.points.length - (end == path.start ? 0 : -1);
}

List<VectorPath> run(
        List<VectorPath> a, List<VectorPath> b, PathBooleanOperation op) =>
    PathBoolean.apply(a, b, op);

void main() {
  group('two overlapping squares', () {
    final List<VectorPath> a = square(0, 0, 100);
    final List<VectorPath> b = square(50, 50, 100);

    test('weld keeps the outline of both, eight corners', () {
      final List<VectorPath> result = run(a, b, PathBooleanOperation.union);
      expect(area(result), closeTo(17500, 1e-6));
      expect(nodes(result), 8);
    });

    test('intersect keeps the overlap', () {
      final List<VectorPath> result = run(a, b, PathBooleanOperation.intersect);
      expect(area(result), closeTo(2500, 1e-6));
      expect(nodes(result), 4);
    });

    test('trim takes the second out of the first', () {
      final List<VectorPath> result =
          run(a, b, PathBooleanOperation.difference);
      expect(area(result), closeTo(7500, 1e-6));
      expect(nodes(result), 6);
    });

    test('exclude keeps what only one covers', () {
      expect(
          area(run(a, b, PathBooleanOperation.exclude)), closeTo(15000, 1e-6));
    });
  });

  test('two squares sharing an edge weld into one outline', () {
    final List<VectorPath> result =
        run(square(0, 0, 100), square(100, 0, 100), PathBooleanOperation.union);
    expect(result, hasLength(1));
    expect(area(result), closeTo(20000, 1e-6));
  });

  test('a square welded to its copy is the square', () {
    final List<VectorPath> result =
        run(square(0, 0, 100), square(0, 0, 100), PathBooleanOperation.union);
    expect(result, hasLength(1));
    expect(area(result), closeTo(10000, 1e-6));
    expect(nodes(result), 4);
  });

  test('a circle welded to a square stays a curve', () {
    final List<VectorPath> result = run(
        square(0, 0, 100), circle(100, 100, 50), PathBooleanOperation.union);
    final double circleArea = area(circle(100, 100, 50));
    expect(area(result), closeTo(10000 + circleArea * .75, 0.5));
    expect(result.single.points.whereType<CurvePoint>(), hasLength(3),
        reason: 'three quarters of the circle, uncut');
  });

  test('a circle trimmed by a square loses exactly a quarter', () {
    final List<VectorPath> result = run(circle(100, 100, 50), square(0, 0, 100),
        PathBooleanOperation.difference);
    expect(area(result), closeTo(area(circle(100, 100, 50)) * .75, 0.5));
  });

  test('a hole is wound against its outline', () {
    final List<VectorPath> result = run(
        square(0, 0, 100), square(40, 40, 20), PathBooleanOperation.difference);
    expect(result, hasLength(2));
    expect(area(result), closeTo(10000 - 400, 1e-6));
    expect(PathBoolean.winding(result, const Offset(50, 50)), 0);
    expect(PathBoolean.winding(result, const Offset(10, 10)), isNot(0));
  });

  test('disjoint shapes weld into two outlines and intersect into none', () {
    final List<VectorPath> a = square(0, 0, 10);
    final List<VectorPath> b = square(50, 0, 10);
    expect(run(a, b, PathBooleanOperation.union), hasLength(2));
    expect(run(a, b, PathBooleanOperation.intersect), isEmpty);
  });

  test('two circles: the lens is symmetric and curved', () {
    final List<VectorPath> result = run(
        circle(0, 0, 50), circle(50, 0, 50), PathBooleanOperation.intersect);
    // The lens of two circles of radius r a radius apart: twice the
    // circular segment, 2r²(π/3 - √3/4).
    const double r = 50;
    final double lens = 2 * (r * r * math.pi / 3 - r * r * math.sqrt(3) / 4);
    expect(area(result), closeTo(lens, lens * 1e-3));
    expect(result.single.points.every((Object p) => p is CurvePoint), isTrue);
  });

  test('weld of many is one outline', () {
    final List<VectorPath> result = PathBoolean.unionAll(<List<VectorPath>>[
      for (var i = 0; i < 5; i++) square(i * 15.0, 0, 20),
    ]);
    expect(result, hasLength(1));
    expect(area(result), closeTo(20 * (4 * 15 + 20), 1e-6));
  });

  test('the winding of an exact curve, a hair inside and outside', () {
    final List<VectorPath> c = circle(0, 0, 50);
    expect(PathBoolean.winding(c, const Offset(49.999, 0)), isNot(0));
    expect(PathBoolean.winding(c, const Offset(50.001, 0)), 0);
  });

  group('against the inputs, point by point', () {
    /// A star of [points] tips, self-crossing when drawn tip to tip.
    List<VectorPath> star(
        double cx, double cy, double r, int points, double turn) {
      final List<Offset> tips = <Offset>[
        for (var i = 0; i < points; i++)
          Offset(cx + r * math.cos(turn + i * 2 * math.pi / points),
              cy + r * math.sin(turn + i * 2 * math.pi / points)),
      ];
      final List<Offset> order = <Offset>[
        for (var i = 0; i < points; i++) tips[(i * 2) % points],
      ];
      return <VectorPath>[
        VectorPath(
            start: order.first,
            points: order.skip(1).toList(),
            closure: PathClosure.closed),
      ];
    }

    List<VectorPath> rotatedSquare(double cx, double cy, double r, double a) =>
        <VectorPath>[
          VectorPath(
            start: Offset(cx + r * math.cos(a), cy + r * math.sin(a)),
            points: <Object>[
              for (var i = 1; i < 4; i++)
                Offset(cx + r * math.cos(a + i * math.pi / 2),
                    cy + r * math.sin(a + i * math.pi / 2)),
            ],
            closure: PathClosure.closed,
          ),
        ];

    List<VectorPath> shape(math.Random random) {
      final double cx = random.nextDouble() * 100;
      final double cy = random.nextDouble() * 100;
      final double r = 20 + random.nextDouble() * 40;
      return switch (random.nextInt(3)) {
        0 => circle(cx, cy, r),
        1 => rotatedSquare(cx, cy, r, random.nextDouble() * math.pi),
        _ => star(cx, cy, r, 5, random.nextDouble()),
      };
    }

    bool inside(List<VectorPath> paths, Offset p) =>
        PathBoolean.winding(paths, p) != 0;

    for (final PathBooleanOperation op in PathBooleanOperation.values) {
      test('${op.name}, twenty random pairs', () {
        final math.Random random = math.Random(op.index + 7);
        var mismatches = 0;
        var samples = 0;
        for (var pair = 0; pair < 20; pair++) {
          final List<VectorPath> a = shape(random);
          final List<VectorPath> b = shape(random);
          final List<VectorPath> result = PathBoolean.apply(a, b, op);
          for (var k = 0; k < 150; k++) {
            final Offset p = Offset(
                random.nextDouble() * 180 - 40, random.nextDouble() * 180 - 40);
            final bool inA = inside(a, p);
            final bool inB = inside(b, p);
            final bool expected = switch (op) {
              PathBooleanOperation.union => inA || inB,
              PathBooleanOperation.intersect => inA && inB,
              PathBooleanOperation.difference => inA && !inB,
              PathBooleanOperation.exclude => inA != inB,
            };
            samples++;
            if (inside(result, p) != expected) mismatches++;
          }
        }
        expect(mismatches, 0, reason: '$mismatches of $samples points');
      });
    }
  });
}
