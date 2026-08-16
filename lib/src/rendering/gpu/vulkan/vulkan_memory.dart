/// This backend's own device-memory allocator.
///
/// ## Why not the Vulkan Memory Allocator
///
/// Section 19.3 of the roadmap is explicit: **do not port VMA.** That is the
/// right call and it is worth writing down why, because "we wrote our own
/// allocator" is normally a warning sign.
///
/// VMA is thirteen thousand lines of C++ solving a problem this renderer does
/// not have. It exists for engines that allocate thousands of resources of
/// wildly different sizes and lifetimes across a frame, and it earns its size
/// with defragmentation, budget tracking across heaps, aliasing, linear
/// allocators for transient resources, and the `bufferImageGranularity` dance
/// that lets a linear buffer and an optimally-tiled image share one block. A
/// Dart transliteration of that would be the largest file in this repository,
/// would be a second thing to keep in step with upstream, and none of its
/// interesting paths would ever run here.
///
/// What this renderer actually allocates, per device, is:
///
///   * one vertex buffer and one index buffer, grown a handful of times;
///   * one staging buffer, reused;
///   * two atlas images (coverage masks, glyphs) that live as long as the
///     device;
///   * one colour image per render target, plus a readback buffer.
///
/// Twenty objects, all long-lived, all created outside the frame loop. So the
/// allocator below is a **block suballocator with a free list and coalescing**
/// and nothing else - about two hundred lines.
///
/// ## Why suballocate at all, then
///
/// Because `VkPhysicalDeviceLimits.maxMemoryAllocationCount` is a real limit -
/// 4096 on most desktop drivers and as low as 256 on some mobile ones - and
/// because a `vkAllocateMemory` is a kernel-visible operation costing tens of
/// microseconds, not a pointer bump. One `VkDeviceMemory` per resource works
/// perfectly at this renderer's twenty objects and stops working the moment
/// the image cache grows, which is a cliff rather than a slope. Blocks make
/// that a non-event.
///
/// ## The one rule that avoids `bufferImageGranularity` entirely
///
/// Vulkan says a buffer (linear) and an optimally-tiled image (non-linear)
/// placed in the same `VkDeviceMemory` must be separated by
/// `bufferImageGranularity` bytes, because some hardware describes a whole
/// page with one tiling mode. Getting that wrong produces a *correct-looking*
/// allocation whose contents are corrupted by the neighbour.
///
/// This allocator never faces the question: its pools are keyed by `(memory
/// type, linearity)`, so a block holds only buffers or only optimal images and
/// the granularity rule is vacuous. The cost is at most one extra block per
/// memory type, which at 8 MiB is nothing beside the correctness.
library;

import 'dart:ffi';

import '../../../ffi/native_memory.dart';
import 'vulkan_bindings.dart';
import 'vulkan_constants.dart';
import 'vulkan_ffi.g.dart';

/// Raised when the device refuses memory, naming what was being allocated.
///
/// Its own type so a caller can turn it into an [OutOfMemory] renderer event
/// with the resource name intact, rather than a `StateError` whose message has
/// to be parsed.
final class VulkanOutOfMemoryError extends Error {
  VulkanOutOfMemoryError(this.resource, this.bytes, this.result);

  final String resource;
  final int bytes;
  final int result;

  @override
  String toString() => 'VulkanOutOfMemoryError: $resource needed $bytes bytes '
      'and vkAllocateMemory answered ${vkResultName(result)}';
}

/// A region of a `VkDeviceMemory` block, owned by the caller until it is
/// handed back to [VulkanMemoryAllocator.free].
final class VulkanAllocation {
  VulkanAllocation._(this._block, this.offset, this.size);

  final _MemoryBlock _block;

  /// Offset within [memory]. This is what `vkBindBufferMemory` wants, and it
  /// is almost never zero - a caller that passes 0 because "the buffer starts
  /// at the beginning" binds every resource to the same bytes.
  final int offset;

  final int size;

  Pointer<VkDeviceMemory_T> get memory => _block.memory;

  int get memoryTypeIndex => _block.typeIndex;

  /// True when this memory can be written by the CPU.
  bool get isHostVisible => _block.mapped != nullptr;

  /// The first byte of *this allocation*, already offset into the block's
  /// mapping.
  ///
  /// Blocks are mapped once and kept mapped, which Vulkan explicitly permits
  /// and which removes a `vkMapMemory`/`vkUnmapMemory` pair from every upload.
  /// A per-allocation map would also be wrong on a driver that refuses to map
  /// the same memory twice.
  Pointer<Uint8> get mapped {
    if (!isHostVisible) {
      throw StateError('this allocation is device-local; it has no CPU '
          'address. Allocate with hostVisible: true, or stage through a '
          'buffer that is');
    }
    return Pointer<Uint8>.fromAddress(_block.mapped.address + offset);
  }

