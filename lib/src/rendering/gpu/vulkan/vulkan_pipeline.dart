/// The render pass, the pipeline layout and the nine graphics pipelines.
///
/// ## Why nine
///
/// A `VkPipeline` bakes in everything Direct3D 11 and OpenGL let a caller
/// change between draws: the shaders, the vertex layout, the blend state. This
/// renderer varies exactly two of those - the fragment mode (three, one per
/// [GpuPipelineKind]) and the blend equation (three, one per display-list
/// blend mode) - so the full cross product is nine objects, built once at
/// device creation and never rebuilt.
///
/// Nine is small enough to build eagerly, which is the point. Building them
/// lazily would move a multi-millisecond compile into the first frame that
/// happens to draw with `blendModePlus`, which is a stutter nobody can trace
/// back to its cause. Building all nine up front turns "this driver cannot
/// compile the shader" into a device that refuses to open, which is where the
/// caller can still choose another backend.
///
/// ## Two render passes, one set of pipelines
///
/// Whether a frame clears its target is a per-frame decision, and `loadOp` is
/// baked into a `VkRenderPass`. So there are two passes - one that clears and
/// one that preserves - and the *same* nine pipelines work with both, because
/// Vulkan's render-pass compatibility rule looks only at the attachments'
/// formats and sample counts, not at their load and store operations. Building
/// eighteen pipelines instead would be a straightforward and entirely
/// unnecessary doubling.
library;

import 'dart:ffi';
import 'dart:typed_data';

import '../../../ffi/native_memory.dart';
import '../../../graphics/display_list_opcodes.dart';
import '../gpu_pipeline.dart';
import 'vulkan_constants.dart';
import 'vulkan_device.dart';
import 'vulkan_ffi.g.dart';
import 'vulkan_shaders.dart';

/// Bytes between one vertex and the next: [kGpuFloatsPerVertex] floats.
const int kVulkanVertexStride = kGpuFloatsPerVertex * 4;

/// The blend modes a pipeline is built for, in the order they are indexed.
///
/// The display list encodes exactly these three (`gpu_pipeline.dart`), and
/// [gpuBlendForMode] throws on a fourth. Keeping the list here rather than
/// deriving it from a `switch` means a mode added to the display list is a
/// missing entry in one place instead of a pipeline that silently is not
/// built.
const List<int> kVulkanBlendModes = <int>[
  blendModeSrcOver,
  blendModeSrc,
  blendModePlus,
];

/// Everything a device compiles once and keeps.
final class VulkanPipelines {
  VulkanPipelines._({
    required this.colorFormat,
    required this.clearRenderPass,
    required this.loadRenderPass,
    required this.descriptorSetLayout,
    required this.layout,
    required List<Pointer<VkPipeline_T>> pipelines,
    required this.shaderWords,
  }) : _pipelines = pipelines;

  /// The attachment format every pipeline here was built for. A target with a
  /// different format needs its own [VulkanPipelines]; using these would be a
  /// render pass incompatibility the driver reports and the caller cannot fix.
  final int colorFormat;

  final Pointer<VkRenderPass_T> clearRenderPass;
  final Pointer<VkRenderPass_T> loadRenderPass;
  final Pointer<VkDescriptorSetLayout_T> descriptorSetLayout;
  final Pointer<VkPipelineLayout_T> layout;

  /// Total SPIR-V words compiled, for a diagnostic.
  final int shaderWords;

  final List<Pointer<VkPipeline_T>> _pipelines;

  int get pipelineCount => _pipelines.length;

  /// The pipeline for [kind] under [blendMode].
  ///
  /// Throws on a blend mode with no pipeline rather than substituting
  /// source-over, for the reason [gpuBlendForMode] gives: a blend that quietly
  /// becomes source-over draws a picture that looks like a paint bug.
  Pointer<VkPipeline_T> pipelineFor(GpuPipelineKind kind, int blendMode) {
    final int blend = kVulkanBlendModes.indexOf(blendMode);
    if (blend < 0) {
      throw ArgumentError.value(
        blendMode,
        'blendMode',
        'no Vulkan pipeline was built for it; the three in '
            'kVulkanBlendModes are the three the display list encodes',
      );
    }
    return _pipelines[kind.index * kVulkanBlendModes.length + blend];
  }

