/// Stream gain: a multiply this framework applies to its own samples.
///
/// ## The distinction this file exists to keep
///
/// There are two different things called "volume" and conflating them is what
/// makes volume controls behave surprisingly.
///
///   * **Stream gain** - this file. A multiply applied inside our own path,
///     before the samples reach the device. It works on every platform because
///     it needs nothing from the platform. It is *ours*: it does not appear in
///     the operating system's volume mixer, the user cannot change it from
///     outside, and it does exactly what the application asked for.
///   * **Session volume** - `audio_session_volume.dart`. The application's own
///     slider in the operating system's mixer. User-visible, user-changeable,
///     persistent across runs, and available only where the platform has a
///     per-application volume concept at all.
///
/// They are never substituted for one another. A caller that asks for session
/// volume on a backend that has none gets a named refusal, not a stream gain
/// pretending to be the same thing.
///
/// ## Linear amplitude, not decibels, is what this type stores
///
/// [AudioGain.factor] is a linear amplitude multiplier, and the reason is that
/// it is the number the DSP actually multiplies by. Decibels are a
/// *presentation* of that number and they are offered as one -
/// [AudioGain.decibels] and [AudioGain.inDecibels] - because two properties
/// have to hold exactly and only the linear form can promise them:
///
///   * `0.0` is true silence. In decibels that is negative infinity, which no
///     slider can produce and no clamped `double` range contains.
///   * `1.0` is bit-identical passthrough. In decibels that is exactly 0, and
///     `10^(0/20)` does return exactly 1.0 - but `10^(-0.0001/20)` does not,
///     and a control whose "unity" is 0.99999 is not transparent. Storing the
///     linear factor makes unity an exact, testable comparison rather than a
///     tolerance.
///
/// Human hearing is still logarithmic, and a linear 0..1 slider does sound
/// wrong at the bottom - most of its travel is spent between "loud" and
/// "slightly less loud". That is a property of the *slider*, not of the
/// storage, so it is fixed where it belongs: [AudioGain.fromSlider] maps a
/// linear fader position through a perceptual curve.
///
/// ## What unity costs
///
/// Nothing, and that is enforced rather than hoped for. Every kernel in
/// [PcmGain] tests the factor **once per buffer** and returns before touching
/// a sample. A per-sample test would cost a compare on every sample of every
/// buffer for a case that is almost always false; a per-buffer test costs one
/// compare per few hundred frames, which is not measurable. This is the same
/// rule `lib/src/rendering/render_diagnostics.dart` argues at length for
/// diagnostics: off must cost nothing, and the enforceable form of nothing is
/// a path that does no work rather than a path that does cheap work.
///
/// The early return is also what makes unity *bit-identical* rather than
/// merely equal: no multiply happens at all, so signed zero, denormals and
/// every other value the buffer holds come out as the exact bytes that went
/// in. `test/audio/audio_gain_test.dart` compares byte for byte.
library;

import 'dart:math' as math;
import 'dart:typed_data';

/// A linear amplitude multiplier for one audio path.
///
/// ## Why this is not a `const` constructor with an assert
///
/// The repository's other value types validate with `assert`, which is right
/// for something read on the UI isolate. This one is read on the audio thread
/// in an AOT build, where asserts are compiled out - and a NaN factor that
/// slips through there is a buffer of NaN handed to the digital-to-analogue
/// converter, which on most endpoints is full-scale noise. So the public
/// constructor is a factory that throws in every build, and the two values
/// that have to be compile-time constants get a private `const` one.
final class AudioGain implements Comparable<AudioGain> {
  const AudioGain._(this.factor);

  /// A gain of [factor], a linear amplitude multiplier.
  ///
  /// Must be finite and not negative. A negative multiplier is a polarity
  /// inversion, which is a real effect and not a volume control; it is
  /// rejected here so that "the volume went below zero" cannot silently mean
  /// "the waveform flipped".
  factory AudioGain(double factor) {
    if (factor.isNaN) {
      throw ArgumentError.value(factor, 'factor', 'must not be NaN');
    }
    if (!factor.isFinite) {
      throw ArgumentError.value(factor, 'factor', 'must be finite');
    }
    if (factor < 0) {
      throw ArgumentError.value(
        factor,
        'factor',
        'must not be negative; a negative multiplier inverts polarity rather '
            'than reducing level',
      );
    }
    return AudioGain._(factor);
  }

  /// A gain expressed in decibels relative to full scale.
  ///
  /// `AudioGain.decibels(0)` is exactly [unity] - `pow(10, 0)` is exactly 1.0
  /// - and `AudioGain.decibels(double.negativeInfinity)` is exactly [silence].
  /// Both are asserted by the tests, because a decibel API whose 0 dB is
  /// 0.9999999 is not a passthrough and every measurement taken through it is
  /// off by an amount nobody thought to look for.
  factory AudioGain.decibels(double decibels) {
    if (decibels.isNaN) {
      throw ArgumentError.value(decibels, 'decibels', 'must not be NaN');
    }
    if (decibels == double.negativeInfinity) return silence;
    return AudioGain(math.pow(10, decibels / 20).toDouble());
  }

