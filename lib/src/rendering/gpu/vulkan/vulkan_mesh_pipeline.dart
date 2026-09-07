/// The Vulkan mesh pipeline: triangles, a depth attachment and two hand-written
/// SPIR-V modules.
///
/// `rendering/mesh/mesh_scene.dart` holds the contract,
/// `rendering/gpu/d3d11/d3d11_mesh_pipeline.dart` is the implementation this
/// one is shaped after, and `vulkan_mesh_shaders.dart` holds the shading and
/// the four ways Vulkan's spelling of it differs. None of those three is
/// repeated. What is here is what *Vulkan* makes different about the pipeline,
/// and every one of them is a way this file could be wrong while the two
/// Direct3D ports are right.
///
/// ## 1. A frame is recorded inside `present`, so a mesh pass is enqueued
///
/// Direct3D 11 submits the moment `drawScene` is called and Direct3D 12
/// records onto the list the target opened in `beginFrame`. Vulkan does
/// neither: `VulkanWindowTarget.present` is where the command buffer is opened
/// **and** where the swapchain image is acquired, so between `beginFrame` and
/// `present` there is no command buffer and no image to draw into. A
/// `drawScene` that tried to record there would have nothing to record onto.
///
/// So [drawScene] **enqueues** a pass on the target and returns; the target
/// runs it inside its own `_record`, before the display list's batches, and
/// hands it the command buffer, the colour view and the size. That is the seam
/// `enqueueSparseStrips` already established in this backend, generalised so
/// that nothing in `vulkan_backend.dart` names a mesh: [VulkanAttachmentPass]
/// is a function of a command buffer and a [VulkanAttachmentSurface], and a
/// mesh renderer happens to be one implementation of it.
///
/// The consequence for [MeshRenderStats.microseconds] is stated where it is
/// filled in: it measures the **geometry preparation and upload**, which is
/// all of this pipeline's per-frame CPU work, because the Vulkan vertex buffers
/// are host-visible and written on the spot. The command recording that
/// follows at present time is a few hundred calls and is not counted.
///
/// A caller that asks a [FrameRequest] for a clear colour *and* enqueues a mesh
/// pass gets the model wiped, because the display list clears after the pass.
/// That is a contradiction in the request rather than a bug: a caller drawing
/// an interface over a model passes no clear colour and lets
/// [MeshScene.backgroundArgb] do the clearing.
///
/// ## 2. The render pass is this file's own, and so is the framebuffer
///
/// A `VkRenderPass` fixes the attachment list, and the nine 2D pipelines are
/// compiled against a pass with **one** attachment. Adding a depth attachment
/// to that pass would make every one of them incompatible with it, so this
/// builds a second pair of passes - one that clears the colour, one that loads
/// it - each with colour plus depth, and its own `VkFramebuffer` per colour
/// view. `vulkan_pipeline.dart` is the template and the differences are
/// exactly the depth attachment, the depth-stencil state, and the cull mode.
///
/// The framebuffers are cached by colour view and dropped whenever the
/// target's `generation` moves, because a swapchain rebuild destroys the views
/// this cache is keyed on and a freed `VkImageView` can be re-allocated at the
/// same address. Keying on the address alone would then hit a framebuffer that
/// names a destroyed view, which is undefined behaviour with no diagnostic.
///
/// ## 3. The descriptor set layout is the 2D path's object, on purpose
///
/// A `VkDescriptorSet` may only be bound through a pipeline layout whose set at
/// that index was "identically defined". `VulkanRenderDevice.createTexture`
/// allocates every texture's set from `VulkanPipelines.descriptorSetLayout`,
/// and a mesh texture is an ordinary device texture - which is what lets one
/// `SetDescriptorHeaps`-equivalent reach it. So this pipeline layout is built
/// with **that same layout object** rather than an identical copy: two objects
/// that are identical today can be edited apart tomorrow, and the failure mode
/// is a validation error nobody sees on a machine without the layer.
///
/// ## 4. `MeshShading.wireframe` is solid here
///
/// See `vulkan_mesh_shaders.dart`, "Disagreement V4": `VK_POLYGON_MODE_LINE`
/// needs the `fillModeNonSolid` device feature and `VulkanDevice.open` enables
/// none. It is the one shading mode where this backend does not draw the same
/// picture as the Direct3D ports, and it is said out loud rather than
/// discovered.
///
/// ## 5. The sampler wraps, so the descriptor sets are this file's own
///
/// A `VkSampler` is part of a `VkDescriptorSet`, not of a pipeline: a combined
/// image sampler binds an image view **and** a sampler together. The device's
/// two samplers - the ones `VulkanRenderDevice.createTexture` writes into every
/// texture's set - both clamp, because that is what a 2D atlas wants. A mesh
/// wants `REPEAT`, for the reason glTF and OBJ both default to it: a model that
/// tiles a floor has UVs outside the unit square, and clamping smears the edge
/// texel across all of it.
///
/// So this file keeps a sampler, a descriptor pool and a set per mesh texture,
/// all allocated from the **same** `VkDescriptorSetLayout` the device uses -
/// see point 3 - and the device's own set on that texture simply goes unused.
/// The alternative was a `REPEAT` sampler on the device, which would change how
/// every 2D image in the renderer samples outside its rectangle.
///
/// The symptom of getting this wrong is precise and worth recording, because it
/// is what caught it: the tiled-checkerboard scene of the parity test went from
/// 113 differing pixels to **15 646**, a third of the frame, with the model in
/// exactly the right place - one tile stretched over the twenty-four the CPU
/// draws.
///
/// ## 6. Geometry lives in host-visible memory, preferring device-local
///
/// A `VkBuffer` cannot be created with its contents the way
/// `D3D11_USAGE_IMMUTABLE` can, and copying through a staging buffer needs a
/// command buffer this file does not own at upload time. So each primitive's
/// vertex and index buffers are allocated `HOST_VISIBLE | HOST_COHERENT`
/// **preferring `DEVICE_LOCAL`**, written once through the persistent mapping
/// and never touched again. On a unified-memory adapter - which is what this
/// was measured on - that is device memory. On a discrete adapter with a small
/// BAR it is host memory the GPU reads across the bus, and a 451 838-triangle
/// model would then pay for it on every frame; that is a real cost and it is
/// recorded here rather than in a benchmark somebody has to reproduce.
library;

import 'dart:ffi';
import 'dart:math' as math;
import 'dart:typed_data';

import '../../../ffi/native_memory.dart';
import '../../../foundation/diagnostics.dart';
import '../../../geometry/rect.dart';
import '../../../graphics/mesh/mesh3d.dart';
import '../../mesh/mesh_rasterizer.dart';
import '../../mesh/mesh_scene.dart';
import '../../renderer.dart';
import '../gpu_texture.dart';
import 'vulkan_backend.dart';
import 'vulkan_constants.dart';
import 'vulkan_device.dart';
import 'vulkan_ffi.g.dart';
import 'vulkan_memory.dart';
import 'vulkan_mesh_shaders.dart';
import 'vulkan_pipeline.dart';

/// How the depth test compares, so a test can break it on purpose.
///
/// The twin of `D3d11MeshDepthTest` and `D3d12MeshDepthTest`, and it exists for
/// the same reason: a parity test that cannot fail proves nothing, and the two
/// ways this pipeline can be wrong without crashing are the depth comparison
/// and the winding.
enum VulkanMeshDepthTest {
  /// Nearer fragments win: the correct one, and `MeshRasterizer`'s rule.
  less,

  /// Farther fragments win, which draws the model inside out through itself.
  greater,

  /// No depth test at all: whatever was recorded last is on top.
  always,
}

/// Draws a [MeshScene] with Vulkan.
///
/// One per device. It owns Vulkan objects, so it must be disposed before the
/// device it was built from.
final class VulkanMeshRenderer implements MeshSceneRenderer {
  VulkanMeshRenderer._(this._device);

  /// Builds the pipeline for [device], or returns the [BackendDiagnostic] that
  /// says what the driver refused.
  ///
  /// A diagnostic and not a throw, matching the two Direct3D ports: a caller
  /// that cannot get a mesh pipeline wants to fall back to the CPU rasteriser
  /// with a reason to print, not to lose its window.
  static Object create(VulkanRenderDevice device) {
    final renderer = VulkanMeshRenderer._(device);
    final BackendDiagnostic? failure = renderer._build();
    if (failure != null) {
      renderer.dispose();
      return failure;
    }
    return renderer;
  }

  final VulkanRenderDevice _device;

  VulkanDevice get _gpu => _device.gpu;

  Pointer<VkShaderModule_T> _vertexModule = nullptr;
  Pointer<VkShaderModule_T> _fragmentModule = nullptr;
  Pointer<VkPipelineLayout_T> _layout = nullptr;
  Pointer<VkDescriptorSetLayout_T> _setLayout = nullptr;

  /// The depth format this device accepted. See [_chooseDepthFormat].
  int _depthFormat = VkFormat.VK_FORMAT_D32_SFLOAT;

  /// Render passes and pipelines, per colour format.
  final Map<int, _MeshPassSet> _passes = <int, _MeshPassSet>{};

  /// Framebuffers by the address of the colour view they wrap.
  final Map<int, Pointer<VkFramebuffer_T>> _framebuffers =
      <int, Pointer<VkFramebuffer_T>>{};
  int _framebufferGeneration = -1;
  int _framebufferWidth = 0;
  int _framebufferHeight = 0;
  int _framebufferFormat = 0;

  Pointer<VkImage_T> _depthImage = nullptr;
  Pointer<VkImageView_T> _depthView = nullptr;
  VulkanAllocation? _depthMemory;
  int _depthWidth = 0;
  int _depthHeight = 0;

  /// The `REPEAT` sampler and the pool the mesh descriptor sets come from.
  ///
  /// See point 5 of the library comment for why this pipeline cannot use the
  /// sets `VulkanRenderDevice.createTexture` already made.
  Pointer<VkSampler_T> _sampler = nullptr;
  Pointer<VkDescriptorPool_T> _descriptorPool = nullptr;
  final Map<VulkanTexture, Pointer<VkDescriptorSet_T>> _sets =
      <VulkanTexture, Pointer<VkDescriptorSet_T>>{};

