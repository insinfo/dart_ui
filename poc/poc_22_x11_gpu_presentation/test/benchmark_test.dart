import 'package:poc_22_x11_gpu_presentation/poc_22_x11_gpu_presentation.dart';
import 'package:test/test.dart';

void main() {
  test('configuration reports tightly packed BGRA frame size', () {
    const configuration = PresentationConfiguration(
      width: 640,
      height: 360,
      frames: 100,
      warmupFrames: 10,
    );

    expect(configuration.frameBytes, 640 * 360 * 4);
  });

  test('measurement derives frame rate, latency, and equivalent throughput',
      () {
    const configuration = PresentationConfiguration(
      width: 100,
      height: 50,
      frames: 200,
      warmupFrames: 0,
    );
    const measurement = PresentationMeasurement(
      backend: 'test',
      device: 'test device',
      mode: 'test mode',
      setupMicroseconds: 123,
      elapsedMicroseconds: 100000,
      configuration: configuration,
    );

    expect(measurement.framesPerSecond, 2000);
    expect(measurement.meanFrameMicroseconds, 500);
    expect(measurement.equivalentMegabytesPerSecond, 40);
    expect(measurement.toJson(), containsPair('setupUs', 123));
  });
}
