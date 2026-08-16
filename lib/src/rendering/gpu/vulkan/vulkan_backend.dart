/// The Vulkan backend: a [RendererBackend], a [RenderDevice] and an offscreen
/// [RenderTarget] over the shared GPU layer.
///
/// ## What this draws, and what it says it does not
///
/// Section 6.6 asks a backend to name what it cannot do rather than to accept
/// everything and draw it wrong. This one draws:
///
///   * **solid fills** - rectangles, with the analytic `boxCoverage`
///     antialiasing of `gpu_pipeline.dart`;
///   * **coverage masks** - paths and rounded rectangles, through the shared
///     [GpuMaskAtlas];
///   * **images** - premultiplied RGBA, uploaded once and sampled.
///
/// And it refuses, by name, through the sink's own [UnsupportedCapabilityError]:
///
///   * **text**. No [GpuGlyphAtlas] is passed, so a glyph run is refused
///     rather than dropped.
///   * **compositing layers**. No [GpuLayerStack] is passed, so a `saveLayer`
///     that needs a real offscreen pass is refused rather than flattened.
///   * **windowed presentation**. There is no swapchain; the only surface this
///     backend supports is a [MemorySurfaceDescriptor]. `supportsSurface`
///     answers false for anything else instead of failing later.
///
/// Each of those is a named gap and not a hidden one, which is the difference
/// between a backend that can be finished and one that has to be re-audited.
///
/// ## The one deliberate performance compromise
///
/// The vertex and index buffers are `HOST_VISIBLE` and are written by the CPU
/// and read by the GPU directly, with no staging copy. On the integrated GPUs
/// this backend has been measured on that is the *right* answer - there is one
/// physical memory and a staging copy is pure cost. On a discrete GPU it means
/// the vertex fetch crosses PCIe every frame, and the fix is a device-local
/// buffer with a per-frame `vkCmdCopyBuffer` into it. That is a change to
/// [VulkanBuffer.createVertexBuffer] and nothing else, and it is written down
/// here rather than discovered by somebody profiling a discrete card.
library;

import 'dart:async';
import 'dart:ffi';
import 'dart:typed_data';

import '../../../ffi/native_memory.dart';
import '../../../foundation/diagnostics.dart';
import '../../../geometry/rect.dart';
import '../../../geometry/transform2d.dart';
import '../../../graphics/display_list.dart';
import '../../../graphics/display_list_reader.dart';
import '../../framebuffer.dart';
import '../../renderer.dart';
import '../../replay/display_list_player.dart';
import '../gpu_batcher.dart';
import '../gpu_mask_atlas.dart';
import '../gpu_raster_sink.dart';
import '../gpu_texture.dart';
import 'vulkan_constants.dart';
import 'vulkan_device.dart';
import 'vulkan_ffi.g.dart';
import 'vulkan_instance.dart';
import 'vulkan_library.dart';
import 'vulkan_memory.dart';
import 'vulkan_pipeline.dart';
import 'vulkan_shaders.dart';

/// A `VkBuffer` and the memory behind it.
final class VulkanBuffer {
  VulkanBuffer._(this.handle, this.memory, this.size);

  final Pointer<VkBuffer_T> handle;
  final VulkanAllocation memory;
  final int size;

  Pointer<Uint8> get mapped => memory.mapped;

  static VulkanBuffer? create(
    VulkanDevice device, {
    required String resource,
    required int size,
    required int usage,
    required bool hostVisible,
  }) =>
      using((NativeArena arena) {
        final Pointer<VkBufferCreateInfo> info = arena<VkBufferCreateInfo>();
        info.ref
          ..sType = VkStructureType.VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO
          ..size = size
          ..usage = usage
          ..sharingMode = VkSharingMode.VK_SHARING_MODE_EXCLUSIVE;
        final Pointer<Pointer<VkBuffer_T>> out = arena<Pointer<VkBuffer_T>>();
        if (vkFailed(
            device.api.createBuffer(device.handle, info, nullptr, out))) {
          return null;
        }
        final Pointer<VkMemoryRequirements> requirements =
            arena<VkMemoryRequirements>();
        device.api.getBufferMemoryRequirements(
            device.handle, out.value, requirements);
        final VulkanAllocation allocation = device.allocator.allocate(
          resource: resource,
          size: requirements.ref.size,
          alignment: requirements.ref.alignment,
          memoryTypeBits: requirements.ref.memoryTypeBits,
          required: hostVisible
              ? VkMemoryPropertyFlagBits.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT |
                  VkMemoryPropertyFlagBits.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT
              : VkMemoryPropertyFlagBits.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT,
          linear: true,
        );
        if (vkFailed(device.api.bindBufferMemory(
            device.handle, out.value, allocation.memory, allocation.offset))) {
          device.allocator.free(allocation);
          device.api.destroyBuffer(device.handle, out.value, nullptr);
          return null;
        }
        return VulkanBuffer._(out.value, allocation, size);
      });

  void dispose(VulkanDevice device) {
    device.api.destroyBuffer(device.handle, handle, nullptr);
    device.allocator.free(memory);
  }
}

/// A texture: an image, its view, its descriptor set and its current layout.
final class VulkanTexture implements GpuTextureHandle {
  VulkanTexture._({
    required this.id,
    required this.width,
    required this.height,
    required this.format,
    required this.filter,
    required this.image,
    required this.view,
    required this.memory,
    required this.descriptorSet,
  });

  @override
  final int id;
  @override
  final int width;
  @override
  final int height;
  @override
  final GpuTextureFormat format;
  @override
  final GpuTextureFilter filter;

  final Pointer<VkImage_T> image;
  final Pointer<VkImageView_T> view;
  final VulkanAllocation memory;
  final Pointer<VkDescriptorSet_T> descriptorSet;

  /// What layout the image is in right now.
  ///
  /// Tracked on the Dart side because Vulkan does not track it: every barrier
  /// states the layout it is transitioning *from*, and getting that wrong is
  /// undefined behaviour that a driver is free to implement as "the contents
  /// are now garbage". Starting at `UNDEFINED` is exactly what
  /// `vkCreateImage` promised.
  int layout = VkImageLayout.VK_IMAGE_LAYOUT_UNDEFINED;

  @override
  bool get isValid => _valid;
  bool _valid = true;

  void _invalidate() => _valid = false;

  @override
  String toString() => 'VulkanTexture($id, ${width}x$height, ${format.name}, '
      '${vkImageLayoutName(layout)})';
}

/// One upload waiting for a command buffer to record it into.
final class _PendingUpload {
  const _PendingUpload(this.texture, this.x, this.y, this.width, this.height,
      this.stagingOffset);

  final VulkanTexture texture;
  final int x;
  final int y;
  final int width;
  final int height;
  final int stagingOffset;
}

