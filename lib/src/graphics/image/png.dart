/// A PNG decoder in pure Dart, written for bytes nobody vouched for.
///
/// ## What is implemented
///
/// All five colour types, at bit depths **1, 2, 4 and 8**: greyscale (0),
/// truecolour (2), indexed with `PLTE` (3), greyscale with alpha (4) and
/// truecolour with alpha (6). All five per-scanline filters - None, Sub, Up,
/// Average and Paeth. Both interlace methods: the ordinary one and **Adam7**,
/// whose seven passes are reassembled into the final raster. `tRNS` is honoured
/// for all three colour types that may carry it, so a single-colour
/// transparency and a palette's alpha both work.
///
/// ## What is declared absent, by name
///
///   * **16 bits per sample.** Legal for colour types 0, 2, 4 and 6, and
///     refused with [PngUnsupportedException] rather than truncated to 8.
///     Rounding it silently would be almost invisible and therefore worse than
///     failing: a wide-gamut source would come out subtly banded with nothing
///     to point at. The output type here is 8 bits per channel, so honouring
///     16 would mean either a second pixel format through the whole renderer or
///     a documented downsample, and neither is this file's decision to take;
///   * **`gAMA`, `sRGB`, `iCCP`, `cHRM` - colour management of every kind.**
///     Samples are used as written. An image with a non-sRGB profile draws with
///     the wrong colours, and this sentence is the only warning of it. These
///     are ancillary chunks, so they are skipped rather than refused;
///   * **APNG** (`acTL`/`fcTL`/`fdAT`). Ancillary, so an animated PNG decodes
///     as its first frame - which is what the base `IDAT` is defined to hold,
///     and is why this is a limitation rather than a failure;
///   * **progressive/streaming decode.** The whole file is required up front.
///
/// Any *critical* chunk this decoder does not know - an uppercase first letter,
/// which is the format's own way of saying "you may not skip me" - is refused
/// with [PngUnsupportedException] instead of being ignored.
///
/// ## Untrusted input, in the terms of section 38.2
///
/// This and the font parser are the only code in the framework that reads bytes
/// from outside it. Each of the following has a test that names the exception:
///
///   * **absurd dimensions** - `IHDR` may declare up to 2^31-1 on each axis,
///     which is a 16-exabyte allocation. [PngLimits.maxDimension] and
///     [PngLimits.maxPixels] refuse it before anything is allocated;
///   * **`IHDR` lying about the size** - a header that declares a large image
///     over an `IDAT` holding one row. The declaration decides the output size
///     and the decompressed stream is then required to be exactly as long as
///     the declaration implies, so the mismatch is [PngDataException] and never
///     a half-filled buffer of uninitialised memory;
///   * **a wrong CRC** - every chunk's CRC-32 is checked before its contents
///     are used for anything, including for deciding where the next chunk
///     starts;
///   * **truncation inside a chunk** - the length is compared against what is
///     left of the file before a single byte is read, so a cut-off download is
///     [PngTruncatedException] and never a range error thrown from inside a
///     loop;
///   * **a decompression bomb** - the inflater is handed a hard ceiling, the
///     lower of `IHDR`'s exact requirement and [PngLimits.maxDecompressedBytes],
///     and stops at it. There is no path that grows a buffer until it fits.
///
/// The parser allocates nothing whose size is taken from the file until that
/// size has been checked against a limit, and it contains no unbounded loop:
/// the chunk walk advances by at least twelve bytes each iteration.
library;

import 'dart:typed_data';

import 'decoded_image.dart';
import 'image_errors.dart';
import 'inflate.dart';

/// The eight bytes every PNG starts with.
///
/// Chosen by the format to catch the ways a file gets damaged in transit: a
/// high bit to detect a 7-bit channel, `PNG` in ASCII, and a CRLF/LF pair that
/// a text-mode transfer would rewrite.
const List<int> kPngSignature = <int>[137, 80, 78, 71, 13, 10, 26, 10];

/// The ceilings a decode runs under.
///
/// Defaults are sized for a user interface - a 4096x4096 texture is already
/// larger than any icon, avatar or background a desktop application has reason
/// to load - and an application that really does open photographs raises them
/// explicitly. The point is that there is always a number, and that the number
/// is the caller's.
final class PngLimits {
  const PngLimits({
    this.maxDimension = 16384,
    this.maxPixels = 16777216,
    this.maxDecompressedBytes = 134217728,
  });

