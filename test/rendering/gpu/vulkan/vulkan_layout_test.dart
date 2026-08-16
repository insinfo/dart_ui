/// The size **and offset** tests section 11.4 asks of every binding package.
///
/// ## Why `sizeOf` alone is not enough, in one story
///
/// While the Direct3D 12 backend was being written, an agent found that the
/// union inside `D3D12_SHADER_RESOURCE_VIEW_DESC` is aligned to 8 bytes, so
/// its `Texture2D` arm begins at offset **16, not 12**. The structure is 40
/// bytes either way, so `sizeOf` could never have caught it. Every field read
/// one slot early, `MipLevels` came back as 0, the device was removed, and the
/// failure was reported several calls later against an innocent one.
///
/// That is the whole argument for this file. A wrong field *type* - `Uint32`
/// where the header says `uint64_t`, a `Pointer` where it says `size_t` - does
/// not always change the total size, because the padding absorbs it. It always
/// changes an offset.
///
/// ## What is being checked, exactly
///
/// The offsets below are **not** re-derived from the Dart declarations: they
/// are the numbers the C ABI produces for `vulkan_core.h` at the pinned commit
/// - natural alignment, struct alignment equal to the widest member, on the
/// LP64 / Win64 layout every platform this backend runs on shares. They are
/// written out by hand, once, so that the generated bindings and the header
/// are compared against a third statement of the same fact rather than against
/// each other.
///
/// Which means this file keeps its value now that `vulkan_ffi.g.dart` is
/// generated. It no longer guards against a typo in a hand-written struct -
/// there are none left - and instead guards against **regenerating from a
/// different header**: a future `VK_HEADER_VERSION` that reordered a field,
/// or a run of the generator against whatever `vulkan_core.h` happened to be
/// on the machine, moves an offset and fails here.
///
/// ## How an offset is measured
///
/// Zero the structure, write a distinctive value through exactly one field's
/// Dart setter, and find where those bytes landed. That measures what
/// `dart:ffi` will *actually do at run time*, which is the only thing that
/// matters; an offset computed from the declaration would be re-deriving the
/// layout rule this file exists to check.
///
/// This test needs no GPU and no loader, so it runs on every platform.
library;

import 'dart:ffi';
import 'dart:typed_data';

import 'package:dart_ui/src/ffi/native_memory.dart';
import 'package:dart_ui/src/rendering/gpu/vulkan/vulkan_constants.dart';
import 'package:dart_ui/src/rendering/gpu/vulkan/vulkan_ffi.g.dart';
import 'package:test/test.dart';

// Sentinels. Each is chosen so its byte pattern cannot appear by accident in a
// zeroed buffer, and so no sentinel is a prefix of another.
const int _u32 = 0x21B2C3D4;
const int _u64 = 0x2122232425262728;
const double _f32 = 12.5;
const int _byte = 0x5A;

const List<int> _u32Bytes = <int>[0xD4, 0xC3, 0xB2, 0x21];
const List<int> _u64Bytes = <int>[
  0x28, 0x27, 0x26, 0x25, 0x24, 0x23, 0x22, 0x21, //
];

/// 12.5 as IEEE-754 binary32 is 0x41480000, little-endian.
const List<int> _f32Bytes = <int>[0x00, 0x00, 0x48, 0x41];
const List<int> _byteBytes = <int>[_byte];

Pointer<T> _sentinelPointer<T extends NativeType>() =>
    Pointer<T>.fromAddress(_u64);

final class _Field {
  _Field(this.name, this.offset, this.write, this.pattern);

  final String name;
  final int offset;
  final void Function() write;
  final List<int> pattern;
}

_Field _u(String name, int offset, void Function() write) =>
    _Field(name, offset, write, _u32Bytes);
_Field _q(String name, int offset, void Function() write) =>
    _Field(name, offset, write, _u64Bytes);
_Field _f(String name, int offset, void Function() write) =>
    _Field(name, offset, write, _f32Bytes);
_Field _b(String name, int offset, void Function() write) =>
    _Field(name, offset, write, _byteBytes);

int _find(Uint8List bytes, List<int> pattern) {
  outer:
  for (var i = 0; i + pattern.length <= bytes.length; i++) {
    for (var k = 0; k < pattern.length; k++) {
      if (bytes[i + k] != pattern[k]) continue outer;
    }
    return i;
  }
  return -1;
}

/// Asserts [name] is [expectedSize] bytes and that every field lands where the
/// C ABI puts it.
void _layout(
  String name,
  int actualSize,
  int expectedSize,
  Pointer<Uint8> raw,
  List<_Field> fields,
) {
  expect(actualSize, expectedSize,
      reason: '$name is $actualSize bytes; the header at the pinned commit '
          'makes it $expectedSize');
  final Uint8List bytes = raw.asTypedList(actualSize);
  for (final _Field field in fields) {
    bytes.fillRange(0, actualSize, 0);
    field.write();
    final int found = _find(bytes, field.pattern);
    expect(found, field.offset,
        reason: '$name.${field.name} landed at offset $found; the header puts '
            'it at ${field.offset}');
  }
  bytes.fillRange(0, actualSize, 0);
}

