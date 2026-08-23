import 'dart:typed_data';

import 'package:dart_ui/src/geometry/path.dart';
import 'package:dart_ui/src/geometry/rect.dart';
import 'package:dart_ui/src/rendering/gpu/vector/sparse_strip_draw_plan.dart';
import 'package:dart_ui/src/rendering/gpu/vector/sparse_strips.dart';
import 'package:dart_ui/src/rendering/path/coverage_span_sink.dart';
import 'package:dart_ui/src/rendering/path/scanline_filler.dart';
import 'package:test/test.dart';

void main() {
  group('SparseStripDrawPlan', () {
    test('atlas and instances reconstruct exact analytic coverage', () {
      const Rect clip = Rect.fromLTRB(-3, -2, 44, 38);
      final Path path = (PathBuilder()
            ..moveTo(1.25, 3.5)
            ..lineTo(40.5, 9.25)
            ..lineTo(29.75, 34.5)
            ..lineTo(8, 29)
            ..close())
          .build();
      final StripBuffer strips = SparseStripGenerator().fill(path, clip);
      final SparseStripDrawPlan plan = SparseStripDrawPlan(
        atlasWidth: 16,
        atlasHeight: 8,
      );

      expect(plan.append(strips, materialIndex: 7), 0);
      expect(
        _reconstructPlan(plan, clip),
        orderedEquals(_analyticCoverage(path, clip)),
      );
      expect(plan.batchMaterial(0), 7);
      expect(plan.batchSolidCount(0), strips.fillCount);
      expect(plan.batchAlphaCount(0), greaterThanOrEqualTo(strips.stripCount));
    });

    test('splits wide strips and paginates without changing alpha', () {
      final StripBuffer source = StripBuffer();
      const int width = 19;
      final int offset = source.reserveAlphas(width * kStripHeight);
      for (var row = 0; row < kStripHeight; row++) {
        for (var x = 0; x < width; x++) {
          source.alphas[offset + row * width + x] = 1 + row * width + x;
        }
      }
      source.addStrip(-5, 8, width, offset);

      final SparseStripDrawPlan plan = SparseStripDrawPlan(
        atlasWidth: 8,
        atlasHeight: 4,
      );
      plan.append(source, materialIndex: 0);

      expect(plan.alphaInstanceCount, 3);
      expect(<int>[
        for (var i = 0; i < plan.alphaInstanceCount; i++) plan.alphaWidth(i),
      ], <int>[
        8,
        8,
        3
      ]);
      expect(plan.alphaPageCount, 3);
      expect(plan.alphaUploadCount, 3);
      expect(plan.batchAlphaPageRunCount(0), 3);
      expect(plan.batchEstimatedDrawCallCount(0), 3);
      expect(plan.metrics.alphaTexelBytes, width * kStripHeight);
      expect(plan.metrics.alphaUploadBytes, width * kStripHeight);

      for (var row = 0; row < kStripHeight; row++) {
        for (var x = 0; x < width; x++) {
          expect(
            _samplePlanAlpha(plan, x, row),
            source.alphas[offset + row * width + x],
            reason: 'row $row, x $x',
          );
        }
      }
    });

    test('keeps path/material order in explicit batches', () {
      final StripBuffer first = StripBuffer()..addFill(1, 2, 5);
      final StripBuffer second = StripBuffer();
      final int alpha = second.reserveAlphas(2 * kStripHeight);
      second.alphas.fillRange(alpha, alpha + 2 * kStripHeight, 127);
      second.addStrip(9, 10, 2, alpha);
      final SparseStripDrawPlan plan = SparseStripDrawPlan();

      expect(plan.append(first, materialIndex: 12), 0);
      expect(plan.append(second, materialIndex: 3), 1);

      expect(plan.batchMaterial(0), 12);
      expect(plan.batchSolidFirst(0), 0);
      expect(plan.batchSolidCount(0), 1);
      expect(plan.batchAlphaCount(0), 0);
      expect(plan.batchMaterial(1), 3);
      expect(plan.batchSolidCount(1), 0);
      expect(plan.batchAlphaFirst(1), 0);
      expect(plan.batchAlphaCount(1), 1);
      expect(plan.metrics.estimatedDrawCallCount, 2);
    });

    test('upload records name tightly occupied shelf rows', () {
      final StripBuffer source = StripBuffer();
      for (final int width in <int>[3, 4, 5]) {
        final int offset = source.reserveAlphas(width * kStripHeight);
        source.alphas.fillRange(offset, offset + width * kStripHeight, 200);
        source.addStrip(0, source.stripCount * kStripHeight, width, offset);
      }
      final SparseStripDrawPlan plan = SparseStripDrawPlan(
        atlasWidth: 8,
        atlasHeight: 8,
      )..append(source, materialIndex: 0);

      expect(plan.alphaUploadCount, 2);
      expect(
        <List<int>>[
          for (var i = 0; i < plan.alphaUploadCount; i++)
            <int>[
              plan.alphaUploadPage(i),
              plan.alphaUploadX(i),
              plan.alphaUploadY(i),
              plan.alphaUploadWidth(i),
              plan.alphaUploadHeight(i),
            ],
        ],
        <List<int>>[
          <int>[0, 0, 0, 7, 4],
          <int>[0, 0, 4, 5, 4],
        ],
      );
      expect(plan.metrics.alphaUploadBytes, (7 + 5) * kStripHeight);
    });

    test('reset reuses high-water instance and atlas arenas', () {
      final StripBuffer source = StripBuffer();
      for (var i = 0; i < 12; i++) {
        source.addFill(i, i * kStripHeight, 1);
        final int offset = source.reserveAlphas(kStripHeight);
        source.alphas.fillRange(offset, offset + kStripHeight, i + 1);
        source.addStrip(i, i * kStripHeight, 1, offset);
      }
      final SparseStripDrawPlan plan = SparseStripDrawPlan(
        atlasWidth: 4,
        atlasHeight: 4,
        initialInstances: 1,
        initialBatches: 1,
      )..append(source, materialIndex: 0);
      final Int32List solidArena = plan.solidInstanceStorage;
      final Int32List alphaArena = plan.alphaInstanceStorage;
      final Uint8List firstPage = plan.alphaPagePixels(0);
      final int growths = plan.arenaGrowths;
      final int retained = plan.metrics.retainedCapacityBytes;

      plan
        ..reset()
        ..append(source, materialIndex: 1);

      expect(plan.solidInstanceStorage, same(solidArena));
      expect(plan.alphaInstanceStorage, same(alphaArena));
      expect(plan.alphaPagePixels(0), same(firstPage));
      expect(plan.arenaGrowths, growths);
      expect(plan.metrics.retainedCapacityBytes, retained);
    });

    test('metrics expose comparable CPU/GPU strategy costs', () {
      final StripBuffer source = StripBuffer()..addFill(0, 0, 20);
      final int offset = source.reserveAlphas(6 * kStripHeight);
      source.alphas.fillRange(offset, offset + 6 * kStripHeight, 128);
      source.addStrip(20, 0, 6, offset);
      final SparseStripDrawPlan plan = SparseStripDrawPlan(
        atlasWidth: 4,
        atlasHeight: 4,
      )..append(source, materialIndex: 2);

      final SparseStripPlanMetrics metrics = plan.metrics;
      expect(metrics.sourceQuadCount, 2);
      expect(metrics.solidInstanceCount, 1);
      expect(metrics.alphaInstanceCount, 2);
      expect(metrics.emittedQuadCount, 3);
      expect(metrics.estimatedVertexCount, 12);
      expect(metrics.estimatedIndexCount, 18);
      expect(metrics.estimatedDrawCallCount, 3);
      expect(metrics.alphaTexelBytes, 24);
      expect(metrics.alphaUploadBytes, 24);
      expect(metrics.instanceBufferBytes, 4 * 4 + 2 * 7 * 4 + 5 * 4);
      expect(metrics.sourceEncodedBytes, source.encodedByteLength);
      expect(SparseStripGpuRequirements.requiresCompute, isFalse);
      expect(SparseStripGpuRequirements.requiresStencil, isFalse);
      expect(SparseStripGpuRequirements.requiresAlpha8Sampling, isTrue);
    });

    test('empty input emits no batch or GPU work', () {
      final SparseStripDrawPlan plan = SparseStripDrawPlan();
      expect(plan.append(StripBuffer(), materialIndex: 0), -1);
      expect(plan.batchCount, 0);
      expect(plan.metrics.emittedQuadCount, 0);
      expect(plan.alphaPageCount, 0);
    });
  });
}