  @override
  String toString() =>
      'VulkanAllocation(type ${_block.typeIndex}, $offset + $size)';
}

/// The allocator. One per device.
final class VulkanMemoryAllocator {
  VulkanMemoryAllocator(
    this._api,
    this._device, {
    required Pointer<VkPhysicalDevice_T> physicalDevice,
    required VulkanInstanceApi instanceApi,
    required this.nonCoherentAtomSize,
    this.blockBytes = kDefaultBlockBytes,
  }) {
    using((NativeArena arena) {
      final Pointer<VkPhysicalDeviceMemoryProperties> properties =
          arena<VkPhysicalDeviceMemoryProperties>();
      instanceApi.getPhysicalDeviceMemoryProperties(physicalDevice, properties);
      _typeCount = properties.ref.memoryTypeCount;
      _typeProperties = List<int>.unmodifiable(<int>[
        for (var i = 0; i < _typeCount; i++)
          properties.ref.memoryTypes[i].propertyFlags,
      ]);
      _heapOfType = List<int>.unmodifiable(<int>[
        for (var i = 0; i < _typeCount; i++)
          properties.ref.memoryTypes[i].heapIndex,
      ]);
      _heapSizes = List<int>.unmodifiable(<int>[
        for (var i = 0; i < properties.ref.memoryHeapCount; i++)
          properties.ref.memoryHeaps[i].size,
      ]);
    });
  }

  /// 8 MiB. Large enough that this renderer's whole working set is one or two
  /// blocks per pool, small enough that a device with a 256 MiB heap is not
  /// embarrassed by the first allocation.
  static const int kDefaultBlockBytes = 8 * 1024 * 1024;

  final VulkanDeviceApi _api;
  final Pointer<VkDevice_T> _device;

  /// `VkPhysicalDeviceLimits.nonCoherentAtomSize`. Flushes and invalidates are
  /// rounded out to it; a range that is not a multiple is undefined behaviour
  /// that works on the driver you tested and not the next one.
  final int nonCoherentAtomSize;

  final int blockBytes;

  late final int _typeCount;
  late final List<int> _typeProperties;
  late final List<int> _heapOfType;
  late final List<int> _heapSizes;

  /// Pools keyed by `typeIndex * 2 + (linear ? 0 : 1)`. See the library
  /// comment for why linearity is part of the key.
  final Map<int, List<_MemoryBlock>> _pools = <int, List<_MemoryBlock>>{};

  int _deviceAllocationCount = 0;
  int _liveAllocationCount = 0;
  bool _disposed = false;

  /// How many times `vkAllocateMemory` was actually called. The number
  /// `maxMemoryAllocationCount` bounds, and the one this whole class exists to
  /// keep small.
  int get deviceAllocationCount => _deviceAllocationCount;

  /// Suballocations handed out and not yet freed.
  int get liveAllocationCount => _liveAllocationCount;

  int get blockCount => _pools.values
      .fold<int>(0, (int sum, List<_MemoryBlock> p) => sum + p.length);

  /// Bytes committed to blocks, whether or not they are carrying anything.
  int get reservedBytes => _pools.values.fold<int>(
      0,
      (int sum, List<_MemoryBlock> pool) =>
          sum + pool.fold<int>(0, (int s, _MemoryBlock b) => s + b.size));

  int get memoryTypeCount => _typeCount;

  /// The property flags of memory type [index].
  int propertiesOfType(int index) => _typeProperties[index];

  /// The size of the heap memory type [index] draws from.
  int heapSizeOfType(int index) => _heapSizes[_heapOfType[index]];

  /// The first memory type in [typeBits] with every flag in [required], or -1.
  ///
  /// First and not best: the specification orders memory types so that the
  /// earlier ones are the more desirable for the properties they advertise,
  /// which is the one piece of allocator policy Vulkan hands you for free.
  int findMemoryType(int typeBits, int required) {
    for (var i = 0; i < _typeCount; i++) {
      if (typeBits & (1 << i) == 0) continue;
      if (_typeProperties[i] & required == required) return i;
    }
    return -1;
  }

