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
    required PdfResolver? resolver,
  }) : _resolver = resolver;

  final int type;
  final PdfDict dictionary;
  final int colorComponents;

  /// Decoded mesh data for shading types 4 through 7.
  final Uint8List data;
  final PdfResolver? _resolver;

  /// Hard ceiling for decoded mesh records. Malicious files must not turn a
  /// small compressed stream into an unbounded object graph.
  static const int maxMeshRecords = 1000000;

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

  int _streamColorComponents(PdfResolver? resolver) =>
      dictionary.getResolved('Function', resolver) == null
          ? colorComponents
          : 1;

  List<double>? _mapMeshColor(List<double> samples, PdfResolver? resolver) {
    final function = dictionary.getResolved('Function', resolver);
    if (function == null) return samples;
    final mapped = _evaluateFunction(function, samples.single, resolver);
    return mapped != null && mapped.length >= colorComponents
        ? mapped.take(colorComponents).toList(growable: false)
        : null;
  }

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
      resolver: resolver,
    );
  }

  /// Decodes the vertex stream of free-form (4) and lattice (5) Gouraud
  /// meshes. Patch meshes (6/7) use control-point records and are intentionally
  /// exposed through [data] until their patch tessellator consumes them.
  List<PdfShadingVertex>? decodeGouraudVertices(PdfResolver? resolver) {
    if (type != 4 && type != 5) return null;
    resolver ??= _resolver;
    final decode = _numbers(dictionary.getArray('Decode', resolver), resolver);
    final streamComponents = _streamColorComponents(resolver);
    if (decode == null || decode.length < 4 + streamComponents * 2) return null;
    final coordinateBits = bitsPerCoordinate!;
    final componentBits = bitsPerComponent!;
    final flagBits = type == 4 ? bitsPerFlag : 0;
    final reader = _BitReader(data);
    final result = <PdfShadingVertex>[];
    final bitsPerVertex =
        flagBits + coordinateBits * 2 + componentBits * streamComponents;
    while (reader.remainingBits >= bitsPerVertex &&
        result.length < maxMeshRecords) {
      final flag = flagBits == 0 ? 0 : reader.read(flagBits);
      final x = _decodeSample(
          reader.read(coordinateBits), coordinateBits, decode[0], decode[1]);
      final y = _decodeSample(
          reader.read(coordinateBits), coordinateBits, decode[2], decode[3]);
      final samples = <double>[
        for (var index = 0; index < streamComponents; index++)
          _decodeSample(
            reader.read(componentBits),
            componentBits,
            decode[4 + index * 2],
            decode[5 + index * 2],
          ),
      ];
      final components = _mapMeshColor(samples, resolver);
      if (components == null) return null;
      result.add(PdfShadingVertex(flag, x, y, components));
    }
    return List<PdfShadingVertex>.unmodifiable(result);
  }

  /// Decodes and tessellates mesh shadings into color-interpolated triangles.
  ///
  /// [patchDivisions] controls the uniform grid used for Coons/tensor patches.
  /// It is deliberately bounded: each patch emits `2 * divisions²` triangles.
  List<PdfShadingTriangle>? tessellate(
    PdfResolver? resolver, {
    int patchDivisions = 8,
    int maxTriangles = 200000,
  }) {
    if (!isMesh || maxTriangles <= 0) return isMesh ? const [] : null;
    resolver ??= _resolver;
    if (type == 4 || type == 5) {
      final vertices = decodeGouraudVertices(resolver);
      if (vertices == null) return null;
      final triangles = <PdfShadingTriangle>[];
      if (type == 5) {
        final width = verticesPerRow!;
        for (var row = 0; row + 1 < vertices.length ~/ width; row++) {
          for (var column = 0; column + 1 < width; column++) {
            final a = vertices[row * width + column];
            final b = vertices[row * width + column + 1];
            final c = vertices[(row + 1) * width + column];
            final d = vertices[(row + 1) * width + column + 1];
            triangles.add(PdfShadingTriangle(a, b, c));
            if (triangles.length >= maxTriangles) {
              return List.unmodifiable(triangles);
            }
            triangles.add(PdfShadingTriangle(b, d, c));
            if (triangles.length >= maxTriangles) {
              return List.unmodifiable(triangles);
            }
          }
        }
        return List.unmodifiable(triangles);
      }
      var index = 0;
      PdfShadingTriangle? previous;
      while (index < vertices.length && triangles.length < maxTriangles) {
        final vertex = vertices[index++];
        final flag = previous == null ? 0 : vertex.flag;
        if (flag == 0) {
          if (index + 1 >= vertices.length) break;
          previous =
              PdfShadingTriangle(vertex, vertices[index++], vertices[index++]);
        } else if (flag == 1) {
          previous = PdfShadingTriangle(previous!.b, previous.c, vertex);
        } else if (flag == 2) {
          previous = PdfShadingTriangle(previous!.a, previous.c, vertex);
        } else {
          continue;
        }
        triangles.add(previous);
      }
      return List.unmodifiable(triangles);
    }

    final patches = _decodePatches(resolver);
    if (patches == null) return null;
    final divisions = patchDivisions.clamp(1, 32);
    final triangles = <PdfShadingTriangle>[];
    for (final patch in patches) {
      for (var y = 0; y < divisions && triangles.length < maxTriangles; y++) {
        for (var x = 0; x < divisions && triangles.length < maxTriangles; x++) {
          final u0 = x / divisions;
          final u1 = (x + 1) / divisions;
          final v0 = y / divisions;
          final v1 = (y + 1) / divisions;
          final a = patch.sample(u0, v0);
          final b = patch.sample(u1, v0);
          final c = patch.sample(u0, v1);
          final d = patch.sample(u1, v1);
          triangles.add(PdfShadingTriangle(a, b, c));
          if (triangles.length < maxTriangles) {
            triangles.add(PdfShadingTriangle(b, d, c));
          }
        }
      }
    }
    return List.unmodifiable(triangles);
  }

  List<_PdfPatch>? _decodePatches(PdfResolver? resolver) {
    final decode = _numbers(dictionary.getArray('Decode', resolver), resolver);
    final streamComponents = _streamColorComponents(resolver);
    if (decode == null || decode.length < 4 + streamComponents * 2) return null;
    final reader = _BitReader(data);
    final patches = <_PdfPatch>[];
    _PdfPatch? previous;
    final pointCount = type == 6 ? 12 : 16;
    while (reader.remainingBits >= bitsPerFlag &&
        patches.length < maxMeshRecords) {
      final flag = reader.read(bitsPerFlag);
      if (flag > 3) break;
      final reused = flag == 0 ? 0 : 4;
      final colorsReused = flag == 0 ? 0 : 2;
      final required = (pointCount - reused) * bitsPerCoordinate! * 2 +
          (4 - colorsReused) * streamComponents * bitsPerComponent!;
      if (reader.remainingBits < required || (flag != 0 && previous == null)) {
        break;
      }
      final points = List<_PdfPoint>.filled(pointCount, const _PdfPoint(0, 0));
      final colors = List<List<double>>.generate(4, (_) => <double>[]);
      if (flag != 0) {
        final start = switch (flag) { 1 => 3, 2 => 6, _ => 9 };
        for (var i = 0; i < 4; i++) {
          points[i] = previous!.boundary[(start + i) % 12];
        }
        final c0 = switch (flag) { 1 => 1, 2 => 2, _ => 3 };
        colors[0] = List.of(previous!.colors[c0]);
        colors[1] = List.of(previous.colors[(c0 + 1) % 4]);
      }
      for (var i = reused; i < pointCount; i++) {
        points[i] = _PdfPoint(
          _decodeSample(reader.read(bitsPerCoordinate!), bitsPerCoordinate!,
              decode[0], decode[1]),
          _decodeSample(reader.read(bitsPerCoordinate!), bitsPerCoordinate!,
              decode[2], decode[3]),
        );
      }
      for (var c = colorsReused; c < 4; c++) {
        colors[c] = <double>[
          for (var i = 0; i < streamComponents; i++)
            _decodeSample(reader.read(bitsPerComponent!), bitsPerComponent!,
                decode[4 + i * 2], decode[5 + i * 2]),
        ];
        final mapped = _mapMeshColor(colors[c], resolver);
        if (mapped == null) return null;
        colors[c] = mapped;
      }
      previous = _PdfPatch.fromStream(type, points, colors);
      patches.add(previous);
    }
    return List.unmodifiable(patches);
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

  /// Converts decoded color-space components to opaque sRGB for renderers.
  int colorForComponents(List<double> values) => _color(values);
}

