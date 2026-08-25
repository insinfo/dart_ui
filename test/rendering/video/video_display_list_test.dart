/// A video frame travelling the display list, end to end, with no GPU.
///
/// This is the test that decides the display-list question. There is no
/// `opDrawVideoFrame`: a frame goes through the existing [opDrawImage], as an
/// interned image resource whose runtime type happens to be [VideoFrame]. The
/// tests below are the argument for that choice, made executable -
/// deduplication, transform, clip and opacity all work on a video frame
/// *because they already worked on an image*, and not one line of the encoder,
/// the reader or the player knows that video exists.
///
/// What a new opcode would have bought is nothing, and what it would have cost
/// is a new method on `RasterSink`, which every sink in the tree implements -
/// including two owned by other backends that would have had to change in
/// lockstep to keep compiling.
library;

import 'package:dart_ui/src/graphics/display_list.dart';
import 'package:dart_ui/src/graphics/image/decoded_image.dart';
import 'package:dart_ui/src/graphics/video/video_color_conversion.dart';
import 'package:dart_ui/src/graphics/video/video_frame.dart';
import 'package:dart_ui/src/rendering/cpu_renderer.dart';
import 'package:dart_ui/src/rendering/framebuffer.dart';
import 'package:dart_ui/src/rendering/renderer.dart';
import 'package:test/test.dart';

import '../../graphics/video/synthetic_frames.dart';

VideoFrame _redBlueFrame() {
  final VideoFrame frame = VideoFrame.allocate(
    VideoFrameFormat(
      pixelFormat: VideoPixelFormat.rgba8888,
      width: 2,
      height: 1,
      range: VideoColorRange.full,
    ),
    streamId: 91,
  );
  frame.plane(0).bytes.setAll(0, <int>[
    255,
    0,
    0,
    255,
    0,
    0,
    255,
    255,
  ]);
  return frame;
}

