/// Turning a [SystemCursor] into pixels on the compositor's pointer.
///
/// On Wayland the client *is* the cursor renderer: `wl_pointer.set_cursor`
/// takes a `wl_surface` the client has drawn into, so every step - find the
/// theme file, parse it, allocate an shm buffer, upload, attach, commit, and
/// keep an animation ticking - happens here. `libwayland-cursor` does this in
/// C; this is the Dart equivalent, assembled from the pieces the backend
/// already has: `wayland_xcursor.dart` parses, `wayland_cursor_theme.dart`
/// locates, and the connection allocates and commits.
///
/// ## What is cached and why
///
/// A cursor is loaded once per [SystemCursor] and kept: the pointer crosses
/// widget boundaries constantly, and re-reading a theme file from disk on
/// every hover would put file I/O on the input path. The cache holds the
/// uploaded buffers, so a repeat of a cursor already seen costs one
/// `set_cursor` request and nothing else.
///
/// ## Animation
///
/// An animated cursor is several frames sharing a nominal size, each with its
/// own delay. Frames are advanced by a timer the owner supplies - the same
/// dispatcher-driven shape as key repeat, so the clock is injectable and a
/// test can play a whole loop without waiting.
library;

import 'dart:typed_data';

import '../../foundation/diagnostics.dart';
import '../../platform/native_window.dart';
import 'wayland_cursor_theme.dart';
import 'wayland_shm.dart';
import 'wayland_xcursor.dart';

/// What the cursor manager needs from a connection.
///
/// Narrower than [WaylandWindowClient] on purpose: everything here is
/// exercised by a fake in the tests, and a fake that had to implement the
/// whole window protocol to check a hotspot would not get written.
abstract interface class WaylandCursorClient {
  bool get supportsShmPresentation;

  int createBareSurface();
  void destroyBareSurface(int surfaceId);

  WaylandShmBufferHandle createShmBuffer({
    required int pixelWidth,
    required int pixelHeight,
  });

  void destroyShmBuffer(WaylandShmBufferHandle buffer);

  BackendDiagnostic? presentShmBuffer({
    required int surfaceId,
    required WaylandShmBufferHandle buffer,
    required WaylandCpuDamage damage,
    required int bufferScale,
  });

  bool setPointerCursor({
    required int surfaceId,
    required int hotspotX,
    required int hotspotY,
  });
}

/// Schedules [callback] after [delay]; returns a cancel function.
///
/// The seam that keeps animation testable: production passes the dispatcher's
/// timer, tests pass a manual clock.
typedef WaylandCursorTimer = void Function() Function(
  Duration delay,
  void Function() callback,
);

/// One uploaded frame: the buffer plus where its hotspot sits.
final class _CursorFrame {
  _CursorFrame({
    required this.buffer,
    required this.hotspotX,
    required this.hotspotY,
    required this.width,
    required this.height,
    required this.delayMilliseconds,
  });

  final WaylandShmBufferHandle buffer;
  final int hotspotX;
  final int hotspotY;
  final int width;
  final int height;
  final int delayMilliseconds;
}

/// Every frame of one loaded cursor.
final class _LoadedCursor {
  _LoadedCursor(this.frames, {required this.scale});

  final List<_CursorFrame> frames;

  /// The buffer scale the frames were uploaded at. A move to a monitor with a
  /// different scale invalidates them, because a cursor scaled by the
  /// compositor is a blurry cursor.
  final int scale;

  bool get isAnimated => frames.length > 1;
}

/// Loads, uploads and applies pointer cursors.
final class WaylandCursorManager {
  WaylandCursorManager({
    required WaylandCursorClient client,
    required CursorFileSystem fileSystem,
    required WaylandCursorThemeResolution resolution,
    WaylandCursorTimer? timer,
  })  : _client = client,
        _fileSystem = fileSystem,
        _resolution = resolution,
        _timer = timer;

  final WaylandCursorClient _client;
  final CursorFileSystem _fileSystem;
  final WaylandCursorThemeResolution _resolution;
  final WaylandCursorTimer? _timer;

  final Map<SystemCursor, _LoadedCursor?> _cache =
      <SystemCursor, _LoadedCursor?>{};
  final List<BackendDiagnostic> _diagnostics = <BackendDiagnostic>[];

  int _surfaceId = 0;
  int _bufferScale = 1;
  SystemCursor? _current;
  bool _hidden = false;
  _LoadedCursor? _playing;
  int _frameIndex = 0;
  void Function()? _cancelTimer;

  /// Everything that went wrong or was fallen back to, newest last.
  List<BackendDiagnostic> get diagnostics =>
      List<BackendDiagnostic>.unmodifiable(_diagnostics);

  /// The cursor currently applied, or null when hidden or never set.
  SystemCursor? get currentCursor => _hidden ? null : _current;

  bool get isHidden => _hidden;

