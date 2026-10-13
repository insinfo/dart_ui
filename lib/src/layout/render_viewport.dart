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

import '../foundation/change_notifier.dart' show Listenable;
import '../geometry/offset.dart';
import '../geometry/rect.dart';
import '../geometry/size.dart';
import '../graphics/display_list.dart';
import '../graphics/display_list_geometry.dart';
import 'box_constraints.dart';
import 'render_box.dart';
import 'render_flex.dart' show Axis;
import 'scroll_metrics.dart';

/// The axis a scroll view scrolls along: the same type as Flutter's [Axis],
/// under the name this framework's scroll views have always used, so
/// `axis: ScrollAxis.vertical` and `scrollDirection: Axis.vertical` are the
/// same value.
typedef ScrollAxis = Axis;

/// What a scroll view's `controller:` accepts.
///
/// Two things are: Flutter's `ScrollController`, which creates a
/// [ScrollPosition] for every scroll view it is given to and follows them all;
/// and a [ScrollPosition] itself, which is how scroll views here have always
/// been driven and which simply drives the one view it is given to. A view
/// asks for its position with [attachScrollable] and hands it back with
/// [detachScrollable].
abstract interface class ScrollPositionSource {
  /// The position a scroll view along [axis] should drive. [oldPosition] is
  /// the one the same view drove until now, whose offset a new position may
  /// carry over.
  ScrollPosition attachScrollable(
    ScrollAxis axis, {
    ScrollPosition? oldPosition,
  });

  /// [position], returned by [attachScrollable], is no longer driven.
  void detachScrollable(ScrollPosition position);
}

/// Something running on a [ScrollPosition] over time - a fling, an
/// `animateTo`, a spring back from overscroll - that a newer one replaces.
///
/// [ScrollPosition.beginActivity] cancels the activity it replaces, which is
/// how a drag stops a fling and how `jumpTo` stops an animation.
abstract interface class ScrollActivityHandle {
  /// Stops the activity where it is. Called by the position; the activity
  /// must not call [ScrollPosition.beginActivity] from here.
  void cancel();
}

/// Hears the life of a scroll from a [ScrollPosition]: when it starts, every
/// movement, an edge hit, when it ends.
///
/// The scroll views implement it to send Flutter's scroll notifications. The
/// position cannot send them itself: it has no place in the widget tree, and
/// this layer has no notifications. `details` is the gesture's details object
/// when the user's input caused the event (a `DragStartDetails`,
/// `DragUpdateDetails` or `DragEndDetails`), null otherwise.
abstract interface class ScrollActivityListener {
  void didStartScroll(ScrollPosition position, Object? details);

  void didUpdateScrollPositionBy(
    ScrollPosition position,
    double delta,
    Object? details,
  );

  void didOverscrollBy(
    ScrollPosition position,
    double overscroll,
    Object? details,
  );

  void didEndScroll(ScrollPosition position, Object? details);

  void didUpdateScrollDirection(
    ScrollPosition position,
    ScrollDirection direction,
  );

  /// The viewport or content extent changed, without the offset moving.
  void didChangeMetrics(ScrollPosition position);
}

/// How far a scroll gesture moves per unit when the platform reports lines.
///
/// The value is the framework's fallback for one detent. Desktop systems
/// conventionally move three text lines per detent; using a single 16-pixel
/// line made long documents feel three times slower than their native peers.
/// A backend with an exact platform preference can still report pixels.
const double defaultLineExtent = 48.0;

/// Placement of scroll content when it is smaller than its viewport.
enum ScrollContentAlignment { start, center, end }

/// Decides where a user delta given to a [ScrollPosition] actually goes.
///
/// Scroll chaining hands an outer scrollable what an inner one *could not*
/// use. Some compositions need the opposite order - a `NestedScrollView`
/// collapses its header before the list inside it moves - and the list's own
/// input layer cannot know that. A position with a [ScrollPosition.coordinator]
/// therefore routes every user delta (wheel, drag, momentum, keyboard, paging)
/// through it, and the coordinator moves whichever positions it coordinates
/// with [ScrollPosition.applyOwnDelta].
abstract interface class ScrollDeltaCoordinator {
  /// Distributes [delta], given by the user to [source], and returns the part
  /// nobody consumed - the same contract as [ScrollPosition.applyDelta].
  double applyUserDelta(
    ScrollPosition source,
    double delta, {
    bool allowOverscroll = false,
  });
}

