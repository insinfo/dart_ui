import 'dart:typed_data';
import 'package:dart_ui/src/crypto/dart/pure_dart_sha.dart';

String _hex(Uint8List bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

void main() {
  final abc = Uint8List.fromList([0x61, 0x62, 0x63]);

  // SHA-512("abc")
  final hash512 = PureDartSha.sha512(abc);
  final hex512 = _hex(hash512);
  const expected512 =
      'ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a'
      '2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f';
  print('SHA-512("abc"):');
  print('  Got:      $hex512');
  print('  Expected: $expected512');
  print('  Match:    ${hex512 == expected512}');

  // SHA-384("abc")
  final hash384 = PureDartSha.sha512(abc, is384: true);
  final hex384 = _hex(hash384);
  const expected384 =
      'cb00753f45a35e8bb5a03d699ac65007272c32ab0eded1631a8b605a43ff5bed'
      '8086072ba1e7cc2358baeca134c825a7';
  print('\nSHA-384("abc"):');
  print('  Got:      $hex384');
  print('  Expected: $expected384');
  print('  Match:    ${hex384 == expected384}');
}
