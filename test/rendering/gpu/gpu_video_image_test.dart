/// The GPU path's video frames, which used to close the window.
///
/// Every backend's `GpuImageResolver` opened with
/// `if (image is! Framebuffer) return null;`, so a `VideoFrame` resolved to
/// nothing and `GpuRasterSink.drawDeviceImage` raised an
/// `UnsupportedCapabilityError` naming `gpuPresentation`. The CPU renderer
/// drew the same display list perfectly, which is why no headless test caught
/// it - the tests here are the ones that would have.
///
/// Two properties are asserted, and the second is as load-bearing as the
/// first. A frame has to become a texture *at all*; and a stream of them has
/// to cost one texture and one staging buffer in total rather than one of each
/// per frame, because a 1080p frame is 8.29 MB and twenty-five of those a
/// second is a quarter of a gigabyte in ten seconds.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:dart_ui/src/foundation/diagnostics.dart';
import 'package:dart_ui/src/geometry/rect.dart';
import 'package:dart_ui/src/graphics/display_list_opcodes.dart';
import 'package:dart_ui/src/graphics/image/decoded_image.dart';
import 'package:dart_ui/src/graphics/video/video_color_conversion.dart';
import 'package:dart_ui/src/graphics/video/video_frame.dart';
import 'package:dart_ui/src/rendering/gpu/gpu_batcher.dart';
import 'package:dart_ui/src/rendering/gpu/gpu_raster_sink.dart';
import 'package:dart_ui/src/rendering/gpu/gpu_texture.dart';
import 'package:dart_ui/src/rendering/gpu/gpu_video_image.dart';
import 'package:dart_ui/src/rendering/replay/display_list_player.dart';
import 'package:test/test.dart';

import '../../graphics/video/synthetic_frames.dart';

const ReplayPaint _opaque = ReplayPaint(
  argbColor: 0xFFFFFFFF,
  style: paintStyleFill,
  strokeWidth: 0,
  blendMode: blendModeSrcOver,
  antiAlias: true,
);

const Rect _wideClip = Rect.fromLTRB(0, 0, 1000, 1000);

VideoFrame _frame(
  VideoPixelFormat pixelFormat, {
  int width = 16,
  int height = 8,
  int streamId = 1,
  int sequence = 0,
  int seed = 0,
}) =>
    SyntheticPicture.ramp(width, height, seed: seed)
        .encode(pixelFormat, streamId: streamId, sequence: sequence);

