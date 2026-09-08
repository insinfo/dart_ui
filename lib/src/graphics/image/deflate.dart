/// DEFLATE compression (RFC 1951) and its zlib wrapper (RFC 1950), in Dart.
///
/// ## Why this file exists at all
///
/// The same reason `inflate.dart` does, read from the other side. `dart:io`
/// ships a zlib codec and this framework cannot be built on it: the web
/// backend compiles under `dart2js` and `dart2wasm`, where `dart:io` does not
/// exist, and the whole point of the project is that one implementation runs
/// everywhere. That codec is reachable - see [DeflateEncoder] below, and the
/// section that explains why it is not the default - but only as a faster
/// second answer to a question this file already answers on every target.
/// There is exactly one caller that has to *produce* a zlib
/// stream - the PDF writer, which compresses a content stream so the object
/// can carry `/Filter /FlateDecode` - and until this file it reached for
/// `package:archive`: a whole third-party dependency, in a repository whose
/// standing rule is that it takes none, for one call.
///
/// ## Which blocks it emits, and the measurement that chose them
///
/// DEFLATE offers stored, fixed-Huffman and dynamic-Huffman blocks and they
/// are not close to one another. Measured over 1225 real `/FlateDecode`
/// streams - 58.8 MiB of page content, embedded fonts and image data pulled
/// out of `test/data/*.pdf` and the PDF corpus under `referencias/` - against
/// what `package:archive` produced for the same bytes:
///
///   * **stored only** costs 5.81x what `archive` does, and one thousandth
///     *more* than the uncompressed input. It is not a strategy: the call site
///     keeps the compressed bytes only `if (compressed.length <
///     streamBytes.length)`, so a stored-block encoder would never once be
///     taken and the dependency would have been replaced by nothing;
///   * **fixed Huffman** costs 1.125x `archive` - 12.5% larger PDFs, for good,
///     on every document written by this framework;
///   * **dynamic Huffman** costs 0.988x, a little *under* `archive`, because a
///     table computed per 16384 symbols tracks a stream that changes from text
///     to font data better than one computed for the whole of it.
///
/// 12.5% of every PDF this framework writes is not a defensible price for the
/// two hundred lines the code-length alphabet and its run-length encoding
/// cost, so all three are implemented and [DeflateBlocks.auto] prices each
/// block three ways and emits the cheapest. Stored earns its keep after all -
/// not as a strategy but as a floor, since incompressible input then costs
/// five bytes per 64 KiB instead of expanding, which is the one guarantee a
/// Huffman-only encoder cannot make.
///
/// One correction to that paragraph, found later and worth stating because it
/// changes what the numbers mean: `package:archive`'s `ZLibEncoder` is not
/// Dart on the VM. Its `_zlib_encoder_io.dart` is `ZLibCodec(level: 6)`, so
/// every ratio above is against C zlib itself, and "a little under `archive`"
/// means a little under zlib.
///
/// ## Which encoder writes the bytes, and why the default is the slow one
///
/// Since zlib is what `dart:io` has been handing us all along, [DeflateEncoder]
/// makes it reachable: [DeflateEncoder.native] is `ZLibCodec` on the VM and
/// this encoder everywhere else, [DeflateEncoder.portable] is this encoder
/// everywhere. The default is [DeflateEncoder.portable], and the measurements
/// that chose it, taken from an AOT binary (`tool/deflate_bench.dart`; `dart
/// run` spends about six seconds front-end compiling this package before
/// `main` and would report that instead) over 2091 `/FlateDecode` streams,
/// 101.3 MiB, from `test/data` and `referencias`:
///
///   * **size**: 24294662 bytes against zlib's 24641706. zlib is **1.43%
///     larger**, for the reason the block section already gives - a table per
///     16384 symbols tracks a stream that turns from text to font data better
///     than one table for the whole of it;
///   * **speed**: 17.9 MiB/s against 43.8, so zlib is **2.45x faster**;
///   * **at the call site**, which is the number that decides it:
///     `PdfDocumentComposer.optimize` on a 60-page document composed by this
///     framework takes 23-28 ms with this encoder and 11-17 ms with zlib -
///     about 11 ms, against a run-to-run spread of the *same* binary of 7 to
///     27 ms. On a real 42-page 6.6 MiB PDF that arrived already
///     `/FlateDecode`-filtered - which is what a document from Word or Acrobat
///     is - the composer keeps those streams untouched and the two encoders
///     are indistinguishable: the difference changed sign between measurement
///     passes.
///
/// So the trade is 1.43% of every archived byte against about eleven
/// milliseconds paid once, on the subset of documents this framework composed
/// itself. The caller this exists for signs documents that are then emailed
/// and archived, where the bytes outlive the eleven milliseconds by years, and
/// the default follows that.
///
/// The second half of the trade has no size to it at all: zlib's bytes are not
/// this encoder's bytes, so with [DeflateEncoder.native] the same document
/// composed on the VM and in a browser stop being byte-identical. Anything
/// that hashes, diffs or golden-tests the output becomes platform-dependent -
/// which is why [DeflateEncoder.portable] exists as a name a caller can ask
/// for rather than as an implementation detail of the web build, and why it is
/// what a caller gets without asking.
///
/// ## The deliberate trades
///
/// Two, in the spirit of the inflater's bit-at-a-time decode - stated rather
/// than hidden:
///
///   * the match finder is a single hash chain with one-byte lazy matching and
///     a chain bounded at [_maxChain] candidates. zlib's `deflate` walks
///     further and has a second heuristic for how far to walk; the bound is
///     what keeps the worst case (a file of one repeated byte, where every
///     position hashes the same) linear instead of quadratic, and it costs
///     under a percent of ratio on real data;
///   * Huffman code lengths are built optimally and then, on a block whose
///     tree is deeper than the format's fifteen-bit limit, *all* frequencies
///     are halved and the tree rebuilt until it fits. That is not the
///     length-limited-optimal construction (package-merge), it is a few lines
///     instead of a hundred, and what it gives up is a handful of bits on a
///     block that has to be pathological to reach it at all: the deepest tree
///     over 58.8 MiB of real streams, and over blocks deliberately built with
///     Fibonacci-shaped frequencies to provoke it, was exactly fifteen bits.
///     Right at the limit and never past it, which is why the limit stays -
///     a sixteen-bit code is a stream no decoder will read - and why it is
///     tested through [huffmanCodeLengths] rather than through a corpus that
///     cannot reach it.
///
/// ## Output correctness
///
/// The tests decode every case with `dart:io`'s `ZLibCodec` - zlib itself, an
/// implementation that shares no line and no misreading of the specification
/// with this one - before they decode it with this repository's own
/// [inflate]. A round trip through our own inflater proves only that the two
/// halves agree.
///
/// [DeflateEncoder.native] is checked the other way round, and has to be: zlib
/// reading its own output proves nothing at all, so what the tests assert is
/// that *this repository's* inflater reads what zlib wrote. Each encoder is
/// read by the decoder written by the other side.
library;

