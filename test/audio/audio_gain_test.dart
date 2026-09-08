/// Stream gain, and the four things it has to get exactly right.
///
/// These need no audio device: gain is a multiply over memory, which is the
/// whole argument for it being the portable half of volume control. Nothing
/// here opens an endpoint and nothing here can make a sound.
///
/// The four:
///
///   1. **Unity is bit-identical.** Not "close to the input" - the same bytes.
///      Everything measured through this path afterwards depends on it, so it
///      is asserted by comparing the raw bytes rather than the sample values,
///      which is the only comparison that catches a signed zero flipped, a
///      denormal flushed, or a NaN canonicalised on the way through.
///   2. **Zero is exact silence**, and a small non-zero factor is not.
///   3. **Integer clipping saturates**, and integer rounding is half away from
///      zero.
///   4. **The two implementations agree.** `PcmGain` over typed lists and
///      `applyNativeGain` over pointers are separate loops, and two copies of
///      one piece of arithmetic are only defensible when a test proves they
///      produce the same bytes.
library;

import 'dart:ffi';
import 'dart:typed_data';

import 'package:dart_ui/audio.dart';
import 'package:dart_ui/src/ffi/native_memory.dart';
import 'package:test/test.dart';

/// The raw bytes behind [list], which is what "bit-identical" means here.
Uint8List _bytesOf(TypedData list) =>
    Uint8List.view(list.buffer, list.offsetInBytes, list.lengthInBytes);

/// A float32 buffer of the values a gain path is most likely to damage.
Float32List _awkwardFloats() => Float32List.fromList(<double>[
      0.0,
      -0.0,
      1.0,
      -1.0,
      0.5,
      -0.25,
      1.1754944e-38, // Smallest normal float32.
      1.4e-45, // A denormal: the value a flush-to-zero path would lose.
      3.4028235e38, // Largest finite float32.
      -3.4028235e38,
      double.nan,
      1e-6,
    ]);

