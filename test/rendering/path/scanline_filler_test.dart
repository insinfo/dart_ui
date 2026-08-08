import 'package:dart_ui/src/geometry/offset.dart';
import 'package:dart_ui/src/geometry/path.dart';
import 'package:dart_ui/src/geometry/rect.dart';
import 'package:dart_ui/src/geometry/transform2d.dart';
import 'package:dart_ui/src/rendering/path/fill_rule.dart';
import 'package:dart_ui/src/rendering/path/scanline_filler.dart';
import 'package:test/test.dart';

import 'support.dart';

/// Fills [path] and hands back the recorder, having checked the span contract.
SpanRecorder fill(
  ScanlineFiller filler,
  Path path,
  Rect clip, {
  FillRule rule = FillRule.nonZero,
  Transform2D transform = Transform2D.identity,
}) {
  final recorder = SpanRecorder();
  filler.fill(path, clip, recorder, rule: rule, transform: transform);
  expectSpanContract(recorder, clip);
  return recorder;
}

/// Compares every pixel of [clip] against the sampled reference.
void expectMatchesReference(
  SpanRecorder recorder,
  List<List<Offset>> contours,
  Rect clip,
  FillRule rule, {
  int tolerance = 2,
}) {
  for (var y = clip.top.floor(); y < clip.bottom.ceil(); y++) {
    for (var x = clip.left.floor(); x < clip.right.ceil(); x++) {
      expect(
        recorder.at(x, y),
        closeTo(sampledCoverage(contours, x, y, rule), tolerance),
        reason: 'pixel ($x, $y)\n${recorder.render(
          clip.right.ceil(),
          clip.bottom.ceil(),
        )}',
      );
    }
  }
}