/// Images resolved to textures, uploaded once each.
final class VulkanImageCache implements GpuImageResolver {
  VulkanImageCache(this._device);

  final VulkanRenderDevice _device;

  /// Weak-keyed so the cache holds no image alive.
  final Expando<VulkanTexture> _byImage = Expando<VulkanTexture>();
  final List<VulkanTexture> _textures = <VulkanTexture>[];

  int get length => _textures.length;

  @override
  GpuTextureHandle? resolve(Object image) {
    if (image is! Framebuffer) return null;
    final VulkanTexture? cached = _byImage[image];
    if (cached != null && cached.isValid) return cached;

    final VulkanTexture texture = _device.createTexture(
      width: image.width,
      height: image.height,
      format: GpuTextureFormat.rgba8888Premultiplied,
      filter: GpuTextureFilter.linear,
    );
    _device.uploadRegion(
      texture,
      x: 0,
      y: 0,
      width: image.width,
      height: image.height,
      pixels: image.pixels,
      bytesPerRow: image.bytesPerRow,
    );
    _byImage[image] = texture;
    _textures.add(texture);
    return texture;
  }

  void dispose() {
    for (final VulkanTexture texture in _textures) {
      _device.releaseTexture(texture);
    }
    _textures.clear();
  }
}

/// An open Vulkan device: the instance, the logical device, the pipelines and
/// the texture allocator.
final class VulkanRenderDevice implements RenderDevice, GpuTextureAllocator {
  VulkanRenderDevice._(this._instance, this.gpu, this._ownsInstance);

  static const String backendName = 'vulkan';

  /// How many textures one descriptor pool can serve.
  ///
  /// Two atlases, a default, and room for an image cache. A pool that runs out
  /// returns `VK_ERROR_OUT_OF_POOL_MEMORY` from `vkAllocateDescriptorSets`,
  /// which [createTexture] turns into a named refusal rather than a null set
  /// that would be bound and sampled.
  static const int kMaxDescriptorSets = 256;

  final VulkanInstance _instance;
  final VulkanDevice gpu;
  final bool _ownsInstance;

  final Map<int, VulkanPipelines> _pipelines = <int, VulkanPipelines>{};

  Pointer<VkDescriptorPool_T> _descriptorPool = nullptr;
  Pointer<VkSampler_T> _nearest = nullptr;
  Pointer<VkSampler_T> _linear = nullptr;

  /// A 1x1 opaque white texture, bound for batches that sample nothing.
  ///
  /// The solid fragment module declares no descriptor at all, so binding
  /// anything is formally unnecessary - but a pipeline layout that declares a
  /// set and a command buffer that never binds one is a difference between
  /// drivers nobody should be relying on. One texel costs nothing and makes
  /// every draw call in this backend look the same.
  VulkanTexture? _defaultTexture;

  VulkanBuffer? _vertices;
  VulkanBuffer? _indices;
  VulkanBuffer? _staging;
  final BytesBuilder _stagingBytes = BytesBuilder(copy: false);
  final List<_PendingUpload> _uploads = <_PendingUpload>[];

  int _nextTextureId = 1;
  bool _disposed = false;

  @override
  bool get isLost => gpu.isLost;

  @override
  RendererInfo get info => RendererInfo(
        name: backendName,
        deviceDescription: gpu.physicalDevice.name,
        driverVersion:
            'Vulkan ${vkVersionText(gpu.physicalDevice.apiVersion)}, driver '
            '0x${gpu.physicalDevice.driverVersion.toRadixString(16)}',
      );

  @override
  RendererCapabilities get capabilities => RendererCapabilities(
        // No swapchain, so no partial present to honour.
        supportsPartialPresent: false,
        supportsMsaa: false,
        supportsCompute: false,
        supportsExternalTextures: false,
        supportsLinearColor: false,
        maxTextureSize: gpu.physicalDevice.maxImageDimension2D,
        formats: const <PixelFormat>{
          PixelFormat.bgra8888Premultiplied,
          PixelFormat.rgba8888Premultiplied,
        },
      );

  @override
  bool get isDisposed => _disposed;

  /// Opens a device, or throws a [BackendSelectionError] naming why not.
  static VulkanRenderDevice open({
    VulkanInstanceOptions options = const VulkanInstanceOptions(),
  }) {
    final VulkanLoadResult load = VulkanLibrary.open();
    final VulkanLibrary? library = load.library;
    if (library == null) {
      throw BackendSelectionError(
        requested: backendName,
        attempts: <BackendProbeResult>[
          BackendProbeResult(
            backendName: backendName,
            supported: false,
            diagnostics: load.diagnostics,
          ),
        ],
      );
    }
    final VulkanInstanceAttempt attempt =
        VulkanInstance.create(library, options: options);
    final VulkanInstance? instance = attempt.instance;
    if (instance == null) {
      throw BackendSelectionError(
        requested: backendName,
        attempts: <BackendProbeResult>[
          BackendProbeResult(
            backendName: backendName,
            supported: false,
            diagnostics: attempt.diagnostics,
          ),
        ],
      );
    }
    try {
      return adoptInstance(instance, ownsInstance: true);
    } on BackendSelectionError {
      instance.dispose();
      rethrow;
    }
  }

  /// Opens a device on an instance the caller already made.
  static VulkanRenderDevice adoptInstance(
    VulkanInstance instance, {
    bool ownsInstance = false,
  }) {
    final VulkanPhysicalDevice? physical = instance.chooseDevice();
    if (physical == null) {
      throw BackendSelectionError(
        requested: backendName,
        attempts: <BackendProbeResult>[
          BackendProbeResult(
            backendName: backendName,
            supported: false,
            diagnostics: <BackendDiagnostic>[
              const BackendDiagnostic(
                kind: DiagnosticKind.incompatibleDevice,
                message: 'no Vulkan physical device has a graphics queue',
              ),
            ],
          ),
        ],
      );
    }
    final VulkanDeviceAttempt opened = VulkanDevice.open(physical);
    final VulkanDevice? gpu = opened.device;
    if (gpu == null) {
      throw BackendSelectionError(
        requested: backendName,
        attempts: <BackendProbeResult>[
          BackendProbeResult(
            backendName: backendName,
            supported: false,
            diagnostics: opened.diagnostics,
          ),
        ],
      );
    }
    final VulkanRenderDevice device =
        VulkanRenderDevice._(instance, gpu, ownsInstance);
    final BackendDiagnostic? failure = device._createDeviceObjects();
    if (failure != null) {
      device.dispose();
      throw BackendSelectionError(
        requested: backendName,
        attempts: <BackendProbeResult>[
          BackendProbeResult(
            backendName: backendName,
            supported: false,
            diagnostics: <BackendDiagnostic>[failure],
          ),
        ],
      );
    }
    return device;
  }

