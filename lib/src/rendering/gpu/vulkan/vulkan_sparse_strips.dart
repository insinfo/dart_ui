/// Vulkan submission contract and SPIR-V for the backend-neutral sparse-strip
/// plan.
///
/// This is `gl_sparse_strips.dart` transposed, deliberately line for line, in
/// exactly the sense `d3d12_sparse_strips.dart` is: the backends are compared
/// against the *same* CPU rasteriser, so a difference between them has to be a
/// bug in one of them rather than a difference of intent between two shader
/// authors.
///
/// ## How the SPIR-V is produced, and why
///
/// **It is emitted here, in Dart, by [SpirvBuilder].** That decision was made
/// once already - `vulkan_spirv.dart` argues it at length for the dense
/// renderer's four modules - and this file follows it rather than reopening
/// it. The short form: `vkCreateShaderModule` takes SPIR-V words and nothing
/// else, turning GLSL into SPIR-V needs `glslang` or `shaderc`, and this
/// repository ships no native library and cannot build one from Dart. The two
/// honest alternatives were a checked-in blob nobody can review or regenerate,
/// and emitting the words directly. The words are emitted directly, they are
/// regenerated on every run so they can never be stale, and they are checkable
/// with no GPU at all.
///
/// What this file adds to that decision is the one place it was under
/// pressure: the reference GLSL has *branches*, and [SpirvBuilder] emits one
/// straight-line block with no `OpSelectionMerge` and no `OpPhi`. Three ways
/// out, and the two that are taken are taken for different reasons:
///
///   1. **Coverage mode and paint mode become separate modules**, exactly as
///      `vulkan_shaders.dart` splits its three `GpuPipelineKind`s. Vulkan
///      bakes blend state into a `VkPipeline`, so there is already an object
///      per blend; making the mode part of the same object costs nothing, and
///      it is also what `wgsl_sparse_shaders.dart` does with its four fragment
///      entry points. Four modules here - solid/alpha coverage crossed with
///      solid/gradient paint - and one pipeline per module per blend.
///   2. **Gradient kind and spread become `OpSelect`**, not modules. They are
///      material state, not batch state; making them pipeline state would turn
///      four fragment modules into fourteen and twelve pipelines into
///      forty-two, all of them built eagerly, to avoid an arithmetic select
///      that costs a few instructions in a shader that is already dominated by
///      two texture fetches.
///   3. Teaching [SpirvBuilder] real control flow. Not done, and the reason is
///      not aversion: `OpSelect` is *sufficient* here because none of these
///      branches guards a side effect or a loop - every one of them chooses
///      between two values. The day a shader here needs a loop, the answer is
///      still an `OpLoopMerge` in the builder and not `shaderc`.
///
/// The thing to keep in mind when reading the fragment shader is what (2)
/// implies: **both** the linear and the radial parameter are computed for
/// every fragment, and the one not selected really does divide by zero when
/// the geometry it reads belongs to the other kind. That is safe -
/// `OpSelect` propagates nothing from the operand it discards - and it is
/// noted at each site rather than left to be rediscovered.
///
/// ## What changes on this API, and what deliberately does not
///
/// **The quad, the instance and the coverage semantics do not change.** Six
/// floats per instance - device `x, y, width, height`, then alpha-atlas
/// `x, y` - four vertices of a triangle strip built from the vertex index, an
/// integer fetch of the alpha page rather than a filtered sample, and the same
/// premultiply-then-scale order for gradients. Every one of those is a
/// correctness decision made once in the GL executor and re-used, not
/// re-decided.
///
/// **Four things change, and all four are Vulkan facts:**
///
///   1. *No `uYFlip`, and no flip at all.* Vulkan's normalised device y points
///      **down** and its framebuffer origin is the top-left corner, which is
///      already the display list's convention. So clip y is `y / height * 2 -
///      1`, the same expression as x, with no negation anywhere - see
///      Disagreement 2 in `vulkan_shaders.dart`. The trap this avoids is
///      copying the GL projection and drawing a correct picture upside down.
///   2. *No attribute rebasing.* Core GL 3.3 has no base-instance draw, so the
///      GL executor re-points `glVertexAttribPointer` before every command.
///      `vkCmdDraw` takes a `firstInstance`, so a command here is one draw call
///      and nothing else. [SparseVulkanSubmission] therefore exposes
///      [SparseVulkanSubmission.commandFirstInstance] directly and has no
///      offset-in-bytes accessor at all.
///   3. *No uniform buffer.* Every scalar is a push constant, written straight
///      into the command buffer with no descriptor, no allocation and no
///      synchronisation against the previous frame's value. The block is 112
///      bytes and the guaranteed `maxPushConstantsSize` is 128, so this needs
///      no capability check.
///   4. *Two descriptor sets, not two bindings.* The alpha page and the
///      gradient ramp are both `COMBINED_IMAGE_SAMPLER` at binding 0 of their
///      own set. That is not a style choice: `VulkanRenderDevice.createTexture`
///      already allocates every texture a one-binding descriptor set from the
///      device pool, so a layout of two single-binding sets lets a page and a
///      ramp be bound *as they already are*, with no second pool, no second
///      layout and no descriptor copies.
library;

