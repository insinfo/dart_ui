/// The HLSL the Direct3D 11 mesh pipeline compiles: one vertex stage, one
/// pixel stage, and the CPU rasteriser's shading transcribed line for line.
///
/// `d3d11_shaders.dart` is the model and its four "disagreements" between
/// OpenGL and Direct3D apply here unchanged. What this file adds are the three
/// disagreements between a **software** rasteriser and a hardware one, because
/// those are what a parity test against `mesh_rasterizer.dart` fails on.
///
/// ## Disagreement A: the depth range
///
/// `Matrix4.perspective` in `graphics/mesh/mesh3d.dart` is OpenGL's: it maps
/// the view frustum's depth into `[-1, 1]`, which is what `MeshRasterizer`
/// writes into its own depth buffer. **Direct3D clips to `0 <= z <= w`.** The
/// same matrix handed to this pipeline unchanged would put every fragment in
/// front of the frustum's midpoint at a negative `z` and the hardware would
/// throw it away - the model loses its whole near half and the far half stays,
/// which looks like a broken near plane rather than like a convention.
///
/// The remap is one line in the vertex stage, `z' = (z + w) * 0.5`, and it is
/// there rather than folded into the matrix on the Dart side on purpose: the
/// camera arithmetic is shared with the CPU path, and a projection matrix that
/// differed between the two would make every parity failure ambiguous. The
/// remap is monotonic in `z/w`, so `LESS` on the remapped value orders
/// fragments exactly as `<` on the CPU's `[-1, 1]` value does, and the plane it
/// clips at - `z' = 0`, that is `z/w = -1`, that is `w = near` - is the same
/// plane `MeshRasterizer` clips its polygons against.
///
/// ## Disagreement B: which varyings are perspective-correct
///
/// HLSL interpolates every varying perspective-correctly unless told
/// otherwise. `MeshRasterizer` does not: it reads its comment #5 and
/// interpolates texture coordinates with `u/w` and `1/w` while leaving the
/// **normal affine**, on the argument that a shading gradient a fraction of a
/// percent off is invisible where a sliding checkerboard is not.
///
/// So the normal is declared `noperspective` and the texture coordinate is
/// not. Getting that backwards is not a crash and not a wrong colour; it is a
/// smooth-shaded model whose highlights sit a few pixels away from where the
/// CPU puts them, on the triangles seen most obliquely - a difference a golden
/// test measures as a handful of levels on a few hundred pixels and a human
/// cannot see at all.
///
/// ## Disagreement C: where the rounding happens
///
/// The CPU works in 8-bit channels throughout: `_mul` folds a texel into the
/// base colour as `(a * b + 127) / 255` on integers, and `_shade` finishes with
/// `(value * intensity).round()` on an integer channel. A pixel shader works in
/// floats and hands the render target a `[0, 1]` value that the hardware
/// quantises.
///
/// This shader therefore does its arithmetic in **0..255 float space** and
/// divides by 255 exactly once, at the return. Every intermediate is an exact
/// integer held in a float - a float32 mantissa is 24 bits and the largest
/// product here is 255 x 255 = 65025 - so `floor` and `round` land on the same
/// integers Dart's do, and `k / 255.0` is the exact value a `UNORM8` target
/// stores back as `k`. The alternative, working in `[0, 1]` and letting the
/// output stage round once, is off by one level wherever an integer division
/// truncates on one side and a float rounds on the other, which on a textured
/// model is most of it.
library;

/// The entry points, one source string holding both.
///
/// Both in one string for the reason `kD3d11ShaderSource` gives: the vertex
/// output structure is shared, and two files would let the stages' fields drift
/// apart with the compiler silently matching by semantic.
const String kD3d11MeshVertexEntryPoint = 'meshVertexMain';
const String kD3d11MeshPixelEntryPoint = 'meshPixelMain';

