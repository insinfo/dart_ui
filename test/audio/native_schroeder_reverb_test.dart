import 'dart:ffi';

import 'package:dart_ui/audio.dart';
import 'package:dart_ui/src/ffi/native_memory.dart';
import 'package:test/test.dart';

void main() {
  test('native Schroeder reverb produces a decaying impulse tail', () {
    const int frames = 256;
    const int channels = 2;
    final Pointer<Float> samples = NativeAllocator.instance.allocate<Float>(
      frames * channels * sizeOf<Float>(),
    );
    final NativeSchroederReverb reverb = NativeSchroederReverb(
      sampleRate: 48000,
      channels: channels,
      wet: 0.7,
      roomSize: 0.75,
      damping: 0.25,
    );
    addTearDown(() {
      reverb.dispose();
      NativeAllocator.instance.free(samples);
    });

    for (int sample = 0; sample < frames * channels; sample++) {
      samples[sample] = 0;
    }
    samples[0] = 1;
    samples[1] = 1;

    double tailEnergy = 0;
    for (int block = 0; block < 32; block++) {
      reverb.processInPlace(samples, frames);
      if (block > 2) {
        for (int sample = 0; sample < frames * channels; sample++) {
          tailEnergy += samples[sample].abs();
        }
      }
      for (int sample = 0; sample < frames * channels; sample++) {
        samples[sample] = 0;
      }
    }
    expect(tailEnergy, greaterThan(0.01));

    reverb.reset();
    reverb.processInPlace(samples, frames);
    expect(
      <double>[
        for (int sample = 0; sample < frames * channels; sample++)
          samples[sample],
      ],
      everyElement(0),
    );
  });
}