final class PdfShadingVertex {
  const PdfShadingVertex(this.flag, this.x, this.y, this.components);

  final int flag;
  final double x;
  final double y;
  final List<double> components;
}

final class PdfShadingTriangle {
  const PdfShadingTriangle(this.a, this.b, this.c);
  final PdfShadingVertex a;
  final PdfShadingVertex b;
  final PdfShadingVertex c;
}

final class _PdfPoint {
  const _PdfPoint(this.x, this.y);
  final double x;
  final double y;
}

final class _PdfPatch {
  _PdfPatch(this.poles, this.boundary, this.colors);
  final List<List<_PdfPoint>> poles;
  final List<_PdfPoint> boundary;
  final List<List<double>> colors;

  factory _PdfPatch.fromStream(
      int type, List<_PdfPoint> p, List<List<double>> colors) {
    final poles = List.generate(
        4, (_) => List<_PdfPoint>.filled(4, const _PdfPoint(0, 0)));
    poles[0][0] = p[0];
    poles[0][1] = p[1];
    poles[0][2] = p[2];
    poles[0][3] = p[3];
    poles[1][3] = p[4];
    poles[2][3] = p[5];
    poles[3][3] = p[6];
    poles[3][2] = p[7];
    poles[3][1] = p[8];
    poles[3][0] = p[9];
    poles[2][0] = p[10];
    poles[1][0] = p[11];
    if (type == 7) {
      poles[1][1] = p[12];
      poles[1][2] = p[13];
      poles[2][2] = p[14];
      poles[2][1] = p[15];
    } else {
      poles[1][1] = _interior(poles[0][0], poles[0][1], poles[1][0],
          poles[0][3], poles[3][0], poles[3][1], poles[1][3], poles[3][3]);
      poles[1][2] = _interior(poles[0][3], poles[0][2], poles[1][3],
          poles[0][0], poles[3][3], poles[3][2], poles[1][0], poles[3][0]);
      poles[2][1] = _interior(poles[3][0], poles[3][1], poles[2][0],
          poles[3][3], poles[0][0], poles[0][1], poles[2][3], poles[0][3]);
      poles[2][2] = _interior(poles[3][3], poles[3][2], poles[2][3],
          poles[3][0], poles[0][3], poles[0][2], poles[2][0], poles[0][0]);
    }
    return _PdfPatch(poles, List.of(p.take(12)), colors);
  }