  /// Descriptor sets this pipeline's pool holds.
  ///
  /// One per distinct [MeshTexture] plus one for the placeholder, and they are
  /// never freed individually: `vkFreeDescriptorSets` is not among the bound
  /// entry points, so the pool is reset only when this renderer is disposed. A
  /// viewer that opened more than this many textured materials in one session
  /// draws the ones past the limit untextured rather than failing the frame -
  /// which is the same answer [_textureFor] gives when the device runs out of
  /// memory, and for the same reason: the shape and the base colour are still
  /// right.
  static const int kMeshDescriptorSets = 128;

  /// The 1x1 transparent texture bound when a material has none.
  ///
  /// The fragment stage samples unconditionally - see
  /// `buildVulkanMeshFragmentShader` for why there is one module and not two -
  /// so a descriptor set is always needed. Sampling an image that was never
  /// written is undefined, which is why this one is uploaded rather than merely
  /// created.
  VulkanTexture? _placeholder;

  final Map<_MeshBufferKey, _MeshBuffers> _buffers =
      <_MeshBufferKey, _MeshBuffers>{};
  final Map<MeshTexture, VulkanTexture> _textures =
      <MeshTexture, VulkanTexture>{};
  int _bufferBytes = 0;
  int _clock = 0;
  bool _disposed = false;

  /// Bytes of cached vertex and index buffers before the least recently drawn
  /// primitive is evicted. The same budget and argument as the Direct3D ports'.
  int bufferBudgetBytes = 384 * 1024 * 1024;

  /// How the depth test compares. Correct at [VulkanMeshDepthTest.less].
  VulkanMeshDepthTest depthTest = VulkanMeshDepthTest.less;

  /// Whether a counter-clockwise triangle in framebuffer space is the front
  /// face. True is correct; see `vulkan_mesh_shaders.dart` for why the Y
  /// negation is what makes this the same rule the Direct3D ports use.
  bool frontCounterClockwise = true;

  int get cachedPrimitiveCount => _buffers.length;
  int get cachedBufferBytes => _bufferBytes;

  /// `vkCreateBuffer` calls this renderer has made for geometry.
  int get bufferUploadCount => _bufferUploadCount;
  int _bufferUploadCount = 0;

  /// The depth format in force, for a probe to print.
  int get depthFormat => _depthFormat;

  bool get isDisposed => _disposed;

  // -------------------------------------------------------------------
  // Construction
  // -------------------------------------------------------------------

  BackendDiagnostic? _build() {
    final VulkanPipelines? shared =
        _device.pipelinesFor(VkFormat.VK_FORMAT_B8G8R8A8_UNORM);
    if (shared == null) {
      return const BackendDiagnostic(
        kind: DiagnosticKind.incompatibleDevice,
        message: 'the 2D Vulkan pipelines could not be built, so the mesh '
            'pipeline has no descriptor set layout to share',
        detail: 'see the layout-sharing section of vulkan_mesh_pipeline.dart',
      );
    }
    _setLayout = shared.descriptorSetLayout;

    final int? depth = _chooseDepthFormat();
    if (depth == null) {
      return BackendDiagnostic(
        kind: DiagnosticKind.incompatibleDevice,
        message: 'no depth format this pipeline can use',
        detail: '${_gpu.physicalDevice.name} reports neither '
            'VK_FORMAT_D32_SFLOAT nor VK_FORMAT_D16_UNORM as a '
            'depth-stencil attachment with optimal tiling, which the '
            'specification requires of every device for at least one of them',
      );
    }
    _depthFormat = depth;

    return using((NativeArena arena) {
      _vertexModule = _createShaderModule(arena, buildVulkanMeshVertexShader());
      if (_vertexModule == nullptr) {
        return const BackendDiagnostic(
          kind: DiagnosticKind.incompatibleDevice,
          message: 'vkCreateShaderModule refused the mesh vertex module',
          detail: 'the SPIR-V is written by hand in vulkan_mesh_shaders.dart',
        );
      }
      _fragmentModule =
          _createShaderModule(arena, buildVulkanMeshFragmentShader());
      if (_fragmentModule == nullptr) {
        return const BackendDiagnostic(
          kind: DiagnosticKind.incompatibleDevice,
          message: 'vkCreateShaderModule refused the mesh fragment module',
          detail: 'the SPIR-V is written by hand in vulkan_mesh_shaders.dart',
        );
      }

      final Pointer<VkPushConstantRange> range = arena<VkPushConstantRange>();
      range.ref
        // Both stages: the vertex stage reads the four matrix rows, the
        // fragment stage reads the light, the colour and the options. One
        // range covering both is what makes a single `vkCmdPushConstants`
        // enough per primitive.
        ..stageFlags = VkShaderStageFlagBits.VK_SHADER_STAGE_VERTEX_BIT |
            VkShaderStageFlagBits.VK_SHADER_STAGE_FRAGMENT_BIT
        ..offset = 0
        ..size = VulkanMeshPushConstant.bytes;
      final int limit = _gpu.physicalDevice.maxPushConstantsSize;
      if (limit < VulkanMeshPushConstant.bytes) {
        return BackendDiagnostic(
          kind: DiagnosticKind.incompatibleDevice,
          message: 'this device has too little push-constant space for the '
              'mesh program',
          detail: '${_gpu.physicalDevice.name} offers $limit bytes and the '
              'mesh program needs ${VulkanMeshPushConstant.bytes}; the '
              'specification guarantees 128',
        );
      }

      final Pointer<Pointer<VkDescriptorSetLayout_T>> layouts =
          arena<Pointer<VkDescriptorSetLayout_T>>();
      layouts.value = _setLayout;
      final Pointer<VkPipelineLayoutCreateInfo> info =
          arena<VkPipelineLayoutCreateInfo>();
      info.ref
        ..sType = VkStructureType.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO
        ..setLayoutCount = 1
        ..pSetLayouts = layouts
        ..pushConstantRangeCount = 1
        ..pPushConstantRanges = range;
      final Pointer<Pointer<VkPipelineLayout_T>> out =
          arena<Pointer<VkPipelineLayout_T>>();
      if (vkFailed(
          _gpu.api.createPipelineLayout(_gpu.handle, info, nullptr, out))) {
        return const BackendDiagnostic(
          kind: DiagnosticKind.incompatibleDevice,
          message: 'vkCreatePipelineLayout refused the mesh layout',
        );
      }
      _layout = out.value;

      final Pointer<VkSamplerCreateInfo> samplerInfo =
          arena<VkSamplerCreateInfo>();
      samplerInfo.ref
        ..sType = VkStructureType.VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO
        // Nearest neighbour, and it is a choice the CPU sampler argues for
        // that this has to copy whether or not it agrees: a linear tap here
        // would be a *better* picture that no parity test could accept.
        ..magFilter = VkFilter.VK_FILTER_NEAREST
        ..minFilter = VkFilter.VK_FILTER_NEAREST
        ..mipmapMode = VkSamplerMipmapMode.VK_SAMPLER_MIPMAP_MODE_NEAREST
        ..addressModeU = VkSamplerAddressMode.VK_SAMPLER_ADDRESS_MODE_REPEAT
        ..addressModeV = VkSamplerAddressMode.VK_SAMPLER_ADDRESS_MODE_REPEAT
        ..addressModeW = VkSamplerAddressMode.VK_SAMPLER_ADDRESS_MODE_REPEAT
        // Zero: every mesh texture is uploaded with one mip level, so there is
        // no level above zero for the sampler to select.
        ..maxLod = 0
        ..borderColor = VkBorderColor.VK_BORDER_COLOR_FLOAT_TRANSPARENT_BLACK;
      final Pointer<Pointer<VkSampler_T>> samplerOut =
          arena<Pointer<VkSampler_T>>();
      if (vkFailed(_gpu.api
          .createSampler(_gpu.handle, samplerInfo, nullptr, samplerOut))) {
        return const BackendDiagnostic(
          kind: DiagnosticKind.incompatibleDevice,
          message: 'vkCreateSampler refused the repeating mesh sampler',
        );
      }
      _sampler = samplerOut.value;

      final Pointer<VkDescriptorPoolSize> poolSize =
          arena<VkDescriptorPoolSize>();
      poolSize.ref
        ..type = VkDescriptorType.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER
        ..descriptorCount = kMeshDescriptorSets;
      final Pointer<VkDescriptorPoolCreateInfo> poolInfo =
          arena<VkDescriptorPoolCreateInfo>();
      poolInfo.ref
        ..sType = VkStructureType.VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO
        ..maxSets = kMeshDescriptorSets
        ..poolSizeCount = 1
        ..pPoolSizes = poolSize;
      final Pointer<Pointer<VkDescriptorPool_T>> poolOut =
          arena<Pointer<VkDescriptorPool_T>>();
      if (vkFailed(_gpu.api
          .createDescriptorPool(_gpu.handle, poolInfo, nullptr, poolOut))) {
        return const BackendDiagnostic(
          kind: DiagnosticKind.incompatibleDevice,
          message: 'vkCreateDescriptorPool refused the mesh descriptor pool',
        );
      }
      _descriptorPool = poolOut.value;

      try {
        _placeholder = _device.createTexture(
          width: 1,
          height: 1,
          format: GpuTextureFormat.rgba8888Premultiplied,
        );
      } on Object catch (error) {
        return BackendDiagnostic(
          kind: DiagnosticKind.incompatibleDevice,
          message: 'the 1x1 placeholder texture could not be created',
          detail: '$error',
        );
      }
      _device.uploadRegion(
        _placeholder!,
        x: 0,
        y: 0,
        width: 1,
        height: 1,
        pixels: Uint8List(4),
        bytesPerRow: 4,
      );
      if (_descriptorSetFor(_placeholder!) == nullptr) {
        return const BackendDiagnostic(
          kind: DiagnosticKind.incompatibleDevice,
          message: 'vkAllocateDescriptorSets refused the placeholder set',
        );
      }
      return null;
    });
  }

