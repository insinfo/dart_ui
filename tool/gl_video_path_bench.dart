/// Measures the two routes a decoded video frame can take to the screen.
///
/// §68.2 lists `GlVideoDevice` as written and not wired, and asks whether
/// wiring it pays. This file is the measurement that answers it, because the
/// answer depends entirely on the *pixel format the decoder emits* and that is
/// a property of this repository rather than of video in general.
///
/// The two routes:
///
///   * **bytes** - `GpuVideoImageCache.resolve`, which every backend already
///     uses. A packed frame whose layout a texture format matches is handed to
///     the driver unread; anything else goes through `convertVideoFrameToRgba`
///     on the Dart side. The texture then reaches the screen as one more quad
///     inside `GpuRasterSink`'s existing batch.
///   * **planes** - `GlVideoDevice`, one texture per plane and the YUV matrix
///     applied in the fragment shader. Never batched: its own program, its own
///     vertex array, one `glDrawArrays` per frame.
///
/// Both are timed on a real GL context - a hidden `HWND` with a WGL context on
/// Windows, EGL elsewhere - because the cost being compared is a driver
/// upload and a headless stub would measure nothing.
///
/// ```
/// dart run tool/gl_video_path_bench.dart
/// dart run tool/gl_video_path_bench.dart --frames=200 --size=1920x1080
/// ```
///
/// Prints one `VIDEO_PATH=` line per (format, route) pair and exits non-zero
/// only when no GL device could be opened, which is the one outcome that
/// makes the numbers meaningless rather than merely unfavourable.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:dart_ui/src/backends/win32/win32_gl_surface.dart';
import 'package:dart_ui/src/geometry/rect.dart';
import 'package:dart_ui/src/graphics/image/decoded_image.dart';
import 'package:dart_ui/src/graphics/video/video_frame.dart';
import 'package:dart_ui/src/rendering/gpu/gl/gl_backend.dart';
import 'package:dart_ui/src/rendering/gpu/gl/gl_bindings.dart';
import 'package:dart_ui/src/rendering/gpu/gl/gl_context.dart';
import 'package:dart_ui/src/rendering/gpu/gpu_texture.dart';
import 'package:dart_ui/src/rendering/gpu/gpu_video_image.dart';
import 'package:dart_ui/src/rendering/gpu/video/gl_video_device.dart';

void main(List<String> arguments) {
  var frames = 120;
  var width = 1920;
  var height = 1080;
  for (final String argument in arguments) {
    if (argument.startsWith('--frames=')) {
      frames = int.parse(argument.substring('--frames='.length));
    } else if (argument.startsWith('--size=')) {
      final List<String> parts =
          argument.substring('--size='.length).split('x');
      width = int.parse(parts[0]);
      height = int.parse(parts[1]);
    }
  }

  final _Session session = _Session.open();
  final GlRenderDevice? device = session.device;
  if (device == null) {
    stderr.writeln('VIDEO_PATH_ERROR=${session.failure}');
    exit(2);
  }
  final NativeHeap? heap = NativeHeap.tryBind(null);
  if (heap == null) {
    stderr.writeln('VIDEO_PATH_ERROR=no native heap');
    exit(2);
  }
  if (!device.makeCurrentOrLose()) {
    stderr.writeln('VIDEO_PATH_ERROR=the context would not become current');
    exit(2);
  }

  stdout.writeln('VIDEO_PATH_DEVICE=${device.info.deviceDescription}');
  stdout.writeln('VIDEO_PATH_SIZE=${width}x$height frames=$frames');

  try {
    for (final VideoPixelFormat pixel in <VideoPixelFormat>[
      VideoPixelFormat.bgra8888,
      VideoPixelFormat.nv12,
    ]) {
      _runBytesRoute(device, pixel, width, height, frames);
      _runPlanesRoute(
        device,
        heap,
        session.isDesktopGl,
        pixel,
        width,
        height,
        frames,
      );
    }
  } finally {
    session.dispose();
  }
}

