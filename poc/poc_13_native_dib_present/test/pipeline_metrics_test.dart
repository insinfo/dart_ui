import 'package:poc_13_native_dib_present/poc_13_native_dib_present.dart';
import 'package:test/test.dart';

void main() {
  test('computes comparable per-frame and per-pixel metrics', () {
    const copied = PipelineMetrics(
      name: 'dartCopy',
      frames: 100,
      pixelsPerFrame: 1000,
      elapsed: Duration(seconds: 2),
      renderMicroseconds: 100000,
      presentMicroseconds: 400000,
    );
    const native = PipelineMetrics(
      name: 'nativeDib',
      frames: 100,
      pixelsPerFrame: 1000,
      elapsed: Duration(seconds: 1),
      renderMicroseconds: 200000,
      presentMicroseconds: 100000,
    );
    const comparison = PipelineComparison(
      dartCopy: copied,
      nativeDib: native,
    );

    expect(copied.framesPerSecond, 50);
    expect(copied.averageRenderMicroseconds, 1000);
    expect(copied.averagePresentMicroseconds, 4000);
    expect(copied.renderNanosecondsPerPixel, 1000);
    expect(comparison.presentationSpeedup, 4);
    expect(comparison.throughputSpeedup, 2);
  });
}
