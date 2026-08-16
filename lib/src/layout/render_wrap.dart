/// A flex that runs out of room and starts a new line.
library;

import 'dart:math' as math;

import '../geometry/offset.dart';
import '../geometry/size.dart';
import 'box_constraints.dart';
import 'render_box.dart';
import 'render_flex.dart';

/// Where a child sits across its run, when the run is taller than the child.
///
/// Separate from [CrossAxisAlignment] because two of that enum's members have
/// no meaning here: `stretch` would force every child to the height of the
/// tallest one in its run, which defeats the point of runs, and `baseline`
/// needs a single line of children to align.
enum WrapCrossAlignment { start, center, end }

/// Per-child bookkeeping. A wrap needs no per-child inputs of its own; this
/// exists so the container's type parameter has something to name.
final class WrapParentData extends BoxParentData {}

/// Lays children out in a line until the next one does not fit, then starts
/// another line.
///
/// ## What decides a break
///
/// A child goes on the current run when the run's used main extent, plus
/// [spacing], plus the child's own main extent, is no larger than the wrap's
/// main extent. Equality fits: three 100px chips in a 300px wrap make one run,
/// not two. The comparison is against the *constraint*, not against the size
/// this node ends up with, so a wrap whose parent later shrinks it does not
/// silently re-flow.
///
/// A child that is larger than the whole line gets a run to itself and is not
/// broken up - there is nothing to break. It cannot overflow the main axis,
/// because children are measured against a maximum of the wrap's own main
/// extent; a 200px-wide child in a 100px wrap is *squeezed to 100*, exactly as
/// a flex squeezes its cross axis. That is the one place this node differs from
/// [RenderFlex], and it differs because the main axis here is not a shared
/// budget: each run gets the whole line, so there is no sibling to be unfair to.
///
/// ## Overflow
///
/// Same policy as [RenderFlex], for the same reasons: this node sizes itself to
/// its constraints, positions the runs where they fall anyway, does not clip and
/// does not throw, and records the excess in [overflow]. Only the cross axis can
/// overflow (see above), so [overflow] is a single number and means "how many
/// cross-axis pixels of runs did not fit".
///
/// ## Unbounded main axis
///
/// There is no line to run out of, so everything lands on one run and this
/// behaves as a [RenderFlex] with [MainAxisSize.min]. That mirrors the flex's
/// own fallback when it has no space to divide, and it is what makes a wrap
/// inside a horizontally scrolling viewport behave predictably rather than
/// wrapping at an arbitrary width.
final class RenderWrap extends RenderBoxContainer<WrapParentData> {
  RenderWrap({
    Axis direction = Axis.horizontal,
    double spacing = 0.0,
    double runSpacing = 0.0,
    MainAxisAlignment alignment = MainAxisAlignment.start,
    MainAxisAlignment runAlignment = MainAxisAlignment.start,
    WrapCrossAlignment crossAxisAlignment = WrapCrossAlignment.start,
  })  : _direction = direction,
        _spacing = spacing,
        _runSpacing = runSpacing,
        _alignment = alignment,
        _runAlignment = runAlignment,
        _crossAxisAlignment = crossAxisAlignment {
    _checkGap('spacing', spacing);
    _checkGap('runSpacing', runSpacing);
  }

  Axis _direction;
  double _spacing;
  double _runSpacing;
  MainAxisAlignment _alignment;
  MainAxisAlignment _runAlignment;
  WrapCrossAlignment _crossAxisAlignment;
  double _overflow = 0.0;

  /// Reused across frames so a re-flow allocates nothing; section 6.5.
  final List<int> _runStarts = <int>[];
  final List<double> _runMain = <double>[];
  final List<double> _runCross = <double>[];

  Axis get direction => _direction;

  set direction(Axis value) {
    if (value == _direction) return;
    _direction = value;
    markNeedsLayout();
  }

  /// Gap between neighbours inside one run.
  double get spacing => _spacing;

  set spacing(double value) {
    if (value == _spacing) return;
    _checkGap('spacing', value);
    _spacing = value;
    markNeedsLayout();
  }

  /// Gap between one run and the next.
  double get runSpacing => _runSpacing;

