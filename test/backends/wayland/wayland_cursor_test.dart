import 'dart:typed_data';

import 'package:dart_ui/src/backends/wayland/wayland_cursor.dart';
import 'package:dart_ui/src/backends/wayland/wayland_cursor_theme.dart';
import 'package:dart_ui/src/backends/wayland/wayland_shm.dart';
import 'package:dart_ui/src/backends/wayland/wayland_xcursor.dart';
import 'package:dart_ui/src/foundation/diagnostics.dart';
import 'package:dart_ui/src/platform/native_window.dart';
import 'package:dart_ui/src/rendering/framebuffer.dart';
import 'package:test/test.dart';

/// Builds a one-colour XCursor file with [frames] frames at [nominalSize].
Uint8List _cursorFile({
  int nominalSize = 24,
  int width = 24,
  int height = 24,
  int hotspotX = 4,
  int hotspotY = 6,
  List<int> delays = const <int>[0],
}) {
  const headerSize = 16;
  const chunkHeaderSize = 36;
  final pixelCount = width * height;
  final tocBytes = delays.length * 12;
  final bodyStart = headerSize + tocBytes;
  final chunkSize = chunkHeaderSize + pixelCount * 4;
  final file = Uint8List(bodyStart + chunkSize * delays.length);
  final data = ByteData.sublistView(file);

  data.setUint32(0, xcursorMagic, Endian.little);
  data.setUint32(4, headerSize, Endian.little);
  data.setUint32(8, 1, Endian.little);
  data.setUint32(12, delays.length, Endian.little);

  for (var i = 0; i < delays.length; i++) {
    final position = bodyStart + chunkSize * i;
    final entry = headerSize + i * 12;
    data.setUint32(entry, xcursorImageType, Endian.little);
    data.setUint32(entry + 4, nominalSize, Endian.little);
    data.setUint32(entry + 8, position, Endian.little);

    data.setUint32(position, chunkHeaderSize, Endian.little);
    data.setUint32(position + 4, xcursorImageType, Endian.little);
    data.setUint32(position + 8, nominalSize, Endian.little);
    data.setUint32(position + 12, 1, Endian.little);
    data.setUint32(position + 16, width, Endian.little);
    data.setUint32(position + 20, height, Endian.little);
    data.setUint32(position + 24, hotspotX, Endian.little);
    data.setUint32(position + 28, hotspotY, Endian.little);
    data.setUint32(position + 32, delays[i], Endian.little);
    for (var p = 0; p < pixelCount; p++) {
      data.setUint32(
        position + chunkHeaderSize + p * 4,
        0xFFFFFFFF,
        Endian.little,
      );
    }
  }
  return file;
}