  /// The descriptor set that binds [texture] through this pipeline's repeating
  /// sampler, or `nullptr` when the pool is full.
  ///
  /// Allocated from the device's own `VkDescriptorSetLayout`, which is what
  /// keeps it bindable through this pipeline layout: a set may only be bound
  /// through a layout whose set at that index was identically defined, and
  /// "the same object" is the only definition of identical that cannot drift.
  Pointer<VkDescriptorSet_T> _descriptorSetFor(VulkanTexture texture) {
    final Pointer<VkDescriptorSet_T>? cached = _sets[texture];
    if (cached != null) return cached;
    return using((NativeArena arena) {
      final Pointer<Pointer<VkDescriptorSetLayout_T>> layouts =
          arena<Pointer<VkDescriptorSetLayout_T>>();
      layouts.value = _setLayout;
      final Pointer<VkDescriptorSetAllocateInfo> info =
          arena<VkDescriptorSetAllocateInfo>();
      info.ref
        ..sType = VkStructureType.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO
        ..descriptorPool = _descriptorPool
        ..descriptorSetCount = 1
        ..pSetLayouts = layouts;
      final Pointer<Pointer<VkDescriptorSet_T>> out =
          arena<Pointer<VkDescriptorSet_T>>();
      if (vkFailed(_gpu.api.allocateDescriptorSets(_gpu.handle, info, out))) {
        return nullptr;
      }
      final Pointer<VkDescriptorImageInfo> imageInfo =
          arena<VkDescriptorImageInfo>();
      imageInfo.ref
        ..sampler = _sampler
        ..imageView = texture.view
        ..imageLayout = VkImageLayout.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
      final Pointer<VkWriteDescriptorSet> write = arena<VkWriteDescriptorSet>();
      write.ref
        ..sType = VkStructureType.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET
        ..dstSet = out.value
        ..dstBinding = kVulkanMeshTextureBinding
        ..descriptorCount = 1
        ..descriptorType =
            VkDescriptorType.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER
        ..pImageInfo = imageInfo;
      _gpu.api.updateDescriptorSets(_gpu.handle, 1, write, 0, nullptr);
      _sets[texture] = out.value;
      return out.value;
    });
  }

  /// `VK_FORMAT_D32_SFLOAT` where the device offers it, `VK_FORMAT_D16_UNORM`
  /// otherwise, or null when it offers neither.
  ///
  /// Asked rather than assumed. The specification guarantees `D16_UNORM` as a
  /// depth-stencil attachment on every device and guarantees only **one of**
  /// `D32_SFLOAT` and `X8_D24_UNORM_PACK32`, so a pipeline that hard-coded
  /// `D32_SFLOAT` - which is what the Direct3D 12 port can do, because
  /// Direct3D guarantees it - would be undefined behaviour on a conforming
  /// device. Sixteen bits is coarse enough to matter on a deep scene, which is
  /// why it is the fallback and not the default.
  int? _chooseDepthFormat() {
    const int attachment =
        VkFormatFeatureFlagBits.VK_FORMAT_FEATURE_DEPTH_STENCIL_ATTACHMENT_BIT;
    for (final int format in <int>[
      VkFormat.VK_FORMAT_D32_SFLOAT,
      VkFormat.VK_FORMAT_D16_UNORM,
    ]) {
      if (_gpu.physicalDevice.optimalTilingFeatures(format) & attachment != 0) {
        return format;
      }
    }
    return null;
  }

  Pointer<VkShaderModule_T> _createShaderModule(
    NativeArena arena,
    Uint32List words,
  ) {
    final Pointer<Uint32> code = arena<Uint32>(words.length);
    code.asTypedList(words.length).setAll(0, words);
    final Pointer<VkShaderModuleCreateInfo> info =
        arena<VkShaderModuleCreateInfo>();
    info.ref
      ..sType = VkStructureType.VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO
      // Bytes, not words.
      ..codeSize = words.length * 4
      ..pCode = code;
    final Pointer<Pointer<VkShaderModule_T>> out =
        arena<Pointer<VkShaderModule_T>>();
    if (vkFailed(
        _gpu.api.createShaderModule(_gpu.handle, info, nullptr, out))) {
      return nullptr;
    }
    return out.value;
  }

  // -------------------------------------------------------------------
  // Drawing
  // -------------------------------------------------------------------

  @override
  MeshRenderStats drawScene(
    RenderTarget target,
    MeshScene scene, {
    Rect? viewport,
  }) {
    _throwIfDisposed();
    if (_device.isLost || _layout == nullptr) return MeshRenderStats.zero;
    // The one place this file knows about concrete target types, and it is
    // unavoidable: `MeshSceneRenderer` promises to take a [RenderTarget] so
    // that the other backends can implement the same method.
    final Object? enqueue = switch (target) {
      VulkanOffscreenTarget() when identical(target.device, _device) => target,
      VulkanWindowTarget() when identical(target.device, _device) => target,
      _ => null,
    };
    if (enqueue == null) return MeshRenderStats.zero;

    // The geometry is prepared and uploaded **now**, not when the pass runs.
    // The buffers are host-visible and mapped, so nothing here needs a command
    // buffer, and doing it now is what makes the returned microseconds mean
    // something: it is this pipeline's whole per-frame CPU cost.
    final Stopwatch watch = Stopwatch()..start();
    final List<_MeshDraw> draws = <_MeshDraw>[];
    var triangles = 0;
    final bool wireframe = scene.shading == MeshShading.wireframe;
    for (final MeshPrimitive primitive in scene.mesh.primitives) {
      triangles += primitive.triangleCount;
      final _MeshBuffers? buffers = _buffersFor(primitive, scene.shading);
      if (buffers == null) continue;
      final MeshTexture? texture = wireframe
          ? null
          : (primitive.uvs == null
              ? null
              : primitive.material.baseColorTexture);
      final VulkanTexture? uploaded =
          texture == null ? null : _textureFor(texture);
      draws.add(_MeshDraw(
        buffers: buffers,
        texture: uploaded,
        colorArgb: primitive.material.colorArgb,
        cull: !primitive.material.doubleSided,
      ));
    }
    watch.stop();
    if (draws.isEmpty) {
      return gpuMeshStats(
        triangles: triangles,
        microseconds: watch.elapsedMicroseconds,
      );
    }

    void pass(
      Pointer<VkCommandBuffer_T> commands,
      VulkanAttachmentSurface surface,
    ) =>
        _record(commands, surface, scene, draws, viewport);

    if (enqueue is VulkanOffscreenTarget) {
      enqueue.enqueueAttachmentPass(pass);
    } else {
      (enqueue as VulkanWindowTarget).enqueueAttachmentPass(pass);
    }
    return gpuMeshStats(
      triangles: triangles,
      microseconds: watch.elapsedMicroseconds,
    );
  }

