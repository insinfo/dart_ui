import 'dart:async';
import 'dart:typed_data';

import 'package:dart_ui/dart_ui.dart';
import 'package:file_explorer/src/engine/file_system.dart';
import 'package:file_explorer/src/ui/thumbnails.dart';
import 'package:test/test.dart';

FileEntry picture(String name) =>
    FileEntry(path: '/p/$name', name: name, isDirectory: false, size: 1);

DecodedImage pixels(int side) => DecodedImage(
      width: side,
      height: side,
      order: ImageChannelOrder.bgra,
      pixels: Uint8List(side * side * 4),
      hasAlpha: false,
    );

void main() {
  test('asked, loaded in the background, then served from the cache', () async {
    final List<String> loads = <String>[];
    var redraws = 0;
    final ThumbnailCache cache = ThumbnailCache(
      loader: (String path) async {
        loads.add(path);
        return pixels(4);
      },
      onLoaded: () => redraws++,
    );
    expect(cache.of(picture('a.png')), isNull);
    expect(cache.of(picture('a.png')), isNull, reason: 'queued once');
    await Future<void>.delayed(Duration.zero);
    expect(redraws, 1);
    expect(cache.of(picture('a.png')), isNotNull);
    expect(loads, <String>['/p/a.png']);
    expect(cache.of(picture('notes.txt')), isNull);
    expect(loads, hasLength(1), reason: 'only pictures are decoded');
  });

  test('past its budget the least recently used goes first', () async {
    final ThumbnailCache cache = ThumbnailCache(
      loader: (String path) async => pixels(4), // 64 bytes each
      onLoaded: () {},
      maxBytes: 150,
      concurrency: 3,
    );
    for (final String n in <String>['a.png', 'b.png', 'c.png']) {
      cache.of(picture(n));
    }
    await Future<void>.delayed(Duration.zero);
    expect(cache.of(picture('a.png')), isNull, reason: 'evicted');
    expect(cache.of(picture('c.png')), isNotNull);
  });
}
