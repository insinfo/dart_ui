/// DEFLATE (RFC 1951) and its zlib wrapper (RFC 1950), in Dart.
///
/// ## Why this file exists at all
///
/// `dart:io` ships a zlib codec and this framework may not use it: the web
/// backend compiles under `dart2js` and `dart2wasm`, where `dart:io` does not
/// exist, and the whole point of the project is that one implementation runs
/// everywhere. A PNG is a zlib stream with a container around it, so a PNG
/// decoder in pure Dart needs an inflater in pure Dart. There is no smaller
/// version of this dependency.
///
/// ## The shape of the implementation
///
/// Canonical Huffman decoding, bit at a time, in the form Mark Adler's `puff.c`
/// popularised: a table of how many codes exist at each length plus the symbols
/// in canonical order, walked one bit deeper per iteration. That is slower than
/// the multi-level lookup tables a production inflater uses and it is a
/// deliberate trade for this stage - it is a third of the code, it has no
/// table-construction step to get wrong, and an *incomplete* code (a real
/// corruption, and one a fast table quietly papers over) falls out of it as a
/// natural failure rather than needing a separate validation pass.
///
/// ## Untrusted input
///
/// Every loop in here is bounded and every read is checked:
///
///   * the output is capped by [inflate]'s `maxOutputBytes`, which is what
///     turns a **decompression bomb** - a few hundred bytes of `IDAT` that
///     expand to gigabytes - into an [ImageBudgetException] with a number in
///     it. There is no "grow until it fits" path;
///   * the code-length walk stops at fifteen bits, which is the format's own
///     maximum, so a corrupt table cannot spin;
///   * a back-reference whose distance points before the start of the output
///     is refused rather than clamped. Clamping would invent pixels;
///   * every bit read checks the input bound, so a stream that stops in the
///     middle of a block raises [InflateException] instead of a range error
///     from inside a loop.
library;

import 'dart:typed_data';

import 'image_errors.dart';

/// Inflates a **zlib** stream: a two-byte header, DEFLATE data, an Adler-32.
///
/// [maxOutputBytes] is a hard ceiling on the decompressed size and it is not
/// optional. When it is reached the decode stops and throws
/// [ImageBudgetException] with [budget] as its `budget` name, so the caller's
/// error message says which of its limits was the binding one.
///
/// Throws [InflateException] for anything malformed, including a bad Adler-32.
Uint8List inflateZlib(
  Uint8List bytes, {
  required int maxOutputBytes,
  required String budget,
}) {
  if (bytes.length < 6) {
    // Two header bytes, at least one block, four trailer bytes. Anything
    // shorter cannot be a zlib stream whatever it contains.
    throw const InflateException(
      'the zlib stream is shorter than its own header and trailer',
    );
  }
  final int cmf = bytes[0];
  final int flg = bytes[1];
  if (cmf & 0x0F != 8) {
    throw InflateException(
      'zlib compression method ${cmf & 0x0F} is not DEFLATE (8)',
    );
  }
  if (cmf >> 4 > 7) {
    throw InflateException(
      'zlib window size 2^${(cmf >> 4) + 8} exceeds the 32 KiB maximum',
    );
  }
  if ((cmf << 8 | flg) % 31 != 0) {
    throw const InflateException(
      'the zlib header check bits do not divide by 31, so the first two bytes '
      'are not a zlib header',
    );
  }
  if (flg & 0x20 != 0) {
    // A preset dictionary means the stream cannot be decoded without a
    // dictionary nobody transmitted. PNG forbids it outright.
    throw const InflateException(
      'the zlib stream declares a preset dictionary, which PNG forbids and '
      'this inflater does not implement',
    );
  }

  final Uint8List out = inflate(
    bytes,
    start: 2,
    end: bytes.length - 4,
    maxOutputBytes: maxOutputBytes,
    budget: budget,
  );

  final int declared = bytes[bytes.length - 4] << 24 |
      bytes[bytes.length - 3] << 16 |
      bytes[bytes.length - 2] << 8 |
      bytes[bytes.length - 1];
  final int computed = adler32(out);
  if (declared != computed) {
    throw InflateException(
      'the zlib stream\'s Adler-32 is 0x${declared.toRadixString(16)} but the '
      'inflated bytes hash to 0x${computed.toRadixString(16)}',
    );
  }
  return out;
}

