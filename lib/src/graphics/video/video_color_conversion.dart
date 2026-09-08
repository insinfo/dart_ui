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
  const YuvToRgbMatrix._(this.rows,
      {required this.colorSpace, required this.range});

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
      format.pixelFormat.isYuv ? of(format.colorSpace, format.range) : identity;

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
  String toString() => 'YuvToRgbMatrix(${colorSpace.name}, ${range.name})';
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
/// the measurement in `benchmark/video_conversion_benchmark.dart` an honest
/// comparison rather than a strawman. The fixed-point evaluation is proved
/// equal to [YuvToRgbMatrix.rgbFromCodes] within one level by test.
///
/// Lookup tables were the obvious next step and were measured instead of
/// assumed: the whole matrix as eight 256-entry `Int32List`s plus a clamp
/// table, which is the cheapest arithmetic this kernel can have, came out
/// inside the noise of the multiplies it replaced (7.89 ms against 8.53 on the
/// same 1080p frame). SIMD is measured out for the same reason and one more:
/// splitting the kernel showed it is roughly a third gather and two thirds
/// arithmetic, and a downscale gathers bytes that are not adjacent, so a
/// `Float32x4` would have to be built from four scalar loads - which this
/// repository has already measured, in the j2k codec, as slower than the
/// scalar loop it replaces.
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
///
/// ## Converting straight into the destination size
///
/// [destinationWidth] and [destinationHeight] ask for the result at a size
/// other than the region's. This is not a new picture: the sample chosen for
/// each destination pixel is **exactly** the one
/// [DecodedImage.resample] would have chosen from a 1:1 conversion, so
/// `convert(region) then resample(w, h)` and `convert(region, destinationWidth:
/// w, destinationHeight: h)` produce identical bytes - asserted over a matrix
/// of scale factors in `video_color_conversion_test.dart`, not assumed here.
///
/// What it removes is the intermediate image. The CPU presentation path drew a
/// 1080p frame into a 1084x610 window by converting 2.07 million pixels and
/// then keeping 0.66 million of them, which is where §68's 86 ms per displayed
/// frame - a ceiling of 11.6 fps - came from.
///
/// It is a point sample, and so was the two-step it replaces:
/// [DecodedImage.resample] is nearest-neighbour and documents that shrinking
/// "drops source pixels entirely and aliases". A box filter would be a better
/// picture than either - measured against a real decoded 1080p frame reduced
/// to 1084x610, the two differ by more than one level on 7% of pixels and by
/// more than sixteen on 3%, in the fine detail - and it would be a *different*
/// picture from the one every golden here records. That makes it the same kind
/// of change as the chroma note above: both paths at once, deliberately, or it
/// is a divergence. It is not a small one to pay for either, since averaging
/// has to read every source pixel that point sampling skips.
Uint8List convertVideoFrameToRgba(
  VideoFrame frame, {
  VideoRegion? region,
  ImageChannelOrder order = ImageChannelOrder.rgba,
  int opacity = 255,
  Uint8List? into,
  int? bytesPerRow,
  int? destinationWidth,
  int? destinationHeight,
}) {
  if (opacity < 0 || opacity > 255) {
    throw ArgumentError.value(opacity, 'opacity', 'must be 0..255');
  }
  final VideoFrameFormat format = frame.format;
  final VideoRegion source =
      (region ?? VideoRegion.wholeFrame(format.width, format.height))
          .intersect(VideoRegion.wholeFrame(format.width, format.height));
  if (source.isEmpty) {
    throw ArgumentError.value(
      region,
      'region',
      'does not overlap the ${format.width}x${format.height} frame',
    );
  }
  final int outWidth = destinationWidth ?? source.width;
  final int outHeight = destinationHeight ?? source.height;
  if (outWidth <= 0 || outHeight <= 0) {
    throw ArgumentError(
      'destination ${outWidth}x$outHeight: an image has at least one pixel on '
      'each axis',
    );
  }
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

  // Which source column and row each destination pixel reads, resolved once
  // instead of once per pixel. Two 4 KB lists against the 8.29 MB the old
  // intermediate image cost, and they take the floating point out of the
  // inner loop - the mapping is decided here and the kernels only index.
  final Int32List columns = _sampleAxis(source.left, source.width, outWidth);
  final Int32List rows = _sampleAxis(source.top, source.height, outHeight);

  switch (format.pixelFormat) {
    case VideoPixelFormat.bgra8888:
    case VideoPixelFormat.rgba8888:
      _convertPackedRgb(
        frame,
        out,
        stride,
        redIndex,
        blueIndex,
        opacity,
        columns,
        rows,
      );
    case VideoPixelFormat.nv12:
    case VideoPixelFormat.i420:
    case VideoPixelFormat.yuy2:
      _convertYuv(
        frame,
        out,
        stride,
        redIndex,
        blueIndex,
        opacity,
        columns,
        rows,
      );
  }
  return out;
}

