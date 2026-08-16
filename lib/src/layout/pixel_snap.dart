/// Where logical coordinates meet the device grid.
///
/// # The decision (roadmap 25.5)
///
/// **Snapping is the painter's job, not the layout's.** Nothing in this
/// directory calls anything in this file; layout stays in logical pixels from
/// the root's constraints to the last child's offset, and a [PixelSnapper] is
/// applied at the boundary where a display list is turned into coverage - by
/// the code that already knows the device pixel ratio.
///
/// The roadmap states the conclusion ("O renderer conhece scale. O layout
/// permanece lógico"); here is the argument for it, because it is the kind of
/// rule that gets quietly broken.
///
///   * **A snapped size is not a size.** If layout rounded, a box's size would
///     depend on the monitor. The same tree would produce different geometry on
///     a 1x and a 1.5x display - not different *pixels*, which is expected, but
///     a different *layout*: a row of five 30.4px chips fits in 152px logical
///     and, snapped per chip at 1x, needs 155. Text would re-wrap when a window
///     was dragged between monitors, and a golden test would have to be
///     re-recorded per scale factor.
///   * **The error compounds down the tree.** Rounding at every level of a
///     ten-deep tree can accumulate ten half-pixels. Rounding once, at the
///     point of drawing, cannot: the error is bounded by half a device pixel
///     *per edge drawn*, regardless of depth.
///   * **Only the painter knows the scale**, and it can change - a window moved
///     between displays gets a new ratio without a single logical coordinate
///     changing. If layout owned snapping, that event would dirty the entire
///     render tree instead of just the raster.
///
/// # What snapping does, when it is applied
///
/// The one rule that matters: **snap edges, not origins-and-extents.** A box at
/// `x = 10.4` of width `9.2` has edges at 10.4 and 19.6. Rounding the origin to
/// 10 and the extent to 9 gives a right edge at 19, and the next box - whose
/// left edge rounds to 20 - is now a pixel away from it. Rounding both edges
/// gives 10 and 20, and the two boxes still touch. Gaps and overlaps between
/// adjacent snapped boxes are the entire failure mode this exists to prevent,
/// so [snapRect] is the primary operation and [snapExtent] is a convenience for
/// the cases where the origin is already integral.
///
/// # Deliberately out of scope
///
///   * **Glyph hinting.** Snapping a text origin to the pixel grid is
///     [PixelSnapPolicy.text]; moving a stem within a glyph outline is the
///     font's TrueType interpreter, and lives with the rasteriser.
///   * **Transforms.** These functions take numbers, not matrices. Under a
///     rotation there is no axis-aligned grid to snap to, and snapping the
///     corners of a rotated rectangle changes its shape.
///   * **Layout.** Stated above, and worth repeating: no `performLayout` in
///     this framework may call any of this.
library;

import '../geometry/offset.dart';
import '../geometry/rect.dart';

/// How much of the geometry is pulled onto the device grid.
enum PixelSnapPolicy {
  /// Nothing is snapped. Correct for a vector target - a PDF, an SVG - and for
  /// anything under a rotation.
  none,

  /// Box edges are snapped, so a fill's boundary is a hard pixel edge rather
  /// than a row of half-covered pixels. Text is left alone.
  edges,

  /// [edges], plus text origins and baselines. Keeps a line of text from
  /// landing between two rows of pixels, which is what makes small text look
  /// blurry rather than merely anti-aliased.
  text,

  /// [text], but rounding to the *device* grid at a non-integer scale rather
  /// than to the logical grid. At a ratio of 1.5 this snaps to multiples of
  /// two thirds of a logical pixel; the other policies would snap to whole
  /// logical pixels, which is a coarser grid than the display actually has and
  /// throws away a third of its resolution.
  devicePixel,
}

/// Rounds logical coordinates onto a device grid.
///
/// Immutable and cheap to construct: a painter holds one per target and
/// replaces it when the display's scale changes.
final class PixelSnapper {
  const PixelSnapper({
    this.policy = PixelSnapPolicy.none,
    this.devicePixelRatio = 1.0,
  });

  /// Snaps nothing. The default everywhere, so that a caller that has not
  /// thought about the question gets exact geometry rather than a surprise.
  static const PixelSnapper none = PixelSnapper();