/// Inflates a raw DEFLATE stream from `bytes[start..end)`.
///
/// Separate from [inflateZlib] because the two wrappers - zlib's and gzip's -
/// disagree about everything except the block format between them, and because
/// this is the half worth testing directly.
Uint8List inflate(
  Uint8List bytes, {
  int start = 0,
  int? end,
  required int maxOutputBytes,
  required String budget,
}) {
  final _BitReader reader = _BitReader(bytes, start, end ?? bytes.length);
  final _Output out = _Output(maxOutputBytes, budget);

  bool last = false;
  while (!last) {
    last = reader.bits(1) == 1;
    final int type = reader.bits(2);
    switch (type) {
      case 0:
        _stored(reader, out);
      case 1:
        _block(reader, out, _fixedLiterals, _fixedDistances);
      case 2:
        final (_Huffman literals, _Huffman distances) = _dynamicTables(reader);
        _block(reader, out, literals, distances);
      default:
        throw const InflateException(
          'DEFLATE block type 3 is reserved and has no meaning',
        );
    }
  }
  return out.toBytes();
}

/// Adler-32 over [data], as RFC 1950 defines it.
int adler32(Uint8List data) {
  int a = 1;
  int b = 0;
  // 5552 is the largest run of bytes that cannot overflow a 32-bit `b`, and
  // deferring the modulo to the end of each run is what makes this cost about
  // one add per byte instead of two divisions.
  int index = 0;
  while (index < data.length) {
    final int chunk = data.length - index < 5552 ? data.length - index : 5552;
    for (int i = 0; i < chunk; i++) {
      a += data[index + i];
      b += a;
    }
    a %= 65521;
    b %= 65521;
    index += chunk;
  }
  return (b << 16 | a) & 0xFFFFFFFF;
}

// ---------------------------------------------------------------------------
// Blocks
// ---------------------------------------------------------------------------

/// A stored (uncompressed) block: byte-aligned, with a length and its
/// one's complement.
void _stored(_BitReader reader, _Output out) {
  reader.alignToByte();
  final int length = reader.byte() | reader.byte() << 8;
  final int complement = reader.byte() | reader.byte() << 8;
  if (length != (~complement & 0xFFFF)) {
    // The one check in the whole format whose only purpose is to catch a
    // corrupt length before it is used as a read size.
    throw InflateException(
      'a stored block declares length $length but its complement says '
      '${~complement & 0xFFFF}',
    );
  }
  for (int i = 0; i < length; i++) {
    out.write(reader.byte());
  }
}

/// One Huffman-coded block, fixed or dynamic - the tables are the only
/// difference between the two.
void _block(
  _BitReader reader,
  _Output out,
  _Huffman literals,
  _Huffman distances,
) {
  while (true) {
    final int symbol = _decode(reader, literals);
    if (symbol < 256) {
      out.write(symbol);
      continue;
    }
    if (symbol == 256) return; // end of block
    final int lengthIndex = symbol - 257;
    if (lengthIndex >= _lengthBase.length) {
      throw InflateException(
        'literal/length symbol $symbol is outside the defined 0..285 range',
      );
    }
    final int length =
        _lengthBase[lengthIndex] + reader.bits(_lengthExtra[lengthIndex]);
    final int distanceSymbol = _decode(reader, distances);
    if (distanceSymbol >= _distanceBase.length) {
      throw InflateException(
        'distance symbol $distanceSymbol is outside the defined 0..29 range',
      );
    }
    final int distance = _distanceBase[distanceSymbol] +
        reader.bits(_distanceExtra[distanceSymbol]);
    out.copy(distance, length);
  }
}