void main() {
  group('resolve', () {
    test('a video frame becomes a texture of the frame size', () {
      final allocator = _Allocator();
      final cache = GpuVideoImageCache(allocator);

      final GpuTextureHandle? texture = cache.resolve(_frame(
        VideoPixelFormat.nv12,
      ));

      // The whole bug in one assertion: this used to be null, and null is
      // what `GpuRasterSink.drawDeviceImage` turns into a fatal
      // UnsupportedCapabilityError.
      expect(texture, isNotNull);
      expect(texture!.isValid, isTrue);
      expect(texture.width, 16);
      expect(texture.height, 8);
      expect(texture.format, GpuTextureFormat.rgba8888Premultiplied);
      // Linear, like every other image texture: a video is drawn at whatever
      // scale the layout produced.
      expect(texture.filter, GpuTextureFilter.linear);
    });

    test('the whole frame is uploaded, tightly packed', () {
      final allocator = _Allocator();
      final cache = GpuVideoImageCache(allocator);
      final VideoFrame frame = _frame(VideoPixelFormat.i420);

      cache.resolve(frame);

      expect(allocator.lastUpload, isNotNull);
      final _Upload upload = allocator.lastUpload!;
      // The whole frame and not a crop: the source rectangle is expressed in
      // the quad's texture coordinates by the sink, so cropping here would
      // crop twice.
      expect(<int>[upload.x, upload.y, upload.width, upload.height],
          <int>[0, 0, 16, 8]);
      expect(upload.bytesPerRow, 16 * 4);
      expect(upload.pixels.length, 16 * 8 * 4);
    });

    test('the texels are what the CPU renderer would have drawn', () {
      final allocator = _Allocator();
      final cache = GpuVideoImageCache(allocator);
      final VideoFrame frame = _frame(VideoPixelFormat.nv12);

      cache.resolve(frame);

      // The parity that matters: the GPU path and the CPU path run the same
      // reference converter, so a golden of one is a golden of the other.
      expect(
        allocator.lastUpload!.pixels,
        convertVideoFrameToRgba(frame),
      );
    });

    test('the channel order is the backend\'s, not video\'s', () {
      final allocator = _Allocator();
      final cache = GpuVideoImageCache(
        allocator,
        channelOrder: ImageChannelOrder.bgra,
      );
      final VideoFrame frame = _frame(VideoPixelFormat.nv12);

      cache.resolve(frame);

      expect(
        allocator.lastUpload!.pixels,
        convertVideoFrameToRgba(frame, order: ImageChannelOrder.bgra),
      );
      // And it is genuinely a different byte order, so the assertion above is
      // not vacuous on a grey test picture.
      expect(
        allocator.lastUpload!.pixels,
        isNot(convertVideoFrameToRgba(frame)),
      );
    });

    test('a packed BGRA frame keeps its alpha', () {
      final allocator = _Allocator();
      final cache = GpuVideoImageCache(allocator);

      cache.resolve(_frame(VideoPixelFormat.bgra8888));

      final Uint8List pixels = allocator.lastUpload!.pixels;
      for (var i = 3; i < pixels.length; i += 4) {
        expect(pixels[i], 255, reason: 'byte $i');
      }
    });

    test('anything that is not a frame is still refused', () {
      final cache = GpuVideoImageCache(_Allocator());

      // The delegation each backend now makes is `is! Framebuffer` -> here, so
      // this has to keep answering null for everything else or a stray object
      // would resolve to a texture.
      expect(cache.resolve(Object()), isNull);
      expect(cache.resolve('not a frame'), isNull);
    });

    test('a device that refuses the size refuses the frame', () {
      final allocator = _Allocator(maxSize: 8);
      final cache = GpuVideoImageCache(allocator);

      // Null, not a throw: the sink turns it into a named error that says
      // which backend and why, which is strictly more informative than an
      // exception thrown from inside a cache.
      expect(cache.resolve(_frame(VideoPixelFormat.nv12)), isNull);
      expect(cache.streamCount, 1);
      expect(allocator.live, 0);
    });
  });

  group('direct upload', () {
    // The optimisation, and the reason it is worth the extra texture format:
    // converting a 1920x1080 bgra8888 frame costs 11.4 ms of Dart time per
    // frame, against a 40 ms budget the decoder has already taken 21 ms out
    // of. Asking for a texture whose memory layout already matches makes the
    // per-frame cost of the colour work zero.

    test('a BGRA frame asks for a BGRA texture and converts nothing', () {
      final allocator = _Allocator();
      final cache = GpuVideoImageCache(allocator);

      final GpuTextureHandle? texture =
          cache.resolve(_frame(VideoPixelFormat.bgra8888));

      expect(texture!.format, GpuTextureFormat.bgra8888Premultiplied);
      expect(cache.conversionCount, 0);
      expect(cache.directUploadCount, 1);
      expect(cache.uploadCount, 1);
      // Nothing was staged, so a 1080p stream holds 8.29 MB less than it did.
      expect(cache.stagingBytes, 0);
    });

    test('the driver gets the decoder\'s own bytes, stride and all', () {
      final allocator = _Allocator(retainPixels: false);
      final cache = GpuVideoImageCache(allocator);
      // A padded stride, because a mapped platform surface routinely has one
      // and a repack to remove it would be the copy this route exists to
      // avoid.
      final VideoFrame frame = SyntheticPicture.ramp(16, 8)
          .encode(VideoPixelFormat.bgra8888, rowPadding: 12);
      final VideoPlane plane = frame.plane(0);

      cache.resolve(frame);

      final _Upload upload = allocator.lastUpload!;
      expect(upload.bytesPerRow, plane.bytesPerRow);
      expect(upload.bytesPerRow, greaterThan(16 * 4));
      // A view of the decoder's bytes, not a copy of them - which is the whole
      // claim, since a copy is the pass over the pixels this route exists to
      // avoid. Proved by writing through the plane and reading it back out of
      // what the driver was handed. (`identical` on `.buffer` cannot be used:
      // the VM hands out a fresh wrapper object on every access.)
      expect(allocator.lastPixels!.length, plane.bytes.length - plane.offset);
      plane.bytes[plane.offset + 5] = 0x5A;
      expect(allocator.lastPixels![5], 0x5A);
    });

    test('a YUV frame still converts, because it has to', () {
      final allocator = _Allocator();
      final cache = GpuVideoImageCache(allocator);

      final GpuTextureHandle? texture =
          cache.resolve(_frame(VideoPixelFormat.nv12));

      // No texture layout can hold subsampled chroma resolved through a colour
      // matrix, so this route is not an optimisation that was missed.
      expect(texture!.format, GpuTextureFormat.rgba8888Premultiplied);
      expect(cache.conversionCount, 1);
      expect(cache.directUploadCount, 0);
    });

    test('a device that refuses BGRA converts instead, and is asked once', () {
      final allocator = _Allocator(refuse: <GpuTextureFormat>{
        GpuTextureFormat.bgra8888Premultiplied,
      });
      final cache = GpuVideoImageCache(allocator);

      for (var sequence = 0; sequence < 5; sequence++) {
        final GpuTextureHandle? texture = cache.resolve(_frame(
          VideoPixelFormat.bgra8888,
          sequence: sequence,
        ));
        expect(texture!.format, GpuTextureFormat.rgba8888Premultiplied);
      }

      // GLES and WebGL 2 land here. Correct output, at the old price - and the
      // refusal is remembered, so it costs one thrown exception for the device
      // rather than one per frame.
      expect(cache.conversionCount, 5);
      expect(allocator.refusals, 1);
    });

    test('the two routes put identical bytes in the texture', () {
      // The parity that matters, and the bug it rules out: uploading BGRA
      // bytes into an RGBA texture swaps red and blue, which on dark footage
      // reads as a colour-grading choice rather than as a fault.
      final VideoFrame frame = _frame(VideoPixelFormat.bgra8888);

      final directAllocator = _Allocator();
      GpuVideoImageCache(directAllocator).resolve(frame);
      final convertAllocator = _Allocator();
      GpuVideoImageCache(convertAllocator, allowDirectUpload: false)
          .resolve(frame);

      final _Upload direct = directAllocator.lastUpload!;
      final _Upload converted = convertAllocator.lastUpload!;
      // Different texture layouts...
      expect(direct.texture.format, GpuTextureFormat.bgra8888Premultiplied);
      expect(converted.texture.format, GpuTextureFormat.rgba8888Premultiplied);
      // ...and, once each is read through the sampler its layout describes,
      // the same picture. The BGRA texture is sampled with B and R exchanged
      // by the texture unit, so the byte at index 0 of a BGRA texel is the
      // blue that index 2 of the RGBA texel holds.
      expect(_rgbaFromBgra(direct.pixels), converted.pixels);
    });

    test('an RGBA frame uploads directly into an RGBA texture', () {
      final allocator = _Allocator();
      final cache = GpuVideoImageCache(allocator);

      final GpuTextureHandle? texture =
          cache.resolve(_frame(VideoPixelFormat.rgba8888));

      // The layouts already agree, so this needed no new texture format at
      // all - it was being converted for nothing before.
      expect(texture!.format, GpuTextureFormat.rgba8888Premultiplied);
      expect(cache.conversionCount, 0);
      expect(cache.directUploadCount, 1);
    });

    test('a BGRA-ordered backend takes a BGRA frame straight', () {
      final allocator = _Allocator();
      final cache = GpuVideoImageCache(
        allocator,
        channelOrder: ImageChannelOrder.bgra,
      );

      final GpuTextureHandle? texture =
          cache.resolve(_frame(VideoPixelFormat.bgra8888));

      // No backend here declares its `rgba8888Premultiplied` to be BGRA, but
      // the enum permits it, so the pair is decided rather than assumed: the
      // frame and the texture already agree and nothing is asked of the
      // optional format.
      expect(texture!.format, GpuTextureFormat.rgba8888Premultiplied);
      expect(cache.conversionCount, 0);
      expect(cache.directUploadCount, 1);
    });

    test('a BGRA stream costs one texture and no conversion at all', () {
      final allocator = _Allocator();
      final cache = GpuVideoImageCache(allocator);

      GpuTextureHandle? first;
      for (var sequence = 0; sequence < 25; sequence++) {
        final GpuTextureHandle? texture = cache.resolve(_frame(
          VideoPixelFormat.bgra8888,
          sequence: sequence,
          seed: sequence,
        ));
        first ??= texture;
        expect(identical(texture, first), isTrue);
      }

      // One second of Windows h264 playback, in full. Everything the first
      // pass guaranteed still holds - one texture, no releases - and the
      // 11.4 ms per frame of colour work is now zero of them.
      expect(allocator.creates, 1);
      expect(allocator.releases, 0);
      expect(allocator.uploads, 25);
      expect(cache.directUploadCount, 25);
      expect(cache.conversionCount, 0);
      expect(cache.stagingBytes, 0);
    });

    test('allowDirectUpload: false forces the conversion route', () {
      final allocator = _Allocator();
      final cache = GpuVideoImageCache(allocator, allowDirectUpload: false);

      cache.resolve(_frame(VideoPixelFormat.bgra8888));

      expect(cache.conversionCount, 1);
      expect(cache.directUploadCount, 0);
      expect(allocator.lastUpload!.texture.format,
          GpuTextureFormat.rgba8888Premultiplied);
    });
  });

  group('cost per frame', () {
    test('a stream of frames costs one texture and one staging buffer', () {
      final allocator = _Allocator();
      final cache = GpuVideoImageCache(allocator);

      GpuTextureHandle? first;
      for (var sequence = 0; sequence < 25; sequence++) {
        final GpuTextureHandle? texture = cache.resolve(_frame(
          VideoPixelFormat.nv12,
          sequence: sequence,
          seed: sequence,
        ));
        expect(texture, isNotNull);
        first ??= texture;
        // The same texture object every frame. A new one per frame is the
        // leak this class exists to prevent: at 1080p it is 8.29 MB a frame,
        // never freed, because the backends' image caches never evict.
        expect(identical(texture, first), isTrue);
      }

      expect(allocator.creates, 1);
      expect(cache.createCount, 1);
      expect(allocator.uploads, 25);
      expect(cache.uploadCount, 25);
      expect(allocator.releases, 0);
      expect(cache.streamCount, 1);
      expect(cache.stagingBytes, 16 * 8 * 4);
    });

    test('the staging buffer is reused rather than reallocated', () {
      final allocator = _Allocator(retainPixels: false);
      final cache = GpuVideoImageCache(allocator);

      cache.resolve(_frame(VideoPixelFormat.nv12, sequence: 0));
      final Uint8List first = allocator.lastPixels!;
      cache.resolve(_frame(VideoPixelFormat.nv12, sequence: 1, seed: 3));
      final Uint8List second = allocator.lastPixels!;

      // Identical, not merely equal: `convertVideoFrameToRgba(into:)` wrote
      // over the same bytes, so a 25 fps stream allocates nothing at all.
      expect(identical(first, second), isTrue);
    });

    test('the same frame drawn twice converts once', () {
      final allocator = _Allocator();
      final cache = GpuVideoImageCache(allocator);
      final VideoFrame frame = _frame(VideoPixelFormat.nv12);

      final GpuTextureHandle? a = cache.resolve(frame);
      final GpuTextureHandle? b = cache.resolve(frame);

      // A picture-in-picture, or a still held under a transition: the display
      // list draws one frame twice and it must not cost two conversions of
      // megabytes.
      expect(identical(a, b), isTrue);
      expect(allocator.uploads, 1);
    });

    test('a re-presented frame at a new sequence re-uploads', () {
      final allocator = _Allocator();
      final cache = GpuVideoImageCache(allocator);
      final VideoFrame frame = _frame(VideoPixelFormat.nv12);

      cache.resolve(frame);
      cache.resolve(frame.atSequence(1));

      // Identity is `(streamId, sequence)`, so a paused playhead that
      // re-presents the same bytes at a new position is a new frame. Skipping
      // the upload here would be a freeze the ring's bookkeeping cannot see.
      expect(allocator.uploads, 2);
      expect(allocator.creates, 1);
    });

    test('two streams get one texture each', () {
      final allocator = _Allocator();
      final cache = GpuVideoImageCache(allocator);

      final GpuTextureHandle? a =
          cache.resolve(_frame(VideoPixelFormat.nv12, streamId: 1));
      final GpuTextureHandle? b =
          cache.resolve(_frame(VideoPixelFormat.nv12, streamId: 2));
      cache.resolve(_frame(VideoPixelFormat.nv12, streamId: 1, sequence: 1));

      expect(identical(a, b), isFalse);
      expect(cache.streamCount, 2);
      expect(allocator.creates, 2);
      expect(allocator.uploads, 3);
    });
  });

  group('lifetime', () {
    test('a resolution change releases the old texture exactly once', () {
      final allocator = _Allocator();
      final cache = GpuVideoImageCache(allocator);

      cache.resolve(_frame(VideoPixelFormat.nv12, width: 16, height: 8));
      cache.resolve(_frame(
        VideoPixelFormat.nv12,
        width: 32,
        height: 16,
        sequence: 1,
      ));

      // An adaptive source stepping up a rung. The old texture is the wrong
      // size for the new frame and has to go back to the driver, not linger.
      expect(allocator.creates, 2);
      expect(allocator.releases, 1);
      expect(allocator.live, 1);
      expect(cache.streamCount, 1);
      expect(cache.stagingBytes, 32 * 16 * 4);
    });

    test('a lost texture is recreated and never double-released', () {
      final allocator = _Allocator();
      final cache = GpuVideoImageCache(allocator);

      final GpuTextureHandle? lost =
          cache.resolve(_frame(VideoPixelFormat.nv12));
      (lost! as _Texture).valid = false;
      final GpuTextureHandle? fresh =
          cache.resolve(_frame(VideoPixelFormat.nv12, sequence: 1));

      expect(fresh, isNotNull);
      expect(identical(fresh, lost), isFalse);
      // The device already destroyed it: handing the dead handle back to
      // `releaseTexture` is a use-after-free in every backend that keeps a
      // native pointer in it.
      expect(allocator.releases, 0);
      expect(allocator.creates, 2);
    });

    test('clear releases every texture and drops every staging buffer', () {
      final allocator = _Allocator();
      final cache = GpuVideoImageCache(allocator);
      cache.resolve(_frame(VideoPixelFormat.nv12, streamId: 1));
      cache.resolve(_frame(VideoPixelFormat.nv12, streamId: 2));

      cache.clear();

      expect(allocator.releases, 2);
      expect(allocator.live, 0);
      expect(cache.streamCount, 0);
      expect(cache.stagingBytes, 0);
    });

    test('discardTextures forgets without releasing', () {
      final allocator = _Allocator();
      final cache = GpuVideoImageCache(allocator);
      cache.resolve(_frame(VideoPixelFormat.nv12));

      cache.discardTextures();
      cache.resolve(_frame(VideoPixelFormat.nv12, sequence: 1));

      // For a device that has already destroyed its textures. A video stream
      // needs no re-upload policy of its own: the next frame is arriving.
      expect(allocator.releases, 0);
      expect(allocator.creates, 2);
    });
  });

  group('through the raster sink', () {
    test('a video frame batches a textured quad instead of throwing', () {
      final allocator = _Allocator();
      final resolver = _VideoResolver(GpuVideoImageCache(allocator));
      final sink = GpuRasterSink(
        batcher: GpuBatcher()..beginFrame(),
        backendName: 'test',
        imageResolver: resolver,
      );

      sink.drawDeviceImage(
        _frame(VideoPixelFormat.nv12),
        const Rect.fromLTRB(0, 0, 16, 8),
        const Rect.fromLTRB(0, 0, 160, 80),
        _wideClip,
        _opaque,
      );

      // The regression, end to end through the code that used to raise:
      // one batch, sampling the texture the video cache produced.
      expect(sink.batcher.batchCount, 1);
      expect(allocator.creates, 1);
    });

    test('without a video-aware resolver it is still refused by name', () {
      final sink = GpuRasterSink(
        batcher: GpuBatcher()..beginFrame(),
        backendName: 'direct3d11',
        imageResolver: _NullResolver(),
      );

      // The behaviour being replaced, kept as a test so the error stays honest
      // for a device that genuinely cannot upload: refused out loud, never a
      // silently missing picture.
      expect(
        () => sink.drawDeviceImage(
          _frame(VideoPixelFormat.nv12),
          const Rect.fromLTRB(0, 0, 16, 8),
          const Rect.fromLTRB(0, 0, 16, 8),
          _wideClip,
          _opaque,
        ),
        throwsA(isA<UnsupportedCapabilityError>()),
      );
    });
  });

  group('every backend delegates', () {
    // Read over the sources, the way `test/architecture/layering_test.dart`
    // does. A device is needed to *run* any of these caches and there is no
    // driver here - but the one line that decides whether video is refused is
    // a source fact, and a backend added later that forgets it should fail
    // this rather than fail silently on a user's machine.
    const Map<String, String> caches = <String, String>{
      'lib/src/rendering/gpu/d3d11/d3d11_backend.dart': 'D3d11ImageCache',
      'lib/src/rendering/gpu/gl/gl_backend.dart': 'GlImageCache',
      'lib/src/rendering/gpu/webgl/webgl_backend.dart': 'WebGlImageCache',
      'lib/src/rendering/gpu/webgpu/webgpu_backend.dart': 'WebGpuImageCache',
      'lib/src/rendering/gpu/vulkan/vulkan_backend.dart': 'VulkanImageCache',
      'lib/src/backends/win32/d3d12/d3d12_device.dart': 'D3d12ImageCache',
    };

    // Every device that can allocate a texture has to answer for the new
    // format, one way or the other: map it to a native BGRA format, or refuse
    // it by name. The third possibility - ignoring it and creating an RGBA
    // texture - is the red/blue swap, and it is what a `format == alpha8 ? a :
    // b` ternary would have done silently.
    const Map<String, String> allocators = <String, String>{
      'lib/src/rendering/gpu/d3d11/d3d11_backend.dart':
          'dxgiFormatB8G8R8A8Unorm',
      'lib/src/backends/win32/d3d12/d3d12_device.dart':
          'dxgiFormatB8G8R8A8Unorm',
      'lib/src/rendering/gpu/gl/gl_backend.dart': 'glBgra',
      'lib/src/rendering/gpu/vulkan/vulkan_backend.dart':
          'VK_FORMAT_B8G8R8A8_UNORM',
      'lib/src/rendering/gpu/webgpu/webgpu_backend.dart': 'bgra8unorm',
      'lib/src/rendering/gpu/metal/metal_bindings.dart': 'bgra8Unorm',
      // WebGL 2 is ES 3.0, so this one refuses rather than maps - and must say
      // so out loud rather than by omission.
      'lib/src/rendering/gpu/webgl/webgl_backend.dart':
          'has no BGRA upload format',
    };

    for (final MapEntry<String, String> entry in allocators.entries) {
      test('${entry.key.split('/').last} answers for a BGRA texture', () {
        final String source = File(entry.key).readAsStringSync();
        expect(
          source.contains('GpuTextureFormat.bgra8888Premultiplied'),
          isTrue,
          reason: '${entry.key} never names the BGRA texture format, so it '
              'would create an RGBA texture and swap red with blue',
        );
        expect(
          source.contains(entry.value),
          isTrue,
          reason: '${entry.key} names the BGRA texture format but never '
              '"${entry.value}", so it neither maps it nor refuses it',
        );
      });
    }

    for (final MapEntry<String, String> entry in caches.entries) {
      test('${entry.value} routes a non-Framebuffer to the video cache', () {
        final String source = File(entry.key).readAsStringSync();
        expect(
          source.contains('GpuVideoImageCache('),
          isTrue,
          reason: '${entry.value} has no video cache, so a VideoFrame '
              'resolves to null and closes the window',
        );
        expect(
          source.contains('if (image is! Framebuffer) return null;'),
          isFalse,
          reason: '${entry.value} still refuses every non-Framebuffer image, '
              'which is exactly what refused VideoFrame',
        );
        expect(
          source.contains('if (image is! Framebuffer) '
              'return _video.resolve(image);'),
          isTrue,
          reason: '${entry.value} does not delegate to the video cache',
        );
      });
    }
  });
}