  /// Records the pass the target enqueued, on the target's own command buffer.
  void _record(
    Pointer<VkCommandBuffer_T> commands,
    VulkanAttachmentSurface surface,
    MeshScene scene,
    List<_MeshDraw> draws,
    Rect? viewport,
  ) {
    if (_disposed || _device.isLost) return;
    final Rect box = viewport ??
        Rect.fromLTWH(
            0, 0, surface.width.toDouble(), surface.height.toDouble());
    if (box.width <= 0 || box.height <= 0) return;
    if (!_ensureDepth(surface.width, surface.height)) return;

    // A load pass needs the colour attachment to already hold something in
    // `COLOR_ATTACHMENT_OPTIMAL`, and on the first frame of a target it holds
    // nothing at all - so "do not clear" becomes "clear to what an untouched
    // attachment holds" exactly once, rather than becoming undefined
    // behaviour.
    final bool clears = scene.backgroundArgb != null || !surface.hasContent;
    final _MeshPassSet? set = _passesFor(surface.colorFormat);
    if (set == null) return;
    final Pointer<VkFramebuffer_T>? framebuffer = _framebufferFor(surface, set);
    if (framebuffer == null) return;

    using((NativeArena arena) {
      final Pointer<VkClearValue> clearValues = arena<VkClearValue>(2);
      final int background = scene.backgroundArgb ?? 0;
      // The colour arrives premultiplied ARGB in an int and the attachment
      // takes four floats in *shader* order. The same unpacking
      // `_recordDenseRange` does, and for the same reason.
      clearValues[0].color.float32[0] = ((background >> 16) & 0xFF) / 255.0;
      clearValues[0].color.float32[1] = ((background >> 8) & 0xFF) / 255.0;
      clearValues[0].color.float32[2] = (background & 0xFF) / 255.0;
      clearValues[0].color.float32[3] = ((background >> 24) & 0xFF) / 255.0;
      // One, and `LESS` against it, which is `MeshRasterizer`'s rule: it clears
      // its depth to `double.infinity` and rejects on `>=`. The one place they
      // differ is a fragment exactly on the far plane, and `MeshCamera.frame`
      // puts the far plane at ten times the camera distance.
      clearValues[1].depthStencil
        ..depth = 1
        ..stencil = 0;

      final Pointer<VkRenderPassBeginInfo> begin =
          arena<VkRenderPassBeginInfo>();
      begin.ref
        ..sType = VkStructureType.VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO
        ..renderPass = clears ? set.clearPass : set.loadPass
        ..framebuffer = framebuffer
        // Two either way. The colour attachment's `loadOp` decides whether
        // entry 0 is read; the depth attachment always clears, so entry 1
        // always is, and a `clearValueCount` of 1 with a depth attachment that
        // clears is a read past the end of the array.
        ..clearValueCount = 2
        ..pClearValues = clearValues;
      begin.ref.renderArea.offset
        ..x = 0
        ..y = 0;
      begin.ref.renderArea.extent
        ..width = surface.width
        ..height = surface.height;
      _gpu.api.cmdBeginRenderPass(
          commands, begin, VkSubpassContents.VK_SUBPASS_CONTENTS_INLINE);

      final Pointer<VkViewport> vp = arena<VkViewport>();
      vp.ref
        ..x = box.left
        ..y = box.top
        ..width = box.width
        ..height = box.height
        ..minDepth = 0
        ..maxDepth = 1;
      final Pointer<VkRect2D> scissor = arena<VkRect2D>();
      final int left = box.left.floor().clamp(0, surface.width);
      final int top = box.top.floor().clamp(0, surface.height);
      scissor.ref.offset
        ..x = left
        ..y = top;
      scissor.ref.extent
        ..width = box.right.ceil().clamp(0, surface.width) - left
        ..height = box.bottom.ceil().clamp(0, surface.height) - top;
      _gpu.api
        ..cmdSetViewport(commands, 0, 1, vp)
        ..cmdSetScissor(commands, 0, 1, scissor);

      final Matrix4 viewProjection = scene.camera
          .projectionMatrix(box.width / box.height)
          .multiply(scene.camera.viewMatrix());
      final Vector3 light = scene.lightDirection.normalized;
      final bool lit = scene.shading != MeshShading.unlit &&
          scene.shading != MeshShading.wireframe;

      final Pointer<Float> push =
          arena<Float>(VulkanMeshPushConstant.bytes ~/ 4);
      final Pointer<Pointer<VkBuffer_T>> vertexBuffers =
          arena<Pointer<VkBuffer_T>>();
      final Pointer<Uint64> offsets = arena<Uint64>();
      offsets.value = 0;
      final Pointer<Pointer<VkDescriptorSet_T>> sets =
          arena<Pointer<VkDescriptorSet_T>>();

      for (final _MeshDraw draw in draws) {
        final Pointer<VkPipeline_T>? pipeline = set.pipelineFor(
          cull: draw.cull,
          test: depthTest,
          frontCcw: frontCounterClockwise,
        );
        if (pipeline == null) continue;
        _writePushConstants(
          push,
          viewProjection,
          light,
          scene.ambient,
          draw.colorArgb,
          lit: lit,
          textured: draw.texture != null,
        );
        vertexBuffers.value = draw.buffers.vertices.handle;
        // This pipeline's set, not the device's: the device's binds the
        // clamping sampler. A texture the pool had no room for falls back to
        // the placeholder and draws untextured.
        final Pointer<VkDescriptorSet_T> bound = draw.texture == null
            ? _sets[_placeholder]!
            : _descriptorSetFor(draw.texture!);
        sets.value = bound == nullptr ? _sets[_placeholder]! : bound;
        _gpu.api
          ..cmdBindPipeline(commands,
              VkPipelineBindPoint.VK_PIPELINE_BIND_POINT_GRAPHICS, pipeline)
          ..cmdPushConstants(
            commands,
            _layout,
            VkShaderStageFlagBits.VK_SHADER_STAGE_VERTEX_BIT |
                VkShaderStageFlagBits.VK_SHADER_STAGE_FRAGMENT_BIT,
            0,
            VulkanMeshPushConstant.bytes,
            push.cast<Void>(),
          )
          ..cmdBindDescriptorSets(
            commands,
            VkPipelineBindPoint.VK_PIPELINE_BIND_POINT_GRAPHICS,
            _layout,
            kVulkanMeshTextureSet,
            1,
            sets,
            0,
            nullptr,
          )
          ..cmdBindVertexBuffers(commands, 0, 1, vertexBuffers, offsets)
          ..cmdBindIndexBuffer(commands, draw.buffers.indices.handle, 0,
              VkIndexType.VK_INDEX_TYPE_UINT32)
          ..cmdDrawIndexed(commands, draw.buffers.indexCount, 1, 0, 0, 0);
      }

      _gpu.api.cmdEndRenderPass(commands);
    });
  }

  /// Writes the twenty-eight push-constant floats.
  ///
  /// The transpose is the whole reason this is not a `setAll`: [Matrix4] stores
  /// column-major, like glTF and OpenGL, and the shader dots *row* `i` with the
  /// position, so `row i, column j` lives at `storage[j * 4 + i]`. Getting it
  /// wrong is a model transformed by the transpose of the intended matrix,
  /// which for a view-projection is not a recognisable transform at all.
  void _writePushConstants(
    Pointer<Float> push,
    Matrix4 viewProjection,
    Vector3 light,
    double ambient,
    int colorArgb, {
    required bool lit,
    required bool textured,
  }) {
    final Float64List m = viewProjection.storage;
    for (var row = 0; row < 4; row++) {
      for (var column = 0; column < 4; column++) {
        push[row * 4 + column] = m[column * 4 + row];
      }
    }
    const int light0 = VulkanMeshPushConstant.light ~/ 4;
    push[light0] = light.x;
    push[light0 + 1] = light.y;
    push[light0 + 2] = light.z;
    push[light0 + 3] = ambient;
    // 0..255 and not 0..1: the shader works in the CPU rasteriser's channel
    // space throughout and divides once at the return.
    const int color0 = VulkanMeshPushConstant.baseColor ~/ 4;
    push[color0] = ((colorArgb >> 16) & 0xFF).toDouble();
    push[color0 + 1] = ((colorArgb >> 8) & 0xFF).toDouble();
    push[color0 + 2] = (colorArgb & 0xFF).toDouble();
    push[color0 + 3] = 255;
    const int options0 = VulkanMeshPushConstant.options ~/ 4;
    push[options0] = lit ? 1 : 0;
    push[options0 + 1] = textured ? 1 : 0;
    push[options0 + 2] = 0;
    push[options0 + 3] = 0;
  }

  // -------------------------------------------------------------------
  // Render passes, pipelines, framebuffers and the depth image
  // -------------------------------------------------------------------

  _MeshPassSet? _passesFor(int colorFormat) {
    final _MeshPassSet? cached = _passes[colorFormat];
    if (cached != null) return cached;
    final _MeshPassSet? built = _MeshPassSet.create(
      _gpu,
      colorFormat: colorFormat,
      depthFormat: _depthFormat,
      layout: _layout,
      vertex: _vertexModule,
      fragment: _fragmentModule,
    );
    if (built == null) return null;
    _passes[colorFormat] = built;
    return built;
  }

  Pointer<VkFramebuffer_T>? _framebufferFor(
    VulkanAttachmentSurface surface,
    _MeshPassSet set,
  ) {
    if (surface.generation != _framebufferGeneration ||
        surface.width != _framebufferWidth ||
        surface.height != _framebufferHeight ||
        surface.colorFormat != _framebufferFormat) {
      _dropFramebuffers();
      _framebufferGeneration = surface.generation;
      _framebufferWidth = surface.width;
      _framebufferHeight = surface.height;
      _framebufferFormat = surface.colorFormat;
    }
    final int key = surface.colorView.address;
    final Pointer<VkFramebuffer_T>? cached = _framebuffers[key];
    if (cached != null) return cached;
    final Pointer<VkFramebuffer_T>? built = using((NativeArena arena) {
      final Pointer<Pointer<VkImageView_T>> attachments =
          arena<Pointer<VkImageView_T>>(2);
      attachments[0] = surface.colorView;
      attachments[1] = _depthView;
      final Pointer<VkFramebufferCreateInfo> info =
          arena<VkFramebufferCreateInfo>();
      info.ref
        ..sType = VkStructureType.VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO
        // Either pass will do: render-pass compatibility only compares the
        // attachments' formats and sample counts, and the clear and load
        // passes differ only in their load operations.
        ..renderPass = set.clearPass
        ..attachmentCount = 2
        ..pAttachments = attachments
        ..width = surface.width
        ..height = surface.height
        ..layers = 1;
      final Pointer<Pointer<VkFramebuffer_T>> out =
          arena<Pointer<VkFramebuffer_T>>();
      if (vkFailed(
          _gpu.api.createFramebuffer(_gpu.handle, info, nullptr, out))) {
        return null;
      }
      return out.value;
    });
    if (built == null) return null;
    _framebuffers[key] = built;
    return built;
  }

  /// Destroys every cached framebuffer, once the GPU has finished with them.
  void _dropFramebuffers() {
    if (_framebuffers.isEmpty) return;
    if (!_device.isLost) _gpu.waitIdle();
    for (final Pointer<VkFramebuffer_T> framebuffer in _framebuffers.values) {
      _gpu.api.destroyFramebuffer(_gpu.handle, framebuffer, nullptr);
    }
    _framebuffers.clear();
  }

