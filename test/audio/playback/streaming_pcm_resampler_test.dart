/// The block resampler, held against the whole-track one it has to replace.
///
/// The interesting assertion in this file is not "the output sounds right", it
/// is "the output is the same as `NativePcmAudioBuffer.converted` produced,
/// frame for frame, *including the frames that sit on a block boundary*".
/// Block boundaries are where a resampler that forgets its phase or its last
/// source frame emits a step discontinuity, and a few hundred of those a
/// second is an audible buzz. A tolerance test on the average would pass with
/// that bug in place; a frame-by-frame comparison against the reference will
/// not.
library;

import 'dart:ffi';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:dart_ui/audio.dart';
import 'package:test/test.dart';

/// A source whose every frame is distinguishable from its neighbours, so a
/// misaligned block shows up as a value that belongs somewhere else.
Float32List _source({
  required int frames,
  required int channels,
  required int sampleRate,
}) {
  final Float32List samples = Float32List(frames * channels);
  for (int frame = 0; frame < frames; frame++) {
    for (int channel = 0; channel < channels; channel++) {
      samples[frame * channels + channel] = 0.5 *
              math.sin(
                  2 * math.pi * (110.0 + channel * 37) * frame / sampleRate) +
          0.2 * math.sin(2 * math.pi * 3000 * frame / sampleRate);
    }
  }
  return samples;
}

NativePcmAudioBuffer _asNative(
  Float32List samples, {
  required int sampleRate,
  required int channels,
}) {
  final int frames = samples.length ~/ channels;
  final NativePcmAudioBuffer buffer = NativePcmAudioBuffer.allocate(
    sampleRate: sampleRate,
    channels: channels,
    frameCount: frames,
  );
  buffer.samples.asTypedList(samples.length).setAll(0, samples);
  return buffer;
}

/// Runs [source] through the streaming resampler in blocks of [blockFrames]
/// and returns everything it produced.
Float32List _resampleInBlocks(
  Float32List source, {
  required int sourceSampleRate,
  required int sourceChannels,
  required int targetSampleRate,
  required int targetChannels,
  required int blockFrames,
  int readFrames = 61,
}) {
  final StreamingPcmResampler resampler = StreamingPcmResampler(
    sourceSampleRate: sourceSampleRate,
    sourceChannels: sourceChannels,
    targetSampleRate: targetSampleRate,
    targetChannels: targetChannels,
  );
  final int sourceFrames = source.length ~/ sourceChannels;
  final List<double> output = <double>[];
  final Float32List scratch = Float32List(readFrames * targetChannels);
  final Float32List block = Float32List(blockFrames * sourceChannels);

  void drain() {
    while (true) {
      final int produced = resampler.read(scratch, readFrames);
      if (produced == 0) return;
      output.addAll(scratch.sublist(0, produced * targetChannels));
    }
  }

  for (int offset = 0; offset < sourceFrames; offset += blockFrames) {
    final int frames = math.min(blockFrames, sourceFrames - offset);
    block.setRange(
      0,
      frames * sourceChannels,
      source,
      offset * sourceChannels,
    );
    resampler.addSource(block, frames);
    drain();
  }
  resampler.endOfSource();
  drain();
  expect(resampler.isFinished, isTrue);
  return Float32List.fromList(output);
}

void _expectMatchesConverted(
  Float32List source, {
  required int sourceSampleRate,
  required int sourceChannels,
  required int targetSampleRate,
  required int targetChannels,
  required int blockFrames,
}) {
  final NativePcmAudioBuffer native = _asNative(
    source,
    sampleRate: sourceSampleRate,
    channels: sourceChannels,
  );
  addTearDown(native.dispose);
  final NativePcmAudioBuffer reference = native.converted(
    sampleRate: targetSampleRate,
    channels: targetChannels,
  );
  addTearDown(reference.dispose);

  final Float32List streamed = _resampleInBlocks(
    source,
    sourceSampleRate: sourceSampleRate,
    sourceChannels: sourceChannels,
    targetSampleRate: targetSampleRate,
    targetChannels: targetChannels,
    blockFrames: blockFrames,
  );

  expect(
    streamed.length ~/ targetChannels,
    reference.frameCount,
    reason: 'block resampling produced a different number of frames',
  );
  final List<double> expected =
      reference.samples.asTypedList(reference.sampleCount);
  for (int index = 0; index < expected.length; index++) {
    expect(
      streamed[index],
      closeTo(expected[index], 1e-6),
      reason: 'sample $index (frame ${index ~/ targetChannels}) differs; '
          'block size $blockFrames',
    );
  }
}