void main() {
  late _FakeCursorClient client;
  late _FakeCursorFileSystem fs;
  late _ManualClock clock;

  setUp(() {
    client = _FakeCursorClient();
    fs = _FakeCursorFileSystem();
    clock = _ManualClock();
  });

  WaylandCursorManager manager({int size = 24, String theme = 'Breeze'}) =>
      WaylandCursorManager(
        client: client,
        fileSystem: fs,
        resolution: resolveWaylandCursorTheme(<String, String>{
          'XCURSOR_THEME': theme,
          'XCURSOR_SIZE': '$size',
        }),
        timer: clock.schedule,
      );

  void installCursor(
    String name, {
    int nominalSize = 24,
    int width = 24,
    int height = 24,
    int hotspotX = 4,
    int hotspotY = 6,
    List<int> delays = const <int>[0],
    String theme = 'Breeze',
  }) {
    fs.files['/usr/share/icons/$theme/cursors/$name'] = _cursorFile(
      nominalSize: nominalSize,
      width: width,
      height: height,
      hotspotX: hotspotX,
      hotspotY: hotspotY,
      delays: delays,
    );
  }

  group('applying a cursor', () {
    test('uploads the image and sets it with the right hotspot', () {
      installCursor('text', hotspotX: 7, hotspotY: 9);
      final cursors = manager();

      expect(cursors.apply(SystemCursor.text), isTrue);

      expect(client.createdSurfaces, hasLength(1));
      expect(client.createdBuffers, hasLength(1));
      final commit = client.commits.single;
      expect(commit.surfaceId, client.createdSurfaces.single);
      expect(commit.damage,
          const WaylandCpuDamage(x: 0, y: 0, width: 24, height: 24));
      final set = client.cursorSets.single;
      expect(set.surfaceId, client.createdSurfaces.single);
      expect(set.hotspotX, 7);
      expect(set.hotspotY, 9);
      expect(cursors.currentCursor, SystemCursor.text);
    });

    test('the buffer holds the cursor pixels, premultiplied', () {
      installCursor('default', width: 2, height: 2, hotspotX: 0, hotspotY: 0);
      manager().apply(SystemCursor.arrow);

      final buffer = client.createdBuffers.single;
      expect(buffer.framebuffer.width, 2);
      // Opaque white throughout.
      expect(buffer.framebuffer.pixels.take(4), <int>[255, 255, 255, 255]);
    });

    test('the commit happens before set_cursor', () {
      installCursor('default');
      manager().apply(SystemCursor.arrow);

      expect(client.order.take(2), <String>['commit', 'set_cursor'],
          reason: 'set_cursor on a surface with no buffer shows nothing');
    });

    test('re-applying the same cursor does not re-upload', () {
      installCursor('default');
      final cursors = manager();
      cursors.apply(SystemCursor.arrow);
      cursors.apply(SystemCursor.arrow);

      expect(client.createdBuffers, hasLength(1));
      expect(client.cursorSets, hasLength(1));
    });

    test('switching cursors uploads once each and reuses the surface', () {
      installCursor('default');
      installCursor('text');
      final cursors = manager();

      cursors.apply(SystemCursor.arrow);
      cursors.apply(SystemCursor.text);
      cursors.apply(SystemCursor.arrow);

      expect(client.createdSurfaces, hasLength(1),
          reason: 'one cursor surface serves every cursor');
      expect(client.createdBuffers, hasLength(2),
          reason: 'the arrow was cached across the round trip');
      expect(client.cursorSets, hasLength(3));
    });

    test('a cursor missing from the theme falls back to the arrow', () {
      installCursor('default');
      final cursors = manager();

      expect(cursors.apply(SystemCursor.notAllowed), isTrue);

      expect(client.cursorSets, hasLength(1));
      expect(
        cursors.diagnostics.map((BackendDiagnostic d) => d.message),
        anyElement(contains('using the arrow cursor')),
      );
    });

    test('no theme at all leaves the compositor default, with a reason', () {
      final cursors = manager();

      expect(cursors.apply(SystemCursor.text), isFalse);

      expect(client.cursorSets, isEmpty);
      expect(client.createdSurfaces, isEmpty,
          reason: 'no surface is created for a cursor that cannot load');
      expect(cursors.diagnostics, isNotEmpty);
    });

    test('a corrupt cursor file is refused rather than uploaded', () {
      fs.files['/usr/share/icons/Breeze/cursors/default'] =
          Uint8List.fromList(<int>[1, 2, 3, 4, 5, 6, 7, 8]);
      final cursors = manager();

      expect(cursors.apply(SystemCursor.arrow), isFalse);
      expect(
        cursors.diagnostics.map((BackendDiagnostic d) => d.message),
        anyElement(contains('not a readable XCursor')),
      );
    });

    test('without wl_shm no cursor is attempted', () {
      installCursor('default');
      client.shmSupported = false;
      final cursors = manager();

      expect(cursors.apply(SystemCursor.arrow), isFalse);
      expect(
        cursors.diagnostics.map((BackendDiagnostic d) => d.message),
        anyElement(contains('cursors need wl_shm')),
      );
    });
  });

  group('hiding', () {
    test('hide sets a null surface, which is how Wayland spells it', () {
      installCursor('default');
      final cursors = manager();
      cursors.apply(SystemCursor.arrow);

      cursors.hide();

      expect(client.cursorSets.last.surfaceId, 0);
      expect(cursors.isHidden, isTrue);
      expect(cursors.currentCursor, isNull);
    });

    test('hiding twice costs one request', () {
      installCursor('default');
      final cursors = manager()..apply(SystemCursor.arrow);
      cursors.hide();
      final count = client.cursorSets.length;
      cursors.hide();
      expect(client.cursorSets, hasLength(count));
    });

    test('applying after hiding shows the cursor again', () {
      installCursor('default');
      final cursors = manager()..apply(SystemCursor.arrow);
      cursors.hide();

      expect(cursors.apply(SystemCursor.arrow), isTrue);
      expect(client.cursorSets.last.surfaceId, isNot(0));
      expect(cursors.isHidden, isFalse);
    });

    test('a pointer enter while hidden re-asserts the hidden state', () {
      installCursor('default');
      final cursors = manager()..apply(SystemCursor.arrow);
      cursors.hide();
      client.cursorSets.clear();

      cursors.reapplyOnPointerEnter();

      expect(client.cursorSets.single.surfaceId, 0);
    });
  });

  group('pointer enter', () {
    test('re-asserts the cursor, because it is per-enter state', () {
      installCursor('default');
      final cursors = manager()..apply(SystemCursor.arrow);
      client.cursorSets.clear();
      client.commits.clear();

      cursors.reapplyOnPointerEnter();

      expect(client.cursorSets, hasLength(1));
      expect(client.createdBuffers, hasLength(1),
          reason: 'the cached buffer is reused, not re-uploaded');
    });

    test('does nothing when no cursor has ever been applied', () {
      manager().reapplyOnPointerEnter();
      expect(client.cursorSets, isEmpty);
    });
  });

  group('animation', () {
    test('a multi-frame cursor advances on the injected clock', () {
      installCursor('wait', delays: <int>[30, 30, 30]);
      final cursors = manager();

      cursors.apply(SystemCursor.wait);

      expect(cursors.isAnimating, isTrue);
      expect(cursors.frameIndex, 0);
      expect(client.commits, hasLength(1));

      clock.advance(const Duration(milliseconds: 30));
      expect(cursors.frameIndex, 1);
      expect(client.commits, hasLength(2));

      clock.advance(const Duration(milliseconds: 30));
      expect(cursors.frameIndex, 2);

      clock.advance(const Duration(milliseconds: 30));
      expect(cursors.frameIndex, 0, reason: 'the animation loops');
      expect(client.commits, hasLength(4));
    });

    test('every frame is uploaded once, up front', () {
      installCursor('wait', delays: <int>[30, 30, 30]);
      manager().apply(SystemCursor.wait);

      expect(client.createdBuffers, hasLength(3));
    });

    test('each frame commits its own buffer', () {
      installCursor('wait', delays: <int>[30, 30]);
      manager().apply(SystemCursor.wait);
      clock.advance(const Duration(milliseconds: 30));

      expect(
        client.commits.map((_Commit c) => c.buffer).toSet(),
        hasLength(2),
      );
    });

    test('a static cursor arms no timer', () {
      installCursor('default');
      final cursors = manager();
      cursors.apply(SystemCursor.arrow);

      expect(cursors.isAnimating, isFalse);
      expect(clock.pending, isZero);
    });

    test('switching away from an animation stops its timer', () {
      installCursor('wait', delays: <int>[30, 30]);
      installCursor('default');
      final cursors = manager()..apply(SystemCursor.wait);
      expect(clock.pending, 1);

      cursors.apply(SystemCursor.arrow);

      expect(clock.pending, isZero);
      expect(cursors.isAnimating, isFalse);
      final commits = client.commits.length;
      clock.advance(const Duration(milliseconds: 100));
      expect(client.commits, hasLength(commits),
          reason: 'a cancelled animation must not keep committing');
    });

    test('hiding stops the animation', () {
      installCursor('wait', delays: <int>[30, 30]);
      final cursors = manager()..apply(SystemCursor.wait);

      cursors.hide();

      expect(clock.pending, isZero);
      expect(cursors.isAnimating, isFalse);
    });

    test('a zero delay is floored instead of spinning the timer', () {
      installCursor('wait', delays: <int>[0, 0]);
      manager().apply(SystemCursor.wait);

      expect(clock.nextDelay, const Duration(milliseconds: 100));
    });
  });

  group('scale changes', () {
    test('a new scale reloads the theme at the larger size', () {
      installCursor('default', nominalSize: 24, width: 24, height: 24);
      installCursor('default', theme: 'Breeze');
      final cursors = manager(size: 24);
      cursors.apply(SystemCursor.arrow);
      expect(client.commits.single.bufferScale, 1);

      cursors.setBufferScale(2);

      expect(cursors.bufferScale, 2);
      expect(client.destroyedBuffers, isNotEmpty,
          reason: 'buffers uploaded for the old scale are released');
      expect(client.commits.last.bufferScale, 2);
    });

    test('the hotspot is divided by the scale it was uploaded at', () {
      // A 48-pixel image with a hotspot at 8,8 on a 2x output is a 4,4
      // hotspot in surface coordinates.
      installCursor('default',
          nominalSize: 48, width: 48, height: 48, hotspotX: 8, hotspotY: 8);
      final cursors = manager(size: 24)..setBufferScale(2);

      cursors.apply(SystemCursor.arrow);

      final set = client.cursorSets.last;
      expect(set.hotspotX, 4);
      expect(set.hotspotY, 4);
    });

    test('the same scale is a no-op', () {
      installCursor('default');
      final cursors = manager()..apply(SystemCursor.arrow);
      final buffers = client.createdBuffers.length;

      cursors.setBufferScale(1);

      expect(client.createdBuffers, hasLength(buffers));
    });
  });

  group('dispose', () {
    test('releases every buffer and the cursor surface', () {
      installCursor('default');
      installCursor('text');
      final cursors = manager()
        ..apply(SystemCursor.arrow)
        ..apply(SystemCursor.text);

      cursors.dispose();

      expect(client.destroyedBuffers, hasLength(2));
      expect(client.destroyedSurfaces, hasLength(1));
    });

    test('stops a running animation', () {
      installCursor('wait', delays: <int>[30, 30]);
      final cursors = manager()..apply(SystemCursor.wait);

      cursors.dispose();

      expect(clock.pending, isZero);
    });
  });
}

