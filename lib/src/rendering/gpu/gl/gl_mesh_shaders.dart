/// The one shader program the GPU mesh pipeline uses.
///
/// The fragment body is a transcription of `MeshRasterizer._shade` in
/// `lib/src/rendering/mesh/mesh_rasterizer.dart`, and it is a transcription
/// rather than a reimplementation on purpose: the CPU rasteriser is the
/// reference picture this pipeline is measured against, so any liberty taken
/// here - a different fill weight, a normalise in a different place, a
/// gamma-correct light - shows up as a parity failure with no bug behind it.
/// The two files have to be changed together, and
/// `test/rendering/gpu/gl/gl_mesh_pipeline_test.dart` fails when they are not.
///
/// ## What is deliberately *not* here
///
/// **No gamma.** The CPU multiplies 8-bit channel values by an intensity and
/// rounds; it never converts to linear light. Doing it properly in the shader
/// would produce a better picture and a worse comparison, and the comparison
/// is what this stage is buying. Whoever decides this renderer should be
/// linear has to move both files at once.
///
/// **No specular, no second texture, no metallic-roughness.** `MeshMaterial`
/// carries `metallic` and `roughness` and neither rasteriser reads them;
/// `Mesh3D.unsupported` is where that is recorded for the user. A shader that
/// quietly used them would make the GPU and CPU paths draw different pictures
/// from the same model, which is the failure this whole exercise exists to
/// rule out.
///
/// ## Two dialects
///
/// GLSL 330 core for a desktop context, GLSL ES 300 for an ES one, exactly as
/// `gl_shaders.dart` does it and for the same reason: the body is shared so a
/// fix cannot land in one dialect and not the other.
library;

/// Attribute locations, bound before linking.
///
/// Explicit binding rather than `layout(location=)` for the reason
/// `gl_shaders.dart` gives - ES 100 has no such qualifier and the door is
/// kept open - and because the three locations are then a fact this file and
/// the vertex-array setup agree on by construction.
const int kMeshAttributePosition = 0;
const int kMeshAttributeNormal = 1;
const int kMeshAttributeTexCoord = 2;

const List<String> kMeshAttributeNames = <String>[
  'aPosition',
  'aNormal',
  'aTexCoord',
];

/// Values of the `uLit` uniform.
///
/// Two and not four: [MeshShading.flat] and [MeshShading.smooth] differ in
/// *which normals the vertex buffer carries*, not in what the fragment stage
/// does with them, and [MeshShading.wireframe] is a different primitive type
/// rather than a different shader. Encoding all four here would have created
/// three branches that are never taken and one that is taken for two
/// different reasons.
const int kMeshShadeUnlit = 0;
const int kMeshShadeLit = 1;

/// Floats per vertex in the interleaved mesh buffer: position, normal, uv.
const int kMeshFloatsPerVertex = 8;
const int kMeshPositionOffset = 0;
const int kMeshNormalOffset = 3;
const int kMeshTexCoordOffset = 6;

const String _vertexBody = '''
uniform mat4 uModelViewProjection;
uniform mat4 uNormalMatrix;

void main() {
  // The upper 3x3 of the inverse transpose of the model matrix. It is the
  // identity whenever the model matrix is, which is every frame the CPU
  // rasteriser can be compared against - that rasteriser has no model matrix
  // and shades in model space. It is a uniform anyway because the first
  // non-uniform scale applied to a model shades it wrong without one, and a
  // wrongly lit model reads as a broken normal in the file.
  vNormal = mat3(uNormalMatrix) * aNormal;
  vTexCoord = aTexCoord;
  gl_Position = uModelViewProjection * vec4(aPosition, 1.0);
}
''';

const String _fragmentBody = '''
uniform sampler2D uBaseColorTexture;
uniform vec3 uBaseColor;
uniform vec3 uLightDirection;
uniform float uAmbient;
uniform int uLit;
uniform int uHasTexture;

void main() {
  // The base-colour factor multiplied by the map rather than replaced by it,
  // which is what glTF specifies and what MeshRasterizer does with its
  // `_mul`: a white factor samples the texture unchanged and a tinted one
  // tints it.
  vec3 surface = uBaseColor;
  if (uHasTexture == 1) {
    surface *= texture(uBaseColorTexture, vTexCoord).rgb;
  }

  if (uLit == 0) {
    fragColor = vec4(surface, 1.0);
    return;
  }

  // Renormalised per fragment because the interpolation between two unit
  // normals is not a unit vector - shortest at the middle of a wide facet,
  // which is exactly where a missing normalise shows as a dark band.
  vec3 n = normalize(vNormal);
  // A back face that survived culling - a double-sided material - is lit with
  // its normal reversed. Without it the inside of an open shell is black and
  // looks like a hole. gl_FrontFacing is GL's answer to the same question
  // MeshRasterizer answers with the sign of the projected triangle's area,
  // and the two agree because the winding convention was matched: see
  // GlMeshPipeline's note on the screen-space y flip.
  if (!gl_FrontFacing) n = -n;

  float lambert = max(0.0, -dot(n, uLightDirection));
  // A second, dimmer light from the opposite side. One light leaves half of
  // every model in flat ambient, where its shape cannot be read at all.
  float fill = max(0.0, dot(n, uLightDirection)) * 0.25;
  float intensity = clamp(uAmbient + lambert * 0.85 + fill, 0.0, 1.2);

  // The clamp to 1.2 lets the product exceed 1.0, and the framebuffer clamps
  // it on write exactly as the CPU's `lit > 255 ? 255 : lit` does. Clamping
  // the colour here as well would be the same answer, and leaving it to the
  // fixed-function write keeps the two files reading the same.
  fragColor = vec4(surface * intensity, 1.0);
}
''';

/// The vertex shader for the dialect [desktop] selects.
String meshVertexShaderSource({required bool desktop}) => desktop
    ? '#version 330 core\n'
        'in vec3 aPosition;\n'
        'in vec3 aNormal;\n'
        'in vec2 aTexCoord;\n'
        'out vec3 vNormal;\n'
        'out vec2 vTexCoord;\n'
        '$_vertexBody'
    : '#version 300 es\n'
        'precision highp float;\n'
        'in vec3 aPosition;\n'
        'in vec3 aNormal;\n'
        'in vec2 aTexCoord;\n'
        'out vec3 vNormal;\n'
        'out vec2 vTexCoord;\n'
        '$_vertexBody';

/// The fragment shader for the dialect [desktop] selects.
String meshFragmentShaderSource({required bool desktop}) => desktop
    ? '#version 330 core\n'
        'in vec3 vNormal;\n'
        'in vec2 vTexCoord;\n'
        'out vec4 fragColor;\n'
        '$_fragmentBody'
    : '#version 300 es\n'
        'precision highp float;\n'
        'in vec3 vNormal;\n'
        'in vec2 vTexCoord;\n'
        'out vec4 fragColor;\n'
        '$_fragmentBody';