  BackendDiagnostic? _createDeviceObjects() => using((NativeArena arena) {
        final Pointer<VkDescriptorPoolSize> size =
            arena<VkDescriptorPoolSize>();
        size.ref
          ..type = VkDescriptorType.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER
          ..descriptorCount = kMaxDescriptorSets;
        final Pointer<VkDescriptorPoolCreateInfo> poolInfo =
            arena<VkDescriptorPoolCreateInfo>();
        poolInfo.ref
          ..sType =
              VkStructureType.VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO
          ..flags = VkDescriptorPoolCreateFlagBits
              .VK_DESCRIPTOR_POOL_CREATE_FREE_DESCRIPTOR_SET_BIT
          ..maxSets = kMaxDescriptorSets
          ..poolSizeCount = 1
          ..pPoolSizes = size;
        final Pointer<Pointer<VkDescriptorPool_T>> poolOut =
            arena<Pointer<VkDescriptorPool_T>>();
        if (vkFailed(gpu.api
            .createDescriptorPool(gpu.handle, poolInfo, nullptr, poolOut))) {
          return const BackendDiagnostic(
            kind: DiagnosticKind.incompatibleDevice,
            message: 'vkCreateDescriptorPool refused',
          );
        }
        _descriptorPool = poolOut.value;

        _nearest = _createSampler(arena, VkFilter.VK_FILTER_NEAREST);
        _linear = _createSampler(arena, VkFilter.VK_FILTER_LINEAR);
        if (_nearest == nullptr || _linear == nullptr) {
          return const BackendDiagnostic(
            kind: DiagnosticKind.incompatibleDevice,
            message: 'vkCreateSampler refused',
          );
        }

        final VulkanTexture white = createTexture(
          width: 1,
          height: 1,
          format: GpuTextureFormat.rgba8888Premultiplied,
        );
        uploadRegion(
          white,
          x: 0,
          y: 0,
          width: 1,
          height: 1,
          pixels: Uint8List.fromList(<int>[0xFF, 0xFF, 0xFF, 0xFF]),
          bytesPerRow: 4,
        );
        _defaultTexture = white;
        return null;
      });

  Pointer<VkSampler_T> _createSampler(NativeArena arena, int filter) {
    final Pointer<VkSamplerCreateInfo> info = arena<VkSamplerCreateInfo>();
    info.ref
      ..sType = VkStructureType.VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO
      ..magFilter = filter
      ..minFilter = filter
      ..mipmapMode = VkSamplerMipmapMode.VK_SAMPLER_MIPMAP_MODE_NEAREST
      ..addressModeU =
          VkSamplerAddressMode.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE
      ..addressModeV =
          VkSamplerAddressMode.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE
      ..addressModeW =
          VkSamplerAddressMode.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE
      ..maxLod = 0
      ..borderColor = VkBorderColor.VK_BORDER_COLOR_FLOAT_TRANSPARENT_BLACK;
    final Pointer<Pointer<VkSampler_T>> out = arena<Pointer<VkSampler_T>>();
    if (vkFailed(gpu.api.createSampler(gpu.handle, info, nullptr, out))) {
      return nullptr;
    }
    return out.value;
  }

  /// The pipelines for [colorFormat], built the first time one is asked for.
  VulkanPipelines? pipelinesFor(int colorFormat) => _pipelines[colorFormat] ??=
      VulkanPipelines.create(gpu, colorFormat: colorFormat) ??
          (throw UnsupportedCapabilityError(
            backendName: backendName,
            capability: Capability.gpuPresentation,
            detail: 'no graphics pipeline could be built for '
                '${vkFormatName(colorFormat)} on ${gpu.physicalDevice.name}',
          ));

  @override
  RenderTarget createTarget(NativeSurfaceDescriptor surface) {
    if (surface is! MemorySurfaceDescriptor) {
      throw UnsupportedCapabilityError(
        backendName: backendName,
        capability: Capability.gpuPresentation,
        detail: 'this Vulkan backend has no swapchain and can only render '
            'into memory; it was asked for a "${surface.kind}" surface',
      );
    }
    return VulkanOffscreenTarget._(this, surface);
  }

  // -- textures -------------------------------------------------------------

  @override
  VulkanTexture createTexture({
    required int width,
    required int height,
    required GpuTextureFormat format,
    GpuTextureFilter filter = GpuTextureFilter.linear,
  }) {
    final int limit = gpu.physicalDevice.maxImageDimension2D;
    if (width < 1 || height < 1 || width > limit || height > limit) {
      throw UnsupportedCapabilityError(
        backendName: backendName,
        capability: Capability.gpuPresentation,
        detail: '${width}x$height exceeds maxImageDimension2D ($limit) on '
            '${gpu.physicalDevice.name}',
      );
    }
    final int vkFormat = format == GpuTextureFormat.alpha8
        ? VkFormat.VK_FORMAT_R8_UNORM
        : VkFormat.VK_FORMAT_R8G8B8A8_UNORM;
    return _createImageTexture(
      width: width,
      height: height,
      format: format,
      filter: filter,
      vkFormat: vkFormat,
      usage: VkImageUsageFlagBits.VK_IMAGE_USAGE_TRANSFER_DST_BIT |
          VkImageUsageFlagBits.VK_IMAGE_USAGE_SAMPLED_BIT,
      sampled: true,
    );
  }

