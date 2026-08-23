/// YUV to RGB, defined once, in a form both a shader and a CPU loop can use.
///
/// There is exactly one place in this repository where the colour of a video
/// frame is decided, and it is [YuvToRgbMatrix.forFormat]. Everything else -
/// the reference converter below, the GLSL uniforms, an HLSL constant buffer -
/// reads its numbers from there.
///
/// That is not tidiness. A conversion matrix written twice is a conversion
/// matrix that will differ in the fourth decimal on one of the two paths, and
/// the symptom is a golden test that passes on the CPU and fails by one level
/// on the GPU, or worse, passes both because the tolerance was widened until
/// it did. The matrix is derived here, from the two luma coefficients the
/// colour space already carries, and handed out as sixteen floats.
///
/// ## The derivation, so nobody has to trust the constants
///
/// With `kr` and `kb` the luma weights of red and blue and `kg = 1 - kr - kb`:
///
///     Y' = kr*R + kg*G + kb*B                    (all in 0..1)
///     U' = (B - Y') / (2 * (1 - kb))             (in -0.5..0.5)
///     V' = (R - Y') / (2 * (1 - kr))
///
/// Inverting:
///
///     R = Y' + 2*(1 - kr) * V'
///     B = Y' + 2*(1 - kb) * U'
///     G = Y' - (2*kb*(1 - kb)/kg) * U' - (2*kr*(1 - kr)/kg) * V'
///
/// The stored 8-bit codes are not `Y'`, `U'`, `V'` but a scaled and offset
/// version of them, and that is where [VideoColorRange] enters:
///
///     limited: Y' = (y*255 - 16)/219,  U' = (u*255 - 128)/224
///     full:    Y' = y,                 U' = u - 128/255
///
/// with `y`, `u`, `v` the texel values a sampler returns, already divided by
/// 255. Substituting one into the other gives an affine map from `(y, u, v)`
/// to `(R, G, B)`, which is what this file stores: three rows of four floats,
/// the fourth being the constant term. A shader evaluates it as three dot
/// products; [convertVideoFrameToRgba] evaluates the same thing in 16.16 fixed
/// point.
library;

import 'dart:typed_data';

import '../image/decoded_image.dart';
import 'video_frame.dart';

/// Chroma's neutral point as a sampler sees it: 128 of 255.
const double _chromaNeutral = 128.0 / 255.0;

/// An affine map from sampled `(y, u, v)` to linear-code `(r, g, b)`.
///
/// "Linear-code" means the values a display expects to receive, in 0..1, not
/// scene-linear light: no transfer function is applied or removed anywhere in
/// this library. A frame decoded here is in the same encoding it was stored
/// in, which is what makes it composite correctly against the rest of a
/// renderer that is itself working in sRGB codes.
final class YuvToRgbMatrix {
  const YuvToRgbMatrix._(this.rows, {required this.colorSpace, required this.range});

  /// Twelve floats: `r` row, then `g`, then `b`, each `(cy, cu, cv, offset)`.
  ///
  /// Laid out as one flat list, in this order, because that is what
  /// `glUniform4f` x3 and a 3x4 constant buffer both want, and a layout that
  /// needs rearranging on one of the two paths is a layout that will be
  /// rearranged wrongly.
  final Float32List rows;

  final VideoColorSpace colorSpace;
  final VideoColorRange range;

  /// The identity map, for the formats that are already RGB.
  ///
  /// Present rather than null so a shader has one code path: an RGBA frame
  /// runs the same three dot products, which cost nothing measurable and
  /// remove a branch from the inner loop of every consumer.
  static final YuvToRgbMatrix identity = YuvToRgbMatrix._(
    Float32List.fromList(const <double>[
      1, 0, 0, 0, //
      0, 1, 0, 0, //
      0, 0, 1, 0, //
    ]),
    colorSpace: VideoColorSpace.bt709,
    range: VideoColorRange.full,
  );

  /// The matrix [format] decodes with.
  ///
  /// Cached per `(colorSpace, range)` pair: there are six of them, they never
  /// change, and building one allocates a `Float32List` that would otherwise
  /// be allocated once per frame per draw.
  static YuvToRgbMatrix forFormat(VideoFrameFormat format) =>
      format.pixelFormat.isYuv
          ? of(format.colorSpace, format.range)
          : identity;

  static YuvToRgbMatrix of(VideoColorSpace colorSpace, VideoColorRange range) =>
      _cache.putIfAbsent(
        (colorSpace, range),
        () => _derive(colorSpace, range),
      );

