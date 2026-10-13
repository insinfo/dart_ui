# Relatório — fazer um app Android e iOS em Dart puro, e o que o Dart SDK poderia mudar

**Data:** 12 de outubro de 2026
**Contexto:** o dart_ui (framework de interface 100% Dart, sem Flutter) passou a
rodar no Android e no iOS neste dia. Este relatório registra **o que foi difícil
e por quê**, medido no caminho, e **propostas concretas** para levar ao
repositório do Dart SDK (`dart-lang/sdk`). As decisões de arquitetura estão nos
ADRs [0009](adr/0009-android-host-java-e-processo-dart.md) e
[0010](adr/0010-dart-aot-embutido-android-ios.md); o guia de uso em
[`ANDROID_IOS.md`](ANDROID_IOS.md).

Ambiente: Mac mini M4, macOS 27.2, Xcode 27.0, Dart 3.13.5; emulador Android 15
arm64 e simulador iOS 27.0 (iPhone 18 Pro).

---

## 1. O que existe hoje, em uma frase cada

- **Android:** uma activity Java inicia o runtime AOT do Dart como processo
  filho; quadros por `memfd`, entrada por socket. Funciona em JIT (VM do Termux)
  e em AOT (runtime compilado do código-fonte do Dart SDK).
- **iOS:** o executável do app é o `dartaotruntime` compilado para iOS com um
  patch de ~100 linhas; o programa é um snapshot Mach-O em
  `App.framework`; o Dart roda na thread principal e fala com o UIKit por FFI.

Nenhum dos dois usa Flutter. Os dois precisaram de trabalho que o SDK poderia
ter evitado.

---

## 2. Dificuldades encontradas

### 2.1 Não existe Dart SDK para Android nem para iOS

O Google publica o SDK para Windows, Linux e macOS (inclusive Linux arm64), e
nada para Android ou iOS — conferido em 12/10/2026: `dartsdk-android-arm64` e
`dartsdk-ios-arm64` dão 404 para 3.6.2, 3.9.4 e 3.10.0.

- O `dart compile exe --help` **lista** `--target-os android` e `ios`, mas o SDK
  só traz o `gen_snapshot` do próprio host. A opção existe e não funciona.
- Para o primeiro marco do Android, a saída foi o pacote `dart` do **Termux**,
  que por sorte depende só do bionic (`libc`, `libdl`, `libm`, `liblog`). É uma
  build de terceiros, e o repositório do Termux guarda só a versão mais nova.
- Para AOT e para o iOS foi preciso **compilar o SDK do código-fonte**:
  `depot_tools`, `gclient sync` (13 GB) e `tools/build.py` por alvo. Quem quer só
  escrever um app não deveria ter de fazer isso.

### 2.2 O runtime AOT não existe como biblioteca

O SDK tem `dart_embedder_runtime_jit` como biblioteca estática, mas o runtime
**AOT** só sai como executável (`dartaotruntime`). Um app Android carrega código
nativo com `System.loadLibrary` (uma `.so`), e um embedder iOS normalmente
ligaria o runtime ao próprio binário. Sem biblioteca:

- no Android o Dart virou **processo filho** (com cópia de cada quadro e sem
  acesso à `ANativeWindow`, logo sem GPU direta);
- no iOS o executável do app teve de **ser** o `dartaotruntime`, e o
  comportamento de app veio por patch no `main_impl.cc`.

### 2.3 A thread principal: o isolate principal não roda nela

`Dart_RunLoop` deixa a thread que o chamou parada em `pthread_cond_wait` e roda
o isolate numa thread do pool. Medido no simulador: o `UIApplicationMain`
chamado do `main()` do Dart rodou numa `DartWorker`, e o UIKit abortou com
*"Must be called from the main thread"*. O mesmo obstáculo já tinha aparecido no
macOS (AppKit), onde o projeto precisou de um host nativo, do SkyLight e de um
sequestro de thread por sinal.

