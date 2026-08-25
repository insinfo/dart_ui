/// A frame of video, described without naming a decoder or a graphics API.
///
/// Nothing in this library decodes anything. A frame arrives here as planes of
/// bytes that somebody else produced - a hardware decoder's mapped surface, a
/// software codec's output, a test that filled three `Uint8List`s - and the
/// only thing this file decides is what those bytes *mean*: which plane holds
/// which samples, how far apart the rows are, which primaries the chroma was
/// encoded against and whether the levels are studio or full range.
///
/// That separation is the point. A video editor's frame source changes with
/// the container, the codec and the operating system; the renderer's contract
/// must not. So the renderer never sees a codec, and the decoder never sees a
/// texture.
///
/// ## Why not `DecodedImage`
///
/// `graphics/image/decoded_image.dart` already carries pixels, and a video
/// frame is deliberately not one of those. Three differences, each of which
/// would have to be papered over:
///
///   1. **It is not RGBA.** The formats that matter here - [nv12], [i420],
///      [yuy2] - are luma plus subsampled chroma, which is between a third and
///      a half of the bytes. Converting at the source throws that saving away
///      exactly where it is worth most, on the path that runs sixty times a
///      second.
///   2. **It is not premultiplied, and has no alpha at all.** `DecodedImage`
///      is premultiplied by contract; a YUV frame is opaque and its channels
///      are not colour channels.
///   3. **Its colour needs two more numbers.** The same byte triple decodes to
///      visibly different colours under BT.601 and BT.709, and to different
///      colours again at limited versus full range. An image type with no
///      place to put [VideoColorSpace] and [VideoColorRange] silently picks
///      one, and the failure looks like a slightly wrong grade rather than a
///      bug.
///
/// ## Streams, frames and identity
///
/// A [VideoFrame] carries a [VideoFrame.streamId] and a
/// [VideoFrame.sequence]. The stream id is the identity that matters to a
/// renderer: it is what a GPU texture is keyed on, so that sixty frames a
/// second reuse one allocation instead of creating and destroying one per
/// frame. The sequence number orders frames within a stream and is what an
/// upload ring compares to decide whether a buffer is still in flight.
///
/// Equality is `(streamId, sequence)`, which is what makes a frame safe to
/// intern into a display list: drawing the same frame twice in one list -
/// a picture-in-picture, a filmstrip thumbnail beside the canvas - interns one
/// resource id, exactly as two draws of one path do.
library;

import 'dart:typed_data';

/// The byte layouts a frame source may hand over.
///
/// Deliberately short. Every member here is either what a hardware decoder
/// hands out on a mainstream platform ([nv12] on Windows and Android, [i420]
/// from every software codec, [yuy2] from capture devices) or the trivial case
/// that needs no conversion at all ([bgra8888], [rgba8888]). Adding a format
/// means adding a plane geometry here, a branch in the reference converter and
/// a branch in every shader - so a format earns its place by being one a real
/// producer emits, not by existing in a specification.
enum VideoPixelFormat {
  /// Plane 0: one luma byte per pixel. Plane 1: one interleaved `U, V` pair
  /// per 2x2 block of pixels, so its rows are `ceil(width / 2)` pairs wide.
  ///
  /// The format Media Foundation, VAAPI and Android's `ImageReader` produce,
  /// which is why it is first.
  nv12,

  /// Plane 0: luma. Plane 1: `U` at half width and half height. Plane 2: `V`
  /// at the same. Also spelled YUV420p; the planar sibling of [nv12].
  i420,

  /// One plane of `Y0, U, Y1, V` quadruples: four bytes per *two* pixels, so a
  /// row is `ceil(width / 2)` quadruples wide. Chroma is subsampled
  /// horizontally only, which is why it survives interlaced capture where
  /// [nv12] does not.
  yuy2,

  /// Blue, green, red, alpha - already colour, no conversion needed. Present
  /// so a source that has nothing better (a screen capture, a title card
  /// rendered elsewhere) travels the same path as a decoded frame.
  bgra8888,

  /// Red, green, blue, alpha. See [bgra8888].
  rgba8888;

  /// Whether decoding needs a [YuvToRgbMatrix]; false for the two RGB members.
  bool get isYuv =>
      this == nv12 || this == i420 || this == yuy2;