  static final Map<(VideoColorSpace, VideoColorRange), YuvToRgbMatrix> _cache =
      <(VideoColorSpace, VideoColorRange), YuvToRgbMatrix>{};

  static YuvToRgbMatrix _derive(
    VideoColorSpace colorSpace,
    VideoColorRange range,
  ) {
    final double kr = colorSpace.kr;
    final double kb = colorSpace.kb;
    final double kg = colorSpace.kg;

    // Coefficients of the inverse, in Y'U'V' space.
    final double cr = 2.0 * (1.0 - kr);
    final double cb = 2.0 * (1.0 - kb);
    final double cu = 2.0 * kb * (1.0 - kb) / kg;
    final double cv = 2.0 * kr * (1.0 - kr) / kg;

    // How the stored codes become Y'U'V'.
    final bool limited = range == VideoColorRange.limited;
    final double lumaScale = limited ? 255.0 / 219.0 : 1.0;
    final double lumaOffset = limited ? 16.0 / 255.0 : 0.0;
    final double chromaScale = limited ? 255.0 / 224.0 : 1.0;

    final double ky = lumaScale;
    final double yShift = -lumaScale * lumaOffset;
    final double kc = chromaScale;
    final double cShift = -chromaScale * _chromaNeutral;

    return YuvToRgbMatrix._(
      Float32List.fromList(<double>[
        // The constant terms take `cShift`, which already carries `kc`;
        // multiplying by `kc` a second time here is the mistake this layout
        // invites, and it shows up as a green cast on black rather than as
        // anything obviously broken.
        ky, 0.0, cr * kc, yShift + cr * cShift, //
        ky, -cu * kc, -cv * kc, yShift - (cu + cv) * cShift, //
        ky, cb * kc, 0.0, yShift + cb * cShift, //
      ]),
      colorSpace: colorSpace,
      range: range,
    );
  }

  double get rY => rows[0];
  double get rU => rows[1];
  double get rV => rows[2];
  double get rOffset => rows[3];
  double get gY => rows[4];
  double get gU => rows[5];
  double get gV => rows[6];
  double get gOffset => rows[7];
  double get bY => rows[8];
  double get bU => rows[9];
  double get bV => rows[10];
  double get bOffset => rows[11];

  /// The double-precision evaluation, for tests and for anything that wants
  /// the answer without a frame around it.
  ///
  /// [y], [u] and [v] are the 8-bit stored codes. The result is three 0..255
  /// channels, rounded, clamped, in red, green, blue order. This is the
  /// definition [convertVideoFrameToRgba] is required to match, and
  /// `video_color_conversion_test.dart` checks that it does across the
  /// sample space rather than at a handful of colours.
  (int, int, int) rgbFromCodes(int y, int u, int v) {
    final double fy = y / 255.0;
    final double fu = u / 255.0;
    final double fv = v / 255.0;
    return (
      _clamp255((rY * fy + rU * fu + rV * fv + rOffset) * 255.0),
      _clamp255((gY * fy + gU * fu + gV * fv + gOffset) * 255.0),
      _clamp255((bY * fy + bU * fu + bV * fv + bOffset) * 255.0),
    );
  }

  static int _clamp255(double value) {
    final int rounded = value.round();
    if (rounded < 0) return 0;
    if (rounded > 255) return 255;
    return rounded;
  }

  @override
  String toString() =>
      'YuvToRgbMatrix(${colorSpace.name}, ${range.name})';
}