/// The source coordinate each of [count] destination pixels samples.
///
/// The formula is [DecodedImage.resample]'s, deliberately and to the letter -
/// destination centre mapped back, floored, clamped - because that is what
/// makes converting at the destination size produce the same bytes as
/// converting 1:1 and resampling afterwards. A change here is a change to
/// every video frame the CPU path has ever drawn, so it is one line in one
/// place rather than one line in each kernel.
///
/// The identity case is spelled out rather than falling out of the arithmetic:
/// `(i + 0.5) * 1.0` floors back to `i` for every `i` a frame can hold, but a
/// 1:1 conversion is the golden-test path and it should not depend on that
/// being true.
Int32List _sampleAxis(int origin, int extent, int count) {
  final Int32List map = Int32List(count);
  if (count == extent) {
    for (var i = 0; i < count; i++) {
      map[i] = origin + i;
    }
    return map;
  }
  final double scale = extent / count;
  final int last = extent - 1;
  for (var i = 0; i < count; i++) {
    var sample = ((i + 0.5) * scale).floor();
    if (sample < 0) sample = 0;
    if (sample > last) sample = last;
    map[i] = origin + sample;
  }
  return map;
}

// `convertVideoFrameToNativeRgba` used to sit here. It moved to
// `video_color_conversion_native.dart` because it needs the FFI ring buffer,
// and this file is reachable from `lib/dart_ui.dart`, which the web backend
// compiles.

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

/// The YUV kernels, one per layout, and why the addressing is written twice.
///
/// [sampleYuvCodes] is still the definition of where a sample lives, and it is
/// what a test or a tool that has to explain one pixel calls. It is *not* what
/// these loops call, and that is a measurement rather than a preference: read
/// per pixel it costs a `frame.plane(i)` list index, a lifetime check and a
/// `rowOffset` multiply on every one of two million pixels, and it returns a
/// record. Hoisting the plane out of the loop and the row offset out of the
/// column took a 1080p NV12 frame from 86 ms to the numbers in
/// `benchmark/video_conversion_benchmark.dart`.
///
/// What keeps the copy honest is not care, it is a test: NV12, I420 and YUY2
/// encode the same `SyntheticPicture` and must convert to byte-identical
/// output, which is the assertion an addressing mistake in exactly one of
/// these three loops cannot survive.
void _convertYuv(
  VideoFrame frame,
  Uint8List out,
  int stride,
  int redIndex,
  int blueIndex,
  int opacity,
  Int32List columns,
  Int32List rows,
) {
  final VideoFrameFormat format = frame.format;
  final _FixedMatrix m = _FixedMatrix(YuvToRgbMatrix.forFormat(format));
  switch (format.pixelFormat) {
    case VideoPixelFormat.nv12:
      final VideoPlane luma = frame.plane(0);
      final VideoPlane chroma = frame.plane(1);
      _convertNv12(
        luma.bytes,
        luma.offset,
        luma.bytesPerRow,
        chroma.bytes,
        chroma.offset,
        chroma.bytesPerRow,
        out,
        stride,
        redIndex,
        blueIndex,
        opacity,
        columns,
        rows,
        m,
      );
    case VideoPixelFormat.i420:
      final VideoPlane luma = frame.plane(0);
      final VideoPlane cb = frame.plane(1);
      final VideoPlane cr = frame.plane(2);
      _convertI420(
        luma.bytes,
        luma.offset,
        luma.bytesPerRow,
        cb.bytes,
        cb.offset,
        cb.bytesPerRow,
        cr.bytes,
        cr.offset,
        cr.bytesPerRow,
        out,
        stride,
        redIndex,
        blueIndex,
        opacity,
        columns,
        rows,
        m,
      );
    case VideoPixelFormat.yuy2:
      final VideoPlane packed = frame.plane(0);
      _convertYuy2(
        packed.bytes,
        packed.offset,
        packed.bytesPerRow,
        out,
        stride,
        redIndex,
        blueIndex,
        opacity,
        columns,
        rows,
        m,
      );
    case VideoPixelFormat.bgra8888:
    case VideoPixelFormat.rgba8888:
      throw ArgumentError.value(
        format.pixelFormat,
        'frame.format.pixelFormat',
        'is already RGB; there are no YUV codes to sample',
      );
  }
}