/// A resolver that answers only for video, which is what a backend's cache
/// does once its still-image path has declined.
final class _VideoResolver implements GpuImageResolver {
  _VideoResolver(this.video);

  final GpuVideoImageCache video;

  @override
  GpuTextureHandle? resolve(Object image) => video.resolve(image);
}

/// The device that cannot upload anything - the state every backend was in.
final class _NullResolver implements GpuImageResolver {
  @override
  GpuTextureHandle? resolve(Object image) => null;
}

final class _Texture implements GpuTextureHandle {
  _Texture({
    required this.id,
    required this.width,
    required this.height,
    required this.format,
    required this.filter,
  });

  @override
  final int id;
  @override
  final int width;
  @override
  final int height;
  @override
  final GpuTextureFormat format;
  @override
  final GpuTextureFilter filter;

  bool valid = true;

  @override
  bool get isValid => valid;
}

/// The same picture a BGRA texture holds, re-laid-out the way an RGBA texture
/// would hold it.
///
/// This is what the texture unit does for free when it samples
/// `DXGI_FORMAT_B8G8R8A8_UNORM`, written out so the parity test can compare
/// two uploads that are deliberately in different layouts. If the direct route
/// ever put RGBA bytes in a BGRA texture, this turns them into BGRA and the
/// comparison fails - which is the swap that would otherwise ship.
Uint8List _rgbaFromBgra(Uint8List bgra) {
  final Uint8List out = Uint8List(bgra.length);
  for (var i = 0; i + 3 < bgra.length; i += 4) {
    out[i] = bgra[i + 2];
    out[i + 1] = bgra[i + 1];
    out[i + 2] = bgra[i];
    out[i + 3] = bgra[i + 3];
  }
  return out;
}

