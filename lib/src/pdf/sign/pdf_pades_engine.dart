import 'dart:typed_data';

import 'pdf_cms.dart';
import 'pdf_external_signer.dart';

/// Fachada compatível para o motor CMS/PAdES real.
///
/// Diferentemente do stub antigo, esta classe não aceita nem simula chave
/// privada. A chave assina somente [PdfCmsSigningRequest.authenticatedAttributesDer].
final class PdfPadesEngine {
  const PdfPadesEngine();

  PdfCmsSigningRequest createSigningRequest({
    required Uint8List documentDigest,
    required Uint8List signerCertificate,
    DateTime? signingTime,
  }) =>
      PdfCmsBuilder.createSigningRequest(
        documentDigest: documentDigest,
        signerCertificate: signerCertificate,
        signingTime: signingTime,
      );

  Uint8List complete({
    required PdfCmsSigningRequest request,
    required Uint8List signature,
    required List<Uint8List> certificateChain,
    PdfSignatureAlgorithm algorithm = PdfSignatureAlgorithm.rsaSha256,
  }) =>
      PdfCmsBuilder.buildDetachedSignedData(
        request: request,
        signature: signature,
        certificateChain: certificateChain,
        algorithm: algorithm,
      );
}
