import 'dart:ffi';
import 'dart:math' as math;

import 'package:dart_ui/audio.dart';
import 'package:dart_ui/src/ffi/native_memory.dart';
import 'package:test/test.dart';

void main() {
  test('spectrum filter bank reacts near the source frequency and resets', () {
    final NativeSpectrumAnalyzer analyzer = NativeSpectrumAnalyzer(
      sampleRate: 48000,
      channels: 2,
      bandCount: 24,
      outputGain: 1,
    );
    final Pointer<Float> samples =
        NativeAllocator.instance.allocate<Float>(4096 * 2 * sizeOf<Float>());
    try {
      for (int frame = 0; frame < 4096; frame++) {
        final double value = math.sin(2 * math.pi * 1000 * frame / 48000);
        samples[frame * 2] = value;
        samples[frame * 2 + 1] = value;
      }
      analyzer.processInPlace(samples, 4096);

      int loudest = 0;
      for (int band = 1; band < analyzer.bandCount; band++) {
        if (analyzer.levelAt(band) > analyzer.levelAt(loudest)) {
          loudest = band;
        }
      }
      expect(analyzer.frequencyAt(loudest), inInclusiveRange(650, 1500));
      expect(analyzer.levelAt(loudest), greaterThan(0.1));

      analyzer.reset();
      for (int band = 0; band < analyzer.bandCount; band++) {
        expect(analyzer.levelAt(band), 0);
      }
    } finally {
      NativeAllocator.instance.free(samples);
      analyzer.dispose();
    }
  });
}
