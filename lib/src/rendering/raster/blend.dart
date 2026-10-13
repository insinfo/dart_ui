/// Source-over compositing on premultiplied 8-bit pixels.
///
/// The framework commits to premultiplied alpha in `PixelFormat`, and that
/// choice is what makes this file short: source-over on premultiplied colour
/// is `dst = src + dst * (1 - srcAlpha)` with no divide and no separate alpha
/// case. Straight alpha would need a divide per channel per pixel here and a
/// re-multiply before handing the buffer to any compositor.
///
/// Nothing in this file knows about channel order. Both `PixelFormat` values
/// put alpha in byte 3 and differ only in whether byte 0 is blue or red, so
/// the routines below take the three colour bytes in *memory order* and the
/// caller - the rasteriser, which knows the target format - decides what those
/// bytes mean. That keeps the swizzle at the one place that has the format and
/// out of the inner loop.
library;

import 'dart:typed_data';

import '../../graphics/display_list_opcodes.dart';

/// Multiplies an 8-bit [value] by an 8-bit [alpha] treated as a fraction of
/// 255, rounded to nearest.
///
/// The `+0x80` then `(t + (t >> 8)) >> 8` form avoids a division. It is not an
/// approximation that happens to be close enough: over the whole 256x256 input
/// domain it produces exactly the same answer as `(value * alpha + 127) ~/ 255`
/// and as `round(value * alpha / 255)`. `blend_test.dart` asserts that
/// exhaustively, because the failure mode of a cheaper approximation is subtle
/// and permanent - a scheme that maps 255x255 to 254 makes it impossible to
/// draw white, and one that maps small products up to 1 makes it impossible to
/// draw black. Those two end points are the ones that get noticed a year later
/// as "the whites are slightly grey".
@pragma('vm:prefer-inline')
int mul255(int value, int alpha) {
  final t = value * alpha + 0x80;
  return (t + (t >> 8)) >> 8;
}

/// Converts a straight-alpha channel to premultiplied.
///
/// Named separately from [mul255] even though the arithmetic is identical,
/// because the two carry different meanings at the call site and confusing
/// "scale this by a coverage" with "premultiply this by its own alpha" is a
/// real bug. The compiler collapses the difference; the reader should not have
/// to.
@pragma('vm:prefer-inline')
int premultiply(int channel, int alpha) => mul255(channel, alpha);

/// One channel of `src over dst`, where [src] is already premultiplied and
/// [inverseAlpha] is `255 - srcAlpha`.
///
/// The caller passes the inverse rather than the alpha so that a fill of a
/// whole row computes `255 - a` once instead of once per channel per pixel.
@pragma('vm:prefer-inline')
int blendChannelOver(int src, int dst, int inverseAlpha) =>
    src + mul255(dst, inverseAlpha);

/// Composites one premultiplied source pixel over the pixel at [offset].
///
/// [c0], [c1] and [c2] are the colour bytes in memory order and [alpha] is
/// byte 3; see the library comment for why the channels are unnamed here.
///
/// Two cases are special-cased and no others:
///
/// * `alpha == 0` contributes nothing. `src` is zero in every channel (it is
///   premultiplied) and the destination is scaled by 255/255, so the general
///   path already returns the destination unchanged - but it writes four bytes
///   to do it. Skipping is worth it because fully transparent pixels are not
///   rare: they are every pixel of the untouched region of a glyph atlas, an
///   icon or any sprite with a transparent margin.
/// * `alpha == 255` is a straight copy. The destination term vanishes, and the
///   copy avoids four multiplies. This is the common case for opaque
///   backgrounds and solid fills, which is most of what a UI paints.
///
/// Nothing else earns a branch. Intermediate alphas are the general case, and
/// a test like `alpha == 128` would cost a comparison on every pixel to save
/// nothing measurable on the few that match; predictable-branch reasoning
/// argues against adding branches whose outcome varies pixel to pixel.
@pragma('vm:prefer-inline')
void blendPixelOver(
  Uint8List dst,
  int offset,
  int c0,
  int c1,
  int c2,
  int alpha,
) {
  if (alpha == 0) return;
  if (alpha == 255) {
    dst[offset] = c0;
    dst[offset + 1] = c1;
    dst[offset + 2] = c2;
    dst[offset + 3] = 255;
    return;
  }
  final inverse = 255 - alpha;
  dst[offset] = blendChannelOver(c0, dst[offset], inverse);
  dst[offset + 1] = blendChannelOver(c1, dst[offset + 1], inverse);
  dst[offset + 2] = blendChannelOver(c2, dst[offset + 2], inverse);
  dst[offset + 3] = blendChannelOver(alpha, dst[offset + 3], inverse);
}

