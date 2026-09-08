import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import '../../crypto/crypto.dart';
import '../../text/normalize.dart';

/// Standard Security Handler defined by ISO 32000-1, 7.6.3.
///
/// Revisions 2--6 are implemented. R5/R6 require all four AES-256 dictionary
/// entries ([ownerEncryptedKey], [userEncryptedKey] and [permsEntry] in
/// addition to /O and /U) and fail closed when any entry is absent or invalid.
class PdfSecurityHandler {
  static final Uint8List _passwordPadding = Uint8List.fromList(<int>[
    0x28,
    0xbf,
    0x4e,
    0x5e,
    0x4e,
    0x75,
    0x8a,
    0x41,
    0x64,
    0x00,
    0x4e,
    0x56,
    0xff,
    0xfa,
    0x01,
    0x08,
    0x2e,
    0x2e,
    0x00,
    0xb6,
    0xd0,
    0x68,
    0x3e,
    0x80,
    0x2f,
    0x0c,
    0xa9,
    0xfe,
    0x64,
    0x53,
    0x69,
    0x7a,
  ]);

  final int revision;
  final Uint8List ownerKey;
  final Uint8List userKey;
  final int permissions;
  final Uint8List fileId;
  final bool isAes;
  final int keyLength;
  final bool encryptMetadata;
  final Uint8List? ownerEncryptedKey;
  final Uint8List? userEncryptedKey;
  final Uint8List? permsEntry;

  late final Uint8List encryptionKey;
  late final bool authenticatedAsOwner;

  PdfSecurityHandler({
    required this.revision,
    required this.ownerKey,
    required this.userKey,
    required this.permissions,
    required this.fileId,
    this.isAes = false,
    int? keyLength,
    this.encryptMetadata = true,
    this.ownerEncryptedKey,
    this.userEncryptedKey,
    this.permsEntry,
    String password = '',
  }) : keyLength = keyLength ??
            (revision == 2
                ? 5
                : revision >= 5
                    ? 32
                    : 16) {
    if (revision < 2 || revision > 6) {
      throw UnsupportedError('Standard Security Handler revision $revision');
    }
    if (revision >= 5 && this.keyLength != 32) {
      throw const FormatException('AES-256 requires a 256-bit key');
    }
    if (revision < 5 && (this.keyLength < 5 || this.keyLength > 16)) {
      throw ArgumentError.value(this.keyLength, 'keyLength', 'must be 5..16');
    }
    if (revision == 2 && this.keyLength != 5) {
      throw const FormatException('Standard Security R2 requires a 40-bit key');
    }
    if (isAes && revision < 5 && (revision != 4 || this.keyLength != 16)) {
      throw const FormatException(
        'AESV2 requires Standard Security R4 with a 128-bit key',
      );
    }
    final expectedKeyEntryLength = revision >= 5 ? 48 : 32;
    if (ownerKey.length != expectedKeyEntryLength ||
        userKey.length != expectedKeyEntryLength) {
      throw const FormatException(
        'Invalid /O or /U entry in encryption dictionary',
      );
    }
    if (revision >= 5 &&
        (ownerEncryptedKey?.length != 32 ||
            userEncryptedKey?.length != 32 ||
            permsEntry?.length != 16)) {
      throw const FormatException(
        'AES-256 requires 32-byte /OE and /UE and 16-byte /Perms entries',
      );
    }
    final result = revision >= 5
        ? _authenticateAes256(password)
        : _authenticateLegacy(password);
    encryptionKey = result.key;
    authenticatedAsOwner = result.owner;
  }

  _AuthenticationResult _authenticateLegacy(String password) {
    final supplied = _passwordBytes(password);

    final userCandidate = _deriveFileKey(supplied);
    if (_validUserKey(userCandidate)) {
      return _AuthenticationResult(userCandidate, false);
    }

    // Algorithm 3.7: decrypt /O with the key derived from the owner password;
    // the result is the padded user password used by algorithm 3.2.
    final ownerEncryptionKey = _ownerEncryptionKey(supplied);
    Uint8List recovered = Crypto.rc4(ownerEncryptionKey, ownerKey);
    if (revision >= 3) {
      for (var i = 19; i >= 1; i--) {
        recovered = Crypto.rc4(_xorKey(ownerEncryptionKey, i), recovered);
      }
    }
    final ownerCandidate = _deriveFileKey(recovered);
    if (_validUserKey(ownerCandidate)) {
      return _AuthenticationResult(ownerCandidate, true);
    }
    throw const FormatException('Invalid PDF password');
  }

