/// Gain travelling from the player down to the pump, and what it must not do.
///
/// The clip here is a 200 Hz tone at an amplitude of 1e-6, about -120 dBFS,
/// which is below the noise floor of any converter - the rule
/// `pcm_audio_players_test.dart` established, and the reason a suite that
/// touches the audio device is still one somebody can run while working.
library;

import 'dart:io';
import 'dart:math' as math;

import 'package:dart_ui/audio.dart';
import 'package:dart_ui/src/audio/playback/wasapi_playback_control_block.dart';
import 'package:test/test.dart';

bool _hasRenderEndpoint() {
  if (!Platform.isWindows) return false;
  try {
    final WasapiAudioBackend backend = WasapiAudioBackend();
    return backend.isAvailable && backend.enumerateDevices().isNotEmpty;
  } on Object {
    return false;
  }
}

NativePcmAudioBuffer _tone({
  int sampleRate = 44100,
  Duration length = const Duration(milliseconds: 600),
}) {
  final int frames = length.inMicroseconds * sampleRate ~/ 1000000;
  final NativePcmAudioBuffer buffer = NativePcmAudioBuffer.allocate(
    sampleRate: sampleRate,
    channels: 1,
    frameCount: frames,
  );
  for (int frame = 0; frame < frames; frame++) {
    buffer.setSample(
      frame,
      0,
      1e-6 * math.sin(2 * math.pi * 200 * frame / sampleRate),
    );
  }
  return buffer;
}

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
  final Object? windowsOnly =
      Platform.isWindows ? null : 'the control block is a Windows allocation';

  group('WasapiPlaybackControlBlock', () {
    test(
      'a fresh block is at unity, not at the zero its memory arrived as',
      () {
        // The trap this asserts: NativeAllocator zeroes what it hands back and
        // zero is a *legitimate* gain - exact silence. A block that never had
        // unity written would play nothing while reporting a healthy clock and
        // a rendering state, which is the hardest kind of silence to diagnose.
        final WasapiPlaybackControlBlock block =
            WasapiPlaybackControlBlock.allocate();
        addTearDown(block.dispose);
        expect(block.requestedGain, 1.0);

        final PlaybackControlSnapshot snapshot = PlaybackControlSnapshot();
        expect(block.tryReadControl(snapshot), isTrue);
        expect(snapshot.gain, 1.0);
      },
      skip: windowsOnly,
    );

    test(
      'a requested gain reaches the pump through the same snapshot as the '
      'transport',
      () {
        final WasapiPlaybackControlBlock block =
            WasapiPlaybackControlBlock.allocate();
        addTearDown(block.dispose);
        final PlaybackControlSnapshot snapshot = PlaybackControlSnapshot();

        block
          ..requestGain(0.25)
          ..requestPlaying(true);
        expect(block.tryReadControl(snapshot), isTrue);
        expect(snapshot.gain, 0.25);
        expect(snapshot.playRequested, isTrue);

        block.requestGain(0);
        expect(block.tryReadControl(snapshot), isTrue);
        expect(snapshot.gain, 0.0);

        expect(() => block.requestGain(double.nan), throwsArgumentError);
        expect(() => block.requestGain(-1), throwsArgumentError);
      },
      skip: windowsOnly,
    );

    test(
      'attaching to a block from an older layout is refused',
      () {
        // The gain slot changed the block's length and version. Attaching an
        // old pump to a new block would read the gain out of whatever follows
        // the allocation, and the value it would find there is a volume.
        final WasapiPlaybackControlBlock block =
            WasapiPlaybackControlBlock.allocate();
        addTearDown(block.dispose);
        expect(
          () => WasapiPlaybackControlBlock.attach(block.address + 8),
          throwsStateError,
        );
      },
      skip: windowsOnly,
    );
  });

  group('PcmAudioPlayer.gain', () {
    final bool hasEndpoint = _hasRenderEndpoint();
    final Object? skip =
        hasEndpoint ? null : 'no active WASAPI render endpoint on this machine';

    test(
      'defaults to unity and reads back what was asked for',
      () async {
        final NativePcmAudioBuffer pcm = _tone();
        addTearDown(pcm.dispose);
        final PcmAudioPlayer player = PcmAudioPlayers.open(pcm)!;
        addTearDown(player.dispose);

        expect(player.gain, AudioGain.unity);
        player.gain = AudioGain.decibels(-30);
        expect(player.gain.factor, closeTo(0.0316227, 1e-6));
        player.gain = AudioGain.silence;
        expect(player.gain, AudioGain.silence);
      },
      skip: skip,
    );

    test(
      'silence silences the samples and does not stop the clock',
      () async {
        // The distinction the whole design turns on. A player at zero gain is
        // still running: the endpoint still consumes frames and [position]
        // still advances, so a profiling run at zero volume exercises the same
        // code a run at full volume does. A "silence" that quietly stopped the
        // pump would have measured a different program - and it was a
        // full-volume profiling run that exposed the absence of this control.
        final NativePcmAudioBuffer pcm = _tone();
        addTearDown(pcm.dispose);
        final PcmAudioPlayer player = PcmAudioPlayers.open(pcm)!;
        addTearDown(player.dispose);

        player
          ..gain = AudioGain.silence
          ..play();
        expect(
          await _waitUntil(() => player.position > Duration.zero),
          isTrue,
          reason: 'the endpoint kept consuming frames at zero gain',
        );
        expect(player.isRunning, isTrue);

        final Duration first = player.position;
        expect(
          await _waitUntil(() => player.position > first),
          isTrue,
          reason: 'the clock kept advancing at zero gain',
        );
        player.pause();
      },
      skip: skip,
    );

    test(
      'a gain change mid-playback is accepted without disturbing the clock',
      () async {
        final NativePcmAudioBuffer pcm = _tone();
        addTearDown(pcm.dispose);
        final PcmAudioPlayer player = PcmAudioPlayers.open(pcm)!;
        addTearDown(player.dispose);

        player
          ..gain = AudioGain.silence
          ..play();
        expect(await _waitUntil(() => player.position > Duration.zero), isTrue);
        final Duration beforeChange = player.position;

        // -60 dB on a -120 dBFS tone is -180 dBFS: still nothing anybody can
        // hear, and still a value the gain path has to actually apply.
        player.gain = AudioGain.decibels(-60);
        expect(
          await _waitUntil(() => player.position > beforeChange),
          isTrue,
          reason: 'the pump applied the new gain and kept rendering',
        );
        player.pause();
      },
      skip: skip,
    );
  });
}
