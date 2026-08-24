import 'dart:typed_data';

enum Pkcs11Mechanism {
  sha256RsaPkcs(0x00000040),
  ecdsa(0x00001041);

  const Pkcs11Mechanism(this.value);
  final int value;
}

final class Pkcs11Token {
  const Pkcs11Token({
    required this.slotId,
    required this.label,
    required this.manufacturer,
    required this.model,
    required this.serialNumber,
    required this.flags,
  });

  final int slotId;
  final String label;
  final String manufacturer;
  final String model;
  final String serialNumber;
  final int flags;
}

final class Pkcs11Certificate {
  Pkcs11Certificate({
    required Uint8List id,
    required this.label,
    required Uint8List derBytes,
  })  : id = Uint8List.fromList(id),
        derBytes = Uint8List.fromList(derBytes);

  final Uint8List id;
  final String label;
  final Uint8List derBytes;

  String get idHex =>
      id.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
}

final class Pkcs11Exception implements Exception {
  const Pkcs11Exception({
    required this.operation,
    required this.code,
    required this.codeName,
  });

  final String operation;
  final int code;
  final String codeName;

  @override
  String toString() => 'Pkcs11Exception: $operation failed with $codeName '
      '(0x${code.toRadixString(16).padLeft(8, '0')})';
}

abstract interface class Pkcs11ModuleApi {
  String get modulePath;
  List<Pkcs11Token> listTokens();
  List<Pkcs11Certificate> listCertificates({
    required int slotId,
    String? pin,
  });
  Uint8List sign({
    required int slotId,
    required String pin,
    required Uint8List keyId,
    required Uint8List data,
    Pkcs11Mechanism mechanism,
  });
  void close();
}
