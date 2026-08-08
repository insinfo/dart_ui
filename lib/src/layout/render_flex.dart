/// Rows and columns: the node that proves the layout protocol carries its
/// weight.
///
/// Everything else in this directory lays out at most one child and can get
/// away with passing its constraints straight down. A flex has to divide a
/// finite resource between children that have not been measured yet, which is
/// what forces the two-pass structure below and what makes `parentUsesSize`
/// and the relayout boundary rule matter in practice.
library;

import 'dart:math' as math;

import '../geometry/offset.dart';
import '../geometry/size.dart';
import 'box_constraints.dart';
import 'render_box.dart';

/// Which way a [RenderFlex] lays its children out.
enum Axis {
  horizontal,
  vertical;

  Axis get cross => this == Axis.horizontal ? Axis.vertical : Axis.horizontal;
}

/// How leftover main-axis space is distributed.
///
/// All six positions assume left-to-right and top-to-bottom. There is no
/// `verticalDirection` and no text-direction resolution: `start` is the
/// physical left or top edge. A right-to-left row is a documented gap, and
/// filling it means threading a directionality value down from the widget
/// layer rather than changing anything here.
enum MainAxisAlignment {
  start,
  end,
  center,

  /// Free space between children, none at the ends. With one child this is
  /// indistinguishable from [start].
  spaceBetween,

  /// Free space split evenly around each child, so the gap at each end is
  /// half the gap between neighbours.
  spaceAround,

  /// Free space split evenly between children and at both ends.
  spaceEvenly,
}

/// How children are placed and sized across the main axis.
enum CrossAxisAlignment {
  start,
  end,
  center,

  /// Children are forced to the full cross extent. Requires a bounded cross
  /// axis - there is nothing to stretch to otherwise, and [RenderFlex] says so
  /// rather than silently falling back.
  stretch,
}

/// Whether a flex sizes itself to its children or to all the space it is
/// allowed.
enum MainAxisSize {
  /// As small as the children allow.
  min,

  /// As large as the constraints allow. Under an unbounded main axis this
  /// behaves as [min], because "all the space" would be infinite.
  max,
}

/// Whether a flexible child must fill its share or may be smaller.
enum FlexFit {
  /// The share is a tight constraint: the child is exactly its allotment.
  tight,

  /// The share is only an upper bound. Leftover space stays unused, which is
  /// what makes a row of loose children not stretch to fill.
  loose,
}

/// Per-child inputs a [RenderFlex] reads.
final class FlexParentData extends BoxParentData {
  /// Zero means inflexible: the child is measured at its natural size and does
  /// not participate in the division of free space.
  int flex = 0;

  FlexFit fit = FlexFit.tight;

  @override
  String toString() => 'FlexParentData(offset: $offset, flex: $flex, $fit)';
}

/// Lays children out in a line, giving flexible children a share of what is
/// left after the inflexible ones have been measured.
///
/// ## Overflow policy
///
/// When the children need more main-axis space than the constraints allow,
/// this node:
///
///   * sizes itself to its constraints, never past them - a node that reported
///     a size its parent did not permit would corrupt every layout above it;
///   * positions the children at their computed offsets anyway, so they extend
///     past the edge and are visibly, obviously wrong;
///   * does **not** clip, and does **not** throw;
///   * records the excess in [overflow].
///
/// The reasoning: clipping hides the bug at exactly the moment it should be
/// noticed, and produces a UI that is merely missing something. Throwing is
/// worse than it sounds, because overflow is frequently transient - one frame
/// during a window resize, or the middle of an animation - and taking the
/// application down for a frame that would have been correct on the next one
/// trades a cosmetic problem for a crash. Overflowing visibly is the only
/// option that is both survivable and impossible to miss, and the recorded
/// amount is what a debug overlay or a test asserts on.
///
/// Clipping remains available to anyone who wants it, as a wrapping clip node
/// (not yet written) rather than a flag here - fusing a clip into flex would
/// mean every row pays for a clip stack push it usually does not need.
///
/// Free space is clamped at zero before alignment, so an overflowing row
/// starts its children at the leading edge instead of at a negative offset.
/// A negative leading space would push the *first* child off the start edge,
/// which hides the beginning of the content rather than the end.
///
/// The cross axis cannot overflow and so has no counterpart to [overflow]:
/// every child is given the flex's own cross extent as its maximum, and this
/// node is never smaller than the largest child that came back. A child taller
/// than the row is squeezed at layout time rather than reported afterwards,
/// which is the opposite of the main-axis policy for the reason that makes the
/// two different - the main axis is a shared budget, and the cross axis is not.
///
/// ## Not implemented
///
/// [CrossAxisAlignment] has no `baseline` member: aligning text baselines
/// needs font metrics, and there is no text node yet. Adding it later is a new
/// enum member plus a baseline query on [RenderBox], and nothing here changes.
final class RenderFlex extends RenderBoxContainer<FlexParentData> {
  RenderFlex({
    Axis direction = Axis.horizontal,
    MainAxisAlignment mainAxisAlignment = MainAxisAlignment.start,
    CrossAxisAlignment crossAxisAlignment = CrossAxisAlignment.start,
    MainAxisSize mainAxisSize = MainAxisSize.max,
  })  : _direction = direction,
        _mainAxisAlignment = mainAxisAlignment,
        _crossAxisAlignment = crossAxisAlignment,
        _mainAxisSize = mainAxisSize;

