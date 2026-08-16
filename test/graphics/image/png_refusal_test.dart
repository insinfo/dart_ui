/// Every way the decoder says no, and the name it says it with.
///
/// Section 38.2 treats an image as untrusted input, and the operative half of
/// that is not "it must not crash" - it is that each refusal is *identifiable*.
/// A caller that gets [PngTruncatedException] knows the download stopped early;
/// one that gets [PngChecksumException] knows the bytes were corrupted; one
/// that gets [ImageBudgetException] knows which of its own limits it should
/// consider raising. "Failed to load" tells nobody anything.
///
/// So there is one test per exception class here, and the budget ones assert on
/// the budget's *name* as well, because "too big" and "expands past what its
/// own header promised" are different attacks.
library;

import 'dart:typed_data';

import 'package:dart_ui/src/graphics/image/image_errors.dart';
import 'package:dart_ui/src/graphics/image/png.dart';
import 'package:test/test.dart';

import 'png_fixtures.dart';

/// A well-formed two-by-two greyscale file, as the thing every fixture below
/// breaks exactly one part of.
Uint8List _valid({int width = 2, int height = 2}) => buildPng(
      width: width,
      height: height,
      colorType: 0,
      filteredRows: unfilteredRows(<List<int>>[
        for (int y = 0; y < height; y++)
          <int>[for (int x = 0; x < width; x++) (x + y * 10) & 0xFF],
      ]),
    );

Matcher _refuses<T extends ImageDecodeException>(Object messageMatcher) =>
    throwsA(
      isA<T>().having(
        (T e) => e.message,
        'message',
        messageMatcher,
      ),
    );

