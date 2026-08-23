/// The buffer rotation, and the two ways it is allowed to say no.
///
/// Every test here is about a frame that must not be overwritten. That is the
/// bug the ring exists for, it produces a picture torn between two moments,
/// and it is invisible in a still - so it is asserted at the level of the
/// bookkeeping, where it is a comparison of two integers rather than a
/// screenshot somebody has to look at.
library;

import 'package:dart_ui/src/rendering/gpu/video/video_upload_ring.dart';
import 'package:test/test.dart';

void main() {
  group('a double-buffered ring', () {
    late VideoUploadRing ring;

    setUp(() {
      ring = VideoUploadRing(bufferCount: VideoUploadRing.doubleBuffered);
    });

    test('starts with nothing in flight and no front buffer', () {
      expect(ring.bufferCount, 2);
      expect(ring.frontBuffer, -1);
      expect(ring.frontSequence, -1);
      expect(ring.inFlightCount, 0);
      expect(ring.retiredThrough, -1);
      expect(ring.hasOpenAcquire, isFalse);
    });

    test('rotates between its two buffers', () {
      final int first = ring.acquire(0);
      ring.present(first);
      expect(ring.frontBuffer, first);
      expect(ring.frontSequence, 0);

      final int second = ring.acquire(1);
      expect(second, isNot(first),
          reason: 'the frame in the first buffer has not retired');
      ring.present(second);
      expect(ring.frontBuffer, second);
      expect(ring.inFlightCount, 2);
    });

    test('refuses a third frame while two are in flight', () {
      ring
        ..present(ring.acquire(0))
        ..present(ring.acquire(1));
      expect(() => ring.acquire(2), throwsA(isA<VideoUploadStalled>()));
    });

    test('the stall names the numbers needed to fix it', () {
      ring
        ..present(ring.acquire(4))
        ..present(ring.acquire(5));
      try {
        ring.acquire(6);
        fail('expected a stall');
      } on VideoUploadStalled catch (error) {
        expect(error.sequence, 6);
        expect(error.bufferCount, 2);
        expect(error.oldestInFlight, 4);
        expect(error.retiredThrough, -1);
        expect(error.toString(), contains('bufferCount'));
      }
    });

    test('retiring frees the buffers at or below the sequence', () {
      ring
        ..present(ring.acquire(0))
        ..present(ring.acquire(1))
        ..retire(0);
      expect(ring.inFlightCount, 1);
      // The retired buffer is reused, and the *front* buffer - the one a draw
      // would sample right now - is not.
      final int third = ring.acquire(2);
      expect(third, isNot(ring.frontBuffer));
    });

    test('retiring the front frame keeps it the front buffer', () {
      final int buffer = ring.acquire(0);
      ring
        ..present(buffer)
        ..retire(0);
      expect(ring.frontBuffer, buffer);
      expect(ring.frontSequence, 0);
      expect(ring.inFlightCount, 0);
    });

    test('retireAll frees everything including the front', () {
      ring
        ..present(ring.acquire(0))
        ..present(ring.acquire(1))
        ..retireAll();
      expect(ring.inFlightCount, 0);
      expect(ring.retiredThrough, 1);
    });

    test('a retire that moves backwards is refused', () {
      // The exact shape of the staging-cursor bug the Vulkan executor hit:
      // a rewind hands out storage somebody is still reading.
      ring
        ..present(ring.acquire(0))
        ..present(ring.acquire(1))
        ..retire(1);
      expect(() => ring.retire(0), throwsA(isA<ArgumentError>()));
      expect(ring.retiredThrough, 1);
    });

    test('a sequence that repeats or moves backwards is refused', () {
      ring.present(ring.acquire(5));
      expect(() => ring.acquire(5), throwsA(isA<ArgumentError>()));
      expect(() => ring.acquire(4), throwsA(isA<ArgumentError>()));
      expect(() => ring.acquire(-1), throwsA(isA<ArgumentError>()));
    });

    test('two acquires without a present is a state error', () {
      ring.acquire(0);
      expect(() => ring.acquire(1), throwsA(isA<StateError>()));
    });

    test('presenting a buffer that was not acquired is a state error', () {
      final int buffer = ring.acquire(0);
      expect(() => ring.present(1 - buffer), throwsA(isA<StateError>()));
    });

    test('abandoning gives the buffer back', () {
      final int buffer = ring.acquire(0);
      ring.abandon(buffer);
      expect(ring.inFlightCount, 0);
      expect(ring.frontBuffer, -1);
      // And the same buffer is available again, which is what stops a failing
      // upload from leaking a slot per failure until the ring never recovers.
      expect(ring.acquire(1), buffer);
    });

    test('reset forgets everything, for a restarted stream', () {
      ring
        ..present(ring.acquire(7))
        ..retire(7)
        ..reset();
      expect(ring.frontBuffer, -1);
      expect(ring.retiredThrough, -1);
      expect(ring.acquire(0), 0);
    });
  });

  group('a single-buffered ring', () {
    test('demands a retire between every frame', () {
      final ring = VideoUploadRing(bufferCount: 1);
      ring.present(ring.acquire(0));
      expect(() => ring.acquire(1), throwsA(isA<VideoUploadStalled>()));
      ring.retire(0);
      expect(ring.acquire(1), 0);
    });
  });

  group('a triple-buffered ring', () {
    test('holds three frames and reuses in round-robin order', () {
      final ring = VideoUploadRing(bufferCount: 3);
      final List<int> order = <int>[];
      for (var i = 0; i < 3; i++) {
        final int buffer = ring.acquire(i);
        order.add(buffer);
        ring.present(buffer);
      }
      expect(order, <int>[0, 1, 2]);
      expect(ring.inFlightCount, 3);
      ring.retire(1);
      // Round-robin resumes where it left off rather than jumping back to the
      // buffer that has been free for the shortest time.
      expect(ring.acquire(3), 0);
    });
  });

  test('a ring needs at least one buffer', () {
    expect(() => VideoUploadRing(bufferCount: 0), throwsA(isA<ArgumentError>()));
  });
}
