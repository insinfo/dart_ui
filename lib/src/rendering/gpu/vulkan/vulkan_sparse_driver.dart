/// The real Vulkan adapter behind [SparseVulkanDriver], and the pipelines it
/// binds.
///
/// `vulkan_sparse_executor.dart` owns the policy and names no API; this file is
/// the other half, and everything it does is a `vkCmd*` call or an object the
/// device keeps. The split is the same one `d3d12_sparse_driver.dart` makes and
/// exists for the same reason: the ordering rules are testable with a fake on a
/// runner that has no GPU, and what is left here is only what a driver can
/// disagree about.
///
/// ## Three Vulkan facts this file is shaped by
///
/// **1. A pipeline is the whole cross product.** Blend factors, the fragment
/// module, the vertex layout and the topology are all baked into a
/// `VkPipeline`, so `setBlendState` and `setSparseMode` cannot bind anything -
/// they *record* which coordinate changed, and the draw resolves the twelve-way
/// choice at the last moment. Twelve is four fragment modules (coverage x
/// paint) times three blend states, built eagerly when the pipeline is created
/// so that "this driver cannot compile the shader" surfaces at opt-in time and
/// not in the first frame that happens to draw a gradient.
///
/// **2. A copy cannot be recorded inside a render pass.** The dense renderer
/// stages every upload of a frame into one buffer and records them all in a
/// single pass before `vkCmdBeginRenderPass`. By the time a sparse submission
/// runs, that moment has gone by - and re-using the dense staging buffer would
/// mean writing over bytes whose `vkCmdCopyBufferToImage` has been recorded and
/// not yet executed, which is a corruption that only shows up under load. So
/// this driver stages its coverage pages into its **own** buffer, records its
/// own copies and barriers when the pass opens, and only then begins a render
/// pass of its own.
///
/// **3. A second render pass is the cheap way to land after the dense draws.**
/// `VulkanPipelines` already builds a `loadRenderPass` whose `loadOp` preserves
/// the attachment, and render-pass compatibility looks only at attachment
/// formats and sample counts - so the sparse pipelines are built against the
/// clearing pass and used with the loading one, exactly as the dense pipelines
/// are. The alternative, threading the sparse draws into the dense pass, would
/// have meant the sparse uploads happening a frame early or the dense pass
/// being split anyway.
///
/// ## What the caller still owns
///
/// The command buffer. [VulkanApiSparseDriver.bindCommandBuffer] is how the
/// target hands one over and how it says which framebuffer and how big it is;
/// nothing here opens a frame, submits a queue or waits on a fence. That keeps
/// the sparse pass inside the target's existing frame, which is the only way
/// the readback that follows it sees its pixels.
library;

import 'dart:ffi';
import 'dart:typed_data';

import '../../../ffi/native_memory.dart';
import '../gpu_gradient.dart';
import '../gpu_pipeline.dart';
import '../gpu_texture.dart';
import 'vulkan_backend.dart';
import 'vulkan_constants.dart';
import 'vulkan_device.dart';
import 'vulkan_ffi.g.dart';
import 'vulkan_pipeline.dart';
import 'vulkan_sparse_executor.dart';
import 'vulkan_sparse_strips.dart';

/// The blend states the sparse pipelines are built for, in the order they are
/// indexed.
///
/// Derived from [kVulkanBlendModes] rather than written out, so a mode added to
/// the display list is a pipeline that appears here too. Two modes that map to
/// the same factor pair would produce two identical pipelines, which is waste
/// and not a bug; today the three are distinct.
List<GpuBlendState> get kVulkanSparseBlendStates => <GpuBlendState>[
      for (final int mode in kVulkanBlendModes) gpuBlendForMode(mode),
    ];

/// The pipeline layout and the twelve graphics pipelines of the sparse path.
final class VulkanSparsePipelines {
  VulkanSparsePipelines._({
    required this.layout,
    required this.renderPass,
    required List<Pointer<VkPipeline_T>> pipelines,
    required this.shaderWords,
    required List<GpuBlendState> blendStates,
  })  : _pipelines = pipelines,
        _blendStates = blendStates;

  /// One set layout used twice - see point 4 of `vulkan_sparse_strips.dart`.
  final Pointer<VkPipelineLayout_T> layout;

  /// The pass the draws are recorded into. Compatible with, and not the same
  /// object as, the one the pipelines were built against.
  final Pointer<VkRenderPass_T> renderPass;

  final int shaderWords;
  final List<Pointer<VkPipeline_T>> _pipelines;
  final List<GpuBlendState> _blendStates;

