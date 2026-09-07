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
/// A solid quad may additionally carry a corner radius, in which case the
/// coverage comes from `roundedCoverage` and the shape is a rounded rectangle
/// evaluated in closed form rather than sampled out of the dense atlas. See
/// [kAnalyticRoundedRect] for how six parameters were fitted into the two
/// floats the shared vertex layout had left over, and which shapes therefore
/// still go to the atlas.
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

/// What the second texture-coordinate float means in [kModeSolid].
///
/// ## Why the analytic primitive rides in `aTexCoord`
///
/// `AnalyticPrimitiveKind` wants six floats on a vertex and the shared layout
/// in `gpu_pipeline.dart` has none spare: twelve floats, all of them read by
/// one of the three modes. Widening it would change the stride, the batcher
/// and every other backend's vertex writer for a shape only this one can
/// draw, so the parameters go where a solid fill already writes zeroes -
/// `aTexCoord`, which [kModeSolid] has never sampled anything with.
///
/// That buys two floats, not six, and the two are spent as
/// `(radius, kind)`. It is enough for the shape a user interface actually
/// draws - the uniform-radius rounded rectangle, whose box is already on the
/// vertex as `aShapeRect` - and it is *not* enough for per-corner radii, for
/// an ellipse's independent centre, or for the oriented kinds' axis. Those
/// keep going through the dense coverage atlas, which is the parity route;
/// see `gpu_raster_sink.dart`, which refuses them by name before it gets here.
///
/// [kAnalyticNone] is zero on purpose: every quad every other path in this
/// renderer writes leaves `aTexCoord` at the origin, so an older vertex and a
/// vertex from another backend both decode as "no analytic primitive" and get
/// the [boxCoverage] term they always got. Nothing had to be changed to keep
/// working.
const int kAnalyticNone = 0;

/// A rounded rectangle: `aShapeRect` is its box and `aTexCoord.x` its radius.
///
/// Radius zero is deliberately *not* encoded this way. The signed-distance
/// field of a zero-radius box and the separable area of [boxCoverage] agree
/// exactly along a straight edge and disagree at the four corner pixels - the
/// field answers `0.5 - length(q)` where the true covered area is the product
/// of the two axis overlaps, which at a pixel centred on the corner is 0.5
/// against 0.25. So a rectangle stays a rectangle here and only a genuinely
/// rounded corner takes the field.
const int kAnalyticRoundedRect = 1;

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

// Coverage of the pixel at [p] by the rectangle [r] with corner radius [rad].
//
// The body is AnalyticPrimitive.fieldAt for AnalyticPrimitiveKind.rounded with
// all four radii equal, transcribed: fold the pixel into the first quadrant,
// pull the box in by the radius, and read the distance to that inset box's
// boundary. It is signed, in device pixels, and exact.
//
// The coverage is then 0.5 - d, which is exact wherever the boundary crossing
// the pixel is straight - the four edges, which is most of the outline - and
// an approximation on the corner arcs, where the true covered area of a
// circular segment differs from the half-plane one by O(1/rad). At the radii
// an interface uses that is under a coverage level; at a radius of one pixel
// it is the widest this route ever deviates from the scanline filler, which is
// where the parity suite measures it.
//
// No dFdx: everything on this path is already in device pixels, because
// GpuRasterSink recognises the rounded rectangle after the player has applied
// the transform. A shape that arrived in some other space would need the
// gradient of the field to normalise the distance, and is refused instead.
float roundedCoverage(vec4 r, float rad, vec2 p) {
  vec2 centre = (r.xy + r.zw) * 0.5;
  // Not named `half`: GLSL reserves that word in both dialects, and a shader
  // that fails to compile here takes the whole renderer down with it.
  vec2 extent = (r.zw - r.xy) * 0.5;
  vec2 q = abs(p - centre) - extent + rad;
  float d = min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - rad;
  return clamp(0.5 - d, 0.0, 1.0);
}

void main() {
  vec4 color = vColor;
  float coverage;
  if (uMode == 1) {
    // A coverage mask scales the already-premultiplied colour, which is the
    // premultiplied equivalent of mul255(alpha, coverage) on the CPU.
    color *= texture(uTexture, vTexCoord).r;
    coverage = boxCoverage(vShapeRect, vDevicePos);
  } else if (uMode == 2) {
    // Premultiplied texel modulated by the paint's alpha; the colour
    // channels carry that alpha too, so this is a plain scale.
    color = texture(uTexture, vTexCoord) * vColor.a;
    coverage = boxCoverage(vShapeRect, vDevicePos);
  } else if (vTexCoord.y >= 0.5) {
    // kAnalyticRoundedRect. The comparison is a threshold rather than an
    // equality because the value is interpolated: it is written identically on
    // all four vertices, so it arrives constant, but a driver is entitled to
    // reconstruct 1.0 as 0.99999994 and an == test would then draw a plain
    // rectangle where a rounded one was asked for, on some hardware only.
    coverage = roundedCoverage(vShapeRect, vTexCoord.x, vDevicePos);
  } else {
    coverage = boxCoverage(vShapeRect, vDevicePos);
  }
  fragColor = color * coverage;
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
