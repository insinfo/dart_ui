/// Thumbnails of pictures, cached: asked for while a view builds, loaded in
/// the background, and the view rebuilt when each one is ready.
library;

import 'dart:async';
import 'dart:collection';

import 'package:dart_ui/dart_ui.dart';

import '../engine/file_system.dart';
import '../engine/file_types.dart';

/// Loads one thumbnail, or answers null for a file it cannot show.
typedef ThumbnailLoader = Future<DecodedImage?> Function(String path);

/// The cache: least recently used out, a couple of loads at a time.
final class ThumbnailCache {
  ThumbnailCache({
    required this.loader,
    required this.onLoaded,
    this.maxBytes = 96 << 20,
    this.concurrency = 2,
  });

  final ThumbnailLoader loader;

  /// A thumbnail arrived: the view should build again.
  final void Function() onLoaded;

  final int maxBytes;
  final int concurrency;

  final LinkedHashMap<String, DecodedImage?> _ready =
      LinkedHashMap<String, DecodedImage?>();
  final Set<String> _loading = <String>{};
  final List<String> _queue = <String>[];
  int _bytes = 0;
  bool _disposed = false;

  /// The cache key: the path and when it last changed, so an edited picture
  /// is decoded again.
  static String _key(FileEntry entry) =>
      '${entry.path}|${entry.modified?.millisecondsSinceEpoch}';

  /// [entry]'s thumbnail if it is ready; otherwise null, and it is queued.
  DecodedImage? of(FileEntry entry) {
    if (kindOf(entry) != FileKind.image ||
        entry.extension == 'svg' ||
        entry.extension == 'cdr') {
      return null;
    }
    final String key = _key(entry);
    if (_ready.containsKey(key)) {
      final DecodedImage? image = _ready.remove(key);
      _ready[key] = image;
      return image;
    }
    if (!_loading.contains(key) && !_queue.contains(key)) {
      _queue.add(key);
      _pump();
    }
    return null;
  }

  void _pump() {
    while (!_disposed && _loading.length < concurrency && _queue.isNotEmpty) {
      // The latest request first: what the user scrolled to is what matters.
      final String key = _queue.removeLast();
      _loading.add(key);
      final String path = key.substring(0, key.lastIndexOf('|'));
      unawaited(loader(path).then((DecodedImage? image) {
        if (_disposed) return;
        _loading.remove(key);
        _store(key, image);
        onLoaded();
        _pump();
      }, onError: (Object _) {
        _loading.remove(key);
        _store(key, null);
        _pump();
      }));
    }
  }

  void _store(String key, DecodedImage? image) {
    _ready[key] = image;
    _bytes += image?.pixels.length ?? 0;
    while (_bytes > maxBytes && _ready.isNotEmpty) {
      final String oldest = _ready.keys.first;
      _bytes -= _ready.remove(oldest)?.pixels.length ?? 0;
    }
  }

  void dispose() {
    _disposed = true;
    _queue.clear();
  }
}
