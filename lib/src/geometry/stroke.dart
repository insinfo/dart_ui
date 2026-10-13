/// What a pen does at the ends of an open contour and at its corners -
/// shared by the display list, which records it, and the stroker, which
/// draws it.
library;

/// How an open contour's ends are finished.
enum StrokeCap {
  /// Stops at the endpoint. A dot - a contour with no length - draws nothing.
  butt,

  /// A semicircle of radius `width / 2` beyond the endpoint. A dot draws a
  /// filled circle, which is what makes a single tap or a lone `moveTo`
  /// visible.
  round,

  /// Extends by `width / 2` and squares off, so the end is a rectangle. A dot
  /// draws an axis-aligned square: with no segment there is no direction to
  /// align the square to, and picking the axes is the only answer that does
  /// not depend on invisible state.
  square,
}

/// How the outer side of a corner is filled in.
enum StrokeJoin {
  /// Extends both offset edges to their intersection, unless that point is
  /// further from the corner than the pen's miter limit allows, in which
  /// case this behaves as [bevel].
  miter,

  /// A circular arc of radius `width / 2` centred on the corner.
  round,

  /// A straight line between the two offset points.
  bevel,
}

/// The miter limit a pen has unless told otherwise - SVG's, PostScript's,
/// Direct2D's and Skia's.
const double kDefaultMiterLimit = 4.0;

/// The rarer half of a pen: a miter limit other than [kDefaultMiterLimit],
/// and a dash pattern. A value, compared by content, so a display list can
/// intern it.
final class StrokeExtras {
  const StrokeExtras._(this.miterLimit, this.dashArray, this.dashOffset);

  /// [miterLimit], [dashArray] and [dashOffset] as a pen can use them, or
  /// null when they say nothing a default pen does not.
  ///
  /// The dash rules are SVG's, so a pattern read from a file means what it
  /// meant there: an odd-length list is repeated to make it even; a list
  /// with a negative or non-finite entry, or one whose entries add up to
  /// zero, draws a solid line. A miter limit below 1 is 1 - every miter is
  /// at least as long as the stroke is wide.
  static StrokeExtras? of(
    double miterLimit,
    List<double>? dashArray,
    double dashOffset,
  ) {
    final double miter = !miterLimit.isFinite
        ? kDefaultMiterLimit
        : miterLimit < 1
            ? 1.0
            : miterLimit;
    List<double>? dashes;
    if (dashArray != null && dashArray.isNotEmpty) {
      var total = 0.0;
      var valid = true;
      for (final double d in dashArray) {
        if (!d.isFinite || d < 0) valid = false;
        total += d;
      }
      if (valid && total > 0) {
        dashes = List<double>.unmodifiable(dashArray.length.isOdd
            ? <double>[...dashArray, ...dashArray]
            : dashArray);
      }
    }
    if (dashes == null && miter == kDefaultMiterLimit) return null;
    return StrokeExtras._(
      miter,
      dashes,
      dashes == null || !dashOffset.isFinite ? 0.0 : dashOffset,
    );
  }

  /// How long a miter may get, as a multiple of the stroke width, before
  /// the corner is beveled instead.
  final double miterLimit;

  /// Dash and gap lengths, alternating, starting with a dash; an even
  /// number of them. Null for a solid line.
  final List<double>? dashArray;

  /// How far into the pattern the line starts.
  final double dashOffset;

  @override
  bool operator ==(Object other) {
    if (other is! StrokeExtras ||
        other.miterLimit != miterLimit ||
        other.dashOffset != dashOffset) {
      return false;
    }
    final List<double>? a = dashArray;
    final List<double>? b = other.dashArray;
    if (a == null || b == null) return a == b;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(miterLimit, dashOffset,
      dashArray == null ? null : Object.hashAll(dashArray!));

  @override
  String toString() => 'StrokeExtras(miter $miterLimit'
      '${dashArray == null ? '' : ', dash $dashArray offset $dashOffset'})';
}
