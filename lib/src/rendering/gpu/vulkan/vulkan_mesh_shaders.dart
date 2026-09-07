/// The mesh program, emitted as SPIR-V by hand: one vertex stage, one fragment
/// stage, and the CPU rasteriser's shading transcribed instruction by
/// instruction.
///
/// `vulkan_shaders.dart` is the model - the same [SpirvBuilder], the same
/// entry-point/interface/decoration order, the same "both arms then `OpSelect`"
/// idiom in place of a branch - and its library comment argues for why this
/// repository writes SPIR-V rather than taking glslang. That is not repeated.
/// `lib/src/rendering/gpu/d3d11/d3d11_mesh_shaders.dart` is the authority for
/// the *shading*, and its three disagreements between a software rasteriser and
/// a hardware one hold here word for word: the depth range, which varyings are
/// perspective-correct, and that the arithmetic runs in **0..255 channel space**
/// and divides by 255 exactly once at the return.
///
/// What follows is only what Vulkan makes different.
///
/// ## Disagreement V1: the clip space is Direct3D's depth and OpenGL's
/// inverted Y
///
/// Vulkan clips to `0 <= z <= w`, like Direct3D, so the `z' = (z + w) * 0.5`
/// remap the two Direct3D ports need is needed here unchanged. Vulkan's
/// **Y axis also points down** in normalised device coordinates, where
/// `Matrix4.perspective` - which is OpenGL's, and is shared with the CPU
/// rasteriser on purpose - produces a Y that points up. So the vertex stage
/// negates `clip.y` as well.
///
/// The two corrections have completely different symptoms and that is worth
/// knowing before debugging one of them: **a missing depth remap clips the
/// model's near half away**, and **a missing Y negation draws it upside down**.
/// A pipeline with both wrong looks like a pipeline with neither.
///
/// Negating Y is done here and not by a `VkViewport` with a negative height,
/// which is the other well-known way. Two reasons: the negative-height viewport
/// is `VK_KHR_maintenance1`, promoted to core only in Vulkan 1.1, and this
/// backend targets 1.0; and a negative height changes the *framebuffer*
/// winding, so the front-face rule would then have to differ from the two
/// Direct3D ports' for a reason no reader would find here.
///
/// After the negation the framebuffer coordinates are the Direct3D ports'
/// exactly, so `VK_FRONT_FACE_COUNTER_CLOCKWISE` is the same set of triangles
/// as `FrontCounterClockwise = TRUE`, which is what makes the winding argument
/// in `d3d11_mesh_pipeline.dart` apply to this backend without restatement.
///
/// ## Disagreement V2: there is no matrix in the builder, and none is needed
///
/// `vulkan_spirv.dart` emits no `OpTypeMatrix` and no `OpMatrixTimesVector`.
/// Rather than extend it, the model-view-projection travels as **four `vec4`
/// rows** and the transform is four `OpDot`s. That is the same arithmetic a
/// driver compiles `mul(m, v)` into, it needs no new opcode, and it makes the
/// row-major/column-major question disappear instead of answering it: the Dart
/// side writes row `i` at push-constant offset `i * 16` and the shader dots row
/// `i` with the position, so there is exactly one place the convention is
/// stated and it is the same place on both sides.
///
/// ## Disagreement V3: the constants are push constants, all 112 bytes of them
///
/// No uniform buffer and no descriptor for it. Vulkan guarantees at least 128
/// bytes of push constant on every device; the seven `vec4` registers below are
/// 112, so the whole per-primitive state rides in the command buffer and there
/// is no buffer whose lifetime has to outlive the frame that reads it.
///
/// The `float4x4 normalMatrix` the two HLSL programs carry is **absent**, and
/// that is a deliberate subtraction rather than an omission: the Dart side of
/// both of them always writes the identity, because `MeshRasterizer` shades
/// against model-space normals and a model-space light and a [MeshScene] has no
/// model matrix at all. Three `vec4` registers and nine multiply-adds per
/// vertex to compute `n = I * n` is arithmetic that can only lose precision,
/// and here it would also be 48 of the 128 guaranteed bytes. When a model
/// matrix arrives it is three more registers and a change on the Dart side, the
/// same as there.
///
/// ## Disagreement V4: `MeshShading.wireframe` is not wireframe here
///
/// `VK_POLYGON_MODE_LINE` requires the `fillModeNonSolid` device feature, and
/// `VulkanDevice.open` enables **no** device features - `pEnabledFeatures` is
/// null - so asking for it would be invalid use that the validation layer
/// reports and a driver is free to ignore. Enabling it is a change to
/// `vulkan_device.dart` that every Vulkan device in the process would pay for,
/// including the ones that do not support it. So this backend draws
/// `MeshShading.wireframe` as an **unlit solid** model and says so here rather
/// than silently. It is the one shading mode where this backend and the two
/// Direct3D ports do not draw the same picture.
library;

