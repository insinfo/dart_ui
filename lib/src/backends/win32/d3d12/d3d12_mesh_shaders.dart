/// The HLSL the Direct3D 12 mesh pipeline compiles, and the two things that
/// make it a different file from the Direct3D 11 one rather than an import.
///
/// `lib/src/rendering/gpu/d3d11/d3d11_mesh_shaders.dart` is the authority for
/// every line of shading below and its three "disagreements" between a software
/// rasteriser and a hardware one - the depth range, which varyings are
/// perspective-correct, and where the rounding happens - apply here word for
/// word. They are not restated. `d3d12_shaders.dart` states the same rule for
/// the 2D program: the two Direct3D files and the GL one are kept parallel
/// deliberately, because that is what makes a parity failure a bug in one
/// backend rather than a difference of intent between two shader authors.
///
/// What is *not* shared, and why this is a copy:
///
///   1. **`row_major`, spelled out.** HLSL packs a constant-buffer matrix
///      column-major by default. The Direct3D 11 pipeline compiles with
///      `D3DCOMPILE_PACK_MATRIX_ROW_MAJOR`, so its source can stay silent;
///      `D3d12RenderDevice._compile` passes **flag 0** on purpose - see its
///      comment about a driver-specific warning refusing to start a renderer -
///      and a matrix uploaded in row order into a column-major cbuffer is the
///      transpose of the intended view-projection, which is not a recognisable
///      transform at all: the model is simply not on screen. The declaration
///      below is the fix, and `d3d12_shaders.dart`'s library comment is the
///      place that already said this is how a matrix must cross into this
///      backend.
///   2. **The constants are root constants, not a buffer.** Forty dwords in
///      the root signature and one `SetGraphicsRoot32BitConstants` per
///      primitive, where Direct3D 11 has an `ID3D11Buffer` and an
///      `UpdateSubresource`. The cbuffer declaration is identical either way -
///      root constants *are* a `b0` cbuffer to the shader - so the difference
///      is entirely on the Dart side, and it is recorded here because the
///      forty is load-bearing in three places at once.
///
/// A shading edit made to one of the two files and not the other is a parity
/// failure by construction, and
/// `test/backends/win32/d3d12/d3d12_mesh_cpu_parity_test.dart` is what turns
/// that from a promise into a measurement.
library;

/// The entry points, one source string holding both.
const String kD3d12MeshVertexEntryPoint = 'meshVertexMain';
const String kD3d12MeshPixelEntryPoint = 'meshPixelMain';

/// `vs_5_0` / `ps_5_0`, matching `kD3d12VertexTarget`.
///
/// Shader Model 5.0 rather than the 4.0 the Direct3D 11 mesh program uses:
/// every device that answers `D3D12CreateDevice` at all guarantees 5.0, so
/// there is no feature level to protect here, and the 2D program next door is
/// already compiled at 5.0. Nothing below needs anything above 4.0.
const String kD3d12MeshVertexTarget = 'vs_5_0';
const String kD3d12MeshPixelTarget = 'ps_5_0';

/// Semantic names and indices of the mesh vertex, paired element by element.
const List<String> kD3d12MeshSemanticNames = <String>[
  'POSITION',
  'NORMAL',
  'TEXCOORD',
];
const List<int> kD3d12MeshSemanticIndices = <int>[0, 0, 0];

/// Bytes of one vertex: `float3` position, `float3` normal, `float2` uv.
const int kD3d12MeshVertexStrideBytes = 32;

/// Byte offsets of the three attributes inside one vertex.
const int kD3d12MeshPositionOffset = 0;
const int kD3d12MeshNormalOffset = 12;
const int kD3d12MeshTexCoordOffset = 24;

/// How many 32-bit values the mesh root constants occupy.
///
/// Forty, and the number is load-bearing three times: it is `Num32BitValues`
/// in the root signature, the count passed to
/// `SetGraphicsRoot32BitConstants`, and the length of the float block the Dart
/// side fills. It is also the whole reason this backend needs no constant
/// buffer, no upload block and no per-frame `Map`: a root signature may hold 64
/// dwords, forty of them are these and one more is the texture table, so the
/// constants travel in the command list itself.
const int kD3d12MeshRootConstantCount = 40;

/// Index of the root-constants parameter in the mesh root signature.
const int kD3d12MeshRootConstantsSlot = 0;

/// Index of the SRV descriptor table parameter in the mesh root signature.
const int kD3d12MeshRootTextureSlot = 1;

/// The mesh program.
///
/// Read `_shade` and `_drawProjected` in
/// `lib/src/rendering/mesh/mesh_rasterizer.dart` beside it: `shadeSurface`
/// below is that function transcribed, including the reversed normal for a back
/// face that survived culling.
const String kD3d12MeshShaderSource = '''
cbuffer MeshConstants : register(b0) {
  // `row_major` is not decoration. See the library comment: this backend
  // compiles with no matrix-packing flag, so without it the Dart side's row
  // order lands in a column-major cbuffer and the model leaves the screen.
  row_major float4x4 modelViewProjection;
  // Rows of the normal matrix, xyz used and w padding. Today the Dart side
  // always writes the identity, because `MeshRasterizer` shades against
  // model-space normals and a model-space light and there is no model matrix
  // in the scene at all.
  float4 normalMatrix0;
  float4 normalMatrix1;
  float4 normalMatrix2;
  // xyz: the direction light travels in, already normalised. w: the ambient
  // level, which is `MeshRasterizer.render`'s `ambient` argument.
  float4 lightDirection;
  // rgb in **0..255**, not 0..1. See "Disagreement C" in the Direct3D 11
  // shader's library comment: the whole shader works in the CPU's channel
  // space and divides once.
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
  // Affine, and that is not an oversight: `MeshRasterizer` interpolates the
  // normal affinely and the texture coordinate perspective-correctly, and this
  // pipeline copies that whether or not it agrees.
  noperspective float3 normal : NORMAL0;
  float2 texCoord : TEXCOORD0;
};

MeshVertexOutput meshVertexMain(MeshVertexInput input) {
  MeshVertexOutput output;
  float4 clip = mul(modelViewProjection, float4(input.position, 1.0));
  // Direct3D 12 clips to `0 <= z <= w` exactly as Direct3D 11 does, and
  // `Matrix4.perspective` is OpenGL's `[-1, 1]`. Without this remap every
  // fragment in front of the frustum's midpoint is thrown away and the model
  // loses its near half.
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
// `MeshRasterizer._mul`, transcribed: `(a * b + 127) ~/ 255` and not `>> 8`.
// The epsilon is what makes the integer divide exact in floats - a true
// quotient that is a whole number can land a few ulps below it, and `floor`
// would then take it down a whole level.
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
  // is non-negative, so away-from-zero is up, and this is that.
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
    // computes a negative signed area for it.
    surface = shadeSurface(surface, normalize(input.normal), !isFrontFace);
  }
  // Opaque, and premultiplying is therefore the identity. The one divide by
  // 255 the whole program does.
  return float4(surface * (1.0 / 255.0), 1.0);
}
''';
