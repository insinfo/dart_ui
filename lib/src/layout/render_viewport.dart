/// Scrolling: a viewport, an offset, and the rules that keep them honest.
///
/// Section 27.8 asks for pixels *and* lines, momentum, overscroll, nested
/// scrolling with chaining, a scrollbar model and accessibility actions. The
/// separation that makes those tractable is between the two objects here:
///
///   * [ScrollPosition] is pure arithmetic - extents, clamping, chaining
///     decisions, momentum steps. It has no render tree in it, so every one of
///     those rules is testable without a window;
///   * [RenderViewport] is geometry - it lays a child out unbounded on the
///     scroll axis, translates it, and clips. It asks the position what the
///     offset is and never decides one itself.
library;

import '../geometry/offset.dart';
import '../geometry/rect.dart';
import '../geometry/size.dart';
import '../graphics/display_list.dart';
import '../graphics/display_list_geometry.dart';
import 'box_constraints.dart';
import 'render_box.dart';

enum ScrollAxis { vertical, horizontal }

/// How far a scroll gesture moves per unit when the platform reports lines.
///
/// The value is the framework's fallback for one detent. Desktop systems
/// conventionally move three text lines per detent; using a single 16-pixel
/// line made long documents feel three times slower than their native peers.
/// A backend with an exact platform preference can still report pixels.
const double defaultLineExtent = 48.0;

/// Placement of scroll content when it is smaller than its viewport.
enum ScrollContentAlignment { start, center, end }

/// Where a scrollable is, how far it may go, and what happens at the edges.
final class ScrollPosition {
  ScrollPosition({
    this.axis = ScrollAxis.vertical,
    double pixels = 0,
    double viewportExtent = 0,
    double contentExtent = 0,
    this.overscrollAllowance = 0,
  })  : _pixels = pixels,
        _viewportExtent = viewportExtent,
        _contentExtent = contentExtent;

  final ScrollAxis axis;

  /// How far past the end a drag may go before it is clamped. Zero gives the
  /// hard-stop behaviour Windows and X11 expect; a positive value is what a
  /// rubber-band effect is built from.
  final double overscrollAllowance;

  final List<void Function(ScrollPosition position)> _listeners =
      <void Function(ScrollPosition position)>[];

  double _pixels;
  double _viewportExtent;
  double _contentExtent;
  double _velocity = 0;

  /// The current scroll offset, in logical pixels, always within
  /// `[-overscrollAllowance, maxScrollExtent + overscrollAllowance]`.
  double get pixels => _pixels;

  /// The visible extent along [axis].
  double get viewportExtent => _viewportExtent;

  /// The child's extent along [axis].
  double get contentExtent => _contentExtent;

  /// The largest in-range offset. Zero when the content fits, which is what
  /// makes a short list refuse to scroll at all rather than jitter.
  double get maxScrollExtent {
    final double extent = _contentExtent - _viewportExtent;
    return extent <= 0 ? 0 : extent;
  }

  bool get canScroll => maxScrollExtent > 0;

  bool get atStart => _pixels <= 0;

  bool get atEnd => _pixels >= maxScrollExtent;

  /// The current fling velocity in pixels per second; zero when at rest.
  double get velocity => _velocity;

  /// The scrollbar thumb as a fraction of the track: its size and its start.
  ///
  /// Returns null when there is nothing to scroll, which is the signal to hide
  /// the scrollbar rather than draw a full-length thumb.
  ({double start, double extent})? get thumb {
    if (!canScroll || _contentExtent <= 0) return null;
    final double extent = (_viewportExtent / _contentExtent).clamp(0.0, 1.0);
    final double start =
        (_pixels / _contentExtent).clamp(0.0, (1.0 - extent).clamp(0.0, 1.0));
    return (start: start, extent: extent);
  }

  void addListener(void Function(ScrollPosition position) listener) =>
      _listeners.add(listener);

  void removeListener(void Function(ScrollPosition position) listener) =>
      _listeners.remove(listener);

  /// Records the geometry measured by the viewport during layout.
  ///
  /// Re-clamps, because a window that shrank can leave the offset past the new
  /// maximum - which shows as a list scrolled into empty space below its last
  /// item.
  bool applyViewportGeometry({
    required double viewportExtent,
    required double contentExtent,
  }) {
    final bool changed =
        viewportExtent != _viewportExtent || contentExtent != _contentExtent;
    _viewportExtent = viewportExtent;
    _contentExtent = contentExtent;
    final double clamped = _clamp(_pixels, allowOverscroll: false);
    if (clamped != _pixels) {
      _pixels = clamped;
      _notify();
      return true;
    }
    if (changed) _notify();
    return changed;
  }

  /// Jumps to [value], clamped into range. Returns true when it moved.
  bool jumpTo(double value) {
    final double clamped = _clamp(value, allowOverscroll: false);
    if (clamped == _pixels) return false;
    _pixels = clamped;
    _velocity = 0;
    _notify();
    return true;
  }