/// The reference converter: a whole frame, or a region of one, to RGBA.
///
/// Correctness first and speed second, in that order and on purpose. This is
/// what the headless renderer draws, what a golden test compares against, and
/// what the GPU path is measured for parity against - so an optimisation that
/// changes a single level here changes the definition of "correct" for
/// everything else.
///
/// It is not, however, deliberately slow. The matrix is evaluated in 16.16
/// fixed point, which is what a production CPU converter does and what makes
/// the measurement in `benchmark/video_upload_benchmark.dart` an honest
/// comparison rather than a strawman. The fixed-point evaluation is proved
/// equal to [YuvToRgbMatrix.rgbFromCodes] within one level by test.
///
/// ## Chroma is sampled nearest, and that is a contract
///
/// One chroma sample covers a 2x2 block, and this expands it by *replication*:
/// every pixel of the block gets that sample unchanged. The alternative -
/// interpolating chroma between neighbouring samples - is what a high quality
/// scaler does and is a different picture, better on smooth gradients and
/// worse on hard colour edges, where it invents a halo.
///
/// The choice matters far more for being *shared* than for being right: the
/// GPU path fetches exactly the same texel with `texelFetch`, so the two agree
/// pixel for pixel and the parity test can declare a tolerance of one level
/// rather than "close enough". A future bilinear chroma upsample is a change
/// to both paths at once or it is a divergence.
///
/// [opacity] is applied as a premultiplication, so the result is a
/// premultiplied RGBA image exactly like every other surface in the renderer.
/// A video frame is opaque, so at full opacity the premultiplication is the
/// identity and costs three compares.
Uint8List convertVideoFrameToRgba(
  VideoFrame frame, {
  VideoRegion? region,
  ImageChannelOrder order = ImageChannelOrder.rgba,
  int opacity = 255,
  Uint8List? into,
  int? bytesPerRow,
}) {
  if (opacity < 0 || opacity > 255) {
    throw ArgumentError.value(opacity, 'opacity', 'must be 0..255');
  }
  final VideoFrameFormat format = frame.format;
  final VideoRegion source = (region ??
          VideoRegion.wholeFrame(format.width, format.height))
      .intersect(VideoRegion.wholeFrame(format.width, format.height));
  if (source.isEmpty) {
    throw ArgumentError.value(
      region,
      'region',
      'does not overlap the ${format.width}x${format.height} frame',
    );
  }
  final int outWidth = source.width;
  final int outHeight = source.height;
  final int stride = bytesPerRow ?? outWidth * 4;
  if (stride < outWidth * 4) {
    throw ArgumentError.value(
      stride,
      'bytesPerRow',
      'a ${outWidth}px row needs at least ${outWidth * 4} bytes',
    );
  }
  final Uint8List out = into ?? Uint8List(stride * outHeight);
  if (out.length < stride * outHeight) {
    throw ArgumentError.value(
      out.length,
      'into.length',
      'needs $stride x $outHeight bytes',
    );
  }

  final int redIndex = order.redIndex;
  final int blueIndex = order.blueIndex;

  switch (format.pixelFormat) {
    case VideoPixelFormat.bgra8888:
    case VideoPixelFormat.rgba8888:
      _convertPackedRgb(
        frame,
        source,
        out,
        stride,
        redIndex,
        blueIndex,
        opacity,
      );
    case VideoPixelFormat.nv12:
    case VideoPixelFormat.i420:
    case VideoPixelFormat.yuy2:
      _convertYuv(frame, source, out, stride, redIndex, blueIndex, opacity);
  }
  return out;
}

/// 16.16 coefficients of [matrix], scaled so the inputs may stay 8-bit codes.
///
/// `out255 = c0*Y + c1*U + c2*V + c3` with the row's constant term already
/// multiplied by 255, so no divide by 255 appears in the inner loop.
final class _FixedMatrix {
  _FixedMatrix(YuvToRgbMatrix matrix)
      : rY = _fixed(matrix.rY),
        rU = _fixed(matrix.rU),
        rV = _fixed(matrix.rV),
        rC = _fixed(matrix.rOffset * 255.0),
        gY = _fixed(matrix.gY),
        gU = _fixed(matrix.gU),
        gV = _fixed(matrix.gV),
        gC = _fixed(matrix.gOffset * 255.0),
        bY = _fixed(matrix.bY),
        bU = _fixed(matrix.bU),
        bV = _fixed(matrix.bV),
        bC = _fixed(matrix.bOffset * 255.0);

  final int rY, rU, rV, rC;
  final int gY, gU, gV, gC;
  final int bY, bU, bV, bC;

  static int _fixed(double value) => (value * 65536.0).round();
}

const int _fixedHalf = 1 << 15;

int _clampByte(int value) {
  if (value < 0) return 0;
  if (value > 255) return 255;
  return value;
}