  /// Allocates the depth image, or reallocates it to cover the target.
  bool _ensureDepth(int width, int height) {
    if (_depthView != nullptr &&
        _depthWidth == width &&
        _depthHeight == height) {
      return true;
    }
    _destroyDepth();
    final bool made = using((NativeArena arena) {
      final Pointer<VkImageCreateInfo> info = arena<VkImageCreateInfo>();
      info.ref
        ..sType = VkStructureType.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO
        ..imageType = VkImageType.VK_IMAGE_TYPE_2D
        ..format = _depthFormat
        ..mipLevels = 1
        ..arrayLayers = 1
        ..samples = VkSampleCountFlagBits.VK_SAMPLE_COUNT_1_BIT
        ..tiling = VkImageTiling.VK_IMAGE_TILING_OPTIMAL
        ..usage =
            VkImageUsageFlagBits.VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT
        ..sharingMode = VkSharingMode.VK_SHARING_MODE_EXCLUSIVE
        // UNDEFINED, and it stays legal for the life of the image: the mesh
        // render pass declares `initialLayout = UNDEFINED` on the depth
        // attachment because it always clears it, so no barrier ever moves
        // this image and there is no layout to track.
        ..initialLayout = VkImageLayout.VK_IMAGE_LAYOUT_UNDEFINED;
      info.ref.extent
        ..width = width
        ..height = height
        ..depth = 1;
      final Pointer<Pointer<VkImage_T>> imageOut = arena<Pointer<VkImage_T>>();
      if (vkFailed(
          _gpu.api.createImage(_gpu.handle, info, nullptr, imageOut))) {
        return false;
      }
      final Pointer<VkMemoryRequirements> requirements =
          arena<VkMemoryRequirements>();
      _gpu.api.getImageMemoryRequirements(
          _gpu.handle, imageOut.value, requirements);
      final VulkanAllocation allocation = _gpu.allocator.allocate(
        resource: 'mesh depth ${width}x$height',
        size: requirements.ref.size,
        alignment: requirements.ref.alignment,
        memoryTypeBits: requirements.ref.memoryTypeBits,
        required: VkMemoryPropertyFlagBits.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT,
        // OPTIMAL tiling, so not linear - which is what keeps this out of the
        // pools the buffers use and makes `bufferImageGranularity` moot.
        linear: false,
      );
      _gpu.api.bindImageMemory(
          _gpu.handle, imageOut.value, allocation.memory, allocation.offset);

      final Pointer<VkImageViewCreateInfo> viewInfo =
          arena<VkImageViewCreateInfo>();
      viewInfo.ref
        ..sType = VkStructureType.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO
        ..image = imageOut.value
        ..viewType = VkImageViewType.VK_IMAGE_VIEW_TYPE_2D
        ..format = _depthFormat;
      viewInfo.ref.subresourceRange
        // DEPTH and not COLOR, which is why this cannot go through
        // `VulkanRenderDevice._createImageTexture`: that method hard-codes the
        // colour aspect, and a depth view created with it is rejected.
        ..aspectMask = VkImageAspectFlagBits.VK_IMAGE_ASPECT_DEPTH_BIT
        ..levelCount = 1
        ..layerCount = 1;
      final Pointer<Pointer<VkImageView_T>> viewOut =
          arena<Pointer<VkImageView_T>>();
      if (vkFailed(
          _gpu.api.createImageView(_gpu.handle, viewInfo, nullptr, viewOut))) {
        _gpu.api.destroyImage(_gpu.handle, imageOut.value, nullptr);
        _gpu.allocator.free(allocation);
        return false;
      }
      _depthImage = imageOut.value;
      _depthView = viewOut.value;
      _depthMemory = allocation;
      _depthWidth = width;
      _depthHeight = height;
      return true;
    });
    // Every cached framebuffer named the old depth view. Dropping them here is
    // what stops a resize from binding a framebuffer whose depth attachment
    // has been destroyed.
    if (made) _dropFramebuffers();
    return made;
  }

  void _destroyDepth() {
    if (_depthView == nullptr && _depthImage == nullptr) return;
    _dropFramebuffers();
    if (!_device.isLost) _gpu.waitIdle();
    if (_depthView != nullptr) {
      _gpu.api.destroyImageView(_gpu.handle, _depthView, nullptr);
      _depthView = nullptr;
    }
    if (_depthImage != nullptr) {
      _gpu.api.destroyImage(_gpu.handle, _depthImage, nullptr);
      _depthImage = nullptr;
    }
    final VulkanAllocation? memory = _depthMemory;
    if (memory != null) _gpu.allocator.free(memory);
    _depthMemory = null;
    _depthWidth = 0;
    _depthHeight = 0;
  }

  // -------------------------------------------------------------------
  // Geometry and texture caches
  // -------------------------------------------------------------------

  @override
  void discardMesh(Mesh3D mesh) {
    var released = false;
    for (final MeshPrimitive primitive in mesh.primitives) {
      for (final _MeshNormalSource source in _MeshNormalSource.values) {
        final _MeshBuffers? entry =
            _buffers.remove(_MeshBufferKey(primitive, source));
        if (entry == null) continue;
        if (!released && !_device.isLost) {
          // Once, and before the first `vkDestroyBuffer`: a frame recorded a
          // draw out of these buffers at most two frames ago and may still be
          // executing it. Vulkan tracks no such lifetime for the caller.
          _gpu.waitIdle();
          released = true;
        }
        _bufferBytes -= entry.bytes;
        entry.dispose(_gpu);
      }
      final MeshTexture? texture = primitive.material.baseColorTexture;
      if (texture == null) continue;
      final VulkanTexture? uploaded = _textures.remove(texture);
      if (uploaded == null) continue;
      // The set is dropped from the map and not freed: see
      // [kMeshDescriptorSets] for why the pool is reset only at dispose.
      _sets.remove(uploaded);
      _device.releaseTexture(uploaded);
    }
  }

  _MeshBuffers? _buffersFor(MeshPrimitive primitive, MeshShading shading) {
    final _MeshNormalSource source = shading == MeshShading.flat
        ? _MeshNormalSource.perFace
        : _MeshNormalSource.perVertex;
    final key = _MeshBufferKey(primitive, source);
    final _MeshBuffers? cached = _buffers[key];
    if (cached != null) {
      cached.lastUsed = ++_clock;
      return cached;
    }
    final _MeshBuffers? built = source == _MeshNormalSource.perFace
        ? _buildFlat(primitive)
        : _buildIndexed(primitive);
    if (built == null) return null;
    built.lastUsed = ++_clock;
    _buffers[key] = built;
    _bufferBytes += built.bytes;
    _evictIfOverBudget(key);
    return built;
  }

  /// The ordinary path: one vertex per vertex, the file's own index buffer.
  _MeshBuffers? _buildIndexed(MeshPrimitive primitive) {
    final int vertexCount = primitive.vertexCount;
    final Uint32List indices = primitive.indices;
    if (vertexCount == 0 || indices.length < 3) return null;
    // `primitive.normals ?? computeSmoothNormals()` is exactly what
    // `MeshRasterizer.render` does for smooth shading, and the fallback is not
    // optional: a mesh with no normals shaded with a zero normal is uniformly
    // ambient, which looks like a flat-lit model rather than like missing data.
    final Float32List normals =
        primitive.normals ?? primitive.computeSmoothNormals();
    final Float32List? uvs = primitive.uvs;
    final Float32List positions = primitive.positions;
    final Float32List vertices =
        Float32List(vertexCount * (kVulkanMeshVertexStrideBytes ~/ 4));
    for (var i = 0; i < vertexCount; i++) {
      final int out = i * 8;
      final int p = i * 3;
      vertices[out] = positions[p];
      vertices[out + 1] = positions[p + 1];
      vertices[out + 2] = positions[p + 2];
      if (p + 2 < normals.length) {
        vertices[out + 3] = normals[p];
        vertices[out + 4] = normals[p + 1];
        vertices[out + 5] = normals[p + 2];
      }
      final int t = i * 2;
      if (uvs != null && t + 1 < uvs.length) {
        vertices[out + 6] = uvs[t];
        vertices[out + 7] = uvs[t + 1];
      }
    }
    // Indices past the end of the vertex array are dropped rather than clamped,
    // which is what `MeshRasterizer` does with its `ia >= vertexCount` guard. A
    // clamp would draw a triangle the CPU never drew - a stray fan back to
    // vertex zero, which is a visible spike out of the model.
    final Uint32List safe = _filterIndices(indices, vertexCount);
    if (safe.isEmpty) return null;
    return _createBuffers(vertices, safe);
  }

  /// The flat-shading path: de-indexed, three vertices per triangle, each
  /// carrying its own face's normal.
  ///
  /// The cross product is `(b - a) x (c - a)` normalised, character for
  /// character `MeshRasterizer._drawProjected`'s `faceNormalOf`.
  _MeshBuffers? _buildFlat(MeshPrimitive primitive) {
    final Float32List positions = primitive.positions;
    final Uint32List indices = primitive.indices;
    final Float32List? uvs = primitive.uvs;
    final int vertexCount = primitive.vertexCount;
    final int triangles = indices.length ~/ 3;
    if (triangles == 0) return null;
    final Float32List vertices = Float32List(triangles * 3 * 8);
    final Uint32List out = Uint32List(triangles * 3);
    var written = 0;
    for (var t = 0; t + 2 < indices.length; t += 3) {
      final int ia = indices[t];
      final int ib = indices[t + 1];
      final int ic = indices[t + 2];
      if (ia >= vertexCount || ib >= vertexCount || ic >= vertexCount) continue;
      final int pa = ia * 3;
      final int pb = ib * 3;
      final int pc = ic * 3;
      final double ax = positions[pb] - positions[pa];
      final double ay = positions[pb + 1] - positions[pa + 1];
      final double az = positions[pb + 2] - positions[pa + 2];
      final double bx = positions[pc] - positions[pa];
      final double by = positions[pc + 1] - positions[pa + 1];
      final double bz = positions[pc + 2] - positions[pa + 2];
      var nx = ay * bz - az * by;
      var ny = az * bx - ax * bz;
      var nz = ax * by - ay * bx;
      final double length = math.sqrt(nx * nx + ny * ny + nz * nz);
      // A zero vector normalises to zero rather than to NaN, the rule
      // `Vector3.normalized` states: degenerate triangles are common in
      // exported models and a NaN normal poisons the shading of everything
      // that shares it.
      if (length != 0) {
        nx /= length;
        ny /= length;
        nz /= length;
      }
      for (final int index in <int>[ia, ib, ic]) {
        final int at = written * 8;
        final int p = index * 3;
        vertices[at] = positions[p];
        vertices[at + 1] = positions[p + 1];
        vertices[at + 2] = positions[p + 2];
        vertices[at + 3] = nx;
        vertices[at + 4] = ny;
        vertices[at + 5] = nz;
        final int uv = index * 2;
        if (uvs != null && uv + 1 < uvs.length) {
          vertices[at + 6] = uvs[uv];
          vertices[at + 7] = uvs[uv + 1];
        }
        out[written] = written;
        written++;
      }
    }
    if (written == 0) return null;
    return _createBuffers(
      Float32List.sublistView(vertices, 0, written * 8),
      Uint32List.sublistView(out, 0, written),
    );
  }

