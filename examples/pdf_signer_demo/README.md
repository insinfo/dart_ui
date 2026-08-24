# PDF Signer Demo

Aplicativo desktop profissional que usa as APIs públicas de
`package:dart_ui/crypto.dart` e `package:dart_ui/pdf.dart` para produzir uma
assinatura incremental PAdES B-B com uma chave RSA ou EC mantida em token,
smart card ou HSM. A interface mostra a página real e permite arrastar o bloco
de assinatura; essa posição é gravada no campo visual do PDF.

```powershell
dart run examples/pdf_signer_demo/main.dart --presentation direct3d11
```

No Windows, a opção padrão lê `CurrentUser\MY` e funciona com tokens que o
sistema reconhece como cartões inteligentes, incluindo minidrivers/KSPs CNG e
CSPs CryptoAPI legados. É o fluxo indicado para SafeSign, StarSign e tokens
atuais fornecidos por autoridades brasileiras: não se escolhe uma DLL e o PIN
é solicitado pela janela segura do Windows/provedor somente ao assinar.

No macOS, a opção nativa lê as identidades do Keychain por
`Security.framework`; dispositivos CryptoTokenKit usam a própria UI protegida
do sistema para autorizar a chave.

PKCS#11 continua disponível como alternativa multiplataforma. Nesse modo, o
módulo é a biblioteca instalada pelo fabricante: `.dll` no Windows, `.so` no
Linux e `.dylib` no macOS. O aplicativo usa o mesmo `CertificateProvider` e o
mesmo adaptador PAdES nas três plataformas. Também é possível iniciar com o
documento e o módulo preenchidos:

```powershell
dart run examples/pdf_signer_demo/main.dart documento.pdf `
  --module="C:\Windows\System32\aetpkss1.dll"
```

O arquivo resultante é salvo ao lado do original com o sufixo
`_assinado.pdf`. No fluxo Windows, o aplicativo nunca recebe o PIN. No fluxo
PKCS#11, ele é enviado somente ao módulo durante a sessão e não é gravado no
PDF ou em logs.

Arquitetura, fluxo em duas fases e limitações estão documentados em
[`doc/PDF_SIGNING.md`](../../doc/PDF_SIGNING.md).

## Validação com token físico no Windows

Quando o token estiver conectado:

1. confirme que o certificado aparece em `certmgr.msc` em
   `Pessoal > Certificados`;
2. abra o exemplo, mantenha `Certificados do Windows` e clique em
   `Ler certificados`;
3. selecione o certificado do token e assine um PDF de teste;
4. confirme que o PIN é solicitado pela janela do Windows/fabricante, e não
   por um campo do aplicativo;
5. abra o `*_assinado.pdf` em um validador PAdES e confira signatário,
   integridade e cadeia ICP-Brasil.

Não execute esse roteiro em teste automatizado: tentativas repetidas com PIN
incorreto podem bloquear o token.

No Linux/macOS, selecione o módulo SafeSign PKCS#11 instalado pelo fabricante.
O framework procura automaticamente locais comuns de `libaetpkss.so`,
`libaetpkss.so.3` e `libaetpkss.dylib`, mas o botão `Procurar` continua sendo a
fonte definitiva quando o pacote da autoridade certificadora usa outro local.
