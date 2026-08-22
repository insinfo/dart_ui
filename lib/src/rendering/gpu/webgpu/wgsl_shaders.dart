/// The WGSL the WebGPU backend compiles, and the pure mappings around it.
///
/// This file is the `gl_shaders.dart` of the WebGPU path, and like that file it
/// is deliberately free of any browser import: everything in it is a string, a
/// constant or a total function over the renderer's own enums, so the VM test
/// suite can check the shader source and the mapping tables on a machine with
/// no browser and no GPU at all. The interop lives in `webgpu_interop.dart`;
/// the objects live in `webgpu_backend.dart`.
///
/// ## One module, three fragment entry points, where GL had one and a uniform
///
/// `gl_shaders.dart` selects the pipeline's behaviour with a `uMode` uniform,
/// because on GL a program switch costs more than an int compare that is
/// uniform across a draw call. WebGPU removes the choice: the *blend state* is
/// baked into a `GPURenderPipeline` at creation, so a batch that changes blend
/// mode forces a pipeline switch whatever the shader looks like - and once a
/// pipeline switch per state change is a given, folding the mode into the
/// pipeline too costs nothing and deletes a uniform, a branch and a way for the
/// two to disagree. So there is one shader module with one vertex entry point
/// and three fragment entry points, and a pipeline is the pair (entry point,
/// blend state). Nine pipelines at most, created lazily and cached for the
/// device's life.
///
/// The three fragment bodies are line-for-line translations of the GLSL in
/// `gl_shaders.dart`, coverage term included - that term *is* the antialiasing,
/// and the parity argument made there applies unchanged: a WGSL copy that
/// drifted from the GLSL would make the two web backends draw different edges
/// from the same display list, and the difference would look like a driver bug.
///
/// ## There is no `uYFlip`, and that is not an omission
///
/// The GL shader carries a `uYFlip` uniform because GL's framebuffer origin is
/// the bottom-left corner: a pass that renders into a texture something else
/// will sample must invert its projection to leave the image top-down, which is
/// the orientation every texture this renderer samples is stored in.
///
/// WebGPU's conventions dissolve the problem. Normalised device coordinates
/// are y-up, and framebuffer coordinates - where the pixels land - have their
/// origin at the **top-left**, like Metal and Direct3D. So the one projection
/// below, `ndcY = 1 - y / viewport.y * 2`, puts device row 0 in framebuffer
/// row 0 for *every* pass: a canvas comes out the right way up, and a layer
/// texture comes out top-down and is sampled with the same `v = y / height`
/// the sink computes for every other texture. `GpuRenderPass.rendersTopDown`
/// is therefore deliberately ignored by this backend - both orientations are
/// the same orientation here - and the scissor rectangle is passed through
/// unflipped, because `setScissorRect` is in framebuffer coordinates, which
/// already share device space's origin.
///
/// ## The bind group split, and why the uniform is dynamic
///
/// Group 0 holds the per-pass data (the viewport size) behind a dynamic
/// offset; group 1 holds the per-batch data (a sampler and a texture). They
/// are separate groups because they change at different rates and because a
/// grown uniform buffer must not invalidate every cached texture bind group -
/// group 1 never references the uniform buffer, so reallocating it rebuilds
/// exactly one bind group. The offset is dynamic rather than one buffer per
/// pass because `GPUQueue.writeBuffer` is ordered against `submit`: every
/// pass's viewport is written into its own 256-byte slice before the command
/// buffer is submitted, and each pass binds the same group at its own offset.
library;

import '../gpu_pipeline.dart';

/// The vertex entry point. One, shared by all three pipelines, exactly as the
/// GL path shares one vertex shader.
const String kWgslVertexEntryPoint = 'vs_main';

/// The fragment entry point for each [GpuPipelineKind].
///
/// A total function rather than a map, so a new pipeline kind is a compile
/// error here instead of a null at pipeline-creation time.
String wgslFragmentEntryPoint(GpuPipelineKind kind) => switch (kind) {
      GpuPipelineKind.solid => 'fs_solid',
      GpuPipelineKind.coverageMask => 'fs_mask',
      GpuPipelineKind.texturedImage => 'fs_image',
    };

/// The `GPUBlendFactor` enumerant for one of the renderer's blend factors.
///
/// Strings because that is what WebGPU descriptors take - the API has no
/// integer enums - and a total switch for [wgslFragmentEntryPoint]'s reason.
String webGpuBlendFactorName(GpuBlendFactor factor) => switch (factor) {
      GpuBlendFactor.zero => 'zero',
      GpuBlendFactor.one => 'one',
      GpuBlendFactor.oneMinusSrcAlpha => 'one-minus-src-alpha',
    };

/// Bytes per vertex in the one interleaved layout: [kGpuFloatsPerVertex]
/// 32-bit floats. The WebGPU vertex-state descriptor wants bytes where GL's
/// `vertexAttribPointer` wanted them too; the multiplication is done here once
/// so the descriptor and the test agree on the number.
const int kWebGpuVertexStrideBytes = kGpuFloatsPerVertex * 4;

