/// The device half of the playback path.
///
/// Everything here needs a real render endpoint, so every test is skipped when
/// the machine has none - the same rule `wasapi_backend_test.dart` follows.
/// The clips are short and quiet (a 200 Hz tone at -34 dBFS) because these do
/// make sound on the machine that runs them.
///
/// If one of these ever goes flaky, run `dart test test/audio
/// --concurrency=1` first: the audio suite has had contention between files
/// competing for the same endpoint, and a serial run tells that apart from a
/// real bug in the pump.
library;

import 'dart:io';
import 'dart:math' as math;

import 'package:dart_ui/audio.dart';
import 'package:test/test.dart';

/// Whether this machine can render audio at all.
bool _hasRenderEndpoint() {
  if (!Platform.isWindows) return false;
  try {
    final WasapiAudioBackend backend = WasapiAudioBackend();
    return backend.isAvailable && backend.enumerateDevices().isNotEmpty;
  } on Object {
    return false;
  }
}

/// A quiet 200 Hz tone at a rate no endpoint uses, so the player has to
/// resample it to whatever the engine negotiated.
NativePcmAudioBuffer _tone({
  int sampleRate = 44100,
  int channels = 1,
  Duration length = const Duration(milliseconds: 400),
}) {
  final int frames = length.inMicroseconds * sampleRate ~/ 1000000;
  final NativePcmAudioBuffer buffer = NativePcmAudioBuffer.allocate(
    sampleRate: sampleRate,
    channels: channels,
    frameCount: frames,
  );
  // Amplitude de 1e-6, cerca de -120 dBFS: fica abaixo do piso de ruido de
  // qualquer conversor e e inaudivel, mas continua diferente de zero — que e
  // a unica coisa que alguma assercao daqui exige do sinal. Um tom audivel
  // repetido a cada execucao da suite e como se para de rodar a suite.
  for (int frame = 0; frame < frames; frame++) {
    final double value =
        1e-6 * math.sin(2 * math.pi * 200 * frame / sampleRate);
    for (int channel = 0; channel < channels; channel++) {
      buffer.setSample(frame, channel, value);
    }
  }
  return buffer;
}

