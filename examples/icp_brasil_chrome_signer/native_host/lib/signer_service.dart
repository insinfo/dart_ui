import 'dart:convert';
import 'dart:typed_data';

import 'package:dart_ui/dart_ui.dart';

typedef ConsentPrompt = Future<bool> Function({
  required String origin,
  required String action,
  required String details,
});

final class SignerService {
  SignerService({CertificateProvider? provider, ConsentPrompt? consent})
      : _provider = provider ?? WindowsCertificateProvider(),
        _consent = consent ?? _nativeConsent;

  final CertificateProvider _provider;
  final ConsentPrompt _consent;
  List<CryptoIdentity> _identities = const <CryptoIdentity>[];

  Future<Map<String, Object?>> handle(Map<String, Object?> request) async {
    final id = request['id']?.toString() ?? '';
    try {
      final origin = _validOrigin(request['origin']);
      final operation = request['operation']?.toString();
      final result = switch (operation) {
        'status' => <String, Object?>{
            'available': _provider.isAvailable,
            'provider': _provider.name,
          },
        'listCertificates' => await _listCertificates(origin),
        'authenticate' => await _authenticate(origin, request),
        'signPdf' => await _signPdf(origin, request),
        'signPdfHash' => await _signPdfHash(origin, request),
        _ => throw const FormatException('unsupported operation'),
      };
      return <String, Object?>{'id': id, 'ok': true, 'result': result};
    } catch (error) {
      return <String, Object?>{
        'id': id,
        'ok': false,
        'error': <String, Object?>{
          'code': _errorCode(error),
          'message': error.toString(),
        },
      };
    }
  }

  Future<Map<String, Object?>> _listCertificates(String origin) async {
    if (!await _consent(
      origin: origin,
      action: 'Listar certificados',
      details: 'O site verá nome, emissor, validade e identificador público.',
    )) {
      throw const _Denied();
    }
    _identities = await _provider.listIdentities();
    final now = DateTime.now();
    return <String, Object?>{
      'certificates': <Object?>[
        for (final identity in _identities)
          <String, Object?>{
            'id': identity.id,
            'name': identity.certificate.icpBrasilDisplayName,
            'maskedCpf': identity.certificate.maskedIcpBrasilCpf,
            'issuer': identity.certificate.issuerName,
            'notBefore': identity.certificate.notBefore.toIso8601String(),
            'notAfter': identity.certificate.notAfter.toIso8601String(),
            'valid': identity.certificate.isValidAt(now),
            'algorithm': identity.publicKeyAlgorithm.name,
          },
      ],
    };
  }

  Future<Map<String, Object?>> _authenticate(
    String origin,
    Map<String, Object?> request,
  ) async {
    final identity = await _identity(request['certificateId']);
    final challenge = _decode(request['challenge'], maxBytes: 64 * 1024);
    if (challenge.length < 16) {
      throw const FormatException('authentication challenge is too short');
    }
    final audience = request['audience']?.toString() ?? origin;
    if (!await _consent(
      origin: origin,
      action: 'Autenticar',
      details:
          '${identity.certificate.icpBrasilDisplayName}\nDestino: $audience',
    )) {
      throw const _Denied();
    }
    final signature = await _provider.signSha256(
      identity: identity,
      data: challenge,
    );
    return <String, Object?>{
      'signature': base64Encode(signature),
      'certificate': base64Encode(identity.certificate.derBytes),
      'algorithm': identity.publicKeyAlgorithm == X509PublicKeyAlgorithm.rsa
          ? 'RS256'
          : 'ES256',
    };
  }

  Future<Map<String, Object?>> _signPdf(
    String origin,
    Map<String, Object?> request,
  ) async {
    final identity = await _identity(request['certificateId']);
    final bytes = _decode(request['pdf'], maxBytes: 32 * 1024 * 1024 - 4096);
    final reason = request['reason']?.toString() ?? 'Assinatura Digital';
    if (!await _consent(
      origin: origin,
      action: 'Assinar PDF',
      details: '${identity.certificate.icpBrasilDisplayName}\n'
          '${bytes.length} bytes\nMotivo: $reason',
    )) {
      throw const _Denied();
    }
    final signer = PdfSigner(
      document: PdfDocument.fromBytes(bytes),
      signerName: identity.certificate.icpBrasilDisplayName,
      reason: reason,
      location: request['location']?.toString(),
    );
    final signed = await signer.sign(
      externalSigner: PdfCertificateProviderSigner(
        provider: _provider,
        identity: identity,
      ),
    );
    return <String, Object?>{'pdf': base64Encode(signed)};
  }

