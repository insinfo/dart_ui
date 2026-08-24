import 'dart:io';

import 'package:dart_ui/audio.dart';
import 'package:test/test.dart';

void main() {
  test(
    'IAudioClient3 backend loads and enumerates active render endpoints',
    () {
      final WasapiAudioBackend backend = WasapiAudioBackend();
      expect(backend.isAvailable, isTrue);
      final List<AudioDeviceInfo> devices = backend.enumerateDevices();
      for (final AudioDeviceInfo device in devices) {
        expect(device.id, isNotEmpty);
        expect(device.name, isNotEmpty);
        expect(device.direction, AudioDeviceDirection.output);
      }
    },
    skip: !Platform.isWindows,
  );

  test(
    'default shared render stream negotiates an engine period',
    () {
      final WasapiAudioBackend backend = WasapiAudioBackend();
      if (backend.enumerateDevices().isEmpty) return;
      final WasapiRenderStream stream = backend.openStream(
        const AudioStreamRequest(preferredPeriodFrames: 128),
      );
      addTearDown(stream.dispose);

      expect(stream.configuration.format.sampleRate, greaterThan(0));
      expect(stream.configuration.periodFrames, greaterThan(0));
      expect(stream.configuration.bufferFrames,
          greaterThanOrEqualTo(stream.configuration.periodFrames));
      expect(stream.state, AudioStreamState.stopped);

      final WasapiSharedRingBuffer ring = WasapiSharedRingBuffer.allocate(
        capacityFrames: stream.configuration.bufferFrames * 2,
        bytesPerFrame: stream.configuration.format.bytesPerFrame,
      );
      addTearDown(ring.dispose);
      stream.start();
      expect(stream.state, AudioStreamState.running);
      expect(stream.waitForPeriod(timeoutMilliseconds: 1000), isTrue);
      expect(stream.renderAvailableFrom(ring), 0,
          reason: 'an empty ring is rendered as silence');
      stream.stop();
      expect(stream.state, AudioStreamState.stopped);
    },
    skip: !Platform.isWindows,
  );
}
