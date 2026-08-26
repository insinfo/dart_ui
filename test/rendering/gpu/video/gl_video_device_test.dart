/// `GlVideoDevice` against a real driver.
///
/// This file exists because of what happened the first time the class was run
/// against one at all. `gl_video_device.dart` had been complete, reviewed and
/// unreferenced since it was written; `test/rendering/gpu/video/` held one
/// test, for the pure-Dart upload ring. `drawFrame` set a `float` uniform
/// through `glUniform4f` on the reading that the extra components are ignored,
/// which is not what `glUniform` does - the declared size must match, and a
/// mismatch is `GL_INVALID_OPERATION` with the uniform left unchanged. The
/// class's own `_checkError` turned that into a `StateError` on the very first
/// call, so *every* draw raised. Nothing caught it because nothing had ever
/// executed it.
///
/// So the assertions here are deliberately the shallow ones a driver answers:
/// that a draw completes, and that the pixels it produced are the colour the
/// portable converter computes for the same frame. A headless double would
/// have reported both of those correctly while the driver refused the call,
/// which is the exact false green this repository has been bitten by before.
///
/// Skips, with a reason, where no GL device answers.
library;

import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:dart_ui/src/backends/win32/win32_gl_surface.dart';
import 'package:dart_ui/src/foundation/diagnostics.dart';
import 'package:dart_ui/src/geometry/rect.dart';
import 'package:dart_ui/src/graphics/image/decoded_image.dart';
import 'package:dart_ui/src/graphics/video/video_color_conversion.dart';
import 'package:dart_ui/src/graphics/video/video_frame.dart';
import 'package:dart_ui/src/rendering/gpu/gl/gl_backend.dart';
import 'package:dart_ui/src/rendering/gpu/gl/gl_bindings.dart';
import 'package:dart_ui/src/rendering/gpu/gl/gl_context.dart';
import 'package:dart_ui/src/rendering/gpu/gl/gl_framebuffer_pool.dart';
import 'package:dart_ui/src/rendering/gpu/video/gl_video_device.dart';
import 'package:dart_ui/src/rendering/gpu/video/video_upload_ring.dart';
import 'package:test/test.dart';

const int _size = 16;

void main() {
  final _GlVideoSession session = _GlVideoSession.open();

  tearDownAll(session.dispose);

  group('GlVideoDevice on a real GL context', () {
    test('a BGRA frame draws the colour it holds', () {
      // The regression the file's header describes: before the fix this threw
      // `StateError: video drawArrays raised GL error 0x502` and never reached
      // a pixel. It is also the channel-order check - the shader reads
      // `texel.bgr` for this format, and dropping that swap would paint the
      // blue below as red on footage nobody would look at twice.
      const int blue = 0xC0;
      const int green = 0x40;
      const int red = 0x20;
      final VideoFrame frame = _packed(
        VideoPixelFormat.bgra8888,
        <int>[blue, green, red, 0xFF],
      );
      final Uint8List pixels = session.render(frame);

      expect(pixels[0], _within(red), reason: 'red channel');
      expect(pixels[1], _within(green), reason: 'green channel');
      expect(pixels[2], _within(blue), reason: 'blue channel');
      expect(pixels[3], _within(0xFF), reason: 'alpha channel');
    }, skip: session.skipReason);

    test('an NV12 frame matches the portable converter', () {
      // The claim the whole class is for: the YUV matrix evaluated in the
      // fragment shader lands on the same colour `convertVideoFrameToRgba`
      // computes in 16.16 fixed point on the CPU. A uniform frame is used so
      // chroma subsampling cannot contribute to the difference - the two sides
      // resolve subsampling identically, but proving *that* is a separate
      // question from proving the matrix.
      final VideoFrame frame = _uniformNv12(luma: 0x90, u: 0x50, v: 0xC0);
      final Uint8List reference = convertVideoFrameToRgba(
        frame,
        order: ImageChannelOrder.rgba,
      );
      final Uint8List pixels = session.render(frame);

      for (var channel = 0; channel < 4; channel++) {
        expect(
          pixels[channel],
          _within(reference[channel]),
          reason: 'channel $channel: GPU ${pixels.sublist(0, 4)} vs CPU '
              '${reference.sublist(0, 4)}',
        );
      }
    }, skip: session.skipReason);

    test('drawFrame reports the planes it bound', () {
      // Cheap, and it is the counter a caller would use to prove a partial
      // upload stayed partial. NV12 is two planes; a device that silently drew
      // one would produce a monochrome picture and no error.
      final VideoFrame frame = _uniformNv12(luma: 0x80, u: 0x80, v: 0x80);
      final VideoDrawStats stats = session.renderStats(frame);
      expect(stats.planeBinds, 2);
      expect(stats.vertexBytes, 4 * 4 * 4);
    }, skip: session.skipReason);
  });
}

