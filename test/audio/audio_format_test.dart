import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

void main() {
  test('PCM frame arithmetic is exact', () {
    const AudioFormat format = AudioFormat(
      sampleRate: 48000,
      channels: 2,
      sampleFormat: AudioSampleFormat.float32,
    );

    expect(format.bytesPerSample, 4);
    expect(format.bytesPerFrame, 8);
    expect(format.bytesPerSecond, 384000);
    expect(format.framesFor(const Duration(milliseconds: 10)), 480);
    expect(format.durationForFrames(480), const Duration(milliseconds: 10));
  });
}
