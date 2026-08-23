import 'dart:typed_data';

import 'package:dart_ui/src/geometry/path.dart';
import 'package:dart_ui/src/geometry/rect.dart';
import 'package:dart_ui/src/geometry/transform2d.dart';
import 'package:dart_ui/src/rendering/gpu/vector/compute_tile_reference.dart';
import 'package:dart_ui/src/rendering/gpu/vector/compute_tile_scene.dart';
import 'package:dart_ui/src/rendering/path/fill_rule.dart';
import 'package:test/test.dart';

void main() {
  test('reuses encoded segments and bins draws deterministically in tile order',
      () {
    final ComputePathEncoding encoding = ComputePathEncoding.fromPath(
      Path.rect(const Rect.fromLTRB(0, 0, 8, 8)),
    );
    final ComputeTileScene scene = ComputeTileScene()
      ..appendEncoding(
        encoding,
        clip: const Rect.fromLTRB(0, 0, 8, 8),
        materialIndex: 2,
        fillRule: FillRule.nonZero,
      )
      ..appendEncoding(
        encoding,
        clip: const Rect.fromLTRB(4, 0, 8, 8),
        materialIndex: 3,
        fillRule: FillRule.evenOdd,
      );
    final ComputeTilePlan plan = scene.build(
      width: 8,
      height: 8,
      tileSize: 4,
    );

    expect(encoding.segmentCount, 4);
    expect(scene.uniqueEncodingCount, 1);
    expect(scene.uniqueSegmentCount, 4);
    expect(plan.segments, isA<Float32List>());
    expect(plan.draws, isA<Uint32List>());
    expect(plan.bins, isA<Uint32List>());
    expect(plan.references, isA<Uint32List>());
    expect(plan.commands, isA<Uint32List>());
    expect(plan.segmentCount, 4, reason: 'shared geometry is uploaded once');
    expect(plan.drawFirstSegment(0), 0);
    expect(plan.drawFirstSegment(1), 0);
    expect(plan.drawMaterial(0), 2);
    expect(plan.drawMaterial(1), 3);
    expect(plan.referenceCount, 6);
    expect(plan.commandCount, 4);
    expect(plan.metrics.drawCount, 2);
    expect(plan.metrics.segmentCount, 4);
    expect(plan.metrics.tileCount, 4);
    expect(plan.metrics.occupiedTileCount, 4);
    expect(plan.metrics.referenceCount, 6);
    expect(
      plan.metrics.uploadBytes,
      plan.segments.lengthInBytes +
          plan.draws.lengthInBytes +
          plan.bounds.lengthInBytes +
          plan.bins.lengthInBytes +
          plan.references.lengthInBytes +
          plan.commands.lengthInBytes +
          // The per-tile segment lists and backdrops are uploaded too: a fine
          // raster that iterated every segment of a draw would not need them,
          // and one that does not is what makes approach D affordable.
          plan.referenceSegments.lengthInBytes +
          plan.tileSegments.lengthInBytes +
          plan.referenceBackdrops.lengthInBytes,
    );
    expect(_tileDraws(plan, 0), <int>[0]);
    expect(_tileDraws(plan, 1), <int>[0, 1]);
    expect(_tileDraws(plan, 2), <int>[0]);
    expect(_tileDraws(plan, 3), <int>[0, 1]);
    expect(
      <int>[for (var i = 0; i < plan.commandCount; i++) plan.commandTile(i)],
      <int>[0, 1, 2, 3],
    );
    expect(() => plan.references[0] = 99, throwsUnsupportedError);
  });

  test('CPU oracle distinguishes fill rules and validates coverage bins', () {
    final Path nested = (PathBuilder()
          ..addRect(const Rect.fromLTRB(0, 0, 8, 8))
          ..addRect(const Rect.fromLTRB(2, 2, 6, 6)))
        .build();
    final ComputePathEncoding encoding = ComputePathEncoding.fromPath(nested);
    final ComputeTileScene scene = ComputeTileScene()
      ..appendEncoding(
        encoding,
        clip: const Rect.fromLTRB(0, 0, 8, 8),
        materialIndex: 0,
        fillRule: FillRule.evenOdd,
      )
      ..appendEncoding(
        encoding,
        clip: const Rect.fromLTRB(0, 0, 8, 8),
        materialIndex: 1,
        fillRule: FillRule.nonZero,
      );
    final ComputeTilePlan plan = scene.build(
      width: 8,
      height: 8,
      tileSize: 4,
    );
    final ComputeTileCpuReference reference = ComputeTileCpuReference(plan);

    expect(reference.contains(0, 1.5, 1.5), isTrue);
    expect(reference.contains(0, 4, 4), isFalse);
    expect(reference.contains(1, 4, 4), isTrue);
    expect(reference.coverageAtPixel(0, 1, 1), 255);
    expect(reference.coverageAtPixel(0, 3, 3), 0);
    expect(reference.coverageAtPixel(1, 3, 3), 255);
    expect(reference.validateBins(), isEmpty);
  });

  test('CPU oracle exposes deterministic fractional reference coverage', () {
    final ComputeTileScene scene = ComputeTileScene()
      ..appendPath(
        Path.rect(const Rect.fromLTRB(0.5, 0.5, 3.5, 3.5)),
        clip: const Rect.fromLTRB(0, 0, 4, 4),
        materialIndex: 0,
        fillRule: FillRule.nonZero,
      );
    final ComputeTileCpuReference reference = ComputeTileCpuReference(
      scene.build(width: 4, height: 4, tileSize: 2),
    );

    expect(reference.coverageAtPixel(0, 0, 1), 128);
    expect(reference.coverageAtPixel(0, 1, 1), 255);
    expect(reference.coverageAtPixel(0, 3, 1), 128);
    expect(reference.validateBins(), isEmpty);
  });

  test('encoding and scene limits reject transactionally', () {
    final ComputeTileScene perPathLimited =
        ComputeTileScene(maxSegmentsPerPath: 3);
    expect(
      () => perPathLimited.appendPath(
        Path.rect(const Rect.fromLTRB(0, 0, 8, 8)),
        clip: const Rect.fromLTRB(0, 0, 8, 8),
        materialIndex: 0,
        fillRule: FillRule.nonZero,
      ),
      throwsA(isA<ComputeTilePlanError>().having(
        (ComputeTilePlanError error) => error.rejection,
        'rejection',
        ComputeTileRejection.segmentLimitExceeded,
      )),
    );
    expect(perPathLimited.drawCount, 0);
    expect(perPathLimited.uniqueSegmentCount, 0);

    final ComputePathEncoding encoding = ComputePathEncoding.fromPath(
      Path.rect(const Rect.fromLTRB(0, 0, 8, 8)),
    );
    final ComputeTileScene sceneLimited =
        ComputeTileScene(maxUniqueSegments: 3);
    expect(
      () => sceneLimited.appendEncoding(
        encoding,
        clip: const Rect.fromLTRB(0, 0, 8, 8),
        materialIndex: 0,
        fillRule: FillRule.nonZero,
      ),
      throwsA(isA<ComputeTilePlanError>().having(
        (ComputeTilePlanError error) => error.rejection,
        'rejection',
        ComputeTileRejection.sceneSegmentLimitExceeded,
      )),
    );
    expect(sceneLimited.drawCount, 0);
    expect(sceneLimited.uniqueEncodingCount, 0);

    final ComputeTileScene pathLimited = ComputeTileScene(maxPaths: 1)
      ..appendEncoding(
        encoding,
        clip: const Rect.fromLTRB(0, 0, 8, 8),
        materialIndex: 0,
        fillRule: FillRule.nonZero,
      );
    expect(
      () => pathLimited.appendEncoding(
        encoding,
        clip: const Rect.fromLTRB(0, 0, 8, 8),
        materialIndex: 1,
        fillRule: FillRule.nonZero,
      ),
      throwsA(isA<ComputeTilePlanError>().having(
        (ComputeTilePlanError error) => error.rejection,
        'rejection',
        ComputeTileRejection.pathLimitExceeded,
      )),
    );
    expect(pathLimited.drawCount, 1);
    expect(pathLimited.uniqueSegmentCount, 4);
  });

  test('bin limits reject build without changing the reusable scene', () {
    final ComputeTileScene scene = ComputeTileScene()
      ..appendPath(
        Path.rect(const Rect.fromLTRB(0, 0, 8, 8)),
        clip: const Rect.fromLTRB(0, 0, 8, 8),
        materialIndex: 0,
        fillRule: FillRule.nonZero,
      );

    expect(
      () => scene.build(
        width: 8,
        height: 8,
        tileSize: 4,
        maxTileReferences: 3,
      ),
      throwsA(isA<ComputeTilePlanError>().having(
        (ComputeTilePlanError error) => error.rejection,
        'rejection',
        ComputeTileRejection.tileReferenceLimitExceeded,
      )),
    );
    expect(
      () => scene.build(
        width: 16,
        height: 16,
        tileSize: 4,
        maxTiles: 15,
      ),
      throwsA(isA<ComputeTilePlanError>().having(
        (ComputeTilePlanError error) => error.rejection,
        'rejection',
        ComputeTileRejection.tileLimitExceeded,
      )),
    );
    expect(scene.drawCount, 1);
    expect(scene.uniqueSegmentCount, 4);
    expect(scene.build(width: 8, height: 8, tileSize: 4).drawCount, 1);
  });

  test('non-finite and float32-overflow geometry is rejected by name', () {
    final Path nonFinite = (PathBuilder()
          ..moveTo(0, 0)
          ..lineTo(double.infinity, 0)
          ..lineTo(0, 1)
          ..close())
        .build();
    expect(
      () => ComputePathEncoding.fromPath(nonFinite),
      throwsA(isA<ComputeTilePlanError>().having(
        (ComputeTilePlanError error) => error.rejection,
        'rejection',
        ComputeTileRejection.nonFiniteGeometry,
      )),
    );
    expect(
      () => ComputePathEncoding.fromPath(
        Path.rect(const Rect.fromLTRB(0, 0, 8, 8)),
        transform: const Transform2D.scaling(1e38, 1e38),
      ),
      throwsA(isA<ComputeTilePlanError>().having(
        (ComputeTilePlanError error) => error.rejection,
        'rejection',
        ComputeTileRejection.nonFiniteGeometry,
      )),
    );
  });
}

List<int> _tileDraws(ComputeTilePlan plan, int tile) => <int>[
      for (var reference = 0;
          reference < plan.tileReferenceCount(tile);
          reference++)
        plan.tileDraw(tile, reference),
    ];