  int get pipelineCount => _pipelines.length;

  /// The pipeline for one coverage x paint x blend triple.
  ///
  /// Throws on a blend state with no pipeline rather than substituting
  /// source-over, for the reason [gpuBlendForMode] gives: a blend that quietly
  /// becomes source-over draws a picture that looks like a paint bug.
  Pointer<VkPipeline_T> pipelineFor({
    required int coverage,
    required int paint,
    required GpuBlendState blend,
  }) {
    final int blendIndex = _blendStates.indexOf(blend);
    if (blendIndex < 0) {
      throw StateError(
        'no sparse Vulkan pipeline for blend factors ${blend.source.name} / '
        '${blend.destination.name}; a factor pair added to gpu_pipeline.dart '
        'needs a blend mode in kVulkanBlendModes',
      );
    }
    return _pipelines[
        fragmentIndex(coverage: coverage, paint: paint) * _blendStates.length +
            blendIndex];
  }

  /// Builds everything, or returns null after releasing whatever was made.
  static VulkanSparsePipelines? create(
    VulkanDevice device, {
    required Pointer<VkDescriptorSetLayout_T> setLayout,
    required Pointer<VkRenderPass_T> compatibleRenderPass,
    required Pointer<VkRenderPass_T> renderPass,
  }) {
    final VulkanSparseShaderCode code = VulkanSparseShaderCode();
    final NativeArena arena = NativeArena();
    final List<Pointer<VkShaderModule_T>> modules =
        <Pointer<VkShaderModule_T>>[];
    Pointer<VkPipelineLayout_T> layout = nullptr;
    final List<Pointer<VkPipeline_T>> pipelines = <Pointer<VkPipeline_T>>[];
    final List<GpuBlendState> blendStates = kVulkanSparseBlendStates;

    void releaseAll() {
      for (final Pointer<VkPipeline_T> pipeline in pipelines) {
        device.api.destroyPipeline(device.handle, pipeline, nullptr);
      }
      pipelines.clear();
      if (layout != nullptr) {
        device.api.destroyPipelineLayout(device.handle, layout, nullptr);
        layout = nullptr;
      }
    }

    try {
      layout = _createPipelineLayout(device, arena, setLayout);
      if (layout == nullptr) return null;

      final Pointer<VkShaderModule_T> vertex =
          _createShaderModule(device, arena, code.vertex);
      if (vertex == nullptr) {
        releaseAll();
        return null;
      }
      modules.add(vertex);

      for (final int coverage in kVulkanSparseCoverageModes) {
        for (final int paint in kVulkanSparsePaintModes) {
          final Pointer<VkShaderModule_T> fragment = _createShaderModule(
              device, arena, code.fragmentFor(coverage: coverage, paint: paint));
          if (fragment == nullptr) {
            releaseAll();
            return null;
          }
          modules.add(fragment);
          for (final GpuBlendState blend in blendStates) {
            final Pointer<VkPipeline_T> pipeline = _createPipeline(
              device,
              arena,
              vertex: vertex,
              fragment: fragment,
              layout: layout,
              renderPass: compatibleRenderPass,
              blend: blend,
            );
            if (pipeline == nullptr) {
              releaseAll();
              return null;
            }
            pipelines.add(pipeline);
          }
        }
      }

      return VulkanSparsePipelines._(
        layout: layout,
        renderPass: renderPass,
        pipelines: pipelines,
        shaderWords: code.wordCount,
        blendStates: blendStates,
      );
    } finally {
      // The modules can go the moment the pipelines exist: a VkShaderModule is
      // a parsed copy of the SPIR-V and vkCreateGraphicsPipelines has already
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
    device.api.destroyPipelineLayout(device.handle, layout, nullptr);
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
      // Bytes, not words.
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

  static Pointer<VkPipelineLayout_T> _createPipelineLayout(
    VulkanDevice device,
    NativeArena arena,
    Pointer<VkDescriptorSetLayout_T> setLayout,
  ) {
    // Two ranges, disjoint and in different stages: the viewport is pushed once
    // when the pass opens and the material once per command, and neither write
    // disturbs the other.
    final Pointer<VkPushConstantRange> ranges = arena<VkPushConstantRange>(2);
    ranges[0]
      ..stageFlags = VkShaderStageFlagBits.VK_SHADER_STAGE_VERTEX_BIT
      ..offset = kVulkanSparseVertexPushOffset
      ..size = kVulkanSparseVertexPushBytes;
    ranges[1]
      ..stageFlags = VkShaderStageFlagBits.VK_SHADER_STAGE_FRAGMENT_BIT
      ..offset = kVulkanSparseFragmentPushOffset
      ..size = kVulkanSparseFragmentPushBytes;

    final Pointer<Pointer<VkDescriptorSetLayout_T>> layouts =
        arena<Pointer<VkDescriptorSetLayout_T>>(
            kVulkanSparseDescriptorSetCount);
    for (var i = 0; i < kVulkanSparseDescriptorSetCount; i++) {
      layouts[i] = setLayout;
    }

    final Pointer<VkPipelineLayoutCreateInfo> info =
        arena<VkPipelineLayoutCreateInfo>();
    info.ref
      ..sType = VkStructureType.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO
      ..setLayoutCount = kVulkanSparseDescriptorSetCount
      ..pSetLayouts = layouts
      ..pushConstantRangeCount = 2
      ..pPushConstantRanges = ranges;

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
        arena.allocateAscii(kVulkanSparseEntryPoint).cast<Char>();

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

    // One binding, and its input rate is the whole trick: the quad's four
    // corners come from gl_VertexIndex and nothing is fetched per vertex, so
    // both attributes advance once per instance.
    final Pointer<VkVertexInputBindingDescription> binding =
        arena<VkVertexInputBindingDescription>();
    binding.ref
      ..binding = 0
      ..stride = kVulkanSparseInstanceStrideBytes
      ..inputRate = VkVertexInputRate.VK_VERTEX_INPUT_RATE_INSTANCE;

    final Pointer<VkVertexInputAttributeDescription> attributes =
        arena<VkVertexInputAttributeDescription>(2);
    attributes[0]
      ..location = kVulkanSparseAttributeQuadRect
      ..binding = 0
      ..format = VkFormat.VK_FORMAT_R32G32B32A32_SFLOAT
      ..offset = kVulkanSparseQuadRectOffsetBytes;
    attributes[1]
      ..location = kVulkanSparseAttributeAtlasOrigin
      ..binding = 0
      ..format = VkFormat.VK_FORMAT_R32G32_SFLOAT
      ..offset = kVulkanSparseAtlasOriginOffsetBytes;

    final Pointer<VkPipelineVertexInputStateCreateInfo> vertexInput =
        arena<VkPipelineVertexInputStateCreateInfo>();
    vertexInput.ref
      ..sType = VkStructureType
          .VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO
      ..vertexBindingDescriptionCount = 1
      ..pVertexBindingDescriptions = binding
      ..vertexAttributeDescriptionCount = 2
      ..pVertexAttributeDescriptions = attributes;

    final Pointer<VkPipelineInputAssemblyStateCreateInfo> assembly =
        arena<VkPipelineInputAssemblyStateCreateInfo>();
    assembly.ref
      ..sType = VkStructureType
          .VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO
      ..topology = VkPrimitiveTopology.VK_PRIMITIVE_TOPOLOGY_TRIANGLE_STRIP;

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
      // No culling, for the reason the dense pipeline gives: the strip's
      // winding in y-down device space is whichever the vertex index produces,
      // and a front face decided here would make every quad invisible.
      ..cullMode = VkCullModeFlagBits.VK_CULL_MODE_NONE
      ..frontFace = VkFrontFace.VK_FRONT_FACE_COUNTER_CLOCKWISE
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
      // The alpha channel gets the same factors as the colour channels, which
      // is correct precisely because everything here is premultiplied.
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

/// One coverage page staged and waiting for the pass to open.
final class _StagedPage {
  const _StagedPage(this.texture, this.x, this.y, this.width, this.height,
      this.stagingOffset);

  final VulkanTexture texture;
  final int x;
  final int y;
  final int width;
  final int height;
  final int stagingOffset;
}

/// The production [SparseVulkanDriver].
final class VulkanApiSparseDriver implements SparseVulkanDriver {
  VulkanApiSparseDriver(this._device, {required this.colorFormat});

  /// The token [createSparsePipeline] returns.
  ///
  /// One driver owns at most one set of pipelines, so a counter would be
  /// theatre; what the executor actually needs from the token is that zero
  /// means refusal and non-zero means "the object I was handed exists".
  static const int kPipelineToken = 1;

  final VulkanRenderDevice _device;

  /// The attachment format the pipelines are built for. A target with another
  /// format needs its own driver, exactly as it needs its own
  /// [VulkanPipelines].
  final int colorFormat;

  VulkanSparsePipelines? _pipelines;
  VulkanBuffer? _instances;
  VulkanBuffer? _staging;

  /// Where the next pass's coverage bytes go inside [_staging].
  ///
  /// Monotonic within a frame, and that is the whole point: a frame may record
  /// several sparse passes, every one of them writing its bytes on the CPU
  /// *now* and having them copied on the GPU *later*. Rewinding to zero for the
  /// second pass would overwrite bytes whose `vkCmdCopyBufferToImage` has been
  /// recorded and not executed - a corruption that is invisible until two
  /// promoted draws land in one frame, which is exactly how it was found.
  int _stagingCursor = 0;

  /// Staging and instance buffers this frame outgrew, kept alive until the
  /// frame retires.
  ///
  /// A buffer cannot be freed the moment a larger one replaces it: copies and
  /// draws already recorded name it by handle. They are released at the start
  /// of the next frame, by which point the target has waited for the queue.
  final List<VulkanBuffer> _retiredBuffers = <VulkanBuffer>[];

  /// Where the next pass's instances go inside [_instances], in bytes.
  ///
  /// Monotonic within a frame for exactly the reason [_stagingCursor] is: the
  /// instance array is written by the CPU when a pass is recorded and read by
  /// the GPU when the frame is submitted, so a second pass that rewound to
  /// zero would draw the first pass's quads from the second pass's data. That
  /// is invisible in a frame with one promoted draw and wrong in a frame with
  /// two.
  int _instanceCursor = 0;

  /// The byte offset the current pass's vertex binding starts at.
  int _instanceBase = 0;

  final Map<int, VulkanTexture> _textures = <int, VulkanTexture>{};
  final BytesBuilder _stagingBytes = BytesBuilder(copy: false);
  final List<_StagedPage> _staged = <_StagedPage>[];

  final NativeArena _arena = NativeArena();
  late final Pointer<Uint32> _pushWords =
      _arena<Uint32>(kVulkanSparsePushConstantBytes ~/ 4);
  late final Pointer<Float> _pushFloats = _pushWords.cast<Float>();

  Pointer<VkCommandBuffer_T> _commands = nullptr;
  Pointer<VkFramebuffer_T> _framebuffer = nullptr;
  int _targetWidth = 0;
  int _targetHeight = 0;

  bool _inPass = false;
  Pointer<VkPipeline_T> _boundPipeline = nullptr;
  int _pendingCoverage = kVulkanSparseModeSolid;
  int _pendingPaint = kVulkanSparsePaintSolid;
  GpuBlendState _pendingBlend =
      const GpuBlendState(GpuBlendFactor.one, GpuBlendFactor.oneMinusSrcAlpha);
  Pointer<VkDescriptorSet_T> _alphaSet = nullptr;
  Pointer<VkDescriptorSet_T> _lutSet = nullptr;

  /// SPIR-V words compiled, for a diagnostic. Zero before initialisation.
  int get shaderWords => _pipelines?.shaderWords ?? 0;

  int get pipelineCount => _pipelines?.pipelineCount ?? 0;

  /// Starts a frame's worth of recording: releases what the last frame
  /// outgrew and rewinds the staging cursor.
  ///
  /// Called once per frame by the target, before any pass. Safe only because
  /// the target waits for the queue between frames; see `_retiredBuffers`.
  void beginFrameRecording() {
    for (final VulkanBuffer buffer in _retiredBuffers) {
      buffer.dispose(_device.gpu);
    }
    _retiredBuffers.clear();
    _stagingCursor = 0;
    _instanceCursor = 0;
    _instanceBase = 0;
  }

  /// Hands over the command buffer the sparse pass records into.
  ///
  /// The buffer must be open and **not** inside a render pass: this driver
  /// records its coverage copies first and opens a pass of its own. See point 2
  /// of the library comment.
  void bindCommandBuffer(
    Pointer<VkCommandBuffer_T> commands, {
    required Pointer<VkFramebuffer_T> framebuffer,
    required int width,
    required int height,
  }) {
    _commands = commands;
    _framebuffer = framebuffer;
    _targetWidth = width;
    _targetHeight = height;
  }

  /// Forgets the command buffer. Any later driver call refuses by name rather
  /// than recording into a buffer that has been submitted.
  void unbindCommandBuffer() {
    _commands = nullptr;
    _framebuffer = nullptr;
    _targetWidth = 0;
    _targetHeight = 0;
  }

  @override
  int createSparsePipeline() {
    if (_pipelines != null) return kPipelineToken;
    final VulkanPipelines? dense = _device.pipelinesFor(colorFormat);
    if (dense == null) return 0;
    _pipelines = VulkanSparsePipelines.create(
      _device.gpu,
      setLayout: dense.descriptorSetLayout,
      compatibleRenderPass: dense.clearRenderPass,
      renderPass: dense.loadRenderPass,
    );
    return _pipelines == null ? 0 : kPipelineToken;
  }

  @override
  void disposeSparsePipeline(int pipeline) {
    _pipelines?.dispose(_device.gpu);
    _pipelines = null;
    _instances?.dispose(_device.gpu);
    _instances = null;
    _staging?.dispose(_device.gpu);
    _staging = null;
    for (final VulkanBuffer buffer in _retiredBuffers) {
      buffer.dispose(_device.gpu);
    }
    _retiredBuffers.clear();
    _stagingCursor = 0;
    _instanceCursor = 0;
    _instanceBase = 0;
  }

  /// Releases the push-constant scratch this driver keeps for its lifetime.
  ///
  /// Separate from [disposeSparsePipeline] because the executor calls that on
  /// its way to a *reinitialisable* state, and freeing the scratch there would
  /// leave a `late final` pointing at memory that has been given back.
  void dispose() {
    disposeSparsePipeline(kPipelineToken);
    _arena.dispose();
  }

  @override
  int createAlpha8Texture({required int width, required int height}) {
    // Nearest, because the fragment module fetches the texel rather than
    // sampling it - the filter cannot affect the result and saying `linear`
    // would suggest otherwise to the next reader.
    final VulkanTexture texture = _device.createTexture(
      width: width,
      height: height,
      format: GpuTextureFormat.alpha8,
      filter: GpuTextureFilter.nearest,
    );
    if (texture.id == kNoTexture) return 0;
    _textures[texture.id] = texture;
    return texture.id;
  }

  @override
  void deleteTexture(int texture) {
    final VulkanTexture? held = _textures.remove(texture);
    if (held != null) _device.releaseTexture(held);
  }

  @override
  void uploadInstances(Float32List instances) {
    if (instances.isEmpty) return;
    final int bytes = instances.lengthInBytes;
    // Aligned to the instance stride, so the binding offset this pass draws
    // from is a whole number of instances and `firstInstance` still counts
    // from the first one this pass uploaded.
    var base = _align(_instanceCursor, kVulkanSparseInstanceStrideBytes);
    if (_instances == null || _instances!.size < base + bytes) {
      final VulkanBuffer? outgrown = _instances;
      if (outgrown != null) _retiredBuffers.add(outgrown);
      _instances = VulkanBuffer.create(
        _device.gpu,
        resource: 'sparse instances',
        size: _grow(bytes),
        usage: VkBufferUsageFlagBits.VK_BUFFER_USAGE_VERTEX_BUFFER_BIT,
        hostVisible: true,
      );
      if (_instances == null) {
        throw StateError('the sparse instance buffer could not be allocated');
      }
      base = 0;
    }
    (_instances!.mapped + base)
        .cast<Float>()
        .asTypedList(instances.length)
        .setAll(0, instances);
    _device.gpu.allocator.flush(_instances!.memory);
    _instanceBase = base;
    _instanceCursor = base + bytes;
  }

  @override
  void uploadAlpha8Region(
    int texture, {
    required int x,
    required int y,
    required int width,
    required int height,
    required Uint8List pixels,
    required int sourceOffset,
    required int sourceBytesPerRow,
  }) {
    final VulkanTexture? page = _textures[texture];
    if (page == null) {
      throw StateError('no sparse coverage page $texture on this device');
    }
    // Repacked to a tight stride here for the same reason the dense uploader
    // gives: `VkBufferImageCopy.bufferRowLength` is in texels and a caller's
    // stride is in bytes.
    final Uint8List packed = Uint8List(width * height);
    for (var row = 0; row < height; row++) {
      final int from = sourceOffset + row * sourceBytesPerRow;
      packed.setRange(row * width, row * width + width, pixels, from);
    }
    _staged.add(
        _StagedPage(page, x, y, width, height, _stagingBytes.length));
    _stagingBytes.add(packed);
  }

  @override
  void beginSparsePass({
    required int pipeline,
    required int viewportWidth,
    required int viewportHeight,
  }) {
    final VulkanSparsePipelines? pipelines = _pipelines;
    if (pipelines == null) {
      throw StateError('the sparse Vulkan pipeline has not been created');
    }
    if (_commands == nullptr) {
      throw StateError('no Vulkan command buffer is bound for a sparse pass');
    }
    if (_inPass) throw StateError('a sparse Vulkan pass is already open');

    _recordStagedPages();

    _inPass = true;
    _boundPipeline = nullptr;
    _pendingCoverage = kVulkanSparseModeSolid;
    _pendingPaint = kVulkanSparsePaintSolid;
    final VulkanTexture? white = _device.defaultTexture;
    _alphaSet = white?.descriptorSet ?? nullptr;
    _lutSet = white?.descriptorSet ?? nullptr;

    using((NativeArena arena) {
      final Pointer<VkRenderPassBeginInfo> begin =
          arena<VkRenderPassBeginInfo>();
      begin.ref
        ..sType = VkStructureType.VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO
        ..renderPass = pipelines.renderPass
        ..framebuffer = _framebuffer
        ..clearValueCount = 0;
      begin.ref.renderArea.offset
        ..x = 0
        ..y = 0;
      begin.ref.renderArea.extent
        ..width = _targetWidth
        ..height = _targetHeight;
      _device.gpu.api.cmdBeginRenderPass(
          _commands, begin, VkSubpassContents.VK_SUBPASS_CONTENTS_INLINE);

      final Pointer<VkViewport> viewport = arena<VkViewport>();
      viewport.ref
        ..x = 0
        ..y = 0
        ..width = viewportWidth.toDouble()
        ..height = viewportHeight.toDouble()
        ..minDepth = 0
        ..maxDepth = 1;
      final Pointer<VkRect2D> scissor = arena<VkRect2D>();
      scissor.ref.offset
        ..x = 0
        ..y = 0;
      scissor.ref.extent
        ..width = _targetWidth
        ..height = _targetHeight;
      _device.gpu.api
        ..cmdSetViewport(_commands, 0, 1, viewport)
        ..cmdSetScissor(_commands, 0, 1, scissor);

      final Pointer<Float> push = arena<Float>(2);
      push[0] = viewportWidth.toDouble();
      push[1] = viewportHeight.toDouble();
      _device.gpu.api.cmdPushConstants(
        _commands,
        pipelines.layout,
        VkShaderStageFlagBits.VK_SHADER_STAGE_VERTEX_BIT,
        kVulkanSparseVertexPushOffset,
        kVulkanSparseVertexPushBytes,
        push.cast<Void>(),
      );

      if (_instances != null) {
        final Pointer<Pointer<VkBuffer_T>> buffers =
            arena<Pointer<VkBuffer_T>>();
        buffers.value = _instances!.handle;
        final Pointer<Uint64> offsets = arena<Uint64>();
        // This pass's slice of the frame's instance arena, so `firstInstance`
        // stays a per-pass index rather than becoming a running total.
        offsets.value = _instanceBase;
        _device.gpu.api
            .cmdBindVertexBuffers(_commands, 0, 1, buffers, offsets);
      }
    });
  }

  @override
  void setBlendState(GpuBlendState blend) {
    _requirePass();
    _pendingBlend = blend;
  }

  @override
  void setPremultipliedColor(
    double red,
    double green,
    double blue,
    double alpha,
  ) {
    _requirePass();
    const int base = VulkanSparsePushConstant.color ~/ 4;
    _pushFloats[base] = red;
    _pushFloats[base + 1] = green;
    _pushFloats[base + 2] = blue;
    _pushFloats[base + 3] = alpha;
  }

  @override
  void useSolidPaint() {
    _requirePass();
    _pendingPaint = kVulkanSparsePaintSolid;
    _lutSet = _device.defaultTexture?.descriptorSet ?? nullptr;
  }

  @override
  void useGradientPaint(
    GpuGradientBinding binding,
    GpuGradientShaderParameters parameters,
  ) {
    _requirePass();
    _pendingPaint = kVulkanSparsePaintGradient;

    final Float32List scalars = parameters.scalars;
    const int transform = GpuGradientUniformOffset.targetToLocal;
    const int geometry = GpuGradientUniformOffset.geometry;

    _pushWords[VulkanSparsePushConstant.gradientKind ~/ 4] =
        scalars[GpuGradientUniformOffset.kind].toInt();
    _pushWords[VulkanSparsePushConstant.gradientSpread ~/ 4] =
        binding.spread.index;
    const int lookup = VulkanSparsePushConstant.gradientLookup ~/ 4;
    _pushFloats[lookup] = binding.lookupScale;
    _pushFloats[lookup + 1] = binding.lookupBias;

    // The same packing the GL and Direct3D adapters use: row 0 of the
    // target-to-local affine transform in the first vec4, row 1 in the second,
    // with the translation in `.z` so the shader's dot product against
    // (x, y, 1) is the whole mapping.
    const int row0 = VulkanSparsePushConstant.targetToLocal0 ~/ 4;
    const int row1 = VulkanSparsePushConstant.targetToLocal1 ~/ 4;
    _pushFloats[row0] = scalars[transform];
    _pushFloats[row0 + 1] = scalars[transform + 2];
    _pushFloats[row0 + 2] = scalars[transform + 4];
    _pushFloats[row0 + 3] = 0;
    _pushFloats[row1] = scalars[transform + 1];
    _pushFloats[row1 + 1] = scalars[transform + 3];
    _pushFloats[row1 + 2] = scalars[transform + 5];
    _pushFloats[row1 + 3] = 0;

    const int geometry0 = VulkanSparsePushConstant.gradientGeometry0 ~/ 4;
    const int geometry1 = VulkanSparsePushConstant.gradientGeometry1 ~/ 4;
    for (var i = 0; i < 4; i++) {
      _pushFloats[geometry0 + i] = scalars[geometry + i];
      _pushFloats[geometry1 + i] = scalars[geometry + 4 + i];
    }

    // The binding's handle *is* the device's texture object - `GpuGradientCache`
    // was given this device as its allocator - so the descriptor set it already
    // owns is the one to bind. Looking it up by integer id instead would be a
    // second table to keep in step with the first.
    final GpuTextureHandle handle = binding.texture;
    if (handle is! VulkanTexture || handle.descriptorSet == nullptr) {
      throw StateError('the gradient LUT texture ${binding.texture.id} was not '
          'created by this Vulkan device');
    }
    _lutSet = handle.descriptorSet;
  }

  @override
  void setSparseMode(int mode) {
    _requirePass();
    if (mode != kVulkanSparseModeSolid && mode != kVulkanSparseModeAlpha) {
      throw ArgumentError.value(mode, 'mode', 'not a sparse coverage mode');
    }
    _pendingCoverage = mode;
    if (mode == kVulkanSparseModeSolid) {
      _alphaSet = _device.defaultTexture?.descriptorSet ?? nullptr;
    }
  }

  @override
  void bindAlpha8Texture(int texture) {
    _requirePass();
    final VulkanTexture? page = _textures[texture];
    if (page == null) {
      throw StateError('no sparse coverage page $texture on this device');
    }
    _alphaSet = page.descriptorSet;
  }

  @override
  void drawTriangleStripInstanced({
    required int vertexCount,
    required int instanceCount,
    required int firstInstance,
  }) {
    _requirePass();
    if (instanceCount <= 0) return;
    final VulkanSparsePipelines pipelines = _pipelines!;
    final Pointer<VkPipeline_T> pipeline = pipelines.pipelineFor(
      coverage: _pendingCoverage,
      paint: _pendingPaint,
      blend: _pendingBlend,
    );
    using((NativeArena arena) {
      if (pipeline != _boundPipeline) {
        _device.gpu.api.cmdBindPipeline(
          _commands,
          VkPipelineBindPoint.VK_PIPELINE_BIND_POINT_GRAPHICS,
          pipeline,
        );
        _boundPipeline = pipeline;
      }
      final Pointer<Pointer<VkDescriptorSet_T>> sets =
          arena<Pointer<VkDescriptorSet_T>>(kVulkanSparseDescriptorSetCount);
      sets[kVulkanSparseAlphaAtlasSet] = _alphaSet;
      sets[kVulkanSparseGradientLutSet] = _lutSet;
      _device.gpu.api
        ..cmdBindDescriptorSets(
          _commands,
          VkPipelineBindPoint.VK_PIPELINE_BIND_POINT_GRAPHICS,
          pipelines.layout,
          0,
          kVulkanSparseDescriptorSetCount,
          sets,
          0,
          nullptr,
        )
        ..cmdPushConstants(
          _commands,
          pipelines.layout,
          VkShaderStageFlagBits.VK_SHADER_STAGE_FRAGMENT_BIT,
          kVulkanSparseFragmentPushOffset,
          kVulkanSparseFragmentPushBytes,
          (_pushWords.cast<Uint8>() + kVulkanSparseFragmentPushOffset)
              .cast<Void>(),
        )
        ..cmdDraw(_commands, vertexCount, instanceCount, 0, firstInstance);
    });
  }

  @override
  void endSparsePass() {
    if (!_inPass) return;
    _inPass = false;
    _boundPipeline = nullptr;
    if (_commands != nullptr) {
      _device.gpu.api.cmdEndRenderPass(_commands);
    }
  }

  @override
  void discardNativeResources() {
    // Forgotten, not destroyed: after a device loss every one of these handles
    // names an object the driver has already taken away, and destroying it is
    // undefined rather than merely redundant.
    _pipelines = null;
    _instances = null;
    _staging = null;
    _retiredBuffers.clear();
    _stagingCursor = 0;
    _instanceCursor = 0;
    _instanceBase = 0;
    _textures.clear();
    _staged.clear();
    _stagingBytes.clear();
    _inPass = false;
    _boundPipeline = nullptr;
    _alphaSet = nullptr;
    _lutSet = nullptr;
    unbindCommandBuffer();
  }

  void _recordStagedPages() {
    if (_staged.isEmpty) return;
    final Uint8List bytes = _stagingBytes.takeBytes();
    // A four-byte start, because `VkBufferImageCopy.bufferOffset` must be a
    // multiple of four as well as of the texel size.
    final int base = _align(_stagingCursor, 4);
    if (_staging == null || _staging!.size < base + bytes.length) {
      final VulkanBuffer? outgrown = _staging;
      if (outgrown != null) _retiredBuffers.add(outgrown);
      _staging = VulkanBuffer.create(
        _device.gpu,
        resource: 'sparse coverage staging',
        size: _grow(bytes.length),
        usage: VkBufferUsageFlagBits.VK_BUFFER_USAGE_TRANSFER_SRC_BIT,
        hostVisible: true,
      );
      if (_staging == null) {
        _staged.clear();
        throw StateError('the sparse staging buffer could not be allocated');
      }
      _stagingCursor = 0;
    }
    final int offset = _align(_stagingCursor, 4);
    _staging!.mapped
        .asTypedList(_staging!.size)
        .setRange(offset, offset + bytes.length, bytes);
    _device.gpu.allocator.flush(_staging!.memory);
    _stagingCursor = offset + bytes.length;

    using((NativeArena arena) {
      final Pointer<VkBufferImageCopy> copy = arena<VkBufferImageCopy>();
      for (final _StagedPage page in _staged) {
        // A page reused by a second pass in the same frame is a *write after
        // read*: the previous pass's fragment stage sampled it. TOP_OF_PIPE
        // waits for nothing, so the source stage has to name the read that
        // actually has to finish first. A page still UNDEFINED has no such
        // read and asking for one would be an ordering nobody needs.
        final bool fresh =
            page.texture.layout == VkImageLayout.VK_IMAGE_LAYOUT_UNDEFINED;
        _device.recordImageBarrier(
          _commands,
          page.texture.image,
          oldLayout: page.texture.layout,
          newLayout: VkImageLayout.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
          srcAccess: fresh ? 0 : VkAccessFlagBits.VK_ACCESS_SHADER_READ_BIT,
          dstAccess: VkAccessFlagBits.VK_ACCESS_TRANSFER_WRITE_BIT,
          srcStage: fresh
              ? VkPipelineStageFlagBits.VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT
              : VkPipelineStageFlagBits.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
          dstStage: VkPipelineStageFlagBits.VK_PIPELINE_STAGE_TRANSFER_BIT,
        );
        copy.ref
          ..bufferOffset = offset + page.stagingOffset
          ..bufferRowLength = 0
          ..bufferImageHeight = 0;
        copy.ref.imageSubresource
          ..aspectMask = VkImageAspectFlagBits.VK_IMAGE_ASPECT_COLOR_BIT
          ..mipLevel = 0
          ..baseArrayLayer = 0
          ..layerCount = 1;
        copy.ref.imageOffset
          ..x = page.x
          ..y = page.y
          ..z = 0;
        copy.ref.imageExtent
          ..width = page.width
          ..height = page.height
          ..depth = 1;
        _device.gpu.api.cmdCopyBufferToImage(
          _commands,
          _staging!.handle,
          page.texture.image,
          VkImageLayout.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
          1,
          copy,
        );
        _device.recordImageBarrier(
          _commands,
          page.texture.image,
          oldLayout: VkImageLayout.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
          newLayout: VkImageLayout.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
          srcAccess: VkAccessFlagBits.VK_ACCESS_TRANSFER_WRITE_BIT,
          dstAccess: VkAccessFlagBits.VK_ACCESS_SHADER_READ_BIT,
          srcStage: VkPipelineStageFlagBits.VK_PIPELINE_STAGE_TRANSFER_BIT,
          dstStage:
              VkPipelineStageFlagBits.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
        );
        page.texture.layout =
            VkImageLayout.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
      }
    });
    _staged.clear();
  }

  void _requirePass() {
    if (!_inPass) throw StateError('no sparse Vulkan pass is open');
  }

  static int _align(int value, int alignment) =>
      (value + alignment - 1) ~/ alignment * alignment;

  static int _grow(int bytes) {
    var size = 4096;
    while (size < bytes) {
      size *= 2;
    }
    return size;
  }
}