  /// How many separately addressable planes a frame of this format carries.
  int get planeCount => switch (this) {
        nv12 => 2,
        i420 => 3,
        yuy2 => 1,
        bgra8888 => 1,
        rgba8888 => 1,
      };

  /// Geometry of plane [index]: how its sample grid relates to the frame's.
  VideoPlaneGeometry planeGeometry(int index) {
    if (index < 0 || index >= planeCount) {
      throw RangeError.index(index, this, 'index', 'no such plane', planeCount);
    }
    return switch (this) {
      nv12 => index == 0
          ? const VideoPlaneGeometry(
              bytesPerSample: 1, widthDivisor: 1, heightDivisor: 1)
          : const VideoPlaneGeometry(
              bytesPerSample: 2, widthDivisor: 2, heightDivisor: 2),
      i420 => index == 0
          ? const VideoPlaneGeometry(
              bytesPerSample: 1, widthDivisor: 1, heightDivisor: 1)
          : const VideoPlaneGeometry(
              bytesPerSample: 1, widthDivisor: 2, heightDivisor: 2),
      // A YUY2 row is quadruples, so one *sample* covers two pixels
      // horizontally and carries four bytes.
      yuy2 => const VideoPlaneGeometry(
          bytesPerSample: 4, widthDivisor: 2, heightDivisor: 1),
      bgra8888 || rgba8888 => const VideoPlaneGeometry(
          bytesPerSample: 4, widthDivisor: 1, heightDivisor: 1),
    };
  }

  /// Whether a frame of this format needs an even width, and an even height.
  ///
  /// Not a stylistic preference: with 4:2:0 chroma an odd dimension leaves the
  /// last row or column of pixels sharing a chroma sample with a row that does
  /// not exist, and every producer answers that differently. Refusing it here
  /// is one line; guessing it is a class of off-by-one colour fringe on the
  /// right and bottom edges that only shows on odd-sized clips.
  (bool, bool) get evenSizeRequirement => switch (this) {
        nv12 || i420 => (true, true),
        yuy2 => (true, false),
        bgra8888 || rgba8888 => (false, false),
      };
}

/// How one plane's sample grid relates to the frame's pixel grid.
final class VideoPlaneGeometry {
  const VideoPlaneGeometry({
    required this.bytesPerSample,
    required this.widthDivisor,
    required this.heightDivisor,
  });

  /// Bytes one sample of this plane occupies: 1 for a luma or a planar chroma
  /// plane, 2 for [VideoPixelFormat.nv12]'s interleaved pair, 4 for a packed
  /// [VideoPixelFormat.yuy2] quadruple or an RGBA pixel.
  final int bytesPerSample;

  /// Frame pixels one sample spans horizontally.
  final int widthDivisor;

  /// Frame pixels one sample spans vertically.
  final int heightDivisor;

  /// Samples across, for a frame [frameWidth] pixels wide.
  ///
  /// Rounded **up**, so that a format which tolerates an odd dimension - the
  /// horizontal half of [VideoPixelFormat.yuy2] is the only one today - still
  /// has a sample covering the last pixel.
  int width(int frameWidth) => (frameWidth + widthDivisor - 1) ~/ widthDivisor;

  int height(int frameHeight) =>
      (frameHeight + heightDivisor - 1) ~/ heightDivisor;

  /// The tightest legal stride for this plane.
  int minBytesPerRow(int frameWidth) => width(frameWidth) * bytesPerSample;
}

/// Which primaries the chroma difference signals were formed against.
///
/// The luma coefficients are the whole content of this enum: everything else
/// about a conversion is derived from `kr` and `kb` (see
/// `video_color_conversion.dart`). They are non-constant-luminance
/// coefficients throughout, which is what BT.2020's *NCL* variant means and
/// what every consumer video file in circulation uses.
enum VideoColorSpace {
  /// Standard definition, and still what a great deal of camera and capture
  /// footage declares. Also the correct default for anything 480p or 576p.
  bt601(kr: 0.299, kb: 0.114),

  /// High definition. The right default for 720p and 1080p.
  bt709(kr: 0.2126, kb: 0.0722),

  /// Ultra high definition, non-constant luminance.
  bt2020(kr: 0.2627, kb: 0.0593);

  const VideoColorSpace({required this.kr, required this.kb});

  /// Luma weight of red.
  final double kr;

