/// The one HLSL program the Direct3D 11 renderer uses.
///
/// The GLSL counterpart is `gl_shaders.dart` and the two are deliberately the
/// same shader written twice, not two shaders that happen to look alike: one
/// program, three modes selected by a constant, the same interleaved vertex
/// layout from `gpu_pipeline.dart`, and the same two analytic coverage terms -
/// `boxCoverage` for a rectangle and `roundedCoverage` for the closed-form
/// rounded rectangle, which a solid quad selects from a shape code it carries
/// in the texture coordinate the solid pipeline never samples. Every argument
/// in that file for why it is shaped this way applies here and is not
/// repeated. What *is* written down here is everything the two APIs disagree
/// about, because those are the places a port goes silently wrong.
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

/// What the second texture-coordinate float means in [kD3dModeSolid].
///
/// The whole argument for the encoding lives in `gl_shaders.dart` under
/// `kAnalyticNone` and is not repeated: the shared vertex of
/// `gpu_pipeline.dart` has exactly two floats a solid fill does not already
/// use, they are `TEXCOORD0`, and they hold `(radius, kind)` - enough for the
/// uniform-radius rounded rectangle a user interface actually draws, and not
/// enough for per-corner radii or an oriented kind, which `GpuRasterSink`
/// refuses by name before the vertex is written.
///
/// What matters *here* is that these are the same integers as the GLSL twin's
/// and are checked against `AnalyticPrimitiveKind.shaderCode` in the test
/// suite. The three of them cross an API boundary a compiler cannot see
/// across: `gpu_raster_sink.dart` writes the code as a float on a vertex and
/// this pixel shader compares it against a literal, so a renumbering that
/// touched only one side would not fail to build - it would draw a plain
/// rectangle where a rounded one was asked for, on this backend only.
const int kD3dAnalyticNone = 0;

/// A rounded rectangle: `shapeRect` is its box and `texCoord.x` its radius.
///
/// Zero is [kD3dAnalyticNone] on purpose, twice over. It is what every other
/// path in this renderer already leaves in `TEXCOORD0` for a solid quad, so
/// nothing that existed before this constant had to change to keep drawing
/// exactly as it did; and radius zero is genuinely not this shape - the
/// distance field says a pixel centred on a square corner is half covered
/// where the true area is a quarter, so the sink redirects a zero radius to
/// the plain rectangle path rather than encoding it here.
const int kD3dAnalyticRoundedRect = 1;

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

// Coverage of the pixel at [p] by the rectangle [r] with corner radius [rad].
//
// The body is AnalyticPrimitive.fieldAt for AnalyticPrimitiveKind.rounded with
// all four radii equal, transcribed: fold the pixel into the first quadrant,
// pull the box in by the radius, and read the distance to that inset box's
// boundary. It is signed, in device pixels, and exact. The coverage is then
// 0.5 - d, exact wherever the boundary crossing the pixel is straight - the
// four edges, which is most of the outline - and an approximation on the
// corner arcs, where the true area of a circular segment differs from the
// half-plane one by O(1/rad).
//
// Line for line the same function as `roundedCoverage` in `gl_shaders.dart`,
// and it has to be: the two backends draw the same display list and a golden
// held against both would hide a divergence here. HLSL and GLSL agree on every
// operation it uses - `abs`, `min`, `max`, `length`, `clamp`, componentwise
// arithmetic on a float2 - so the transcription is mechanical, with one real
// difference: GLSL's `vec2`/`vec4` are `float2`/`float4`. The local is still
// not named `half`, because HLSL has a `half` *type* where GLSL merely
// reserves the word, and shadowing it is a compile error that would take the
// whole renderer down at device creation rather than at the draw.
//
// No ddx: everything on this path is already in device pixels, because
// GpuRasterSink recognises the rounded rectangle after the player has applied
// the transform. A shape that arrived in some other space would need the
// gradient of the field to normalise the distance, and is refused instead.
float roundedCoverage(float4 r, float rad, float2 p) {
  float2 centre = (r.xy + r.zw) * 0.5;
  float2 extent = (r.zw - r.xy) * 0.5;
  float2 q = abs(p - centre) - extent + rad;
  float d = min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - rad;
  return clamp(0.5 - d, 0.0, 1.0);
}