  VulkanTexture _createImageTexture({
    required int width,
    required int height,
    required GpuTextureFormat format,
    required GpuTextureFilter filter,
    required int vkFormat,
    required int usage,
    required bool sampled,
  }) =>
      using((NativeArena arena) {
        final Pointer<VkImageCreateInfo> info = arena<VkImageCreateInfo>();
        info.ref
          ..sType = VkStructureType.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO
          ..imageType = VkImageType.VK_IMAGE_TYPE_2D
          ..format = vkFormat
          ..mipLevels = 1
          ..arrayLayers = 1
          ..samples = VkSampleCountFlagBits.VK_SAMPLE_COUNT_1_BIT
          ..tiling = VkImageTiling.VK_IMAGE_TILING_OPTIMAL
          ..usage = usage
          ..sharingMode = VkSharingMode.VK_SHARING_MODE_EXCLUSIVE
          ..initialLayout = VkImageLayout.VK_IMAGE_LAYOUT_UNDEFINED;
        info.ref.extent
          ..width = width
          ..height = height
          ..depth = 1;

        final Pointer<Pointer<VkImage_T>> imageOut =
            arena<Pointer<VkImage_T>>();
        if (vkFailed(
            gpu.api.createImage(gpu.handle, info, nullptr, imageOut))) {
          throw UnsupportedCapabilityError(
            backendName: backendName,
            capability: Capability.gpuPresentation,
            detail: 'vkCreateImage refused ${width}x$height '
                '${vkFormatName(vkFormat)}',
          );
        }

        final Pointer<VkMemoryRequirements> requirements =
            arena<VkMemoryRequirements>();
        gpu.api.getImageMemoryRequirements(
            gpu.handle, imageOut.value, requirements);
        final VulkanAllocation allocation = gpu.allocator.allocate(
          resource: 'image ${width}x$height ${vkFormatName(vkFormat)}',
          size: requirements.ref.size,
          alignment: requirements.ref.alignment,
          memoryTypeBits: requirements.ref.memoryTypeBits,
          required:
              VkMemoryPropertyFlagBits.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT,
          // Optimal tiling, so this must not share a block with a buffer. See
          // the bufferImageGranularity discussion in `vulkan_memory.dart`.
          linear: false,
        );
        gpu.api.bindImageMemory(
            gpu.handle, imageOut.value, allocation.memory, allocation.offset);

        final Pointer<VkImageViewCreateInfo> viewInfo =
            arena<VkImageViewCreateInfo>();
        viewInfo.ref
          ..sType = VkStructureType.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO
          ..image = imageOut.value
          ..viewType = VkImageViewType.VK_IMAGE_VIEW_TYPE_2D
          ..format = vkFormat;
        viewInfo.ref.subresourceRange
          ..aspectMask = VkImageAspectFlagBits.VK_IMAGE_ASPECT_COLOR_BIT
          ..levelCount = 1
          ..layerCount = 1;
        final Pointer<Pointer<VkImageView_T>> viewOut =
            arena<Pointer<VkImageView_T>>();
        if (vkFailed(
            gpu.api.createImageView(gpu.handle, viewInfo, nullptr, viewOut))) {
          throw UnsupportedCapabilityError(
            backendName: backendName,
            capability: Capability.gpuPresentation,
            detail: 'vkCreateImageView refused ${vkFormatName(vkFormat)}',
          );
        }

        Pointer<VkDescriptorSet_T> set = nullptr;
        if (sampled) {
          set = _allocateDescriptorSet(arena, viewOut.value, filter);
        }

        return VulkanTexture._(
          id: _nextTextureId++,
          width: width,
          height: height,
          format: format,
          filter: filter,
          image: imageOut.value,
          view: viewOut.value,
          memory: allocation,
          descriptorSet: set,
        );
      });

  Pointer<VkDescriptorSet_T> _allocateDescriptorSet(
    NativeArena arena,
    Pointer<VkImageView_T> view,
    GpuTextureFilter filter,
  ) {
    final VulkanPipelines pipelines =
        pipelinesFor(VkFormat.VK_FORMAT_B8G8R8A8_UNORM)!;
    final Pointer<Pointer<VkDescriptorSetLayout_T>> layouts =
        arena<Pointer<VkDescriptorSetLayout_T>>();
    layouts.value = pipelines.descriptorSetLayout;

    final Pointer<VkDescriptorSetAllocateInfo> info =
        arena<VkDescriptorSetAllocateInfo>();
    info.ref
      ..sType = VkStructureType.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO
      ..descriptorPool = _descriptorPool
      ..descriptorSetCount = 1
      ..pSetLayouts = layouts;
    final Pointer<Pointer<VkDescriptorSet_T>> out =
        arena<Pointer<VkDescriptorSet_T>>();
    final int result = gpu.api.allocateDescriptorSets(gpu.handle, info, out);
    if (vkFailed(result)) {
      throw UnsupportedCapabilityError(
        backendName: backendName,
        capability: Capability.gpuPresentation,
        detail: 'vkAllocateDescriptorSets answered ${vkResultName(result)}; '
            'this device pool holds $kMaxDescriptorSets sets',
      );
    }

    final Pointer<VkDescriptorImageInfo> imageInfo =
        arena<VkDescriptorImageInfo>();
    imageInfo.ref
      ..sampler = filter == GpuTextureFilter.linear ? _linear : _nearest
      ..imageView = view
      ..imageLayout = VkImageLayout.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;

    final Pointer<VkWriteDescriptorSet> write = arena<VkWriteDescriptorSet>();
    write.ref
      ..sType = VkStructureType.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET
      ..dstSet = out.value
      ..dstBinding = kVulkanTextureBinding
      ..descriptorCount = 1
      ..descriptorType =
          VkDescriptorType.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER
      ..pImageInfo = imageInfo;
    gpu.api.updateDescriptorSets(gpu.handle, 1, write, 0, nullptr);
    return out.value;
  }

  @override
  void uploadRegion(
    covariant VulkanTexture texture, {
    required int x,
    required int y,
    required int width,
    required int height,
    required Uint8List pixels,
    required int bytesPerRow,
  }) {
    final int bytesPerPixel = texture.format.bytesPerPixel;
    final int tight = width * bytesPerPixel;
    final int offset = _stagingBytes.length;
    // Repacked to a tight stride here rather than passed through with a row
    // pitch, because `VkBufferImageCopy.bufferRowLength` is in *texels* and a
    // caller's stride is in bytes; converting at this one place is cheaper
    // than a rule every call site has to remember.
    final Uint8List packed = Uint8List(tight * height);
    for (var row = 0; row < height; row++) {
      packed.setRange(
          row * tight, row * tight + tight, pixels, row * bytesPerRow);
    }
    _stagingBytes.add(packed);
    _uploads.add(_PendingUpload(texture, x, y, width, height, offset));
  }

  @override
  void releaseTexture(covariant VulkanTexture texture) {
    if (!texture.isValid) return;
    texture._invalidate();
    gpu.api
      ..destroyImageView(gpu.handle, texture.view, nullptr)
      ..destroyImage(gpu.handle, texture.image, nullptr);
    gpu.allocator.free(texture.memory);
  }