/// Reads the code lengths a dynamic block carries and builds its two tables.
(_Huffman, _Huffman) _dynamicTables(_BitReader reader) {
  final int literalCount = reader.bits(5) + 257;
  final int distanceCount = reader.bits(5) + 1;
  final int lengthCount = reader.bits(4) + 4;
  if (literalCount > 286 || distanceCount > 30) {
    throw InflateException(
      'a dynamic block declares $literalCount literal and $distanceCount '
      'distance codes; the format allows at most 286 and 30',
    );
  }

  final Uint8List codeLengths = Uint8List(19);
  for (int i = 0; i < lengthCount; i++) {
    codeLengths[_codeLengthOrder[i]] = reader.bits(3);
  }
  final _Huffman lengthTable = _Huffman(codeLengths);

  final Uint8List lengths = Uint8List(literalCount + distanceCount);
  int index = 0;
  while (index < lengths.length) {
    final int symbol = _decode(reader, lengthTable);
    if (symbol < 16) {
      lengths[index++] = symbol;
      continue;
    }
    int repeat;
    int value = 0;
    switch (symbol) {
      case 16:
        if (index == 0) {
          throw const InflateException(
            'code length 16 repeats the previous length, and there is no '
            'previous length at the start of the table',
          );
        }
        value = lengths[index - 1];
        repeat = 3 + reader.bits(2);
      case 17:
        repeat = 3 + reader.bits(3);
      default:
        repeat = 11 + reader.bits(7);
    }
    if (index + repeat > lengths.length) {
      throw InflateException(
        'a code-length repeat of $repeat runs past the end of the '
        '${lengths.length}-entry table',
      );
    }
    for (int i = 0; i < repeat; i++) {
      lengths[index++] = value;
    }
  }
  if (lengths[256] == 0) {
    // Without an end-of-block code the block could only ever end by running
    // out of input, which is how a malformed stream turns into a long loop.
    throw const InflateException(
      'the dynamic table has no end-of-block code, so the block could never '
      'terminate',
    );
  }

  return (
    _Huffman(Uint8List.sublistView(lengths, 0, literalCount)),
    _Huffman(Uint8List.sublistView(lengths, literalCount)),
  );
}

// ---------------------------------------------------------------------------
// Huffman
// ---------------------------------------------------------------------------

/// A canonical Huffman table as counts-per-length plus symbols in order.
///
/// Building it is two counting passes and no allocation beyond these two
/// arrays, which is why rebuilding one per dynamic block costs nothing worth
/// measuring.
final class _Huffman {
  _Huffman(List<int> lengths)
      : counts = Int32List(16),
        symbols = Int32List(lengths.length) {
    for (final int length in lengths) {
      if (length > 15) {
        throw InflateException('a code length of $length exceeds the maximum');
      }
      counts[length]++;
    }
    // Length 0 means "this symbol is not in the code" and is not a length.
    counts[0] = 0;

    final Int32List offsets = Int32List(16);
    for (int length = 1; length < 15; length++) {
      offsets[length + 1] = offsets[length] + counts[length];
    }
    for (int symbol = 0; symbol < lengths.length; symbol++) {
      if (lengths[symbol] != 0) {
        symbols[offsets[lengths[symbol]]++] = symbol;
      }
    }
  }

  /// How many codes have each length, indexed by length.
  final Int32List counts;

  /// The symbols, ordered by (length, symbol) - canonical order.
  final Int32List symbols;
}

/// Walks [table] one bit at a time until a code matches.
///
/// The loop is bounded by the format's fifteen-bit maximum, so an incomplete
/// or over-subscribed table fails here rather than reading forever.
int _decode(_BitReader reader, _Huffman table) {
  int code = 0;
  int first = 0;
  int index = 0;
  for (int length = 1; length <= 15; length++) {
    code |= reader.bits(1);
    final int count = table.counts[length];
    if (code - first < count) return table.symbols[index + (code - first)];
    index += count;
    first = (first + count) << 1;
    code <<= 1;
  }
  throw const InflateException(
    'no Huffman code matched in fifteen bits, so the code table is incomplete '
    'or the stream is not DEFLATE',
  );
}

