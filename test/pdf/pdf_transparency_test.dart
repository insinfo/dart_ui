import 'dart:convert';
import 'dart:typed_data';

import 'package:dart_ui/pdf.dart';
import 'package:test/test.dart';

void main() {
  PdfStream form(String content, {PdfDict? group}) => PdfStream(
        PdfDict(<String, PdfObject>{
          'Subtype': const PdfName('Form'),
          'BBox': const PdfArray(<PdfObject>[
            PdfNumber(0),
            PdfNumber(0),
            PdfNumber(10),
            PdfNumber(10),
          ]),
          if (group != null) 'Group': group,
        }),
        Uint8List.fromList(utf8.encode(content)),
      );

  test('ExtGState applies standard and explicitly reports unknown blend modes',
      () {
    final resources = PdfDict(<String, PdfObject>{
      'ExtGState': PdfDict(<String, PdfObject>{
        'blend': PdfDict(<String, PdfObject>{
          'BM': const PdfArray(<PdfObject>[
            PdfName('VendorMode'),
            PdfName('Multiply'),
          ]),
          'CA': const PdfNumber(0.7),
          'ca': const PdfNumber(0.4),
        }),
        'unknown': PdfDict(<String, PdfObject>{
          'BM': const PdfName('VendorMode'),
        }),
      }),
    });
    final interpreter = PdfContentInterpreter(
      device: PdfMemoryOutputDevice(),
      resources: resources,
    )..execute(Uint8List.fromList(utf8.encode('/blend gs')));

    expect(interpreter.currentState.blendMode, PdfBlendMode.multiply);
    expect(interpreter.currentState.unsupportedBlendMode, isNull);
    expect(interpreter.currentState.strokeAlpha, 0.7);
    expect(interpreter.currentState.fillAlpha, 0.4);

    interpreter.execute(Uint8List.fromList(utf8.encode('/unknown gs')));
    expect(interpreter.currentState.blendMode, PdfBlendMode.normal);
    expect(interpreter.currentState.unsupportedBlendMode, 'VendorMode');
  });

  test('parses Alpha and Luminosity soft masks and clears with None', () {
    final maskGroup = form('0 g 0 0 10 10 re f');
    PdfDict mask(String subtype) => PdfDict(<String, PdfObject>{
          'S': PdfName(subtype),
          'G': maskGroup,
          'BC': const PdfArray(<PdfObject>[PdfNumber(0.25)]),
          'TR': const PdfName('Identity'),
        });
    final resources = PdfDict(<String, PdfObject>{
      'ExtGState': PdfDict(<String, PdfObject>{
        'alpha': PdfDict(<String, PdfObject>{'SMask': mask('Alpha')}),
        'luminosity': PdfDict(<String, PdfObject>{
          'SMask': mask('Luminosity'),
        }),
        'clear': PdfDict(<String, PdfObject>{
          'SMask': const PdfName('None'),
        }),
      }),
    });
    final device = PdfMemoryOutputDevice();
    final interpreter = PdfContentInterpreter(
      device: device,
      resources: resources,
    );

    interpreter.execute(Uint8List.fromList(utf8.encode('/alpha gs')));
    expect(
        interpreter.currentState.softMask?.subtype, PdfSoftMaskSubtype.alpha);
    expect(interpreter.currentState.softMask?.backgroundColor, <double>[0.25]);
    interpreter.execute(Uint8List.fromList(utf8.encode('/luminosity gs')));
    expect(
      interpreter.currentState.softMask?.subtype,
      PdfSoftMaskSubtype.luminosity,
    );
    interpreter.execute(Uint8List.fromList(utf8.encode('/clear gs')));
    expect(interpreter.currentState.softMask, isNull);
    expect(
      device.commands.where((command) => command.startsWith('softMask')),
      <String>['softMask(alpha)', 'softMask(luminosity)', 'softMask(none)'],
    );
  });

  test('malformed soft mask is rejected without retaining an earlier mask', () {
    final validGroup = form('');
    final resources = PdfDict(<String, PdfObject>{
      'ExtGState': PdfDict(<String, PdfObject>{
        'valid': PdfDict(<String, PdfObject>{
          'SMask': PdfDict(<String, PdfObject>{
            'S': const PdfName('Alpha'),
            'G': validGroup,
          }),
        }),
        'broken': PdfDict(<String, PdfObject>{
          'SMask': PdfDict(<String, PdfObject>{
            'S': const PdfName('Unknown'),
            'G': validGroup,
          }),
        }),
      }),
    });
    final interpreter = PdfContentInterpreter(
      device: PdfMemoryOutputDevice(),
      resources: resources,
    )..execute(Uint8List.fromList(utf8.encode('/valid gs /broken gs')));

    expect(interpreter.currentState.softMask, isNull);
    expect(interpreter.currentState.unsupportedSoftMaskReason, isNotNull);
  });

  test('q/Q restores blend and soft-mask state', () {
    final group = form('');
    final resources = PdfDict(<String, PdfObject>{
      'ExtGState': PdfDict(<String, PdfObject>{
        'outer': PdfDict(<String, PdfObject>{
          'BM': const PdfName('Screen'),
          'SMask': PdfDict(<String, PdfObject>{
            'S': const PdfName('Alpha'),
            'G': group,
          }),
        }),
        'inner': PdfDict(<String, PdfObject>{
          'BM': const PdfName('Difference'),
          'SMask': const PdfName('None'),
        }),
      }),
    });
    final interpreter = PdfContentInterpreter(
      device: PdfMemoryOutputDevice(),
      resources: resources,
    )..execute(Uint8List.fromList(utf8.encode('/outer gs q /inner gs Q')));

    expect(interpreter.currentState.blendMode, PdfBlendMode.screen);
    expect(
        interpreter.currentState.softMask?.subtype, PdfSoftMaskSubtype.alpha);
  });

  test('Form transparency group emits bounded begin/end hooks', () {
    final transparency = PdfDict(<String, PdfObject>{
      'S': const PdfName('Transparency'),
      'CS': const PdfName('DeviceRGB'),
      'I': const PdfBoolean(true),
      'K': const PdfBoolean(true),
    });
    final grouped = form('1 0 0 rg 0 0 10 10 re f', group: transparency);
    final resources = PdfDict(<String, PdfObject>{
      'XObject': PdfDict(<String, PdfObject>{'Fx': grouped}),
    });
    final device = PdfMemoryOutputDevice();
    PdfContentInterpreter(device: device, resources: resources).execute(
      Uint8List.fromList(utf8.encode('/Fx Do')),
    );

    expect(device.supportsTransparencyGroups, isFalse);
    expect(
      device.commands,
      contains('beginTransparencyGroup(isolated: true, knockout: true)'),
    );
    expect(device.commands, contains('endTransparencyGroup'));
    expect(
        device.commands.any((command) => command.startsWith('fill(')), isTrue);
  });
}