  /// Records every upload queued since the last frame into [commands].
  ///
  /// The barrier story, in full, for each texture touched:
  ///
  ///   `UNDEFINED` or `SHADER_READ_ONLY_OPTIMAL` -> `TRANSFER_DST_OPTIMAL`
  ///   -> copy -> `SHADER_READ_ONLY_OPTIMAL`
  ///
  /// Both transitions are needed and neither is decoration. Without the first,
  /// the copy writes to an image the driver may still be treating as
  /// shader-readable and the tiling is undefined; without the second, the
  /// fragment shader samples an image in a transfer layout, which is exactly
  /// the "correct picture, wrong texels" failure that has no error attached.
  bool _recordUploads(Pointer<VkCommandBuffer_T> commands) {
    if (_uploads.isEmpty) return true;
    final Uint8List bytes = _stagingBytes.takeBytes();
    if (!_ensureStaging(bytes.length)) return false;
    _staging!.mapped.asTypedList(bytes.length).setAll(0, bytes);
    gpu.allocator.flush(_staging!.memory);

    using((NativeArena arena) {
      final Pointer<VkBufferImageCopy> region = arena<VkBufferImageCopy>();
      for (final _PendingUpload upload in _uploads) {
        _imageBarrier(
          commands,
          upload.texture.image,
          oldLayout: upload.texture.layout,
          newLayout: VkImageLayout.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
          srcAccess: 0,
          dstAccess: VkAccessFlagBits.VK_ACCESS_TRANSFER_WRITE_BIT,
          srcStage: VkPipelineStageFlagBits.VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,
          dstStage: VkPipelineStageFlagBits.VK_PIPELINE_STAGE_TRANSFER_BIT,
        );

        region.ref
          ..bufferOffset = upload.stagingOffset
          ..bufferRowLength = 0
          ..bufferImageHeight = 0;
        region.ref.imageSubresource
          ..aspectMask = VkImageAspectFlagBits.VK_IMAGE_ASPECT_COLOR_BIT
          ..mipLevel = 0
          ..baseArrayLayer = 0
          ..layerCount = 1;
        region.ref.imageOffset
          ..x = upload.x
          ..y = upload.y
          ..z = 0;
        region.ref.imageExtent
          ..width = upload.width
          ..height = upload.height
          ..depth = 1;
        gpu.api.cmdCopyBufferToImage(
          commands,
          _staging!.handle,
          upload.texture.image,
          VkImageLayout.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
          1,
          region,
        );

        _imageBarrier(
          commands,
          upload.texture.image,
          oldLayout: VkImageLayout.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
          newLayout: VkImageLayout.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
          srcAccess: VkAccessFlagBits.VK_ACCESS_TRANSFER_WRITE_BIT,
          dstAccess: VkAccessFlagBits.VK_ACCESS_SHADER_READ_BIT,
          srcStage: VkPipelineStageFlagBits.VK_PIPELINE_STAGE_TRANSFER_BIT,
          dstStage:
              VkPipelineStageFlagBits.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
        );
        upload.texture.layout =
            VkImageLayout.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
      }
    });
    _uploads.clear();
    return true;
  }

  /// One image memory barrier, spelled out.
  void _imageBarrier(
    Pointer<VkCommandBuffer_T> commands,
    Pointer<VkImage_T> image, {
    required int oldLayout,
    required int newLayout,
    required int srcAccess,
    required int dstAccess,
    required int srcStage,
    required int dstStage,
  }) {
    using((NativeArena arena) {
      final Pointer<VkImageMemoryBarrier> barrier =
          arena<VkImageMemoryBarrier>();
      barrier.ref
        ..sType = VkStructureType.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER
        ..srcAccessMask = srcAccess
        ..dstAccessMask = dstAccess
        ..oldLayout = oldLayout
        ..newLayout = newLayout
        // No queue-family transfer: this backend has one queue, and naming a
        // family here instead of IGNORED is how an image ends up owned by a
        // queue that never gives it back.
        ..srcQueueFamilyIndex = vkQueueFamilyIgnored
        ..dstQueueFamilyIndex = vkQueueFamilyIgnored
        ..image = image;
      barrier.ref.subresourceRange
        ..aspectMask = VkImageAspectFlagBits.VK_IMAGE_ASPECT_COLOR_BIT
        ..baseMipLevel = 0
        ..levelCount = 1
        ..baseArrayLayer = 0
        ..layerCount = 1;
      gpu.api.cmdPipelineBarrier(
          commands, srcStage, dstStage, 0, 0, nullptr, 0, nullptr, 1, barrier);
    });
  }

  bool _ensureStaging(int bytes) {
    if (_staging != null && _staging!.size >= bytes) return true;
    _staging?.dispose(gpu);
    _staging = VulkanBuffer.create(
      gpu,
      resource: 'staging buffer',
      size: _grow(bytes),
      usage: VkBufferUsageFlagBits.VK_BUFFER_USAGE_TRANSFER_SRC_BIT,
      hostVisible: true,
    );
    return _staging != null;
  }

  bool _ensureVertexBuffers(int vertexBytes, int indexBytes) {
    if (_vertices == null || _vertices!.size < vertexBytes) {
      _vertices?.dispose(gpu);
      _vertices = VulkanBuffer.create(
        gpu,
        resource: 'vertex buffer',
        size: _grow(vertexBytes),
        usage: VkBufferUsageFlagBits.VK_BUFFER_USAGE_VERTEX_BUFFER_BIT,
        hostVisible: true,
      );
      if (_vertices == null) return false;
    }
    if (_indices == null || _indices!.size < indexBytes) {
      _indices?.dispose(gpu);
      _indices = VulkanBuffer.create(
        gpu,
        resource: 'index buffer',
        size: _grow(indexBytes),
        usage: VkBufferUsageFlagBits.VK_BUFFER_USAGE_INDEX_BUFFER_BIT,
        hostVisible: true,
      );
      if (_indices == null) return false;
    }
    return true;
  }

  /// Rounds up to a power of two, minimum 64 KiB.
  ///
  /// Growth in powers of two rather than to the exact size, because a buffer
  /// that is reallocated on every frame that adds one quad is a device
  /// allocation per frame - and the allocator's whole point is that there are
  /// almost none.
  static int _grow(int bytes) {
    var size = 64 * 1024;
    while (size < bytes) {
      size *= 2;
    }
    return size;
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    gpu.waitIdle();
    if (_defaultTexture != null) releaseTexture(_defaultTexture!);
    _vertices?.dispose(gpu);
    _indices?.dispose(gpu);
    _staging?.dispose(gpu);
    for (final VulkanPipelines pipelines in _pipelines.values) {
      pipelines.dispose(gpu);
    }
    _pipelines.clear();
    if (_descriptorPool != nullptr) {
      gpu.api.destroyDescriptorPool(gpu.handle, _descriptorPool, nullptr);
    }
    if (_nearest != nullptr) {
      gpu.api.destroySampler(gpu.handle, _nearest, nullptr);
    }
    if (_linear != nullptr) {
      gpu.api.destroySampler(gpu.handle, _linear, nullptr);
    }
    gpu.dispose();
    if (_ownsInstance) _instance.dispose();
  }

  /// The instance behind this device. For a test that reads its diagnostics.
  VulkanInstance get instance => _instance;
}

