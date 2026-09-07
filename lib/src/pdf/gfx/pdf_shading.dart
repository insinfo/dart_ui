import 'dart:math' as math;
import 'dart:typed_data';

import '../../graphics/gradient.dart';
import '../format/pdf_object.dart';

/// Parsed ISO 32000 shading dictionary (ShadingType 1 through 7).
final class PdfShading {
  PdfShading._({
    required this.type,
    required this.dictionary,
    required this.colorComponents,
    required this.data,
  });

  final int type;
  final PdfDict dictionary;
  final int colorComponents;

  /// Decoded mesh data for shading types 4 through 7.
  final Uint8List data;

  bool get isMesh => type >= 4 && type <= 7;

  bool extension(PdfResolver? resolver, int end) {
    final values = dictionary.getArray('Extend', resolver);
    return (values?.getResolved(end, resolver) as PdfBoolean?)?.value ?? false;
  }

  int? get bitsPerCoordinate =>
      dictionary.getNumber('BitsPerCoordinate')?.toInt();
  int? get bitsPerComponent =>
      dictionary.getNumber('BitsPerComponent')?.toInt();
  int get bitsPerFlag => dictionary.getNumber('BitsPerFlag')?.toInt() ?? 0;
  int? get verticesPerRow => dictionary.getNumber('VerticesPerRow')?.toInt();

  static PdfShading? parse(PdfObject object, PdfResolver? resolver) {
    final resolved = object.resolve(resolver);
    final PdfDict dictionary;
    final Uint8List data;
    if (resolved is PdfStream) {
      dictionary = resolved.dict;
      data = resolved.getDecodedBytes(resolver);
    } else if (resolved is PdfDict) {
      dictionary = resolved;
      data = Uint8List(0);
    } else {
      return null;
    }
    final type = dictionary.getNumber('ShadingType', resolver)?.toInt();
    if (type == null || type < 1 || type > 7) return null;
    final colorSpace = dictionary.getResolved('ColorSpace', resolver);
    final components = _colorComponents(colorSpace, resolver);
    if (components == null) return null;
    if (type >= 4) {
      if (data.isEmpty || !_validMeshDictionary(dictionary, type, resolver)) {
        return null;
      }
    }
    return PdfShading._(
      type: type,
      dictionary: dictionary,
      colorComponents: components,
      data: data,
    );
  }

  /// Decodes the vertex stream of free-form (4) and lattice (5) Gouraud
  /// meshes. Patch meshes (6/7) use control-point records and are intentionally
  /// exposed through [data] until their patch tessellator consumes them.
  List<PdfShadingVertex>? decodeGouraudVertices(PdfResolver? resolver) {
    if (type != 4 && type != 5) return null;
    final decode = _numbers(dictionary.getArray('Decode', resolver), resolver);
    if (decode == null || decode.length < 4 + colorComponents * 2) return null;
    final coordinateBits = bitsPerCoordinate!;
    final componentBits = bitsPerComponent!;
    final flagBits = type == 4 ? bitsPerFlag : 0;
    final reader = _BitReader(data);
    final result = <PdfShadingVertex>[];
    final bitsPerVertex =
        flagBits + coordinateBits * 2 + componentBits * colorComponents;
    while (reader.remainingBits >= bitsPerVertex) {
      final flag = flagBits == 0 ? 0 : reader.read(flagBits);
      final x = _decodeSample(
          reader.read(coordinateBits), coordinateBits, decode[0], decode[1]);
      final y = _decodeSample(
          reader.read(coordinateBits), coordinateBits, decode[2], decode[3]);
      final components = <double>[
        for (var index = 0; index < colorComponents; index++)
          _decodeSample(
            reader.read(componentBits),
            componentBits,
            decode[4 + index * 2],
            decode[5 + index * 2],
          ),
      ];
      result.add(PdfShadingVertex(flag, x, y, components));
    }
    return List<PdfShadingVertex>.unmodifiable(result);
  }