void _convertNv12(
  Uint8List luma,
  int lumaOffset,
  int lumaStride,
  Uint8List chroma,
  int chromaOffset,
  int chromaStride,
  Uint8List out,
  int stride,
  int redIndex,
  int blueIndex,
  int opacity,
  Int32List columns,
  Int32List rows,
  _FixedMatrix m,
) {
  // The twelve coefficients as locals. Left as field reads they are twelve
  // loads through the same object on every pixel, and the AOT compiler does
  // not hoist them out of a loop that also writes to a `Uint8List`.
  final int rY = m.rY, rU = m.rU, rV = m.rV, rC = m.rC;
  final int gY = m.gY, gU = m.gU, gV = m.gV, gC = m.gC;
  final int bY = m.bY, bU = m.bU, bV = m.bV, bC = m.bC;
  final bool opaque = opacity == 255;
  final int width = columns.length;
  for (var j = 0; j < rows.length; j++) {
    final int sourceY = rows[j];
    final int lumaRow = lumaOffset + sourceY * lumaStride;
    final int chromaRow = chromaOffset + (sourceY >> 1) * chromaStride;
    var offset = j * stride;
    for (var i = 0; i < width; i++) {
      final int sourceX = columns[i];
      final int sy = luma[lumaRow + sourceX];
      final int chromaAt = chromaRow + (sourceX >> 1) * 2;
      final int su = chroma[chromaAt];
      final int sv = chroma[chromaAt + 1];
      var r = (rY * sy + rU * su + rV * sv + rC + _fixedHalf) >> 16;
      var g = (gY * sy + gU * su + gV * sv + gC + _fixedHalf) >> 16;
      var b = (bY * sy + bU * su + bV * sv + bC + _fixedHalf) >> 16;
      r = _clampByte(r);
      g = _clampByte(g);
      b = _clampByte(b);
      if (!opaque) {
        r = premultiplyChannel(r, opacity);
        g = premultiplyChannel(g, opacity);
        b = premultiplyChannel(b, opacity);
      }
      out[offset + redIndex] = r;
      out[offset + 1] = g;
      out[offset + blueIndex] = b;
      out[offset + 3] = opacity;
      offset += 4;
    }
  }
}

void _convertI420(
  Uint8List luma,
  int lumaOffset,
  int lumaStride,
  Uint8List cb,
  int cbOffset,
  int cbStride,
  Uint8List cr,
  int crOffset,
  int crStride,
  Uint8List out,
  int stride,
  int redIndex,
  int blueIndex,
  int opacity,
  Int32List columns,
  Int32List rows,
  _FixedMatrix m,
) {
  final int rY = m.rY, rU = m.rU, rV = m.rV, rC = m.rC;
  final int gY = m.gY, gU = m.gU, gV = m.gV, gC = m.gC;
  final int bY = m.bY, bU = m.bU, bV = m.bV, bC = m.bC;
  final bool opaque = opacity == 255;
  final int width = columns.length;
  for (var j = 0; j < rows.length; j++) {
    final int sourceY = rows[j];
    final int lumaRow = lumaOffset + sourceY * lumaStride;
    final int cbRow = cbOffset + (sourceY >> 1) * cbStride;
    final int crRow = crOffset + (sourceY >> 1) * crStride;
    var offset = j * stride;
    for (var i = 0; i < width; i++) {
      final int sourceX = columns[i];
      final int half = sourceX >> 1;
      final int sy = luma[lumaRow + sourceX];
      final int su = cb[cbRow + half];
      final int sv = cr[crRow + half];
      var r = (rY * sy + rU * su + rV * sv + rC + _fixedHalf) >> 16;
      var g = (gY * sy + gU * su + gV * sv + gC + _fixedHalf) >> 16;
      var b = (bY * sy + bU * su + bV * sv + bC + _fixedHalf) >> 16;
      r = _clampByte(r);
      g = _clampByte(g);
      b = _clampByte(b);
      if (!opaque) {
        r = premultiplyChannel(r, opacity);
        g = premultiplyChannel(g, opacity);
        b = premultiplyChannel(b, opacity);
      }
      out[offset + redIndex] = r;
      out[offset + 1] = g;
      out[offset + blueIndex] = b;
      out[offset + 3] = opacity;
      offset += 4;
    }
  }
}

