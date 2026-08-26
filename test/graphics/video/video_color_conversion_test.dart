/// The reference conversion, checked against the published constants and
/// against itself.
///
/// Three separate things are asserted here and they fail for different
/// reasons, which is why they are not one test:
///
///   1. The **matrix** matches the coefficients every specification and every
///      other implementation prints - 1.596, 2.017, 1.793, 2.112. If this is
///      wrong the picture is wrongly coloured everywhere, on every backend, and
///      no amount of GPU/CPU parity would notice because both sides would be
///      equally wrong.
///   2. The **fixed-point evaluation** agrees with the double-precision one
///      across the sample space. That is what lets the fast path be the
///      reference.
///   3. The **layouts** agree with each other. NV12, I420 and YUY2 carrying the
///      same picture must decode to the same pixels, which catches an
///      addressing error in exactly one of them.
library;

import 'package:dart_ui/src/graphics/image/decoded_image.dart';
import 'package:dart_ui/src/graphics/video/video_color_conversion.dart';
import 'package:dart_ui/src/graphics/video/video_frame.dart';
import 'package:test/test.dart';

import 'synthetic_frames.dart';

void main() {
  group('the matrix', () {
    test('BT.601 limited range is the classic 1.164 / 1.596 / 2.017', () {
      final m = YuvToRgbMatrix.of(
        VideoColorSpace.bt601,
        VideoColorRange.limited,
      );
      expect(m.rY, closeTo(1.16438, 1e-4));
      expect(m.rV, closeTo(1.59603, 1e-4));
      expect(m.gU, closeTo(-0.39176, 1e-4));
      expect(m.gV, closeTo(-0.81297, 1e-4));
      expect(m.bU, closeTo(2.01723, 1e-4));
      expect(m.rU, 0.0);
      expect(m.bV, 0.0);
    });

    test('BT.709 limited range is 1.164 / 1.793 / 2.112', () {
      final m = YuvToRgbMatrix.of(
        VideoColorSpace.bt709,
        VideoColorRange.limited,
      );
      expect(m.rY, closeTo(1.16438, 1e-4));
      expect(m.rV, closeTo(1.79274, 1e-4));
      expect(m.gU, closeTo(-0.21325, 1e-4));
      expect(m.gV, closeTo(-0.53291, 1e-4));
      expect(m.bU, closeTo(2.11240, 1e-4));
    });

    test('BT.2020 non-constant luminance is 1.164 / 1.679 / 2.142', () {
      final m = YuvToRgbMatrix.of(
        VideoColorSpace.bt2020,
        VideoColorRange.limited,
      );
      expect(m.rV, closeTo(1.67867, 1e-4));
      expect(m.gU, closeTo(-0.18733, 1e-4));
      expect(m.gV, closeTo(-0.65042, 1e-4));
      expect(m.bU, closeTo(2.14177, 1e-4));
    });

    test('full range keeps luma unscaled', () {
      final m = YuvToRgbMatrix.of(VideoColorSpace.bt709, VideoColorRange.full);
      expect(m.rY, 1.0);
      expect(m.rV, closeTo(1.5748, 1e-4));
      expect(m.bU, closeTo(1.8556, 1e-4));
    });

    test('limited range maps 16 to black and 235 to white', () {
      final m = YuvToRgbMatrix.of(
        VideoColorSpace.bt709,
        VideoColorRange.limited,
      );
      expect(m.rgbFromCodes(16, 128, 128), (0, 0, 0));
      expect(m.rgbFromCodes(235, 128, 128), (255, 255, 255));
      // Below black and above white clamp rather than wrapping.
      expect(m.rgbFromCodes(0, 128, 128), (0, 0, 0));
      expect(m.rgbFromCodes(255, 128, 128), (255, 255, 255));
    });

    test('full range maps 0 to black and 255 to white', () {
      final m = YuvToRgbMatrix.of(VideoColorSpace.bt709, VideoColorRange.full);
      expect(m.rgbFromCodes(0, 128, 128), (0, 0, 0));
      expect(m.rgbFromCodes(255, 128, 128), (255, 255, 255));
    });

    test('the range is not cosmetic: 16 is black or is not', () {
      final limited = YuvToRgbMatrix.of(
        VideoColorSpace.bt709,
        VideoColorRange.limited,
      );
      final full = YuvToRgbMatrix.of(
        VideoColorSpace.bt709,
        VideoColorRange.full,
      );
      expect(limited.rgbFromCodes(16, 128, 128), (0, 0, 0));
      expect(full.rgbFromCodes(16, 128, 128), (16, 16, 16));
    });

    test('the colour space is not cosmetic either', () {
      const int y = 128;
      const int u = 200;
      const int v = 60;
      final bt601 = YuvToRgbMatrix.of(
        VideoColorSpace.bt601,
        VideoColorRange.limited,
      ).rgbFromCodes(y, u, v);
      final bt709 = YuvToRgbMatrix.of(
        VideoColorSpace.bt709,
        VideoColorRange.limited,
      ).rgbFromCodes(y, u, v);
      expect(bt601, isNot(equals(bt709)));
    });

    test('a packed RGB format decodes through the identity', () {
      final format = VideoFrameFormat(
        pixelFormat: VideoPixelFormat.rgba8888,
        width: 4,
        height: 4,
      );
      expect(YuvToRgbMatrix.forFormat(format), same(YuvToRgbMatrix.identity));
      expect(YuvToRgbMatrix.identity.rgbFromCodes(10, 20, 30), (10, 20, 30));
    });

    test('one matrix object is reused per space and range', () {
      // The frame path asks for this per draw; allocating a Float32List there
      // would be an allocation per frame per stream forever.
      expect(
        YuvToRgbMatrix.of(VideoColorSpace.bt709, VideoColorRange.limited),
        same(YuvToRgbMatrix.of(VideoColorSpace.bt709, VideoColorRange.limited)),
      );
    });
  });

  group('the fixed-point evaluation', () {
    test('agrees with double precision within one level over the sweep', () {
      // Every luma code against a lattice of chroma, for all six colour
      // configurations: 256 * 17 * 17 * 6 samples, which is enough to catch a
      // rounding rule that is wrong anywhere rather than at the corners.
      var worst = 0;
      var worstAt = '';
      for (final VideoColorSpace space in VideoColorSpace.values) {
        for (final VideoColorRange range in VideoColorRange.values) {
          final format = VideoFrameFormat(
            pixelFormat: VideoPixelFormat.nv12,
            width: 2,
            height: 2,
            colorSpace: space,
            range: range,
          );
          final matrix = YuvToRgbMatrix.of(space, range);
          for (var y = 0; y < 256; y++) {
            for (var u = 0; u <= 255; u += 15) {
              for (var v = 0; v <= 255; v += 15) {
                final frame = VideoFrame.allocate(format, streamId: 1);
                frame.plane(0).bytes.fillRange(0, 4, y);
                frame.plane(1).bytes[0] = u;
                frame.plane(1).bytes[1] = v;
                final converted = convertVideoFrameToRgba(frame);
                final (int r, int g, int b) = matrix.rgbFromCodes(y, u, v);
                final List<int> deltas = <int>[
                  (converted[0] - r).abs(),
                  (converted[1] - g).abs(),
                  (converted[2] - b).abs(),
                ];
                for (final int delta in deltas) {
                  if (delta > worst) {
                    worst = delta;
                    worstAt = 'y=$y u=$u v=$v ${space.name} ${range.name}';
                  }
                }
              }
            }
          }
        }
      }
      expect(worst, lessThanOrEqualTo(1), reason: 'worst at $worstAt');
      printOnFailure('worst fixed-point deviation: $worst level at $worstAt');
    });
  });

  group('the layouts', () {
    test('NV12, I420 and YUY2 of one picture decode identically', () {
      final picture = SyntheticPicture.ramp(32, 16);
      final nv12 = convertVideoFrameToRgba(
        picture.encode(VideoPixelFormat.nv12),
      );
      final i420 = convertVideoFrameToRgba(
        picture.encode(VideoPixelFormat.i420),
      );
      final yuy2 = convertVideoFrameToRgba(
        picture.encode(VideoPixelFormat.yuy2),
      );
      expect(i420, orderedEquals(nv12));
      expect(yuy2, orderedEquals(nv12));
    });

    test('a padded stride decodes to the same picture as a packed one', () {
      final picture = SyntheticPicture.ramp(32, 16);
      for (final VideoPixelFormat format in <VideoPixelFormat>[
        VideoPixelFormat.nv12,
        VideoPixelFormat.i420,
        VideoPixelFormat.yuy2,
      ]) {
        expect(
          convertVideoFrameToRgba(picture.encode(format, rowPadding: 37)),
          orderedEquals(convertVideoFrameToRgba(picture.encode(format))),
          reason: format.name,
        );
      }
    });

    test('chroma is replicated across the 2x2 block, not interpolated', () {
      // Two blocks with very different chroma side by side. Replication means
      // every pixel of the left block is exactly the left colour; an
      // interpolating converter would produce four different colours in the
      // seam.
      final format = VideoFrameFormat(
        pixelFormat: VideoPixelFormat.nv12,
        width: 4,
        height: 2,
      );
      final VideoFrame frame = VideoFrame.allocate(format, streamId: 1);
      frame.plane(0).bytes.fillRange(0, 8, 128);
      frame.plane(1).bytes
        ..[0] = 40
        ..[1] = 210
        ..[2] = 210
        ..[3] = 40;
      final converted = convertVideoFrameToRgba(frame);
      List<int> pixel(int x, int y) =>
          converted.sublist((y * 4 + x) * 4, (y * 4 + x) * 4 + 4);
      expect(pixel(0, 0), pixel(1, 0));
      expect(pixel(0, 0), pixel(0, 1));
      expect(pixel(0, 0), pixel(1, 1));
      expect(pixel(2, 0), pixel(3, 1));
      expect(pixel(0, 0), isNot(equals(pixel(2, 0))));
    });

    test('YUY2 gives the two pixels of a pair their own luma', () {
      final format = VideoFrameFormat(
        pixelFormat: VideoPixelFormat.yuy2,
        width: 2,
        height: 1,
        range: VideoColorRange.full,
      );
      final VideoFrame frame = VideoFrame.allocate(format, streamId: 1);
      frame.plane(0).bytes
        ..[0] = 40
        ..[1] = 128
        ..[2] = 200
        ..[3] = 128;
      final converted = convertVideoFrameToRgba(frame);
      expect(converted[0], 40);
      expect(converted[4], 200);
    });
  });

  group('the converter', () {
    test('honours a region as a crop', () {
      final picture = SyntheticPicture.ramp(16, 16);
      final VideoFrame frame = picture.encode(VideoPixelFormat.nv12);
      final whole = convertVideoFrameToRgba(frame);
      final cropped = convertVideoFrameToRgba(
        frame,
        region: const VideoRegion(4, 2, 12, 10),
      );
      expect(cropped.length, 8 * 8 * 4);
      for (var y = 0; y < 8; y++) {
        for (var x = 0; x < 8; x++) {
          final int from = ((y + 2) * 16 + (x + 4)) * 4;
          final int to = (y * 8 + x) * 4;
          expect(cropped.sublist(to, to + 4),
              orderedEquals(whole.sublist(from, from + 4)),
              reason: 'at $x, $y');
        }
      }
    });

    test('writes BGRA when asked, swapping only red and blue', () {
      final picture = SyntheticPicture.ramp(8, 8);
      final VideoFrame frame = picture.encode(VideoPixelFormat.i420);
      final rgba = convertVideoFrameToRgba(frame);
      final bgra =
          convertVideoFrameToRgba(frame, order: ImageChannelOrder.bgra);
      for (var i = 0; i < rgba.length; i += 4) {
        expect(bgra[i], rgba[i + 2]);
        expect(bgra[i + 1], rgba[i + 1]);
        expect(bgra[i + 2], rgba[i]);
        expect(bgra[i + 3], rgba[i + 3]);
      }
    });

    test('premultiplies by opacity', () {
      final picture = SyntheticPicture.ramp(8, 8);
      final VideoFrame frame = picture.encode(VideoPixelFormat.nv12);
      final opaque = convertVideoFrameToRgba(frame);
      final half = convertVideoFrameToRgba(frame, opacity: 128);
      for (var i = 0; i < opaque.length; i += 4) {
        expect(half[i + 3], 128);
        expect(half[i], premultiplyChannel(opaque[i], 128));
      }
    });

    test('a packed frame passes its own bytes through', () {
      final picture = SyntheticPicture.ramp(8, 8);
      final VideoFrame frame = picture.encode(VideoPixelFormat.rgba8888);
      final converted = convertVideoFrameToRgba(frame);
      expect(converted, orderedEquals(frame.plane(0).bytes));
    });

    test('a BGRA frame is reordered, not reinterpreted', () {
      final format = VideoFrameFormat(
        pixelFormat: VideoPixelFormat.bgra8888,
        width: 1,
        height: 1,
      );
      final VideoFrame frame = VideoFrame.allocate(format, streamId: 1);
      frame.plane(0).bytes
        ..[0] = 10 // blue
        ..[1] = 20 // green
        ..[2] = 30 // red
        ..[3] = 255;
      expect(convertVideoFrameToRgba(frame).take(4), <int>[30, 20, 10, 255]);
    });

    test('refuses a region outside the frame and a short output buffer', () {
      final VideoFrame frame =
          SyntheticPicture.ramp(8, 8).encode(VideoPixelFormat.nv12);
      expect(
        () => convertVideoFrameToRgba(
          frame,
          region: const VideoRegion(20, 20, 24, 24),
        ),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => convertVideoFrameToRgba(frame, bytesPerRow: 4),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('sampling a packed frame for YUV codes is refused', () {
      final VideoFrame frame =
          SyntheticPicture.ramp(4, 4).encode(VideoPixelFormat.rgba8888);
      expect(
        () => sampleYuvCodes(frame, 0, 0),
        throwsA(isA<ArgumentError>()),
      );
    });
  });
}