import 'dart:typed_data';

import 'package:meta/meta.dart';

import 'deflate_platform_stub.dart'
    if (dart.library.io) 'deflate_platform_io.dart' as platform;
import 'inflate.dart' show adler32;

/// Which of the two encoders writes the bytes.
///
/// The choice is a parameter and not a platform test, because it is a trade
/// and the caller is the only one who knows which side of it they are on. See
/// the "Which encoder" section of this file's header for the measurement.
enum DeflateEncoder {
  /// The encoder in this file, on every platform.
  ///
  /// The same input produces the same bytes on the VM, under dart2js and
  /// under dart2wasm. That is what a caller needs when the output is hashed,
  /// signed, diffed against a golden file, or compared between a desktop
  /// build and a web build of the same application.
  portable,

  /// The platform's own zlib where there is one - `dart:io`'s `ZLibCodec` -
  /// and [portable] where there is not, which is every web target.
  ///
  /// Faster and slightly larger, and its bytes are *not* the bytes [portable]
  /// writes: a document composed on the VM with this and one composed in a
  /// browser are both valid and differ byte for byte.
  native,
}

/// Which block types [deflate] is allowed to emit.
///
/// [auto] is the answer for callers; the other three exist because a test that
/// only ever drove `auto` would never once exercise the stored path (real data
/// is compressible) or the fixed path (dynamic almost always wins), and
/// because forcing each one is how the measurement in this file's header was
/// taken.
enum DeflateBlocks {
  /// Price stored, fixed and dynamic per block and emit the cheapest.
  auto,

  /// Stored blocks only. Never compresses; exists to exercise the path.
  stored,

  /// RFC 1951's built-in code tables, with no table to transmit.
  fixedHuffman,

  /// A code table computed per block and transmitted with it.
  dynamicHuffman,
}

/// Compresses [data] into a **zlib** stream: a two-byte header, DEFLATE data,
/// an Adler-32 of the *uncompressed* bytes.
///
/// This is what `/FlateDecode` in a PDF and `IDAT` in a PNG both mean.
///
/// [encoder] chooses between reproducible bytes and speed and defaults to the
/// first; [blocks] is only meaningful to [DeflateEncoder.portable], since the
/// platform codec picks its own block types.
Uint8List deflateZlib(
  Uint8List data, {
  DeflateBlocks blocks = DeflateBlocks.auto,
  DeflateEncoder encoder = DeflateEncoder.portable,
}) {
  if (_wantsNative(encoder, blocks)) {
    final Uint8List? native = platform.nativeDeflate(data, raw: false);
    if (native != null) return native;
  }
  final Uint8List body = deflate(data, blocks: blocks);
  final Uint8List out = Uint8List(body.length + 6);
  // 0x78: DEFLATE with the full 32 KiB window. 0x9C: no preset dictionary,
  // "default" compression level, and check bits chosen so that the two bytes
  // read as a big-endian number divide by 31, which is the header's only
  // integrity check and the one `inflateZlib` refuses on.
  out[0] = 0x78;
  out[1] = 0x9C;
  out.setRange(2, 2 + body.length, body);
  final int checksum = adler32(data);
  final int tail = 2 + body.length;
  out[tail] = checksum >> 24 & 0xFF;
  out[tail + 1] = checksum >> 16 & 0xFF;
  out[tail + 2] = checksum >> 8 & 0xFF;
  out[tail + 3] = checksum & 0xFF;
  return out;
}

