import 'dart:convert';
import 'dart:typed_data';
import '../filter/ascii85_filter.dart';
import '../filter/ascii_hex_filter.dart';
import '../filter/ccitt_fax_filter.dart';
import '../filter/flate_filter.dart';
import '../filter/lzw_filter.dart';
import '../filter/pdf_filter.dart';
import '../filter/run_length_filter.dart';

/// Classe base abstrata para qualquer objeto da especificação PDF (ISO 32000).
abstract class PdfObject {
  const PdfObject();

  /// Resolve o objeto real caso seja uma referência indireta ([PdfRef]).
  PdfObject resolve(PdfResolver? resolver) => this;

  /// Retorna como [PdfDict] ou `null`.
  PdfDict? asDict() => this is PdfDict ? this as PdfDict : null;

  /// Retorna como [PdfArray] ou `null`.
  PdfArray? asArray() => this is PdfArray ? this as PdfArray : null;

  /// Retorna como [PdfName] ou `null`.
  PdfName? asName() => this is PdfName ? this as PdfName : null;

  /// Retorna como [PdfString] ou `null`.
  PdfString? asPdfString() => this is PdfString ? this as PdfString : null;

  /// Retorna como [PdfNumber] ou `null`.
  PdfNumber? asNumber() => this is PdfNumber ? this as PdfNumber : null;

  /// Retorna como [PdfStream] ou `null`.
  PdfStream? asStream() => this is PdfStream ? this as PdfStream : null;

  /// Retorna como [PdfBoolean] ou `null`.
  PdfBoolean? asBool() => this is PdfBoolean ? this as PdfBoolean : null;
}

/// Interface para resolver referências indiretas ([PdfRef]) contra a tabela XRef.
abstract class PdfResolver {
  PdfObject? resolveRef(PdfRef ref);
}

/// Objeto PDF Nulo (`null`).
class PdfNull extends PdfObject {
  const PdfNull();
  @override
  String toString() => 'null';
}

/// Objeto Booleano PDF (`true` ou `false`).
class PdfBoolean extends PdfObject {
  final bool value;
  const PdfBoolean(this.value);

  @override
  String toString() => value ? 'true' : 'false';
}

/// Objeto Numérico PDF (Inteiro ou Ponto Flutuante).
class PdfNumber extends PdfObject {
  final num value;
  const PdfNumber(this.value);

  int get asInt => value.toInt();
  double get asDouble => value.toDouble();

  @override
  String toString() => value.toString();
}

/// Objeto de String PDF (Literal `(...)` ou Hexadecimal `<...>`).
class PdfString extends PdfObject {
  final Uint8List bytes;
  final bool isHex;

  const PdfString(this.bytes, {this.isHex = false});

  factory PdfString.fromString(String text) {
    return PdfString(Uint8List.fromList(utf8.encode(text)));
  }

  String toUtf8String() {
    try {
      if (bytes.length >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF) {
        // UTF-16BE com BOM
        final codeUnits = <int>[];
        for (var i = 2; i + 1 < bytes.length; i += 2) {
          codeUnits.add((bytes[i] << 8) | bytes[i + 1]);
        }
        return String.fromCharCodes(codeUnits);
      }
      return utf8.decode(bytes);
    } catch (_) {
      return String.fromCharCodes(bytes);
    }
  }

  @override
  String toString() => 'PdfString(${toUtf8String()})';
}

/// Objeto de Nome PDF (`/Name`).
class PdfName extends PdfObject {
  final String name;
  const PdfName(this.name);

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is PdfName && name == other.name;

  @override
  int get hashCode => name.hashCode;

  @override
  String toString() => '/$name';
}

/// Objeto de Array PDF (`[...]`).
class PdfArray extends PdfObject {
  final List<PdfObject> elements;

  const PdfArray([this.elements = const []]);

  int get length => elements.length;
  PdfObject operator [](int index) => elements[index];

  PdfObject? getResolved(int index, [PdfResolver? resolver]) {
    if (index < 0 || index >= elements.length) return null;
    final item = elements[index];
    return resolver != null ? item.resolve(resolver) : item;
  }

  num? getNumber(int index, [PdfResolver? resolver]) {
    final obj = getResolved(index, resolver);
    return obj is PdfNumber ? obj.value : null;
  }

  String? getString(int index, [PdfResolver? resolver]) {
    final obj = getResolved(index, resolver);
    if (obj is PdfString) return obj.toUtf8String();
    if (obj is PdfName) return obj.name;
    return null;
  }

  PdfDict? getDict(int index, [PdfResolver? resolver]) {
    final obj = getResolved(index, resolver);
    return obj is PdfDict ? obj : null;
  }

  PdfArray? getArray(int index, [PdfResolver? resolver]) {
    final obj = getResolved(index, resolver);
    return obj is PdfArray ? obj : null;
  }

  @override
  String toString() => '[${elements.map((e) => e.toString()).join(', ')}]';
}

/// Objeto de Dicionário PDF (`<< /Key Value ... >>`).
class PdfDict extends PdfObject {
  final Map<String, PdfObject> entries;

  PdfDict([Map<String, PdfObject>? entries]) : entries = entries ?? {};

  PdfObject? operator [](String key) => entries[key];
  void operator []=(String key, PdfObject value) => entries[key] = value;

  bool containsKey(String key) => entries.containsKey(key);

  PdfObject? getResolved(String key, [PdfResolver? resolver]) {
    final item = entries[key];
    if (item == null) return null;
    return resolver != null ? item.resolve(resolver) : item;
  }

