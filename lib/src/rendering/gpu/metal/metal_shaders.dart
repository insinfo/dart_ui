/// The one Metal Shading Language shader pair the Metal renderer uses.
///
/// This is `gl_shaders.dart` and `d3d12_shaders.dart` transposed, deliberately
/// line for line: one program, three modes selected by a constant, and the same
/// analytic `boxCoverage` term. The parallel is not tidiness - it is what makes
/// a pixel-parity test between backends mean something. A difference between
/// the CPU rasteriser and this backend has to be a bug in one of them, not a
/// difference of intent between two shader authors.
///
/// **Nothing here has been compiled.** There is no Mac in this loop and
/// `newLibraryWithSource:options:error:` has never been called on this string.
/// What the tests assert is structure - that the mode constants match
/// [GpuPipelineKind], that the attribute offsets match `gpu_pipeline.dart`,
/// that the uniform block is the size Dart and MSL both think it is. A
/// syntax error in the MSL below would survive all of that and be caught by
/// the first compile on a Mac.
///
/// ## The conventions, declared
///
/// **Matrices: there are none.** As in the other two, the vertex stage
/// computes normalised device coordinates arithmetically from the device
/// position and the viewport size. That removes the row-major / column-major
/// question rather than answering it.
///
/// **Texture origin: top-left, v downwards.** Metal's texture coordinate
/// origin is the top-left texel and `v` increases downwards. Every texture this
/// renderer samples - an uploaded image, the coverage atlas, the glyph atlas -
/// is stored top-down, row 0 first, because that is the order a [Framebuffer]
/// and a rasterised mask are laid out in. So texture row `y` is `v = y /
/// height`, with nothing flipped anywhere.
///
/// **Render-target origin: top-left, y downwards.** `d3d12_shaders.dart`
/// states that Metal, Direct3D and Vulkan all store a rendered texture
/// top-down while OpenGL is bottom-left. **Confirmed and followed here.**
/// Concretely, for Metal:
///
///   * `MTLViewport.originY` is measured from the **top** of the render target;
///   * `MTLScissorRect.y` likewise;
///   * a texture rendered into and then sampled comes out row 0 first, which
///     is the same orientation as an uploaded one.
///
/// So all three cases - a presented surface, a layer target that will be
/// sampled, and a scissor rectangle - are the same orientation, and this
/// backend passes [kMetalYFlipDefault] everywhere. [kMetalYFlipTopDown] exists
/// only so that deleting the branch would not delete the *reason*: OpenGL needs
/// that flip and Metal does not, and the next person to add a
/// render-into-texture path here would otherwise have to rediscover it.
///
/// The practical consequence for `gpu_layer_stack.dart` is worth stating in
/// one line, because it is the thing that would be got wrong: when a pass
/// reports `rendersTopDown`, the GL backend changes both its projection and its
/// scissor conversion, and **this backend changes neither** - device row 0 is
/// always render-target row 0 here.
///
/// ## Why the uniform block has no `float2`
///
/// `float2` has 8-byte alignment in MSL, so a block of `{float2, uint, uint,
/// uint}` is 24 bytes with the scalars at 8, 12 and 16 - while the obvious Dart
/// mirror of it, five 4-byte fields, is 20 bytes with no padding at all. The
/// two would disagree, and `sizeOf` on the Dart side alone would report 20 and
/// look right.
///
/// So the viewport is **two separate `float`s**. Every field is then 4-byte
/// aligned, the block is 20 bytes on both sides, and the Dart struct is a real
/// mirror that a size and offset test can check. This is the same class of
/// error as the `D3D12_SHADER_RESOURCE_VIEW_DESC` union whose `Texture2D` arm
/// starts at offset 16 rather than 12 - invisible to `sizeOf`, visible to an
/// offset test.
///
/// ## Why two samplers and two samples
///
/// MSL cannot select a `sampler` dynamically without argument buffers, exactly
/// as Shader Model 5.0 cannot. So the two filters this renderer needs - point
/// for the coverage atlases, linear for scaled images - are both declared as
/// `constexpr sampler`s in the shader, both sampled, and one selected by a
/// uniform. The cost is one extra fetch out of a texture that is already in
/// cache; the alternatives were more pipeline states or a sampler heap, and
/// `d3d12_shaders.dart` already weighed the same trade and made the same call.
///
/// Declaring them `constexpr` in the shader is also why `MTLSamplerState` is on
/// the deliberately-unbound list in `metal_bindings.dart`: there is no sampler
/// object to create.
library;

/// Values of the `mode` uniform. Must match [GpuPipelineKind]'s order, and
/// match `kModeSolid` in `gl_shaders.dart` and `kD3d12ModeSolid` in
/// `d3d12_shaders.dart` - the backends are compared pixel for pixel and a mode
/// that meant something different on one side would be very hard to see in a
/// diff.
const int kMetalModeSolid = 0;
const int kMetalModeCoverageMask = 1;
const int kMetalModeTexturedImage = 2;

/// Values of the `yFlip` uniform.
///
/// [kMetalYFlipTopDown] is never passed by this backend. See the library
/// comment: Metal's render-target origin is already the top-left corner.
const int kMetalYFlipDefault = 0;
const int kMetalYFlipTopDown = 1;

/// Values of the `useLinear` uniform, which picks between the two `constexpr`
/// samplers.
const int kMetalSamplerPoint = 0;
const int kMetalSamplerLinear = 1;