No iOS a correção foi um patch no runtime: com `Dart_SetMessageNotifyCallback`,
as mensagens do isolate principal passam a ser tratadas **na thread principal**,
por uma fonte do `CFRunLoop`, com o isolate sempre entrado nela. É o que todo
embedder de UI faz — e o `dart` standalone não oferece.

### 2.4 Microtasks paradas depois de um callback nativo

Com o isolate na thread principal, o UIKit chama o Dart por
`NativeCallable.isolateLocal` **fora de qualquer mensagem**. O que o callback
agenda — a conclusão de um `Future`, um evento de `Stream` — fica na fila de
microtasks até a próxima mensagem. Medido: a cena conectava, mas o
`Application.start` só continuaria no timeout de 30 s. A saída foi o backend
mandar uma mensagem vazia para si mesmo depois de cada callback. Funciona, mas é
um truque que cada embedder teria de descobrir.

### 2.5 O iOS abre o app sem argumentos

O `dartaotruntime` espera o caminho do snapshot em `argv[1]`. O iOS não passa
argumentos. Patch: sem argumentos, procurar
`Frameworks/App.framework/App` ao lado do executável.

### 2.6 O snapshot Mach-O sai marcado só para aparelho

`gen_snapshot --snapshot_kind=app-aot-macho-dylib` grava `LC_BUILD_VERSION` com
plataforma iOS mesmo no build de simulador, e o `dyld` do simulador recusa
(*"incompatible platform (have 'iOS', need 'iOS-simulator')"*). Saída:
`vtool -set-build-version iossim` antes de assinar.

### 2.7 Compilar o SDK com o Xcode e o macOS atuais

Três ajustes para a tag 3.13.5 compilar no macOS 27 / iOS 27:

- o `ld64.lld` do SDK não lê os `.tbd` do macOS 27 (alvo `arm64e.x1-macos`,
  *"unknown target"*); as ferramentas do host foram ligadas contra o SDK 26.5;
- `runtime/vm/thread.cc` usa `NAN` sem `<cmath>`, que os cabeçalhos do iOS 27 já
  não trazem por tabela;
- no iOS, `-exported_symbol` (do `dartaotruntime`) e `-unexported_symbols_list`
  (do `libc++abi`) não podem ir juntos no mesmo link.

### 2.8 `dart:io` não envia descritores arbitrários

Para mandar o `memfd` de um quadro ao host Android, o natural seria
`RawSocket.sendMessage` com `SocketControlMessage.fromHandles`. Mas um
`ResourceHandle` só nasce de arquivo, socket ou pipe que o próprio `dart:io`
abriu, e reabrir o `memfd` por `/proc/self/fd/N` é negado pelo SELinux do
Android (`EACCES`). Saída: o socket inteiro por FFI na libc (`socket`,
`sendmsg` com `SCM_RIGHTS`, `poll`), reaproveitando o transporte do backend
Wayland.

### 2.9 `errno` pela FFI

A FFI não captura o `errno` da última chamada. O backend lê o `errno` chamando a
função da libc que devolve o endereço dele — `__errno_location` na glibc, mas
`__errno` no bionic do Android. Sem saber disso, todo `EAGAIN` virou "conexão
quebrada" e o app saía com código 0 sem dizer nada.

### 2.10 Versões amarradas

O kernel, o `gen_snapshot` e o runtime têm de ser **exatamente** da mesma versão.
O build do app precisa de um Dart do host na mesma tag do runtime embarcado, o
que obriga o projeto a fixar versão e manter dois SDKs.

### 2.11 Callbacks de outras threads não retornam valor

`NativeCallable.listener` aceita só retorno `void`. Callbacks de sistema que
chegam em outra thread e esperam resposta (o cliente do Dock no macOS é um
exemplo) não podem ser escritos em Dart sem uma thread que espere.

---

## 3. Propostas para o Dart SDK

Em ordem de impacto para quem faz app mobile em Dart puro. As três primeiras,
sozinhas, eliminariam quase todo o trabalho deste relatório.