  Axis _direction;
  MainAxisAlignment _mainAxisAlignment;
  CrossAxisAlignment _crossAxisAlignment;
  MainAxisSize _mainAxisSize;
  double _overflow = 0;

  Axis get direction => _direction;

  set direction(Axis value) {
    if (value == _direction) return;
    _direction = value;
    markNeedsLayout();
  }

  MainAxisAlignment get mainAxisAlignment => _mainAxisAlignment;

  set mainAxisAlignment(MainAxisAlignment value) {
    if (value == _mainAxisAlignment) return;
    _mainAxisAlignment = value;
    markNeedsLayout();
  }

  CrossAxisAlignment get crossAxisAlignment => _crossAxisAlignment;

  set crossAxisAlignment(CrossAxisAlignment value) {
    if (value == _crossAxisAlignment) return;
    _crossAxisAlignment = value;
    markNeedsLayout();
  }

  MainAxisSize get mainAxisSize => _mainAxisSize;

  set mainAxisSize(MainAxisSize value) {
    if (value == _mainAxisSize) return;
    _mainAxisSize = value;
    markNeedsLayout();
  }

  /// Main-axis pixels the children needed beyond what this node was allowed,
  /// or zero. See the overflow policy above.
  double get overflow => _overflow;

  bool get hasOverflow => _overflow > 0;

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! FlexParentData) {
      child.parentData = FlexParentData();
    }
  }

  /// Adds [child] at the end.
  ///
  /// [flex] is the child's share of the leftover space, relative to its
  /// siblings; zero means the child keeps its natural size. [fit] defaults to
  /// tight because a flexible child that does not fill its share is the
  /// unusual case - the common intent behind "give this one the rest of the
  /// row" is that it occupy all of it.
  @override
  void add(RenderBox child, {int flex = 0, FlexFit fit = FlexFit.tight}) =>
      insert(child, index: childCount, flex: flex, fit: fit);

  @override
  void insert(
    RenderBox child, {
    required int index,
    int flex = 0,
    FlexFit fit = FlexFit.tight,
  }) {
    if (flex < 0) {
      throw ArgumentError.value(flex, 'flex', 'must not be negative');
    }
    super.insert(child, index: index);
    final FlexParentData data = childParentData(child);
    data.flex = flex;
    data.fit = fit;
  }

  /// Changes a child's share after the fact.
  void setFlex(RenderBox child, int flex, {FlexFit fit = FlexFit.tight}) {
    if (flex < 0) {
      throw ArgumentError.value(flex, 'flex', 'must not be negative');
    }
    final FlexParentData data = childParentData(child);
    if (data.flex == flex && data.fit == fit) return;
    data.flex = flex;
    data.fit = fit;
    markNeedsLayout();
  }

  bool get _isHorizontal => _direction == Axis.horizontal;

  double _mainOf(Size size) => _isHorizontal ? size.width : size.height;

  double _crossOf(Size size) => _isHorizontal ? size.height : size.width;

  BoxConstraints _childConstraints(
    double minMain,
    double maxMain,
    double maxCross,
  ) {
    final double minCross =
        _crossAxisAlignment == CrossAxisAlignment.stretch ? maxCross : 0.0;
    return _isHorizontal
        ? BoxConstraints(
            minWidth: minMain,
            maxWidth: maxMain,
            minHeight: minCross,
            maxHeight: maxCross,
          )
        : BoxConstraints(
            minWidth: minCross,
            maxWidth: maxCross,
            minHeight: minMain,
            maxHeight: maxMain,
          );
  }

  @override
  void performLayout() {
    final BoxConstraints constraints = this.constraints;
    final double maxMain =
        _isHorizontal ? constraints.maxWidth : constraints.maxHeight;
    final double maxCross =
        _isHorizontal ? constraints.maxHeight : constraints.maxWidth;
    final bool canFlex = maxMain.isFinite;

    if (_crossAxisAlignment == CrossAxisAlignment.stretch &&
        !maxCross.isFinite) {
      throw StateError(
        'CrossAxisAlignment.stretch on a $runtimeType with an unbounded '
        '${_direction.cross.name} axis: there is no extent to stretch to. Give '
        'the flex a bounded cross axis, or use start/center/end.',
      );
    }

    // --- pass one: the children whose size does not depend on what is left --
    //
    // Inflexible children are measured against an unbounded main axis. They
    // are entitled to their natural size; squeezing them into what remains
    // would make the result depend on sibling order, and it is what produces
    // the overflow this node reports rather than hides.
    int totalFlex = 0;
    double allocated = 0.0;
    double maxChildCross = 0.0;
    RenderBox? lastFlexChild;
    final int count = childCount;

    for (int i = 0; i < count; i++) {
      final RenderBox child = childAt(i);
      final FlexParentData data = childParentData(child);
      if (data.flex > 0) {
        totalFlex += data.flex;
        lastFlexChild = child;
        continue;
      }
      child.layout(
        _childConstraints(0.0, double.infinity, maxCross),
        parentUsesSize: true,
      );
      final Size childSize = child.size;
      allocated += _mainOf(childSize);
      maxChildCross = math.max(maxChildCross, _crossOf(childSize));
    }

    // --- pass two: divide what is left ------------------------------------
    //
    // Only now is free space known, which is the entire reason for two passes.
    // Under an unbounded main axis there is no space to divide, so flexible
    // children fall back to their natural size and the flex behaves as if
    // nothing were flexible.
    if (totalFlex > 0) {
      final double freeSpace =
          math.max(0.0, (canFlex ? maxMain : 0.0) - allocated);
      final double spacePerFlex = canFlex ? freeSpace / totalFlex : 0.0;
      // Budget rather than actual consumption: a loose child that took less
      // than its share must not hand the surplus to the last child, or the
      // division would stop being proportional.
      double budgetUsed = 0.0;

      for (int i = 0; i < count; i++) {
        final RenderBox child = childAt(i);
        final FlexParentData data = childParentData(child);
        if (data.flex == 0) continue;

        final double maxChildMain;
        if (!canFlex) {
          maxChildMain = double.infinity;
        } else if (identical(child, lastFlexChild)) {
          // The remainder, so that repeated divisions cannot lose a fraction
          // of a pixel and leave a gap at the end of the row.
          maxChildMain = math.max(0.0, freeSpace - budgetUsed);
        } else {
          maxChildMain = spacePerFlex * data.flex;
        }
        budgetUsed += maxChildMain;

        final double minChildMain =
            data.fit == FlexFit.tight && maxChildMain.isFinite
                ? maxChildMain
                : 0.0;
        child.layout(
          _childConstraints(minChildMain, maxChildMain, maxCross),
          parentUsesSize: true,
        );
        final Size childSize = child.size;
        allocated += _mainOf(childSize);
        maxChildCross = math.max(maxChildCross, _crossOf(childSize));
      }
    }

    final double idealMain =
        _mainAxisSize == MainAxisSize.max && canFlex ? maxMain : allocated;
    size = constraints.constrain(
      _isHorizontal
          ? Size(idealMain, maxChildCross)
          : Size(maxChildCross, idealMain),
    );

    final Size resolved = size;
    final double actualMain = _mainOf(resolved);
    final double actualCross = _crossOf(resolved);
    final double slack = actualMain - allocated;
    _overflow = math.max(0.0, -slack);
    final double remaining = math.max(0.0, slack);

    final (double leading, double between) = _distribute(remaining, count);

    double position = leading;
    for (int i = 0; i < count; i++) {
      final RenderBox child = childAt(i);
      final Size childSize = child.size;
      final double cross = _crossOffset(actualCross, _crossOf(childSize));
      childParentData(child).offset =
          _isHorizontal ? Offset(position, cross) : Offset(cross, position);
      position += _mainOf(childSize) + between;
    }
  }

  /// Leading space before the first child, and the gap between neighbours.
  (double, double) _distribute(double remaining, int count) =>
      switch (_mainAxisAlignment) {
        MainAxisAlignment.start => (0.0, 0.0),
        MainAxisAlignment.end => (remaining, 0.0),
        MainAxisAlignment.center => (remaining / 2.0, 0.0),
        MainAxisAlignment.spaceBetween =>
          count > 1 ? (0.0, remaining / (count - 1)) : (0.0, 0.0),
        MainAxisAlignment.spaceAround =>
          count > 0 ? (remaining / count / 2.0, remaining / count) : (0.0, 0.0),
        MainAxisAlignment.spaceEvenly => (
            remaining / (count + 1),
            remaining / (count + 1)
          ),
      };

  double _crossOffset(double extent, double childExtent) =>
      switch (_crossAxisAlignment) {
        CrossAxisAlignment.start || CrossAxisAlignment.stretch => 0.0,
        CrossAxisAlignment.center => (extent - childExtent) / 2.0,
        CrossAxisAlignment.end => extent - childExtent,
      };
}
