/// Arrowheads: the shapes an outline's open ends can finish in, by the
/// index `StrokeDescriptor.startArrow` and `endArrow` keep.
///
/// An arrowhead is a filled shape drawn in the outline's colour, sized by the
/// outline's width so a heavier line gets a heavier head, and placed with its
/// base on the line's end and its point beyond it. That placement is what
/// keeps the line out of the point: a line ending *at* the point would show
/// its butt end through the narrow tip of every pointed head.
library;

import 'dart:math' as math;

import '../../geometry/offset.dart';
import '../../geometry/path.dart';
import '../../geometry/rect.dart';

/// The arrowheads, in the order their indices name them. Index 0 is none.
enum ArrowHead {
  none('None'),
  triangle('Triangle'),
  open('Open'),
  stealth('Stealth'),
  circle('Circle'),
  square('Square'),
  diamond('Diamond'),
  bar('Bar');

  const ArrowHead(this.label);

  /// What a menu calls it.
  final String label;

  /// The head an index names; out of range is none.
  static ArrowHead of(int? index) =>
      index == null || index < 0 || index >= values.length
          ? none
          : values[index];

  /// The head for an outline of [width] ending at [end], the line arriving
  /// along [direction] (pointing out of the line, any length), or null for
  /// [none] or a direction of no length.
  Path? at(Offset end, Offset direction, double width) {
    if (this == none) return null;
    final double length = direction.distance;
    if (length == 0 || !length.isFinite) return null;
    // A unit along the line and one across it.
    final Offset u = direction / length;
    final Offset n = Offset(-u.dy, u.dx);
    // Never smaller than a hairline's head would read as.
    final double w = math.max(width, 0.75);
    final double long = 4 * w;
    final double half = 2 * w;
    Offset p(double along, double across) => end + u * along + n * across;
    final PathBuilder b = PathBuilder();
    void polygon(List<Offset> points) {
      b.moveTo(points.first.dx, points.first.dy);
      for (final Offset q in points.skip(1)) {
        b.lineTo(q.dx, q.dy);
      }
      b.close();
    }

    switch (this) {
      case triangle:
        polygon(<Offset>[p(long, 0), p(0, half), p(0, -half)]);
      case stealth:
        // Swept back: the base notched in towards the point.
        polygon(<Offset>[
          p(long, 0),
          p(-long * .25, half),
          p(long * .2, 0),
          p(-long * .25, -half),
        ]);
      case open:
        // A chevron as thick as the line, open at the back.
        final double t = w;
        polygon(<Offset>[
          p(long, 0),
          p(0, half + t * .5),
          p(-t, half - t * .5),
          p(long - t * 1.6, 0),
          p(-t, -half + t * .5),
          p(0, -half - t * .5),
        ]);
      case circle:
        final Offset c = p(half, 0);
        b.addOval(Rect.fromLTWH(c.dx - half, c.dy - half, half * 2, half * 2));
      case square:
        polygon(<Offset>[
          p(0, half),
          p(half * 2, half),
          p(half * 2, -half),
          p(0, -half),
        ]);
      case diamond:
        polygon(<Offset>[
          p(0, 0),
          p(long * .5, half),
          p(long, 0),
          p(long * .5, -half),
        ]);
      case bar:
        polygon(<Offset>[
          p(0, half * 1.5),
          p(w, half * 1.5),
          p(w, -half * 1.5),
          p(0, -half * 1.5),
        ]);
      case none:
        return null;
    }
    return b.build();
  }
}