  _AuthenticationResult _authenticateAes256(String password) {
    final supplied = _unicodePasswordBytes(password);
    final userValidation = _aes256Hash(
      supplied,
      Uint8List.sublistView(userKey, 32, 40),
      null,
    );
    if (_constantTimeEquals(userValidation, userKey, 32)) {
      final wrappingKey = _aes256Hash(
        supplied,
        Uint8List.sublistView(userKey, 40, 48),
        null,
      );
      final fileKey = _unwrapFileKey(wrappingKey, userEncryptedKey!);
      _validatePerms(fileKey);
      return _AuthenticationResult(fileKey, false);
    }

    final ownerValidation = _aes256Hash(
      supplied,
      Uint8List.sublistView(ownerKey, 32, 40),
      userKey,
    );
    if (_constantTimeEquals(ownerValidation, ownerKey, 32)) {
      final wrappingKey = _aes256Hash(
        supplied,
        Uint8List.sublistView(ownerKey, 40, 48),
        userKey,
      );
      final fileKey = _unwrapFileKey(wrappingKey, ownerEncryptedKey!);
      _validatePerms(fileKey);
      return _AuthenticationResult(fileKey, true);
    }
    throw const FormatException('Invalid PDF password');
  }

  Uint8List _aes256Hash(
    Uint8List password,
    Uint8List salt,
    Uint8List? userEntry,
  ) {
    final initial = Uint8List.fromList(<int>[
      ...password,
      ...salt,
      if (userEntry != null) ...userEntry,
    ]);
    if (revision == 5) return Crypto.sha256(initial);

    // ISO 32000-2 algorithm 2.B. K1 is always a multiple of 64 bytes, hence
    // CBC can be applied without padding at every round.
    var k = Crypto.sha256(initial);
    var round = 0;
    var last = 0;
    do {
      final block = <int>[
        ...password,
        ...k,
        if (userEntry != null) ...userEntry,
      ];
      final k1 = Uint8List(block.length * 64);
      for (var i = 0; i < 64; i++) {
        k1.setAll(i * block.length, block);
      }
      final e = Crypto.aesEncryptCbc(
        Uint8List.sublistView(k, 0, 16),
        Uint8List.sublistView(k, 16, 32),
        k1,
        padding: false,
      );
      var selector = 0;
      for (var i = 0; i < 16; i++) {
        selector = (selector + e[i]) % 3;
      }
      k = switch (selector) {
        0 => Crypto.sha256(e),
        1 => Crypto.sha384(e),
        _ => Crypto.sha512(e),
      };
      last = e.last;
      round++;
    } while (round < 64 || last > round - 32);
    return Uint8List.fromList(k.sublist(0, 32));
  }

  static Uint8List _unwrapFileKey(Uint8List key, Uint8List encrypted) =>
      Crypto.aesDecryptCbc(key, Uint8List(16), encrypted, padding: false);

  void _validatePerms(Uint8List fileKey) {
    final decoded = Crypto.aesDecryptCbc(
      fileKey,
      Uint8List(16),
      permsEntry!,
      padding: false,
    );
    final encodedPermissions =
        decoded[0] | decoded[1] << 8 | decoded[2] << 16 | decoded[3] << 24;
    final expectedPermissions = permissions & 0xffffffff;
    final metadataByte = encryptMetadata ? 0x54 : 0x46; // T / F
    if (encodedPermissions != expectedPermissions ||
        decoded[4] != 0xff ||
        decoded[5] != 0xff ||
        decoded[6] != 0xff ||
        decoded[7] != 0xff ||
        decoded[8] != metadataByte ||
        decoded[9] != 0x61 ||
        decoded[10] != 0x64 ||
        decoded[11] != 0x62) {
      throw const FormatException('Invalid AES-256 /Perms entry');
    }
  }

  Uint8List _deriveFileKey(Uint8List password) {
    final padded = _padPassword(password);
    final input = BytesBuilder(copy: false)
      ..add(padded)
      ..add(ownerKey)
      ..add(<int>[
        permissions & 0xff,
        (permissions >> 8) & 0xff,
        (permissions >> 16) & 0xff,
        (permissions >> 24) & 0xff,
      ])
      ..add(fileId);
    if (revision >= 4 && !encryptMetadata) {
      input.add(const <int>[0xff, 0xff, 0xff, 0xff]);
    }
    var digest = Crypto.md5(input.takeBytes());
    if (revision >= 3) {
      for (var i = 0; i < 50; i++) {
        digest = Crypto.md5(Uint8List.sublistView(digest, 0, keyLength));
      }
    }
    return Uint8List.fromList(digest.sublist(0, keyLength));
  }

