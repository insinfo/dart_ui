import 'dart:async';

import 'package:dart_ui/src/foundation/lru_cache.dart';
import 'package:test/test.dart';

void main() {
  test('reads promote entries and eviction removes the least recent', () {
    final LruCache<String, int> cache = LruCache<String, int>(maximumSize: 2)
      ..put('a', 1)
      ..put('b', 2);

    expect(cache['a'], 1);
    cache.put('c', 3);
    expect(cache['b'], isNull);
    expect(cache['a'], 1);
    expect(cache['c'], 3);
  });

  test('shrinking a cache trims it immediately', () {
    final LruCache<String, int> cache = LruCache<String, int>(maximumSize: 3)
      ..put('a', 1)
      ..put('b', 2)
      ..put('c', 3);
    cache.maximumSize = 1;
    expect(cache.count, 1);
    expect(cache['c'], 3);
  });

  test('nullable entries are cached and promoted like any other value', () {
    final LruCache<String, int?> cache = LruCache<String, int?>(maximumSize: 2)
      ..put('empty', null)
      ..put('one', 1);
    expect(cache.putIfAbsent('empty', () => 99), isNull);
    cache.put('two', 2);
    expect(cache['one'], isNull);
    expect(cache.containsKey('empty'), isTrue);
  });

  test('async cache coalesces work and removes a failed pending load',
      () async {
    final AsyncLruCache<String, int> cache = AsyncLruCache<String, int>();
    final Completer<int> completer = Completer<int>();
    var calls = 0;
    Future<int> load() {
      calls++;
      return completer.future;
    }

    final Future<int> first = cache.putIfAbsent('a', load);
    final Future<int> second = cache.putIfAbsent('a', load);
    expect(identical(first, second), isTrue);
    expect(calls, 1);
    completer.completeError(StateError('failed'));
    await expectLater(first, throwsStateError);
    await expectLater(second, throwsStateError);
    expect(cache.pendingCount, 0);

    expect(await cache.putIfAbsent('a', () async => 7), 7);
    expect(cache.count, 1);
  });

  test('clear prevents an old pending load from repopulating the cache',
      () async {
    final AsyncLruCache<String, int> cache = AsyncLruCache<String, int>();
    final Completer<int> old = Completer<int>();
    final Future<int> oldResult = cache.putIfAbsent('a', () => old.future);
    cache.clear();

    expect(await cache.putIfAbsent('a', () async => 2), 2);
    old.complete(1);
    expect(await oldResult, 1);
    expect(cache.count, 1);
    expect(await cache.putIfAbsent('a', () async => 3), 2);
  });
}
