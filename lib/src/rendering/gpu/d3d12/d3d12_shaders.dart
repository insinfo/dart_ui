/// The one HLSL shader pair the Direct3D 12 renderer uses.
///
/// This is `gl_shaders.dart` transposed, deliberately line for line: one
/// program, three modes selected by a constant, and the same analytic
/// `boxCoverage` term. Keeping the two files parallel is not tidiness - it is
/// what makes the parity test in `test/rendering/gpu/d3d12/` meaningful. A
/// difference between the CPU rasteriser and this backend has to be a bug in
/// one of them, not a difference of intent between two shader authors.
///
/// ## The conventions, declared
///
/// **Matrices: there are none.** No `float4x4` is uploaded and no matrix is
/// multiplied. The vertex stage computes normalised device coordinates
/// arithmetically from the device-space position and the viewport size, which
/// is exactly what the GLSL does. That removes the row-major / column-major
/// question from this backend entirely rather than answering it, and the
/// removal is the point: HLSL packs constant-buffer matrices **column-major by
/// default** while GLSL's `mat4` constructor takes columns and this
/// framework's [Transform2D] stores rows, so a matrix crossing that boundary
/// has three chances to be transposed and no test that would notice a
/// transpose of a symmetric projection. If a future change does need one, it
/// must be declared `row_major` in the HLSL and uploaded in row order, and
/// this comment is the place that says so.
///
/// **Texture origin: top-left, v downwards.** Direct3D's texture coordinate
/// origin is the top-left texel, and `v` increases downwards. Every texture
/// this renderer samples - an uploaded image, the coverage atlas, the glyph
/// atlas - is stored top-down, row 0 first, which is the order a [Framebuffer]
/// and a rasterised mask are laid out in. So texture row `y` is `v = y /
/// height`, with nothing flipped anywhere.
///
/// **Render-target origin: top-left, y downwards.** This is where Direct3D and
/// OpenGL genuinely disagree, and it is why [kD3d12YFlipTopDown] exists only
/// to be documented as unused. GL's framebuffer origin is the *bottom-left*
/// corner, so a GL pass that renders into a texture something else will sample
/// has to invert its projection to leave the image top-down - that is what
/// `gl_shaders.dart`'s `uYFlip` is for. Direct3D 12 writes render-target row 0
/// at the top already, and its `D3D12_RECT` scissor is y-down from the same
/// corner, so:
///
///   * a surface that is presented or read back is written top-down;
///   * a layer target that will be sampled is written top-down;
///   * a scissor rectangle needs no y conversion at all.
///
/// All three are the same orientation, so this backend passes
/// [kD3d12YFlipDefault] everywhere. The constant and the branch are kept
/// because deleting them would leave the *reason* unrecorded, and the next
/// person to add a render-into-texture path here would have to rediscover that
/// Direct3D does not need the flip that OpenGL does.
///
/// ## Why two samplers and two samples
///
/// Shader Model 5.0 cannot select a `SamplerState` dynamically - that needs the
/// descriptor indexing of 5.1 and a sampler heap. The two filters this
/// renderer needs (point for coverage atlases, linear for scaled images) are
/// therefore both declared as static samplers, both sampled, and one selected
/// by a root constant. The cost is one extra texture fetch per pixel; the
/// alternatives were a fourth pipeline state object per blend mode, or a
/// dynamic sampler heap, and both are more machinery than a fetch out of a
/// texture that is already in cache.
library;

/// Values of the `uMode` root constant. Must match [GpuPipelineKind]'s order,
/// and match `kModeSolid` and friends in `gl_shaders.dart` - the two backends
/// are compared pixel for pixel and a mode that meant something different on
/// one side would be very hard to see in the diff.
const int kD3d12ModeSolid = 0;
const int kD3d12ModeCoverageMask = 1;
const int kD3d12ModeTexturedImage = 2;

/// Values of the `uYFlip` root constant.
///
/// [kD3d12YFlipTopDown] is never passed by this backend. See the library
/// comment: Direct3D's render-target origin is already the top-left corner, so
/// every pass here is [kD3d12YFlipDefault].
const int kD3d12YFlipDefault = 0;
const int kD3d12YFlipTopDown = 1;

/// Values of the `uUseLinear` root constant, which picks between the two
/// static samplers.
const int kD3d12SamplerPoint = 0;
const int kD3d12SamplerLinear = 1;

/// How many 32-bit values the root constants occupy.
///
/// Five, and the number is load-bearing twice: it is `Num32BitValues` in the
/// root signature and the count passed to `SetGraphicsRoot32BitConstants`.
/// The cbuffer below packs them into dwords 0..4 - `float2` takes 0 and 1,
/// then three scalars at 2, 3 and 4 - because HLSL only forbids a scalar
/// *straddling* a 16-byte boundary, and none of these does.
const int kD3d12RootConstantCount = 5;

/// Index of the root constants parameter in the root signature.
const int kD3d12RootConstantsSlot = 0;