  /// Largest width or height, in pixels. Checked first because it is the
  /// cheapest and because it bounds every product computed after it.
  final int maxDimension;

  /// Largest `width * height`. Separate from [maxDimension] because
  /// 16384x16384 passes that check and is a gigabyte of output.
  final int maxPixels;

  /// Absolute ceiling on the inflated `IDAT` bytes.
  ///
  /// The effective ceiling is the lower of this and the exact number of bytes
  /// `IHDR` implies, so a well-formed file never comes near it and a bomb is
  /// stopped by whichever is smaller.
  ///
  /// The default is deliberately above what [maxPixels] can require - 16.7
  /// megapixels of RGBA is 67 MB of filtered scanlines - so that an image
  /// admitted by the other two limits is never then refused by this one. A
  /// caller that lowers [maxPixels] should lower this with it.
  final int maxDecompressedBytes;

  /// The output buffer a decode of [width] by [height] will allocate.
  static int outputBytesFor(int width, int height) => width * height * 4;
}

/// The five colour types, with the sample layout each implies.
enum PngColorType {
  greyscale(0, 1),
  truecolour(2, 3),
  indexed(3, 1),
  greyscaleAlpha(4, 2),
  truecolourAlpha(6, 4);

  const PngColorType(this.code, this.channels);

  /// The value stored in `IHDR`.
  final int code;

  /// How many samples each pixel carries in the raw stream.
  final int channels;

  static PngColorType? fromCode(int code) {
    for (final PngColorType type in values) {
      if (type.code == code) return type;
    }
    return null;
  }

  /// The bit depths the specification allows for this colour type.
  List<int> get allowedBitDepths => switch (this) {
        PngColorType.greyscale => const <int>[1, 2, 4, 8, 16],
        PngColorType.indexed => const <int>[1, 2, 4, 8],
        _ => const <int>[8, 16],
      };
}

/// `IHDR`, validated.
final class PngHeader {
  const PngHeader({
    required this.width,
    required this.height,
    required this.bitDepth,
    required this.colorType,
    required this.interlaced,
  });

  final int width;
  final int height;
  final int bitDepth;
  final PngColorType colorType;

  /// Adam7. The seven-pass layout, not a different pixel format.
  final bool interlaced;

  /// Bytes a whole-pixel step covers when filtering, never less than one.
  ///
  /// Below 8 bits per sample a pixel is smaller than a byte, and the format
  /// says the Sub and Paeth filters then operate on **bytes** one apart - so
  /// this is the filter's stride, not the pixel's size.
  int get filterStride {
    final int bits = colorType.channels * bitDepth;
    return bits < 8 ? 1 : bits ~/ 8;
  }

  /// Bytes in one unfiltered scanline of [pixelWidth] pixels, rounded up.
  int rowBytes(int pixelWidth) =>
      (pixelWidth * colorType.channels * bitDepth + 7) ~/ 8;

  @override
  String toString() => 'PngHeader(${width}x$height, ${colorType.name}, '
      '$bitDepth-bit${interlaced ? ', Adam7' : ''})';
}

/// Reads and validates `IHDR` without decompressing anything.
///
/// Useful on its own: a caller deciding whether to load an image at all wants
/// its dimensions, and paying for the pixels to find them out is exactly the
/// allocation the limits exist to avoid.
PngHeader readPngHeader(
  Uint8List bytes, {
  PngLimits limits = const PngLimits(),
}) =>
    _Reader(bytes, limits).header();

/// Decodes [bytes] into premultiplied pixels in [order].
///
/// Throws a subclass of [ImageDecodeException] - never null, and never a
/// partially filled image. See the library comment for which subclass means
/// what.
DecodedImage decodePng(
  Uint8List bytes, {
  ImageChannelOrder order = ImageChannelOrder.bgra,
  PngLimits limits = const PngLimits(),
}) =>
    _Reader(bytes, limits).decode(order);

