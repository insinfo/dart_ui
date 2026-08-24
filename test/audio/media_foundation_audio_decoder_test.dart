import 'dart:ffi';
import 'dart:io';

import 'package:dart_ui/audio.dart';
import 'package:test/test.dart';

void main() {
  test(
    'Media Foundation decodes MP3 into owned float32 PCM',
    () {
      final String path = <String>[
        'examples',
        'drumer',
        'samples',
        'AK-Mixa-Kit',
        'kick 1.mp3',
      ].join(Platform.pathSeparator);
      final NativePcmAudioBuffer decoded =
          MediaFoundationAudioDecoder.decodeFile(File(path).absolute.path);
      addTearDown(decoded.dispose);

      expect(decoded.sampleRate, greaterThan(0));
      expect(decoded.channels, greaterThan(0));
      expect(decoded.frameCount, greaterThan(1000));
      expect(
        decoded.samples.asTypedList(decoded.sampleCount).any(
              (double sample) => sample.abs() > 0.0001,
            ),
        isTrue,
      );
    },
    skip: !Platform.isWindows,
  );
}
