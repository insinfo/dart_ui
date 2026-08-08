/// Exact per-pixel coverage for axis-aligned rectangles.
///
/// Coverage is "how much of this pixel does the shape occupy", as a byte in
/// 0..255 that the rasteriser folds into the source alpha. For an axis-aligned
/// rectangle it is not an estimate and needs no sampling: the area of the
/// overlap between a pixel square and the rectangle is the product of the
/// overlap along x and the overlap along y, and each of those is one
/// subtraction. That separability is the whole reason rectangle antialiasing
/// is cheap enough to do on the boundary of every fill - a general path has to
/// accumulate a signed area per scanline instead.
///
/// QUANTISATION, AND WHY IT IS ANCHORED TO THE SURFACE ORIGIN. The obvious
/// implementation, `round(overlapWidth * 255)`, loses a unit of area at the
/// edges: a rectangle one pixel wide sitting halfway between two columns gives
/// `round(0.5 * 255) = 128` twice, and 128 + 128 is 256. That extra unit is a
/// seam - a column a shade too bright where two halves of one pixel meet.
///
/// So this file quantises *positions*, not widths: [_quantise] maps a device-
/// space coordinate to 1/255ths of a pixel measured from the surface origin,
/// and a pixel's coverage is the difference of the two quantised positions
/// bounding it. Adjacent pixels share a boundary, and the shared position
/// quantises to the same integer for both, so the errors cancel and the
/// coverages telescope: they sum to `quantise(end) - quantise(start)` exactly,
/// for any span, with no accumulated drift.
///
/// One consequence to expect rather than be surprised by: a span offset by
/// exactly half a pixel splits as 127 and 128, not 128 and 128. Conservation
/// forces the two to sum to 255, which is odd, so an exactly symmetric split is
/// not representable in 8 bits. Preferring the symmetric-looking answer would
/// mean giving up conservation, and the asymmetry is invisible while the seam
/// is not.
library;

/// A device-space coordinate in 1/255ths of a pixel, rounded to nearest.
///
/// Anchored at the surface origin, so the same boundary always quantises to
/// the same value no matter which rectangle is asking. That is what makes the
/// differences in [spanCoverage] telescope.
int _quantise(double position) => (position * 255.0 + 0.5).floor();

/// Coverage of the pixel occupying `[index, index + 1)` by the device-space
/// span `[start, end)`, as a byte in 0..255.
///
/// Returns 0 when the pixel lies entirely outside, and exactly 255 when it
/// lies entirely inside - the second is what lets the rasteriser send interior
/// pixels down the same fast path a non-antialiased fill uses, with the
/// antialiasing cost falling only on the boundary.
int spanCoverage(double start, double end, int index) {
  final low = start > index ? start : index.toDouble();
  final high = end < index + 1 ? end : index + 1.0;
  // Half-open, matching Rect: a pixel the span merely touches is not covered.
  if (high <= low) return 0;
  return _quantise(high) - _quantise(low);
}

/// First pixel index a span starting at [start] touches.
int firstCoveredPixel(double start) => start.floor();

/// One past the last pixel index a span ending at [end] touches.
///
/// `ceil` rather than the fill's round-to-nearest: an antialiased edge at 10.2
/// still puts ink in column 10, so the iteration bound has to be generous
/// where the hard-edged bound could round it away. [spanCoverage] returns 0 for
/// any pixel that turns out not to be touched, so being generous here costs at
/// most one column and one row of coverage tests per fill.
int coveredPixelEnd(double end) => end.ceil();