/// Compresses [data] into a raw DEFLATE stream, with no wrapper.
///
/// Separate from [deflateZlib] for the same reason [inflate] is separate from
/// `inflateZlib`: the block format is the half worth testing directly, and the
/// wrappers agree about nothing else.
Uint8List deflate(
  Uint8List data, {
  DeflateBlocks blocks = DeflateBlocks.auto,
  DeflateEncoder encoder = DeflateEncoder.portable,
}) {
  if (_wantsNative(encoder, blocks)) {
    final Uint8List? native = platform.nativeDeflate(data, raw: true);
    if (native != null) return native;
  }
  return _Deflater(data, blocks).run();
}

/// Whether the platform codec may answer this request.
///
/// A codec that prices its own blocks cannot honour [blocks], and quietly
/// ignoring it would make `DeflateBlocks.stored` mean whatever zlib felt like
/// - which is exactly what the block-type tests assert it does not.
bool _wantsNative(DeflateEncoder encoder, DeflateBlocks blocks) {
  assert(
    encoder == DeflateEncoder.portable || blocks == DeflateBlocks.auto,
    'DeflateEncoder.native cannot emit $blocks; it picks its own block types.',
  );
  return encoder == DeflateEncoder.native && blocks == DeflateBlocks.auto;
}

/// The Huffman construction and its length limit, exposed for tests.
///
/// Two things here have to be right and neither is observable from the bytes
/// [deflate] produces on any input that can be built: that no code is longer
/// than [maxLength], and that the code is *complete* - every leaf of the
/// binary tree used, so the Kraft sum is exactly one. An incomplete literal
/// code is a stream zlib refuses outright, and it is what a naive encoder
/// emits for a block with a single distinct symbol.
@visibleForTesting
Uint8List huffmanCodeLengths(Int32List frequencies, int maxLength) =>
    _codeLengths(frequencies, maxLength);

// ---------------------------------------------------------------------------
// Tuning constants
// ---------------------------------------------------------------------------

/// The format's window: a back-reference may reach 32768 bytes.
const int _windowSize = 32768;
const int _windowMask = _windowSize - 1;

/// Below three bytes a back-reference costs more than the literals it saves.
const int _minMatch = 3;

/// The longest run the length alphabet can name.
const int _maxMatch = 258;

const int _hashBits = 15;
const int _hashSize = 1 << _hashBits;
const int _hashMask = _hashSize - 1;

/// How many candidates the match finder will look at before taking what it
/// has. Without a bound, input that is one repeated byte puts every position
/// in one chain and the search becomes quadratic.
const int _maxChain = 128;

/// Symbols buffered before a block is priced and emitted. Larger blocks
/// amortise the transmitted code table; smaller ones let the table track a
/// change in the data. 16384 is where the two stop trading on this corpus.
const int _maxBlockSymbols = 16384;

/// A stored block's length field is sixteen bits, so a block that covers more
/// input than this could not be priced as stored - and the stored floor is the
/// only thing standing between incompressible input and an encoder that makes
/// it bigger.
const int _maxBlockSpan = 65535;

// ---------------------------------------------------------------------------
// The encoder
// ---------------------------------------------------------------------------

final class _Deflater {
  _Deflater(this._data, this._blocks)
      : _head = Int32List(_hashSize)..fillRange(0, _hashSize, -1),
        _prev = Int32List(_windowSize)..fillRange(0, _windowSize, -1);

  final Uint8List _data;
  final DeflateBlocks _blocks;

  /// Most recent position whose three bytes hash to each bucket.
  final Int32List _head;

  /// The position before [_head] in the same bucket, indexed by position
  /// modulo the window - which is why a chain walks backwards in time and
  /// stops on its own once it leaves the window.
  final Int32List _prev;

  late final _BitWriter _writer = _BitWriter(_data.length);

  /// The buffered block: `_dists[i] == 0` marks a literal, and then
  /// `_values[i]` is the byte; otherwise `_values[i]` is the match length.
  /// Two slots of slack: the lazy step can emit a literal and a match in one
  /// pass, and the fullness check only runs once that pass is over.
  final Uint16List _values = Uint16List(_maxBlockSymbols + 2);
  final Uint16List _dists = Uint16List(_maxBlockSymbols + 2);
  int _symbolCount = 0;