void main() {
  group('AudioGain', () {
    test('unity and silence are exact', () {
      expect(AudioGain.unity.factor, 1.0);
      expect(AudioGain.silence.factor, 0.0);
      expect(AudioGain.unity.isUnity, isTrue);
      expect(AudioGain.silence.isSilent, isTrue);
      expect(AudioGain(1).isUnity, isTrue);
    });

    test('0 dB is exactly unity and -infinity dB is exactly silence', () {
      // The reason the type stores linear amplitude. A decibel API whose 0 dB
      // came back as 0.9999999 would make every measurement taken through the
      // path slightly wrong in a way nobody would think to look for.
      expect(AudioGain.decibels(0).factor, 1.0);
      expect(AudioGain.decibels(0), AudioGain.unity);
      expect(AudioGain.decibels(double.negativeInfinity), AudioGain.silence);
      expect(AudioGain.decibels(-6).factor, closeTo(0.5011872, 1e-7));
      expect(AudioGain.decibels(-20).factor, closeTo(0.1, 1e-12));
      expect(AudioGain(0.5).inDecibels, closeTo(-6.0206, 1e-4));
      expect(AudioGain.silence.inDecibels, double.negativeInfinity);
    });

    test('a fader is exact at both ends and logarithmic in between', () {
      expect(AudioGain.fromSlider(1).factor, 1.0);
      expect(AudioGain.fromSlider(0).factor, 0.0);
      // The cube law: half travel is -18 dB, not -6, which is what makes the
      // bottom half of a fader usable rather than a cliff.
      expect(AudioGain.fromSlider(0.5).inDecibels, closeTo(-18.06, 0.01));
      expect(AudioGain.fromSlider(0.5).factor, closeTo(0.125, 1e-12));
      expect(AudioGain(0.125).sliderPosition, closeTo(0.5, 1e-12));
      expect(AudioGain.unity.sliderPosition, 1.0);
      expect(AudioGain.silence.sliderPosition, 0.0);
      // Out of range is clamped rather than rejected: a fader that is dragged
      // past its end is a UI event, not a programming error.
      expect(AudioGain.fromSlider(1.5).factor, 1.0);
      expect(AudioGain.fromSlider(-1).factor, 0.0);
    });

    test('rejects the values that would reach the audio thread as noise', () {
      expect(() => AudioGain(double.nan), throwsArgumentError);
      expect(() => AudioGain(double.infinity), throwsArgumentError);
      // A negative multiplier inverts polarity, which is an effect and not a
      // volume control.
      expect(() => AudioGain(-0.5), throwsArgumentError);
      expect(() => AudioGain.decibels(double.nan), throwsArgumentError);
    });

    test('gains in series multiply', () {
      expect((AudioGain(0.5) * AudioGain(0.5)).factor, 0.25);
      expect((AudioGain(0.3) * AudioGain.unity).factor, 0.3);
    });
  });

  group('unity is bit-identical', () {
    test('float32, including signed zero, denormals and NaN', () {
      final Float32List samples = _awkwardFloats();
      final Uint8List before = Uint8List.fromList(_bytesOf(samples));
      PcmGain.applyFloat32(samples, AudioGain.unity.factor);
      expect(_bytesOf(samples), before,
          reason: 'a gain path that is not transparent at unity is a defect '
              'that hides in every measurement made through it');
      // Specifically: -0.0 stayed negative zero, which `== 0.0` would not
      // have caught.
      expect(samples[1].isNegative, isTrue);
      expect(samples[7], isNot(0.0), reason: 'the denormal was not flushed');
      expect(samples[10].isNaN, isTrue);
    });

    test('signed16, signed32 and unsigned8', () {
      final Int16List signed16 =
          Int16List.fromList(<int>[-32768, -1, 0, 1, 32767, 12345]);
      final Uint8List before16 = Uint8List.fromList(_bytesOf(signed16));
      PcmGain.applySigned16(signed16, 1);
      expect(_bytesOf(signed16), before16);

      final Int32List signed32 =
          Int32List.fromList(<int>[-2147483648, -1, 0, 1, 2147483647, 999999]);
      final Uint8List before32 = Uint8List.fromList(_bytesOf(signed32));
      PcmGain.applySigned32(signed32, 1);
      expect(_bytesOf(signed32), before32);

      final Uint8List unsigned8 =
          Uint8List.fromList(<int>[0, 1, 127, 128, 129, 255]);
      final Uint8List before8 = Uint8List.fromList(unsigned8);
      PcmGain.applyUnsigned8(unsigned8, 1);
      expect(unsigned8, before8);
    });

    test('the native pointer kernel too', () {
      final Float32List reference = _awkwardFloats();
      final Pointer<Float> samples = NativeAllocator.instance
          .allocate<Float>(reference.length * sizeOf<Float>());
      addTearDown(() => NativeAllocator.instance.free(samples));
      samples.asTypedList(reference.length).setAll(0, reference);
      final Uint8List before = Uint8List.fromList(
        samples.cast<Uint8>().asTypedList(reference.length * 4),
      );

      applyNativeFloat32Gain(samples, reference.length, 1);
      expect(
        samples.cast<Uint8>().asTypedList(reference.length * 4),
        before,
      );
    });
  });

  group('silence', () {
    test('zero is exactly zero, and a tiny factor is not zero', () {
      final Float32List samples =
          Float32List.fromList(<double>[1, -1, 0.5, 1e-6]);
      PcmGain.applyFloat32(samples, 1e-9);
      // The check a naive "is this basically silent?" short circuit would get
      // wrong. Every one of these is minute and none of them is zero, and a
      // path that decided to skip the write here would stop the endpoint
      // consuming frames - which is the clock, which is what a profiling run
      // is measuring.
      for (final double value in samples) {
        expect(value, isNot(0.0));
      }

      final Float32List silenced =
          Float32List.fromList(<double>[1, -1, 0.5, 1e-6]);
      PcmGain.applyFloat32(silenced, AudioGain.silence.factor);
      expect(silenced, everyElement(0.0));
    });

    test('unsigned8 silence is 128, not 0', () {
      // 0 in this format is full-scale negative DC, so zeroing the bytes would
      // be a loud click on the way down and another on the way back up.
      final Uint8List samples = Uint8List.fromList(<int>[0, 64, 128, 200, 255]);
      PcmGain.applyUnsigned8(samples, 0);
      expect(samples, everyElement(128));

      final Uint8List halved = Uint8List.fromList(<int>[0, 64, 128, 192, 255]);
      PcmGain.applyUnsigned8(halved, 0.5);
      expect(halved, <int>[64, 96, 128, 160, 192]);
    });
  });

  group('integer clipping and rounding', () {
    test('a gain above unity saturates rather than wrapping', () {
      final Int16List samples =
          Int16List.fromList(<int>[32767, -32768, 20000, -20000]);
      PcmGain.applySigned16(samples, 2);
      // Wrapping would turn the loudest sample into the most negative one:
      // 32767 * 2 truncated to 16 bits is -2. That is a crackle on material
      // that was merely loud, which is a bug; saturation is ordinary digital
      // clipping, which is an answer.
      expect(samples, <int>[32767, -32768, 32767, -32768]);
    });

    test('an enormous factor does not throw on the way to the clamp', () {
      // The clamp is applied to the double before `round()`, because `round()`
      // throws on a value it cannot represent as an integer.
      final Int32List samples = Int32List.fromList(<int>[1, -1]);
      PcmGain.applySigned32(samples, 1e300);
      expect(samples, <int>[2147483647, -2147483648]);
    });

    test('rounding is half away from zero', () {
      final Int16List samples = Int16List.fromList(<int>[1, -1, 3, -3]);
      PcmGain.applySigned16(samples, 1.5);
      expect(samples, <int>[2, -2, 5, -5]);
    });

    test('float32 does not saturate; there is no full scale to saturate to',
        () {
      // Stated because it is the difference between the two families and the
      // difference is deliberate: a float32 endpoint takes values above 1.0
      // and the audio engine decides what to do with them. Clamping here would
      // silently change the material of anyone doing headroom work.
      final Float32List samples = Float32List.fromList(<double>[1, -1]);
      PcmGain.applyFloat32(samples, 4);
      expect(samples, <double>[4, -4]);
    });
  });

  group('the pointer kernels match the typed-list kernels', () {
    /// Runs both implementations over the same bytes and compares them.
    void agree(
      AudioSampleFormat format,
      List<int> sourceBytes,
      double factor,
      void Function(Uint8List) applyList,
    ) {
      final Uint8List expected = Uint8List.fromList(sourceBytes);
      applyList(expected);

      final Pointer<Uint8> native =
          NativeAllocator.instance.allocate<Uint8>(sourceBytes.length);
      try {
        native.asTypedList(sourceBytes.length).setAll(0, sourceBytes);
        final int bytesPerSample = format.bytesPerSample;
        applyNativeGain(
          native,
          format,
          sourceBytes.length ~/ bytesPerSample,
          factor,
        );
        expect(native.asTypedList(sourceBytes.length), expected,
            reason: 'the $format kernels disagree at $factor');
      } finally {
        NativeAllocator.instance.free(native);
      }
    }

    test('float32', () {
      final Float32List source = _awkwardFloats();
      for (final double factor in <double>[0, 0.5, 1, 2.5, 1e-9]) {
        agree(
          AudioSampleFormat.float32,
          _bytesOf(source),
          factor,
          (Uint8List bytes) => PcmGain.applyFloat32(
            Float32List.view(bytes.buffer),
            factor,
          ),
        );
      }
    });

    test('signed16', () {
      final Int16List source =
          Int16List.fromList(<int>[-32768, -20000, -1, 0, 1, 20000, 32767]);
      for (final double factor in <double>[0, 0.5, 1, 1.5, 3, 1e300]) {
        agree(
          AudioSampleFormat.signed16,
          _bytesOf(source),
          factor,
          (Uint8List bytes) => PcmGain.applySigned16(
            Int16List.view(bytes.buffer),
            factor,
          ),
        );
      }
    });

    test('signed32', () {
      final Int32List source =
          Int32List.fromList(<int>[-2147483648, -5, 0, 5, 2147483647, 1000000]);
      for (final double factor in <double>[0, 0.25, 1, 7]) {
        agree(
          AudioSampleFormat.signed32,
          _bytesOf(source),
          factor,
          (Uint8List bytes) => PcmGain.applySigned32(
            Int32List.view(bytes.buffer),
            factor,
          ),
        );
      }
    });

    test('unsigned8', () {
      final List<int> source = <int>[0, 1, 64, 127, 128, 129, 200, 255];
      for (final double factor in <double>[0, 0.5, 1, 2]) {
        agree(
          AudioSampleFormat.unsigned8,
          source,
          factor,
          (Uint8List bytes) => PcmGain.applyUnsigned8(bytes, factor),
        );
      }
    });

    test('float64', () {
      final Float64List source =
          Float64List.fromList(<double>[0, -0.0, 1, -1, 1e-300, 1e300]);
      for (final double factor in <double>[0, 0.5, 1, 2]) {
        agree(
          AudioSampleFormat.float64,
          _bytesOf(source),
          factor,
          (Uint8List bytes) => PcmGain.applyFloat64(
            Float64List.view(bytes.buffer),
            factor,
          ),
        );
      }
    });
  });

  group('refusals', () {
    test('packed 24-bit names itself rather than passing samples through', () {
      final Pointer<Uint8> native = NativeAllocator.instance.allocate<Uint8>(6);
      addTearDown(() => NativeAllocator.instance.free(native));
      expect(nativeGainSupportsFormat(AudioSampleFormat.signed24), isFalse);
      expect(
        () => applyNativeGain(native, AudioSampleFormat.signed24, 2, 0.5),
        throwsA(isA<ArgumentError>().having(
          (ArgumentError error) => error.toString(),
          'message',
          contains('24-bit'),
        )),
      );
      // Unity is still free, because it touches nothing at all.
      applyNativeGain(native, AudioSampleFormat.signed24, 2, 1);
    });

    test('a NaN factor cannot reach a sample loop', () {
      final Float32List samples = Float32List(4);
      expect(
          () => PcmGain.applyFloat32(samples, double.nan), throwsArgumentError);
      expect(() => PcmGain.applyFloat32(samples, -1), throwsArgumentError);
    });
  });

  group('NativeFloat32GainStage', () {
    test('scales a block in place and is free at unity', () {
      final Pointer<Float> block =
          NativeAllocator.instance.allocate<Float>(4 * sizeOf<Float>());
      addTearDown(() => NativeAllocator.instance.free(block));
      block.asTypedList(4).setAll(0, <double>[1, -1, 0.5, -0.0]);

      final NativeFloat32GainStage stage = NativeFloat32GainStage(
        sampleRate: 48000,
        channels: 2,
      );
      addTearDown(stage.dispose);

      stage.processInPlace(block, 2);
      expect(block.asTypedList(4), <double>[1, -1, 0.5, -0.0]);
      expect(block[3].isNegative, isTrue, reason: 'unity touched nothing');

      stage.gain = AudioGain(0.5);
      stage.processInPlace(block, 2);
      expect(block.asTypedList(4), <double>[0.5, -0.5, 0.25, -0.0]);
    });
  });
}
