/// The one shader program the GPU renderer uses.
///
/// One program, three modes selected by a uniform, rather than three programs.
/// The reason is the batching rule: a pipeline change already breaks a batch,
/// so making it also a program switch would cost a `glUseProgram` per break -
/// but making the three modes *share* a program means the vertex layout, the
/// projection and the analytic-coverage term are written once and cannot
/// drift apart between them. The uniform branch is coherent across a whole
/// draw call, which is the case every GPU predicts perfectly.
///
/// ## The coverage term is the antialiasing
///
/// `boxCoverage` computes the exact area of the intersection between a pixel
/// square and the vertex's shape rectangle. For an axis-aligned rectangle
/// that is the true analytic coverage - not a sample count, not a distance
/// approximation - and it is the same quantity `raster/coverage.dart`
/// computes on the CPU. The two differ only in quantisation: the CPU rounds
/// positions to 1/255ths of a pixel to make adjacent spans telescope
/// exactly, while this stays in float. The difference is bounded by one
/// coverage level per axis.
///
/// Masked and textured quads set their shape rectangle equal to their
/// geometry, so the term evaluates to exactly 1 and the mask alone decides
/// coverage. That is why there is no separate "no coverage" mode.
///
/// ## Two dialects
///
/// GLSL 330 core for a desktop context, GLSL ES 300 for an ES one. They
/// differ in the version line and in ES needing explicit precision. The body
/// is shared so a fix cannot land in one and not the other.
library;

/// Attribute locations, bound before linking so neither dialect needs a
/// `layout(location=)` qualifier - ES 300 accepts them, ES 100 does not, and
/// binding explicitly keeps the door open.
const int kAttributePosition = 0;
const int kAttributeTexCoord = 1;
const int kAttributeColor = 2;
const int kAttributeShapeRect = 3;

const List<String> kAttributeNames = <String>[
  'aPosition',
  'aTexCoord',
  'aColor',
  'aShapeRect',
];

/// Values of the `uMode` uniform. Must match [GpuPipelineKind]'s order.
const int kModeSolid = 0;
const int kModeCoverageMask = 1;
const int kModeTexturedImage = 2;

/// Values of the `uYFlip` uniform: the orientation convention, declared.
///
/// OpenGL's framebuffer origin is the **bottom-left** corner. Every texture
/// this renderer samples - an uploaded image, the coverage atlas, the glyph
/// atlas - is stored **top-down**, row 0 first, because that is the order a
/// [Framebuffer] and a rasterised mask are laid out in and converting them
/// would cost a copy per upload.
///
/// Both atlases are *uploaded* rather than rendered into, and that is what
/// keeps them out of this uniform entirely. `glTexSubImage2D` writes the first
/// row of the bytes it is handed at the texture row it was given, so a
/// top-down staging image becomes a top-down texture, and the `v` a quad
/// carries for its top edge is `y / height` - the row the glyph or mask was
/// rasterised into. Nothing is flipped anywhere on that path. A backend that
/// reached for [kYFlipTopDown] when wiring the glyph atlas would draw every
/// letter upside down, and the test that ought to catch it does not if it uses
/// a face whose glyphs are symmetric: Ahem draws solid squares, and a square
/// is its own mirror image.
///
/// The two conventions meet at a layer. A pass that renders into a texture and
/// is then *sampled* must leave the image top-down like every other texture,
/// so it inverts its projection ([kYFlipTopDown]) - and, in `gl_backend.dart`,
/// its scissor rectangle with it. A pass that renders into a surface which is
/// *presented* or *read back* - a window's back buffer, or the offscreen
/// target's readback framebuffer - keeps GL's native orientation
/// ([kYFlipDefault]), because `SwapBuffers` and the row flip in `_readPixels`
/// both already expect it.
///
/// Getting this backwards does not fail, it draws every layer upside down,
/// which is exactly the kind of wrong picture that looks like a bug in the
/// scene. It is a uniform rather than two programs because a program switch
/// per pass costs more than an int compare per vertex that is uniform across
/// the whole draw call.
const int kYFlipDefault = 0;
const int kYFlipTopDown = 1;