### P1 — Publicar os artefatos de Android e iOS e fazer `--target-os` funcionar

Publicar em cada release, como já se faz com Linux arm64:

- `dartaotruntime` para `android-arm64`, `android-x64`, `android-arm` e
  `ios-arm64` (aparelho e simulador);
- `gen_snapshot` de cada host (macOS, Linux, Windows) para esses alvos.

E fazer `dart compile exe|aot-snapshot --target-os android|ios` baixar e usar o
`gen_snapshot` certo, como `--target-os linux --target-arch arm64` já faz desde
o 3.8. Resolve 2.1 e 2.10, e tira o Termux do caminho.

### P2 — O runtime AOT como biblioteca, com API de embedder estável

Publicar `libdart_precompiled_runtime` — `.a`/`.so` e um `.xcframework` — com
`dart_api.h`, `dart_embedder_api.h` e `bin/dart_io_api.h` versionados, e um
exemplo mínimo de embedder em `samples/` para Android (`NativeActivity`) e iOS
(`UIApplicationMain`). Resolve 2.2: no Android, o Dart no processo do app com a
`ANativeWindow` (GPU direta); no iOS, um embedder sem patch.

### P3 — Rodar o isolate principal na thread principal, integrado ao loop da plataforma

Um modo do runtime standalone, por flag (`--main-isolate-on-main-thread`) ou
pela API de embedder, em que as mensagens do isolate principal são tratadas na
thread do processo, a partir do `CFRunLoop` (Apple) ou do `ALooper` (Android),
com o isolate sempre entrado nela. O patch de iOS deste projeto (seção 2.3) é
uma implementação mínima para Apple e pode virar o PR inicial.

Complementa as propostas já escritas no projeto, que tratam o mesmo eixo pelo
lado do desktop:
[01](propostas/01_proposta_dart_sdk_main_thread_ptbr.md)/[02](propostas/02_proposal_dart_sdk_process_main_thread_github_en.md)
(tomar a *process main thread*),
[04](propostas/04_proposta_dart_sdk_event_loop_nativo_ptbr.md)/[05](propostas/05_proposal_dart_sdk_external_event_loop_github_en.md)
(`Isolate.onEvent`/`handleEvent` para loops externos) e
[08](propostas/08_proposta_dart_sdk_laco_modal_aninhado_ptbr.md) (laço modal
aninhado). Mobile é o caso em que o problema deixa de ser incômodo e passa a ser
impeditivo: no iOS não há outro jeito.

### P4 — Esvaziar microtasks depois de um callback nativo

Quando um `NativeCallable.isolateLocal` é chamado com o isolate ocioso (entrado,
mas fora de uma mensagem), o VM esvaziar a fila de microtasks ao retornar; ou
expor `Dart_DrainMicrotasks()` na API de embedder para o embedder chamar depois
de cada evento da plataforma. Resolve 2.4 sem a mensagem para si mesmo.

### P5 — Descritores arbitrários no `dart:io`

`ResourceHandle.fromRawFileDescriptor(int fd)` (e o inverso, ler o descritor de
um `ResourceHandle` recebido) para `RawSocket.sendMessage`/`receiveMessage` em
sockets Unix. Resolve 2.8: `memfd`, `AHardwareBuffer` e `dma-buf` passariam pelo
`dart:io` sem reescrever o socket em FFI.

### P6 — `errno` capturado pela FFI

Uma forma de declarar que uma chamada FFI captura o `errno` logo depois de
retornar, e uma leitura portátil dele, sem depender do nome da função interna de
cada libc. Resolve 2.9.

### P7 — `gen_snapshot` marcar a plataforma do Mach-O

Uma opção (`--macho-platform=ios|iossim|macos`) ou a escolha automática pelo
`target_os` do build. Resolve 2.6.

### P8 — Snapshot no bundle sem argumentos

