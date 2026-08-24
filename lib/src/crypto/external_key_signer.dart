import 'dart:typed_data';

import 'crypto_identity.dart';

/// Dados opcionais de uma operacao que nao pertencem ao certificado.
final class CertificateOperationContext {
  const CertificateOperationContext({
    this.pin,
    this.nativeWindowHandle = 0,
  });

  /// PIN efemero para provedores com autenticacao no aplicativo.
  /// Provedores com UI propria ignoram este campo.
  final String? pin;

  /// Handle opaco da janela proprietaria de uma eventual UI do provedor.
  final int nativeWindowHandle;
}

/// Chave externa capaz de assinar sem expor seu material privado.
abstract interface class ExternalKeySigner {
  /// Assina [data] com SHA-256.
  ///
  /// RSA retorna PKCS#1 v1.5 em big-endian. ECDSA retorna a sequencia DER
  /// `(r, s)`, independentemente do formato nativo do provedor.
  Future<Uint8List> signSha256({
    required CryptoIdentity identity,
    required Uint8List data,
    CertificateOperationContext context = const CertificateOperationContext(),
  });
}
