import 'dart:convert';
import 'dart:math' as math;

import '../format/pdf_object.dart';

/// A PDF function used by shadings and special colour spaces.
abstract class PdfFunction {
  const PdfFunction(this.domain, this.range);

  final List<double> domain;
  final List<double>? range;

  int get inputCount => domain.length ~/ 2;

  List<double>? evaluate(List<double> inputs);

  List<double>? clipOutput(List<double>? values) {
    if (values == null) return null;
    final limits = range;
    if (limits == null) return values;
    if (limits.length < values.length * 2) return null;
    return <double>[
      for (var i = 0; i < values.length; i++)
        values[i].clamp(limits[i * 2], limits[i * 2 + 1]).toDouble(),
    ];
  }

  List<double>? clipInput(List<double> values) {
    if (values.length != inputCount) return null;
    return <double>[
      for (var i = 0; i < values.length; i++)
        values[i].clamp(domain[i * 2], domain[i * 2 + 1]).toDouble(),
    ];
  }

  static PdfFunction? parse(PdfObject? object, PdfResolver? resolver) {
    final resolved = object?.resolve(resolver);
    final dict = switch (resolved) {
      PdfStream(:final dict) => dict,
      PdfDict() => resolved,
      _ => null,
    };
    if (dict == null) return null;
    final domain = _numbers(dict.getArray('Domain', resolver), resolver);
    if (domain == null || domain.isEmpty || domain.length.isOdd) return null;
    final range = _numbers(dict.getArray('Range', resolver), resolver);
    if (range != null && (range.isEmpty || range.length.isOdd)) return null;
    return switch (dict.getNumber('FunctionType', resolver)?.toInt()) {
      0 when resolved is PdfStream =>
        _SampledFunction.parse(resolved, domain, range, resolver),
      2 => _ExponentialFunction.parse(dict, domain, range, resolver),
      3 => _StitchingFunction.parse(dict, domain, range, resolver),
      4 when resolved is PdfStream =>
        _CalculatorFunction.parse(resolved, domain, range, resolver),
      _ => null,
    };
  }
}

final class _ExponentialFunction extends PdfFunction {
  const _ExponentialFunction(
    super.domain,
    super.range,
    this.c0,
    this.c1,
    this.exponent,
  );

  final List<double> c0;
  final List<double> c1;
  final double exponent;

  static PdfFunction? parse(
    PdfDict dict,
    List<double> domain,
    List<double>? range,
    PdfResolver? resolver,
  ) {
    if (domain.length != 2) return null;
    final c0 = _numbers(dict.getArray('C0', resolver), resolver) ?? <double>[0];
    final c1 = _numbers(dict.getArray('C1', resolver), resolver) ?? <double>[1];
    final exponent = dict.getNumber('N', resolver)?.toDouble();
    if (c0.length != c1.length || exponent == null || !exponent.isFinite) {
      return null;
    }
    return _ExponentialFunction(domain, range, c0, c1, exponent);
  }

  @override
  List<double>? evaluate(List<double> inputs) {
    final clipped = clipInput(inputs);
    if (clipped == null) return null;
    final factor = math.pow(clipped.single, exponent).toDouble();
    return clipOutput(<double>[
      for (var i = 0; i < c0.length; i++) c0[i] + factor * (c1[i] - c0[i]),
    ]);
  }
}

final class _StitchingFunction extends PdfFunction {
  const _StitchingFunction(
    super.domain,
    super.range,
    this.functions,
    this.bounds,
    this.encode,
  );

  final List<PdfFunction> functions;
  final List<double> bounds;
  final List<double> encode;

  static PdfFunction? parse(
    PdfDict dict,
    List<double> domain,
    List<double>? range,
    PdfResolver? resolver,
  ) {
    if (domain.length != 2) return null;
    final objects = dict.getArray('Functions', resolver);
    final bounds = _numbers(dict.getArray('Bounds', resolver), resolver);
    final encode = _numbers(dict.getArray('Encode', resolver), resolver);
    if (objects == null || bounds == null || encode == null) return null;
    final functions = <PdfFunction>[];
    for (var i = 0; i < objects.length; i++) {
      final function =
          PdfFunction.parse(objects.getResolved(i, resolver), resolver);
      if (function == null) return null;
      functions.add(function);
    }
    if (functions.isEmpty ||
        bounds.length != functions.length - 1 ||
        encode.length != functions.length * 2) {
      return null;
    }
    return _StitchingFunction(domain, range, functions, bounds, encode);
  }

