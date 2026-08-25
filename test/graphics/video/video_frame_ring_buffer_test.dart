import 'dart:ffi';

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

    final first = ring.acquire();
    first.pointer.asTypedList(4).setAll(0, <int>[1, 2, 3, 4]);
    final firstView = first.bytes;
    expect(firstView, <int>[1, 2, 3, 4]);

    final second = ring.acquire();
    expect(second.pointer.address, first.pointer.address + 4);
    final wrapped = ring.acquire();
    expect(wrapped.pointer.address, second.pointer.address - 4);
    expect(identical(wrapped.bytes, firstView), isTrue);
    expect(first.isValid, isFalse);
    expect(first.validate, throwsStateError);
  });

  test('invalidateAll rejects old generations and restarts at slot zero', () {
    final ring = NativeVideoFrameRing(slotCount: 3, bytesPerSlot: 8);
    addTearDown(ring.dispose);
    final first = ring.acquire();
    final second = ring.acquire();
    final firstAddress = first.pointer.address;

    ring.invalidateAll();

    expect(first.isValid, isFalse);
    expect(second.isValid, isFalse);
    expect(ring.acquire().pointer.address, firstAddress);
  });

  test('dispose frees once and invalidates leases deterministically', () {
    final allocator = _TrackingAllocator();
    final ring = NativeVideoFrameRing(
      slotCount: 1,
      bytesPerSlot: 16,
      allocator: allocator,
    );
    final lease = ring.acquire();

    ring.dispose();
    ring.dispose();

    expect(allocator.freeCount, 1);
    expect(ring.isDisposed, isTrue);
    expect(lease.isValid, isFalse);
    expect(() => lease.bytes, throwsStateError);
    expect(ring.acquire, throwsStateError);
  });

  test('a VideoPlane retains and checks the native lease generation', () {
    final ring = NativeVideoFrameRing(slotCount: 1, bytesPerSlot: 16);
    addTearDown(ring.dispose);
    final lease = ring.acquire();
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
    ring.acquire();
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
      10, 20, 30, 255,
      40, 50, 60, 255,
      70, 80, 90, 255,
      100, 110, 120, 255,
    ]);
    final lease = ring.acquire();

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