/// Whether [bytes] begins with the PNG signature.
///
/// A sniff, for a caller choosing a decoder. It is not validation: a file may
/// start with these eight bytes and be rubbish after them.
bool isPng(Uint8List bytes) {
  if (bytes.length < kPngSignature.length) return false;
  for (int i = 0; i < kPngSignature.length; i++) {
    if (bytes[i] != kPngSignature[i]) return false;
  }
  return true;
}

// ---------------------------------------------------------------------------
// The parser
// ---------------------------------------------------------------------------

final class _Reader {
  _Reader(this.bytes, this.limits);

  final Uint8List bytes;
  final PngLimits limits;

  PngHeader? _header;
  Uint8List? _palette;
  Uint8List? _paletteAlpha;
  List<int>? _transparentSample;

  /// The `IDAT` payloads, in order. Held as views rather than copied so that a
  /// large image is not duplicated before it is inflated.
  final List<Uint8List> _idat = <Uint8List>[];
  int _idatLength = 0;
  bool _idatClosed = false;
  bool _sawEnd = false;

  PngHeader header() {
    _walk(stopAfterHeader: true);
    return _header!;
  }

  DecodedImage decode(ImageChannelOrder order) {
    _walk(stopAfterHeader: false);
    final PngHeader header = _header!;
    if (_idatLength == 0) {
      throw const PngDataException(
        'the file has no IDAT chunk, so it declares an image and carries no '
        'pixels for it',
      );
    }
    if (header.colorType == PngColorType.indexed && _palette == null) {
      throw const PngDataException(
        'colour type 3 is indexed and the file has no PLTE chunk, so its '
        'samples index a palette that does not exist',
      );
    }

    final int expected = _expectedRawBytes(header);
    // The lower of the two ceilings binds, and the name of the one that binds
    // is what the exception reports - so "the file is bigger than we allow" and
    // "the file expands past what its own header promised" stay distinguishable.
    final bool headerBinds = expected <= limits.maxDecompressedBytes;
    final Uint8List raw = inflateZlib(
      _joinIdat(),
      maxOutputBytes: headerBinds ? expected : limits.maxDecompressedBytes,
      budget: headerBinds ? 'idatRawBytes' : 'maxDecompressedBytes',
    );
    if (raw.length != expected) {
      throw PngDataException(
        'IHDR declares ${header.width}x${header.height} at ${header.bitDepth} '
        'bits, which needs $expected filtered bytes, but IDAT expands to '
        '${raw.length}',
      );
    }

    final Uint8List out =
        Uint8List(PngLimits.outputBytesFor(header.width, header.height));
    final _Surface surface = _Surface(
      header: header,
      order: order,
      out: out,
      palette: _palette,
      paletteAlpha: _paletteAlpha,
      transparentSample: _transparentSample,
    );
    if (header.interlaced) {
      _readAdam7(header, raw, surface);
    } else {
      _readPasses(
        header,
        raw,
        surface,
        offset: 0,
        pixelWidth: header.width,
        rowCount: header.height,
        xOrigin: 0,
        xStep: 1,
        yOrigin: 0,
        yStep: 1,
      );
    }

    return DecodedImage(
      width: header.width,
      height: header.height,
      order: order,
      pixels: out,
      hasAlpha: header.colorType == PngColorType.greyscaleAlpha ||
          header.colorType == PngColorType.truecolourAlpha ||
          _paletteAlpha != null ||
          _transparentSample != null,
    );
  }

  // --- chunk walk ----------------------------------------------------------