final class _Upload {
  const _Upload({
    required this.texture,
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    required this.pixels,
    required this.bytesPerRow,
  });

  final _Texture texture;
  final int x;
  final int y;
  final int width;
  final int height;
  final Uint8List pixels;
  final int bytesPerRow;
}

final class _Allocator implements GpuTextureAllocator {
  _Allocator({
    this.maxSize = 4096,
    this.retainPixels = true,
    this.refuse = const <GpuTextureFormat>{},
  });

  /// Textures larger than this are refused the way a real device refuses one
  /// past `D3D11_REQ_TEXTURE2D_U_OR_V_DIMENSION`.
  final int maxSize;

  /// Whether [lastUpload] copies the staging bytes. The reuse test needs the
  /// original object, every other test wants a snapshot.
  final bool retainPixels;

  /// Formats this fake device does not have - GLES and WebGL 2 are in exactly
  /// this position for [GpuTextureFormat.bgra8888Premultiplied].
  final Set<GpuTextureFormat> refuse;

  int creates = 0;
  int uploads = 0;
  int releases = 0;

  /// How many times a format was refused. It has to stay at one however many
  /// frames go by, or the fallback is throwing an exception per frame.
  int refusals = 0;
  int get live => creates - releases;
  _Upload? lastUpload;
  Uint8List? lastPixels;