/// An offscreen target: a colour image, a framebuffer and a readback buffer.
final class VulkanOffscreenTarget implements RenderTarget {
  VulkanOffscreenTarget._(this._device, this._surface) {
    _createSurfaceObjects();
    _maskAtlas = GpuMaskAtlas();
    _maskTexture = _device.createTexture(
      width: _maskAtlas.width,
      height: _maskAtlas.height,
      format: GpuTextureFormat.alpha8,
    );
    _images = VulkanImageCache(_device);
    _sink = GpuRasterSink(
      batcher: _batcher,
      backendName: VulkanRenderDevice.backendName,
      maskAtlas: _maskAtlas,
      maskTextureId: _maskTexture.id,
      imageResolver: _images,
    );
    _player = DisplayListPlayer(_sink);
  }

  final VulkanRenderDevice _device;
  MemorySurfaceDescriptor _surface;

  final GpuBatcher _batcher = GpuBatcher();
  late final GpuMaskAtlas _maskAtlas;
  late final VulkanTexture _maskTexture;
  late final VulkanImageCache _images;
  late final GpuRasterSink _sink;
  late final DisplayListPlayer _player;

  late Framebuffer _readback;
  late VulkanTexture _color;
  Pointer<VkFramebuffer_T> _framebuffer = nullptr;
  VulkanBuffer? _readbackBuffer;

  int _generation = 0;
  int? _pendingClear;
  bool _disposed = false;

  /// True once the colour image holds something worth loading. Until then a
  /// frame that asks not to clear is still given the clearing render pass,
  /// because the alternative is a `loadOp` of LOAD on an image whose layout is
  /// still UNDEFINED - undefined contents, which on a tiler is whatever the
  /// last application left in that memory.
  bool _hasContent = false;

  @override
  NativeSurfaceDescriptor get surface => _surface;

  @override
  int get generation => _generation;

  @override
  bool get isDisposed => _disposed;

  /// The pixels of the last presented frame.
  Framebuffer get framebuffer => _readback;

  /// The image cache, for a test that counts uploads.
  VulkanImageCache get images => _images;

  GpuMaskAtlas get maskAtlas => _maskAtlas;

  int get batchCount => _batcher.batchCount;

  int get _vkFormat => _surface.format == PixelFormat.rgba8888Premultiplied
      ? VkFormat.VK_FORMAT_R8G8B8A8_UNORM
      : VkFormat.VK_FORMAT_B8G8R8A8_UNORM;

  @override
  Frame beginFrame(FrameRequest request) {
    _batcher.beginFrame();
    _maskAtlas.beginFrame();
    _pendingClear = request.clearColor;
    return Frame(
      target: this,
      framebuffer: _readback,
      damage: request.damage ??
          Rect.fromLTWH(
              0, 0, _readback.width.toDouble(), _readback.height.toDouble()),
      generation: _generation,
    );
  }

  /// Mirrors `GlOffscreenTarget.renderDisplayList` argument for argument, so a
  /// golden test can swap one for the other and compare.
  Future<PresentResult> renderDisplayList(
    DisplayList list, {
    int? clearColor,
    Transform2D deviceTransform = Transform2D.identity,
  }) async {
    final Frame frame = beginFrame(FrameRequest(clearColor: clearColor));
    _player.play(
      DisplayListReader(list),
      DisplayListResources(list),
      deviceBounds: Rect.fromLTWH(
        0,
        0,
        _readback.width.toDouble(),
        _readback.height.toDouble(),
      ),
      deviceTransform: deviceTransform,
    );
    return present(frame);
  }

  @override
  Future<PresentResult> present(Frame frame) async {
    if (_disposed) {
      return const PresentResult(
        status: PresentStatus.failed,
        diagnostic: BackendDiagnostic(
          kind: DiagnosticKind.rejectedByPolicy,
          message: 'this Vulkan target is disposed',
        ),
      );
    }
    if (frame.generation != _generation) {
      return const PresentResult(status: PresentStatus.stale);
    }
    if (_device.isLost) {
      return const PresentResult(
        status: PresentStatus.deviceLost,
        diagnostic: BackendDiagnostic(
          kind: DiagnosticKind.incompatibleDevice,
          message: 'the Vulkan device was lost before this frame presented',
        ),
      );
    }

    _uploadMaskAtlas();

    final Pointer<VkCommandBuffer_T>? commands = _device.gpu.beginFrame();
    if (commands == null) return _lost('beginFrame could not open a frame');
    if (!_device._recordUploads(commands)) {
      _device.gpu.abandonFrame();
      return _lost('an atlas upload could not be staged');
    }

    if (!_record(commands)) {
      _device.gpu.abandonFrame();
      return _lost('the frame could not be recorded');
    }
    if (!_device.gpu.endFrame()) return _lost('vkQueueSubmit refused');
    if (!_device.gpu.waitIdle()) return _lost('the frame never completed');

    _readPixels();
    _hasContent = true;
    return const PresentResult(status: PresentStatus.presented);
  }

  PresentResult _lost(String message) => PresentResult(
        status:
            _device.isLost ? PresentStatus.deviceLost : PresentStatus.failed,
        diagnostic: BackendDiagnostic(
          kind: DiagnosticKind.incompatibleDevice,
          message: message,
          detail: 'on ${_device.gpu.physicalDevice.name}',
        ),
      );

