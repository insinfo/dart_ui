/// Synthetic video frames, built in code.
///
/// Nothing in this repository decodes video, so every test that needs a frame
/// makes one. The point of this helper is that it makes *the same* frame in
/// three different layouts: a [SyntheticPicture] defines luma per pixel and
/// chroma per 2x2 block, and each encoder below writes exactly those samples
/// into NV12, I420 or YUY2. A test can then assert that all three decode to
/// identical pixels, which is the property that catches an addressing mistake
/// in one layout - by far the most likely bug in this area, and one a
/// single-format test cannot see.
library;

import 'dart:typed_data';

import 'package:dart_ui/src/graphics/video/video_frame.dart';

/// A picture with chroma at 2x2 block resolution, so that it survives every
/// subsampled layout unchanged.
final class SyntheticPicture {
  SyntheticPicture({
    required this.width,
    required this.height,
    required this.luma,
    required this.chromaU,
    required this.chromaV,
  });

  /// A deterministic test picture: a luma ramp across the diagonal, chroma
  /// sweeping in the other two directions, and a hard edge down the middle so
  /// that a converter which blurs chroma is visibly different from one that
  /// replicates it.
  factory SyntheticPicture.ramp(int width, int height, {int seed = 0}) =>
      SyntheticPicture(
        width: width,
        height: height,
        luma: (int x, int y) =>
            (16 + (x * 219 ~/ (width - 1) + y * 97 + seed * 13) % 220)
                .clamp(0, 255),
        chromaU: (int bx, int by) =>
            (16 + (bx * 7 + by * 3 + seed) % 225).clamp(0, 255),
        chromaV: (int bx, int by) =>
            (bx * 2 + by * 2 < (width + height) ~/ 2 ? 90 : 200),
      );

  final int width;
  final int height;

  /// Luma code at a pixel.
  final int Function(int x, int y) luma;

  /// U code of the 2x2 block at ([bx], [by]).
  final int Function(int bx, int by) chromaU;

  /// V code of the same block.
  final int Function(int bx, int by) chromaV;

  /// Encodes into [pixelFormat], optionally padding each plane's rows.
  ///
  /// [rowPadding] exists because a real decoder's stride is almost never the
  /// packed one, and a converter that quietly assumes it is produces a sheared
  /// picture that still looks like a picture.
  VideoFrame encode(
    VideoPixelFormat pixelFormat, {
    VideoColorSpace colorSpace = VideoColorSpace.bt709,
    VideoColorRange range = VideoColorRange.limited,
    int streamId = 1,
    int sequence = 0,
    int rowPadding = 0,
  }) {
    final VideoFrameFormat format = VideoFrameFormat(
      pixelFormat: pixelFormat,
      width: width,
      height: height,
      colorSpace: colorSpace,
      range: range,
    );
    final List<VideoPlane> planes = <VideoPlane>[];
    for (var index = 0; index < format.planeCount; index++) {
      final int stride = format.planeMinBytesPerRow(index) + rowPadding;
      planes.add(VideoPlane(
        bytes: Uint8List(stride * format.planeHeight(index)),
        bytesPerRow: stride,
      ));
    }

    switch (pixelFormat) {
      case VideoPixelFormat.nv12:
        _writeLuma(planes[0], format);
        final VideoPlane chroma = planes[1];
        for (var by = 0; by < format.planeHeight(1); by++) {
          final int row = chroma.rowOffset(by);
          for (var bx = 0; bx < format.planeWidth(1); bx++) {
            chroma.bytes[row + bx * 2] = chromaU(bx, by);
            chroma.bytes[row + bx * 2 + 1] = chromaV(bx, by);
          }
        }
      case VideoPixelFormat.i420:
        _writeLuma(planes[0], format);
        for (var by = 0; by < format.planeHeight(1); by++) {
          final int uRow = planes[1].rowOffset(by);
          final int vRow = planes[2].rowOffset(by);
          for (var bx = 0; bx < format.planeWidth(1); bx++) {
            planes[1].bytes[uRow + bx] = chromaU(bx, by);
            planes[2].bytes[vRow + bx] = chromaV(bx, by);
          }
        }
      case VideoPixelFormat.yuy2:
        final VideoPlane packed = planes[0];
        for (var y = 0; y < height; y++) {
          final int row = packed.rowOffset(y);
          for (var pair = 0; pair < format.planeWidth(0); pair++) {
            final int base = row + pair * 4;
            packed.bytes[base] = luma(pair * 2, y);
            packed.bytes[base + 1] = chromaU(pair, y ~/ 2);
            packed.bytes[base + 2] = luma(pair * 2 + 1, y);
            packed.bytes[base + 3] = chromaV(pair, y ~/ 2);
          }
        }
      case VideoPixelFormat.bgra8888:
      case VideoPixelFormat.rgba8888:
        final VideoPlane packed = planes[0];
        for (var y = 0; y < height; y++) {
          final int row = packed.rowOffset(y);
          for (var x = 0; x < width; x++) {
            final int base = row + x * 4;
            packed.bytes[base] = luma(x, y);
            packed.bytes[base + 1] = chromaU(x ~/ 2, y ~/ 2);
            packed.bytes[base + 2] = chromaV(x ~/ 2, y ~/ 2);
            packed.bytes[base + 3] = 255;
          }
        }
    }

    return VideoFrame(
      format: format,
      planes: planes,
      streamId: streamId,
      sequence: sequence,
    );
  }

  void _writeLuma(VideoPlane plane, VideoFrameFormat format) {
    for (var y = 0; y < height; y++) {
      final int row = plane.rowOffset(y);
      for (var x = 0; x < width; x++) {
        plane.bytes[row + x] = luma(x, y);
      }
    }
  }
}