/// Polls [ready] until it holds, and reports whether it did in time.
Future<bool> _waitUntil(
  bool Function() ready, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final Stopwatch elapsed = Stopwatch()..start();
  while (elapsed.elapsed < timeout) {
    if (ready()) return true;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  return ready();
}

void main() {
  final bool hasEndpoint = _hasRenderEndpoint();
  final Object? skip =
      hasEndpoint ? null : 'no active WASAPI render endpoint on this machine';

  group('PcmAudioPlayers.open', () {
    test('reports the endpoint format, not the file format', () async {
      final NativePcmAudioBuffer pcm = _tone();
      addTearDown(pcm.dispose);
      final PcmAudioPlayer? player = PcmAudioPlayers.open(pcm);
      expect(player, isNotNull);
      addTearDown(player!.dispose);

      expect(player.sampleRate, greaterThan(0));
      expect(player.channels, greaterThan(0));
      // A shared-mode engine is nearly always 48 kHz, so this clip nearly
      // always has to be converted - and the duration must survive it.
      expect(
        player.duration.inMilliseconds,
        closeTo(pcm.duration.inMilliseconds, 2),
      );
      expect(player.position, Duration.zero);
      expect(player.isRunning, isFalse);
    });

    test('refuses a clip that has already been released', () {
      final NativePcmAudioBuffer pcm = _tone();
      pcm.dispose();
      expect(() => PcmAudioPlayers.open(pcm), throwsArgumentError);
    });

    test('leaves the caller owning the clip', () async {
      final NativePcmAudioBuffer pcm = _tone();
      addTearDown(pcm.dispose);
      final PcmAudioPlayer? player = PcmAudioPlayers.open(pcm);
      expect(player, isNotNull);
      await player!.dispose();
      expect(pcm.isDisposed, isFalse);
      expect(pcm.sampleAt(100, 0), isNot(0));
      // Disposing twice is a no-op, as everything in this package promises.
      await player.dispose();
    });
  }, skip: skip);

  group('the clock', () {
    test('advances only while the device is consuming', () async {
      final NativePcmAudioBuffer pcm = _tone(
        length: const Duration(milliseconds: 700),
      );
      addTearDown(pcm.dispose);
      final PcmAudioPlayer player = PcmAudioPlayers.open(pcm)!;
      addTearDown(player.dispose);

      expect(player.position, Duration.zero);
      player.play();
      expect(player.isRunning, isTrue);

      expect(
        await _waitUntil(
          () => player.position > const Duration(milliseconds: 20),
        ),
        isTrue,
        reason: 'the endpoint never started consuming this clip',
      );

      final Duration first = player.position;
      await Future<void>.delayed(const Duration(milliseconds: 120));
      final Duration second = player.position;
      expect(second, greaterThan(first));
      // Real time, not some multiple of it: a clip played at the wrong rate
      // would drain at the wrong speed.
      expect(
        (second - first).inMilliseconds,
        inInclusiveRange(40, 260),
        reason: 'the clock should track the wall clock while playing',
      );

      player.pause();
      expect(player.isRunning, isFalse);
      await Future<void>.delayed(const Duration(milliseconds: 120));
      final Duration paused = player.position;
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(player.position, paused, reason: 'a paused clock must stand');

      player.play();
      expect(
        await _waitUntil(() => player.position > paused),
        isTrue,
        reason: 'the clock did not resume',
      );
    });

    test('answers a seek before the device has acted on it', () async {
      final NativePcmAudioBuffer pcm = _tone(
        length: const Duration(milliseconds: 800),
      );
      addTearDown(pcm.dispose);
      final PcmAudioPlayer player = PcmAudioPlayers.open(pcm)!;
      addTearDown(player.dispose);

      player.seek(const Duration(milliseconds: 500));
      expect(
        player.position.inMilliseconds,
        closeTo(500, 2),
        reason: 'a seek must be visible immediately, not one period later',
      );

      // And it survives the round trip through the pump.
      player.play();
      expect(
        await _waitUntil(
          () => player.position > const Duration(milliseconds: 520),
        ),
        isTrue,
      );
      expect(player.position, greaterThan(const Duration(milliseconds: 500)));

      player.pause();
      player.seek(Duration.zero);
      expect(player.position, Duration.zero);
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(player.position, lessThan(const Duration(milliseconds: 30)));
    });

    test('clamps a seek to the clip', () async {
      final NativePcmAudioBuffer pcm = _tone();
      addTearDown(pcm.dispose);
      final PcmAudioPlayer player = PcmAudioPlayers.open(pcm)!;
      addTearDown(player.dispose);

      player.seek(const Duration(hours: 1));
      expect(player.position, player.duration);
      player.seek(const Duration(seconds: -30));
      expect(player.position, Duration.zero);
    });

    test('stops at the end of the clip, having played all of it', () async {
      final NativePcmAudioBuffer pcm = _tone(
        length: const Duration(milliseconds: 600),
      );
      addTearDown(pcm.dispose);
      final PcmAudioPlayer player = PcmAudioPlayers.open(pcm)!;
      addTearDown(player.dispose);

      player.seek(player.duration - const Duration(milliseconds: 150));
      player.play();
      expect(
        await _waitUntil(() => !player.isRunning),
        isTrue,
        reason: 'playback never reached the end of the clip',
      );
      // The last buffer is played, not truncated: the clock only reports the
      // end once the endpoint has drained.
      expect(
        player.position.inMilliseconds,
        closeTo(player.duration.inMilliseconds, 5),
      );
    });
  }, skip: skip);

  group('MediaAudioTracks.decodeFile', () {
    test('decodes the audio track of a media file', () {
      final String path = File(<String>[
        'examples',
        'drumer',
        'samples',
        'AK-Mixa-Kit',
        'kick 1.mp3',
      ].join(Platform.pathSeparator))
          .absolute
          .path;
      if (!File(path).existsSync()) return;

      final NativePcmAudioBuffer? decoded = MediaAudioTracks.decodeFile(path);
      expect(decoded, isNotNull);
      addTearDown(decoded!.dispose);
      expect(decoded.sampleRate, greaterThan(0));
      expect(decoded.channels, greaterThan(0));
      expect(decoded.frameCount, greaterThan(0));
    });

    test('returns null instead of throwing when there is no audio', () {
      // The three shapes of "no soundtrack" a video player can hit.
      expect(MediaAudioTracks.decodeFile('no-such-file.mp4'), isNull);
      expect(MediaAudioTracks.decodeFile('pubspec.yaml'), isNull);
      expect(MediaAudioTracks.decodeFile(''), isNull);
    });
  }, skip: Platform.isWindows ? null : 'Media Foundation is Windows-only');
}
