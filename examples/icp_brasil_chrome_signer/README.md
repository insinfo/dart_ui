# Extensão Dart UI ICP-Brasil para Chrome, Brave, Edge e Firefox

Suíte completa para assinar PDFs com certificado ICP-Brasil. O aplicativo
Windows funciona sozinho; a extensão Chrome/Brave/Edge/Firefox acrescenta a
mesma capacidade a sites autorizados. Aplicativo, popup e página web são
árvores de widgets `dart_ui`: no Windows o framework usa sua janela e seu
renderer nativos; no navegador, `WebWindowingBackend` monta um `<canvas>` HTML
e apresenta a mesma pipeline por WebGPU ou WebGL2.

O host usa `WindowsCertificateProvider` (repositório `CurrentUser\\MY`,
CNG/KSP e CryptoAPI/CSP) e o assinador PDF do `dart_ui` para produzir PAdES
B-B. Nenhuma interface do produto é implementada com botões ou formulários
HTML.

## Aplicativo Windows independente

O build produz
`application/dist/dart_ui_pdf_signer.exe`. Ele oferece:

- abertura e visualização real de PDFs com `PdfView`;
- seleção automática de certificados ICP-Brasil do Windows;
- alternativa PKCS#11 para token, smart card ou HSM;
- posicionamento arrastável da aparência visual na página;
- assinatura PAdES B-B e gravação do PDF assinado;
- PIN solicitado pela UI segura do Windows/minidriver, sem passar pelo app.

Em Windows, macOS ou Linux, compile o executável nativo na própria plataforma
sem depender do PowerShell:

```console
dart run examples/icp_brasil_chrome_signer/application/build.dart
```

Para instalar no perfil atual e criar o atalho no Menu Iniciar:

```powershell
powershell -ExecutionPolicy Bypass -File examples/icp_brasil_chrome_signer/install_app.ps1 -DesktopShortcut
```

Para também registrar a integração do navegador:

```powershell
powershell -ExecutionPolicy Bypass -File examples/icp_brasil_chrome_signer/install_app.ps1 -ExtensionId ID_DA_EXTENSAO
```

## Segurança e limites

- A chave privada nunca sai do token/provedor do Windows.
- A origem é derivada de `sender.tab.url` pelo service worker; um site não pode declará-la.
- HTTP só é aceito em `localhost`; produção exige HTTPS.
- Listagem, autenticação e assinatura exibem confirmação nativa. O PIN é solicitado pelo middleware do token e não é armazenado nem transmitido.
- O host aceita no máximo 32 MiB por mensagem. Para documentos maiores, o protocolo deve evoluir para transferência em blocos.
- `authenticate` assina o desafio recebido com SHA-256. O servidor deve criar desafio aleatório, de uso único, com expiração curta, associá-lo à sessão e verificar certificado, cadeia ICP-Brasil, revogação e assinatura.
- Esta versão implementa PAdES B-B. Carimbo do tempo e LTV (B-T/B-LT/B-LTA) dependem de TSA e dados de revogação externos.

## Construção e instalação no Windows

1. Na raiz do projeto, execute `powershell -ExecutionPolicy Bypass -File examples/icp_brasil_chrome_signer/build.ps1`.
2. No Chrome, Brave ou Edge, abra a página de extensões, habilite o modo do desenvolvedor e escolha **Carregar sem compactação** em `examples/icp_brasil_chrome_signer/extension/dist`. Essa pasta contém o `manifest.json`; não selecione `dist` dentro dela novamente.
3. Copie o ID exibido pelo Chrome.
4. Execute `powershell -ExecutionPolicy Bypass -File examples/icp_brasil_chrome_signer/install_host.ps1 -ExtensionId ID_COPIADO`. O instalador registra o host para Chrome, Brave, Edge e Firefox no perfil atual.
5. Reinicie o Chrome. Rode `dart run examples/icp_brasil_chrome_signer/demo_server.dart` e abra `http://localhost:8787`. Essa página também é desenhada integralmente pelo `dart_ui`; o HTML contém apenas o ponto de montagem do backend.

O host pode ser verificado sem abrir o token ou pedir PIN com
`dart run examples/icp_brasil_chrome_signer/native_host_smoke.dart`.
Para confirmar que o Windows e o `dart_ui` enxergam os certificados ICP-Brasil,
execute `dart run examples/icp_brasil_chrome_signer/native_host_smoke.dart --list`.

### Firefox

O build também produz `extension/dist_firefox` e o pacote
`extension/dart-ui-icp-brasil@insinfo.dev.xpi`. Durante o desenvolvimento,
abra `about:debugging#/runtime/this-firefox`, clique em **Carregar extensão
temporária** e selecione `extension/dist_firefox/manifest.json`. Extensões não
assinadas instaladas dessa forma são removidas quando o Firefox fecha. Para
distribuição permanente, assine o XPI no AMO.

Para remover o registro, execute `uninstall_host.ps1`. O script preserva os binários em `%LOCALAPPDATA%\\DartUiIcpBrasil` para evitar exclusão destrutiva implícita.
Para remover o aplicativo e seus atalhos, execute `uninstall_app.ps1`.

## Interface no navegador

Aplicações web importam `package:dart_ui/dart_ui.dart` normalmente. Este exemplo
usa o backend canvas/WebGPU/WebGL2 já existente. Um eventual backend DOM/HTML é
uma frente separada e não faz parte desta suíte.

O exemplo web está em `web/main.dart`; `build.ps1` o compila para
`demo/main.dart.js`. O documento HTML não duplica o layout: tamanhos, textos,
cards, botões, seletor, visualizador PDF, foco, hit testing e pintura pertencem
ao `dart_ui`.

## API para qualquer site

Após detectar `window.dartUiIcpBrasil`, o site pode usar:

```js
const { certificates } = await dartUiIcpBrasil.listCertificates({});
const authentication = await dartUiIcpBrasil.authenticate({
  certificateId: certificates[0].id,
  challenge: base64Challenge,
  audience: location.origin,
});
const signed = await dartUiIcpBrasil.signPdf({
  certificateId: certificates[0].id,
  pdf: base64Pdf,
  reason: 'Aceite do contrato',
  location: 'Brasília, DF',
});

// Fluxo remoto: o servidor prepara o PDF, reserva /Contents e calcula
// SHA-256 sobre os intervalos definidos por /ByteRange.
const detached = await dartUiIcpBrasil.signPdfHash({
  certificateId: certificates[0].id,
  byteRangeDigest: base64Sha256OfPreparedByteRange,
  reason: 'Aceite do contrato',
});
// Valide e incorpore `detached.cms` no /Contents reservado.
```

Respostas de erro têm `{code, message}`. Códigos estáveis: `USER_DENIED`, `INVALID_REQUEST`, `SIGNER_ERROR`, `NATIVE_HOST_ERROR` e `PROTOCOL_ERROR`.

## Decisões extraídas das referências

Lacuna Web PKI, `chrome-token-signing` e `Digital-Signature-Chrome-Extension` confirmam Native Messaging como a fronteira correta entre a sandbox do navegador e o certificado. PJeOffice Pro confirma o papel do middleware/PKCS#11 e da confirmação local. O projeto evita copiar formatos proprietários: publica uma API pequena, documentada e independente do site, sobre os provedores e PAdES já implementados no `dart_ui`.
