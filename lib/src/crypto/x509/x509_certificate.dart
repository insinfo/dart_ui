import 'dart:convert';
import 'dart:typed_data';

import '../asn1/der.dart';

enum X509PublicKeyAlgorithm {
  rsa('1.2.840.113549.1.1.1'),
  ec('1.2.840.10045.2.1'),
  unknown('');

  const X509PublicKeyAlgorithm(this.oid);
  final String oid;

  static X509PublicKeyAlgorithm fromOid(String oid) =>
      X509PublicKeyAlgorithm.values.firstWhere(
        (value) => value != unknown && value.oid == oid,
        orElse: () => unknown,
      );
}

/// Metadados X.509 reutilizaveis por PDF, PKCS#11, Windows e outros protocolos.
final class X509Certificate {
  X509Certificate._({
    required this.derBytes,
    required this.serialNumber,
    required this.issuerDer,
    required this.subjectDer,
    required this.subjectName,
    required this.issuerName,
    required this.notBefore,
    required this.notAfter,
    required this.publicKeyAlgorithmOid,
    required this.subjectAlternativeNames,
  });

  factory X509Certificate.parse(Uint8List bytes) {
    final der = Uint8List.fromList(bytes);
    final outer = DerReader(der).read();
    if (outer.tag != 0x30) {
      throw const FormatException('X.509 certificate is not a SEQUENCE');
    }
    final certificate = DerReader(outer.value);
    final tbs = certificate.read();
    if (tbs.tag != 0x30) {
      throw const FormatException('X.509 TBSCertificate is not a SEQUENCE');
    }
    final reader = DerReader(tbs.value);
    var value = reader.read();
    if (value.tag == 0xa0) value = reader.read();
    if (value.tag != 0x02) {
      throw const FormatException('X.509 certificate has no serial number');
    }
    final serial = Uint8List.fromList(value.value);
    reader.read(); // signature AlgorithmIdentifier
    final issuer = reader.read();
    final validity = reader.read();
    final subject = reader.read();
    final subjectPublicKeyInfo = reader.read();
    if (issuer.tag != 0x30 ||
        subject.tag != 0x30 ||
        validity.tag != 0x30 ||
        subjectPublicKeyInfo.tag != 0x30) {
      throw const FormatException('X.509 TBSCertificate fields are invalid');
    }
    final validityReader = DerReader(validity.value);
    final notBefore = _parseTime(validityReader.read());
    final notAfter = _parseTime(validityReader.read());
    final spkiReader = DerReader(subjectPublicKeyInfo.value);
    final algorithmIdentifier = spkiReader.read();
    if (algorithmIdentifier.tag != 0x30) {
      throw const FormatException('X.509 public key algorithm is invalid');
    }
    final algorithmReader = DerReader(algorithmIdentifier.value);
    final algorithmOid = algorithmReader.read();
    if (algorithmOid.tag != 0x06) {
      throw const FormatException('X.509 public key algorithm has no OID');
    }
    final subjectAlternativeNames = _readSubjectAlternativeNames(reader);
    return X509Certificate._(
      derBytes: der,
      serialNumber: serial,
      issuerDer: Uint8List.fromList(issuer.encoded),
      subjectDer: Uint8List.fromList(subject.encoded),
      subjectName: _readName(subject.value),
      issuerName: _readName(issuer.value),
      notBefore: notBefore,
      notAfter: notAfter,
      publicKeyAlgorithmOid: decodeOid(algorithmOid.value),
      subjectAlternativeNames: subjectAlternativeNames,
    );
  }

  final Uint8List derBytes;
  final Uint8List serialNumber;
  final Uint8List issuerDer;
  final Uint8List subjectDer;
  final String subjectName;
  final String issuerName;
  final DateTime notBefore;
  final DateTime notAfter;
  final String publicKeyAlgorithmOid;

  /// Valores `otherName` presentes em SubjectAlternativeName, indexados por
  /// OID. Certificados ICP-Brasil guardam CPF/CNPJ e outros dados nesse local.
  final Map<String, String> subjectAlternativeNames;

  X509PublicKeyAlgorithm get publicKeyAlgorithm =>
      X509PublicKeyAlgorithm.fromOid(publicKeyAlgorithmOid);