int _samplePlanAlpha(SparseStripDrawPlan plan, int sourceX, int row) {
  var accumulated = 0;
  for (var i = 0; i < plan.alphaInstanceCount; i++) {
    final int width = plan.alphaWidth(i);
    if (sourceX < accumulated + width) {
      final Uint8List page = plan.alphaPagePixels(plan.alphaAtlasPage(i));
      return page[(plan.alphaAtlasY(i) + row) * plan.atlasWidth +
          plan.alphaAtlasX(i) +
          sourceX -
          accumulated];
    }
    accumulated += width;
  }
  throw RangeError.index(sourceX, plan.alphaInstances);
}

Uint8List _analyticCoverage(Path path, Rect clip) {
  final int left = clip.left.floor();
  final int top = clip.top.floor();
  final int width = clip.right.ceil() - left;
  final int height = clip.bottom.ceil() - top;
  final _DenseSink sink = _DenseSink(left, top, width, height);
  ScanlineFiller().fill(path, clip, sink);
  return sink.bytes;
}

Uint8List _reconstructPlan(SparseStripDrawPlan plan, Rect clip) {
  final int left = clip.left.floor();
  final int top = clip.top.floor();
  final int width = clip.right.ceil() - left;
  final int height = clip.bottom.ceil() - top;
  final Uint8List bytes = Uint8List(width * height);

  void put(int x, int y, int alpha) {
    final int localX = x - left;
    final int localY = y - top;
    if (localX >= 0 && localX < width && localY >= 0 && localY < height) {
      bytes[localY * width + localX] = alpha;
    }
  }

  for (var i = 0; i < plan.solidInstanceCount; i++) {
    for (var y = 0; y < plan.solidHeight(i); y++) {
      for (var x = 0; x < plan.solidWidth(i); x++) {
        put(plan.solidX(i) + x, plan.solidY(i) + y, 255);
      }
    }
  }
  for (var i = 0; i < plan.alphaInstanceCount; i++) {
    final Uint8List page = plan.alphaPagePixels(plan.alphaAtlasPage(i));
    for (var y = 0; y < plan.alphaHeight(i); y++) {
      for (var x = 0; x < plan.alphaWidth(i); x++) {
        final int atlasOffset = (plan.alphaAtlasY(i) + y) * plan.atlasWidth +
            plan.alphaAtlasX(i) +
            x;
        put(plan.alphaX(i) + x, plan.alphaY(i) + y, page[atlasOffset]);
      }
    }
  }
  return bytes;
}

final class _DenseSink implements CoverageSpanSink {
  _DenseSink(this.left, this.top, this.width, int height)
      : bytes = Uint8List(width * height);

  final int left;
  final int top;
  final int width;
  final Uint8List bytes;

  @override
  void span(int y, int xStart, int xEnd, int coverage) {
    final int start = (y - top) * width + xStart - left;
    bytes.fillRange(start, start + xEnd - xStart, coverage);
  }
}