  /// Reserves [size] bytes for a resource whose requirements are
  /// [memoryTypeBits] and [alignment].
  ///
  /// [linear] must be true for a buffer and for a `VK_IMAGE_TILING_LINEAR`
  /// image, and false for an optimally-tiled image. It is not inferred from
  /// anything, because it cannot be: the allocator sees a size and a bitmask,
  /// not the object.
  ///
  /// [preferred] flags are tried first and dropped if no type has them, which
  /// is how "device-local if there is any" is expressed without a second code
  /// path.
  VulkanAllocation allocate({
    required String resource,
    required int size,
    required int alignment,
    required int memoryTypeBits,
    required int required,
    int preferred = 0,
    required bool linear,
  }) {
    if (_disposed) throw StateError('this allocator is disposed');
    if (size <= 0) {
      throw ArgumentError.value(size, 'size', 'must be positive');
    }
    var typeIndex = preferred == 0
        ? -1
        : findMemoryType(memoryTypeBits, required | preferred);
    if (typeIndex < 0) typeIndex = findMemoryType(memoryTypeBits, required);
    if (typeIndex < 0) {
      throw VulkanOutOfMemoryError(
        '$resource: no memory type in 0x${memoryTypeBits.toRadixString(16)} '
        'has 0x${required.toRadixString(16)}',
        size,
        VkResult.VK_ERROR_OUT_OF_DEVICE_MEMORY,
      );
    }

    // The mapping's own alignment matters as much as the resource's: a host
    // pointer that is not aligned for the type the caller writes through it is
    // a fault on some architectures and a slow path on the rest.
    final int effectiveAlignment = alignment < 1 ? 1 : alignment;
    final int key = typeIndex * 2 + (linear ? 0 : 1);
    final List<_MemoryBlock> pool =
        _pools.putIfAbsent(key, () => <_MemoryBlock>[]);

    for (final _MemoryBlock block in pool) {
      final VulkanAllocation? placed =
          block.tryAllocate(size, effectiveAlignment);
      if (placed != null) {
        _liveAllocationCount++;
        return placed;
      }
    }

    final int blockSize = size > blockBytes ? size : blockBytes;
    final _MemoryBlock block = _createBlock(resource, typeIndex, blockSize);
    pool.add(block);
    final VulkanAllocation? placed =
        block.tryAllocate(size, effectiveAlignment);
    if (placed == null) {
      throw VulkanOutOfMemoryError(
        '$resource did not fit a block allocated exactly for it, which means '
        'the alignment $effectiveAlignment exceeds the block size',
        size,
        VkResult.VK_ERROR_OUT_OF_DEVICE_MEMORY,
      );
    }
    _liveAllocationCount++;
    return placed;
  }

  void free(VulkanAllocation allocation) {
    if (_disposed) return;
    allocation._block.free(allocation);
    _liveAllocationCount--;
  }

  /// Makes CPU writes to [allocation] visible to the device.
  ///
  /// A no-op on `HOST_COHERENT` memory, which is the usual case on a desktop
  /// integrated GPU, and not a no-op anywhere else. Calling it unconditionally
  /// is the point: a renderer that only flushes "when it needs to" is one
  /// where the need is decided at the call site, and it will be decided wrong
  /// on the one driver that hands back non-coherent host memory.
  void flush(VulkanAllocation allocation) =>
      _range(allocation, _api.flushMappedMemoryRanges);

  /// Makes device writes to [allocation] visible to the CPU. The readback
  /// counterpart of [flush].
  void invalidate(VulkanAllocation allocation) =>
      _range(allocation, _api.invalidateMappedMemoryRanges);

  void _range(VulkanAllocation allocation, VkMappedRangesDart command) {
    if (_typeProperties[allocation.memoryTypeIndex] &
            VkMemoryPropertyFlagBits.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT !=
        0) {
      return;
    }
    using((NativeArena arena) {
      final int atom = nonCoherentAtomSize < 1 ? 1 : nonCoherentAtomSize;
      final int start = (allocation.offset ~/ atom) * atom;
      final int end =
          (((allocation.offset + allocation.size) + atom - 1) ~/ atom) * atom;
      final Pointer<VkMappedMemoryRange> range = arena<VkMappedMemoryRange>();
      range.ref
        ..sType = VkStructureType.VK_STRUCTURE_TYPE_MAPPED_MEMORY_RANGE
        ..memory = allocation.memory
        ..offset = start
        ..size = end - start > allocation._block.size - start
            ? vkWholeSize
            : end - start;
      command(_device, 1, range);
    });
  }