  String get commonName {
    final match = RegExp(r'(?:^|, )CN=([^,]+)').firstMatch(subjectName);
    return match?.group(1) ?? subjectName;
  }

  /// Nome adequado para exibição em um selo ICP-Brasil.
  ///
  /// Certificados de pessoa física frequentemente acrescentam `:CPF` ao CN;
  /// o sufixo é removido para que o documento não exponha o número completo.
  /// Para certificados de pessoa jurídica, o OID 2.16.76.1.3.2 identifica o
  /// responsável pelo certificado.
  String get icpBrasilDisplayName {
    final responsible = subjectAlternativeNames['2.16.76.1.3.2']?.trim();
    if (responsible != null && responsible.isNotEmpty) return responsible;
    return commonName.replaceFirst(RegExp(r':\s*\d{11}\s*$'), '').trim();
  }

  /// CPF conforme as formas usadas por certificados ICP-Brasil atuais e
  /// legados: `serialNumber` do DN, outros nomes do SAN ou sufixo do CN.
  String? get icpBrasilCpf {
    final serialNumber = RegExp(
      r'(?:^|, )SERIALNUMBER=([^,]+)',
    ).firstMatch(subjectName)?.group(1);
    final serialCpf = _cpfFromUnstructuredValue(serialNumber);
    if (serialCpf != null) return serialCpf;

    for (final oid in const <String>['2.16.76.1.3.1', '2.16.76.1.3.4']) {
      final raw = subjectAlternativeNames[oid];
      if (raw == null) continue;
      final digits = raw.replaceAll(RegExp(r'\D'), '');
      final cpf = digits.length == 11
          ? digits
          : (digits.length >= 19 ? digits.substring(8, 19) : null);
      if (cpf != null && RegExp(r'^\d{11}$').hasMatch(cpf)) return cpf;
    }
    return RegExp(r':\s*(\d{11})\s*$').firstMatch(commonName)?.group(1);
  }

  static String? _cpfFromUnstructuredValue(String? value) {
    if (value == null) return null;
    final digits = value.replaceAll(RegExp(r'\D'), '');
    return digits.length == 11 ? digits : null;
  }

  /// CPF no padrão de privacidade usado pelo Assinador SERPRO:
  /// `***.456.789-**`.
  String? get maskedIcpBrasilCpf => maskBrazilianCpf(icpBrasilCpf);

  bool isValidAt(DateTime instant) {
    final utc = instant.toUtc();
    return !utc.isBefore(notBefore) && !utc.isAfter(notAfter);
  }

  static String _readName(Uint8List bytes) {
    const labels = <String, String>{
      '2.5.4.3': 'CN',
      '2.5.4.6': 'C',
      '2.5.4.7': 'L',
      '2.5.4.8': 'ST',
      '2.5.4.10': 'O',
      '2.5.4.11': 'OU',
      '2.5.4.5': 'SERIALNUMBER',
      '1.2.840.113549.1.9.1': 'E',
    };
    final components = <String>[];
    final rdns = DerReader(bytes);
    while (!rdns.isAtEnd) {
      final set = rdns.read();
      if (set.tag != 0x31) continue;
      final attributes = DerReader(set.value);
      while (!attributes.isAtEnd) {
        final sequence = attributes.read();
        if (sequence.tag != 0x30) continue;
        final attribute = DerReader(sequence.value);
        final oid = attribute.read();
        final value = attribute.read();
        final dotted = decodeOid(oid.value);
        components.add('${labels[dotted] ?? dotted}=${_decodeString(value)}');
      }
    }
    return components.join(', ');
  }

