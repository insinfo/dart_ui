/// The block suballocator, against a real device.
///
/// The allocator is the part of this backend with the most arithmetic and the
/// least visible failure mode: a wrong offset produces a buffer that overlaps
/// its neighbour, and what comes out is a frame where somebody else's vertices
/// appear in the middle of yours - a picture, not an error. So the invariants
/// are asserted directly rather than inferred from the fact that a scene drew.
library;

import 'dart:ffi';

import 'package:dart_ui/src/rendering/gpu/vulkan/vulkan_ffi.g.dart';
import 'package:dart_ui/src/rendering/gpu/vulkan/vulkan_memory.dart';
import 'package:test/test.dart';

import 'vulkan_session.dart';

void main() {
  final VulkanSession session = VulkanSession.open();

  group('the block suballocator', () {
    tearDownAll(session.close);

    VulkanMemoryAllocator allocator() => session.device!.allocator;

    /// Host-visible memory, which every device has and which lets the test
    /// prove a mapping really points at distinct bytes.
    VulkanAllocation take(int size, {int alignment = 256}) =>
        allocator().allocate(
          resource: 'test $size',
          size: size,
          alignment: alignment,
          // Every bit set: any memory type will do, and the allocator picks
          // the first with the properties asked for.
          memoryTypeBits: 0xFFFFFFFF,
          required:
              VkMemoryPropertyFlagBits.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT |
                  VkMemoryPropertyFlagBits.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
          linear: true,
        );

    test('many suballocations cost one device allocation', () {
      // The reason this class exists. `maxMemoryAllocationCount` is as low as
      // 256 on some drivers, and one vkAllocateMemory per resource hits it.
      final int before = allocator().deviceAllocationCount;
      final List<VulkanAllocation> taken = <VulkanAllocation>[
        for (var i = 0; i < 32; i++) take(1024),
      ];
      expect(allocator().deviceAllocationCount - before, lessThanOrEqualTo(1));
      expect(allocator().liveAllocationCount, greaterThanOrEqualTo(32));

      // Distinct, non-overlapping, and aligned. Three separate claims, and the
      // third is the one a "just bump a pointer" allocator gets wrong first.
      final List<VulkanAllocation> sorted = taken.toList()
        ..sort((VulkanAllocation a, VulkanAllocation b) =>
            a.offset.compareTo(b.offset));
      for (var i = 0; i < sorted.length; i++) {
        expect(sorted[i].offset % 256, 0);
        if (i > 0) {
          expect(sorted[i].offset,
              greaterThanOrEqualTo(sorted[i - 1].offset + sorted[i - 1].size));
        }
      }
      for (final VulkanAllocation allocation in taken) {
        allocator().free(allocation);
      }
    }, skip: session.skipReason);

    test('a mapped allocation points at its own bytes', () {
      // The offset arithmetic, checked through the mapping rather than through
      // the number. Writing a sentinel into one and reading it back out of the
      // other is what would fail if `mapped` forgot to add the offset.
      final VulkanAllocation first = take(4096);
      final VulkanAllocation second = take(4096);
      expect(first.isHostVisible, isTrue);
      expect(first.memory, second.memory,
          reason: 'two small allocations should share one block');
      expect(first.offset, isNot(second.offset));

      first.mapped.asTypedList(4096).fillRange(0, 4096, 0xAB);
      second.mapped.asTypedList(4096).fillRange(0, 4096, 0xCD);
      expect(first.mapped.asTypedList(4096).every((int b) => b == 0xAB), isTrue,
          reason: 'the second allocation overwrote the first, so the two '
              'overlap');
      expect(second.mapped[0], 0xCD);

      allocator()
        ..free(first)
        ..free(second);
    }, skip: session.skipReason);

    test('freed runs coalesce, so a big allocation can reuse them', () {
      // The invariant that stops a device from fragmenting into unusable
      // stripes. Three adjacent 4 KiB runs, freed, must be able to hold one
      // 12 KiB request afterwards - which they can only do if the free list
      // merged them.
      final VulkanAllocation a = take(4096, alignment: 1);
      final VulkanAllocation b = take(4096, alignment: 1);
      final VulkanAllocation c = take(4096, alignment: 1);
      expect(b.offset, a.offset + a.size);
      expect(c.offset, b.offset + b.size);
      final int runsBefore = a.debugBlockFreeRunCount;

      allocator()
        ..free(b)
        ..free(a)
        ..free(c);
      expect(a.debugBlockFreeRunCount, lessThanOrEqualTo(runsBefore),
          reason: 'freeing three adjacent runs left them unmerged');

      final VulkanAllocation big = take(4096 * 3, alignment: 1);
      expect(big.offset, a.offset,
          reason: 'the merged run was not reused; the free list is '
              'fragmenting');
      allocator().free(big);
    }, skip: session.skipReason);

    test('an impossible request is refused by name', () {
      // No memory type has every property, so this cannot be satisfied and
      // must say so rather than return an allocation on the wrong heap.
      expect(
        () => allocator().allocate(
          resource: 'impossible',
          size: 64,
          alignment: 1,
          memoryTypeBits: 0,
          required:
              VkMemoryPropertyFlagBits.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT,
          linear: true,
        ),
        throwsA(isA<VulkanOutOfMemoryError>()),
      );
      expect(
        () => allocator().allocate(
          resource: 'zero',
          size: 0,
          alignment: 1,
          memoryTypeBits: 0xFFFFFFFF,
          required: 0,
          linear: true,
        ),
        throwsArgumentError,
      );
    }, skip: session.skipReason);

    test('device-local memory has no CPU address, and says so', () {
      final VulkanAllocation allocation = allocator().allocate(
        resource: 'device local',
        size: 4096,
        alignment: 256,
        memoryTypeBits: 0xFFFFFFFF,
        required: VkMemoryPropertyFlagBits.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT,
        linear: false,
      );
      // On an integrated GPU the device-local type is often host-visible too,
      // so this is a conditional claim: what must never happen is `mapped`
      // returning a pointer into nothing.
      if (!allocation.isHostVisible) {
        expect(() => allocation.mapped, throwsStateError);
      } else {
        expect(allocation.mapped.address, isNot(0));
      }
      allocator().free(allocation);
    }, skip: session.skipReason);

    test('buffers and optimal images never share a block', () {
      // The rule that makes `bufferImageGranularity` vacuous here. Two
      // allocations of the same memory type, one linear and one not, must land
      // in different VkDeviceMemory objects.
      final VulkanAllocation linear = take(4096);
      final VulkanAllocation tiled = allocator().allocate(
        resource: 'optimal image',
        size: 4096,
        alignment: 256,
        memoryTypeBits: 0xFFFFFFFF,
        required: VkMemoryPropertyFlagBits.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT |
            VkMemoryPropertyFlagBits.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
        linear: false,
      );
      expect(linear.memoryTypeIndex, tiled.memoryTypeIndex);
      expect(linear.memory, isNot(tiled.memory),
          reason: 'a linear and a non-linear allocation shared one block, so '
              'bufferImageGranularity applies and nothing enforces it');
      allocator()
        ..free(linear)
        ..free(tiled);
    }, skip: session.skipReason);

    test('flush and invalidate are safe on coherent memory', () {
      // Both are no-ops on HOST_COHERENT and are called unconditionally by the
      // renderer. What is checked is that calling them does not fail; a
      // mapped-range whose size is not a multiple of nonCoherentAtomSize is a
      // validation error on the drivers where they are not no-ops.
      final VulkanAllocation allocation = take(300, alignment: 1);
      allocator()
        ..flush(allocation)
        ..invalidate(allocation)
        ..free(allocation);
      expect(session.device!.isLost, isFalse);
    }, skip: session.skipReason);

    test('the allocator reports the numbers a leak report needs', () {
      final VulkanMemoryAllocator a = allocator();
      expect(a.blockCount, greaterThan(0));
      expect(a.reservedBytes,
          greaterThanOrEqualTo(VulkanMemoryAllocator.kDefaultBlockBytes));
      expect(a.memoryTypeCount, greaterThan(0));
      expect(session.device!.physicalDevice.nonCoherentAtomSize,
          greaterThanOrEqualTo(1));
    }, skip: session.skipReason);
  });
}
