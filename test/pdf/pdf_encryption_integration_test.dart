import 'dart:convert';
import 'dart:typed_data';

import 'package:dart_ui/src/pdf/crypto/pdf_encryption.dart';
import 'package:dart_ui/src/pdf/crypto/pdf_security_handler.dart';
import 'package:dart_ui/src/pdf/document/pdf_document.dart';
import 'package:dart_ui/src/pdf/format/pdf_object.dart';
import 'package:test/test.dart';

void main() {
  test('PdfDocument requires a password and decrypts strings/streams lazily',
      () {
    final bytes = _r2EncryptedPdf();
    expect(
      () => PdfDocument.fromBytes(bytes),
      throwsA(isA<PdfPasswordRequiredException>()),
    );
    expect(
      () => PdfDocument.fromBytes(bytes, password: 'wrong'),
      throwsFormatException,
    );

    PdfEncryptionInfo? request;
    final document = PdfDocument.fromBytes(
      bytes,
      passwordProvider: (info) {
        request = info;
        return 'user';
      },
    );
    expect(request?.revision, 2);
    expect(request?.permissions, -4);
    expect(document.title, 'Título secreto');
    expect(
      utf8.decode(document.getPage(1).getContentsBytes()).trim(),
      'BT (segredo) Tj ET',
    );
  });

  test('crypt filters route Identity, AESV2 and metadata exemption', () {
    final dictionary = PdfDict(<String, PdfObject>{
      'Filter': const PdfName('Standard'),
      'V': const PdfNumber(4),
      'R': const PdfNumber(4),
      'Length': const PdfNumber(128),
      'O': PdfString(_bytes(
        '280edbce8610357a34e187bf4801bfba6b774a1eb0eec974aa56a7f6b1cea515',
      )),
      'U': PdfString(_bytes(
        '36fbb22617c6281680421f276b5a2cdb00112233445566778899aabbccddeeff',
      )),
      'P': const PdfNumber(-3904),
      'EncryptMetadata': const PdfBoolean(false),
      'StmF': const PdfName('Encrypted'),
      'StrF': const PdfName('Identity'),
      'CF': PdfDict(<String, PdfObject>{
        'Encrypted': PdfDict(<String, PdfObject>{
          'CFM': const PdfName('AESV2'),
        }),
      }),
    });
    final context = PdfEncryptionContext.fromDictionary(
      dictionary,
      _bytes('deadbeef00112233445566778899aabb'),
      'metadata-off',
    );
    final handler = context.handler;
    final plaintext = Uint8List.fromList(utf8.encode('stream secreto'));
    final encrypted = handler.encryptContent(
      8,
      0,
      plaintext,
      cipher: PdfSecurityCipher.aes128,
    );

    final normal = context.decryptObject(
      8,
      0,
      PdfStream(PdfDict(), encrypted),
    ) as PdfStream;
    expect(normal.rawBytes, plaintext);

    final identity = context.decryptObject(
      8,
      0,
      PdfStream(
        PdfDict(<String, PdfObject>{
          'Filter': const PdfName('Crypt'),
          'DecodeParms': PdfDict(<String, PdfObject>{
            'Name': const PdfName('Identity'),
          }),
        }),
        encrypted,
      ),
    ) as PdfStream;
    expect(identity.rawBytes, encrypted);

    final metadata = context.decryptObject(
      8,
      0,
      PdfStream(
        PdfDict(<String, PdfObject>{'Type': const PdfName('Metadata')}),
        encrypted,
      ),
    ) as PdfStream;
    expect(metadata.rawBytes, encrypted);
  });
}

Uint8List _r2EncryptedPdf() {
  final owner = _bytes(
    '94e8094419662a774442fb072e3d9f19e9d130ec09a4d0061e78fe920f7ab62f',
  );
  final user = _bytes(
    'b1f625689bca1356d125453c43cfa750c0296b5c271c03f1cc359fa658a4fa21',
  );
  final id = _bytes('00112233445566778899aabbccddeeff');
  final security = PdfSecurityHandler(
    revision: 2,
    ownerKey: owner,
    userKey: user,
    permissions: -4,
    fileId: id,
    password: 'user',
  );
  final content = security.encryptContent(
    4,
    0,
    Uint8List.fromList(utf8.encode('BT (segredo) Tj ET')),
  );
  final title = security.encryptContent(
    6,
    0,
    Uint8List.fromList(utf8.encode('Título secreto')),
  );
  final objects = <int, List<int>>{
    1: ascii.encode('<< /Type /Catalog /Pages 2 0 R >>'),
    2: ascii.encode('<< /Type /Pages /Kids [3 0 R] /Count 1 >>'),
    3: ascii.encode(
      '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 300] /Contents 4 0 R >>',
    ),
    4: <int>[
      ...ascii.encode('<< /Length ${content.length} >>\nstream\n'),
      ...content,
      ...ascii.encode('\nendstream'),
    ],
    5: ascii.encode(
      '<< /Filter /Standard /V 1 /R 2 /Length 40 /O <${_hex(owner)}> '
      '/U <${_hex(user)}> /P -4 >>',
    ),
    6: ascii.encode('<< /Title <${_hex(title)}> >>'),
  };
  final output = BytesBuilder(copy: false)..add(ascii.encode('%PDF-1.4\n'));
  final offsets = <int>[0];
  for (var number = 1; number <= objects.length; number++) {
    offsets.add(output.length);
    output
      ..add(ascii.encode('$number 0 obj\n'))
      ..add(objects[number]!)
      ..add(ascii.encode('\nendobj\n'));
  }
  final xref = output.length;
  output.add(ascii.encode('xref\n0 7\n0000000000 65535 f \n'));
  for (var number = 1; number <= objects.length; number++) {
    output.add(ascii
        .encode('${offsets[number].toString().padLeft(10, '0')} 00000 n \n'));
  }
  output.add(ascii.encode(
    'trailer\n<< /Size 7 /Root 1 0 R /Info 6 0 R /Encrypt 5 0 R '
    '/ID [<${_hex(id)}> <${_hex(id)}>] >>\nstartxref\n$xref\n%%EOF',
  ));
  return output.takeBytes();
}

Uint8List _bytes(String hex) => Uint8List.fromList(<int>[
      for (var i = 0; i < hex.length; i += 2)
        int.parse(hex.substring(i, i + 2), radix: 16),
    ]);

String _hex(List<int> bytes) =>
    bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