  void _walk({required bool stopAfterHeader}) {
    if (bytes.length < kPngSignature.length) {
      throw PngSignatureException(
        'the file is ${bytes.length} bytes, shorter than the eight-byte PNG '
        'signature',
      );
    }
    for (int i = 0; i < kPngSignature.length; i++) {
      if (bytes[i] != kPngSignature[i]) {
        throw PngSignatureException(
          'byte $i is 0x${bytes[i].toRadixString(16)} where the PNG signature '
          'has 0x${kPngSignature[i].toRadixString(16)}; this is not a PNG',
        );
      }
    }

    int offset = kPngSignature.length;
    while (!_sawEnd) {
      // Length and type, then the payload, then the CRC: twelve bytes of
      // overhead, which is also the minimum this loop advances by.
      if (offset + 8 > bytes.length) {
        throw PngTruncatedException(
          'the file ends after $offset bytes, inside a chunk header',
        );
      }
      final int length = _u32(offset);
      if (length > 0x7FFFFFFF) {
        throw PngHeaderException(
          'a chunk declares a length of $length; PNG caps a chunk at '
          '2147483647 bytes',
        );
      }
      final String type = _type(offset + 4);
      if (offset + 12 + length > bytes.length) {
        throw PngTruncatedException(
          'chunk "$type" declares $length bytes at offset $offset, which runs '
          'past the end of the ${bytes.length}-byte file',
        );
      }

      final int declaredCrc = _u32(offset + 8 + length);
      final int actualCrc = _crc32(bytes, offset + 4, 4 + length);
      if (declaredCrc != actualCrc) {
        throw PngChecksumException(
          'chunk "$type" carries CRC-32 0x${declaredCrc.toRadixString(16)} but '
          'its bytes hash to 0x${actualCrc.toRadixString(16)}',
        );
      }

      final int start = offset + 8;
      _chunk(type, start, length);
      if (stopAfterHeader && _header != null) return;
      offset += 12 + length;
    }
  }

  void _chunk(String type, int start, int length) {
    if (_header == null && type != 'IHDR') {
      throw PngHeaderException(
        'the first chunk is "$type"; PNG requires IHDR to come first',
      );
    }
    switch (type) {
      case 'IHDR':
        if (_header != null) {
          throw const PngHeaderException('the file has more than one IHDR');
        }
        _readHeader(start, length);
      case 'PLTE':
        _readPalette(start, length);
      case 'tRNS':
        _readTransparency(start, length);
      case 'IDAT':
        if (_idatClosed) {
          throw const PngDataException(
            'an IDAT chunk follows a non-IDAT chunk; PNG requires the IDAT '
            'chunks to be consecutive',
          );
        }
        _idat.add(Uint8List.sublistView(bytes, start, start + length));
        _idatLength += length;
      case 'IEND':
        if (length != 0) {
          throw PngDataException(
              'IEND carries $length bytes; it must be empty');
        }
        _sawEnd = true;
      default:
        // Bit 5 of the first byte is the format's own "you may skip me" flag:
        // clear (uppercase) means critical. Skipping a critical chunk we do not
        // understand would produce an image whose meaning we cannot vouch for.
        final int first = type.codeUnitAt(0);
        if (first >= 0x41 && first <= 0x5A) {
          throw PngUnsupportedException(
            'critical chunk "$type" is not one this decoder implements, and a '
            'critical chunk may not be skipped',
          );
        }
    }
    if (type != 'IDAT' && type != 'IHDR' && _idat.isNotEmpty) {
      _idatClosed = true;
    }
  }

  void _readHeader(int start, int length) {
    if (length != 13) {
      throw PngHeaderException('IHDR carries $length bytes; it must carry 13');
    }
    final int width = _u32(start);
    final int height = _u32(start + 4);
    final int bitDepth = bytes[start + 8];
    final int colorTypeCode = bytes[start + 9];
    final int compression = bytes[start + 10];
    final int filter = bytes[start + 11];
    final int interlace = bytes[start + 12];

    if (width == 0 || height == 0) {
      throw PngHeaderException(
        'IHDR declares ${width}x$height; a PNG has at least one pixel on each '
        'axis',
      );
    }
    if (width > 0x7FFFFFFF || height > 0x7FFFFFFF) {
      throw PngHeaderException(
        'IHDR declares ${width}x$height; PNG caps each axis at 2147483647',
      );
    }
    // Both limits are checked here, before the palette, before the IDAT is
    // gathered, and above all before anything is sized from these numbers.
    if (width > limits.maxDimension || height > limits.maxDimension) {
      throw ImageBudgetException(
        budget: 'maxDimension',
        limit: limits.maxDimension,
        actual: width > height ? width : height,
        message: 'IHDR declares ${width}x$height and the limit is '
            '${limits.maxDimension} pixels on an axis',
      );
    }
    if (width * height > limits.maxPixels) {
      throw ImageBudgetException(
        budget: 'maxPixels',
        limit: limits.maxPixels,
        actual: width * height,
        message: 'IHDR declares ${width}x$height, which is ${width * height} '
            'pixels and would allocate '
            '${PngLimits.outputBytesFor(width, height)} bytes of output',
      );
    }

    final PngColorType? colorType = PngColorType.fromCode(colorTypeCode);
    if (colorType == null) {
      throw PngHeaderException(
        'IHDR declares colour type $colorTypeCode; PNG defines 0, 2, 3, 4 '
        'and 6',
      );
    }
    if (!colorType.allowedBitDepths.contains(bitDepth)) {
      throw PngHeaderException(
        'IHDR pairs colour type $colorTypeCode (${colorType.name}) with a bit '
        'depth of $bitDepth; that type allows '
        '${colorType.allowedBitDepths.join(", ")}',
      );
    }
    if (bitDepth == 16) {
      throw const PngUnsupportedException(
        'this image is 16 bits per sample, which this decoder does not '
        'implement; its output is 8 bits per channel and truncating would be '
        'a silent loss of precision',
      );
    }
    if (compression != 0) {
      throw PngHeaderException(
        'IHDR declares compression method $compression; PNG defines only 0 '
        '(zlib/DEFLATE)',
      );
    }
    if (filter != 0) {
      throw PngHeaderException(
        'IHDR declares filter method $filter; PNG defines only 0 (the five '
        'adaptive per-scanline filters)',
      );
    }
    if (interlace > 1) {
      throw PngHeaderException(
        'IHDR declares interlace method $interlace; PNG defines 0 (none) and '
        '1 (Adam7)',
      );
    }

    _header = PngHeader(
      width: width,
      height: height,
      bitDepth: bitDepth,
      colorType: colorType,
      interlaced: interlace == 1,
    );
  }