// ---------------------------------------------------------------------------
// Fakes
// ---------------------------------------------------------------------------

final class _Commit {
  _Commit(this.surfaceId, this.buffer, this.damage, this.bufferScale);
  final int surfaceId;
  final WaylandShmBufferHandle buffer;
  final WaylandCpuDamage damage;
  final int bufferScale;
}

final class _CursorSet {
  _CursorSet(this.surfaceId, this.hotspotX, this.hotspotY);
  final int surfaceId;
  final int hotspotX;
  final int hotspotY;
}

final class _FakeBuffer implements WaylandShmBufferHandle {
  _FakeBuffer(int width, int height)
      : framebuffer = Framebuffer(
          width: width,
          height: height,
          bytesPerRow: width * 4,
          format: PixelFormat.bgra8888Premultiplied,
          pixels: Uint8List(width * height * 4),
        );

  @override
  final Framebuffer framebuffer;

  @override
  bool isBusy = false;
}

final class _FakeCursorClient implements WaylandCursorClient {
  bool shmSupported = true;
  int _nextSurface = 50;

  final List<int> createdSurfaces = <int>[];
  final List<int> destroyedSurfaces = <int>[];
  final List<_FakeBuffer> createdBuffers = <_FakeBuffer>[];
  final List<WaylandShmBufferHandle> destroyedBuffers =
      <WaylandShmBufferHandle>[];
  final List<_Commit> commits = <_Commit>[];
  final List<_CursorSet> cursorSets = <_CursorSet>[];
  final List<String> order = <String>[];