  @override
  List<double>? evaluate(List<double> inputs) {
    final clipped = clipInput(inputs);
    if (clipped == null) return null;
    final x = clipped.single;
    var i = 0;
    while (i < bounds.length && x >= bounds[i]) {
      i++;
    }
    final low = i == 0 ? domain[0] : bounds[i - 1];
    final high = i == bounds.length ? domain[1] : bounds[i];
    final mapped = low == high
        ? encode[i * 2]
        : encode[i * 2] +
            (x - low) / (high - low) * (encode[i * 2 + 1] - encode[i * 2]);
    return clipOutput(functions[i].evaluate(<double>[mapped]));
  }
}

final class _SampledFunction extends PdfFunction {
  const _SampledFunction(
    super.domain,
    super.range,
    this.sizes,
    this.bits,
    this.encode,
    this.decode,
    this.samples,
  );

  final List<int> sizes;
  final int bits;
  final List<double> encode;
  final List<double> decode;
  final List<int> samples;

  int get outputCount => decode.length ~/ 2;

  static PdfFunction? parse(
    PdfStream stream,
    List<double> domain,
    List<double>? range,
    PdfResolver? resolver,
  ) {
    final rawSizes = _numbers(stream.dict.getArray('Size', resolver), resolver);
    final bits = stream.dict.getNumber('BitsPerSample', resolver)?.toInt();
    final order = stream.dict.getNumber('Order', resolver)?.toInt() ?? 1;
    if (rawSizes == null ||
        rawSizes.length != domain.length ~/ 2 ||
        rawSizes.any((value) => value < 1 || value != value.roundToDouble()) ||
        bits == null ||
        !const <int>[1, 2, 4, 8, 12, 16, 24, 32].contains(bits) ||
        order != 1 ||
        range == null) {
      return null;
    }
    final sizes = rawSizes.map((value) => value.toInt()).toList();
    final encode =
        _numbers(stream.dict.getArray('Encode', resolver), resolver) ??
            <double>[
              for (final size in sizes) ...<double>[0, size - 1.0]
            ];
    final decode =
        _numbers(stream.dict.getArray('Decode', resolver), resolver) ?? range;
    if (encode.length != domain.length || decode.length != range.length) {
      return null;
    }
    final count = sizes.fold<int>(1, (a, b) => a * b) * (decode.length ~/ 2);
    final reader = _BitReader(stream.getDecodedBytes(resolver));
    if (reader.remaining < count * bits) return null;
    return _SampledFunction(
      domain,
      range,
      sizes,
      bits,
      encode,
      decode,
      <int>[for (var i = 0; i < count; i++) reader.read(bits)],
    );
  }

  @override
  List<double>? evaluate(List<double> inputs) {
    final values = clipInput(inputs);
    if (values == null || values.length > 16) return null;
    final lows = <int>[];
    final highs = <int>[];
    final fractions = <double>[];
    for (var i = 0; i < values.length; i++) {
      final mapped = (encode[i * 2] +
              (values[i] - domain[i * 2]) /
                  (domain[i * 2 + 1] - domain[i * 2]) *
                  (encode[i * 2 + 1] - encode[i * 2]))
          .clamp(0.0, sizes[i] - 1.0);
      lows.add(mapped.floor());
      highs.add(math.min(sizes[i] - 1, mapped.ceil()));
      fractions.add(mapped - mapped.floor());
    }
    final result = List<double>.filled(outputCount, 0);
    for (var corner = 0; corner < (1 << values.length); corner++) {
      var weight = 1.0;
      var sampleIndex = 0;
      var stride = 1;
      for (var axis = 0; axis < values.length; axis++) {
        final high = corner & (1 << axis) != 0;
        sampleIndex += (high ? highs[axis] : lows[axis]) * stride;
        stride *= sizes[axis];
        weight *= high ? fractions[axis] : 1 - fractions[axis];
      }
      for (var output = 0; output < outputCount; output++) {
        result[output] += samples[sampleIndex * outputCount + output] * weight;
      }
    }
    final maximum = bits == 32 ? 0xFFFFFFFF : (1 << bits) - 1;
    return clipOutput(<double>[
      for (var i = 0; i < outputCount; i++)
        decode[i * 2] +
            result[i] / maximum * (decode[i * 2 + 1] - decode[i * 2]),
    ]);
  }
}