  /// Where in [_data] the buffered block starts, which is what a stored block
  /// would have to copy verbatim.
  int _blockStart = 0;

  /// How far the hash chains have been filled in. Kept separate from the
  /// coding position because a match skips over positions that still have to
  /// be inserted, and because the lazy step looks one position ahead.
  int _inserted = 0;

  int _matchLength = 0;
  int _matchDistance = 0;

  Uint8List run() {
    _lz77();
    _flush(_data.length, last: true);
    _writer.finish();
    return _writer.toBytes();
  }

  // -------------------------------------------------------------------------
  // LZ77
  // -------------------------------------------------------------------------

  void _lz77() {
    final int n = _data.length;
    int pos = 0;
    while (pos < n) {
      _insertUpTo(pos);
      _findMatch(pos);
      int length = _matchLength;
      int distance = _matchDistance;

      // Lazy matching: a match here that a longer match one byte later would
      // overlap is worth giving up, because the literal it costs is cheaper
      // than the bytes the longer match saves. One byte of lookahead is where
      // the gain stops paying for the extra search.
      if (length >= _minMatch && length < _maxMatch && pos + 1 < n) {
        _insertUpTo(pos + 1);
        _findMatch(pos + 1);
        if (_matchLength > length) {
          _emitLiteral(_data[pos]);
          pos++;
          length = _matchLength;
          distance = _matchDistance;
        }
      }

      if (length >= _minMatch) {
        _emitMatch(length, distance);
        pos += length;
      } else {
        _emitLiteral(_data[pos]);
        pos++;
      }

      // Priced and emitted at a symbol boundary, so the block's symbols cover
      // exactly `_data[_blockStart..pos)` and the stored price is knowable.
      if (_symbolCount >= _maxBlockSymbols ||
          pos - _blockStart >= _maxBlockSpan - _maxMatch) {
        _flush(pos, last: false);
      }
    }
  }

  void _insertUpTo(int limit) {
    final int last = _data.length - _minMatch;
    while (_inserted < limit) {
      if (_inserted > last) {
        // The final two positions have no three bytes to hash. Nothing can
        // match them anyway, so the chains simply end here.
        _inserted = limit;
        return;
      }
      final int bucket = _hash(_inserted);
      _prev[_inserted & _windowMask] = _head[bucket];
      _head[bucket] = _inserted;
      _inserted++;
    }
  }

  int _hash(int pos) =>
      (_data[pos] << 10 ^ _data[pos + 1] << 5 ^ _data[pos + 2]) & _hashMask;

  /// Sets [_matchLength] and [_matchDistance] to the longest back-reference
  /// starting at [pos], or to zero when there is none worth taking.
  void _findMatch(int pos) {
    _matchLength = 0;
    _matchDistance = 0;
    final int n = _data.length;
    int maxLength = n - pos;
    if (maxLength < _minMatch) return;
    if (maxLength > _maxMatch) maxLength = _maxMatch;

    // A distance of exactly 32768 is legal - it is the last value distance
    // symbol 29 can name - so the oldest reachable position is `pos - 32768`
    // and not one byte later.
    final int oldest = pos > _windowSize ? pos - _windowSize : 0;
    int best = _minMatch - 1;
    int bestDistance = 0;
    int candidate = _head[_hash(pos)];
    int chain = _maxChain;
    while (candidate >= oldest && chain-- > 0) {
      // Comparing the byte one past the current best first rejects most
      // candidates in a single load: a candidate that cannot beat `best`
      // cannot match there.
      if (_data[candidate + best] == _data[pos + best] &&
          _data[candidate] == _data[pos]) {
        int length = 0;
        while (length < maxLength &&
            _data[candidate + length] == _data[pos + length]) {
          length++;
        }
        if (length > best) {
          best = length;
          bestDistance = pos - candidate;
          if (length >= maxLength) break;
        }
      }
      candidate = _prev[candidate & _windowMask];
    }
    if (best >= _minMatch) {
      _matchLength = best;
      _matchDistance = bestDistance;
    }
  }

  void _emitLiteral(int byte) {
    _values[_symbolCount] = byte;
    _dists[_symbolCount] = 0;
    _symbolCount++;
  }

  void _emitMatch(int length, int distance) {
    _values[_symbolCount] = length;
    _dists[_symbolCount] = distance;
    _symbolCount++;
  }

  // -------------------------------------------------------------------------
  // Block pricing and emission
  // -------------------------------------------------------------------------

