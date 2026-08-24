/// Configurable realtime graphic equalizer over native float32 blocks.
library;

import 'dart:ffi';
import 'dart:math' as math;

import '../../ffi/native_memory.dart';
import '../../foundation/lifecycle.dart';
import 'native_audio_processor.dart';

/// Cascades constant-Q peaking biquads at caller-selected center frequencies.
///
/// Coefficients, gains and delay state all live in native memory. [setGainDb]
/// recalculates one band's five coefficients only when its value changes;
/// [processInPlace] performs no allocation and no transcendental arithmetic.
final class NativeGraphicEqualizer
    with DisposableMixin
    implements NativeFloat32AudioEffect {
  NativeGraphicEqualizer({
    required this.sampleRate,
    required this.channels,
    required List<double> frequencies,
    this.q = 1.4,
    this.minimumGainDb = -12,
    this.maximumGainDb = 12,
  })  : frequencies = List<double>.unmodifiable(frequencies),
        _gains = NativeAllocator.instance.allocate<Double>(
          frequencies.length * sizeOf<Double>(),
        ),
        _coefficients = NativeAllocator.instance.allocate<Double>(
          frequencies.length * _coefficientCount * sizeOf<Double>(),
        ),
        _state = NativeAllocator.instance.allocate<Double>(
          frequencies.length * channels * 2 * sizeOf<Double>(),
        ) {
    if (sampleRate <= 0 || channels <= 0) {
      throw ArgumentError('sampleRate and channels must be positive');
    }
    if (frequencies.isEmpty ||
        frequencies.any((double frequency) =>
            frequency <= 0 || frequency >= sampleRate / 2)) {
      throw ArgumentError('frequencies must lie between 0 and Nyquist');
    }
    if (q <= 0 || minimumGainDb >= maximumGainDb) {
      throw ArgumentError('q and gain range are invalid');
    }
    for (int band = 0; band < frequencies.length; band++) {
      _writeIdentity(band);
    }
  }

  static const int _coefficientCount = 5;
  static const int _b0 = 0;
  static const int _b1 = 1;
  static const int _b2 = 2;
  static const int _a1 = 3;
  static const int _a2 = 4;

  @override
  final int sampleRate;
  @override
  final int channels;
  final List<double> frequencies;
  final double q;
  final double minimumGainDb;
  final double maximumGainDb;
  final Pointer<Double> _gains;
  final Pointer<Double> _coefficients;
  final Pointer<Double> _state;

  int get bandCount => frequencies.length;

  double gainDbAt(int band) {
    throwIfDisposed();
    RangeError.checkValidIndex(band, frequencies, 'band');
    return _gains[band];
  }

  void setGainDb(int band, double gainDb) {
    throwIfDisposed();
    RangeError.checkValidIndex(band, frequencies, 'band');
    final double gain = gainDb.clamp(minimumGainDb, maximumGainDb);
    if (_gains[band] == gain) return;
    _gains[band] = gain;
    if (gain == 0) {
      _writeIdentity(band);
      return;
    }
    final double a = math.pow(10, gain / 40).toDouble();
    final double omega = 2 * math.pi * frequencies[band] / sampleRate;
    final double cosine = math.cos(omega);
    final double alpha = math.sin(omega) / (2 * q);
    final double a0 = 1 + alpha / a;
    final int offset = band * _coefficientCount;
    _coefficients[offset + _b0] = (1 + alpha * a) / a0;
    _coefficients[offset + _b1] = (-2 * cosine) / a0;
    _coefficients[offset + _b2] = (1 - alpha * a) / a0;
    _coefficients[offset + _a1] = (-2 * cosine) / a0;
    _coefficients[offset + _a2] = (1 - alpha / a) / a0;
  }

  void setAllGains(Iterable<double> gains) {
    int band = 0;
    for (final double gain in gains) {
      if (band >= bandCount) {
        throw ArgumentError('more gains than equalizer bands');
      }
      setGainDb(band++, gain);
    }
    if (band != bandCount) {
      throw ArgumentError('expected $bandCount gains, received $band');
    }
  }

  void resetGains() {
    for (int band = 0; band < bandCount; band++) {
      setGainDb(band, 0);
    }
  }

  @override
  void processInPlace(Pointer<Float> interleavedSamples, int frames) {
    throwIfDisposed();
    for (int frame = 0; frame < frames; frame++) {
      final int frameBase = frame * channels;
      for (int channel = 0; channel < channels; channel++) {
        double value = interleavedSamples[frameBase + channel];
        for (int band = 0; band < bandCount; band++) {
          final int coefficient = band * _coefficientCount;
          final int state = (band * channels + channel) * 2;
          final double output =
              _coefficients[coefficient + _b0] * value + _state[state];
          _state[state] = _coefficients[coefficient + _b1] * value -
              _coefficients[coefficient + _a1] * output +
              _state[state + 1];
          _state[state + 1] = _coefficients[coefficient + _b2] * value -
              _coefficients[coefficient + _a2] * output;
          value = output;
        }
        interleavedSamples[frameBase + channel] = value.clamp(-1.0, 1.0);
      }
    }
  }

  @override
  void reset() {
    throwIfDisposed();
    final int stateCount = bandCount * channels * 2;
    for (int index = 0; index < stateCount; index++) {
      _state[index] = 0;
    }
  }

  void _writeIdentity(int band) {
    final int offset = band * _coefficientCount;
    _coefficients[offset + _b0] = 1;
    _coefficients[offset + _b1] = 0;
    _coefficients[offset + _b2] = 0;
    _coefficients[offset + _a1] = 0;
    _coefficients[offset + _a2] = 0;
  }

  @override
  void onDispose() {
    NativeAllocator.instance
      ..free(_state)
      ..free(_coefficients)
      ..free(_gains);
  }
}