/// Replaces the pixel at [offset] with a premultiplied source. GL: `ONE,
/// ZERO`.
///
/// A replace, not a draw: the alpha goes too, so a source that is partly
/// transparent makes the destination partly transparent rather than showing
/// through it. Nothing is special-cased, and in particular `alpha == 0` is
/// *not* skipped here - erasing the destination is the whole content of this
/// equation, and the branch [blendPixelOver] takes there would turn it into a
/// no-op. Whether a source that has rounded away to nothing should reach this
/// function at all is the caller's question, and `rasterizer.dart` answers it
/// in one place for all three modes.
///
/// ## What "replace" means under partial coverage
///
/// It means replace with the *coverage-scaled* source, not "lerp towards the
/// source by the coverage". A caller that has scaled all four channels of a
/// premultiplied source by a coverage byte and hands the result here writes a
/// pixel that is `coverage` opaque, wherever the destination was opaque
/// before. So an antialiased shape drawn with `src` cuts a soft hole in what
/// was under it, and the fringe of that hole is *transparent*, not a mix of
/// the two colours.
///
/// That is not a choice made for tidiness. `gl_shaders.dart` multiplies the
/// premultiplied vertex colour by the coverage in the fragment shader and
/// hands the product to a fixed-function `ONE, ZERO` blend, so the GPU writes
/// exactly `src * coverage` and nothing of the destination survives. The
/// alternative reading - `dst = src * c + dst * (1 - c)`, which is what Skia
/// does, and which keeps an opaque destination opaque - is a *different*
/// equation with a different name (`srcOver` against a pre-erased
/// destination), and it is not the one this framework's GPU backend can
/// express. Two backends with two readings of `src` is the divergence this
/// whole file exists to prevent, so the CPU takes the one the GPU is capable
/// of.
@pragma('vm:prefer-inline')
void blendPixelSrc(
  Uint8List dst,
  int offset,
  int c0,
  int c1,
  int c2,
  int alpha,
) {
  dst[offset] = c0;
  dst[offset + 1] = c1;
  dst[offset + 2] = c2;
  dst[offset + 3] = alpha;
}

/// Adds a premultiplied source into the pixel at [offset], saturating. GL:
/// `ONE, ONE`.
///
/// Every channel including alpha, and every one of them clamped rather than
/// wrapped; see [addSaturating] for why the clamp is the equation and not a
/// guard.
///
/// A premultiplied source with `alpha == 0` has zero in every colour channel
/// too - `premultiply` scales each of them by that same alpha - so it adds
/// nothing, and the caller that already knows the alpha is zero can skip the
/// call. There is no branch here for it: unlike [blendPixelOver], which saves
/// four multiplies by testing, this would save four adds.
@pragma('vm:prefer-inline')
void blendPixelPlus(
  Uint8List dst,
  int offset,
  int c0,
  int c1,
  int c2,
  int alpha,
) {
  dst[offset] = addSaturating(c0, dst[offset]);
  dst[offset + 1] = addSaturating(c1, dst[offset + 1]);
  dst[offset + 2] = addSaturating(c2, dst[offset + 2]);
  dst[offset + 3] = addSaturating(alpha, dst[offset + 3]);
}