  /// A gain for a fader at [position], where 0 is silence and 1 is unity.
  ///
  /// The curve is `position^3`, the cube law used by most mixing faders. A
  /// linear position-to-amplitude map spends most of its travel between "loud"
  /// and "slightly less loud" and then falls off a cliff at the bottom,
  /// because hearing responds to level roughly logarithmically; the cube law
  /// puts the halfway point at -18 dB, which is where a fader has to be for
  /// the bottom half of its travel to be useful.
  ///
  /// The exponent is a taste choice and it is worth naming the alternative:
  /// Stevens' power law would argue for about `position^1.67` if the goal were
  /// strict linearity of *perceived loudness*, and practical faders are all
  /// steeper than that because they also have to reach usefully quiet. A
  /// caller who wants a different law does not need this constructor at all -
  /// [AudioGain.decibels] takes whatever curve the caller computes.
  ///
  /// Both endpoints are exact: `0^3` is 0.0 and `1^3` is 1.0, so a fader at
  /// the top is bit-identical passthrough and a fader at the bottom is true
  /// silence, with no epsilon anywhere.
  factory AudioGain.fromSlider(double position) {
    if (position.isNaN) {
      throw ArgumentError.value(position, 'position', 'must not be NaN');
    }
    final double clamped = position.clamp(0.0, 1.0);
    return AudioGain._(clamped * clamped * clamped);
  }

  /// Bit-identical passthrough. The default for every path in this framework.
  static const AudioGain unity = AudioGain._(1);

  /// True silence: every sample becomes zero.
  ///
  /// Not "very quiet". A profiling run that needs to hear nothing needs this
  /// to be exactly zero, and a caller that asks for it and gets -80 dB has
  /// been given something else.
  static const AudioGain silence = AudioGain._(0);

  /// The linear amplitude multiplier. Finite and not negative.
  final double factor;

  /// Whether this gain is exact passthrough, and therefore free.
  bool get isUnity => factor == 1.0;

  /// Whether this gain is exact silence.
  bool get isSilent => factor == 0.0;

  /// This gain in decibels relative to full scale, or negative infinity for
  /// [silence].
  double get inDecibels =>
      factor == 0 ? double.negativeInfinity : 20 * math.log(factor) / math.ln10;

  /// The fader position [AudioGain.fromSlider] would need to produce this
  /// gain, clamped to 0..1.
  double get sliderPosition {
    if (factor <= 0) return 0;
    if (factor >= 1) return 1;
    return math.pow(factor, 1 / 3).toDouble();
  }

  /// The gain of two stages in series.
  AudioGain operator *(AudioGain other) => AudioGain._(factor * other.factor);

  @override
  int compareTo(AudioGain other) => factor.compareTo(other.factor);

  @override
  bool operator ==(Object other) =>
      other is AudioGain && other.factor == factor;

  @override
  int get hashCode => factor.hashCode;

  @override
  String toString() {
    if (isUnity) return 'AudioGain.unity';
    if (isSilent) return 'AudioGain.silence';
    return 'AudioGain($factor, ${inDecibels.toStringAsFixed(1)} dB)';
  }
}

/// In-place gain kernels over Dart typed lists, one per PCM sample format.
///
/// These are the portable half: no `dart:ffi`, so they analyse and run
/// everywhere, and they are what the tests compare the realtime pointer
/// kernels in `dsp/native_gain.dart` against. Two implementations of the same
/// arithmetic are only defensible if a test proves they agree, and
/// `test/audio/audio_gain_test.dart` does.
///
/// ## What the integer kernels do about rounding and clipping
///
/// Both questions have to be answered out loud, because the wrong answer to
/// either is inaudible in a unit test and unmistakable through a speaker.
///
///   * **Rounding** is half away from zero, which is what `double.round()`
///     does. Truncation would bias every sample towards zero and show up as a
///     low-level distortion that gets worse the quieter the material is.
///   * **Clipping saturates.** A gain above 1.0 applied to a sample near full
///     scale produces a value the format cannot hold, and the two possible
///     behaviours are not both defects: saturating to the maximum is ordinary
///     digital clipping, which sounds like distortion, while letting the value
///     wrap turns the loudest sample into the *most negative* one and sounds
///     like a crackle on material that was merely loud. The clamp is applied
///     to the `double` before rounding rather than after, so an infinite or
///     enormous product is bounded rather than reaching `round()`, which
///     throws on values it cannot represent.
///
/// ## `AudioSampleFormat.signed24` is deliberately absent
///
/// It is packed three bytes per sample and has no typed list, so it would need
/// a byte-level kernel of its own. Nothing in this repository produces it on a
/// playback path - WASAPI shared mode negotiates float32, and the WAVE decoder
/// widens 24-bit to float on the way in - so the kernel is *not needed* rather
/// than *not noticed*, which is the distinction
/// `kMetalDeliberatelyUnbound` exists to keep visible. Callers that reach a
/// 24-bit endpoint with a non-unity gain get a named refusal from
/// `WasapiRenderStream.gain`, never a silent passthrough.
abstract final class PcmGain {
  /// Rejects a factor that must never reach a sample loop.
  ///
  /// Called once per buffer, before the early returns, so the audio thread
  /// cannot be handed a NaN by a caller that built its factor by arithmetic
  /// rather than through [AudioGain].
  static double _checked(double factor) {
    if (factor.isNaN || !factor.isFinite || factor < 0) {
      throw ArgumentError.value(
        factor,
        'factor',
        'must be a finite, non-negative linear amplitude',
      );
    }
    return factor;
  }