  static Map<String, String> _readSubjectAlternativeNames(DerReader reader) {
    final values = <String, String>{};
    while (!reader.isAtEnd) {
      final optional = reader.read();
      if (optional.tag != 0xa3) continue;
      try {
        final extensionsValue = DerReader(optional.value).read();
        if (extensionsValue.tag != 0x30) continue;
        final extensions = DerReader(extensionsValue.value);
        while (!extensions.isAtEnd) {
          final extension = extensions.read();
          if (extension.tag != 0x30) continue;
          final fields = DerReader(extension.value);
          final oid = fields.read();
          if (oid.tag != 0x06) continue;
          var value = fields.read();
          if (value.tag == 0x01 && !fields.isAtEnd) value = fields.read();
          if (decodeOid(oid.value) != '2.5.29.17' || value.tag != 0x04) {
            continue;
          }
          final generalNames = DerReader(value.value).read();
          if (generalNames.tag != 0x30) continue;
          final names = DerReader(generalNames.value);
          while (!names.isAtEnd) {
            final name = names.read();
            if (name.tag != 0xa0) continue;
            final parsed = _readOtherName(name.value);
            if (parsed != null) values[parsed.$1] = parsed.$2;
          }
        }
      } on FormatException {
        // Uma extensão SAN malformada não invalida os demais metadados X.509.
      }
    }
    return Map<String, String>.unmodifiable(values);
  }

  static (String, String)? _readOtherName(Uint8List bytes) {
    try {
      var payload = DerReader(bytes);
      final first = payload.read();
      if (first.tag == 0x30) payload = DerReader(first.value);
      final oidValue = first.tag == 0x30 ? payload.read() : first;
      if (oidValue.tag != 0x06) return null;
      final oid = decodeOid(oidValue.value);
      var encoded = payload.read();
      while (encoded.tag >= 0xa0 && encoded.tag <= 0xbf) {
        encoded = DerReader(encoded.value).read();
      }
      final text = _decodeString(encoded).trim();
      return text.isEmpty ? null : (oid, text);
    } on FormatException {
      return null;
    }
  }

  static String _decodeString(DerValue value) {
    switch (value.tag) {
      case 0x0c:
        return utf8.decode(value.value, allowMalformed: true);
      case 0x1e:
        final units = <int>[];
        for (var i = 0; i + 1 < value.value.length; i += 2) {
          units.add((value.value[i] << 8) | value.value[i + 1]);
        }
        return String.fromCharCodes(units);
      default:
        return latin1.decode(value.value, allowInvalid: true);
    }
  }

  static String decodeOid(Uint8List bytes) {
    if (bytes.isEmpty) throw const FormatException('DER: empty OID');
    final arcs = <int>[];
    var value = 0;
    for (final byte in bytes) {
      value = (value << 7) | (byte & 0x7f);
      if ((byte & 0x80) == 0) {
        if (arcs.isEmpty) {
          final first = value < 40 ? 0 : (value < 80 ? 1 : 2);
          arcs
            ..add(first)
            ..add(value - first * 40);
        } else {
          arcs.add(value);
        }
        value = 0;
      }
    }
    if (value != 0) throw const FormatException('DER: truncated OID');
    return arcs.join('.');
  }

  static DateTime _parseTime(DerValue value) {
    final text = ascii.decode(value.value);
    if (!text.endsWith('Z')) {
      throw const FormatException('X.509 non-UTC time is unsupported');
    }
    if (value.tag == 0x17 && text.length == 13) {
      final shortYear = int.parse(text.substring(0, 2));
      return DateTime.utc(
        shortYear >= 50 ? 1900 + shortYear : 2000 + shortYear,
        int.parse(text.substring(2, 4)),
        int.parse(text.substring(4, 6)),
        int.parse(text.substring(6, 8)),
        int.parse(text.substring(8, 10)),
        int.parse(text.substring(10, 12)),
      );
    }
    if (value.tag == 0x18 && text.length == 15) {
      return DateTime.utc(
        int.parse(text.substring(0, 4)),
        int.parse(text.substring(4, 6)),
        int.parse(text.substring(6, 8)),
        int.parse(text.substring(8, 10)),
        int.parse(text.substring(10, 12)),
        int.parse(text.substring(12, 14)),
      );
    }
    throw const FormatException('X.509 invalid validity time');
  }
}

/// Mascara um CPF sem nunca devolver os cinco dígitos das extremidades.
String? maskBrazilianCpf(String? value) {
  if (value == null) return null;
  if (RegExp(r'^\*{3}\.\d{3}\.\d{3}-\*{2}$').hasMatch(value)) {
    return value;
  }
  final digits = value.replaceAll(RegExp(r'\D'), '');
  if (digits.length != 11) return null;
  return '***.${digits.substring(3, 6)}.${digits.substring(6, 9)}-**';
}