float4 pixelMain(VertexOutput input) : SV_Target {
  float4 color = input.color;
  float coverage;
  if (mode == 1) {
    // A coverage mask scales the already-premultiplied colour, which is the
    // premultiplied equivalent of mul255(alpha, coverage) on the CPU. The
    // mask is an R8_UNORM texture, so the coverage is in .r exactly as the
    // GLSL twin reads it out of a GL_R8.
    color *= sourceTexture.Sample(sourceSampler, input.texCoord).r;
    coverage = boxCoverage(input.shapeRect, input.devicePos);
  } else if (mode == 2) {
    // Premultiplied texel modulated by the paint's alpha; the colour channels
    // carry that alpha too, so this is a plain scale.
    color = sourceTexture.Sample(sourceSampler, input.texCoord) * input.color.a;
    coverage = boxCoverage(input.shapeRect, input.devicePos);
  } else if (input.texCoord.y >= 0.5) {
    // kD3dAnalyticRoundedRect. A threshold rather than an equality, and that
    // is not defensiveness: the value is a vertex attribute, so it is
    // *interpolated*, and although the sink writes the identical float on all
    // four corners a driver is entitled to reconstruct 1.0 as 0.99999994 at
    // the pixel centre. An `== 1.0` test would then fall through to
    // boxCoverage and draw a hard-cornered rectangle where a rounded one was
    // asked for - on some hardware only, which is the worst way to be wrong.
    // The threshold also keeps kD3dAnalyticNone decoding as "no primitive" for
    // every quad this renderer has ever written, since those carry exact zero.
    coverage =
        roundedCoverage(input.shapeRect, input.texCoord.x, input.devicePos);
  } else {
    coverage = boxCoverage(input.shapeRect, input.devicePos);
  }
  return color * coverage;
}
''';

// ---------------------------------------------------------------------------
// The opt-in vector program: approaches B and C
// ---------------------------------------------------------------------------

/// One HLSL program for the tessellated mesh (B) and the stencil cover (C).
///
/// The two routes are usually written as two programs because OpenGL's are -
/// `gl_tessellated_executor.dart` carries a transform in its vertex shader and
/// `gl_stencil_cover_executor.dart` does not. That difference is not real: both
/// consume a position-only vertex and both write one premultiplied constant
/// colour, and the only thing C would leave unused is a matrix it can set to
/// the identity. So this is one program, one input layout and one constant
/// buffer, and the cost of the merge is two dot products per stencil vertex.
///
/// Merging them is worth more here than it would be on GL. Every D3D11
/// pipeline object is a COM object created from a descriptor at device
/// creation and released with the device, and a second program would mean a
/// second compile, a second `CreateInputLayout` against a second bytecode blob,
/// and a second object to rebuild after a device loss - all for a vertex shader
/// that differs by a multiply the identity makes free.
///
/// **No `boxCoverage`, and that is the whole trade these routes make.** The
/// dense program in [kD3d11ShaderSource] multiplies every fragment by the exact
/// area of the pixel square inside the shape rectangle, which is where this
/// renderer's antialiasing comes from on every other path. A mesh and a cover
/// quad have no such closed form, so their coverage is whatever the hardware's
/// sample mask gives: exact in the interior, quantised at the edge. See
/// `doc/RELATORIO_POC_23_GPU_2D_STRATEGIES_INTEL_UHD.md`.
const String kD3d11VectorShaderSource = '''
cbuffer VectorConstants : register(b0) {
  float2 viewport;
  float2 vectorPadding;
  // Rows of the 2x3 local-to-target affine, in the order Transform2D stores
  // them: (a, c, tx) and (b, d, ty). Approach C leaves these the identity
  // because `StencilCoverDrawPlan` has already flattened its geometry into
  // target space; approach B keeps the mesh in local coordinates so one
  // retained vertex buffer survives a subtree that only moves.
  float4 localToTarget0;
  float4 localToTarget1;
  float4 vectorColor;
};

struct VectorVertexInput {
  float2 position : POSITION0;
};

struct VectorVertexOutput {
  float4 clipPosition : SV_Position;
};

VectorVertexOutput vectorVertexMain(VectorVertexInput input) {
  VectorVertexOutput output;
  float3 local = float3(input.position, 1.0);
  float2 target = float2(
      dot(localToTarget0.xyz, local),
      dot(localToTarget1.xyz, local));
  // The same unconditional flip the dense program uses, and for the same
  // reason: device space is y-down from the top-left, clip space is y-up from
  // the middle, and D3D11 needs no second conditional flip because a rendered
  // target is already stored top-down. See "Disagreement 1" above.
  output.clipPosition = float4(
      target.x / viewport.x * 2.0 - 1.0,
      1.0 - target.y / viewport.y * 2.0,
      0.0,
      1.0);
  return output;
}

float4 vectorPixelMain(VectorVertexOutput input) : SV_Target {
  return vectorColor;
}
''';

const String kD3d11VectorVertexEntryPoint = 'vectorVertexMain';
const String kD3d11VectorPixelEntryPoint = 'vectorPixelMain';

/// Bytes of [kD3d11VectorShaderSource]'s constant buffer.
///
/// Four `float4` registers. A constant buffer's `ByteWidth` must be a multiple
/// of 16 and HLSL will not straddle a register boundary with a `float4`, so
/// this is exactly what the declaration above occupies - the padding after
/// `viewport` is named in the source rather than left implicit so that the Dart
/// side can write the four registers as sixteen consecutive floats.
const int kD3d11VectorConstantBytes = 64;
