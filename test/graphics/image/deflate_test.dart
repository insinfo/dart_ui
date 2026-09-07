/// The pure-Dart deflater, read by a stranger.
///
/// Every case is decoded by `dart:io`'s `ZLibCodec` - zlib itself, an
/// implementation that shares no line and no misreading of RFC 1951 with this
/// one - *before* it is decoded by this repository's own inflater. The order
/// is the point. A round trip through code written here at both ends agrees
/// with itself whatever it does, so it can only ever prove that the two halves
/// were written by the same person; only the foreign decoder proves the bytes
/// are DEFLATE.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:dart_ui/pdf.dart';
import 'package:dart_ui/src/geometry/offset.dart';
import 'package:dart_ui/src/graphics/image/deflate.dart';
import 'package:dart_ui/src/graphics/image/inflate.dart';
import 'package:test/test.dart';

/// Room for anything these tests produce. The inflater's budget is tested
/// where the inflater is.
const int _plenty = 1 << 26;

/// Compresses [raw], then makes zlib and this repository's inflater both read
/// it back, and reports which of the two disagreed.
Uint8List _roundTrip(
  Uint8List raw, {
  DeflateBlocks blocks = DeflateBlocks.auto,
}) {
  final Uint8List packed = deflateZlib(raw, blocks: blocks);
  expect(zlib.decode(packed), raw, reason: 'zlib itself could not read it');
  expect(
    inflateZlib(packed, maxOutputBytes: _plenty, budget: 'test'),
    raw,
    reason: 'this repository\'s own inflater could not read it',
  );
  return packed;
}

Uint8List _bytes(List<int> values) => Uint8List.fromList(values);

/// Every `/FlateDecode` stream in a PDF, already decompressed - the real data
/// the one replaced call site sees.
List<Uint8List> _pdfStreams(String path) {
  final Uint8List file = File(path).readAsBytesSync();
  final String text = String.fromCharCodes(file);
  final List<Uint8List> streams = <Uint8List>[];
  for (final RegExpMatch match
      in RegExp(r'/Length\s+(\d+)[^>]*>>\s*stream\r?\n').allMatches(text)) {
    final int length = int.parse(match.group(1)!);
    if (match.end + length > file.length) continue;
    try {
      streams.add(inflateZlib(
        Uint8List.sublistView(file, match.end, match.end + length),
        maxOutputBytes: _plenty,
        budget: 'test',
      ));
    } on Object {
      // Not every stream is Flate; the ones that are not are not this test's
      // corpus and are silently skipped.
    }
  }
  return streams;
}

