import 'package:dart_ui/audio.dart';
import 'package:test/test.dart';

/// A clip whose sample at frame `n`, channel `c` is `n + c / 10`.
NativePcmAudioBuffer _ramp({
  required int sampleRate,
  required int channels,
  required int frameCount,
}) {
  final NativePcmAudioBuffer buffer = NativePcmAudioBuffer.allocate(
    sampleRate: sampleRate,
    channels: channels,
    frameCount: frameCount,
  );
  for (int frame = 0; frame < frameCount; frame++) {
    for (int channel = 0; channel < channels; channel++) {
      buffer.setSample(frame, channel, frame + channel / 10);
    }
  }
  return buffer;
}

void main() {
  group('conformPcmBuffer', () {
    test('borrows the clip when it already matches the endpoint', () {
      final NativePcmAudioBuffer source =
          _ramp(sampleRate: 48000, channels: 2, frameCount: 16);
      addTearDown(source.dispose);

      final ConformedPcmBuffer conformed = conformPcmBuffer(
        source,
        sampleRate: 48000,
        channels: 2,
      );
      expect(conformed.ownsBuffer, isFalse,
          reason: 'a matching format must not cost a copy of the whole track');
      expect(identical(conformed.buffer, source), isTrue);

      // Releasing what it does not own must leave the source usable.
      conformed.disposeIfOwned();
      expect(source.isDisposed, isFalse);
      expect(source.sampleAt(3, 1), closeTo(3.1, 1e-6));
    });

    test('resamples to the endpoint rate, keeping the same duration', () {
      final NativePcmAudioBuffer source =
          _ramp(sampleRate: 22050, channels: 1, frameCount: 22050);
      addTearDown(source.dispose);

      final ConformedPcmBuffer conformed = conformPcmBuffer(
        source,
        sampleRate: 44100,
        channels: 1,
      );
      addTearDown(conformed.disposeIfOwned);

      expect(conformed.ownsBuffer, isTrue);
      expect(conformed.buffer.sampleRate, 44100);
      expect(conformed.buffer.frameCount, 44100);
      // The point of resampling: the clip still lasts a second. Playing it
      // unconverted would last half of one, at twice the pitch, and the audio
      // clock would run at twice the speed of the picture.
      expect(conformed.buffer.duration, source.duration);
      // Linear interpolation, so the half-way frames are the midpoints.
      expect(conformed.buffer.sampleAt(0, 0), closeTo(0, 1e-4));
      expect(conformed.buffer.sampleAt(1, 0), closeTo(0.5, 1e-4));
      expect(conformed.buffer.sampleAt(2, 0), closeTo(1, 1e-4));
      expect(conformed.buffer.sampleAt(3, 0), closeTo(1.5, 1e-4));
    });

    test('spreads mono across the endpoint channels', () {
      final NativePcmAudioBuffer source =
          _ramp(sampleRate: 48000, channels: 1, frameCount: 8);
      addTearDown(source.dispose);

      final ConformedPcmBuffer conformed = conformPcmBuffer(
        source,
        sampleRate: 48000,
        channels: 2,
      );
      addTearDown(conformed.disposeIfOwned);

      expect(conformed.buffer.channels, 2);
      expect(conformed.buffer.frameCount, 8);
      for (int frame = 0; frame < 8; frame++) {
        expect(conformed.buffer.sampleAt(frame, 0), closeTo(frame, 1e-4));
        expect(conformed.buffer.sampleAt(frame, 1), closeTo(frame, 1e-4));
      }
    });

    test('folds extra channels down to a mono endpoint', () {
      final NativePcmAudioBuffer source =
          _ramp(sampleRate: 48000, channels: 2, frameCount: 4);
      addTearDown(source.dispose);

      final ConformedPcmBuffer conformed = conformPcmBuffer(
        source,
        sampleRate: 48000,
        channels: 1,
      );
      addTearDown(conformed.disposeIfOwned);

      expect(conformed.buffer.channels, 1);
      for (int frame = 0; frame < 4; frame++) {
        expect(
          conformed.buffer.sampleAt(frame, 0),
          closeTo(frame + 0.05, 1e-4),
          reason: 'a downmix averages, it does not drop a channel',
        );
      }
    });

    test('converts rate and channels together', () {
      final NativePcmAudioBuffer source =
          _ramp(sampleRate: 44100, channels: 1, frameCount: 441);
      addTearDown(source.dispose);

      final ConformedPcmBuffer conformed = conformPcmBuffer(
        source,
        sampleRate: 48000,
        channels: 2,
      );
      addTearDown(conformed.disposeIfOwned);

      expect(conformed.buffer.sampleRate, 48000);
      expect(conformed.buffer.channels, 2);
      expect(conformed.buffer.frameCount, 480);
    });
  });

  group('conformedFrameCount', () {
    test('predicts the length the player will report', () {
      for (final List<int> shape in <List<int>>[
        <int>[44100, 44100, 48000],
        <int>[22050, 22050, 44100],
        <int>[48000, 48000, 44100],
        <int>[1000, 44100, 48000],
      ]) {
        final NativePcmAudioBuffer source = _ramp(
          sampleRate: shape[1],
          channels: 1,
          frameCount: shape[0],
        );
        addTearDown(source.dispose);
        final ConformedPcmBuffer conformed = conformPcmBuffer(
          source,
          sampleRate: shape[2],
          channels: 1,
        );
        addTearDown(conformed.disposeIfOwned);
        expect(
          conformedFrameCount(source, sampleRate: shape[2]),
          conformed.buffer.frameCount,
          reason: 'duration is reported before the conversion happens, so the '
              'prediction has to match it exactly',
        );
      }
    });

    test('is the identity when the rate already matches', () {
      final NativePcmAudioBuffer source =
          _ramp(sampleRate: 48000, channels: 2, frameCount: 12345);
      addTearDown(source.dispose);
      expect(conformedFrameCount(source, sampleRate: 48000), 12345);
    });
  });

  group('NativePcmAudioBuffer.borrow', () {
    test('views samples it does not own', () {
      final NativePcmAudioBuffer owner =
          _ramp(sampleRate: 48000, channels: 2, frameCount: 32);
      addTearDown(owner.dispose);

      final NativePcmAudioBuffer view = NativePcmAudioBuffer.borrow(
        samples: owner.samples,
        sampleRate: owner.sampleRate,
        channels: owner.channels,
        frameCount: owner.frameCount,
      );
      expect(view.sampleAt(5, 1), closeTo(5.1, 1e-6));
      view.dispose();

      // If the view had freed the block, this allocation would very likely be
      // handed the same memory - and NativeAllocator zeroes what it hands out.
      final List<NativePcmAudioBuffer> churn = <NativePcmAudioBuffer>[
        for (int index = 0; index < 8; index++)
          NativePcmAudioBuffer.allocate(
            sampleRate: 48000,
            channels: 2,
            frameCount: 32,
          ),
      ];
      addTearDown(() {
        for (final NativePcmAudioBuffer buffer in churn) {
          buffer.dispose();
        }
      });
      expect(owner.sampleAt(5, 1), closeTo(5.1, 1e-6));
    });

    test('rejects a view that could not describe a clip', () {
      final NativePcmAudioBuffer owner =
          _ramp(sampleRate: 48000, channels: 1, frameCount: 4);
      addTearDown(owner.dispose);
      expect(
        () => NativePcmAudioBuffer.borrow(
          samples: owner.samples,
          sampleRate: 0,
          channels: 1,
          frameCount: 4,
        ),
        throwsRangeError,
      );
      expect(
        () => NativePcmAudioBuffer.borrow(
          samples: owner.samples,
          sampleRate: 48000,
          channels: 0,
          frameCount: 4,
        ),
        throwsRangeError,
      );
    });
  });
}