void main() {
  Future<MemoryRenderTarget> targetOf(int width, int height) async {
    final device = await const CpuRendererBackend().createDevice();
    return device.createTarget(
      MemorySurfaceDescriptor(pixelWidth: width, pixelHeight: height),
    ) as MemoryRenderTarget;
  }

  List<int> pixelAt(Framebuffer buffer, int x, int y) {
    final int offset = buffer.offsetOf(x, y);
    final ImageChannelOrder order =
        buffer.format == PixelFormat.bgra8888Premultiplied
            ? ImageChannelOrder.bgra
            : ImageChannelOrder.rgba;
    return <int>[
      buffer.pixels[offset + order.redIndex],
      buffer.pixels[offset + 1],
      buffer.pixels[offset + order.blueIndex],
      buffer.pixels[offset + 3],
    ];
  }

  final SyntheticPicture picture = SyntheticPicture.ramp(8, 8);

  group('resource interning', () {
    test('a frame drawn twice interns one id, like a path', () {
      final VideoFrame frame = picture.encode(VideoPixelFormat.nv12);
      final list = DisplayList();
      final int first = list.addImage(frame);
      final int second = list.addImage(frame);
      expect(second, first);
      expect(list.imageCount, 1);
      expect(list.imageAt(first), same(frame));
    });

    test('an equal frame from the same stream interns the same id', () {
      // Identity is (streamId, sequence), so a source that rebuilds its frame
      // object around the same planes does not double the resource table.
      final list = DisplayList();
      expect(
        list.addImage(picture.encode(VideoPixelFormat.nv12)),
        list.addImage(picture.encode(VideoPixelFormat.nv12)),
      );
      expect(list.imageCount, 1);
    });

    test('the next frame of a stream is a new id', () {
      final list = DisplayList();
      list
        ..addImage(picture.encode(VideoPixelFormat.nv12, sequence: 0))
        ..addImage(picture.encode(VideoPixelFormat.nv12, sequence: 1));
      expect(list.imageCount, 2);
    });

    test('two streams never share an id', () {
      final list = DisplayList();
      list
        ..addImage(picture.encode(VideoPixelFormat.nv12, streamId: 1))
        ..addImage(picture.encode(VideoPixelFormat.nv12, streamId: 2));
      expect(list.imageCount, 2);
    });
  });

  group('the CPU fallback', () {
    test('scales the converted frame to the destination rectangle', () async {
      final VideoFrame frame = _redBlueFrame();
      final MemoryRenderTarget target = await targetOf(4, 2);
      final DisplayList list = DisplayList();
      final int paint = list.addPaint(colorArgb: 0xFFFFFFFF);
      list.drawImage(list.addImage(frame), 0, 0, 2, 1, 0, 0, 4, 2, paint);

      await target.renderDisplayList(list, clearColor: 0);

      for (var y = 0; y < 2; y++) {
        expect(pixelAt(target.framebuffer, 0, y), <int>[255, 0, 0, 255]);
        expect(pixelAt(target.framebuffer, 1, y), <int>[255, 0, 0, 255]);
        expect(pixelAt(target.framebuffer, 2, y), <int>[0, 0, 255, 255]);
        expect(pixelAt(target.framebuffer, 3, y), <int>[0, 0, 255, 255]);
      }
    });

    test('fractional destination uses its snapped pixel extent', () async {
      final VideoFrame frame = _redBlueFrame();
      final MemoryRenderTarget target = await targetOf(3, 1);
      final DisplayList list = DisplayList();
      final int paint = list.addPaint(colorArgb: 0xFFFFFFFF);
      list.drawImage(
        list.addImage(frame),
        0,
        0,
        2,
        1,
        0.6,
        0,
        2.4,
        1,
        paint,
      );

      await target.renderDisplayList(list, clearColor: 0);

      expect(pixelAt(target.framebuffer, 0, 0), <int>[0, 0, 0, 0]);
      expect(pixelAt(target.framebuffer, 1, 0), <int>[0, 0, 255, 255]);
      expect(pixelAt(target.framebuffer, 2, 0), <int>[0, 0, 0, 0]);
    });

    test('draws the frame the reference converter produces', () async {
      final VideoFrame frame = picture.encode(VideoPixelFormat.nv12);
      final MemoryRenderTarget target = await targetOf(16, 16);
      final list = DisplayList();
      final int paint = list.addPaint(colorArgb: 0xFFFFFFFF);
      list.drawImage(list.addImage(frame), 0, 0, 8, 8, 2, 1, 10, 9, paint);

      final result = await target.renderDisplayList(list, clearColor: 0);
      expect(result.status, PresentStatus.presented);

      final expected = convertVideoFrameToRgba(frame);
      for (var y = 0; y < 8; y++) {
        for (var x = 0; x < 8; x++) {
          final int source = (y * 8 + x) * 4;
          expect(
            pixelAt(target.framebuffer, x + 2, y + 1),
            <int>[
              expected[source],
              expected[source + 1],
              expected[source + 2],
              expected[source + 3],
            ],
            reason: 'at $x, $y - deviation must be zero, both paths run the '
                'same converter',
          );
        }
      }
      // And nothing outside the destination was touched.
      expect(pixelAt(target.framebuffer, 0, 0), <int>[0, 0, 0, 0]);
      expect(pixelAt(target.framebuffer, 12, 12), <int>[0, 0, 0, 0]);
    });

    test('every layout draws the same picture', () async {
      final List<List<int>> drawn = <List<int>>[];
      for (final VideoPixelFormat format in <VideoPixelFormat>[
        VideoPixelFormat.nv12,
        VideoPixelFormat.i420,
        VideoPixelFormat.yuy2,
      ]) {
        final MemoryRenderTarget target = await targetOf(8, 8);
        final list = DisplayList();
        final int paint = list.addPaint(colorArgb: 0xFFFFFFFF);
        list.drawImage(
          list.addImage(picture.encode(format)),
          0,
          0,
          8,
          8,
          0,
          0,
          8,
          8,
          paint,
        );
        await target.renderDisplayList(list, clearColor: 0);
        drawn.add(List<int>.of(target.framebuffer.pixels));
      }
      expect(drawn[1], orderedEquals(drawn[0]));
      expect(drawn[2], orderedEquals(drawn[0]));
    });

    test('honours the source rectangle as a crop', () async {
      final VideoFrame frame = picture.encode(VideoPixelFormat.i420);
      final MemoryRenderTarget target = await targetOf(8, 8);
      final list = DisplayList();
      final int paint = list.addPaint(colorArgb: 0xFFFFFFFF);
      list.drawImage(list.addImage(frame), 2, 2, 6, 6, 0, 0, 4, 4, paint);
      await target.renderDisplayList(list, clearColor: 0);

      final expected = convertVideoFrameToRgba(
        frame,
        region: const VideoRegion(2, 2, 6, 6),
      );
      for (var y = 0; y < 4; y++) {
        for (var x = 0; x < 4; x++) {
          final int source = (y * 4 + x) * 4;
          expect(pixelAt(target.framebuffer, x, y).take(3),
              expected.sublist(source, source + 3));
        }
      }
    });

    test('honours the clip', () async {
      final VideoFrame frame = picture.encode(VideoPixelFormat.nv12);
      final MemoryRenderTarget target = await targetOf(8, 8);
      final list = DisplayList();
      final int paint = list.addPaint(colorArgb: 0xFFFFFFFF);
      list
        ..save()
        ..clipRect(0, 0, 4, 8)
        ..drawImage(list.addImage(frame), 0, 0, 8, 8, 0, 0, 8, 8, paint)
        ..restore();
      await target.renderDisplayList(list, clearColor: 0);

      expect(pixelAt(target.framebuffer, 3, 4)[3], 255);
      expect(pixelAt(target.framebuffer, 4, 4), <int>[0, 0, 0, 0]);
    });

    test('honours the translation in the transform', () async {
      final VideoFrame frame = picture.encode(VideoPixelFormat.nv12);
      final MemoryRenderTarget target = await targetOf(16, 16);
      final list = DisplayList();
      final int paint = list.addPaint(colorArgb: 0xFFFFFFFF);
      list
        ..save()
        ..transform(1, 0, 0, 1, 5, 3)
        ..drawImage(list.addImage(frame), 0, 0, 8, 8, 0, 0, 8, 8, paint)
        ..restore();
      await target.renderDisplayList(list, clearColor: 0);

      final expected = convertVideoFrameToRgba(frame);
      expect(pixelAt(target.framebuffer, 5, 3).take(3), expected.sublist(0, 3));
      expect(pixelAt(target.framebuffer, 4, 3), <int>[0, 0, 0, 0]);
    });

    test('the paint alpha is a premultiplied opacity', () async {
      final VideoFrame frame = picture.encode(VideoPixelFormat.nv12);
      final MemoryRenderTarget target = await targetOf(8, 8);
      final list = DisplayList();
      final int paint = list.addPaint(colorArgb: 0x80FFFFFF);
      list.drawImage(list.addImage(frame), 0, 0, 8, 8, 0, 0, 8, 8, paint);
      await target.renderDisplayList(list, clearColor: 0);

      final expected = convertVideoFrameToRgba(frame, opacity: 0x80);
      for (var y = 0; y < 8; y++) {
        for (var x = 0; x < 8; x++) {
          final int source = (y * 8 + x) * 4;
          expect(
            pixelAt(target.framebuffer, x, y),
            expected.sublist(source, source + 4),
            reason: 'at $x, $y',
          );
        }
      }
    });

    test('a fully transparent paint draws nothing', () async {
      final MemoryRenderTarget target = await targetOf(8, 8);
      final list = DisplayList();
      final int paint = list.addPaint(colorArgb: 0x00FFFFFF);
      list.drawImage(
        list.addImage(picture.encode(VideoPixelFormat.nv12)),
        0,
        0,
        8,
        8,
        0,
        0,
        8,
        8,
        paint,
      );
      await target.renderDisplayList(list, clearColor: 0);
      expect(pixelAt(target.framebuffer, 4, 4), <int>[0, 0, 0, 0]);
    });

    test('an image the CPU renderer cannot draw is named, not ignored',
        () async {
      final MemoryRenderTarget target = await targetOf(8, 8);
      final list = DisplayList();
      final int paint = list.addPaint(colorArgb: 0xFFFFFFFF);
      list.drawImage(
          list.addImage('not an image'), 0, 0, 8, 8, 0, 0, 8, 8, paint);
      await expectLater(
        target.renderDisplayList(list, clearColor: 0),
        throwsA(isA<ArgumentError>()),
      );
    });
  });
}