  /// Applies a user delta, returning the part this position could **not**
  /// consume.
  ///
  /// The unconsumed remainder is the whole basis of scroll chaining (section
  /// 27.8): an inner list that has hit its end returns the leftover, and the
  /// outer scrollable moves by exactly that much. A method that returned only
  /// "handled or not" cannot express a gesture that is half consumed.
  double applyDelta(double delta, {bool allowOverscroll = false}) {
    if (delta == 0) return 0;
    final double target = _pixels + delta;
    final double clamped = _clamp(target, allowOverscroll: allowOverscroll);
    final double consumed = clamped - _pixels;
    if (consumed != 0) {
      _pixels = clamped;
      _notify();
    }
    // `target - clamped`, not `delta - consumed`, and the difference is not
    // cosmetic. The two are equal in arithmetic and not in floating point:
    // `(pixels + delta) - pixels` is not exactly `delta`, so `delta - consumed`
    // left a residue near 1e-15 on a step that in fact consumed everything.
    // `_clamp` returns its argument *unchanged* when nothing is out of range,
    // so `target - clamped` is exactly `0.0` in that case, by identity rather
    // than by luck.
    //
    // What that residue cost: `tickMomentum` reads a non-zero remainder as
    // "hit an edge" and stops the fling. Every fling therefore died on its
    // second tick - 31 px of a 265 px throw - and the momentum written for
    // `ScrollPosition.fling` was, in practice, unreachable. A tolerance would
    // also have worked and would have needed a number nobody can justify; this
    // needs none.
    return target - clamped;
  }

  /// Converts a platform scroll delta into pixels and applies it.
  double applyScrollDelta(
    double delta, {
    bool inLines = false,
    double lineExtent = defaultLineExtent,
  }) =>
      applyDelta(inLines ? delta * lineExtent : delta);

  /// Scrolls by one page, the Page Up/Page Down and scrollbar-track step.
  ///
  /// One viewport minus a line of context, so the user keeps a reference row
  /// across the jump.
  double pageBy(int pages) {
    final double step =
        (_viewportExtent - defaultLineExtent).clamp(1.0, double.infinity);
    return applyDelta(step * pages);
  }

  /// Starts a fling at [velocity] pixels per second.
  void fling(double velocity) {
    _velocity = velocity;
    _notify();
  }

  /// Advances momentum by [elapsed] and returns whether motion continues.
  ///
  /// Deterministic and clock-free by design: the caller supplies the timestep,
  /// so a test can run a whole fling in a loop and a real app can drive it from
  /// the frame scheduler.
  bool tickMomentum(Duration elapsed, {double friction = 0.94}) {
    if (_velocity == 0) return false;
    final double seconds =
        elapsed.inMicroseconds / Duration.microsecondsPerSecond;
    if (seconds <= 0) return true;
    final double remainder = applyDelta(_velocity * seconds);
    // Decay after moving, so a fling always produces at least one step.
    _velocity *= friction;
    if (remainder != 0 || _velocity.abs() < 8) {
      // Hitting an edge ends the fling rather than grinding against it.
      _velocity = 0;
      _notify();
      return false;
    }
    return true;
  }

  /// Scrolls the least amount that brings `[start, start + extent]` of the
  /// content fully into view. Returns true when it moved.
  bool revealRange(double start, double extent) {
    final double end = start + extent;
    if (start < _pixels) return jumpTo(start);
    if (end > _pixels + _viewportExtent) {
      return jumpTo(end - _viewportExtent);
    }
    return false;
  }

  double _clamp(double value, {required bool allowOverscroll}) {
    final double slack = allowOverscroll ? overscrollAllowance : 0;
    final double lower = -slack;
    final double upper = maxScrollExtent + slack;
    if (value < lower) return lower;
    if (value > upper) return upper;
    return value;
  }

  void _notify() {
    for (final void Function(ScrollPosition) listener
        in List<void Function(ScrollPosition)>.of(_listeners)) {
      listener(this);
    }
  }

  @override
  String toString() =>
      'ScrollPosition(${axis.name}, $_pixels of $maxScrollExtent)';
}

/// Shows one window onto a child that may be larger than it.
///
/// The child is laid out unbounded along the scroll axis and constrained
/// across it, which is the definition that makes a column of items measure its
/// natural height while still matching the viewport's width.
/// Open for extension: a scroll *viewer* is a viewport plus a scrollbar and
/// input handling, and those belong to the control layer rather than here.
class RenderViewport extends RenderSingleChildBox {
  RenderViewport({
    required ScrollPosition position,
    ScrollContentAlignment contentAlignment = ScrollContentAlignment.start,
    super.child,
  })  : _position = position,
        _contentAlignment = contentAlignment {
    _position.addListener(_onPositionChanged);
  }

  ScrollPosition _position;
  ScrollContentAlignment _contentAlignment;

