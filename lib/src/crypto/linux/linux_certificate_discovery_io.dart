import 'dart:io';

import '../pkcs11/pkcs11.dart';

final class LinuxCertificateDiscoveryResult {
  LinuxCertificateDiscoveryResult({
    required List<Pkcs11CertificateProvider> providers,
    required Map<String, String> failures,
  })  : providers = List<Pkcs11CertificateProvider>.unmodifiable(providers),
        failures = Map<String, String>.unmodifiable(failures);

  final List<Pkcs11CertificateProvider> providers;
  final Map<String, String> failures;

  void close() {
    for (final provider in providers) {
      provider.close();
    }
  }
}

/// Descobre tokens Linux publicados por middleware PKCS#11.
///
/// PC/SC transporta o smart card; SafeSign, OpenSC ou o middleware do
/// fabricante publica as operacoes criptograficas pelo modulo PKCS#11.
final class LinuxCertificateProviderDiscovery {
  static bool get isAvailable => Platform.isLinux;

  static LinuxCertificateDiscoveryResult discover({
    Iterable<String>? modulePaths,
  }) {
    if (!Platform.isLinux) {
      return LinuxCertificateDiscoveryResult(
        providers: const <Pkcs11CertificateProvider>[],
        failures: const <String, String>{},
      );
    }
    final paths = (modulePaths ?? Pkcs11Module.discoverCommonModules()).toSet();
    final providers = <Pkcs11CertificateProvider>[];
    final failures = <String, String>{};
    for (final path in paths) {
      Pkcs11Module? probe;
      try {
        probe = Pkcs11Module(path);
        final tokens = probe.listTokens();
        probe.close();
        probe = null;
        for (final token in tokens) {
          final module = Pkcs11Module(path);
          providers.add(
            Pkcs11CertificateProvider.forToken(
              module: module,
              token: token,
              ownsModule: true,
            ),
          );
        }
      } on Object catch (error) {
        failures[path] = '$error';
      } finally {
        probe?.close();
      }
    }
    return LinuxCertificateDiscoveryResult(
      providers: providers,
      failures: failures,
    );
  }
}