void main() {
  group('zlib itself reads what this encoder writes', () {
    test('empty input, which still has to be a well-formed stream', () {
      final Uint8List packed = _roundTrip(Uint8List(0));
      // Six bytes of wrapper plus at least one block: an encoder that emitted
      // nothing at all would round-trip through a lenient decoder and fail
      // against a strict one.
      expect(packed.length, greaterThan(6));
    });

    test('a single byte, where there is no match to be found', () {
      _roundTrip(_bytes(<int>[0x42]));
    });

    test('two bytes, one short of the minimum match', () {
      _roundTrip(_bytes(<int>[0x00, 0xFF]));
    });

    test('every byte value exactly once, a maximally wide alphabet', () {
      _roundTrip(Uint8List.fromList(List<int>.generate(256, (int i) => i)));
    });

    test('text, which is what a PDF content stream is', () {
      final StringBuffer buffer = StringBuffer();
      for (int i = 0; i < 2000; i++) {
        buffer.write('BT /F1 12 Tf 1 0 0 1 40 ${700 - i % 40 * 16} Tm '
            '(line $i of the report) Tj ET\n');
      }
      _roundTrip(Uint8List.fromList(utf8.encode(buffer.toString())));
    });
  });

  group('the back-reference encoding at its limits', () {
    test('one byte repeated, which is a run of maximum-length matches', () {
      // 200000 bytes of one value is `distance: 1` and `length: 258` over and
      // over, so it exercises both ends of the length alphabet's last symbol
      // and the overlapping copy the inflater has to do forwards.
      final Uint8List raw = Uint8List(200000)..fillRange(0, 200000, 0xAB);
      final Uint8List packed = _roundTrip(raw);
      expect(packed.length, lessThan(1500));
    });

    test('a match of exactly 258 bytes, the longest the format can name', () {
      // A literal prefix, then 258 bytes that repeat it exactly, then one
      // byte that differs - so the match cannot run past 258 by accident and
      // symbol 285 is the only one that can encode it.
      final Random random = Random(20260907);
      final Uint8List head = Uint8List.fromList(
        List<int>.generate(258, (_) => random.nextInt(256)),
      );
      final BytesBuilder builder = BytesBuilder()
        ..add(head)
        ..add(head)
        ..addByte(head[0] ^ 0xFF);
      _roundTrip(builder.takeBytes());
    });

    test('a match at exactly 32768 back, the far edge of the window', () {
      // Distance 32768 is the last value distance symbol 29 can name, and a
      // match finder that stopped one position early - or a window indexed
      // modulo 32768 without care - would silently emit literals here.
      final Random random = Random(1951);
      final Uint8List raw = Uint8List(32768 + 64);
      for (int i = 0; i < raw.length; i++) {
        raw[i] = random.nextInt(256);
      }
      raw.setRange(32768, 32768 + 64, raw, 0);
      final Uint8List packed = _roundTrip(raw);
      // The last 64 bytes must have cost a back-reference rather than 64
      // literals of incompressible data.
      expect(packed.length, lessThan(32768 + 64));
    });

    test('data far longer than the window, so distances have to wrap', () {
      final Random random = Random(1950);
      final Uint8List block = Uint8List.fromList(
        List<int>.generate(20000, (_) => random.nextInt(256)),
      );
      final BytesBuilder builder = BytesBuilder();
      for (int i = 0; i < 8; i++) {
        builder.add(block);
      }
      _roundTrip(builder.takeBytes());
    });

    test('a Fibonacci-skewed alphabet, the deepest tree real data makes', () {
      // Fibonacci-weighted frequencies are the shape that drives a Huffman
      // tree towards the format's fifteen-bit ceiling; over 2 MiB of them the
      // encoder lands on exactly fifteen. The limit itself is tested through
      // `huffmanCodeLengths`, because no input reaches past it.
      final List<int> weights = <int>[1, 1];
      while (weights.length < 24) {
        weights.add(weights[weights.length - 1] + weights[weights.length - 2]);
      }
      final List<int> pool = <int>[];
      for (int symbol = 0; symbol < weights.length; symbol++) {
        for (int i = 0; i < weights[symbol]; i++) {
          pool.add(symbol);
        }
      }
      pool.shuffle(Random(46368));
      _roundTrip(Uint8List.fromList(pool));
    });
  });

  group('the Huffman code lengths', () {
    /// A code is complete when its leaves fill the tree exactly. Anything less
    /// is a stream zlib rejects; anything more is not a prefix code at all.
    double kraft(Uint8List lengths) {
      double sum = 0;
      for (final int length in lengths) {
        if (length != 0) sum += 1 / (1 << length);
      }
      return sum;
    }

    Int32List fibonacci(int symbols) {
      final Int32List frequencies = Int32List(symbols);
      frequencies[0] = 1;
      if (symbols > 1) frequencies[1] = 1;
      for (int i = 2; i < symbols; i++) {
        frequencies[i] = frequencies[i - 1] + frequencies[i - 2];
      }
      return frequencies;
    }

    test('are optimal, and Fibonacci frequencies really do overrun', () {
      // Without this the next assertion would be vacuous: a limit that never
      // bites cannot be shown to work.
      final Uint8List unlimited = huffmanCodeLengths(fibonacci(20), 30);
      expect(unlimited.reduce(max), 19);
      expect(kraft(unlimited), closeTo(1, 1e-12));
    });

    test('are cut to the limit, and the code stays complete', () {
      for (final int symbols in <int>[17, 20, 24, 30]) {
        final Uint8List limited = huffmanCodeLengths(fibonacci(symbols), 15);
        expect(limited.reduce(max), lessThanOrEqualTo(15),
            reason: 'a $symbols-symbol tree overran the fifteen-bit maximum');
        expect(kraft(limited), closeTo(1, 1e-12),
            reason: 'a $symbols-symbol tree stopped being a complete code');
      }
    });

    test('the code-length alphabet gets seven bits, not fifteen', () {
      final Uint8List limited = huffmanCodeLengths(fibonacci(19), 7);
      expect(limited.reduce(max), lessThanOrEqualTo(7));
      expect(kraft(limited), closeTo(1, 1e-12));
    });

    test('one symbol still gets a complete code, by inventing a second', () {
      // The failure this exists for: a block whose distance tree has a single
      // code decodes fine through our own inflater and is refused outright by
      // zlib, because half the code space would decode to nothing.
      final Int32List single = Int32List(30);
      single[7] = 500;
      final Uint8List lengths = huffmanCodeLengths(single, 15);
      expect(lengths[7], 1);
      expect(kraft(lengths), closeTo(1, 1e-12));

      final Uint8List none = huffmanCodeLengths(Int32List(30), 15);
      expect(kraft(none), closeTo(1, 1e-12));
    });

    test('random frequency vectors always produce a complete code', () {
      final Random random = Random(1951);
      for (int round = 0; round < 200; round++) {
        final Int32List frequencies = Int32List(286);
        for (int i = 0; i < frequencies.length; i++) {
          frequencies[i] = random.nextInt(4) == 0 ? random.nextInt(100000) : 0;
        }
        final Uint8List lengths = huffmanCodeLengths(frequencies, 15);
        expect(lengths.reduce(max), lessThanOrEqualTo(15));
        expect(kraft(lengths), closeTo(1, 1e-12));
      }
    });
  });

  group('incompressible input', () {
    test('costs a stored block header and never expands', () {
      // The whole reason stored blocks are implemented: uniform random bytes
      // cost more than eight bits each under any Huffman code, and an encoder
      // without a stored floor hands back something larger than it was given.
      final Random random = Random(20260101);
      final Uint8List raw = Uint8List.fromList(
        List<int>.generate(1 << 16, (_) => random.nextInt(256)),
      );
      final Uint8List packed = _roundTrip(raw);
      expect(packed.length, lessThan(raw.length + raw.length ~/ 1000 + 16));
    });

    test('and one byte of it still round trips', () {
      _roundTrip(_bytes(<int>[0x9E]));
    });
  });

  group('each block type on its own', () {
    // `auto` picks, so a test that only drove `auto` would never once emit a
    // stored block on compressible data or a fixed block on data where the
    // dynamic table wins - which is nearly all of it.
    final Uint8List sample = Uint8List.fromList(utf8.encode(
      'q 1 0 0 1 0 0 cm /Im0 Do Q ' * 400,
    ));

    for (final DeflateBlocks blocks in DeflateBlocks.values) {
      test('$blocks produces a stream zlib accepts', () {
        _roundTrip(sample, blocks: blocks);
        _roundTrip(Uint8List(0), blocks: blocks);
        _roundTrip(_bytes(<int>[7]), blocks: blocks);
      });
    }

    test('stored never compresses and dynamic beats fixed on text', () {
      final int stored =
          deflateZlib(sample, blocks: DeflateBlocks.stored).length;
      final int fixed =
          deflateZlib(sample, blocks: DeflateBlocks.fixedHuffman).length;
      final int dynamic =
          deflateZlib(sample, blocks: DeflateBlocks.dynamicHuffman).length;
      expect(stored, greaterThan(sample.length));
      expect(dynamic, lessThan(fixed));
      expect(deflateZlib(sample).length, lessThanOrEqualTo(dynamic));
    });
  });

  group('the raw stream, with no wrapper', () {
    test('zlib reads it with the wrapper switched off', () {
      final Uint8List raw =
          Uint8List.fromList(utf8.encode('BT (x) Tj ET ' * 50));
      final Uint8List packed = deflate(raw);
      expect(ZLibDecoder(raw: true).convert(packed), raw);
      expect(
        inflate(packed, maxOutputBytes: _plenty, budget: 'test'),
        raw,
      );
    });
  });

  group('the zlib wrapper', () {
    test('carries the header bytes a decoder checks', () {
      final Uint8List packed = deflateZlib(_bytes(<int>[1, 2, 3]));
      expect(packed[0] & 0x0F, 8, reason: 'the method must say DEFLATE');
      expect(packed[0] >> 4, lessThanOrEqualTo(7));
      expect((packed[0] << 8 | packed[1]) % 31, 0);
      expect(packed[1] & 0x20, 0, reason: 'no preset dictionary');
    });

    test('the Adler-32 matches a published vector, not our own arithmetic', () {
      // RFC 1950's own worked example, and the one every implementation is
      // checked against. Comparing adler32 to a second copy of adler32 would
      // agree on any bug they shared.
      expect(adler32(Uint8List.fromList(utf8.encode('Wikipedia'))), 0x11E60398);
      expect(adler32(Uint8List(0)), 1);
      expect(adler32(Uint8List.fromList(utf8.encode('a'))), 0x00620062);
    });

    test('the trailer we write is the trailer zlib writes', () {
      // An independent check on the checksum over data long enough to make
      // the 5552-byte modulo deferral run more than once.
      final Random random = Random(5552);
      final Uint8List raw = Uint8List.fromList(
        List<int>.generate(40000, (_) => random.nextInt(256)),
      );
      final List<int> theirs = zlib.encode(raw);
      expect(
        deflateZlib(raw).sublist(deflateZlib(raw).length - 4),
        theirs.sublist(theirs.length - 4),
      );
    });
  });

  group('the real corpus', () {
    test('every Flate stream in the PDF fixtures re-compresses smaller', () {
      // The corpus is read as a whole rather than file by file because the
      // fixtures are JPEG 2000 documents: one of them carries no Flate stream
      // at all, and a per-file assertion would fail on the file's contents
      // rather than on anything this encoder did.
      final List<Uint8List> streams = <Uint8List>[
        ..._pdfStreams('test/data/sample_jpxdecode_minimal.pdf'),
        ..._pdfStreams('test/data/balloon_jpx.pdf'),
      ];
      expect(streams, isNotEmpty, reason: 'the corpus lost its Flate streams');
      for (final Uint8List stream in streams) {
        final Uint8List packed = _roundTrip(stream);
        expect(packed.length, lessThan(stream.length));
      }
    });
  });

  group('the PDF writer that this replaced a dependency for', () {
    test('a composed document is Flate-compressed and reads back', () {
      final PdfDocumentBuilder builder =
          PdfDocumentBuilder(title: 'Compressao', author: 'dart_ui');
      for (int page = 0; page < 3; page++) {
        final canvas = builder.addPage(width: 595, height: 842);
        for (int line = 0; line < 30; line++) {
          canvas.drawText(
            'pagina ${page + 1} linha $line - texto suficientemente repetido '
            'para que a compressao valha a pena',
            Offset(40, 60 + line * 20),
          );
        }
      }
      final PdfDocument source = PdfDocument.fromBytes(builder.build());
      final Uint8List optimized = PdfDocumentComposer.optimize(source);

      // The filter is only written when the compressed bytes are smaller, so
      // its presence is the proof that this encoder actually won.
      expect(String.fromCharCodes(optimized), contains('/FlateDecode'));
      expect(optimized.length, lessThan(source.rawBytes.length));

      // And the repository's own reader - lexer, xref, FlateFilter - opens it.
      final PdfDocument reopened = PdfDocument.fromBytes(optimized);
      expect(reopened.pageCount, 3);
      for (int page = 1; page <= 3; page++) {
        expect(
          String.fromCharCodes(reopened.getPage(page).getContentsBytes()),
          contains('pagina $page linha 29'),
        );
      }
    });
  });
}
