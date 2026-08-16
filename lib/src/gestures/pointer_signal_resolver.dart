/// Which one of the scrollables under the cursor gets the wheel.
///
/// A pointer signal - a wheel notch, a trackpad scroll - is not a gesture and
/// cannot be arbitrated like one. There is no press, no movement and no
/// release, so there is nothing to hold two interpretations open *over*: the
/// event arrives complete and has to be answered before it is dispatched to
/// the next node.
///
/// Left alone, the consequence is a concrete bug in this repository today. A
/// `RenderScrollViewer` inside another `RenderScrollViewer` puts both of them
/// on the hit-test path, `PointerRouter` offers the same
/// `PointerScrollEvent` to both, and both call
/// `ScrollPosition.applyScrollDelta`. One notch of the wheel scrolls two
/// lists. `ScrollPosition` already has the *other* half of the answer -
/// `applyDelta` returns the delta it could not consume, so an inner list at its
/// end can hand the remainder outward deliberately - but nothing was
/// arbitrating who gets to consume in the first place.
///
/// So: candidates register interest while the event is being dispatched, the
/// router resolves once dispatch is done, and **the first registrant wins**.
/// First means innermost, because the hit-test path is offered deepest-first,
/// and innermost is the right default for the same reason it is on every
/// platform - the wheel acts on the thing under the cursor, not on its
/// container.
///
/// The design is Flutter's `PointerSignalResolver`.
library;

import '../platform/input_events.dart';

/// Handles a scroll signal that has been awarded to its registrant.
typedef PointerSignalResolvedCallback = void Function(PointerScrollEvent event);

/// Collects candidates for one scroll signal and awards it to the first.
///
/// One instance per router. Registration is only meaningful during the
/// dispatch of the event being registered for; [resolve] closes the round.
final class PointerSignalResolver {
  PointerSignalResolvedCallback? _firstRegistered;
  PointerScrollEvent? _currentEvent;

  /// Whether a candidate has claimed the event currently being dispatched.
  bool get hasCandidate => _firstRegistered != null;

  /// Offers to handle [event], if nobody deeper already has.
  ///
  /// Called from a render node's pointer handler instead of acting on the
  /// event directly. Later registrations for the same event are dropped -
  /// that is the arbitration - so a node must not assume its callback runs.
  ///
  /// Registering for a *different* event while one is pending is a bug in the
  /// caller: it means a node acted on an event that was never resolved, and
  /// the pending callback would then be invoked with the wrong event. It
  /// throws rather than silently mismatching them.
  void register(
    PointerScrollEvent event,
    PointerSignalResolvedCallback callback,
  ) {
    final PointerScrollEvent? pending = _currentEvent;
    if (pending != null && !identical(pending, event)) {
      throw StateError(
        'PointerSignalResolver.register() was called for a different event '
        'than the one still pending. Registration is only valid while the '
        'event is being dispatched, and the router resolves each event '
        'before dispatching the next.',
      );
    }
    if (_firstRegistered != null) return;
    _currentEvent = event;
    _firstRegistered = callback;
  }

  /// Awards [event] to its first registrant, if there was one.
  ///
  /// Returns whether anything consumed the event - which a backend can use to
  /// let the platform have the wheel notch instead, so that a window with no
  /// scrollable under the cursor still scrolls its parent in the shell.
  ///
  /// Always leaves the resolver empty, including when the callback throws:
  /// a pending registration that outlived its event would attach itself to the
  /// next notch of the wheel.
  bool resolve(PointerScrollEvent event) {
    final PointerSignalResolvedCallback? callback = _firstRegistered;
    final PointerScrollEvent? pending = _currentEvent;
    _firstRegistered = null;
    _currentEvent = null;
    if (callback == null || pending == null) return false;
    if (!identical(pending, event)) {
      throw StateError(
        'PointerSignalResolver.resolve() was called for an event other than '
        'the one candidates registered for.',
      );
    }
    callback(pending);
    return true;
  }
}
