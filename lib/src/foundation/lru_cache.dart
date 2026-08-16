/// Small reusable least-recently-used caches.
///
/// Keeping this primitive in `foundation` prevents each image, font, SVG, and
/// input subsystem from growing its own `lastOrNull`, map reordering, and
/// pending-future bookkeeping.
library;

import 'dart:collection';

final class LruCache<K, V> {
  LruCache({int maximumSize = 100}) : _maximumSize = maximumSize {
    if (maximumSize < 0) {
      throw ArgumentError.value(maximumSize, 'maximumSize', 'must be >= 0');
    }
  }

  final LinkedHashMap<K, V> _values = LinkedHashMap<K, V>();
  int _maximumSize;

  int get maximumSize => _maximumSize;

  set maximumSize(int value) {
    if (value < 0) {
      throw ArgumentError.value(value, 'maximumSize', 'must be >= 0');
    }
    if (value == _maximumSize) return;
    _maximumSize = value;
    _trim();
  }

  int get count => _values.length;
  bool get isEmpty => _values.isEmpty;

  /// Returns a value and promotes it to most recently used.
  V? operator [](K key) {
    final bool present = _values.containsKey(key);
    final V? value = _values.remove(key);
    if (present) _values[key] = value as V;
    return value;
  }

  V putIfAbsent(K key, V Function() loader) {
    if (_values.containsKey(key)) return this[key] as V;
    final V value = loader();
    put(key, value);
    return value;
  }

  void put(K key, V value) {
    if (_maximumSize == 0) return;
    _values.remove(key);
    _values[key] = value;
    _trim();
  }

  bool containsKey(K key) => _values.containsKey(key);

  bool evict(K key) => _values.remove(key) != null;

  void clear() => _values.clear();

  void _trim() {
    while (_values.length > _maximumSize) {
      _values.remove(_values.keys.first);
    }
  }
}

/// An LRU cache that also coalesces concurrent loads of the same key.
final class AsyncLruCache<K, V> {
  AsyncLruCache({int maximumSize = 100})
      : _completed = LruCache<K, V>(maximumSize: maximumSize);

  final LruCache<K, V> _completed;
  final Map<K, Future<V>> _pending = <K, Future<V>>{};
  int _generation = 0;

  int get maximumSize => _completed.maximumSize;
  set maximumSize(int value) => _completed.maximumSize = value;
  int get count => _completed.count;
  int get pendingCount => _pending.length;

  Future<V> putIfAbsent(K key, Future<V> Function() loader) {
    if (_completed.containsKey(key)) {
      return Future<V>.value(_completed[key] as V);
    }
    final Future<V>? pending = _pending[key];
    if (pending != null) return pending;

    final int loadGeneration = _generation;
    late final Future<V> created;
    try {
      created = Future<V>.sync(loader).then((V value) {
        if (identical(_pending[key], created)) {
          _pending.remove(key);
          if (loadGeneration == _generation) _completed.put(key, value);
        }
        return value;
      }, onError: (Object error, StackTrace stackTrace) {
        if (identical(_pending[key], created)) _pending.remove(key);
        Error.throwWithStackTrace(error, stackTrace);
      });
    } catch (error, stackTrace) {
      return Future<V>.error(error, stackTrace);
    }
    _pending[key] = created;
    return created;
  }

  bool evict(K key) {
    final bool wasPending = _pending.remove(key) != null;
    return _completed.evict(key) || wasPending;
  }

  /// Prevents already-running loads from repopulating the cleared cache.
  /// Their futures still complete for existing callers; Dart futures cannot
  /// be cancelled safely, but their values are no longer retained.
  void clear() {
    _generation++;
    _pending.clear();
    _completed.clear();
  }
}