  void _readPalette(int start, int length) {
    if (length % 3 != 0) {
      throw PngDataException(
        'PLTE carries $length bytes, which is not a whole number of '
        'three-byte entries',
      );
    }
    if (length > 256 * 3) {
      throw PngDataException(
        'PLTE carries ${length ~/ 3} entries; a palette holds at most 256',
      );
    }
    _palette = Uint8List.sublistView(bytes, start, start + length);
  }

  void _readTransparency(int start, int length) {
    final PngHeader header = _header!;
    switch (header.colorType) {
      case PngColorType.indexed:
        final Uint8List? palette = _palette;
        if (palette == null) {
          throw const PngDataException(
            'tRNS precedes PLTE; an indexed image\'s transparency is per '
            'palette entry, so the palette has to come first',
          );
        }
        if (length > palette.length ~/ 3) {
          throw PngDataException(
            'tRNS carries $length alpha values for a palette of '
            '${palette.length ~/ 3} entries',
          );
        }
        // Entries the chunk does not reach are opaque, which is the format's
        // rule and is why this is filled rather than sized to `length`.
        final Uint8List alpha = Uint8List(palette.length ~/ 3)
          ..fillRange(0, palette.length ~/ 3, 255);
        alpha.setRange(0, length, bytes, start);
        _paletteAlpha = alpha;
      case PngColorType.greyscale:
        if (length != 2) {
          throw PngDataException(
            'tRNS on a greyscale image carries $length bytes; it must carry a '
            'single two-byte sample',
          );
        }
        _transparentSample = <int>[bytes[start] << 8 | bytes[start + 1]];
      case PngColorType.truecolour:
        if (length != 6) {
          throw PngDataException(
            'tRNS on a truecolour image carries $length bytes; it must carry '
            'three two-byte samples',
          );
        }
        _transparentSample = <int>[
          bytes[start] << 8 | bytes[start + 1],
          bytes[start + 2] << 8 | bytes[start + 3],
          bytes[start + 4] << 8 | bytes[start + 5],
        ];
      case PngColorType.greyscaleAlpha:
      case PngColorType.truecolourAlpha:
        throw PngDataException(
          'tRNS is present on colour type ${header.colorType.code}, which '
          'already carries a full alpha channel',
        );
    }
  }

  Uint8List _joinIdat() {
    if (_idat.length == 1) return _idat.first;
    final Uint8List joined = Uint8List(_idatLength);
    int offset = 0;
    for (final Uint8List part in _idat) {
      joined.setRange(offset, offset + part.length, part);
      offset += part.length;
    }
    return joined;
  }