import 'dart:typed_data';

import '../vector/sparse_strip_draw_plan.dart';
import 'vulkan_spirv.dart';

/// Six floats per instance: device `x, y, width, height`, then alpha-atlas
/// `x, y`. Solid instances leave the atlas origin at zero.
const int kVulkanSparseInstanceFloatCount = 6;
const int kVulkanSparseInstanceStrideBytes =
    kVulkanSparseInstanceFloatCount * 4;
const int kVulkanSparseQuadRectOffsetBytes = 0;
const int kVulkanSparseAtlasOriginOffsetBytes = 4 * 4;

/// Vertex attribute locations. Both advance once per quad, not once per corner.
const int kVulkanSparseAttributeQuadRect = 0;
const int kVulkanSparseAttributeAtlasOrigin = 1;

/// Coverage source. Same numbers as `kSparseGlMode*` and `kD3d12SparseMode*`.
const int kVulkanSparseModeSolid = 0;
const int kVulkanSparseModeAlpha = 1;

/// Material source, independent from whether coverage is solid or alpha8.
/// Same numbers as `kSparseGlPaint*` and `kD3d12SparsePaint*`.
const int kVulkanSparsePaintSolid = 0;
const int kVulkanSparsePaintGradient = 1;

/// `mode, material, atlasPage, firstInstance, instanceCount`.
const int kVulkanSparseCommandStride = 5;

/// The descriptor sets, and the one binding each of them has.
///
/// Binding 0 in both, and that is the load-bearing part: it is the layout
/// `VulkanRenderDevice` already allocates for every texture it creates, so an
/// alpha page and a gradient ramp arrive here as descriptor sets that are
/// already written and need no further work. See point 4 of the library
/// comment.
const int kVulkanSparseAlphaAtlasSet = 0;
const int kVulkanSparseGradientLutSet = 1;
const int kVulkanSparseTextureBinding = 0;
const int kVulkanSparseDescriptorSetCount = 2;

/// Byte offsets into the push-constant block.
///
/// Explicit, and decorated as such in the SPIR-V, rather than left to a
/// packing rule: the Dart side writes these bytes and the shader reads them
/// back, and a layout the two sides derive independently is a layout that can
/// disagree. Every `vec4` starts on a 16-byte boundary because Vulkan's
/// std430-derived rules require it of a `Block` member, and the two `vec2`s
/// sit where an 8-byte alignment is satisfied.
abstract final class VulkanSparsePushConstant {
  /// `vec2`, vertex stage only.
  static const int viewport = 0;

  /// `vec4`, premultiplied. Fragment stage.
  static const int color = 16;

  /// `uint`. `shaderKindLinear` is 1 and `shaderKindRadial` is 2.
  static const int gradientKind = 32;

  /// `uint`. The index of a `GradientSpread`.
  static const int gradientSpread = 36;

  /// `vec2`: `GpuGradientBinding.lookupScale` then `lookupBias`.
  static const int gradientLookup = 40;

  /// `vec4`: row 0 of the target-to-local affine transform, `(a, c, tx, 0)`.
  static const int targetToLocal0 = 48;

  /// `vec4`: row 1, `(b, d, ty, 0)`.
  static const int targetToLocal1 = 64;

  /// `vec4` and `vec4`: `Gradient.geometry`, zero-padded to eight scalars.
  static const int gradientGeometry0 = 80;
  static const int gradientGeometry1 = 96;
}

/// The vertex stage's push-constant range: the viewport and nothing else.
const int kVulkanSparseVertexPushOffset = 0;
const int kVulkanSparseVertexPushBytes = 8;

/// The fragment stage's range: everything from the colour onwards.
///
/// Disjoint from the vertex range, so the viewport is pushed once per pass and
/// the material once per command, and neither write disturbs the other.
const int kVulkanSparseFragmentPushOffset = VulkanSparsePushConstant.color;
const int kVulkanSparseFragmentPushBytes = 96;

/// Total bytes of push constant the pipeline layout declares.
///
/// 112, against a guaranteed `maxPushConstantsSize` of 128. A block that grew
/// past 128 would need a device query and a refusal path; this one does not,
/// and [validateVulkanSparseShaderContract] asserts it stays that way.
const int kVulkanSparsePushConstantBytes = 112;

/// The smallest `maxPushConstantsSize` Vulkan permits a device to report.
const int kVulkanMinPushConstantBytes = 128;

/// The entry point name every module declares, matching
/// `VkPipelineShaderStageCreateInfo.pName`.
const String kVulkanSparseEntryPoint = 'main';

/// The interpolant locations the two stages agree on.
const int kVulkanSparseVaryingAtlasTexel = 0;
const int kVulkanSparseVaryingTargetPosition = 1;

// ---------------------------------------------------------------------------
// The vertex stage
// ---------------------------------------------------------------------------

