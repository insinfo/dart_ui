/// Two different capabilities that the word "external texture" has been doing
/// duty for, separated and named.
///
/// `RendererCapabilities.supportsExternalTextures` is false in every backend
/// in this repository, and `gl_backend.dart` says in prose what it means by
/// it: *foreign* textures - a texture object the driver already owns, created
/// by somebody else, that this renderer would sample without ever having
/// uploaded it. That reading is kept. It is [GpuForeignTextureImporter] here,
/// and it stays optional, because it is the one that needs a platform interop
/// handle (a DXGI shared handle, an `EGLImage`, an `IOSurface`) and can
/// therefore only ever work on some pairs of producer and device.
///
/// What a video editor needs before any of that is a different thing entirely,
/// and it had no name at all: a texture the renderer *does* own, whose
/// contents are replaced every frame from bytes the CPU can see. That is
/// [GpuVideoTextureAllocator], and it works on every backend, because
/// uploading bytes is the one thing every graphics API can do.
///
/// Conflating them is why nothing could draw a video frame. A reader looking
/// for "can this device show video" found a false boolean about interop and
/// stopped.
///
/// ## What the streaming contract has to express, and why each part is here
///
///   * **Creation by format and size, once per stream.** A `createTexture`
///     per frame is a driver allocation, a residency change and a descriptor
///     write sixty times a second; the whole point of
///     [GpuStreamingVideoTexture] is that it outlives the frames that flow
///     through it. That is why the allocator takes a [VideoFrameFormat] and
///     not a [VideoFrame].
///
///   * **Whole or partial update, at predictable cost.** [uploadFrame] takes
///     an optional region, which a source that knows what changed - a
///     compositor overlaying a caption, a paint tool touching one corner -
///     uses to upload a fraction of the bytes. The region is snapped outward
///     to whole chroma samples by [VideoRegion.alignedTo]; see there for why a
///     4:2:0 frame cannot start a partial upload on an odd row.
///
///   * **Buffering, so the upload does not wait for the GPU.** A texture the
///     GPU is still reading cannot be written without either a stall or a
///     tear. [GpuStreamingVideoTexture.bufferCount] is how many sets of plane
///     textures rotate: one means "stall or tear", two is the working default,
///     three covers a driver that keeps a frame in flight longer than one
///     present. The rotation itself is [VideoUploadRing], which is
///     backend-neutral and refuses to hand out a buffer that has not retired
///     rather than overwriting it.
///
///   * **Deterministic release.** [releaseStreamingTexture] frees every buffer
///     of every plane at a point the caller chose. Nothing here is finalised
///     by the garbage collector: a texture is device memory, a video editor
///     opens and closes streams constantly, and "eventually" is not an
///     acceptable answer for a hundred megabytes.
library;

import '../../../graphics/video/video_frame.dart';
import 'video_upload_ring.dart';

/// What one plane's texture holds, from a sampler's point of view.
///
/// A separate enum from `GpuTextureFormat` rather than three more members on
/// it, and the reason is the argument that type already makes for staying at
/// three methods: every backend implements it before it can draw its first
/// rectangle. Two-channel textures are needed by exactly one thing in this
/// renderer - [VideoPixelFormat.nv12]'s interleaved chroma - and making every
/// backend answer for `rg8` in order to fill a rectangle would be paying for
/// video everywhere including the backends that will never show any.
enum VideoPlaneSampleFormat {
  /// One byte per sample: a luma plane, or a planar chroma plane.
  r8,

  /// Two bytes per sample: NV12's interleaved `U, V`.
  rg8,

  /// Four bytes per sample: a packed YUY2 quadruple, or an RGBA pixel.
  ///
  /// A YUY2 plane is *not* colour, it is four unrelated bytes that happen to
  /// travel four at a time. The shader unpacks them; the texture format only
  /// has to deliver them unchanged, which is why filtering on such a texture
  /// must be nearest - interpolating `Y0` against `U` is meaningless.
  rgba8;

  int get bytesPerSample => switch (this) {
        r8 => 1,
        rg8 => 2,
        rgba8 => 4,
      };

  /// The sample format plane [index] of [format] needs.
  static VideoPlaneSampleFormat forPlane(VideoPixelFormat format, int index) =>
      switch (format.planeGeometry(index).bytesPerSample) {
        1 => r8,
        2 => rg8,
        _ => rgba8,
      };
}

/// One plane of one buffer: a name a backend can bind, and its extent.
abstract interface class VideoPlaneTexture {
  /// Unique within one device. Never zero, which every backend in this tree
  /// uses to mean "nothing bound".
  int get id;