  bool _record(Pointer<VkCommandBuffer_T> commands) {
    final VulkanPipelines pipelines = _device.pipelinesFor(_vkFormat)!;
    final int? clear = _pendingClear;
    _pendingClear = null;
    final bool clears = clear != null || !_hasContent;

    // The vertex data. Written straight into host-visible memory; see the
    // library comment for why there is no staging copy here.
    final Float32List vertices = _batcher.buffer.vertices;
    final Uint32List indices = _batcher.buffer.indices;
    if (!_device._ensureVertexBuffers(vertices.lengthInBytes.clamp(4, 1 << 30),
        indices.lengthInBytes.clamp(4, 1 << 30))) {
      return false;
    }
    if (vertices.isNotEmpty) {
      _device._vertices!.mapped
          .cast<Float>()
          .asTypedList(vertices.length)
          .setAll(0, vertices);
      _device.gpu.allocator.flush(_device._vertices!.memory);
    }
    if (indices.isNotEmpty) {
      _device._indices!.mapped
          .cast<Uint32>()
          .asTypedList(indices.length)
          .setAll(0, indices);
      _device.gpu.allocator.flush(_device._indices!.memory);
    }

    return using((NativeArena arena) {
      final Pointer<VkClearValue> clearValue = arena<VkClearValue>();
      if (clears) {
        // The clear colour is premultiplied BGRA in an int, and the attachment
        // takes four floats in *shader* order - r, g, b, a - which the driver
        // maps onto the format's channels. Reading the int as BGRA and writing
        // it as RGBA here is what makes a `0xFF204060` request come back as
        // 0x20, 0x40, 0x60 in a bgra8888 framebuffer.
        final int packed = clear ?? 0;
        clearValue.ref.color.float32[0] = ((packed >> 16) & 0xFF) / 255.0;
        clearValue.ref.color.float32[1] = ((packed >> 8) & 0xFF) / 255.0;
        clearValue.ref.color.float32[2] = (packed & 0xFF) / 255.0;
        clearValue.ref.color.float32[3] = ((packed >> 24) & 0xFF) / 255.0;
      }

      final Pointer<VkRenderPassBeginInfo> begin =
          arena<VkRenderPassBeginInfo>();
      begin.ref
        ..sType = VkStructureType.VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO
        ..renderPass =
            clears ? pipelines.clearRenderPass : pipelines.loadRenderPass
        ..framebuffer = _framebuffer
        ..clearValueCount = clears ? 1 : 0
        ..pClearValues = clears ? clearValue : nullptr;
      begin.ref.renderArea.offset
        ..x = 0
        ..y = 0;
      begin.ref.renderArea.extent
        ..width = _readback.width
        ..height = _readback.height;

      _device.gpu.api.cmdBeginRenderPass(
          commands, begin, VkSubpassContents.VK_SUBPASS_CONTENTS_INLINE);

      final Pointer<VkViewport> viewport = arena<VkViewport>();
      viewport.ref
        ..x = 0
        ..y = 0
        ..width = _readback.width.toDouble()
        ..height = _readback.height.toDouble()
        ..minDepth = 0
        ..maxDepth = 1;
      _device.gpu.api.cmdSetViewport(commands, 0, 1, viewport);

      final Pointer<Float> push = arena<Float>(2);
      push[0] = _readback.width.toDouble();
      push[1] = _readback.height.toDouble();
      _device.gpu.api.cmdPushConstants(
        commands,
        pipelines.layout,
        VkShaderStageFlagBits.VK_SHADER_STAGE_VERTEX_BIT,
        0,
        kVulkanPushConstantBytes,
        push.cast<Void>(),
      );

      if (_batcher.batchCount > 0 && indices.isNotEmpty) {
        final Pointer<Pointer<VkBuffer_T>> vertexBuffers =
            arena<Pointer<VkBuffer_T>>();
        vertexBuffers.value = _device._vertices!.handle;
        final Pointer<Uint64> offsets = arena<Uint64>();
        offsets.value = 0;
        _device.gpu.api
          ..cmdBindVertexBuffers(commands, 0, 1, vertexBuffers, offsets)
          ..cmdBindIndexBuffer(commands, _device._indices!.handle, 0,
              VkIndexType.VK_INDEX_TYPE_UINT32);

        final Pointer<VkRect2D> scissor = arena<VkRect2D>();
        final Pointer<Pointer<VkDescriptorSet_T>> sets =
            arena<Pointer<VkDescriptorSet_T>>();

        for (final GpuBatch batch in _batcher.batches) {
          final VulkanTexture texture = _textureFor(batch.textureId);
          scissor.ref.offset
            ..x = batch.scissorLeft
            ..y = batch.scissorTop;
          scissor.ref.extent
            ..width = batch.scissorWidth < 0 ? 0 : batch.scissorWidth
            ..height = batch.scissorHeight < 0 ? 0 : batch.scissorHeight;
          sets.value = texture.descriptorSet;

          _device.gpu.api
            ..cmdBindPipeline(
              commands,
              VkPipelineBindPoint.VK_PIPELINE_BIND_POINT_GRAPHICS,
              pipelines.pipelineFor(batch.pipeline, batch.blendMode),
            )
            ..cmdBindDescriptorSets(
              commands,
              VkPipelineBindPoint.VK_PIPELINE_BIND_POINT_GRAPHICS,
              pipelines.layout,
              kVulkanTextureSet,
              1,
              sets,
              0,
              nullptr,
            )
            ..cmdSetScissor(commands, 0, 1, scissor)
            ..cmdDrawIndexed(
                commands, batch.indexCount, 1, batch.indexOffset, 0, 0);
        }
      }

      _device.gpu.api.cmdEndRenderPass(commands);

      // COLOR_ATTACHMENT_OPTIMAL -> TRANSFER_SRC_OPTIMAL, copy, and back. The
      // windowed counterpart of this pair is the transition to
      // PRESENT_SRC_KHR; an offscreen target reads its pixels instead of
      // handing them to a compositor, so TRANSFER_SRC is where they go.
      _device._imageBarrier(
        commands,
        _color.image,
        oldLayout: VkImageLayout.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
        newLayout: VkImageLayout.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
        srcAccess: VkAccessFlagBits.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
        dstAccess: VkAccessFlagBits.VK_ACCESS_TRANSFER_READ_BIT,
        srcStage: VkPipelineStageFlagBits
            .VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
        dstStage: VkPipelineStageFlagBits.VK_PIPELINE_STAGE_TRANSFER_BIT,
      );

      final Pointer<VkBufferImageCopy> copy = arena<VkBufferImageCopy>();
      copy.ref
        ..bufferOffset = 0
        ..bufferRowLength = 0
        ..bufferImageHeight = 0;
      copy.ref.imageSubresource
        ..aspectMask = VkImageAspectFlagBits.VK_IMAGE_ASPECT_COLOR_BIT
        ..mipLevel = 0
        ..baseArrayLayer = 0
        ..layerCount = 1;
      copy.ref.imageOffset
        ..x = 0
        ..y = 0
        ..z = 0;
      copy.ref.imageExtent
        ..width = _readback.width
        ..height = _readback.height
        ..depth = 1;
      _device.gpu.api.cmdCopyImageToBuffer(
        commands,
        _color.image,
        VkImageLayout.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
        _readbackBuffer!.handle,
        1,
        copy,
      );

      _device._imageBarrier(
        commands,
        _color.image,
        oldLayout: VkImageLayout.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
        newLayout: VkImageLayout.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
        srcAccess: VkAccessFlagBits.VK_ACCESS_TRANSFER_READ_BIT,
        dstAccess: VkAccessFlagBits.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
        srcStage: VkPipelineStageFlagBits.VK_PIPELINE_STAGE_TRANSFER_BIT,
        dstStage: VkPipelineStageFlagBits
            .VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
      );
      _color.layout = VkImageLayout.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;
      return true;
    });
  }

  VulkanTexture _textureFor(int id) {
    if (id == _maskTexture.id) return _maskTexture;
    for (final VulkanTexture texture in _images._textures) {
      if (texture.id == id) return texture;
    }
    return _device._defaultTexture!;
  }