/// The instanced sparse-strip vertex shader, as SPIR-V words.
///
/// The GLSL twin is `_sparseVertexBody` in `gl_sparse_strips.dart` and the HLSL
/// twin is `kD3d12SparseVertexShader`. The only difference of substance is the
/// projection: no `uYFlip` and no negation, because Vulkan's clip space already
/// points the way the display list does.
Uint32List buildVulkanSparseVertexShader() {
  final SpirvBuilder module = SpirvBuilder()
    ..capability(kSpirvCapabilityShader)
    ..memoryModel(kSpirvAddressingModelLogical, kSpirvMemoryModelGlsl450);

  final int mainId = module.freshId();

  final int voidType = module.typeVoid();
  final int fnType = module.typeFunction(voidType, const <int>[]);
  final int f32 = module.typeFloat(32);
  final int i32 = module.typeInt(32, signed: true);
  final int v2 = module.typeVector(f32, 2);
  final int v4 = module.typeVector(f32, 4);

  final int inI32 = module.typePointer(kSpirvStorageClassInput, i32);
  final int inV2 = module.typePointer(kSpirvStorageClassInput, v2);
  final int inV4 = module.typePointer(kSpirvStorageClassInput, v4);
  final int outV2 = module.typePointer(kSpirvStorageClassOutput, v2);
  final int outV4 = module.typePointer(kSpirvStorageClassOutput, v4);

  final int pushStruct = module.typeStruct(<int>[v2]);
  final int pushPointer =
      module.typePointer(kSpirvStorageClassPushConstant, pushStruct);
  final int pushMemberPointer =
      module.typePointer(kSpirvStorageClassPushConstant, v2);

  final int zero = module.constantFloat(f32, 0);
  final int one = module.constantFloat(f32, 1);
  final int two = module.constantFloat(f32, 2);
  final int oneOne = module.constantComposite(v2, <int>[one, one]);
  final int firstMember = module.constantInt(i32, 0);
  final int intOne = module.constantInt(i32, 1);

  final int aQuadRect = module.variable(inV4, kSpirvStorageClassInput);
  final int aAtlasOrigin = module.variable(inV2, kSpirvStorageClassInput);
  final int vertexIndex = module.variable(inI32, kSpirvStorageClassInput);
  final int vAtlasTexel = module.variable(outV2, kSpirvStorageClassOutput);
  final int vTargetPosition = module.variable(outV2, kSpirvStorageClassOutput);
  final int position = module.variable(outV4, kSpirvStorageClassOutput);
  final int push = module.variable(pushPointer, kSpirvStorageClassPushConstant);

  module
    ..entryPoint(
        kSpirvExecutionModelVertex, mainId, kVulkanSparseEntryPoint, <int>[
      aQuadRect,
      aAtlasOrigin,
      vertexIndex,
      vAtlasTexel,
      vTargetPosition,
      position,
    ])
    ..decorate(aQuadRect, kSpirvDecorationLocation,
        const <int>[kVulkanSparseAttributeQuadRect])
    ..decorate(aAtlasOrigin, kSpirvDecorationLocation,
        const <int>[kVulkanSparseAttributeAtlasOrigin])
    ..decorate(vertexIndex, kSpirvDecorationBuiltIn,
        const <int>[kSpirvBuiltInVertexIndex])
    ..decorate(vAtlasTexel, kSpirvDecorationLocation,
        const <int>[kVulkanSparseVaryingAtlasTexel])
    ..decorate(vTargetPosition, kSpirvDecorationLocation,
        const <int>[kVulkanSparseVaryingTargetPosition])
    ..decorate(position, kSpirvDecorationBuiltIn, <int>[kSpirvBuiltInPosition])
    ..decorate(pushStruct, kSpirvDecorationBlock)
    ..memberDecorate(pushStruct, 0, kSpirvDecorationOffset,
        const <int>[VulkanSparsePushConstant.viewport]);

  final SpirvFunction body = module.beginFunction(voidType, fnType, mainId);

  // Four vertices form a triangle strip: TL, TR, BL, BR. gl_VertexIndex makes
  // the immutable unit quad free - the only uploaded data is per-instance.
  final int index = body.load(i32, vertexIndex);
  final int cornerX =
      body.convertToFloat(f32, body.bitwiseAnd(i32, index, intOne));
  final int cornerY = body.convertToFloat(
      f32, body.bitwiseAnd(i32, body.shiftRight(i32, index, intOne), intOne));
  final int corner = body.construct(v2, <int>[cornerX, cornerY]);

  final int quad = body.load(v4, aQuadRect);
  final int origin = body.shuffle(v2, quad, quad, const <int>[0, 1]);
  final int size = body.shuffle(v2, quad, quad, const <int>[2, 3]);
  final int span = body.multiply(v2, corner, size);
  final int devicePosition = body.add(v2, origin, span);

  body
    ..store(vAtlasTexel, body.add(v2, body.load(v2, aAtlasOrigin), span))
    ..store(vTargetPosition, devicePosition);

  // clip = position / viewport * 2 - 1, in both axes and with no flip.
  final int viewport = body.load(
      v2, body.accessChain(pushMemberPointer, push, <int>[firstMember]));
  final int ratio = body.divide(v2, devicePosition, viewport);
  final int ndc = body.subtract(v2, body.scale(v2, ratio, two), oneOne);
  body
    ..store(
        position,
        body.construct(v4, <int>[
          body.extract(f32, ndc, 0),
          body.extract(f32, ndc, 1),
          zero,
          one,
        ]))
    ..returnVoid();

  return module.assemble();
}

