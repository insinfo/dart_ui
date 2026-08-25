import 'dart:async';

import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

void main() {
  group('VideoDecoderOptions', () {
    test('defaults form a usable bounded decoder policy', () {
      const options = VideoDecoderOptions();

      expect(options.acceleration, VideoDecoderAcceleration.automatic);
      expect(options.enableFfmpegFallback, isTrue);
      expect(options.maxWidth, 8192);
      expect(options.maxHeight, 8192);
      expect(options.maxFrameBytes, 256 * 1024 * 1024);
      expect(options.validate, returnsNormally);
      expect(
        options.validateDecodedFrame(
          width: 1920,
          height: 1080,
          bytesPerPixel: 4,
        ),
        1920 * 1080 * 4,
      );
    });

    test('each non-positive decoder limit is rejected by the portable seam',
        () {
      for (final options in <VideoDecoderOptions>[
        const VideoDecoderOptions(maxWidth: 0),
        const VideoDecoderOptions(maxHeight: 0),
        const VideoDecoderOptions(maxFrameBytes: 0),
      ]) {
        expect(
          options.validate,
          throwsA(
            isA<VideoDecoderException>()
                .having((error) => error.operation, 'operation', 'open')
                .having(
                    (error) => error.message, 'message', contains('positive')),
          ),
        );
      }
    });

    test('invalid decoded geometry is distinguished from configured limits',
        () {
      const options = VideoDecoderOptions();

      expect(
        () => options.validateDecodedFrame(
          width: 0,
          height: 1080,
          bytesPerPixel: 4,
        ),
        throwsA(
          isA<VideoDecoderException>()
              .having((error) => error.operation, 'operation', 'probe')
              .having(
                  (error) => error.message, 'message', contains('geometry')),
        ),
      );
      expect(
        () => options.validateDecodedFrame(
          width: 1920,
          height: 1080,
          bytesPerPixel: 0,
        ),
        throwsA(isA<VideoDecoderException>()),
      );
    });

    test('dimension and decoded-byte limits are enforced independently', () {
      const dimensions = VideoDecoderOptions(
        maxWidth: 1920,
        maxHeight: 1080,
      );
      const bytes = VideoDecoderOptions(
        maxWidth: 4096,
        maxHeight: 4096,
        maxFrameBytes: 1024,
      );

      expect(
        () => dimensions.validateDecodedFrame(
          width: 1921,
          height: 1080,
          bytesPerPixel: 4,
        ),
        throwsA(
          isA<VideoDecoderException>().having(
              (error) => error.message, 'message', contains('1920x1080')),
        ),
      );
      expect(
        () => bytes.validateDecodedFrame(
          width: 32,
          height: 16,
          bytesPerPixel: 4,
        ),
        throwsA(
          isA<VideoDecoderException>()
              .having(
                  (error) => error.message, 'message', contains('2048 bytes'))
              .having(
                  (error) => error.message, 'message', contains('1024-byte')),
        ),
      );
    });
  });

  group('VideoStreamInfo', () {
    VideoStreamInfo info(double frameRate) => VideoStreamInfo(
          width: 1920,
          height: 1080,
          frameRate: frameRate,
          duration: const Duration(seconds: 5),
          codec: 'h264',
          backend: 'fake',
          hardwareAcceleration: false,
        );

    test('preserves stream metadata and computes fractional frame rates', () {
      final metadata = info(24000 / 1001);

      expect(metadata.width, 1920);
      expect(metadata.height, 1080);
      expect(metadata.duration, const Duration(seconds: 5));
      expect(metadata.codec, 'h264');
      expect(metadata.backend, 'fake');
      expect(metadata.hardwareAcceleration, isFalse);
      expect(
          metadata.nominalFrameDuration, const Duration(microseconds: 41708));
    });

    test('unknown rates use 30 fps and extreme rates remain non-zero', () {
      expect(info(0).nominalFrameDuration, const Duration(microseconds: 33333));
      expect(info(double.nan).nominalFrameDuration,
          const Duration(microseconds: 33333));
      expect(info(double.infinity).nominalFrameDuration,
          const Duration(microseconds: 33333));
      expect(info(1e20).nominalFrameDuration, const Duration(microseconds: 1));
    });
  });

  group('VideoDecoder contract', () {
    test('can be implemented without a native backend', () async {
      final decoder = _FakeVideoDecoder(<VideoSample>[
        _sample(sequence: 0, timestamp: Duration.zero),
        _sample(
          sequence: 1,
          timestamp: const Duration(milliseconds: 40),
        ),
      ]);

      expect((await decoder.readFrame())!.frame.sequence, 0);
      expect((await decoder.readFrame())!.timestamp,
          const Duration(milliseconds: 40));
      expect(await decoder.readFrame(), isNull);
      expect(await decoder.readFrame(), isNull);

      await decoder.seek(Duration.zero);
      expect((await decoder.readFrame())!.frame.sequence, 0);
      await decoder.close();
      await decoder.close();
      expect(decoder.isClosed, isTrue);
      expect(decoder.readFrame, throwsStateError);
      expect(() => decoder.seek(Duration.zero), throwsStateError);
    });

    test('sample and decoder exceptions retain structured context', () {
      final sample = _sample(
        sequence: 7,
        timestamp: const Duration(milliseconds: 280),
      );
      final cause = StateError('native failure');
      final error =
          VideoDecoderException('decode', 'frame failed', cause: cause);

      expect(sample.frame.sequence, 7);
      expect(sample.timestamp, const Duration(milliseconds: 280));
      expect(sample.duration, const Duration(milliseconds: 40));
      expect(error.operation, 'decode');
      expect(error.message, 'frame failed');
      expect(error.cause, same(cause));
      expect(error.toString(), contains('decode: frame failed'));
    });
  });
}

VideoSample _sample({required int sequence, required Duration timestamp}) {
  final frame = VideoFrame.allocate(
    VideoFrameFormat(
      pixelFormat: VideoPixelFormat.bgra8888,
      width: 2,
      height: 2,
      colorSpace: VideoColorSpace.bt709,
      range: VideoColorRange.full,
    ),
    streamId: 99,
    sequence: sequence,
  );
  return VideoSample(
    frame: frame,
    timestamp: timestamp,
    duration: const Duration(milliseconds: 40),
  );
}

final class _FakeVideoDecoder implements VideoDecoder {
  _FakeVideoDecoder(this._samples);

  final List<VideoSample> _samples;
  int _index = 0;
  bool _closed = false;

  @override
  VideoStreamInfo get info => VideoStreamInfo(
        width: 2,
        height: 2,
        frameRate: 25,
        duration: Duration(milliseconds: _samples.length * 40),
        codec: 'synthetic',
        backend: 'test',
        hardwareAcceleration: false,
      );

  @override
  bool get isClosed => _closed;

  @override
  Future<VideoSample?> readFrame() async {
    if (_closed) throw StateError('closed');
    if (_index >= _samples.length) return null;
    return _samples[_index++];
  }

  @override
  Future<void> seek(Duration position) async {
    if (_closed) throw StateError('closed');
    _index = (position.inMilliseconds ~/ 40).clamp(0, _samples.length);
  }

  @override
  Future<void> close() async => _closed = true;
}
