/// Allocation-free playback cursor over one native PCM clip.
library;

import 'dart:ffi';

import '../../foundation/lifecycle.dart';
import '../native/native_pcm_audio_buffer.dart';
import 'native_audio_processor.dart';

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
    final double gain = volume.clamp(0.0, 2.0);
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
              clip.samples[sourceBase + channel] * gain;
        }
      }
      _positionFrames += copied;
      outputFrame += copied;
    }
  }

  @override
  void onDispose() {}
}