  static Uint32List _filterIndices(Uint32List indices, int vertexCount) {
    var bad = 0;
    for (var t = 0; t + 2 < indices.length; t += 3) {
      if (indices[t] >= vertexCount ||
          indices[t + 1] >= vertexCount ||
          indices[t + 2] >= vertexCount) {
        bad++;
      }
    }
    final int triangles = indices.length ~/ 3;
    if (bad == 0) {
      return triangles * 3 == indices.length
          ? indices
          : Uint32List.sublistView(indices, 0, triangles * 3);
    }
    final Uint32List out = Uint32List((triangles - bad) * 3);
    var at = 0;
    for (var t = 0; t + 2 < indices.length; t += 3) {
      if (indices[t] >= vertexCount ||
          indices[t + 1] >= vertexCount ||
          indices[t + 2] >= vertexCount) {
        continue;
      }
      out[at++] = indices[t];
      out[at++] = indices[t + 1];
      out[at++] = indices[t + 2];
    }
    return out;
  }

  _MeshBuffers? _createBuffers(Float32List vertices, Uint32List indices) {
    final VulkanBuffer? vertexBuffer = _geometryBuffer(
      'mesh vertices',
      vertices.lengthInBytes,
      VkBufferUsageFlagBits.VK_BUFFER_USAGE_VERTEX_BUFFER_BIT,
    );
    if (vertexBuffer == null) return null;
    final VulkanBuffer? indexBuffer = _geometryBuffer(
      'mesh indices',
      indices.lengthInBytes,
      VkBufferUsageFlagBits.VK_BUFFER_USAGE_INDEX_BUFFER_BIT,
    );
    if (indexBuffer == null) {
      vertexBuffer.dispose(_gpu);
      return null;
    }
    vertexBuffer.mapped
        .cast<Float>()
        .asTypedList(vertices.length)
        .setAll(0, vertices);
    indexBuffer.mapped
        .cast<Uint32>()
        .asTypedList(indices.length)
        .setAll(0, indices);
    // Explicit even though the memory is requested HOST_COHERENT: `flush` is a
    // documented no-op on a coherent allocation, and leaving it out would make
    // the code depend on a property of the *allocation* that the request only
    // asks for.
    _gpu.allocator
      ..flush(vertexBuffer.memory)
      ..flush(indexBuffer.memory);
    return _MeshBuffers(
      vertices: vertexBuffer,
      indices: indexBuffer,
      indexCount: indices.length,
      bytes: vertices.lengthInBytes + indices.lengthInBytes,
    );
  }

  /// A host-visible buffer that the allocator puts in device-local memory when
  /// this adapter has any that the CPU can write.
  ///
  /// `VulkanBuffer.create` cannot express the preference - it takes a bool -
  /// so this repeats its four calls to pass `preferred`. See the library
  /// comment for what the preference buys and what it costs when it is not
  /// honoured.
  VulkanBuffer? _geometryBuffer(String resource, int bytes, int usage) =>
      using((NativeArena arena) {
        final Pointer<VkBufferCreateInfo> info = arena<VkBufferCreateInfo>();
        info.ref
          ..sType = VkStructureType.VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO
          ..size = bytes
          ..usage = usage
          ..sharingMode = VkSharingMode.VK_SHARING_MODE_EXCLUSIVE;
        final Pointer<Pointer<VkBuffer_T>> out = arena<Pointer<VkBuffer_T>>();
        if (vkFailed(_gpu.api.createBuffer(_gpu.handle, info, nullptr, out))) {
          return null;
        }
        final Pointer<VkMemoryRequirements> requirements =
            arena<VkMemoryRequirements>();
        _gpu.api
            .getBufferMemoryRequirements(_gpu.handle, out.value, requirements);
        final VulkanAllocation allocation;
        try {
          allocation = _gpu.allocator.allocate(
            resource: resource,
            size: requirements.ref.size,
            alignment: requirements.ref.alignment,
            memoryTypeBits: requirements.ref.memoryTypeBits,
            required: VkMemoryPropertyFlagBits
                    .VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT |
                VkMemoryPropertyFlagBits.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
            preferred:
                VkMemoryPropertyFlagBits.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT,
            linear: true,
          );
        } on Object {
          _gpu.api.destroyBuffer(_gpu.handle, out.value, nullptr);
          return null;
        }
        if (vkFailed(_gpu.api.bindBufferMemory(
            _gpu.handle, out.value, allocation.memory, allocation.offset))) {
          _gpu.allocator.free(allocation);
          _gpu.api.destroyBuffer(_gpu.handle, out.value, nullptr);
          return null;
        }
        _bufferUploadCount++;
        return VulkanBuffer.adopt(out.value, allocation, bytes);
      });

  void _evictIfOverBudget(_MeshBufferKey keep) {
    var waited = false;
    while (_bufferBytes > bufferBudgetBytes && _buffers.length > 1) {
      _MeshBufferKey? oldest;
      var oldestUse = 1 << 62;
      for (final MapEntry<_MeshBufferKey, _MeshBuffers> entry
          in _buffers.entries) {
        if (entry.key == keep) continue;
        if (entry.value.lastUsed >= oldestUse) continue;
        oldestUse = entry.value.lastUsed;
        oldest = entry.key;
      }
      if (oldest == null) return;
      if (!waited && !_device.isLost) {
        _gpu.waitIdle();
        waited = true;
      }
      final _MeshBuffers evicted = _buffers.remove(oldest)!;
      _bufferBytes -= evicted.bytes;
      evicted.dispose(_gpu);
    }
  }

  /// Uploads [texture] once, as `B8G8R8A8_UNORM`.
  ///
  /// The format is the interesting part. [MeshTexture] stores `0xAARRGGBB`
  /// words, and a little-endian word of that lands in memory as B, G, R, A -
  /// which is exactly what `B8G8R8A8_UNORM` reads. Declaring
  /// `R8G8B8A8_UNORM` and uploading the same words would swap red and blue on
  /// every textured model.
  ///
  /// `VK_FORMAT_B8G8R8A8_UNORM` is not a format every device can sample - the
  /// specification guarantees only the RGBA one - so
  /// `VulkanRenderDevice.createTexture` refuses it where the device says no.
  /// The words are swapped on the CPU in that case, which is a copy the two
  /// Direct3D ports never make and the only alternative to not drawing the
  /// texture at all.
  VulkanTexture? _textureFor(MeshTexture texture) {
    final VulkanTexture? cached = _textures[texture];
    if (cached != null) return cached;
    if (texture.width <= 0 || texture.height <= 0) return null;
    final int bytes = texture.width * texture.height * 4;
    final Uint8List source = texture.pixels.buffer.asUint8List(
      texture.pixels.offsetInBytes,
      math.min(bytes, texture.pixels.lengthInBytes),
    );
    final Uint8List pixels = source.length == bytes
        ? source
        : (Uint8List(bytes)..setRange(0, source.length, source));

    final bool bgra =
        _gpu.physicalDevice.supportsSampling(VkFormat.VK_FORMAT_B8G8R8A8_UNORM);
    final VulkanTexture uploaded;
    try {
      uploaded = _device.createTexture(
        width: texture.width,
        height: texture.height,
        format: bgra
            ? GpuTextureFormat.bgra8888Premultiplied
            : GpuTextureFormat.rgba8888Premultiplied,
        filter: GpuTextureFilter.nearest,
      );
    } on Object {
      // A device out of descriptor sets or out of memory draws the model
      // untextured rather than losing the frame; the material's base colour is
      // still right and the shape is still there.
      return null;
    }
    final Uint8List payload;
    if (bgra) {
      payload = pixels;
    } else {
      payload = Uint8List(bytes);
      for (var i = 0; i < bytes; i += 4) {
        payload[i] = pixels[i + 2];
        payload[i + 1] = pixels[i + 1];
        payload[i + 2] = pixels[i];
        payload[i + 3] = pixels[i + 3];
      }
    }
    _device.uploadRegion(
      uploaded,
      x: 0,
      y: 0,
      width: texture.width,
      height: texture.height,
      pixels: payload,
      bytesPerRow: texture.width * 4,
    );
    _textures[texture] = uploaded;
    return uploaded;
  }

  // -------------------------------------------------------------------
  // Teardown
  // -------------------------------------------------------------------

  void _throwIfDisposed() {
    if (_disposed) {
      throw StateError('this VulkanMeshRenderer has been disposed');
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    // Every destroy below frees an object a command buffer may still be
    // executing against. Vulkan tracks none of that for the caller.
    if (!_device.isLost) _gpu.waitIdle();
    _dropFramebuffers();
    _destroyDepth();
    for (final _MeshBuffers entry in _buffers.values) {
      entry.dispose(_gpu);
    }
    _buffers.clear();
    _bufferBytes = 0;
    for (final VulkanTexture entry in _textures.values) {
      _device.releaseTexture(entry);
    }
    _textures.clear();
    _sets.clear();
    if (_descriptorPool != nullptr) {
      // The pool, not its sets: destroying a pool frees everything allocated
      // from it, and `vkFreeDescriptorSets` is not bound at all.
      _gpu.api.destroyDescriptorPool(_gpu.handle, _descriptorPool, nullptr);
      _descriptorPool = nullptr;
    }
    if (_sampler != nullptr) {
      _gpu.api.destroySampler(_gpu.handle, _sampler, nullptr);
      _sampler = nullptr;
    }
    final VulkanTexture? placeholder = _placeholder;
    if (placeholder != null) _device.releaseTexture(placeholder);
    _placeholder = null;
    for (final _MeshPassSet set in _passes.values) {
      set.dispose(_gpu);
    }
    _passes.clear();
    if (_layout != nullptr) {
      _gpu.api.destroyPipelineLayout(_gpu.handle, _layout, nullptr);
      _layout = nullptr;
    }
    // The descriptor set layout is **not** destroyed: it belongs to
    // `VulkanPipelines`, which is where it was borrowed from. Destroying it
    // here would leave every 2D pipeline on this device holding a freed
    // object.
    _setLayout = nullptr;
    for (final Pointer<VkShaderModule_T> module in <Pointer<VkShaderModule_T>>[
      _vertexModule,
      _fragmentModule,
    ]) {
      if (module != nullptr) {
        _gpu.api.destroyShaderModule(_gpu.handle, module, nullptr);
      }
    }
    _vertexModule = nullptr;
    _fragmentModule = nullptr;
  }
}

/// The render passes and pipelines for one colour format.
final class _MeshPassSet {
  _MeshPassSet._(this._device, this.clearPass, this.loadPass, this._pipelines,
      this._layout, this._vertex, this._fragment);

