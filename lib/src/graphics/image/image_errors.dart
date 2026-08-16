/// Why a decode refused - one class per reason, never a boolean.
///
/// ## The rule this file exists to keep
///
/// An image is the second thing in this framework parsed from bytes somebody
/// else wrote (the font parser is the first), and section 38.2 treats such
/// bytes as hostile by default. A hostile file is not a file that is merely
/// wrong: it is a file written to make the decoder allocate, loop, or read
/// past the end of what it was given.
///
/// So every refusal here is a **named type**, and the name says which check
/// caught it. That is not decoration. "the image failed to load" gives a
/// caller nothing to act on and gives a bug report nothing to reproduce from,
/// while [PngChecksumException] versus [PngTruncatedException] is the
/// difference between "the bytes were corrupted in transit" and "the download
/// stopped early" - two different fixes, decided by the decoder, which is the
/// only place that knows.
///
/// A caller that genuinely wants "did it load" catches [ImageDecodeException],
/// which is sealed: the exhaustive `switch` over these classes is checked by
/// the analyser, so a new refusal cannot be added without every handler being
/// told about it.
library;

/// The base of every refusal a decoder in this directory may produce.
///
/// Sealed so that a `switch` over the reasons is exhaustive. Nothing outside
/// this library may add a case, which is what makes such a switch safe to
/// write in application code.
sealed class ImageDecodeException implements Exception {
  const ImageDecodeException(this.message);

  /// One sentence, in the terms of the format, saying what was rejected.
  final String message;

  @override
  String toString() => '$runtimeType: $message';
}

/// The first eight bytes are not the PNG signature.
///
/// The cheapest check there is, done before anything is allocated, and the one
/// that catches a JPEG, an HTML error page served in place of an image, and a
/// zero-length file.
final class PngSignatureException extends ImageDecodeException {
  const PngSignatureException(super.message);
}

/// `IHDR` is malformed: a zero dimension, an unknown colour type, a bit depth
/// the colour type does not allow, or a compression/filter/interlace method
/// this version of the format does not define.
///
/// Distinct from [PngUnsupportedException]: this is a header no conforming
/// encoder could have written, not a legal header this decoder declines.
final class PngHeaderException extends ImageDecodeException {
  const PngHeaderException(super.message);
}

/// The file ends inside a chunk - in its header, its payload or its CRC - or
/// ends before `IEND`.
///
/// This is what a download cut short looks like, and it is caught by
/// arithmetic on lengths **before** any read, so a truncated file can never
/// produce a range error from inside the parser.
final class PngTruncatedException extends ImageDecodeException {
  const PngTruncatedException(super.message);
}

/// A chunk's CRC-32 does not match its contents.
///
/// The bytes are not the bytes the encoder wrote. Nothing after this point can
/// be trusted, including the lengths the parser would use to walk the rest of
/// the file, which is why a mismatch stops the decode rather than being
/// recorded and skipped.
final class PngChecksumException extends ImageDecodeException {
  const PngChecksumException(super.message);
}

/// A scanline's filter byte is outside 0..4.
///
/// Its own class rather than a data error because it is the one corruption
/// that appears *after* decompression: every chunk CRC can be correct and the
/// zlib stream can inflate perfectly, and the filter byte still be garbage.
final class PngFilterException extends ImageDecodeException {
  const PngFilterException(super.message);
}

/// The chunks are individually well-formed but do not describe an image.
///
/// The important member of this class is **`IHDR` lying about the size**: a
/// header that declares 4096x4096 over an `IDAT` that expands to one row. The
/// decoder never trusts the declaration - it sizes its output from `IHDR`,
/// which is bounded by [ImageBudgetException]'s limits, and then requires the
/// decompressed stream to be exactly as long as that declaration implies.
///
/// Also: a missing `IDAT`, a missing `PLTE` under colour type 3, a palette
/// index with no entry, a `PLTE` whose length is not a multiple of three, and
/// `IDAT` chunks that are not consecutive.
final class PngDataException extends ImageDecodeException {
  const PngDataException(super.message);
}

/// A legal PNG feature this decoder declares absent, by name.
///
/// The list, in full, is in the library comment of `png.dart`. Reported rather
/// than approximated: a 16-bit-per-sample image rendered as though it were
/// 8-bit would look almost right, and "almost right, silently" is the failure
/// section 6.6 exists to forbid.
final class PngUnsupportedException extends ImageDecodeException {
  const PngUnsupportedException(super.message);
}

/// The zlib/DEFLATE stream inside `IDAT` is malformed.
///
/// Everything RFC 1950 and RFC 1951 can be wrong about: a bad zlib header, a
/// preset dictionary, a reserved block type, a stored block whose length and
/// complement disagree, an incomplete Huffman table, a code that runs past
/// fifteen bits, a back-reference pointing before the start of the output, or
/// a stream that ends before its final block.
///
/// A bad Adler-32 lands here too rather than in [PngChecksumException],
/// because it is the *zlib* stream's checksum and the inflater is what owns
/// it; the PNG layer only ever sees "the compressed data was not valid".
final class InflateException extends ImageDecodeException {
  const InflateException(super.message);
}

/// A declared limit was reached.
///
/// This is the class that makes a decompression bomb an ordinary failure
/// instead of an out-of-memory kill. Every limit is a number written down in
/// `PngLimits` and passed in, so an application that really does open
/// hundred-megapixel scans raises them deliberately rather than discovering
/// there was never a bound.
///
/// [budget] names which one, and it is worth switching on: `maxDimension` and
/// `maxPixels` are refused before a single byte is allocated, while
/// `idatRawBytes` and `maxDecompressedBytes` are refused part way through
/// inflating - so only the last two mean work was already done.
final class ImageBudgetException extends ImageDecodeException {
  const ImageBudgetException({
    required this.budget,
    required this.limit,
    required this.actual,
    required String message,
  }) : super(message);

  /// Which limit: `maxDimension`, `maxPixels`, `idatRawBytes` or
  /// `maxDecompressedBytes`.
  final String budget;

  /// The value the limit was set to.
  final int limit;

  /// What the file asked for. For the two inflate budgets this is the point
  /// the decoder stopped at, not the file's true size - it stops precisely so
  /// that it never has to find that out.
  final int actual;

  @override
  String toString() =>
      'ImageBudgetException($budget: $actual exceeds $limit): $message';
}
