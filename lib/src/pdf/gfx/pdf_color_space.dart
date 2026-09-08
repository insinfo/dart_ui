import 'dart:math' as math;
import 'dart:typed_data';

import '../format/pdf_object.dart';
import 'pdf_function.dart';

/// Representação abstrata de um espaço de cor no PDF (ISO 32000-1, Seção 8.6).
abstract class PdfColorSpace {
  /// Retorna o número de componentes de cor esperados por este espaço.
  int get numComponents;

  /// Converte um array de componentes de cor neste espaço para RGB (0.0 a 1.0).
  ///
  /// O retorno sempre contém 3 elementos: [R, G, B].
  List<double> toRgb(List<double> components);

  /// Resolves the device and calibrated color spaces defined by ISO 32000.
  /// Unsupported spaces return null instead of being silently treated as RGB.
  static PdfColorSpace? parse(PdfObject? object, PdfResolver? resolver) {
    final resolved = object?.resolve(resolver);
    if (resolved is PdfName) {
      if (resolved.name == 'Pattern') return PdfPatternColorSpace();
      return _deviceSpace(resolved.name);
    }
    if (resolved is! PdfArray || resolved.length == 0) return null;
    final family = resolved.getResolved(0, resolver);
    if (family is! PdfName) return null;
    if (family.name == 'Indexed' || family.name == 'I') {
      if (resolved.length < 4) return null;
      final base = parse(resolved.getResolved(1, resolver), resolver);
      final hival = resolved.getNumber(2, resolver)?.toInt();
      final lookup = resolved.getResolved(3, resolver);
      final bytes = switch (lookup) {
        PdfString(:final bytes) => bytes,
        PdfStream() => lookup.getDecodedBytes(resolver),
        _ => null,
      };
      if (base == null || hival == null || hival < 0 || bytes == null) {
        return null;
      }
      final required = (hival + 1) * base.numComponents;
      if (bytes.length < required) return null;
      return PdfIndexedColorSpace(
        baseSpace: base,
        hival: hival,
        lookupTable: Uint8List.sublistView(bytes, 0, required),
      );
    }
    if (family.name == 'ICCBased') {
      final profile = resolved.getResolved(1, resolver);
      if (profile is! PdfStream) return null;
      final components = profile.dict.getNumber('N', resolver)?.toInt();
      if (components == null || !const <int>[1, 3, 4].contains(components)) {
        return null;
      }
      final alternateObject = profile.dict.getResolved('Alternate', resolver);
      final alternate = alternateObject == null
          ? switch (components) {
              1 => PdfDeviceGray(),
              3 => PdfDeviceRgb(),
              4 => PdfDeviceCmyk(),
              _ => null,
            }
          : parse(alternateObject, resolver);
      if (alternate == null || alternate.numComponents != components) {
        return null;
      }
      return PdfIccBasedColorSpace(
        componentCount: components,
        alternateSpace: alternate,
        profile: profile.rawBytes,
      );
    }
    if (family.name == 'Separation') {
      if (resolved.length < 4) return null;
      final colorant = resolved.getResolved(1, resolver);
      final alternate = parse(resolved.getResolved(2, resolver), resolver);
      final transform =
          PdfFunction.parse(resolved.getResolved(3, resolver), resolver);
      if (colorant is! PdfName ||
          alternate == null ||
          transform == null ||
          transform.inputCount != 1) {
        return null;
      }
      return PdfSeparationColorSpace(
        colorantName: colorant.name,
        alternateSpace: alternate,
        tintTransform: transform,
      );
    }
    if (family.name == 'DeviceN') {
      if (resolved.length < 4) return null;
      final namesObject = resolved.getResolved(1, resolver);
      final alternate = parse(resolved.getResolved(2, resolver), resolver);
      final transform =
          PdfFunction.parse(resolved.getResolved(3, resolver), resolver);
      if (namesObject is! PdfArray || alternate == null || transform == null) {
        return null;
      }
      final names = <String>[];
      for (var i = 0; i < namesObject.length; i++) {
        final name = namesObject.getResolved(i, resolver);
        if (name is! PdfName) return null;
        names.add(name.name);
      }
      if (names.isEmpty || transform.inputCount != names.length) return null;
      return PdfDeviceNColorSpace(
        colorantNames: List<String>.unmodifiable(names),
        alternateSpace: alternate,
        tintTransform: transform,
      );
    }
    if (family.name == 'Pattern') {
      if (resolved.length == 1) return PdfPatternColorSpace();
      final base = parse(resolved.getResolved(1, resolver), resolver);
      return base == null ? null : PdfPatternColorSpace(base);
    }
    final parameters = resolved.getResolved(1, resolver);
    if (parameters is! PdfDict) return null;
    return switch (family.name) {
      'CalGray' => PdfCalGray.fromDictionary(parameters, resolver),
      'CalRGB' => PdfCalRgb.fromDictionary(parameters, resolver),
      'Lab' => PdfLab.fromDictionary(parameters, resolver),
      _ => null,
    };
  }
}