/// Keeps the source where the destination has alpha: `dst = src * dstAlpha`.
/// GL: `DST_ALPHA, ZERO`.
///
/// The destination's colour is discarded and only its alpha is read, which is
/// what gradient text needs: the text is drawn into a layer first, and a ramp
/// drawn over the whole layer with this mode takes the ramp's colour exactly
/// where a glyph put alpha and nothing elsewhere. Each channel, alpha
/// included, is one [mul255] of the premultiplied source by the destination's
/// alpha byte, which is the single multiply `DST_ALPHA` asks the blend unit
/// for; the result stays premultiplied because every channel is scaled by the
/// same factor.
///
/// No case is special. A transparent source writes zeros, which is the
/// equation's answer and not an accident - see
/// `blendModeWritesTransparentSource` for why a caller must not skip it.
@pragma('vm:prefer-inline')
void blendPixelSrcIn(
  Uint8List dst,
  int offset,
  int c0,
  int c1,
  int c2,
  int alpha,
) {
  final int dstAlpha = dst[offset + 3];
  dst[offset] = mul255(c0, dstAlpha);
  dst[offset + 1] = mul255(c1, dstAlpha);
  dst[offset + 2] = mul255(c2, dstAlpha);
  dst[offset + 3] = mul255(alpha, dstAlpha);
}

/// Keeps the destination where the source has alpha: `dst = dst * srcAlpha`.
/// GL: `ZERO, SRC_ALPHA`.
///
/// The source's colour channels are ignored - only [alpha] is read - which is
/// what makes this a mask: a ramp from opaque to transparent drawn with it
/// fades whatever is under it, whatever colour the ramp happens to be. The
/// colour parameters are kept so every equation in this file has one
/// signature and the loops that pick one can call any of them.
@pragma('vm:prefer-inline')
void blendPixelDstIn(
  Uint8List dst,
  int offset,
  int c0,
  int c1,
  int c2,
  int alpha,
) {
  if (alpha == 255) return;
  dst[offset] = mul255(dst[offset], alpha);
  dst[offset + 1] = mul255(dst[offset + 1], alpha);
  dst[offset + 2] = mul255(dst[offset + 2], alpha);
  dst[offset + 3] = mul255(dst[offset + 3], alpha);
}

/// Erases the destination where the source has alpha:
/// `dst = dst * (1 - srcAlpha)`. GL: `ZERO, ONE_MINUS_SRC_ALPHA`.
///
/// The complement of [blendPixelDstIn], and the destination term of
/// [blendPixelOver] with the source term left out - so it rounds exactly as
/// source-over's attenuation does, through the same [mul255] by `255 - a`.
@pragma('vm:prefer-inline')
void blendPixelDstOut(
  Uint8List dst,
  int offset,
  int c0,
  int c1,
  int c2,
  int alpha,
) {
  if (alpha == 0) return;
  final int inverse = 255 - alpha;
  dst[offset] = mul255(dst[offset], inverse);
  dst[offset + 1] = mul255(dst[offset + 1], inverse);
  dst[offset + 2] = mul255(dst[offset + 2], inverse);
  dst[offset + 3] = mul255(dst[offset + 3], inverse);
}

/// Composites one premultiplied source pixel with [mode].
///
/// The per-pixel dispatch, for the loops whose source changes every pixel
/// anyway - a gradient, a layer composite - and for the masking modes, which
/// are drawn over one layer per `ShaderMask` and not on any path that has
/// been measured hot. The three original modes keep their own hoisted loops in
/// `rasterizer.dart`; this is the one copy of the dispatch everything else
/// shares, so a mode added to [CpuBlendMode] is a compile error here and
/// nowhere else.
@pragma('vm:prefer-inline')
void blendPixel(
  CpuBlendMode mode,
  Uint8List dst,
  int offset,
  int c0,
  int c1,
  int c2,
  int alpha,
) {
  switch (mode) {
    case CpuBlendMode.srcOver:
      blendPixelOver(dst, offset, c0, c1, c2, alpha);
    case CpuBlendMode.src:
      blendPixelSrc(dst, offset, c0, c1, c2, alpha);
    case CpuBlendMode.plus:
      blendPixelPlus(dst, offset, c0, c1, c2, alpha);
    case CpuBlendMode.srcIn:
      blendPixelSrcIn(dst, offset, c0, c1, c2, alpha);
    case CpuBlendMode.dstIn:
      blendPixelDstIn(dst, offset, c0, c1, c2, alpha);
    case CpuBlendMode.dstOut:
      blendPixelDstOut(dst, offset, c0, c1, c2, alpha);
  }
}