  ScrollPosition get position => _position;

  set position(ScrollPosition value) {
    if (identical(value, _position)) return;
    _position.removeListener(_onPositionChanged);
    _position = value..addListener(_onPositionChanged);
    markNeedsLayout();
  }

  ScrollContentAlignment get contentAlignment => _contentAlignment;

  set contentAlignment(ScrollContentAlignment value) {
    if (value == _contentAlignment) return;
    _contentAlignment = value;
    markNeedsLayout();
  }

  // Intrinsics stop at the scroll axis. A viewport's whole job is to make the
  // content's extent along that axis irrelevant to its parent, so reporting the
  // content's height as this node's intrinsic height would undo the scrolling:
  // a column that sized itself to a viewport's max-content height would be as
  // tall as the document. The minimum is therefore zero and the maximum is
  // zero too, which reads as "I will take whatever you give me". The cross axis
  // is a genuine requirement - the content really cannot be narrower - so it is
  // delegated unchanged.

  @override
  double computeMinIntrinsicWidth(double height) =>
      _position.axis == ScrollAxis.horizontal
          ? 0.0
          : super.computeMinIntrinsicWidth(height);

  @override
  double computeMaxIntrinsicWidth(double height) =>
      _position.axis == ScrollAxis.horizontal
          ? 0.0
          : super.computeMaxIntrinsicWidth(height);

  @override
  double computeMinIntrinsicHeight(double width) =>
      _position.axis == ScrollAxis.vertical
          ? 0.0
          : super.computeMinIntrinsicHeight(width);

  @override
  double computeMaxIntrinsicHeight(double width) =>
      _position.axis == ScrollAxis.vertical
          ? 0.0
          : super.computeMaxIntrinsicHeight(width);

  /// None. A scrolled child's baseline moves every frame, and a row that
  /// aligned to it would twitch as the content scrolled.
  @override
  double? computeDistanceToActualBaseline(TextBaseline baseline) => null;

  @override
  void performLayout() {
    final RenderBox? child = this.child;
    // A viewport is as big as it is allowed to be: it is the thing that turns
    // "unbounded content" into "bounded box", so it must not shrink-wrap.
    final Size viewport = Size(
      constraints.hasBoundedWidth ? constraints.maxWidth : constraints.minWidth,
      constraints.hasBoundedHeight
          ? constraints.maxHeight
          : constraints.minHeight,
    );
    size = constraints.constrain(viewport);
    if (child == null) {
      _position.applyViewportGeometry(viewportExtent: 0, contentExtent: 0);
      return;
    }
    final BoxConstraints childConstraints =
        _position.axis == ScrollAxis.vertical
            ? BoxConstraints(
                minWidth: size.width,
                maxWidth: size.width,
                maxHeight: double.infinity,
              )
            : BoxConstraints(
                minHeight: size.height,
                maxHeight: size.height,
                maxWidth: double.infinity,
              );
    child.layout(childConstraints, parentUsesSize: true);
    final double viewportExtent =
        _position.axis == ScrollAxis.vertical ? size.height : size.width;
    final double contentExtent = _position.axis == ScrollAxis.vertical
        ? child.size.height
        : child.size.width;
    _position.applyViewportGeometry(
      viewportExtent: viewportExtent,
      contentExtent: contentExtent,
    );
    final double slack = (viewportExtent - contentExtent).clamp(
      0.0,
      double.infinity,
    );
    final double alignmentOffset = switch (_contentAlignment) {
      ScrollContentAlignment.start => 0.0,
      ScrollContentAlignment.center => slack / 2,
      ScrollContentAlignment.end => slack,
    };
    // The scroll offset is negative; alignment contributes only while content
    // is smaller than the viewport, when maxScrollExtent is zero.
    child.parentData!.offset = _position.axis == ScrollAxis.vertical
        ? Offset(0, alignmentOffset - _position.pixels)
        : Offset(alignmentOffset - _position.pixels, 0);
  }

  @override
  void paint(DisplayList list, Offset offset) {
    final RenderBox? child = this.child;
    if (child == null) return;
    // Clipping is not decoration here: without it a viewport paints its whole
    // child over its siblings, and the frame is wrong rather than merely ugly.
    list.save();
    list.clipRectangle(
      Rect.fromLTWH(offset.dx, offset.dy, size.width, size.height),
    );
    paintChild(list, child, offset);
    list.restore();
  }

  @override
  RenderBox? hitTestChildren(Offset position, {HitTestPath? path}) {
    // Outside the viewport there is nothing to hit even though the child
    // extends past it - the same rule the clip enforces for paint.
    if (!size.contains(position)) return null;
    return super.hitTestChildren(position, path: path);
  }

  void _onPositionChanged(ScrollPosition position) {
    // Scrolling moves a child, which is layout, not paint: the child's offset
    // is written in performLayout.
    markNeedsLayout();
  }
}
