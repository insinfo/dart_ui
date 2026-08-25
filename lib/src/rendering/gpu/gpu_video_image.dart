/// The one place a decoded video frame becomes a GPU texture.
///
/// Every `GpuImageResolver` in this repository used to open with
/// `if (image is! Framebuffer) return null;`, and a [VideoFrame] is not a
/// `Framebuffer`. The null travelled up to `GpuRasterSink.drawDeviceImage`,
/// which turned it into an `UnsupportedCapabilityError` naming
/// `gpuPresentation` - so opening a video closed the window on every
/// accelerated backend while the CPU renderer drew the same list perfectly.
/// That asymmetry is what this file removes, once, instead of six times.
///
/// ## The cheapest frame is the one nobody converts
///
/// There are two routes to a texture here, and which one a frame takes is the
/// difference between playing at 25 fps and not:
///
///   * **Direct upload.** The frame is already packed 32-bit colour and some
///     texture format on this device has exactly that byte layout, so the
///     decoder's own bytes are handed to `uploadRegion` unread. Zero passes
///     over the pixels in Dart.
///   * **Conversion.** Everything else - every YUV layout, and a packed frame
///     on a device that refuses the matching texture format - goes through
///     [convertVideoFrameToRgba] into a reused staging buffer.
///
/// The measurement that put the direct route here, on the 1920x1080 h264 file
/// this was tuned against, per frame:
///
///     convertVideoFrameToRgba (generic)   11.40 ms
///     convert to bgra order (no swizzle)  10.96 ms
///     32-bit swizzle loop                  5.14 ms
///     whole-plane setRange                 0.60 ms
///     direct upload (no Dart pass at all)  0.00 ms
///
/// Two things are worth reading off that table, because both are unobvious.
/// First, **the channel swap is not the cost**: asking the converter for BGRA
/// output from a BGRA source makes it a straight copy and it still costs
/// 10.96 ms, so a dedicated swizzle path would have bought 6 ms of the 11.4
/// and left the rest. The cost is the per-pixel generic loop, which is written
/// for YUV and pays for that generality on every format. Second, Windows Media
/// Foundation decodes h264 straight to `bgra8888`, so on the platform where
/// this mattered the frame needs *no* conversion at all - only a texture whose
/// memory layout matches, which is
/// [GpuTextureFormat.bgra8888Premultiplied].
///
/// A device may refuse that format (GLES and WebGL 2 have no BGRA upload
/// format), and refusal is a normal answer: the stream falls back to
/// conversion, once, and remembers - see [_refusedFormats], because throwing
/// and catching twenty-five times a second is its own kind of slow.
///
/// ## Why the texture lives here and not in the backends' image caches
///
/// The obvious repair for the original bug is to convert the frame to a
/// `Framebuffer` and hand it to the cache that is already there. It does not
/// survive contact with a twenty-five frame per second stream: those caches
/// are keyed by image *identity* (an [Expando], or an identity `Map`) and they
/// never evict, by documented design - "an eviction policy needs a frame
/// budget this framework does not measure yet". A fresh `Framebuffer` per
/// decoded frame is therefore a fresh entry and a fresh driver texture per
/// frame, retained forever: at 1080p that is 8.29 MB of device memory a frame,
/// a quarter of a gigabyte in ten seconds, plus a `createTexture` on the
/// frame-critical path.
///
/// Converting into the *same* `Framebuffer` object each time does not work
/// either, and fails in the opposite direction: the cache would find its
/// entry, see a live texture and return it without re-uploading, so the video
/// would freeze on its first frame.
///
/// So the streaming case gets its own bookkeeping, which is the one thing
/// those caches cannot express - a texture whose *contents* change while its
/// identity does not:
///
///   * **One texture per stream**, not per frame. [VideoFrame.streamId] is
///     documented as the key a GPU texture is held under precisely because it
///     is "what stops sixty allocations a second". A texture is created when a
///     stream is first seen, and again only if the frame size or layout
///     changes or the device was lost.
///   * **One staging buffer per stream** on the conversion route, reused
///     through [convertVideoFrameToRgba]'s `into:` parameter - and *no*
///     staging buffer at all on the direct route, which is the point of it.
///   * **Re-upload keyed on [VideoFrame.sequence]**, which is what identity
///     means for a frame ("Identity is `(streamId, sequence)`, never the
///     bytes"). Drawing the same frame twice in one list - a
///     picture-in-picture, a still held under a transition - uploads once,
///     exactly like `cpu_renderer.dart`'s single-slot cache.
///
/// Nothing here holds a [VideoFrame] alive. The cache remembers two integers
/// and, on the conversion route, its own staging bytes - so a decoder's ring
/// buffer can recycle a frame the moment it has been drawn.
///
/// ## Channel order is the backend's answer, not this file's
///
/// [GpuTextureFormat.rgba8888Premultiplied] says the channel order "is the
/// backend's business, matching `PixelFormat`", so [channelOrder] is a
/// constructor argument and every backend states its own - the same decision
/// `cpu_renderer.dart` makes from its target's `PixelFormat`. It is read
/// twice: it is the order the conversion writes, *and* it is what decides
/// whether a packed frame can skip the conversion entirely. All six backends
/// in this repository create image textures as `R8G8B8A8`, so they all pass
/// [ImageChannelOrder.rgba].
///
/// ## Portability
///
/// [convertVideoFrameToRgba] is the portable reference converter, not the FFI
/// one in `video_color_conversion_native.dart`. This file is reachable from
/// `lib/dart_ui.dart`, which the web backend compiles, so importing the native
/// converter here would break that build - see the note at the bottom of
/// `video_color_conversion.dart`.
library;