import 'dart:typed_data';

import 'vulkan_spirv.dart';

/// The entry point name both stages use.
const String kVulkanMeshEntryPoint = 'main';

/// Vertex attribute locations, matching the interleaved vertex the pipeline
/// uploads.
const int kVulkanMeshAttributePosition = 0;
const int kVulkanMeshAttributeNormal = 1;
const int kVulkanMeshAttributeTexCoord = 2;

/// Bytes of one vertex: `vec3` position, `vec3` normal, `vec2` texture
/// coordinate.
///
/// Thirty-two, the same stride the two Direct3D ports use, which is what lets
/// the three build their vertex streams with one piece of arithmetic.
const int kVulkanMeshVertexStrideBytes = 32;

/// Byte offsets of the three attributes inside one vertex.
const int kVulkanMeshPositionOffset = 0;
const int kVulkanMeshNormalOffset = 12;
const int kVulkanMeshTexCoordOffset = 24;

/// The descriptor set and binding the base-colour sampler lives at.
///
/// Deliberately the same pair `vulkan_shaders.dart` declares, because the mesh
/// pipeline layout reuses the *same* `VkDescriptorSetLayout` object the 2D one
/// built. See `VulkanMeshRenderer` for why: a descriptor set allocated from one
/// layout may only be bound through a pipeline layout whose set at that index
/// is identically defined, and sharing the object is the only way to be sure
/// the two never drift apart.
const int kVulkanMeshTextureSet = 0;
const int kVulkanMeshTextureBinding = 0;

/// Push-constant offsets, in bytes, of the seven `vec4` registers.
///
/// A block of `vec4`s at 16-byte offsets, which every layout rule this could be
/// read under - std140, std430, scalar - agrees about. Anything narrower would
/// have to name the rule.
abstract final class VulkanMeshPushConstant {
  /// Rows 0..3 of the model-view-projection. See "Disagreement V2".
  static const int row0 = 0;
  static const int row1 = 16;
  static const int row2 = 32;
  static const int row3 = 48;

  /// xyz: the direction light travels in, already normalised. w: the ambient
  /// level, which is `MeshRasterizer.render`'s `ambient` argument.
  static const int light = 64;

  /// rgb in **0..255**, not 0..1, and a in 0..255 as well. See the Direct3D 11
  /// shader's "Disagreement C".
  static const int baseColor = 80;

  /// x: 1 when the surface is lit, 0 for `MeshShading.unlit` and `.wireframe`.
  /// y: 1 when a base-colour texture is bound at the sampler.
  static const int options = 96;

  /// Total bytes, and the size of the one `VkPushConstantRange`.
  ///
  /// 112 of the 128 every Vulkan 1.0 device guarantees.
  static const int bytes = 112;
}

/// Members of the push-constant block, in declaration order.
const int _memberRow0 = 0;
const int _memberRow1 = 1;
const int _memberRow2 = 2;
const int _memberRow3 = 3;
const int _memberLight = 4;
const int _memberBaseColor = 5;
const int _memberOptions = 6;
const int _memberCount = 7;

