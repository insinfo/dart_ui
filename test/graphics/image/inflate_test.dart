/// The pure-Dart inflater, against the platform's own zlib.
///
/// The differential shape is the point: `dart:io`'s `ZLibCodec` produces the
/// bytes and this repository's inflater reads them, so a round trip through
/// code written here at both ends - which would agree with itself whatever it
/// did - is never what is being asserted. Only the refusals, and the stored
/// blocks the platform encoder will not emit on request, are hand-built.
library;

import 'dart:math';
import 'dart:typed_data';

import 'package:dart_ui/src/graphics/image/image_errors.dart';
import 'package:dart_ui/src/graphics/image/inflate.dart' as subject;
import 'package:dart_ui/src/graphics/image/inflate.dart' show inflateZlib;
import 'package:test/test.dart';

import 'png_fixtures.dart';

/// Room for any output these tests produce; the budget itself is tested
/// separately, and a limit that also bound the ordinary cases would make every
/// other failure ambiguous.
const int _plenty = 1 << 20;

Uint8List _inflate(Uint8List bytes) =>
    inflateZlib(bytes, maxOutputBytes: _plenty, budget: 'test');

void main() {
  group('round trips against the platform encoder', () {
    test('an empty stream', () {
      expect(_inflate(zlibDeflate(Uint8List(0))), isEmpty);
    });

    test('a run of one byte, which is the LZ77 overlapping copy', () {
      // `distance: 1, length: n` is how DEFLATE spells a run, and a copy that
      // read the whole source before writing would produce garbage after the
      // first byte.
      final Uint8List raw = Uint8List(5000)..fillRange(0, 5000, 0xAB);
      expect(_inflate(zlibDeflate(raw)), raw);
    });

    test('incompressible bytes, which force a stored or near-stored block', () {
      final Random random = Random(20260815);
      final Uint8List raw = Uint8List.fromList(
        List<int>.generate(4096, (_) => random.nextInt(256)),
      );
      expect(_inflate(zlibDeflate(raw)), raw);
    });

    test('text long enough to need a dynamic Huffman table', () {
      // Level 9 over a hundred kilobytes of structured text is where the
      // encoder builds its own code lengths rather than using the fixed table.
      final StringBuffer text = StringBuffer();
      for (int i = 0; i < 4000; i++) {
        text.write('the quick brown fox jumps over the lazy dog $i\n');
      }
      final Uint8List raw = Uint8List.fromList(text.toString().codeUnits);
      expect(_inflate(zlibDeflate(raw, level: 9)), raw);
    });

    test('every byte value, at every compression level', () {
      final Uint8List raw = Uint8List.fromList(
        List<int>.generate(256 * 7, (int i) => (i * 31) & 0xFF),
      );
      for (int level = 1; level <= 9; level++) {
        expect(
          _inflate(zlibDeflate(raw, level: level)),
          raw,
          reason: 'level $level',
        );
      }
    });
  });

  group('stored blocks', () {
    test('a hand-built stored stream inflates', () {
      final Uint8List raw =
          Uint8List.fromList(List<int>.generate(300, (int i) => i & 0xFF));
      expect(_inflate(zlibStored(raw)), raw);
    });

    test('several stored blocks are concatenated', () {
      final Uint8List raw =
          Uint8List.fromList(List<int>.generate(300, (int i) => i & 0xFF));
      expect(_inflate(zlibStored(raw, blockSize: 64)), raw);
    });

    test('a length that disagrees with its complement is refused', () {
      final Uint8List stream = zlibStored(Uint8List.fromList(<int>[1, 2, 3]));
      // Bytes 2..6 are the block header: BFINAL/BTYPE, then LEN and NLEN.
      stream[3] = 0x09; // LEN low byte, now disagreeing with NLEN
      expect(
        () => _inflate(stream),
        throwsA(
          isA<InflateException>().having(
            (InflateException e) => e.message,
            'message',
            contains('complement'),
          ),
        ),
      );
    });
  });

  group('refusals', () {
    test('a stream shorter than its own header and trailer', () {
      expect(
        () => _inflate(Uint8List.fromList(<int>[0x78, 0x01])),
        throwsA(isA<InflateException>()),
      );
    });

    test('a compression method that is not DEFLATE', () {
      final Uint8List stream = zlibDeflate(Uint8List.fromList(<int>[1, 2, 3]));
      stream[0] = 0x79; // CM = 9
      expect(
        () => _inflate(stream),
        throwsA(
          isA<InflateException>().having(
            (InflateException e) => e.message,
            'message',
            contains('not DEFLATE'),
          ),
        ),
      );
    });

    test('a header whose check bits do not divide by 31', () {
      final Uint8List stream = zlibDeflate(Uint8List.fromList(<int>[1, 2, 3]));
      stream[1] = (stream[1] + 1) & 0xFF;
      expect(
        () => _inflate(stream),
        throwsA(
          isA<InflateException>().having(
            (InflateException e) => e.message,
            'message',
            anyOf(contains('31'), contains('preset dictionary')),
          ),
        ),
      );
    });

    test('a preset dictionary is named, not guessed at', () {
      // FDICT is bit 5 of FLG, and the check bits have to be fixed up
      // afterwards or the earlier test catches it instead.
      final Uint8List stream = zlibDeflate(Uint8List.fromList(<int>[1, 2, 3]));
      final int flg = List<int>.generate(256, (int i) => i).firstWhere(
        (int candidate) =>
            candidate & 0x20 != 0 && (stream[0] << 8 | candidate) % 31 == 0,
      );
      stream[1] = flg;
      expect(
        () => _inflate(stream),
        throwsA(
          isA<InflateException>().having(
            (InflateException e) => e.message,
            'message',
            contains('preset dictionary'),
          ),
        ),
      );
    });

    test('a truncated stream stops rather than reading past the end', () {
      final Uint8List raw = Uint8List(4000)..fillRange(0, 4000, 7);
      final Uint8List whole = zlibDeflate(raw);
      final Uint8List cut = Uint8List.sublistView(whole, 0, whole.length ~/ 2);
      expect(
        () => _inflate(cut),
        throwsA(
          isA<InflateException>().having(
            (InflateException e) => e.message,
            'message',
            contains('ends in the middle'),
          ),
        ),
      );
    });

    test('a corrupt Adler-32 is caught even when the bits inflate', () {
      final Uint8List stream =
          zlibStored(Uint8List.fromList(<int>[9, 8, 7, 6]));
      stream[stream.length - 1] ^= 0xFF;
      expect(
        () => _inflate(stream),
        throwsA(
          isA<InflateException>().having(
            (InflateException e) => e.message,
            'message',
            contains('Adler-32'),
          ),
        ),
      );
    });

    test('block type 3 is reserved and is refused by name', () {
      // BFINAL=1, BTYPE=11 in the first byte after the zlib header.
      final Uint8List stream =
          Uint8List.fromList(<int>[0x78, 0x01, 0x07, 0, 0, 0, 0, 0]);
      expect(
        () => _inflate(stream),
        throwsA(
          isA<InflateException>().having(
            (InflateException e) => e.message,
            'message',
            contains('reserved'),
          ),
        ),
      );
    });

    test('a back-reference before the start of the output is refused', () {
      // A fixed-Huffman block: literal 'A', then length 3 / distance 5, which
      // points four bytes before anything has been written.
      final _BitWriter bits = _BitWriter()
        ..write(1, 1) // BFINAL
        ..write(1, 2) // BTYPE = fixed
        ..writeFixedLiteral(0x41)
        ..writeFixedLiteral(257) // length 3, no extra bits
        ..write(4, 5); // distance code 4 -> base 5, 1 extra bit
      // Distance code 4 carries one extra bit; a zero keeps the base of 5.
      bits.write(0, 1);
      final Uint8List stream = Uint8List.fromList(<int>[
        0x78,
        0x01,
        ...bits.bytes,
        0,
        0,
        0,
        0,
      ]);
      expect(
        () => _inflate(stream),
        throwsA(
          isA<InflateException>().having(
            (InflateException e) => e.message,
            'message',
            contains('points before the start'),
          ),
        ),
      );
    });
  });

  group('the output budget', () {
    test('a bomb is stopped at the limit, by name', () {
      // Forty megabytes of zeroes compress to a few hundred bytes. Nothing here
      // ever allocates forty megabytes.
      final Uint8List bomb = zlibDeflate(Uint8List(40 << 20), level: 9);
      expect(bomb.length, lessThan(64 * 1024));
      expect(
        () => inflateZlib(bomb, maxOutputBytes: 4096, budget: 'idatRawBytes'),
        throwsA(
          isA<ImageBudgetException>()
              .having((ImageBudgetException e) => e.budget, 'budget',
                  'idatRawBytes')
              .having((ImageBudgetException e) => e.limit, 'limit', 4096),
        ),
      );
    });

    test('a stream that fits exactly is not refused', () {
      final Uint8List raw = Uint8List(1000)..fillRange(0, 1000, 3);
      expect(
        inflateZlib(zlibDeflate(raw), maxOutputBytes: 1000, budget: 'exact'),
        hasLength(1000),
      );
    });

    test('one byte over the limit is refused', () {
      final Uint8List raw = Uint8List(1001)..fillRange(0, 1001, 3);
      expect(
        () => inflateZlib(zlibDeflate(raw),
            maxOutputBytes: 1000, budget: 'tight'),
        throwsA(
          isA<ImageBudgetException>()
              .having((ImageBudgetException e) => e.budget, 'budget', 'tight'),
        ),
      );
    });

    test('the stored path honours the same limit', () {
      final Uint8List raw = Uint8List(500);
      expect(
        () => inflateZlib(
          zlibStored(raw),
          maxOutputBytes: 100,
          budget: 'stored',
        ),
        throwsA(isA<ImageBudgetException>()),
      );
    });
  });

  test('adler32 matches the definition in RFC 1950', () {
    // The specification's own worked property: the running sums of "Wikipedia"
    // are 0x11E60398.
    expect(
      subject.adler32(Uint8List.fromList('Wikipedia'.codeUnits)),
      0x11E60398,
    );
    expect(subject.adler32(Uint8List(0)), 1);
    // And against the fixtures' own independent implementation, over a range
    // long enough to cross the 5552-byte deferred-modulo run.
    final Uint8List long =
        Uint8List.fromList(List<int>.generate(20000, (int i) => i & 0xFF));
    expect(subject.adler32(long), adler32(long));
  });
}

/// A least-significant-bit-first bit writer, for the two malformed streams that
/// cannot be produced any other way.
final class _BitWriter {
  final List<int> bytes = <int>[];
  int _buffer = 0;
  int _count = 0;

  void write(int value, int width) {
    for (int i = 0; i < width; i++) {
      _buffer |= (value >> i & 1) << _count;
      if (++_count == 8) {
        bytes.add(_buffer);
        _buffer = 0;
        _count = 0;
      }
    }
  }

  /// A symbol in RFC 1951's fixed literal/length code, which is written
  /// **most** significant bit first even though everything around it is not.
  void writeFixedLiteral(int symbol) {
    final (int code, int width) = switch (symbol) {
      < 144 => (0x30 + symbol, 8),
      < 256 => (0x190 + symbol - 144, 9),
      < 280 => (symbol - 256, 7),
      _ => (0xC0 + symbol - 280, 8),
    };
    for (int i = width - 1; i >= 0; i--) {
      write(code >> i & 1, 1);
    }
  }
}