  Uint8List _ownerEncryptionKey(Uint8List password) {
    var digest = Crypto.md5(_padPassword(password));
    if (revision >= 3) {
      for (var i = 0; i < 50; i++) {
        digest = Crypto.md5(digest);
      }
    }
    return Uint8List.fromList(digest.sublist(0, keyLength));
  }

  bool _validUserKey(Uint8List key) {
    if (revision == 2) {
      return _constantTimeEquals(
          Crypto.rc4(key, _passwordPadding), userKey, 32);
    }
    var candidate = Crypto.md5(Uint8List.fromList(<int>[
      ..._passwordPadding,
      ...fileId,
    ]));
    candidate = Crypto.rc4(key, candidate);
    for (var i = 1; i <= 19; i++) {
      candidate = Crypto.rc4(_xorKey(key, i), candidate);
    }
    return _constantTimeEquals(candidate, userKey, 16);
  }

  /// Encrypts a string or stream belonging to the indirect object.
  Uint8List encryptContent(int objNum, int objGen, Uint8List data) {
    final objectKey = _computeObjectKey(objNum, objGen);
    if (!isAes && revision < 5) return Crypto.rc4(objectKey, data);

    final random = Random.secure();
    final iv = Uint8List.fromList(
      List<int>.generate(16, (_) => random.nextInt(256), growable: false),
    );
    final ciphertext = Crypto.aesEncryptCbc(
      objectKey,
      iv,
      data,
      padding: true,
    );
    return Uint8List.fromList(<int>[...iv, ...ciphertext]);
  }

  /// Decrypts a string or stream belonging to the indirect object.
  Uint8List decryptContent(int objNum, int objGen, Uint8List data) {
    final objectKey = _computeObjectKey(objNum, objGen);
    if (!isAes && revision < 5) return Crypto.rc4(objectKey, data);
    if (data.length < 32 || (data.length - 16) % 16 != 0) {
      throw const FormatException('Invalid AES-encrypted PDF object');
    }
    return Crypto.aesDecryptCbc(
      objectKey,
      Uint8List.sublistView(data, 0, 16),
      Uint8List.sublistView(data, 16),
      padding: true,
    );
  }

  Uint8List _computeObjectKey(int objNum, int objGen) {
    if (revision >= 5) return encryptionKey;
    if (objNum < 0 || objNum > 0xffffff || objGen < 0 || objGen > 0xffff) {
      throw RangeError(
          'PDF object and generation numbers must fit 3 and 2 bytes');
    }
    final input = Uint8List(encryptionKey.length + 5 + (isAes ? 4 : 0));
    input
      ..setAll(0, encryptionKey)
      ..[encryptionKey.length] = objNum & 0xff
      ..[encryptionKey.length + 1] = (objNum >> 8) & 0xff
      ..[encryptionKey.length + 2] = (objNum >> 16) & 0xff
      ..[encryptionKey.length + 3] = objGen & 0xff
      ..[encryptionKey.length + 4] = (objGen >> 8) & 0xff;
    if (isAes) {
      input.setAll(input.length - 4, const <int>[0x73, 0x41, 0x6c, 0x54]);
    }
    final digest = Crypto.md5(input);
    final length = min(encryptionKey.length + 5, 16);
    return Uint8List.fromList(digest.sublist(0, length));
  }

  static Uint8List _passwordBytes(String password) => Uint8List.fromList(
        const Latin1Codec(allowInvalid: true).encode(password),
      );

  Uint8List _unicodePasswordBytes(String password) {
    final prepared = revision == 6 ? _saslPrep(password) : password;
    final encoded = utf8.encode(prepared);
    return Uint8List.fromList(
        encoded.length <= 127 ? encoded : encoded.sublist(0, 127));
  }

