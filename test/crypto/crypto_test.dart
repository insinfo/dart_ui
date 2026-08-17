import 'dart:convert';
import 'dart:typed_data';
import 'package:dart_ui/src/crypto/crypto.dart';
import 'package:test/test.dart';

void main() {
  group('Subconjunto Criptográfico dart_ui (Puro Dart + Aceleração FFI Nativa)',
      () {
    test('SHA-256 atende a vetores de teste NIST', () {
      final input = Uint8List.fromList(ascii.encode('abc'));
      final digest = Crypto.sha256(input);
      final hex = digest.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

      expect(hex,
          'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad');
    });

    test('SHA-1 atende a vetores de teste NIST', () {
      final input = Uint8List.fromList(ascii.encode('abc'));
      final digest = Crypto.sha1(input);
      final hex = digest.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

      expect(hex, 'a9993e364706816aba3e25717850c26c9cd0d89d');
    });

    test('MD5 atende a vetores de teste RFC 1321', () {
      final input = Uint8List.fromList(ascii.encode('abc'));
      final digest = Crypto.md5(input);
      final hex = digest.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

      expect(hex, '900150983cd24fb0d6963f7d28e17f72');
    });

    test('SHA-512 e SHA-384 calculam hashes válidos', () {
      final input = Uint8List.fromList(ascii.encode('abc'));

      final sha512 = Crypto.sha512(input);
      expect(sha512.length, 64);
      final hex512 =
          sha512.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      expect(hex512, startsWith('ddaf35a193617abacc417349ae204131'));

      final sha384 = Crypto.sha384(input);
      expect(sha384.length, 48);
      final hex384 =
          sha384.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      expect(hex384, startsWith('cb00753f45a35e8bb5a03d699ac65007'));
    });

    test('AES-128 / AES-256 CBC cifra e decifra com round-trip perfeito', () {
      final key = Uint8List.fromList([
        0x00,
        0x01,
        0x02,
        0x03,
        0x04,
        0x05,
        0x06,
        0x07,
        0x08,
        0x09,
        0x0a,
        0x0b,
        0x0c,
        0x0d,
        0x0e,
        0x0f,
      ]);
      final iv = Uint8List.fromList([
        0x00,
        0x11,
        0x22,
        0x33,
        0x44,
        0x55,
        0x66,
        0x77,
        0x88,
        0x99,
        0xaa,
        0xbb,
        0xcc,
        0xdd,
        0xee,
        0xff,
      ]);

      final plaintext = Uint8List.fromList(utf8
          .encode('Mensagem confidencial assinada em puro Dart no dart_ui!'));

      final ciphertext = Crypto.aesEncryptCbc(key, iv, plaintext);
      expect(ciphertext, isNot(equals(plaintext)));
      expect(ciphertext.length % 16, 0); // Alinhado ao bloco

      final decrypted = Crypto.aesDecryptCbc(key, iv, ciphertext);
      expect(utf8.decode(decrypted),
          'Mensagem confidencial assinada em puro Dart no dart_ui!');
    });

    test('RC4 cifra e decifra fluxos de dados com simetria', () {
      final key = Uint8List.fromList(ascii.encode('KeySegredoPDF'));
      final data =
          Uint8List.fromList(utf8.encode('Conteudo protegido do fluxo'));

      final encrypted = Crypto.rc4(key, data);
      expect(encrypted, isNot(equals(data)));

      final decrypted = Crypto.rc4(key, encrypted);
      expect(utf8.decode(decrypted), 'Conteudo protegido do fluxo');
    });

    test('Crypto backend identifica nome da plataforma em tempo de execução',
        () {
      expect(Crypto.backendName, isNotEmpty);
    });
  });
}
