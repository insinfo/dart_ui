import 'dart:convert';
import 'dart:typed_data';

import 'package:dart_ui/pdf.dart';
import 'package:test/test.dart';

void main() {
  PdfContentInterpreter run(String content, {PdfDict? resources}) {
    return PdfContentInterpreter(
      device: PdfMemoryOutputDevice(),
      resources: resources,
    )..execute(Uint8List.fromList(utf8.encode(content)));
  }

  group('PdfContentInterpreter color spaces', () {
    test('supports device spaces through cs/CS and sc/SC', () {
      final interpreter = run(
        '/DeviceRGB cs 1 0.5 0 sc /DeviceCMYK CS 1 0 0 0 SC',
      );

      expect(interpreter.currentState.fillColorSpace, isA<PdfDeviceRgb>());
      expect(interpreter.currentState.fillColor, 0xffff8000);
      expect(interpreter.currentState.strokeColorSpace, isA<PdfDeviceCmyk>());
      expect(interpreter.currentState.strokeColor, 0xff00ffff);
    });

    test('resolves Indexed, CalGray, CalRGB and Lab resources', () {
      final resources = PdfDict(<String, PdfObject>{
        'ColorSpace': PdfDict(<String, PdfObject>{
          'Palette': PdfArray(<PdfObject>[
            const PdfName('Indexed'),
            const PdfName('DeviceRGB'),
            const PdfNumber(1),
            PdfString(Uint8List.fromList(<int>[255, 0, 0, 0, 255, 0])),
          ]),
          'Gray': PdfArray(<PdfObject>[
            const PdfName('CalGray'),
            PdfDict(<String, PdfObject>{
              'WhitePoint': const PdfArray(<PdfObject>[
                PdfNumber(0.9505),
                PdfNumber(1),
                PdfNumber(1.089),
              ]),
            }),
          ]),
          'Rgb': PdfArray(<PdfObject>[
            const PdfName('CalRGB'),
            PdfDict(<String, PdfObject>{
              'WhitePoint': const PdfArray(<PdfObject>[
                PdfNumber(0.9505),
                PdfNumber(1),
                PdfNumber(1.089),
              ]),
            }),
          ]),
          'LabSpace': PdfArray(<PdfObject>[
            const PdfName('Lab'),
            PdfDict(<String, PdfObject>{
              'WhitePoint': const PdfArray(<PdfObject>[
                PdfNumber(0.9505),
                PdfNumber(1),
                PdfNumber(1.089),
              ]),
            }),
          ]),
        }),
      });

      final indexed = run('/Palette cs 1 scn', resources: resources);
      expect(indexed.currentState.fillColorSpace, isA<PdfIndexedColorSpace>());
      expect(indexed.currentState.fillColor, 0xff00ff00);

      final gray = run('/Gray cs 0.5 sc', resources: resources);
      expect(gray.currentState.fillColorSpace, isA<PdfCalGray>());
      expect(gray.currentState.fillColor, isNot(0xff000000));

      final rgb = run('/Rgb CS 0.2 0.3 0.4 SC', resources: resources);
      expect(rgb.currentState.strokeColorSpace, isA<PdfCalRgb>());
      expect(rgb.currentState.strokeColor, isNot(0xff000000));

      final lab = run('/LabSpace cs 50 20 -20 scn', resources: resources);
      expect(lab.currentState.fillColorSpace, isA<PdfLab>());
      expect(lab.currentState.fillColor, isNot(0xff000000));
    });

    test('q/Q restores color space as well as color', () {
      final interpreter = run(
        '0.25 g q /DeviceRGB cs 1 0 0 sc Q 0.5 sc',
      );

      expect(interpreter.currentState.fillColorSpace, isA<PdfDeviceGray>());
      expect(interpreter.currentState.fillColor, 0xff808080);
    });

    test('unsupported spaces leave known color unchanged', () {
      final resources = PdfDict(<String, PdfObject>{
        'ColorSpace': PdfDict(<String, PdfObject>{
          'Spot': const PdfArray(<PdfObject>[
            PdfName('Separation'),
            PdfName('LogoInk'),
            PdfName('DeviceCMYK'),
            PdfNull(),
          ]),
        }),
      });
      final interpreter = run(
        '0.4 g /Spot cs 1 scn',
        resources: resources,
      );

      expect(interpreter.currentState.fillColorSpace, isA<PdfDeviceGray>());
      expect(interpreter.currentState.fillColor, 0xff666666);
      expect(interpreter.currentState.fillColorSpaceSupported, isFalse);
    });
  });
}