// ---------------------------------------------------------------------------
// The fragment stage
// ---------------------------------------------------------------------------

/// One of the four sparse fragment modules, as SPIR-V words.
///
/// [coverage] is [kVulkanSparseModeSolid] or [kVulkanSparseModeAlpha];
/// [paint] is [kVulkanSparsePaintSolid] or [kVulkanSparsePaintGradient].
/// Anything else throws rather than defaulting, for the reason
/// `vulkan_shaders.dart` gives: a mode that silently becomes solid draws a
/// picture that looks like a missing texture.
Uint32List buildVulkanSparseFragmentShader({
  required int coverage,
  required int paint,
}) {
  if (coverage != kVulkanSparseModeSolid &&
      coverage != kVulkanSparseModeAlpha) {
    throw ArgumentError.value(coverage, 'coverage',
        'the two coverage sources are kVulkanSparseModeSolid and Alpha');
  }
  if (paint != kVulkanSparsePaintSolid && paint != kVulkanSparsePaintGradient) {
    throw ArgumentError.value(paint, 'paint',
        'the two paint sources are kVulkanSparsePaintSolid and Gradient');
  }
  final bool samplesAtlas = coverage == kVulkanSparseModeAlpha;
  final bool samplesRamp = paint == kVulkanSparsePaintGradient;

  final SpirvBuilder module = SpirvBuilder()
    ..capability(kSpirvCapabilityShader);
  final int glsl = module.extInstImport(kGlslStd450);
  module.memoryModel(kSpirvAddressingModelLogical, kSpirvMemoryModelGlsl450);

  final int mainId = module.freshId();

  final int voidType = module.typeVoid();
  final int fnType = module.typeFunction(voidType, const <int>[]);
  final int f32 = module.typeFloat(32);
  final int i32 = module.typeInt(32, signed: true);
  final int u32 = module.typeInt(32, signed: false);
  final int boolType = module.typeBool();
  final int v2 = module.typeVector(f32, 2);
  final int v3 = module.typeVector(f32, 3);
  final int v4 = module.typeVector(f32, 4);
  final int iv2 = module.typeVector(i32, 2);

  final int inV2 = module.typePointer(kSpirvStorageClassInput, v2);
  final int outV4 = module.typePointer(kSpirvStorageClassOutput, v4);

  final int imageType = module.typeImage2D(f32);
  final int sampledImage = module.typeSampledImage(imageType);
  final int sampledPointer =
      module.typePointer(kSpirvStorageClassUniformConstant, sampledImage);

  // The fragment half of the block. Members carry absolute byte offsets, so
  // the struct legitimately starts at 16 - the vertex stage owns 0..8 and the
  // two ranges are declared separately in the pipeline layout.
  final int pushStruct = module.typeStruct(<int>[
    v4, // 0: colour
    u32, // 1: gradient kind
    u32, // 2: gradient spread
    v2, // 3: lookup scale/bias
    v4, // 4: target-to-local row 0
    v4, // 5: target-to-local row 1
    v4, // 6: geometry 0..3
    v4, // 7: geometry 4..7
  ]);
  final int pushPointer =
      module.typePointer(kSpirvStorageClassPushConstant, pushStruct);
  final int pushV4 = module.typePointer(kSpirvStorageClassPushConstant, v4);
  final int pushV2 = module.typePointer(kSpirvStorageClassPushConstant, v2);
  final int pushU32 = module.typePointer(kSpirvStorageClassPushConstant, u32);

  final int zero = module.constantFloat(f32, 0);
  final int one = module.constantFloat(f32, 1);
  final int two = module.constantFloat(f32, 2);
  final int four = module.constantFloat(f32, 4);
  final int half = module.constantFloat(f32, 0.5);
  final int lodZero = module.constantInt(i32, 0);
  final int uOne = module.constantInt(u32, 1);
  final int uTwo = module.constantInt(u32, 2);

  final int vAtlasTexel = module.variable(inV2, kSpirvStorageClassInput);
  final int vTargetPosition = module.variable(inV2, kSpirvStorageClassInput);
  final int fragColor = module.variable(outV4, kSpirvStorageClassOutput);
  // Declared only where read. A module that declares a descriptor it never
  // samples invites the reader to believe the pipeline needs one bound.
  final int alphaAtlas = samplesAtlas
      ? module.variable(sampledPointer, kSpirvStorageClassUniformConstant)
      : 0;
  final int gradientLut = samplesRamp
      ? module.variable(sampledPointer, kSpirvStorageClassUniformConstant)
      : 0;
  final int push = module.variable(pushPointer, kSpirvStorageClassPushConstant);

  module
    ..entryPoint(kSpirvExecutionModelFragment, mainId, kVulkanSparseEntryPoint,
        <int>[vAtlasTexel, vTargetPosition, fragColor])
    ..executionMode(mainId, kSpirvExecutionModeOriginUpperLeft)
    ..decorate(vAtlasTexel, kSpirvDecorationLocation,
        const <int>[kVulkanSparseVaryingAtlasTexel])
    ..decorate(vTargetPosition, kSpirvDecorationLocation,
        const <int>[kVulkanSparseVaryingTargetPosition])
    ..decorate(fragColor, kSpirvDecorationLocation, const <int>[0])
    ..decorate(pushStruct, kSpirvDecorationBlock);
  const List<int> memberOffsets = <int>[
    VulkanSparsePushConstant.color,
    VulkanSparsePushConstant.gradientKind,
    VulkanSparsePushConstant.gradientSpread,
    VulkanSparsePushConstant.gradientLookup,
    VulkanSparsePushConstant.targetToLocal0,
    VulkanSparsePushConstant.targetToLocal1,
    VulkanSparsePushConstant.gradientGeometry0,
    VulkanSparsePushConstant.gradientGeometry1,
  ];
  for (var member = 0; member < memberOffsets.length; member++) {
    module.memberDecorate(pushStruct, member, kSpirvDecorationOffset,
        <int>[memberOffsets[member]]);
  }
  if (samplesAtlas) {
    module
      ..decorate(alphaAtlas, kSpirvDecorationDescriptorSet,
          const <int>[kVulkanSparseAlphaAtlasSet])
      ..decorate(alphaAtlas, kSpirvDecorationBinding,
          const <int>[kVulkanSparseTextureBinding]);
  }
  if (samplesRamp) {
    module
      ..decorate(gradientLut, kSpirvDecorationDescriptorSet,
          const <int>[kVulkanSparseGradientLutSet])
      ..decorate(gradientLut, kSpirvDecorationBinding,
          const <int>[kVulkanSparseTextureBinding]);
  }

  final SpirvFunction body = module.beginFunction(voidType, fnType, mainId);

  int memberInt(int member) => module.constantInt(i32, member);
  int loadV4(int member) =>
      body.load(v4, body.accessChain(pushV4, push, <int>[memberInt(member)]));

  // -- coverage --------------------------------------------------------------

  final int coverageValue;
  if (samplesAtlas) {
    // Device rectangles and atlas placements are integer-aligned. At pixel
    // centres the interpolated coordinate is texel + 0.5, so floor names the
    // exact alpha8 texel; the fetch then bypasses filtering and normalisation
    // entirely, which is what texelFetch does in the GL shader and what Load
    // does in the HLSL.
    final int texel = body.load(v2, vAtlasTexel);
    final int floored = body.extInst(v2, glsl, kGlslStd450Floor, <int>[texel]);
    final int coordinate = body.convertToSigned(iv2, floored);
    final int pageImage =
        body.image(imageType, body.load(sampledImage, alphaAtlas));
    coverageValue =
        body.extract(f32, body.fetch(v4, pageImage, coordinate, lodZero), 0);
  } else {
    coverageValue = one;
  }

  // -- paint -----------------------------------------------------------------

  final int color;
  if (!samplesRamp) {
    color = loadV4(0);
  } else {
    final int target = body.load(v2, vTargetPosition);
    final int targetXY1 = body.construct(v3, <int>[
      body.extract(f32, target, 0),
      body.extract(f32, target, 1),
      one,
    ]);
    final int row0 = loadV4(4);
    final int row1 = loadV4(5);
    final int local = body.construct(v2, <int>[
      body.dot(
          f32, body.shuffle(v3, row0, row0, const <int>[0, 1, 2]), targetXY1),
      body.dot(
          f32, body.shuffle(v3, row1, row1, const <int>[0, 1, 2]), targetXY1),
    ]);

    final int geometry0 = loadV4(6);
    final int geometry1 = loadV4(7);

    // Linear: t = dot(local - start, end - start) / |end - start|^2.
    final int start = body.shuffle(v2, geometry0, geometry0, const <int>[0, 1]);
    final int end = body.shuffle(v2, geometry0, geometry0, const <int>[2, 3]);
    final int direction = body.subtract(v2, end, start);
    final int lengthSquared = body.dot(f32, direction, direction);
    final int projection =
        body.dot(f32, body.subtract(v2, local, start), direction);
    // Divides unconditionally: when the two endpoints coincide this is 0 / 0
    // and produces a NaN, and the select below discards it. See the library
    // comment on what OpSelect does and does not propagate.
    final int linear = body.select(
        f32,
        body.equalFloat(boolType, lengthSquared, zero),
        zero,
        body.divide(f32, projection, lengthSquared));

    // Radial and focal, the same four cases the CPU reference distinguishes.
    final int center =
        body.shuffle(v2, geometry0, geometry0, const <int>[0, 1]);
    final int radius = body.extract(f32, geometry0, 2);
    final int focus = body.construct(v2, <int>[
      body.extract(f32, geometry0, 3),
      body.extract(f32, geometry1, 0),
    ]);
    final int ray = body.subtract(v2, local, focus);
    final int rayX = body.extract(f32, ray, 0);
    final int rayY = body.extract(f32, ray, 1);
    final int rayIsZero = body.logicalAnd(
        boolType,
        body.equalFloat(boolType, rayX, zero),
        body.equalFloat(boolType, rayY, zero));
    final int focusAtCenter = body.logicalAnd(
        boolType,
        body.equalFloat(boolType, body.extract(f32, focus, 0),
            body.extract(f32, center, 0)),
        body.equalFloat(boolType, body.extract(f32, focus, 1),
            body.extract(f32, center, 1)));

    final int a = body.dot(f32, ray, ray);
    final int concentric = body.divide(
        f32, body.extInst(f32, glsl, kGlslStd450Sqrt, <int>[a]), radius);

    final int focusFromCenter = body.subtract(v2, focus, center);
    final int b = body.multiply(f32, two, body.dot(f32, focusFromCenter, ray));
    final int c = body.subtract(
        f32,
        body.dot(f32, focusFromCenter, focusFromCenter),
        body.multiply(f32, radius, radius));
    final int discriminant = body.subtract(f32, body.multiply(f32, b, b),
        body.multiply(f32, four, body.multiply(f32, a, c)));
    // sqrt of a clamped discriminant, not of the discriminant: a negative one
    // is refused by the guard below anyway, and feeding sqrt a negative number
    // would put a NaN into arithmetic that a reader then has to prove is
    // discarded.
    final int root = body.extInst(f32, glsl, kGlslStd450Sqrt, <int>[
      body.extInst(f32, glsl, kGlslStd450FMax, <int>[discriminant, zero]),
    ]);
    final int negB = body.negate(f32, b);
    final int twoA = body.multiply(f32, two, a);
    final int first = body.divide(f32, body.subtract(f32, negB, root), twoA);
    final int second = body.divide(f32, body.add(f32, negB, root), twoA);
    final int scale = body.extInst(f32, glsl, kGlslStd450FMax, <int>[
      body.select(
          f32, body.greaterThanFloat(boolType, first, zero), first, zero),
      body.select(
          f32, body.greaterThanFloat(boolType, second, zero), second, zero),
    ]);
    final int focal = body.select(
        f32,
        body.logicalOr(boolType, body.equalFloat(boolType, a, zero),
            body.lessThanFloat(boolType, discriminant, zero)),
        zero,
        body.select(f32, body.greaterThanFloat(boolType, scale, zero),
            body.divide(f32, one, scale), zero));

    final int radial = body.select(f32, rayIsZero, zero,
        body.select(f32, focusAtCenter, concentric, focal));

    final int kind =
        body.load(u32, body.accessChain(pushU32, push, <int>[memberInt(1)]));
    final int parameter =
        body.select(f32, body.equalInt(boolType, kind, uOne), linear, radial);

    // Spread. `repeat` is fract; `reflect` is a triangle wave built from
    // GLSL's mod and not from a truncating remainder - `x - 2 * floor(x / 2)`
    // keeps a negative parameter on the same half of the ramp the CPU puts it
    // on, which a remainder that truncates towards zero would mirror.
    final int pad =
        body.extInst(f32, glsl, kGlslStd450FClamp, <int>[parameter, zero, one]);
    final int repeat =
        body.extInst(f32, glsl, kGlslStd450Fract, <int>[parameter]);
    final int wrapped = body.subtract(
        f32,
        parameter,
        body.multiply(
            f32,
            two,
            body.extInst(f32, glsl, kGlslStd450Floor,
                <int>[body.divide(f32, parameter, two)])));
    final int reflected = body.select(
        f32,
        body.lessThanOrEqualFloat(boolType, wrapped, one),
        wrapped,
        body.subtract(f32, two, wrapped));

    final int spread =
        body.load(u32, body.accessChain(pushU32, push, <int>[memberInt(2)]));
    final int spreadParameter = body.select(
        f32,
        body.equalInt(boolType, spread, uOne),
        repeat,
        body.select(
            f32, body.equalInt(boolType, spread, uTwo), reflected, pad));

    final int lookup =
        body.load(v2, body.accessChain(pushV2, push, <int>[memberInt(3)]));
    final int rampCoordinate = body.add(
        f32,
        body.multiply(f32, spreadParameter, body.extract(f32, lookup, 0)),
        body.extract(f32, lookup, 1));
    final int straight = body.sampleLod(
        v4,
        body.load(sampledImage, gradientLut),
        body.construct(v2, <int>[rampCoordinate, half]),
        zero);
    // The ramp is straight alpha; premultiply before coverage, in that order,
    // exactly as the GLSL and the HLSL do.
    final int rampAlpha = body.extract(f32, straight, 3);
    color = body.construct(v4, <int>[
      body.multiply(f32, body.extract(f32, straight, 0), rampAlpha),
      body.multiply(f32, body.extract(f32, straight, 1), rampAlpha),
      body.multiply(f32, body.extract(f32, straight, 2), rampAlpha),
      rampAlpha,
    ]);
  }

  body
    ..store(fragColor, body.scale(v4, color, coverageValue))
    ..returnVoid();

  return module.assemble();
}