  /// In samples, not in frame pixels: a 1920x1080 NV12 frame's chroma plane is
  /// 960x540 here.
  int get width;
  int get height;

  VideoPlaneSampleFormat get sampleFormat;

  /// False once the device was lost or the owning texture was released.
  bool get isValid;
}

/// A set of plane textures, rotated over [bufferCount] buffers.
///
/// The handle a renderer holds for a whole video stream. It is created once
/// from a [VideoFrameFormat] and then fed frames; what changes per frame is
/// which buffer [plane] answers with.
abstract interface class GpuStreamingVideoTexture {
  /// The layout every frame uploaded into this must share. A frame whose
  /// [VideoFrameFormat.hasSameLayoutAs] disagrees is refused by [uploadFrame]
  /// rather than being stretched or reinterpreted.
  VideoFrameFormat get format;

  /// How many independent sets of plane textures rotate. One or more.
  int get bufferCount;

  /// The stream this belongs to; [VideoFrame.streamId] of every frame that may
  /// be uploaded into it.
  int get streamId;

  int get planeCount;

  /// Plane [index] of the buffer the last completed [uploadFrame] wrote.
  ///
  /// This is the one a draw call binds. It changes as buffers rotate, which is
  /// why a backend must read it at draw time and must not cache the id across
  /// frames.
  VideoPlaneTexture plane(int index);

  /// Plane [index] of buffer [buffer]. For a backend that records a command
  /// list ahead of the upload, and for tests.
  VideoPlaneTexture planeOfBuffer(int buffer, int index);

  /// [VideoFrame.sequence] of the frame [plane] currently answers with, or -1
  /// before the first upload.
  int get frontSequence;

  /// The ring that decides which buffer the next upload may use. Exposed so
  /// the code that knows when the GPU finished with a frame -
  /// [VideoUploadRing.retire] - can say so without going through the
  /// allocator.
  VideoUploadRing get ring;

  bool get isValid;
}

/// What one [uploadFrame] actually did.
///
/// Returned rather than kept internally because it is the measurement: a
/// caller that wants to know whether its partial-update logic is working reads
/// [bytesUploaded] against the frame's packed size, and the benchmark in
/// `benchmark/video_upload_benchmark.dart` reads it directly.
final class VideoUploadReceipt {
  const VideoUploadReceipt({
    required this.buffer,
    required this.sequence,
    required this.region,
    required this.bytesUploaded,
    required this.wasPartial,
  });

  /// Which buffer of the ring received the frame.
  final int buffer;

  /// [VideoFrame.sequence] of the frame that was uploaded.
  final int sequence;

  /// The region actually written, after alignment. Never smaller than the
  /// region asked for.
  final VideoRegion region;

  final int bytesUploaded;

  /// False when the whole frame was written, whatever the caller asked for.
  final bool wasPartial;

  @override
  String toString() => 'VideoUploadReceipt(buffer $buffer, #$sequence, '
      '$region, $bytesUploaded bytes, '
      '${wasPartial ? 'partial' : 'full'})';
}

/// What a device can do with video, answered per format rather than as one
/// boolean.
///
/// Per format because the answers genuinely differ: a device may sample two
/// separate planes happily and have no two-channel texture format for NV12's
/// interleaved chroma, and a caller that is told only "yes" would find out by
/// getting a black frame.
final class VideoTextureCapabilities {
  const VideoTextureCapabilities({
    required this.streamingFormats,
    required this.supportsPartialUpload,
    required this.maxBufferCount,
    required this.supportsForeignImport,
  });

  /// The formats [GpuVideoTextureAllocator.createStreamingTexture] accepts.
  /// Empty means this device cannot stream video at all, which is a legitimate
  /// answer for a device that has no two-channel or single-channel texture
  /// format.
  final Set<VideoPixelFormat> streamingFormats;

  /// Whether a region smaller than the frame is honoured. When false,
  /// [GpuVideoTextureAllocator.uploadFrame] still accepts a region and simply
  /// writes everything - the receipt says so through
  /// [VideoUploadReceipt.wasPartial], and a caller must read that rather than
  /// assume its own region was used.
  final bool supportsPartialUpload;

  /// The largest [GpuStreamingVideoTexture.bufferCount] this device will
  /// allocate.
  final int maxBufferCount;

  /// Whether [GpuForeignTextureImporter] is implemented. The honest reading of
  /// `RendererCapabilities.supportsExternalTextures`, and false everywhere
  /// today.
  final bool supportsForeignImport;

  bool supportsStreaming(VideoPixelFormat format) =>
      streamingFormats.contains(format);