  String? getString(String key, [PdfResolver? resolver]) {
    final obj = getResolved(key, resolver);
    if (obj is PdfString) return obj.toUtf8String();
    if (obj is PdfName) return obj.name;
    return null;
  }

  PdfName? getName(String key, [PdfResolver? resolver]) {
    final obj = getResolved(key, resolver);
    return obj is PdfName ? obj : null;
  }

  num? getNumber(String key, [PdfResolver? resolver]) {
    final obj = getResolved(key, resolver);
    return obj is PdfNumber ? obj.value : null;
  }

  bool? getBool(String key, [PdfResolver? resolver]) {
    final obj = getResolved(key, resolver);
    return obj is PdfBoolean ? obj.value : null;
  }

  PdfDict? getDict(String key, [PdfResolver? resolver]) {
    final obj = getResolved(key, resolver);
    return obj is PdfDict ? obj : null;
  }

  PdfArray? getArray(String key, [PdfResolver? resolver]) {
    final obj = getResolved(key, resolver);
    return obj is PdfArray ? obj : null;
  }

  PdfStream? getStream(String key, [PdfResolver? resolver]) {
    final obj = getResolved(key, resolver);
    return obj is PdfStream ? obj : null;
  }

  @override
  String toString() =>
      '<< ${entries.entries.map((e) => '/${e.key} ${e.value}').join(' ')} >>';
}

/// Referência Indireta PDF (`id gen R`).
class PdfRef extends PdfObject {
  final int objNum;
  final int genNum;

  const PdfRef(this.objNum, this.genNum);

  @override
  PdfObject resolve(PdfResolver? resolver) {
    if (resolver == null) return this;
    final resolved = resolver.resolveRef(this);
    return resolved ?? const PdfNull();
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PdfRef && objNum == other.objNum && genNum == other.genNum;

  @override
  int get hashCode => Object.hash(objNum, genNum);

  @override
  String toString() => '$objNum $genNum R';
}

/// Objeto de Stream PDF (Dicionário de metadados + bytes de carga binária).
class PdfStream extends PdfObject {
  final PdfDict dict;
  final Uint8List rawBytes;
  Uint8List? _decodedBytes;

  PdfStream(this.dict, this.rawBytes);

  /// Retorna os bytes descompactados aplicando os filtros declarados em `/Filter`.
  Uint8List getDecodedBytes([PdfResolver? resolver]) {
    if (_decodedBytes != null) return _decodedBytes!;

    final filterObj = dict.getResolved('Filter', resolver);
    if (filterObj == null) {
      _decodedBytes = rawBytes;
      return _decodedBytes!;
    }

    final filters = <String>[];
    if (filterObj is PdfName) {
      filters.add(filterObj.name);
    } else if (filterObj is PdfArray) {
      for (var i = 0; i < filterObj.length; i++) {
        final item = filterObj.getResolved(i, resolver);
        if (item is PdfName) filters.add(item.name);
      }
    }

    final decodeParmsObj = dict.getResolved('DecodeParms', resolver);
    var currentBytes = rawBytes;

    for (var i = 0; i < filters.length; i++) {
      final filterName = filters[i];
      final parms = _extractDecodeParms(decodeParmsObj, i, resolver);
      currentBytes = _applyFilter(filterName, currentBytes, parms);
    }

    _decodedBytes = currentBytes;
    return _decodedBytes!;
  }

  DecodeParms _extractDecodeParms(
      PdfObject? parmsObj, int filterIndex, PdfResolver? resolver) {
    if (parmsObj == null) return const DecodeParms();
    PdfDict? d;
    if (parmsObj is PdfDict) {
      d = parmsObj;
    } else if (parmsObj is PdfArray && filterIndex < parmsObj.length) {
      final item = parmsObj.getResolved(filterIndex, resolver);
      if (item is PdfDict) d = item;
    }
    if (d == null) return const DecodeParms();

    return DecodeParms(
      predictor: d.getNumber('Predictor')?.toInt() ?? 1,
      colors: d.getNumber('Colors')?.toInt() ?? 1,
      bitsPerComponent: d.getNumber('BitsPerComponent')?.toInt() ?? 8,
      columns: d.getNumber('Columns')?.toInt() ?? 1,
      earlyChange: d.getNumber('EarlyChange')?.toInt() ?? 1,
      k: d.getNumber('K')?.toInt() ?? 0,
      endOfLine: d.getBool('EndOfLine') ?? false,
      encodedByteAlign: d.getBool('EncodedByteAlign') ?? false,
      rows: d.getNumber('Rows')?.toInt() ?? 0,
      endOfBlock: d.getBool('EndOfBlock') ?? true,
      blackIs1: d.getBool('BlackIs1') ?? false,
    );
  }

  Uint8List _applyFilter(String filterName, Uint8List data, DecodeParms parms) {
    switch (filterName) {
      case 'FlateDecode':
      case 'Fl':
        return const FlateFilter().decode(data, parms);
      case 'LZWDecode':
      case 'LZW':
        return const LzwFilter().decode(data, parms);
      case 'ASCII85Decode':
      case 'A85':
        return const Ascii85Filter().decode(data, parms);
      case 'ASCIIHexDecode':
      case 'AHx':
        return const AsciiHexFilter().decode(data, parms);
      case 'RunLengthDecode':
      case 'RL':
        return const RunLengthFilter().decode(data, parms);
      case 'CCITTFaxDecode':
      case 'CCF':
        return const CcittFaxFilter().decode(data, parms);
      default:
        // Filtros não suportados ou pass-through (ex: DCTDecode para JPEGs)
        return data;
    }
  }

  @override
  String toString() => 'PdfStream(dict: $dict, size: ${rawBytes.length})';
}