/// The GPU is allowed two levels: the shader evaluates the matrix in float and
/// the converter in 16.16 fixed point, and the readback is 8 bit.
Matcher _within(int expected) => inInclusiveRange(
    (expected - 2).clamp(0, 255), (expected + 2).clamp(0, 255));

// ---------------------------------------------------------------------------
// Frames
// ---------------------------------------------------------------------------

/// A [_size]x[_size] packed frame in which every pixel is [pixel].
VideoFrame _packed(VideoPixelFormat format, List<int> pixel) {
  final VideoFrame frame = VideoFrame.allocate(
    VideoFrameFormat(
      pixelFormat: format,
      width: _size,
      height: _size,
      colorSpace: VideoColorSpace.bt709,
      range: VideoColorRange.full,
    ),
    streamId: 1,
  );
  final VideoPlane plane = frame.plane(0);
  for (var i = plane.offset; i + 3 < plane.bytes.length; i += 4) {
    plane.bytes[i] = pixel[0];
    plane.bytes[i + 1] = pixel[1];
    plane.bytes[i + 2] = pixel[2];
    plane.bytes[i + 3] = pixel[3];
  }
  return frame;
}

/// A [_size]x[_size] NV12 frame of one colour.
VideoFrame _uniformNv12({
  required int luma,
  required int u,
  required int v,
}) {
  final VideoFrame frame = VideoFrame.allocate(
    VideoFrameFormat(
      pixelFormat: VideoPixelFormat.nv12,
      width: _size,
      height: _size,
      colorSpace: VideoColorSpace.bt709,
      range: VideoColorRange.full,
    ),
    streamId: 1,
  );
  final VideoPlane y = frame.plane(0);
  for (var i = y.offset; i < y.offset + _size * y.bytesPerRow; i++) {
    y.bytes[i] = luma;
  }
  final VideoPlane uv = frame.plane(1);
  for (var i = uv.offset;
      i + 1 < uv.offset + (_size ~/ 2) * uv.bytesPerRow;
      i += 2) {
    uv.bytes[i] = u;
    uv.bytes[i + 1] = v;
  }
  return frame;
}

// ---------------------------------------------------------------------------
// The context
// ---------------------------------------------------------------------------

final class _GlVideoSession {
  _GlVideoSession._(
    this._device,
    this._video,
    this._pool,
    this._target,
    this._heap,
    this.skipReason,
    this._surface,
    this._context,
  );

  /// Null when a device opened; a string - which `skip:` accepts - naming what
  /// was missing when one did not.
  final String? skipReason;

  final GlRenderDevice? _device;
  final GlVideoDevice? _video;
  final GlFramebufferPool? _pool;
  final GlFramebuffer? _target;
  final NativeHeap? _heap;
  final Win32GlSurface? _surface;
  final GlContext? _context;

  static _GlVideoSession _failed(
    String reason, [
    Win32GlSurface? surface,
    GlContext? context,
  ]) {
    context?.dispose();
    surface?.dispose();
    return _GlVideoSession._(null, null, null, null, null, reason, null, null);
  }

  static _GlVideoSession open() {
    try {
      return Platform.isWindows ? _openWindows() : _openEgl();
    } on Object catch (error) {
      return _failed('opening a GL device threw: $error');
    }
  }