  /// Builds everything, or returns null after releasing whatever was made.
  ///
  /// Null rather than an exception because a driver that refuses a pipeline is
  /// a backend that cannot be used, not a bug in the caller; the caller turns
  /// it into a [BackendDiagnostic] with the device's name attached.
  static VulkanPipelines? create(
    VulkanDevice device, {
    required int colorFormat,
  }) {
    final VulkanShaderCode code = VulkanShaderCode();
    final NativeArena arena = NativeArena();
    final List<Pointer<VkShaderModule_T>> modules =
        <Pointer<VkShaderModule_T>>[];
    Pointer<VkRenderPass_T> clearPass = nullptr;
    Pointer<VkRenderPass_T> loadPass = nullptr;
    Pointer<VkDescriptorSetLayout_T> setLayout = nullptr;
    Pointer<VkPipelineLayout_T> layout = nullptr;
    final List<Pointer<VkPipeline_T>> pipelines = <Pointer<VkPipeline_T>>[];

    void releaseAll() {
      for (final Pointer<VkPipeline_T> pipeline in pipelines) {
        device.api.destroyPipeline(device.handle, pipeline, nullptr);
      }
      if (layout != nullptr) {
        device.api.destroyPipelineLayout(device.handle, layout, nullptr);
      }
      if (setLayout != nullptr) {
        device.api
            .destroyDescriptorSetLayout(device.handle, setLayout, nullptr);
      }
      if (clearPass != nullptr) {
        device.api.destroyRenderPass(device.handle, clearPass, nullptr);
      }
      if (loadPass != nullptr) {
        device.api.destroyRenderPass(device.handle, loadPass, nullptr);
      }
    }

    try {
      clearPass = _createRenderPass(device, arena, colorFormat, clears: true);
      if (clearPass == nullptr) return null;
      loadPass = _createRenderPass(device, arena, colorFormat, clears: false);
      if (loadPass == nullptr) {
        releaseAll();
        return null;
      }

      setLayout = _createDescriptorSetLayout(device, arena);
      if (setLayout == nullptr) {
        releaseAll();
        return null;
      }
      layout = _createPipelineLayout(device, arena, setLayout);
      if (layout == nullptr) {
        releaseAll();
        return null;
      }

      final Pointer<VkShaderModule_T> vertex =
          _createShaderModule(device, arena, code.vertex);
      if (vertex == nullptr) {
        releaseAll();
        return null;
      }
      modules.add(vertex);

      for (final GpuPipelineKind kind in GpuPipelineKind.values) {
        final Pointer<VkShaderModule_T> fragment =
            _createShaderModule(device, arena, code.fragmentFor(kind));
        if (fragment == nullptr) {
          releaseAll();
          return null;
        }
        modules.add(fragment);
        for (final int blendMode in kVulkanBlendModes) {
          final Pointer<VkPipeline_T> pipeline = _createPipeline(
            device,
            arena,
            vertex: vertex,
            fragment: fragment,
            layout: layout,
            renderPass: clearPass,
            blend: gpuBlendForMode(blendMode),
          );
          if (pipeline == nullptr) {
            releaseAll();
            return null;
          }
          pipelines.add(pipeline);
        }
      }

      return VulkanPipelines._(
        colorFormat: colorFormat,
        clearRenderPass: clearPass,
        loadRenderPass: loadPass,
        descriptorSetLayout: setLayout,
        layout: layout,
        pipelines: pipelines,
        shaderWords: code.wordCount,
      );
    } finally {
      // The modules can go the moment the pipelines exist: a VkShaderModule is
      // a parsed copy of the SPIR-V, and vkCreateGraphicsPipelines has already
      // taken everything it needs from it.
      for (final Pointer<VkShaderModule_T> module in modules) {
        device.api.destroyShaderModule(device.handle, module, nullptr);
      }
      arena.dispose();
    }
  }

  void dispose(VulkanDevice device) {
    for (final Pointer<VkPipeline_T> pipeline in _pipelines) {
      device.api.destroyPipeline(device.handle, pipeline, nullptr);
    }
    _pipelines.clear();
    device.api
      ..destroyPipelineLayout(device.handle, layout, nullptr)
      ..destroyDescriptorSetLayout(device.handle, descriptorSetLayout, nullptr)
      ..destroyRenderPass(device.handle, clearRenderPass, nullptr)
      ..destroyRenderPass(device.handle, loadRenderPass, nullptr);
  }