  @override
  GpuTextureHandle createTexture({
    required int width,
    required int height,
    required GpuTextureFormat format,
    GpuTextureFilter filter = GpuTextureFilter.nearest,
  }) {
    if (refuse.contains(format)) {
      refusals++;
      throw UnsupportedCapabilityError(
        backendName: 'test',
        capability: Capability.gpuPresentation,
        detail: 'this device has no ${format.name} textures',
      );
    }
    if (width > maxSize || height > maxSize) {
      throw UnsupportedCapabilityError(
        backendName: 'test',
        capability: Capability.gpuPresentation,
        detail: 'a ${width}x$height texture is over the $maxSize limit',
      );
    }
    creates++;
    return _Texture(
      id: creates,
      width: width,
      height: height,
      format: format,
      filter: filter,
    );
  }

  @override
  void uploadRegion(
    GpuTextureHandle texture, {
    required int x,
    required int y,
    required int width,
    required int height,
    required Uint8List pixels,
    required int bytesPerRow,
  }) {
    uploads++;
    lastPixels = pixels;
    lastUpload = _Upload(
      texture: texture as _Texture,
      x: x,
      y: y,
      width: width,
      height: height,
      pixels: retainPixels ? Uint8List.fromList(pixels) : pixels,
      bytesPerRow: bytesPerRow,
    );
  }

  @override
  void releaseTexture(GpuTextureHandle texture) {
    releases++;
    (texture as _Texture).valid = false;
  }
}
