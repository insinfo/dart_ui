/// The portable realtime output against the real device: WASAPI on Windows,
/// an Audio Queue on macOS. Skipped where [AudioProcessorOutput.open] says
/// there is no output. The processor writes silence, so nothing is heard.
library;

import 'dart:ffi';

import 'package:dart_ui/audio.dart';
import 'package:dart_ui/src/foundation/lifecycle.dart';
import 'package:test/test.dart';

const int _blocks = 0;
const int _echo = 1;

final class _CountingSilence
    with DisposableMixin
    implements NativeFloat32AudioProcessor {
  _CountingSilence(this.sampleRate, this.channels, this.controls);

  @override
  final int sampleRate;
  @override
  final int channels;
  final AudioControlBlock controls;

  @override
  void process(Pointer<Float> samples, int frames) {
    for (var i = 0; i < frames * channels; i++) {
      samples[i] = 0;
    }
    controls
      ..publish(_blocks, controls.telemetry(_blocks) + 1)
      ..publish(_echo, controls.parameter(0));
  }

  @override
  void onDispose() {}
}

NativeFloat32AudioProcessor _build(AudioOutputContext context) {
  context.details['built'] = 'on the audio isolate';
  return _CountingSilence(
      context.sampleRate, context.channels, context.controls!);
}

NativeFloat32AudioProcessor _failing(AudioOutputContext context) =>
    throw StateError('builder refused');

Future<bool> _waitUntil(bool Function() ready) async {
  final Stopwatch watch = Stopwatch()..start();
  while (watch.elapsed < const Duration(seconds: 3)) {
    if (ready()) return true;
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  return ready();
}

void main() {
  test('a processor renders on its own isolate and reads the controls',
      () async {
    final AudioControlBlock controls =
        AudioControlBlock.allocate(parameters: 1, telemetry: 2);
    final AudioProcessorOutput? output =
        await AudioProcessorOutput.open(_build, controls: controls);
    if (output == null) {
      controls.dispose();
      markTestSkipped('no audio output on this machine');
      return;
    }
    expect(output.details['built'], 'on the audio isolate');
    expect(output.sampleRate, greaterThan(0));
    expect(output.backend, isNotEmpty);
    expect(await _waitUntil(() => controls.telemetry(_blocks) >= 3), isTrue,
        reason: 'the device keeps asking for blocks');
    controls.setParameter(0, 0.75);
    expect(await _waitUntil(() => controls.telemetry(_echo) == 0.75), isTrue);
    await output.close();
    expect(output.error, isNull);
    final double after = controls.telemetry(_blocks);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(controls.telemetry(_blocks), after, reason: 'closed means stopped');
    controls.dispose();
  });

  test('a throw from the builder comes back from open', () async {
    final AudioControlBlock controls = AudioControlBlock.allocate();
    final Future<AudioProcessorOutput?> opening =
        AudioProcessorOutput.open(_failing, controls: controls);
    try {
      final AudioProcessorOutput? output = await opening;
      // Only a machine with no output never runs the builder.
      expect(output, isNull);
    } on StateError catch (error) {
      expect('$error', contains('builder refused'));
    }
    controls.dispose();
  });
}