  PdfShadingVertex sample(double u, double v) {
    final bu = _bernstein(u), bv = _bernstein(v);
    var x = 0.0, y = 0.0;
    for (var i = 0; i < 4; i++) {
      for (var j = 0; j < 4; j++) {
        final w = bv[i] * bu[j];
        x += poles[i][j].x * w;
        y += poles[i][j].y * w;
      }
    }
    final components = <double>[
      for (var k = 0; k < colors[0].length; k++)
        colors[0][k] * (1 - u) * (1 - v) +
            colors[1][k] * u * (1 - v) +
            colors[2][k] * u * v +
            colors[3][k] * (1 - u) * v,
    ];
    return PdfShadingVertex(0, x, y, components);
  }

  static List<double> _bernstein(double t) => <double>[
        (1 - t) * (1 - t) * (1 - t),
        3 * t * (1 - t) * (1 - t),
        3 * t * t * (1 - t),
        t * t * t
      ];
  static _PdfPoint _interior(_PdfPoint a, _PdfPoint b, _PdfPoint c, _PdfPoint d,
          _PdfPoint e, _PdfPoint f, _PdfPoint g, _PdfPoint h) =>
      _PdfPoint(
        (-4 * a.x + 6 * (b.x + c.x) - 2 * (d.x + e.x) + 3 * (f.x + g.x) - h.x) /
            9,
        (-4 * a.y + 6 * (b.y + c.y) - 2 * (d.y + e.y) + 3 * (f.y + g.y) - h.y) /
            9,
      );
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
