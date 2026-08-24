/// Snapping manager for aligning coordinates to grid, guides, and object nodes.
///
/// ## Two snaps, not one
///
/// [snapPoint] snaps a **pointer**. That is right for a tool that is drawing a
/// shape from nothing: the corner of a new rectangle is wherever the pointer
/// is, so pulling the pointer onto a grid line puts the corner on it.
///
/// It is the wrong thing for a *drag*, and it was the only thing here. When an
/// object is being moved, the pointer is not a corner of anything: it is
/// wherever inside the shape the user happened to grab it. Snapping it makes
/// the object jump by whatever the grab offset was and lands its edges nowhere
/// in particular - the shape moves *because* it snapped, and it still is not
/// aligned to anything. sK1 snaps the **edges of the transformed bounding
/// box** (`MoveController._snap`), which is the thing the user can see and the
/// thing they are trying to line up.
///
/// So [correctionFor] is the drag snap: it takes the box as the drag has
/// already moved it and returns the small extra nudge that puts its nearest
/// edge - or its centre line - onto a grid line or a guide. A caller adds that
/// to the delta it was going to apply. The shape creators keep [snapPoint],
/// unchanged, because for them it is correct.
library;

import '../../geometry/offset.dart';
import '../../geometry/rect.dart';
import '../../graphics/vector/structural_objects.dart';
import 'selection.dart';

/// Which lines of a box a drag snap is allowed to move onto a guide.
///
/// A move offers all three on each axis: any edge of the box, or its centre
/// line, may be what the user is lining up. A resize offers only the edges the
/// handle is actually dragging - snapping the *anchored* edge of a resize would
/// mean the anchor moved, which is the one thing a resize promises not to do.
final class SnapEdges {
  const SnapEdges({
    this.left = false,
    this.centerX = false,
    this.right = false,
    this.top = false,
    this.centerY = false,
    this.bottom = false,
  });

  /// Every edge and both centre lines: what a move offers.
  static const SnapEdges all = SnapEdges(
    left: true,
    centerX: true,
    right: true,
    top: true,
    centerY: true,
    bottom: true,
  );

  final bool left;
  final bool centerX;
  final bool right;
  final bool top;
  final bool centerY;
  final bool bottom;

  bool get hasHorizontal => left || centerX || right;
  bool get hasVertical => top || centerY || bottom;

  /// The x coordinates of [bounds] this permits.
  List<double> xsOf(Rect bounds) => <double>[
        if (left) bounds.left,
        if (centerX) bounds.center.dx,
        if (right) bounds.right,
      ];

  /// The y coordinates of [bounds] this permits.
  List<double> ysOf(Rect bounds) => <double>[
        if (top) bounds.top,
        if (centerY) bounds.center.dy,
        if (bottom) bounds.bottom,
      ];
}

/// Alignment helper that snaps cursor and object coordinates.
class SnapManager {
  SnapManager({
    this.snapToGrid = true,
    this.snapToGuides = true,
    this.snapToObjects = true,
    this.gridSpacing = 28.346, // ~10 mm
    this.threshold = 6.0,
  });

  bool snapToGrid;
  bool snapToGuides;
  bool snapToObjects;
  double gridSpacing;

  /// How close, in **document units**, a coordinate has to be to snap.
  ///
  /// Document units and not pixels, which is why a drag passes its own
  /// tolerance: see [dragPixels].
  double threshold;

  /// How close, in **device pixels**, a dragged edge has to be to snap.
  ///
  /// A drag's tolerance is a screen distance for the same reason a handle's
  /// is: at 20% zoom, six document units is barely over a pixel and the snap
  /// never fires; at 800% it is a fifty-pixel magnet that makes the object
  /// impossible to place. Callers divide by the zoom - the canvas does it in
  /// one place - which is what [SelectionManager.handleGrabPixels] does too.
  static const double dragPixels = 6.0;

