import 'dart:typed_data';

/// Representação abstrata de um espaço de cor no PDF (ISO 32000-1, Seção 8.6).
abstract class PdfColorSpace {
  /// Retorna o número de componentes de cor esperados por este espaço.
  int get numComponents;

  /// Converte um array de componentes de cor neste espaço para RGB (0.0 a 1.0).
  ///
  /// O retorno sempre contém 3 elementos: [R, G, B].
  List<double> toRgb(List<double> components);
}

/// Espaço de cor /DeviceGray (1 componente).
class PdfDeviceGray extends PdfColorSpace {
  @override
  int get numComponents => 1;

  @override
  List<double> toRgb(List<double> components) {
    if (components.isEmpty) return [0.0, 0.0, 0.0];
    final g = components[0].clamp(0.0, 1.0);
    return [g, g, g];
  }
}

/// Espaço de cor /DeviceRGB (3 componentes).
class PdfDeviceRgb extends PdfColorSpace {
  @override
  int get numComponents => 3;

  @override
  List<double> toRgb(List<double> components) {
    if (components.length < 3) return [0.0, 0.0, 0.0];
    return [
      components[0].clamp(0.0, 1.0),
      components[1].clamp(0.0, 1.0),
      components[2].clamp(0.0, 1.0),
    ];
  }
}

/// Espaço de cor /DeviceCMYK (4 componentes).
class PdfDeviceCmyk extends PdfColorSpace {
  @override
  int get numComponents => 4;

  @override
  List<double> toRgb(List<double> components) {
    if (components.length < 4) return [0.0, 0.0, 0.0];
    final c = components[0].clamp(0.0, 1.0);
    final m = components[1].clamp(0.0, 1.0);
    final y = components[2].clamp(0.0, 1.0);
    final k = components[3].clamp(0.0, 1.0);

    // Conversão CMYK para RGB padrão (sem perfil ICC)
    final r = 1.0 - (c * (1.0 - k) + k);
    final g = 1.0 - (m * (1.0 - k) + k);
    final b = 1.0 - (y * (1.0 - k) + k);

    return [r.clamp(0.0, 1.0), g.clamp(0.0, 1.0), b.clamp(0.0, 1.0)];
  }
}

/// Espaço de cor indexado (/Indexed), usando uma paleta base.
class PdfIndexedColorSpace extends PdfColorSpace {
  final PdfColorSpace baseSpace;
  final int hival;
  final Uint8List lookupTable;

  PdfIndexedColorSpace({
    required this.baseSpace,
    required this.hival,
    required this.lookupTable,
  });

  @override
  int get numComponents => 1;

  @override
  List<double> toRgb(List<double> components) {
    if (components.isEmpty) return [0.0, 0.0, 0.0];
    int index = components[0].toInt();
    if (index < 0) index = 0;
    if (index > hival) index = hival;

    final n = baseSpace.numComponents;
    final baseOffset = index * n;

    if (baseOffset + n > lookupTable.length) {
      return [0.0, 0.0, 0.0]; // Tabela malformada
    }

    final baseComponents = List<double>.filled(n, 0.0);
    for (var i = 0; i < n; i++) {
      baseComponents[i] = lookupTable[baseOffset + i] / 255.0;
    }

    return baseSpace.toRgb(baseComponents);
  }
}
