/// Synthetic PNGs, built byte by byte.
///
/// Every fixture in these tests is constructed here rather than checked in as a
/// file, for three reasons that all matter:
///
///   * **no licence question.** A checked-in PNG comes from somewhere, and
///     "somewhere" has to be recorded and kept true;
///   * **the assertions can be exact.** A three-pixel image whose bytes were
///     chosen in this file can be asserted pixel by pixel, and when the
///     assertion fails the expected value is visible five lines above it;
///   * **the malformed cases are constructible at all.** A PNG with a wrong
///     CRC, a truncated chunk or an `IHDR` that lies about its size cannot be
///     produced by any encoder - that is what makes them the interesting
///     inputs. They exist only if a test builds them.
///
/// The CRC-32 here is written out independently of the decoder's. Two
/// implementations of the same polynomial agreeing is worth something; one
/// implementation agreeing with itself is worth nothing.
library;

import 'dart:io';
import 'dart:typed_data';

const List<int> pngSignature = <int>[137, 80, 78, 71, 13, 10, 26, 10];

/// The five PNG scanline filters, as an encoder applies them.
enum PngFilter { none, sub, up, average, paeth }

/// A PNG assembled from parts, with every part overridable so that a test can
/// break exactly one of them.
Uint8List buildPng({
  required int width,
  required int height,
  required int colorType,
  int bitDepth = 8,
  int interlace = 0,
  int compression = 0,
  int filterMethod = 0,
  List<int>? palette,
  List<int>? transparency,

  /// Filtered scanlines - each row a filter byte followed by its data. Ignored
  /// when [compressedIdat] is given.
  List<int>? filteredRows,

  /// The exact bytes to put in `IDAT`, for the cases where the point is that
  /// they are wrong.
  List<int>? compressedIdat,

  /// Splits `IDAT` across this many chunks, to exercise the join.
  int idatChunks = 1,

  /// Set false for the file that declares an image and carries no pixels.
  bool includeIdat = true,
  bool includeEnd = true,
  List<int>? signature,

  /// Extra chunks inserted after `IHDR`, as `(type, data)` pairs.
  List<(String, List<int>)> extraChunks = const <(String, List<int>)>[],

  /// Corrupts one chunk's CRC by name, which is the only way to produce a
  /// checksum failure.
  String? corruptCrcOf,
}) {
  final BytesBuilder out = BytesBuilder();
  out.add(signature ?? pngSignature);

  final Uint8List header = Uint8List(13);
  _writeU32(header, 0, width);
  _writeU32(header, 4, height);
  header[8] = bitDepth;
  header[9] = colorType;
  header[10] = compression;
  header[11] = filterMethod;
  header[12] = interlace;
  out.add(chunk('IHDR', header, corrupt: corruptCrcOf == 'IHDR'));

  for (final (String type, List<int> data) in extraChunks) {
    out.add(chunk(type, data, corrupt: corruptCrcOf == type));
  }
  if (palette != null) {
    out.add(chunk('PLTE', palette, corrupt: corruptCrcOf == 'PLTE'));
  }
  if (transparency != null) {
    out.add(chunk('tRNS', transparency, corrupt: corruptCrcOf == 'tRNS'));
  }

  if (includeIdat) {
    final List<int> idat = compressedIdat ??
        zlibDeflate(Uint8List.fromList(filteredRows ?? <int>[]));
    final int per = (idat.length / idatChunks).ceil();
    if (idat.isEmpty) {
      out.add(chunk('IDAT', const <int>[]));
    } else {
      for (int i = 0; i < idat.length; i += per) {
        final int end = i + per < idat.length ? i + per : idat.length;
        out.add(
          chunk('IDAT', idat.sublist(i, end), corrupt: corruptCrcOf == 'IDAT'),
        );
      }
    }
  }

  if (includeEnd) {
    out.add(chunk('IEND', const <int>[], corrupt: corruptCrcOf == 'IEND'));
  }
  return out.toBytes();
}

/// One chunk: length, type, data, CRC-32 over type and data.
Uint8List chunk(String type, List<int> data, {bool corrupt = false}) {
  final Uint8List out = Uint8List(12 + data.length);
  _writeU32(out, 0, data.length);
  for (int i = 0; i < 4; i++) {
    out[4 + i] = type.codeUnitAt(i);
  }
  out.setRange(8, 8 + data.length, data);
  final int crc = crc32(out, 4, 4 + data.length);
  _writeU32(out, 8 + data.length, corrupt ? crc ^ 0xFFFF : crc);
  return out;
}

/// Applies [filter] to [row] against [previous], the way an encoder does.
///
/// The inverse of what the decoder runs, so a round trip through both is a
/// genuine test of the filter rather than of one function against itself.
List<int> filterRow(
  PngFilter filter,
  List<int> row,
  List<int> previous,
  int stride,
) {
  final List<int> out = <int>[filter.index];
  for (int i = 0; i < row.length; i++) {
    final int left = i >= stride ? row[i - stride] : 0;
    final int above = previous[i];
    final int upperLeft = i >= stride ? previous[i - stride] : 0;
    final int predictor = switch (filter) {
      PngFilter.none => 0,
      PngFilter.sub => left,
      PngFilter.up => above,
      PngFilter.average => (left + above) >> 1,
      PngFilter.paeth => _paeth(left, above, upperLeft),
    };
    out.add((row[i] - predictor) & 0xFF);
  }
  return out;
}