  void _uploadMaskAtlas() {
    if (!_maskAtlas.isDirty) return;
    final int top = _maskAtlas.dirtyTop;
    final int height = _maskAtlas.dirtyBottom - top;
    if (height <= 0) return;
    _device.uploadRegion(
      _maskTexture,
      x: 0,
      y: top,
      width: _maskAtlas.width,
      height: height,
      pixels: Uint8List.sublistView(_maskAtlas.pixels, top * _maskAtlas.width),
      bytesPerRow: _maskAtlas.width,
    );
    _maskAtlas.markUploaded();
  }

  void _readPixels() {
    _device.gpu.allocator.invalidate(_readbackBuffer!.memory);
    final int bytes = _readback.pixels.length;
    _readback.pixels.setAll(0, _readbackBuffer!.mapped.asTypedList(bytes));
  }

  void _createSurfaceObjects() {
    _readback = Framebuffer.allocate(
      width: _surface.pixelWidth,
      height: _surface.pixelHeight,
      format: _surface.format,
    );
    _color = _device._createImageTexture(
      width: _surface.pixelWidth,
      height: _surface.pixelHeight,
      format: GpuTextureFormat.rgba8888Premultiplied,
      filter: GpuTextureFilter.nearest,
      vkFormat: _vkFormat,
      usage: VkImageUsageFlagBits.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT |
          VkImageUsageFlagBits.VK_IMAGE_USAGE_TRANSFER_SRC_BIT,
      sampled: false,
    );
    _readbackBuffer = VulkanBuffer.create(
      _device.gpu,
      resource: 'readback buffer',
      size: _readback.pixels.length,
      usage: VkBufferUsageFlagBits.VK_BUFFER_USAGE_TRANSFER_DST_BIT,
      hostVisible: true,
    );

    using((NativeArena arena) {
      final Pointer<Pointer<VkImageView_T>> attachments =
          arena<Pointer<VkImageView_T>>();
      attachments.value = _color.view;
      final Pointer<VkFramebufferCreateInfo> info =
          arena<VkFramebufferCreateInfo>();
      info.ref
        ..sType = VkStructureType.VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO
        ..renderPass = _device.pipelinesFor(_vkFormat)!.clearRenderPass
        ..attachmentCount = 1
        ..pAttachments = attachments
        ..width = _surface.pixelWidth
        ..height = _surface.pixelHeight
        ..layers = 1;
      final Pointer<Pointer<VkFramebuffer_T>> out =
          arena<Pointer<VkFramebuffer_T>>();
      if (vkFailed(_device.gpu.api
          .createFramebuffer(_device.gpu.handle, info, nullptr, out))) {
        throw UnsupportedCapabilityError(
          backendName: VulkanRenderDevice.backendName,
          capability: Capability.gpuPresentation,
          detail: 'vkCreateFramebuffer refused '
              '${_surface.pixelWidth}x${_surface.pixelHeight}',
        );
      }
      _framebuffer = out.value;
    });
    _hasContent = false;
  }

  void _destroySurfaceObjects() {
    if (_framebuffer != nullptr) {
      _device.gpu.api
          .destroyFramebuffer(_device.gpu.handle, _framebuffer, nullptr);
      _framebuffer = nullptr;
    }
    _readbackBuffer?.dispose(_device.gpu);
    _readbackBuffer = null;
    _device.releaseTexture(_color);
  }

  @override
  void resize(int pixelWidth, int pixelHeight, double scale) {
    if (pixelWidth == _surface.pixelWidth &&
        pixelHeight == _surface.pixelHeight &&
        scale == _surface.scale) {
      return;
    }
    _device.gpu.waitIdle();
    _destroySurfaceObjects();
    _surface = MemorySurfaceDescriptor(
      pixelWidth: pixelWidth,
      pixelHeight: pixelHeight,
      scale: scale,
      format: _surface.format,
    );
    _createSurfaceObjects();
    _generation++;
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _device.gpu.waitIdle();
    _images.dispose();
    _device.releaseTexture(_maskTexture);
    _destroySurfaceObjects();
  }
}

/// The Vulkan backend as a whole, on this machine.
final class VulkanRendererBackend implements RendererBackend {
  const VulkanRendererBackend({this.validation = false});

  /// Whether a device this backend opens enables the validation layer. Never
  /// inferred; see the policy in `vulkan_instance.dart`.
  final bool validation;

  static const String backendName = VulkanRenderDevice.backendName;

  @override
  RendererInfo get info => const RendererInfo(
        name: backendName,
        deviceDescription: 'Vulkan',
      );

  @override
  BackendProbeResult probe() {
    try {
      return _probe();
    } on Object catch (error, stack) {
      return BackendProbeResult.unsupported(
        backendName,
        BackendDiagnostic(
          kind: DiagnosticKind.unsupportedPlatform,
          message: 'the Vulkan probe threw, which is a bug in the probe',
          detail: '$error\n$stack',
        ),
      );
    }
  }

  BackendProbeResult _probe() {
    final VulkanLoadResult load = VulkanLibrary.open();
    final VulkanLibrary? library = load.library;
    if (library == null) {
      return BackendProbeResult(
        backendName: backendName,
        supported: false,
        diagnostics: load.diagnostics,
      );
    }
    final VulkanInstanceAttempt attempt = VulkanInstance.create(
      library,
      options: VulkanInstanceOptions(validation: validation),
    );
    final VulkanInstance? instance = attempt.instance;
    if (instance == null) {
      return BackendProbeResult(
        backendName: backendName,
        supported: false,
        diagnostics: attempt.diagnostics,
      );
    }
    try {
      final VulkanPhysicalDevice? physical = instance.chooseDevice();
      if (physical == null) {
        return BackendProbeResult(
          backendName: backendName,
          supported: false,
          diagnostics: <BackendDiagnostic>[
            ...attempt.diagnostics,
            const BackendDiagnostic(
              kind: DiagnosticKind.incompatibleDevice,
              message: 'no Vulkan physical device has a graphics queue',
            ),
          ],
        );
      }
      return BackendProbeResult(
        backendName: backendName,
        supported: true,
        capabilities: const <Capability>{Capability.gpuPresentation},
        diagnostics: <BackendDiagnostic>[
          ...attempt.diagnostics,
          BackendDiagnostic.note('Vulkan on "$physical"'),
          const BackendDiagnostic.note(
            'this backend draws solid rectangles, antialiased paths through a '
            'coverage-mask atlas and images, into memory. It has no swapchain, '
            'no glyph atlas and no layer stack, and refuses each by name',
          ),
        ],
      );
    } finally {
      instance.dispose();
    }
  }

  @override
  bool supportsSurface(NativeSurfaceDescriptor surface) =>
      surface is MemorySurfaceDescriptor;

  @override
  Future<RenderDevice> createDevice() async => VulkanRenderDevice.open(
        options: VulkanInstanceOptions(validation: validation),
      );
}