// ---------------------------------------------------------------------------
// Route "bytes": GpuVideoImageCache, the path in use today.
// ---------------------------------------------------------------------------

void _runBytesRoute(
  GlRenderDevice device,
  VideoPixelFormat pixel,
  int width,
  int height,
  int frames,
) {
  // `ImageChannelOrder.rgba` because that is what every backend in this
  // repository passes; it is what decides whether a BGRA frame skips the
  // conversion.
  final cache =
      GpuVideoImageCache(device, channelOrder: ImageChannelOrder.rgba);
  final List<VideoFrame> stream = _frames(pixel, width, height, frames, 1);

  // One warm frame, so texture creation and the format probe are not charged
  // to the loop the way they never are to a running player.
  cache.resolve(stream.first);
  device.api.finish();

  final Stopwatch watch = Stopwatch()..start();
  for (var i = 1; i < stream.length; i++) {
    final GpuTextureHandle? texture = cache.resolve(stream[i]);
    if (texture == null) {
      stdout.writeln('VIDEO_PATH=${pixel.name} route=bytes REFUSED');
      return;
    }
  }
  device.api.finish();
  watch.stop();

  _report(
    pixel: pixel,
    route: 'bytes',
    watch: watch,
    frames: stream.length - 1,
    detail: 'direct=${cache.directUploadCount} '
        'converted=${cache.conversionCount} '
        'textures=${cache.createCount} '
        'staging=${cache.stagingBytes}B',
  );
}

// ---------------------------------------------------------------------------
// Route "planes": GlVideoDevice, conversion in the fragment shader.
// ---------------------------------------------------------------------------

void _runPlanesRoute(
  GlRenderDevice device,
  NativeHeap heap,
  bool desktop,
  VideoPixelFormat pixel,
  int width,
  int height,
  int frames,
) {
  final video = GlVideoDevice(device.api, heap, desktop: desktop);
  try {
    video.initialize();
  } on Object catch (error) {
    stdout.writeln('VIDEO_PATH=${pixel.name} route=planes UNAVAILABLE $error');
    video.dispose();
    return;
  }

  final List<VideoFrame> stream = _frames(pixel, width, height, frames, 2);
  final VideoFrameFormat format = stream.first.format;
  final GlStreamingVideoTexture texture = video.createStreamingTexture(
    format: format,
    streamId: 2,
  );

  final destination = Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble());
  final source = Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble());

  video.uploadFrame(texture, stream.first);
  video.drawFrame(
    texture,
    sourceRect: source,
    destination: destination,
    clip: destination,
    viewportWidth: width,
    viewportHeight: height,
  );
  device.api.finish();

  final uploadOnly = Stopwatch();
  final Stopwatch total = Stopwatch()..start();
  for (var i = 1; i < stream.length; i++) {
    uploadOnly.start();
    video.uploadFrame(texture, stream[i]);
    uploadOnly.stop();
    video.drawFrame(
      texture,
      sourceRect: source,
      destination: destination,
      clip: destination,
      viewportWidth: width,
      viewportHeight: height,
    );
    // A double-buffered ring only frees a slot when the caller declares a
    // frame finished. A player does that from a fence or from the swap chain's
    // frame index; here the frame drawn on the previous iteration is the
    // newest one no draw is still being recorded against.
    texture.ring.retire(stream[i - 1].sequence);
  }
  device.api.finish();
  total.stop();

  _report(
    pixel: pixel,
    route: 'planes',
    watch: total,
    frames: stream.length - 1,
    detail: 'upload='
        '${_perFrame(uploadOnly, stream.length - 1)}ms '
        'planes=${format.planeCount}',
  );

  video
    ..releaseStreamingTexture(texture)
    ..dispose();
}

// ---------------------------------------------------------------------------
// Frames
// ---------------------------------------------------------------------------

