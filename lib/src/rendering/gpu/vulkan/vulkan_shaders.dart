/// The one shader program this renderer draws with, emitted as SPIR-V.
///
/// The GLSL twin is `gl_shaders.dart` and the HLSL twin is
/// `d3d11_shaders.dart`; this is deliberately the same shader a third time,
/// not a third shader that happens to look alike. Same interleaved vertex
/// layout out of `gpu_pipeline.dart`, same three modes, same analytic
/// `boxCoverage` term. Every argument in those files applies here. What is
/// written down below is only what Vulkan disagrees with.
///
/// ## Disagreement 1: the three modes are three modules, not three branches
///
/// GL and Direct3D pick the mode with a uniform and an `if` in the fragment
/// stage. This backend compiles three fragment modules instead - one per
/// [GpuPipelineKind] - and picks between them by picking a pipeline, which
/// Vulkan makes the caller do anyway: a `VkPipeline` bakes in blend state, so
/// there is already one object per (mode, blend) pair and the mode costs
/// nothing extra.
///
/// It also removes every branch from the generated SPIR-V, and that is the
/// real reason. `vulkan_spirv.dart` emits straight-line SSA; supporting a
/// branch means `OpSelectionMerge`, a merge block, and a builder that has to
/// track which block it is writing into - a meaningful amount of machinery for
/// a renderer whose shaders have no loops and no data-dependent control flow.
/// Three small modules is the cheaper correct answer.
///
/// The closed-form rounded rectangle did **not** become a fourth module, and
/// the reason is batching rather than elegance. The shape code rides in a
/// *vertex* float (see `gl_shaders.dart`), so a quad decides per-quad whether
/// it is rounded; a fourth module would be a fourth pipeline, and a scene that
/// alternates a plain rectangle with a rounded one would then submit a draw
/// call per primitive instead of one for the batch. So the arm lives inside
/// the solid module as an `OpSelect` - both coverages are evaluated and one is
/// chosen, which is what keeps this file's promise of a single straight-line
/// block intact. `vulkan_spirv_test.dart` asserts that promise by counting
/// `OpLabel`, and it still reads 1.
///
/// ## Disagreement 2: Vulkan's clip space already points the right way
///
/// OpenGL's normalised device y points *up* and its framebuffer origin is the
/// bottom-left corner, which is why `gl_shaders.dart` carries a `uYFlip`
/// uniform and inverts its scissor with it. **Vulkan's NDC y points down and
/// its framebuffer origin is the top-left corner**, which is the same
/// convention the display list, `Framebuffer` and `gpu_layer_stack.dart`
/// already use. So, exactly as in Direct3D:
///
///   * the projection is unconditional - device y maps to clip y with no
///     negation, `y / height * 2 - 1`, the *same* expression as x;
///   * `GpuRenderPass.rendersTopDown` is ignored, because every pass already
///     renders top-down;
///   * a scissor rectangle is used as it comes, with no `height - bottom`;
///   * readback needs no row flip.
///
/// The trap this avoids is the well-known one: copying the GL projection
/// (`1.0 - y / height * 2.0`) into a Vulkan shader draws a correct picture
/// upside down, which reads as a bug in the scene rather than in the backend.
///
/// ## Disagreement 3: the viewport arrives as a push constant
///
/// GL sets a uniform; Direct3D fills a constant buffer. Vulkan has push
/// constants - eight bytes here, written straight into the command buffer -
/// which need no descriptor set, no buffer, no allocation and no
/// synchronisation with the previous frame's value. `vec2 viewport` is the
/// whole of it, and it is visible to the vertex stage only, because the
/// fragment stage does not read it.
///
/// The mode is *not* a push constant, per Disagreement 1, and neither is a
/// y-flip, per Disagreement 2. The result is that a batch change costs a
/// pipeline bind and a descriptor bind, and nothing else.
library;

import 'dart:typed_data';

import '../gpu_pipeline.dart';
import 'vulkan_spirv.dart';

/// Values of the mode this file compiles a separate module for. They are the
/// indices of [GpuPipelineKind] and `vulkan_shaders_test.dart` asserts it.
const int kVulkanModeSolid = 0;
const int kVulkanModeCoverageMask = 1;
const int kVulkanModeTexturedImage = 2;

