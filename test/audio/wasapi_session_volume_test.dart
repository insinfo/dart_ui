/// The WASAPI half of volume: session volume, and gain on a real stream.
///
/// ## How this stays silent
///
/// Three ways at once, because the gap this file tests was found when a
/// profiling run played a tone through somebody's speakers at full volume and
/// interrupted them.
///
///   1. The session volume is set near zero **before** the stream is ever
///      started, and the session is muted as well.
///   2. The only signal rendered is at an amplitude of 1e-6, about -120 dBFS,
///      which is below the noise floor of any converter - the same rule
///      `playback/pcm_audio_players_test.dart` follows.
///   3. Playback lasts a few engine periods, tens of milliseconds.
///
/// The session volume and mute are the *user's* settings - Windows persists
/// them per application, so a test that left them where it found them would
/// silently change what `dart.exe` sounds like from then on. Both are read
/// first and restored in a `finally`, not only in a tear-down.
///
/// ## Why it skips with a string
///
/// A machine with no render endpoint cannot answer any of these, and a test
/// that quietly returned would report a pass for a question it never asked.
/// The string is what the runner prints, so an empty CI machine says why.
library;

import 'dart:ffi';
import 'dart:io';
import 'dart:math' as math;

import 'package:dart_ui/audio.dart';
import 'package:test/test.dart';

/// Whether this machine can open a shared-mode render stream at all.
bool _hasRenderEndpoint() {
  if (!Platform.isWindows) return false;
  try {
    final WasapiAudioBackend backend = WasapiAudioBackend();
    return backend.isAvailable && backend.enumerateDevices().isNotEmpty;
  } on Object {
    return false;
  }
}

/// Fills a block with a 200 Hz tone at -120 dBFS.
///
/// Non-zero on purpose: a processor writing silence would pass every assertion
/// here even if the gain path were dropping the buffer on the floor.
final class _InaudibleTone implements NativeFloat32AudioProcessor {
  _InaudibleTone({required this.sampleRate, required this.channels});

  @override
  final int sampleRate;

  @override
  final int channels;

  int processedFrames = 0;
  int _phase = 0;
  bool _disposed = false;

  @override
  bool get isDisposed => _disposed;

  @override
  void process(Pointer<Float> interleavedSamples, int frames) {
    for (int frame = 0; frame < frames; frame++) {
      final double value =
          1e-6 * math.sin(2 * math.pi * 200 * _phase / sampleRate);
      for (int channel = 0; channel < channels; channel++) {
        interleavedSamples[(frame * channels) + channel] = value;
      }
      _phase++;
    }
    processedFrames += frames;
  }

  @override
  void dispose() => _disposed = true;
}

