/// Allocation-free playback cursor over one native PCM clip.
library;

import 'dart:ffi';

import '../../foundation/lifecycle.dart';
import '../native/native_pcm_audio_buffer.dart';
import 'native_audio_processor.dart';
import 'native_gain.dart';

/// Plays a prepared PCM clip into caller-owned float32 output blocks.
///
/// The clip is borrowed and must outlive this player. All controls are intended
/// to be changed by the same audio isolate immediately before [process].
final class NativePcmClipPlayer
    with DisposableMixin
    implements NativeFloat32AudioProcessor {
  NativePcmClipPlayer(this.clip)
      : sampleRate = clip.sampleRate,
        channels = clip.channels;

  final NativePcmAudioBuffer clip;
  @override
  final int sampleRate;
  @override
  final int channels;

  bool playing = false;
  bool loop = false;

  /// A mix level for this one clip, clamped to 0..2.
  ///
  /// Not the same thing as `AudioStream.gain` and deliberately not merged into
  /// it: this is per-*source*, applied before anything mixes several sources
  /// together, and a caller that wants one level over the whole output sets
  /// the stream's gain instead. Unity costs nothing here too - see [process].
  double volume = 1;
  int _positionFrames = 0;

  int get positionFrames => _positionFrames;
  double get positionFraction =>
      clip.frameCount == 0 ? 0 : _positionFrames / clip.frameCount;
  bool get isAtEnd => clip.frameCount > 0 && _positionFrames >= clip.frameCount;

  void seekToFrame(int frame) {
    throwIfDisposed();
    _positionFrames = frame.clamp(0, clip.frameCount);
  }

  void seekToFraction(double fraction) =>
      seekToFrame((clip.frameCount * fraction.clamp(0.0, 1.0)).round());

  @override
  void process(Pointer<Float> interleavedSamples, int frames) {
    throwIfDisposed();
    final int sampleCount = frames * channels;
    for (int index = 0; index < sampleCount; index++) {
      interleavedSamples[index] = 0;
    }
    if (!playing || clip.frameCount == 0) return;

    int outputFrame = 0;
    while (outputFrame < frames && playing) {
      if (_positionFrames >= clip.frameCount) {
        if (loop) {
          _positionFrames = 0;
        } else {
          playing = false;
          break;
        }
      }
      final int remainingOutput = frames - outputFrame;
      final int remainingClip = clip.frameCount - _positionFrames;
      final int copied =
          remainingOutput < remainingClip ? remainingOutput : remainingClip;
      for (int frame = 0; frame < copied; frame++) {
        final int sourceBase = (_positionFrames + frame) * channels;
        final int outputBase = (outputFrame + frame) * channels;
        for (int channel = 0; channel < channels; channel++) {
          interleavedSamples[outputBase + channel] =
              clip.samples[sourceBase + channel];
        }
      }
      _positionFrames += copied;
      outputFrame += copied;
    }

    // One pass at the end rather than a multiply inside the copy loop, for the
    // property the copy loop could not have: at [volume] 1.0 - which is the
    // default and the normal case - this returns without touching a sample, so
    // the block that leaves here is bit-identical to the clip. The old form
    // multiplied every sample by a `gain` that was 1.0, which is the same
    // number but not the same guarantee, and it cost a multiply per sample to
    // arrive at it.
    applyNativeFloat32Gain(
      interleavedSamples,
      sampleCount,
      volume.clamp(0.0, 2.0),
    );
  }

  @override
  void onDispose() {}
}