import 'dart:typed_data';

import '../../foundation/diagnostics.dart';
import '../../graphics/image/decoded_image.dart';
import '../../graphics/video/video_color_conversion.dart';
import '../../graphics/video/video_frame.dart';
import 'gpu_texture.dart';

/// Converts decoded video frames into textures for one device, reusing both
/// the texture and the conversion buffer across the frames of a stream, and
/// skipping the conversion altogether where the layouts already agree.
///
/// Shared by every backend's `GpuImageResolver`: each one delegates to
/// [resolve] when the display list interned a [VideoFrame], and keeps its own
/// still-image path unchanged.
final class GpuVideoImageCache {
  GpuVideoImageCache(
    this._allocator, {
    this.channelOrder = ImageChannelOrder.rgba,
    this.filter = GpuTextureFilter.linear,
    this.allowDirectUpload = true,
  });

  final GpuTextureAllocator _allocator;

  /// The byte order this device's `rgba8888Premultiplied` textures are
  /// sampled in. See the library comment: the answer belongs to the backend,
  /// not to video.
  final ImageChannelOrder channelOrder;

  /// Linear, for the reason every image cache gives: a video is drawn at
  /// whatever scale the layout produced, and nearest sampling there is the
  /// blocky, shimmering resampling that reads as a renderer bug.
  final GpuTextureFilter filter;

  /// Whether a packed frame may skip the conversion when a texture format
  /// matches its layout.
  ///
  /// False forces every frame through [convertVideoFrameToRgba]. It exists so
  /// a test can drive both routes over the same frame and compare the bytes
  /// that reach the driver - the parity proof that the direct route does not
  /// quietly swap red and blue, which on dark footage nobody would notice.
  final bool allowDirectUpload;

  final Map<int, _VideoStream> _streams = <int, _VideoStream>{};

  /// Texture formats this device has already refused.
  ///
  /// Remembered rather than rediscovered: a refusal is a thrown exception, and
  /// a stream would raise and catch one per frame otherwise. A device does not
  /// change its mind about a format, so one answer is enough for the process.
  final Set<GpuTextureFormat> _refusedFormats = <GpuTextureFormat>{};

  /// How many streams hold a texture. One per concurrent video, never one per
  /// frame - the invariant this class exists to keep.
  int get streamCount => _streams.length;

  /// Textures created since construction. It stops rising once each stream is
  /// warm, and a test asserts exactly that.
  int get createCount => _createCount;
  int _createCount = 0;

  /// Frames uploaded. Rises once per *new* frame, so a frame drawn twice in
  /// one list costs one.
  int get uploadCount => _uploadCount;
  int _uploadCount = 0;

  /// Frames that had to be converted - the expensive ones. On a Windows
  /// `bgra8888` stream this stays at zero, which is the whole optimisation;
  /// on a YUV stream it equals [uploadCount].
  int get conversionCount => _conversionCount;
  int _conversionCount = 0;

