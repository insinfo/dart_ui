import 'dart:ffi';
import 'dart:math' as math;

import 'package:dart_ui/audio.dart';
import 'package:dart_ui/src/ffi/native_memory.dart';
import 'package:test/test.dart';

void main() {
  test('ten unity bands preserve the input block', () {
    const int frames = 64;
    final Pointer<Float> samples =
        NativeAllocator.instance.allocate<Float>(frames * sizeOf<Float>());
    final NativeGraphicEqualizer equalizer = NativeGraphicEqualizer(
      sampleRate: 48000,
      channels: 1,
      frequencies: const <double>[
        31,
        62,
        125,
        250,
        500,
        1000,
        2000,
        4000,
        8000,
        16000,
      ],
    );
    addTearDown(() {
      equalizer.dispose();
      NativeAllocator.instance.free(samples);
    });
    for (int frame = 0; frame < frames; frame++) {
      samples[frame] = math.sin(frame * 0.13) * 0.25;
    }
    final List<double> before = List<double>.of(samples.asTypedList(frames));
    equalizer.processInPlace(samples, frames);
    for (int frame = 0; frame < frames; frame++) {
      expect(samples[frame], closeTo(before[frame], 0.000001));
    }
  });

  test('updates individual bands, clamps gain and clears delay state', () {
    final NativeGraphicEqualizer equalizer = NativeGraphicEqualizer(
      sampleRate: 48000,
      channels: 2,
      frequencies: const <double>[125, 1000, 8000],
    );
    final Pointer<Float> samples =
        NativeAllocator.instance.allocate<Float>(128 * 2 * sizeOf<Float>());
    addTearDown(() {
      equalizer.dispose();
      NativeAllocator.instance.free(samples);
    });
    equalizer.setGainDb(1, 50);
    expect(equalizer.gainDbAt(1), 12);
    samples[0] = 0.4;
    samples[1] = 0.4;
    equalizer.processInPlace(samples, 128);
    expect(
        samples.asTypedList(256).skip(2).any((v) => v.abs() > 0.00001), isTrue);
    samples.asTypedList(256).fillRange(0, 256, 0);
    equalizer
      ..reset()
      ..processInPlace(samples, 128);
    expect(samples.asTypedList(256), everyElement(0));
  });
}