  static String _saslPrep(String input) {
    final mapped = StringBuffer();
    for (final rune in input.runes) {
      if (_mappedToNothing(rune)) continue;
      mapped.writeCharCode(_nonAsciiSpace(rune) ? 0x20 : rune);
    }
    final result = nfkc(mapped.toString());
    // RFC 4013 is tied to Unicode 3.2's unassigned-code-point table. The
    // framework normalizer deliberately tracks a newer Unicode version, so a
    // blanket acceptance of non-ASCII output could accept a character that
    // SASLprep 3.2 requires us to reject. Compatibility characters that NFKC
    // maps to ASCII are safe; other non-ASCII passwords fail closed until the
    // generated Unicode tables expose the 3.2 Assigned property explicitly.
    if (result.runes.any((rune) => rune > 0x7f)) {
      throw UnsupportedError(
        'R6 non-ASCII passwords require the Unicode 3.2 SASLprep tables',
      );
    }
    var hasRandAl = false;
    var hasL = false;
    final runes = result.runes.toList(growable: false);
    for (final rune in runes) {
      if (_prohibited(rune)) {
        throw const FormatException(
            'Password contains a SASLprep-prohibited character');
      }
      hasRandAl |= _randAl(rune);
      hasL |= _lCategory(rune);
    }
    if (hasRandAl &&
        (hasL ||
            runes.isEmpty ||
            !_randAl(runes.first) ||
            !_randAl(runes.last))) {
      throw const FormatException(
          'Password violates SASLprep bidirectional rules');
    }
    return result;
  }

  static bool _mappedToNothing(int c) =>
      c == 0x00ad ||
      c == 0x034f ||
      c == 0x1806 ||
      (c >= 0x180b && c <= 0x180d) ||
      (c >= 0x200b && c <= 0x200d) ||
      c == 0x2060 ||
      (c >= 0xfe00 && c <= 0xfe0f) ||
      c == 0xfeff;

  static bool _nonAsciiSpace(int c) =>
      c == 0x00a0 ||
      c == 0x1680 ||
      (c >= 0x2000 && c <= 0x200b) ||
      c == 0x202f ||
      c == 0x205f ||
      c == 0x3000;

  static bool _prohibited(int c) =>
      c <= 0x1f ||
      c == 0x7f ||
      (c >= 0x80 && c <= 0x9f) ||
      c == 0x06dd ||
      c == 0x070f ||
      c == 0x180e ||
      (c >= 0x200c && c <= 0x200d) ||
      (c >= 0x2028 && c <= 0x2029) ||
      (c >= 0x2060 && c <= 0x2063) ||
      (c >= 0x206a && c <= 0x206f) ||
      (c >= 0x1d173 && c <= 0x1d17a) ||
      (c >= 0xe000 && c <= 0xf8ff) ||
      (c >= 0xf0000 && c <= 0xffffd) ||
      (c >= 0x100000 && c <= 0x10fffd) ||
      (c & 0xffff) >= 0xfffe ||
      (c >= 0xd800 && c <= 0xdfff) ||
      (c >= 0xfff9 && c <= 0xfffd) ||
      (c >= 0x2ff0 && c <= 0x2ffb) ||
      (c >= 0xe0001 && c <= 0xe007f) ||
      c == 0x0340 ||
      c == 0x0341 ||
      c == 0x200e ||
      c == 0x200f ||
      (c >= 0x202a && c <= 0x202e) ||
      (c >= 0x206a && c <= 0x206f);

  static bool _randAl(int c) =>
      c == 0x05be ||
      c == 0x05c0 ||
      c == 0x05c3 ||
      (c >= 0x05d0 && c <= 0x05ea) ||
      (c >= 0x05f0 && c <= 0x05f4) ||
      (c >= 0x0600 && c <= 0x06ff) ||
      (c >= 0x0700 && c <= 0x074f) ||
      (c >= 0x0780 && c <= 0x07bf) ||
      (c >= 0xfb1d && c <= 0xfdff) ||
      (c >= 0xfe70 && c <= 0xfefc);

  static bool _lCategory(int c) =>
      (c >= 0x0041 && c <= 0x005a) ||
      (c >= 0x0061 && c <= 0x007a) ||
      (c >= 0x00c0 && c <= 0x02af) ||
      (c >= 0x0370 && c <= 0x052f) ||
      (c >= 0x0900 && c <= 0x1fff) ||
      (c >= 0x2c00 && c <= 0xd7ff);

  static Uint8List _padPassword(Uint8List password) {
    final result = Uint8List(32);
    final count = min(password.length, 32);
    result.setRange(0, count, password);
    if (count < 32) result.setRange(count, 32, _passwordPadding);
    return result;
  }

  static Uint8List _xorKey(Uint8List key, int value) => Uint8List.fromList(
      key.map((byte) => byte ^ value).toList(growable: false));

  static bool _constantTimeEquals(List<int> a, List<int> b, int count) {
    if (a.length < count || b.length < count) return false;
    var difference = 0;
    for (var i = 0; i < count; i++) {
      difference |= a[i] ^ b[i];
    }
    return difference == 0;
  }
}

final class _AuthenticationResult {
  const _AuthenticationResult(this.key, this.owner);

  final Uint8List key;
  final bool owner;
}