  /// Frames handed to the driver without a single Dart pass over the pixels.
  int get directUploadCount => _directUploadCount;
  int _directUploadCount = 0;

  /// Bytes of staging this cache keeps alive - one full RGBA frame per stream
  /// on the conversion route, and nothing at all on the direct route.
  int get stagingBytes {
    var bytes = 0;
    for (final _VideoStream stream in _streams.values) {
      bytes += stream.staging?.length ?? 0;
    }
    return bytes;
  }

  /// The texture holding [image], or null when [image] is not a [VideoFrame]
  /// or the device refused a texture that large.
  ///
  /// Null for a non-frame is what lets a caller write the delegation as one
  /// line at the top of its own `resolve` and keep the resolver's contract:
  /// null means "this device cannot draw it", which the sink turns into a
  /// named error rather than a wrong picture.
  GpuTextureHandle? resolve(Object image) {
    if (image is! VideoFrame) return null;
    final int width = image.width;
    final int height = image.height;
    if (width <= 0 || height <= 0) return null;

    final _VideoStream stream = _streams[image.streamId] ??= _VideoStream();

    // Which texture layout would let this frame skip the conversion, if the
    // device will give us one. Null means the frame must be converted whatever
    // the device says - every YUV layout lands here.
    final GpuTextureFormat? direct =
        allowDirectUpload ? _directFormatFor(image.format.pixelFormat) : null;

    // A texture is discarded for three reasons, and none of them happens per
    // frame: the stream changed resolution (an adaptive source stepping up a
    // rung), the device was lost and took the texture with it, or the route
    // changed because the device refused the direct format on the first try.
    GpuTextureHandle? texture = stream.texture;
    if (texture != null &&
        (!texture.isValid ||
            texture.width != width ||
            texture.height != height)) {
      if (texture.isValid) _allocator.releaseTexture(texture);
      stream.texture = null;
      stream.uploadedSequence = null;
      texture = null;
    }

    if (texture != null && stream.uploadedSequence == image.sequence) {
      // The same frame, drawn again. Uploading it a second time would be a
      // full pass over megabytes to produce the bytes the texture holds.
      return texture;
    }

    if (texture == null) {
      // The direct layout first, the conversion layout as the fallback. A
      // refusal is remembered so this costs one thrown exception per device
      // and per format, not one per frame.
      texture = direct == null ? null : _tryCreate(direct, width, height);
      texture ??= _tryCreate(
        GpuTextureFormat.rgba8888Premultiplied,
        width,
        height,
      );
      if (texture == null) return null;
      stream.texture = texture;
      _createCount++;
    }

    if (direct != null && texture.format == direct) {
      // The decoder's own bytes, unread. `uploadRegion` carries the stride
      // explicitly, so a plane whose rows are padded - which a mapped platform
      // surface routinely is - needs no repack either.
      final VideoPlane plane = image.plane(0);
      _allocator.uploadRegion(
        texture,
        x: 0,
        y: 0,
        width: width,
        height: height,
        pixels: Uint8List.sublistView(plane.bytes, plane.offset),
        bytesPerRow: plane.bytesPerRow,
      );
      stream.staging = null;
      _directUploadCount++;
    } else {
      final int bytesPerRow = width * 4;
      final int required = bytesPerRow * height;
      Uint8List? staging = stream.staging;
      if (staging == null || staging.length != required) {
        staging = Uint8List(required);
        stream.staging = staging;
      }
      // Opacity is deliberately *not* folded in here, unlike the CPU path: the
      // batcher modulates the paint's alpha into the quad's vertex colour, so
      // baking it into the texels would apply it twice - and would make the
      // texture's contents depend on the paint, which turns one texture per
      // stream back into one per draw.
      convertVideoFrameToRgba(
        image,
        order: channelOrder,
        into: staging,
        bytesPerRow: bytesPerRow,
      );
      _conversionCount++;
      _allocator.uploadRegion(
        texture,
        x: 0,
        y: 0,
        width: width,
        height: height,
        pixels: staging,
        bytesPerRow: bytesPerRow,
      );
    }
    stream.uploadedSequence = image.sequence;
    _uploadCount++;
    return texture;
  }