  @override
  bool get supportsShmPresentation => shmSupported;

  @override
  int createBareSurface() {
    final id = _nextSurface++;
    createdSurfaces.add(id);
    return id;
  }

  @override
  void destroyBareSurface(int surfaceId) => destroyedSurfaces.add(surfaceId);

  @override
  WaylandShmBufferHandle createShmBuffer({
    required int pixelWidth,
    required int pixelHeight,
  }) {
    final buffer = _FakeBuffer(pixelWidth, pixelHeight);
    createdBuffers.add(buffer);
    return buffer;
  }

  @override
  void destroyShmBuffer(WaylandShmBufferHandle buffer) =>
      destroyedBuffers.add(buffer);

  @override
  BackendDiagnostic? presentShmBuffer({
    required int surfaceId,
    required WaylandShmBufferHandle buffer,
    required WaylandCpuDamage damage,
    required int bufferScale,
  }) {
    commits.add(_Commit(surfaceId, buffer, damage, bufferScale));
    order.add('commit');
    return null;
  }

  @override
  bool setPointerCursor({
    required int surfaceId,
    required int hotspotX,
    required int hotspotY,
  }) {
    cursorSets.add(_CursorSet(surfaceId, hotspotX, hotspotY));
    order.add('set_cursor');
    return true;
  }
}

final class _FakeCursorFileSystem implements CursorFileSystem {
  final Map<String, Uint8List> files = <String, Uint8List>{};

  @override
  bool fileExists(String path) => files.containsKey(path);

  @override
  List<int>? readFile(String path) => files[path];
}

/// A timer the test drives, so an animation runs in zero real time.
final class _ManualClock {
  final List<({Duration delay, void Function() callback})> _scheduled =
      <({Duration delay, void Function() callback})>[];

  int get pending => _scheduled.length;

  Duration? get nextDelay =>
      _scheduled.isEmpty ? null : _scheduled.first.delay;

  void Function() schedule(Duration delay, void Function() callback) {
    final entry = (delay: delay, callback: callback);
    _scheduled.add(entry);
    return () => _scheduled.remove(entry);
  }

  /// Fires every timer whose delay is at most [duration], one round.
  void advance(Duration duration) {
    final due = _scheduled
        .where((({Duration delay, void Function() callback}) e) =>
            e.delay <= duration)
        .toList();
    for (final entry in due) {
      if (!_scheduled.remove(entry)) continue;
      entry.callback();
    }
  }
}