/// The entry point name every module declares.
///
/// `main` because that is what `VkPipelineShaderStageCreateInfo.pName` will be
/// given and the two have to agree exactly; SPIR-V places no meaning on the
/// name, so a mismatch is not a compile error, it is a pipeline that fails to
/// create with a message about a missing entry point.
const String kVulkanEntryPoint = 'main';

/// What the second texture-coordinate float means in [kVulkanModeSolid].
///
/// The encoding is `gl_shaders.dart`'s and is repeated here only as named
/// numbers, because `gpu_raster_sink.dart` writes one vertex and every backend
/// decodes it: if two of them disagreed about what a code meant, the same
/// display list would draw two different pictures on one machine depending on
/// which backend the policy opened, and every golden in this repository is
/// rendered through one backend at a time so nothing would catch it.
/// `vulkan_analytic_primitive_test.dart` asserts the three agree.
///
/// Zero is "no analytic primitive" on purpose: every other route in this
/// renderer leaves the solid quad's texture coordinate at the origin, so an
/// untouched vertex decodes as a plain rectangle and gets the `boxCoverage` it
/// always got.
const int kVulkanAnalyticNone = 0;
const int kVulkanAnalyticRoundedRect = 1;

/// Vertex attribute locations, matching the interleaved layout of
/// `gpu_pipeline.dart` element for element.
const int kVulkanAttributePosition = 0;
const int kVulkanAttributeTexCoord = 1;
const int kVulkanAttributeColor = 2;
const int kVulkanAttributeShapeRect = 3;

/// The descriptor set and binding the combined image sampler lives at.
///
/// One set with one binding. A second set would buy the ability to change the
/// texture without rebinding anything else, which this renderer never needs:
/// a batch break already changes the pipeline as often as it changes the
/// texture.
const int kVulkanTextureSet = 0;
const int kVulkanTextureBinding = 0;

/// Bytes of push constant the vertex stage reads: one `vec2`.
const int kVulkanPushConstantBytes = 8;