/// Byte offsets of the four vertex attributes, derived from the same
/// `kGpu*Offset` constants the other backends derive theirs from - which is
/// what keeps this backend incapable of disagreeing with the batcher about
/// where a colour lives inside a vertex.
const int kWebGpuPositionOffsetBytes = kGpuPositionOffset * 4;
const int kWebGpuTexCoordOffsetBytes = kGpuTexCoordOffset * 4;
const int kWebGpuColorOffsetBytes = kGpuColorOffset * 4;
const int kWebGpuShapeRectOffsetBytes = kGpuShapeRectOffset * 4;

/// The stride between per-pass uniform slices, in bytes.
///
/// 256 is `minUniformBufferOffsetAlignment`'s specified default, and every
/// dynamic offset must be a multiple of it. The slice itself is eight bytes -
/// a `vec2f` viewport - so 248 of every 256 are padding; a frame has a handful
/// of passes, so the padding is bytes, not kilobytes, and buying the alignment
/// query from the adapter to shave it would be complexity for nothing.
const int kWebGpuUniformSliceStride = 256;

/// Bytes of one pass's uniform data: the `vec2f` viewport.
const int kWebGpuUniformSliceSize = 8;

/// The clear colour as WebGPU wants it: straight floats, RGBA order.
///
/// The input is the same packed premultiplied 32-bit BGRA integer
/// `FrameRequest.clearColor` carries everywhere else, and the extraction is
/// the same one `WebGlRenderDevice.submit` performs before `clearColor` - kept
/// as a pure function here so a VM test can pin the channel order without a
/// browser. Getting it wrong is the classic silently-wrong failure: a red
/// clear renders blue and everything else still works.
({double r, double g, double b, double a}) webGpuClearValue(int clearColor) => (
      r: ((clearColor >> 16) & 0xFF) / 255.0,
      g: ((clearColor >> 8) & 0xFF) / 255.0,
      b: (clearColor & 0xFF) / 255.0,
      a: ((clearColor >> 24) & 0xFF) / 255.0,
    );

/// The whole shader module.
///
/// A constant rather than a function of a dialect flag: WGSL has exactly one
/// dialect, which is the one honest simplification WebGPU offers over GL's
/// desktop/ES split.
const String kWgslShaderModuleSource = '''
// Per-pass data, bound at a dynamic offset. See the library comment of
// wgsl_shaders.dart for why the viewport is the only field and why there is
// no yFlip here.
struct FrameUniforms {
  viewport: vec2f,
}

@group(0) @binding(0) var<uniform> uFrame: FrameUniforms;
@group(1) @binding(0) var uSampler: sampler;
@group(1) @binding(1) var uTexture: texture_2d<f32>;

struct VertexInput {
  @location(0) position: vec2f,
  @location(1) texCoord: vec2f,
  @location(2) color: vec4f,
  @location(3) shapeRect: vec4f,
}

struct VertexOutput {
  @builtin(position) position: vec4f,
  @location(0) texCoord: vec2f,
  @location(1) color: vec4f,
  @location(2) shapeRect: vec4f,
  @location(3) devicePos: vec2f,
}

@vertex
fn vs_main(in: VertexInput) -> VertexOutput {
  var out: VertexOutput;
  out.texCoord = in.texCoord;
  out.color = in.color;
  out.shapeRect = in.shapeRect;
  out.devicePos = in.position;
  // Device space is y-down with the origin at the top-left corner; NDC is
  // y-up with the origin in the middle. WebGPU's framebuffer origin is the
  // top-left corner, so this one flip is right for every pass - surface and
  // layer alike - where GL needed a uniform to invert it per pass.
  out.position = vec4f(
    in.position.x / uFrame.viewport.x * 2.0 - 1.0,
    1.0 - in.position.y / uFrame.viewport.y * 2.0,
    0.0,
    1.0);
  return out;
}

// Exact area of the pixel square at p that lies inside the rectangle r.
// Separable, which is why an axis-aligned rectangle needs no mask. The same
// quantity gl_shaders.dart computes, translated token for token.
fn boxCoverage(r: vec4f, p: vec2f) -> f32 {
  let lo = max(r.xy, p - vec2f(0.5));
  let hi = min(r.zw, p + vec2f(0.5));
  let overlap = clamp(hi - lo, vec2f(0.0), vec2f(1.0));
  return overlap.x * overlap.y;
}

@fragment
fn fs_solid(in: VertexOutput) -> @location(0) vec4f {
  return in.color * boxCoverage(in.shapeRect, in.devicePos);
}

@fragment
fn fs_mask(in: VertexOutput) -> @location(0) vec4f {
  // A coverage mask scales the already-premultiplied colour, which is the
  // premultiplied equivalent of mul255(alpha, coverage) on the CPU.
  let coverage = textureSample(uTexture, uSampler, in.texCoord).r;
  return in.color * coverage * boxCoverage(in.shapeRect, in.devicePos);
}

@fragment
fn fs_image(in: VertexOutput) -> @location(0) vec4f {
  // Premultiplied texel modulated by the paint's alpha; the colour channels
  // carry that alpha too, so this is a plain scale.
  let texel = textureSample(uTexture, uSampler, in.texCoord);
  return texel * in.color.a * boxCoverage(in.shapeRect, in.devicePos);
}
''';
