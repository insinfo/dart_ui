/// The realtime half of stream gain: in-place over native sample memory.
///
/// ## Why this is not just a view onto [PcmGain]
///
/// `Pointer<Float>.asTypedList` would let the typed-list kernels in
/// `audio_gain.dart` operate straight on the endpoint buffer, which is the
/// idiom `streaming_file_playback.dart` uses for its staging buffer. It is the
/// wrong tool *here*: the pointer WASAPI hands back changes on every
/// `GetBuffer`, so the view cannot be built once and kept, and building one
/// per engine wakeup allocates a Dart object on the realtime path.
/// `WasapiRenderStream` documents that a successful period performs no
/// deliberate Dart heap allocation, and one small allocation every ten
/// milliseconds is exactly the kind of thing that is invisible until a
/// collection lands inside a period and the endpoint underruns.
///
/// So these loops index the pointer directly, and
/// `test/audio/audio_gain_test.dart` asserts they produce the same bytes as
/// the typed-list kernels for the same input. Two implementations of one piece
/// of arithmetic are only defensible when a test proves they agree.
library;

import 'dart:ffi';

import '../../foundation/lifecycle.dart';
import '../audio_format.dart';
import '../audio_gain.dart';
import 'native_audio_processor.dart';

/// Applies [factor] in place to [sampleCount] interleaved float32 samples.
///
/// The unity and silence tests are per *buffer*, not per sample - see the
/// argument in `audio_gain.dart`. Unity returns without touching memory, which
/// is what makes it bit-identical rather than merely equal.
void applyNativeFloat32Gain(
  Pointer<Float> samples,
  int sampleCount,
  double factor,
) {
  _checkFactor(factor);
  if (factor == 1.0 || sampleCount <= 0) return;
  if (factor == 0.0) {
    for (int index = 0; index < sampleCount; index++) {
      samples[index] = 0;
    }
    return;
  }
  for (int index = 0; index < sampleCount; index++) {
    samples[index] = samples[index] * factor;
  }
}

/// Applies [factor] in place to [sampleCount] samples of [format] at [bytes].
///
/// The dispatch is here rather than at the call site because the call site is
/// a render loop that must not grow a `switch` over sample formats, and
/// because there is exactly one format this repository cannot do:
/// [AudioSampleFormat.signed24] is packed three bytes per sample and has no
/// kernel. It throws rather than passing the samples through unchanged - a
/// gain control that silently does nothing on one endpoint format is the
/// defect this whole file exists to avoid. `WasapiRenderStream` refuses the
/// combination at the setter, so the throw here is a backstop that names the
/// case rather than a path a caller can reach.
void applyNativeGain(
  Pointer<Uint8> bytes,
  AudioSampleFormat format,
  int sampleCount,
  double factor,
) {
  _checkFactor(factor);
  if (factor == 1.0 || sampleCount <= 0) return;
  switch (format) {
    case AudioSampleFormat.float32:
      applyNativeFloat32Gain(bytes.cast<Float>(), sampleCount, factor);
    case AudioSampleFormat.float64:
      final Pointer<Double> samples = bytes.cast<Double>();
      if (factor == 0.0) {
        for (int index = 0; index < sampleCount; index++) {
          samples[index] = 0;
        }
        return;
      }
      for (int index = 0; index < sampleCount; index++) {
        samples[index] = samples[index] * factor;
      }
    case AudioSampleFormat.signed16:
      final Pointer<Int16> samples = bytes.cast<Int16>();
      if (factor == 0.0) {
        for (int index = 0; index < sampleCount; index++) {
          samples[index] = 0;
        }
        return;
      }
      for (int index = 0; index < sampleCount; index++) {
        samples[index] = _saturate(samples[index] * factor, -32768, 32767);
      }
    case AudioSampleFormat.signed32:
      final Pointer<Int32> samples = bytes.cast<Int32>();
      if (factor == 0.0) {
        for (int index = 0; index < sampleCount; index++) {
          samples[index] = 0;
        }
        return;
      }
      for (int index = 0; index < sampleCount; index++) {
        samples[index] =
            _saturate(samples[index] * factor, -2147483648, 2147483647);
      }
    case AudioSampleFormat.unsigned8:
      // 128 is silence in this format, not 0 - see PcmGain.applyUnsigned8 for
      // the click that scaling the raw byte produces.
      if (factor == 0.0) {
        for (int index = 0; index < sampleCount; index++) {
          bytes[index] = 128;
        }
        return;
      }
      for (int index = 0; index < sampleCount; index++) {
        bytes[index] =
            _saturate((bytes[index] - 128) * factor, -128, 127) + 128;
      }
    case AudioSampleFormat.signed24:
      throw ArgumentError.value(
        format,
        'format',
        'packed 24-bit gain is not implemented; nothing in this repository '
            'renders it, and passing the samples through unattenuated would '
            'be a volume control that silently does nothing',
      );
  }
}

/// Whether [applyNativeGain] can scale [format] at all.
///
/// Asked by a stream's gain setter so a caller learns that its endpoint format
/// has no kernel *when it sets the gain*, on its own isolate, rather than as a
/// throw from the audio thread three periods later.
bool nativeGainSupportsFormat(AudioSampleFormat format) =>
    format != AudioSampleFormat.signed24;

void _checkFactor(double factor) {
  if (factor.isNaN || !factor.isFinite || factor < 0) {
    throw ArgumentError.value(
      factor,
      'factor',
      'must be a finite, non-negative linear amplitude',
    );
  }
}

/// Rounds half away from zero into `[low, high]`, saturating.
///
/// The comparisons precede `round()` because `round()` throws on a value it
/// cannot represent, and a large factor applied to a full-scale sample reaches
/// exactly that. Saturating rather than wrapping is the whole point: a wrapped
/// full-scale sample becomes the most negative one and sounds like a crackle
/// on material that was only loud.
int _saturate(double value, int low, int high) {
  if (value <= low) return low;
  if (value >= high) return high;
  return value.round();
}

/// An in-place [AudioGain] stage for a native float32 processing chain.
///
/// Exists so that a graph built out of `NativeFloat32AudioEffect` nodes can
/// place gain explicitly, and so that the "as late as possible" rule has
/// something to name. The rule itself is enforced where it matters -
/// `WasapiRenderStream` applies the stream's gain after the processor has
/// filled the endpoint buffer, so one multiply covers resampling, mixing and
/// every effect at once, and no earlier stage ever sees attenuated samples it
/// might make a decision from.
final class NativeFloat32GainStage
    with DisposableMixin
    implements NativeFloat32AudioEffect {
  NativeFloat32GainStage({
    required this.sampleRate,
    required this.channels,
    AudioGain gain = AudioGain.unity,
  }) : _gain = gain;

  @override
  final int sampleRate;

  @override
  final int channels;

  AudioGain _gain;

  AudioGain get gain => _gain;

  set gain(AudioGain value) {
    throwIfDisposed();
    _gain = value;
  }

  @override
  void processInPlace(Pointer<Float> interleavedSamples, int frames) {
    throwIfDisposed();
    applyNativeFloat32Gain(
      interleavedSamples,
      frames * channels,
      _gain.factor,
    );
  }

  /// Nothing to reset: a multiply has no state, which is also why it can be
  /// changed between any two buffers without a click beyond the step itself.
  @override
  void reset() {}

  @override
  void onDispose() {}
}
