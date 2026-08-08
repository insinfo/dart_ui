/// Ownership and teardown rules the whole framework follows.
///
/// These are not abstract preferences. Every rule here was paid for by a bug
/// in this repository's macOS spike:
///
///   * Idempotent disposal, because a second teardown of an already-stopped
///     backend used to throw instead of being a no-op.
///   * Reverse-order disposal, because releasing a Mach port before removing
///     its run-loop source left the source pointing at freed memory.
///   * Generation tokens, because native code holds callbacks that keep
///     firing after shutdown, and "is it still valid?" cannot be answered by
///     a null check.
library;

/// Something holding a resource that must be released explicitly.
///
/// [dispose] must be safe to call more than once. Callers routinely dispose
/// on both the success and the failure path, and making them track which one
/// already ran is how leaks and double-frees get written.
abstract interface class Disposable {
  bool get isDisposed;
  void dispose();
}

/// Mixin supplying the idempotence half of the contract, so implementations
/// only write the release itself.
mixin DisposableMixin implements Disposable {
  bool _disposed = false;

  @override
  bool get isDisposed => _disposed;

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    onDispose();
  }

  /// Runs exactly once, on the first [dispose].
  void onDispose();

  /// Guard for operations that are meaningless after teardown.
  void throwIfDisposed() {
    if (_disposed) {
      throw StateError('$runtimeType was used after dispose()');
    }
  }
}

/// A stack of resources released in reverse acquisition order.
///
/// The order is the point. Native handles form a dependency chain - a run-loop
/// source depends on a Mach port, a drawing context depends on a window - and
/// releasing the dependency first is how a teardown turns into a crash.
final class DisposableBag with DisposableMixin {
  final List<void Function()> _releases = <void Function()>[];

  /// Registers [release] to run during [dispose]. Returns [resource] so an
  /// acquisition can be registered in the same expression that performs it.
  T add<T>(T resource, void Function() release) {
    throwIfDisposed();
    _releases.add(release);
    return resource;
  }

  void addDisposable(Disposable disposable) {
    add(disposable, disposable.dispose);
  }

  int get length => _releases.length;

  /// Releases everything, last acquired first.
  ///
  /// A release that throws does not stop the rest: a half-torn-down process
  /// leaks more than a noisy one. The first error is rethrown once everything
  /// has been attempted, so the failure is still visible.
  @override
  void onDispose() {
    Object? firstError;
    StackTrace? firstStack;
    for (var i = _releases.length - 1; i >= 0; i--) {
      try {
        _releases[i]();
      } on Object catch (error, stack) {
        firstError ??= error;
        firstStack ??= stack;
      }
    }
    _releases.clear();
    if (firstError != null) {
      Error.throwWithStackTrace(firstError, firstStack!);
    }
  }
}

/// Monotonic token used to reject work that belongs to a previous lifetime.
///
/// Native code keeps calling the callbacks it was given - after shutdown,
/// after a device was lost, after a window closed. Freeing the callback and
/// hoping is a use-after-free; ignoring by null check cannot distinguish "not
/// ready yet" from "already gone". A generation compares two integers and is
/// correct in both directions.
final class GenerationToken {
  GenerationToken();

  int _generation = 0;

  /// The generation callbacks must carry to be accepted.
  int get current => _generation;

  /// Invalidates every outstanding callback. Returns the new generation.
  int invalidate() => ++_generation;

  /// Whether work stamped with [generation] still belongs to this lifetime.
  bool accepts(int generation) => generation == _generation;
}