  /// The texture layout whose bytes are identical to a [pixel] frame's, or
  /// null when no conversion can be avoided for it.
  ///
  /// Only the packed 32-bit layouts can qualify: a YUV frame has to be
  /// resolved through the colour matrix whatever texture it lands in. Which
  /// packed layout matches depends on [channelOrder], because that is what the
  /// backend says its `rgba8888Premultiplied` texture holds - so the frame
  /// order and the texture order are compared, never assumed equal.
  ///
  /// Premultiplication is not a difference here. The conversion route copies
  /// the source alpha through unchanged for a packed frame (see
  /// `_convertPackedRgb`), so the two routes produce identical bytes, which is
  /// what the parity test asserts.
  GpuTextureFormat? _directFormatFor(VideoPixelFormat pixel) =>
      switch ((pixel, channelOrder)) {
        (VideoPixelFormat.rgba8888, ImageChannelOrder.rgba) ||
        (VideoPixelFormat.bgra8888, ImageChannelOrder.bgra) =>
          GpuTextureFormat.rgba8888Premultiplied,
        // The Windows case: Media Foundation decodes h264 to BGRA and every
        // backend here samples RGBA, so the swap is pushed into the texture
        // unit, where it is free.
        (VideoPixelFormat.bgra8888, ImageChannelOrder.rgba) =>
          GpuTextureFormat.bgra8888Premultiplied,
        // No backend declares a BGRA-ordered `rgba8888Premultiplied` today, so
        // an RGBA frame on one would have to be converted. Stated rather than
        // defaulted, so the pair is a decision and not an oversight.
        (VideoPixelFormat.rgba8888, ImageChannelOrder.bgra) => null,
        (VideoPixelFormat.nv12, _) ||
        (VideoPixelFormat.i420, _) ||
        (VideoPixelFormat.yuy2, _) =>
          null,
      };

  /// A texture in [format], or null when this device refuses that format or
  /// that size.
  ///
  /// The refusal is cached in [_refusedFormats] rather than rediscovered,
  /// which is what keeps a fallback from costing an exception a frame. Size
  /// refusals are not cached: they are a property of the frame, not of the
  /// device, and a stream that steps down a rung must be able to succeed.
  GpuTextureHandle? _tryCreate(GpuTextureFormat format, int width, int height) {
    if (_refusedFormats.contains(format)) return null;
    try {
      return _allocator.createTexture(
        width: width,
        height: height,
        format: format,
        filter: filter,
      );
    } on UnsupportedCapabilityError {
      // Either the format or the size. Remembering the refusal for a format
      // this device is expected to have - `rgba8888Premultiplied` - would
      // strand every later stream over one oversized frame, so only the
      // optional layout is remembered.
      if (format != GpuTextureFormat.rgba8888Premultiplied) {
        _refusedFormats.add(format);
      }
      return null;
    }
  }

  /// Releases every texture and drops every staging buffer.
  ///
  /// Called from the owning image cache's own `clear`/`dispose`, so a video
  /// texture dies at the same deterministic point an image texture does rather
  /// than whenever a finaliser gets around to it.
  ///
  /// What a device has refused is *not* forgotten: it is a fact about the
  /// device, and rediscovering it would cost a thrown exception on the first
  /// frame after every clear.
  void clear() {
    for (final _VideoStream stream in _streams.values) {
      final GpuTextureHandle? texture = stream.texture;
      if (texture != null && texture.isValid) {
        _allocator.releaseTexture(texture);
      }
      stream.texture = null;
      stream.staging = null;
      stream.uploadedSequence = null;
    }
    _streams.clear();
  }

  /// Forgets every texture *without* releasing it, for a device that has
  /// already destroyed them - a lost device, a recreated context.
  ///
  /// The next [resolve] recreates and re-uploads from the next decoded frame,
  /// which is the whole recovery a video stream needs: unlike a still image,
  /// its source is arriving anyway, so there is nothing to retain and nothing
  /// that can be stranded.
  void discardTextures() {
    for (final _VideoStream stream in _streams.values) {
      stream.texture = null;
      stream.uploadedSequence = null;
    }
  }
}

/// One video stream's texture and, on the conversion route, staging buffer.
final class _VideoStream {
  GpuTextureHandle? texture;

  /// The RGBA bytes the last conversion wrote, reused by the next one. Null on
  /// the direct route, which converts nothing and stages nothing.
  Uint8List? staging;

  /// [VideoFrame.sequence] of the frame currently in [texture], or null when
  /// the texture holds nothing yet.
  int? uploadedSequence;
}