  set runSpacing(double value) {
    if (value == _runSpacing) return;
    _checkGap('runSpacing', value);
    _runSpacing = value;
    markNeedsLayout();
  }

  /// How the leftover space inside a run is distributed.
  MainAxisAlignment get alignment => _alignment;

  set alignment(MainAxisAlignment value) {
    if (value == _alignment) return;
    _alignment = value;
    markNeedsLayout();
  }

  /// How the leftover space across the runs is distributed.
  MainAxisAlignment get runAlignment => _runAlignment;

  set runAlignment(MainAxisAlignment value) {
    if (value == _runAlignment) return;
    _runAlignment = value;
    markNeedsLayout();
  }

  WrapCrossAlignment get crossAxisAlignment => _crossAxisAlignment;

  set crossAxisAlignment(WrapCrossAlignment value) {
    if (value == _crossAxisAlignment) return;
    _crossAxisAlignment = value;
    markNeedsLayout();
  }

  /// Cross-axis pixels of runs that did not fit, or zero.
  double get overflow => _overflow;

  bool get hasOverflow => _overflow > 0;

  /// How many runs the last layout produced. One per line of chips.
  int get runCount => _runStarts.length;

  static void _checkGap(String name, double value) {
    if (value.isNaN || value.isInfinite || value < 0.0) {
      throw ArgumentError.value(
        value,
        name,
        'must be a finite, non-negative number of pixels',
      );
    }
  }

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! WrapParentData) {
      child.parentData = WrapParentData();
    }
  }

  bool get _isHorizontal => _direction == Axis.horizontal;

  double _mainOf(Size size) => _isHorizontal ? size.width : size.height;

  double _crossOf(Size size) => _isHorizontal ? size.height : size.width;

  @override
  void performLayout() {
    final BoxConstraints constraints = this.constraints;
    final int count = childCount;
    _runStarts.clear();
    _runMain.clear();
    _runCross.clear();

    if (count == 0) {
      size = constraints.constrain(Size.zero);
      _overflow = 0.0;
      return;
    }

    final double mainLimit =
        _isHorizontal ? constraints.maxWidth : constraints.maxHeight;
    final BoxConstraints childConstraints = _isHorizontal
        ? BoxConstraints(maxWidth: mainLimit)
        : BoxConstraints(maxHeight: mainLimit);

    // --- pass one: measure, and cut the sequence into runs ------------------
    int runStart = 0;
    double runMain = 0.0;
    double runCross = 0.0;
    double widestRun = 0.0;
    double totalCross = 0.0;
    _runStarts.add(0);

    for (int i = 0; i < count; i++) {
      final RenderBox child = childAt(i);
      child.layout(childConstraints, parentUsesSize: true);
      final Size childSize = child.size;
      final double childMain = _mainOf(childSize);
      final double childCross = _crossOf(childSize);

      final bool runIsEmpty = i == runStart;
      final double wouldBe =
          runIsEmpty ? childMain : runMain + _spacing + childMain;
      if (!runIsEmpty && wouldBe > mainLimit) {
        // Close the run before adding this child, so a child never straddles.
        _runMain.add(runMain);
        _runCross.add(runCross);
        widestRun = math.max(widestRun, runMain);
        totalCross += runCross + _runSpacing;
        runStart = i;
        _runStarts.add(i);
        runMain = childMain;
        runCross = childCross;
        continue;
      }
      runMain = wouldBe;
      runCross = math.max(runCross, childCross);
    }
    _runMain.add(runMain);
    _runCross.add(runCross);
    widestRun = math.max(widestRun, runMain);
    totalCross += runCross;

    final double idealMain = mainLimit.isFinite ? mainLimit : widestRun;
    size = constraints.constrain(
      _isHorizontal ? Size(idealMain, totalCross) : Size(totalCross, idealMain),
    );

    // --- pass two: position -------------------------------------------------
    final Size resolved = size;
    final double actualMain = _mainOf(resolved);
    final double actualCross = _crossOf(resolved);
    _overflow = math.max(0.0, totalCross - actualCross);

    final int runs = _runStarts.length;
    final double crossSlack = math.max(0.0, actualCross - totalCross);
    final (double leadingCross, double betweenRuns) =
        distributeFreeSpace(_runAlignment, crossSlack, runs);

    double crossPosition = leadingCross;
    for (int run = 0; run < runs; run++) {
      final int start = _runStarts[run];
      final int end = run + 1 < runs ? _runStarts[run + 1] : count;
      final double thisRunCross = _runCross[run];
      final double mainSlack = math.max(0.0, actualMain - _runMain[run]);
      final (double leadingMain, double betweenChildren) =
          distributeFreeSpace(_alignment, mainSlack, end - start);

      double mainPosition = leadingMain;
      for (int i = start; i < end; i++) {
        final RenderBox child = childAt(i);
        final Size childSize = child.size;
        final double childCross = _crossOf(childSize);
        final double offsetInRun = switch (_crossAxisAlignment) {
          WrapCrossAlignment.start => 0.0,
          WrapCrossAlignment.center => (thisRunCross - childCross) / 2.0,
          WrapCrossAlignment.end => thisRunCross - childCross,
        };
        final double cross = crossPosition + offsetInRun;
        childParentData(child).offset = _isHorizontal
            ? Offset(mainPosition, cross)
            : Offset(cross, mainPosition);
        mainPosition += _mainOf(childSize) + _spacing + betweenChildren;
      }
      crossPosition += thisRunCross + _runSpacing + betweenRuns;
    }
  }

  // --- intrinsics ---------------------------------------------------------
  //
  // The main axis is exact: at its minimum a wrap is as wide as its widest
  // single child, because that child cannot be broken; at its maximum it is
  // everything on one run, which is the sum plus the gaps.
  //
  // The cross axis is not, and cannot be without running the wrap. The honest
  // answer would require re-flowing at the given main extent, which means
  // measuring every child and cutting runs - a layout in all but name. What is
  // reported instead is the tallest single child, i.e. the height of a wrap
  // that happened to need only one run, and this is the documented
  // approximation: a caller that needs the real height must lay the wrap out.

  double _childMain(RenderBox child, {required bool max}) => _isHorizontal
      ? (max
          ? child.getMaxIntrinsicWidth(double.infinity)
          : child.getMinIntrinsicWidth(double.infinity))
      : (max
          ? child.getMaxIntrinsicHeight(double.infinity)
          : child.getMinIntrinsicHeight(double.infinity));

  double _childCross(RenderBox child, {required bool max}) => _isHorizontal
      ? (max
          ? child.getMaxIntrinsicHeight(double.infinity)
          : child.getMinIntrinsicHeight(double.infinity))
      : (max
          ? child.getMaxIntrinsicWidth(double.infinity)
          : child.getMinIntrinsicWidth(double.infinity));

  double _intrinsicMain({required bool max}) {
    if (childCount == 0) return 0.0;
    if (!max) {
      double widest = 0.0;
      for (int i = 0; i < childCount; i++) {
        widest = math.max(widest, _childMain(childAt(i), max: false));
      }
      return widest;
    }
    double total = 0.0;
    for (int i = 0; i < childCount; i++) {
      total += _childMain(childAt(i), max: true);
    }
    return total + _spacing * (childCount - 1);
  }

  double _intrinsicCross({required bool max}) {
    double tallest = 0.0;
    for (int i = 0; i < childCount; i++) {
      tallest = math.max(tallest, _childCross(childAt(i), max: max));
    }
    return tallest;
  }

  @override
  double computeMinIntrinsicWidth(double height) =>
      _isHorizontal ? _intrinsicMain(max: false) : _intrinsicCross(max: false);

  @override
  double computeMaxIntrinsicWidth(double height) =>
      _isHorizontal ? _intrinsicMain(max: true) : _intrinsicCross(max: true);

  @override
  double computeMinIntrinsicHeight(double width) =>
      _isHorizontal ? _intrinsicCross(max: false) : _intrinsicMain(max: false);

  @override
  double computeMaxIntrinsicHeight(double width) =>
      _isHorizontal ? _intrinsicCross(max: true) : _intrinsicMain(max: true);
}
