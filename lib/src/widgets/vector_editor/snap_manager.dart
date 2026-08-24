/// Snapping manager for aligning coordinates to grid, guides, and object nodes.
library;

import '../../geometry/offset.dart';
import '../../graphics/vector/structural_objects.dart';

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
  double threshold;

  /// Snaps [point] to active grid lines or guidelines on [page].
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
}