  static _GlVideoSession _openWindows() {
    final attempt = Win32GlSurface.hidden();
    final Win32GlSurface? surface = attempt.surface;
    if (surface == null) {
      return _failed('no GL surface: ${attempt.diagnostics.join('; ')}');
    }
    final contextAttempt = surface.createContext();
    final GlContext? context = contextAttempt.context;
    if (context == null) {
      return _failed(
        'no GL context: ${contextAttempt.diagnostics.join('; ')}',
        surface,
      );
    }
    return _adopt(
      () => GlRendererBackend.adoptContext(context, surface.glLibrary),
      context,
      surface,
    );
  }

  static _GlVideoSession _openEgl() {
    final load = GlLibrary.open();
    if (!load.isLoaded) {
      return _failed('no GL library: ${load.attempted.join(', ')}');
    }
    final attempt = const GlContextFactory()
        .create(width: _size, height: _size, glLibrary: load.library!);
    final GlContext? context = attempt.context;
    if (context == null) {
      return _failed('no EGL context: ${attempt.diagnostics.join('; ')}');
    }
    return _adopt(
      () => GlRendererBackend.adoptContext(context, load.library!),
      context,
      null,
    );
  }

  static _GlVideoSession _adopt(
    GlRenderDevice Function() open,
    GlContext context,
    Win32GlSurface? surface,
  ) {
    final GlRenderDevice device;
    try {
      device = open();
    } on BackendSelectionError catch (error) {
      return _failed('no GL device: $error', surface, context);
    }
    final NativeHeap? heap = NativeHeap.tryBind(null);
    if (heap == null) {
      device.dispose();
      return _failed('no native heap for the readback', surface, context);
    }
    if (!device.makeCurrentOrLose()) {
      device.dispose();
      return _failed('the context would not become current', surface, context);
    }
    final video = GlVideoDevice(device.api, heap, desktop: context.isDesktopGl);
    try {
      video.initialize();
    } on Object catch (error) {
      video.dispose();
      device.dispose();
      return _failed(
          'the video program did not build: $error', surface, context);
    }
    final pool = GlFramebufferPool(
      factory: GlDeviceFramebufferFactory(
        gl: device.api,
        scratchNames: device.scratchNames,
        makeCurrent: device.makeCurrentOrLose,
      ),
    );
    return _GlVideoSession._(
      device,
      video,
      pool,
      pool.acquireFramebuffer(_size, _size),
      heap,
      null,
      surface,
      context,
    );
  }

  /// Draws [frame] into the offscreen target and reads the top-left pixel's
  /// row back as RGBA.
  Uint8List render(VideoFrame frame) => _render(frame).$1;

  VideoDrawStats renderStats(VideoFrame frame) => _render(frame).$2;

  (Uint8List, VideoDrawStats) _render(VideoFrame frame) {
    final GlRenderDevice device = _device!;
    final GlVideoDevice video = _video!;
    final NativeHeap heap = _heap!;
    expect(device.makeCurrentOrLose(), isTrue);

    final GlStreamingVideoTexture texture = video.createStreamingTexture(
      format: frame.format,
      streamId: frame.streamId,
      bufferCount: VideoUploadRing.singleBuffered,
    );
    try {
      video.uploadFrame(texture, frame);

      final whole = Rect.fromLTWH(0, 0, _size.toDouble(), _size.toDouble());
      device.api
        ..bindFramebuffer(glFramebuffer, _target!.id)
        ..disable(glScissorTest)
        ..clearColor(0, 0, 0, 0)
        ..clear(glColorBufferBit);
      final VideoDrawStats stats = video.drawFrame(
        texture,
        sourceRect: whole,
        destination: whole,
        clip: whole,
        viewportWidth: _size,
        viewportHeight: _size,
      );

      final Pointer<Uint8> native = heap.allocate<Uint8>(_size * _size * 4);
      try {
        device.api
          ..bindFramebuffer(glFramebuffer, _target.id)
          ..pixelStorei(glPackAlignment, 1)
          ..finish()
          ..readPixels(
              0, 0, _size, _size, glRgba, glUnsignedByte, native.cast<Void>());
        return (
          Uint8List.fromList(native.asTypedList(_size * _size * 4)),
          stats,
        );
      } finally {
        heap.release(native);
      }
    } finally {
      video.releaseStreamingTexture(texture);
    }
  }

  void dispose() {
    _pool?.dispose();
    _video?.dispose();
    _device?.dispose();
    _context?.dispose();
    _surface?.dispose();
  }
}
