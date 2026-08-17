import '../crypto_backend.dart';
import '../dart/pure_dart_crypto_backend.dart';

/// Retorna a melhor implementação disponível de criptografia para a plataforma atual.
CryptoBackend createPlatformCryptoBackend() {
  return const PureDartCryptoBackend();
}
