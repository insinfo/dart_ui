/// Deterministic pointer input for gesture tests.
///
/// Every timestamp here comes from a [ManualDispatcher]'s virtual clock, and
/// nothing in this file or in `lib/src/gestures` calls `DateTime.now`. That is
/// not tidiness: a gesture suite whose long-press deadline or double-tap
/// interval is measured against the wall clock passes on a fast laptop and
/// fails on a loaded CI runner, and the failure looks like a flaky product
/// rather than a flaky test.
library;

import 'package:dart_ui/src/geometry/offset.dart';
import 'package:dart_ui/src/gestures/arena.dart';
import 'package:dart_ui/src/gestures/recognizer.dart';
import 'package:dart_ui/src/platform/input_events.dart';
import 'package:dart_ui/src/platform/window_events.dart';
import 'package:dart_ui/src/scheduler/manual_dispatcher.dart';

/// A single pointer, driven by a virtual clock.
final class Hand {
  Hand({
    ManualDispatcher? dispatcher,
    this.kind = PointerKind.mouse,
    this.pointerId = 0,
  }) : dispatcher = dispatcher ?? ManualDispatcher();

  final ManualDispatcher dispatcher;
  final PointerKind kind;
  final int pointerId;

  static const NativeWindowId windowId = NativeWindowId(1);

  /// The current virtual instant. Every event this hand makes is stamped here.
  Duration get now => dispatcher.elapsed;

  /// Moves the virtual clock, firing any deadline that comes due.
  void advance(Duration delta) => dispatcher.advance(delta);

  PointerDownEvent down(
    Offset position, {
    PointerButton button = PointerButton.primary,
    int clickCount = 1,
  }) =>
      PointerDownEvent(
        windowId: windowId,
        generation: 1,
        timestamp: now,
        pointerId: pointerId,
        kind: kind,
        logicalPosition: position,
        button: button,
        clickCount: clickCount,
      );

  PointerMoveEvent move(Offset position) => PointerMoveEvent(
        windowId: windowId,
        generation: 1,
        timestamp: now,
        pointerId: pointerId,
        kind: kind,
        logicalPosition: position,
      );

  PointerUpEvent up(
    Offset position, {
    PointerButton button = PointerButton.primary,
  }) =>
      PointerUpEvent(
        windowId: windowId,
        generation: 1,
        timestamp: now,
        pointerId: pointerId,
        kind: kind,
        logicalPosition: position,
        button: button,
      );

  PointerCancelEvent cancel(Offset position) => PointerCancelEvent(
        windowId: windowId,
        generation: 1,
        timestamp: now,
        pointerId: pointerId,
        kind: kind,
        logicalPosition: position,
      );

  PointerScrollEvent scroll(
    Offset delta, {
    Offset position = Offset.zero,
    ScrollDeltaUnit unit = ScrollDeltaUnit.pixels,
  }) =>
      PointerScrollEvent(
        windowId: windowId,
        generation: 1,
        timestamp: now,
        pointerId: pointerId,
        kind: kind,
        logicalPosition: position,
        scrollDelta: delta,
        scrollDeltaUnit: unit,
      );

  /// A second hand on the same clock, for pinch tests.
  Hand withPointer(int id) =>
      Hand(dispatcher: dispatcher, kind: kind, pointerId: id);
}

/// Drives recognizers exactly the way `PointerRouter` does, with no tree.
///
/// The order is the contract being tested: every recognizer sees the event
/// first, and only then does the arena move to its next phase. Closing the
/// arena in the middle of dispatch would resolve a negotiation that the
/// recognizers further down the path had not joined yet.
final class RecognizerHarness {
  RecognizerHarness({GestureArenaManager? arena})
      : arena = arena ?? GestureArenaManager();

  final GestureArenaManager arena;
  final List<GestureRecognizer> recognizers = <GestureRecognizer>[];

  /// Adds a recognizer. Order matters: it is the arena's tie-break, and the
  /// real router adds them deepest-first.
  T add<T extends GestureRecognizer>(T recognizer) {
    recognizers.add(recognizer);
    return recognizer;
  }

  void dispatch(PointerEvent event) {
    for (final GestureRecognizer recognizer in recognizers) {
      recognizer.routeEvent(event);
    }
    switch (event) {
      case PointerDownEvent():
        arena.close(event.pointerId);
      case PointerUpEvent():
        arena.sweep(event.pointerId);
      case PointerCancelEvent():
        arena.cancel(event.pointerId);
      case PointerMoveEvent():
      case PointerScrollEvent():
        break;
    }
  }

  void dispatchAll(Iterable<PointerEvent> events) => events.forEach(dispatch);
}

/// An arena member that records what happened to it, in order.
final class RecordingMember implements GestureArenaMember {
  RecordingMember(this.name);

  final String name;
  final List<String> log = <String>[];

  bool get accepted => log.contains('accept');

  bool get rejected => log.contains('reject');

  /// The contract says exactly one of the two, exactly once.
  bool get settledExactlyOnce => log.length == 1;

  @override
  void acceptGesture(int pointer) => log.add('accept');

  @override
  void rejectGesture(int pointer) => log.add('reject');

  @override
  String toString() => 'RecordingMember($name, $log)';
}

/// An arena member that claims victory as soon as it is told to.
final class EagerMember implements GestureArenaMember {
  EagerMember(this.name);

  final String name;
  final List<String> log = <String>[];
  GestureArenaEntry? entry;

  void claim() => entry?.resolve(GestureDisposition.accepted);

  void concede() => entry?.resolve(GestureDisposition.rejected);

  @override
  void acceptGesture(int pointer) => log.add('accept');

  @override
  void rejectGesture(int pointer) => log.add('reject');

  @override
  String toString() => 'EagerMember($name, $log)';
}
