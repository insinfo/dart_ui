import 'dart:ffi';

import 'package:dart_ui/audio.dart';
import 'package:dart_ui/src/ffi/native_memory.dart';
import 'package:test/test.dart';

void main() {
  test('waveform keeps recent downmixed PCM and resets', () {
    final NativeWaveformAnalyzer analyzer = NativeWaveformAnalyzer(
      sampleRate: 48000,
      channels: 2,
      pointCount: 4,
      windowFrames: 8,
    );
    final Pointer<Float> samples =
        NativeAllocator.instance.allocate<Float>(8 * 2 * sizeOf<Float>());
    try {
      for (int frame = 0; frame < 8; frame++) {
        samples[frame * 2] = frame / 8;
        samples[frame * 2 + 1] = frame / 8;
      }
      analyzer.processInPlace(samples, 8);

      expect(analyzer.sampleAt(0), closeTo(0, 1e-6));
      expect(analyzer.sampleAt(3), closeTo(7 / 8, 1e-6));
      expect(analyzer.sampleAt(2), greaterThan(analyzer.sampleAt(1)));

      analyzer.reset();
      for (int point = 0; point < analyzer.pointCount; point++) {
        expect(analyzer.sampleAt(point), 0);
      }
    } finally {
      NativeAllocator.instance.free(samples);
      analyzer.dispose();
    }
  });
}