  /// The device every pipeline in [_pipelines] belongs to.
  ///
  /// Held rather than passed to [pipelineFor], because that method is called
  /// from inside a recorded frame where the caller has a command buffer and no
  /// reason to be carrying a device around.
  final VulkanDevice _device;

  final Pointer<VkRenderPass_T> clearPass;
  final Pointer<VkRenderPass_T> loadPass;
  final Map<int, Pointer<VkPipeline_T>> _pipelines;
  final Pointer<VkPipelineLayout_T> _layout;
  final Pointer<VkShaderModule_T> _vertex;
  final Pointer<VkShaderModule_T> _fragment;

  static _MeshPassSet? create(
    VulkanDevice device, {
    required int colorFormat,
    required int depthFormat,
    required Pointer<VkPipelineLayout_T> layout,
    required Pointer<VkShaderModule_T> vertex,
    required Pointer<VkShaderModule_T> fragment,
  }) {
    final Pointer<VkRenderPass_T> clearPass =
        _createRenderPass(device, colorFormat, depthFormat, clears: true);
    if (clearPass == nullptr) return null;
    final Pointer<VkRenderPass_T> loadPass =
        _createRenderPass(device, colorFormat, depthFormat, clears: false);
    if (loadPass == nullptr) {
      device.api.destroyRenderPass(device.handle, clearPass, nullptr);
      return null;
    }
    final set = _MeshPassSet._(device, clearPass, loadPass,
        <int, Pointer<VkPipeline_T>>{}, layout, vertex, fragment);
    // The pipeline for the ordinary draw, built now rather than on the first
    // frame: a driver compiles a pipeline the moment it is created, and the
    // one thing a 3D viewer must not do is stall for a shader compile between
    // `beginFrame` and `present`.
    if (set.pipelineFor(
          cull: true,
          test: VulkanMeshDepthTest.less,
          frontCcw: true,
        ) ==
        null) {
      set.dispose(device);
      return null;
    }
    return set;
  }

  /// The winding is part of the key so that flipping `frontCounterClockwise`
  /// mid-run builds a second pipeline rather than returning the first one and
  /// silently ignoring the change - which would make the sabotage test pass by
  /// doing nothing.
  static int _key({
    required bool cull,
    required VulkanMeshDepthTest test,
    required bool frontCcw,
  }) =>
      (cull ? 1 : 0) | (frontCcw ? 2 : 0) | (test.index << 2);

  Pointer<VkPipeline_T>? pipelineFor({
    required bool cull,
    required VulkanMeshDepthTest test,
    required bool frontCcw,
  }) {
    final int key = _key(cull: cull, test: test, frontCcw: frontCcw);
    final Pointer<VkPipeline_T>? cached = _pipelines[key];
    if (cached != null) return cached;
    final Pointer<VkPipeline_T> built = _createPipeline(
      _device,
      vertex: _vertex,
      fragment: _fragment,
      layout: _layout,
      renderPass: clearPass,
      cull: cull,
      test: test,
      frontCcw: frontCcw,
    );
    if (built == nullptr) return null;
    _pipelines[key] = built;
    return built;
  }

  void dispose(VulkanDevice device) {
    for (final Pointer<VkPipeline_T> pipeline in _pipelines.values) {
      device.api.destroyPipeline(device.handle, pipeline, nullptr);
    }
    _pipelines.clear();
    device.api
      ..destroyRenderPass(device.handle, clearPass, nullptr)
      ..destroyRenderPass(device.handle, loadPass, nullptr);
  }

  /// Colour plus depth. `vulkan_pipeline.dart::_createRenderPass` is the
  /// template; the second attachment and the `pDepthStencilAttachment` are the
  /// whole difference, and they are why this cannot reuse that pass: the nine
  /// 2D pipelines were compiled against a pass with one attachment and a pass
  /// with two is not compatible with them.
  static Pointer<VkRenderPass_T> _createRenderPass(
    VulkanDevice device,
    int colorFormat,
    int depthFormat, {
    required bool clears,
  }) =>
      using((NativeArena arena) {
        final Pointer<VkAttachmentDescription> attachments =
            arena<VkAttachmentDescription>(2);
        attachments[0]
          ..format = colorFormat
          ..samples = VkSampleCountFlagBits.VK_SAMPLE_COUNT_1_BIT
          ..loadOp = clears
              ? VkAttachmentLoadOp.VK_ATTACHMENT_LOAD_OP_CLEAR
              : VkAttachmentLoadOp.VK_ATTACHMENT_LOAD_OP_LOAD
          ..storeOp = VkAttachmentStoreOp.VK_ATTACHMENT_STORE_OP_STORE
          ..stencilLoadOp = VkAttachmentLoadOp.VK_ATTACHMENT_LOAD_OP_DONT_CARE
          ..stencilStoreOp =
              VkAttachmentStoreOp.VK_ATTACHMENT_STORE_OP_DONT_CARE
          ..initialLayout = clears
              ? VkImageLayout.VK_IMAGE_LAYOUT_UNDEFINED
              : VkImageLayout.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL
          ..finalLayout =
              VkImageLayout.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;
        attachments[1]
          ..format = depthFormat
          ..samples = VkSampleCountFlagBits.VK_SAMPLE_COUNT_1_BIT
          // Always CLEAR and always DONT_CARE on the way out. The depth buffer
          // belongs to this pipeline and means nothing between passes, so
          // storing it would be bandwidth spent on bytes nothing reads - and
          // `initialLayout = UNDEFINED` is what lets the image live its whole
          // life without a single barrier.
          ..loadOp = VkAttachmentLoadOp.VK_ATTACHMENT_LOAD_OP_CLEAR
          ..storeOp = VkAttachmentStoreOp.VK_ATTACHMENT_STORE_OP_DONT_CARE
          ..stencilLoadOp = VkAttachmentLoadOp.VK_ATTACHMENT_LOAD_OP_DONT_CARE
          ..stencilStoreOp =
              VkAttachmentStoreOp.VK_ATTACHMENT_STORE_OP_DONT_CARE
          ..initialLayout = VkImageLayout.VK_IMAGE_LAYOUT_UNDEFINED
          ..finalLayout =
              VkImageLayout.VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL;

        final Pointer<VkAttachmentReference> colorRef =
            arena<VkAttachmentReference>();
        colorRef.ref
          ..attachment = 0
          ..layout = VkImageLayout.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;
        final Pointer<VkAttachmentReference> depthRef =
            arena<VkAttachmentReference>();
        depthRef.ref
          ..attachment = 1
          ..layout =
              VkImageLayout.VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL;

        final Pointer<VkSubpassDescription> subpass =
            arena<VkSubpassDescription>();
        subpass.ref
          ..pipelineBindPoint =
              VkPipelineBindPoint.VK_PIPELINE_BIND_POINT_GRAPHICS
          ..colorAttachmentCount = 1
          ..pColorAttachments = colorRef
          ..pDepthStencilAttachment = depthRef;

        final Pointer<VkSubpassDependency> dependencies =
            arena<VkSubpassDependency>(2);
        dependencies[0]
          ..srcSubpass = vkSubpassExternal
          ..dstSubpass = 0
          // The depth stages as well as the colour one, because this pass
          // writes both. A dependency that named only colour would leave the
          // depth clear unordered against whatever touched the image before.
          ..srcStageMask = VkPipelineStageFlagBits
                  .VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT |
              VkPipelineStageFlagBits.VK_PIPELINE_STAGE_EARLY_FRAGMENT_TESTS_BIT
          ..dstStageMask = VkPipelineStageFlagBits
                  .VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT |
              VkPipelineStageFlagBits.VK_PIPELINE_STAGE_EARLY_FRAGMENT_TESTS_BIT
          ..srcAccessMask = 0
          ..dstAccessMask = VkAccessFlagBits
                  .VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT |
              VkAccessFlagBits.VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT |
              (clears
                  ? 0
                  : VkAccessFlagBits.VK_ACCESS_COLOR_ATTACHMENT_READ_BIT);
        dependencies[1]
          ..srcSubpass = 0
          ..dstSubpass = vkSubpassExternal
          ..srcStageMask = VkPipelineStageFlagBits
              .VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT
          ..dstStageMask =
              VkPipelineStageFlagBits.VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT
          ..srcAccessMask =
              VkAccessFlagBits.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT
          ..dstAccessMask = 0;

        final Pointer<VkRenderPassCreateInfo> info =
            arena<VkRenderPassCreateInfo>();
        info.ref
          ..sType = VkStructureType.VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO
          ..attachmentCount = 2
          ..pAttachments = attachments
          ..subpassCount = 1
          ..pSubpasses = subpass
          ..dependencyCount = 2
          ..pDependencies = dependencies;

        final Pointer<Pointer<VkRenderPass_T>> out =
            arena<Pointer<VkRenderPass_T>>();
        if (vkFailed(
            device.api.createRenderPass(device.handle, info, nullptr, out))) {
          return nullptr;
        }
        return out.value;
      });

