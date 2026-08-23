import 'dart:typed_data';

import 'package:dart_ui/src/geometry/path.dart';
import 'package:dart_ui/src/geometry/rect.dart';
import 'package:dart_ui/src/rendering/gpu/vector/cpu_tessellation.dart';
import 'package:dart_ui/src/rendering/path/fill_rule.dart';
import 'package:test/test.dart';

void main() {
  const CpuPathTessellator tessellator = CpuPathTessellator();

  group('CpuPathTessellator', () {
    test('emits the portable float32/uint32 contract for a convex path', () {
      final Path path = Path.rect(const Rect.fromLTRB(2, 3, 12, 8));
      final TessellatedPathMesh mesh = tessellator.tessellate(path);

      expect(mesh.vertices, isA<Float32List>());
      expect(mesh.indices, isA<Uint32List>());
      expect(mesh.vertexCount, 4);
      expect(mesh.triangleCount, 2);
      expect(mesh.bounds, const Rect.fromLTRB(2, 3, 12, 8));
      expect(_meshArea(mesh), closeTo(50, 1e-9));
      expect(mesh.metrics.signedArea, closeTo(50, 1e-9));
      expect(mesh.metrics.isConvex, isTrue);
      expect(mesh.metrics.sourceCurveCount, 0);
      expect(mesh.metrics.flattenedSegmentCount, 4);
      expect(mesh.metrics.vertexBytes, 32);
      expect(mesh.metrics.indexBytes, 24);
      expect(mesh.metrics.retainedBytes, 56);
      expect(
        mesh.indices,
        everyElement(inInclusiveRange(0, mesh.vertexCount - 1)),
      );
    });

    test('ear-clips a concave polygon without filling its notch', () {
      final Path path = _polygon(<(double, double)>[
        (0, 0),
        (6, 0),
        (6, 6),
        (3, 3),
        (0, 6),
      ]);
      final TessellatedPathMesh mesh = tessellator.tessellate(path);

      expect(mesh.vertexCount, 5);
      expect(mesh.triangleCount, 3);
      expect(mesh.metrics.isConvex, isFalse);
      expect(_meshArea(mesh), closeTo(27, 1e-9));
      for (var i = 0; i < mesh.indices.length; i += 3) {
        expect(_triangleDoubleArea(mesh, i), greaterThan(0));
      }
    });

    test('normalizes either source winding in indices, not vertices', () {
      final Path clockwise = _polygon(<(double, double)>[
        (0, 0),
        (4, 0),
        (4, 3),
        (0, 3),
      ]);
      final Path counterClockwise = _polygon(<(double, double)>[
        (0, 0),
        (0, 3),
        (4, 3),
        (4, 0),
      ]);

      for (final Path path in <Path>[clockwise, counterClockwise]) {
        final TessellatedPathMesh mesh = tessellator.tessellate(path);
        expect(_meshArea(mesh), closeTo(12, 1e-9));
        for (var i = 0; i < mesh.indices.length; i += 3) {
          expect(_triangleDoubleArea(mesh, i), greaterThan(0));
        }
      }
    });

    test('removes only redundant duplicate and collinear vertices', () {
      final Path path = _polygon(<(double, double)>[
        (0, 0),
        (2, 0),
        (2, 0),
        (4, 0),
        (4, 4),
        (0, 4),
      ]);
      final TessellatedPathMesh mesh = tessellator.tessellate(path);

      expect(mesh.vertexCount, 4);
      expect(mesh.metrics.removedVertexCount, 2);
      expect(_meshArea(mesh), closeTo(16, 1e-9));
    });

    test('cache key is content-based and independent from draw transform', () {
      final Path first = _polygon(<(double, double)>[
        (0, 0),
        (8, 0),
        (0, 8),
      ]);
      final Path second = _polygon(<(double, double)>[
        (0, 0),
        (8, 0),
        (0, 8),
      ]);
      final TessellatedPathMesh a = tessellator.tessellate(first);
      final TessellatedPathMesh b = tessellator.tessellate(second);
      final TessellatedPathMesh otherRule = tessellator.tessellate(
        second,
        fillRule: FillRule.evenOdd,
      );
      final TessellatedPathMesh otherTolerance = tessellator.tessellate(
        second,
        flattenTolerance: 0.125,
      );

      expect(a.cacheKey, b.cacheKey);
      expect(a.cacheKey.hashCode, b.cacheKey.hashCode);
      expect(a.cacheKey, isNot(otherRule.cacheKey));
      expect(a.cacheKey, isNot(otherTolerance.cacheKey));
    });

    test('retained cache reuses local mesh across draws and path instances',
        () {
      final cache = CpuTessellatedPathCache();
      final first = _polygon(<(double, double)>[
        (2, 3),
        (12, 3),
        (2, 13),
      ]);
      final equivalent = _polygon(<(double, double)>[
        (2, 3),
        (12, 3),
        (2, 13),
      ]);

      final mesh = cache.resolve(first, flattenTolerance: 0.25);
      final reused = cache.resolve(equivalent, flattenTolerance: 0.25);
      final finer = cache.resolve(equivalent, flattenTolerance: 0.125);

      expect(reused, same(mesh));
      expect(finer, isNot(same(mesh)));
      expect(cache.length, 2);
      expect(cache.hitCount, 1);
      expect(cache.missCount, 2);
      expect(cache.retainedBytes,
          mesh.metrics.retainedBytes + finer.metrics.retainedBytes);
      expect(mesh.bounds, const Rect.fromLTRB(2, 3, 12, 13),
          reason: 'the mesh remains local; draw transforms are GPU state');

      cache.clear();
      expect(cache.length, 0);
      expect(cache.retainedBytes, 0);
      expect(cache.hitCount, 0);
      expect(cache.missCount, 0);
    });

    test('empty path has a reusable empty mesh', () {
      final TessellatedPathMesh mesh = tessellator.tessellate(Path.empty);
      expect(mesh.vertexCount, 0);
      expect(mesh.triangleCount, 0);
      expect(mesh.bounds, Rect.zero);
      expect(tessellator.inspect(Path.empty).isEligible, isTrue);
    });

    test('flattens quadratic and cubic curves explicitly in local space', () {
      final Path quadratic = (PathBuilder()
            ..moveTo(0, 0)
            ..quadraticBezierTo(5, 10, 10, 0)
            ..lineTo(10, 10)
            ..lineTo(0, 10)
            ..close())
          .build();
      final Path cubic = (PathBuilder()
            ..moveTo(0, 0)
            ..cubicTo(2, 8, 8, 8, 10, 0)
            ..lineTo(10, 10)
            ..lineTo(0, 10)
            ..close())
          .build();

      for (final path in <Path>[quadratic, cubic]) {
        final mesh = tessellator.tessellate(path, flattenTolerance: 0.1);
        expect(mesh.metrics.sourceCurveCount, 1);
        expect(mesh.metrics.flattenedSegmentCount, greaterThan(4));
        expect(mesh.metrics.vertexCount, greaterThan(4));
        expect(mesh.metrics.triangleCount, mesh.metrics.vertexCount - 2);
        expect(mesh.cacheKey.flattenTolerance, 0.1);
        expect(tessellator.inspect(path, flattenTolerance: 0.1).isEligible,
            isTrue);
      }
    });

    test('tolerance changes topology and remains part of the cache key', () {
      final path = (PathBuilder()
            ..moveTo(0, 0)
            ..cubicTo(0, 100, 100, 100, 100, 0)
            ..lineTo(100, 100)
            ..lineTo(0, 100)
            ..close())
          .build();

      final coarse = tessellator.tessellate(path, flattenTolerance: 8);
      final fine = tessellator.tessellate(path, flattenTolerance: 0.125);
      expect(fine.vertexCount, greaterThan(coarse.vertexCount));
      expect(fine.metrics.flattenedSegmentCount,
          greaterThan(coarse.metrics.flattenedSegmentCount));
      expect(fine.cacheKey, isNot(coarse.cacheKey));
      expect(fine.cacheKey.path, same(path));
    });

    test('rejects multiple/open contours by name', () {
      final Path multiple = (PathBuilder()
            ..moveTo(0, 0)
            ..lineTo(4, 0)
            ..lineTo(0, 4)
            ..close()
            ..moveTo(1, 1)
            ..lineTo(2, 1)
            ..lineTo(1, 2)
            ..close())
          .build();
      final Path open = (PathBuilder()
            ..moveTo(0, 0)
            ..lineTo(4, 0)
            ..lineTo(0, 4))
          .build();

      expect(
        tessellator.inspect(multiple).rejection,
        TessellationRejection.multipleContoursUnsupported,
      );
      expect(
        tessellator.inspect(open).rejection,
        TessellationRejection.openContourUnsupported,
      );
    });

    test('detects and rejects a self-intersecting bow tie', () {
      final Path path = _polygon(<(double, double)>[
        (0, 0),
        (5, 5),
        (0, 5),
        (5, 0),
      ]);
      final CpuTessellationEligibility eligibility = tessellator.inspect(path);

      expect(eligibility.isEligible, isFalse);
      expect(eligibility.hasSelfIntersections, isTrue);
      expect(eligibility.rejection, TessellationRejection.selfIntersection);
      expect(
        () => tessellator.tessellate(path),
        throwsA(
          isA<TessellationUnsupportedError>().having(
            (TessellationUnsupportedError error) => error.rejection,
            'rejection',
            TessellationRejection.selfIntersection,
          ),
        ),
      );
    });

    test('rejects an invalid future flattening tolerance', () {
      expect(
        () => tessellator.tessellate(
          Path.rect(const Rect.fromLTRB(0, 0, 1, 1)),
          flattenTolerance: 0,
        ),
        throwsArgumentError,
      );
    });

    test('refuses flattening before its configured segment budget explodes',
        () {
      const limited = CpuPathTessellator(maxFlattenedSegments: 4);
      final path = (PathBuilder()
            ..moveTo(0, 0)
            ..quadraticBezierTo(50, 100, 100, 0)
            ..lineTo(100, 100)
            ..lineTo(0, 100)
            ..close())
          .build();

      expect(
        () => limited.tessellate(path, flattenTolerance: 0.01),
        throwsA(
          isA<TessellationUnsupportedError>().having(
            (error) => error.rejection,
            'rejection',
            TessellationRejection.segmentLimitExceeded,
          ),
        ),
      );
      expect(
        limited.inspect(path, flattenTolerance: 0.01).rejection,
        TessellationRejection.segmentLimitExceeded,
      );
    });

    test('refuses rather than accepting Path per-curve quality clamping', () {
      final path = (PathBuilder()
            ..moveTo(0, 0)
            ..quadraticBezierTo(500000, 1000000, 1000000, 0)
            ..lineTo(1000000, 1000000)
            ..lineTo(0, 1000000)
            ..close())
          .build();

      expect(
        () => tessellator.tessellate(path, flattenTolerance: 0.000001),
        throwsA(
          isA<TessellationUnsupportedError>().having(
            (error) => error.rejection,
            'rejection',
            TessellationRejection.segmentLimitExceeded,
          ),
        ),
      );
    });

    test('rejects non-finite curve control points before flattening', () {
      final path = (PathBuilder()
            ..moveTo(0, 0)
            ..quadraticBezierTo(double.infinity, 4, 8, 0)
            ..lineTo(0, 8)
            ..close())
          .build();

      expect(
        () => tessellator.tessellate(path),
        throwsA(
          isA<TessellationUnsupportedError>().having(
            (error) => error.rejection,
            'rejection',
            TessellationRejection.nonFiniteCoordinate,
          ),
        ),
      );
    });
  });
}

Path _polygon(List<(double, double)> points) {
  final PathBuilder builder = PathBuilder()
    ..moveTo(points.first.$1, points.first.$2);
  for (var i = 1; i < points.length; i++) {
    builder.lineTo(points[i].$1, points[i].$2);
  }
  builder.close();
  return builder.build();
}

double _triangleDoubleArea(TessellatedPathMesh mesh, int indexOffset) {
  final int a = mesh.indices[indexOffset] * 2;
  final int b = mesh.indices[indexOffset + 1] * 2;
  final int c = mesh.indices[indexOffset + 2] * 2;
  return (mesh.vertices[b] - mesh.vertices[a]) *
          (mesh.vertices[c + 1] - mesh.vertices[a + 1]) -
      (mesh.vertices[b + 1] - mesh.vertices[a + 1]) *
          (mesh.vertices[c] - mesh.vertices[a]);
}

double _meshArea(TessellatedPathMesh mesh) {
  var doubleArea = 0.0;
  for (var i = 0; i < mesh.indices.length; i += 3) {
    doubleArea += _triangleDoubleArea(mesh, i);
  }
  return doubleArea * 0.5;
}
