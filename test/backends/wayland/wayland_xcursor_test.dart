import 'dart:typed_data';

import 'package:dart_ui/src/backends/wayland/wayland_cursor_theme.dart';
import 'package:dart_ui/src/backends/wayland/wayland_xcursor.dart';
import 'package:dart_ui/src/platform/native_window.dart';
import 'package:test/test.dart';

/// One image chunk, as an XCursor file stores it.
final class _Image {
  const _Image({
    required this.nominalSize,
    required this.width,
    required this.height,
    this.hotspotX = 0,
    this.hotspotY = 0,
    this.delay = 0,
    this.argb = const <int>[],
  });

  final int nominalSize;
  final int width;
  final int height;
  final int hotspotX;
  final int hotspotY;
  final int delay;

  /// Non-premultiplied 0xAARRGGBB words, row-major. Defaults to opaque white.
  final List<int> argb;
}

/// Builds a real XCursor file, so the parser is tested against the format
/// rather than against a mock of it.
Uint8List _buildXcursorFile(List<_Image> images, {int magic = xcursorMagic}) {
  const headerSize = 16;
  const chunkHeaderSize = 36;
  final tocBytes = images.length * 12;
  final bodyStart = headerSize + tocBytes;

  final chunks = <Uint8List>[];
  var position = bodyStart;
  final positions = <int>[];
  for (final image in images) {
    positions.add(position);
    final pixelCount = image.width * image.height;
    final chunk = Uint8List(chunkHeaderSize + pixelCount * 4);
    final data = ByteData.sublistView(chunk);
    data.setUint32(0, chunkHeaderSize, Endian.little);
    data.setUint32(4, xcursorImageType, Endian.little);
    data.setUint32(8, image.nominalSize, Endian.little);
    data.setUint32(12, 1, Endian.little); // version
    data.setUint32(16, image.width, Endian.little);
    data.setUint32(20, image.height, Endian.little);
    data.setUint32(24, image.hotspotX, Endian.little);
    data.setUint32(28, image.hotspotY, Endian.little);
    data.setUint32(32, image.delay, Endian.little);
    for (var i = 0; i < pixelCount; i++) {
      final value = i < image.argb.length ? image.argb[i] : 0xFFFFFFFF;
      data.setUint32(chunkHeaderSize + i * 4, value, Endian.little);
    }
    chunks.add(chunk);
    position += chunk.length;
  }

  final file = Uint8List(position);
  final data = ByteData.sublistView(file);
  data.setUint32(0, magic, Endian.little);
  data.setUint32(4, headerSize, Endian.little);
  data.setUint32(8, 1, Endian.little); // version
  data.setUint32(12, images.length, Endian.little);
  for (var i = 0; i < images.length; i++) {
    final entry = headerSize + i * 12;
    data.setUint32(entry, xcursorImageType, Endian.little);
    data.setUint32(entry + 4, images[i].nominalSize, Endian.little);
    data.setUint32(entry + 8, positions[i], Endian.little);
  }
  var offset = bodyStart;
  for (final chunk in chunks) {
    file.setRange(offset, offset + chunk.length, chunk);
    offset += chunk.length;
  }
  return file;
}

