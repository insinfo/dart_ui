/// The objects a recognizer needs but cannot be handed by an event.
///
/// A `PointerEventTarget` is called with one argument - the event - and that
/// signature belongs to `pointer_router.dart`, which several controls in this
/// repository already implement. A recognizer nevertheless needs two things
/// the event cannot carry: the arena its window arbitrates in, and the
/// dispatcher its deadlines are armed on.
///
/// Passing them at construction is the honest route and is always available -
/// `GestureRecognizer` and `GestureDetector` both take them. This file
/// provides the fallback for the ordinary case where a widget deep in a tree
/// should not have to be told which window it is in: while an event is being
/// dispatched, the router publishes its binding here, and a recognizer that
/// was not given one explicitly picks it up at the moment it joins an arena.
///
/// This is ambient, not global. It is set and cleared around a single
/// synchronous dispatch by the router that owns it, on the one thread that
/// owns the window, so two windows never observe each other's binding.
/// [instance] exists only as the last resort for a recognizer used with no
/// router at all - a unit test, or a control driving recognizers by hand.
library;

import '../scheduler/ui_dispatcher.dart';
import 'arena.dart';
import 'pointer_signal_resolver.dart';

/// The arena, signal resolver and dispatcher in force for one render tree.
final class GestureBinding {
  GestureBinding({
    GestureArenaManager? arena,
    PointerSignalResolver? signalResolver,
    this.dispatcher,
  })  : arena = arena ?? GestureArenaManager(),
        signalResolver = signalResolver ?? PointerSignalResolver();

  static GestureBinding? _current;
  static GestureBinding? _instance;

  /// The binding of the dispatch in progress, or null outside one.
  static GestureBinding? get current => _current;

  /// The fallback binding for recognizers used outside any router.
  ///
  /// Created on first use and never replaced, so a test that leans on it is
  /// still deterministic; it holds no per-gesture state between gestures
  /// because arenas are removed as they resolve.
  static GestureBinding get instance => _instance ??= GestureBinding();

  /// The binding a recognizer should use when it was not given one.
  static GestureBinding get ambient => _current ?? instance;

  /// Where gestures for this tree are arbitrated.
  final GestureArenaManager arena;

  /// Which node consumes a wheel notch in this tree.
  final PointerSignalResolver signalResolver;

  /// Where a long press arms its deadline. Null when the owner has none, in
  /// which case a recognizer that needs a timer must be given one directly.
  final UiDispatcher? dispatcher;

  /// Publishes this binding for the duration of [body].
  ///
  /// Restores the previous value rather than clearing it, so a nested dispatch
  /// - a control that routes a synthesized event from inside a handler - does
  /// not leave the outer dispatch without a binding.
  T dispatching<T>(T Function() body) {
    final GestureBinding? previous = _current;
    _current = this;
    try {
      return body();
    } finally {
      _current = previous;
    }
  }
}
