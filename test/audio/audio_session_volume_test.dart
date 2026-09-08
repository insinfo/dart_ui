/// Discovering session volume, and the refusal when a backend has none.
///
/// No device is involved: the point of the capability shape is that a caller
/// can ask before it opens anything, and that the "no" is a named refusal
/// rather than a silent no-op. The fake stream below is a backend without
/// session volume, which is what every non-Windows backend in this repository
/// is today - see [kAudioSessionVolumeUnimplemented] for which platforms
/// could have it and which never can.
library;

import 'package:dart_ui/audio.dart';
import 'package:test/test.dart';

/// A stream from a backend that has stream gain and no session volume.
///
/// Deliberately *not* implementing [AudioSessionVolume]: that is the whole
/// case under test. It does implement gain, because gain is portable and every
/// backend can promise it.
final class _GainOnlyStream implements AudioStream {
  @override
  AudioStreamConfiguration get configuration => const AudioStreamConfiguration(
        format: AudioFormat(
          sampleRate: 48000,
          channels: 2,
          sampleFormat: AudioSampleFormat.float32,
        ),
        periodFrames: 480,
        bufferFrames: 960,
        streamLatency: Duration(milliseconds: 10),
      );

  @override
  AudioStreamState get state => AudioStreamState.stopped;

  @override
  AudioGain gain = AudioGain.unity;

  @override
  void start() {}

  @override
  void stop() {}

  @override
  bool get isDisposed => false;

  @override
  void dispose() {}
}

void main() {
  test('a backend without session volume is not discovered as having it', () {
    final _GainOnlyStream stream = _GainOnlyStream();
    expect(AudioSessionVolumes.of(stream), isNull);
  });

  test('demanding it produces a refusal that names the backend', () {
    final _GainOnlyStream stream = _GainOnlyStream();
    expect(
      () => AudioSessionVolumes.require(stream),
      throwsA(isA<AudioCapabilityError>()
          .having((AudioCapabilityError e) => e.capability, 'capability',
              'session volume')
          .having((AudioCapabilityError e) => e.backendName, 'backendName',
              contains('GainOnlyStream'))
          .having((AudioCapabilityError e) => e.toString(), 'toString',
              contains('does not provide session volume'))),
    );
  });

  test('stream gain is not offered as a substitute for it', () {
    // The failure this guards against is a helpful fallback: returning an
    // AudioSessionVolume backed by the stream's own gain would make
    // `AudioSessionVolumes.require` always succeed and always lie. One is
    // inside this process and invisible to the user; the other is the
    // operating system's and visible to everyone.
    final _GainOnlyStream stream = _GainOnlyStream()
      ..gain = AudioGain.decibels(-20);
    expect(AudioSessionVolumes.of(stream), isNull);
    expect(stream.gain.factor, closeTo(0.1, 1e-12));
  });

  test('every unimplemented platform states which kind of "no" it is', () {
    // "Not needed" against "not noticed", the distinction
    // kMetalDeliberatelyUnbound exists to keep visible. A future implementer
    // has to be able to tell an API that does not exist from one nobody has
    // bound yet before spending an afternoon looking for the first.
    expect(kAudioSessionVolumeUnimplemented.keys,
        containsAll(<String>['ALSA', 'CoreAudio (macOS)', 'PulseAudio']));
    for (final MapEntry<String, String> entry
        in kAudioSessionVolumeUnimplemented.entries) {
      expect(entry.value, isNotEmpty, reason: '${entry.key} has no reason');
    }
    expect(kAudioSessionVolumeUnimplemented['ALSA'], contains('no session'));
    expect(kAudioSessionVolumeUnimplemented['PulseAudio'],
        contains('no PulseAudio AudioBackend'));
  });

  test('gain on a portable stream defaults to bit-identical passthrough', () {
    expect(_GainOnlyStream().gain, AudioGain.unity);
  });
}