/// The five modules a device compiles: one vertex stage and four fragment
/// stages, one per coverage x paint pair.
final class VulkanSparseShaderCode {
  VulkanSparseShaderCode()
      : vertex = buildVulkanSparseVertexShader(),
        fragments = List<Uint32List>.unmodifiable(<Uint32List>[
          for (final int coverage in kVulkanSparseCoverageModes)
            for (final int paint in kVulkanSparsePaintModes)
              buildVulkanSparseFragmentShader(coverage: coverage, paint: paint),
        ]);

  final Uint32List vertex;

  /// Indexed by [fragmentIndex]; the outer loop is coverage and the inner is
  /// paint, so the order matches [kVulkanSparseCoverageModes] crossed with
  /// [kVulkanSparsePaintModes].
  final List<Uint32List> fragments;

  Uint32List fragmentFor({required int coverage, required int paint}) =>
      fragments[fragmentIndex(coverage: coverage, paint: paint)];

  /// Total SPIR-V words emitted, for a diagnostic. A shader that suddenly
  /// halves in size is a builder that stopped emitting a section.
  int get wordCount =>
      vertex.length +
      fragments.fold<int>(0, (int sum, Uint32List f) => sum + f.length);
}

const List<int> kVulkanSparseCoverageModes = <int>[
  kVulkanSparseModeSolid,
  kVulkanSparseModeAlpha,
];

