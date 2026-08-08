/// The cancellation token returned by `UiDispatcher.schedule`.
///
/// The idempotence in this file is a house rule earned the hard way: the
/// macOS spike in this repository spent weeks on crashes whose proximate
/// cause was a second teardown of something already torn down, arriving late
/// from a callback that had outlived the object it referenced. A handle that
/// throws or double-frees on the second `cancel()` pushes that whole class of
/// bug onto every caller. This one absorbs it.
library;

import 'package:meta/meta.dart';

/// A scheduled timer that has not necessarily fired yet.
///
/// A handle is *active* from creation until exactly one of two things
/// happens: it fires, or it is cancelled. Both are terminal, both are
/// observable through [isActive], and neither can happen twice.
///
/// Contract for callers:
///
/// - [cancel] is idempotent. Calling it twice, calling it after the timer has
///   already fired, or calling it from inside the timer's own callback are
///   all legal and all no-ops after the first effective call.
/// - After [cancel] returns, the callback will not run. There is no window in
///   which a cancelled timer still fires, because a dispatcher marks a timer
///   as fired *before* invoking its callback.
///
/// Contract for dispatcher implementations: construct one handle per
/// scheduled timer, call [markFired] immediately before invoking the
/// callback, and treat the `onCancel` hook as a request to forget the timer.
/// The hook is invoked at most once and never for a timer that already fired.
final class TimerHandle {
  /// Creates a handle for a timer the caller has just armed.
  ///
  /// [onCancel] is the owning dispatcher's de-registration hook. It receives
  /// this handle so one shared implementation can serve every timer the
  /// dispatcher owns without allocating a closure per timer.
  TimerHandle({required void Function(TimerHandle handle) onCancel})
      : _onCancel = onCancel;

  final void Function(TimerHandle handle) _onCancel;

  bool _active = true;
  bool _cancelled = false;

  /// Whether the timer is still pending: armed, not yet fired, not cancelled.
  bool get isActive => _active;

  /// Whether the timer stopped being active because [cancel] was called,
  /// as opposed to having fired.
  ///
  /// Kept distinct from `!isActive` because "did not run" and "already ran"
  /// are different facts, and a diagnostic that conflates them sends the
  /// reader looking for the wrong bug.
  bool get isCancelled => _cancelled;

  /// Cancels the timer if it is still pending.
  ///
  /// Safe to call any number of times, in any order, from anywhere -
  /// including from inside another timer's callback while the owning
  /// dispatcher is mid-pump.
  void cancel() {
    if (!_active) return;
    _active = false;
    _cancelled = true;
    _onCancel(this);
  }

  /// Marks the timer as having fired. Owner-side API.
  ///
  /// `@internal` makes that enforceable: the analyser flags a call from
  /// outside this package, which is where the damage would come from.
  ///
  /// Called by the dispatcher that created the handle, immediately before it
  /// invokes the callback - never by client code. Doing it before rather than
  /// after the callback is what makes "cancel from inside my own callback" a
  /// no-op instead of a re-entrant de-registration.
  @internal
  void markFired() {
    _active = false;
  }

  @override
  String toString() {
    if (_active) return 'TimerHandle(pending)';
    return _cancelled ? 'TimerHandle(cancelled)' : 'TimerHandle(fired)';
  }
}
