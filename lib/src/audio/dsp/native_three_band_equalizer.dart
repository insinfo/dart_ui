/// Realtime three-band equalizer over native float32 blocks.
library;

import 'dart:ffi';
import 'dart:math' as math;

import '../../ffi/native_memory.dart';
import '../../foundation/lifecycle.dart';
import 'native_audio_processor.dart';

/// Cascaded low-shelf, peaking and high-shelf biquads in pure Dart DSP.
///
/// Delay state is held in native double buffers. Coefficients are recalculated
/// only when a gain changes, never per sample. Gains are expressed in dB and
/// clamped to -12...+12 dB.
final class NativeThreeBandEqualizer
    with DisposableMixin
    implements NativeFloat32AudioEffect {
  NativeThreeBandEqualizer({
    required this.sampleRate,
    required this.channels,
    double bassGainDb = 0,
    double midGainDb = 0,
    double trebleGainDb = 0,
  }) : _state = NativeAllocator.instance.allocate<Double>(
          channels * _bandCount * 2 * sizeOf<Double>(),
        ) {
    if (sampleRate <= 0 || channels <= 0) {
      throw ArgumentError('sampleRate and channels must be positive');
    }
    _bassGainDb = bassGainDb.clamp(-12.0, 12.0);
    _midGainDb = midGainDb.clamp(-12.0, 12.0);
    _trebleGainDb = trebleGainDb.clamp(-12.0, 12.0);
    _updateCoefficients();
  }

  static const int _bandCount = 3;
  static const int _bass = 0;
  static const int _mid = 1;
  static const int _treble = 2;

  @override
  final int sampleRate;
  @override
  final int channels;
  final Pointer<Double> _state;
  final List<_BiquadCoefficients> _coefficients = <_BiquadCoefficients>[
    _BiquadCoefficients.identity,
    _BiquadCoefficients.identity,
    _BiquadCoefficients.identity,
  ];

  double _bassGainDb = 0;
  double _midGainDb = 0;
  double _trebleGainDb = 0;

  double get bassGainDb => _bassGainDb;
  set bassGainDb(double value) {
    final double next = value.clamp(-12.0, 12.0);
    if (next == _bassGainDb) return;
    _bassGainDb = next;
    _coefficients[_bass] = _lowShelf(180, next);
  }

  double get midGainDb => _midGainDb;
  set midGainDb(double value) {
    final double next = value.clamp(-12.0, 12.0);
    if (next == _midGainDb) return;
    _midGainDb = next;
    _coefficients[_mid] = _peaking(1100, 0.82, next);
  }

  double get trebleGainDb => _trebleGainDb;
  set trebleGainDb(double value) {
    final double next = value.clamp(-12.0, 12.0);
    if (next == _trebleGainDb) return;
    _trebleGainDb = next;
    _coefficients[_treble] = _highShelf(6500, next);
  }

  void _updateCoefficients() {
    _coefficients[_bass] = _lowShelf(180, _bassGainDb);
    _coefficients[_mid] = _peaking(1100, 0.82, _midGainDb);
    _coefficients[_treble] = _highShelf(6500, _trebleGainDb);
  }

  @override
  void processInPlace(Pointer<Float> interleavedSamples, int frames) {
    throwIfDisposed();
    for (int frame = 0; frame < frames; frame++) {
      final int base = frame * channels;
      for (int channel = 0; channel < channels; channel++) {
        double value = interleavedSamples[base + channel];
        for (int band = 0; band < _bandCount; band++) {
          final _BiquadCoefficients c = _coefficients[band];
          final int stateBase = (band * channels + channel) * 2;
          final double z1 = _state[stateBase];
          final double z2 = _state[stateBase + 1];
          final double output = c.b0 * value + z1;
          _state[stateBase] = c.b1 * value - c.a1 * output + z2;
          _state[stateBase + 1] = c.b2 * value - c.a2 * output;
          value = output;
        }
        interleavedSamples[base + channel] = value.clamp(-1.0, 1.0);
      }
    }
  }

  @override
  void reset() {
    throwIfDisposed();
    for (int index = 0; index < channels * _bandCount * 2; index++) {
      _state[index] = 0;
    }
  }

  _BiquadCoefficients _peaking(double frequency, double q, double gainDb) {
    if (gainDb == 0) return _BiquadCoefficients.identity;
    final double a = math.pow(10, gainDb / 40).toDouble();
    final double omega = 2 * math.pi * frequency / sampleRate;
    final double cosine = math.cos(omega);
    final double alpha = math.sin(omega) / (2 * q);
    return _BiquadCoefficients.normalized(
      1 + alpha * a,
      -2 * cosine,
      1 - alpha * a,
      1 + alpha / a,
      -2 * cosine,
      1 - alpha / a,
    );
  }

  _BiquadCoefficients _lowShelf(double frequency, double gainDb) {
    if (gainDb == 0) return _BiquadCoefficients.identity;
    final double a = math.pow(10, gainDb / 40).toDouble();
    final double omega = 2 * math.pi * frequency / sampleRate;
    final double cosine = math.cos(omega);
    final double alpha = math.sin(omega) / math.sqrt(2);
    final double root = 2 * math.sqrt(a) * alpha;
    return _BiquadCoefficients.normalized(
      a * ((a + 1) - (a - 1) * cosine + root),
      2 * a * ((a - 1) - (a + 1) * cosine),
      a * ((a + 1) - (a - 1) * cosine - root),
      (a + 1) + (a - 1) * cosine + root,
      -2 * ((a - 1) + (a + 1) * cosine),
      (a + 1) + (a - 1) * cosine - root,
    );
  }

  _BiquadCoefficients _highShelf(double frequency, double gainDb) {
    if (gainDb == 0) return _BiquadCoefficients.identity;
    final double a = math.pow(10, gainDb / 40).toDouble();
    final double omega = 2 * math.pi * frequency / sampleRate;
    final double cosine = math.cos(omega);
    final double alpha = math.sin(omega) / math.sqrt(2);
    final double root = 2 * math.sqrt(a) * alpha;
    return _BiquadCoefficients.normalized(
      a * ((a + 1) + (a - 1) * cosine + root),
      -2 * a * ((a - 1) + (a + 1) * cosine),
      a * ((a + 1) + (a - 1) * cosine - root),
      (a + 1) - (a - 1) * cosine + root,
      2 * ((a - 1) - (a + 1) * cosine),
      (a + 1) - (a - 1) * cosine - root,
    );
  }

  @override
  void onDispose() => NativeAllocator.instance.free(_state);
}

final class _BiquadCoefficients {
  const _BiquadCoefficients(this.b0, this.b1, this.b2, this.a1, this.a2);

  factory _BiquadCoefficients.normalized(
    double b0,
    double b1,
    double b2,
    double a0,
    double a1,
    double a2,
  ) =>
      _BiquadCoefficients(b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0);

  static const _BiquadCoefficients identity =
      _BiquadCoefficients(1, 0, 0, 0, 0);

  final double b0;
  final double b1;
  final double b2;
  final double a1;
  final double a2;
}