  final PixelSnapPolicy policy;

  /// Device pixels per logical pixel. Only [PixelSnapPolicy.devicePixel] reads
  /// it; the others snap to the logical grid by definition.
  final double devicePixelRatio;

  /// Whether box edges are snapped under this policy.
  bool get snapsEdges => policy != PixelSnapPolicy.none;

  /// Whether text origins and baselines are snapped under this policy.
  bool get snapsText =>
      policy == PixelSnapPolicy.text || policy == PixelSnapPolicy.devicePixel;

  /// The grid spacing in logical pixels: 1 for the logical policies, and the
  /// reciprocal of the ratio for [PixelSnapPolicy.devicePixel].
  double get grid => policy == PixelSnapPolicy.devicePixel &&
          devicePixelRatio > 0 &&
          devicePixelRatio.isFinite
      ? 1.0 / devicePixelRatio
      : 1.0;

  /// One coordinate, rounded to the nearest grid line.
  ///
  /// Half-way values round **up**, toward positive infinity - not away from
  /// zero, which is what `roundToDouble` would give. The difference only shows
  /// at negative coordinates and it matters there: away-from-zero makes a
  /// rectangle spanning `-0.5 .. 0.5` snap to `-1 .. 1` and double in width,
  /// and makes two adjacent edges that are both at `x.5` round in opposite
  /// directions depending on which side of the origin they fell. Rounding up
  /// everywhere keeps snapping invariant under whole-pixel translation, which
  /// is the property a scrolled or panned scene depends on.
  double snapCoordinate(double value) {
    if (!snapsEdges || !value.isFinite) return value;
    final double step = grid;
    return (value / step + 0.5).floorToDouble() * step;
  }

  /// An extent, rounded to a whole number of grid steps but never to zero.
  ///
  /// The floor at one step is the difference between a hairline divider and an
  /// invisible one: a 0.4px separator under a rounding policy would vanish
  /// entirely, and a rule that is sometimes there and sometimes not is worse
  /// than one that is always a pixel thick. A genuinely zero extent stays zero,
  /// because that one was asked for.
  double snapExtent(double value) {
    if (!snapsEdges || !value.isFinite || value == 0.0) return value;
    final double step = grid;
    final double snapped = (value / step + 0.5).floorToDouble() * step;
    if (snapped != 0.0) return snapped;
    return value.isNegative ? -step : step;
  }

  /// A point, snapped on both axes.
  Offset snapOffset(Offset offset) => snapsEdges
      ? Offset(snapCoordinate(offset.dx), snapCoordinate(offset.dy))
      : offset;

  /// A rectangle, snapped **edge by edge**.
  ///
  /// This is the operation that keeps adjacent boxes adjacent; see the library
  /// comment. A rectangle that is non-empty before snapping stays non-empty
  /// after it, for the same reason [snapExtent] has a floor.
  Rect snapRect(Rect rect) {
    if (!snapsEdges) return rect;
    final double step = grid;
    final double left = snapCoordinate(rect.left);
    final double top = snapCoordinate(rect.top);
    double right = snapCoordinate(rect.right);
    double bottom = snapCoordinate(rect.bottom);
    if (right == left && rect.right != rect.left) right = left + step;
    if (bottom == top && rect.bottom != rect.top) bottom = top + step;
    return Rect.fromLTRB(left, top, right, bottom);
  }

  /// A text baseline, snapped only under a policy that says text should be.
  ///
  /// Separate from [snapCoordinate] because the two are genuinely different
  /// decisions: a design can want crisp box edges and unsnapped text - which is
  /// what you choose when the text is animating, since a snapped baseline makes
  /// a slow vertical slide crawl one pixel at a time instead of gliding.
  double snapBaseline(double value) {
    if (!snapsText || !value.isFinite) return value;
    final double step = grid;
    return (value / step + 0.5).floorToDouble() * step;
  }

  @override
  bool operator ==(Object other) =>
      other is PixelSnapper &&
      other.policy == policy &&
      other.devicePixelRatio == devicePixelRatio;

  @override
  int get hashCode => Object.hash(policy, devicePixelRatio);

  @override
  String toString() =>
      'PixelSnapper(${policy.name}, devicePixelRatio: $devicePixelRatio)';
}