/// The mesh vertex stage, as SPIR-V words.
Uint32List buildVulkanMeshVertexShader() {
  final SpirvBuilder module = SpirvBuilder()
    ..capability(kSpirvCapabilityShader)
    ..memoryModel(kSpirvAddressingModelLogical, kSpirvMemoryModelGlsl450);

  final int mainId = module.freshId();

  final int voidType = module.typeVoid();
  final int fnType = module.typeFunction(voidType, const <int>[]);
  final int f32 = module.typeFloat(32);
  final int i32 = module.typeInt(32, signed: true);
  final int v2 = module.typeVector(f32, 2);
  final int v3 = module.typeVector(f32, 3);
  final int v4 = module.typeVector(f32, 4);

  final int inV2 = module.typePointer(kSpirvStorageClassInput, v2);
  final int inV3 = module.typePointer(kSpirvStorageClassInput, v3);
  final int outV2 = module.typePointer(kSpirvStorageClassOutput, v2);
  final int outV3 = module.typePointer(kSpirvStorageClassOutput, v3);
  final int outV4 = module.typePointer(kSpirvStorageClassOutput, v4);

  final int pushStruct = module.typeStruct(List<int>.filled(_memberCount, v4));
  final int pushPointer =
      module.typePointer(kSpirvStorageClassPushConstant, pushStruct);
  final int pushMemberPointer =
      module.typePointer(kSpirvStorageClassPushConstant, v4);

  final int one = module.constantFloat(f32, 1);
  final int half = module.constantFloat(f32, 0.5);

  final int aPosition = module.variable(inV3, kSpirvStorageClassInput);
  final int aNormal = module.variable(inV3, kSpirvStorageClassInput);
  final int aTexCoord = module.variable(inV2, kSpirvStorageClassInput);
  final int vNormal = module.variable(outV3, kSpirvStorageClassOutput);
  final int vTexCoord = module.variable(outV2, kSpirvStorageClassOutput);
  final int position = module.variable(outV4, kSpirvStorageClassOutput);
  final int push = module.variable(pushPointer, kSpirvStorageClassPushConstant);

  module
    ..entryPoint(kSpirvExecutionModelVertex, mainId, kVulkanMeshEntryPoint,
        <int>[aPosition, aNormal, aTexCoord, vNormal, vTexCoord, position])
    ..decorate(aPosition, kSpirvDecorationLocation,
        <int>[kVulkanMeshAttributePosition])
    ..decorate(
        aNormal, kSpirvDecorationLocation, <int>[kVulkanMeshAttributeNormal])
    ..decorate(aTexCoord, kSpirvDecorationLocation,
        <int>[kVulkanMeshAttributeTexCoord])
    ..decorate(vNormal, kSpirvDecorationLocation, const <int>[0])
    // Affine, and the fragment stage declares the same. See
    // [kSpirvDecorationNoPerspective]: a decoration on only one side of an
    // interface is a module the validator rejects, and a decoration on neither
    // is a smooth-shaded model whose highlights sit a few pixels from where the
    // CPU puts them.
    ..decorate(vNormal, kSpirvDecorationNoPerspective)
    ..decorate(vTexCoord, kSpirvDecorationLocation, const <int>[1])
    ..decorate(position, kSpirvDecorationBuiltIn, <int>[kSpirvBuiltInPosition])
    ..decorate(pushStruct, kSpirvDecorationBlock);
  for (var i = 0; i < _memberCount; i++) {
    module.memberDecorate(pushStruct, i, kSpirvDecorationOffset, <int>[i * 16]);
  }

  final SpirvFunction body = module.beginFunction(voidType, fnType, mainId);
  int row(int member) => body.load(
        v4,
        body.accessChain(
            pushMemberPointer, push, <int>[module.constantInt(i32, member)]),
      );

  final int local = body.load(v3, aPosition);
  final int local4 = body.construct(v4, <int>[
    body.extract(f32, local, 0),
    body.extract(f32, local, 1),
    body.extract(f32, local, 2),
    one,
  ]);
  final int clipX = body.dot(f32, row(_memberRow0), local4);
  final int clipY = body.dot(f32, row(_memberRow1), local4);
  final int clipZ = body.dot(f32, row(_memberRow2), local4);
  final int clipW = body.dot(f32, row(_memberRow3), local4);

  body
    ..store(
        position,
        body.construct(v4, <int>[
          clipX,
          // Disagreement V1, half one: OpenGL's Y up made Vulkan's Y down.
          body.negate(f32, clipY),
          // Disagreement V1, half two: `[-1, 1]` made `[0, w]`. x, y and w are
          // untouched, so the perspective divide, the viewport transform and
          // the near-plane clip all land where the CPU rasteriser's do.
          // `multiply` and not `scale`: `OpVectorTimesScalar` needs a vector
          // on the left and this is two scalars, which the validator catches
          // and a reader does not.
          body.multiply(f32, body.add(f32, clipZ, clipW), half),
          clipW,
        ]))
    ..store(vNormal, body.load(v3, aNormal))
    ..store(vTexCoord, body.load(v2, aTexCoord))
    ..returnVoid();

  return module.assemble();
}

