/// A native-memory Schroeder reverb implemented entirely in Dart FFI.
library;

import 'dart:ffi';

import '../../ffi/native_memory.dart';
import '../../foundation/lifecycle.dart';
import 'native_audio_processor.dart';

/// Lightweight room reverb: four parallel damped combs followed by two
/// serial all-pass filters for each channel.
///
/// Delay samples and filter state live in manually managed native memory.
/// [processInPlace] performs no collection allocation and can run inside the
/// WASAPI event period.
final class NativeSchroederReverb
    with DisposableMixin
    implements NativeFloat32AudioEffect {
  NativeSchroederReverb({
    required this.sampleRate,
    required this.channels,
    double wet = 0.28,
    double roomSize = 0.72,
    double damping = 0.24,
  })  : assert(sampleRate > 0),
        assert(channels > 0),
        _wet = _unit(wet),
        _roomSize = _feedback(roomSize),
        _damping = _unit(damping) {
    const List<int> combTunings = <int>[1557, 1617, 1491, 1422];
    const List<int> allPassTunings = <int>[225, 556];
    final double scale = sampleRate / 44100.0;
    for (int channel = 0; channel < channels; channel++) {
      final int spread = channel * 23;
      for (final int tuning in combTunings) {
        _combs.add(_NativeCombFilter(
          _scaledLength(tuning + spread, scale),
          feedback: _roomSize,
          damping: _damping,
        ));
      }
      for (final int tuning in allPassTunings) {
        _allPasses.add(
          _NativeAllPassFilter(_scaledLength(tuning + spread, scale)),
        );
      }
    }
  }

  @override
  final int sampleRate;
  @override
  final int channels;

  static const int _combsPerChannel = 4;
  static const int _allPassesPerChannel = 2;
  final List<_NativeCombFilter> _combs = <_NativeCombFilter>[];
  final List<_NativeAllPassFilter> _allPasses = <_NativeAllPassFilter>[];

  double _wet;
  double _roomSize;
  double _damping;

  double get wet => _wet;
  set wet(double value) {
    final double next = _unit(value);
    if (next == _wet) return;
    _wet = next;
  }

  double get roomSize => (_roomSize - 0.55) / 0.4;
  set roomSize(double value) {
    final double next = _feedback(value);
    if (next == _roomSize) return;
    _roomSize = next;
    for (final _NativeCombFilter comb in _combs) {
      comb.feedback = _roomSize;
    }
  }

  double get damping => _damping;
  set damping(double value) {
    final double next = _unit(value);
    if (next == _damping) return;
    _damping = next;
    for (final _NativeCombFilter comb in _combs) {
      comb.damping = _damping;
    }
  }

  @override
  void processInPlace(Pointer<Float> interleavedSamples, int frames) {
    throwIfDisposed();
    if (interleavedSamples == nullptr) {
      throw ArgumentError.value(
          interleavedSamples, 'interleavedSamples', 'must not be null');
    }
    if (frames <= 0) return;
    final double wetMix = _wet;
    final double dryMix = 1.0 - wetMix * 0.45;
    for (int frame = 0; frame < frames; frame++) {
      final int frameBase = frame * channels;
      for (int channel = 0; channel < channels; channel++) {
        final int sampleIndex = frameBase + channel;
        final double input = interleavedSamples[sampleIndex];
        final int combBase = channel * _combsPerChannel;
        double reverberated = 0;
        for (int comb = 0; comb < _combsPerChannel; comb++) {
          reverberated += _combs[combBase + comb].process(input);
        }
        reverberated *= 1 / _combsPerChannel;
        final int allPassBase = channel * _allPassesPerChannel;
        for (int filter = 0; filter < _allPassesPerChannel; filter++) {
          reverberated = _allPasses[allPassBase + filter].process(reverberated);
        }
        double output = input * dryMix + reverberated * wetMix;
        if (output > 1) {
          output = 1;
        } else if (output < -1) {
          output = -1;
        }
        interleavedSamples[sampleIndex] = output;
      }
    }
  }

  @override
  void reset() {
    throwIfDisposed();
    for (final _NativeCombFilter comb in _combs) {
      comb.reset();
    }
    for (final _NativeAllPassFilter filter in _allPasses) {
      filter.reset();
    }
  }

  @override
  void onDispose() {
    for (final _NativeCombFilter comb in _combs) {
      comb.dispose();
    }
    for (final _NativeAllPassFilter filter in _allPasses) {
      filter.dispose();
    }
    _combs.clear();
    _allPasses.clear();
  }

  static double _unit(double value) => value.clamp(0.0, 1.0);
  static double _feedback(double value) => 0.55 + _unit(value) * 0.4;
  static int _scaledLength(int samples, double scale) {
    final int result = (samples * scale).round();
    return result < 2 ? 2 : result;
  }
}

final class _NativeCombFilter with DisposableMixin {
  _NativeCombFilter(
    this.length, {
    required this.feedback,
    required this.damping,
  }) : buffer = NativeAllocator.instance.allocate<Float>(
          length * sizeOf<Float>(),
        ) {
    for (int index = 0; index < length; index++) {
      buffer[index] = 0;
    }
  }

  final int length;
  final Pointer<Float> buffer;
  double feedback;
  double damping;
  int index = 0;
  double filterStore = 0;

  double process(double input) {
    final double output = buffer[index];
    filterStore = output * (1.0 - damping) + filterStore * damping;
    buffer[index] = input + filterStore * feedback;
    index++;
    if (index == length) index = 0;
    return output;
  }

  void reset() {
    for (int sample = 0; sample < length; sample++) {
      buffer[sample] = 0;
    }
    index = 0;
    filterStore = 0;
  }

  @override
  void onDispose() => NativeAllocator.instance.free(buffer);
}

final class _NativeAllPassFilter with DisposableMixin {
  _NativeAllPassFilter(this.length)
      : buffer = NativeAllocator.instance.allocate<Float>(
          length * sizeOf<Float>(),
        ) {
    for (int index = 0; index < length; index++) {
      buffer[index] = 0;
    }
  }

  final int length;
  final Pointer<Float> buffer;
  int index = 0;

  double process(double input) {
    final double delayed = buffer[index];
    final double output = delayed - input;
    buffer[index] = input + delayed * 0.5;
    index++;
    if (index == length) index = 0;
    return output;
  }

  void reset() {
    for (int sample = 0; sample < length; sample++) {
      buffer[sample] = 0;
    }
    index = 0;
  }

  @override
  void onDispose() => NativeAllocator.instance.free(buffer);
}