const List<int> kVulkanSparsePaintModes = <int>[
  kVulkanSparsePaintSolid,
  kVulkanSparsePaintGradient,
];

/// Where the module for [coverage] x [paint] sits in
/// [VulkanSparseShaderCode.fragments].
int fragmentIndex({required int coverage, required int paint}) {
  final int row = kVulkanSparseCoverageModes.indexOf(coverage);
  final int column = kVulkanSparsePaintModes.indexOf(paint);
  if (row < 0 || column < 0) {
    throw ArgumentError('no sparse Vulkan fragment module for coverage '
        '$coverage and paint $paint');
  }
  return row * kVulkanSparsePaintModes.length + column;
}

/// How many fragment modules, and therefore how many pipelines per blend.
const int kVulkanSparseFragmentModuleCount = 4;

/// Checks the Dart-side contract against the modules this file emits.
///
/// The GL and Direct3D twins grep their shader *source* for a declaration; a
/// module that is words rather than text cannot be grepped, so this checks the
/// three things the source check was standing in for: that the words are a
/// well-formed SPIR-V module, that the push-constant block the two sides
/// agree on still fits what Vulkan guarantees, and that the module count
/// matches the pipeline count a driver will build. A driver may run this
/// before creating anything; the tests run it unconditionally.
void validateVulkanSparseShaderContract() {
  if (kVulkanSparsePushConstantBytes > kVulkanMinPushConstantBytes) {
    throw StateError(
      'the sparse push-constant block is $kVulkanSparsePushConstantBytes '
      'bytes, past the $kVulkanMinPushConstantBytes Vulkan guarantees; it '
      'now needs a maxPushConstantsSize query and a refusal path',
    );
  }
  if (kVulkanSparseFragmentPushOffset + kVulkanSparseFragmentPushBytes !=
      kVulkanSparsePushConstantBytes) {
    throw StateError('the fragment push-constant range does not end where the '
        'block does');
  }
  if (VulkanSparsePushConstant.gradientGeometry1 + 16 !=
      kVulkanSparsePushConstantBytes) {
    throw StateError('kVulkanSparsePushConstantBytes does not cover the '
        'declared block');
  }
  final VulkanSparseShaderCode code = VulkanSparseShaderCode();
  if (code.fragments.length != kVulkanSparseFragmentModuleCount) {
    throw StateError('kVulkanSparseFragmentModuleCount says '
        '$kVulkanSparseFragmentModuleCount and the builder emitted '
        '${code.fragments.length}');
  }
  for (final (String, Uint32List) module in <(String, Uint32List)>[
    ('vertex', code.vertex),
    for (var i = 0; i < code.fragments.length; i++)
      ('fragment $i', code.fragments[i]),
  ]) {
    final List<String> problems = validateSpirvStructure(module.$2);
    if (problems.isNotEmpty) {
      throw StateError('the sparse ${module.$1} module is malformed: '
          '${problems.join('; ')}');
    }
  }
}

