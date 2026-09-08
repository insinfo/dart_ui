import 'dart:ffi';
import 'dart:typed_data';

import 'package:dart_ui/src/ffi/native_memory.dart';
import 'package:dart_ui/src/graphics/image/decoded_image.dart';
import 'package:dart_ui/src/graphics/video/video_color_conversion_native.dart';
import 'package:dart_ui/src/graphics/video/video_frame.dart';
import 'package:dart_ui/src/graphics/video/video_frame_ring_buffer.dart';
import 'package:test/test.dart';

void main() {
  test('native writes are visible through one cached view per slot', () {
    final allocator = _TrackingAllocator();
    final ring = NativeVideoFrameRing(
      slotCount: 2,
      bytesPerSlot: 4,
      allocator: allocator,
    );
    addTearDown(ring.dispose);

    final first = ring.acquire()!;
    first.pointer.asTypedList(4).setAll(0, <int>[1, 2, 3, 4]);
    final firstView = first.bytes;
    expect(firstView, <int>[1, 2, 3, 4]);

    final second = ring.acquire()!;
    expect(second.pointer.address, first.pointer.address + 4);

    first.release();
    final wrapped = ring.acquire()!;
    expect(wrapped.pointer.address, second.pointer.address - 4);
    expect(identical(wrapped.bytes, firstView), isTrue);
    expect(first.isValid, isFalse);
    expect(first.validate, throwsStateError);
  });

  // The property the borrow exists for, checked without a stopwatch: wrap the
  // cursor all the way round onto a slot whose lease is still out and see the
  // ring refuse it. Before this, the third acquisition here returned slot 0
  // and the holder's `validate` started throwing mid-conversion.
  test('acquire refuses to wrap onto a slot a consumer still holds', () {
    final ring = NativeVideoFrameRing(slotCount: 3, bytesPerSlot: 8);
    addTearDown(ring.dispose);

    final held = ring.acquire()!;
    final int heldAddress = held.pointer.address;

    // Two full turns of the cursor, each one released immediately: the ring
    // has to keep answering, and never with the held slot.
    for (var turn = 0; turn < 8; turn++) {
      final lease = ring.acquire()!;
      expect(lease.pointer.address, isNot(heldAddress));
      lease.release();
      expect(held.isValid, isTrue);
    }

    expect(ring.borrowedSlots, 1);
    expect(ring.droppedFrames, 0);
    expect(held.isValid, isTrue);
  });

  test('a refusal is counted and the count is readable by a reporter', () {
    final ring = NativeVideoFrameRing(slotCount: 2, bytesPerSlot: 8);
    addTearDown(ring.dispose);

    final first = ring.acquire()!;
    final second = ring.acquire()!;
    expect(ring.freeSlots, 0);

    expect(ring.acquire(), isNull);
    expect(ring.acquire(), isNull);
    expect(ring.droppedFrames, 2);
    expect(ring.consecutiveDrops, 2);

    // A consumer that gives one frame back is served again, and the drop
    // total stays where it is: it counts frames lost, not frames refused
    // once.
    second.release();
    expect(ring.acquire(), isNotNull);
    expect(ring.droppedFrames, 2);
    expect(ring.consecutiveDrops, 0);
    expect(first.isValid, isTrue);
  });

  // The 27 ms window from §68, made deterministic: a consumer reads its frame
  // one row at a time while the producer decodes as fast as it can between
  // rows. The assertion is on the *bytes*, not on the generation counter -
  // the generation is what already failed loudly, the bytes are what tore.
  test('bytes under a held lease do not move while the producer runs', () {
    const int bytesPerSlot = 64;
    final ring = NativeVideoFrameRing(
      slotCount: 3,
      bytesPerSlot: bytesPerSlot,
    );
    addTearDown(ring.dispose);

    final held = ring.acquire()!;
    // Read through the view taken once, the way a conversion kernel does:
    // going back through `held.bytes` every row would assert on the
    // generation counter, and the generation is the failure that was already
    // loud. What tears silently is the memory behind the view.
    final Uint8List picture = held.bytes;
    picture.fillRange(0, bytesPerSlot, 0xA5);

    var produced = 0;
    for (var row = 0; row < bytesPerSlot; row++) {
      final produce = ring.acquire();
      if (produce != null) {
        produce.bytes.fillRange(0, bytesPerSlot, 0x5A);
        produced++;
        produce.release();
      }
      expect(
        picture[row],
        0xA5,
        reason: 'the producer overwrote row $row of a held frame',
      );
    }

    expect(produced, bytesPerSlot, reason: 'the producer was never blocked');
    expect(picture, everyElement(0xA5));
    expect(held.isValid, isTrue);
    expect(ring.droppedFrames, 0);
  });

  // The branch a leak hides in. A player awaits a frame and then finds the
  // widget gone or the file replaced - `!mounted || generation != _generation`
  // in the demo - and abandons it. That path runs only after a resize, a
  // reopen or a seek, so a missing release there passes every smoke test and
  // starves the ring in front of somebody. Modelled here at the ring, where it
  // can be asserted every run.
  test('frames abandoned on a discard path give their slots back', () {
    final ring = NativeVideoFrameRing(slotCount: 3, bytesPerSlot: 8);
    addTearDown(ring.dispose);

    // The player's own shape: one frame on screen, one decoded ahead, and the
    // rest thrown away. Three slots is exactly enough for it and not one more,
    // so any route that forgets to release starves within four frames.
    NativeVideoFrameLease? onScreen;
    NativeVideoFrameLease? decodedAhead;
    var presented = 0;
    var abandoned = 0;

    for (var i = 0; i < 500; i++) {
      final decoded = ring.acquire();
      expect(
        decoded,
        isNotNull,
        reason: 'starved at frame $i after $presented presented and '
            '$abandoned abandoned',
      );
      decodedAhead = decoded;

      if (i % 3 == 0) {
        // The abandoned branch: the widget went away or the file was
        // replaced between the request and the answer.
        decodedAhead!.release();
        decodedAhead = null;
        abandoned++;
        continue;
      }

      // The presented branch: the outgoing picture leaves the screen here.
      onScreen?.release();
      onScreen = decodedAhead;
      decodedAhead = null;
      presented++;
    }

    onScreen?.release();
    decodedAhead?.release();
    expect(ring.borrowedSlots, 0);
    expect(ring.droppedFrames, 0);
    expect(presented, greaterThan(0));
    expect(abandoned, greaterThan(0));
  });

  test('a borrow that is never released fails by name, not by stalling', () {
    final ring = NativeVideoFrameRing(
      slotCount: 2,
      bytesPerSlot: 8,
      starvationLimit: 4,
    );
    addTearDown(ring.dispose);

    final leaked = ring.acquire()!;
    ring.acquire();

    for (var i = 0; i < 3; i++) {
      expect(ring.acquire(), isNull, reason: 'refusal $i should be a drop');
    }
    expect(ring.droppedFrames, 3);

    expect(
      ring.acquire,
      throwsA(
        isA<StateError>().having(
          (StateError error) => error.message,
          'message',
          allOf(
            contains('all 2 native video frame slots'),
            contains('4 consecutive acquisitions'),
            contains('release()'),
          ),
        ),
      ),
    );
    expect(leaked.isValid, isTrue);
  });

  test('release is idempotent and a released lease refuses access', () {
    final ring = NativeVideoFrameRing(slotCount: 1, bytesPerSlot: 8);
    addTearDown(ring.dispose);

    final lease = ring.acquire()!;
    lease.release();
    lease.release();

    expect(ring.borrowedSlots, 0);
    expect(lease.isValid, isFalse);
    expect(
      () => lease.bytes,
      throwsA(
        isA<StateError>().having(
          (StateError error) => error.message,
          'message',
          contains('has already been released'),
        ),
      ),
    );

    // And the released lease is not revived by the slot's next tenant: the
    // generation moved on, so the stale object reports the wrap it always
    // did rather than aliasing somebody else's frame.
    final next = ring.acquire()!;
    expect(next.isValid, isTrue);
    expect(lease.isValid, isFalse);
    expect(
      lease.validate,
      throwsA(
        isA<StateError>().having(
          (StateError error) => error.message,
          'message',
          contains('is no longer valid'),
        ),
      ),
    );
  });

  test('invalidateAll rejects old generations and returns every borrow', () {
    final ring = NativeVideoFrameRing(slotCount: 3, bytesPerSlot: 8);
    addTearDown(ring.dispose);
    final first = ring.acquire()!;
    final second = ring.acquire()!;
    final firstAddress = first.pointer.address;
    expect(ring.borrowedSlots, 2);

    ring.invalidateAll();

    expect(first.isValid, isFalse);
    expect(second.isValid, isFalse);
    // A consumer that forgot to release before a seek does not starve the
    // ring: the seek takes the slots back and its lease is refused by name.
    expect(ring.borrowedSlots, 0);
    expect(ring.acquire()!.pointer.address, firstAddress);
    // Releasing a lease a seek already invalidated must not free the slot its
    // new tenant is using.
    first.release();
    expect(ring.borrowedSlots, 1);
  });

  test('the hot path allocates no pointer or view per frame', () {
    final ring = NativeVideoFrameRing(slotCount: 3, bytesPerSlot: 16);
    addTearDown(ring.dispose);

    final first = ring.acquire()!;
    final firstView = first.bytes;
    final int firstAddress = first.pointer.address;
    first.release();

    for (var i = 0; i < 1000; i++) {
      final lease = ring.acquire()!;
      if (lease.pointer.address == firstAddress) {
        expect(identical(lease.bytes, firstView), isTrue,
            reason: 'a slot must hand out the same external view forever');
      }
      lease.release();
    }
  });

  test('dispose frees once and invalidates leases deterministically', () {
    final allocator = _TrackingAllocator();
    final ring = NativeVideoFrameRing(
      slotCount: 1,
      bytesPerSlot: 16,
      allocator: allocator,
    );
    final lease = ring.acquire()!;

    ring.dispose();
    ring.dispose();

    expect(allocator.freeCount, 1);
    expect(ring.isDisposed, isTrue);
    expect(lease.isValid, isFalse);
    expect(() => lease.bytes, throwsStateError);
    expect(lease.release, returnsNormally);
    expect(ring.acquire, throwsStateError);
  });

  test('a VideoPlane retains and checks the native lease generation', () {
    final ring = NativeVideoFrameRing(slotCount: 1, bytesPerSlot: 16);
    addTearDown(ring.dispose);
    final lease = ring.acquire()!;
    final frame = VideoFrame(
      format: VideoFrameFormat(
        pixelFormat: VideoPixelFormat.bgra8888,
        width: 2,
        height: 2,
      ),
      planes: <VideoPlane>[
        VideoPlane(bytes: lease.bytes, bytesPerRow: 8, lifetime: lease),
      ],
      streamId: 1,
      sequence: 0,
    );

    expect(frame.plane(0), same(frame.planes.first));
    // The ring cannot take the slot back while the frame holds it.
    expect(ring.acquire(), isNull);
    expect(frame.plane(0), same(frame.planes.first));

    // `VideoFrame.release` is the whole consumer-side contract: one call, and
    // the decoder can decode into that slot again.
    frame.release();
    expect(ring.borrowedSlots, 0);
    expect(ring.acquire(), isNotNull);
    expect(() => frame.plane(0), throwsStateError);
  });

  test('color conversion writes into the cached external native view', () {
    final ring = NativeVideoFrameRing(slotCount: 2, bytesPerSlot: 16);
    addTearDown(ring.dispose);
    final source = VideoFrame.allocate(
      VideoFrameFormat(
        pixelFormat: VideoPixelFormat.rgba8888,
        width: 2,
        height: 2,
        range: VideoColorRange.full,
      ),
      streamId: 1,
    );
    source.plane(0).bytes.setAll(0, <int>[
      10,
      20,
      30,
      255,
      40,
      50,
      60,
      255,
      70,
      80,
      90,
      255,
      100,
      110,
      120,
      255,
    ]);
    final lease = ring.acquire()!;

    final result = convertVideoFrameToNativeRgba(
      source,
      lease,
      order: ImageChannelOrder.rgba,
    );

    expect(identical(result, lease.bytes), isTrue);
    expect(result, source.plane(0).bytes);
  });

  test('invalid dimensions are rejected before native allocation', () {
    final allocator = _TrackingAllocator();

    expect(
      () => NativeVideoFrameRing(
        slotCount: 0,
        bytesPerSlot: 4,
        allocator: allocator,
      ),
      throwsRangeError,
    );
    expect(
      () => NativeVideoFrameRing(
        slotCount: 1,
        bytesPerSlot: 0,
        allocator: allocator,
      ),
      throwsRangeError,
    );
    expect(
      () => NativeVideoFrameRing(
        slotCount: 1,
        bytesPerSlot: 4,
        starvationLimit: 0,
        allocator: allocator,
      ),
      throwsRangeError,
    );
    expect(allocator.allocateCount, 0);
  });
}

final class _TrackingAllocator implements Allocator {
  final NativeAllocator _delegate = NativeAllocator.instance;
  int allocateCount = 0;
  int freeCount = 0;

  @override
  Pointer<T> allocate<T extends NativeType>(int byteCount, {int? alignment}) {
    allocateCount++;
    return _delegate.allocate<T>(byteCount, alignment: alignment);
  }

  @override
  void free(Pointer<NativeType> pointer) {
    freeCount++;
    _delegate.free(pointer);
  }
}
