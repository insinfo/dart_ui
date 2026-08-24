import 'dart:typed_data';

import 'windows_certificate_store_types.dart';

/// Implementacao indisponivel fora das plataformas com `dart:io`.
final class WindowsCertificateStore implements WindowsCertificateStoreApi {
  WindowsCertificateStore();

  Never _unsupported() => throw UnsupportedError(
        'WindowsCertificateStore is available only on Windows',
      );

  @override
  List<WindowsCertificate> listCertificates({bool requirePrivateKey = true}) =>
      _unsupported();

  @override
  Uint8List signSha256({
    required WindowsCertificate certificate,
    required Uint8List data,
    int parentWindowHandle = 0,
  }) =>
      _unsupported();
}
