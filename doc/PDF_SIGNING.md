# Assinatura digital de PDF

O `dart_ui` oferece um pipeline reutilizável de assinatura incremental PAdES
com chave externa. A chave privada nunca é recebida pelo parser PDF ou pelo
construtor CMS.

## Camadas

- `package:dart_ui/crypto.dart`: criptografia genérica, PKCS#11/Cryptoki e
  stores nativos. Pode carregar uma DLL/`.so`/`.dylib`, enumerar
  `CurrentUser\MY` no Windows ou identidades do Keychain no macOS e delegar ao
  sistema/middleware a interface segura de PIN.
  ASN.1 DER (`Der`, `DerReader`) e X.509 (`X509Certificate`) também vivem nessa
  camada e não dependem de PDF.
  `CertificateProvider`, `CryptoIdentity`, `ExternalKeySigner` e
  `CertificateOperationContext` formam o contrato comum para qualquer origem.
- `package:dart_ui/pdf.dart`: atributos CMS, `SignedData`, atualização
  incremental, AcroForm, widget de assinatura,
  aparência, `ByteRange` e adaptação da chave externa.
- `PdfCertificateProviderSigner`: único adaptador entre as duas camadas. PDF
  não importa Windows, PKCS#11, PC/SC, CCID ou minidriver.

Essa separação permite reutilizar `Pkcs11Module` em assinatura XML, TLS,
autenticação ou outros protocolos sem importar PDF.

A implementação segue a divisão abaixo:

```text
crypto/
├── certificate_provider.dart
├── crypto_identity.dart
├── external_key_signer.dart
├── asn1/
├── x509/
├── pkcs11/
├── windows/
├── macos/
└── linux/
```

DER e X.509 são expostos exclusivamente por `package:dart_ui/crypto.dart`, com
as implementações em `src/crypto/asn1` e `src/crypto/x509`.

## Tokens e cartões inteligentes no Windows

Tokens atuais podem aparecer no Gerenciador de Dispositivos como leitores de
cartão inteligente CCID/PC/SC. O aplicativo não deve falar diretamente com o
leitor para assinar um PDF: o minidriver do cartão e seu KSP/CSP publicam o
certificado e a chave no subsistema criptográfico do Windows.

`WindowsCertificateStore` implementa esse caminho:

1. abre o repositório `CurrentUser\MY` e enumera certificados com
   `CERT_KEY_PROV_INFO_PROP_ID`;
2. reencontra a seleção pela impressão digital e chama
   `CryptAcquireCertificatePrivateKey` com preferência por CNG;
3. usa `NCryptSignHash` para KSP/CNG ou `CryptSignHashW` para CSP/CryptoAPI;
4. não usa modo silencioso nem recebe PIN, permitindo que Windows, SafeSign,
   StarSign ou outro provedor apresente a interface segura;
5. recebe opcionalmente o `HWND` do aplicativo para associar a janela do
   provedor à janela do assinador.

O parser X.509 identifica chaves RSA e EC. CNG usa PKCS#1 v1.5 para RSA e
converte a assinatura ECDSA no formato de componentes fixos do provedor para a
sequência DER exigida pelo CMS. CSP legado é aceito somente para RSA.

Exemplo direto, sem PKCS#11:

```dart
final provider = WindowsCertificateProvider();
final identity = (await provider.listIdentities()).first;
final document = PdfDocument.fromBytes(await File(inputPath).readAsBytes());
final signed = await PdfSigner(
  document: document,
  signerName: identity.certificate.commonName,
  standard: PdfSignatureStandard.padesBB,
).sign(
  externalSigner: PdfCertificateProviderSigner(
    provider: provider,
    identity: identity,
    context: CertificateOperationContext(nativeWindowHandle: hwnd),
  ),
);
await File(outputPath).writeAsBytes(signed, flush: true);
```

PKCS#11 permanece necessário quando o dispositivo/HSM não publica uma chave
utilizável no store do Windows ou em Linux/macOS. Ele é uma origem paralela,
não uma dependência do suporte Windows.

## macOS e Linux

`MacOsCertificateProvider` enumera `SecIdentity` no Keychain e chama
`SecKeyCreateSignature` com RSA PKCS#1 v1.5/SHA-256 ou ECDSA X9.62/SHA-256.
Tokens publicados por CryptoTokenKit participam do mesmo fluxo e a confirmação
fica na UI protegida do macOS.

No Linux, `LinuxCertificateProviderDiscovery` procura os módulos PKCS#11
instalados e cria um `Pkcs11CertificateProvider` por token. PC/SC continua
responsável pelo transporte até o cartão; SafeSign, OpenSC ou o middleware do
fabricante expõe certificado e chave pela API Cryptoki consumida pelo
framework.