// ---------------------------------------------------------------------------
// The submission arenas
// ---------------------------------------------------------------------------

/// Reusable Vulkan-oriented instance and command arenas built from a
/// [SparseStripDrawPlan].
///
/// A near-duplicate of `SparseGlSubmission` on purpose, and for the reason
/// `SparseD3d12Submission` states: the files are held parallel so the parity
/// between them means something, and the commands here carry a first
/// *instance* where the GL ones carry a byte offset, because `vkCmdDraw` takes
/// one and core GL 3.3 does not.
final class SparseVulkanSubmission {
  SparseVulkanSubmission({int initialInstances = 256, int initialCommands = 64})
      : _instances = Float32List(
          _positive(initialInstances, 'initialInstances') *
              kVulkanSparseInstanceFloatCount,
        ),
        _commands = Int32List(
          _positive(initialCommands, 'initialCommands') *
              kVulkanSparseCommandStride,
        );

  Float32List _instances;
  Int32List _commands;
  int _instanceCount = 0;
  int _commandCount = 0;
  int _growths = 0;

  int get instanceCount => _instanceCount;
  int get commandCount => _commandCount;
  int get arenaGrowths => _growths;

  Float32List get instanceStorage => _instances;
  Int32List get commandStorage => _commands;

  Float32List get instances => Float32List.sublistView(
        _instances,
        0,
        _instanceCount * kVulkanSparseInstanceFloatCount,
      );