  /// Which frame of an animation is showing. Always 0 for a static cursor.
  int get frameIndex => _frameIndex;

  /// Whether the applied cursor is animating.
  bool get isAnimating => _playing != null && _playing!.isAnimated;

  /// The integer buffer scale cursors are rendered at.
  int get bufferScale => _bufferScale;

  /// Adopts a new output scale, discarding cursors uploaded for the old one.
  ///
  /// A cursor is not resized by the compositor for free: a 24-pixel image on
  /// a 2x output is either blurry or half-size, so the theme is re-read at the
  /// size the new scale wants.
  void setBufferScale(int scale) {
    final next = scale < 1 ? 1 : scale;
    if (next == _bufferScale) return;
    _bufferScale = next;
    _releaseCache();
    final current = _current;
    if (current != null && !_hidden) {
      _current = null;
      apply(current);
    }
  }

  /// Applies [cursor], loading it the first time it is asked for.
  ///
  /// Returns whether a cursor was actually installed. False means the theme
  /// had nothing usable, and the reason is in [diagnostics]; the pointer then
  /// keeps whatever the compositor last showed rather than going invisible,
  /// which is the least surprising failure.
  bool apply(SystemCursor cursor) {
    if (!_hidden && _current == cursor) return _playing != null;
    _hidden = false;
    _current = cursor;
    _stopAnimation();

    final loaded = _load(cursor) ?? _loadFallbackArrow(cursor);
    if (loaded == null) return false;

    if (!_ensureSurface()) return false;
    _playing = loaded;
    _frameIndex = 0;
    _showFrame(0);
    if (loaded.isAnimated) _scheduleNextFrame();
    return true;
  }

  /// Hides the pointer: `set_cursor` with a null surface, which is the only
  /// way the protocol expresses it.
  void hide() {
    if (_hidden) return;
    _hidden = true;
    _stopAnimation();
    _playing = null;
    _client.setPointerCursor(surfaceId: 0, hotspotX: 0, hotspotY: 0);
  }

  /// Re-applies the current cursor, which a `wl_pointer.enter` must do: the
  /// cursor is per-enter state, and a pointer that re-entered a window with
  /// no `set_cursor` shows the compositor's default.
  void reapplyOnPointerEnter() {
    if (_hidden) {
      _client.setPointerCursor(surfaceId: 0, hotspotX: 0, hotspotY: 0);
      return;
    }
    final playing = _playing;
    if (playing == null) return;
    _showFrame(_frameIndex);
  }

  void _showFrame(int index) {
    final playing = _playing;
    if (playing == null || _surfaceId == 0) return;
    final frame = playing.frames[index % playing.frames.length];
    final failure = _client.presentShmBuffer(
      surfaceId: _surfaceId,
      buffer: frame.buffer,
      damage: WaylandCpuDamage(
        x: 0,
        y: 0,
        width: frame.width,
        height: frame.height,
      ),
      bufferScale: playing.scale,
    );
    if (failure != null) {
      _record(failure);
      return;
    }
    // The hotspot is in surface-local coordinates, so it is the image hotspot
    // divided by the scale the image was uploaded at - getting this wrong
    // puts the click point in the wrong place on every HiDPI screen.
    _client.setPointerCursor(
      surfaceId: _surfaceId,
      hotspotX: frame.hotspotX ~/ playing.scale,
      hotspotY: frame.hotspotY ~/ playing.scale,
    );
  }

  void _scheduleNextFrame() {
    final timer = _timer;
    final playing = _playing;
    if (timer == null || playing == null || !playing.isAnimated) return;
    final frame = playing.frames[_frameIndex % playing.frames.length];
    // A zero delay would spin the timer; the protocol leaves it undefined and
    // real themes use 30-100ms, so a floor keeps a broken theme cheap.
    final delay = frame.delayMilliseconds < 10 ? 100 : frame.delayMilliseconds;
    _cancelTimer = timer(Duration(milliseconds: delay), _advanceFrame);
  }

  void _advanceFrame() {
    _cancelTimer = null;
    final playing = _playing;
    if (playing == null || !playing.isAnimated) return;
    _frameIndex = (_frameIndex + 1) % playing.frames.length;
    _showFrame(_frameIndex);
    _scheduleNextFrame();
  }

  void _stopAnimation() {
    _cancelTimer?.call();
    _cancelTimer = null;
    _frameIndex = 0;
  }

  bool _ensureSurface() {
    if (_surfaceId != 0) return true;
    final surfaceId = _client.createBareSurface();
    if (surfaceId == 0) {
      _record(const BackendDiagnostic(
        kind: DiagnosticKind.surfaceCreationFailed,
        message: 'could not create a wl_surface for the pointer cursor',
      ));
      return false;
    }
    _surfaceId = surfaceId;
    return true;
  }