  static int _end(int length, int start, int? count) {
    if (start < 0 || start > length) {
      throw RangeError.range(start, 0, length, 'start');
    }
    final int end = count == null ? length : start + count;
    if (end < start || end > length) {
      throw RangeError.range(end - start, 0, length - start, 'count');
    }
    return end;
  }

  /// Scales `count` float32 samples of [samples] from [start] by [factor].
  static void applyFloat32(
    Float32List samples,
    double factor, {
    int start = 0,
    int? count,
  }) {
    _checked(factor);
    if (factor == 1.0) return;
    final int end = _end(samples.length, start, count);
    if (factor == 0.0) {
      samples.fillRange(start, end, 0);
      return;
    }
    for (int index = start; index < end; index++) {
      samples[index] = samples[index] * factor;
    }
  }

  /// Scales `count` float64 samples of [samples] from [start] by [factor].
  static void applyFloat64(
    Float64List samples,
    double factor, {
    int start = 0,
    int? count,
  }) {
    _checked(factor);
    if (factor == 1.0) return;
    final int end = _end(samples.length, start, count);
    if (factor == 0.0) {
      samples.fillRange(start, end, 0);
      return;
    }
    for (int index = start; index < end; index++) {
      samples[index] = samples[index] * factor;
    }
  }

  /// Scales `count` signed 16-bit samples of [samples] from [start], rounding
  /// half away from zero and saturating at the format's limits.
  static void applySigned16(
    Int16List samples,
    double factor, {
    int start = 0,
    int? count,
  }) {
    _checked(factor);
    if (factor == 1.0) return;
    final int end = _end(samples.length, start, count);
    if (factor == 0.0) {
      samples.fillRange(start, end, 0);
      return;
    }
    for (int index = start; index < end; index++) {
      samples[index] = _saturate(samples[index] * factor, -32768, 32767);
    }
  }

  /// Scales `count` signed 32-bit samples of [samples] from [start], rounding
  /// half away from zero and saturating at the format's limits.
  static void applySigned32(
    Int32List samples,
    double factor, {
    int start = 0,
    int? count,
  }) {
    _checked(factor);
    if (factor == 1.0) return;
    final int end = _end(samples.length, start, count);
    if (factor == 0.0) {
      samples.fillRange(start, end, 0);
      return;
    }
    for (int index = start; index < end; index++) {
      samples[index] =
          _saturate(samples[index] * factor, -2147483648, 2147483647);
    }
  }

  /// Scales `count` unsigned 8-bit samples of [samples] from [start].
  ///
  /// Unsigned 8-bit WAVE audio is biased: 128 is silence, not 0 - which is the
  /// convention `codecs/wave_decoder.dart` reads with `(byte - 128) / 128`.
  /// So the multiply has to happen around 128 and not around zero. Scaling the
  /// raw byte instead would turn a gain of 0.0 into a buffer of zeroes, which
  /// in this format is not silence but full-scale negative DC - a loud click
  /// on the way down and another on the way back up.
  static void applyUnsigned8(
    Uint8List samples,
    double factor, {
    int start = 0,
    int? count,
  }) {
    _checked(factor);
    if (factor == 1.0) return;
    final int end = _end(samples.length, start, count);
    if (factor == 0.0) {
      samples.fillRange(start, end, 128);
      return;
    }
    for (int index = start; index < end; index++) {
      samples[index] =
          _saturate((samples[index] - 128) * factor, -128, 127) + 128;
    }
  }

  /// Rounds [value] half away from zero into `[low, high]`.
  ///
  /// The comparisons come before `round()` on purpose: `round()` throws on a
  /// value it cannot represent as an integer, and a large factor applied to a
  /// full-scale sample reaches exactly that.
  static int _saturate(double value, int low, int high) {
    if (value <= low) return low;
    if (value >= high) return high;
    return value.round();
  }
}