/// [count] frames of moving content, so no route can win by uploading the same
/// bytes twice - `GpuVideoImageCache` skips a re-upload keyed on `sequence`,
/// which would flatter it into measuring nothing.
List<VideoFrame> _frames(
  VideoPixelFormat pixel,
  int width,
  int height,
  int count,
  int streamId,
) {
  final format = VideoFrameFormat(
    pixelFormat: pixel,
    width: width,
    height: height,
    colorSpace: VideoColorSpace.bt709,
    range: VideoColorRange.full,
  );
  return <VideoFrame>[
    for (var i = 0; i < count; i++)
      _fill(VideoFrame.allocate(format, streamId: streamId, sequence: i), i),
  ];
}

VideoFrame _fill(VideoFrame frame, int index) {
  // A cheap gradient that moves. The content does not matter to either route's
  // cost, only that the buffers are touched and distinct.
  for (var plane = 0; plane < frame.format.planeCount; plane++) {
    final VideoPlane target = frame.plane(plane);
    final Uint8List bytes = target.bytes;
    final int start = target.offset;
    final int step = 1 + plane;
    for (var i = start; i < bytes.length; i += 64) {
      bytes[i] = (i * step + index) & 0xFF;
    }
  }
  return frame;
}

// ---------------------------------------------------------------------------
// Reporting
// ---------------------------------------------------------------------------

String _perFrame(Stopwatch watch, int frames) =>
    (watch.elapsedMicroseconds / frames / 1000).toStringAsFixed(3);

void _report({
  required VideoPixelFormat pixel,
  required String route,
  required Stopwatch watch,
  required int frames,
  required String detail,
}) {
  stdout.writeln('VIDEO_PATH=${pixel.name} route=$route '
      'perFrame=${_perFrame(watch, frames)}ms $detail');
}

// ---------------------------------------------------------------------------
// The context
// ---------------------------------------------------------------------------

final class _Session {
  _Session._(this.device, this.failure, this._surface, this._context);

  final GlRenderDevice? device;
  final String? failure;
  final Win32GlSurface? _surface;
  final GlContext? _context;

  /// The shader dialect `GlVideoDevice` has to be built for. Read from the
  /// context rather than guessed from the platform: an ANGLE context on
  /// Windows is a GLES context.
  bool get isDesktopGl => _context?.isDesktopGl ?? true;

  static _Session open() {
    try {
      return Platform.isWindows ? _openWindows() : _openEgl();
    } on Object catch (error) {
      return _Session._(null, 'opening a GL device threw: $error', null, null);
    }
  }

  static _Session _openWindows() {
    final attempt = Win32GlSurface.hidden();
    final Win32GlSurface? surface = attempt.surface;
    if (surface == null) {
      return _Session._(
          null, 'no GL surface: ${attempt.diagnostics.join('; ')}', null, null);
    }
    final contextAttempt = surface.createContext();
    final GlContext? context = contextAttempt.context;
    if (context == null) {
      surface.dispose();
      return _Session._(
          null,
          'no GL context: ${contextAttempt.diagnostics.join('; ')}',
          null,
          null);
    }
    return _Session._(
      GlRendererBackend.adoptContext(context, surface.glLibrary),
      null,
      surface,
      context,
    );
  }

  static _Session _openEgl() {
    final load = GlLibrary.open();
    if (!load.isLoaded) {
      return _Session._(
          null, 'no GL library: ${load.attempted.join(', ')}', null, null);
    }
    final attempt = const GlContextFactory()
        .create(width: 16, height: 16, glLibrary: load.library!);
    final GlContext? context = attempt.context;
    if (context == null) {
      return _Session._(null,
          'no EGL context: ${attempt.diagnostics.join('; ')}', null, null);
    }
    return _Session._(
      GlRendererBackend.adoptContext(context, load.library!),
      null,
      null,
      context,
    );
  }

  void dispose() {
    device?.dispose();
    _context?.dispose();
    _surface?.dispose();
  }
}
