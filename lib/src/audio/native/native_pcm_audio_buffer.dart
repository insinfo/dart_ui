/// Caller-owned interleaved float32 PCM stored outside the Dart heap.
library;

import 'dart:ffi';
import 'dart:math' as math;

import '../../ffi/native_memory.dart';
import '../../foundation/lifecycle.dart';

/// A decoded PCM clip whose samples live in explicitly managed native memory.
///
/// This is the representation consumed by realtime DSP nodes. Decoding and
/// format conversion happen before playback; the audio thread only reads the
/// pointer and advances integer frame cursors.
final class NativePcmAudioBuffer with DisposableMixin {
  NativePcmAudioBuffer.allocate({
    required this.sampleRate,
    required this.channels,
    required this.frameCount,
  }) : samples = NativeAllocator.instance.allocate<Float>(
          _checkedSampleCount(channels, frameCount) * sizeOf<Float>(),
        );

  final int sampleRate;
  final int channels;
  final int frameCount;
  final Pointer<Float> samples;

  int get sampleCount => frameCount * channels;
  Duration get duration => Duration(
        microseconds:
            (frameCount * Duration.microsecondsPerSecond) ~/ sampleRate,
      );

  double sampleAt(int frame, int channel) {
    throwIfDisposed();
    RangeError.checkValidIndex(frame, this, 'frame', frameCount);
    RangeError.checkValidIndex(channel, this, 'channel', channels);
    return samples[frame * channels + channel];
  }

  void setSample(int frame, int channel, double value) {
    throwIfDisposed();
    RangeError.checkValidIndex(frame, this, 'frame', frameCount);
    RangeError.checkValidIndex(channel, this, 'channel', channels);
    samples[frame * channels + channel] = value;
  }

  /// Creates a playback-ready copy using linear resampling and channel
  /// conversion. This method is deliberately an offline operation.
  NativePcmAudioBuffer converted({
    required int sampleRate,
    required int channels,
  }) {
    throwIfDisposed();
    if (sampleRate <= 0 || channels <= 0) {
      throw ArgumentError('sampleRate and channels must be positive');
    }
    final int outputFrames = math.max(
      1,
      (frameCount * sampleRate / this.sampleRate).round(),
    );
    final NativePcmAudioBuffer output = NativePcmAudioBuffer.allocate(
      sampleRate: sampleRate,
      channels: channels,
      frameCount: outputFrames,
    );
    if (frameCount == 0) return output;

    final double ratio = this.sampleRate / sampleRate;
    for (int frame = 0; frame < outputFrames; frame++) {
      final double sourcePosition = frame * ratio;
      final int first = math.min(sourcePosition.floor(), frameCount - 1);
      final int second = math.min(first + 1, frameCount - 1);
      final double fraction = sourcePosition - first;
      for (int channel = 0; channel < channels; channel++) {
        final double a = _mappedSample(first, channel, channels);
        final double b = _mappedSample(second, channel, channels);
        output.samples[frame * channels + channel] = a + (b - a) * fraction;
      }
    }
    return output;
  }

  double _mappedSample(int frame, int outputChannel, int outputChannels) {
    if (channels == outputChannels) {
      return samples[frame * channels + outputChannel];
    }
    if (channels == 1) return samples[frame];
    if (outputChannels == 1) {
      double sum = 0;
      for (int channel = 0; channel < channels; channel++) {
        sum += samples[frame * channels + channel];
      }
      return sum / channels;
    }
    return samples[frame * channels + math.min(outputChannel, channels - 1)];
  }

  @override
  void onDispose() => NativeAllocator.instance.free(samples);

  static int _checkedSampleCount(int channels, int frames) {
    if (channels <= 0) {
      throw RangeError.value(channels, 'channels', 'must be positive');
    }
    if (frames < 0) {
      throw RangeError.value(frames, 'frameCount', 'must not be negative');
    }
    return channels * frames;
  }
}
