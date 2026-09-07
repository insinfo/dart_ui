import 'dart:typed_data';

import 'package:dart_ui/pdf.dart';
import 'package:dart_ui/src/graphics/gradient.dart';
import 'package:test/test.dart';

void main() {
  test('parses every ISO 32000 ShadingType from dictionary or stream', () {
    for (var type = 1; type <= 7; type++) {
      final dictionary = PdfDict(<String, PdfObject>{
        'ShadingType': PdfNumber(type),
        'ColorSpace': const PdfName('DeviceRGB'),
        if (type >= 4) ...<String, PdfObject>{
          'BitsPerCoordinate': const PdfNumber(8),
          'BitsPerComponent': const PdfNumber(8),
          'Decode': const PdfArray(<PdfObject>[
            PdfNumber(0),
            PdfNumber(1),
            PdfNumber(0),
            PdfNumber(1),
            PdfNumber(0),
            PdfNumber(1),
            PdfNumber(0),
            PdfNumber(1),
            PdfNumber(0),
            PdfNumber(1),
          ]),
          if (type == 5) 'VerticesPerRow': const PdfNumber(2),
          if (type != 5) 'BitsPerFlag': const PdfNumber(2),
        },
      });
      final object = type < 4
          ? dictionary
          : PdfStream(dictionary, Uint8List.fromList(<int>[0]));
      final shading = PdfShading.parse(object, null);

      expect(shading, isNotNull, reason: 'ShadingType $type');
      expect(shading!.type, type);
      expect(shading.isMesh, type >= 4);
    }
  });

  test('decodes type 5 Gouraud lattice samples bit-exactly', () {
    final shading = PdfShading.parse(
      PdfStream(
        PdfDict(<String, PdfObject>{
          'ShadingType': const PdfNumber(5),
          'ColorSpace': const PdfName('DeviceRGB'),
          'BitsPerCoordinate': const PdfNumber(8),
          'BitsPerComponent': const PdfNumber(8),
          'VerticesPerRow': const PdfNumber(2),
          'Decode': const PdfArray(<PdfObject>[
            PdfNumber(0),
            PdfNumber(100),
            PdfNumber(0),
            PdfNumber(200),
            PdfNumber(0),
            PdfNumber(1),
            PdfNumber(0),
            PdfNumber(1),
            PdfNumber(0),
            PdfNumber(1),
          ]),
        }),
        Uint8List.fromList(<int>[128, 64, 255, 0, 128]),
      ),
      null,
    )!;

    final vertex = shading.decodeGouraudVertices(null)!.single;
    expect(vertex.flag, 0);
    expect(vertex.x, closeTo(50.196, 0.001));
    expect(vertex.y, closeTo(50.196, 0.001));
    expect(vertex.components[0], 1);
    expect(vertex.components[1], 0);
    expect(vertex.components[2], closeTo(0.502, 0.001));
  });

  test('converts type 2 exponential function to an axial gradient', () {
    final shading = PdfShading.parse(
      PdfDict(<String, PdfObject>{
        'ShadingType': const PdfNumber(2),
        'ColorSpace': const PdfName('DeviceRGB'),
        'Coords': const PdfArray(<PdfObject>[
          PdfNumber(10),
          PdfNumber(20),
          PdfNumber(110),
          PdfNumber(20),
        ]),
        'Function': PdfDict(<String, PdfObject>{
          'FunctionType': const PdfNumber(2),
          'C0': const PdfArray(<PdfObject>[
            PdfNumber(1),
            PdfNumber(0),
            PdfNumber(0),
          ]),
          'C1': const PdfArray(<PdfObject>[
            PdfNumber(0),
            PdfNumber(0),
            PdfNumber(1),
          ]),
          'N': const PdfNumber(1),
        }),
      }),
      null,
    )!;

    final gradient = shading.toGradient(null, samples: 3) as LinearGradient;
    expect(gradient.startX, 10);
    expect(gradient.endX, 110);
    expect(gradient.stopColors.first, 0xFFFF0000);
    expect(gradient.stopColors.last, 0xFF0000FF);
  });

  test('interpolates a sampled type 0 function used by a shading', () {
    final function = PdfStream(
      PdfDict(<String, PdfObject>{
        'FunctionType': const PdfNumber(0),
        'Domain': const PdfArray(<PdfObject>[PdfNumber(0), PdfNumber(1)]),
        'Range': const PdfArray(<PdfObject>[
          PdfNumber(0),
          PdfNumber(1),
          PdfNumber(0),
          PdfNumber(1),
          PdfNumber(0),
          PdfNumber(1),
        ]),
        'Size': const PdfArray(<PdfObject>[PdfNumber(2)]),
        'BitsPerSample': const PdfNumber(8),
      }),
      Uint8List.fromList(<int>[255, 0, 0, 0, 0, 255]),
    );
    final shading = PdfShading.parse(
      PdfDict(<String, PdfObject>{
        'ShadingType': const PdfNumber(2),
        'ColorSpace': const PdfName('DeviceRGB'),
        'Coords': const PdfArray(<PdfObject>[
          PdfNumber(0),
          PdfNumber(0),
          PdfNumber(100),
          PdfNumber(0),
        ]),
        'Function': function,
      }),
      null,
    )!;

    final gradient = shading.toGradient(null, samples: 3)!;
    expect(gradient.stopColors.first, 0xFFFF0000);
    expect(gradient.stopColors[1], 0xFF800080);
    expect(gradient.stopColors.last, 0xFF0000FF);
  });

  test('sh operator resolves and dispatches the named shading', () {
    final resources = PdfDict(<String, PdfObject>{
      'Shading': PdfDict(<String, PdfObject>{
        'S1': PdfDict(<String, PdfObject>{
          'ShadingType': const PdfNumber(1),
          'ColorSpace': const PdfName('DeviceGray'),
        }),
      }),
    });
    final device = PdfMemoryOutputDevice();
    PdfContentInterpreter(device: device, resources: resources).execute(
      Uint8List.fromList('/S1 sh'.codeUnits),
    );

    expect(device.commands, contains('drawShading(type: 1)'));
  });
}