  /// Luma weight of blue.
  final double kb;

  /// Luma weight of green: whatever the other two leave.
  double get kg => 1.0 - kr - kb;
}

/// Whether the 8-bit codes span the full 0..255 or the studio subrange.
///
/// Getting this wrong is the single most common video colour bug, and it is
/// subtle in exactly the wrong way: a limited-range frame decoded as full
/// range is washed out rather than broken, and a full-range frame decoded as
/// limited clips its own black and white. Neither looks like a defect, so
/// neither gets reported.
enum VideoColorRange {
  /// Y in 16..235, chroma in 16..240. What essentially every compressed file
  /// carries, which is why it is the default everywhere in this library.
  limited,

  /// Y and chroma both in 0..255. What JPEG-derived and some capture paths
  /// produce.
  full,
}

/// Everything about a frame except its bytes: format, size and colour.
///
/// Split out from [VideoFrame] because it is the part a GPU resource is
/// allocated against. A streaming texture is created once from a
/// [VideoFrameFormat] and then fed thousands of [VideoFrame]s that all share
/// it; making the allocator take the frame would invite an implementation that
/// reallocates whenever any field of the frame differs, which is precisely the
/// per-frame resource churn the streaming contract exists to prevent.
final class VideoFrameFormat {
  VideoFrameFormat({
    required this.pixelFormat,
    required this.width,
    required this.height,
    this.colorSpace = VideoColorSpace.bt709,
    this.range = VideoColorRange.limited,
  }) {
    if (width <= 0 || height <= 0) {
      throw ArgumentError('a video frame must have a positive size, got '
          '${width}x$height');
    }
    final (bool evenWidth, bool evenHeight) = pixelFormat.evenSizeRequirement;
    if (evenWidth && width.isOdd) {
      throw ArgumentError.value(
        width,
        'width',
        '${pixelFormat.name} subsamples chroma horizontally, so an odd width '
            'leaves the last column sharing a chroma sample with a column '
            'that does not exist; crop or pad before this point',
      );
    }
    if (evenHeight && height.isOdd) {
      throw ArgumentError.value(
        height,
        'height',
        '${pixelFormat.name} subsamples chroma vertically, so an odd height '
            'leaves the last row sharing a chroma sample with a row that does '
            'not exist; crop or pad before this point',
      );
    }
  }

  final VideoPixelFormat pixelFormat;
  final int width;
  final int height;

  /// Ignored for the two RGB formats, and carried anyway rather than made
  /// nullable: a nullable field would have to be checked at every use, and
  /// there is no reading of a BGRA frame under which these two change a pixel.
  final VideoColorSpace colorSpace;
  final VideoColorRange range;

  int get planeCount => pixelFormat.planeCount;

  VideoPlaneGeometry planeGeometry(int index) =>
      pixelFormat.planeGeometry(index);

  /// Samples across in plane [index].
  int planeWidth(int index) => planeGeometry(index).width(width);

  /// Rows in plane [index].
  int planeHeight(int index) => planeGeometry(index).height(height);

  /// The tightest legal stride of plane [index], in bytes.
  int planeMinBytesPerRow(int index) => planeGeometry(index).minBytesPerRow(
        width,
      );

  /// Bytes a tightly packed frame of this format occupies, all planes.
  int get packedByteLength {
    var total = 0;
    for (var i = 0; i < planeCount; i++) {
      total += planeMinBytesPerRow(i) * planeHeight(i);
    }
    return total;
  }

  /// Whether [other] describes the same GPU resource - same layout, same size.
  ///
  /// The colour fields are excluded on purpose: they are shader uniforms, not
  /// allocation parameters, so a stream that switches from BT.601 to BT.709
  /// mid-play keeps its textures and changes three `vec4`s.
  bool hasSameLayoutAs(VideoFrameFormat other) =>
      pixelFormat == other.pixelFormat &&
      width == other.width &&
      height == other.height;

  @override
  bool operator ==(Object other) =>
      other is VideoFrameFormat &&
      other.pixelFormat == pixelFormat &&
      other.width == width &&
      other.height == height &&
      other.colorSpace == colorSpace &&
      other.range == range;

  @override
  int get hashCode => Object.hash(pixelFormat, width, height, colorSpace, range);