  /// Exactly how many bytes the decompressed stream must hold.
  ///
  /// One filter byte plus a rounded-up scanline per row, summed over the
  /// interlace passes when there are any. Computed from `IHDR` alone, which is
  /// what makes it usable as the inflater's ceiling: the file cannot influence
  /// it except through numbers already checked against the limits.
  int _expectedRawBytes(PngHeader header) {
    if (!header.interlaced) {
      return header.height * (1 + header.rowBytes(header.width));
    }
    int total = 0;
    for (int pass = 0; pass < 7; pass++) {
      final int pixelWidth = _passWidth(header.width, pass);
      final int rowCount = _passHeight(header.height, pass);
      if (pixelWidth == 0 || rowCount == 0) continue;
      total += rowCount * (1 + header.rowBytes(pixelWidth));
    }
    return total;
  }

  // --- filtering and interlace --------------------------------------------

  void _readAdam7(PngHeader header, Uint8List raw, _Surface surface) {
    int offset = 0;
    for (int pass = 0; pass < 7; pass++) {
      final int pixelWidth = _passWidth(header.width, pass);
      final int rowCount = _passHeight(header.height, pass);
      if (pixelWidth == 0 || rowCount == 0) continue;
      offset = _readPasses(
        header,
        raw,
        surface,
        offset: offset,
        pixelWidth: pixelWidth,
        rowCount: rowCount,
        xOrigin: _adam7XOrigin[pass],
        xStep: _adam7XStep[pass],
        yOrigin: _adam7YOrigin[pass],
        yStep: _adam7YStep[pass],
      );
    }
  }

  /// Unfilters [rowCount] scanlines and writes them into [surface].
  ///
  /// Returns where in [raw] the next pass starts. One routine for both the
  /// ordinary and the interlaced case, because the only differences are the
  /// scanline width and where each row's pixels land - and having two copies of
  /// the Paeth predictor is how the two stop agreeing.
  int _readPasses(
    PngHeader header,
    Uint8List raw,
    _Surface surface, {
    required int offset,
    required int pixelWidth,
    required int rowCount,
    required int xOrigin,
    required int xStep,
    required int yOrigin,
    required int yStep,
  }) {
    final int rowBytes = header.rowBytes(pixelWidth);
    final int stride = header.filterStride;
    // The Up, Average and Paeth filters read the row above. The first row's
    // "row above" is defined to be zeroes, which this buffer starts as and
    // which is why it is allocated rather than aliased.
    Uint8List previous = Uint8List(rowBytes);
    Uint8List current = Uint8List(rowBytes);

    for (int row = 0; row < rowCount; row++) {
      final int filter = raw[offset++];
      current.setRange(0, rowBytes, raw, offset);
      offset += rowBytes;
      _unfilter(filter, current, previous, stride, rowBytes);
      surface.writeRow(
        current,
        pixelWidth: pixelWidth,
        y: yOrigin + row * yStep,
        xOrigin: xOrigin,
        xStep: xStep,
      );
      // Swap rather than copy: the row just produced is the next row's
      // predictor, and the buffer it displaces is about to be overwritten.
      final Uint8List swap = previous;
      previous = current;
      current = swap;
    }
    return offset;
  }

  /// Reverses one scanline filter in place.
  ///
  /// The five are RFC 2083's, and each is written as the specification writes
  /// it - reconstruct(x) = filtered(x) + predictor - so that the Average
  /// filter's floor division and Paeth's tie-breaking are visibly the ones the
  /// format defines. Both are places an "obvious" rewrite is subtly wrong: the
  /// average truncates rather than rounds, and Paeth prefers `a` on a tie
  /// between `a` and `b`.
  void _unfilter(
    int filter,
    Uint8List row,
    Uint8List above,
    int stride,
    int length,
  ) {
    switch (filter) {
      case 0: // None
        return;
      case 1: // Sub
        for (int i = stride; i < length; i++) {
          row[i] = (row[i] + row[i - stride]) & 0xFF;
        }
      case 2: // Up
        for (int i = 0; i < length; i++) {
          row[i] = (row[i] + above[i]) & 0xFF;
        }
      case 3: // Average
        for (int i = 0; i < stride; i++) {
          row[i] = (row[i] + (above[i] >> 1)) & 0xFF;
        }
        for (int i = stride; i < length; i++) {
          row[i] = (row[i] + ((row[i - stride] + above[i]) >> 1)) & 0xFF;
        }
      case 4: // Paeth
        for (int i = 0; i < stride; i++) {
          row[i] = (row[i] + above[i]) & 0xFF;
        }
        for (int i = stride; i < length; i++) {
          row[i] =
              (row[i] + _paeth(row[i - stride], above[i], above[i - stride])) &
                  0xFF;
        }
      default:
        throw PngFilterException(
          'a scanline declares filter type $filter; PNG defines 0 (None), '
          '1 (Sub), 2 (Up), 3 (Average) and 4 (Paeth)',
        );
    }
  }

