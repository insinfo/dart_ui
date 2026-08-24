import 'dart:ffi';
import 'dart:math' as math;

import 'package:dart_ui/audio.dart';
import 'package:dart_ui/src/ffi/native_memory.dart';
import 'package:test/test.dart';

void main() {
  test('unity equalizer leaves samples unchanged', () {
    const int frames = 32;
    final Pointer<Float> samples =
        NativeAllocator.instance.allocate<Float>(frames * sizeOf<Float>());
    final NativeThreeBandEqualizer equalizer = NativeThreeBandEqualizer(
      sampleRate: 48000,
      channels: 1,
    );
    addTearDown(() {
      equalizer.dispose();
      NativeAllocator.instance.free(samples);
    });
    for (int frame = 0; frame < frames; frame++) {
      samples[frame] = math.sin(frame * 0.31) * 0.4;
    }
    final List<double> before = List<double>.of(samples.asTypedList(frames));
    equalizer.processInPlace(samples, frames);
    for (int frame = 0; frame < frames; frame++) {
      expect(samples[frame], closeTo(before[frame], 0.000001));
    }
  });

  test('bass boost changes an impulse and reset clears filter state', () {
    const int frames = 128;
    final Pointer<Float> samples =
        NativeAllocator.instance.allocate<Float>(frames * sizeOf<Float>());
    final NativeThreeBandEqualizer equalizer = NativeThreeBandEqualizer(
      sampleRate: 48000,
      channels: 1,
      bassGainDb: 9,
    );
    addTearDown(() {
      equalizer.dispose();
      NativeAllocator.instance.free(samples);
    });
    samples[0] = 0.5;
    equalizer.processInPlace(samples, frames);
    expect(samples.asTypedList(frames).skip(1).any((v) => v.abs() > 0.00001),
        isTrue);
    samples.asTypedList(frames).fillRange(0, frames, 0);
    equalizer
      ..reset()
      ..processInPlace(samples, frames);
    expect(samples.asTypedList(frames), everyElement(0));
  });
}
