/// The one GLSL program that turns a video frame into pixels.
///
/// A program of its own rather than a fourth mode in `gl_shaders.dart`, and
/// the reason is the vertex layout. The renderer's program carries a colour
/// and a shape rectangle per vertex so that a solid fill, a coverage mask and
/// an image can share a batch; a video frame carries neither and needs
/// something none of them do - source-pixel coordinates precise enough to
/// address an individual texel - plus up to three samplers where that program
/// has one. Folding it in would widen every vertex of every rectangle in the
/// scene to pay for it.
///
/// ## Sampling is `texelFetch`, and that is the parity contract
///
/// Every sample here is an unfiltered integer texel fetch, not a normalised
/// `texture()` call. Three things follow, and all three are wanted:
///
///   1. **It is exact.** There is no filter, no wrap mode and no
///      normalisation to disagree about, so the value the shader reads is the
///      byte the upload wrote. That is what lets
///      `video_color_conversion.dart` be a *reference* rather than an
///      approximation, and what lets the GL parity test declare a tolerance of
///      one level instead of a percentage.
///   2. **Chroma is replicated, not interpolated.** `p / 2` is integer
///      division, so all four pixels of a 2x2 block read one chroma sample -
///      exactly what [sampleYuvCodes] does on the CPU. See the note on chroma
///      in `video_color_conversion.dart` for why a bilinear upsample is a
///      change to both paths or it is a divergence.
///   3. **YUY2 can be unpacked at all.** A packed `Y0 U Y1 V` quadruple is
///      four unrelated bytes; a filtered sampler would blend `Y0` with `U` at
///      the seam between two texels and produce colour noise along every
///      second column.
///
/// ## Where the transform, the clip and the crop live
///
/// None of them are in this shader, and that is deliberate.
///
///   * The **transform** is baked into the four vertex positions by the
///     caller, which is what makes an arbitrarily rotated or skewed frame
///     correct here while the display-list path can only express an
///     axis-aligned box. A matrix uniform would move the same arithmetic into
///     the vertex stage and buy nothing: there are four vertices.
///   * The **clip** is `glScissor`. It is rectangular, it costs no fragment
///     work, and the display list's clip is a device rectangle by the time it
///     arrives.
///   * The **crop** is the source rectangle, carried per vertex as
///     `aSource`. A frame drawn from a region is four different numbers in the
///     vertex buffer and nothing else.
///
/// Opacity is the one thing that has to be a uniform, because it multiplies
/// the fragment.
library;

import '../../../graphics/video/video_frame.dart';

/// Attribute locations, bound before linking for the reason
/// `gl_shaders.dart` gives: ES 100 has no `layout(location=)` and binding
/// explicitly keeps that door open.
const int kVideoAttributePosition = 0;
const int kVideoAttributeSource = 1;

const List<String> kVideoAttributeNames = <String>[
  'aPosition',
  'aSource',
];

/// Values of the `uFormat` uniform.
///
/// Not `VideoPixelFormat.index`: the enum is a portable description that may
/// gain a member in the middle, and a shader constant that silently follows an
/// enum's declaration order is a renumbering waiting to happen. The mapping is
/// [videoGlModeFor], and [validateVideoGlShaderContract] checks it is total.
const int kVideoGlModeNv12 = 0;
const int kVideoGlModeI420 = 1;
const int kVideoGlModeYuy2 = 2;
const int kVideoGlModeRgba = 3;
const int kVideoGlModeBgra = 4;
const int kVideoGlModeCount = 5;

/// The `uFormat` value [format] is drawn with.
int videoGlModeFor(VideoPixelFormat format) => switch (format) {
      VideoPixelFormat.nv12 => kVideoGlModeNv12,
      VideoPixelFormat.i420 => kVideoGlModeI420,
      VideoPixelFormat.yuy2 => kVideoGlModeYuy2,
      VideoPixelFormat.rgba8888 => kVideoGlModeRgba,
      VideoPixelFormat.bgra8888 => kVideoGlModeBgra,
    };

/// Samplers the program declares, in binding-unit order.
const List<String> kVideoSamplerNames = <String>[
  'uPlane0',
  'uPlane1',
  'uPlane2',
];

/// Fails loudly if the shader constants and the portable format enum have
/// drifted apart.
///
/// Called from the executor's `initialize`, in the spirit of
/// `validateSparseGlShaderContract`: a mismatch between a Dart enum and a
/// shader's integer is not a compile error anywhere, and its symptom is a
/// frame decoded as the wrong format - which for NV12 read as I420 is a
/// picture that is recognisable and wrongly coloured, the hardest kind of
/// wrong to notice.
void validateVideoGlShaderContract() {
  final Set<int> seen = <int>{};
  for (final VideoPixelFormat format in VideoPixelFormat.values) {
    final int mode = videoGlModeFor(format);
    if (mode < 0 || mode >= kVideoGlModeCount) {
      throw StateError(
        'video GL mode $mode for ${format.name} is outside 0..'
        '${kVideoGlModeCount - 1}',
      );
    }
    if (!seen.add(mode)) {
      throw StateError('two video formats share GL mode $mode');
    }
    if (format.planeCount > kVideoSamplerNames.length) {
      throw StateError(
        '${format.name} has ${format.planeCount} planes and the video program '
        'declares only ${kVideoSamplerNames.length} samplers',
      );
    }
  }
}