  /// Converts the directly representable axial/radial shadings to dart_ui's
  /// retained gradient resource. Other types remain parsed for mesh/raster
  /// consumers and return null here.
  Gradient? toGradient(PdfResolver? resolver, {int samples = 17}) {
    if (type != 2 && type != 3) return null;
    final coords = _numbers(dictionary.getArray('Coords', resolver), resolver);
    if (coords == null || coords.length < (type == 2 ? 4 : 6)) return null;
    final function = dictionary.getResolved('Function', resolver);
    if (function == null) return null;
    final domain =
        _numbers(dictionary.getArray('Domain', resolver), resolver) ??
            const <double>[0, 1];
    if (domain.length < 2) return null;
    final stops = <GradientStop>[];
    for (var index = 0; index < samples; index++) {
      final offset = index / (samples - 1);
      final input = domain[0] + (domain[1] - domain[0]) * offset;
      final values = _evaluateFunction(function, input, resolver);
      if (values == null || values.length < colorComponents) return null;
      stops.add(GradientStop(offset, _color(values)));
    }
    if (type == 2) {
      return LinearGradient(
        startX: coords[0],
        startY: coords[1],
        endX: coords[2],
        endY: coords[3],
        stops: stops,
        spread: GradientSpread.pad,
      );
    }
    // The retained radial primitive exactly represents the overwhelmingly
    // common PDF case where the first circle is a point.
    if (coords[2].abs() > 1e-9 || coords[5] <= 0) return null;
    return RadialGradient(
      focusX: coords[0],
      focusY: coords[1],
      centerX: coords[3],
      centerY: coords[4],
      radius: coords[5],
      stops: stops,
      spread: GradientSpread.pad,
    );
  }

  int _color(List<double> values) {
    int byte(double value) => (value.clamp(0.0, 1.0) * 255).round();
    final int r;
    final int g;
    final int b;
    if (colorComponents == 1) {
      r = g = b = byte(values[0]);
    } else if (colorComponents == 4) {
      final c = values[0].clamp(0.0, 1.0);
      final m = values[1].clamp(0.0, 1.0);
      final y = values[2].clamp(0.0, 1.0);
      final k = values[3].clamp(0.0, 1.0);
      r = byte((1 - c) * (1 - k));
      g = byte((1 - m) * (1 - k));
      b = byte((1 - y) * (1 - k));
    } else {
      r = byte(values[0]);
      g = byte(values[1]);
      b = byte(values[2]);
    }
    return 0xFF000000 | (r << 16) | (g << 8) | b;
  }
}

final class PdfShadingVertex {
  const PdfShadingVertex(this.flag, this.x, this.y, this.components);

  final int flag;
  final double x;
  final double y;
  final List<double> components;
}

bool _validMeshDictionary(PdfDict dictionary, int type, PdfResolver? resolver) {
  final coordinateBits =
      dictionary.getNumber('BitsPerCoordinate', resolver)?.toInt();
  final componentBits =
      dictionary.getNumber('BitsPerComponent', resolver)?.toInt();
  if (!const <int>[1, 2, 4, 8, 12, 16, 24, 32].contains(coordinateBits) ||
      !const <int>[1, 2, 4, 8, 12, 16].contains(componentBits)) {
    return false;
  }
  final decode = dictionary.getArray('Decode', resolver);
  if (decode == null || decode.length < 4) return false;
  if (type == 5) {
    return (dictionary.getNumber('VerticesPerRow', resolver)?.toInt() ?? 0) >=
        2;
  }
  return const <int>[2, 4, 8]
      .contains(dictionary.getNumber('BitsPerFlag', resolver)?.toInt());
}

double _decodeSample(int sample, int bits, double low, double high) {
  final maximum = bits == 32 ? 0xFFFFFFFF : (1 << bits) - 1;
  return low + sample / maximum * (high - low);
}

final class _BitReader {
  _BitReader(this.bytes);

  final Uint8List bytes;
  int get remainingBits => bytes.length * 8 - _offset;
  int _offset = 0;

  int read(int count) {
    var value = 0;
    for (var index = 0; index < count; index++) {
      final byte = bytes[_offset >> 3];
      value = (value << 1) | ((byte >> (7 - (_offset & 7))) & 1);
      _offset++;
    }
    return value;
  }
}

int? _colorComponents(PdfObject? object, PdfResolver? resolver) {
  final resolved = object?.resolve(resolver);
  final name = resolved is PdfName
      ? resolved.name
      : resolved is PdfArray && resolved.length > 0
          ? (resolved.getResolved(0, resolver) as PdfName?)?.name
          : null;
  return switch (name) {
    'DeviceGray' || 'G' || 'CalGray' => 1,
    'DeviceRGB' || 'RGB' || 'CalRGB' || 'Lab' => 3,
    'DeviceCMYK' || 'CMYK' => 4,
    _ => null,
  };
}

List<double>? _numbers(PdfArray? array, PdfResolver? resolver) {
  if (array == null) return null;
  final values = <double>[];
  for (var index = 0; index < array.length; index++) {
    final value = array.getNumber(index, resolver);
    if (value == null) return null;
    values.add(value.toDouble());
  }
  return values;
}