/// Every row of [rows] filtered with [filter], concatenated.
List<int> filterRows(PngFilter filter, List<List<int>> rows, int stride) {
  final List<int> out = <int>[];
  List<int> previous = List<int>.filled(rows.first.length, 0);
  for (final List<int> row in rows) {
    out.addAll(filterRow(filter, row, previous, stride));
    previous = row;
  }
  return out;
}

/// Rows with no filter at all, which is what most fixtures want.
List<int> unfilteredRows(List<List<int>> rows) =>
    filterRows(PngFilter.none, rows, 1);

const List<int> adam7XOrigin = <int>[0, 4, 0, 2, 0, 1, 0];
const List<int> adam7YOrigin = <int>[0, 0, 4, 0, 2, 0, 1];
const List<int> adam7XStep = <int>[8, 8, 4, 4, 2, 2, 1];
const List<int> adam7YStep = <int>[8, 8, 8, 4, 4, 2, 2];

/// The same pixels, laid out as Adam7's seven passes, filtered with None.
///
/// [rows] are the whole image's unfiltered scanlines at 8 bits per sample, and
/// [bytesPerPixel] says how to cut a pixel out of one. Interlacing is a
/// permutation of pixels and nothing else, so a fixture built this way and the
/// same fixture built flat must decode to identical output - which is exactly
/// what the interlace test asserts.
List<int> adam7Rows(
  int width,
  int height,
  int bytesPerPixel,
  List<List<int>> rows,
) {
  final List<int> out = <int>[];
  for (int pass = 0; pass < 7; pass++) {
    final int passWidth =
        (width - adam7XOrigin[pass] + adam7XStep[pass] - 1) ~/ adam7XStep[pass];
    final int passHeight =
        (height - adam7YOrigin[pass] + adam7YStep[pass] - 1) ~/
            adam7YStep[pass];
    if (passWidth <= 0 || passHeight <= 0) continue;
    for (int r = 0; r < passHeight; r++) {
      final int y = adam7YOrigin[pass] + r * adam7YStep[pass];
      out.add(PngFilter.none.index);
      for (int c = 0; c < passWidth; c++) {
        final int x = adam7XOrigin[pass] + c * adam7XStep[pass];
        for (int b = 0; b < bytesPerPixel; b++) {
          out.add(rows[y][x * bytesPerPixel + b]);
        }
      }
    }
  }
  return out;
}

int _paeth(int a, int b, int c) {
  final int p = a + b - c;
  final int pa = (p - a).abs();
  final int pb = (p - b).abs();
  final int pc = (p - c).abs();
  if (pa <= pb && pa <= pc) return a;
  if (pb <= pc) return b;
  return c;
}

/// Compresses with the platform's zlib.
///
/// Deliberately *not* our own encoder: the point of running the decoder against
/// a real compressor's output is that the fixed and dynamic Huffman blocks it
/// emits are ones nothing in this repository chose. A round trip through code
/// we wrote at both ends would agree with itself no matter what it did.
Uint8List zlibDeflate(Uint8List raw, {int level = 6}) =>
    Uint8List.fromList(ZLibCodec(level: level).encode(raw));

/// A zlib stream of stored (uncompressed) DEFLATE blocks, built by hand.
///
/// The one shape the platform encoder will not produce on request, and the one
/// that exercises the inflater's stored-block path - including the length and
/// one's-complement pair that is the only defence against a corrupt block
/// length.
Uint8List zlibStored(Uint8List raw, {int blockSize = 65535}) {
  final BytesBuilder out = BytesBuilder();
  out.add(<int>[0x78, 0x01]);
  if (raw.isEmpty) {
    out.add(<int>[0x01, 0x00, 0x00, 0xFF, 0xFF]);
  }
  for (int i = 0; i < raw.length; i += blockSize) {
    final int length = raw.length - i < blockSize ? raw.length - i : blockSize;
    final bool last = i + length >= raw.length;
    out.addByte(last ? 1 : 0);
    out.add(<int>[
      length & 0xFF,
      length >> 8 & 0xFF,
      ~length & 0xFF,
      ~length >> 8 & 0xFF,
    ]);
    out.add(raw.sublist(i, i + length));
  }
  final int sum = adler32(raw);
  out.add(<int>[
    sum >> 24 & 0xFF,
    sum >> 16 & 0xFF,
    sum >> 8 & 0xFF,
    sum & 0xFF,
  ]);
  return out.toBytes();
}

int adler32(List<int> data) {
  int a = 1;
  int b = 0;
  for (final int byte in data) {
    a = (a + byte) % 65521;
    b = (b + a) % 65521;
  }
  return b << 16 | a;
}

int crc32(List<int> data, int start, int length) {
  int c = 0xFFFFFFFF;
  for (int i = 0; i < length; i++) {
    c ^= data[start + i];
    for (int k = 0; k < 8; k++) {
      c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
    }
  }
  return c ^ 0xFFFFFFFF;
}

void _writeU32(Uint8List out, int offset, int value) {
  out[offset] = value >> 24 & 0xFF;
  out[offset + 1] = value >> 16 & 0xFF;
  out[offset + 2] = value >> 8 & 0xFF;
  out[offset + 3] = value & 0xFF;
}
