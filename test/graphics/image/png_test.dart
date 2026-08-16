/// The PNG decoder, on bytes this file wrote.
///
/// Every assertion is on concrete bytes. That is affordable because the
/// fixtures are three pixels wide, and it is necessary because the two things
/// most likely to be wrong about an image decoder - premultiplication and
/// channel order - are both invisible in anything less exact than a byte.
library;

import 'dart:typed_data';

import 'package:dart_ui/src/graphics/image/decoded_image.dart';
import 'package:dart_ui/src/graphics/image/png.dart';
import 'package:test/test.dart';

import 'png_fixtures.dart';

/// The four bytes of the pixel at ([x], [y]), in the image's own order.
List<int> _bytesAt(DecodedImage image, int x, int y) {
  final int offset = (y * image.width + x) * 4;
  return image.pixels.sublist(offset, offset + 4);
}

void main() {
  group('colour types at eight bits', () {
    test('greyscale (0) expands one sample into three channels', () {
      final Uint8List png = buildPng(
        width: 3,
        height: 2,
        colorType: 0,
        filteredRows: unfilteredRows(<List<int>>[
          <int>[0, 128, 255],
          <int>[17, 34, 51],
        ]),
      );

      final DecodedImage image = decodePng(png);
      expect(image.width, 3);
      expect(image.height, 2);
      expect(image.hasAlpha, isFalse);
      expect(_bytesAt(image, 0, 0), <int>[0, 0, 0, 255]);
      expect(_bytesAt(image, 1, 0), <int>[128, 128, 128, 255]);
      expect(_bytesAt(image, 2, 0), <int>[255, 255, 255, 255]);
      expect(_bytesAt(image, 0, 1), <int>[17, 17, 17, 255]);
      expect(_bytesAt(image, 2, 1), <int>[51, 51, 51, 255]);
    });

    test('truecolour (2) keeps the three samples apart', () {
      final Uint8List png = buildPng(
        width: 2,
        height: 2,
        colorType: 2,
        filteredRows: unfilteredRows(<List<int>>[
          <int>[255, 0, 0, 0, 255, 0],
          <int>[0, 0, 255, 10, 20, 30],
        ]),
      );

      final DecodedImage image = decodePng(png);
      // BGRA: blue is byte 0 and red is byte 2, so pure red is [0, 0, 255, a].
      expect(_bytesAt(image, 0, 0), <int>[0, 0, 255, 255]);
      expect(_bytesAt(image, 1, 0), <int>[0, 255, 0, 255]);
      expect(_bytesAt(image, 0, 1), <int>[255, 0, 0, 255]);
      expect(_bytesAt(image, 1, 1), <int>[30, 20, 10, 255]);
      expect(image.argbAt(1, 1), 0xFF0A141E);
    });

    test('indexed (3) resolves through PLTE, and tRNS gives it alpha', () {
      final Uint8List png = buildPng(
        width: 4,
        height: 1,
        colorType: 3,
        palette: <int>[
          255, 0, 0, // 0: red
          0, 255, 0, // 1: green
          0, 0, 255, // 2: blue
          255, 255, 255, // 3: white
        ],
        // Only the first two entries get an alpha; the rest are opaque.
        transparency: <int>[0, 128],
        filteredRows: unfilteredRows(<List<int>>[
          <int>[0, 1, 2, 3],
        ]),
      );

      final DecodedImage image = decodePng(png);
      expect(image.hasAlpha, isTrue);
      // Entry 0 is fully transparent, so premultiplication takes its colour to
      // zero as well - which is the whole point of premultiplying.
      expect(_bytesAt(image, 0, 0), <int>[0, 0, 0, 0]);
      // Entry 1 is green at half alpha: premultiplied green, and nothing else.
      expect(_bytesAt(image, 1, 0), <int>[0, 128, 0, 128]);
      expect(_bytesAt(image, 2, 0), <int>[255, 0, 0, 255]);
      expect(_bytesAt(image, 3, 0), <int>[255, 255, 255, 255]);
    });

    test('greyscale with alpha (4) premultiplies', () {
      final Uint8List png = buildPng(
        width: 3,
        height: 1,
        colorType: 4,
        filteredRows: unfilteredRows(<List<int>>[
          <int>[255, 255, 255, 128, 200, 0],
        ]),
      );

      final DecodedImage image = decodePng(png);
      expect(_bytesAt(image, 0, 0), <int>[255, 255, 255, 255]);
      expect(_bytesAt(image, 1, 0), <int>[128, 128, 128, 128]);
      expect(_bytesAt(image, 2, 0), <int>[0, 0, 0, 0]);
    });

    test('truecolour with alpha (6) premultiplies each channel', () {
      final Uint8List png = buildPng(
        width: 2,
        height: 1,
        colorType: 6,
        filteredRows: unfilteredRows(<List<int>>[
          <int>[255, 200, 100, 128, 1, 2, 3, 255],
        ]),
      );

      final DecodedImage image = decodePng(png);
      // mul255(255, 128) = 128, mul255(200, 128) = 100, mul255(100, 128) = 50.
      expect(_bytesAt(image, 0, 0), <int>[50, 100, 128, 128]);
      expect(_bytesAt(image, 1, 0), <int>[3, 2, 1, 255]);
    });
  });

  group('premultiplication', () {
    test('a half-transparent white does not come back as 255', () {
      // The halo, stated as an assertion. Straight alpha would leave 255 here,
      // and the compositor would then scale an already-white channel by 128 a
      // second time - a bright fringe around every soft edge.
      final Uint8List png = buildPng(
        width: 1,
        height: 1,
        colorType: 6,
        filteredRows: unfilteredRows(<List<int>>[
          <int>[255, 255, 255, 128],
        ]),
      );

      final DecodedImage image = decodePng(png);
      expect(_bytesAt(image, 0, 0), <int>[128, 128, 128, 128]);
      expect(image.pixels[0], isNot(255));
    });

    test('every channel goes through the same rounding as the rasteriser', () {
      // A ramp of alphas over a fixed colour, checked against the shared
      // helper rather than against a second formula written here.
      final List<List<int>> row = <List<int>>[
        <int>[
          for (int alpha = 0; alpha < 256; alpha += 8) ...<int>[
            200,
            100,
            50,
            alpha,
          ],
        ],
      ];
      final Uint8List png = buildPng(
        width: 32,
        height: 1,
        colorType: 6,
        filteredRows: unfilteredRows(row),
      );

      final DecodedImage image = decodePng(png);
      for (int i = 0; i < 32; i++) {
        final int alpha = i * 8;
        expect(
          _bytesAt(image, i, 0),
          <int>[
            premultiplyChannel(50, alpha),
            premultiplyChannel(100, alpha),
            premultiplyChannel(200, alpha),
            alpha,
          ],
          reason: 'alpha $alpha',
        );
      }
    });

    test('an opaque image is byte-identical either way', () {
      final Uint8List png = buildPng(
        width: 2,
        height: 1,
        colorType: 6,
        filteredRows: unfilteredRows(<List<int>>[
          <int>[9, 8, 7, 255, 6, 5, 4, 255],
        ]),
      );
      expect(_bytesAt(decodePng(png), 0, 0), <int>[7, 8, 9, 255]);
    });
  });

  group('channel order', () {
    final Uint8List png = buildPng(
      width: 2,
      height: 1,
      colorType: 6,
      filteredRows: unfilteredRows(<List<int>>[
        <int>[255, 0, 0, 255, 0, 0, 255, 255],
      ]),
    );

    test('bgra puts blue first', () {
      final DecodedImage image = decodePng(png, order: ImageChannelOrder.bgra);
      expect(image.order, ImageChannelOrder.bgra);
      expect(_bytesAt(image, 0, 0), <int>[0, 0, 255, 255], reason: 'red');
      expect(_bytesAt(image, 1, 0), <int>[255, 0, 0, 255], reason: 'blue');
    });

    test('rgba puts red first, on the same file', () {
      final DecodedImage image = decodePng(png, order: ImageChannelOrder.rgba);
      expect(image.order, ImageChannelOrder.rgba);
      expect(_bytesAt(image, 0, 0), <int>[255, 0, 0, 255], reason: 'red');
      expect(_bytesAt(image, 1, 0), <int>[0, 0, 255, 255], reason: 'blue');
    });

    test('the two orders agree about the colour they describe', () {
      // The bug this exists for: a decoder that ignored the requested order
      // would pass every test that only ever looked at greys, because grey is
      // the one colour where the two are identical.
      final DecodedImage bgra = decodePng(png, order: ImageChannelOrder.bgra);
      final DecodedImage rgba = decodePng(png, order: ImageChannelOrder.rgba);
      expect(bgra.pixels, isNot(rgba.pixels));
      for (int x = 0; x < 2; x++) {
        expect(bgra.argbAt(x, 0), rgba.argbAt(x, 0));
      }
      expect(bgra.argbAt(0, 0), 0xFFFF0000);
      expect(bgra.argbAt(1, 0), 0xFF0000FF);
    });

    test('inOrder converts without going back through the decoder', () {
      final DecodedImage bgra = decodePng(png, order: ImageChannelOrder.bgra);
      expect(
        bgra.inOrder(ImageChannelOrder.rgba).pixels,
        decodePng(png, order: ImageChannelOrder.rgba).pixels,
      );
      expect(identical(bgra.inOrder(ImageChannelOrder.bgra), bgra), isTrue);
    });
  });

  group('the five scanline filters', () {
    // A gradient in all three channels, so that each predictor produces
    // different bytes and a filter that was silently ignored would show.
    final List<List<int>> rows = <List<int>>[
      for (int y = 0; y < 4; y++)
        <int>[
          for (int x = 0; x < 4; x++) ...<int>[
            (x * 40 + y * 7) & 0xFF,
            (x * 3 + y * 60) & 0xFF,
            (x * y * 17 + 5) & 0xFF,
          ],
        ],
    ];

    for (final PngFilter filter in PngFilter.values) {
      test('${filter.name} reconstructs the same image', () {
        final Uint8List png = buildPng(
          width: 4,
          height: 4,
          colorType: 2,
          filteredRows: filterRows(filter, rows, 3),
        );

        final DecodedImage image = decodePng(png);
        for (int y = 0; y < 4; y++) {
          for (int x = 0; x < 4; x++) {
            expect(
              _bytesAt(image, x, y),
              <int>[
                rows[y][x * 3 + 2],
                rows[y][x * 3 + 1],
                rows[y][x * 3],
                255
              ],
              reason: '${filter.name} at ($x, $y)',
            );
          }
        }
      });
    }

    test('a row may choose a different filter from its neighbours', () {
      // Which is the whole reason the filter byte is per scanline: a real
      // encoder picks the cheapest one per row.
      final List<int> mixed = <int>[];
      List<int> previous = List<int>.filled(12, 0);
      for (int y = 0; y < 4; y++) {
        mixed.addAll(
          filterRow(PngFilter.values[y + 1], rows[y], previous, 3),
        );
        previous = rows[y];
      }
      final Uint8List png = buildPng(
        width: 4,
        height: 4,
        colorType: 2,
        filteredRows: mixed,
      );

      final DecodedImage image = decodePng(png);
      expect(_bytesAt(image, 3, 3),
          <int>[rows[3][11], rows[3][10], rows[3][9], 255]);
    });
  });

  group('sub-byte bit depths', () {
    test('greyscale at 1 bit is black and white', () {
      final Uint8List png = buildPng(
        width: 8,
        height: 1,
        colorType: 0,
        bitDepth: 1,
        filteredRows: unfilteredRows(<List<int>>[
          <int>[0xB1], // 1011 0001
        ]),
      );

      final DecodedImage image = decodePng(png);
      const List<int> expected = <int>[255, 0, 255, 255, 0, 0, 0, 255];
      for (int x = 0; x < 8; x++) {
        expect(image.pixels[x * 4], expected[x], reason: 'pixel $x');
      }
    });

    test('greyscale at 2 bits reaches both ends of the range', () {
      final Uint8List png = buildPng(
        width: 4,
        height: 1,
        colorType: 0,
        bitDepth: 2,
        filteredRows: unfilteredRows(<List<int>>[
          <int>[0x1B], // 00 01 10 11
        ]),
      );

      final DecodedImage image = decodePng(png);
      expect(
        <int>[for (int x = 0; x < 4; x++) image.pixels[x * 4]],
        <int>[0, 85, 170, 255],
      );
    });

    test('greyscale at 4 bits, with a width that does not fill its last byte',
        () {
      final Uint8List png = buildPng(
        width: 3,
        height: 1,
        colorType: 0,
        bitDepth: 4,
        filteredRows: unfilteredRows(<List<int>>[
          <int>[0x0F, 0x80],
        ]),
      );

      final DecodedImage image = decodePng(png);
      expect(
        <int>[for (int x = 0; x < 3; x++) image.pixels[x * 4]],
        <int>[0, 255, 136],
      );
    });

    test('indexed at 4 bits reads two entries per byte', () {
      final Uint8List png = buildPng(
        width: 3,
        height: 1,
        colorType: 3,
        bitDepth: 4,
        palette: <int>[
          0, 0, 0, //
          255, 0, 0, //
          0, 255, 0, //
        ],
        filteredRows: unfilteredRows(<List<int>>[
          <int>[0x12, 0x00],
        ]),
      );

      final DecodedImage image = decodePng(png);
      expect(_bytesAt(image, 0, 0), <int>[0, 0, 255, 255]);
      expect(_bytesAt(image, 1, 0), <int>[0, 255, 0, 255]);
      expect(_bytesAt(image, 2, 0), <int>[0, 0, 0, 255]);
    });
  });

  group('tRNS on the two non-indexed types', () {
    test('a greyscale key makes exactly that sample transparent', () {
      final Uint8List png = buildPng(
        width: 3,
        height: 1,
        colorType: 0,
        transparency: <int>[0x00, 128],
        filteredRows: unfilteredRows(<List<int>>[
          <int>[127, 128, 129],
        ]),
      );

      final DecodedImage image = decodePng(png);
      expect(image.hasAlpha, isTrue);
      expect(_bytesAt(image, 0, 0), <int>[127, 127, 127, 255]);
      expect(_bytesAt(image, 1, 0), <int>[0, 0, 0, 0]);
      expect(_bytesAt(image, 2, 0), <int>[129, 129, 129, 255]);
    });

    test('a truecolour key matches on all three samples at once', () {
      final Uint8List png = buildPng(
        width: 2,
        height: 1,
        colorType: 2,
        transparency: <int>[0, 1, 0, 2, 0, 3],
        filteredRows: unfilteredRows(<List<int>>[
          <int>[1, 2, 3, 1, 2, 4],
        ]),
      );

      final DecodedImage image = decodePng(png);
      expect(_bytesAt(image, 0, 0), <int>[0, 0, 0, 0]);
      expect(_bytesAt(image, 1, 0), <int>[4, 2, 1, 255]);
    });
  });

  group('interlacing', () {
    test('Adam7 reassembles into the same image as the flat encoding', () {
      const int width = 11;
      const int height = 9;
      final List<List<int>> rows = <List<int>>[
        for (int y = 0; y < height; y++)
          <int>[
            for (int x = 0; x < width; x++) ...<int>[
              (x * 20 + y) & 0xFF,
              (y * 20 + x) & 0xFF,
              (x ^ y) & 0xFF,
            ],
          ],
      ];

      final DecodedImage flat = decodePng(
        buildPng(
          width: width,
          height: height,
          colorType: 2,
          filteredRows: unfilteredRows(rows),
        ),
      );
      final DecodedImage interlaced = decodePng(
        buildPng(
          width: width,
          height: height,
          colorType: 2,
          interlace: 1,
          filteredRows: adam7Rows(width, height, 3, rows),
        ),
      );

      expect(interlaced.width, width);
      expect(interlaced.height, height);
      expect(interlaced.pixels, flat.pixels);
    });

    test('an image smaller than one Adam7 tile still decodes', () {
      // 1x1 reaches only pass 0; the other six have zero width or height and
      // must contribute no scanlines at all.
      final Uint8List png = buildPng(
        width: 1,
        height: 1,
        colorType: 2,
        interlace: 1,
        filteredRows: adam7Rows(1, 1, 3, <List<int>>[
          <int>[7, 8, 9],
        ]),
      );
      expect(_bytesAt(decodePng(png), 0, 0), <int>[9, 8, 7, 255]);
    });
  });

  group('the container', () {
    final List<int> rows = unfilteredRows(<List<int>>[
      <int>[1, 2, 3, 4, 5, 6],
      <int>[7, 8, 9, 10, 11, 12],
    ]);

    test('IDAT split across several chunks is joined', () {
      final DecodedImage single = decodePng(
        buildPng(width: 2, height: 2, colorType: 2, filteredRows: rows),
      );
      final DecodedImage split = decodePng(
        buildPng(
          width: 2,
          height: 2,
          colorType: 2,
          filteredRows: rows,
          idatChunks: 4,
        ),
      );
      expect(split.pixels, single.pixels);
    });

    test('a stored-block zlib stream decodes like a compressed one', () {
      final DecodedImage stored = decodePng(
        buildPng(
          width: 2,
          height: 2,
          colorType: 2,
          compressedIdat: zlibStored(Uint8List.fromList(rows)),
        ),
      );
      expect(stored.argbAt(0, 0), 0xFF010203);
    });

    test('an unknown ancillary chunk is skipped', () {
      final DecodedImage image = decodePng(
        buildPng(
          width: 2,
          height: 2,
          colorType: 2,
          filteredRows: rows,
          extraChunks: const <(String, List<int>)>[
            ('gAMA', <int>[0, 1, 0x86, 0xA0]),
            ('tEXt', <int>[65, 66, 0, 67]),
          ],
        ),
      );
      expect(image.width, 2);
    });

    test('readPngHeader answers without touching the pixels', () {
      final PngHeader header = readPngHeader(
        buildPng(
          width: 640,
          height: 480,
          colorType: 6,
          // Deliberately no IDAT at all: reading the header must not need one.
          filteredRows: const <int>[],
        ),
      );
      expect(header.width, 640);
      expect(header.height, 480);
      expect(header.colorType, PngColorType.truecolourAlpha);
      expect(header.bitDepth, 8);
      expect(header.interlaced, isFalse);
      expect(header.filterStride, 4);
      expect(header.rowBytes(640), 2560);
    });

    test('isPng sniffs without validating', () {
      expect(isPng(buildPng(width: 1, height: 1, colorType: 0)), isTrue);
      expect(isPng(Uint8List.fromList(<int>[1, 2, 3])), isFalse);
      expect(
        isPng(Uint8List.fromList(<int>[...pngSignature, 9, 9, 9])),
        isTrue,
      );
    });
  });
}
