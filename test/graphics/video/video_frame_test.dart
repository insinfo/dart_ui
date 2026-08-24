/// The format contract: plane geometry, the strides a producer may hand over,
/// and what a frame refuses.
///
/// These run on any machine. Everything they assert is arithmetic about
/// layouts, which is exactly the part that has to be right before a single
/// byte reaches a driver: a plane geometry that is off by a factor of two
/// produces a texture that uploads without error and samples as noise.
library;

import 'dart:typed_data';

import 'package:dart_ui/src/graphics/video/video_frame.dart';
import 'package:test/test.dart';

void main() {
  group('plane geometry', () {
    test('NV12 is a full luma plane and one interleaved chroma plane', () {
      final format = VideoFrameFormat(
        pixelFormat: VideoPixelFormat.nv12,
        width: 1920,
        height: 1080,
      );
      expect(format.planeCount, 2);
      expect(format.planeWidth(0), 1920);
      expect(format.planeHeight(0), 1080);
      expect(format.planeMinBytesPerRow(0), 1920);
      // 960 pairs of two bytes: the chroma plane is half as wide in *samples*
      // and exactly as wide in *bytes*, which is the fact an upload gets wrong
      // if it reasons in pixels.
      expect(format.planeWidth(1), 960);
      expect(format.planeHeight(1), 540);
      expect(format.planeMinBytesPerRow(1), 1920);
      expect(format.packedByteLength, 1920 * 1080 * 3 ~/ 2);
    });

    test('I420 splits the same chroma into two half-width planes', () {
      final format = VideoFrameFormat(
        pixelFormat: VideoPixelFormat.i420,
        width: 1280,
        height: 720,
      );
      expect(format.planeCount, 3);
      expect(format.planeMinBytesPerRow(1), 640);
      expect(format.planeMinBytesPerRow(2), 640);
      expect(format.planeHeight(1), 360);
      expect(format.packedByteLength, 1280 * 720 * 3 ~/ 2);
    });

    test('YUY2 is one plane of four bytes per two pixels', () {
      final format = VideoFrameFormat(
        pixelFormat: VideoPixelFormat.yuy2,
        width: 640,
        height: 481,
      );
      expect(format.planeCount, 1);
      expect(format.planeWidth(0), 320);
      // Vertically unsubsampled, which is why an odd height is legal here and
      // is not for the two 4:2:0 formats.
      expect(format.planeHeight(0), 481);
      expect(format.planeMinBytesPerRow(0), 1280);
      expect(format.packedByteLength, 640 * 481 * 2);
    });

    test('the packed formats are four bytes a pixel with one plane', () {
      for (final VideoPixelFormat pixelFormat in <VideoPixelFormat>[
        VideoPixelFormat.bgra8888,
        VideoPixelFormat.rgba8888,
      ]) {
        final format = VideoFrameFormat(
          pixelFormat: pixelFormat,
          width: 7,
          height: 3,
        );
        expect(format.planeCount, 1);
        expect(format.planeMinBytesPerRow(0), 28);
        expect(format.packedByteLength, 84);
      }
    });

    test('asking for a plane that does not exist is a range error', () {
      expect(
        () => VideoPixelFormat.nv12.planeGeometry(2),
        throwsA(isA<RangeError>()),
      );
    });
  });

  group('size validation', () {
    test('4:2:0 refuses an odd dimension in either direction', () {
      for (final VideoPixelFormat pixelFormat in <VideoPixelFormat>[
        VideoPixelFormat.nv12,
        VideoPixelFormat.i420,
      ]) {
        expect(
          () =>
              VideoFrameFormat(pixelFormat: pixelFormat, width: 31, height: 16),
          throwsA(isA<ArgumentError>()),
          reason: '${pixelFormat.name} at an odd width',
        );
        expect(
          () =>
              VideoFrameFormat(pixelFormat: pixelFormat, width: 32, height: 15),
          throwsA(isA<ArgumentError>()),
          reason: '${pixelFormat.name} at an odd height',
        );
      }
    });

    test('YUY2 refuses an odd width and accepts an odd height', () {
      expect(
        () => VideoFrameFormat(
            pixelFormat: VideoPixelFormat.yuy2, width: 5, height: 4),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        VideoFrameFormat(
                pixelFormat: VideoPixelFormat.yuy2, width: 4, height: 5)
            .height,
        5,
      );
    });

    test('a non-positive size is refused', () {
      expect(
        () => VideoFrameFormat(
            pixelFormat: VideoPixelFormat.rgba8888, width: 0, height: 4),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('layout equality ignores colour and identity does not', () {
      final a = VideoFrameFormat(
        pixelFormat: VideoPixelFormat.nv12,
        width: 16,
        height: 16,
        colorSpace: VideoColorSpace.bt601,
      );
      final b = VideoFrameFormat(
        pixelFormat: VideoPixelFormat.nv12,
        width: 16,
        height: 16,
        colorSpace: VideoColorSpace.bt2020,
        range: VideoColorRange.full,
      );
      // A stream that changes colour space keeps its textures; one that
      // changes size does not.
      expect(a.hasSameLayoutAs(b), isTrue);
      expect(a == b, isFalse);
      expect(
        a.hasSameLayoutAs(VideoFrameFormat(
          pixelFormat: VideoPixelFormat.nv12,
          width: 18,
          height: 16,
        )),
        isFalse,
      );
    });
  });

  group('a frame', () {
    VideoFrameFormat nv12(int width, int height) => VideoFrameFormat(
          pixelFormat: VideoPixelFormat.nv12,
          width: width,
          height: height,
        );

    test('allocates tightly packed planes', () {
      final VideoFrame frame =
          VideoFrame.allocate(nv12(64, 32), streamId: 3, sequence: 7);
      expect(frame.planes.length, 2);
      expect(frame.plane(0).bytesPerRow, 64);
      expect(frame.plane(0).bytes.length, 64 * 32);
      expect(frame.plane(1).bytesPerRow, 64);
      expect(frame.plane(1).bytes.length, 64 * 16);
      expect(frame.streamId, 3);
      expect(frame.sequence, 7);
    });

    test('accepts a padded stride', () {
      final frame = VideoFrame(
        format: nv12(64, 32),
        planes: <VideoPlane>[
          VideoPlane(bytes: Uint8List(128 * 32), bytesPerRow: 128),
          VideoPlane(bytes: Uint8List(128 * 16), bytesPerRow: 128),
        ],
        streamId: 1,
        sequence: 0,
      );
      expect(frame.plane(0).rowOffset(2), 256);
    });

    test('accepts a last row that stops at the last sample', () {
      // A mapped decoder surface routinely ends exactly at the end of the
      // picture rather than at the end of the last stride. Refusing that would
      // refuse most real frames.
      const int stride = 128;
      const int shortBy = stride - 64;
      final frame = VideoFrame(
        format: nv12(64, 32),
        planes: <VideoPlane>[
          VideoPlane(
              bytes: Uint8List(stride * 32 - shortBy), bytesPerRow: stride),
          VideoPlane(
              bytes: Uint8List(stride * 16 - shortBy), bytesPerRow: stride),
        ],
        streamId: 1,
        sequence: 0,
      );
      expect(frame.width, 64);
    });

    test('refuses a stride narrower than the plane', () {
      expect(
        () => VideoFrame(
          format: nv12(64, 32),
          planes: <VideoPlane>[
            VideoPlane(bytes: Uint8List(64 * 32), bytesPerRow: 64),
            VideoPlane(bytes: Uint8List(32 * 16), bytesPerRow: 32),
          ],
          streamId: 1,
          sequence: 0,
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('refuses a buffer too short for the rows it claims', () {
      expect(
        () => VideoFrame(
          format: nv12(64, 32),
          planes: <VideoPlane>[
            VideoPlane(bytes: Uint8List(64 * 31), bytesPerRow: 64),
            VideoPlane(bytes: Uint8List(64 * 16), bytesPerRow: 64),
          ],
          streamId: 1,
          sequence: 0,
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('refuses the wrong number of planes', () {
      expect(
        () => VideoFrame(
          format: nv12(64, 32),
          planes: <VideoPlane>[
            VideoPlane(bytes: Uint8List(64 * 32), bytesPerRow: 64),
          ],
          streamId: 1,
          sequence: 0,
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('refuses stream id zero, which means "no stream"', () {
      expect(
        () => VideoFrame.allocate(nv12(16, 16), streamId: 0),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('identity is the stream and the sequence, never the bytes', () {
      final VideoFrame a = VideoFrame.allocate(nv12(16, 16), streamId: 9);
      final VideoFrame b = VideoFrame.allocate(nv12(16, 16), streamId: 9);
      // Different objects, identical (empty) pixels, same position in the
      // same stream: one resource as far as a display list is concerned.
      expect(a, equals(b));
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(equals(a.atSequence(1))));
      expect(
        a,
        isNot(equals(VideoFrame.allocate(nv12(16, 16), streamId: 10))),
      );
    });
  });

  group('a region', () {
    test('aligns outward to whole chroma samples for 4:2:0', () {
      const region = VideoRegion(3, 5, 10, 11);
      expect(
        region.alignedTo(VideoPixelFormat.nv12),
        const VideoRegion(2, 4, 10, 12),
      );
      expect(
        region.alignedTo(VideoPixelFormat.i420),
        const VideoRegion(2, 4, 10, 12),
      );
    });

    test('aligns horizontally only for YUY2', () {
      expect(
        const VideoRegion(3, 5, 10, 11).alignedTo(VideoPixelFormat.yuy2),
        const VideoRegion(2, 5, 10, 11),
      );
    });

    test('leaves a packed format alone', () {
      const region = VideoRegion(3, 5, 10, 11);
      expect(region.alignedTo(VideoPixelFormat.rgba8888), region);
    });

    test('intersects and reports emptiness', () {
      const whole = VideoRegion.wholeFrame(64, 32);
      expect(const VideoRegion(-4, -4, 8, 8).intersect(whole),
          const VideoRegion(0, 0, 8, 8));
      expect(const VideoRegion(70, 0, 80, 8).intersect(whole).isEmpty, isTrue);
      expect(whole.width, 64);
      expect(whole.height, 32);
    });
  });
}
