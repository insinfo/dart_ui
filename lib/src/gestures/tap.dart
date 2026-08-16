/// Tap, and the second tap that means something else.
library;

import '../geometry/offset.dart';
import '../platform/input_events.dart';
import 'constants.dart';
import 'recognizer.dart';

/// What a tap callback is told.
final class TapDetails {
  const TapDetails({
    required this.globalPosition,
    required this.timestamp,
    required this.kind,
    required this.button,
    required this.tapCount,
  });

  /// Where the press or release happened, in root coordinates.
  final Offset globalPosition;

  /// The platform's timestamp for the event that produced this callback.
  final Duration timestamp;

  final PointerKind kind;
  final PointerButton button;

  /// 1, 2 or 3: which tap of a run this was. See [MultiTapCounter].
  final int tapCount;

  @override
  String toString() => 'TapDetails($globalPosition, tapCount: $tapCount)';
}

/// Decides whether a tap continues the previous one, or starts a new run.
///
/// **The rule here is not invented; it is the one this repository already
/// applies to mouse clicks in `RenderTextField._countClick`, and it must stay
/// that way.** Two presses that make a double click for a text field and two
/// separate taps for a gesture detector, in the same window, in the same
/// instant, would be indefensible.
///
/// So, in order:
///
///  1. **If the platform counted, the platform is right.**
///     [PointerDownEvent.clickCount] is greater than 1 when the OS itself
///     decided this press continues the previous one - `WM_LBUTTONDBLCLK` on
///     Windows, `NSEvent.clickCount` on macOS. That decision was made against
///     `GetDoubleClickTime()` and the `SM_CXDOUBLECLK` rectangle, both of which
///     live in the user's mouse control panel and are **accessibility
///     settings**: someone with a tremor raises the interval precisely because
///     the default is too fast for them. Re-deriving the count from a constant
///     here would silently override the setting they chose.
///  2. **Otherwise, time and distance together.** X11 reports no count at all,
///     and touch never does. Either test alone is wrong: two presses a second
///     apart in the same pixel are two taps, and two fast presses at opposite
///     corners are also two taps. The distance test is per-axis, a rectangle,
///     because that is the shape Windows uses.
///  3. **A fourth tap starts again at one**, which is what Windows does, and
///     which is what makes triple-click-to-select-line repeatable.
///
/// Note that even on Windows the *third* press of a triple lands on rule 2:
/// there is no `WM_LBUTTONTRIPLECLK`, so the OS counts to two and stops.
final class MultiTapCounter {
  MultiTapCounter({this.interval = kDoubleTapTimeout, this.slop});

  /// The longest gap that still continues a run when the platform did not say.
  final Duration interval;

  /// The largest per-axis distance that still continues a run, or null to use
  /// [doubleTapSlopForKind] for the device the press came from.
  final double? slop;

  int _count = 0;
  Duration _lastAt = Duration.zero;
  Offset _lastPosition = Offset.zero;
  bool _hasPrevious = false;

  /// The current run length: 0 before any tap, else 1, 2 or 3.
  int get count => _count;

  /// Counts a press described by its parts, and returns which tap it is.
  ///
  /// [platformClickCount] is [PointerDownEvent.clickCount]: 1 when the platform
  /// did not count, more when it did and said this press continues the
  /// previous one.
  int countTapAt({
    required Duration timestamp,
    required Offset position,
    required PointerKind kind,
    int platformClickCount = 1,
  }) {
    _count = peekTapAt(
      timestamp: timestamp,
      position: position,
      kind: kind,
      platformClickCount: platformClickCount,
    );
    _lastAt = timestamp;
    _lastPosition = position;
    _hasPrevious = true;
    return _count;
  }

  /// What [countTapAt] would return, without counting.
  ///
  /// For a caller that has to report the count *before* the tap completes -
  /// a press highlight that differs on the second click - and must not let
  /// that report decide the run.
  int peekTapAt({
    required Duration timestamp,
    required Offset position,
    required PointerKind kind,
    int platformClickCount = 1,
  }) {
    final Duration since = timestamp - _lastAt;
    final Offset moved = position - _lastPosition;
    final double limit = slop ?? doubleTapSlopForKind(kind);
    final bool continues = _hasPrevious &&
        (platformClickCount > 1 ||
            (since >= Duration.zero &&
                since <= interval &&
                moved.dx.abs() <= limit &&
                moved.dy.abs() <= limit));
    return continues ? _count % 3 + 1 : 1;
  }

  /// Counts [event], the press form of [countTapAt].
  int countTap(PointerDownEvent event) => countTapAt(
        timestamp: event.timestamp,
        position: event.logicalPosition,
        kind: event.kind,
        platformClickCount: event.clickCount,
      );

  /// Forgets the run, so the next tap counts as the first.
  void reset() {
    _count = 0;
    _hasPrevious = false;
    _lastAt = Duration.zero;
    _lastPosition = Offset.zero;
  }
}