void _convertYuv(
  VideoFrame frame,
  VideoRegion source,
  Uint8List out,
  int stride,
  int redIndex,
  int blueIndex,
  int opacity,
) {
  final VideoFrameFormat format = frame.format;
  final _FixedMatrix m = _FixedMatrix(YuvToRgbMatrix.forFormat(format));
  final bool opaque = opacity == 255;
  const int greenIndex = 1;
  const int alphaIndex = 3;

  for (var y = source.top; y < source.bottom; y++) {
    var offset = (y - source.top) * stride;
    for (var x = source.left; x < source.right; x++) {
      final (int sy, int su, int sv) = sampleYuvCodes(frame, x, y);
      var r = (m.rY * sy + m.rU * su + m.rV * sv + m.rC + _fixedHalf) >> 16;
      var g = (m.gY * sy + m.gU * su + m.gV * sv + m.gC + _fixedHalf) >> 16;
      var b = (m.bY * sy + m.bU * su + m.bV * sv + m.bC + _fixedHalf) >> 16;
      r = _clampByte(r);
      g = _clampByte(g);
      b = _clampByte(b);
      if (!opaque) {
        r = premultiplyChannel(r, opacity);
        g = premultiplyChannel(g, opacity);
        b = premultiplyChannel(b, opacity);
      }
      out[offset + redIndex] = r;
      out[offset + greenIndex] = g;
      out[offset + blueIndex] = b;
      out[offset + alphaIndex] = opacity;
      offset += 4;
    }
  }
}

void _convertPackedRgb(
  VideoFrame frame,
  VideoRegion source,
  Uint8List out,
  int stride,
  int redIndex,
  int blueIndex,
  int opacity,
) {
  final VideoPlane plane = frame.plane(0);
  final Uint8List bytes = plane.bytes;
  // The frame's own channel order, which is the format's business, not the
  // target's.
  final int srcRed =
      frame.format.pixelFormat == VideoPixelFormat.bgra8888 ? 2 : 0;
  final int srcBlue = 2 - srcRed;
  final bool opaque = opacity == 255;

  for (var y = source.top; y < source.bottom; y++) {
    var src = plane.rowOffset(y) + source.left * 4;
    var dst = (y - source.top) * stride;
    for (var x = source.left; x < source.right; x++) {
      var r = bytes[src + srcRed];
      var g = bytes[src + 1];
      var b = bytes[src + srcBlue];
      final int a = bytes[src + 3];
      if (!opaque) {
        r = premultiplyChannel(r, opacity);
        g = premultiplyChannel(g, opacity);
        b = premultiplyChannel(b, opacity);
      }
      out[dst + redIndex] = r;
      out[dst + 1] = g;
      out[dst + blueIndex] = b;
      out[dst + 3] = opaque ? a : premultiplyChannel(a, opacity);
      src += 4;
      dst += 4;
    }
  }
}

/// The `(y, u, v)` codes at frame pixel ([x], [y]), sampled nearest.
///
/// The one function that knows where a sample lives in each layout, so that
/// the converter above, a test, and any tool that has to explain a pixel all
/// read the same addressing arithmetic. It is deliberately not inlined by hand
/// into the loop: the shapes it hides - an interleaved pair, two planes at
/// half resolution, a packed quadruple whose luma alternates - are exactly the
/// places a hand-inlined copy would drift.
(int, int, int) sampleYuvCodes(VideoFrame frame, int x, int y) {
  switch (frame.format.pixelFormat) {
    case VideoPixelFormat.nv12:
      final VideoPlane luma = frame.plane(0);
      final VideoPlane chroma = frame.plane(1);
      final int chromaOffset = chroma.rowOffset(y >> 1) + (x >> 1) * 2;
      return (
        luma.bytes[luma.rowOffset(y) + x],
        chroma.bytes[chromaOffset],
        chroma.bytes[chromaOffset + 1],
      );
    case VideoPixelFormat.i420:
      final VideoPlane luma = frame.plane(0);
      final VideoPlane cb = frame.plane(1);
      final VideoPlane cr = frame.plane(2);
      return (
        luma.bytes[luma.rowOffset(y) + x],
        cb.bytes[cb.rowOffset(y >> 1) + (x >> 1)],
        cr.bytes[cr.rowOffset(y >> 1) + (x >> 1)],
      );
    case VideoPixelFormat.yuy2:
      final VideoPlane packed = frame.plane(0);
      final int base = packed.rowOffset(y) + (x >> 1) * 4;
      return (
        packed.bytes[base + (x.isEven ? 0 : 2)],
        packed.bytes[base + 1],
        packed.bytes[base + 3],
      );
    case VideoPixelFormat.bgra8888:
    case VideoPixelFormat.rgba8888:
      throw ArgumentError.value(
        frame.format.pixelFormat,
        'frame.format.pixelFormat',
        'is already RGB; there are no YUV codes to sample',
      );
  }
}
