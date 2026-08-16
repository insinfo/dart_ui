/// The one HLSL program the Direct3D 11 renderer uses.
///
/// The GLSL counterpart is `gl_shaders.dart` and the two are deliberately the
/// same shader written twice, not two shaders that happen to look alike: one
/// program, three modes selected by a constant, the same interleaved vertex
/// layout from `gpu_pipeline.dart`, and the same analytic `boxCoverage` term.
/// Every argument in that file for why it is shaped this way applies here and
/// is not repeated. What *is* written down here is everything the two APIs
/// disagree about, because those are the places a port goes silently wrong.
///
/// ## Disagreement 1: where a rendered image's row 0 is
///
/// **OpenGL's framebuffer origin is the bottom-left corner. Direct3D's is the
/// top-left.** That single difference removes an entire uniform.
///
/// `gl_shaders.dart` carries `uYFlip` because GL stores a rendered texture
/// upside down relative to every texture this renderer *uploads*, so a pass
/// that renders into a texture something else will sample has to invert its
/// projection - and invert its scissor's y with it. In D3D11 a render target's
/// row 0 is the top row, which is already the convention
/// `gpu_layer_stack.dart` declares for a layer's colour texture ("a layer's
/// colour texture is **top-down**"). So:
///
///   * the projection below is unconditional - device y down maps to clip y up
///     exactly once, the same expression GL uses for `kYFlipDefault`;
///   * [D3d11RenderDevice.submit] ignores `GpuRenderPass.rendersTopDown`,
///     because every pass already renders top-down;
///   * a scissor rectangle is used as it comes, with no `height - bottom`;
///   * readback needs no row flip, unlike `GlRenderDevice._readPixels`.
///
/// Four places, one cause. Getting any of them wrong draws a correct picture
/// upside down, which reads as a bug in the scene rather than in the backend.
///
/// ## Disagreement 2: matrix packing
///
/// HLSL packs a `matrix` in a constant buffer **column-major by default**;
/// `Transform2D` in this framework stores its coefficients row-major, and GLSL
/// `mat` types are column-major too but are *indexed* differently, so the two
/// languages disagree twice over and cancel out only by accident.
///
/// This shader contains no matrix at all - the projection is two divides
/// against a `float2` viewport, exactly as in GLSL - so today the question is
/// moot. It is declared anyway, and enforced: the compile flags in
/// `d3d11_backend.dart` include [d3dCompilePackMatrixRowMajor], so the day
/// somebody adds a `float3x3` for a general transform it will be packed the
/// way `Transform2D` already stores one. The alternative - leaving the default
/// and remembering to transpose - is a rule that lives in a comment and is
/// broken by the second person to touch the file.
///
/// ## Disagreement 3: texture sampling syntax, not semantics
///
/// GLSL's `texture(sampler2D, uv)` becomes `Texture2D.Sample(SamplerState,
/// uv)`: in D3D11 the texture and the sampler are separate objects bound to
/// separate slots. The renderer therefore keeps two immutable sampler states
/// (point and linear) and picks one per batch from the filter the texture was
/// created with, where GL sets the filter on the texture object itself. The
/// *result* is identical, and it has to be: the mask and glyph atlases are
/// sampled one texel per pixel with point filtering precisely so the GPU
/// reproduces the CPU rasteriser's coverage byte, and a linear tap there is
/// the soft, muddy text a bitmap cache gets blamed for.
///
/// Texture *coordinates* need no adjustment. Both APIs put `v = 0` at the
/// first row of the memory that was uploaded, so a top-down staging image
/// becomes a top-down texture in both.
///
/// ## The pixel centre, which is the same and was not always
///
/// `boxCoverage` evaluates the exact area of the pixel square that the shape
/// rectangle covers, and it is only the right answer if the interpolated
/// device position arrives at the *centre* of the pixel. Direct3D 10 and later
/// place the pixel centre at (x + 0.5, y + 0.5), the same as OpenGL. Direct3D 9
/// did not, and the half-texel offset it needed is the single most copied
/// workaround in D3D sample code; it is wrong here and is not applied.
library;

/// Values of the `mode` constant. Must match [GpuPipelineKind]'s order and the
/// GLSL constants of the same name.
const int kD3dModeSolid = 0;
const int kD3dModeCoverageMask = 1;
const int kD3dModeTexturedImage = 2;

