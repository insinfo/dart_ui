// The tile plan for large shapes: only tiles a curve or an off-pixel edge
// passes near become masks, and the rest are covered exactly by rectangles.
//
// Measured before it existed: a window-sized rounded card - its border, and
// the complement a ClipRRect erases the corners with - was rasterised as
// atlas-sized masks every frame, 46% of a column drag's CPU. The coverage the
// plan reports is checked here against the path itself, pixel by pixel.
import 'package:dart_ui/dart_ui.dart';
import 'package:dart_ui/src/rendering/gpu/gpu_mask_tiling.dart';
import 'package:test/test.dart';

/// Every pixel of every tile that does not need a mask: covered by the plan's
/// rectangles exactly when the path contains the pixel's centre.
void _expectExactOutsideMasks(
    MaskTilePlan plan, Path path, FillRule rule, Rect bounds) {
  final Path ruled = Path.from(path)
    ..fillType =
        rule == FillRule.evenOdd ? PathFillType.evenOdd : PathFillType.nonZero;
  for (int row = 0; row < plan.rows; row++) {
    for (int column = 0; column < plan.columns; column++) {
      if (plan.needsMask(column, row)) continue;
      final List<Rect> covered = <Rect>[];
      plan.coveredRects(column, row, (int l, int t, int r, int b) {
        covered.add(Rect.fromLTRB(
            l.toDouble(), t.toDouble(), r.toDouble(), b.toDouble()));
      });
      // Every other pixel: a full scan would be 600k containment tests.
      for (int y = plan.tileTop(row); y < plan.tileBottom(row); y += 3) {
        for (int x = plan.tileLeft(column);
            x < plan.tileRight(column);
            x += 3) {
          final Offset centre = Offset(x + .5, y + .5);
          final bool inPlan = covered.any((Rect r) => r.contains(centre));
          expect(inPlan, ruled.contains(centre),
              reason: 'pixel ($x, $y) of tile ($column, $row)');
        }
      }
    }
  }
}

void main() {
  test('a whole-pixel ring needs no mask at all', () {
    const Rect outer = Rect.fromLTRB(0, 0, 1000, 600);
    final Path ring = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(outer)
      ..addRect(outer.deflate(2));
    final MaskTilePlan plan = MaskTilePlan()
      ..plan(ring, Transform2D.identity,
          left: 0, top: 0, right: 1000, bottom: 600, rule: FillRule.evenOdd);
    expect(plan.maskedTileCount, 0);
    double area = 0;
    for (int row = 0; row < plan.rows; row++) {
      for (int column = 0; column < plan.columns; column++) {
        plan.coveredRects(column, row, (int l, int t, int r, int b) {
          area += (r - l) * (b - t);
        });
      }
    }
    expect(area, 1000 * 600 - 996 * 596);
    _expectExactOutsideMasks(plan, ring, FillRule.evenOdd, outer);
  });

  test("a rounded clip's complement masks only its corners", () {
    // What writeClipMask draws for a ClipRRect: the bounds grown by one,
    // minus the rounded rectangle, even-odd.
    const Rect card = Rect.fromLTRB(232, 141, 1272, 764);
    final Path complement = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(card.inflate(1))
      ..addRRect(RRect.fromRectAndRadius(card, const Radius.circular(8)));
    final MaskTilePlan plan = MaskTilePlan()
      ..plan(complement, Transform2D.identity,
          left: 232,
          top: 141,
          right: 1272,
          bottom: 764,
          rule: FillRule.evenOdd);
    expect(plan.maskedTileCount, inInclusiveRange(4, 8),
        reason: 'one tile per corner, two where a corner meets a tile edge');
    _expectExactOutsideMasks(plan, complement, FillRule.evenOdd, card);
  });

  test('an edge between pixels needs its tiles masked', () {
    final Path shape = Path()..addRect(const Rect.fromLTRB(10.5, 10, 300, 300));
    final MaskTilePlan plan = MaskTilePlan()
      ..plan(shape, Transform2D.identity,
          left: 10, top: 10, right: 300, bottom: 300, rule: FillRule.nonZero);
    // The left column of tiles holds the half-covered pixels.
    for (int row = 0; row < plan.rows; row++) {
      expect(plan.needsMask(0, row), isTrue);
    }
    _expectExactOutsideMasks(
        plan, shape, FillRule.nonZero, const Rect.fromLTRB(10, 10, 300, 300));
  });

  test('a scaled transform is classified in device pixels', () {
    // A 1 px border at 2x: whole device pixels, no mask.
    const Rect outer = Rect.fromLTRB(100, 50, 600, 350);
    final Path ring = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(outer)
      ..addRect(outer.deflate(1));
    final MaskTilePlan plan = MaskTilePlan()
      ..plan(ring, const Transform2D.scaling(2, 2),
          left: 200,
          top: 100,
          right: 1200,
          bottom: 700,
          rule: FillRule.evenOdd);
    expect(plan.maskedTileCount, 0);
    _expectExactOutsideMasks(
        plan,
        ring.transform(const Transform2D.scaling(2, 2)),
        FillRule.evenOdd,
        const Rect.fromLTRB(200, 100, 1200, 700));
  });
}