  static Pointer<VkPipeline_T> _createPipeline(
    VulkanDevice device, {
    required Pointer<VkShaderModule_T> vertex,
    required Pointer<VkShaderModule_T> fragment,
    required Pointer<VkPipelineLayout_T> layout,
    required Pointer<VkRenderPass_T> renderPass,
    required bool cull,
    required VulkanMeshDepthTest test,
    required bool frontCcw,
  }) =>
      using((NativeArena arena) {
        final Pointer<Char> entryPoint =
            arena.allocateAscii(kVulkanMeshEntryPoint).cast<Char>();

        final Pointer<VkPipelineShaderStageCreateInfo> stages =
            arena<VkPipelineShaderStageCreateInfo>(2);
        stages[0]
          ..sType = VkStructureType
              .VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO
          ..stage = VkShaderStageFlagBits.VK_SHADER_STAGE_VERTEX_BIT
          ..module = vertex
          ..pName = entryPoint;
        stages[1]
          ..sType = VkStructureType
              .VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO
          ..stage = VkShaderStageFlagBits.VK_SHADER_STAGE_FRAGMENT_BIT
          ..module = fragment
          ..pName = entryPoint;

        final Pointer<VkVertexInputBindingDescription> binding =
            arena<VkVertexInputBindingDescription>();
        binding.ref
          ..binding = 0
          ..stride = kVulkanMeshVertexStrideBytes
          ..inputRate = VkVertexInputRate.VK_VERTEX_INPUT_RATE_VERTEX;

        final Pointer<VkVertexInputAttributeDescription> attributes =
            arena<VkVertexInputAttributeDescription>(3);
        attributes[0]
          ..location = kVulkanMeshAttributePosition
          ..binding = 0
          ..format = VkFormat.VK_FORMAT_R32G32B32_SFLOAT
          ..offset = kVulkanMeshPositionOffset;
        attributes[1]
          ..location = kVulkanMeshAttributeNormal
          ..binding = 0
          ..format = VkFormat.VK_FORMAT_R32G32B32_SFLOAT
          ..offset = kVulkanMeshNormalOffset;
        attributes[2]
          ..location = kVulkanMeshAttributeTexCoord
          ..binding = 0
          ..format = VkFormat.VK_FORMAT_R32G32_SFLOAT
          ..offset = kVulkanMeshTexCoordOffset;

        final Pointer<VkPipelineVertexInputStateCreateInfo> vertexInput =
            arena<VkPipelineVertexInputStateCreateInfo>();
        vertexInput.ref
          ..sType = VkStructureType
              .VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO
          ..vertexBindingDescriptionCount = 1
          ..pVertexBindingDescriptions = binding
          ..vertexAttributeDescriptionCount = 3
          ..pVertexAttributeDescriptions = attributes;

        final Pointer<VkPipelineInputAssemblyStateCreateInfo> assembly =
            arena<VkPipelineInputAssemblyStateCreateInfo>();
        assembly.ref
          ..sType = VkStructureType
              .VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO
          ..topology = VkPrimitiveTopology.VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST;

        final Pointer<VkPipelineViewportStateCreateInfo> viewport =
            arena<VkPipelineViewportStateCreateInfo>();
        viewport.ref
          ..sType = VkStructureType
              .VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO
          ..viewportCount = 1
          ..scissorCount = 1;

        final Pointer<VkPipelineRasterizationStateCreateInfo> raster =
            arena<VkPipelineRasterizationStateCreateInfo>();
        raster.ref
          ..sType = VkStructureType
              .VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO
          // FILL for every shading mode, wireframe included. See
          // `vulkan_mesh_shaders.dart`, "Disagreement V4".
          ..polygonMode = VkPolygonMode.VK_POLYGON_MODE_FILL
          ..cullMode = cull
              ? VkCullModeFlagBits.VK_CULL_MODE_BACK_BIT
              : VkCullModeFlagBits.VK_CULL_MODE_NONE
          // `MeshRasterizer` culls the triangle whose screen-space signed area
          // is positive, which with y down is the clockwise one, so declaring
          // counter-clockwise to be the front makes Vulkan's "back" the same
          // set of triangles. Getting it backwards culls exactly the triangles
          // the CPU keeps and the model is drawn inside out.
          ..frontFace = frontCcw
              ? VkFrontFace.VK_FRONT_FACE_COUNTER_CLOCKWISE
              : VkFrontFace.VK_FRONT_FACE_CLOCKWISE
          ..lineWidth = 1;

        final Pointer<VkPipelineMultisampleStateCreateInfo> multisample =
            arena<VkPipelineMultisampleStateCreateInfo>();
        multisample.ref
          ..sType = VkStructureType
              .VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO
          ..rasterizationSamples = VkSampleCountFlagBits.VK_SAMPLE_COUNT_1_BIT
          ..minSampleShading = 1;

        final Pointer<VkPipelineDepthStencilStateCreateInfo> depth =
            arena<VkPipelineDepthStencilStateCreateInfo>();
        depth.ref
          ..sType = VkStructureType
              .VK_STRUCTURE_TYPE_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO
          ..depthTestEnable =
              test == VulkanMeshDepthTest.always ? vkFalse : vkTrue
          ..depthWriteEnable = vkTrue
          ..depthCompareOp = switch (test) {
            VulkanMeshDepthTest.less => VkCompareOp.VK_COMPARE_OP_LESS,
            VulkanMeshDepthTest.greater => VkCompareOp.VK_COMPARE_OP_GREATER,
            VulkanMeshDepthTest.always => VkCompareOp.VK_COMPARE_OP_ALWAYS,
          }
          // Zero, and not merely unset: the `depthBounds` device feature is not
          // enabled - `VulkanDevice.open` enables none - so a non-zero value
          // here is invalid use rather than a bounds test.
          ..depthBoundsTestEnable = vkFalse
          ..stencilTestEnable = vkFalse
          ..minDepthBounds = 0
          ..maxDepthBounds = 1;

        final Pointer<VkPipelineColorBlendAttachmentState> blendAttachment =
            arena<VkPipelineColorBlendAttachmentState>();
        // Blending off, all four channels written. `MeshRasterizer` writes
        // `argb | 0xFF000000` at every pixel that passes the depth test, so the
        // model is opaque by construction, and blending it over a 2D pass would
        // be invisible on a cleared target and very visible on one with an
        // interface already on it.
        blendAttachment.ref
          ..blendEnable = vkFalse
          ..srcColorBlendFactor = VkBlendFactor.VK_BLEND_FACTOR_ONE
          ..dstColorBlendFactor = VkBlendFactor.VK_BLEND_FACTOR_ZERO
          ..colorBlendOp = VkBlendOp.VK_BLEND_OP_ADD
          ..srcAlphaBlendFactor = VkBlendFactor.VK_BLEND_FACTOR_ONE
          ..dstAlphaBlendFactor = VkBlendFactor.VK_BLEND_FACTOR_ZERO
          ..alphaBlendOp = VkBlendOp.VK_BLEND_OP_ADD
          ..colorWriteMask = VkColorComponentFlagBits.VK_COLOR_COMPONENT_R_BIT |
              VkColorComponentFlagBits.VK_COLOR_COMPONENT_G_BIT |
              VkColorComponentFlagBits.VK_COLOR_COMPONENT_B_BIT |
              VkColorComponentFlagBits.VK_COLOR_COMPONENT_A_BIT;

        final Pointer<VkPipelineColorBlendStateCreateInfo> colorBlend =
            arena<VkPipelineColorBlendStateCreateInfo>();
        colorBlend.ref
          ..sType = VkStructureType
              .VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO
          ..attachmentCount = 1
          ..pAttachments = blendAttachment;

        // `UnsignedInt` and not `Uint32`: `pDynamicStates` is an enum array and
        // the generated binding types it as the C `unsigned int` it is.
        final Pointer<UnsignedInt> dynamicStates = arena<UnsignedInt>(2);
        dynamicStates[0] = VkDynamicState.VK_DYNAMIC_STATE_VIEWPORT;
        dynamicStates[1] = VkDynamicState.VK_DYNAMIC_STATE_SCISSOR;
        final Pointer<VkPipelineDynamicStateCreateInfo> dynamic =
            arena<VkPipelineDynamicStateCreateInfo>();
        dynamic.ref
          ..sType = VkStructureType
              .VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO
          ..dynamicStateCount = 2
          ..pDynamicStates = dynamicStates;

        final Pointer<VkGraphicsPipelineCreateInfo> info =
            arena<VkGraphicsPipelineCreateInfo>();
        info.ref
          ..sType =
              VkStructureType.VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO
          ..stageCount = 2
          ..pStages = stages
          ..pVertexInputState = vertexInput
          ..pInputAssemblyState = assembly
          ..pViewportState = viewport
          ..pRasterizationState = raster
          ..pMultisampleState = multisample
          ..pDepthStencilState = depth
          ..pColorBlendState = colorBlend
          ..pDynamicState = dynamic
          ..layout = layout
          ..renderPass = renderPass
          ..subpass = 0
          ..basePipelineIndex = -1;

        final Pointer<Pointer<VkPipeline_T>> out =
            arena<Pointer<VkPipeline_T>>();
        if (vkFailed(device.api.createGraphicsPipelines(
            device.handle, nullptr, 1, info, nullptr, out))) {
          return nullptr;
        }
        return out.value;
      });
}

/// One primitive's worth of a recorded frame.
final class _MeshDraw {
  const _MeshDraw({
    required this.buffers,
    required this.texture,
    required this.colorArgb,
    required this.cull,
  });

  final _MeshBuffers buffers;
  final VulkanTexture? texture;
  final int colorArgb;
  final bool cull;
}

/// Which normals a cached vertex stream carries.
enum _MeshNormalSource {
  /// The file's normals, or smooth ones derived from the faces.
  perVertex,

  /// One normal per triangle, which needs a de-indexed stream.
  perFace,
}

/// Identity of a primitive plus the normals its stream was built with.
final class _MeshBufferKey {
  const _MeshBufferKey(this.primitive, this.source);

  final MeshPrimitive primitive;
  final _MeshNormalSource source;

  @override
  bool operator ==(Object other) =>
      other is _MeshBufferKey &&
      identical(other.primitive, primitive) &&
      other.source == source;

  @override
  int get hashCode => Object.hash(identityHashCode(primitive), source);
}

final class _MeshBuffers {
  _MeshBuffers({
    required this.vertices,
    required this.indices,
    required this.indexCount,
    required this.bytes,
  });

  final VulkanBuffer vertices;
  final VulkanBuffer indices;
  final int indexCount;
  final int bytes;

  /// The renderer's monotonic draw counter when this was last used, which is
  /// what makes the eviction least-recently-used rather than arbitrary.
  int lastUsed = 0;

  void dispose(VulkanDevice device) {
    vertices.dispose(device);
    indices.dispose(device);
  }
}