void main() {
  final bool hasEndpoint = _hasRenderEndpoint();
  final Object? skip =
      hasEndpoint ? null : 'no active WASAPI render endpoint on this machine';

  test(
    'a WASAPI render stream offers session volume, and gain, and they differ',
    () {
      final WasapiAudioBackend backend = WasapiAudioBackend();
      final WasapiRenderStream stream =
          backend.openStream(const AudioStreamRequest());
      addTearDown(stream.dispose);

      // Discovery, not an assumption about the backend's class.
      final AudioSessionVolume session = AudioSessionVolumes.require(stream);
      expect(identical(session, stream), isTrue,
          reason: 'WASAPI implements the capability on the stream itself');

      final double originalVolume = session.sessionVolume;
      final bool originalMute = session.sessionMuted;
      expect(originalVolume, inInclusiveRange(0.0, 1.0));

      try {
        // Quiet first, loud never. Both guards go on before the engine is
        // started, and 0.0001 rather than 0 so that nothing about the write
        // path can be short-circuited by a zero check somewhere below.
        session
          ..sessionVolume = 0.0001
          ..sessionMuted = true;
        expect(session.sessionVolume, closeTo(0.0001, 1e-5));
        expect(session.sessionMuted, isTrue);

        // Level and mute are separate pieces of state, and the platform keeps
        // them separate: a caller that "muted" by writing zero would have
        // destroyed the level the user chose.
        session.sessionMuted = false;
        expect(session.sessionMuted, isFalse);
        expect(session.sessionVolume, closeTo(0.0001, 1e-5));
        session.sessionMuted = true;

        // Stream gain is this framework's own, and setting one does not move
        // the other. That is the whole distinction: one is inside this process
        // and invisible in the mixer, the other is the mixer.
        expect(stream.gain, AudioGain.unity);
        stream.gain = AudioGain.decibels(-40);
        expect(stream.gain.factor, closeTo(0.01, 1e-9));
        expect(session.sessionVolume, closeTo(0.0001, 1e-5),
            reason: 'stream gain must not touch the operating system slider');

        final _InaudibleTone tone = _InaudibleTone(
          sampleRate: stream.configuration.format.sampleRate,
          channels: stream.configuration.format.channels,
        );
        addTearDown(tone.dispose);

        // A few periods at unity, then the same at exact silence. The frame
        // counts must be identical: silence means the samples are zero, not
        // that the write was skipped. If it short-circuited, the endpoint
        // would stop consuming and the clock derived from those frames would
        // stop with it - which would make a profiling run at zero volume
        // measure a different program than the one being profiled, and that
        // is the use case that exposed the absence of this control.
        stream
          ..gain = AudioGain.unity
          ..start();
        var renderedAtUnity = 0;
        for (int period = 0; period < 3; period++) {
          expect(stream.waitForPeriod(timeoutMilliseconds: 1000), isTrue);
          renderedAtUnity += stream.renderAvailableWith(tone);
        }
        expect(renderedAtUnity, greaterThan(0));

        stream.gain = AudioGain.silence;
        var renderedAtSilence = 0;
        for (int period = 0; period < 3; period++) {
          expect(stream.waitForPeriod(timeoutMilliseconds: 1000), isTrue);
          renderedAtSilence += stream.renderAvailableWith(tone);
        }
        expect(renderedAtSilence, greaterThan(0));
        expect(tone.processedFrames, renderedAtUnity + renderedAtSilence,
            reason: 'the processor ran for every frame at silence too');

        stream.stop();
      } finally {
        // Restored here rather than only in a tear-down: these are the user's
        // settings, Windows remembers them per application, and a failed
        // expectation above must not be the reason dart.exe is muted forever.
        session
          ..sessionVolume = originalVolume
          ..sessionMuted = originalMute;
      }

      expect(session.sessionVolume, closeTo(originalVolume, 1e-5));
      expect(session.sessionMuted, originalMute);
    },
    skip: skip,
  );

  test(
    'session volume clamps rather than letting the platform reject the write',
    () {
      final WasapiAudioBackend backend = WasapiAudioBackend();
      final WasapiRenderStream stream =
          backend.openStream(const AudioStreamRequest());
      addTearDown(stream.dispose);

      final AudioSessionVolume session = AudioSessionVolumes.require(stream);
      final double original = session.sessionVolume;
      try {
        // SetMasterVolume answers E_INVALIDARG outside 0..1, and a rejected
        // write would leave the slider wherever it happened to be while the
        // caller believed it had moved.
        session.sessionVolume = -5;
        expect(session.sessionVolume, closeTo(0, 1e-6));
        session.sessionVolume = 0.0001;
        expect(session.sessionVolume, closeTo(0.0001, 1e-5));
      } finally {
        session.sessionVolume = original;
      }
      expect(session.sessionVolume, closeTo(original, 1e-5));
    },
    skip: skip,
  );

  test(
    'the stream reports unity until something asks for otherwise',
    () {
      final WasapiAudioBackend backend = WasapiAudioBackend();
      final WasapiRenderStream stream =
          backend.openStream(const AudioStreamRequest());
      addTearDown(stream.dispose);
      expect(stream.gain, AudioGain.unity);
      expect(stream.gain.isUnity, isTrue);
    },
    skip: skip,
  );
}