void main() {
  late ScanlineFiller filler;

  setUp(() => filler = ScanlineFiller());

  group('shapes', () {
    test('a triangle matches an independent area reference', () {
      final corners = <Offset>[
        const Offset(1.5, 0.75),
        const Offset(10.25, 3.5),
        const Offset(4, 11.5),
      ];
      const clip = Rect.fromLTRB(0, 0, 12, 12);

      final recorder = fill(filler, polygonPath(corners), clip);

      expectMatchesReference(
        recorder,
        <List<Offset>>[corners],
        clip,
        FillRule.nonZero,
      );
    });

    test('a convex quad matches an independent area reference', () {
      final corners = <Offset>[
        const Offset(1, 2.5),
        const Offset(9.5, 1),
        const Offset(11, 8.25),
        const Offset(3.25, 10),
      ];
      const clip = Rect.fromLTRB(0, 0, 12, 12);

      final recorder = fill(filler, polygonPath(corners), clip);

      expectMatchesReference(
        recorder,
        <List<Offset>>[corners],
        clip,
        FillRule.nonZero,
      );
    });

    test('winding direction does not change the result', () {
      final corners = <Offset>[
        const Offset(1.5, 0.75),
        const Offset(10.25, 3.5),
        const Offset(4, 11.5),
      ];
      const clip = Rect.fromLTRB(0, 0, 12, 12);

      final clockwise = fill(filler, polygonPath(corners), clip);
      final other = fill(filler, polygonPath(corners.reversed.toList()), clip);

      expect(other.spans, clockwise.spans);
    });
  });

  group('fill rules', () {
    // The case the two rules exist to disagree about. The centre pentagon of
    // a self-crossing star is wound twice.
    final points = starPoints(const Offset(16, 16), 14);
    final star = polygonPath(points);
    const clip = Rect.fromLTRB(0, 0, 32, 32);
    final contours = <List<Offset>>[points];

    test('non-zero fills the star solid', () {
      final recorder = fill(filler, star, clip);

      expect(recorder.at(16, 16), 255, reason: 'centre is wound twice');
      expect(recorder.at(16, 8), 255, reason: 'a point of the star');
      expect(recorder.at(1, 1), 0, reason: 'outside');
    });

    test('even-odd leaves the twice-wound centre hollow', () {
      final recorder = fill(filler, star, clip, rule: FillRule.evenOdd);

      expect(recorder.at(16, 16), 0, reason: 'centre folds back to outside');
      expect(recorder.at(16, 8), 255, reason: 'a point is still wound once');
    });

    test('the two rules differ, and differ where the path crosses itself', () {
      final nonZero = fill(filler, star, clip);
      final evenOdd = fill(filler, star, clip, rule: FillRule.evenOdd);

      // Explicit, not implied: the same pixel is opaque under one rule and
      // absent under the other.
      expect(nonZero.at(16, 16), 255);
      expect(evenOdd.at(16, 16), 0);
      expect(nonZero.spans, isNot(evenOdd.spans));
      expect(evenOdd.pixelCount, lessThan(nonZero.pixelCount));

      // And they agree everywhere the winding is 0 or 1: outside, and in the
      // five points.
      expect(nonZero.at(16, 8), evenOdd.at(16, 8));
      expect(nonZero.at(0, 0), evenOdd.at(0, 0));
    });

    test('both rules agree with the reference away from the edges', () {
      for (final rule in FillRule.values) {
        final recorder = fill(filler, star, clip, rule: rule);
        for (var y = 0; y < 32; y++) {
          for (var x = 0; x < 32; x++) {
            // Only the pixels the reference calls entirely in or entirely
            // out. Boundary pixels are where the accumulation's documented
            // single-pixel approximation lives, and the sampled reference has
            // its own error there.
            final reference = sampledCoverage(contours, x, y, rule);
            if (reference == 255 || reference == 0) {
              expect(
                recorder.at(x, y),
                reference,
                reason: '$rule at ($x, $y)\n${recorder.render(32, 32)}',
              );
            }
          }
        }
      }
    });

    test('a rectangle inside a rectangle is a hole only under even-odd', () {
      final path = (PathBuilder()
            ..addRect(const Rect.fromLTRB(2, 2, 14, 14))
            ..addRect(const Rect.fromLTRB(5, 5, 11, 11)))
          .build();
      const clip = Rect.fromLTRB(0, 0, 16, 16);

      final nonZero = fill(filler, path, clip);
      final evenOdd = fill(filler, path, clip, rule: FillRule.evenOdd);

      expect(nonZero.at(8, 8), 255, reason: 'both wound the same way');
      expect(evenOdd.at(8, 8), 0, reason: 'two crossings: outside again');
      expect(nonZero.at(3, 8), 255);
      expect(evenOdd.at(3, 8), 255, reason: 'the ring itself is unaffected');
    });
  });

  group('agreement with an exact rectangle fill', () {
    test('a whole-pixel rectangle covers exactly the rectangle', () {
      const rect = Rect.fromLTRB(1, 1, 3, 3);
      const clip = Rect.fromLTRB(0, 0, 4, 4);

      final recorder = fill(filler, Path.rect(rect), clip);

      // The reference is the half-open rule `Rect.contains` and the
      // rasteriser's rectangle fills already use - deliberately computed here
      // rather than by calling the rasteriser, so that this stays a statement
      // about coverage and not about whatever the compositor does with it.
      expect(recorder.spans, <Span>[
        const Span(1, 1, 3, 255),
        const Span(2, 1, 3, 255),
      ]);
      for (var y = 0; y < 4; y++) {
        for (var x = 0; x < 4; x++) {
          final inside = rect.contains(Offset(x + 0.5, y + 0.5));
          expect(recorder.at(x, y), inside ? 255 : 0, reason: '($x, $y)');
        }
      }
    });

    test('a fractional rectangle covers the exact overlapping area', () {
      const rect = Rect.fromLTRB(1.25, 1.5, 3.75, 3.5);
      const clip = Rect.fromLTRB(0, 0, 5, 5);

      final recorder = fill(filler, Path.rect(rect), clip);

      // The same product-of-fractional-overlaps an antialiased rectangle fill
      // computes. Exact, not approximate: an axis-aligned rectangle is the one
      // case where the area is a product, and the filler has to land on it or
      // a path-drawn rectangle would not match a rectangle-drawn one.
      for (var y = 0; y < 5; y++) {
        for (var x = 0; x < 5; x++) {
          final overlapX = _overlap(rect.left, rect.right, x.toDouble());
          final overlapY = _overlap(rect.top, rect.bottom, y.toDouble());
          final expected = (overlapX * overlapY * 255 + 0.5).floor();
          expect(recorder.at(x, y), expected, reason: 'pixel ($x, $y)');
        }
      }
    });

    test('abutting rectangles never claim the same pixel twice', () {
      const clip = Rect.fromLTRB(0, 0, 4, 1);

      final left =
          fill(filler, Path.rect(const Rect.fromLTRB(0, 0, 2, 1)), clip);
      final right =
          fill(filler, Path.rect(const Rect.fromLTRB(2, 0, 4, 1)), clip);

      expect(left.spans, <Span>[const Span(0, 0, 2, 255)]);
      expect(right.spans, <Span>[const Span(0, 2, 4, 255)]);
    });
  });

  group('clipping', () {
    test('a path outside the clip emits nothing', () {
      const clip = Rect.fromLTRB(0, 0, 16, 16);

      for (final rect in <Rect>[
        const Rect.fromLTRB(100, 100, 120, 120),
        const Rect.fromLTRB(-40, 0, -10, 16),
        const Rect.fromLTRB(0, -40, 16, -1),
        const Rect.fromLTRB(0, 16, 16, 40),
      ]) {
        final recorder = fill(filler, Path.rect(rect), clip);
        expect(recorder.spans, isEmpty, reason: '$rect');
      }
    });

    test('a shape crossing the clip still fills the visible part', () {
      // The x-clamping case: an edge to the left of the clip winds around
      // every pixel in the row, so dropping it instead of clamping it would
      // leave the visible half unfilled.
      const clip = Rect.fromLTRB(4, 4, 8, 8);

      final recorder = fill(
        filler,
        Path.rect(const Rect.fromLTRB(-100, -100, 100, 100)),
        clip,
      );

      expect(recorder.spans, <Span>[
        const Span(4, 4, 8, 255),
        const Span(5, 4, 8, 255),
        const Span(6, 4, 8, 255),
        const Span(7, 4, 8, 255),
      ]);
    });

    test('a shape half inside is cut at the clip edge, not scaled', () {
      const clip = Rect.fromLTRB(0, 0, 4, 4);

      final recorder = fill(
        filler,
        Path.rect(const Rect.fromLTRB(2, 1, 40, 3)),
        clip,
      );

      expect(recorder.spans, <Span>[
        const Span(1, 2, 4, 255),
        const Span(2, 2, 4, 255),
      ]);
    });
  });

  group('degenerate input', () {
    test('a horizontal edge does not become a crossing', () {
      // A step, whose middle edge is exactly horizontal and lands on a pixel
      // boundary. Naive scanline code counts that edge as a crossing on row 4
      // and fills from x = 2 to the surface edge.
      final corners = <Offset>[
        const Offset(2, 2),
        const Offset(10, 2),
        const Offset(10, 4),
        const Offset(6, 4),
        const Offset(6, 8),
        const Offset(2, 8),
      ];
      const clip = Rect.fromLTRB(0, 0, 12, 12);

      final recorder = fill(filler, polygonPath(corners), clip);

      expect(recorder.spans, <Span>[
        const Span(2, 2, 10, 255),
        const Span(3, 2, 10, 255),
        const Span(4, 2, 6, 255),
        const Span(5, 2, 6, 255),
        const Span(6, 2, 6, 255),
        const Span(7, 2, 6, 255),
      ]);
    });

    test('a horizontal edge inside a scanline is still not a crossing', () {
      // The same shape shifted by half a pixel, so the horizontal edge sits
      // inside row 4 rather than on its boundary and the row is a blend of
      // both widths.
      final corners = <Offset>[
        const Offset(2, 2),
        const Offset(10, 2),
        const Offset(10, 4.5),
        const Offset(6, 4.5),
        const Offset(6, 8),
        const Offset(2, 8),
      ];
      const clip = Rect.fromLTRB(0, 0, 12, 12);

      final recorder = fill(filler, polygonPath(corners), clip);

      expect(recorder.at(3, 4), 255, reason: 'left of the step: fully inside');
      expect(recorder.at(7, 4), 128, reason: 'right of the step: half the row');
      expect(recorder.at(7, 5), 0);
      expect(recorder.at(7, 3), 255);
      expectMatchesReference(
        recorder,
        <List<Offset>>[corners],
        clip,
        FillRule.nonZero,
      );
    });

    test('shapes with no area emit nothing', () {
      const clip = Rect.fromLTRB(0, 0, 8, 8);

      final horizontalLine = (PathBuilder()
            ..moveTo(1, 4)
            ..lineTo(7, 4)
            ..close())
          .build();
      final repeatedPoint = (PathBuilder()
            ..moveTo(3, 3)
            ..lineTo(3, 3)
            ..lineTo(3, 3)
            ..close())
          .build();

      expect(fill(filler, horizontalLine, clip).spans, isEmpty);
      expect(fill(filler, repeatedPoint, clip).spans, isEmpty);
      expect(fill(filler, Path.empty, clip).spans, isEmpty);
    });

    test('an unclosed contour is filled as if it had been closed', () {
      const clip = Rect.fromLTRB(0, 0, 8, 8);
      final open = (PathBuilder()
            ..moveTo(1, 1)
            ..lineTo(5, 1)
            ..lineTo(5, 5)
            ..lineTo(1, 5))
          .build();

      expect(
        fill(filler, open, clip).spans,
        fill(filler, Path.rect(const Rect.fromLTRB(1, 1, 5, 5)), clip).spans,
      );
    });
  });

  group('transform', () {
    test('filling through a transform equals filling a transformed path', () {
      const clip = Rect.fromLTRB(0, 0, 32, 32);
      const transform = Transform2D(2, 0, 0, 2, 3, 1);
      final path = polygonPath(<Offset>[
        const Offset(1.5, 0.75),
        const Offset(10.25, 3.5),
        const Offset(4, 11.5),
      ]);

      final throughTransform = fill(filler, path, clip, transform: transform);
      final preTransformed = fill(filler, path.transform(transform), clip);

      expect(throughTransform.spans, preTransformed.spans);
    });
  });

  group('reuse', () {
    test('filling the same path a hundred times reallocates nothing', () {
      const clip = Rect.fromLTRB(0, 0, 32, 32);
      final star = polygonPath(starPoints(const Offset(16, 16), 14));

      // One warm-up fill sizes every buffer for this path.
      final first = fill(filler, star, clip);
      final growths = filler.bufferGrowths;
      expect(filler.edgeCapacity, greaterThan(0));
      expect(filler.accumulatorCapacity, greaterThanOrEqualTo(32));

      for (var i = 0; i < 100; i++) {
        final again = fill(filler, star, clip);
        expect(again.spans, first.spans, reason: 'fill $i drifted');
      }

      expect(filler.bufferGrowths, growths);
    });

    test('a larger path grows the buffers once and then stops', () {
      const small = Rect.fromLTRB(0, 0, 8, 8);
      const large = Rect.fromLTRB(0, 0, 256, 256);
      final path = Path.oval(const Rect.fromLTRB(1, 1, 250, 250));

      fill(filler, path, small);
      fill(filler, path, large);
      final growths = filler.bufferGrowths;

      for (var i = 0; i < 20; i++) {
        fill(filler, path, large);
      }

      expect(filler.bufferGrowths, growths);
    });
  });
}

/// Overlap between the interval [low], [high] and the unit pixel at [pixel].
double _overlap(double low, double high, double pixel) {
  final left = low > pixel ? low : pixel;
  final right = high < pixel + 1 ? high : pixel + 1;
  return right > left ? right - left : 0;
}