  /// Loads [cursor] from the theme, or null when nothing usable was found.
  /// The result - including the null - is cached, so a missing cursor costs
  /// one failed lookup rather than one per pointer move.
  _LoadedCursor? _load(SystemCursor cursor) {
    if (_cache.containsKey(cursor)) return _cache[cursor];
    final loaded = _loadUncached(cursor);
    _cache[cursor] = loaded;
    return loaded;
  }

  _LoadedCursor? _loadUncached(SystemCursor cursor) {
    if (!_client.supportsShmPresentation) {
      _record(const BackendDiagnostic(
        kind: DiagnosticKind.incompatibleDevice,
        message: 'cursors need wl_shm, which this compositor did not offer',
      ));
      return null;
    }
    final path = findWaylandCursorFile(
      fileSystem: _fileSystem,
      resolution: _resolution,
      cursor: cursor,
    );
    if (path == null) {
      _record(BackendDiagnostic(
        kind: DiagnosticKind.note,
        message: 'no theme file for ${cursor.name}',
        detail: 'theme ${_resolution.themeName}; tried '
            '${(waylandCursorNames[cursor] ?? const <String>[]).join(', ')}',
      ));
      return null;
    }
    final bytes = _fileSystem.readFile(path);
    if (bytes == null) {
      _record(BackendDiagnostic(
        kind: DiagnosticKind.permissionDenied,
        message: 'cursor file could not be read',
        detail: path,
      ));
      return null;
    }
    final file = parseXcursorFile(
      bytes is Uint8List ? bytes : Uint8List.fromList(bytes),
    );
    if (file == null) {
      _record(BackendDiagnostic(
        kind: DiagnosticKind.incompatibleVersion,
        message: 'cursor file is not a readable XCursor image',
        detail: path,
      ));
      return null;
    }

    final wanted = _resolution.size * _bufferScale;
    final chosen = file.bestForSize(wanted);
    if (chosen == null) return null;
    final frames = file.framesForSize(chosen.nominalSize);
    final uploaded = <_CursorFrame>[];
    for (final frame in frames) {
      final buffer = _upload(frame);
      if (buffer == null) {
        for (final done in uploaded) {
          _client.destroyShmBuffer(done.buffer);
        }
        return null;
      }
      uploaded.add(buffer);
    }
    if (uploaded.isEmpty) return null;
    return _LoadedCursor(uploaded, scale: _bufferScale);
  }

  _CursorFrame? _upload(XcursorImage image) {
    try {
      final buffer = _client.createShmBuffer(
        pixelWidth: image.width,
        pixelHeight: image.height,
      );
      final framebuffer = buffer.framebuffer;
      // The parser already produced premultiplied BGRA, which is exactly the
      // framebuffer's format, so this is a straight row copy - honouring the
      // destination stride, which need not equal width * 4.
      for (var y = 0; y < image.height; y++) {
        final source = y * image.bytesPerRow;
        final destination = y * framebuffer.bytesPerRow;
        framebuffer.pixels.setRange(
          destination,
          destination + image.bytesPerRow,
          image.pixels,
          source,
        );
      }
      return _CursorFrame(
        buffer: buffer,
        hotspotX: image.hotspotX,
        hotspotY: image.hotspotY,
        width: image.width,
        height: image.height,
        delayMilliseconds: image.delayMilliseconds,
      );
    } on Object catch (error) {
      _record(BackendDiagnostic(
        kind: DiagnosticKind.surfaceCreationFailed,
        message: 'failed to upload a cursor image',
        detail: '$error',
      ));
      return null;
    }
  }

  /// The arrow, when the requested cursor is missing from the theme.
  ///
  /// Better than an invisible pointer and better than the compositor's
  /// default, which would not match the theme the user chose. Recorded, so
  /// "why is my resize cursor an arrow" has an answer.
  _LoadedCursor? _loadFallbackArrow(SystemCursor requested) {
    if (requested == SystemCursor.arrow) return null;
    final arrow = _load(SystemCursor.arrow);
    if (arrow != null) {
      _record(BackendDiagnostic.note(
        'using the arrow cursor for ${requested.name}',
        detail: 'the theme has no image for it',
      ));
    }
    return arrow;
  }

  void _releaseCache() {
    for (final loaded in _cache.values) {
      if (loaded == null) continue;
      for (final frame in loaded.frames) {
        _client.destroyShmBuffer(frame.buffer);
      }
    }
    _cache.clear();
    _playing = null;
  }

  void _record(BackendDiagnostic diagnostic) {
    if (_diagnostics.length >= 32) _diagnostics.removeAt(0);
    _diagnostics.add(diagnostic);
  }

  void dispose() {
    _stopAnimation();
    _releaseCache();
    if (_surfaceId != 0) {
      _client.destroyBareSurface(_surfaceId);
      _surfaceId = 0;
    }
    _current = null;
  }
}
