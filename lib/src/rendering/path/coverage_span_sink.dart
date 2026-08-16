/// Where a filled path's coverage goes.
///
/// The filler answers "which pixels, and how much of each" and stops there.
/// It does not know a framebuffer, a colour, a blend mode or a channel order,
/// and it never calls the rasteriser - the same separation the display-list
/// player keeps from `RasterSink`, and for a sharper reason here: coverage is
/// provable on its own. A span list can be compared against an exact area
/// computation in a unit test, while the same bug seen through a compositor
/// is one wrong byte among four in a picture.
///
/// It also keeps the filler usable for the things that are not painting:
/// building a clip mask, collecting a damage region, or measuring how much of
/// a shape survives a clip. Each is a different sink over the same walk.
library;

/// Receives horizontal runs of constant coverage, in increasing `y`.
///
/// The contract, stated tightly because a sink implementation cannot see the
/// filler's reasoning:
///
///   * Spans arrive with `y` non-decreasing, and within one `y` with
///     `xStart` strictly increasing. No two spans of one scanline overlap.
///   * `xStart` is inclusive, `xEnd` exclusive - the same half-open
///     convention `Rect` and the rasteriser's fills use, so abutting shapes
///     never both claim a pixel.
///   * `coverage` is 1..255 and never 0: a fully transparent run is not
///     reported at all, so a sink never has to test for it. 255 means the
///     pixel is entirely inside the path.
///   * Every span lies inside the clip rectangle the fill was given.
///
/// `coverage` is an alpha in the compositor's own units. It is the value that
/// goes into `mul255(paintAlpha, coverage)` before the composite equation,
/// which is why it is a byte rounded to nearest rather than a float: rounding
/// once here, with the same rule `mul255` uses, keeps a full-coverage span
/// exactly as opaque as the equivalent rectangle fill.
///
/// ## Where the blend mode is, and why it is not here
///
/// A paint's blend mode is a property of the *fill*, not of a span: every span
/// of one filled path composites with the same equation, and threading it
/// through this method would put a value on the hot path that cannot change
/// along it. So the sink that paints - `_CoverageToRasterizer` in
/// `cpu_renderer.dart` - resolves the mode once when the fill starts and holds
/// it, and this interface stays what it was: geometry and coverage, provable
/// on its own against an exact area computation, and still usable by the sinks
/// that do not paint at all (a clip mask, a damage region).
abstract interface class CoverageSpanSink {
  /// One run of pixels on scanline [y], from [xStart] up to but not
  /// including [xEnd], each covered by [coverage] of 255.
  void span(int y, int xStart, int xEnd, int coverage);
}
