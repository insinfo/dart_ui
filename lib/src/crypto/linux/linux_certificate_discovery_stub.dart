import '../pkcs11/pkcs11_certificate_provider.dart';

final class LinuxCertificateDiscoveryResult {
  const LinuxCertificateDiscoveryResult({
    this.providers = const <Pkcs11CertificateProvider>[],
    this.failures = const <String, String>{},
  });

  final List<Pkcs11CertificateProvider> providers;
  final Map<String, String> failures;
}

/// Descoberta indisponivel em runtimes sem `dart:io`.
final class LinuxCertificateProviderDiscovery {
  static bool get isAvailable => false;

  static LinuxCertificateDiscoveryResult discover({
    Iterable<String>? modulePaths,
  }) =>
      const LinuxCertificateDiscoveryResult();
}
