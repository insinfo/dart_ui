import 'dart:typed_data';

import '../format/pdf_object.dart';
import 'pdf_security_handler.dart';

typedef PdfPasswordProvider = String? Function(PdfEncryptionInfo info);

final class PdfEncryptionInfo {
  const PdfEncryptionInfo({
    required this.revision,
    required this.version,
    required this.permissions,
    required this.encryptMetadata,
  });

  final int revision;
  final int version;
  final int permissions;
  final bool encryptMetadata;
}

final class PdfPasswordRequiredException implements Exception {
  const PdfPasswordRequiredException(this.info);
  final PdfEncryptionInfo info;

  @override
  String toString() =>
      'A password is required for this encrypted PDF (R${info.revision})';
}

/// Authenticated encryption state attached to one xref table.
final class PdfEncryptionContext {
  PdfEncryptionContext._(
    this.handler,
    this.streamFilter,
    this.stringFilter,
    this.filters,
  );

  final PdfSecurityHandler handler;
  final String streamFilter;
  final String stringFilter;
  final Map<String, PdfSecurityCipher?> filters;

  static PdfEncryptionInfo inspect(PdfDict dictionary,
      [PdfResolver? resolver]) {
    final revision = dictionary.getNumber('R', resolver)?.toInt();
    final permissions = dictionary.getNumber('P', resolver)?.toInt();
    if (revision == null || permissions == null) {
      throw const FormatException('Incomplete Standard encryption dictionary');
    }
    return PdfEncryptionInfo(
      revision: revision,
      version: dictionary.getNumber('V', resolver)?.toInt() ?? 0,
      permissions: permissions,
      encryptMetadata: dictionary.getBool('EncryptMetadata', resolver) ?? true,
    );
  }

  static PdfEncryptionContext fromDictionary(
    PdfDict dictionary,
    Uint8List fileId,
    String password, [
    PdfResolver? resolver,
  ]) {
    final filter = dictionary.getName('Filter', resolver)?.name;
    if (filter != 'Standard') {
      throw UnsupportedError('PDF security handler /$filter');
    }
    final revision = dictionary.getNumber('R', resolver)?.toInt();
    final version = dictionary.getNumber('V', resolver)?.toInt() ?? 0;
    final permissions = dictionary.getNumber('P', resolver)?.toInt();
    final owner = dictionary.getResolved('O', resolver);
    final user = dictionary.getResolved('U', resolver);
    if (revision == null ||
        permissions == null ||
        owner is! PdfString ||
        user is! PdfString) {
      throw const FormatException('Incomplete Standard encryption dictionary');
    }
    final encryptMetadata =
        dictionary.getBool('EncryptMetadata', resolver) ?? true;
    final lengthBits = dictionary.getNumber('Length', resolver)?.toInt() ??
        (revision == 2
            ? 40
            : revision >= 5
                ? 256
                : 128);
    if (lengthBits % 8 != 0) {
      throw const FormatException('Encryption /Length must be byte-aligned');
    }

    final cryptFilters = <String, PdfSecurityCipher?>{
      'Identity': null,
    };
    final cf = dictionary.getDict('CF', resolver);
    if (cf != null) {
      for (final entry in cf.entries.entries) {
        final value = entry.value.resolve(resolver);
        if (value is! PdfDict) continue;
        cryptFilters[entry.key] = _cipherForName(
          value.getName('CFM', resolver)?.name ?? 'None',
        );
      }
    }
    if (version <= 2) cryptFilters['StdCF'] = PdfSecurityCipher.rc4;

    final streamFilter = version >= 4
        ? dictionary.getName('StmF', resolver)?.name ?? 'Identity'
        : 'StdCF';
    final stringFilter = version >= 4
        ? dictionary.getName('StrF', resolver)?.name ?? 'Identity'
        : 'StdCF';
    if (!cryptFilters.containsKey(streamFilter) ||
        !cryptFilters.containsKey(stringFilter)) {
      throw const FormatException('Unknown default PDF crypt filter');
    }

    final oe = dictionary.getResolved('OE', resolver);
    final ue = dictionary.getResolved('UE', resolver);
    final perms = dictionary.getResolved('Perms', resolver);
    final defaultCipher =
        cryptFilters[streamFilter] ?? cryptFilters[stringFilter];
    final handler = PdfSecurityHandler(
      revision: revision,
      ownerKey: owner.bytes,
      userKey: user.bytes,
      ownerEncryptedKey: oe is PdfString ? oe.bytes : null,
      userEncryptedKey: ue is PdfString ? ue.bytes : null,
      permsEntry: perms is PdfString ? perms.bytes : null,
      permissions: permissions,
      fileId: fileId,
      password: password,
      keyLength: lengthBits ~/ 8,
      encryptMetadata: encryptMetadata,
      isAes: defaultCipher == PdfSecurityCipher.aes128 ||
          defaultCipher == PdfSecurityCipher.aes256,
    );
    return PdfEncryptionContext._(
      handler,
      streamFilter,
      stringFilter,
      Map.unmodifiable(cryptFilters),
    );
  }