  @override
  String toString() => 'VideoFrameFormat(${pixelFormat.name}, ${width}x$height,'
      ' ${colorSpace.name}, ${range.name})';
}

/// One plane's bytes and the distance between its rows.
///
/// [bytesPerRow] is carried explicitly for the same reason `Framebuffer` and
/// `GpuTextureAllocator.uploadRegion` carry it: a decoder's output is
/// row-aligned to whatever its hardware wanted - 64, 128, 256 bytes - and
/// almost never to `width * bytesPerSample`. Recomputing the stride at the
/// call site is how a frame comes out sheared, one row shifting a little
/// further left than the last.
/// Lifetime guard for storage that can be recycled independently of Dart GC.
abstract interface class VideoFrameStorageLifetime {
  bool get isValid;
  void validate();
}

final class VideoPlane {
  VideoPlane({
    required this.bytes,
    required this.bytesPerRow,
    this.offset = 0,
    this.lifetime,
  }) {
    if (bytesPerRow <= 0) {
      throw ArgumentError.value(bytesPerRow, 'bytesPerRow', 'must be positive');
    }
    if (offset < 0 || offset > bytes.length) {
      throw ArgumentError.value(offset, 'offset', 'outside the buffer');
    }
    lifetime?.validate();
  }

  final Uint8List bytes;

  /// Distance between the first byte of one row and the first byte of the
  /// next, in bytes. Never smaller than the plane's packed row length.
  final int bytesPerRow;

  /// Byte position of the plane's first row inside [bytes].
  ///
  /// Present so that the common case - one allocation holding every plane of
  /// an NV12 frame back to back, which is what a mapped decoder surface is -
  /// needs no `sublistView` per plane per frame. A view is cheap but it is not
  /// free, and this path runs once per plane per frame forever.
  final int offset;

  /// Keeps external/native storage ownership with the plane and detects a
  /// ring slot that has wrapped before the renderer reads it.
  final VideoFrameStorageLifetime? lifetime;

  /// First byte of row [row].
  int rowOffset(int row) {
    lifetime?.validate();
    return offset + row * bytesPerRow;
  }

  @override
  String toString() =>
      'VideoPlane(${bytes.length} bytes, stride $bytesPerRow, at $offset)';
}

/// A frame: a [VideoFrameFormat], its planes, and where it sits in its stream.
final class VideoFrame {
  VideoFrame({
    required this.format,
    required this.planes,
    required this.streamId,
    required this.sequence,
  }) {
    if (planes.length != format.planeCount) {
      throw ArgumentError.value(
        planes.length,
        'planes.length',
        '${format.pixelFormat.name} has ${format.planeCount} planes',
      );
    }
    if (streamId <= 0) {
      throw ArgumentError.value(
        streamId,
        'streamId',
        'must be positive; zero is reserved for "no stream"',
      );
    }
    if (sequence < 0) {
      throw ArgumentError.value(sequence, 'sequence', 'must not be negative');
    }
    for (var i = 0; i < planes.length; i++) {
      final VideoPlane plane = planes[i];
      final int minimum = format.planeMinBytesPerRow(i);
      if (plane.bytesPerRow < minimum) {
        throw ArgumentError.value(
          plane.bytesPerRow,
          'planes[$i].bytesPerRow',
          'plane $i of a ${format.width}x${format.height} '
              '${format.pixelFormat.name} frame needs at least $minimum bytes '
              'per row',
        );
      }
      final int rows = format.planeHeight(i);
      // The last row need only be *present*, not padded to the full stride:
      // a tightly cropped mapped surface routinely ends exactly at the last
      // sample, and refusing that would refuse most real frames.
      final int required =
          plane.offset + (rows - 1) * plane.bytesPerRow + minimum;
      if (plane.bytes.length < required) {
        throw ArgumentError.value(
          plane.bytes.length,
          'planes[$i].bytes.length',
          'plane $i needs $required bytes at stride ${plane.bytesPerRow} for '
              '$rows rows',
        );
      }
    }
  }