  void _flush(int end, {required bool last}) {
    final int span = end - _blockStart;

    final Int32List literalFreq = Int32List(286);
    final Int32List distanceFreq = Int32List(30);
    literalFreq[256] = 1; // the end-of-block symbol is always emitted
    for (int i = 0; i < _symbolCount; i++) {
      final int distance = _dists[i];
      if (distance == 0) {
        literalFreq[_values[i]]++;
      } else {
        literalFreq[257 + _lengthCode[_values[i]]]++;
        distanceFreq[_distanceCode(distance)]++;
      }
    }

    final _Tree fixed = _Tree.fixed();
    final int fixedBits = _payloadBits(fixed, literalFreq, distanceFreq);

    final _Tree dynamicTree = _Tree.from(literalFreq, distanceFreq);
    final _CodeLengthHeader header = _CodeLengthHeader(dynamicTree);
    final int dynamicBits =
        header.bits + _payloadBits(dynamicTree, literalFreq, distanceFreq);

    // Three header bits, then the alignment a stored block insists on, then
    // LEN and NLEN. Priced against the current bit position because the
    // padding is real: a stored block that lands one bit into a byte throws
    // seven away.
    final int storedBits = span <= _maxBlockSpan
        ? 3 + (-(_writer.bitPosition + 3) & 7) + 32 + 8 * span
        : 1 << 30;

    switch (_pick(storedBits, fixedBits, dynamicBits)) {
      case DeflateBlocks.stored:
        _writeStored(end, last: last);
      case DeflateBlocks.fixedHuffman:
        _writer.bits(last ? 1 : 0, 1);
        _writer.bits(1, 2);
        _writeSymbols(fixed);
      case DeflateBlocks.dynamicHuffman || DeflateBlocks.auto:
        _writer.bits(last ? 1 : 0, 1);
        _writer.bits(2, 2);
        header.write(_writer, dynamicTree);
        _writeSymbols(dynamicTree);
    }

    _symbolCount = 0;
    _blockStart = end;
  }

  DeflateBlocks _pick(int storedBits, int fixedBits, int dynamicBits) {
    if (_blocks != DeflateBlocks.auto) return _blocks;
    if (storedBits <= fixedBits && storedBits <= dynamicBits) {
      return DeflateBlocks.stored;
    }
    return fixedBits <= dynamicBits
        ? DeflateBlocks.fixedHuffman
        : DeflateBlocks.dynamicHuffman;
  }

  /// What the buffered symbols cost under [tree], excluding any table.
  int _payloadBits(_Tree tree, Int32List literalFreq, Int32List distanceFreq) {
    int bits = 3;
    for (int symbol = 0; symbol < 286; symbol++) {
      final int count = literalFreq[symbol];
      if (count == 0) continue;
      if (tree.literalLengths[symbol] == 0) {
        // The fixed table names every symbol, so only a tree built for a
        // *different* block could fail here; being explicit keeps a future
        // caching bug from silently emitting a zero-length code.
        return 1 << 30;
      }
      bits += count * tree.literalLengths[symbol];
      if (symbol >= 257) bits += count * _lengthExtra[symbol - 257];
    }
    for (int symbol = 0; symbol < 30; symbol++) {
      final int count = distanceFreq[symbol];
      if (count == 0) continue;
      if (tree.distanceLengths[symbol] == 0) return 1 << 30;
      bits += count * (tree.distanceLengths[symbol] + _distanceExtra[symbol]);
    }
    return bits;
  }

  void _writeStored(int end, {required bool last}) {
    _writer.bits(last ? 1 : 0, 1);
    _writer.bits(0, 2);
    _writer.alignToByte();
    final int span = end - _blockStart;
    _writer.bits(span & 0xFFFF, 16);
    _writer.bits(~span & 0xFFFF, 16);
    _writer.raw(_data, _blockStart, end);
  }

  void _writeSymbols(_Tree tree) {
    for (int i = 0; i < _symbolCount; i++) {
      final int distance = _dists[i];
      final int value = _values[i];
      if (distance == 0) {
        _writer.bits(tree.literalCodes[value], tree.literalLengths[value]);
        continue;
      }
      final int lengthIndex = _lengthCode[value];
      final int symbol = 257 + lengthIndex;
      _writer.bits(tree.literalCodes[symbol], tree.literalLengths[symbol]);
      _writer.bits(value - _lengthBase[lengthIndex], _lengthExtra[lengthIndex]);
      final int distanceIndex = _distanceCode(distance);
      _writer.bits(
        tree.distanceCodes[distanceIndex],
        tree.distanceLengths[distanceIndex],
      );
      _writer.bits(
        distance - _distanceBase[distanceIndex],
        _distanceExtra[distanceIndex],
      );
    }
    _writer.bits(tree.literalCodes[256], tree.literalLengths[256]);
  }
}

// ---------------------------------------------------------------------------
// Huffman
// ---------------------------------------------------------------------------

/// The pair of code tables a Huffman block is coded with.
final class _Tree {
  _Tree._(
    this.literalLengths,
    this.distanceLengths,
  )   : literalCodes = _canonicalCodes(literalLengths),
        distanceCodes = _canonicalCodes(distanceLengths);