final class _CalculatorFunction extends PdfFunction {
  const _CalculatorFunction(super.domain, super.range, this.program);

  final List<Object> program;

  static PdfFunction? parse(
    PdfStream stream,
    List<double> domain,
    List<double>? range,
    PdfResolver? resolver,
  ) {
    if (range == null) return null;
    try {
      final tokens = _tokenizeCalculator(
        latin1.decode(stream.getDecodedBytes(resolver), allowInvalid: true),
      );
      final program = _parseProcedure(tokens);
      return _CalculatorFunction(domain, range, program);
    } on Object {
      return null;
    }
  }

  @override
  List<double>? evaluate(List<double> inputs) {
    final clipped = clipInput(inputs);
    if (clipped == null) return null;
    final stack = <Object>[...clipped];
    try {
      _execute(program, stack, 0);
    } on Object {
      return null;
    }
    final outputCount = range!.length ~/ 2;
    if (stack.length < outputCount) return null;
    final output = stack.sublist(stack.length - outputCount);
    if (output.any((value) => value is! num)) return null;
    return clipOutput(
        output.map((value) => (value as num).toDouble()).toList());
  }
}

void _execute(List<Object> program, List<Object> stack, int depth) {
  if (depth > 32 || program.length > 10000) throw const FormatException();
  num number() {
    final value = stack.removeLast();
    if (value is! num) throw const FormatException();
    return value;
  }

  bool boolean() {
    final value = stack.removeLast();
    if (value is! bool) throw const FormatException();
    return value;
  }

  int integer() {
    final value = number();
    if (value != value.toInt()) throw const FormatException();
    return value.toInt();
  }

  for (final token in program) {
    if (token is num || token is bool || token is List<Object>) {
      stack.add(token);
      continue;
    }
    switch (token) {
      case 'add':
        final b = number();
        final a = number();
        stack.add(a + b);
      case 'sub':
        final b = number();
        final a = number();
        stack.add(a - b);
      case 'mul':
        final b = number();
        final a = number();
        stack.add(a * b);
      case 'div':
        final b = number();
        final a = number();
        stack.add(a / b);
      case 'idiv':
        final b = integer();
        final a = integer();
        stack.add(a ~/ b);
      case 'mod':
        final b = integer();
        final a = integer();
        stack.add(a % b);
      case 'neg':
        stack.add(-number());
      case 'abs':
        stack.add(number().abs());
      case 'sqrt':
        stack.add(math.sqrt(number().toDouble()));
      case 'exp':
        final b = number();
        final a = number();
        stack.add(math.pow(a, b));
      case 'ln':
        stack.add(math.log(number()));
      case 'log':
        stack.add(math.log(number()) / math.ln10);
      case 'sin':
        stack.add(math.sin(number() * math.pi / 180));
      case 'cos':
        stack.add(math.cos(number() * math.pi / 180));
      case 'atan':
        final denominator = number();
        final numerator = number();
        var degrees = math.atan2(numerator, denominator) * 180 / math.pi;
        if (degrees < 0) degrees += 360;
        stack.add(degrees);
      case 'floor':
        stack.add(number().floor());
      case 'ceiling':
        stack.add(number().ceil());
      case 'round':
        stack.add(number().round());
      case 'truncate':
        stack.add(number().truncate());
      case 'cvi':
        stack.add(number().toInt());
      case 'cvr':
        stack.add(number().toDouble());
      case 'dup':
        stack.add(stack.last);
      case 'exch':
        final b = stack.removeLast();
        final a = stack.removeLast();
        stack
          ..add(b)
          ..add(a);
      case 'copy':
        final count = integer();
        if (count < 0 || count > stack.length) throw const FormatException();
        stack.addAll(List<Object>.from(stack.sublist(stack.length - count)));
      case 'index':
        final index = integer();
        if (index < 0 || index >= stack.length) throw const FormatException();
        stack.add(stack[stack.length - 1 - index]);
      case 'roll':
        var places = integer();
        final count = integer();
        if (count < 0 || count > stack.length) throw const FormatException();
        if (count != 0) {
          places %= count;
          final start = stack.length - count;
          final values = stack.sublist(start);
          stack
            ..removeRange(start, stack.length)
            ..addAll(values.sublist(count - places))
            ..addAll(values.sublist(0, count - places));
        }
      case 'pop':
        stack.removeLast();
      case 'eq':
        final b = stack.removeLast();
        final a = stack.removeLast();
        stack.add(a == b);
      case 'ne':
        final b = stack.removeLast();
        final a = stack.removeLast();
        stack.add(a != b);
      case 'gt':
        final b = number();
        final a = number();
        stack.add(a > b);
      case 'ge':
        final b = number();
        final a = number();
        stack.add(a >= b);
      case 'lt':
        final b = number();
        final a = number();
        stack.add(a < b);
      case 'le':
        final b = number();
        final a = number();
        stack.add(a <= b);
      case 'and':
        final b = stack.removeLast();
        final a = stack.removeLast();
        if (a is bool && b is bool) {
          stack.add(a && b);
        } else if (a is int && b is int) {
          stack.add(a & b);
        } else {
          throw const FormatException();
        }
      case 'or':
        final b = stack.removeLast();
        final a = stack.removeLast();
        if (a is bool && b is bool) {
          stack.add(a || b);
        } else if (a is int && b is int) {
          stack.add(a | b);
        } else {
          throw const FormatException();
        }
      case 'xor':
        final b = stack.removeLast();
        final a = stack.removeLast();
        if (a is bool && b is bool) {
          stack.add(a != b);
        } else if (a is int && b is int) {
          stack.add(a ^ b);
        } else {
          throw const FormatException();
        }
      case 'not':
        final value = stack.removeLast();
        if (value is bool) {
          stack.add(!value);
        } else if (value is int) {
          stack.add(~value);
        } else {
          throw const FormatException();
        }
      case 'bitshift':
        final shift = integer();
        final value = integer();
        stack.add(shift < 0 ? value >> -shift : value << shift);
      case 'if':
        final procedure = stack.removeLast();
        final condition = boolean();
        if (procedure is! List<Object>) throw const FormatException();
        if (condition) _execute(procedure, stack, depth + 1);
      case 'ifelse':
        final otherwise = stack.removeLast();
        final then = stack.removeLast();
        final condition = boolean();
        if (then is! List<Object> || otherwise is! List<Object>) {
          throw const FormatException();
        }
        _execute(condition ? then : otherwise, stack, depth + 1);
      default:
        throw const FormatException();
    }
    if (stack.length > 10000) throw const FormatException();
  }
}