  PdfObject decryptObject(int objectNumber, int generation, PdfObject object) =>
      _decryptValue(objectNumber, generation, object, decryptStrings: true);

  PdfObject _decryptValue(
    int objectNumber,
    int generation,
    PdfObject object, {
    required bool decryptStrings,
  }) {
    if (object is PdfString && decryptStrings) {
      final cipher = filters[stringFilter];
      return cipher == null
          ? object
          : PdfString(
              handler.decryptContent(
                objectNumber,
                generation,
                object.bytes,
                cipher: cipher,
              ),
              isHex: object.isHex,
            );
    }
    if (object is PdfArray) {
      return PdfArray(<PdfObject>[
        for (final value in object.elements)
          _decryptValue(
            objectNumber,
            generation,
            value,
            decryptStrings: decryptStrings,
          ),
      ]);
    }
    if (object is PdfStream) {
      final dict = _decryptValue(
        objectNumber,
        generation,
        object.dict,
        decryptStrings: decryptStrings,
      ) as PdfDict;
      final isXRef = dict.getName('Type')?.name == 'XRef';
      final isUnencryptedMetadata =
          !handler.encryptMetadata && dict.getName('Type')?.name == 'Metadata';
      final cipher = _streamCipher(dict);
      final bytes = isXRef || isUnencryptedMetadata || cipher == null
          ? object.rawBytes
          : handler.decryptContent(
              objectNumber,
              generation,
              object.rawBytes,
              cipher: cipher,
            );
      return PdfStream(dict, bytes);
    }
    if (object is PdfDict) {
      return PdfDict(<String, PdfObject>{
        for (final entry in object.entries.entries)
          entry.key: _decryptValue(
            objectNumber,
            generation,
            entry.value,
            decryptStrings: decryptStrings,
          ),
      });
    }
    return object;
  }

  PdfSecurityCipher? _streamCipher(PdfDict dictionary) {
    final filter = dictionary['Filter'];
    if (filter is PdfName && filter.name == 'Crypt') {
      return _explicitCryptCipher(dictionary['DecodeParms']);
    }
    if (filter is PdfArray) {
      for (var i = 0; i < filter.length; i++) {
        if (filter[i] is PdfName && (filter[i] as PdfName).name == 'Crypt') {
          final parms = dictionary['DecodeParms'];
          return _explicitCryptCipher(
            parms is PdfArray && i < parms.length ? parms[i] : parms,
          );
        }
      }
    }
    return filters[streamFilter];
  }

  PdfSecurityCipher? _explicitCryptCipher(PdfObject? parameters) {
    final name = parameters is PdfDict
        ? parameters.getName('Name')?.name ?? 'Identity'
        : 'Identity';
    if (!filters.containsKey(name)) {
      throw FormatException('Unknown stream crypt filter /$name');
    }
    return filters[name];
  }

  static PdfSecurityCipher? _cipherForName(String name) => switch (name) {
        'None' => null,
        'V2' => PdfSecurityCipher.rc4,
        'AESV2' => PdfSecurityCipher.aes128,
        'AESV3' => PdfSecurityCipher.aes256,
        _ => throw UnsupportedError('PDF crypt filter method /$name'),
      };
}