/// ICCBased space. The profile bytes are preserved for colour-managed devices;
/// the portable converter uses the profile's explicit Alternate space (or the
/// ISO-defined device default when Alternate is absent).
final class PdfIccBasedColorSpace extends PdfColorSpace {
  PdfIccBasedColorSpace({
    required this.componentCount,
    required this.alternateSpace,
    required this.profile,
  });

  final int componentCount;
  final PdfColorSpace alternateSpace;
  final Uint8List profile;

  @override
  int get numComponents => componentCount;

  @override
  List<double> toRgb(List<double> components) =>
      alternateSpace.toRgb(components);
}

/// A single named colourant mapped through a PDF tint transform.
final class PdfSeparationColorSpace extends PdfColorSpace {
  PdfSeparationColorSpace({
    required this.colorantName,
    required this.alternateSpace,
    required this.tintTransform,
  });

  final String colorantName;
  final PdfColorSpace alternateSpace;
  final PdfFunction tintTransform;

  @override
  int get numComponents => 1;

  @override
  List<double> toRgb(List<double> components) {
    if (components.length != 1) return const <double>[0, 0, 0];
    final alternate = tintTransform.evaluate(components);
    if (alternate == null || alternate.length != alternateSpace.numComponents) {
      throw const FormatException('Invalid Separation tint transform result');
    }
    return alternateSpace.toRgb(alternate);
  }
}

/// Multiple named colourants mapped through a PDF tint transform.
final class PdfDeviceNColorSpace extends PdfColorSpace {
  PdfDeviceNColorSpace({
    required this.colorantNames,
    required this.alternateSpace,
    required this.tintTransform,
  });

  final List<String> colorantNames;
  final PdfColorSpace alternateSpace;
  final PdfFunction tintTransform;

  @override
  int get numComponents => colorantNames.length;

  @override
  List<double> toRgb(List<double> components) {
    if (components.length != numComponents) return const <double>[0, 0, 0];
    final alternate = tintTransform.evaluate(components);
    if (alternate == null || alternate.length != alternateSpace.numComponents) {
      throw const FormatException('Invalid DeviceN tint transform result');
    }
    return alternateSpace.toRgb(alternate);
  }
}

/// Pattern color space, optionally carrying the base space of an uncolored
/// tiling pattern.
final class PdfPatternColorSpace extends PdfColorSpace {
  PdfPatternColorSpace([this.baseSpace]);
  final PdfColorSpace? baseSpace;

  @override
  int get numComponents => baseSpace?.numComponents ?? 0;

  @override
  List<double> toRgb(List<double> components) =>
      baseSpace?.toRgb(components) ?? const <double>[0, 0, 0];
}

PdfColorSpace? _deviceSpace(String name) => switch (name) {
      'DeviceGray' || 'G' => PdfDeviceGray(),
      'DeviceRGB' || 'RGB' => PdfDeviceRgb(),
      'DeviceCMYK' || 'CMYK' => PdfDeviceCmyk(),
      _ => null,
    };

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

/// CIE-based calibrated gray space.
final class PdfCalGray extends PdfColorSpace {
  PdfCalGray({required this.whitePoint, this.gamma = 1});

  factory PdfCalGray.fromDictionary(PdfDict dict, PdfResolver? resolver) {
    return PdfCalGray(
      whitePoint: _triple(dict.getArray('WhitePoint', resolver), resolver,
          fallback: const <double>[0.9505, 1, 1.089]),
      gamma: dict.getNumber('Gamma', resolver)?.toDouble() ?? 1,
    );
  }

  final List<double> whitePoint;
  final double gamma;

  @override
  int get numComponents => 1;

