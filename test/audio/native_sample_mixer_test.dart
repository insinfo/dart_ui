import 'dart:ffi';

import 'package:dart_ui/audio.dart';
import 'package:dart_ui/src/ffi/native_memory.dart';
import 'package:test/test.dart';

void main() {
  test('mixes overlapping native samples without allocating voices', () {
    final NativePcmAudioBuffer sample = NativePcmAudioBuffer.allocate(
      sampleRate: 48000,
      channels: 2,
      frameCount: 2,
    );
    sample.samples.asTypedList(4).setAll(0, <double>[0.5, -0.5, 0.25, -0.25]);
    final NativeSampleMixer mixer = NativeSampleMixer(
      sampleRate: 48000,
      channels: 2,
      samples: <NativePcmAudioBuffer>[sample],
      maxVoices: 2,
    );
    final Pointer<Float> output =
        NativeAllocator.instance.allocate<Float>(4 * sizeOf<Float>());
    addTearDown(() {
      NativeAllocator.instance.free(output);
      mixer.dispose();
      sample.dispose();
    });

    mixer
      ..trigger(0, gain: 0.5)
      ..trigger(0, gain: 0.5)
      ..process(output, 2);
    expect(output[0], closeTo(0.5 / 1.14, 0.0001));
    expect(output[1], closeTo(-0.5 / 1.14, 0.0001));
    expect(mixer.activeVoiceCount, 0);
  });

  test('choke group stops a previous voice', () {
    final NativePcmAudioBuffer sample = NativePcmAudioBuffer.allocate(
      sampleRate: 48000,
      channels: 1,
      frameCount: 4,
    );
    sample.samples.asTypedList(4).fillRange(0, 4, 0.5);
    final NativeSampleMixer mixer = NativeSampleMixer(
      sampleRate: 48000,
      channels: 1,
      samples: <NativePcmAudioBuffer>[sample],
      maxVoices: 4,
    );
    addTearDown(() {
      mixer.dispose();
      sample.dispose();
    });

    mixer.trigger(0, chokeGroup: 3);
    mixer.trigger(0, chokeGroup: 3);
    expect(mixer.activeVoiceCount, 1);
  });
}
