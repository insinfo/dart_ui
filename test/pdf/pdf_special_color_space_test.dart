import 'dart:convert';
import 'dart:typed_data';

import 'package:dart_ui/pdf.dart';
import 'package:test/test.dart';

void main() {
  PdfStream functionStream(
    int type,
    String program, {
    List<PdfObject> domain = const <PdfObject>[PdfNumber(0), PdfNumber(1)],
    List<PdfObject> range = const <PdfObject>[
      PdfNumber(0),
      PdfNumber(1),
      PdfNumber(0),
      PdfNumber(1),
      PdfNumber(0),
      PdfNumber(1),
      PdfNumber(0),
      PdfNumber(1),
    ],
  }) =>
      PdfStream(
        PdfDict(<String, PdfObject>{
          'FunctionType': PdfNumber(type),
          'Domain': PdfArray(domain),
          'Range': PdfArray(range),
        }),
        Uint8List.fromList(latin1.encode(program)),
      );

  test('ICCBased preserves profile and uses explicit Alternate', () {
    final profile = PdfStream(
      PdfDict(<String, PdfObject>{
        'N': const PdfNumber(3),
        'Alternate': const PdfName('DeviceRGB'),
      }),
      Uint8List.fromList(<int>[1, 2, 3, 4]),
    );
    final space = PdfColorSpace.parse(
      PdfArray(<PdfObject>[const PdfName('ICCBased'), profile]),
      null,
    );

    expect(space, isA<PdfIccBasedColorSpace>());
    expect((space! as PdfIccBasedColorSpace).profile, <int>[1, 2, 3, 4]);
    expect(space.toRgb(<double>[0.2, 0.4, 0.6]), <double>[0.2, 0.4, 0.6]);
  });

  test('ICCBased rejects an Alternate with the wrong component count', () {
    final profile = PdfStream(
      PdfDict(<String, PdfObject>{
        'N': const PdfNumber(3),
        'Alternate': const PdfName('DeviceGray'),
      }),
      Uint8List(0),
    );
    expect(
      PdfColorSpace.parse(
        PdfArray(<PdfObject>[const PdfName('ICCBased'), profile]),
        null,
      ),
      isNull,
    );
  });

  test('Separation evaluates a type 2 tint transform', () {
    final transform = PdfDict(<String, PdfObject>{
      'FunctionType': const PdfNumber(2),
      'Domain': const PdfArray(<PdfObject>[PdfNumber(0), PdfNumber(1)]),
      'C0': const PdfArray(<PdfObject>[
        PdfNumber(0),
        PdfNumber(0),
        PdfNumber(0),
        PdfNumber(0),
      ]),
      'C1': const PdfArray(<PdfObject>[
        PdfNumber(0),
        PdfNumber(1),
        PdfNumber(0),
        PdfNumber(0),
      ]),
      'N': const PdfNumber(1),
    });
    final space = PdfColorSpace.parse(
      PdfArray(<PdfObject>[
        const PdfName('Separation'),
        const PdfName('BrandGreen'),
        const PdfName('DeviceCMYK'),
        transform,
      ]),
      null,
    );

    expect(space, isA<PdfSeparationColorSpace>());
    expect(space!.toRgb(<double>[0.5]), <double>[1, 0.5, 1]);
  });

  test('DeviceN evaluates a multi-input type 4 calculator function', () {
    final transform = functionStream(
      4,
      '{ 0 0 }',
      domain: const <PdfObject>[
        PdfNumber(0),
        PdfNumber(1),
        PdfNumber(0),
        PdfNumber(1),
      ],
    );
    final space = PdfColorSpace.parse(
      PdfArray(<PdfObject>[
        const PdfName('DeviceN'),
        const PdfArray(<PdfObject>[PdfName('Cyan'), PdfName('Magenta')]),
        const PdfName('DeviceCMYK'),
        transform,
      ]),
      null,
    );

    expect(space, isA<PdfDeviceNColorSpace>());
    expect(space!.toRgb(<double>[0.25, 0.5]), <double>[0.75, 0.5, 1]);
  });

  test('operators paint Separation and preserve invalid transforms safely', () {
    final good = PdfDict(<String, PdfObject>{
      'FunctionType': const PdfNumber(2),
      'Domain': const PdfArray(<PdfObject>[PdfNumber(0), PdfNumber(1)]),
      'C0': const PdfArray(<PdfObject>[
        PdfNumber(0),
        PdfNumber(0),
        PdfNumber(0),
      ]),
      'C1': const PdfArray(<PdfObject>[
        PdfNumber(1),
        PdfNumber(0),
        PdfNumber(0),
      ]),
      'N': const PdfNumber(1),
    });
    final resources = PdfDict(<String, PdfObject>{
      'ColorSpace': PdfDict(<String, PdfObject>{
        'Spot': PdfArray(<PdfObject>[
          const PdfName('Separation'),
          const PdfName('Ink'),
          const PdfName('DeviceRGB'),
          good,
        ]),
        'Broken': const PdfArray(<PdfObject>[
          PdfName('Separation'),
          PdfName('Ink'),
          PdfName('DeviceRGB'),
          PdfNull(),
        ]),
      }),
    });
    final interpreter = PdfContentInterpreter(
      device: PdfMemoryOutputDevice(),
      resources: resources,
    )..execute(
        Uint8List.fromList(utf8.encode('/Spot cs 0.5 scn /Broken cs 1 scn')));

    expect(interpreter.currentState.fillColor, 0xff800000);
    expect(interpreter.currentState.fillColorSpaceSupported, isFalse);
  });

  test('sampled and stitching functions evaluate deterministically', () {
    final sampled = PdfStream(
      PdfDict(<String, PdfObject>{
        'FunctionType': const PdfNumber(0),
        'Domain': const PdfArray(<PdfObject>[PdfNumber(0), PdfNumber(1)]),
        'Range': const PdfArray(<PdfObject>[PdfNumber(0), PdfNumber(1)]),
        'Size': const PdfArray(<PdfObject>[PdfNumber(2)]),
        'BitsPerSample': const PdfNumber(8),
      }),
      Uint8List.fromList(<int>[0, 255]),
    );
    expect(PdfFunction.parse(sampled, null)!.evaluate(<double>[0.5])!.single,
        closeTo(0.5, 0.001));

    PdfDict exponential(double from, double to) => PdfDict(<String, PdfObject>{
          'FunctionType': const PdfNumber(2),
          'Domain': const PdfArray(<PdfObject>[PdfNumber(0), PdfNumber(1)]),
          'C0': PdfArray(<PdfObject>[PdfNumber(from)]),
          'C1': PdfArray(<PdfObject>[PdfNumber(to)]),
          'N': const PdfNumber(1),
        });
    final stitching = PdfDict(<String, PdfObject>{
      'FunctionType': const PdfNumber(3),
      'Domain': const PdfArray(<PdfObject>[PdfNumber(0), PdfNumber(1)]),
      'Functions': PdfArray(<PdfObject>[
        exponential(0, 1),
        exponential(1, 0),
      ]),
      'Bounds': const PdfArray(<PdfObject>[PdfNumber(0.5)]),
      'Encode': const PdfArray(<PdfObject>[
        PdfNumber(0),
        PdfNumber(1),
        PdfNumber(0),
        PdfNumber(1),
      ]),
    });
    expect(PdfFunction.parse(stitching, null)!.evaluate(<double>[0.25])!.single,
        closeTo(0.5, 0.001));
  });
}