const String _vertexBody = '''
uniform vec2 uViewport;
uniform int uYFlip;

void main() {
  vTexCoord = aTexCoord;
  vColor = aColor;
  vShapeRect = aShapeRect;
  vDevicePos = aPosition;
  // Device space is y-down with the origin at the top-left corner of the
  // surface; normalised device coordinates are y-up with the origin in the
  // middle. The flip lives here, once, instead of in every backend that
  // computes a rectangle.
  float ndcY = 1.0 - aPosition.y / uViewport.y * 2.0;
  // ...and is inverted again when the pass renders into a texture something
  // else will sample. See kYFlipTopDown for the whole argument; in one line,
  // GL stores a rendered image bottom-up and every texture this renderer
  // samples is top-down, so a layer target has to be written upside down to
  // come out the right way up.
  gl_Position = vec4(
    aPosition.x / uViewport.x * 2.0 - 1.0,
    uYFlip == 0 ? ndcY : -ndcY,
    0.0,
    1.0);
}
''';

const String _fragmentBody = '''
uniform sampler2D uTexture;
uniform int uMode;

// Exact area of the pixel square at [p] that lies inside the rectangle [r].
// Separable, which is why an axis-aligned rectangle needs no mask.
float boxCoverage(vec4 r, vec2 p) {
  vec2 lo = max(r.xy, p - 0.5);
  vec2 hi = min(r.zw, p + 0.5);
  vec2 overlap = clamp(hi - lo, 0.0, 1.0);
  return overlap.x * overlap.y;
}

void main() {
  vec4 color = vColor;
  if (uMode == 1) {
    // A coverage mask scales the already-premultiplied colour, which is the
    // premultiplied equivalent of mul255(alpha, coverage) on the CPU.
    color *= texture(uTexture, vTexCoord).r;
  } else if (uMode == 2) {
    // Premultiplied texel modulated by the paint's alpha; the colour
    // channels carry that alpha too, so this is a plain scale.
    color = texture(uTexture, vTexCoord) * vColor.a;
  }
  fragColor = color * boxCoverage(vShapeRect, vDevicePos);
}
''';

/// The vertex shader for the dialect [desktop] selects.
String vertexShaderSource({required bool desktop}) => desktop
    ? '#version 330 core\n'
        'in vec2 aPosition;\n'
        'in vec2 aTexCoord;\n'
        'in vec4 aColor;\n'
        'in vec4 aShapeRect;\n'
        'out vec2 vTexCoord;\n'
        'out vec4 vColor;\n'
        'out vec4 vShapeRect;\n'
        'out vec2 vDevicePos;\n'
        '$_vertexBody'
    : '#version 300 es\n'
        'precision highp float;\n'
        'in vec2 aPosition;\n'
        'in vec2 aTexCoord;\n'
        'in vec4 aColor;\n'
        'in vec4 aShapeRect;\n'
        'out vec2 vTexCoord;\n'
        'out vec4 vColor;\n'
        'out vec4 vShapeRect;\n'
        'out vec2 vDevicePos;\n'
        '$_vertexBody';

/// The fragment shader for the dialect [desktop] selects.
String fragmentShaderSource({required bool desktop}) => desktop
    ? '#version 330 core\n'
        'in vec2 vTexCoord;\n'
        'in vec4 vColor;\n'
        'in vec4 vShapeRect;\n'
        'in vec2 vDevicePos;\n'
        'out vec4 fragColor;\n'
        '$_fragmentBody'
    : '#version 300 es\n'
        'precision highp float;\n'
        'in vec2 vTexCoord;\n'
        'in vec4 vColor;\n'
        'in vec4 vShapeRect;\n'
        'in vec2 vDevicePos;\n'
        'out vec4 fragColor;\n'
        '$_fragmentBody';