  /// The Paeth predictor: whichever of left, above and upper-left is closest to
  /// `a + b - c`, preferring left, then above, on a tie.
  static int _paeth(int a, int b, int c) {
    final int p = a + b - c;
    final int pa = (p - a).abs();
    final int pb = (p - b).abs();
    final int pc = (p - c).abs();
    if (pa <= pb && pa <= pc) return a;
    if (pb <= pc) return b;
    return c;
  }

  // --- byte helpers --------------------------------------------------------

  int _u32(int offset) =>
      bytes[offset] << 24 |
      bytes[offset + 1] << 16 |
      bytes[offset + 2] << 8 |
      bytes[offset + 3];

  String _type(int offset) {
    final StringBuffer out = StringBuffer();
    for (int i = 0; i < 4; i++) {
      final int unit = bytes[offset + i];
      final bool letter =
          (unit >= 0x41 && unit <= 0x5A) || (unit >= 0x61 && unit <= 0x7A);
      if (!letter) {
        throw PngDataException(
          'a chunk type at offset $offset is not four ASCII letters '
          '(byte $i is 0x${unit.toRadixString(16)})',
        );
      }
      out.writeCharCode(unit);
    }
    return out.toString();
  }
}

/// Turns unfiltered scanlines into premultiplied output pixels.
///
/// Separated from the parser because this is where the *colour* decisions live
/// - palette lookup, `tRNS` matching, sub-byte sample expansion and
/// premultiplication - and none of them depend on how the bytes arrived.
final class _Surface {
  _Surface({
    required this.header,
    required this.order,
    required this.out,
    required this.palette,
    required this.paletteAlpha,
    required this.transparentSample,
  })  : redIndex = order.redIndex,
        blueIndex = order.blueIndex,
        // A sample of depth d spans 0..2^d-1 and has to reach 0..255 with both
        // ends exact, which is what multiplying by 255/(2^d-1) does: depth 1
        // maps 1 to 255, depth 2 maps 3 to 255, depth 4 maps 15 to 255. This
        // is bit replication written as a multiply.
        sampleScale = header.colorType == PngColorType.indexed
            ? 1
            : 255 ~/ ((1 << header.bitDepth) - 1);

  final PngHeader header;
  final ImageChannelOrder order;
  final Uint8List out;
  final Uint8List? palette;
  final Uint8List? paletteAlpha;
  final List<int>? transparentSample;
  final int redIndex;
  final int blueIndex;
  final int sampleScale;

  void writeRow(
    Uint8List row, {
    required int pixelWidth,
    required int y,
    required int xOrigin,
    required int xStep,
  }) {
    final int depth = header.bitDepth;
    final int channels = header.colorType.channels;
    final int rowBase = y * header.width;
    final int mask = (1 << depth) - 1;

    for (int i = 0; i < pixelWidth; i++) {
      int red = 0;
      int green = 0;
      int blue = 0;
      int alpha = 255;

      if (depth == 8) {
        final int base = i * channels;
        switch (header.colorType) {
          case PngColorType.greyscale:
            red = green = blue = row[base];
            alpha = _greyAlpha(row[base]);
          case PngColorType.truecolour:
            red = row[base];
            green = row[base + 1];
            blue = row[base + 2];
            alpha = _rgbAlpha(red, green, blue);
          case PngColorType.indexed:
            (red, green, blue, alpha) = _paletteEntry(row[base]);
          case PngColorType.greyscaleAlpha:
            red = green = blue = row[base];
            alpha = row[base + 1];
          case PngColorType.truecolourAlpha:
            red = row[base];
            green = row[base + 1];
            blue = row[base + 2];
            alpha = row[base + 3];
        }
      } else {
        // One sample per pixel is the only shape the sub-byte depths allow:
        // colour types 2, 4 and 6 require eight bits, and 3 and 0 carry a
        // single sample. So the bit address is just `i * depth`.
        final int bit = i * depth;
        final int sample = row[bit >> 3] >> (8 - depth - (bit & 7)) & mask;
        if (header.colorType == PngColorType.indexed) {
          (red, green, blue, alpha) = _paletteEntry(sample);
        } else {
          final int value = sample * sampleScale;
          red = green = blue = value;
          alpha = _greyAlpha(sample);
        }
      }

      final int offset = (rowBase + xOrigin + i * xStep) * 4;
      // Premultiplied here and nowhere else. See `decoded_image.dart` for why
      // this is the only affordable place to do it.
      out[offset + redIndex] = premultiplyChannel(red, alpha);
      out[offset + 1] = premultiplyChannel(green, alpha);
      out[offset + blueIndex] = premultiplyChannel(blue, alpha);
      out[offset + 3] = alpha;
    }
  }

