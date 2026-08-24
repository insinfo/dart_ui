library;

import 'dart:typed_data';

import 'package:dart_ui/src/pdf/format/pdf_object.dart';
import 'package:dart_ui/src/pdf/render/pdf_image_decoder.dart';
import 'package:test/test.dart';

void main() {
  group('PDF image sample decoder', () {
    test('uses an 8-bit indexed palette instead of painting indices as gray',
        () {
      final image = decodePdfImage(
        bytes: Uint8List.fromList(<int>[1, 2]),
        width: 2,
        height: 1,
        dictionary: _indexedDictionary(
          bits: 8,
          highValue: 255,
          palette: <int>[
            0,
            0,
            0,
            255,
            255,
            255,
            0,
            101,
            175,
          ],
        ),
      );

      expect(image, isNotNull);
      expect(
        image!.pixels,
        <int>[255, 255, 255, 255, 175, 101, 0, 255],
      );
    });

    test('unpacks two 4-bit palette indices from each byte', () {
      final image = decodePdfImage(
        bytes: Uint8List.fromList(<int>[0x12]),
        width: 2,
        height: 1,
        dictionary: _indexedDictionary(
          bits: 4,
          highValue: 15,
          palette: <int>[
            0,
            0,
            0,
            255,
            0,
            0,
            0,
            255,
            0,
          ],
        ),
      );

      expect(image, isNotNull);
      expect(image!.pixels, <int>[0, 0, 255, 255, 0, 255, 0, 255]);
    });

    test('honours byte padding at the end of 1-bit grayscale rows', () {
      final image = decodePdfImage(
        bytes: Uint8List.fromList(<int>[0xA0, 0x40]),
        width: 3,
        height: 2,
        dictionary: PdfDict(<String, PdfObject>{
          'BitsPerComponent': const PdfNumber(1),
          'ColorSpace': const PdfName('DeviceGray'),
        }),
      );

      expect(image, isNotNull);
      expect(
        _blueValues(image!.pixels),
        <int>[255, 0, 255, 0, 255, 0],
      );
    });

    test('applies an inverted Decode array', () {
      final image = decodePdfImage(
        bytes: Uint8List.fromList(<int>[0x80]),
        width: 2,
        height: 1,
        dictionary: PdfDict(<String, PdfObject>{
          'BitsPerComponent': const PdfNumber(1),
          'ColorSpace': const PdfName('DeviceGray'),
          'Decode': const PdfArray(<PdfObject>[
            PdfNumber(1),
            PdfNumber(0),
          ]),
        }),
      );

      expect(image, isNotNull);
      expect(_blueValues(image!.pixels), <int>[0, 255]);
    });

    test('resolves an indirect palette stream', () {
      final resolver = _MapResolver(<PdfRef, PdfObject>{
        const PdfRef(9, 0): PdfStream(
          PdfDict(),
          Uint8List.fromList(<int>[0, 0, 0, 240, 128, 16]),
        ),
      });
      final image = decodePdfImage(
        bytes: Uint8List.fromList(<int>[1]),
        width: 1,
        height: 1,
        dictionary: PdfDict(<String, PdfObject>{
          'BitsPerComponent': const PdfNumber(8),
          'ColorSpace': const PdfArray(<PdfObject>[
            PdfName('Indexed'),
            PdfName('DeviceRGB'),
            PdfNumber(255),
            PdfRef(9, 0),
          ]),
        }),
        resolver: resolver,
      );

      expect(image, isNotNull);
      expect(image!.pixels, <int>[16, 128, 240, 255]);
    });
  });
}

PdfDict _indexedDictionary({
  required int bits,
  required int highValue,
  required List<int> palette,
}) =>
    PdfDict(<String, PdfObject>{
      'BitsPerComponent': PdfNumber(bits),
      'ColorSpace': PdfArray(<PdfObject>[
        const PdfName('Indexed'),
        const PdfName('DeviceRGB'),
        PdfNumber(highValue),
        PdfString(Uint8List.fromList(palette)),
      ]),
    });

List<int> _blueValues(Uint8List bgra) => <int>[
      for (var offset = 0; offset < bgra.length; offset += 4) bgra[offset],
    ];

final class _MapResolver implements PdfResolver {
  const _MapResolver(this.objects);

  final Map<PdfRef, PdfObject> objects;

  @override
  PdfObject? resolveRef(PdfRef ref) => objects[ref];
}
