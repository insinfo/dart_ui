import 'dart:typed_data';

/// Algoritmo da chave externa usada pelo pacote CMS.
enum PdfSignatureAlgorithm {
  rsaSha256,
  ecdsaSha256,
}

/// Fronteira entre o PDF/CMS e uma chave que nunca sai do token ou HSM.
abstract interface class PdfExternalSigner {
  List<Uint8List> get certificateChain;
  PdfSignatureAlgorithm get algorithm;

  /// Assina os bytes DER dos atributos autenticados CMS.
  ///
  /// RSA retorna o bloco PKCS#1 v1.5. ECDSA retorna a sequência DER `(r, s)`.
  Future<Uint8List> sign(Uint8List authenticatedAttributesDer);
}

/// Adaptador conveniente para integrações que já expõem uma função de assinatura.
final class PdfCallbackSigner implements PdfExternalSigner {
  const PdfCallbackSigner({
    required this.certificateChain,
    required this.signCallback,
    this.algorithm = PdfSignatureAlgorithm.rsaSha256,
  });

  @override
  final List<Uint8List> certificateChain;
  @override
  final PdfSignatureAlgorithm algorithm;
  final Future<Uint8List> Function(Uint8List data) signCallback;

  @override
  Future<Uint8List> sign(Uint8List authenticatedAttributesDer) =>
      signCallback(authenticatedAttributesDer);
}