/// `vs_4_0` / `ps_4_0`: feature level 10.0, the floor `kD3d11FeatureLevels`
/// declares. Nothing below uses anything above Shader Model 4 - `SV_IsFrontFace`
/// and `noperspective` are both 4.0 - so compiling for 5.0 would refuse to run
/// on a 10.x device for no gain.
const String kD3d11MeshVertexProfile = 'vs_4_0';
const String kD3d11MeshPixelProfile = 'ps_4_0';

/// Semantic names and indices of the mesh vertex, paired element by element.
///
/// `NORMAL` is a real HLSL semantic, unlike the shape rectangle of the 2D
/// program which had to travel as a numbered `TEXCOORD`.
const List<String> kD3d11MeshSemanticNames = <String>[
  'POSITION',
  'NORMAL',
  'TEXCOORD',
];
const List<int> kD3d11MeshSemanticIndices = <int>[0, 0, 0];

/// Bytes of one vertex: `float3` position, `float3` normal, `float2` uv.
///
/// Thirty-two, which is a happy accident rather than padding: the input
/// assembler has no alignment requirement past four bytes, and a stride that
/// happens to be a power of two is what a cache line wants.
const int kD3d11MeshVertexStrideBytes = 32;

/// Byte offsets of the three attributes inside one vertex.
const int kD3d11MeshPositionOffset = 0;
const int kD3d11MeshNormalOffset = 12;
const int kD3d11MeshTexCoordOffset = 24;

/// Floats in the constant buffer: ten `float4` registers.
///
/// A `float4x4` occupies four, the 3x3 normal matrix occupies three because
/// HLSL will not straddle a register boundary with a `float3` row, and the
/// light, the base colour and the options take one each. The padding is named
/// in the declaration rather than left implicit so the Dart side can write the
/// whole file as forty consecutive floats.
const int kD3d11MeshConstantFloats = 40;
const int kD3d11MeshConstantBytes = kD3d11MeshConstantFloats * 4;