  static Pointer<VkShaderModule_T> _createShaderModule(
    VulkanDevice device,
    NativeArena arena,
    Uint32List words,
  ) {
    final Pointer<Uint32> code = arena<Uint32>(words.length);
    code.asTypedList(words.length).setAll(0, words);
    final Pointer<VkShaderModuleCreateInfo> info =
        arena<VkShaderModuleCreateInfo>();
    info.ref
      ..sType = VkStructureType.VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO
      // Bytes, not words. Passing the word count is a module the driver reads
      // a quarter of and rejects with a message about a truncated stream.
      ..codeSize = words.length * 4
      ..pCode = code;
    final Pointer<Pointer<VkShaderModule_T>> out =
        arena<Pointer<VkShaderModule_T>>();
    if (vkFailed(
        device.api.createShaderModule(device.handle, info, nullptr, out))) {
      return nullptr;
    }
    return out.value;
  }

  static Pointer<VkRenderPass_T> _createRenderPass(
    VulkanDevice device,
    NativeArena arena,
    int colorFormat, {
    required bool clears,
  }) {
    final Pointer<VkAttachmentDescription> attachment =
        arena<VkAttachmentDescription>();
    attachment.ref
      ..format = colorFormat
      ..samples = VkSampleCountFlagBits.VK_SAMPLE_COUNT_1_BIT
      ..loadOp = clears
          ? VkAttachmentLoadOp.VK_ATTACHMENT_LOAD_OP_CLEAR
          : VkAttachmentLoadOp.VK_ATTACHMENT_LOAD_OP_LOAD
      ..storeOp = VkAttachmentStoreOp.VK_ATTACHMENT_STORE_OP_STORE
      ..stencilLoadOp = VkAttachmentLoadOp.VK_ATTACHMENT_LOAD_OP_DONT_CARE
      ..stencilStoreOp = VkAttachmentStoreOp.VK_ATTACHMENT_STORE_OP_DONT_CARE
      // UNDEFINED when clearing, because the previous contents are about to be
      // overwritten and promising to preserve them costs a driver a resolve it
      // does not need. COLOR_ATTACHMENT_OPTIMAL when loading, because the only
      // way there is content worth loading is that a previous pass left it in
      // that layout.
      ..initialLayout = clears
          ? VkImageLayout.VK_IMAGE_LAYOUT_UNDEFINED
          : VkImageLayout.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL
      ..finalLayout = VkImageLayout.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;

    final Pointer<VkAttachmentReference> reference =
        arena<VkAttachmentReference>();
    reference.ref
      ..attachment = 0
      ..layout = VkImageLayout.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;

    final Pointer<VkSubpassDescription> subpass = arena<VkSubpassDescription>();
    subpass.ref
      ..pipelineBindPoint = VkPipelineBindPoint.VK_PIPELINE_BIND_POINT_GRAPHICS
      ..colorAttachmentCount = 1
      ..pColorAttachments = reference;

    // Two dependencies, and they are not decoration. Without the first, the
    // colour writes of this pass are not ordered after whatever touched the
    // image before it - an upload, or the previous frame - and the driver is
    // free to begin them early. Without the second, a later transfer read (the
    // readback) is not ordered after the writes, and the pixels copied out are
    // whatever was there when the copy started.
    final Pointer<VkSubpassDependency> dependencies =
        arena<VkSubpassDependency>(2);
    dependencies[0]
      ..srcSubpass = vkSubpassExternal
      ..dstSubpass = 0
      ..srcStageMask =
          VkPipelineStageFlagBits.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT
      ..dstStageMask =
          VkPipelineStageFlagBits.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT
      ..srcAccessMask = 0
      ..dstAccessMask = VkAccessFlagBits.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT |
          (clears ? 0 : VkAccessFlagBits.VK_ACCESS_COLOR_ATTACHMENT_READ_BIT);
    dependencies[1]
      ..srcSubpass = 0
      ..dstSubpass = vkSubpassExternal
      ..srcStageMask =
          VkPipelineStageFlagBits.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT
      ..dstStageMask =
          VkPipelineStageFlagBits.VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT
      ..srcAccessMask = VkAccessFlagBits.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT
      ..dstAccessMask = 0;

    final Pointer<VkRenderPassCreateInfo> info =
        arena<VkRenderPassCreateInfo>();
    info.ref
      ..sType = VkStructureType.VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO
      ..attachmentCount = 1
      ..pAttachments = attachment
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
  }

