import 'dart:convert';
import 'dart:typed_data';

import 'package:dart_ui/src/pdf/crypto/pdf_security_handler.dart';
import 'package:test/test.dart';

void main() {
  group('Standard Security Handler', () {
    test('authenticates R2 user and owner passwords against known vector', () {
      final user = _handler(
        revision: 2,
        owner:
            '94e8094419662a774442fb072e3d9f19e9d130ec09a4d0061e78fe920f7ab62f',
        user:
            'b1f625689bca1356d125453c43cfa750c0296b5c271c03f1cc359fa658a4fa21',
        permissions: -4,
        id: '00112233445566778899aabbccddeeff',
        password: 'user',
      );
      expect(_hex(user.encryptionKey), '77867d7fae');
      expect(user.authenticatedAsOwner, isFalse);

      final owner = _handler(
        revision: 2,
        owner:
            '94e8094419662a774442fb072e3d9f19e9d130ec09a4d0061e78fe920f7ab62f',
        user:
            'b1f625689bca1356d125453c43cfa750c0296b5c271c03f1cc359fa658a4fa21',
        permissions: -4,
        id: '00112233445566778899aabbccddeeff',
        password: 'owner',
      );
      expect(_hex(owner.encryptionKey), '77867d7fae');
      expect(owner.authenticatedAsOwner, isTrue);
    });

    test('authenticates R3 and performs RC4 object round trip', () {
      final handler = _handler(
        revision: 3,
        owner:
            '3fbb536a2990981cb10ee0f08ca1dc95e92f3477a281a9fcafa2301eb5e03932',
        user:
            'd06084679a0ab5fdb6bd21fe06f8912700112233445566778899aabbccddeeff',
        permissions: -1028,
        id: '102132435465768798a9bacbdcedfe0f',
        password: 'user128',
      );
      expect(_hex(handler.encryptionKey), 'abe7c29def1e44dcc13fb4b93fddb731');
      final plaintext = Uint8List.fromList(utf8.encode('conteudo de objeto'));
      final encrypted = handler.encryptContent(42, 3, plaintext);
      expect(encrypted, isNot(plaintext));
      expect(handler.decryptContent(42, 3, encrypted), plaintext);
    });

    test('R4 honors EncryptMetadata=false and uses random AES IVs', () {
      final handler = _handler(
        revision: 4,
        owner:
            '280edbce8610357a34e187bf4801bfba6b774a1eb0eec974aa56a7f6b1cea515',
        user:
            '36fbb22617c6281680421f276b5a2cdb00112233445566778899aabbccddeeff',
        permissions: -3904,
        id: 'deadbeef00112233445566778899aabb',
        password: 'metadata-off',
        aes: true,
        encryptMetadata: false,
      );
      expect(_hex(handler.encryptionKey), 'a7e8c86a2c8f4c932c5d7dd7a39b7e15');
      final plaintext = Uint8List.fromList(utf8.encode('AES-128 no PDF'));
      final first = handler.encryptContent(9, 0, plaintext);
      final second = handler.encryptContent(9, 0, plaintext);
      expect(first.sublist(0, 16), isNot(second.sublist(0, 16)));
      expect(handler.decryptContent(9, 0, first), plaintext);
      expect(handler.decryptContent(9, 0, second), plaintext);
    });

    test('rejects a wrong password and unsupported AES-256 revisions', () {
      expect(
        () => _handler(
          revision: 2,
          owner:
              '94e8094419662a774442fb072e3d9f19e9d130ec09a4d0061e78fe920f7ab62f',
          user:
              'b1f625689bca1356d125453c43cfa750c0296b5c271c03f1cc359fa658a4fa21',
          permissions: -4,
          id: '00112233445566778899aabbccddeeff',
          password: 'wrong',
        ),
        throwsFormatException,
      );
      expect(
        () => PdfSecurityHandler(
          revision: 3,
          ownerKey: Uint8List(32),
          userKey: Uint8List(32),
          permissions: -4,
          fileId: Uint8List(16),
          isAes: true,
        ),
        throwsFormatException,
      );
    });

    test('authenticates AES-256 R5 user and owner known vectors', () {
      final entries = _aes256Entries(5);
      final user = _aes256Handler(entries, revision: 5, password: 'päss');
      expect(_hex(user.encryptionKey), _aes256FileKey);
      expect(user.authenticatedAsOwner, isFalse);
      final owner = _aes256Handler(entries, revision: 5, password: 'owner5');
      expect(_hex(owner.encryptionKey), _aes256FileKey);
      expect(owner.authenticatedAsOwner, isTrue);
    });

    test('authenticates R6 algorithm 2.B and applies SASLprep', () {
      final entries = _aes256Entries(6);
      // Full-width P is NFKC-folded and soft hyphen is mapped to nothing.
      final user = _aes256Handler(
        entries,
        revision: 6,
        password: 'Ｐass\u00adword',
      );
      expect(_hex(user.encryptionKey), _aes256FileKey);
      expect(user.authenticatedAsOwner, isFalse);
      final owner = _aes256Handler(entries, revision: 6, password: 'owner6');
      expect(owner.authenticatedAsOwner, isTrue);

      final plaintext = Uint8List.fromList(utf8.encode('objeto AES-256'));
      final encrypted = user.encryptContent(100, 0, plaintext);
      expect(user.decryptContent(999, 12, encrypted), plaintext,
          reason: 'AESV3 uses the file key directly, not an object key');
    });

    test('AES-256 validates /Perms and SASLprep prohibited characters', () {
      final entries = _aes256Entries(6);
      final damagedPerms = Uint8List.fromList(entries.perms)..[0] ^= 1;
      expect(
        () => _aes256Handler(
          entries.copyWith(perms: damagedPerms),
          revision: 6,
          password: 'Password',
        ),
        throwsFormatException,
      );
      expect(
        () => _aes256Handler(entries, revision: 6, password: 'bad\u0007pass'),
        throwsFormatException,
      );
      expect(
        () => _aes256Handler(entries, revision: 6, password: 'não-ascii'),
        throwsUnsupportedError,
      );
    });
  });
}