  /// RFC 1951's built-in tables: 8, 9, 7 and 8 bits by literal range, and five
  /// bits for every distance.
  factory _Tree.fixed() => _fixedTree;

  /// The optimal tables for one block's symbol frequencies.
  factory _Tree.from(Int32List literalFreq, Int32List distanceFreq) => _Tree._(
        _codeLengths(literalFreq, 15),
        _codeLengths(distanceFreq, 15),
      );

  final Uint8List literalLengths;
  final Uint8List distanceLengths;
  final Int32List literalCodes;
  final Int32List distanceCodes;

  /// How many literal/length codes the header has to transmit: everything up
  /// to the last one that is used, and never fewer than the format's 257.
  int get literalCount {
    int count = 286;
    while (count > 257 && literalLengths[count - 1] == 0) {
      count--;
    }
    return count;
  }

  /// How many distance codes the header has to transmit, never fewer than one.
  int get distanceCount {
    int count = 30;
    while (count > 1 && distanceLengths[count - 1] == 0) {
      count--;
    }
    return count;
  }
}

final _Tree _fixedTree = _Tree._(
  Uint8List(288)
    ..fillRange(0, 144, 8)
    ..fillRange(144, 256, 9)
    ..fillRange(256, 280, 7)
    ..fillRange(280, 288, 8),
  Uint8List(30)..fillRange(0, 30, 5),
);

/// Optimal code lengths for [freq], none longer than [maxLength].
///
/// The length limit is enforced by halving every frequency and rebuilding,
/// which is not the length-limited-optimal construction and is documented as
/// such in this file's header. It terminates because halving converges on all
/// frequencies equal, and a balanced tree over 286 symbols is nine deep.
Uint8List _codeLengths(Int32List freq, int maxLength) {
  Int32List working = freq;
  while (true) {
    final Uint8List lengths = _buildLengths(working);
    int longest = 0;
    for (final int length in lengths) {
      if (length > longest) longest = length;
    }
    if (longest <= maxLength) return lengths;
    final Int32List halved = Int32List(freq.length);
    for (int i = 0; i < freq.length; i++) {
      // Rounding up keeps a symbol that is in the code in the code; rounding
      // down would drop it and produce a table that cannot encode the block.
      halved[i] = working[i] == 0 ? 0 : working[i] + 1 >> 1;
    }
    working = halved;
  }
}

/// One Huffman construction, with no length limit.
Uint8List _buildLengths(Int32List freq) {
  final int n = freq.length;
  final Uint8List lengths = Uint8List(n);
  final List<int> active = <int>[];
  for (int i = 0; i < n; i++) {
    if (freq[i] > 0) active.add(i);
  }

  // A code with fewer than two symbols is *incomplete*: half the code space
  // decodes to nothing. Our own inflater would accept it and zlib's would
  // reject the stream outright, so a second symbol is invented. Its frequency
  // is zero, so it costs one bit in the transmitted table and nothing in the
  // payload.
  if (active.length < 2) {
    final int first = active.isEmpty ? 0 : active[0];
    lengths[first] = 1;
    lengths[first == 0 ? 1 : 0] = 1;
    return lengths;
  }

  final Int32List weights = Int32List(active.length);
  for (int i = 0; i < active.length; i++) {
    weights[i] = freq[active[i]];
  }
  // Sorting by frequency is what lets the construction run with two ordered
  // queues instead of a heap: the internal nodes come out non-decreasing on
  // their own.
  final List<int> order = List<int>.generate(active.length, (int i) => i)
    ..sort((int a, int b) {
      final int difference = weights[a] - weights[b];
      return difference != 0 ? difference : active[a] - active[b];
    });

  final int leaves = active.length;
  final int nodes = 2 * leaves - 1;
  final Int32List nodeWeight = Int32List(nodes);
  final Int32List parent = Int32List(nodes)..fillRange(0, nodes, -1);
  for (int i = 0; i < leaves; i++) {
    nodeWeight[i] = weights[order[i]];
  }

  int nextLeaf = 0;
  int nextInternal = leaves;
  int next = leaves;
  while (next < nodes) {
    final int left = _cheapest(
      nodeWeight,
      leaves,
      next,
      nextLeaf,
      nextInternal,
    );
    if (left < leaves) {
      nextLeaf++;
    } else {
      nextInternal++;
    }
    final int right = _cheapest(
      nodeWeight,
      leaves,
      next,
      nextLeaf,
      nextInternal,
    );
    if (right < leaves) {
      nextLeaf++;
    } else {
      nextInternal++;
    }
    nodeWeight[next] = nodeWeight[left] + nodeWeight[right];
    parent[left] = next;
    parent[right] = next;
    next++;
  }

  // A parent is always created after both its children, so one backwards pass
  // gives every node its depth without walking to the root per leaf.
  final Int32List depth = Int32List(nodes);
  for (int i = nodes - 2; i >= 0; i--) {
    depth[i] = depth[parent[i]] + 1;
  }
  for (int i = 0; i < leaves; i++) {
    lengths[active[order[i]]] = depth[i];
  }
  return lengths;
}