  Future<Map<String, Object?>> _signPdfHash(
    String origin,
    Map<String, Object?> request,
  ) async {
    final identity = await _identity(request['certificateId']);
    final digest = _decode(request['byteRangeDigest'], maxBytes: 32);
    if (digest.length != 32) {
      throw const FormatException('byteRangeDigest must be a SHA-256 digest');
    }
    final reason = request['reason']?.toString() ?? 'Assinatura remota de PDF';
    if (!await _consent(
      origin: origin,
      action: 'Assinar hash de PDF',
      details: '${identity.certificate.icpBrasilDisplayName}\n'
          'SHA-256: ${_hex(digest)}\nMotivo: $reason',
    )) {
      throw const _Denied();
    }
    final signingTime = DateTime.now();
    final externalSigner = PdfCertificateProviderSigner(
      provider: _provider,
      identity: identity,
    );
    final signingRequest = PdfCmsBuilder.createSigningRequest(
      documentDigest: digest,
      signerCertificate: identity.certificate.derBytes,
      signingTime: signingTime,
    );
    final signature = await externalSigner.sign(
      signingRequest.authenticatedAttributesDer,
    );
    final cms = PdfCmsBuilder.buildDetachedSignedData(
      request: signingRequest,
      signature: signature,
      certificateChain: externalSigner.certificateChain,
      algorithm: externalSigner.algorithm,
    );
    return <String, Object?>{
      'cms': base64Encode(cms),
      'standard': 'PAdES-B-B',
      'digestAlgorithm': 'SHA-256',
      'signingTime': signingTime.toUtc().toIso8601String(),
      'certificateChain': <String>[
        for (final certificate in externalSigner.certificateChain)
          base64Encode(certificate),
      ],
    };
  }

  Future<CryptoIdentity> _identity(Object? id) async {
    if (_identities.isEmpty) {
      _identities = await _provider.listIdentities();
    }
    return _identities.firstWhere(
      (value) => value.id == id,
      orElse: () => throw const FormatException('certificate not found'),
    );
  }

  static Uint8List _decode(Object? value, {required int maxBytes}) {
    if (value is! String) {
      throw const FormatException('base64 payload missing');
    }
    final bytes = base64Decode(value);
    if (bytes.length > maxBytes) {
      throw const FormatException('payload too large');
    }
    return bytes;
  }

  static String _validOrigin(Object? value) {
    final uri = Uri.tryParse(value?.toString() ?? '');
    if (uri == null ||
        !uri.hasAuthority ||
        !{'https', 'http'}.contains(uri.scheme)) {
      throw const FormatException('invalid page origin');
    }
    if (uri.scheme == 'http' &&
        uri.host != 'localhost' &&
        uri.host != '127.0.0.1') {
      throw const FormatException('plain HTTP is allowed only on localhost');
    }
    return uri.origin;
  }

  static String _errorCode(Object error) => switch (error) {
        _Denied() => 'USER_DENIED',
        FormatException() => 'INVALID_REQUEST',
        _ => 'SIGNER_ERROR',
      };

  static String _hex(Uint8List bytes) =>
      bytes.map((value) => value.toRadixString(16).padLeft(2, '0')).join();

  static Future<bool> _nativeConsent({
    required String origin,
    required String action,
    required String details,
  }) =>
      NativeMessageBox.show(
        title: 'Dart UI — ICP-Brasil',
        message: '$origin solicita: $action\n\n$details\n\nDeseja continuar?',
        kind: MessageBoxKind.confirm,
      );

  void close() => _provider.close();
}

final class _Denied implements Exception {
  const _Denied();
  @override
  String toString() => 'operation cancelled by the user';
}
