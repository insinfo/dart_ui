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
import '../text/shaper.dart' show TextDirection;
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
/// These six names are **logical**, not physical. On a horizontal flex,
/// [start] is the edge the text begins at: the left edge under
/// [TextDirection.leftToRight] and the *right* edge under
/// [TextDirection.rightToLeft]. On a vertical flex [start] is always the top,
/// because there is no `verticalDirection` here and reading direction does not
/// turn a column upside down.
///
/// The distribution arithmetic is direction-free - [distributeFreeSpace] does
/// not take a [TextDirection] and never will. A right-to-left row gets exactly
/// the same leading space and the same gaps; [RenderFlex] mirrors the finished
/// offsets. That is what keeps [spaceBetween] meaning "equal gaps" in both
/// locales while the children still come out in the opposite order.
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
///
/// [start] and [end] are logical here too, and which axis that affects is the
/// opposite of [MainAxisAlignment]'s. A row's cross axis is vertical, so its
/// [start] is always the top. A **column's** cross axis is horizontal, so its
/// [start] is the left edge under [TextDirection.leftToRight] and the right
/// edge under [TextDirection.rightToLeft]. A column does not reverse, but the
/// side its children align to does.
enum CrossAxisAlignment {
  start,
  end,
  center,

  /// Children are forced to the full cross extent. Requires a bounded cross
  /// axis - there is nothing to stretch to otherwise, and [RenderFlex] says so
  /// rather than silently falling back.
  stretch,

