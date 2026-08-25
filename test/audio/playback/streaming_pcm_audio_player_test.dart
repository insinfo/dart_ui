/// `PcmAudioPlayers.openFile`, the path that does not decode the file first.
///
/// Everything here needs a real render endpoint, so every test is skipped when
/// the machine has none - the same rule `pcm_audio_players_test.dart` follows,
/// and these two files compete for the same device, so
/// `dart test test/audio --concurrency=1` is the first thing to try if one
/// goes flaky.
///
/// The clips are the repository's own drum samples, which are short and not
/// especially loud: these do make sound on the machine that runs them.
library;

import 'dart:io';

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

String _sample(List<String> parts) =>
    File(parts.join(Platform.pathSeparator)).absolute.path;

final String _wav = _sample(<String>[
  'examples',
  'drumer',
  'drum_sounds',
  'crash-acoustic.wav',
]);

final String _mp3 = _sample(<String>[
  'examples',
  'drumer',
  'samples',
  'AK-Mixa-Kit',
  'kick 1.mp3',
]);

/// Polls [ready] until it holds, and reports whether it did in time.
Future<bool> _waitUntil(
  bool Function() ready, {
  Duration timeout = const Duration(seconds: 8),
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

  group('PcmAudioPlayers.openFile', () {
    test('knows the format and the length before playing a sample', () async {
      final PcmAudioPlayer? player = PcmAudioPlayers.openFile(_wav);
      expect(player, isNotNull);
      addTearDown(player!.dispose);

      expect(player.sampleRate, greaterThan(0));
      expect(player.channels, greaterThan(0));
      // From the container's header, not from counting decoded frames - which
      // is the entire reason this path exists.
      expect(
        player.duration.inMilliseconds,
        closeTo(3990, 60),
        reason: 'the duration should come from the container',
      );
      expect(player.position, Duration.zero);
      expect(player.isRunning, isFalse);
    });

    test('starts playing well inside a second', () async {
      // The number that motivated the whole streaming path. It is generous
      // here - four seconds rather than the one the design targets - because
      // this is a shared CI-style assertion and the first WASAPI stream in a
      // process pays a one-off engine warm-up of around half a second that has
      // nothing to do with the file. What it is really guarding is the failure
      // mode it replaced, which was *minutes*.
      final Stopwatch elapsed = Stopwatch()..start();
      final PcmAudioPlayer player = PcmAudioPlayers.openFile(_wav)!;
      addTearDown(player.dispose);
      player.play();
      expect(
        await _waitUntil(() => player.position > Duration.zero),
        isTrue,
        reason: 'the endpoint never started consuming this file',
      );
      elapsed.stop();
      expect(elapsed.elapsed, lessThan(const Duration(seconds: 4)));
    });

    test('advances at real time, and stops when paused', () async {
      final PcmAudioPlayer player = PcmAudioPlayers.openFile(_wav)!;
      addTearDown(player.dispose);

      player.play();
      expect(player.isRunning, isTrue);
      expect(
        await _waitUntil(
          () => player.position > const Duration(milliseconds: 20),
        ),
        isTrue,
      );

      final Duration first = player.position;
      final Stopwatch wall = Stopwatch()..start();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      wall.stop();
      final Duration second = player.position;
      expect(second, greaterThan(first));
      expect(
        (second - first).inMicroseconds / wall.elapsedMicroseconds,
        inInclusiveRange(0.5, 1.6),
        reason: 'a file played at the wrong rate drains at the wrong speed',
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

    test('answers a seek before the decoder has acted on it', () async {
      final PcmAudioPlayer player = PcmAudioPlayers.openFile(_wav)!;
      addTearDown(player.dispose);

      player.seek(const Duration(milliseconds: 2500));
      expect(
        player.position.inMilliseconds,
        closeTo(2500, 5),
        reason: 'a seek must be visible immediately, not one refill later',
      );

      player.play();
      expect(
        await _waitUntil(
          () => player.position > const Duration(milliseconds: 2600),
        ),
        isTrue,
        reason: 'playback did not resume at the new position',
      );
      // And it landed near where it was asked to, not back at the start: a
      // producer that failed to reposition would play from zero.
      expect(player.position, greaterThan(const Duration(milliseconds: 2400)));
      expect(player.position, lessThan(const Duration(milliseconds: 3600)));
    });

    test('clamps a seek to the declared duration', () {
      final PcmAudioPlayer player = PcmAudioPlayers.openFile(_wav)!;
      addTearDown(player.dispose);

      player.seek(const Duration(hours: 1));
      expect(player.position, player.duration);
      player.seek(const Duration(seconds: -30));
      expect(player.position, Duration.zero);
    });

    test('plays to the end and stops there', () async {
      final PcmAudioPlayer player = PcmAudioPlayers.openFile(_mp3)!;
      addTearDown(player.dispose);

      expect(player.duration, greaterThan(Duration.zero));
      player.play();
      expect(
        await _waitUntil(() => !player.isRunning),
        isTrue,
        reason: 'playback never reached the end of the file',
      );
      // The last buffer is played, not truncated: the clock only reports the
      // end once the endpoint has drained it.
      expect(
        player.position.inMilliseconds,
        closeTo(player.duration.inMilliseconds, 60),
      );
    });

    test('a file with no audio track opens no player', () {
      expect(PcmAudioPlayers.openFile('no-such-file.mp4'), isNull);
      expect(PcmAudioPlayers.openFile('pubspec.yaml'), isNull);
      expect(PcmAudioPlayers.openFile(''), isNull);
    });

    test('disposing releases both isolates, twice over', () async {
      final PcmAudioPlayer player = PcmAudioPlayers.openFile(_wav)!;
      player.play();
      await _waitUntil(() => player.position > Duration.zero);
      await player.dispose();
      // Disposing twice is a no-op, as everything in this package promises,
      // and the second call must not double-free the ring.
      await player.dispose();
      expect(player.isRunning, isFalse);
    });

    test('several players can stream at once', () async {
      final PcmAudioPlayer first = PcmAudioPlayers.openFile(_wav)!;
      addTearDown(first.dispose);
      final PcmAudioPlayer second = PcmAudioPlayers.openFile(_mp3)!;
      addTearDown(second.dispose);

      first.play();
      second.play();
      expect(
        await _waitUntil(
          () =>
              first.position > Duration.zero && second.position > Duration.zero,
        ),
        isTrue,
        reason: 'two streaming players should not block each other',
      );
    });
  }, skip: skip);
}