/// The buffer index the interleaved vertex data is bound at.
///
/// Zero, and the vertex descriptor's `bufferIndex` must agree: an attribute
/// pointing at a buffer index nothing was bound to reads zeroes, which draws a
/// degenerate quad at the origin rather than failing.
const int kMetalVertexBufferIndex = 0;

/// The buffer index the uniform block is bound at, in **both** stages.
///
/// One in both, not zero in the fragment stage where nothing else is bound.
/// Metal's buffer indices are per-stage, so zero would have been legal - and it
/// would have meant that the same block was `[[buffer(1)]]` in one function and
/// `[[buffer(0)]]` in the other, which is one edit away from binding it to
/// exactly one of the two and getting a shader that draws in the right shape
/// and the wrong colour.
const int kMetalUniformBufferIndex = 1;

/// The texture index the fragment stage samples.
const int kMetalTextureIndex = 0;

/// Attribute indices, matching `gl_shaders.dart`'s `kAttributePosition` and
/// friends and therefore the order of `gpu_pipeline.dart`'s offsets.
const int kMetalAttributePosition = 0;
const int kMetalAttributeTexCoord = 1;
const int kMetalAttributeColor = 2;
const int kMetalAttributeShapeRect = 3;

/// Entry point names, passed to `newFunctionWithName:`.
const String kMetalVertexEntryPoint = 'vsMain';
const String kMetalFragmentEntryPoint = 'fsMain';

/// The whole MSL translation unit - both stages in one string.
///
/// One string rather than two because `newLibraryWithSource:options:error:`
/// compiles a whole library and both functions come out of it. That also makes
/// the shared `Uniforms` and `Varying` declarations literally shared, so the
/// two stages cannot drift apart about which field means what - the same
/// reason `d3d12_shaders.dart` factors out its `_shared` block.
const String kMetalShaderSource = '''
#include <metal_stdlib>
using namespace metal;

// The viewport is two scalars and not a float2 on purpose. See the library
// comment of metal_shaders.dart: a float2 here is 8-byte aligned and would
// make this block 24 bytes while its Dart mirror is 20, with no size check
// able to notice.
struct Uniforms {
  float viewportWidth;
  float viewportHeight;
  uint mode;
  uint yFlip;
  uint useLinear;
};

struct VertexIn {
  float2 position  [[attribute(0)]];
  float2 texCoord  [[attribute(1)]];
  float4 color     [[attribute(2)]];
  float4 shapeRect [[attribute(3)]];
};

struct Varying {
  float4 position [[position]];
  float2 texCoord;
  float4 color;
  float4 shapeRect;
  float2 devicePos;
};

vertex Varying vsMain(VertexIn vin [[stage_in]],
                      constant Uniforms& u [[buffer(1)]]) {
  Varying out;
  out.texCoord = vin.texCoord;
  out.color = vin.color;
  out.shapeRect = vin.shapeRect;
  out.devicePos = vin.position;
  // Device space is y-down with the origin at the top-left corner of the
  // surface; normalised device coordinates are y-up with the origin in the
  // middle. Metal's render target is written from the top-left corner, so this
  // single flip is the whole conversion and yFlip is always 0 - see the
  // library comment of metal_shaders.dart for why the branch is kept anyway.
  float ndcY = 1.0 - vin.position.y / u.viewportHeight * 2.0;
  out.position = float4(
      vin.position.x / u.viewportWidth * 2.0 - 1.0,
      u.yFlip == 0 ? ndcY : -ndcY,
      0.0,
      1.0);
  return out;
}

// Exact area of the pixel square at [p] that lies inside the rectangle [r].
// Separable, which is why an axis-aligned rectangle needs no mask. The same
// arithmetic as raster/coverage.dart on the CPU and as boxCoverage in
// gl_shaders.dart and d3d12_shaders.dart, in that order of authority.
static float boxCoverage(float4 r, float2 p) {
  float2 lo = max(r.xy, p - 0.5);
  float2 hi = min(r.zw, p + 0.5);
  float2 overlap = clamp(hi - lo, 0.0, 1.0);
  return overlap.x * overlap.y;
}

fragment float4 fsMain(Varying in [[stage_in]],
                       constant Uniforms& u [[buffer(1)]],
                       texture2d<float> tex [[texture(0)]]) {
  // MSL cannot index a sampler without argument buffers, so both filters are
  // declared here and one is selected. clamp_to_edge on both: an atlas slot is
  // padded by one texel and a repeat mode would fetch a neighbouring glyph at
  // the seam.
  constexpr sampler pointSampler(coord::normalized,
                                 filter::nearest,
                                 address::clamp_to_edge);
  constexpr sampler linearSampler(coord::normalized,
                                  filter::linear,
                                  address::clamp_to_edge);

  float4 pointTexel = tex.sample(pointSampler, in.texCoord);
  float4 linearTexel = tex.sample(linearSampler, in.texCoord);
  float4 texel = u.useLinear == 0 ? pointTexel : linearTexel;

  float4 color = in.color;
  if (u.mode == 1) {
    // A coverage mask scales the already-premultiplied colour, which is the
    // premultiplied equivalent of mul255(alpha, coverage) on the CPU.
    color *= texel.r;
  } else if (u.mode == 2) {
    // Premultiplied texel modulated by the paint's alpha; the colour channels
    // carry that alpha too, so this is a plain scale.
    color = texel * in.color.a;
  }
  return color * boxCoverage(in.shapeRect, in.devicePos);
}
''';