const String _vertexBody = '''
uniform vec2 uViewport;
uniform int uYFlip;

void main() {
  vSource = aSource;
  // Device space is y-down from the top-left; NDC is y-up from the centre.
  // The second flip is for a pass rendering into a texture that will itself
  // be sampled - see kYFlipTopDown in gl_shaders.dart, which this deliberately
  // mirrors rather than reinvents, so a layer holding video is the same way up
  // as a layer holding anything else.
  float ndcY = 1.0 - aPosition.y / uViewport.y * 2.0;
  gl_Position = vec4(
    aPosition.x / uViewport.x * 2.0 - 1.0,
    uYFlip == 0 ? ndcY : -ndcY,
    0.0,
    1.0);
}
''';

const String _fragmentBody = '''
uniform sampler2D uPlane0;
uniform sampler2D uPlane1;
uniform sampler2D uPlane2;
uniform int uFormat;
uniform vec2 uFrameSize;
uniform float uOpacity;
uniform vec4 uMatrixR;
uniform vec4 uMatrixG;
uniform vec4 uMatrixB;

void main() {
  ivec2 size = ivec2(uFrameSize);
  // The floor is the nearest-sample rule, and the clamp is the edge rule: a
  // destination rectangle whose right edge lands exactly on the frame's width
  // would otherwise fetch one texel past the end, which is undefined rather
  // than merely wrong.
  ivec2 p = clamp(ivec2(floor(vSource)), ivec2(0), size - ivec2(1));

  vec3 yuv;
  float alpha = 1.0;
  if (uFormat == 0) {
    // NV12: luma at full resolution, one interleaved U,V pair per 2x2 block.
    float luma = texelFetch(uPlane0, p, 0).r;
    vec2 chroma = texelFetch(uPlane1, p / 2, 0).rg;
    yuv = vec3(luma, chroma.x, chroma.y);
  } else if (uFormat == 1) {
    // I420: the same subsampling, two separate chroma planes.
    ivec2 c = p / 2;
    yuv = vec3(
      texelFetch(uPlane0, p, 0).r,
      texelFetch(uPlane1, c, 0).r,
      texelFetch(uPlane2, c, 0).r);
  } else if (uFormat == 2) {
    // YUY2: one RGBA texel per two pixels, holding Y0, U, Y1, V. Which luma
    // belongs to this pixel is the parity of its x, and the fetch is
    // unfiltered precisely so the four bytes arrive unmixed.
    vec4 quad = texelFetch(uPlane0, ivec2(p.x / 2, p.y), 0);
    float luma = (p.x - (p.x / 2) * 2) == 0 ? quad.r : quad.b;
    yuv = vec3(luma, quad.g, quad.a);
  } else {
    // Already colour. The matrix is the identity here, so the three dot
    // products below cost nothing and remove a branch from the common path.
    vec4 texel = texelFetch(uPlane0, p, 0);
    yuv = uFormat == 3 ? texel.rgb : texel.bgr;
    alpha = texel.a;
  }

  vec4 sample4 = vec4(yuv, 1.0);
  vec3 rgb = clamp(
    vec3(dot(uMatrixR, sample4), dot(uMatrixG, sample4), dot(uMatrixB, sample4)),
    0.0,
    1.0);
  // Premultiplied out, like every other surface this renderer produces.
  fragColor = vec4(rgb * alpha * uOpacity, alpha * uOpacity);
}
''';

/// The vertex shader for the dialect [desktop] selects.
String videoVertexShaderSource({required bool desktop}) => desktop
    ? '#version 330 core\n'
        'in vec2 aPosition;\n'
        'in vec2 aSource;\n'
        'out vec2 vSource;\n'
        '$_vertexBody'
    : '#version 300 es\n'
        'precision highp float;\n'
        'in vec2 aPosition;\n'
        'in vec2 aSource;\n'
        'out vec2 vSource;\n'
        '$_vertexBody';

/// The fragment shader for the dialect [desktop] selects.
///
/// `highp` on ES is not decoration: a source coordinate on a 4K frame exceeds
/// what `mediump` guarantees, and the failure is a frame that samples the
/// wrong texel in bands down the right-hand side.
String videoFragmentShaderSource({required bool desktop}) => desktop
    ? '#version 330 core\n'
        'in vec2 vSource;\n'
        'out vec4 fragColor;\n'
        '$_fragmentBody'
    : '#version 300 es\n'
        'precision highp float;\n'
        'precision highp int;\n'
        'precision highp sampler2D;\n'
        'in vec2 vSource;\n'
        'out vec4 fragColor;\n'
        '$_fragmentBody';