const _aes256FileKey =
    '000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f';

_Aes256Entries _aes256Entries(int revision) => revision == 5
    ? _Aes256Entries(
        owner: _bytes(
            '6d6dad66d9327707128f502789b99339269c3876572a32bd6c2b9142a3bba61621222324252627283132333435363738'),
        user: _bytes(
            '4301ec02da3ebdb52f750b7f81db0f90e1aea50339ae6313fea949a074d8425501020304050607081112131415161718'),
        ownerEncrypted: _bytes(
            '1627cc6ee547517c59ea6cd1f5a2bf9a686ae776e132c8d27eab5036b9911e03'),
        userEncrypted: _bytes(
            '6e27aa47402af7e11622c5e8678efd5ddffd85e5d118126f155135bd619c0f34'),
        perms: _bytes('4a647476feb2bbe76203c1a27705e205'),
      )
    : _Aes256Entries(
        owner: _bytes(
            'e0bfaaac00d6aac1a347ae24dc577e2f60759ab952b96f553df960b4dc06967d21222324252627283132333435363738'),
        user: _bytes(
            '04c47ce59ab19f80a12606345f8fe84eefc7e4f70cb95c7497e23128a2a6d4df01020304050607081112131415161718'),
        ownerEncrypted: _bytes(
            '33dbd08216e0767911c4b1755fd48f355afbd1a69e00ce0e8044298c4a5256a5'),
        userEncrypted: _bytes(
            'de0fb190f2237f8ce44e10ed7cc6cd3e2e98d2340aad5fe853f836dc67b9ade0'),
        perms: _bytes('4a647476feb2bbe76203c1a27705e205'),
      );

PdfSecurityHandler _aes256Handler(
  _Aes256Entries entries, {
  required int revision,
  required String password,
}) =>
    PdfSecurityHandler(
      revision: revision,
      ownerKey: entries.owner,
      userKey: entries.user,
      ownerEncryptedKey: entries.ownerEncrypted,
      userEncryptedKey: entries.userEncrypted,
      permsEntry: entries.perms,
      permissions: -3904,
      fileId: Uint8List(16),
      password: password,
      isAes: true,
    );

final class _Aes256Entries {
  const _Aes256Entries({
    required this.owner,
    required this.user,
    required this.ownerEncrypted,
    required this.userEncrypted,
    required this.perms,
  });
  final Uint8List owner;
  final Uint8List user;
  final Uint8List ownerEncrypted;
  final Uint8List userEncrypted;
  final Uint8List perms;

  _Aes256Entries copyWith({Uint8List? perms}) => _Aes256Entries(
        owner: owner,
        user: user,
        ownerEncrypted: ownerEncrypted,
        userEncrypted: userEncrypted,
        perms: perms ?? this.perms,
      );
}

PdfSecurityHandler _handler({
  required int revision,
  required String owner,
  required String user,
  required int permissions,
  required String id,
  required String password,
  bool aes = false,
  bool encryptMetadata = true,
}) =>
    PdfSecurityHandler(
      revision: revision,
      ownerKey: _bytes(owner),
      userKey: _bytes(user),
      permissions: permissions,
      fileId: _bytes(id),
      password: password,
      isAes: aes,
      encryptMetadata: encryptMetadata,
    );

Uint8List _bytes(String hex) => Uint8List.fromList(<int>[
      for (var i = 0; i < hex.length; i += 2)
        int.parse(hex.substring(i, i + 2), radix: 16),
    ]);

String _hex(List<int> bytes) =>
    bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