  /// Snaps [point] to active grid lines or guidelines on [page].
  ///
  /// The **pointer** snap. Right for a tool drawing a shape from the pointer,
  /// wrong for a drag; see the library comment.
  ///
  /// Returns the adjusted [Offset].
  Offset snapPoint(Offset point, VectorPage page) {
    var sx = point.dx;
    var sy = point.dy;

    // 1. Snap to guides
    if (snapToGuides) {
      for (final child in page.children) {
        if (child is GuideLayer && child.isVisible) {
          for (final g in child.children) {
            if (g is VectorGuide) {
              if (g.isHorizontal) {
                if ((point.dy - g.position).abs() <= threshold) {
                  sy = g.position;
                }
              } else {
                if ((point.dx - g.position).abs() <= threshold) {
                  sx = g.position;
                }
              }
            }
          }
        }
      }
    }

    // 2. Snap to grid
    if (snapToGrid) {
      final nearestGridX = (point.dx / gridSpacing).round() * gridSpacing;
      final nearestGridY = (point.dy / gridSpacing).round() * gridSpacing;

      if ((point.dx - nearestGridX).abs() <= threshold) {
        sx = nearestGridX;
      }
      if ((point.dy - nearestGridY).abs() <= threshold) {
        sy = nearestGridY;
      }
    }

    return Offset(sx, sy);
  }

  /// The extra nudge that lands an edge of [bounds] on a grid line or guide.
  ///
  /// The **drag** snap, and the one a move or a resize uses. [bounds] is the
  /// box as the gesture has already moved or resized it; the returned offset is
  /// what to add on top, and it is [Offset.zero] when nothing is near enough.
  ///
  /// One correction per axis, and it is the *smallest* one on offer: three
  /// candidate lines per axis would otherwise fight, and a box whose left edge
  /// and centre are both near a grid line would be pulled twice. Picking the
  /// nearest is also what makes the snap feel like a magnet rather than like a
  /// rule - the edge you have almost lined up is the one that clicks into
  /// place.
  ///
  /// [tolerance] defaults to [threshold]; a canvas passes
  /// `SnapManager.dragPixels / zoom`.
  Offset correctionFor(
    Rect bounds,
    VectorPage page, {
    SnapEdges edges = SnapEdges.all,
    double? tolerance,
  }) {
    if (bounds == Rect.zero) return Offset.zero;
    final double limit = tolerance ?? threshold;
    if (limit <= 0) return Offset.zero;

    double? bestX;
    double? bestY;

    void offerX(double from, double to) {
      final double correction = to - from;
      if (correction.abs() > limit) return;
      if (bestX == null || correction.abs() < bestX!.abs()) bestX = correction;
    }

    void offerY(double from, double to) {
      final double correction = to - from;
      if (correction.abs() > limit) return;
      if (bestY == null || correction.abs() < bestY!.abs()) bestY = correction;
    }

    final List<double> xs = edges.xsOf(bounds);
    final List<double> ys = edges.ysOf(bounds);

    // Guides first, and grid second, so that when both are within reach the
    // grid can only win by being strictly closer. A guide is something the
    // user put there on purpose; the grid is everywhere.
    if (snapToGuides) {
      for (final child in page.children) {
        if (child is! GuideLayer || !child.isVisible) continue;
        for (final g in child.children) {
          if (g is! VectorGuide) continue;
          if (g.isHorizontal) {
            for (final y in ys) {
              offerY(y, g.position);
            }
          } else {
            for (final x in xs) {
              offerX(x, g.position);
            }
          }
        }
      }
    }

    if (snapToGrid && gridSpacing > 0) {
      for (final x in xs) {
        offerX(x, (x / gridSpacing).round() * gridSpacing);
      }
      for (final y in ys) {
        offerY(y, (y / gridSpacing).round() * gridSpacing);
      }
    }

    return Offset(bestX ?? 0, bestY ?? 0);
  }

  /// Which lines a drag of [handle] is allowed to snap.
  ///
  /// Null [handle] is a move, which offers everything. A resize offers only
  /// the edges that handle moves: a corner offers two, an edge handle one, and
  /// neither offers a centre line - a resize about a fixed anchor has no
  /// meaningful centre to align, because the centre moves as a side effect of
  /// the size rather than being placed.
  static SnapEdges edgesForHandle(TransformHandle? handle) => switch (handle) {
        null => SnapEdges.all,
        TransformHandle.topLeft => const SnapEdges(left: true, top: true),
        TransformHandle.topCenter => const SnapEdges(top: true),
        TransformHandle.topRight => const SnapEdges(right: true, top: true),
        TransformHandle.midRight => const SnapEdges(right: true),
        TransformHandle.bottomRight =>
          const SnapEdges(right: true, bottom: true),
        TransformHandle.bottomCenter => const SnapEdges(bottom: true),
        TransformHandle.bottomLeft => const SnapEdges(left: true, bottom: true),
        TransformHandle.midLeft => const SnapEdges(left: true),
        // The pivot is placed, not sized: it snaps on both axes like a point.
        TransformHandle.rotationCenter => SnapEdges.all,
      };
}