/// The vertex shader entry point, in the profile the device is created for.
const String kD3d11VertexEntryPoint = 'vertexMain';
const String kD3d11PixelEntryPoint = 'pixelMain';

/// `vs_4_0` / `ps_4_0` is feature level 10.0, which is the floor
/// `kD3d11FeatureLevels` declares. Compiling for `vs_5_0` would refuse to run
/// on a 10.x device for no gain: this shader uses nothing above Shader Model 4.
const String kD3d11VertexProfile = 'vs_4_0';
const String kD3d11PixelProfile = 'ps_4_0';

/// The semantic names the input layout binds, and the order the interleaved
/// vertex of `gpu_pipeline.dart` lays them out in.
///
/// `TEXCOORD1` carries the shape rectangle rather than a semantic of its own
/// because HLSL has no `SHAPERECT` semantic and inventing one is not possible:
/// the set is fixed by the language. Anything not consumed by a fixed-function
/// stage travels as a numbered `TEXCOORD`, which is the standard idiom and
/// costs nothing.
const List<String> kD3d11SemanticNames = <String>[
  'POSITION',
  'TEXCOORD',
  'COLOR',
  'TEXCOORD',
];

/// Semantic *indices*, paired with [kD3d11SemanticNames] element by element.
const List<int> kD3d11SemanticIndices = <int>[0, 0, 0, 1];

/// One source string holding both entry points.
///
/// Both in one string, compiled twice with different entry points, because the
/// vertex output structure is shared: two files would let the vertex shader's
/// outputs and the pixel shader's inputs drift apart, and the compiler would
/// not complain - it would silently match by semantic and leave the mismatched
/// field reading whatever was in the register.
const String kD3d11ShaderSource = '''
cbuffer FrameConstants : register(b0) {
  float2 viewport;
  uint mode;
  uint padding;
};

struct VertexInput {
  float2 position  : POSITION0;
  float2 texCoord  : TEXCOORD0;
  float4 color     : COLOR0;
  float4 shapeRect : TEXCOORD1;
};

struct VertexOutput {
  float4 clipPosition : SV_Position;
  float2 texCoord     : TEXCOORD0;
  float4 color        : COLOR0;
  float4 shapeRect    : TEXCOORD1;
  float2 devicePos    : TEXCOORD2;
};

VertexOutput vertexMain(VertexInput input) {
  VertexOutput output;
  output.texCoord = input.texCoord;
  output.color = input.color;
  output.shapeRect = input.shapeRect;
  output.devicePos = input.position;
  // Device space is y-down with the origin at the top-left corner of the
  // surface; clip space is y-up with the origin in the middle. The flip lives
  // here, once. Unlike the GLSL twin there is no second, conditional flip:
  // Direct3D already stores a rendered target top-down, which is the
  // orientation every texture this renderer samples is in.
  output.clipPosition = float4(
      input.position.x / viewport.x * 2.0 - 1.0,
      1.0 - input.position.y / viewport.y * 2.0,
      0.0,
      1.0);
  return output;
}

Texture2D<float4> sourceTexture : register(t0);
SamplerState sourceSampler : register(s0);

// Exact area of the pixel square at [p] that lies inside the rectangle [r].
// Separable, which is why an axis-aligned rectangle needs no mask.
float boxCoverage(float4 r, float2 p) {
  float2 lo = max(r.xy, p - 0.5);
  float2 hi = min(r.zw, p + 0.5);
  float2 overlap = clamp(hi - lo, 0.0, 1.0);
  return overlap.x * overlap.y;
}

float4 pixelMain(VertexOutput input) : SV_Target {
  float4 color = input.color;
  if (mode == 1) {
    // A coverage mask scales the already-premultiplied colour, which is the
    // premultiplied equivalent of mul255(alpha, coverage) on the CPU. The
    // mask is an R8_UNORM texture, so the coverage is in .r exactly as the
    // GLSL twin reads it out of a GL_R8.
    color *= sourceTexture.Sample(sourceSampler, input.texCoord).r;
  } else if (mode == 2) {
    // Premultiplied texel modulated by the paint's alpha; the colour channels
    // carry that alpha too, so this is a plain scale.
    color = sourceTexture.Sample(sourceSampler, input.texCoord) * input.color.a;
  }
  return color * boxCoverage(input.shapeRect, input.devicePos);
}
''';
