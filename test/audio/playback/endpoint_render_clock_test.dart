import 'package:dart_ui/src/audio/playback/endpoint_render_clock.dart';
import 'package:test/test.dart';

void main() {
  group('EndpointRenderClock', () {
    test('holds at the origin while the priming silence drains', () {
      // start() primes the endpoint with a full buffer of silence, so the
      // first frames the device consumes are not media and the clock must not
      // move for them.
      final EndpointRenderClock clock = EndpointRenderClock(bufferFrames: 480);
      clock.restart(0);
      expect(clock.positionFrames, 0);

      // Wakeup after one 160-frame period: padding 320, so 160 frames of the
      // priming silence have been consumed.
      expect(clock.onRendered(160), 0);
      expect(clock.onRendered(160), 0);
      // 480 consumed: the silence is gone and the media begins now.
      expect(clock.onRendered(160), 0);
      expect(clock.onRendered(160), 160);
      expect(clock.onRendered(160), 320);
    });

    test('reports the device position, not the write cursor', () {
      final EndpointRenderClock clock = EndpointRenderClock(bufferFrames: 480);
      clock.restart(0);
      for (int wakeup = 0; wakeup < 3; wakeup++) {
        clock.onRendered(160);
      }
      // Three wakeups have written 480 media frames, but the device has only
      // played the priming silence: nothing of the media is audible yet.
      expect(clock.releasedFrames, 480 + 480);
      expect(clock.positionFrames, 0);
      expect(clock.inFlightFrames, 480);
    });

    test('rebases on the media frame a restart begins at', () {
      final EndpointRenderClock clock = EndpointRenderClock(bufferFrames: 480);
      clock.restart(96000);
      expect(clock.positionFrames, 96000);
      expect(clock.onRendered(480), 96000);
      expect(clock.onRendered(480), 96000 + 480);
    });

    test('an unusually large wakeup means the device ran ahead', () {
      // A wakeup that can write the whole buffer is one where the endpoint had
      // emptied: every frame released so far has been played.
      final EndpointRenderClock clock = EndpointRenderClock(bufferFrames: 480);
      clock.restart(0);
      clock.onRendered(480); // consumed all 480 priming frames
      expect(clock.positionFrames, 0);
      expect(clock.onRendered(480), 480);
      expect(clock.inFlightFrames, 480);
    });

    test('a wakeup with nothing writable leaves the clock alone', () {
      final EndpointRenderClock clock = EndpointRenderClock(bufferFrames: 480);
      clock.restart(1000);
      clock.onRendered(240);
      final int before = clock.positionFrames;
      expect(clock.onRendered(0), before);
      expect(clock.releasedFrames, 480 + 240);
    });

    test('rejects a buffer size no endpoint could report', () {
      expect(() => EndpointRenderClock(bufferFrames: 0), throwsRangeError);
    });
  });

  group('frame arithmetic', () {
    test('converts frames to a duration without drifting', () {
      expect(framesToDuration(48000, 48000), const Duration(seconds: 1));
      expect(framesToDuration(0, 48000), Duration.zero);
      expect(framesToDuration(-5, 48000), Duration.zero);
      expect(framesToDuration(44100 * 3600, 44100), const Duration(hours: 1));
      // 44.1 kHz does not divide a microsecond evenly; the answer still has to
      // be exact to the frame, which is why this is integer arithmetic.
      expect(framesToDuration(1, 44100).inMicroseconds, 22);
      expect(
        framesToDuration(44100 * 7200 + 1, 44100),
        const Duration(hours: 2) + const Duration(microseconds: 22),
      );
    });

    test('converts a duration to frames, rounding down', () {
      expect(durationToFrames(const Duration(seconds: 1), 48000), 48000);
      expect(durationToFrames(Duration.zero, 48000), 0);
      expect(durationToFrames(const Duration(seconds: -1), 48000), 0);
      expect(durationToFrames(const Duration(microseconds: 22), 44100), 0);
      expect(durationToFrames(const Duration(microseconds: 23), 44100), 1);
    });

    test('round-trips a position to within one frame', () {
      // A microsecond is coarser than a frame above 1 MHz of nothing, but at
      // 48 kHz one frame is 20.8 us, so the round trip can lose the fraction
      // and land one frame early. That is 20 microseconds of seek accuracy,
      // which is three orders of magnitude below anything a viewer can see -
      // and it is bounded, which is the property that matters: the error does
      // not accumulate over a film's worth of seeks.
      for (final int frames in <int>[0, 1, 999, 48000, 4800000, 172800000]) {
        final int round = durationToFrames(
          framesToDuration(frames, 48000),
          48000,
        );
        expect(round, inInclusiveRange(frames - 1, frames));
      }
    });

    test('rejects a sample rate that cannot be a clock', () {
      expect(() => framesToDuration(1, 0), throwsRangeError);
      expect(() => durationToFrames(Duration.zero, -1), throwsRangeError);
    });
  });
}
