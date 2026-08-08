/// Overlapping children, aligned or explicitly positioned.
library;

import 'dart:math' as math;

import '../geometry/offset.dart';
import '../geometry/size.dart';
import 'alignment.dart';
import 'box_constraints.dart';
import 'render_box.dart';

/// How a [RenderStack] constrains its non-positioned children.
enum StackFit {
  /// Children may be any size up to the stack's own maximum.
  loose,

  /// Children are forced to the stack's biggest allowed size.
  expand,

  /// Children get the stack's own constraints unchanged, minima included.
  passthrough,
}

/// Per-child inputs a [RenderStack] reads.
///
/// A child with no edge or extent set is *non-positioned*: it is sized like
/// the others and placed by the stack's alignment. Setting any of these makes
/// it positioned, and positioned children take no part in deciding the stack's
/// size - which is the point, since a stack that grew to contain a child
/// pinned 20px from its right edge could never settle.
final class StackParentData extends BoxParentData {
  double? left;
  double? top;
  double? right;
  double? bottom;
  double? width;
  double? height;

  bool get isPositioned =>
      left != null ||
      top != null ||
      right != null ||
      bottom != null ||
      width != null ||
      height != null;

  @override
  String toString() => 'StackParentData(offset: $offset, '
      'l: $left, t: $top, r: $right, b: $bottom, w: $width, h: $height)';
}

/// Paints its children in order, all sharing the same box.
///
/// Sizing: with at least one non-positioned child the stack is as large as the
/// largest of them (constrained). With none, it fills what it is given, since
/// there is nothing to measure - and falls back to its minimum on an unbounded
/// axis, per [BoxConstraints.largestFinite].
///
/// Overflow is not clipped, matching `RenderFlex`; the reasoning there applies
/// here unchanged, and a positioned child with a negative edge is often
/// deliberately outside the box.
final class RenderStack extends RenderBoxContainer<StackParentData> {
  RenderStack({
    Alignment alignment = Alignment.topLeft,
    StackFit fit = StackFit.loose,
  })  : _alignment = alignment,
        _fit = fit;

  Alignment _alignment;
  StackFit _fit;

  Alignment get alignment => _alignment;

  set alignment(Alignment value) {
    if (value == _alignment) return;
    _alignment = value;
    markNeedsLayout();
  }

  StackFit get fit => _fit;

  set fit(StackFit value) {
    if (value == _fit) return;
    _fit = value;
    markNeedsLayout();
  }

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! StackParentData) {
      child.parentData = StackParentData();
    }
  }

  /// Pins [child] to the given edges and/or extents.
  ///
  /// Passing both edges on an axis stretches the child between them; passing
  /// one edge and an extent fixes it; passing neither leaves that axis to the
  /// stack's [alignment].
  void position(
    RenderBox child, {
    double? left,
    double? top,
    double? right,
    double? bottom,
    double? width,
    double? height,
  }) {
    final StackParentData data = childParentData(child);
    data
      ..left = left
      ..top = top
      ..right = right
      ..bottom = bottom
      ..width = width
      ..height = height;
    markNeedsLayout();
  }

  @override
  void performLayout() {
    final BoxConstraints constraints = this.constraints;
    final int count = childCount;

    final BoxConstraints nonPositioned = switch (_fit) {
      StackFit.loose => constraints.loosen(),
      StackFit.expand => BoxConstraints.tight(constraints.largestFinite),
      StackFit.passthrough => constraints,
    };

    bool hasNonPositioned = false;
    double width = constraints.minWidth;
    double height = constraints.minHeight;

    for (int i = 0; i < count; i++) {
      final RenderBox child = childAt(i);
      if (childParentData(child).isPositioned) continue;
      hasNonPositioned = true;
      child.layout(nonPositioned, parentUsesSize: true);
      final Size childSize = child.size;
      width = math.max(width, childSize.width);
      height = math.max(height, childSize.height);
    }

    size = hasNonPositioned
        ? constraints.constrain(Size(width, height))
        : constraints.largestFinite;

    // Placed only after the stack's own size is known, because a positioned
    // child's constraints are expressed relative to it.
    final Size resolved = size;
    for (int i = 0; i < count; i++) {
      final RenderBox child = childAt(i);
      final StackParentData data = childParentData(child);
      if (!data.isPositioned) {
        data.offset = _alignment.offsetFor(child.size, resolved);
        continue;
      }
      _layoutPositioned(child, data, resolved);
    }
  }

  void _layoutPositioned(
    RenderBox child,
    StackParentData data,
    Size stackSize,
  ) {
    double minWidth = 0.0;
    double maxWidth = double.infinity;
    if (data.left != null && data.right != null) {
      minWidth = maxWidth = math.max(
        0.0,
        stackSize.width - data.left! - data.right!,
      );
    } else if (data.width != null) {
      minWidth = maxWidth = math.max(0.0, data.width!);
    }

    double minHeight = 0.0;
    double maxHeight = double.infinity;
    if (data.top != null && data.bottom != null) {
      minHeight = maxHeight = math.max(
        0.0,
        stackSize.height - data.top! - data.bottom!,
      );
    } else if (data.height != null) {
      minHeight = maxHeight = math.max(0.0, data.height!);
    }

    child.layout(
      BoxConstraints(
        minWidth: minWidth,
        maxWidth: maxWidth,
        minHeight: minHeight,
        maxHeight: maxHeight,
      ),
      parentUsesSize: true,
    );
    final Size childSize = child.size;

    // An axis with neither edge given falls back to the stack's alignment,
    // which is what makes "centred, but 8px from the bottom" expressible.
    final double dx = data.left ??
        (data.right != null
            ? stackSize.width - data.right! - childSize.width
            : _alignment.offsetFor(childSize, stackSize).dx);
    final double dy = data.top ??
        (data.bottom != null
            ? stackSize.height - data.bottom! - childSize.height
            : _alignment.offsetFor(childSize, stackSize).dy);
    data.offset = Offset(dx, dy);
  }
}