/// The mesh program.
///
/// Read `_shade` and `_drawProjected` in
/// `lib/src/rendering/mesh/mesh_rasterizer.dart` beside it: `shadeSurface`
/// below is that function transcribed, including the reversed normal for a back
/// face that survived culling, and any edit to one that is not made to the
/// other is a parity failure by construction.
const String kD3d11MeshShaderSource = '''
cbuffer MeshConstants : register(b0) {
  // Rows of the model-view-projection, in the order row-major packing puts
  // them. The Dart side transposes: Matrix4 stores column-major, like glTF.
  float4x4 modelViewProjection;
  // Rows of the normal matrix, xyz used and w padding. Today the Dart side
  // always writes the identity, because `MeshRasterizer` shades against
  // model-space normals and a model-space light and there is no model matrix
  // in the scene at all. It is a uniform rather than a constant so that adding
  // one later is a change on the Dart side only.
  float4 normalMatrix0;
  float4 normalMatrix1;
  float4 normalMatrix2;
  // xyz: the direction light travels in, already normalised. w: the ambient
  // level, which is `MeshRasterizer.render`'s `ambient` argument.
  float4 lightDirection;
  // rgb in **0..255**, not 0..1. See "Disagreement C" in the library comment:
  // the whole shader works in the CPU's channel space and divides once.
  float4 baseColor;
  // x: 1 when the surface is lit, 0 for MeshShading.unlit and .wireframe.
  // y: 1 when a base-colour texture is bound at t0.
  float4 meshOptions;
};

Texture2D<float4> baseColorTexture : register(t0);
SamplerState baseColorSampler : register(s0);

struct MeshVertexInput {
  float3 position : POSITION0;
  float3 normal   : NORMAL0;
  float2 texCoord : TEXCOORD0;
};

struct MeshVertexOutput {
  float4 clipPosition : SV_Position;
  // Affine, and that is not an oversight: see "Disagreement B".
  noperspective float3 normal : NORMAL0;
  float2 texCoord : TEXCOORD0;
};

MeshVertexOutput meshVertexMain(MeshVertexInput input) {
  MeshVertexOutput output;
  float4 clip = mul(modelViewProjection, float4(input.position, 1.0));
  // The depth remap of "Disagreement A". x, y and w are untouched, so the
  // perspective divide, the viewport transform and the near-plane clip all land
  // exactly where the CPU's do.
  output.clipPosition = float4(clip.x, clip.y, (clip.z + clip.w) * 0.5, clip.w);
  output.normal = float3(
      dot(normalMatrix0.xyz, input.normal),
      dot(normalMatrix1.xyz, input.normal),
      dot(normalMatrix2.xyz, input.normal));
  output.texCoord = input.texCoord;
  return output;
}

// One channel of a texel times one channel of the factor, both 0..255.
//
// `MeshRasterizer._mul`, transcribed: `(a * b + 127) ~/ 255` and not `>> 8`,
// because the shift is a divide by 256 and leaves white times white at 254 -
// every fully lit textured surface one level dark, and a visible seam where a
// textured mesh meets an untextured one.
//
// The epsilon is what makes the integer divide exact in floats. `product + 127`
// is an integer up to 65152 held exactly; dividing by 255 is not exact, and
// where the true quotient is a whole number the result can land a few ulps
// below it, which `floor` would then take down a whole level. Consecutive
// quotients here differ by 1/255, about 3.9e-3, so 1e-4 is far inside the gap
// and far outside the error.
float modulate(float texel, float factor) {
  float product = round(texel * 255.0) * factor;
  return floor((product + 127.0) * (1.0 / 255.0) + 1e-4);
}

// Lambert plus a rim term, in 0..255 channel space.
//
// `MeshRasterizer._shade`, transcribed. A back face that survived culling - a
// double-sided material - is lit with its normal reversed; without that the
// inside of an open shell is black and looks like a hole.
float3 shadeSurface(float3 surface, float3 normal, bool backFacing) {
  float3 n = backFacing ? -normal : normal;
  float lambert = max(0.0, -dot(n, lightDirection.xyz));
  // A second, dimmer light from the opposite side. One light leaves half of
  // every model in flat ambient, where its shape cannot be read at all.
  float fill = max(0.0, dot(n, lightDirection.xyz)) * 0.25;
  float intensity =
      clamp(lightDirection.w + lambert * 0.85 + fill, 0.0, 1.2);
  // `floor(x + 0.5)` and not `round(x)`: HLSL's `round` is round-half-to-even
  // and Dart's `double.round()` is round-half-away-from-zero. Every value here
  // is non-negative, so away-from-zero is up, and this is that. On a tie the
  // two differ by one level, which is exactly the kind of difference a parity
  // test is built to notice and a reader is not.
  return min(floor(surface * intensity + 0.5), 255.0);
}

float4 meshPixelMain(
    MeshVertexOutput input,
    bool isFrontFace : SV_IsFrontFace) : SV_Target {
  float3 surface = baseColor.rgb;
  if (meshOptions.y >= 0.5) {
    float4 texel = baseColorTexture.Sample(baseColorSampler, input.texCoord);
    // Multiplied by the factor rather than replacing it, which is what glTF
    // specifies: a white factor samples the texture unchanged and a tinted one
    // tints it.
    surface = float3(
        modulate(texel.r, baseColor.r),
        modulate(texel.g, baseColor.g),
        modulate(texel.b, baseColor.b));
  }
  if (meshOptions.x >= 0.5) {
    // `backFacing` is the CPU's, and the rasteriser state is what makes the
    // two agree: `FrontCounterClockwise` is TRUE, so the hardware calls a
    // triangle front-facing exactly when `MeshRasterizer._drawProjected`
    // computes a negative signed area for it. See the rasteriser state in
    // `d3d11_mesh_pipeline.dart` for the whole argument, and for why getting it
    // backwards leaves a model looking hollow.
    surface = shadeSurface(surface, normalize(input.normal), !isFrontFace);
  }
  // Opaque, and premultiplying is therefore the identity. The one divide by
  // 255 the whole program does.
  return float4(surface * (1.0 / 255.0), 1.0);
}
''';
