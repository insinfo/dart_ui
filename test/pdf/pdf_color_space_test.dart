import 'dart:typed_data';

import 'package:dart_ui/src/pdf/format/pdf_object.dart';
import 'package:dart_ui/src/pdf/gfx/pdf_color_space.dart';
import 'package:test/test.dart';

void main() {
  test('resolves device and Indexed color spaces', () {
    expect(PdfColorSpace.parse(const PdfName('DeviceRGB'), null),
        isA<PdfDeviceRgb>());
    final indexed = PdfColorSpace.parse(
      PdfArray(<PdfObject>[
        const PdfName('Indexed'),
        const PdfName('DeviceRGB'),
        const PdfNumber(1),
        PdfString(Uint8List.fromList(<int>[255, 0, 0, 0, 128, 255])),
      ]),
      null,
    );
    expect(indexed, isA<PdfIndexedColorSpace>());
    expect(indexed!.toRgb(const <double>[1]), <double>[0, 128 / 255, 1]);
  });

  test('CalGray white and black convert to bounded sRGB', () {
    final space = PdfColorSpace.parse(
      PdfArray(<PdfObject>[
        const PdfName('CalGray'),
        PdfDict(<String, PdfObject>{
          'WhitePoint': const PdfArray(<PdfObject>[
            PdfNumber(0.9505),
            PdfNumber(1),
            PdfNumber(1.089),
          ]),
          'Gamma': const PdfNumber(2.2),
        }),
      ]),
      null,
    )!;
    expect(space.toRgb(const <double>[0]), everyElement(0));
    expect(space.toRgb(const <double>[1]), everyElement(closeTo(1, 0.001)));
  });

  test('Lab neutral axis produces gray and clamps its declared range', () {
    final space = PdfColorSpace.parse(
      PdfArray(<PdfObject>[
        const PdfName('Lab'),
        PdfDict(<String, PdfObject>{
          'WhitePoint': const PdfArray(<PdfObject>[
            PdfNumber(0.9505),
            PdfNumber(1),
            PdfNumber(1.089),
          ]),
          'Range': const PdfArray(<PdfObject>[
            PdfNumber(-80),
            PdfNumber(80),
            PdfNumber(-70),
            PdfNumber(70),
          ]),
        }),
      ]),
      null,
    )!;
    final rgb = space.toRgb(const <double>[50, 0, 0]);
    expect(rgb[0], closeTo(rgb[1], 0.002));
    expect(rgb[1], closeTo(rgb[2], 0.002));
    expect(space.toRgb(const <double>[50, 1000, -1000]),
        everyElement(inInclusiveRange(0, 1)));
  });
}