  /// `tRNS` on a greyscale image names one **raw** sample value, at the image's
  /// own bit depth, not the scaled 8-bit one - so the comparison happens before
  /// the scale is applied.
  int _greyAlpha(int rawSample) {
    final List<int>? key = transparentSample;
    if (key == null) return 255;
    return key[0] == rawSample ? 0 : 255;
  }

  int _rgbAlpha(int red, int green, int blue) {
    final List<int>? key = transparentSample;
    if (key == null) return 255;
    return key[0] == red && key[1] == green && key[2] == blue ? 0 : 255;
  }

  (int, int, int, int) _paletteEntry(int index) {
    final Uint8List entries = palette!;
    if (index * 3 + 2 >= entries.length) {
      throw PngDataException(
        'a pixel indexes palette entry $index and PLTE has '
        '${entries.length ~/ 3}',
      );
    }
    return (
      entries[index * 3],
      entries[index * 3 + 1],
      entries[index * 3 + 2],
      paletteAlpha?[index] ?? 255,
    );
  }
}

// ---------------------------------------------------------------------------
// Adam7
// ---------------------------------------------------------------------------

/// Where each of the seven passes starts and how far it steps.
///
/// The layout is a fixed 8x8 tile: pass 0 is one pixel in sixty-four, and each
/// pass afterwards fills in half the remaining grid, which is what lets a
/// progressive viewer show a whole blurry image from the first pass alone.
const List<int> _adam7XOrigin = <int>[0, 4, 0, 2, 0, 1, 0];
const List<int> _adam7YOrigin = <int>[0, 0, 4, 0, 2, 0, 1];
const List<int> _adam7XStep = <int>[8, 8, 4, 4, 2, 2, 1];
const List<int> _adam7YStep = <int>[8, 8, 8, 4, 4, 2, 2];

int _passWidth(int width, int pass) =>
    (width - _adam7XOrigin[pass] + _adam7XStep[pass] - 1) ~/ _adam7XStep[pass];

int _passHeight(int height, int pass) =>
    (height - _adam7YOrigin[pass] + _adam7YStep[pass] - 1) ~/ _adam7YStep[pass];

// ---------------------------------------------------------------------------
// CRC-32
// ---------------------------------------------------------------------------

/// The IEEE CRC-32 table, built once on first use.
///
/// Lazily rather than as a `const` list of 256 literals because the polynomial
/// is the specification and the table is a derivation of it; writing the table
/// out would put 256 numbers in the source that nobody can check by eye.
final Uint32List _crcTable = _buildCrcTable();

Uint32List _buildCrcTable() {
  final Uint32List table = Uint32List(256);
  for (int n = 0; n < 256; n++) {
    int c = n;
    for (int k = 0; k < 8; k++) {
      c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
    }
    table[n] = c;
  }
  return table;
}

/// CRC-32 over `data[start..start+length)`, as PNG computes it: over the chunk
/// type **and** its data, never over the length.
int _crc32(Uint8List data, int start, int length) {
  int c = 0xFFFFFFFF;
  for (int i = 0; i < length; i++) {
    c = _crcTable[(c ^ data[start + i]) & 0xFF] ^ (c >> 8);
  }
  return (c ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}