No runtime para iOS, procurar o snapshot no bundle (`App.framework`, ou uma
chave do `Info.plist`) quando não houver argumento. Resolve 2.5; vem de graça
com P2 ou P3.

### P9 — Manter o SDK compilável com o Xcode corrente

Os três ajustes da seção 2.7 são pequenos e devem ir como PRs: `<cmath>` em
`thread.cc`, não combinar `-exported_symbol` com o `-unexported_symbols_list`
do `libc++abi` no iOS, e atualizar o `lld` (ou cair para o `ld` do Xcode) para
ler os `.tbd` novos.

### P10 — Callbacks síncronos de outras threads

Uma variante de `NativeCallable` que, chamada de outra thread, entra no isolate,
roda e devolve o valor — ou a estabilização dos callbacks ligados ao *isolate
group* que o SDK vem experimentando. Resolve 2.11.

### P11 — `dart compile shared-library`: o programa como `.so`/`.dylib`/`.dll`/`.a`

O comando que o desenvolvedor digitaria para obter P2. Hoje `dart compile exe`
junta runtime e programa num executável; a variante geraria o mesmo conjunto
como **biblioteca**, com uma função C de entrada (inicia a VM e roda `main`) e,
opcionalmente, funções Dart exportadas por `@Native`/`NativeCallable`:

```
dart compile shared-library --target-os android --target-arch arm64 \
    lib/main.dart -o build/libapp.so
dart compile shared-library --target-os ios lib/main.dart -o build/App.xcframework
```

- **Android:** a activity faz `System.loadLibrary("app")` e o Dart roda no
  processo do app, com a `ANativeWindow` — sem processo filho, sem cópia por
  quadro, com GPU direta (hoje impossível sem código nativo próprio, seção 2.2);
- **iOS:** o app liga a biblioteca ao executável; sem runtime no papel de
  executável e sem patch (seções 2.3 e 2.5);
- **desktop:** plugins em Dart carregáveis por programas C/C++/Java, pedido antigo
  da comunidade.

### P12 — `dart build android` / `dart build ios`: o pacote da loja num comando

A camada acima de P11: gerar APK/AAB e `.app`/IPA assinados a partir de um
arquivo de configuração (identificador, nome, versão, ícones, permissões,
identidade de assinatura). É o que `tool/android/build_apk.dart` e
`tool/ios/build_app.dart` fazem à mão neste projeto. O lugar natural é o
`dart build`, que o SDK já usa para *native assets*. A configuração de loja é
específica de cada app, e por isso a equipe do Dart pode preferir deixar essa
parte para pacotes — mas o empacotamento mínimo (manifesto, bundle, assinatura
de desenvolvimento) cabe no SDK e tiraria do caminho `gen_snapshot`, `vtool` e
a convenção `lib*.so`. Depende de P1, e de P11 para o Android sair do modelo de
processo.

---

## 4. Como levar ao `dart-lang/sdk`

1. **Issues primeiro**, uma por proposta, com o caso medido deste relatório e os
   números (APK de 3,1 MB em AOT; crash *"Must be called from the main thread"*;
   404 dos artefatos). P1, P2/P11, P3 e P12 são as que pedem decisão da equipe
   do Dart — P11 provavelmente como comentário na discussão já existente sobre
   compilar Dart para biblioteca compartilhada, com o caso mobile como motivo;
   P5, P6, P7 e P9 são mudanças pequenas e podem ir direto como PR.
2. **PRs de P9** já existem em forma de patch:
   `tool/mobile/dart_sdk_patches/3.13.5-ios.patch`. Separar os três ajustes de
   build (P9) do modo de thread principal (P3) antes de enviar.
3. **P3 como protótipo:** o trecho de `main_impl.cc` do patch mostra que o
   modo cabe em ~70 linhas para Apple; falta o `ALooper` para Android e a
   decisão de interface (flag do runtime ou API de embedder).

As issues podem ser escritas em inglês a partir deste texto, no formato das
propostas 02 e 05.
