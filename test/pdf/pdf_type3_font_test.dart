import 'dart:typed_data';

import 'package:dart_ui/pdf.dart';
import 'package:test/test.dart';

void main() {
  test('Type3 executes CharProcs and records selectable text', () {
    final font = _font(<String, String>{
      'A': '600 0 d0 0 0 600 700 re f',
      'B': '600 0 0 0 600 700 d1 0 0 600 700 re f',
    });
    final device = PdfMemoryOutputDevice();
    PdfContentInterpreter(device: device, resources: _fontResources(font))
        .execute(Uint8List.fromList(
      'BT /F 10 Tf 1 0 0 1 20 30 Tm (AB) Tj ET'.codeUnits,
    ));

    expect(
        device.commands.where((c) => c.startsWith('transform(')), hasLength(2));
    expect(device.commands.where((c) => c.startsWith('fill(')), hasLength(2));
    expect(device.commands, contains('recordText("AB", advance: 12.0)'));
  });

  test('Type3 uses d0 width when Widths is absent', () {
    final font = _font(<String, String>{
      'A': '750 0 d0 0 0 500 500 re f',
    }, includeWidths: false);
    final device = PdfMemoryOutputDevice();
    PdfContentInterpreter(device: device, resources: _fontResources(font))
        .execute(Uint8List.fromList('BT /F 8 Tf (A) Tj ET'.codeUnits));

    expect(device.commands, contains('recordText("A", advance: 6.0)'));
  });

  test('Type3 honors a direct ToUnicode map without requiring a resolver', () {
    final font = _font(<String, String>{'A': '600 0 d0'})
      ..entries['ToUnicode'] = PdfStream(
        PdfDict(<String, PdfObject>{}),
        Uint8List.fromList('''
          1 begincodespacerange <00> <FF> endcodespacerange
          1 beginbfchar <41> <03A9> endbfchar
        '''
            .codeUnits),
      );
    final device = PdfMemoryOutputDevice();
    PdfContentInterpreter(device: device, resources: _fontResources(font))
        .execute(Uint8List.fromList('BT /F 10 Tf (A) Tj ET'.codeUnits));

    expect(device.commands.any((c) => c.contains('recordText("Ω"')), isTrue);
  });

  test('Type3 Encoding Differences supplies Unicode fallback text', () {
    final font = _font(<String, String>{'uni03A9': '600 0 d0'});
    final device = PdfMemoryOutputDevice();
    PdfContentInterpreter(device: device, resources: _fontResources(font))
        .execute(Uint8List.fromList('BT /F 10 Tf (A) Tj ET'.codeUnits));

    expect(device.commands.any((c) => c.contains('recordText("Ω"')), isTrue);
  });

  test('Type3 recursive glyph programs share a strict glyph budget', () {
    final font = _font(<String, String>{
      'A': '600 0 d0 BT /F 10 Tf (A) Tj ET',
    });
    final resources = _fontResources(font);
    font.entries['Resources'] = resources;
    final device = PdfMemoryOutputDevice();
    PdfContentInterpreter(
      device: device,
      resources: resources,
      type3Budget: PdfType3RenderBudget(maximumGlyphs: 2),
    ).execute(Uint8List.fromList('BT /F 10 Tf (A) Tj ET'.codeUnits));

    expect(
        device.commands.where((c) => c.startsWith('transform(')), hasLength(2));
  });
}

PdfDict _fontResources(PdfDict font) => PdfDict(<String, PdfObject>{
      'Font': PdfDict(<String, PdfObject>{'F': font}),
    });

PdfDict _font(Map<String, String> programs, {bool includeWidths = true}) {
  final names = programs.keys.toList(growable: false);
  return PdfDict(<String, PdfObject>{
    'Type': const PdfName('Font'),
    'Subtype': const PdfName('Type3'),
    'FontBBox': const PdfArray(<PdfObject>[
      PdfNumber(0),
      PdfNumber(0),
      PdfNumber(1000),
      PdfNumber(1000),
    ]),
    'FontMatrix': const PdfArray(<PdfObject>[
      PdfNumber(0.001),
      PdfNumber(0),
      PdfNumber(0),
      PdfNumber(0.001),
      PdfNumber(0),
      PdfNumber(0),
    ]),
    'FirstChar': const PdfNumber(65),
    'LastChar': PdfNumber(64 + names.length),
    if (includeWidths)
      'Widths': PdfArray(<PdfObject>[
        for (var i = 0; i < names.length; i++) const PdfNumber(600),
      ]),
    'Encoding': PdfDict(<String, PdfObject>{
      'Differences': PdfArray(<PdfObject>[
        const PdfNumber(65),
        for (final name in names) PdfName(name),
      ]),
    }),
    'CharProcs': PdfDict(<String, PdfObject>{
      for (final entry in programs.entries)
        entry.key: PdfStream(
          PdfDict(<String, PdfObject>{}),
          Uint8List.fromList(entry.value.codeUnits),
        ),
    }),
    'Resources': PdfDict(<String, PdfObject>{}),
  });
}