List<double>? _evaluateFunction(
  PdfObject object,
  double input,
  PdfResolver? resolver,
) {
  final resolved = object.resolve(resolver);
  if (resolved is PdfArray) {
    final values = <double>[];
    for (var index = 0; index < resolved.length; index++) {
      final child = resolved.getResolved(index, resolver);
      if (child == null) return null;
      final result = _evaluateFunction(child, input, resolver);
      if (result == null) return null;
      values.addAll(result);
    }
    return values;
  }
  final dict = resolved is PdfStream
      ? resolved.dict
      : resolved is PdfDict
          ? resolved
          : null;
  if (dict == null) return null;
  final functionType = dict.getNumber('FunctionType', resolver)?.toInt();
  final domain = _numbers(dict.getArray('Domain', resolver), resolver) ??
      const <double>[0, 1];
  if (domain.length < 2) return null;
  final x = input.clamp(domain[0], domain[1]);
  if (functionType == 0 && resolved is PdfStream) {
    final sizes = _numbers(dict.getArray('Size', resolver), resolver);
    final bits = dict.getNumber('BitsPerSample', resolver)?.toInt();
    if (sizes == null || sizes.length != 1 || bits == null || bits > 32) {
      return null;
    }
    final size = sizes.single.toInt();
    if (size < 1 || !const <int>[1, 2, 4, 8, 12, 16, 24, 32].contains(bits)) {
      return null;
    }
    final range = _numbers(dict.getArray('Range', resolver), resolver);
    if (range == null || range.length.isOdd) return null;
    final outputs = range.length ~/ 2;
    final encode = _numbers(dict.getArray('Encode', resolver), resolver) ??
        <double>[0, (size - 1).toDouble()];
    final decode =
        _numbers(dict.getArray('Decode', resolver), resolver) ?? range;
    if (encode.length < 2 || decode.length < outputs * 2) return null;
    final position =
        ((x - domain[0]) / (domain[1] - domain[0]) * (encode[1] - encode[0]) +
                encode[0])
            .clamp(0.0, (size - 1).toDouble());
    final lowIndex = position.floor();
    final highIndex = math.min(size - 1, lowIndex + 1);
    final fraction = position - lowIndex;
    final reader = _BitReader(resolved.getDecodedBytes(resolver));
    final all = <int>[];
    while (reader.remainingBits >= bits) {
      all.add(reader.read(bits));
    }
    if (all.length < size * outputs) return null;
    final maximum = bits == 32 ? 0xFFFFFFFF : (1 << bits) - 1;
    return <double>[
      for (var output = 0; output < outputs; output++)
        () {
          final a = all[lowIndex * outputs + output] / maximum;
          final b = all[highIndex * outputs + output] / maximum;
          final sample = a + (b - a) * fraction;
          final value = decode[output * 2] +
              sample * (decode[output * 2 + 1] - decode[output * 2]);
          return value.clamp(range[output * 2], range[output * 2 + 1]);
        }(),
    ];
  }
  if (functionType == 3) {
    final functions = dict.getArray('Functions', resolver);
    final bounds = _numbers(dict.getArray('Bounds', resolver), resolver) ??
        const <double>[];
    final encode = _numbers(dict.getArray('Encode', resolver), resolver);
    if (functions == null ||
        functions.length == 0 ||
        bounds.length != functions.length - 1 ||
        encode == null ||
        encode.length < functions.length * 2) {
      return null;
    }
    var index = 0;
    while (index < bounds.length && x >= bounds[index]) {
      index++;
    }
    final low = index == 0 ? domain[0] : bounds[index - 1];
    final high = index == bounds.length ? domain[1] : bounds[index];
    final encoded = low == high
        ? encode[index * 2]
        : encode[index * 2] +
            (x - low) /
                (high - low) *
                (encode[index * 2 + 1] - encode[index * 2]);
    final child = functions.getResolved(index, resolver);
    return child == null ? null : _evaluateFunction(child, encoded, resolver);
  }
  if (functionType != 2) return null;
  final c0 =
      _numbers(dict.getArray('C0', resolver), resolver) ?? const <double>[0];
  final c1 =
      _numbers(dict.getArray('C1', resolver), resolver) ?? const <double>[1];
  if (c0.length != c1.length) return null;
  final exponent = dict.getNumber('N', resolver)?.toDouble() ?? 1;
  final factor = math.pow(x, exponent).toDouble();
  return <double>[
    for (var index = 0; index < c0.length; index++)
      c0[index] + factor * (c1[index] - c0[index]),
  ];
}