  static Pointer<VkDescriptorSetLayout_T> _createDescriptorSetLayout(
    VulkanDevice device,
    NativeArena arena,
  ) {
    final Pointer<VkDescriptorSetLayoutBinding> binding =
        arena<VkDescriptorSetLayoutBinding>();
    binding.ref
      ..binding = kVulkanTextureBinding
      ..descriptorType =
          VkDescriptorType.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER
      ..descriptorCount = 1
      ..stageFlags = VkShaderStageFlagBits.VK_SHADER_STAGE_FRAGMENT_BIT;

    final Pointer<VkDescriptorSetLayoutCreateInfo> info =
        arena<VkDescriptorSetLayoutCreateInfo>();
    info.ref
      ..sType =
          VkStructureType.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO
      ..bindingCount = 1
      ..pBindings = binding;

    final Pointer<Pointer<VkDescriptorSetLayout_T>> out =
        arena<Pointer<VkDescriptorSetLayout_T>>();
    if (vkFailed(device.api
        .createDescriptorSetLayout(device.handle, info, nullptr, out))) {
      return nullptr;
    }
    return out.value;
  }

  static Pointer<VkPipelineLayout_T> _createPipelineLayout(
    VulkanDevice device,
    NativeArena arena,
    Pointer<VkDescriptorSetLayout_T> setLayout,
  ) {
    final Pointer<VkPushConstantRange> range = arena<VkPushConstantRange>();
    range.ref
      ..stageFlags = VkShaderStageFlagBits.VK_SHADER_STAGE_VERTEX_BIT
      ..offset = 0
      ..size = kVulkanPushConstantBytes;

    final Pointer<Pointer<VkDescriptorSetLayout_T>> layouts =
        arena<Pointer<VkDescriptorSetLayout_T>>();
    layouts.value = setLayout;

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
        device.api.createPipelineLayout(device.handle, info, nullptr, out))) {
      return nullptr;
    }
    return out.value;
  }

  static int _blendFactor(GpuBlendFactor factor) => switch (factor) {
        GpuBlendFactor.zero => VkBlendFactor.VK_BLEND_FACTOR_ZERO,
        GpuBlendFactor.one => VkBlendFactor.VK_BLEND_FACTOR_ONE,
        GpuBlendFactor.oneMinusSrcAlpha =>
          VkBlendFactor.VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA,
      };

  static Pointer<VkPipeline_T> _createPipeline(
    VulkanDevice device,
    NativeArena arena, {
    required Pointer<VkShaderModule_T> vertex,
    required Pointer<VkShaderModule_T> fragment,
    required Pointer<VkPipelineLayout_T> layout,
    required Pointer<VkRenderPass_T> renderPass,
    required GpuBlendState blend,
  }) {
    final Pointer<Char> entryPoint =
        arena.allocateAscii(kVulkanEntryPoint).cast<Char>();

    final Pointer<VkPipelineShaderStageCreateInfo> stages =
        arena<VkPipelineShaderStageCreateInfo>(2);
    stages[0]
      ..sType =
          VkStructureType.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO
      ..stage = VkShaderStageFlagBits.VK_SHADER_STAGE_VERTEX_BIT
      ..module = vertex
      ..pName = entryPoint;
    stages[1]
      ..sType =
          VkStructureType.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO
      ..stage = VkShaderStageFlagBits.VK_SHADER_STAGE_FRAGMENT_BIT
      ..module = fragment
      ..pName = entryPoint;

    final Pointer<VkVertexInputBindingDescription> binding =
        arena<VkVertexInputBindingDescription>();
    binding.ref
      ..binding = 0
      ..stride = kVulkanVertexStride
      ..inputRate = VkVertexInputRate.VK_VERTEX_INPUT_RATE_VERTEX;

    // The one interleaved layout of `gpu_pipeline.dart`, in Vulkan's spelling.
    // The offsets are floats there and bytes here, which is the single most
    // likely place for this file to be wrong - so they are multiplied from the
    // shared constants rather than written out.
    final Pointer<VkVertexInputAttributeDescription> attributes =
        arena<VkVertexInputAttributeDescription>(4);
    attributes[0]
      ..location = kVulkanAttributePosition
      ..binding = 0
      ..format = VkFormat.VK_FORMAT_R32G32_SFLOAT
      ..offset = kGpuPositionOffset * 4;
    attributes[1]
      ..location = kVulkanAttributeTexCoord
      ..binding = 0
      ..format = VkFormat.VK_FORMAT_R32G32_SFLOAT
      ..offset = kGpuTexCoordOffset * 4;
    attributes[2]
      ..location = kVulkanAttributeColor
      ..binding = 0
      ..format = VkFormat.VK_FORMAT_R32G32B32A32_SFLOAT
      ..offset = kGpuColorOffset * 4;
    attributes[3]
      ..location = kVulkanAttributeShapeRect
      ..binding = 0
      ..format = VkFormat.VK_FORMAT_R32G32B32A32_SFLOAT
      ..offset = kGpuShapeRectOffset * 4;

    final Pointer<VkPipelineVertexInputStateCreateInfo> vertexInput =
        arena<VkPipelineVertexInputStateCreateInfo>();
    vertexInput.ref
      ..sType = VkStructureType
          .VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO
      ..vertexBindingDescriptionCount = 1
      ..pVertexBindingDescriptions = binding
      ..vertexAttributeDescriptionCount = 4
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
      ..sType =
          VkStructureType.VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO
      ..viewportCount = 1
      ..scissorCount = 1;

    final Pointer<VkPipelineRasterizationStateCreateInfo> raster =
        arena<VkPipelineRasterizationStateCreateInfo>();
    raster.ref
      ..sType = VkStructureType
          .VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO
      ..polygonMode = VkPolygonMode.VK_POLYGON_MODE_FILL
      // No culling, and this is load-bearing: `GpuVertexBuffer` emits its quad
      // as top-left, top-right, bottom-right, bottom-left, which is clockwise
      // in y-down device space. With culling on, whichever winding the driver
      // decided was front would make every quad in the renderer invisible.
      ..cullMode = VkCullModeFlagBits.VK_CULL_MODE_NONE
      ..frontFace = VkFrontFace.VK_FRONT_FACE_COUNTER_CLOCKWISE
      // Required to be 1.0 unless the wideLines feature is enabled, and this
      // device enables no features at all.
      ..lineWidth = 1;

    final Pointer<VkPipelineMultisampleStateCreateInfo> multisample =
        arena<VkPipelineMultisampleStateCreateInfo>();
    multisample.ref
      ..sType = VkStructureType
          .VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO
      ..rasterizationSamples = VkSampleCountFlagBits.VK_SAMPLE_COUNT_1_BIT
      ..minSampleShading = 1;

    final Pointer<VkPipelineColorBlendAttachmentState> blendAttachment =
        arena<VkPipelineColorBlendAttachmentState>();
    blendAttachment.ref
      ..blendEnable = vkTrue
      ..srcColorBlendFactor = _blendFactor(blend.source)
      ..dstColorBlendFactor = _blendFactor(blend.destination)
      ..colorBlendOp = VkBlendOp.VK_BLEND_OP_ADD
      // The alpha channel gets the same factors as the colour channels. That
      // is correct precisely because everything here is premultiplied: for
      // source-over the equation is `a = as + ad * (1 - as)` in both, and
      // giving alpha its own factors is how a premultiplied pipeline ends up
      // with an alpha that no longer matches its colour.
      ..srcAlphaBlendFactor = _blendFactor(blend.source)
      ..dstAlphaBlendFactor = _blendFactor(blend.destination)
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

    // `UnsignedInt` and not `Uint32`: `pDynamicStates` is a `const
    // VkDynamicState*`, which is an enum, and the generated binding types an
    // enum array as the C `unsigned int` it is. Identical in width on every
    // platform this runs on, and the type system is right to insist on the
    // spelling rather than let two names for four bytes drift apart.
    final Pointer<UnsignedInt> dynamicStates = arena<UnsignedInt>(2);
    dynamicStates[0] = VkDynamicState.VK_DYNAMIC_STATE_VIEWPORT;
    dynamicStates[1] = VkDynamicState.VK_DYNAMIC_STATE_SCISSOR;
    final Pointer<VkPipelineDynamicStateCreateInfo> dynamic =
        arena<VkPipelineDynamicStateCreateInfo>();
    dynamic.ref
      ..sType =
          VkStructureType.VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO
      ..dynamicStateCount = 2
      ..pDynamicStates = dynamicStates;

    final Pointer<VkGraphicsPipelineCreateInfo> info =
        arena<VkGraphicsPipelineCreateInfo>();
    info.ref
      ..sType = VkStructureType.VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO
      ..stageCount = 2
      ..pStages = stages
      ..pVertexInputState = vertexInput
      ..pInputAssemblyState = assembly
      ..pViewportState = viewport
      ..pRasterizationState = raster
      ..pMultisampleState = multisample
      ..pColorBlendState = colorBlend
      ..pDynamicState = dynamic
      ..layout = layout
      ..renderPass = renderPass
      ..subpass = 0
      ..basePipelineIndex = -1;

    final Pointer<Pointer<VkPipeline_T>> out = arena<Pointer<VkPipeline_T>>();
    if (vkFailed(device.api.createGraphicsPipelines(
        device.handle, nullptr, 1, info, nullptr, out))) {
      return nullptr;
    }
    return out.value;
  }
}