  /// Releases every block. Every allocation handed out becomes invalid.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final List<_MemoryBlock> pool in _pools.values) {
      for (final _MemoryBlock block in pool) {
        if (block.mapped != nullptr) {
          _api.unmapMemory(_device, block.memory);
        }
        _api.freeMemory(_device, block.memory, nullptr);
      }
    }
    _pools.clear();
    _liveAllocationCount = 0;
  }

  _MemoryBlock _createBlock(String resource, int typeIndex, int size) =>
      using((NativeArena arena) {
        final Pointer<VkMemoryAllocateInfo> info =
            arena<VkMemoryAllocateInfo>();
        info.ref
          ..sType = VkStructureType.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO
          ..allocationSize = size
          ..memoryTypeIndex = typeIndex;
        final Pointer<Pointer<VkDeviceMemory_T>> out =
            arena<Pointer<VkDeviceMemory_T>>();
        final int result = _api.allocateMemory(_device, info, nullptr, out);
        if (vkFailed(result)) {
          throw VulkanOutOfMemoryError(resource, size, result);
        }
        _deviceAllocationCount++;

        Pointer<Uint8> mapped = nullptr;
        if (_typeProperties[typeIndex] &
                VkMemoryPropertyFlagBits.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT !=
            0) {
          final Pointer<Pointer<Void>> address = arena<Pointer<Void>>();
          final int mapResult =
              _api.mapMemory(_device, out.value, 0, vkWholeSize, 0, address);
          if (vkFailed(mapResult)) {
            _api.freeMemory(_device, out.value, nullptr);
            throw VulkanOutOfMemoryError(
                '$resource: vkMapMemory refused', size, mapResult);
          }
          mapped = address.value.cast<Uint8>();
        }
        return _MemoryBlock(out.value, typeIndex, size, mapped);
      });
}

/// One `VkDeviceMemory` and the free runs inside it.
final class _MemoryBlock {
  _MemoryBlock(this.memory, this.typeIndex, this.size, this.mapped)
      : _free = <int>[0, size];

  final Pointer<VkDeviceMemory_T> memory;
  final int typeIndex;
  final int size;
  final Pointer<Uint8> mapped;

  /// `offset, length` pairs of free runs, sorted by offset and never adjacent
  /// to each other. The same shape `ShelfAtlas` uses for its holes, and for
  /// the same reason: two adjacent free runs that are not merged cannot hold
  /// an allocation their sum would fit, so a device that allocates and frees
  /// in a loop would fragment into unusable stripes.
  final List<int> _free;

  VulkanAllocation? tryAllocate(int size, int alignment) {
    for (var i = 0; i < _free.length; i += 2) {
      final int start = _free[i];
      final int length = _free[i + 1];
      final int aligned = ((start + alignment - 1) ~/ alignment) * alignment;
      final int padding = aligned - start;
      if (padding + size > length) continue;

      // The run is rewritten as at most two runs: what the alignment skipped
      // in front, and what is left behind. Both may be empty.
      final int tailStart = aligned + size;
      final int tailLength = length - padding - size;
      _free.removeRange(i, i + 2);
      var insert = i;
      if (tailLength > 0) {
        _free
          ..insert(insert, tailLength)
          ..insert(insert, tailStart);
      }
      if (padding > 0) {
        _free
          ..insert(insert, padding)
          ..insert(insert, start);
        insert += 2;
      }
      return VulkanAllocation._(this, aligned, size);
    }
    return null;
  }

  void free(VulkanAllocation allocation) {
    final int start = allocation.offset;
    final int length = allocation.size;
    var i = 0;
    while (i < _free.length && _free[i] < start) {
      i += 2;
    }
    _free
      ..insert(i, length)
      ..insert(i, start);
    // Merge forwards then backwards, in that order: merging backwards first
    // would move the run this index points at.
    if (i + 2 < _free.length && _free[i] + _free[i + 1] == _free[i + 2]) {
      _free[i + 1] += _free[i + 3];
      _free.removeRange(i + 2, i + 4);
    }
    if (i >= 2 && _free[i - 2] + _free[i - 1] == _free[i]) {
      _free[i - 1] += _free[i + 1];
      _free.removeRange(i, i + 2);
    }
  }

  /// Bytes not in any free run. For a test and for a leak report.
  int get usedBytes {
    var free = 0;
    for (var i = 1; i < _free.length; i += 2) {
      free += _free[i];
    }
    return size - free;
  }

  /// How many separate free runs there are. One means the block is unfragmented
  /// (or empty); a number that climbs while [usedBytes] does not is the
  /// signature of a coalescing bug.
  int get freeRunCount => _free.length ~/ 2;
}

/// Test-only view of a block's interior.
///
/// An extension rather than public members on [_MemoryBlock], because nothing
/// in the renderer may reach inside a block: an allocator whose internals are
/// part of its API cannot change its strategy.
extension VulkanAllocationDebug on VulkanAllocation {
  int get debugBlockUsedBytes => _block.usedBytes;
  int get debugBlockFreeRunCount => _block.freeRunCount;
  int get debugBlockSize => _block.size;
}