/// The composite equations this rasteriser can draw with.
///
/// Six, and exactly the six the display list can encode. The enum exists
/// instead of passing the wire constant down because the raster layer has no
/// business validating a wire format twice: [cpuBlendForMode] is the one place
/// an unknown mode is refused, and everything below it takes a value that
/// cannot be anything else.
///
/// It is also what a primitive is drawn with, not only what a layer is
/// composited with. The two used to be different: the rasteriser composited
/// every *primitive* source-over regardless of the paint, and only a layer's
/// composite honoured the mode. That made a `plus` rectangle a different
/// picture on the two backends, which is what `test/differential` found.
///
/// These are the *premultiplied* equations, on 8-bit channels, and they are
/// written to agree term for term with the fixed-function factors
/// `gpu_pipeline.dart` hands OpenGL for the same mode. That correspondence is
/// the whole point: a layer composited on the CPU and the same layer
/// composited by a driver have to land on the same byte, and they only can if
/// both sides start from the same equation.
enum CpuBlendMode {
  /// `dst = src + dst * (1 - srcAlpha)`. GL: `ONE, ONE_MINUS_SRC_ALPHA`.
  srcOver(skipsTransparentSource: true),

  /// `dst = src`, alpha included - a replace, not a draw. GL: `ONE, ZERO`.
  src(skipsTransparentSource: true),

  /// `dst = min(255, src + dst)` per channel. GL: `ONE, ONE`, whose fixed
  /// function clamps to [0, 1] in exactly the same place.
  plus(skipsTransparentSource: true),

  /// `dst = src * dstAlpha`. GL: `DST_ALPHA, ZERO`.
  srcIn(skipsTransparentSource: false),

  /// `dst = dst * srcAlpha`. GL: `ZERO, SRC_ALPHA`.
  dstIn(skipsTransparentSource: false),

  /// `dst = dst * (1 - srcAlpha)`. GL: `ZERO, ONE_MINUS_SRC_ALPHA`.
  dstOut(skipsTransparentSource: true);

  const CpuBlendMode({required this.skipsTransparentSource});

  /// Whether a source whose (coverage-scaled) alpha is zero may be skipped
  /// rather than composited.
  ///
  /// The CPU mirror of `blendModeWritesTransparentSource`, as a field so the
  /// span loops read a bool rather than re-deriving it from the wire value.
  /// True for the modes where a transparent source is an identity, and for
  /// [src], where skipping is the framework's stated choice; false for the two
  /// "in" modes, where a transparent source erases.
  final bool skipsTransparentSource;
}

/// The equation one of the display list's `blendMode*` constants means here.
///
/// Throws rather than falling back to source-over, mirroring
/// `gpuBlendForMode`. A blend mode that quietly becomes source-over draws a
/// picture that is wrong in a way that looks like a paint bug, and a mode the
/// two backends resolve differently is precisely what a differential test can
/// no longer detect once one of them has a silent default.
CpuBlendMode cpuBlendForMode(int blendMode) => switch (blendMode) {
      blendModeSrcOver => CpuBlendMode.srcOver,
      blendModeSrc => CpuBlendMode.src,
      blendModePlus => CpuBlendMode.plus,
      blendModeSrcIn => CpuBlendMode.srcIn,
      blendModeDstIn => CpuBlendMode.dstIn,
      blendModeDstOut => CpuBlendMode.dstOut,
      _ => throw ArgumentError.value(
          blendMode,
          'blendMode',
          'no CPU blend equation; the display list encodes only srcOver, src, '
              'plus, srcIn, dstIn and dstOut, and a new mode must be given an '
              'equation here rather than falling back to srcOver',
        ),
    };

/// Saturating 8-bit addition, the arithmetic [CpuBlendMode.plus] is defined by.
///
/// The clamp is not a defensive check: `plus` on two opaque whites really does
/// overflow, and GL's fixed-function blend clamps the same sum to 1.0 before
/// it is quantised back to a byte. Wrapping instead - which a bare
/// `Uint8List` store would do - turns a bright overlap into a black one.
@pragma('vm:prefer-inline')
int addSaturating(int a, int b) {
  final sum = a + b;
  return sum > 255 ? 255 : sum;
}
