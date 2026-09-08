import 'dart:typed_data';

import 'package:dart_ui/pdf.dart';
import 'package:test/test.dart';

void main() {
  test('parses a valid tiling pattern and rejects zero steps', () {
    expect(PdfTilingPattern.parse(_pattern(), null), isNotNull);
    expect(PdfTilingPattern.parse(_pattern(xStep: 0), null), isNull);
  });

  test('colored tiling pattern repeats its content through clipped cells', () {
    final device = PdfMemoryOutputDevice();
    PdfContentInterpreter(device: device, resources: _resources(_pattern()))
        .execute(Uint8List.fromList(
      '/Pattern cs /P scn 0 0 20 20 re f'.codeUnits,
    ));

    expect(device.commands, contains('clip(evenOdd: false)'));
    expect(device.commands.where((c) => c.startsWith('transform(')), isNotEmpty,
        reason: device.commands.toString());
    expect(device.commands.where((c) => c.startsWith('fill(')), isNotEmpty,
        reason: device.commands.toString());
  });

  test('uncolored pattern receives components from its base color space', () {
    final device = PdfMemoryOutputDevice();
    PdfContentInterpreter(
      device: device,
      resources: _resources(_pattern(
        paintType: 2,
        contents: '0 0 5 5 re f',
      )),
    ).execute(Uint8List.fromList(
      '/PatternRGB cs 1 0 0 /P scn 0 0 5 5 re f'.codeUnits,
    ));

    expect(device.commands.where((c) => c.contains('ffff0000')), isNotEmpty,
        reason: device.commands.toString());
  });

  test('pattern-owned resources are used by its content stream', () {
    final shading = PdfDict(<String, PdfObject>{
      'ShadingType': const PdfNumber(1),
      'ColorSpace': const PdfName('DeviceGray'),
    });
    final patternResources = PdfDict(<String, PdfObject>{
      'Shading': PdfDict(<String, PdfObject>{'S': shading}),
    });
    final pattern = _pattern(
      contents: '/S sh',
      resources: patternResources,
    );
    final device = PdfMemoryOutputDevice();
    PdfContentInterpreter(device: device, resources: _resources(pattern))
        .execute(Uint8List.fromList(
      '/Pattern cs /P scn 0 0 2 2 re f'.codeUnits,
    ));

    expect(device.commands, contains('drawShading(type: 1)'));
  });
}

PdfDict _resources(PdfStream pattern) => PdfDict(<String, PdfObject>{
      'Pattern': PdfDict(<String, PdfObject>{'P': pattern}),
      'ColorSpace': PdfDict(<String, PdfObject>{
        'PatternRGB': const PdfArray(<PdfObject>[
          PdfName('Pattern'),
          PdfName('DeviceRGB'),
        ]),
      }),
    });

PdfStream _pattern({
  int paintType = 1,
  double xStep = 10,
  String contents = '0 1 0 rg 0 0 5 5 re f',
  PdfDict? resources,
}) =>
    PdfStream(
      PdfDict(<String, PdfObject>{
        'Type': const PdfName('Pattern'),
        'PatternType': const PdfNumber(1),
        'PaintType': PdfNumber(paintType),
        'TilingType': const PdfNumber(1),
        'BBox': const PdfArray(<PdfObject>[
          PdfNumber(0),
          PdfNumber(0),
          PdfNumber(10),
          PdfNumber(10),
        ]),
        'XStep': PdfNumber(xStep),
        'YStep': const PdfNumber(10),
        'Resources': resources ?? PdfDict(<String, PdfObject>{}),
      }),
      Uint8List.fromList(contents.codeUnits),
    );