void _convertYuy2(
  Uint8List packed,
  int packedOffset,
  int packedStride,
  Uint8List out,
  int stride,
  int redIndex,
  int blueIndex,
  int opacity,
  Int32List columns,
  Int32List rows,
  _FixedMatrix m,
) {
  final int rY = m.rY, rU = m.rU, rV = m.rV, rC = m.rC;
  final int gY = m.gY, gU = m.gU, gV = m.gV, gC = m.gC;
  final int bY = m.bY, bU = m.bU, bV = m.bV, bC = m.bC;
  final bool opaque = opacity == 255;
  final int width = columns.length;
  for (var j = 0; j < rows.length; j++) {
    final int packedRow = packedOffset + rows[j] * packedStride;
    var offset = j * stride;
    for (var i = 0; i < width; i++) {
      final int sourceX = columns[i];
      final int base = packedRow + (sourceX >> 1) * 4;
      final int sy = packed[base + (sourceX.isEven ? 0 : 2)];
      final int su = packed[base + 1];
      final int sv = packed[base + 3];
      var r = (rY * sy + rU * su + rV * sv + rC + _fixedHalf) >> 16;
      var g = (gY * sy + gU * su + gV * sv + gC + _fixedHalf) >> 16;
      var b = (bY * sy + bU * su + bV * sv + bC + _fixedHalf) >> 16;
      r = _clampByte(r);
      g = _clampByte(g);
      b = _clampByte(b);
      if (!opaque) {
        r = premultiplyChannel(r, opacity);
        g = premultiplyChannel(g, opacity);
        b = premultiplyChannel(b, opacity);
      }
      out[offset + redIndex] = r;
      out[offset + 1] = g;
      out[offset + blueIndex] = b;
      out[offset + 3] = opacity;
      offset += 4;
    }
  }
}

void _convertPackedRgb(
  VideoFrame frame,
  Uint8List out,
  int stride,
  int redIndex,
  int blueIndex,
  int opacity,
  Int32List columns,
  Int32List rows,
) {
  final VideoPlane plane = frame.plane(0);
  // The frame's own channel order, which is the format's business, not the
  // target's.
  final int srcRed =
      frame.format.pixelFormat == VideoPixelFormat.bgra8888 ? 2 : 0;
  _copyPackedRgb(
    plane.bytes,
    plane.offset,
    plane.bytesPerRow,
    out,
    stride,
    srcRed,
    2 - srcRed,
    redIndex,
    blueIndex,
    opacity,
    columns,
    rows,
  );
}

void _copyPackedRgb(
  Uint8List source,
  int sourceOffset,
  int sourceStride,
  Uint8List out,
  int stride,
  int srcRed,
  int srcBlue,
  int redIndex,
  int blueIndex,
  int opacity,
  Int32List columns,
  Int32List rows,
) {
  final bool opaque = opacity == 255;
  final int width = columns.length;
  for (var j = 0; j < rows.length; j++) {
    final int row = sourceOffset + rows[j] * sourceStride;
    var dst = j * stride;
    for (var i = 0; i < width; i++) {
      final int src = row + columns[i] * 4;
      var r = source[src + srcRed];
      var g = source[src + 1];
      var b = source[src + srcBlue];
      final int a = source[src + 3];
      if (!opaque) {
        r = premultiplyChannel(r, opacity);
        g = premultiplyChannel(g, opacity);
        b = premultiplyChannel(b, opacity);
      }
      out[dst + redIndex] = r;
      out[dst + 1] = g;
      out[dst + blueIndex] = b;
      out[dst + 3] = opaque ? a : premultiplyChannel(a, opacity);
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
