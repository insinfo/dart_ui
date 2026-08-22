import 'dart:typed_data';

import 'package:dart_ui/src/geometry/path.dart';
import 'package:dart_ui/src/geometry/rect.dart';
import 'package:dart_ui/src/geometry/transform2d.dart';
import 'package:dart_ui/src/rendering/gpu/vector/sparse_strips.dart';
import 'package:dart_ui/src/rendering/path/coverage_span_sink.dart';
import 'package:dart_ui/src/rendering/path/fill_rule.dart';
import 'package:dart_ui/src/rendering/path/scanline_filler.dart';
import 'package:test/test.dart';

void main() {
  group('SparseStripGenerator', () {
    test('reconstructs exact analytic coverage for representative paths', () {
      final cases = <({Path path, FillRule rule, Transform2D transform})>[
        (
          path: Path.rect(const Rect.fromLTRB(2.25, 3.5, 29.75, 21.25)),
          rule: FillRule.nonZero,
          transform: Transform2D.identity,
        ),
        (
          path: Path.oval(const Rect.fromLTRB(4, 2, 31, 27)),
          rule: FillRule.nonZero,
          transform: Transform2D.identity,
        ),
        (
          path: (PathBuilder()
                ..moveTo(1, 2)
                ..lineTo(34, 8)
                ..lineTo(12, 29)
                ..close())
              .build(),
          rule: FillRule.nonZero,
          transform: const Transform2D.translation(2.5, -1.25),
        ),
        (
          path: (PathBuilder()
                ..addRect(const Rect.fromLTRB(2, 2, 34, 30))
                ..addRect(const Rect.fromLTRB(10, 9, 26, 23)))
              .build(),
          rule: FillRule.evenOdd,
          transform: Transform2D.identity,
        ),
      ];
      const clip = Rect.fromLTRB(-3, -2, 40, 34);

      for (final value in cases) {
        final dense = _analyticCoverage(
          value.path,
          clip,
          rule: value.rule,
          transform: value.transform,
        );
        final sparse = SparseStripGenerator().fill(
          value.path,
          clip,
          rule: value.rule,
          transform: value.transform,
        );
        final reconstructed = _reconstruct(sparse, clip);

        expect(
          reconstructed,
          orderedEquals(dense),
          reason: 'sparse strips must be a representation change only',
        );
      }
    });

    test('large solid UI shape is proportional to strips, not mask area', () {
      const clip = Rect.fromLTRB(0, 0, 256, 256);
      final buffer = SparseStripGenerator().fill(Path.rect(clip), clip);

      expect(buffer.stripCount, 0);
      expect(buffer.fillCount, 256 ~/ kStripHeight);
      expect(buffer.alphaCount, 0);
      expect(buffer.encodedByteLength, lessThan(1024));
      expect(buffer.encodedByteLength, lessThan(256 * 256 ~/ 50));
    });

    test('curved edges store alpha only near the boundary', () {
      const clip = Rect.fromLTRB(0, 0, 256, 256);
      final buffer = SparseStripGenerator().fill(Path.oval(clip), clip);

      expect(buffer.stripCount, greaterThan(0));
      expect(buffer.fillCount, greaterThan(0));
      expect(buffer.alphaCount, lessThan(256 * 256 ~/ 4));
      expect(buffer.encodedByteLength, lessThan(256 * 256 ~/ 3));
    });

    test('empty and clipped-away paths produce no GPU work', () {
      const clip = Rect.fromLTRB(0, 0, 32, 32);
      final generator = SparseStripGenerator();

      var buffer = generator.fill(Path.empty, clip);
      expect(buffer.quadCount, 0);
      expect(buffer.encodedByteLength, 0);

      buffer = generator.fill(
        Path.rect(const Rect.fromLTRB(100, 100, 120, 120)),
        clip,
      );
      expect(buffer.quadCount, 0);
      expect(buffer.alphaCount, 0);
    });

    test('generator reuses its arena and resets visible counts', () {
      const clip = Rect.fromLTRB(0, 0, 64, 64);
      final generator = SparseStripGenerator();
      final first = generator.fill(Path.oval(clip), clip);
      final alphaArena = first.alphas;
      expect(first.alphaCount, greaterThan(0));

      final second = generator.fill(Path.empty, clip);
      expect(second, same(first));
      expect(second.alphas, same(alphaArena));
      expect(second.alphaCount, 0);
      expect(second.quadCount, 0);
    });
  });
}

Uint8List _analyticCoverage(
  Path path,
  Rect clip, {
  required FillRule rule,
  required Transform2D transform,
}) {
  final width = clip.right.ceil() - clip.left.floor();
  final height = clip.bottom.ceil() - clip.top.floor();
  final sink = _DenseSink(
    clipLeft: clip.left.floor(),
    clipTop: clip.top.floor(),
    width: width,
    height: height,
  );
  ScanlineFiller().fill(
    path,
    clip,
    sink,
    rule: rule,
    transform: transform,
  );
  return sink.bytes;
}

Uint8List _reconstruct(StripBuffer buffer, Rect clip) {
  final left = clip.left.floor();
  final top = clip.top.floor();
  final width = clip.right.ceil() - left;
  final height = clip.bottom.ceil() - top;
  final bytes = Uint8List(width * height);

  void put(int x, int y, int alpha) {
    final localX = x - left;
    final localY = y - top;
    if (localX < 0 || localX >= width || localY < 0 || localY >= height) {
      return;
    }
    bytes[localY * width + localX] = alpha;
  }

  for (var i = 0; i < buffer.fillCount; i++) {
    for (var row = 0; row < kStripHeight; row++) {
      for (var x = 0; x < buffer.fillWidth(i); x++) {
        put(buffer.fillX(i) + x, buffer.fillY(i) + row, 255);
      }
    }
  }
  for (var i = 0; i < buffer.stripCount; i++) {
    for (var row = 0; row < kStripHeight; row++) {
      for (var x = 0; x < buffer.stripWidth(i); x++) {
        put(
          buffer.stripX(i) + x,
          buffer.stripY(i) + row,
          buffer.stripAlpha(i, x, row),
        );
      }
    }
  }
  return bytes;
}

final class _DenseSink implements CoverageSpanSink {
  _DenseSink({
    required this.clipLeft,
    required this.clipTop,
    required this.width,
    required int height,
  }) : bytes = Uint8List(width * height);

  final int clipLeft;
  final int clipTop;
  final int width;
  final Uint8List bytes;

  @override
  void span(int y, int xStart, int xEnd, int coverage) {
    final start = (y - clipTop) * width + (xStart - clipLeft);
    bytes.fillRange(start, start + (xEnd - xStart), coverage);
  }
}
