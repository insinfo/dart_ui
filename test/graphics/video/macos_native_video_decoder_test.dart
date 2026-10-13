import 'dart:io';

import 'package:dart_ui/src/graphics/video/macos_native_video_decoder.dart';
import 'package:dart_ui/src/graphics/video/video_decoder.dart';
import 'package:test/test.dart';

void main() {
  test('the hot path writes native slots without a managed frame allocation',
      () {
    final String source = File(
      'lib/src/graphics/video/macos_native_video_decoder.dart',
    ).readAsStringSync();

    expect(source, contains('storage.acquire()'));
    expect(source, contains('_memcpy('));
    expect(source, contains('lifetime: decoded.lease'));
    expect(source, isNot(contains('Uint8List(')));
    expect(source, isNot(contains('.asTypedList(')));
  });

  test('the direct backend refuses non-macOS without loading frameworks', () {
    if (Platform.isMacOS) return;
    expect(
      openMacosNativeVideoDecoder('unused.mov', const VideoDecoderOptions()),
      throwsA(
        isA<VideoDecoderException>()
            .having((e) => e.operation, 'operation', 'native-open')
            .having((e) => e.message, 'message', contains('only on macOS')),
      ),
    );
  });

  test('reports the container duration and decodes every frame', () async {
    // 2 s of 160x96 H.264 at 10 fps, written by AVAssetWriter.
    final VideoDecoder decoder = await openMacosNativeVideoDecoder(
      'test/data/tiny_h264.mp4',
      const VideoDecoderOptions(),
    );
    expect(decoder.info.width, 160);
    expect(decoder.info.height, 96);
    expect(decoder.info.duration, const Duration(seconds: 2));
    expect(decoder.info.frameRate, closeTo(10, 0.01));
    var frames = 0;
    for (VideoSample? sample = await decoder.readFrame();
        sample != null;
        sample = await decoder.readFrame()) {
      frames++;
      sample.release();
    }
    expect(frames, 20);
    await decoder.close();
  }, skip: Platform.isMacOS ? null : 'AVFoundation is macOS-only');

  test('seek lands on the requested time', () async {
    final VideoDecoder decoder = await openMacosNativeVideoDecoder(
      'test/data/tiny_h264.mp4',
      const VideoDecoderOptions(),
    );
    await decoder.seek(const Duration(milliseconds: 1500));
    final VideoSample sample = (await decoder.readFrame())!;
    expect(sample.timestamp.inMilliseconds, closeTo(1500, 100));
    // The reader starts at the target. It used to start at the beginning
    // and decode 15 frames to throw away here - on a seven-minute video,
    // eleven seconds of a frozen window to reach 90%.
    expect(debugMacosSeekDiscardedFrames(decoder), lessThan(3));
    sample.release();
    await decoder.close();
  }, skip: Platform.isMacOS ? null : 'AVFoundation is macOS-only');
}