/// RFC 1951's fixed literal/length code: 8, 9, 7 and 8 bits by range.
final _Huffman _fixedLiterals = _Huffman(
  Uint8List(288)
    ..fillRange(0, 144, 8)
    ..fillRange(144, 256, 9)
    ..fillRange(256, 280, 7)
    ..fillRange(280, 288, 8),
);

/// RFC 1951's fixed distance code: thirty-two five-bit codes, of which the
/// last two are never emitted by a conforming encoder and are refused above.
final _Huffman _fixedDistances = _Huffman(Uint8List(32)..fillRange(0, 32, 5));

const List<int> _codeLengthOrder = <int>[
  16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15, //
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

// ---------------------------------------------------------------------------
// Input and output
// ---------------------------------------------------------------------------

/// Least-significant-bit-first bit reader over a byte range.
final class _BitReader {
  _BitReader(this._data, this._offset, this._end);

  final Uint8List _data;
  int _offset;
  final int _end;
  int _buffer = 0;
  int _count = 0;

  /// [need] bits, LSB first. `need == 0` is legal and returns 0, which is what
  /// lets the length/distance tables carry a zero extra-bit count.
  int bits(int need) {
    while (_count < need) {
      if (_offset >= _end) {
        throw const InflateException(
          'the DEFLATE stream ends in the middle of a block',
        );
      }
      _buffer |= _data[_offset++] << _count;
      _count += 8;
    }
    final int value = _buffer & ((1 << need) - 1);
    _buffer >>= need;
    _count -= need;
    return value;
  }

  /// Discards the partial byte, as a stored block's header requires.
  void alignToByte() {
    _buffer = 0;
    _count = 0;
  }

  /// One whole byte, for the body of a stored block.
  int byte() {
    if (_count >= 8) return bits(8);
    if (_offset >= _end) {
      throw const InflateException(
        'a stored block runs past the end of the compressed data',
      );
    }
    _buffer = 0;
    _count = 0;
    return _data[_offset++];
  }
}

/// A growing output buffer with a ceiling.
///
/// The ceiling is the reason this is a class rather than a `BytesBuilder`: a
/// builder grows until the process dies, and the whole defence against a
/// decompression bomb is that this one refuses to.
final class _Output {
  _Output(this._limit, this._budget);

  final int _limit;
  final String _budget;
  Uint8List _bytes = Uint8List(0);
  int _length = 0;

  void write(int byte) {
    if (_length == _limit) throw _overflow();
    if (_length == _bytes.length) _grow(_length + 1);
    _bytes[_length++] = byte;
  }

  /// An LZ77 back-reference: [length] bytes starting [distance] back.
  ///
  /// The copy is deliberately byte at a time and forwards, because the ranges
  /// are allowed to overlap - `distance: 1, length: 100` is how DEFLATE spells
  /// a run of a hundred equal bytes, and a block move would read the tail
  /// before it was written.
  void copy(int distance, int length) {
    if (distance > _length) {
      throw InflateException(
        'a back-reference of $distance bytes points before the start of the '
        '$_length bytes produced so far',
      );
    }
    if (_length + length > _limit) throw _overflow();
    if (_length + length > _bytes.length) _grow(_length + length);
    int from = _length - distance;
    for (int i = 0; i < length; i++) {
      _bytes[_length++] = _bytes[from++];
    }
  }

  ImageBudgetException _overflow() => ImageBudgetException(
        budget: _budget,
        limit: _limit,
        actual: _limit + 1,
        message: 'the compressed data expands past the $_limit-byte limit; '
            'inflating was stopped rather than allowed to continue',
      );

  void _grow(int needed) {
    int capacity = _bytes.isEmpty ? 1024 : _bytes.length * 2;
    while (capacity < needed) {
      capacity *= 2;
    }
    if (capacity > _limit) capacity = _limit;
    final Uint8List grown = Uint8List(capacity);
    grown.setRange(0, _length, _bytes);
    _bytes = grown;
  }

  Uint8List toBytes() => Uint8List.sublistView(_bytes, 0, _length);
}
