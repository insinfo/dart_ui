import 'dart:ffi';

import 'package:dart_ui/audio.dart';
import 'package:dart_ui/src/ffi/native_memory.dart';
import 'package:test/test.dart';

void main() {
  test('plays, seeks and stops a native PCM clip at its end', () {
    final NativePcmAudioBuffer clip = NativePcmAudioBuffer.allocate(
      sampleRate: 48000,
      channels: 1,
      frameCount: 3,
    );
    clip.samples.asTypedList(3).setAll(0, <double>[0.2, 0.4, 0.6]);
    final NativePcmClipPlayer player = NativePcmClipPlayer(clip)
      ..playing = true
      ..volume = 0.5;
    final Pointer<Float> output =
        NativeAllocator.instance.allocate<Float>(4 * sizeOf<Float>());
    addTearDown(() {
      NativeAllocator.instance.free(output);
      player.dispose();
      clip.dispose();
    });

    player.process(output, 4);
    expect(output[0], closeTo(0.1, 0.0001));
    expect(output[1], closeTo(0.2, 0.0001));
    expect(output[2], closeTo(0.3, 0.0001));
    expect(output[3], 0);
    expect(player.playing, isFalse);
    expect(player.isAtEnd, isTrue);

    player
      ..seekToFraction(1 / 3)
      ..playing = true
      ..process(output, 1);
    expect(output[0], closeTo(0.2, 0.0001));
  });
}
