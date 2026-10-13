/// Something that says "I changed" to whoever listens, with no value
/// attached: Flutter's `Listenable` and `ChangeNotifier`, so models written
/// against them carry over unchanged.
///
/// `ValueNotifier` is a [ChangeNotifier] that also holds a value, as in
/// Flutter, and anything that rebuilds on a change takes a [Listenable],
/// which an `Animation`, a [ChangeNotifier] and a `ValueNotifier` all are.
library;

import 'package:meta/meta.dart';

/// An object that notifies listeners when it changes.
abstract interface class Listenable {
  /// Calls [listener] after every change.
  void addListener(void Function() listener);

  /// Stops calling [listener]. Removing one that was never added does
  /// nothing.
  void removeListener(void Function() listener);

  /// One [Listenable] that notifies when any of [listenables] does - a
  /// builder that depends on two models listens to their merge.
  factory Listenable.merge(Iterable<Listenable?> listenables) =
      _MergedListenable;
}

/// A [Listenable] with the bookkeeping written: [notifyListeners] calls
/// every listener, in the order they were added, over a copy - so one that
/// removes itself does not make its neighbour miss the call.
///
/// A mixin class, as in Flutter, so a model can `extend` it or mix it in.
mixin class ChangeNotifier implements Listenable {
  List<void Function()>? _listeners = <void Function()>[];
  bool _notifying = false;

  /// Whether anything is listening. For a model that does work only while
  /// it is watched.
  @protected
  bool get hasListeners => _listeners?.isNotEmpty ?? false;

  @override
  void addListener(void Function() listener) {
    _assertAlive('addListener');
    _listeners!.add(listener);
  }

  @override
  void removeListener(void Function() listener) => _listeners?.remove(listener);

  /// Calls every listener.
  ///
  /// A listener that throws does not stop the rest: one broken observer
  /// must not leave the others showing stale state. The first error is
  /// rethrown once all have run.
  @protected
  void notifyListeners() {
    _assertAlive('notifyListeners');
    final List<void Function()> listeners = _listeners!;
    if (listeners.isEmpty) return;
    _notifying = true;
    Object? firstError;
    StackTrace? firstStack;
    try {
      for (final void Function() listener
          in List<void Function()>.of(listeners)) {
        try {
          listener();
        } catch (error, stack) {
          firstError ??= error;
          firstStack ??= stack;
        }
      }
    } finally {
      _notifying = false;
    }
    if (firstError != null) {
      Error.throwWithStackTrace(firstError, firstStack!);
    }
  }

  /// Drops every listener; using the notifier afterwards is an error.
  @mustCallSuper
  void dispose() {
    assert(!_notifying, 'dispose() called while notifying listeners');
    _listeners = null;
  }

  void _assertAlive(String method) {
    if (_listeners == null) {
      throw StateError('$runtimeType.$method after dispose()');
    }
  }
}

final class _MergedListenable implements Listenable {
  _MergedListenable(Iterable<Listenable?> listenables)
      : _children = listenables.whereType<Listenable>().toList();

  final List<Listenable> _children;

  @override
  void addListener(void Function() listener) {
    for (final Listenable child in _children) {
      child.addListener(listener);
    }
  }

  @override
  void removeListener(void Function() listener) {
    for (final Listenable child in _children) {
      child.removeListener(listener);
    }
  }

  @override
  String toString() => 'Listenable.merge($_children)';
}
