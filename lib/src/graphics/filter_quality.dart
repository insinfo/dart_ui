/// Flutter's `FilterQuality`: how much effort to spend sampling an image that
/// is drawn at another size.
///
/// Accepted wherever Flutter takes it - `Image`, `RawImage`,
/// `AnimatedScale`, `AnimatedRotation` - so ported code compiles. The
/// framework's image path resamples with its own filter whatever the value
/// (see `DecodedImage.resample`), and transforms are composited by the
/// renderer's own sampler. No value changes the pixels yet.
library;

/// Quality levels for image sampling, lowest to highest.
enum FilterQuality {
  /// Nearest neighbour: the fastest, and blocky when enlarged.
  none,

  /// Bilinear.
  low,

  /// Bilinear with mipmaps when shrinking.
  medium,

  /// Bicubic when enlarging, mipmaps when shrinking.
  high,
}