void main() {
  final NativeArena arena = NativeArena();
  tearDownAll(arena.dispose);

  Pointer<T> alloc<T extends NativeType>(int size) => arena.allocate<T>(size);

  group('the measurement itself', () {
    test('finds a planted offset and reports -1 when there is none', () {
      // A layout test whose finder always returned the expected number would
      // pass forever. This is its non-vacuity check.
      final Uint8List bytes = Uint8List(16);
      expect(_find(bytes, _u32Bytes), -1);
      bytes.setRange(4, 8, _u32Bytes);
      expect(_find(bytes, _u32Bytes), 4);
      expect(_find(bytes, _u64Bytes), -1);
    });

    test('this is a 64-bit process, which every offset below assumes', () {
      // Half the numbers in this file are what they are because a pointer is
      // eight bytes. On a 32-bit build they would all be wrong, and
      // `VulkanLibrary.open` refuses that build by name for the same reason.
      expect(sizeOf<Pointer<Void>>(), 8);
      expect(sizeOf<Size>(), 8);
    });
  });

  group('geometry', () {
    test('VkExtent2D, VkExtent3D, VkOffset2D, VkOffset3D', () {
      final Pointer<VkExtent2D> e2 = alloc<VkExtent2D>(sizeOf<VkExtent2D>());
      _layout('VkExtent2D', sizeOf<VkExtent2D>(), 8, e2.cast<Uint8>(), <_Field>[
        _u('width', 0, () => e2.ref.width = _u32),
        _u('height', 4, () => e2.ref.height = _u32),
      ]);

      final Pointer<VkExtent3D> e3 = alloc<VkExtent3D>(sizeOf<VkExtent3D>());
      _layout(
          'VkExtent3D', sizeOf<VkExtent3D>(), 12, e3.cast<Uint8>(), <_Field>[
        _u('width', 0, () => e3.ref.width = _u32),
        _u('height', 4, () => e3.ref.height = _u32),
        _u('depth', 8, () => e3.ref.depth = _u32),
      ]);

      final Pointer<VkOffset2D> o2 = alloc<VkOffset2D>(sizeOf<VkOffset2D>());
      _layout('VkOffset2D', sizeOf<VkOffset2D>(), 8, o2.cast<Uint8>(), <_Field>[
        _u('x', 0, () => o2.ref.x = _u32),
        _u('y', 4, () => o2.ref.y = _u32),
      ]);

      final Pointer<VkOffset3D> o3 = alloc<VkOffset3D>(sizeOf<VkOffset3D>());
      _layout(
          'VkOffset3D', sizeOf<VkOffset3D>(), 12, o3.cast<Uint8>(), <_Field>[
        _u('x', 0, () => o3.ref.x = _u32),
        _u('y', 4, () => o3.ref.y = _u32),
        _u('z', 8, () => o3.ref.z = _u32),
      ]);
    });

    test('VkRect2D and VkViewport', () {
      final Pointer<VkRect2D> rect = alloc<VkRect2D>(sizeOf<VkRect2D>());
      _layout('VkRect2D', sizeOf<VkRect2D>(), 16, rect.cast<Uint8>(), <_Field>[
        _u('offset.x', 0, () => rect.ref.offset.x = _u32),
        _u('extent.width', 8, () => rect.ref.extent.width = _u32),
      ]);

      final Pointer<VkViewport> view = alloc<VkViewport>(sizeOf<VkViewport>());
      _layout(
          'VkViewport', sizeOf<VkViewport>(), 24, view.cast<Uint8>(), <_Field>[
        _f('x', 0, () => view.ref.x = _f32),
        _f('y', 4, () => view.ref.y = _f32),
        _f('width', 8, () => view.ref.width = _f32),
        _f('height', 12, () => view.ref.height = _f32),
        _f('minDepth', 16, () => view.ref.minDepth = _f32),
        _f('maxDepth', 20, () => view.ref.maxDepth = _f32),
      ]);
    });
  });

  group('instance', () {
    test('VkApplicationInfo', () {
      final Pointer<VkApplicationInfo> p =
          alloc<VkApplicationInfo>(sizeOf<VkApplicationInfo>());
      _layout('VkApplicationInfo', sizeOf<VkApplicationInfo>(), 48,
          p.cast<Uint8>(), <_Field>[
        _u('sType', 0, () => p.ref.sType = _u32),
        _q('pNext', 8, () => p.ref.pNext = _sentinelPointer<Void>()),
        _q('pApplicationName', 16,
            () => p.ref.pApplicationName = _sentinelPointer<Char>()),
        _u('applicationVersion', 24, () => p.ref.applicationVersion = _u32),
        _q('pEngineName', 32,
            () => p.ref.pEngineName = _sentinelPointer<Char>()),
        _u('engineVersion', 40, () => p.ref.engineVersion = _u32),
        _u('apiVersion', 44, () => p.ref.apiVersion = _u32),
      ]);
    });

    test('VkInstanceCreateInfo', () {
      final Pointer<VkInstanceCreateInfo> p =
          alloc<VkInstanceCreateInfo>(sizeOf<VkInstanceCreateInfo>());
      _layout('VkInstanceCreateInfo', sizeOf<VkInstanceCreateInfo>(), 64,
          p.cast<Uint8>(), <_Field>[
        _u('sType', 0, () => p.ref.sType = _u32),
        _q('pNext', 8, () => p.ref.pNext = _sentinelPointer<Void>()),
        _u('flags', 16, () => p.ref.flags = _u32),
        _q(
            'pApplicationInfo',
            24,
            () =>
                p.ref.pApplicationInfo = _sentinelPointer<VkApplicationInfo>()),
        _u('enabledLayerCount', 32, () => p.ref.enabledLayerCount = _u32),
        _q(
            'ppEnabledLayerNames',
            40,
            () =>
                p.ref.ppEnabledLayerNames = _sentinelPointer<Pointer<Char>>()),
        _u('enabledExtensionCount', 48,
            () => p.ref.enabledExtensionCount = _u32),
        _q(
            'ppEnabledExtensionNames',
            56,
            () => p.ref.ppEnabledExtensionNames =
                _sentinelPointer<Pointer<Char>>()),
      ]);
    });

    test('VkLayerProperties and VkExtensionProperties', () {
      final Pointer<VkLayerProperties> layer =
          alloc<VkLayerProperties>(sizeOf<VkLayerProperties>());
      _layout('VkLayerProperties', sizeOf<VkLayerProperties>(), 520,
          layer.cast<Uint8>(), <_Field>[
        _b('layerName', 0, () => layer.ref.layerName[0] = _byte),
        _u('specVersion', 256, () => layer.ref.specVersion = _u32),
        _u('implementationVersion', 260,
            () => layer.ref.implementationVersion = _u32),
        _b('description', 264, () => layer.ref.description[0] = _byte),
      ]);

      final Pointer<VkExtensionProperties> extension =
          alloc<VkExtensionProperties>(sizeOf<VkExtensionProperties>());
      _layout('VkExtensionProperties', sizeOf<VkExtensionProperties>(), 260,
          extension.cast<Uint8>(), <_Field>[
        _b('extensionName', 0, () => extension.ref.extensionName[0] = _byte),
        _u('specVersion', 256, () => extension.ref.specVersion = _u32),
      ]);
    });
  });

  group('physical device', () {
    test('VkPhysicalDeviceProperties is 824 bytes with limits at 296', () {
      final Pointer<VkPhysicalDeviceProperties> p =
          alloc<VkPhysicalDeviceProperties>(
              sizeOf<VkPhysicalDeviceProperties>());
      _layout('VkPhysicalDeviceProperties',
          sizeOf<VkPhysicalDeviceProperties>(), 824, p.cast<Uint8>(), <_Field>[
        _u('apiVersion', 0, () => p.ref.apiVersion = _u32),
        _u('driverVersion', 4, () => p.ref.driverVersion = _u32),
        _u('vendorID', 8, () => p.ref.vendorID = _u32),
        _u('deviceID', 12, () => p.ref.deviceID = _u32),
        _u('deviceType', 16, () => p.ref.deviceType = _u32),
        _b('deviceName', 20, () => p.ref.deviceName[0] = _byte),
        _b('pipelineCacheUUID', 276, () => p.ref.pipelineCacheUUID[0] = _byte),
        // The nested structure. `deviceName` is 256 bytes and the UUID is 16,
        // so limits begins at 292 rounded up to the 8 its first 64-bit member
        // needs - and reading it four bytes early is the exact shape of the
        // Direct3D 12 bug this file exists for.
        _u('limits', 296, () => p.ref.limits.maxImageDimension1D = _u32),
        _u('sparseProperties', 800,
            () => p.ref.sparseProperties.residencyStandard2DBlockShape = _u32),
      ]);
      expect(vkMaxPhysicalDeviceNameSize, 256);
      expect(vkUuidSize, 16);
    });

    test('VkPhysicalDeviceLimits is 504 bytes with its 64-bit members placed',
        () {
      // A curated set, not all 106 fields: the ones checked are every point
      // where a 64-bit member or an array forces padding, which is where a
      // wrong field type hides. A `Uint32` written where the header says
      // `VkDeviceSize` would move `sparseAddressSpaceSize` and everything
      // after it, and the total size would still not be 504.
      final Pointer<VkPhysicalDeviceLimits> p =
          alloc<VkPhysicalDeviceLimits>(sizeOf<VkPhysicalDeviceLimits>());
      _layout('VkPhysicalDeviceLimits', sizeOf<VkPhysicalDeviceLimits>(), 504,
          p.cast<Uint8>(), <_Field>[
        _u('maxImageDimension1D', 0, () => p.ref.maxImageDimension1D = _u32),
        _u('maxImageDimension2D', 4, () => p.ref.maxImageDimension2D = _u32),
        _u('maxPushConstantsSize', 32, () => p.ref.maxPushConstantsSize = _u32),
        _u('maxSamplerAllocationCount', 40,
            () => p.ref.maxSamplerAllocationCount = _u32),
        _q('bufferImageGranularity', 48,
            () => p.ref.bufferImageGranularity = _u64),
        _q('sparseAddressSpaceSize', 56,
            () => p.ref.sparseAddressSpaceSize = _u64),
        _u('maxBoundDescriptorSets', 64,
            () => p.ref.maxBoundDescriptorSets = _u32),
        _u('maxVertexInputAttributes', 128,
            () => p.ref.maxVertexInputAttributes = _u32),
        _u('maxComputeWorkGroupCount', 220,
            () => p.ref.maxComputeWorkGroupCount[0] = _u32),
        _u('maxComputeWorkGroupSize', 236,
            () => p.ref.maxComputeWorkGroupSize[0] = _u32),
        _f('maxSamplerLodBias', 268, () => p.ref.maxSamplerLodBias = _f32),
        _u('maxViewportDimensions', 280,
            () => p.ref.maxViewportDimensions[0] = _u32),
        _f('viewportBoundsRange', 288,
            () => p.ref.viewportBoundsRange[0] = _f32),
        _u('viewportSubPixelBits', 296,
            () => p.ref.viewportSubPixelBits = _u32),
        // `size_t`, so eight bytes with four of padding before it.
        _q('minMemoryMapAlignment', 304,
            () => p.ref.minMemoryMapAlignment = _u64),
        _q('minTexelBufferOffsetAlignment', 312,
            () => p.ref.minTexelBufferOffsetAlignment = _u64),
        _q('minStorageBufferOffsetAlignment', 328,
            () => p.ref.minStorageBufferOffsetAlignment = _u64),
        _u('minTexelOffset', 336, () => p.ref.minTexelOffset = _u32),
        _f('minInterpolationOffset', 352,
            () => p.ref.minInterpolationOffset = _f32),
        _u('maxColorAttachments', 392, () => p.ref.maxColorAttachments = _u32),
        _f('timestampPeriod', 424, () => p.ref.timestampPeriod = _f32),
        _f('pointSizeRange', 444, () => p.ref.pointSizeRange[0] = _f32),
        _f('lineWidthRange', 452, () => p.ref.lineWidthRange[0] = _f32),
        _q('optimalBufferCopyOffsetAlignment', 480,
            () => p.ref.optimalBufferCopyOffsetAlignment = _u64),
        _q('optimalBufferCopyRowPitchAlignment', 488,
            () => p.ref.optimalBufferCopyRowPitchAlignment = _u64),
        _q('nonCoherentAtomSize', 496, () => p.ref.nonCoherentAtomSize = _u64),
      ]);
    });

    test('VkQueueFamilyProperties and VkFormatProperties', () {
      final Pointer<VkQueueFamilyProperties> q =
          alloc<VkQueueFamilyProperties>(sizeOf<VkQueueFamilyProperties>());
      _layout('VkQueueFamilyProperties', sizeOf<VkQueueFamilyProperties>(), 24,
          q.cast<Uint8>(), <_Field>[
        _u('queueFlags', 0, () => q.ref.queueFlags = _u32),
        _u('queueCount', 4, () => q.ref.queueCount = _u32),
        _u('timestampValidBits', 8, () => q.ref.timestampValidBits = _u32),
        _u('minImageTransferGranularity', 12,
            () => q.ref.minImageTransferGranularity.width = _u32),
      ]);

      final Pointer<VkFormatProperties> f =
          alloc<VkFormatProperties>(sizeOf<VkFormatProperties>());
      _layout('VkFormatProperties', sizeOf<VkFormatProperties>(), 12,
          f.cast<Uint8>(), <_Field>[
        _u('linearTilingFeatures', 0, () => f.ref.linearTilingFeatures = _u32),
        _u('optimalTilingFeatures', 4,
            () => f.ref.optimalTilingFeatures = _u32),
        _u('bufferFeatures', 8, () => f.ref.bufferFeatures = _u32),
      ]);
    });

    test('VkPhysicalDeviceMemoryProperties packs 32 types and 16 heaps', () {
      // 520 bytes, and the heap array is the interesting part: it begins at
      // 264 because `VkMemoryHeap` contains a `VkDeviceSize` and so wants
      // 8-byte alignment, while the type array before it needs only 4.
      final Pointer<VkPhysicalDeviceMemoryProperties> p =
          alloc<VkPhysicalDeviceMemoryProperties>(
              sizeOf<VkPhysicalDeviceMemoryProperties>());
      _layout(
          'VkPhysicalDeviceMemoryProperties',
          sizeOf<VkPhysicalDeviceMemoryProperties>(),
          520,
          p.cast<Uint8>(), <_Field>[
        _u('memoryTypeCount', 0, () => p.ref.memoryTypeCount = _u32),
        _u('memoryTypes[0]', 4,
            () => p.ref.memoryTypes[0].propertyFlags = _u32),
        _u('memoryTypes[31]', 4 + 31 * 8,
            () => p.ref.memoryTypes[31].propertyFlags = _u32),
        _u('memoryHeapCount', 260, () => p.ref.memoryHeapCount = _u32),
        _q('memoryHeaps[0]', 264, () => p.ref.memoryHeaps[0].size = _u64),
        _q('memoryHeaps[15]', 264 + 15 * 16,
            () => p.ref.memoryHeaps[15].size = _u64),
      ]);

      final Pointer<VkMemoryType> type =
          alloc<VkMemoryType>(sizeOf<VkMemoryType>());
      _layout('VkMemoryType', sizeOf<VkMemoryType>(), 8,
          type.cast<Uint8>(), <_Field>[
        _u('propertyFlags', 0, () => type.ref.propertyFlags = _u32),
        _u('heapIndex', 4, () => type.ref.heapIndex = _u32),
      ]);

      final Pointer<VkMemoryHeap> heap =
          alloc<VkMemoryHeap>(sizeOf<VkMemoryHeap>());
      _layout('VkMemoryHeap', sizeOf<VkMemoryHeap>(), 16,
          heap.cast<Uint8>(), <_Field>[
        _q('size', 0, () => heap.ref.size = _u64),
        _u('flags', 8, () => heap.ref.flags = _u32),
      ]);
    });
  });

  group('device and memory', () {
    test('VkDeviceQueueCreateInfo and VkDeviceCreateInfo', () {
      final Pointer<VkDeviceQueueCreateInfo> q =
          alloc<VkDeviceQueueCreateInfo>(sizeOf<VkDeviceQueueCreateInfo>());
      _layout('VkDeviceQueueCreateInfo', sizeOf<VkDeviceQueueCreateInfo>(), 40,
          q.cast<Uint8>(), <_Field>[
        _u('sType', 0, () => q.ref.sType = _u32),
        _q('pNext', 8, () => q.ref.pNext = _sentinelPointer<Void>()),
        _u('flags', 16, () => q.ref.flags = _u32),
        _u('queueFamilyIndex', 20, () => q.ref.queueFamilyIndex = _u32),
        _u('queueCount', 24, () => q.ref.queueCount = _u32),
        _q('pQueuePriorities', 32,
            () => q.ref.pQueuePriorities = _sentinelPointer<Float>()),
      ]);

      final Pointer<VkDeviceCreateInfo> d =
          alloc<VkDeviceCreateInfo>(sizeOf<VkDeviceCreateInfo>());
      _layout('VkDeviceCreateInfo', sizeOf<VkDeviceCreateInfo>(), 72,
          d.cast<Uint8>(), <_Field>[
        _u('sType', 0, () => d.ref.sType = _u32),
        _q('pNext', 8, () => d.ref.pNext = _sentinelPointer<Void>()),
        _u('flags', 16, () => d.ref.flags = _u32),
        _u('queueCreateInfoCount', 20, () => d.ref.queueCreateInfoCount = _u32),
        _q(
            'pQueueCreateInfos',
            24,
            () => d.ref.pQueueCreateInfos =
                _sentinelPointer<VkDeviceQueueCreateInfo>()),
        _u('enabledLayerCount', 32, () => d.ref.enabledLayerCount = _u32),
        _q(
            'ppEnabledLayerNames',
            40,
            () =>
                d.ref.ppEnabledLayerNames = _sentinelPointer<Pointer<Char>>()),
        _u('enabledExtensionCount', 48,
            () => d.ref.enabledExtensionCount = _u32),
        _q(
            'ppEnabledExtensionNames',
            56,
            () => d.ref.ppEnabledExtensionNames =
                _sentinelPointer<Pointer<Char>>()),
        _q(
            'pEnabledFeatures',
            64,
            () => d.ref.pEnabledFeatures =
                _sentinelPointer<VkPhysicalDeviceFeatures>()),
      ]);
    });

    test('VkMemoryAllocateInfo, VkMemoryRequirements, VkMappedMemoryRange', () {
      final Pointer<VkMemoryAllocateInfo> a =
          alloc<VkMemoryAllocateInfo>(sizeOf<VkMemoryAllocateInfo>());
      _layout('VkMemoryAllocateInfo', sizeOf<VkMemoryAllocateInfo>(), 32,
          a.cast<Uint8>(), <_Field>[
        _u('sType', 0, () => a.ref.sType = _u32),
        _q('pNext', 8, () => a.ref.pNext = _sentinelPointer<Void>()),
        _q('allocationSize', 16, () => a.ref.allocationSize = _u64),
        _u('memoryTypeIndex', 24, () => a.ref.memoryTypeIndex = _u32),
      ]);

      final Pointer<VkMemoryRequirements> r =
          alloc<VkMemoryRequirements>(sizeOf<VkMemoryRequirements>());
      _layout('VkMemoryRequirements', sizeOf<VkMemoryRequirements>(), 24,
          r.cast<Uint8>(), <_Field>[
        _q('size', 0, () => r.ref.size = _u64),
        _q('alignment', 8, () => r.ref.alignment = _u64),
        _u('memoryTypeBits', 16, () => r.ref.memoryTypeBits = _u32),
      ]);

      final Pointer<VkMappedMemoryRange> m =
          alloc<VkMappedMemoryRange>(sizeOf<VkMappedMemoryRange>());
      _layout('VkMappedMemoryRange', sizeOf<VkMappedMemoryRange>(), 40,
          m.cast<Uint8>(), <_Field>[
        _u('sType', 0, () => m.ref.sType = _u32),
        _q('pNext', 8, () => m.ref.pNext = _sentinelPointer<Void>()),
        _q('memory', 16,
            () => m.ref.memory = _sentinelPointer<VkDeviceMemory_T>()),
        _q('offset', 24, () => m.ref.offset = _u64),
        _q('size', 32, () => m.ref.size = _u64),
      ]);
    });
  });

  group('buffers and images', () {
    test('VkBufferCreateInfo puts its VkDeviceSize at 24', () {
      // The classic: `flags` is 4 bytes at 16 and `size` is 8, so four bytes
      // of padding sit between them. A binding that packed them would put
      // every later field four bytes early and create buffers of a plausible
      // wrong size.
      final Pointer<VkBufferCreateInfo> p =
          alloc<VkBufferCreateInfo>(sizeOf<VkBufferCreateInfo>());
      _layout('VkBufferCreateInfo', sizeOf<VkBufferCreateInfo>(), 56,
          p.cast<Uint8>(), <_Field>[
        _u('sType', 0, () => p.ref.sType = _u32),
        _q('pNext', 8, () => p.ref.pNext = _sentinelPointer<Void>()),
        _u('flags', 16, () => p.ref.flags = _u32),
        _q('size', 24, () => p.ref.size = _u64),
        _u('usage', 32, () => p.ref.usage = _u32),
        _u('sharingMode', 36, () => p.ref.sharingMode = _u32),
        _u('queueFamilyIndexCount', 40,
            () => p.ref.queueFamilyIndexCount = _u32),
        _q('pQueueFamilyIndices', 48,
            () => p.ref.pQueueFamilyIndices = _sentinelPointer<Uint32>()),
      ]);
    });

    test('VkImageCreateInfo', () {
      final Pointer<VkImageCreateInfo> p =
          alloc<VkImageCreateInfo>(sizeOf<VkImageCreateInfo>());
      _layout('VkImageCreateInfo', sizeOf<VkImageCreateInfo>(), 88,
          p.cast<Uint8>(), <_Field>[
        _u('sType', 0, () => p.ref.sType = _u32),
        _q('pNext', 8, () => p.ref.pNext = _sentinelPointer<Void>()),
        _u('flags', 16, () => p.ref.flags = _u32),
        _u('imageType', 20, () => p.ref.imageType = _u32),
        _u('format', 24, () => p.ref.format = _u32),
        _u('extent', 28, () => p.ref.extent.width = _u32),
        _u('mipLevels', 40, () => p.ref.mipLevels = _u32),
        _u('arrayLayers', 44, () => p.ref.arrayLayers = _u32),
        _u('samples', 48, () => p.ref.samples = _u32),
        _u('tiling', 52, () => p.ref.tiling = _u32),
        _u('usage', 56, () => p.ref.usage = _u32),
        _u('sharingMode', 60, () => p.ref.sharingMode = _u32),
        _u('queueFamilyIndexCount', 64,
            () => p.ref.queueFamilyIndexCount = _u32),
        _q('pQueueFamilyIndices', 72,
            () => p.ref.pQueueFamilyIndices = _sentinelPointer<Uint32>()),
        _u('initialLayout', 80, () => p.ref.initialLayout = _u32),
      ]);
    });

    test('VkImageViewCreateInfo and its two nested structures', () {
      final Pointer<VkImageViewCreateInfo> p =
          alloc<VkImageViewCreateInfo>(sizeOf<VkImageViewCreateInfo>());
      _layout('VkImageViewCreateInfo', sizeOf<VkImageViewCreateInfo>(), 80,
          p.cast<Uint8>(), <_Field>[
        _u('sType', 0, () => p.ref.sType = _u32),
        _q('pNext', 8, () => p.ref.pNext = _sentinelPointer<Void>()),
        _u('flags', 16, () => p.ref.flags = _u32),
        _q('image', 24, () => p.ref.image = _sentinelPointer<VkImage_T>()),
        _u('viewType', 32, () => p.ref.viewType = _u32),
        _u('format', 36, () => p.ref.format = _u32),
        _u('components', 40, () => p.ref.components.r = _u32),
        _u('subresourceRange', 56,
            () => p.ref.subresourceRange.aspectMask = _u32),
      ]);

      final Pointer<VkComponentMapping> c =
          alloc<VkComponentMapping>(sizeOf<VkComponentMapping>());
      _layout('VkComponentMapping', sizeOf<VkComponentMapping>(), 16,
          c.cast<Uint8>(), <_Field>[
        _u('r', 0, () => c.ref.r = _u32),
        _u('g', 4, () => c.ref.g = _u32),
        _u('b', 8, () => c.ref.b = _u32),
        _u('a', 12, () => c.ref.a = _u32),
      ]);

      final Pointer<VkImageSubresourceRange> s =
          alloc<VkImageSubresourceRange>(sizeOf<VkImageSubresourceRange>());
      _layout('VkImageSubresourceRange', sizeOf<VkImageSubresourceRange>(), 20,
          s.cast<Uint8>(), <_Field>[
        _u('aspectMask', 0, () => s.ref.aspectMask = _u32),
        _u('baseMipLevel', 4, () => s.ref.baseMipLevel = _u32),
        _u('levelCount', 8, () => s.ref.levelCount = _u32),
        _u('baseArrayLayer', 12, () => s.ref.baseArrayLayer = _u32),
        _u('layerCount', 16, () => s.ref.layerCount = _u32),
      ]);
    });

    test('VkSamplerCreateInfo interleaves floats and enums', () {
      final Pointer<VkSamplerCreateInfo> p =
          alloc<VkSamplerCreateInfo>(sizeOf<VkSamplerCreateInfo>());
      _layout('VkSamplerCreateInfo', sizeOf<VkSamplerCreateInfo>(), 80,
          p.cast<Uint8>(), <_Field>[
        _u('sType', 0, () => p.ref.sType = _u32),
        _q('pNext', 8, () => p.ref.pNext = _sentinelPointer<Void>()),
        _u('magFilter', 20, () => p.ref.magFilter = _u32),
        _u('minFilter', 24, () => p.ref.minFilter = _u32),
        _u('mipmapMode', 28, () => p.ref.mipmapMode = _u32),
        _u('addressModeU', 32, () => p.ref.addressModeU = _u32),
        _u('addressModeW', 40, () => p.ref.addressModeW = _u32),
        _f('mipLodBias', 44, () => p.ref.mipLodBias = _f32),
        _u('anisotropyEnable', 48, () => p.ref.anisotropyEnable = _u32),
        _f('maxAnisotropy', 52, () => p.ref.maxAnisotropy = _f32),
        _u('compareEnable', 56, () => p.ref.compareEnable = _u32),
        _u('compareOp', 60, () => p.ref.compareOp = _u32),
        _f('minLod', 64, () => p.ref.minLod = _f32),
        _f('maxLod', 68, () => p.ref.maxLod = _f32),
        _u('borderColor', 72, () => p.ref.borderColor = _u32),
        _u('unnormalizedCoordinates', 76,
            () => p.ref.unnormalizedCoordinates = _u32),
      ]);
    });

    test('VkBufferCopy and VkBufferImageCopy', () {
      final Pointer<VkBufferCopy> c =
          alloc<VkBufferCopy>(sizeOf<VkBufferCopy>());
      _layout(
          'VkBufferCopy', sizeOf<VkBufferCopy>(), 24, c.cast<Uint8>(), <_Field>[
        _q('srcOffset', 0, () => c.ref.srcOffset = _u64),
        _q('dstOffset', 8, () => c.ref.dstOffset = _u64),
        _q('size', 16, () => c.ref.size = _u64),
      ]);

      final Pointer<VkBufferImageCopy> p =
          alloc<VkBufferImageCopy>(sizeOf<VkBufferImageCopy>());
      _layout('VkBufferImageCopy', sizeOf<VkBufferImageCopy>(), 56,
          p.cast<Uint8>(), <_Field>[
        _q('bufferOffset', 0, () => p.ref.bufferOffset = _u64),
        _u('bufferRowLength', 8, () => p.ref.bufferRowLength = _u32),
        _u('bufferImageHeight', 12, () => p.ref.bufferImageHeight = _u32),
        _u('imageSubresource', 16,
            () => p.ref.imageSubresource.aspectMask = _u32),
        _u('imageOffset', 32, () => p.ref.imageOffset.x = _u32),
        _u('imageExtent', 44, () => p.ref.imageExtent.width = _u32),
      ]);
    });
  });

  group('synchronisation', () {
    test('the three create-infos that are only sType, pNext and flags', () {
      final Pointer<VkFenceCreateInfo> fence =
          alloc<VkFenceCreateInfo>(sizeOf<VkFenceCreateInfo>());
      _layout('VkFenceCreateInfo', sizeOf<VkFenceCreateInfo>(), 24,
          fence.cast<Uint8>(), <_Field>[
        _u('sType', 0, () => fence.ref.sType = _u32),
        _q('pNext', 8, () => fence.ref.pNext = _sentinelPointer<Void>()),
        _u('flags', 16, () => fence.ref.flags = _u32),
      ]);

      final Pointer<VkSemaphoreCreateInfo> semaphore =
          alloc<VkSemaphoreCreateInfo>(sizeOf<VkSemaphoreCreateInfo>());
      _layout('VkSemaphoreCreateInfo', sizeOf<VkSemaphoreCreateInfo>(), 24,
          semaphore.cast<Uint8>(), <_Field>[
        _u('sType', 0, () => semaphore.ref.sType = _u32),
        _q('pNext', 8, () => semaphore.ref.pNext = _sentinelPointer<Void>()),
        _u('flags', 16, () => semaphore.ref.flags = _u32),
      ]);

      final Pointer<VkEventCreateInfo> event =
          alloc<VkEventCreateInfo>(sizeOf<VkEventCreateInfo>());
      _layout('VkEventCreateInfo', sizeOf<VkEventCreateInfo>(), 24,
          event.cast<Uint8>(), <_Field>[
        _u('sType', 0, () => event.ref.sType = _u32),
        _q('pNext', 8, () => event.ref.pNext = _sentinelPointer<Void>()),
        _u('flags', 16, () => event.ref.flags = _u32),
      ]);
    });

    test('VkImageMemoryBarrier is 72 bytes with the image handle at 40', () {
      // The structure every layout transition in this backend fills in. Its
      // two queue-family indices sit between the layouts and the handle, and
      // a binding that dropped either of them would transition the wrong
      // image - or corrupt the stack, since the handle would be read from
      // eight bytes of two enums.
      final Pointer<VkImageMemoryBarrier> p =
          alloc<VkImageMemoryBarrier>(sizeOf<VkImageMemoryBarrier>());
      _layout('VkImageMemoryBarrier', sizeOf<VkImageMemoryBarrier>(), 72,
          p.cast<Uint8>(), <_Field>[
        _u('sType', 0, () => p.ref.sType = _u32),
        _q('pNext', 8, () => p.ref.pNext = _sentinelPointer<Void>()),
        _u('srcAccessMask', 16, () => p.ref.srcAccessMask = _u32),
        _u('dstAccessMask', 20, () => p.ref.dstAccessMask = _u32),
        _u('oldLayout', 24, () => p.ref.oldLayout = _u32),
        _u('newLayout', 28, () => p.ref.newLayout = _u32),
        _u('srcQueueFamilyIndex', 32, () => p.ref.srcQueueFamilyIndex = _u32),
        _u('dstQueueFamilyIndex', 36, () => p.ref.dstQueueFamilyIndex = _u32),
        _q('image', 40, () => p.ref.image = _sentinelPointer<VkImage_T>()),
        _u('subresourceRange', 48,
            () => p.ref.subresourceRange.aspectMask = _u32),
      ]);

      final Pointer<VkMemoryBarrier> m =
          alloc<VkMemoryBarrier>(sizeOf<VkMemoryBarrier>());
      _layout('VkMemoryBarrier', sizeOf<VkMemoryBarrier>(), 24,
          m.cast<Uint8>(), <_Field>[
        _u('sType', 0, () => m.ref.sType = _u32),
        _q('pNext', 8, () => m.ref.pNext = _sentinelPointer<Void>()),
        _u('srcAccessMask', 16, () => m.ref.srcAccessMask = _u32),
        _u('dstAccessMask', 20, () => m.ref.dstAccessMask = _u32),
      ]);
    });
  });

  group('commands', () {
    test('the command pool and buffer structures', () {
      final Pointer<VkCommandPoolCreateInfo> pool =
          alloc<VkCommandPoolCreateInfo>(sizeOf<VkCommandPoolCreateInfo>());
      _layout('VkCommandPoolCreateInfo', sizeOf<VkCommandPoolCreateInfo>(), 24,
          pool.cast<Uint8>(), <_Field>[
        _u('sType', 0, () => pool.ref.sType = _u32),
        _q('pNext', 8, () => pool.ref.pNext = _sentinelPointer<Void>()),
        _u('flags', 16, () => pool.ref.flags = _u32),
        _u('queueFamilyIndex', 20, () => pool.ref.queueFamilyIndex = _u32),
      ]);

      final Pointer<VkCommandBufferAllocateInfo> alloc0 =
          alloc<VkCommandBufferAllocateInfo>(
              sizeOf<VkCommandBufferAllocateInfo>());
      _layout(
          'VkCommandBufferAllocateInfo',
          sizeOf<VkCommandBufferAllocateInfo>(),
          32,
          alloc0.cast<Uint8>(), <_Field>[
        _u('sType', 0, () => alloc0.ref.sType = _u32),
        _q('pNext', 8, () => alloc0.ref.pNext = _sentinelPointer<Void>()),
        _q('commandPool', 16,
            () => alloc0.ref.commandPool = _sentinelPointer<VkCommandPool_T>()),
        _u('level', 24, () => alloc0.ref.level = _u32),
        _u('commandBufferCount', 28,
            () => alloc0.ref.commandBufferCount = _u32),
      ]);

      final Pointer<VkCommandBufferBeginInfo> begin =
          alloc<VkCommandBufferBeginInfo>(sizeOf<VkCommandBufferBeginInfo>());
      _layout('VkCommandBufferBeginInfo', sizeOf<VkCommandBufferBeginInfo>(),
          32, begin.cast<Uint8>(), <_Field>[
        _u('sType', 0, () => begin.ref.sType = _u32),
        _q('pNext', 8, () => begin.ref.pNext = _sentinelPointer<Void>()),
        _u('flags', 16, () => begin.ref.flags = _u32),
        _q(
            'pInheritanceInfo',
            24,
            () => begin.ref.pInheritanceInfo =
                _sentinelPointer<VkCommandBufferInheritanceInfo>()),
      ]);
    });

    test('VkSubmitInfo is 72 bytes with three padded counts', () {
      // Every submission this backend makes goes through it, and its three
      // `uint32_t` counts each sit before a pointer, so each has four bytes of
      // padding after it. A packed version would put `pCommandBuffers` where
      // `pWaitDstStageMask` belongs and submit garbage.
      final Pointer<VkSubmitInfo> p =
          alloc<VkSubmitInfo>(sizeOf<VkSubmitInfo>());
      _layout(
          'VkSubmitInfo', sizeOf<VkSubmitInfo>(), 72, p.cast<Uint8>(), <_Field>[
        _u('sType', 0, () => p.ref.sType = _u32),
        _q('pNext', 8, () => p.ref.pNext = _sentinelPointer<Void>()),
        _u('waitSemaphoreCount', 16, () => p.ref.waitSemaphoreCount = _u32),
        _q(
            'pWaitSemaphores',
            24,
            () => p.ref.pWaitSemaphores =
                _sentinelPointer<Pointer<VkSemaphore_T>>()),
        _q('pWaitDstStageMask', 32,
            () => p.ref.pWaitDstStageMask = _sentinelPointer<Uint32>()),
        _u('commandBufferCount', 40, () => p.ref.commandBufferCount = _u32),
        _q(
            'pCommandBuffers',
            48,
            () => p.ref.pCommandBuffers =
                _sentinelPointer<Pointer<VkCommandBuffer_T>>()),
        _u('signalSemaphoreCount', 56, () => p.ref.signalSemaphoreCount = _u32),
        _q(
            'pSignalSemaphores',
            64,
            () => p.ref.pSignalSemaphores =
                _sentinelPointer<Pointer<VkSemaphore_T>>()),
      ]);
    });
  });

  group('debug utils', () {
    test('VkDebugUtilsMessengerCreateInfoEXT', () {
      final Pointer<VkDebugUtilsMessengerCreateInfoEXT> p =
          alloc<VkDebugUtilsMessengerCreateInfoEXT>(
              sizeOf<VkDebugUtilsMessengerCreateInfoEXT>());
      _layout(
          'VkDebugUtilsMessengerCreateInfoEXT',
          sizeOf<VkDebugUtilsMessengerCreateInfoEXT>(),
          48,
          p.cast<Uint8>(), <_Field>[
        _u('sType', 0, () => p.ref.sType = _u32),
        _q('pNext', 8, () => p.ref.pNext = _sentinelPointer<Void>()),
        _u('flags', 16, () => p.ref.flags = _u32),
        _u('messageSeverity', 20, () => p.ref.messageSeverity = _u32),
        _u('messageType', 24, () => p.ref.messageType = _u32),
        // The field is a fully-spelled function pointer type; what is
        // being measured is where eight bytes land, so any pointer will
        // do and the cast keeps the spelling out of the test.
        _q('pfnUserCallback', 32,
            () => p.ref.pfnUserCallback = _sentinelPointer<Void>().cast()),
        _q('pUserData', 40, () => p.ref.pUserData = _sentinelPointer<Void>()),
      ]);
    });

    test('VkDebugUtilsMessengerCallbackDataEXT reaches pMessage at 40', () {
      // Read-only, through a pointer the loader owns, and the only field this
      // backend touches is `pMessage`. If it were at the wrong offset the
      // renderer would print whatever `messageIdNumber` happened to be beside,
      // as a string, from an address that is not one.
      final Pointer<VkDebugUtilsMessengerCallbackDataEXT> p =
          alloc<VkDebugUtilsMessengerCallbackDataEXT>(
              sizeOf<VkDebugUtilsMessengerCallbackDataEXT>());
      _layout(
          'VkDebugUtilsMessengerCallbackDataEXT',
          sizeOf<VkDebugUtilsMessengerCallbackDataEXT>(),
          96,
          p.cast<Uint8>(), <_Field>[
        _u('sType', 0, () => p.ref.sType = _u32),
        _q('pNext', 8, () => p.ref.pNext = _sentinelPointer<Void>()),
        _u('flags', 16, () => p.ref.flags = _u32),
        _q('pMessageIdName', 24,
            () => p.ref.pMessageIdName = _sentinelPointer<Char>()),
        _u('messageIdNumber', 32, () => p.ref.messageIdNumber = _u32),
        _q('pMessage', 40, () => p.ref.pMessage = _sentinelPointer<Char>()),
      ]);
    });
  });
}