void main() {
  group('parseXcursorFile', () {
    test('reads geometry, hotspot and delay from a real file layout', () {
      final bytes = _buildXcursorFile(<_Image>[
        const _Image(
          nominalSize: 24,
          width: 2,
          height: 2,
          hotspotX: 1,
          hotspotY: 1,
          delay: 40,
        ),
      ]);

      final file = parseXcursorFile(bytes);
      expect(file, isNotNull);
      final image = file!.images.single;
      expect(image.nominalSize, 24);
      expect(image.width, 2);
      expect(image.height, 2);
      expect(image.hotspotX, 1);
      expect(image.hotspotY, 1);
      expect(image.delayMilliseconds, 40);
      expect(image.pixels, hasLength(2 * 2 * 4));
      expect(image.bytesPerRow, 8);
    });

    test('ARGB words land as BGRA bytes without a channel shuffle', () {
      // Opaque pure red: 0xFFFF0000 little-endian is 00 00 FF FF in memory,
      // which is B=0, G=0, R=255, A=255 - the framework's own order.
      final bytes = _buildXcursorFile(<_Image>[
        const _Image(
          nominalSize: 24,
          width: 1,
          height: 1,
          argb: <int>[0xFFFF0000],
        ),
      ]);

      final image = parseXcursorFile(bytes)!.images.single;
      expect(image.pixels.sublist(0, 4), <int>[0, 0, 255, 255]);
    });

    test('translucent pixels are premultiplied, as wl_shm requires', () {
      // 50% alpha over pure white: every colour channel halves.
      final bytes = _buildXcursorFile(<_Image>[
        const _Image(
          nominalSize: 24,
          width: 1,
          height: 1,
          argb: <int>[0x80FFFFFF],
        ),
      ]);

      final image = parseXcursorFile(bytes)!.images.single;
      expect(image.pixels[3], 0x80);
      expect(image.pixels[0], 0x80);
      expect(image.pixels[1], 0x80);
      expect(image.pixels[2], 0x80);
    });

    test('fully transparent pixels stay zero in every channel', () {
      final bytes = _buildXcursorFile(<_Image>[
        const _Image(
          nominalSize: 24,
          width: 1,
          height: 1,
          argb: <int>[0x00FFFFFF],
        ),
      ]);

      final image = parseXcursorFile(bytes)!.images.single;
      expect(image.pixels, <int>[0, 0, 0, 0]);
    });

    test('several sizes in one file are all parsed', () {
      final bytes = _buildXcursorFile(<_Image>[
        const _Image(nominalSize: 24, width: 24, height: 24),
        const _Image(nominalSize: 32, width: 32, height: 32),
        const _Image(nominalSize: 48, width: 48, height: 48),
      ]);

      final file = parseXcursorFile(bytes)!;
      expect(file.images, hasLength(3));
      expect(file.nominalSizes, <int>[24, 32, 48]);
    });

    test('a nominal size that differs from the pixel size is preserved', () {
      // Themes routinely store a "24" cursor as 32 real pixels.
      final bytes = _buildXcursorFile(<_Image>[
        const _Image(nominalSize: 24, width: 32, height: 32),
      ]);
      final image = parseXcursorFile(bytes)!.images.single;
      expect(image.nominalSize, 24);
      expect(image.width, 32);
    });

    group('malformed input is rejected, never thrown', () {
      test('a wrong magic is not a cursor file', () {
        final bytes = _buildXcursorFile(
          <_Image>[const _Image(nominalSize: 24, width: 1, height: 1)],
          magic: 0x12345678,
        );
        expect(parseXcursorFile(bytes), isNull);
      });

      test('an empty or truncated file', () {
        expect(parseXcursorFile(Uint8List(0)), isNull);
        expect(parseXcursorFile(Uint8List(8)), isNull);
        final bytes = _buildXcursorFile(
          <_Image>[const _Image(nominalSize: 24, width: 4, height: 4)],
        );
        expect(parseXcursorFile(bytes.sublist(0, bytes.length - 10)), isNull);
      });

      test('a toc that claims more entries than the file holds', () {
        final bytes = _buildXcursorFile(
          <_Image>[const _Image(nominalSize: 24, width: 1, height: 1)],
        );
        ByteData.sublistView(bytes).setUint32(12, 4096, Endian.little);
        expect(parseXcursorFile(bytes), isNull);
      });

      test('an absurd image size is refused before allocating', () {
        final bytes = _buildXcursorFile(
          <_Image>[const _Image(nominalSize: 24, width: 2, height: 2)],
        );
        // Rewrite the chunk's width to something no cursor could be.
        ByteData.sublistView(bytes)
            .setUint32(28 + 16, 0x40000000, Endian.little);
        expect(parseXcursorFile(bytes), isNull);
      });

      test('a hotspot outside the image', () {
        final bytes = _buildXcursorFile(<_Image>[
          const _Image(
            nominalSize: 24,
            width: 2,
            height: 2,
            hotspotX: 99,
          ),
        ]);
        expect(parseXcursorFile(bytes), isNull);
      });
    });
  });

  group('XcursorFile.bestForSize', () {
    late XcursorFile file;

    setUp(() {
      file = parseXcursorFile(_buildXcursorFile(<_Image>[
        const _Image(nominalSize: 24, width: 24, height: 24),
        const _Image(nominalSize: 48, width: 48, height: 48),
      ]))!;
    });

    test('an exact size wins', () {
      expect(file.bestForSize(48)!.nominalSize, 48);
      expect(file.bestForSize(24)!.nominalSize, 24);
    });

    test('the closest size wins, not the next one up', () {
      expect(file.bestForSize(32)!.nominalSize, 24);
      expect(file.bestForSize(40)!.nominalSize, 48);
    });

    test('a request below every size still gets the smallest', () {
      expect(file.bestForSize(8)!.nominalSize, 24);
    });

    test('a tie prefers the larger image, which scales down better', () {
      expect(file.bestForSize(36)!.nominalSize, 48);
    });

    test('an animation returns its first frame, not a mid-blink one', () {
      final animated = parseXcursorFile(_buildXcursorFile(<_Image>[
        const _Image(nominalSize: 24, width: 1, height: 1, delay: 30),
        const _Image(nominalSize: 24, width: 1, height: 1, delay: 60),
      ]))!;
      expect(animated.bestForSize(24)!.delayMilliseconds, 30);
      expect(animated.framesForSize(24), hasLength(2));
    });
  });

  group('resolveWaylandCursorTheme', () {
    test('reads the theme and size the user configured', () {
      final resolution = resolveWaylandCursorTheme(<String, String>{
        'XCURSOR_THEME': 'Breeze',
        'XCURSOR_SIZE': '32',
        'HOME': '/home/ana',
      });
      expect(resolution.themeName, 'Breeze');
      expect(resolution.size, 32);
    });

    test('falls back to the freedesktop defaults', () {
      final resolution = resolveWaylandCursorTheme(const <String, String>{});
      expect(resolution.themeName, 'default');
      expect(resolution.size, 24);
      expect(resolution.searchPaths, contains('/usr/share/icons'));
    });

    test('a nonsense size is replaced rather than propagated', () {
      final resolution = resolveWaylandCursorTheme(<String, String>{
        'XCURSOR_SIZE': 'huge',
      });
      expect(resolution.size, 24);
      expect(
        resolveWaylandCursorTheme(<String, String>{'XCURSOR_SIZE': '0'}).size,
        24,
      );
    });

    test('the home directories precede the system ones', () {
      final resolution = resolveWaylandCursorTheme(<String, String>{
        'HOME': '/home/ana',
      });
      expect(
        resolution.searchPaths.indexOf('/home/ana/.icons'),
        lessThan(resolution.searchPaths.indexOf('/usr/share/icons')),
      );
    });

    test('XDG_DATA_HOME replaces the ~/.local default', () {
      final resolution = resolveWaylandCursorTheme(<String, String>{
        'HOME': '/home/ana',
        'XDG_DATA_HOME': '/custom/data',
      });
      expect(resolution.searchPaths, contains('/custom/data/icons'));
      expect(
        resolution.searchPaths,
        isNot(contains('/home/ana/.local/share/icons')),
      );
    });

    test('XCURSOR_PATH overrides the whole search order', () {
      final resolution = resolveWaylandCursorTheme(<String, String>{
        'HOME': '/home/ana',
        'XCURSOR_PATH': '/opt/cursors:/other/cursors',
      });
      expect(
        resolution.searchPaths,
        <String>['/opt/cursors', '/other/cursors'],
      );
    });
  });

  group('findWaylandCursorFile', () {
    late _FakeFileSystem fs;

    setUp(() => fs = _FakeFileSystem());

    test('finds the standard name in the configured theme', () {
      fs.files.add('/usr/share/icons/Breeze/cursors/text');
      final path = findWaylandCursorFile(
        fileSystem: fs,
        resolution: resolveWaylandCursorTheme(<String, String>{
          'XCURSOR_THEME': 'Breeze',
        }),
        cursor: SystemCursor.text,
      );
      expect(path, '/usr/share/icons/Breeze/cursors/text');
    });

    test('falls back through the legacy X11 names', () {
      // An old theme has `xterm` and no `text`.
      fs.files.add('/usr/share/icons/Breeze/cursors/xterm');
      final path = findWaylandCursorFile(
        fileSystem: fs,
        resolution: resolveWaylandCursorTheme(<String, String>{
          'XCURSOR_THEME': 'Breeze',
        }),
        cursor: SystemCursor.text,
      );
      expect(path, '/usr/share/icons/Breeze/cursors/xterm');
    });

    test('a theme earlier on the path wins over a system one', () {
      fs.files.add('/home/ana/.icons/Breeze/cursors/default');
      fs.files.add('/usr/share/icons/Breeze/cursors/default');
      final path = findWaylandCursorFile(
        fileSystem: fs,
        resolution: resolveWaylandCursorTheme(<String, String>{
          'XCURSOR_THEME': 'Breeze',
          'HOME': '/home/ana',
        }),
        cursor: SystemCursor.arrow,
      );
      expect(path, '/home/ana/.icons/Breeze/cursors/default');
    });

    test('a missing theme falls back to the ones every distro ships', () {
      fs.files.add('/usr/share/icons/Adwaita/cursors/default');
      final path = findWaylandCursorFile(
        fileSystem: fs,
        resolution: resolveWaylandCursorTheme(<String, String>{
          'XCURSOR_THEME': 'NoSuchTheme',
        }),
        cursor: SystemCursor.arrow,
      );
      expect(path, '/usr/share/icons/Adwaita/cursors/default');
    });

    test('a cursor no theme provides is null, not a wrong cursor', () {
      fs.files.add('/usr/share/icons/Breeze/cursors/default');
      final path = findWaylandCursorFile(
        fileSystem: fs,
        resolution: resolveWaylandCursorTheme(<String, String>{
          'XCURSOR_THEME': 'Breeze',
        }),
        cursor: SystemCursor.notAllowed,
      );
      expect(path, isNull);
    });

    test('every SystemCursor has at least one candidate name', () {
      for (final cursor in SystemCursor.values) {
        expect(waylandCursorNames[cursor], isNotEmpty,
            reason: '$cursor has no theme name to look for');
      }
    });
  });
}

final class _FakeFileSystem implements CursorFileSystem {
  final Set<String> files = <String>{};

  @override
  bool fileExists(String path) => files.contains(path);

  @override
  List<int>? readFile(String path) => files.contains(path) ? <int>[] : null;
}