/// The vertex shader, as SPIR-V words.
///
/// Rebuilt on every call rather than cached. It costs a few microseconds once
/// per device and a cache would be a second piece of state to invalidate; the
/// callers - [VulkanShaderModules] - build each module exactly once.
Uint32List buildVulkanVertexShader() {
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
  final int firstMember = module.constantInt(i32, 0);
  final int oneOne = module.constantComposite(v2, <int>[one, one]);

  final int aPosition = module.variable(inV2, kSpirvStorageClassInput);
  final int aTexCoord = module.variable(inV2, kSpirvStorageClassInput);
  final int aColor = module.variable(inV4, kSpirvStorageClassInput);
  final int aShapeRect = module.variable(inV4, kSpirvStorageClassInput);
  final int vTexCoord = module.variable(outV2, kSpirvStorageClassOutput);
  final int vColor = module.variable(outV4, kSpirvStorageClassOutput);
  final int vShapeRect = module.variable(outV4, kSpirvStorageClassOutput);
  final int vDevicePos = module.variable(outV2, kSpirvStorageClassOutput);
  final int position = module.variable(outV4, kSpirvStorageClassOutput);
  final int push = module.variable(pushPointer, kSpirvStorageClassPushConstant);

  module
    ..entryPoint(kSpirvExecutionModelVertex, mainId, kVulkanEntryPoint, <int>[
      aPosition,
      aTexCoord,
      aColor,
      aShapeRect,
      vTexCoord,
      vColor,
      vShapeRect,
      vDevicePos,
      position,
    ])
    ..decorate(
        aPosition, kSpirvDecorationLocation, <int>[kVulkanAttributePosition])
    ..decorate(
        aTexCoord, kSpirvDecorationLocation, <int>[kVulkanAttributeTexCoord])
    ..decorate(aColor, kSpirvDecorationLocation, <int>[kVulkanAttributeColor])
    ..decorate(
        aShapeRect, kSpirvDecorationLocation, <int>[kVulkanAttributeShapeRect])
    ..decorate(vTexCoord, kSpirvDecorationLocation, const <int>[0])
    ..decorate(vColor, kSpirvDecorationLocation, const <int>[1])
    ..decorate(vShapeRect, kSpirvDecorationLocation, const <int>[2])
    ..decorate(vDevicePos, kSpirvDecorationLocation, const <int>[3])
    ..decorate(position, kSpirvDecorationBuiltIn, <int>[kSpirvBuiltInPosition])
    ..decorate(pushStruct, kSpirvDecorationBlock)
    ..memberDecorate(pushStruct, 0, kSpirvDecorationOffset, const <int>[0]);

  final SpirvFunction body = module.beginFunction(voidType, fnType, mainId);
  final int devicePosition = body.load(v2, aPosition);
  body
    ..store(vDevicePos, devicePosition)
    ..store(vTexCoord, body.load(v2, aTexCoord))
    ..store(vColor, body.load(v4, aColor))
    ..store(vShapeRect, body.load(v4, aShapeRect));

  // clip = position / viewport * 2 - 1, in both axes. See Disagreement 2.
  final int viewport = body.load(
      v2,
      body.accessChain(pushMemberPointer, push, <int>[
        firstMember,
      ]));
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

/// The fragment shader for one [GpuPipelineKind], as SPIR-V words.
///
/// [mode] is one of [kVulkanModeSolid], [kVulkanModeCoverageMask] and
/// [kVulkanModeTexturedImage]. Anything else throws rather than defaulting to
/// solid: a mode that silently becomes solid draws a picture that looks like a
/// missing texture, which is the failure that gets blamed on the atlas.
Uint32List buildVulkanFragmentShader(int mode) {
  if (mode != kVulkanModeSolid &&
      mode != kVulkanModeCoverageMask &&
      mode != kVulkanModeTexturedImage) {
    throw ArgumentError.value(
        mode,
        'mode',
        'no Vulkan fragment module; the three modes are the three '
            'GpuPipelineKind values and a fourth needs a module here');
  }
  final bool samples = mode != kVulkanModeSolid;

  final SpirvBuilder module = SpirvBuilder()
    ..capability(kSpirvCapabilityShader);
  final int glsl = module.extInstImport(kGlslStd450);
  module.memoryModel(kSpirvAddressingModelLogical, kSpirvMemoryModelGlsl450);

  final int mainId = module.freshId();

  final int voidType = module.typeVoid();
  final int fnType = module.typeFunction(voidType, const <int>[]);
  final int f32 = module.typeFloat(32);
  final int v2 = module.typeVector(f32, 2);
  final int v4 = module.typeVector(f32, 4);

  final int inV2 = module.typePointer(kSpirvStorageClassInput, v2);
  final int inV4 = module.typePointer(kSpirvStorageClassInput, v4);
  final int outV4 = module.typePointer(kSpirvStorageClassOutput, v4);

  final int sampledImage = module.typeSampledImage(module.typeImage2D(f32));
  final int sampledPointer =
      module.typePointer(kSpirvStorageClassUniformConstant, sampledImage);

  final int zero = module.constantFloat(f32, 0);
  final int one = module.constantFloat(f32, 1);
  final int half = module.constantFloat(f32, 0.5);
  final int zeroZero = module.constantComposite(v2, <int>[zero, zero]);
  final int oneOne = module.constantComposite(v2, <int>[one, one]);
  final int halfHalf = module.constantComposite(v2, <int>[half, half]);

  final int vTexCoord = module.variable(inV2, kSpirvStorageClassInput);
  final int vColor = module.variable(inV4, kSpirvStorageClassInput);
  final int vShapeRect = module.variable(inV4, kSpirvStorageClassInput);
  final int vDevicePos = module.variable(inV2, kSpirvStorageClassInput);
  final int fragColor = module.variable(outV4, kSpirvStorageClassOutput);
  // Declared only where it is read. A solid fill samples nothing, and a module
  // that declares a descriptor it never uses invites the reader to believe the
  // pipeline needs one bound.
  final int texture = samples
      ? module.variable(sampledPointer, kSpirvStorageClassUniformConstant)
      : 0;

  module
    ..entryPoint(kSpirvExecutionModelFragment, mainId, kVulkanEntryPoint,
        <int>[vTexCoord, vColor, vShapeRect, vDevicePos, fragColor])
    ..executionMode(mainId, kSpirvExecutionModeOriginUpperLeft)
    ..decorate(vTexCoord, kSpirvDecorationLocation, const <int>[0])
    ..decorate(vColor, kSpirvDecorationLocation, const <int>[1])
    ..decorate(vShapeRect, kSpirvDecorationLocation, const <int>[2])
    ..decorate(vDevicePos, kSpirvDecorationLocation, const <int>[3])
    ..decorate(fragColor, kSpirvDecorationLocation, const <int>[0]);
  if (samples) {
    module
      ..decorate(texture, kSpirvDecorationDescriptorSet,
          const <int>[kVulkanTextureSet])
      ..decorate(
          texture, kSpirvDecorationBinding, const <int>[kVulkanTextureBinding]);
  }

  final SpirvFunction body = module.beginFunction(voidType, fnType, mainId);
  final int vertexColor = body.load(v4, vColor);

  final int color;
  switch (mode) {
    case kVulkanModeCoverageMask:
      // The premultiplied colour scaled by the coverage byte, which is the
      // premultiplied equivalent of mul255(alpha, coverage) on the CPU. The
      // mask is R8_UNORM, so the coverage is in .r.
      final int texel = body.sample(
          v4, body.load(sampledImage, texture), body.load(v2, vTexCoord));
      color = body.scale(v4, vertexColor, body.extract(f32, texel, 0));
    case kVulkanModeTexturedImage:
      // A premultiplied texel modulated by the paint's alpha. The vertex's
      // colour channels carry that alpha too, so this is a plain scale and
      // not a tint.
      final int texel = body.sample(
          v4, body.load(sampledImage, texture), body.load(v2, vTexCoord));
      color = body.scale(v4, texel, body.extract(f32, vertexColor, 3));
    default:
      color = vertexColor;
  }

  // boxCoverage: the exact area of the pixel square at p that lies inside the
  // rectangle r. Separable, which is why an axis-aligned rectangle needs no
  // mask. The same four steps as the GLSL and the HLSL, in the same order.
  final int rect = body.load(v4, vShapeRect);
  final int pixel = body.load(v2, vDevicePos);
  final int lowCorner = body.shuffle(v2, rect, rect, const <int>[0, 1]);
  final int highCorner = body.shuffle(v2, rect, rect, const <int>[2, 3]);
  final int lo = body.extInst(v2, glsl, kGlslStd450FMax, <int>[
    lowCorner,
    body.subtract(v2, pixel, halfHalf),
  ]);
  final int hi = body.extInst(v2, glsl, kGlslStd450FMin, <int>[
    highCorner,
    body.add(v2, pixel, halfHalf),
  ]);
  final int overlap = body.extInst(v2, glsl, kGlslStd450FClamp,
      <int>[body.subtract(v2, hi, lo), zeroZero, oneOne]);
  final int boxCoverage = body.multiply(
      f32, body.extract(f32, overlap, 0), body.extract(f32, overlap, 1));

  final int coverage = mode == kVulkanModeSolid
      ? _analyticCoverage(
          body,
          glsl: glsl,
          f32: f32,
          v2: v2,
          boolType: module.typeBool(),
          lowCorner: lowCorner,
          highCorner: highCorner,
          pixel: pixel,
          texCoord: body.load(v2, vTexCoord),
          boxCoverage: boxCoverage,
          zero: zero,
          one: one,
          half: half,
          zeroZero: zeroZero,
        )
      : boxCoverage;

  body
    ..store(fragColor, body.scale(v4, color, coverage))
    ..returnVoid();

  return module.assemble();
}

/// `boxCoverage`, or the closed-form rounded-rectangle coverage where the
/// vertex asked for one, chosen with an `OpSelect`.
///
/// ## It is the *same* formula, instruction for instruction
///
/// `gl_shaders.dart`'s `roundedCoverage` is the original and this is its third
/// transcription, after the HLSL. It is transcribed rather than re-derived on
/// purpose: an SDF that is merely equivalent - `sqrt` of a `dot` instead of
/// `length`, the radius folded into the extent instead of added to `q`, the
/// clamp written as two `min`/`max` - evaluates to a *slightly* different
/// float32, and a half-coverage pixel then quantises one level the other way
/// along every rounded edge. That is invisible in a screenshot and fatal to
/// `vulkan_cpu_parity_test.dart`, which since 06/09/2026 asserts this shape at
/// `tolerance: 0` against the CPU's own transcription in
/// `raster/rounded_rect_coverage.dart`. So the order of operations below is
/// the GLSL's, and a simplification that looks harmless is a parity failure.
///
///     vec2 centre = (r.xy + r.zw) * 0.5;
///     vec2 extent = (r.zw - r.xy) * 0.5;
///     vec2 q = abs(p - centre) - extent + rad;
///     float d = min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - rad;
///     return clamp(0.5 - d, 0.0, 1.0);
///
/// ## Why `OpSelect` and not `OpSelectionMerge`
///
/// A branch would need a merge block and a builder that tracks which block it
/// is writing into; `vulkan_spirv.dart` says so and says the day to build that
/// is the day a shader needs a loop. This needs neither: the field is total.
/// `max(q, 0.0)` is non-negative before `length` sees it, so there is no
/// `sqrt` of a negative and no division anywhere, and evaluating it on a quad
/// that is *not* rounded - where `rad` is 0 and `q` reduces to the plain box
/// field - produces a finite number that is then discarded. `OpSelect`
/// propagates nothing from the operand it drops.
///
/// The test is `>= 0.5` and not `== 1.0` for the reason the GLSL and the HLSL
/// both record: the shape code is written identically on all four vertices so
/// it *should* interpolate to a constant, but a driver is entitled to
/// reconstruct 1.0 as 0.99999994 at the pixel centre, and an equality would
/// then draw a square-cornered rectangle where a rounded one was asked for -
/// on some hardware only, which is the worst kind of only.
int _analyticCoverage(
  SpirvFunction body, {
  required int glsl,
  required int f32,
  required int v2,
  required int boolType,
  required int lowCorner,
  required int highCorner,
  required int pixel,
  required int texCoord,
  required int boxCoverage,
  required int zero,
  required int one,
  required int half,
  required int zeroZero,
}) {
  // Not a texture coordinate: `gpu_raster_sink.dart` writes the radius and the
  // shape code into the two floats the solid pipeline has never sampled with.
  final int radius = body.extract(f32, texCoord, 0);
  final int shapeCode = body.extract(f32, texCoord, 1);
  // SPIR-V has no implicit broadcast, so the scalar radius that GLSL adds to a
  // vec2 has to be built into one.
  final int radiusPair = body.construct(v2, <int>[radius, radius]);

  final int centre = body.scale(v2, body.add(v2, lowCorner, highCorner), half);
  final int extent =
      body.scale(v2, body.subtract(v2, highCorner, lowCorner), half);
  final int folded = body.extInst(
      v2, glsl, kGlslStd450FAbs, <int>[body.subtract(v2, pixel, centre)]);
  final int q = body.add(v2, body.subtract(v2, folded, extent), radiusPair);

  // The interior term: how far inside the inset box the pixel is, zero
  // outside it.
  final int inner = body.extInst(f32, glsl, kGlslStd450FMin, <int>[
    body.extInst(f32, glsl, kGlslStd450FMax,
        <int>[body.extract(f32, q, 0), body.extract(f32, q, 1)]),
    zero,
  ]);
  // The exterior term: the distance to the inset box's corner, which is what
  // turns the corner into an arc.
  final int outer = body.extInst(f32, glsl, kGlslStd450Length, <int>[
    body.extInst(v2, glsl, kGlslStd450FMax, <int>[q, zeroZero]),
  ]);
  final int distance = body.subtract(f32, body.add(f32, inner, outer), radius);
  final int rounded = body.extInst(f32, glsl, kGlslStd450FClamp,
      <int>[body.subtract(f32, half, distance), zero, one]);

  return body.select(
      f32,
      body.greaterThanOrEqualFloat(boolType, shapeCode, half),
      rounded,
      boxCoverage);
}

/// The four modules a device compiles: one vertex stage and three fragment
/// stages, indexed by [GpuPipelineKind.index].
final class VulkanShaderCode {
  VulkanShaderCode()
      : vertex = buildVulkanVertexShader(),
        fragments = List<Uint32List>.unmodifiable(<Uint32List>[
          for (final GpuPipelineKind kind in GpuPipelineKind.values)
            buildVulkanFragmentShader(kind.index),
        ]);

  final Uint32List vertex;
  final List<Uint32List> fragments;

  Uint32List fragmentFor(GpuPipelineKind kind) => fragments[kind.index];

  /// Total words emitted, for a diagnostic. A shader that suddenly halves in
  /// size is a builder that stopped emitting a section.
  int get wordCount =>
      vertex.length +
      fragments.fold<int>(0, (int sum, Uint32List f) => sum + f.length);
}
