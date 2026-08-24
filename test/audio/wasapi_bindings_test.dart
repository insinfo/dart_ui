import 'dart:ffi';

import 'package:dart_ui/audio.dart';
import 'package:dart_ui/src/ffi/native_memory.dart';
import 'package:test/test.dart';

void main() {
  test('WAVEFORMATEXTENSIBLE round-trips through native memory', () {
    final NativeArena arena = NativeArena();
    addTearDown(arena.dispose);
    const AudioFormat expected = AudioFormat(
      sampleRate: 48000,
      channels: 2,
      sampleFormat: AudioSampleFormat.float32,
    );

    final Pointer<Uint8> pointer = WasapiWaveFormat.allocate(expected, arena);
    final WasapiWaveFormat actual = WasapiWaveFormat.read(pointer);

    expect(actual.format, expected.copyWithChannelMask(3));
    expect(actual.validBitsPerSample, 32);
  });

  test('engine period is clamped and rounded to the fundamental period', () {
    expect(
      chooseWasapiPeriod(
        requested: 130,
        fundamental: 16,
        minimum: 48,
        maximum: 480,
      ),
      128,
    );
    expect(
      chooseWasapiPeriod(
        requested: 1,
        fundamental: 16,
        minimum: 48,
        maximum: 480,
      ),
      48,
    );
  });
}

extension on AudioFormat {
  AudioFormat copyWithChannelMask(int mask) => AudioFormat(
        sampleRate: sampleRate,
        channels: channels,
        sampleFormat: sampleFormat,
        interleaved: interleaved,
        channelMask: mask,
      );
}