/// The mesh fragment stage, as SPIR-V words.
///
/// One module for every shading mode, with `lit` and `textured` arriving as
/// push constants and selected with `OpSelect`. `vulkan_shaders.dart` builds a
/// module per mode instead, and the difference is not inconsistency: there the
/// mode is a property of a *batch* and the pipeline changes at every batch
/// break anyway, while here it is a property of a **material** and a mesh with
/// a hundred materials would otherwise be a hundred pipeline objects compiled
/// during the first frame that opened the model.
///
/// The cost of the choice is that the texture is sampled even when the material
/// has none. That is what the 1x1 placeholder `VulkanMeshRenderer` binds is
/// for, and it is the same trade `d3d12_shaders.dart` records for its two
/// samplers: one fetch out of a texture that is already in cache, against a
/// pipeline object per combination.
Uint32List buildVulkanMeshFragmentShader() {
  final SpirvBuilder module = SpirvBuilder()
    ..capability(kSpirvCapabilityShader);
  final int glsl = module.extInstImport(kGlslStd450);
  module.memoryModel(kSpirvAddressingModelLogical, kSpirvMemoryModelGlsl450);

  final int mainId = module.freshId();

  final int voidType = module.typeVoid();
  final int fnType = module.typeFunction(voidType, const <int>[]);
  final int f32 = module.typeFloat(32);
  final int i32 = module.typeInt(32, signed: true);
  final int boolType = module.typeBool();
  final int bool3 = module.typeVector(boolType, 3);
  final int v2 = module.typeVector(f32, 2);
  final int v3 = module.typeVector(f32, 3);
  final int v4 = module.typeVector(f32, 4);

  final int inV2 = module.typePointer(kSpirvStorageClassInput, v2);
  final int inV3 = module.typePointer(kSpirvStorageClassInput, v3);
  final int inBool = module.typePointer(kSpirvStorageClassInput, boolType);
  final int outV4 = module.typePointer(kSpirvStorageClassOutput, v4);

  final int imageType = module.typeImage2D(f32);
  final int sampledImage = module.typeSampledImage(imageType);
  final int sampledPointer =
      module.typePointer(kSpirvStorageClassUniformConstant, sampledImage);

  final int pushStruct = module.typeStruct(List<int>.filled(_memberCount, v4));
  final int pushPointer =
      module.typePointer(kSpirvStorageClassPushConstant, pushStruct);
  final int pushMemberPointer =
      module.typePointer(kSpirvStorageClassPushConstant, v4);

  final int zero = module.constantFloat(f32, 0);
  final int half = module.constantFloat(f32, 0.5);
  final int one = module.constantFloat(f32, 1);
  final int oneOverTwoFiveFive = module.constantFloat(f32, 1 / 255.0);
  final int twoFiveFive = module.constantFloat(f32, 255);
  final int oneTwoSeven = module.constantFloat(f32, 127);
  final int epsilon = module.constantFloat(f32, 1e-4);
  final int fillScale = module.constantFloat(f32, 0.25);
  final int lambertScale = module.constantFloat(f32, 0.85);
  final int intensityCeiling = module.constantFloat(f32, 1.2);
  final int halfV3 = module.constantComposite(v3, <int>[half, half, half]);
  final int ceilingV3 = module
      .constantComposite(v3, <int>[twoFiveFive, twoFiveFive, twoFiveFive]);

  final int vNormal = module.variable(inV3, kSpirvStorageClassInput);
  final int vTexCoord = module.variable(inV2, kSpirvStorageClassInput);
  final int frontFacing = module.variable(inBool, kSpirvStorageClassInput);
  final int fragColor = module.variable(outV4, kSpirvStorageClassOutput);
  final int texture =
      module.variable(sampledPointer, kSpirvStorageClassUniformConstant);
  final int push = module.variable(pushPointer, kSpirvStorageClassPushConstant);

  module
    ..entryPoint(kSpirvExecutionModelFragment, mainId, kVulkanMeshEntryPoint,
        <int>[vNormal, vTexCoord, frontFacing, fragColor])
    ..executionMode(mainId, kSpirvExecutionModeOriginUpperLeft)
    ..decorate(vNormal, kSpirvDecorationLocation, const <int>[0])
    ..decorate(vNormal, kSpirvDecorationNoPerspective)
    ..decorate(vTexCoord, kSpirvDecorationLocation, const <int>[1])
    ..decorate(
        frontFacing, kSpirvDecorationBuiltIn, <int>[kSpirvBuiltInFrontFacing])
    ..decorate(fragColor, kSpirvDecorationLocation, const <int>[0])
    ..decorate(texture, kSpirvDecorationDescriptorSet,
        const <int>[kVulkanMeshTextureSet])
    ..decorate(texture, kSpirvDecorationBinding,
        const <int>[kVulkanMeshTextureBinding])
    ..decorate(pushStruct, kSpirvDecorationBlock);
  for (var i = 0; i < _memberCount; i++) {
    module.memberDecorate(pushStruct, i, kSpirvDecorationOffset, <int>[i * 16]);
  }

  final SpirvFunction body = module.beginFunction(voidType, fnType, mainId);
  int member(int index) => body.load(
        v4,
        body.accessChain(
            pushMemberPointer, push, <int>[module.constantInt(i32, index)]),
      );

  final int baseColor = member(_memberBaseColor);
  final int light = member(_memberLight);
  final int options = member(_memberOptions);
  final int base = body.shuffle(v3, baseColor, baseColor, const <int>[0, 1, 2]);

  // `MeshRasterizer._mul`, transcribed: `(a * b + 127) ~/ 255` on 0..255
  // integers held exactly in floats. `floor(x + 0.5)` rather than an extended
  // `Round`, because GLSL.std.450's `Round` is unspecified on a tie and every
  // value here is one; the epsilon is what makes the integer divide exact, a
  // true quotient that is a whole number being able to land a few ulps below
  // it where `floor` would take it down a level.
  int modulate(int texel, int factor) {
    final int scaled = body.extInst(f32, glsl, kGlslStd450Floor,
        <int>[body.add(f32, body.multiply(f32, texel, twoFiveFive), half)]);
    final int product = body.multiply(f32, scaled, factor);
    return body.extInst(f32, glsl, kGlslStd450Floor, <int>[
      body.add(
          f32,
          body.multiply(
              f32, body.add(f32, product, oneTwoSeven), oneOverTwoFiveFive),
          epsilon)
    ]);
  }

  final int texel = body.sample(
      v4, body.load(sampledImage, texture), body.load(v2, vTexCoord));
  final int textured = body.construct(
      bool3,
      List<int>.filled(
          3,
          body.greaterThanOrEqualFloat(
              boolType, body.extract(f32, options, 1), half)));
  // Multiplied by the factor rather than replacing it, which is what glTF
  // specifies: a white factor samples the texture unchanged and a tinted one
  // tints it.
  final int modulated = body.construct(v3, <int>[
    modulate(body.extract(f32, texel, 0), body.extract(f32, base, 0)),
    modulate(body.extract(f32, texel, 1), body.extract(f32, base, 1)),
    modulate(body.extract(f32, texel, 2), body.extract(f32, base, 2)),
  ]);
  final int surface = body.select(v3, textured, modulated, base);

  // `MeshRasterizer._shade`, transcribed. A back face that survived culling - a
  // double-sided material - is lit with its normal reversed; without that the
  // inside of an open shell is black and looks like a hole.
  final int normal = body
      .extInst(v3, glsl, kGlslStd450Normalize, <int>[body.load(v3, vNormal)]);
  final int front = body.construct(
      bool3, List<int>.filled(3, body.load(boolType, frontFacing)));
  final int shadingNormal =
      body.select(v3, front, normal, body.negate(v3, normal));
  final int towards = body.dot(
      f32, shadingNormal, body.shuffle(v3, light, light, const <int>[0, 1, 2]));
  final int lambert = body.extInst(
      f32, glsl, kGlslStd450FMax, <int>[zero, body.negate(f32, towards)]);
  // A second, dimmer light from the opposite side. One light leaves half of
  // every model in flat ambient, where its shape cannot be read at all.
  final int fill = body.multiply(
      f32,
      body.extInst(f32, glsl, kGlslStd450FMax, <int>[zero, towards]),
      fillScale);
  final int intensity = body.extInst(f32, glsl, kGlslStd450FClamp, <int>[
    body.add(
        f32,
        body.add(f32, body.extract(f32, light, 3),
            body.multiply(f32, lambert, lambertScale)),
        fill),
    zero,
    intensityCeiling,
  ]);
  // `floor(x + 0.5)` and not a `Round`: Dart's `double.round()` is
  // round-half-away-from-zero and every value here is non-negative, so
  // away-from-zero is up, and this is that.
  final int shaded = body.extInst(v3, glsl, kGlslStd450FMin, <int>[
    body.extInst(v3, glsl, kGlslStd450Floor,
        <int>[body.add(v3, body.scale(v3, surface, intensity), halfV3)]),
    ceilingV3,
  ]);
  final int lit = body.construct(
      bool3,
      List<int>.filled(
          3,
          body.greaterThanOrEqualFloat(
              boolType, body.extract(f32, options, 0), half)));
  final int result = body.select(v3, lit, shaded, surface);

  // Opaque, and premultiplying is therefore the identity. The one divide by
  // 255 the whole program does.
  final int scaled = body.scale(v3, result, oneOverTwoFiveFive);
  body
    ..store(
        fragColor,
        body.construct(v4, <int>[
          body.extract(f32, scaled, 0),
          body.extract(f32, scaled, 1),
          body.extract(f32, scaled, 2),
          one,
        ]))
    ..returnVoid();

  return module.assemble();
}