## Fluxo completo

```dart
import 'dart:io';

import 'package:dart_ui/crypto.dart';
import 'package:dart_ui/pdf.dart';

Future<void> signPdf({
  required String inputPath,
  required String outputPath,
  required String modulePath,
  required String pin,
}) async {
  final module = Pkcs11Module(modulePath);
  try {
    final token = module.listTokens().first;
    final provider = Pkcs11CertificateProvider.forToken(
      module: module,
      token: token,
    );
    final context = CertificateOperationContext(pin: pin);
    final identity = (await provider.listIdentities(context: context)).first;
    final document = PdfDocument.fromBytes(
      await File(inputPath).readAsBytes(),
    );
    final signer = PdfSigner(
      document: document,
      signerName: identity.certificate.commonName,
      reason: 'Aprovação do documento',
      standard: PdfSignatureStandard.padesBB,
    );
    final signed = await signer.sign(
      externalSigner: PdfCertificateProviderSigner(
        provider: provider,
        identity: identity,
        context: context,
      ),
    );
    await File(outputPath).writeAsBytes(signed, flush: true);
  } finally {
    module.close();
  }
}
```

`PdfPreparedSignature` também expõe o fluxo em duas fases. Ele é indicado para
HSM remoto ou serviço de assinatura: `PdfSigner.prepare()` produz o documento
e o hash do `ByteRange`; `PdfCmsBuilder.createSigningRequest()` produz os
atributos autenticados; depois da assinatura externa,
`PdfCmsBuilder.buildDetachedSignedData()` e `PdfPreparedSignature.embed()`
concluem o PDF sem alterar offsets.

## PAdES implementado

O perfil funcional atual é PAdES B-B RSA/SHA-256:

- atualização incremental, preservando os bytes do documento original;
- campo AcroForm `/FT /Sig` conectado ao catálogo e à página;
- `/Filter /Adobe.PPKLite` e `/SubFilter /ETSI.CAdES.detached`;
- `ByteRange` calculado antes do hash e placeholder de tamanho fixo;
- CMS `SignedData` destacado com certificado e cadeia opcional;
- atributos assinados `contentType`, `messageDigest`, `signingTime` e
  `SigningCertificateV2`;
- identificador do signatário por `IssuerAndSerialNumber`;
- aparência `/AP /N` opcional.

`padesBT` e `padesBLT` falham explicitamente, em vez de produzir um arquivo
com perfil incorreto. Para B-T ainda são necessários cliente TSA RFC 3161 e o
atributo `signatureTimeStampToken`. Para B-LT ainda são necessários coleta e
validação de OCSP/CRL, DSS/VRI e atualização incremental posterior.

## Segurança operacional

- No fluxo Windows, o PIN pertence ao provedor da chave e nunca entra em um
  campo, objeto ou log do `dart_ui`. Não use flags silenciosas para contornar a
  confirmação segura do dispositivo.
- Use o módulo PKCS#11 fornecido pelo fabricante e com a mesma arquitetura do
  processo Dart (normalmente x64).
- O PIN não é gravado no PDF nem incluído em mensagens de log. Ainda assim,
  uma `String` Dart não pode ser zerada de forma confiável; descarte o estado da
  tela logo após o uso e não persista o controlador.
- O framework rejeita PDF criptografado e assinatura visual em página rotada
  até que essas transformações sejam implementadas com segurança.
- O certificado é validado quanto ao período de validade. Construção e
  validação completa da cadeia ICP-Brasil, política de assinatura, OCSP e CRL
  pertencem ao trabalho B-LT e não são simuladas.
- O tamanho padrão reservado para `/Contents` é 32 KiB. Cadeias grandes podem
  exigir `reservedSignatureBytes` maior; exceder o espaço gera
  `PdfSignatureSizeException` sem truncamento.

## Exemplo e testes

O aplicativo está em `examples/pdf_signer_demo` e oferece store nativo e
PKCS#11 através do mesmo `CertificateProvider`. Ele inclui preview real da
página, navegação e um bloco visual arrastável; o retângulo exibido é o mesmo
enviado ao `PdfSignatureAppearance`. Os testes unitários cobrem DER,
X.509, CMS, AcroForm, `ByteRange`, callbacks externos, enumeração do store real
do Windows, provedores genéricos e os adaptadores CNG/CSP/PKCS#11. O teste
`test/pdf/pdf_signer_openssl_test.dart` gera credenciais efêmeras e exige que o
OpenSSL verifique criptograficamente o CMS contra o conteúdo destacado.
