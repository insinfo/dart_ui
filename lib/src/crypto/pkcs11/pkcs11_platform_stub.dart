import 'dart:typed_data';

import 'pkcs11_types.dart';

final class Pkcs11Module implements Pkcs11ModuleApi {
  Pkcs11Module(String path) : modulePath = path {
    throw UnsupportedError('PKCS#11 requires a dart:io runtime');
  }

  static List<String> discoverCommonModules() => const <String>[];

  @override
  final String modulePath;

  @override
  void close() {}

  @override
  List<Pkcs11Certificate> listCertificates({
    required int slotId,
    String? pin,
  }) =>
      throw UnsupportedError('PKCS#11 requires a dart:io runtime');

  @override
  List<Pkcs11Token> listTokens() =>
      throw UnsupportedError('PKCS#11 requires a dart:io runtime');

  @override
  Uint8List sign({
    required int slotId,
    required String pin,
    required Uint8List keyId,
    required Uint8List data,
    Pkcs11Mechanism mechanism = Pkcs11Mechanism.sha256RsaPkcs,
  }) =>
      throw UnsupportedError('PKCS#11 requires a dart:io runtime');
}