void main() {
  test('the fixture this file breaks is itself valid', () {
    expect(decodePng(_valid()).width, 2);
  });

  group('PngSignatureException', () {
    test('a file that is not a PNG at all', () {
      expect(
        () => decodePng(Uint8List.fromList(<int>[0xFF, 0xD8, 0xFF, 0xE0])),
        _refuses<PngSignatureException>(contains('shorter than')),
      );
    });

    test('eight bytes that are the wrong eight bytes', () {
      final Uint8List png = _valid();
      png[1] = 0x50 + 1;
      expect(
        () => decodePng(png),
        _refuses<PngSignatureException>(contains('this is not a PNG')),
      );
    });

    test('an empty file', () {
      expect(
        () => decodePng(Uint8List(0)),
        _refuses<PngSignatureException>(contains('0 bytes')),
      );
    });
  });

  group('PngHeaderException', () {
    test('a colour type the format does not define', () {
      expect(
        () => decodePng(
          buildPng(
              width: 1, height: 1, colorType: 5, filteredRows: <int>[0, 0]),
        ),
        _refuses<PngHeaderException>(contains('colour type 5')),
      );
    });

    test('a bit depth the colour type does not allow', () {
      // Truecolour at 4 bits: a legal depth, an illegal pairing.
      expect(
        () => decodePng(
          buildPng(
            width: 1,
            height: 1,
            colorType: 2,
            bitDepth: 4,
            filteredRows: <int>[0, 0],
          ),
        ),
        _refuses<PngHeaderException>(contains('bit depth of 4')),
      );
    });

    test('a zero dimension', () {
      expect(
        () => decodePng(
          buildPng(width: 0, height: 4, colorType: 0, filteredRows: <int>[0]),
        ),
        _refuses<PngHeaderException>(contains('0x4')),
      );
    });

    test('a compression method other than zero', () {
      expect(
        () => decodePng(
          buildPng(
            width: 1,
            height: 1,
            colorType: 0,
            compression: 1,
            filteredRows: <int>[0, 0],
          ),
        ),
        _refuses<PngHeaderException>(contains('compression method 1')),
      );
    });

    test('a filter method other than zero', () {
      expect(
        () => decodePng(
          buildPng(
            width: 1,
            height: 1,
            colorType: 0,
            filterMethod: 3,
            filteredRows: <int>[0, 0],
          ),
        ),
        _refuses<PngHeaderException>(contains('filter method 3')),
      );
    });

    test('an interlace method that is neither 0 nor 1', () {
      expect(
        () => decodePng(
          buildPng(
            width: 1,
            height: 1,
            colorType: 0,
            interlace: 2,
            filteredRows: <int>[0, 0],
          ),
        ),
        _refuses<PngHeaderException>(contains('interlace method 2')),
      );
    });

    test('IHDR that is not the first chunk', () {
      final BytesBuilder out = BytesBuilder()
        ..add(pngSignature)
        ..add(chunk('tEXt', <int>[65, 0, 66]))
        ..add(Uint8List.sublistView(_valid(), 8));
      expect(
        () => decodePng(out.toBytes()),
        _refuses<PngHeaderException>(contains('requires IHDR to come first')),
      );
    });

    test('a chunk length above the format\'s own cap', () {
      final BytesBuilder out = BytesBuilder()
        ..add(pngSignature)
        ..add(<int>[0xFF, 0xFF, 0xFF, 0xFF, 0x49, 0x48, 0x44, 0x52])
        ..add(List<int>.filled(20, 0));
      expect(
        () => decodePng(out.toBytes()),
        _refuses<PngHeaderException>(contains('2147483647')),
      );
    });
  });

  group('PngUnsupportedException', () {
    test('16 bits per sample is declared absent, not truncated', () {
      expect(
        () => decodePng(
          buildPng(
            width: 1,
            height: 1,
            colorType: 2,
            bitDepth: 16,
            filteredRows: <int>[0, 0, 0, 0, 0, 0, 0],
          ),
        ),
        _refuses<PngUnsupportedException>(contains('16 bits per sample')),
      );
    });

    test('an unknown critical chunk is refused rather than skipped', () {
      expect(
        () => decodePng(
          buildPng(
            width: 1,
            height: 1,
            colorType: 0,
            filteredRows: <int>[0, 0],
            extraChunks: const <(String, List<int>)>[
              ('ZZZZ', <int>[1])
            ],
          ),
        ),
        _refuses<PngUnsupportedException>(contains('critical chunk "ZZZZ"')),
      );
    });

    test('an unknown *ancillary* chunk is not', () {
      expect(
        decodePng(
          buildPng(
            width: 1,
            height: 1,
            colorType: 0,
            filteredRows: <int>[0, 0],
            extraChunks: const <(String, List<int>)>[
              ('zZZz', <int>[1])
            ],
          ),
        ).width,
        1,
      );
    });
  });

  group('PngTruncatedException', () {
    test('a file cut off inside a chunk\'s payload', () {
      final Uint8List whole = _valid(width: 64, height: 64);
      expect(
        () => decodePng(Uint8List.sublistView(whole, 0, whole.length - 30)),
        _refuses<PngTruncatedException>(contains('runs past the end')),
      );
    });

    test('a file cut off inside a chunk header', () {
      final Uint8List whole = _valid();
      expect(
        () => decodePng(Uint8List.sublistView(whole, 0, whole.length - 10)),
        _refuses<PngTruncatedException>(contains('inside a chunk header')),
      );
    });

    test('a file with no IEND', () {
      expect(
        () => decodePng(
          buildPng(
            width: 1,
            height: 1,
            colorType: 0,
            filteredRows: <int>[0, 0],
            includeEnd: false,
          ),
        ),
        _refuses<PngTruncatedException>(contains('inside a chunk header')),
      );
    });
  });

  group('PngChecksumException', () {
    test('a corrupt IHDR CRC stops the walk before the header is used', () {
      expect(
        () => decodePng(
          buildPng(
            width: 1,
            height: 1,
            colorType: 0,
            filteredRows: <int>[0, 0],
            corruptCrcOf: 'IHDR',
          ),
        ),
        _refuses<PngChecksumException>(contains('chunk "IHDR"')),
      );
    });

    test('a corrupt IDAT CRC is caught before it is decompressed', () {
      expect(
        () => decodePng(
          buildPng(
            width: 1,
            height: 1,
            colorType: 0,
            filteredRows: <int>[0, 0],
            corruptCrcOf: 'IDAT',
          ),
        ),
        _refuses<PngChecksumException>(contains('chunk "IDAT"')),
      );
    });

    test('a single flipped bit anywhere in a payload is caught', () {
      final Uint8List png = _valid(width: 16, height: 16);
      // The last IDAT byte before its CRC; a flip here changes the compressed
      // data and nothing else.
      png[png.length - 17] ^= 0x01;
      expect(() => decodePng(png), throwsA(isA<ImageDecodeException>()));
    });
  });

  group('PngFilterException', () {
    test('a filter byte outside 0..4', () {
      expect(
        () => decodePng(
          buildPng(
            width: 2,
            height: 1,
            colorType: 0,
            filteredRows: <int>[5, 1, 2],
          ),
        ),
        _refuses<PngFilterException>(contains('filter type 5')),
      );
    });

    test('the message names all five filters, so the fix is in the error', () {
      try {
        decodePng(
          buildPng(
            width: 1,
            height: 1,
            colorType: 0,
            filteredRows: <int>[9, 0],
          ),
        );
        fail('expected a refusal');
      } on PngFilterException catch (error) {
        expect(error.message, contains('Paeth'));
      }
    });
  });

  group('PngDataException', () {
    test('IHDR lying about the size: the header promises more than IDAT has',
        () {
      // 64x64 greyscale needs 64 * (1 + 64) = 4160 bytes; this carries one row.
      expect(
        () => decodePng(
          buildPng(
            width: 64,
            height: 64,
            colorType: 0,
            filteredRows: <int>[0, ...List<int>.filled(64, 7)],
          ),
        ),
        _refuses<PngDataException>(
          allOf(contains('needs 4160'), contains('expands to 65')),
        ),
      );
    });

    test('a file with no IDAT at all', () {
      expect(
        () => decodePng(
          buildPng(width: 1, height: 1, colorType: 0, includeIdat: false),
        ),
        _refuses<PngDataException>(contains('no IDAT')),
      );
    });

    test('an indexed image with no PLTE', () {
      expect(
        () => decodePng(
          buildPng(
            width: 1,
            height: 1,
            colorType: 3,
            filteredRows: <int>[0, 0],
          ),
        ),
        _refuses<PngDataException>(contains('no PLTE')),
      );
    });

    test('a PLTE whose length is not a whole number of entries', () {
      expect(
        () => decodePng(
          buildPng(
            width: 1,
            height: 1,
            colorType: 3,
            palette: <int>[1, 2, 3, 4],
            filteredRows: <int>[0, 0],
          ),
        ),
        _refuses<PngDataException>(contains('three-byte entries')),
      );
    });

    test('a pixel that indexes a palette entry that does not exist', () {
      expect(
        () => decodePng(
          buildPng(
            width: 2,
            height: 1,
            colorType: 3,
            palette: <int>[1, 2, 3, 4, 5, 6],
            filteredRows: <int>[0, 0, 9],
          ),
        ),
        _refuses<PngDataException>(contains('palette entry 9')),
      );
    });

    test('IDAT chunks that are not consecutive', () {
      final Uint8List valid = _valid();
      final List<int> compressed = zlibStored(
        Uint8List.fromList(
          unfilteredRows(<List<int>>[
            <int>[0, 1],
            <int>[2, 3],
          ]),
        ),
      );
      final BytesBuilder out = BytesBuilder()
        ..add(Uint8List.sublistView(valid, 0, 8 + 25))
        ..add(chunk('IDAT', compressed.sublist(0, 4)))
        ..add(chunk('tEXt', <int>[65, 0, 66]))
        ..add(chunk('IDAT', compressed.sublist(4)))
        ..add(chunk('IEND', const <int>[]));
      expect(
        () => decodePng(out.toBytes()),
        _refuses<PngDataException>(contains('consecutive')),
      );
    });

    test('an IEND that carries data', () {
      final Uint8List valid = _valid();
      final BytesBuilder out = BytesBuilder()
        ..add(Uint8List.sublistView(valid, 0, valid.length - 12))
        ..add(chunk('IEND', <int>[1, 2]));
      expect(
        () => decodePng(out.toBytes()),
        _refuses<PngDataException>(contains('IEND carries 2 bytes')),
      );
    });

    test('a chunk type that is not four ASCII letters', () {
      final Uint8List valid = _valid();
      final BytesBuilder out = BytesBuilder()
        ..add(pngSignature)
        ..add(<int>[0, 0, 0, 0, 0x49, 0x48, 0x44, 0x00])
        ..add(List<int>.filled(4, 0))
        ..add(Uint8List.sublistView(valid, 8));
      expect(
        () => decodePng(out.toBytes()),
        _refuses<PngDataException>(contains('four ASCII letters')),
      );
    });
  });

  group('ImageBudgetException', () {
    test('an absurd dimension is refused before anything is allocated', () {
      expect(
        () => decodePng(
          buildPng(
            width: 100000,
            height: 1,
            colorType: 0,
            filteredRows: <int>[0, 0],
          ),
        ),
        throwsA(
          isA<ImageBudgetException>()
              .having((ImageBudgetException e) => e.budget, 'budget',
                  'maxDimension')
              .having((ImageBudgetException e) => e.limit, 'limit', 16384)
              .having((ImageBudgetException e) => e.actual, 'actual', 100000),
        ),
      );
    });

    test('a pixel count that no axis limit would have caught', () {
      // 10000 x 10000 is inside maxDimension on both axes and a hundred
      // megapixels together - four hundred megabytes of output.
      expect(
        () => decodePng(
          buildPng(
            width: 10000,
            height: 10000,
            colorType: 0,
            filteredRows: <int>[0, 0],
          ),
        ),
        throwsA(
          isA<ImageBudgetException>()
              .having(
                  (ImageBudgetException e) => e.budget, 'budget', 'maxPixels')
              .having(
                  (ImageBudgetException e) => e.actual, 'actual', 100000000),
        ),
      );
    });

    test('a decompression bomb stops at what IHDR asked for', () {
      // Four megabytes of zeroes behind a two-by-two header. Nothing here ever
      // allocates four megabytes: the inflater is capped at the six bytes the
      // header implies and stops there.
      final Uint8List bomb = zlibDeflate(Uint8List(4 << 20), level: 9);
      expect(bomb.length, lessThan(8192));
      expect(
        () => decodePng(
          buildPng(width: 2, height: 2, colorType: 0, compressedIdat: bomb),
        ),
        throwsA(
          isA<ImageBudgetException>()
              .having((ImageBudgetException e) => e.budget, 'budget',
                  'idatRawBytes')
              .having((ImageBudgetException e) => e.limit, 'limit', 6),
        ),
      );
    });

    test('the absolute ceiling binds when it is the lower of the two', () {
      expect(
        () => decodePng(
          _valid(),
          limits: const PngLimits(maxDecompressedBytes: 4),
        ),
        throwsA(
          isA<ImageBudgetException>().having(
            (ImageBudgetException e) => e.budget,
            'budget',
            'maxDecompressedBytes',
          ),
        ),
      );
    });

    test('the limits are the caller\'s: a raised one admits the same file', () {
      expect(
        decodePng(
          buildPng(
            width: 20000,
            height: 1,
            colorType: 0,
            filteredRows: <int>[0, ...List<int>.filled(20000, 3)],
          ),
          limits: const PngLimits(maxDimension: 32768),
        ).width,
        20000,
      );
    });
  });

  group('InflateException', () {
    test('an IDAT that is not a zlib stream at all', () {
      expect(
        () => decodePng(
          buildPng(
            width: 1,
            height: 1,
            colorType: 0,
            compressedIdat: <int>[1, 2, 3, 4, 5, 6, 7, 8],
          ),
        ),
        _refuses<InflateException>(
            anyOf(contains('zlib'), contains('DEFLATE'))),
      );
    });

    test('an IDAT whose Adler-32 does not match', () {
      final Uint8List stream = zlibStored(
        Uint8List.fromList(unfilteredRows(<List<int>>[
          <int>[1, 2],
          <int>[3, 4],
        ])),
      );
      stream[stream.length - 1] ^= 0xFF;
      expect(
        () => decodePng(
          buildPng(
            width: 2,
            height: 2,
            colorType: 0,
            compressedIdat: stream,
          ),
        ),
        _refuses<InflateException>(contains('Adler-32')),
      );
    });
  });

  test('every refusal is an ImageDecodeException, so one catch covers them all',
      () {
    final List<Uint8List> broken = <Uint8List>[
      Uint8List.fromList(<int>[1, 2, 3]),
      buildPng(width: 1, height: 1, colorType: 9, filteredRows: <int>[0, 0]),
      buildPng(
        width: 1,
        height: 1,
        colorType: 0,
        filteredRows: <int>[0, 0],
        corruptCrcOf: 'IDAT',
      ),
      buildPng(width: 1, height: 1, colorType: 0, includeIdat: false),
    ];
    for (final Uint8List bytes in broken) {
      expect(
        () => decodePng(bytes),
        throwsA(isA<ImageDecodeException>()),
        reason: '${bytes.length} bytes',
      );
    }
  });
}