int _cheapest(
  Int32List nodeWeight,
  int leaves,
  int next,
  int nextLeaf,
  int nextInternal,
) {
  if (nextLeaf < leaves &&
      (nextInternal >= next ||
          nodeWeight[nextLeaf] <= nodeWeight[nextInternal])) {
    return nextLeaf;
  }
  return nextInternal;
}

/// Canonical codes for [lengths], already bit-reversed.
///
/// DEFLATE writes Huffman codes most-significant bit first into a
/// least-significant-bit-first stream, which is the one place in the format
/// where the two orders disagree. Reversing once here is cheaper and far
/// harder to get wrong than reversing at every write.
Int32List _canonicalCodes(Uint8List lengths) {
  final Int32List countPerLength = Int32List(16);
  for (final int length in lengths) {
    countPerLength[length]++;
  }
  countPerLength[0] = 0;

  final Int32List nextCode = Int32List(16);
  int code = 0;
  for (int length = 1; length <= 15; length++) {
    code = code + countPerLength[length - 1] << 1;
    nextCode[length] = code;
  }

  final Int32List codes = Int32List(lengths.length);
  for (int symbol = 0; symbol < lengths.length; symbol++) {
    final int length = lengths[symbol];
    if (length != 0) codes[symbol] = _reverse(nextCode[length]++, length);
  }
  return codes;
}

int _reverse(int code, int length) {
  int reversed = 0;
  for (int i = 0; i < length; i++) {
    reversed = reversed << 1 | code >> i & 1;
  }
  return reversed;
}

// ---------------------------------------------------------------------------
// The dynamic block's transmitted table
// ---------------------------------------------------------------------------

/// The run-length-encoded code lengths of a dynamic block, and their own
/// Huffman code.
///
/// Built eagerly rather than on demand because its size is half of what
/// decides whether a dynamic block is worth emitting at all - a block of two
/// hundred symbols routinely loses to fixed Huffman on the table alone.
final class _CodeLengthHeader {
  factory _CodeLengthHeader(_Tree tree) {
    final int literalCount = tree.literalCount;
    final int distanceCount = tree.distanceCount;
    final Uint8List combined = Uint8List(literalCount + distanceCount);
    combined.setRange(0, literalCount, tree.literalLengths);
    combined.setRange(literalCount, combined.length, tree.distanceLengths);

    final List<int> symbols = <int>[];
    final List<int> extras = <int>[];
    final Int32List freq = Int32List(19);
    void emit(int symbol, int extra) {
      symbols.add(symbol);
      extras.add(extra);
      freq[symbol]++;
    }

    int index = 0;
    while (index < combined.length) {
      final int value = combined[index];
      int run = 1;
      while (index + run < combined.length && combined[index + run] == value) {
        run++;
      }
      index += run;
      if (value == 0) {
        while (run >= 11) {
          final int take = run > 138 ? 138 : run;
          emit(18, take - 11);
          run -= take;
        }
        while (run >= 3) {
          final int take = run > 10 ? 10 : run;
          emit(17, take - 3);
          run -= take;
        }
        while (run-- > 0) {
          emit(0, 0);
        }
      } else {
        emit(value, 0);
        run--;
        while (run >= 3) {
          final int take = run > 6 ? 6 : run;
          emit(16, take - 3);
          run -= take;
        }
        while (run-- > 0) {
          emit(value, 0);
        }
      }
    }

    // Seven bits is the code-length alphabet's own maximum, and it is not the
    // fifteen the other two alphabets get.
    final Uint8List lengths = _codeLengths(freq, 7);
    int transmitted = 19;
    while (transmitted > 4 && lengths[_codeLengthOrder[transmitted - 1]] == 0) {
      transmitted--;
    }

    int bits = 5 + 5 + 4 + 3 * transmitted;
    for (int i = 0; i < symbols.length; i++) {
      bits += lengths[symbols[i]] + _codeLengthExtra[symbols[i]];
    }

    return _CodeLengthHeader._(
      symbols,
      extras,
      lengths,
      _canonicalCodes(lengths),
      transmitted,
      bits,
    );
  }

  _CodeLengthHeader._(
    this._symbols,
    this._extras,
    this._lengths,
    this._codes,
    this._transmitted,
    this.bits,
  );

  final List<int> _symbols;
  final List<int> _extras;
  final Uint8List _lengths;
  final Int32List _codes;
  final int _transmitted;

  /// The exact size of this header in bits, including HLIT/HDIST/HCLEN.
  final int bits;