/// Where a scrollable is, how far it may go, and what happens at the edges.
///
/// ## As Flutter's `ScrollPosition`
///
/// It is a [ScrollMetrics] ([viewportDimension], [extentBefore],
/// [extentAfter], [outOfRange]...), a `Listenable` - [addListener] takes
/// Flutter's `void Function()` as well as this framework's
/// `void Function(ScrollPosition)` - and `animateTo` is an extension in the
/// widget layer, where the clock is. It is also a [ScrollPositionSource], so
/// a scroll view's `controller:` takes one directly, as it always has here;
/// Flutter code passes a `ScrollController` instead.
///
/// Differences from Flutter: [jumpTo] clamps to the scroll range rather than
/// overscrolling and springing back; [minScrollExtent] is always zero; and
/// there is no `ScrollActivity`/`ScrollContext` - the activity is a
/// [ScrollActivityHandle] and the scroll view listens through
/// [ScrollActivityListener].
final class ScrollPosition
    with ScrollMetrics
    implements Listenable, ScrollPositionSource {
  ScrollPosition({
    this.axis = ScrollAxis.vertical,
    double pixels = 0,
    double viewportExtent = 0,
    double contentExtent = 0,
    this.overscrollAllowance = 0,
    this.debugLabel,
  })  : _pixels = pixels,
        _viewportExtent = viewportExtent,
        _contentExtent = contentExtent;

  @override
  final ScrollAxis axis;

  /// A name for this position in [toString], for debugging.
  final String? debugLabel;

  /// How far past the end a drag may go before it is clamped. Zero gives the
  /// hard-stop behaviour Windows and X11 expect; a positive value is what a
  /// rubber-band effect is built from.
  final double overscrollAllowance;

  /// Either `void Function()` or `void Function(ScrollPosition)`.
  final List<Function> _listeners = <Function>[];

  final List<ScrollActivityListener> _activityListeners =
      <ScrollActivityListener>[];

  /// Who decides where this position's user deltas go; null applies them
  /// here. See [ScrollDeltaCoordinator].
  ScrollDeltaCoordinator? coordinator;

  double _pixels;
  double _viewportExtent;
  double _contentExtent;
  double _velocity = 0;
  bool _hasGeometry = false;
  AxisDirection? _axisDirection;
  ScrollActivityHandle? _activity;
  bool _scrolling = false;
  bool _holdOverscroll = false;
  ScrollDirection _userScrollDirection = ScrollDirection.idle;

  /// The details object of the user input currently moving this position -
  /// a `DragUpdateDetails` during a drag - which is reported with the
  /// movement it causes. Set by the scroll view around the call that moves
  /// the position, and null at any other time.
  Object? userDetails;

  // ---------------------------------------------------------------------------
  // ScrollMetrics
  // ---------------------------------------------------------------------------

  /// Always zero: content here starts at offset zero.
  @override
  double get minScrollExtent => 0.0;

  @override
  bool get hasPixels => true;

  @override
  bool get hasContentDimensions => _hasGeometry;

  @override
  bool get hasViewportDimension => _hasGeometry;

  /// Flutter's name for [viewportExtent].
  @override
  double get viewportDimension => _viewportExtent;

  /// The direction the offset grows in: down or right unless the scroll view
  /// driving this position said otherwise with [updateAxisDirection] (a
  /// reversed view says up or left).
  @override
  AxisDirection get axisDirection =>
      _axisDirection ??
      (axis == ScrollAxis.vertical ? AxisDirection.down : AxisDirection.right);

  /// One logical pixel per pixel: a position does not know the screen.
  @override
  double get devicePixelRatio => 1.0;

  /// Records which way the offset grows, which the scroll view knows (it is
  /// `reverse`) and the position does not. Must lie along [axis].
  void updateAxisDirection(AxisDirection direction) {
    if (axisDirectionToAxis(direction) != axis) {
      throw ArgumentError.value(
        direction,
        'direction',
        'must lie along the position\'s axis (${axis.name})',
      );
    }
    _axisDirection = direction;
  }

  // ---------------------------------------------------------------------------
  // Activity: what is scrolling this position, and the notifications about it
  // ---------------------------------------------------------------------------

  /// Whether a scroll is under way: a drag, a fling, an animation. Between
  /// [didStartScroll] and [didEndScroll].
  bool get isScrolling => _scrolling;

  /// The direction the user last scrolled in; [ScrollDirection.idle] once
  /// the scroll ended.
  ScrollDirection get userScrollDirection => _userScrollDirection;

  /// The activity currently driving this position, if any.
  ScrollActivityHandle? get activity => _activity;

  /// Makes [activity] the one driving this position, cancelling the one it
  /// replaces. Null just cancels.
  void beginActivity(ScrollActivityHandle? activity) {
    final ScrollActivityHandle? previous = _activity;
    if (identical(previous, activity)) return;
    _activity = activity;
    previous?.cancel();
  }

  /// [activity] has finished on its own. Does nothing if another one has
  /// replaced it.
  void endActivity(ScrollActivityHandle activity) {
    if (identical(_activity, activity)) _activity = null;
  }

  /// Starts listening to the life of scrolls on this position.
  void addActivityListener(ScrollActivityListener listener) =>
      _activityListeners.add(listener);

  void removeActivityListener(ScrollActivityListener listener) =>
      _activityListeners.remove(listener);

  /// A scroll starts: a drag began, a fling or an animation started. Does
  /// nothing if one is already under way.
  void didStartScroll([Object? details]) {
    if (_scrolling) return;
    _scrolling = true;
    for (final ScrollActivityListener listener in _activityListenersCopy) {
      listener.didStartScroll(this, details);
    }
  }

  /// The scroll under way ends. Settles an offset left out of range by an
  /// overscroll, and sets [userScrollDirection] back to idle.
  void didEndScroll([Object? details]) {
    if (!_scrolling) return;
    _scrolling = false;
    if (_holdOverscroll) {
      _holdOverscroll = false;
      final double clamped = _clamp(_pixels, allowOverscroll: false);
      if (clamped != _pixels) {
        final double delta = clamped - _pixels;
        _pixels = clamped;
        _notify();
        _reportUpdate(delta);
      }
    }
    for (final ScrollActivityListener listener in _activityListenersCopy) {
      listener.didEndScroll(this, details);
    }
    updateUserScrollDirection(ScrollDirection.idle);
  }

  /// Reports that [overscroll] pixels of a movement could not be applied.
  void didOverscrollBy(double overscroll) {
    if (overscroll == 0 || _activityListeners.isEmpty) return;
    for (final ScrollActivityListener listener in _activityListenersCopy) {
      listener.didOverscrollBy(this, overscroll, userDetails);
    }
  }

  /// Records the direction the user is scrolling in, telling the listeners
  /// when it changes.
  void updateUserScrollDirection(ScrollDirection direction) {
    if (direction == _userScrollDirection) return;
    _userScrollDirection = direction;
    for (final ScrollActivityListener listener in _activityListenersCopy) {
      listener.didUpdateScrollDirection(this, direction);
    }
  }

  List<ScrollActivityListener> get _activityListenersCopy =>
      _activityListeners.isEmpty
          ? const <ScrollActivityListener>[]
          : List<ScrollActivityListener>.of(_activityListeners);

  /// Tells the activity listeners the offset moved by [delta]. A movement
  /// outside a scroll - a key press, a `jumpTo` - is a scroll of its own: it
  /// starts and ends around the movement.
  void _reportUpdate(double delta) {
    if (delta == 0 || _activityListeners.isEmpty) return;
    final bool oneShot = !_scrolling;
    if (oneShot) didStartScroll();
    for (final ScrollActivityListener listener in _activityListenersCopy) {
      listener.didUpdateScrollPositionBy(this, delta, userDetails);
    }
    if (oneShot) didEndScroll();
  }

  /// Sets the offset to [value] without clamping, for a physics that lets
  /// the content be pulled past an edge (a bounce). While the offset is out
  /// of range, layout does not pull it back; [didEndScroll] does, if the
  /// physics has not already brought it back.
  void forcePixels(double value) {
    if (value == _pixels) return;
    final double delta = value - _pixels;
    _pixels = value;
    _holdOverscroll = value < 0 || value > maxScrollExtent;
    _notify();
    _reportUpdate(delta);
  }

  /// Moves to [value], clamped into range, without cancelling the current
  /// activity - what an animation calls on each frame. Returns the part of
  /// the move the range did not allow, as Flutter's `setPixels` does.
  double setPixels(double value) {
    final double clamped = _clamp(value, allowOverscroll: false);
    if (clamped != _pixels) {
      final double delta = clamped - _pixels;
      _pixels = clamped;
      _holdOverscroll = false;
      _notify();
      _reportUpdate(delta);
    }
    final double overscroll = value - clamped;
    if (overscroll != 0 && _scrolling) didOverscrollBy(overscroll);
    return overscroll;
  }

  // ---------------------------------------------------------------------------
  // ScrollPositionSource: a position drives the view it is given to
  // ---------------------------------------------------------------------------

  @override
  ScrollPosition attachScrollable(
    ScrollAxis axis, {
    ScrollPosition? oldPosition,
  }) =>
      this;

  @override
  void detachScrollable(ScrollPosition position) {}

  /// The current scroll offset, in logical pixels, within
  /// `[-overscrollAllowance, maxScrollExtent + overscrollAllowance]` unless a
  /// bouncing physics has pulled it further with [forcePixels].
  @override
  double get pixels => _pixels;

  /// The visible extent along [axis].
  double get viewportExtent => _viewportExtent;

  /// The child's extent along [axis].
  double get contentExtent => _contentExtent;

  /// The largest in-range offset. Zero when the content fits, which is what
  /// makes a short list refuse to scroll at all rather than jitter.
  @override
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

  /// Calls [listener] whenever the offset or the geometry changes.
  ///
  /// [listener] is either Flutter's `void Function()` or this framework's
  /// `void Function(ScrollPosition)`, which is handed the position. The
  /// parameter is typed [Function] so that both compile; anything else is an
  /// [ArgumentError].
  @override
  void addListener(Function listener) {
    if (listener is! void Function(ScrollPosition) &&
        listener is! void Function()) {
      throw ArgumentError.value(
        listener,
        'listener',
        'must be a void Function() or a void Function(ScrollPosition)',
      );
    }
    _listeners.add(listener);
  }

  @override
  void removeListener(Function listener) => _listeners.remove(listener);

  /// Records the geometry measured by the viewport during layout.
  ///
  /// Re-clamps, because a window that shrank can leave the offset past the new
  /// maximum - which shows as a list scrolled into empty space below its last
  /// item.
  bool applyViewportGeometry({
    required double viewportExtent,
    required double contentExtent,
  }) {
    final bool changed = !_hasGeometry ||
        viewportExtent != _viewportExtent ||
        contentExtent != _contentExtent;
    _viewportExtent = viewportExtent;
    _contentExtent = contentExtent;
    _hasGeometry = true;
    // An overscroll a bouncing physics is holding is the physics' to settle;
    // re-clamping it here would snap the content back mid-gesture.
    final double clamped =
        _holdOverscroll ? _pixels : _clamp(_pixels, allowOverscroll: false);
    if (clamped != _pixels) {
      _pixels = clamped;
      _notify();
      _reportMetrics();
      return true;
    }
    if (changed) {
      _notify();
      _reportMetrics();
    }
    return changed;
  }

  void _reportMetrics() {
    for (final ScrollActivityListener listener in _activityListenersCopy) {
      listener.didChangeMetrics(this);
    }
  }

  /// Jumps to [value], clamped into range. Returns true when it moved.
  ///
  /// Stops whatever was moving the position - a fling, an animation - as
  /// Flutter's `jumpTo` does, and is reported as a scroll of its own.
  bool jumpTo(double value) {
    beginActivity(null);
    final double clamped = _clamp(value, allowOverscroll: false);
    if (clamped == _pixels) return false;
    final double delta = clamped - _pixels;
    _pixels = clamped;
    _velocity = 0;
    _holdOverscroll = false;
    _notify();
    _reportUpdate(delta);
    return true;
  }

  /// Moves the offset by [correction] without clamping it and without ending
  /// a fling, because the content moved rather than the user.
  ///
  /// This is the call a sliver viewport makes during layout when a list
  /// discovers that the items *above* the visible ones are not the size it
  /// had estimated. The content before the viewport just grew or shrank by
  /// [correction], so the same pixel offset now shows different items; moving
  /// the offset by the same amount keeps the item the user was looking at
  /// exactly where it was. [jumpTo] would be wrong twice over: it clamps
  /// against a content extent that is itself about to be corrected, and it
  /// stops a fling that the user did nothing to stop.
  ///
  /// Listeners are notified, so a scrollbar follows; the next
  /// [applyViewportGeometry] re-clamps once the content extent is known.
  void correctBy(double correction) {
    if (correction == 0) return;
    _pixels += correction;
    _notify();
  }

  /// Applies a user delta, returning the part this position could **not**
  /// consume.
  ///
  /// The unconsumed remainder is the whole basis of scroll chaining (section
  /// 27.8): an inner list that has hit its end returns the leftover, and the
  /// outer scrollable moves by exactly that much. A method that returned only
  /// "handled or not" cannot express a gesture that is half consumed.
  ///
  /// With a [coordinator] the delta is the coordinator's to distribute, and
  /// the remainder is what no position it coordinates could use.
  double applyDelta(double delta, {bool allowOverscroll = false}) {
    final ScrollDeltaCoordinator? coordinator = this.coordinator;
    if (coordinator != null) {
      return coordinator.applyUserDelta(
        this,
        delta,
        allowOverscroll: allowOverscroll,
      );
    }
    return applyOwnDelta(delta, allowOverscroll: allowOverscroll);
  }

  /// [applyDelta] on this position alone, bypassing any [coordinator]. What a
  /// coordinator itself calls.
  double applyOwnDelta(double delta, {bool allowOverscroll = false}) {
    if (delta == 0) return 0;
    final double target = _pixels + delta;
    final double clamped = _clamp(target, allowOverscroll: allowOverscroll);
    final double consumed = clamped - _pixels;
    if (consumed != 0) {
      _pixels = clamped;
      _holdOverscroll = false;
      _notify();
      _reportUpdate(consumed);
    }
    // Only a scroll under way reports what it could not use: a key pressed
    // at the end of a list is not an overscroll, a drag pulled past it is.
    if (target != clamped && _scrolling) didOverscrollBy(target - clamped);
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
    if (_listeners.isEmpty) return;
    for (final Function listener in List<Function>.of(_listeners)) {
      if (listener is void Function(ScrollPosition)) {
        listener(this);
      } else {
        (listener as void Function())();
      }
    }
  }

  @override
  String toString() => 'ScrollPosition('
      '${debugLabel == null ? '' : '$debugLabel, '}'
      '${axis.name}, $_pixels of $maxScrollExtent)';
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
    bool reverse = false,
    super.child,
  })  : _position = position,
        _contentAlignment = contentAlignment,
        _reverse = reverse {
    _position.addListener(_onPositionChanged);
  }

  ScrollPosition _position;
  ScrollContentAlignment _contentAlignment;
  bool _reverse;

  /// Whether offset zero shows the *end* of the child - its bottom, or its
  /// right edge - as in Flutter's `SingleChildScrollView(reverse: true)`.
  /// A child shorter than the viewport then sits at the bottom (or right).
  bool get reverse => _reverse;

  set reverse(bool value) {
    if (value == _reverse) return;
    _reverse = value;
    markNeedsLayout();
  }

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
    final bool vertical = _position.axis == ScrollAxis.vertical;
    // A viewport is as big as it is allowed to be: it is the thing that turns
    // "unbounded content" into "bounded box", so it must not shrink-wrap.
    // Except along an axis with no bound at all - a scroll view in a column -
    // where the only finite answer is the child's own extent, which is what
    // Flutter gives (and what makes the view not scroll there).
    final bool unboundedMain =
        vertical ? !constraints.hasBoundedHeight : !constraints.hasBoundedWidth;
    final bool unboundedCross =
        vertical ? !constraints.hasBoundedWidth : !constraints.hasBoundedHeight;
    if (child == null) {
      size = constraints.constrain(Size(
        constraints.hasBoundedWidth
            ? constraints.maxWidth
            : constraints.minWidth,
        constraints.hasBoundedHeight
            ? constraints.maxHeight
            : constraints.minHeight,
      ));
      _position.applyViewportGeometry(viewportExtent: 0, contentExtent: 0);
      return;
    }
    final double crossExtent = vertical
        ? (unboundedCross ? double.infinity : constraints.maxWidth)
        : (unboundedCross ? double.infinity : constraints.maxHeight);
    final BoxConstraints childConstraints = vertical
        ? (unboundedCross
            ? BoxConstraints(
                minWidth: constraints.minWidth,
                maxHeight: double.infinity,
              )
            : BoxConstraints(
                minWidth: crossExtent,
                maxWidth: crossExtent,
                maxHeight: double.infinity,
              ))
        : (unboundedCross
            ? BoxConstraints(
                minHeight: constraints.minHeight,
                maxWidth: double.infinity,
              )
            : BoxConstraints(
                minHeight: crossExtent,
                maxHeight: crossExtent,
                maxWidth: double.infinity,
              ));
    child.layout(childConstraints, parentUsesSize: true);
    size = constraints.constrain(Size(
      vertical
          ? (unboundedCross ? child.size.width : constraints.maxWidth)
          : (unboundedMain ? child.size.width : constraints.maxWidth),
      vertical
          ? (unboundedMain ? child.size.height : constraints.maxHeight)
          : (unboundedCross ? child.size.height : constraints.maxHeight),
    ));
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
    // is smaller than the viewport, when maxScrollExtent is zero. Reversed,
    // offset zero shows the child's far end, and alignment is mirrored too.
    final double main = _reverse
        ? viewportExtent - contentExtent - alignmentOffset + _position.pixels
        : alignmentOffset - _position.pixels;
    child.parentData!.offset = _position.axis == ScrollAxis.vertical
        ? Offset(0, main)
        : Offset(main, 0);
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