  @override
  List<double> toRgb(List<double> components) {
    final a = (components.isEmpty ? 0.0 : components[0]).clamp(0.0, 1.0);
    final value = math.pow(a, gamma).toDouble();
    return _xyzToSrgb(
      value * whitePoint[0],
      value * whitePoint[1],
      value * whitePoint[2],
    );
  }
}

/// CIE-based calibrated RGB space.
final class PdfCalRgb extends PdfColorSpace {
  PdfCalRgb({
    required this.whitePoint,
    required this.gamma,
    required this.matrix,
  });

  factory PdfCalRgb.fromDictionary(PdfDict dict, PdfResolver? resolver) {
    return PdfCalRgb(
      whitePoint: _triple(dict.getArray('WhitePoint', resolver), resolver,
          fallback: const <double>[0.9505, 1, 1.089]),
      gamma: _triple(dict.getArray('Gamma', resolver), resolver,
          fallback: const <double>[1, 1, 1]),
      matrix: _numbers(dict.getArray('Matrix', resolver), resolver, 9) ??
          const <double>[1, 0, 0, 0, 1, 0, 0, 0, 1],
    );
  }

  final List<double> whitePoint;
  final List<double> gamma;
  final List<double> matrix;

  @override
  int get numComponents => 3;

  @override
  List<double> toRgb(List<double> components) {
    if (components.length < 3) return const <double>[0, 0, 0];
    final a = math.pow(components[0].clamp(0, 1), gamma[0]).toDouble();
    final b = math.pow(components[1].clamp(0, 1), gamma[1]).toDouble();
    final c = math.pow(components[2].clamp(0, 1), gamma[2]).toDouble();
    return _xyzToSrgb(
      matrix[0] * a + matrix[3] * b + matrix[6] * c,
      matrix[1] * a + matrix[4] * b + matrix[7] * c,
      matrix[2] * a + matrix[5] * b + matrix[8] * c,
    );
  }
}

/// CIE L*a*b* color space with the PDF default range for a and b.
final class PdfLab extends PdfColorSpace {
  PdfLab({required this.whitePoint, required this.range});

  factory PdfLab.fromDictionary(PdfDict dict, PdfResolver? resolver) {
    return PdfLab(
      whitePoint: _triple(dict.getArray('WhitePoint', resolver), resolver,
          fallback: const <double>[0.9505, 1, 1.089]),
      range: _numbers(dict.getArray('Range', resolver), resolver, 4) ??
          const <double>[-100, 100, -100, 100],
    );
  }

  final List<double> whitePoint;
  final List<double> range;

  @override
  int get numComponents => 3;

  @override
  List<double> toRgb(List<double> components) {
    if (components.length < 3) return const <double>[0, 0, 0];
    final l = components[0].clamp(0.0, 100.0);
    final a = components[1].clamp(range[0], range[1]);
    final b = components[2].clamp(range[2], range[3]);
    final fy = (l + 16) / 116;
    final fx = fy + a / 500;
    final fz = fy - b / 200;
    double inverse(double value) {
      final cube = value * value * value;
      return cube >= 216 / 24389 ? cube : (116 * value - 16) / 903.3;
    }

    return _xyzToSrgb(
      whitePoint[0] * inverse(fx),
      whitePoint[1] * inverse(fy),
      whitePoint[2] * inverse(fz),
    );
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

List<double> _xyzToSrgb(double x, double y, double z) {
  final linear = <double>[
    3.2404542 * x - 1.5371385 * y - 0.4985314 * z,
    -0.969266 * x + 1.8760108 * y + 0.041556 * z,
    0.0556434 * x - 0.2040259 * y + 1.0572252 * z,
  ];
  double encode(double value) => (value <= 0.0031308
          ? 12.92 * value
          : 1.055 * math.pow(value, 1 / 2.4) - 0.055)
      .clamp(0.0, 1.0)
      .toDouble();
  return <double>[for (final value in linear) encode(value)];
}

List<double> _triple(
  PdfArray? array,
  PdfResolver? resolver, {
  required List<double> fallback,
}) =>
    _numbers(array, resolver, 3) ?? fallback;

List<double>? _numbers(PdfArray? array, PdfResolver? resolver, int count) {
  if (array == null || array.length < count) return null;
  final result = <double>[];
  for (var index = 0; index < count; index++) {
    final value = array.getNumber(index, resolver);
    if (value == null) return null;
    result.add(value.toDouble());
  }
  return List<double>.unmodifiable(result);
}