  Int32List get commands => Int32List.sublistView(
        _commands,
        0,
        _commandCount * kVulkanSparseCommandStride,
      );

  int commandMode(int command) => _commandField(command, 0);
  int commandMaterial(int command) => _commandField(command, 1);
  int commandAtlasPage(int command) => _commandField(command, 2);
  int commandFirstInstance(int command) => _commandField(command, 3);
  int commandInstanceCount(int command) => _commandField(command, 4);

  double instanceX(int instance) => _instanceField(instance, 0);
  double instanceY(int instance) => _instanceField(instance, 1);
  double instanceWidth(int instance) => _instanceField(instance, 2);
  double instanceHeight(int instance) => _instanceField(instance, 3);
  double instanceAtlasX(int instance) => _instanceField(instance, 4);
  double instanceAtlasY(int instance) => _instanceField(instance, 5);

  /// Re-encodes [plan] while retaining the high-water typed-array arenas.
  void encode(SparseStripDrawPlan plan) {
    _instanceCount = 0;
    _commandCount = 0;
    for (var batch = 0; batch < plan.batchCount; batch++) {
      final int material = plan.batchMaterial(batch);
      final int solidCount = plan.batchSolidCount(batch);
      if (solidCount != 0) {
        final int first = _instanceCount;
        final int end = plan.batchSolidFirst(batch) + solidCount;
        for (var i = plan.batchSolidFirst(batch); i < end; i++) {
          _appendInstance(
            plan.solidX(i),
            plan.solidY(i),
            plan.solidWidth(i),
            plan.solidHeight(i),
            0,
            0,
          );
        }
        _appendCommand(kVulkanSparseModeSolid, material, -1, first, solidCount);
      }

      final int alphaEnd =
          plan.batchAlphaFirst(batch) + plan.batchAlphaCount(batch);
      var alpha = plan.batchAlphaFirst(batch);
      while (alpha < alphaEnd) {
        final int page = plan.alphaAtlasPage(alpha);
        final int first = _instanceCount;
        var count = 0;
        do {
          _appendInstance(
            plan.alphaX(alpha),
            plan.alphaY(alpha),
            plan.alphaWidth(alpha),
            plan.alphaHeight(alpha),
            plan.alphaAtlasX(alpha),
            plan.alphaAtlasY(alpha),
          );
          count++;
          alpha++;
        } while (alpha < alphaEnd && plan.alphaAtlasPage(alpha) == page);
        _appendCommand(kVulkanSparseModeAlpha, material, page, first, count);
      }
    }
  }

  void _appendInstance(
    int x,
    int y,
    int width,
    int height,
    int atlasX,
    int atlasY,
  ) {
    _ensureInstanceCapacity(_instanceCount + 1);
    final int base = _instanceCount * kVulkanSparseInstanceFloatCount;
    _instances[base] = x.toDouble();
    _instances[base + 1] = y.toDouble();
    _instances[base + 2] = width.toDouble();
    _instances[base + 3] = height.toDouble();
    _instances[base + 4] = atlasX.toDouble();
    _instances[base + 5] = atlasY.toDouble();
    _instanceCount++;
  }

  void _appendCommand(
    int mode,
    int material,
    int atlasPage,
    int first,
    int count,
  ) {
    _ensureCommandCapacity(_commandCount + 1);
    final int base = _commandCount * kVulkanSparseCommandStride;
    _commands[base] = mode;
    _commands[base + 1] = material;
    _commands[base + 2] = atlasPage;
    _commands[base + 3] = first;
    _commands[base + 4] = count;
    _commandCount++;
  }

  void _ensureInstanceCapacity(int count) {
    final int required = count * kVulkanSparseInstanceFloatCount;
    if (required <= _instances.length) return;
    var length = _instances.length * 2;
    while (length < required) {
      length *= 2;
    }
    final Float32List grown = Float32List(length)
      ..setRange(0, _instances.length, _instances);
    _instances = grown;
    _growths++;
  }

  void _ensureCommandCapacity(int count) {
    final int required = count * kVulkanSparseCommandStride;
    if (required <= _commands.length) return;
    var length = _commands.length * 2;
    while (length < required) {
      length *= 2;
    }
    final Int32List grown = Int32List(length)
      ..setRange(0, _commands.length, _commands);
    _commands = grown;
    _growths++;
  }

  double _instanceField(int instance, int field) {
    if (instance < 0 || instance >= _instanceCount) {
      throw RangeError.index(instance, _instances, 'instance');
    }
    return _instances[instance * kVulkanSparseInstanceFloatCount + field];
  }

  int _commandField(int command, int field) {
    if (command < 0 || command >= _commandCount) {
      throw RangeError.index(command, _commands, 'command');
    }
    return _commands[command * kVulkanSparseCommandStride + field];
  }
}

int _positive(int value, String name) {
  if (value <= 0) throw ArgumentError.value(value, name, 'must be > 0');
  return value;
}