  /// A frame whose planes are tightly packed and zero-filled - the shape a
  /// test or a synthetic source builds before writing samples into it.
  factory VideoFrame.allocate(
    VideoFrameFormat format, {
    required int streamId,
    int sequence = 0,
  }) {
    final List<VideoPlane> planes = <VideoPlane>[];
    for (var i = 0; i < format.planeCount; i++) {
      final int stride = format.planeMinBytesPerRow(i);
      planes.add(VideoPlane(
        bytes: Uint8List(stride * format.planeHeight(i)),
        bytesPerRow: stride,
      ));
    }
    return VideoFrame(
      format: format,
      planes: planes,
      streamId: streamId,
      sequence: sequence,
    );
  }

  final VideoFrameFormat format;
  final List<VideoPlane> planes;

  /// Which stream this frame belongs to. A GPU texture is keyed on this, not
  /// on the frame, which is what stops sixty allocations a second.
  final int streamId;

  /// Position in the stream. Strictly increasing per stream, and compared by
  /// an upload ring to tell a frame still in flight from one that retired.
  final int sequence;

  int get width => format.width;
  int get height => format.height;

  VideoPlane plane(int index) {
    final VideoPlane result = planes[index];
    result.lifetime?.validate();
    return result;
  }

  /// A frame with the same bytes at a new position in the stream.
  ///
  /// Useful where a source re-presents a held frame - a paused playhead, a
  /// still held across a transition - and the renderer must still be able to
  /// tell the two draws apart for the ring's bookkeeping.
  VideoFrame atSequence(int newSequence) => VideoFrame(
        format: format,
        planes: planes,
        streamId: streamId,
        sequence: newSequence,
      );

  /// Identity is `(streamId, sequence)`, never the bytes.
  ///
  /// Comparing pixels would be a megabyte-scale `==` on a path a display list
  /// calls for every draw, and two frames of one stream with identical bytes
  /// are still two frames as far as an upload ring is concerned.
  @override
  bool operator ==(Object other) =>
      other is VideoFrame &&
      other.streamId == streamId &&
      other.sequence == sequence;

  @override
  int get hashCode => Object.hash(streamId, sequence);

  @override
  String toString() =>
      'VideoFrame(stream $streamId, #$sequence, $format)';
}

/// An integer rectangle of a frame, in frame pixels.
///
/// Integer and not `Rect` because every consumer of it - a texture upload, a
/// plane row range, a dirty region - addresses texels, and a fractional edge
/// there is a rounding decision made in the wrong place. See [alignedTo] for
/// the one rounding this type does make.
final class VideoRegion {
  const VideoRegion(this.left, this.top, this.right, this.bottom);

  const VideoRegion.wholeFrame(int width, int height)
      : left = 0,
        top = 0,
        right = width,
        bottom = height;

  final int left;
  final int top;
  final int right;
  final int bottom;

  int get width => right - left;
  int get height => bottom - top;
  bool get isEmpty => right <= left || bottom <= top;

  /// Grows to whole chroma samples of [format].
  ///
  /// A partial upload of a 4:2:0 frame cannot start on an odd row: one chroma
  /// sample covers two luma rows, so uploading the odd row alone would have to
  /// either skip its chroma - leaving the colour a frame stale - or rewrite a
  /// sample the even row above still depends on. Snapping outward costs at
  /// most one row and one column and removes the whole question.
  VideoRegion alignedTo(VideoPixelFormat format) {
    var alignX = 1;
    var alignY = 1;
    for (var i = 0; i < format.planeCount; i++) {
      final VideoPlaneGeometry geometry = format.planeGeometry(i);
      if (geometry.widthDivisor > alignX) alignX = geometry.widthDivisor;
      if (geometry.heightDivisor > alignY) alignY = geometry.heightDivisor;
    }
    return VideoRegion(
      left - (left % alignX),
      top - (top % alignY),
      _roundUp(right, alignX),
      _roundUp(bottom, alignY),
    );
  }

  VideoRegion intersect(VideoRegion other) => VideoRegion(
        left > other.left ? left : other.left,
        top > other.top ? top : other.top,
        right < other.right ? right : other.right,
        bottom < other.bottom ? bottom : other.bottom,
      );

  static int _roundUp(int value, int align) =>
      value % align == 0 ? value : value + align - value % align;

  @override
  bool operator ==(Object other) =>
      other is VideoRegion &&
      other.left == left &&
      other.top == top &&
      other.right == right &&
      other.bottom == bottom;

  @override
  int get hashCode => Object.hash(left, top, right, bottom);

  @override
  String toString() => 'VideoRegion($left, $top, $right, $bottom)';
}
