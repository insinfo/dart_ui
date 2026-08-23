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
import '../gpu_path_planning.dart';
import '../gpu_path_strategy.dart';
import '../gpu_raster_sink.dart';
import '../gpu_texture.dart';
import '../vector/sparse_strip_draw_plan.dart';
import 'vulkan_constants.dart';
import 'vulkan_device.dart';
import 'vulkan_ffi.g.dart';
import 'vulkan_instance.dart';
import 'vulkan_library.dart';
import 'vulkan_memory.dart';
import 'vulkan_pipeline.dart';
import 'vulkan_shaders.dart';
import 'vulkan_sparse_driver.dart';
import 'vulkan_sparse_executor.dart';
import 'vulkan_surface_descriptor.dart';
import 'vulkan_swapchain.dart';
import 'vulkan_vector_path_recorder.dart';
import 'vulkan_wsi_bindings.dart';

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
  VulkanRenderDevice._(
    this._instance,
    this.gpu,
    this._ownsInstance, {
    required this.experimentalSparseStripsEnabled,
  });

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

  /// Whether this device was opened with the experimental sparse-strip path.
  ///
  /// The opt-in is a device-open flag rather than a per-frame one for the
  /// reason `gl_backend.dart` gives: the pipelines are built once and the
  /// established dense atlas has to stay the default even on hardware that
  /// would run sparse strips faster. A target on a device that answers false
  /// refuses [VulkanOffscreenTarget.enqueueSparseStrips] by name.
  final bool experimentalSparseStripsEnabled;

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

  /// The 1x1 opaque white texture, for a pipeline layout that declares a set
  /// the current shader does not sample.
  VulkanTexture? get defaultTexture => _defaultTexture;

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
        rasterizationApproach: RasterizationApproach.analyticCoverageAtlas,
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
    bool enableExperimentalSparseStrips = false,
    bool enablePresentation = false,
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
      return adoptInstance(
        instance,
        ownsInstance: true,
        enableExperimentalSparseStrips: enableExperimentalSparseStrips,
        enablePresentation: enablePresentation,
      );
    } on BackendSelectionError {
      instance.dispose();
      rethrow;
    }
  }

  /// Opens a device on an instance the caller already made.
  /// Opens a device on an instance the caller already made.
  ///
  /// [enablePresentation] adds `VK_KHR_swapchain` and picks a queue family that
  /// can present. It is opt-in because a device extension has to be named at
  /// `vkCreateDevice`, long before any window exists, and a headless runner
  /// that had it forced on would lose Vulkan entirely rather than render
  /// offscreen.
  ///
  /// **How the present family is chosen without a surface, and what that
  /// costs.** The honest way is to create the surface first and ask
  /// `vkGetPhysicalDeviceSurfaceSupportKHR` about each family - but the surface
  /// belongs to a window that does not exist yet when the device is opened. So:
  /// on Win32 this asks `vkGetPhysicalDeviceWin32PresentationSupportKHR`, which
  /// answers the same question about the *desktop* and needs no surface; on
  /// every other platform it takes the graphics family, which is right on every
  /// driver this has run on. Either way the answer is **verified** when a
  /// surface finally exists: `VulkanWindowTarget` asks the surface directly and
  /// refuses by name if the family it was given cannot present to it, rather
  /// than presenting on a queue the driver never agreed to.
  static VulkanRenderDevice adoptInstance(
    VulkanInstance instance, {
    bool ownsInstance = false,
    bool enableExperimentalSparseStrips = false,
    bool enablePresentation = false,
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
    final VulkanDeviceAttempt opened = VulkanDevice.open(
      physical,
      extensions: enablePresentation
          ? const <String>[vkKhrSwapchainExtension]
          : const <String>[],
      presentQueueFamily:
          enablePresentation ? _presentFamilyFor(physical) : null,
    );
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
    final VulkanRenderDevice device = VulkanRenderDevice._(
      instance,
      gpu,
      ownsInstance,
      experimentalSparseStripsEnabled: enableExperimentalSparseStrips,
    );
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

  /// A queue family that can present, guessed without a surface.
  ///
  /// See the note on [adoptInstance]. Null means "use the graphics family",
  /// which is what [VulkanDevice.open] does with it.
  static int? _presentFamilyFor(VulkanPhysicalDevice physical) {
    final VkGetWin32PresentationSupportDart? supported =
        physical.instance.surfaceApi?.getPhysicalDeviceWin32PresentationSupport;
    if (supported == null) return null;
    final int? graphics = physical.graphicsQueueFamily;
    if (graphics != null && supported(physical.handle, graphics) == vkTrue) {
      return graphics;
    }
    for (var family = 0; family < physical.queueFamilyFlags.length; family++) {
      if (supported(physical.handle, family) == vkTrue) return family;
    }
    // Nothing answered yes. Returning null keeps the graphics family, so the
    // device still opens and the refusal lands where it can name the surface.
    return null;
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
    if (surface is MemorySurfaceDescriptor) {
      return VulkanOffscreenTarget._(this, surface);
    }
    if (surface is VulkanWindowSurfaceDescriptor) {
      if (!gpu.canPresent) {
        throw UnsupportedCapabilityError(
          backendName: backendName,
          capability: Capability.gpuPresentation,
          detail: 'this Vulkan device was opened without $vkKhrSwapchainExtension; '
              'open it with enablePresentation: true to present to a window',
        );
      }
      return VulkanWindowTarget._(this, surface);
    }
    throw UnsupportedCapabilityError(
      backendName: backendName,
      capability: Capability.gpuPresentation,
      detail: 'this Vulkan backend presents to a memory surface or to a '
          'VulkanWindowSurfaceDescriptor; it was asked for a '
          '"${surface.kind}" surface',
    );
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
        recordImageBarrier(
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

        recordImageBarrier(
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

  /// One image memory barrier, spelled out: a layout transition for [image].
  ///
  /// Public because the experimental sparse-strip driver stages its own
  /// coverage pages and therefore has to transition them itself; see the
  /// staging discussion in `vulkan_sparse_driver.dart`. Nothing about the
  /// barrier differs between the two callers, and a second copy of it would be
  /// a second place for a stage or an access mask to be wrong.
  void recordImageBarrier(
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
/// The dense/vector interleave, shared by every Vulkan target.
///
/// Extracted rather than written twice, and the reason is on record: the two
/// bugs this walk has had - a staging cursor and an instance buffer that both
/// rewound on a second pass in one frame - were invisible until two promoted
/// draws landed together, and a second copy of this logic would be a second
/// place for them to come back. The offscreen target and the window target
/// differ in *what they render into*, which is the four values [record] takes,
/// and in nothing else.
///
/// It owns the experimental machinery too - the sparse driver, its executor,
/// the vector recorder and the planning telemetry - because their lifetimes are
/// exactly this object's and splitting them across the targets would mean two
/// places to remember a `beginFrameRecording`.
final class _VulkanOrderedRecorder {
  _VulkanOrderedRecorder({
    required VulkanRenderDevice device,
    required GpuBatcher batcher,
    required VulkanTexture Function(int textureId) textureFor,
  })  : _device = device,
        _batcher = batcher,
        _textureFor = textureFor {
    // The experimental vector route is wired only when the device was opened
    // with it. A production device leaves both fields null, the sink consults
    // neither, and the dense path is bit-for-bit the one that shipped.
    if (_device.experimentalSparseStripsEnabled) {
      final VulkanVectorPathRecorder recorder = VulkanVectorPathRecorder();
      vectorRecorder = recorder;
      planning = GpuPathPlanningTelemetry(
        // Per draw rather than per device, and both traits matter here:
        //
        //   * sparse coverage *is* analytic antialiasing, so it is a correct
        //     answer for an antialiased fill and the wrong picture for an
        //     aliased one;
        //   * a gradient has no resolved material on this route - the replay
        //     paint carries no LUT binding - and the recorder would refuse it
        //     at commit time, so saying so here keeps the selector from
        //     proposing a route that cannot be taken. The *shader* draws
        //     gradients; see `vulkan_vector_path_recorder.dart` for what is
        //     actually missing.
        capabilitiesProbe: (GpuPathDrawTraits traits) =>
            GpuPathStrategyCapabilities(
          sparseStrips: traits.antiAlias && !traits.hasGradient,
        ),
        sparseMetricsProbe: recorder.probeSparseMetrics,
      );
    }
  }

  final VulkanRenderDevice _device;
  final GpuBatcher _batcher;
  final VulkanTexture Function(int textureId) _textureFor;

  VulkanVectorPathRecorder? vectorRecorder;
  GpuPathPlanningTelemetry? planning;
  SparseVulkanExecutionStats? lastStats;

  VulkanApiSparseDriver? _driver;
  SparseVulkanExecutor? _executor;
  SparseStripDrawPlan? _pendingPlan;
  List<SparseVulkanMaterial>? _pendingMaterials;

  // Per-frame, set by [record] before anything is issued.
  Pointer<VkFramebuffer_T> _framebuffer = nullptr;
  int _width = 0;
  int _height = 0;
  int _colorFormat = 0;
  int? _pendingClear;
  bool _hasContent = false;

  /// SPIR-V words the sparse pipelines were built from, or zero.
  int get sparseShaderWords => _driver?.shaderWords ?? 0;

  /// Forgets the vector commands the previous frame promoted.
  ///
  /// Deliberately *not* the explicitly queued plan: a caller queues one with
  /// [enqueue] before opening the frame it belongs to - which is the order the
  /// Direct3D 12 seam established and the order every test uses - so clearing
  /// it here would throw away the submission the frame was opened for.
  void beginFrame() => vectorRecorder?.resetForFrame();

  /// Forgets everything a frame that will never be submitted had queued.
  void abandonFrame() {
    vectorRecorder?.resetForFrame();
    _pendingPlan = null;
    _pendingMaterials = null;
    _driver?.unbindCommandBuffer();
  }

  /// Queues one explicit sparse-strip submission for the next [record].
  void enqueue(
    SparseStripDrawPlan plan,
    List<SparseVulkanMaterial> materials,
  ) {
    if (!_device.experimentalSparseStripsEnabled) {
      throw StateError(
        'sparse strips are disabled; open the Vulkan device with '
        'enableExperimentalSparseStrips: true',
      );
    }
    _pendingPlan = plan;
    _pendingMaterials = List<SparseVulkanMaterial>.unmodifiable(materials);
  }

  /// Issues the frame into [framebuffer], and reports whether the attachment
  /// now holds something a later pass could load.
  ///
  /// [hasContent] is what the caller knows about the attachment *before* this
  /// frame: false means the first pass has to clear whatever the frame asked
  /// for, because loading an image whose layout is still `UNDEFINED` loads
  /// whatever the last application left in that memory.
  bool record(
    Pointer<VkCommandBuffer_T> commands, {
    required Pointer<VkFramebuffer_T> framebuffer,
    required int width,
    required int height,
    required int colorFormat,
    required int? clearColor,
    required bool hasContent,
  }) {
    _framebuffer = framebuffer;
    _width = width;
    _height = height;
    _colorFormat = colorFormat;
    _pendingClear = clearColor;
    _hasContent = hasContent;
    _recordOrdered(commands);
    _framebuffer = nullptr;
    return _hasContent;
  }

  void dispose() {
    _executor?.dispose();
    _executor = null;
    _driver?.dispose();
    _driver = null;
  }

  /// Forgets driver objects a lost device already took away.
  void discardNativeResources() {
    _executor?.disposeAfterDeviceLoss();
    _executor = null;
    _driver = null;
  }

  /// Issues everything recorded this frame, dense and vector, in display-list
  /// order.
  ///
  /// The whole point of the interleave: a vector command names the first dense
  /// batch that must run *after* it, so the dense range before that boundary is
  /// issued first, then the command, then the rest. Grouping all the dense work
  /// ahead of all the vector work would composite the frame in the wrong order,
  /// and on an opaque scene it would look almost right.
  ///
  /// On Vulkan a boundary costs a render pass, because a coverage upload cannot
  /// be recorded inside one - see `vulkan_sparse_driver.dart`. A frame with no
  /// promoted draw therefore records exactly one pass, which is what the
  /// production path has always recorded; the extra passes are paid only by a
  /// device that asked for the experimental route.
  void _recordOrdered(Pointer<VkCommandBuffer_T> commands) {
    // One frame, one staging cursor: several sparse passes may record copies
    // into this command buffer and every one of them has to keep its own bytes
    // until the queue runs them. See `vulkan_sparse_driver.dart`.
    _driver?.beginFrameRecording();
    final VulkanVectorPathRecorder? recorder = vectorRecorder;
    var cursor = 0;
    if (recorder != null) {
      for (var i = 0; i < recorder.commandCount; i++) {
        final VulkanSparsePathCommand command = recorder.commandAt(i);
        // Even when the range is empty this call is not: it performs the
        // frame's one clear, which has to happen before the first vector
        // command rather than after it.
        _recordDenseRange(commands, cursor, command.batchIndex);
        cursor = command.batchIndex;
        _submitSparse(
          commands,
          command.plan,
          <SparseVulkanMaterial>[command.material],
        );
      }
    }
    _recordDenseRange(commands, cursor, _batcher.batchCount);
    _recordEnqueuedSparse(commands);
  }

  /// One dense render pass over batches `[firstBatch, endBatch)`.
  ///
  /// The clear is a property of the *frame*, not of the range: `_pendingClear`
  /// is consumed by whichever range runs first and every later pass loads. A
  /// second clear would erase the vector command that ran between them.
  void _recordDenseRange(
    Pointer<VkCommandBuffer_T> commands,
    int firstBatch,
    int endBatch,
  ) {
    final VulkanPipelines pipelines = _device.pipelinesFor(_colorFormat)!;
    final int? clear = _pendingClear;
    _pendingClear = null;
    final bool clears = clear != null || !_hasContent;
    if (!clears && endBatch <= firstBatch) return;
    _hasContent = true;
    final Uint32List indices = _batcher.buffer.indices;

    using((NativeArena arena) {
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
        ..width = _width
        ..height = _height;

      _device.gpu.api.cmdBeginRenderPass(
          commands, begin, VkSubpassContents.VK_SUBPASS_CONTENTS_INLINE);

      final Pointer<VkViewport> viewport = arena<VkViewport>();
      viewport.ref
        ..x = 0
        ..y = 0
        ..width = _width.toDouble()
        ..height = _height.toDouble()
        ..minDepth = 0
        ..maxDepth = 1;
      _device.gpu.api.cmdSetViewport(commands, 0, 1, viewport);

      final Pointer<Float> push = arena<Float>(2);
      push[0] = _width.toDouble();
      push[1] = _height.toDouble();
      _device.gpu.api.cmdPushConstants(
        commands,
        pipelines.layout,
        VkShaderStageFlagBits.VK_SHADER_STAGE_VERTEX_BIT,
        0,
        kVulkanPushConstantBytes,
        push.cast<Void>(),
      );

      if (endBatch > firstBatch && indices.isNotEmpty) {
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

        for (var i = firstBatch; i < endBatch; i++) {
          final GpuBatch batch = _batcher.batchAt(i);
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
    });
  }

  /// Runs the submission queued by [enqueueSparseStrips], if there is one.
  ///
  /// The explicit seam runs *after* every dense batch and every promoted draw,
  /// because a caller handing over a whole plan is saying "draw this on top of
  /// the frame" and has no batch index to be ordered against.
  void _recordEnqueuedSparse(Pointer<VkCommandBuffer_T> commands) {
    final SparseStripDrawPlan? plan = _pendingPlan;
    final List<SparseVulkanMaterial>? materials = _pendingMaterials;
    _pendingPlan = null;
    _pendingMaterials = null;
    if (plan == null || materials == null) return;
    _submitSparse(commands, plan, materials);
  }

  /// One sparse pass, recorded into [commands].
  ///
  /// Called with no render pass open, because the driver records its coverage
  /// copies before opening a pass of its own and a copy cannot be recorded
  /// inside a render pass. See `vulkan_sparse_driver.dart`.
  void _submitSparse(
    Pointer<VkCommandBuffer_T> commands,
    SparseStripDrawPlan plan,
    List<SparseVulkanMaterial> materials,
  ) {
    final SparseVulkanExecutor executor = _ensureSparseExecutor();
    _driver!.bindCommandBuffer(
      commands,
      framebuffer: _framebuffer,
      width: _width,
      height: _height,
    );
    try {
      lastStats = executor.submit(
        plan,
        materials: materials,
        viewportWidth: _width,
        viewportHeight: _height,
      );
      // The attachment now holds something worth loading, so a later dense
      // range in this frame must not clear over it.
      _hasContent = true;
    } finally {
      _driver!.unbindCommandBuffer();
    }
  }

  SparseVulkanExecutor _ensureSparseExecutor() {
    final SparseVulkanExecutor? existing = _executor;
    if (existing != null) return existing;
    final VulkanApiSparseDriver driver =
        VulkanApiSparseDriver(_device, colorFormat: _colorFormat);
    final SparseVulkanExecutor executor =
        SparseVulkanExecutor(driver, textureAllocator: _device);
    executor.initialize();
    _driver = driver;
    _executor = executor;
    // The driver is built lazily, so the frame that builds it is a frame whose
    // `_recordOrdered` already ran past the reset. Doing it here keeps the
    // cursor's invariant true from the first pass onwards.
    driver.beginFrameRecording();
    return executor;
  }
}

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
    _recorder = _VulkanOrderedRecorder(
      device: _device,
      batcher: _batcher,
      textureFor: _textureFor,
    );
    _sink = GpuRasterSink(
      batcher: _batcher,
      backendName: VulkanRenderDevice.backendName,
      maskAtlas: _maskAtlas,
      maskTextureId: _maskTexture.id,
      imageResolver: _images,
      pathPlanningTelemetry: _recorder.planning,
      pathCommandRecorder: _recorder.vectorRecorder,
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

  late final _VulkanOrderedRecorder _recorder;

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

  /// What the last sparse-strip submission actually sent, or null.
  SparseVulkanExecutionStats? get lastSparseStats => _recorder.lastStats;

  /// The selector telemetry, or null on a device without the opt-in.
  GpuPathPlanningTelemetry? get pathPlanning => _recorder.planning;

  /// The vector recorder, or null on a device without the opt-in.
  VulkanVectorPathRecorder? get vectorRecorder => _recorder.vectorRecorder;

  /// How many SPIR-V words the sparse pipelines were built from, or zero if
  /// they have not been built.
  int get sparseShaderWords => _recorder.sparseShaderWords;

  /// Queues one experimental sparse-strip submission for the next [present].
  ///
  /// Queued rather than executed, because the pass has to land *after* the
  /// dense batches of the same frame and *before* the readback - see
  /// `_recordSparse`. The refusal when the device was not opened for it
  /// happens here, at the moment the caller can still do something else,
  /// rather than at present: nothing has been encoded, nothing has been
  /// uploaded and no device state has moved, so a caller that catches this is
  /// looking at exactly the frame it had, and the dense path draws it.
  void enqueueSparseStrips(
    SparseStripDrawPlan plan, {
    required List<SparseVulkanMaterial> materials,
  }) {
    if (_disposed) throw StateError('this Vulkan target is disposed');
    _recorder.enqueue(plan, materials);
  }

  int get _vkFormat => _surface.format == PixelFormat.rgba8888Premultiplied
      ? VkFormat.VK_FORMAT_R8G8B8A8_UNORM
      : VkFormat.VK_FORMAT_B8G8R8A8_UNORM;

  @override
  Frame beginFrame(FrameRequest request) {
    _batcher.beginFrame();
    _maskAtlas.beginFrame();
    _recorder.beginFrame();
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

    try {
      if (!_record(commands)) {
        _device.gpu.abandonFrame();
        return _lost('the frame could not be recorded');
      }
    } on Object {
      // A sparse submission that refuses throws out of here. The frame is
      // abandoned before the error escapes so the device is not left holding
      // an open command buffer, and the caller sees the original reason.
      _device.gpu.abandonFrame();
      _recorder.abandonFrame();
      rethrow;
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

    final int? clear = _pendingClear;
    _pendingClear = null;
    _hasContent = _recorder.record(
      commands,
      framebuffer: _framebuffer,
      width: _readback.width,
      height: _readback.height,
      colorFormat: _vkFormat,
      clearColor: clear,
      hasContent: _hasContent,
    );

    return using((NativeArena arena) {
      // COLOR_ATTACHMENT_OPTIMAL -> TRANSFER_SRC_OPTIMAL, copy, and back. The
      // windowed counterpart of this pair is the transition to
      // PRESENT_SRC_KHR; an offscreen target reads its pixels instead of
      // handing them to a compositor, so TRANSFER_SRC is where they go.
      _device.recordImageBarrier(
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

      _device.recordImageBarrier(
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
    _recorder.dispose();
    _images.dispose();
    _device.releaseTexture(_maskTexture);
    _destroySurfaceObjects();
  }
}

/// A `RenderTarget` that presents into a window through a swapchain.
///
/// The twin of [VulkanOffscreenTarget], and everything the two share -
/// the mask atlas, the sink, the player, and the ordered dense/vector walk -
/// really is shared: `_VulkanOrderedRecorder` is the same object doing the same
/// thing, given a different framebuffer. What is here and not there is the part
/// a window forces:
///
///   * **the images are borrowed.** `vkAcquireNextImageKHR` hands one over
///     asynchronously and signals a semaphore when it is safe to render into;
///     the submission waits on that semaphore at `COLOR_ATTACHMENT_OUTPUT`, and
///     `vkQueuePresentKHR` waits on a second semaphore the submission signals.
///     Neither wait is optional and neither can be a fence: a fence is a
///     host-side wait, and the whole point is that the host does not wait.
///   * **the render-finished semaphore is per image, not per frame in
///     flight.** This is the classic Vulkan bug and it is worth naming: a
///     semaphore signalled for a present is not known to be free when the
///     *submission* that signalled it retires, because the present is still
///     queued behind it. One per image is safe because the presentation engine
///     will not hand an image back before its present has completed, so the
///     semaphore is idle by the time it is signalled again. One per frame slot
///     is not, and the difference is invisible until the compositor is slow.
///   * **the swapchain is rebuilt, not resized.** A `VkSwapchainKHR` has no
///     resize. `VK_ERROR_OUT_OF_DATE_KHR` and `VK_SUBOPTIMAL_KHR` from either
///     acquire or present, and [resize] itself, all land in
///     [_recreateSwapchain], which waits for the device to go idle, builds a
///     new chain with the old one as `oldSwapchain`, and only then destroys the
///     old one - the order the specification requires.
///
/// ## Readback, and why it is off by default
///
/// [captureFrames] copies each presented image into [framebuffer] so a test can
/// compare a *window* against the CPU rasteriser. It costs a full pipeline
/// drain and a surface-sized copy per frame, so it is off unless asked for, and
/// it is unavailable when the surface does not allow `TRANSFER_SRC` usage on
/// its images - which nothing guarantees. [canCaptureFrames] says which.
final class VulkanWindowTarget implements DisplayListRenderTarget {
  VulkanWindowTarget._(this._device, this._surface) {
    _maskAtlas = GpuMaskAtlas();
    _maskTexture = _device.createTexture(
      width: _maskAtlas.width,
      height: _maskAtlas.height,
      format: GpuTextureFormat.alpha8,
    );
    _images = VulkanImageCache(_device);
    _recorder = _VulkanOrderedRecorder(
      device: _device,
      batcher: _batcher,
      textureFor: _textureFor,
    );
    _sink = GpuRasterSink(
      batcher: _batcher,
      backendName: VulkanRenderDevice.backendName,
      maskAtlas: _maskAtlas,
      maskTextureId: _maskTexture.id,
      imageResolver: _images,
      pathPlanningTelemetry: _recorder.planning,
      pathCommandRecorder: _recorder.vectorRecorder,
    );
    _player = DisplayListPlayer(_sink);
    for (var i = 0; i < _device.gpu.framesInFlight; i++) {
      _imageAvailable.add(_device.gpu.createSemaphore());
    }
    _createSurfaceObjects();
  }

  final VulkanRenderDevice _device;
  VulkanWindowSurfaceDescriptor _surface;

  final GpuBatcher _batcher = GpuBatcher();
  late final GpuMaskAtlas _maskAtlas;
  late final VulkanTexture _maskTexture;
  late final VulkanImageCache _images;
  late final GpuRasterSink _sink;
  late final DisplayListPlayer _player;
  late final _VulkanOrderedRecorder _recorder;

  VulkanSurface? _vkSurface;
  VulkanSwapchain? _swapchain;
  BackendDiagnostic? _creationFailure;

  /// One per frame in flight: waited by the submission that renders into the
  /// image it was signalled for.
  final List<Pointer<VkSemaphore_T>> _imageAvailable =
      <Pointer<VkSemaphore_T>>[];

  /// One per swapchain image. See the library comment for why not per frame.
  final List<Pointer<VkSemaphore_T>> _renderFinished =
      <Pointer<VkSemaphore_T>>[];

  Framebuffer? _readback;
  VulkanBuffer? _readbackBuffer;

  int _generation = 0;
  int? _pendingClear;
  bool _disposed = false;
  bool _needsRecreation = false;

  /// Whether each presented image is copied back into [framebuffer].
  bool captureFrames = false;

  @override
  NativeSurfaceDescriptor get surface => _surface;

  @override
  int get generation => _generation;

  @override
  bool get isDisposed => _disposed;

  /// Why the swapchain could not be built, or null.
  BackendDiagnostic? get creationFailure => _creationFailure;

  /// Whether a frame can actually be shown right now.
  bool get isPresentable => _swapchain != null && !_device.isLost;

  /// What the surface and the two policies settled on.
  VulkanSwapchainConfiguration? get configuration => _swapchain?.configuration;

  int get imageCount => _swapchain?.imageCount ?? 0;

  /// Whether [captureFrames] can do anything on this surface.
  bool get canCaptureFrames =>
      _swapchain?.configuration.supportsTransferSource ?? false;

  /// The pixels of the last presented frame, or null when [captureFrames] has
  /// never been on.
  Framebuffer? get framebuffer => _readback;

  VulkanImageCache get images => _images;

  GpuMaskAtlas get maskAtlas => _maskAtlas;

  int get batchCount => _batcher.batchCount;

  SparseVulkanExecutionStats? get lastSparseStats => _recorder.lastStats;

  GpuPathPlanningTelemetry? get pathPlanning => _recorder.planning;

  VulkanVectorPathRecorder? get vectorRecorder => _recorder.vectorRecorder;

  int get sparseShaderWords => _recorder.sparseShaderWords;

  /// Queues one experimental sparse-strip submission for the next [present].
  void enqueueSparseStrips(
    SparseStripDrawPlan plan, {
    required List<SparseVulkanMaterial> materials,
  }) {
    if (_disposed) throw StateError('this Vulkan window target is disposed');
    _recorder.enqueue(plan, materials);
  }

  @override
  Frame beginFrame(FrameRequest request) {
    _batcher.beginFrame();
    _maskAtlas.beginFrame();
    _recorder.beginFrame();
    _pendingClear = request.clearColor;
    final int width = _swapchain?.configuration.width ?? _surface.pixelWidth;
    final int height = _swapchain?.configuration.height ?? _surface.pixelHeight;
    return Frame(
      target: this,
      framebuffer: _readback,
      damage: request.damage ??
          Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
      generation: _generation,
    );
  }

  @override
  Future<PresentResult> renderDisplayList(
    DisplayList list, {
    int? clearColor,
    Transform2D deviceTransform = Transform2D.identity,
  }) async {
    final Frame frame = beginFrame(FrameRequest(clearColor: clearColor));
    final int width = _swapchain?.configuration.width ?? _surface.pixelWidth;
    final int height = _swapchain?.configuration.height ?? _surface.pixelHeight;
    _player.play(
      DisplayListReader(list),
      DisplayListResources(list),
      deviceBounds: Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
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
          message: 'this Vulkan window target is disposed',
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
    if (_needsRecreation) _recreateSwapchain();
    final VulkanSwapchain? chain = _swapchain;
    if (chain == null) {
      return PresentResult(
        status: PresentStatus.failed,
        diagnostic: _creationFailure ??
            const BackendDiagnostic(
              kind: DiagnosticKind.incompatibleDevice,
              message: 'this window has no Vulkan swapchain',
            ),
      );
    }

    _uploadMaskAtlas();

    final Pointer<VkCommandBuffer_T>? commands = _device.gpu.beginFrame();
    if (commands == null) return _lost('beginFrame could not open a frame');

    // Acquired *after* the frame slot's fence has been waited on, which is what
    // makes this slot's image-available semaphore free to signal again.
    final int slot = _device.gpu.frameIndex;
    final VulkanAcquiredImage acquired =
        chain.acquire(_device.gpu, semaphore: _imageAvailable[slot]);
    if (!acquired.acquired) {
      _device.gpu.abandonFrame();
      _recorder.abandonFrame();
      if (acquired.result == VkResult.VK_ERROR_OUT_OF_DATE_KHR) {
        // The window moved or resized between the last present and this one.
        // Rebuilding and reporting stale is the honest answer: the frame that
        // was recorded belongs to a surface that no longer exists.
        _recreateSwapchain();
        return const PresentResult(status: PresentStatus.stale);
      }
      return _lost('vkAcquireNextImageKHR answered '
          '${vkResultName(acquired.result)}');
    }

    final int image = acquired.imageIndex;
    if (!_device._recordUploads(commands)) {
      _device.gpu.abandonFrame();
      _recorder.abandonFrame();
      return _lost('an atlas upload could not be staged');
    }

    try {
      _record(commands, chain, image);
    } on Object {
      _device.gpu.abandonFrame();
      _recorder.abandonFrame();
      rethrow;
    }

    if (!_device.gpu.endFrame(
      waitSemaphores: <Pointer<VkSemaphore_T>>[_imageAvailable[slot]],
      waitStages: <int>[
        VkPipelineStageFlagBits.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
      ],
      signalSemaphores: <Pointer<VkSemaphore_T>>[_renderFinished[image]],
    )) {
      return _lost('vkQueueSubmit refused');
    }

    final int presented = chain.present(
      _device.gpu,
      semaphore: _renderFinished[image],
      imageIndex: image,
    );
    chain.markPresentable(image);

    if (captureFrames && canCaptureFrames) {
      // The one blocking wait this target has, and it exists only for a test:
      // the bytes are read on the CPU on the next line.
      if (!_device.gpu.waitIdle()) return _lost('the frame never completed');
      _readPixels();
    }

    if (presented == VkResult.VK_ERROR_OUT_OF_DATE_KHR ||
        presented == VkResult.VK_SUBOPTIMAL_KHR ||
        acquired.result == VkResult.VK_SUBOPTIMAL_KHR) {
      // Suboptimal is not a failure: the frame was shown. It means the next one
      // should be drawn into a chain built for the surface as it is now, so the
      // rebuild is deferred to the next present rather than done under a frame
      // whose semaphores are still in flight.
      _needsRecreation = true;
    } else if (vkFailed(presented)) {
      return _lost('vkQueuePresentKHR answered ${vkResultName(presented)}');
    }
    return const PresentResult(status: PresentStatus.presented);
  }

  PresentResult _lost(String message) => PresentResult(
        status:
            _device.isLost ? PresentStatus.deviceLost : PresentStatus.failed,
        diagnostic: BackendDiagnostic(
          kind: DiagnosticKind.incompatibleDevice,
          message: message,
          detail: 'on ${_device.gpu.physicalDevice.name}, $_surface',
        ),
      );

  void _record(
    Pointer<VkCommandBuffer_T> commands,
    VulkanSwapchain chain,
    int image,
  ) {
    final int? clear = _pendingClear;
    _pendingClear = null;
    final VulkanSwapchainConfiguration config = chain.configuration;

    final Float32List vertices = _batcher.buffer.vertices;
    final Uint32List indices = _batcher.buffer.indices;
    if (!_device._ensureVertexBuffers(vertices.lengthInBytes.clamp(4, 1 << 30),
        indices.lengthInBytes.clamp(4, 1 << 30))) {
      throw StateError('the Vulkan geometry buffers could not be allocated');
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

    // A frame that does not clear loads what this image already holds, and a
    // load render pass declares `initialLayout = COLOR_ATTACHMENT_OPTIMAL`
    // while a presented image sits in `PRESENT_SRC_KHR`. The clearing pass
    // needs no such transition: its `initialLayout` is UNDEFINED, which is
    // legal from any layout and says the contents are about to be overwritten.
    final bool loads = clear == null && chain.isPresentable(image);
    if (loads) {
      _device.recordImageBarrier(
        commands,
        chain.imageAt(image),
        oldLayout: VkImageLayout.VK_IMAGE_LAYOUT_PRESENT_SRC_KHR,
        newLayout: VkImageLayout.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
        srcAccess: 0,
        dstAccess: VkAccessFlagBits.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT |
            VkAccessFlagBits.VK_ACCESS_COLOR_ATTACHMENT_READ_BIT,
        srcStage: VkPipelineStageFlagBits
            .VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
        dstStage: VkPipelineStageFlagBits
            .VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
      );
    }

    _recorder.record(
      commands,
      framebuffer: chain.framebufferAt(image),
      width: config.width,
      height: config.height,
      colorFormat: config.format,
      clearColor: clear,
      hasContent: loads,
    );

    final bool captures = captureFrames && canCaptureFrames;
    if (captures) {
      _ensureReadback(config);
      _device.recordImageBarrier(
        commands,
        chain.imageAt(image),
        oldLayout: VkImageLayout.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
        newLayout: VkImageLayout.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
        srcAccess: VkAccessFlagBits.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
        dstAccess: VkAccessFlagBits.VK_ACCESS_TRANSFER_READ_BIT,
        srcStage: VkPipelineStageFlagBits
            .VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
        dstStage: VkPipelineStageFlagBits.VK_PIPELINE_STAGE_TRANSFER_BIT,
      );
      using((NativeArena arena) {
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
          ..width = config.width
          ..height = config.height
          ..depth = 1;
        _device.gpu.api.cmdCopyImageToBuffer(
          commands,
          chain.imageAt(image),
          VkImageLayout.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
          _readbackBuffer!.handle,
          1,
          copy,
        );
      });
    }

    // The last transition of the frame, and the one that makes it showable.
    // The windowed counterpart of the offscreen target's transfer-source
    // transition: an offscreen image is read, a window image is presented.
    _device.recordImageBarrier(
      commands,
      chain.imageAt(image),
      oldLayout: captures
          ? VkImageLayout.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL
          : VkImageLayout.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
      newLayout: VkImageLayout.VK_IMAGE_LAYOUT_PRESENT_SRC_KHR,
      srcAccess: captures
          ? VkAccessFlagBits.VK_ACCESS_TRANSFER_READ_BIT
          : VkAccessFlagBits.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
      // Nothing: the presentation engine's read is synchronised by the
      // semaphore `vkQueuePresentKHR` waits on, not by an access mask.
      dstAccess: 0,
      srcStage: captures
          ? VkPipelineStageFlagBits.VK_PIPELINE_STAGE_TRANSFER_BIT
          : VkPipelineStageFlagBits
              .VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
      dstStage: VkPipelineStageFlagBits.VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT,
    );
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

  VulkanTexture _textureFor(int id) {
    if (id == _maskTexture.id) return _maskTexture;
    for (final VulkanTexture texture in _images._textures) {
      if (texture.id == id) return texture;
    }
    return _device._defaultTexture!;
  }

  void _ensureReadback(VulkanSwapchainConfiguration config) {
    final PixelFormat format =
        config.pixelFormat ?? PixelFormat.bgra8888Premultiplied;
    final Framebuffer? existing = _readback;
    if (existing != null &&
        existing.width == config.width &&
        existing.height == config.height &&
        existing.format == format) {
      return;
    }
    _readback = Framebuffer.allocate(
      width: config.width,
      height: config.height,
      format: format,
    );
    _readbackBuffer?.dispose(_device.gpu);
    _readbackBuffer = VulkanBuffer.create(
      _device.gpu,
      resource: 'window readback buffer',
      size: _readback!.pixels.length,
      usage: VkBufferUsageFlagBits.VK_BUFFER_USAGE_TRANSFER_DST_BIT,
      hostVisible: true,
    );
    if (_readbackBuffer == null) {
      throw StateError('the window readback buffer could not be allocated');
    }
  }

  void _readPixels() {
    final VulkanBuffer? buffer = _readbackBuffer;
    final Framebuffer? readback = _readback;
    if (buffer == null || readback == null) return;
    _device.gpu.allocator.invalidate(buffer.memory);
    readback.pixels
        .setAll(0, buffer.mapped.asTypedList(readback.pixels.length));
  }

  void _createSurfaceObjects() {
    _creationFailure = null;
    final VulkanSurfaceAttempt attempt =
        VulkanSurface.create(_device.gpu.physicalDevice.instance, _surface);
    final VulkanSurface? created = attempt.surface;
    if (created == null) {
      _creationFailure = attempt.diagnostics
          .where((BackendDiagnostic d) => d.isFailure)
          .firstOrNull;
      return;
    }
    _vkSurface = created;

    // The guess made at device-open time, verified now that a surface exists.
    // See `VulkanRenderDevice.adoptInstance`.
    if (!created.supportsPresentOn(
        _device.gpu.physicalDevice, _device.gpu.presentQueueFamily)) {
      _creationFailure = BackendDiagnostic(
        kind: DiagnosticKind.incompatibleDevice,
        message: 'queue family ${_device.gpu.presentQueueFamily} cannot '
            'present to this surface',
        detail: 'the device was opened before the window existed and chose '
            'that family; a device whose presenting family differs has to be '
            'reopened once the surface is known',
      );
      created.dispose();
      _vkSurface = null;
      return;
    }
    _buildSwapchain();
  }

  void _buildSwapchain({Pointer<VkSwapchainKHR_T>? oldSwapchain}) {
    final VulkanSurface? surface = _vkSurface;
    if (surface == null) return;
    final VulkanPhysicalDevice physical = _device.gpu.physicalDevice;
    final VulkanSurfaceCapabilities? capabilities =
        surface.capabilitiesOn(physical);
    if (capabilities == null) {
      _creationFailure = const BackendDiagnostic(
        kind: DiagnosticKind.connectionFailed,
        message: 'vkGetPhysicalDeviceSurfaceCapabilitiesKHR refused',
      );
      return;
    }
    final VulkanSwapchainConfiguration? config =
        VulkanSurfaceConfiguration.choose(
      capabilities: capabilities,
      formats: surface.formatsOn(physical),
      presentModes: surface.presentModesOn(physical),
      descriptor: _surface,
    );
    if (config == null) {
      _creationFailure = const BackendDiagnostic(
        kind: DiagnosticKind.incompatibleDevice,
        message: 'this surface reports no format a swapchain can be made of',
      );
      return;
    }
    if (config.isEmpty) {
      // A minimised window: zero by zero is not an error and not a swapchain
      // either. Leaving `_swapchain` null makes every present report failure
      // by name until the window comes back, and `resize` rebuilds then.
      _creationFailure = BackendDiagnostic(
        kind: DiagnosticKind.rejectedByPolicy,
        message: 'the window has no area (${config.width}x${config.height}); '
            'no swapchain is created until it does',
      );
      return;
    }

    final VulkanPipelines? pipelines = _device.pipelinesFor(config.format);
    if (pipelines == null) {
      _creationFailure = BackendDiagnostic(
        kind: DiagnosticKind.incompatibleDevice,
        message: 'no graphics pipeline could be built for '
            '${vkFormatName(config.format)}',
      );
      return;
    }

    final VulkanSwapchain? chain = VulkanSwapchain.create(
      _device.gpu,
      surface,
      configuration: config,
      // The clearing pass, because render-pass compatibility looks only at the
      // attachments' formats and sample counts - so one framebuffer works with
      // both passes and there is no second set to build.
      renderPass: pipelines.clearRenderPass,
      oldSwapchain: oldSwapchain,
    );
    if (chain == null) {
      _creationFailure = BackendDiagnostic(
        kind: DiagnosticKind.incompatibleDevice,
        message: 'vkCreateSwapchainKHR refused $config',
      );
      return;
    }
    _swapchain = chain;
    _creationFailure = null;
    _needsRecreation = false;

    for (final Pointer<VkSemaphore_T> semaphore in _renderFinished) {
      _device.gpu.destroySemaphore(semaphore);
    }
    _renderFinished
      ..clear()
      ..addAll(<Pointer<VkSemaphore_T>>[
        for (var i = 0; i < chain.imageCount; i++)
          _device.gpu.createSemaphore(),
      ]);
  }

  /// Rebuilds the chain for the surface as it is now.
  ///
  /// Waits for the device first, because the images and their framebuffers are
  /// still referenced by whatever is in flight, and destroying an image view a
  /// queued command buffer names is undefined rather than merely early.
  void _recreateSwapchain() {
    _needsRecreation = false;
    if (_vkSurface == null) return;
    _device.gpu.waitIdle();
    final VulkanSwapchain? old = _swapchain;
    _swapchain = null;
    _buildSwapchain(oldSwapchain: old?.handle);
    // After the new chain exists, never before: `oldSwapchain` is what lets the
    // presentation engine keep showing the old images until the new ones are
    // ready, and destroying it first throws that away.
    old?.dispose(_device.gpu);
  }

  @override
  void resize(int pixelWidth, int pixelHeight, double scale) {
    if (_disposed) throw StateError('this Vulkan window target is disposed');
    if (pixelWidth == _surface.pixelWidth &&
        pixelHeight == _surface.pixelHeight &&
        scale == _surface.scale) {
      return;
    }
    _surface = _surface.resized(
      pixelWidth: pixelWidth,
      pixelHeight: pixelHeight,
      scale: scale,
    );
    _recreateSwapchain();
    _generation++;
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _device.gpu.waitIdle();
    _recorder.dispose();
    _images.dispose();
    _device.releaseTexture(_maskTexture);
    for (final Pointer<VkSemaphore_T> semaphore in _renderFinished) {
      _device.gpu.destroySemaphore(semaphore);
    }
    _renderFinished.clear();
    for (final Pointer<VkSemaphore_T> semaphore in _imageAvailable) {
      _device.gpu.destroySemaphore(semaphore);
    }
    _imageAvailable.clear();
    _swapchain?.dispose(_device.gpu);
    _swapchain = null;
    _readbackBuffer?.dispose(_device.gpu);
    _readbackBuffer = null;
    _vkSurface?.dispose();
    _vkSurface = null;
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
        rasterizationApproach: RasterizationApproach.analyticCoverageAtlas,
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