  void write(_BitWriter writer, _Tree tree) {
    writer.bits(tree.literalCount - 257, 5);
    writer.bits(tree.distanceCount - 1, 5);
    writer.bits(_transmitted - 4, 4);
    for (int i = 0; i < _transmitted; i++) {
      writer.bits(_lengths[_codeLengthOrder[i]], 3);
    }
    for (int i = 0; i < _symbols.length; i++) {
      final int symbol = _symbols[i];
      writer.bits(_codes[symbol], _lengths[symbol]);
      writer.bits(_extras[i], _codeLengthExtra[symbol]);
    }
  }
}

// ---------------------------------------------------------------------------
// Alphabet tables
// ---------------------------------------------------------------------------

/// The order HCLEN transmits the code-length code in, which puts the lengths
/// most likely to be zero last so they can be trimmed off.
const List<int> _codeLengthOrder = <int>[
  16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15, //
];

/// Extra bits carried by each code-length symbol; only 16, 17 and 18 have any.
const List<int> _codeLengthExtra = <int>[
  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2, 3, 7, //
];

const List<int> _lengthBase = <int>[
  3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, //
  35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258, //
];

const List<int> _lengthExtra = <int>[
  0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, //
  3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0, //
];

const List<int> _distanceBase = <int>[
  1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, //
  257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, //
  8193, 12289, 16385, 24577, //
];

const List<int> _distanceExtra = <int>[
  0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, //
  7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13, //
];

/// Length in 3..258 to its symbol index in 0..28.
///
/// Built rather than written out because the one entry a hand-written table
/// gets wrong is 258: symbol 27 can also name it, through its extra bits, and
/// only symbol 28 is what a decoder expects for the maximum match.
final Uint8List _lengthCode = _buildLengthCode();

Uint8List _buildLengthCode() {
  final Uint8List table = Uint8List(_maxMatch + 1);
  for (int length = _minMatch; length <= _maxMatch; length++) {
    int index = 0;
    while (index + 1 < _lengthBase.length && _lengthBase[index + 1] <= length) {
      index++;
    }
    table[length] = index;
  }
  return table;
}

/// Distances 1..256 to their symbol, and 257..32768 through their top bits.
///
/// Every distance base above 256 is one more than a multiple of 128, so
/// `(distance - 1) >> 7` names the symbol uniquely - the trick zlib uses, and
/// the reason this is two 256-byte tables instead of one 32 KiB one.
final Uint8List _distanceCodeSmall = _buildDistanceCode(false);
final Uint8List _distanceCodeLarge = _buildDistanceCode(true);

int _distanceCode(int distance) {
  final int index = distance - 1;
  return index < 256
      ? _distanceCodeSmall[index]
      : _distanceCodeLarge[index >> 7];
}

Uint8List _buildDistanceCode(bool large) {
  final Uint8List table = Uint8List(256);
  for (int i = 0; i < 256; i++) {
    final int distance = large ? (i << 7) + 1 : i + 1;
    int index = 0;
    while (index + 1 < _distanceBase.length &&
        _distanceBase[index + 1] <= distance) {
      index++;
    }
    table[i] = index;
  }
  return table;
}

// ---------------------------------------------------------------------------
// Output
// ---------------------------------------------------------------------------

/// Least-significant-bit-first bit writer, the mirror of the inflater's
/// reader.
final class _BitWriter {
  _BitWriter(int inputLength) : _bytes = Uint8List(64 + (inputLength >> 1));

  Uint8List _bytes;
  int _length = 0;
  int _buffer = 0;
  int _count = 0;

  /// How many bits have been written, which is what prices a stored block's
  /// alignment padding before anything is committed.
  int get bitPosition => _length * 8 + _count;

  /// [count] bits of [value], LSB first. `count == 0` is legal and writes
  /// nothing, which is what lets a zero extra-bit count go through unguarded.
  void bits(int value, int count) {
    _buffer |= (value & (1 << count) - 1) << _count;
    _count += count;
    while (_count >= 8) {
      _push(_buffer & 0xFF);
      _buffer >>= 8;
      _count -= 8;
    }
  }

  void alignToByte() {
    if (_count > 0) {
      _push(_buffer & 0xFF);
      _buffer = 0;
      _count = 0;
    }
  }

  /// `data[start..end)` verbatim, for a stored block's body.
  void raw(Uint8List data, int start, int end) {
    final int span = end - start;
    if (_length + span > _bytes.length) _grow(_length + span);
    _bytes.setRange(_length, _length + span, data, start);
    _length += span;
  }

  /// Pads the last partial byte with zeros, which is what ends a stream.
  void finish() => alignToByte();

  Uint8List toBytes() => Uint8List.sublistView(_bytes, 0, _length);

  void _push(int byte) {
    if (_length == _bytes.length) _grow(_length + 1);
    _bytes[_length++] = byte;
  }

  void _grow(int needed) {
    int capacity = _bytes.length * 2;
    while (capacity < needed) {
      capacity *= 2;
    }
    final Uint8List grown = Uint8List(capacity);
    grown.setRange(0, _length, _bytes);
    _bytes = grown;
  }
}