List<String> _tokenizeCalculator(String source) => source
    .replaceAll(RegExp(r'%[^\r\n]*'), '')
    .replaceAll('{', ' { ')
    .replaceAll('}', ' } ')
    .split(RegExp(r'\s+'))
    .where((value) => value.isNotEmpty)
    .toList();

List<Object> _parseProcedure(List<String> tokens) {
  var position = 0;
  List<Object> parse({bool nested = false}) {
    final result = <Object>[];
    while (position < tokens.length) {
      final token = tokens[position++];
      if (token == '{') {
        result.add(parse(nested: true));
        continue;
      }
      if (token == '}') {
        if (!nested) throw const FormatException();
        return result;
      }
      result.add(token == 'true'
          ? true
          : token == 'false'
              ? false
              : num.tryParse(token) ?? token);
    }
    if (nested) throw const FormatException();
    return result;
  }

  final outer = parse();
  return outer.length == 1 && outer.single is List<Object>
      ? outer.single as List<Object>
      : outer;
}

final class _BitReader {
  _BitReader(this.bytes);
  final List<int> bytes;
  int offset = 0;
  int get remaining => bytes.length * 8 - offset;
  int read(int count) {
    var value = 0;
    for (var i = 0; i < count; i++, offset++) {
      value = (value << 1) | ((bytes[offset >> 3] >> (7 - (offset & 7))) & 1);
    }
    return value;
  }
}

List<double>? _numbers(PdfArray? array, PdfResolver? resolver) {
  if (array == null) return null;
  final values = <double>[];
  for (var i = 0; i < array.length; i++) {
    final value = array.getNumber(i, resolver)?.toDouble();
    if (value == null || !value.isFinite) return null;
    values.add(value);
  }
  return values;
}