  /// Children are shifted so that the text baselines named by
  /// [RenderFlex.textBaseline] fall on one line.
  ///
  /// Only meaningful on a horizontal flex: a column's children are already on
  /// separate lines, so there is nothing to align. [RenderFlex] rejects the
  /// combination instead of quietly behaving like [start], because a row that
  /// was rotated into a column and kept this setting is a bug worth hearing
  /// about.
  ///
  /// A child with no text in it - a coloured box, an icon - has no real
  /// baseline and is placed at the leading edge. That is a deliberate choice
  /// over pretending its bottom edge is a baseline: a 40px box next to a 16px
  /// label would otherwise drag the whole row's baseline down to 40.
  baseline,
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

/// How [remaining] free pixels are split among [count] items placed in a line
/// under [alignment]: the leading space before the first, and the gap between
/// neighbours.
///
/// Top-level and public because a wrap needs exactly these six rules twice -
/// once inside a run and once between runs - and a second copy of
/// `spaceEvenly`'s arithmetic is a second place for it to disagree with a row's.
(double, double) distributeFreeSpace(
  MainAxisAlignment alignment,
  double remaining,
  int count,
) =>
    switch (alignment) {
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
/// ## Direction
///
/// [textDirection] is resolved once, at the end of layout, by mirroring the
/// finished offsets along **one** axis - never by reversing the child list.
/// Reversing the list would change which child is measured first, which is
/// observable through the last-flex-child remainder rule above and would make
/// a right-to-left row round its pixels differently from its left-to-right
/// mirror image. Mirroring offsets cannot: the two layouts are the same
/// arithmetic, reflected.
///
/// Which axis gets mirrored depends on [direction], and it is exactly one:
///
///   * a **row** mirrors its *main* axis - the first child ends up on the
///     right - and leaves the cross axis alone, because a row's cross axis is
///     vertical and no reading direction affects up and down;
///   * a **column** mirrors its *cross* axis - `CrossAxisAlignment.start`
///     puts children against the right edge - and leaves the main axis alone,
///     because a column in Arabic still reads top to bottom.
///
/// Never affected by [textDirection], in either direction: child order,
/// measurement, the sizes children are given, [MainAxisSize], the flex
/// division, [overflow], the intrinsic queries, and
/// [CrossAxisAlignment.baseline] - a baseline offset is vertical, and the only
/// flex that may use it is a row, whose cross axis is the unmirrored one.
/// [CrossAxisAlignment.stretch] and `center` are unaffected in practice too:
/// both are symmetric, so mirroring them is the identity.
///
/// There is still no `verticalDirection`: a column reads top to bottom in
/// every locale this framework targets, and inventing a flag for it would
/// invite `MainAxisAlignment.start` to mean the bottom.
final class RenderFlex extends RenderBoxContainer<FlexParentData> {
  RenderFlex({
    Axis direction = Axis.horizontal,
    MainAxisAlignment mainAxisAlignment = MainAxisAlignment.start,
    CrossAxisAlignment crossAxisAlignment = CrossAxisAlignment.start,
    MainAxisSize mainAxisSize = MainAxisSize.max,
    TextBaseline textBaseline = TextBaseline.alphabetic,
    TextDirection? textDirection,
  })  : _direction = direction,
        _mainAxisAlignment = mainAxisAlignment,
        _crossAxisAlignment = crossAxisAlignment,
        _mainAxisSize = mainAxisSize,
        _textBaseline = textBaseline,
        _textDirection = textDirection;

  Axis _direction;
  MainAxisAlignment _mainAxisAlignment;
  CrossAxisAlignment _crossAxisAlignment;
  MainAxisSize _mainAxisSize;
  TextBaseline _textBaseline;
  TextDirection? _textDirection;
  double _overflow = 0;

  /// The reading direction the logical `start`/`end` names resolve against.
  ///
  /// Null means unresolved, and unresolved lays out as
  /// [TextDirection.leftToRight]. That is deliberate and it is *not* the same
  /// policy the widget layer uses, where a missing `Directionality` is a named
  /// error. The two layers are answering different questions. A render tree is
  /// a machine for turning constraints into physical coordinates; it is
  /// assembled directly by tests, by tools and by nodes that have no locale at
  /// all, and it has no widget path to name in an error message. Refusing to
  /// lay out would make every one of those callers pass a value they have no
  /// opinion about. The widget layer is where a locale is a *decision*, so the
  /// diagnostic for forgetting to make one lives there - see
  /// `Directionality.of`.
  TextDirection? get textDirection => _textDirection;

  set textDirection(TextDirection? value) {
    if (value == _textDirection) return;
    _textDirection = value;
    markNeedsLayout();
  }

  /// Where the baseline this node aligns to sits, when
  /// [crossAxisAlignment] is [CrossAxisAlignment.baseline]. Ignored otherwise.
  TextBaseline get textBaseline => _textBaseline;

  set textBaseline(TextBaseline value) {
    if (value == _textBaseline) return;
    _textBaseline = value;
    markNeedsLayout();
  }

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

  /// Whether the reading direction runs right to left. Null resolves to
  /// left-to-right; see [textDirection].
  bool get _isRtl => _textDirection == TextDirection.rightToLeft;

  /// Whether the main axis is mirrored: a right-to-left **row**, and nothing
  /// else. A column's main axis is vertical and untouched.
  bool get _flipMain => _isRtl && _isHorizontal;

  /// Whether the cross axis is mirrored: a right-to-left **column**, whose
  /// cross axis is the horizontal one.
  bool get _flipCross => _isRtl && !_isHorizontal;

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
    if (_crossAxisAlignment == CrossAxisAlignment.baseline && !_isHorizontal) {
      throw StateError(
        'CrossAxisAlignment.baseline on a vertical $runtimeType: the children '
        'of a column are already on separate lines, so there is no shared '
        'baseline to align them to. Use start/center/end, or make this a row.',
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

    // --- baseline pass ----------------------------------------------------
    //
    // Runs only in baseline mode, and only after every child has a size,
    // because a baseline is a property of a laid-out line of text. The cross
    // extent a row of baselined children needs is not the tallest child: it is
    // the deepest baseline plus the deepest descent below any baseline, which
    // can exceed every individual height when a tall-ascender child sits next
    // to a deep-descender one.
    double maxBaseline = 0.0;
    if (_crossAxisAlignment == CrossAxisAlignment.baseline) {
      double maxDescent = 0.0;
      for (int i = 0; i < count; i++) {
        final RenderBox child = childAt(i);
        final double? distance =
            child.getDistanceToBaseline(_textBaseline, onlyReal: true);
        if (distance == null) continue;
        maxBaseline = math.max(maxBaseline, distance);
        maxDescent = math.max(maxDescent, child.size.height - distance);
      }
      maxChildCross = math.max(maxChildCross, maxBaseline + maxDescent);
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

    final (double leading, double between) =
        distributeFreeSpace(_mainAxisAlignment, remaining, count);

    // Positions are computed in *logical* space - `start` at zero, running
    // toward `end` - and reflected afterwards when the direction calls for it.
    // Everything above this loop, including the free-space arithmetic, is
    // direction-free; see the class comment for why the reflection happens
    // here rather than by walking the children backwards.
    final bool flipMain = _flipMain;
    final bool flipCross = _flipCross;
    double position = leading;
    for (int i = 0; i < count; i++) {
      final RenderBox child = childAt(i);
      final Size childSize = child.size;
      final double childMain = _mainOf(childSize);
      final double childCross = _crossOf(childSize);
      final double cross;
      if (_crossAxisAlignment == CrossAxisAlignment.baseline) {
        // Read from the child's own cache, filled by the pass above.
        final double? distance =
            child.getDistanceToBaseline(_textBaseline, onlyReal: true);
        cross = distance == null ? 0.0 : maxBaseline - distance;
      } else {
        cross = _crossOffset(actualCross, childCross);
      }
      // Reflect about the box's own extent, which turns a leading-edge
      // distance into a trailing-edge one and leaves the child's size alone.
      final double mainOffset =
          flipMain ? actualMain - position - childMain : position;
      final double crossOffset =
          flipCross ? actualCross - cross - childCross : cross;
      childParentData(child).offset = _isHorizontal
          ? Offset(mainOffset, crossOffset)
          : Offset(crossOffset, mainOffset);
      position += childMain + between;
    }
  }

  // --- intrinsics ---------------------------------------------------------
  //
  // Along the main axis the children's demands add up, except that flexible
  // children are all sized from one shared per-flex rate: the row is wide
  // enough when the greediest child's demand is met at that rate, so the
  // answer is `max(demand / flex) * totalFlex` for the flexible ones plus the
  // plain sum for the rest.
  //
  // Across it they do not add up at all - the answer is the largest single
  // demand. That query has to invent a main extent for each child first, which
  // is where the approximation lives: inflexible children are measured at their
  // own max-content main extent, and flexible ones at their share of what is
  // left. It is the same division layout performs, done on intrinsics instead
  // of sizes, so the two agree whenever the children's intrinsics are honest.

  double _childMain(RenderBox child, double crossExtent, {required bool max}) =>
      _isHorizontal
          ? (max
              ? child.getMaxIntrinsicWidth(crossExtent)
              : child.getMinIntrinsicWidth(crossExtent))
          : (max
              ? child.getMaxIntrinsicHeight(crossExtent)
              : child.getMinIntrinsicHeight(crossExtent));

  double _childCross(RenderBox child, double mainExtent, {required bool max}) =>
      _isHorizontal
          ? (max
              ? child.getMaxIntrinsicHeight(mainExtent)
              : child.getMinIntrinsicHeight(mainExtent))
          : (max
              ? child.getMaxIntrinsicWidth(mainExtent)
              : child.getMinIntrinsicWidth(mainExtent));

  double _intrinsicMain(double crossExtent, {required bool max}) {
    int totalFlex = 0;
    double inflexible = 0.0;
    double maxFlexRate = 0.0;
    for (int i = 0; i < childCount; i++) {
      final RenderBox child = childAt(i);
      final int flex = childParentData(child).flex;
      final double demand = _childMain(child, crossExtent, max: max);
      if (flex > 0) {
        totalFlex += flex;
        maxFlexRate = math.max(maxFlexRate, demand / flex);
      } else {
        inflexible += demand;
      }
    }
    return maxFlexRate * totalFlex + inflexible;
  }

  double _intrinsicCross(double mainExtent, {required bool max}) {
    int totalFlex = 0;
    double inflexible = 0.0;
    double widest = 0.0;
    for (int i = 0; i < childCount; i++) {
      final RenderBox child = childAt(i);
      final int flex = childParentData(child).flex;
      if (flex > 0) {
        totalFlex += flex;
        continue;
      }
      final double childMain = _childMain(child, double.infinity, max: true);
      inflexible += childMain;
      widest = math.max(widest, _childCross(child, childMain, max: max));
    }
    if (totalFlex == 0) return widest;
    // An unbounded main axis leaves nothing to divide, exactly as in layout,
    // so a flexible child falls back to its own natural main extent.
    final double perFlex = mainExtent.isFinite
        ? math.max(0.0, (mainExtent - inflexible) / totalFlex)
        : double.infinity;
    for (int i = 0; i < childCount; i++) {
      final RenderBox child = childAt(i);
      final int flex = childParentData(child).flex;
      if (flex == 0) continue;
      final double childMain = perFlex.isFinite
          ? perFlex * flex
          : _childMain(child, double.infinity, max: true);
      widest = math.max(widest, _childCross(child, childMain, max: max));
    }
    return widest;
  }

  @override
  double computeMinIntrinsicWidth(double height) => _isHorizontal
      ? _intrinsicMain(height, max: false)
      : _intrinsicCross(height, max: false);

  @override
  double computeMaxIntrinsicWidth(double height) => _isHorizontal
      ? _intrinsicMain(height, max: true)
      : _intrinsicCross(height, max: true);

  @override
  double computeMinIntrinsicHeight(double width) => _isHorizontal
      ? _intrinsicCross(width, max: false)
      : _intrinsicMain(width, max: false);

  @override
  double computeMaxIntrinsicHeight(double width) => _isHorizontal
      ? _intrinsicCross(width, max: true)
      : _intrinsicMain(width, max: true);

  /// A row's baseline is its **highest** child baseline; a column's is its
  /// **first**.
  ///
  /// The two differ because the children mean different things. In a row every
  /// child is on the same line, so the line the row sits on is the topmost one
  /// any of them claims - taking the first child's instead would make a row's
  /// alignment depend on which label happened to be written first. In a column
  /// the children *are* successive lines, and a paragraph aligns to its first.
  @override
  double? computeDistanceToActualBaseline(TextBaseline baseline) {
    if (!_isHorizontal) {
      return defaultComputeDistanceToFirstActualBaseline(baseline);
    }
    double? highest;
    for (int i = 0; i < childCount; i++) {
      final RenderBox child = childAt(i);
      if (!child.hasSize) continue;
      final double? distance =
          child.getDistanceToBaseline(baseline, onlyReal: true);
      if (distance == null) continue;
      final double inParent = distance + child.offsetFromParent.dy;
      if (highest == null || inParent < highest) highest = inParent;
    }
    return highest;
  }

  double _crossOffset(double extent, double childExtent) =>
      switch (_crossAxisAlignment) {
        // baseline never reaches here: performLayout branches before calling
        // this, because a baseline offset is not a function of the two extents.
        CrossAxisAlignment.start ||
        CrossAxisAlignment.stretch ||
        CrossAxisAlignment.baseline =>
          0.0,
        CrossAxisAlignment.center => (extent - childExtent) / 2.0,
        CrossAxisAlignment.end => extent - childExtent,
      };
}
