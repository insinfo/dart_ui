/// Allocation-free polyphonic playback of decoded native PCM clips.
library;

import 'dart:ffi';
import 'dart:math' as math;

import '../../ffi/native_memory.dart';
import '../../foundation/lifecycle.dart';
import '../native/native_pcm_audio_buffer.dart';
import 'native_audio_processor.dart';

/// Mixes prepared float32 clips with a fixed pool of realtime voices.
///
/// Every clip must already match [sampleRate] and [channels]. [trigger] and
/// [process] are allocation-free and are intended to run in the audio isolate.
/// Clip ownership remains with the caller.
final class NativeSampleMixer
    with DisposableMixin
    implements NativeFloat32AudioProcessor {
  NativeSampleMixer({
    required this.sampleRate,
    required this.channels,
    required List<NativePcmAudioBuffer> samples,
    this.maxVoices = 32,
  })  : samples = List<NativePcmAudioBuffer>.unmodifiable(samples),
        _sampleIndices = NativeAllocator.instance.allocate<Int32>(
          maxVoices * sizeOf<Int32>(),
        ),
        _positions = NativeAllocator.instance.allocate<Int64>(
          maxVoices * sizeOf<Int64>(),
        ),
        _gains = NativeAllocator.instance.allocate<Float>(
          maxVoices * sizeOf<Float>(),
        ),
        _chokeGroups = NativeAllocator.instance.allocate<Int32>(
          maxVoices * sizeOf<Int32>(),
        ),
        _active = NativeAllocator.instance.allocate<Uint8>(maxVoices) {
    if (sampleRate <= 0 || channels <= 0 || maxVoices <= 0) {
      throw ArgumentError(
          'sampleRate, channels and maxVoices must be positive');
    }
    for (final NativePcmAudioBuffer sample in samples) {
      if (sample.sampleRate != sampleRate || sample.channels != channels) {
        throw ArgumentError(
            'every sample must match $sampleRate Hz / $channels channels');
      }
    }
    for (int voice = 0; voice < maxVoices; voice++) {
      _sampleIndices[voice] = -1;
      _chokeGroups[voice] = -1;
    }
  }

  @override
  final int sampleRate;
  @override
  final int channels;
  final List<NativePcmAudioBuffer> samples;
  final int maxVoices;
  final Pointer<Int32> _sampleIndices;
  final Pointer<Int64> _positions;
  final Pointer<Float> _gains;
  final Pointer<Int32> _chokeGroups;
  final Pointer<Uint8> _active;
  int _nextVoice = 0;

  double outputGain = 1;

  int get activeVoiceCount {
    throwIfDisposed();
    int count = 0;
    for (int voice = 0; voice < maxVoices; voice++) {
      if (_active[voice] != 0) count++;
    }
    return count;
  }

  /// Starts a clip and returns the selected voice. A non-negative choke group
  /// stops older voices in the same group, as required by open/closed hi-hats.
  int trigger(int sampleIndex, {double gain = 1, int chokeGroup = -1}) {
    throwIfDisposed();
    RangeError.checkValidIndex(sampleIndex, samples, 'sampleIndex');
    if (chokeGroup >= 0) choke(chokeGroup);
    int selected = -1;
    for (int offset = 0; offset < maxVoices; offset++) {
      final int candidate = (_nextVoice + offset) % maxVoices;
      if (_active[candidate] == 0) {
        selected = candidate;
        break;
      }
    }
    selected = selected < 0 ? _nextVoice : selected;
    _nextVoice = (selected + 1) % maxVoices;
    _sampleIndices[selected] = sampleIndex;
    _positions[selected] = 0;
    _gains[selected] = gain.clamp(0.0, 4.0);
    _chokeGroups[selected] = chokeGroup;
    _active[selected] = 1;
    return selected;
  }

  void choke(int group) {
    throwIfDisposed();
    for (int voice = 0; voice < maxVoices; voice++) {
      if (_active[voice] != 0 && _chokeGroups[voice] == group) {
        _active[voice] = 0;
      }
    }
  }

  void reset() {
    throwIfDisposed();
    for (int voice = 0; voice < maxVoices; voice++) {
      _active[voice] = 0;
    }
  }

  @override
  void process(Pointer<Float> interleavedSamples, int frames) {
    throwIfDisposed();
    final int outputSamples = frames * channels;
    for (int index = 0; index < outputSamples; index++) {
      interleavedSamples[index] = 0;
    }
    final double master = outputGain;
    for (int voice = 0; voice < maxVoices; voice++) {
      if (_active[voice] == 0) continue;
      final NativePcmAudioBuffer clip = samples[_sampleIndices[voice]];
      int position = _positions[voice];
      final int available = clip.frameCount - position;
      final int mixedFrames = math.min(frames, available);
      final double gain = _gains[voice] * master;
      for (int frame = 0; frame < mixedFrames; frame++) {
        final int sourceBase = (position + frame) * channels;
        final int outputBase = frame * channels;
        for (int channel = 0; channel < channels; channel++) {
          interleavedSamples[outputBase + channel] +=
              clip.samples[sourceBase + channel] * gain;
        }
      }
      position += mixedFrames;
      _positions[voice] = position;
      if (position >= clip.frameCount) _active[voice] = 0;
    }
    // A smooth rational saturator prevents coincident drum hits from clipping
    // while retaining substantially more transient detail than a hard clamp.
    for (int index = 0; index < outputSamples; index++) {
      final double value = interleavedSamples[index];
      interleavedSamples[index] = value / (1 + value.abs() * 0.28);
    }
  }

  @override
  void onDispose() {
    NativeAllocator.instance
      ..free(_active)
      ..free(_chokeGroups)
      ..free(_gains)
      ..free(_positions)
      ..free(_sampleIndices);
  }
}
