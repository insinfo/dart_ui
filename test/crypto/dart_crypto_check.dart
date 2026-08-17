import 'dart:convert';
import 'dart:typed_data';

import 'package:dart_ui/src/crypto/dart/pure_dart_sha.dart';

void main() {
  final bytes = Uint8List.fromList(utf8.encode('abc'));
  final digest = PureDartSha.sha512(bytes);
  print(digest.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join());
}