  static const VideoTextureCapabilities none = VideoTextureCapabilities(
    streamingFormats: <VideoPixelFormat>{},
    supportsPartialUpload: false,
    maxBufferCount: 0,
    supportsForeignImport: false,
  );
}

/// A device that can hold a video stream in GPU memory and be fed frames.
///
/// Four methods, mirroring the shape of `GpuTextureAllocator`: create, write,
/// present, destroy. Anything richer - a mipmapped video texture, an
/// asynchronous upload queue, a format conversion at upload time - is a
/// backend detail that no code above this line needs, and putting it here
/// would mean a second backend implementing it before it could show its first
/// frame.
abstract interface class GpuVideoTextureAllocator {
  VideoTextureCapabilities get videoCapabilities;

  /// Allocates [bufferCount] sets of plane textures for [format].
  ///
  /// [streamId] is the identity the caller will key this on; it is stored so
  /// that [uploadFrame] can refuse a frame from a different stream, which is
  /// the mistake that shows up as one clip's pixels appearing inside another's
  /// rectangle.
  ///
  /// Throws when [format] is not in
  /// [VideoTextureCapabilities.streamingFormats]; a caller checks first, and
  /// the check is cheap.
  GpuStreamingVideoTexture createStreamingTexture({
    required VideoFrameFormat format,
    required int streamId,
    int bufferCount = 2,
  });

  /// Writes [frame] into the next free buffer of [texture] and makes it the
  /// one [GpuStreamingVideoTexture.plane] answers with.
  ///
  /// Throws [VideoUploadStalled] when every buffer is still in flight. That is
  /// deliberately an error and not a silent overwrite: overwriting a buffer a
  /// recorded draw still points at is the bug that produces a frame with two
  /// halves from different moments, and it is invisible in a still.
  VideoUploadReceipt uploadFrame(
    covariant GpuStreamingVideoTexture texture,
    VideoFrame frame, {
    VideoRegion? region,
  });

  void releaseStreamingTexture(covariant GpuStreamingVideoTexture texture);
}

/// How a texture that already exists on the device was obtained.
///
/// The descriptor is deliberately opaque past this point: an importer knows
/// what its own [kind] means and refuses every other. Making it a sealed
/// hierarchy of platform types would put a DXGI type in the portable rendering
/// layer, which `test/architecture/layering_test.dart` forbids and which would
/// be wrong anyway - the handle is an integer to everything above the backend.
final class ForeignTextureDescriptor {
  const ForeignTextureDescriptor({
    required this.kind,
    required this.handle,
    required this.format,
    this.acquireKey = 0,
  });

  /// Names the interop mechanism: `dxgi_shared_handle`, `egl_image`,
  /// `io_surface`, `opaque_fd`. A string rather than an enum so that adding a
  /// mechanism is a backend change and not a change to this file, which every
  /// backend imports.
  final String kind;

  /// The platform handle, as an integer. What that integer *is* is [kind]'s
  /// business.
  final int handle;

  /// What the foreign texture holds, so a shader knows how to sample it.
  final VideoFrameFormat format;

  /// Keyed-mutex acquire key, for the mechanisms that have one. Zero
  /// otherwise.
  final int acquireKey;

  @override
  String toString() =>
      'ForeignTextureDescriptor($kind, handle 0x${handle.toRadixString(16)}, '
      '$format)';
}

/// The *interop* capability: sampling a texture this renderer never created.
///
/// This is what `supportsExternalTextures` has always meant, and it is
/// separate from [GpuVideoTextureAllocator] because it answers a different
/// question and fails for different reasons. Streaming fails when a device has
/// no suitable texture format; importing fails when the producer and the
/// consumer do not share an interop mechanism - which depends on the two
/// drivers, not on either one alone.
///
/// Nothing implements it yet. It is declared so that the capability has a
/// shape to be implemented against, and so that a reader of
/// `supportsExternalTextures` has somewhere to be sent.
abstract interface class GpuForeignTextureImporter {
  /// Whether [kind] is a mechanism this device understands. Asked before
  /// [importForeignTexture], because the answer depends on the driver pair and
  /// a caller usually has more than one handle it could offer.
  bool supportsForeignKind(String kind);

  /// Adopts the texture [descriptor] names. The returned object behaves like a
  /// single-buffered [GpuStreamingVideoTexture] whose [uploadFrame] is refused:
  /// its contents are the producer's business.
  GpuStreamingVideoTexture importForeignTexture(
    ForeignTextureDescriptor descriptor,
  );

  /// Gives the texture back. Whether that destroys anything depends on the
  /// mechanism; what it always does is stop this device from sampling it.
  void releaseForeignTexture(covariant GpuStreamingVideoTexture texture);
}
