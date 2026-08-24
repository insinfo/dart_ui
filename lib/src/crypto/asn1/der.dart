import 'dart:convert';
import 'dart:typed_data';

/// Codificador/decodificador ASN.1 DER pequeno e estrito.
///
/// DER nao admite comprimentos indefinidos; entradas truncadas ou nao
/// canonicas sao rejeitadas antes que alcancem CMS, X.509 ou uma chave.
final class Der {
  const Der._();

  static Uint8List length(int value) {
    if (value < 0) throw ArgumentError.value(value, 'value');
    if (value < 0x80) return Uint8List.fromList(<int>[value]);
    final bytes = <int>[];
    var remaining = value;
    while (remaining != 0) {
      bytes.add(remaining & 0xff);
      remaining >>= 8;
    }
    return Uint8List.fromList(<int>[0x80 | bytes.length, ...bytes.reversed]);
  }

  static Uint8List tlv(int tag, Iterable<int> value) {
    final body = Uint8List.fromList(value.toList(growable: false));
    return Uint8List.fromList(<int>[tag, ...length(body.length), ...body]);
  }

  static Uint8List sequence(Iterable<Uint8List> values) =>
      tlv(0x30, values.expand((value) => value));

  /// SET OF em ordem lexicografica, como exige a canonicalizacao DER.
  static Uint8List setOf(Iterable<Uint8List> values) {
    final sorted = values.map(Uint8List.fromList).toList()..sort(_compareBytes);
    return tlv(0x31, sorted.expand((value) => value));
  }

  static Uint8List integerBytes(Uint8List unsignedValue) {
    var start = 0;
    while (start + 1 < unsignedValue.length && unsignedValue[start] == 0) {
      start++;
    }
    final value = unsignedValue.isEmpty
        ? Uint8List.fromList(const <int>[0])
        : Uint8List.sublistView(unsignedValue, start);
    return tlv(0x02, <int>[
      if ((value.first & 0x80) != 0) 0,
      ...value,
    ]);
  }

  static Uint8List integer(int value) {
    if (value < 0) {
      throw ArgumentError.value(value, 'value', 'must be non-negative');
    }
    if (value == 0) return tlv(0x02, const <int>[0]);
    final bytes = <int>[];
    var remaining = value;
    while (remaining != 0) {
      bytes.add(remaining & 0xff);
      remaining >>= 8;
    }
    return integerBytes(Uint8List.fromList(bytes.reversed.toList()));
  }

  static Uint8List oid(String dotted) {
    final arcs = dotted.split('.').map(int.parse).toList(growable: false);
    if (arcs.length < 2 || arcs.first < 0 || arcs.first > 2 || arcs[1] < 0) {
      throw ArgumentError.value(dotted, 'dotted', 'invalid object identifier');
    }
    if (arcs.first < 2 && arcs[1] > 39) {
      throw ArgumentError.value(dotted, 'dotted', 'invalid second arc');
    }
    final bytes = <int>[];
    void appendArc(int value) {
      if (value < 0) throw ArgumentError.value(dotted, 'dotted');
      final encoded = <int>[value & 0x7f];
      value >>= 7;
      while (value != 0) {
        encoded.add(0x80 | (value & 0x7f));
        value >>= 7;
      }
      bytes.addAll(encoded.reversed);
    }

    appendArc(arcs.first * 40 + arcs[1]);
    for (final arc in arcs.skip(2)) {
      appendArc(arc);
    }
    return tlv(0x06, bytes);
  }

  static Uint8List nullValue() => tlv(0x05, const <int>[]);
  static Uint8List octetString(Uint8List value) => tlv(0x04, value);
  static Uint8List explicit(int number, Uint8List value) =>
      tlv(0xa0 + number, value);
  static Uint8List implicitConstructed(int number, Iterable<int> value) =>
      tlv(0xa0 + number, value);

  static Uint8List time(DateTime value) {
    final utc = value.toUtc();
    String two(int n) => n.toString().padLeft(2, '0');
    if (utc.year >= 1950 && utc.year < 2050) {
      return tlv(
        0x17,
        ascii.encode(
          '${two(utc.year % 100)}${two(utc.month)}${two(utc.day)}'
          '${two(utc.hour)}${two(utc.minute)}${two(utc.second)}Z',
        ),
      );
    }
    return tlv(
      0x18,
      ascii.encode(
        '${utc.year.toString().padLeft(4, '0')}${two(utc.month)}${two(utc.day)}'
        '${two(utc.hour)}${two(utc.minute)}${two(utc.second)}Z',
      ),
    );
  }

  static int _compareBytes(Uint8List a, Uint8List b) {
    final count = a.length < b.length ? a.length : b.length;
    for (var i = 0; i < count; i++) {
      final comparison = a[i].compareTo(b[i]);
      if (comparison != 0) return comparison;
    }
    return a.length.compareTo(b.length);
  }
}

/// Um TLV DER com sua codificacao original preservada.
final class DerValue {
  const DerValue({
    required this.tag,
    required this.value,
    required this.encoded,
  });

  final int tag;
  final Uint8List value;
  final Uint8List encoded;
}

final class DerReader {
  DerReader(Uint8List bytes) : _bytes = bytes;

  final Uint8List _bytes;
  int _offset = 0;

  bool get isAtEnd => _offset == _bytes.length;

  DerValue read() {
    final start = _offset;
    if (_offset >= _bytes.length) throw const FormatException('DER: EOF');
    final tag = _bytes[_offset++];
    if (_offset >= _bytes.length) {
      throw const FormatException('DER: missing length');
    }
    final first = _bytes[_offset++];
    int valueLength;
    if ((first & 0x80) == 0) {
      valueLength = first;
    } else {
      final count = first & 0x7f;
      if (count == 0) {
        throw const FormatException('DER: indefinite length is forbidden');
      }
      if (count > 8 || _offset + count > _bytes.length) {
        throw const FormatException('DER: invalid long length');
      }
      if (_bytes[_offset] == 0) {
        throw const FormatException('DER: non-canonical long length');
      }
      valueLength = 0;
      for (var i = 0; i < count; i++) {
        valueLength = (valueLength << 8) | _bytes[_offset++];
      }
      if (valueLength < 0x80) {
        throw const FormatException('DER: non-canonical length');
      }
    }
    final end = _offset + valueLength;
    if (end > _bytes.length) throw const FormatException('DER: truncated');
    final value = Uint8List.sublistView(_bytes, _offset, end);
    _offset = end;
    return DerValue(
      tag: tag,
      value: value,
      encoded: Uint8List.sublistView(_bytes, start, end),
    );
  }
}