void main() {
  group('block resampling equals whole-track resampling', () {
    const int sourceRate = 44100;
    const int targetRate = 48000;

    for (final int blockFrames in <int>[1, 7, 128, 1024, 4099]) {
      test('44.1 -> 48 kHz stereo, blocks of $blockFrames frames', () {
        _expectMatchesConverted(
          _source(frames: 9000, channels: 2, sampleRate: sourceRate),
          sourceSampleRate: sourceRate,
          sourceChannels: 2,
          targetSampleRate: targetRate,
          targetChannels: 2,
          blockFrames: blockFrames,
        );
      });
    }

    test('48 -> 44.1 kHz downsamples across blocks', () {
      _expectMatchesConverted(
        _source(frames: 9000, channels: 2, sampleRate: targetRate),
        sourceSampleRate: targetRate,
        sourceChannels: 2,
        targetSampleRate: sourceRate,
        targetChannels: 2,
        blockFrames: 333,
      );
    });

    test('mono source widened to stereo', () {
      _expectMatchesConverted(
        _source(frames: 5000, channels: 1, sampleRate: sourceRate),
        sourceSampleRate: sourceRate,
        sourceChannels: 1,
        targetSampleRate: targetRate,
        targetChannels: 2,
        blockFrames: 97,
      );
    });

    test('stereo source folded down to mono', () {
      _expectMatchesConverted(
        _source(frames: 5000, channels: 2, sampleRate: sourceRate),
        sourceSampleRate: sourceRate,
        sourceChannels: 2,
        targetSampleRate: targetRate,
        targetChannels: 1,
        blockFrames: 512,
      );
    });

    test('a matching format still round-trips exactly', () {
      _expectMatchesConverted(
        _source(frames: 3000, channels: 2, sampleRate: targetRate),
        sourceSampleRate: targetRate,
        sourceChannels: 2,
        targetSampleRate: targetRate,
        targetChannels: 2,
        blockFrames: 64,
      );
    });

    test('a big rate change - 8 kHz up to 48 kHz - keeps its phase', () {
      _expectMatchesConverted(
        _source(frames: 2000, channels: 1, sampleRate: 8000),
        sourceSampleRate: 8000,
        sourceChannels: 1,
        targetSampleRate: targetRate,
        targetChannels: 1,
        blockFrames: 17,
      );
    });
  });

  test('no step discontinuity appears at a block boundary', () {
    // The click test, stated directly rather than through the reference: a
    // pure ramp resampled correctly is still a ramp, so every consecutive
    // difference is the same. A resampler that restarted its phase at each
    // block would show a difference of a different size exactly at the
    // boundaries.
    const int blockFrames = 100;
    const int sourceFrames = 2000;
    final Float32List ramp = Float32List(sourceFrames);
    for (int frame = 0; frame < sourceFrames; frame++) {
      ramp[frame] = frame / sourceFrames;
    }
    final Float32List streamed = _resampleInBlocks(
      ramp,
      sourceSampleRate: 44100,
      sourceChannels: 1,
      targetSampleRate: 48000,
      targetChannels: 1,
      blockFrames: blockFrames,
      readFrames: 23,
    );

    final double step = streamed[1] - streamed[0];
    // The final frames repeat the clamped last source frame, so the ramp's
    // slope only holds while the interpolation is still inside the source.
    const int slopeFrames = (sourceFrames - 2) * 48000 ~/ 44100;
    for (int frame = 1; frame < slopeFrames; frame++) {
      expect(
        streamed[frame] - streamed[frame - 1],
        closeTo(step, 1e-6),
        reason: 'the ramp is not straight at output frame $frame, which is '
            'the discontinuity a per-block resampler introduces',
      );
    }
  });

  group('lifecycle', () {
    test('holds only a bounded window regardless of how much is fed', () {
      final StreamingPcmResampler resampler = StreamingPcmResampler(
        sourceSampleRate: 44100,
        sourceChannels: 2,
        targetSampleRate: 48000,
        targetChannels: 2,
      );
      final Float32List block = Float32List(1024 * 2);
      final Float32List out = Float32List(4096 * 2);
      for (int round = 0; round < 200; round++) {
        resampler.addSource(block, 1024);
        while (resampler.read(out, 4096) > 0) {}
        expect(
          resampler.pendingSourceFrames,
          lessThanOrEqualTo(2),
          reason: 'the held window must not grow with the length of the file',
        );
      }
      expect(resampler.sourceFramesAccepted, 200 * 1024);
    });

    test('reset rewinds the phase for a seek', () {
      final StreamingPcmResampler resampler = StreamingPcmResampler(
        sourceSampleRate: 44100,
        sourceChannels: 1,
        targetSampleRate: 48000,
        targetChannels: 1,
      );
      final Float32List source = _source(
        frames: 500,
        channels: 1,
        sampleRate: 44100,
      );
      final Float32List first = Float32List(600);
      resampler.addSource(source);
      resampler.endOfSource();
      final int producedFirst = resampler.read(first, 600);

      resampler.reset();
      expect(resampler.outputFramesProduced, 0);
      expect(resampler.isSourceEnded, isFalse);
      final Float32List second = Float32List(600);
      resampler.addSource(source);
      resampler.endOfSource();
      final int producedSecond = resampler.read(second, 600);

      expect(producedSecond, producedFirst);
      for (int index = 0; index < producedFirst; index++) {
        expect(second[index], first[index]);
      }
    });

    test('an empty source yields the one silent frame `converted` yields', () {
      final StreamingPcmResampler resampler = StreamingPcmResampler(
        sourceSampleRate: 44100,
        sourceChannels: 2,
        targetSampleRate: 48000,
        targetChannels: 2,
      )..endOfSource();
      final Float32List out = Float32List(64);
      expect(resampler.read(out, 32), 1);
      expect(out[0], 0);
      expect(out[1], 0);
      expect(resampler.isFinished, isTrue);
    });

    test('rejects source after the end and nonsense formats', () {
      final StreamingPcmResampler resampler = StreamingPcmResampler(
        sourceSampleRate: 44100,
        sourceChannels: 1,
        targetSampleRate: 48000,
        targetChannels: 1,
      )..endOfSource();
      expect(() => resampler.addSource(Float32List(8)), throwsStateError);
      expect(
        () => StreamingPcmResampler(
          sourceSampleRate: 0,
          sourceChannels: 1,
          targetSampleRate: 48000,
          targetChannels: 1,
        ),
        throwsRangeError,
      );
      expect(
        () => StreamingPcmResampler(
          sourceSampleRate: 44100,
          sourceChannels: 1,
          targetSampleRate: 48000,
          targetChannels: 0,
        ),
        throwsRangeError,
      );
    });
  });
}