/// Recognizes a press and release on the same target.
///
/// ## When the callbacks fire
///
/// [onTapDown] fires when this recognizer **wins its arena**, not when the
/// press arrives. For a detector with no competition that is the same instant,
/// so a button still highlights the moment it is touched. Where there is
/// competition it is deliberately later: highlighting a button that the scroll
/// underneath is about to take over is the flicker every toolkit has had to
/// fix, and the fix is always to wait for the arena.
///
/// [onTap] fires on the release, and only if the release landed on the target -
/// see [PrimaryPointerGestureRecognizer.targetContains]. Dragging off the
/// button and letting go is how a user takes a tap back.
///
/// ## Double tap
///
/// [onDoubleTap] fires **in addition to** [onTap], on the second tap of a run.
/// This is the desktop convention and the one the rest of this repository
/// already follows: `WM_LBUTTONDOWN` is delivered before `WM_LBUTTONDBLCLK`,
/// and a text field places the caret on the first click and selects the word
/// on the second - it does not withhold the first click until the double-click
/// interval expires.
///
/// That choice has a consequence worth being explicit about: because nothing is
/// withheld, **no timer is involved at all**. Mobile toolkits suppress the
/// first tap until the timeout, which costs a deadline, an arena hold, and a
/// visible delay on every single tap. Here the count is derived from the press
/// itself - see [MultiTapCounter] - so a single tap is never slower for the
/// possibility of a second.
class TapGestureRecognizer extends PrimaryPointerGestureRecognizer {
  TapGestureRecognizer({
    super.arena,
    super.debugOwner,
    super.slop,
    super.button,
    this.onTapDown,
    this.onTapUp,
    this.onTap,
    this.onDoubleTap,
    this.onTapCancel,
    MultiTapCounter? counter,
  }) : _counter = counter ?? MultiTapCounter();

  /// The press was accepted as this recognizer's.
  void Function(TapDetails details)? onTapDown;

  /// The release that completed the tap, with position and count.
  void Function(TapDetails details)? onTapUp;

  /// The tap happened. The zero-argument form, for the common case.
  void Function()? onTap;

  /// The second tap of a run happened. [onTap] fired for it as well.
  void Function(TapDetails details)? onDoubleTap;

  /// A press that had been reported by [onTapDown] will not become a tap.
  void Function()? onTapCancel;

  final MultiTapCounter _counter;

  /// The run counter, exposed so an owner can reset it - a control that loses
  /// focus should not let a click from before the focus change join a run.
  MultiTapCounter get counter => _counter;

  PointerUpEvent? _up;
  bool _downReported = false;

  @override
  void didPressDown(PointerDownEvent event) {
    _up = null;
    _downReported = false;
  }

  @override
  void handlePrimaryPointer(PointerEvent event) {
    switch (event) {
      case PointerMoveEvent():
        // Past the slop this press is somebody else's - a drag, a scroll. The
        // recognizer concedes rather than waiting to lose, which is what lets
        // a lone drag recognizer win by walkover as soon as it moves.
        if (distanceFromOrigin(event.logicalPosition) > slop) {
          concede();
        }
      case PointerUpEvent():
        if (event.button != button) return;
        final bool Function(Offset)? contains = targetContains;
        if (contains != null && !contains(event.logicalPosition)) {
          concede();
          return;
        }
        _up = event;
        _checkDownAndUp();
      case PointerCancelEvent():
        concede();
      case PointerDownEvent():
      case PointerScrollEvent():
        break;
    }
  }

  @override
  void acceptGesture(int pointer) {
    super.acceptGesture(pointer);
    _checkDownAndUp();
  }

  @override
  void rejectGesture(int pointer) {
    if (pointer == primaryPointer && _downReported) {
      _downReported = false;
      onTapCancel?.call();
    }
    _up = null;
    super.rejectGesture(pointer);
  }

  /// Fires whatever the current state allows.
  ///
  /// Called from both the release and the arena win, because either can be
  /// last: a lone detector wins on the press and fires on the release, while a
  /// detector competing with a drag is still undecided at the release and wins
  /// on the sweep that follows it.
  void _checkDownAndUp() {
    if (!hasWonArena) return;
    final int? pointer = primaryPointer;
    if (pointer == null) return;
    if (!_downReported) {
      _downReported = true;
      onTapDown?.call(
        TapDetails(
          globalPosition: initialPosition,
          timestamp: initialTime,
          kind: pointerKind,
          button: button,
          // Projected, not counted: the run is only advanced when the tap
          // actually completes, so a press that ends up losing its arena to a
          // scroll must not make the next one a double.
          tapCount: _counter.peekTapAt(
            timestamp: initialTime,
            position: initialPosition,
            kind: pointerKind,
            platformClickCount: _platformClickCount,
          ),
        ),
      );
    }
    final PointerUpEvent? up = _up;
    if (up == null) return;
    _up = null;
    // Counted here rather than on the press: a press that lost its arena to a
    // scroll was never a tap, and must not make the next one a double. The
    // press's own timestamp and position are what the run is measured by,
    // because that is what the platform measured its own count against.
    final int count = _counter.countTapAt(
      timestamp: initialTime,
      position: initialPosition,
      kind: pointerKind,
      platformClickCount: _platformClickCount,
    );
    _platformClickCount = 1;
    final details = TapDetails(
      globalPosition: up.logicalPosition,
      timestamp: up.timestamp,
      kind: pointerKind,
      button: up.button,
      tapCount: count,
    );
    _downReported = false;
    stopTracking();
    onTapUp?.call(details);
    onTap?.call();
    if (count == 2) onDoubleTap?.call(details);
  }

  int _platformClickCount = 1;

  @override
  bool shouldAcceptPress(PointerDownEvent event) {
    // Remembered rather than read later: the count the OS reported belongs to
    // this press, and the press event is gone by the time the tap completes.
    _platformClickCount = event.clickCount;
    return true;
  }
}

/// Recognizes only the second tap of a run, for an owner that wants nothing
/// else.
///
/// Fires [onDoubleTap] and nothing on a single tap. It still does not suppress
/// or delay a competing single-tap recognizer, because it has no way to and no
/// reason to: see [TapGestureRecognizer] for why the first tap is never
/// withheld here.
final class DoubleTapGestureRecognizer extends TapGestureRecognizer {
  DoubleTapGestureRecognizer({
    super.arena,
    super.debugOwner,
    super.slop,
    super.button,
    super.onDoubleTap,
    super.counter,
  });
}
