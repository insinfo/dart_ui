library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'display.dart';

const int _familyLocal = 256;
const int _familyWild = 0xffff;
const String _mitMagicCookie = 'MIT-MAGIC-COOKIE-1';

final class X11Authorization {
  const X11Authorization({required this.name, required this.data});

  static const none = X11Authorization(name: '', data: <int>[]);

  final String name;
  final List<int> data;

  static Future<X11Authorization> discover(
    X11DisplayTarget display, {
    Map<String, String>? environment,
  }) async {
    final env = environment ?? Platform.environment;
    final explicit = env['XAUTHORITY'];
    final home = env['HOME'];
    final path = explicit != null && explicit.isNotEmpty
        ? explicit
        : home == null || home.isEmpty
            ? null
            : '$home/.Xauthority';
    if (path == null) return none;
    final file = File(path);
    if (!await file.exists()) return none;
    final records = parse(await file.readAsBytes());
    final number = '${display.displayNumber}';
    for (final record in records) {
      if ((record.family == _familyLocal || record.family == _familyWild) &&
          record.number == number &&
          record.name == _mitMagicCookie) {
        return X11Authorization(name: record.name, data: record.data);
      }
    }
    return none;
  }

  static List<XAuthorityRecord> parse(Uint8List bytes) {
    final records = <XAuthorityRecord>[];
    var offset = 0;
    while (offset < bytes.length) {
      if (bytes.length - offset < 2) {
        throw const FormatException('truncated Xauthority family');
      }
      final family = _readU16Be(bytes, offset);
      offset += 2;
      final address = _readField(bytes, offset);
      offset = address.next;
      final number = _readField(bytes, offset);
      offset = number.next;
      final name = _readField(bytes, offset);
      offset = name.next;
      final data = _readField(bytes, offset);
      offset = data.next;
      records.add(XAuthorityRecord(
        family: family,
        address: latin1.decode(address.bytes),
        number: ascii.decode(number.bytes),
        name: ascii.decode(name.bytes),
        data: List<int>.unmodifiable(data.bytes),
      ));
    }
    return records;
  }
}

final class XAuthorityRecord {
  const XAuthorityRecord({
    required this.family,
    required this.address,
    required this.number,
    required this.name,
    required this.data,
  });

  final int family;
  final String address;
  final String number;
  final String name;
  final List<int> data;
}

({Uint8List bytes, int next}) _readField(Uint8List source, int offset) {
  if (source.length - offset < 2) {
    throw const FormatException('truncated Xauthority field length');
  }
  final length = _readU16Be(source, offset);
  final start = offset + 2;
  final end = start + length;
  if (end > source.length) {
    throw const FormatException('truncated Xauthority field');
  }
  return (bytes: Uint8List.sublistView(source, start, end), next: end);
}

int _readU16Be(Uint8List bytes, int offset) =>
    (bytes[offset] << 8) | bytes[offset + 1];