/// Index of the SRV descriptor table parameter in the root signature.
const int kD3d12RootTextureSlot = 1;

/// The semantic names the input layout declares, in vertex layout order.
///
/// `TEXCOORD` appears twice with different semantic *indices*: 0 for the
/// texture coordinate and 1 for the shape rectangle. That is how Direct3D
/// spells what GLSL spells with two attribute names, and the indices are part
/// of the match - a shape rectangle bound to `TEXCOORD0` would silently become
/// the texture coordinate and every mask would sample the wrong texel.
const List<String> kD3d12SemanticNames = <String>[
  'POSITION',
  'TEXCOORD',
  'COLOR',
  'TEXCOORD',
];

/// Semantic indices matching [kD3d12SemanticNames].
const List<int> kD3d12SemanticIndices = <int>[0, 0, 0, 1];

/// The shared declarations, so the two stages cannot disagree about the
/// interpolants or about which dword of the root constants means what.
const String _shared = '''
cbuffer Constants : register(b0) {
  float2 uViewport;
  uint uMode;
  uint uYFlip;
  uint uUseLinear;
};

struct Varying {
  float4 position  : SV_Position;
  float2 texCoord  : TEXCOORD0;
  float4 color     : COLOR0;
  float4 shapeRect : TEXCOORD1;
  float2 devicePos : TEXCOORD2;
};
''';

/// The vertex stage, entry point `vsMain`, target `vs_5_0`.
const String kD3d12VertexShader = '''
$_shared

struct VertexIn {
  float2 position  : POSITION;
  float2 texCoord  : TEXCOORD0;
  float4 color     : COLOR0;
  float4 shapeRect : TEXCOORD1;
};

Varying vsMain(VertexIn input) {
  Varying output;
  output.texCoord = input.texCoord;
  output.color = input.color;
  output.shapeRect = input.shapeRect;
  output.devicePos = input.position;
  // Device space is y-down with the origin at the top-left corner of the
  // surface; normalised device coordinates are y-up with the origin in the
  // middle. Direct3D's render target is written from the top-left corner, so
  // this single flip is the whole conversion and uYFlip is always 0 - see the
  // library comment of d3d12_shaders.dart for why the branch is kept anyway.
  float ndcY = 1.0 - input.position.y / uViewport.y * 2.0;
  output.position = float4(
      input.position.x / uViewport.x * 2.0 - 1.0,
      uYFlip == 0 ? ndcY : -ndcY,
      0.0,
      1.0);
  return output;
}
''';

/// The pixel stage, entry point `psMain`, target `ps_5_0`.
const String kD3d12PixelShader = '''
$_shared

Texture2D uTexture : register(t0);
SamplerState uPoint : register(s0);
SamplerState uLinear : register(s1);

// Exact area of the pixel square at [p] that lies inside the rectangle [r].
// Separable, which is why an axis-aligned rectangle needs no mask. The same
// arithmetic as raster/coverage.dart on the CPU and as boxCoverage in
// gl_shaders.dart, in that order of authority.
float boxCoverage(float4 r, float2 p) {
  float2 lo = max(r.xy, p - 0.5);
  float2 hi = min(r.zw, p + 0.5);
  float2 overlap = clamp(hi - lo, 0.0, 1.0);
  return overlap.x * overlap.y;
}

float4 psMain(Varying input) : SV_Target {
  // Both samplers, then a select. Shader Model 5.0 cannot index a sampler, and
  // sampling inside the mode branch would put a gradient instruction under
  // flow control - legal here because the condition is uniform across the draw
  // call, but the compiler is entitled to warn and the hoist is what it would
  // do anyway.
  float4 pointTexel = uTexture.Sample(uPoint, input.texCoord);
  float4 linearTexel = uTexture.Sample(uLinear, input.texCoord);
  float4 texel = uUseLinear == 0 ? pointTexel : linearTexel;

  float4 color = input.color;
  if (uMode == 1) {
    // A coverage mask scales the already-premultiplied colour, which is the
    // premultiplied equivalent of mul255(alpha, coverage) on the CPU.
    color *= texel.r;
  } else if (uMode == 2) {
    // Premultiplied texel modulated by the paint's alpha; the colour channels
    // carry that alpha too, so this is a plain scale.
    color = texel * input.color.a;
  }
  return color * boxCoverage(input.shapeRect, input.devicePos);
}
''';

/// Entry point names, passed to `D3DCompile` as ASCII.
const String kD3d12VertexEntryPoint = 'vsMain';
const String kD3d12PixelEntryPoint = 'psMain';

/// Compilation targets.
///
/// Shader Model 5.0 rather than 5.1: 5.1 needs feature level 11_1 for some of
/// its features and buys this renderer nothing, while 5.0 is guaranteed by
/// every device that answers `D3D12CreateDevice` at all.
const String kD3d12VertexTarget = 'vs_5_0';
const String kD3d12PixelTarget = 'ps_5_0';
