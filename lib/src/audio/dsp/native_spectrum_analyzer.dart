/// Allocation-free spectrum telemetry over native float32 audio buffers.
library;

import 'dart:ffi';
import 'dart:math' as math;

import '../../ffi/native_memory.dart';
import '../../foundation/lifecycle.dart';
import 'native_audio_processor.dart';

/// A logarithmic constant-Q filter bank suitable for realtime bar displays.
///
/// The analyzer never changes the caller-owned samples. Coefficients, filter
/// state, accumulators and smoothed levels are all allocated once in native
/// memory, so [processInPlace] performs no heap allocation. This is intended
/// for metering and visualization, not scientific FFT measurements.
final class NativeSpectrumAnalyzer
    with DisposableMixin
    implements NativeFloat32AudioEffect {
  NativeSpectrumAnalyzer({
    required this.sampleRate,
    required this.channels,
    this.bandCount = 40,
    this.minimumFrequency = 40,
    this.maximumFrequency = 16000,
    this.q = 1.35,
    this.outputGain = 4,
    this.attack = 0.65,
    this.release = 0.16,
  })  : _frequencies = NativeAllocator.instance.allocate<Double>(
          bandCount * sizeOf<Double>(),
        ),
        _coefficients = NativeAllocator.instance.allocate<Double>(
          bandCount * 5 * sizeOf<Double>(),
        ),
        _states = NativeAllocator.instance.allocate<Double>(
          bandCount * 2 * sizeOf<Double>(),
        ),
        _sums = NativeAllocator.instance.allocate<Double>(
          bandCount * sizeOf<Double>(),
        ),
        _levels = NativeAllocator.instance.allocate<Float>(
          bandCount * sizeOf<Float>(),
        ) {
    if (sampleRate <= 0 || channels <= 0 || bandCount <= 0) {
      throw ArgumentError(
          'sampleRate, channels and bandCount must be positive');
    }
    if (minimumFrequency <= 0 ||
        maximumFrequency <= minimumFrequency ||
        maximumFrequency >= sampleRate / 2) {
      throw ArgumentError('frequency range must lie below Nyquist');
    }
    if (q <= 0 || outputGain <= 0) {
      throw ArgumentError('q and outputGain must be positive');
    }
    if (attack < 0 || attack > 1 || release < 0 || release > 1) {
      throw ArgumentError('attack and release must be between zero and one');
    }
    _prepareFilters();
    reset();
  }

  @override
  final int sampleRate;
  @override
  final int channels;
  final int bandCount;
  final double minimumFrequency;
  final double maximumFrequency;
  final double q;
  final double outputGain;
  final double attack;
  final double release;

  final Pointer<Double> _frequencies;
  final Pointer<Double> _coefficients;
  final Pointer<Double> _states;
  final Pointer<Double> _sums;
  final Pointer<Float> _levels;

  double frequencyAt(int band) {
    throwIfDisposed();
    RangeError.checkValidIndex(band, this, 'band', bandCount);
    return _frequencies[band];
  }

  double levelAt(int band) {
    throwIfDisposed();
    RangeError.checkValidIndex(band, this, 'band', bandCount);
    return _levels[band];
  }

  void _prepareFilters() {
    final double ratio = maximumFrequency / minimumFrequency;
    for (int band = 0; band < bandCount; band++) {
      final double fraction = bandCount == 1 ? 0.5 : band / (bandCount - 1);
      final double frequency =
          minimumFrequency * math.pow(ratio, fraction).toDouble();
      _frequencies[band] = frequency;
      final double omega = 2 * math.pi * frequency / sampleRate;
      final double alpha = math.sin(omega) / (2 * q);
      final double a0 = 1 + alpha;
      final int coefficient = band * 5;
      _coefficients[coefficient] = alpha / a0;
      _coefficients[coefficient + 1] = 0;
      _coefficients[coefficient + 2] = -alpha / a0;
      _coefficients[coefficient + 3] = (-2 * math.cos(omega)) / a0;
      _coefficients[coefficient + 4] = (1 - alpha) / a0;
    }
  }

  @override
  void processInPlace(Pointer<Float> interleavedSamples, int frames) {
    throwIfDisposed();
    if (frames <= 0) return;
    for (int band = 0; band < bandCount; band++) {
      _sums[band] = 0;
    }
    for (int frame = 0; frame < frames; frame++) {
      final int sampleOffset = frame * channels;
      double input = 0;
      for (int channel = 0; channel < channels; channel++) {
        input += interleavedSamples[sampleOffset + channel];
      }
      input /= channels;
      for (int band = 0; band < bandCount; band++) {
        final int coefficient = band * 5;
        final int state = band * 2;
        final double output =
            _coefficients[coefficient] * input + _states[state];
        _states[state] = _coefficients[coefficient + 1] * input -
            _coefficients[coefficient + 3] * output +
            _states[state + 1];
        _states[state + 1] = _coefficients[coefficient + 2] * input -
            _coefficients[coefficient + 4] * output;
        _sums[band] += output * output;
      }
    }
    for (int band = 0; band < bandCount; band++) {
      final double magnitude = math.sqrt(_sums[band] / frames) * outputGain;
      // A linear meter makes ordinary music look nearly flat because its
      // energy is distributed over many narrow bands. Map -72..0 dB onto the
      // visible range, like hardware spectrum displays and media players do.
      final double decibels =
          magnitude <= 1e-12 ? -72 : 20 * math.log(magnitude) / math.ln10;
      final double target = ((decibels + 72) / 72).clamp(0.0, 1.0);
      final double previous = _levels[band];
      final double smoothing = target > previous ? attack : release;
      _levels[band] = previous + (target - previous) * smoothing;
    }
  }

  @override
  void reset() {
    throwIfDisposed();
    for (int band = 0; band < bandCount; band++) {
      _states[band * 2] = 0;
      _states[band * 2 + 1] = 0;
      _sums[band] = 0;
      _levels[band] = 0;
    }
  }

  @override
  void onDispose() {
    NativeAllocator.instance
      ..free(_levels)
      ..free(_sums)
      ..free(_states)
      ..free(_coefficients)
      ..free(_frequencies);
  }
}
