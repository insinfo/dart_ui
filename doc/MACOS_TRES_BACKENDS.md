# macOS — estratégia de quatro backends

> O arquivo mantém o nome `MACOS_TRES_BACKENDS.md` porque é referenciado por
> nome no código e em outros documentos. Em 13/10/2026 entrou o quarto
> backend, `appkitEmbedded` (seção "Backend 4").

## Decisão

O projeto manterá quatro implementações macOS atrás do mesmo contrato de janela,
input, apresentação e lifecycle. Elas não são três nomes para a mesma técnica:
cada uma tem ownership de thread, risco e finalidade diferentes.

| Backend | Processo principal | API de janela | Main thread | Uso pretendido |
|---|---|---|---|---|
| `skylight` | Dart standalone | SkyLight/CGS privada | não exige thread 0 no caminho medido | laboratório avançado e fallback controlado |
| `appkitSignal` | Dart standalone | AppKit por ObjC runtime | sequestrada por sinal | pesquisa e comparação; nunca default |
| `appkitNativeHost` | executável `.m` | AppKit normal | possuída desde `main()` | caminho recomendado para robustez |
| `appkitEmbedded` | runtime Dart AOT compilado do código-fonte, com patch | AppKit por ObjC runtime, no mesmo processo | do runtime: o isolate principal roda nela, dentro do `CFRunLoop` | `.app` de processo único; escolhido sozinho dentro desse runtime |

Distribuição pela App Store não decide esta matriz. Os critérios são correção,
recuperação após falha, compatibilidade por versão e capacidade de teardown.

## Contrato comum

O código de widgets não pode conhecer qual estratégia está ativa. O adaptador
macOS deverá fornecer, no mínimo:

```dart
enum MacosBackendKind { skylight, appkitSignal, appkitNativeHost, appkitEmbedded }

abstract interface class MacosWindowBackend {
  MacosBackendKind get kind;
  MacosBackendCapabilities get capabilities;

  Future<void> initialize();
  Future<MacosWindow> createWindow(MacosWindowOptions options);
  Stream<MacosInputEvent> get inputEvents;
  Future<void> present(MacosWindow window, MacosFrame frame);
  Future<void> closeWindow(MacosWindow window);
  Future<void> shutdown();
}
```

O contrato concreto deve incluir tokens geracionais para rejeitar callbacks
tardios, estados explícitos (`new`, `initializing`, `running`, `stopping`,
`stopped`, `failed`) e shutdown idempotente.

O contrato, a máquina de estados e os testes dessas invariantes agora vivem em
[`poc/poc_20_macos_three_backends/lib`](https://github.com/insinfo/dart_ui/blob/exploracao-inicial/poc/poc_20_macos_three_backends/lib).
O estado inicial concreto chama-se `created` (equivalente ao `new` conceitual
acima, que é palavra reservada em Dart).

## Backend 1 — SkyLight/CGS

### Evidência já confirmada

- `SLSMainConnectionID` fora da main thread;
- janela via `SLSNewWindow`;
- pixels via `SLWindowContextCreate`/Core Graphics;
- porta via `SLSGetEventPort` + `CFMachPort`;
- input direcionado com `SLEventPostToPid`;
- três eventos obrigatórios no CI: `[10, 11, 5]`.

### macOS 27: conteúdo via Core Animation

Medido em 2026-10-12, numa máquina com macOS 27.2: com a feature
`WindowServer/CAWindowContent` ativa, desenhar por `SLWindowContextCreate` não
chega à tela. A SkyLight atualiza a camada CA do backing store por blocos que
sempre manda para a main queue, e a thread 0 de um processo Dart nunca drena
essa fila. O backend agora detecta a feature e, quando ela está ativa, cria a
janela com tipo 5 (o que o AppKit usa) e hospeda um `CAContext` próprio via
`SLSSetWindowLayerContext`, com `CATransaction` na thread do isolate. Isso
continua sem exigir a thread 0. Para receber cliques físicos, o processo
também precisa de um PSN: `GetCurrentProcess()` (check-in no LaunchServices)
antes de `SLPSRegisterWithServer`. Evidência e procedimento em
[`logs/MACOS27_TRES_BACKENDS_2026-10-12.md`](logs/MACOS27_TRES_BACKENDS_2026-10-12.md).

### Regra de consumo medida

Uma leitura por mensagem **não basta**: o WindowServer agrupa. Três eventos
postados chegaram como duas mensagens Mach, e a leitura única deixou o terceiro
na fila — era essa a razão de o backend receber `keyDown`/`keyUp` mas nunca o
movimento do mouse.

A regra medida é: uma leitura por mensagem dentro do callback, mais leituras
extras **limitadas e fora do callback**, apenas depois de uma fatia do run loop
que entregou algo. O bloqueio histórico acontecia dentro do callback e sem
limite.

### Em `lib/` desde 12/10/2026

`DART_UI_BACKEND=macos-skylight` com `ApplicationOptions.allowExperimentalBackends`
abre o `Application` numa janela SkyLight, sem host e sem AppKit
(`lib/src/backends/macos/skylight/`). O que mudou em relação ao POC:

- **sem CFRunLoop**: o POC instalava a porta de eventos como source no run loop
  da thread atual e não podia fazer `await` até a última fatia, porque o isolate
  pode retomar noutra thread. Em `lib/` a porta é **consultada**:
  `mach_port_get_attributes(MACH_PORT_RECEIVE_STATUS)` diz quantas mensagens há
  sem receber nenhuma, e `SLEventCreateNextEvent` é chamado uma vez por mensagem
  — a mesma regra de consumo, de qualquer thread. Medido em macOS 27: tecla e
  movimento chegam com `await` entre cada consulta;
- janela com barra desenhada pelo framework (`ClientDecoratedWindow`, o mesmo
  `ClientDecorationFrame` do Wayland sem SSD), mover e redimensionar seguindo o
  arraste na própria janela, maximizar para a tela principal;
- **Dock sem AppKit**: `TransformProcessType(psn, kProcessTransformToForegroundApplication)`
  dá ao processo um tile no Dock (passa de `BackgroundOnly` a `Foreground`).
  Minimizar é `CoreDockMinimizeItemWithTitleAsync(windowId, título)` e restaurar
  `CoreDockRestoreItemAsync(windowId)` (HIServices, API privada), sem registrar
  o processo como cliente do Dock — então sem run loop nem callback de outra
  thread. O clique no tile chega como Apple Event `kAEReopenApplication`
  (`'aevt'/'rapp'`) e Sair no menu do tile como `kAEQuitApplication`, na porta
  de `AEGetRegisteredMachPort`, consultada como a porta de eventos e recebida
  com o trailer de auditoria (sem ele `AEProcessMessage` recusa). Uma
  restauração que o Dock faz sozinho é notada por `SLSWindowIsOrderedIn`,
  depois de a janela ter saído da tela (ela continua na tela durante o efeito
  de minimizar);
- no caminho CoreGraphics (macOS 14) crescer a janela **a substitui** por uma do
  novo tamanho, no mesmo lugar e ordem: a janela com backing store
  redimensionada por `SLSSetWindowShape` mantém o backing store antigo e o
  quadro maior escrevia além dele (SIGSEGV em `CGContextDrawImage`, mesmo com
  contexto novo). `DART_UI_SKYLIGHT_CG=1` força esse caminho num Mac que
  hospedaria camada;
- apresentação CPU própria (`macos-cpu`, compatível só com `macos-skylight` e
  `macos-appkit-signal`),
  a `CGImage` do framebuffer posta na `CALayer` hospedada; o Metal e o caminho
  de IOSurface recusam essas janelas pelo nome;
- teclado com texto (`CGEventKeyboardGetUnicodeString`), mouse, roda e
  modificadores pelas mesmas tabelas do host nativo.

`tool/macos_skylight_smoke.dart` prova janela, pixels de fora
(`screencapture -l`), clique, digitação com acento, mover, maximizar,
minimizar para o Dock e voltar pelo `'rapp'` enviado de outro processo (como o
Dock envia) e o botão de fechar, com input postado pelo WindowServer
(`SLEventPostToPid`).

A barra de menus continua fora: o Menu Manager do HIToolbox cria menus em 64
bits, mas a barra não muda sem AppKit; o caminho seria publicar janelas-imagem
com `SLSSetMenuBars`, cujo dicionário não está documentado.

### Trabalho restante

- ~~extrair o código de `probe.dart` para tipos pequenos com ownership
  explícito~~ — feito em
  [`skylight_backend.dart`](https://github.com/insinfo/dart_ui/blob/exploracao-inicial/poc/poc_20_macos_three_backends/lib/src/skylight_backend.dart);
- ~~invalidar e liberar source, Mach port, callbacks, regions, contexts e
  janelas em ordem inversa~~ — medido:
  `CGContextRelease → SLSReleaseWindow → CGSReleaseRegion →
  CFRunLoopRemoveSource → CFRelease(source) → CFMachPortInvalidate+CFRelease →
  NativeCallable.close`, sem símbolo faltando;
- input **físico** (só provado com eventos postados ao processo), IME,
  acessibilidade, clipboard, cursores e drag-and-drop;
- reconciliação após Spaces, fullscreen, monitores, sleep/wake e WindowServer
  restart;
- tabela de símbolos/ABIs por versão do macOS e falha rápida quando incompatível.

## Backend 2 — AppKit com signal hijack

### O que ele demonstra

O processo Dart mantém a thread 0 estacionada no launcher. O probe instala
`CFRunLoopRun` como handler de `SIGUSR2`, sinaliza a thread principal e passa a
enfileirar trabalho AppKit nela. Isso já criou uma `NSWindow` real e manteve o
runtime Dart ativo.

### Por que é experimental e inseguro

- `CFRunLoopRun` não é async-signal-safe;
- o handler não estabelece um frame normal de entrada do AppKit;
- `[NSApp run]` e alguns pumps produziram traps/crashes;
- os probes históricos usam `_exit`; o probe de lifecycle agora testa
  `CFRunLoopRemoveSource` + `CFRunLoopStop` + `CFRunLoopWakeUp` para devolver a
  thread 0 ao frame do launcher e permitir shutdown normal;
- bibliotecas do processo podem disputar o mesmo sinal;
- não há contrato do Dart que preserve o estado estacionado da thread 0.

Esse backend deve exigir opção explícita, emitir diagnóstico visível e nunca
ser escolhido automaticamente. Seu valor é comparar comportamento AppKit e
testar APIs enquanto o SDK não oferece takeover suportado da process main
thread.

### Em `lib/` desde 12/10/2026

`DART_UI_BACKEND=macos-appkit-signal` com `allowExperimentalBackends` abre o
`Application` numa `NSWindow` de verdade, criada neste processo
(`lib/src/backends/macos/appkit_signal/`): barra, botões e redimensionar do
próprio AppKit, conteúdo desenhado pelo framework como `CGImage` no layer da
view. Cinco coisas que o POC não precisava e o framework precisa, todas
achadas por crash ou travamento medidos aqui:

- **sem marcador atrás da chamada**: AppKit gira o run loop dentro de
  `nextEventMatchingMask:`, e um marcador enfileirado depois da chamada rodava
  *aninhado*, antes de ela terminar — o lado Dart reusava buffers que a thread 0
  ainda usava e o heap quebrava em `-[NSInvocation setArgument:]`. Agora cada
  chamada é `waitUntilDone:YES`, e o risco que o marcador cobria (o loop parado
  por fora com uma chamada na fila) é de um **isolate vigia**: outra thread que,
  enquanto há chamada em voo, olha `CFRunLoopCopyCurrentMode(main)` e reestaciona
  a thread 0 quando o loop não está rodando em duas olhadas seguidas;
- **`-[NSEvent characters]` na thread principal**: ele consulta a fonte de
  entrada do teclado (teclas mortas) e o HIToolbox exige a fila principal;
  chamado da thread do Dart, aborta;
- **ativação**: um processo lançado por outro em segundo plano (terminal,
  editor) tem `activateIgnoringOtherApps:` recusado, e um app inativo perde o
  clique; `_SLPSSetFrontProcessWithOptions(…, kCPSUserGenerated)` o traz para
  frente, como o Dock faz;
- **eventos sem janela**: um evento postado ao processo chega com
  `windowNumber` 0; é refeito por `mouseEventWithType:…windowNumber:` para a
  janela sob o ponto, como um clique ali teria sido;
- **encerramento**: depois do `dispose` nenhuma chamada espera a thread 0
  (ela está de volta no `Dart_RunLoop` e nada roda a fila — era um travamento),
  e o `NativeCallable.listener` do botão fechar não segura o isolate.

O botão vermelho, Cmd+W e Janela > Fechar chegam como `performClose:` numa
subclasse criada em tempo de execução, que **pede** o fechamento ao framework em
vez de fechar. Um clique postado no próprio botão ou na barra roda dentro do
loop de rastreamento do AppKit, que vê o evento cru sem janela: só input real ou
permissão de Acessibilidade alcança esse caminho, e o smoke manda
`performClose:` direto.

`tool/macos_appkit_signal_smoke.dart` prova janela, captura de fora, clique,
digitação com acento, maximizar/restaurar (`zoom:`) e o pedido de fechar, e o
processo sai sozinho com status 0 — em macOS 27 aqui e no macOS 14 do runner
(CI de 12/10/2026, commit `b0b5fa7`).

O clique do smoke entra na fila do próprio AppKit (`postEvent:atStart:`),
endereçado à janela. Postado ao processo pelo WindowServer ele chega **sem
janela**, e no macOS 14 a `NSMenuBarTrackingSession` toma esse press dentro de
`nextEventMatchingMask:` e roda o loop de menu esperando o próximo clique — a
amostra (`sample`) do CI mostrou a thread do Dart presa no
`performSelectorOnMainThread:waitUntilDone:` dessa leitura. Um clique real traz
a janela e não cai nisso.

O mesmo vale como limite para input real: um loop aninhado do AppKit (menu da
barra aberto, arraste da barra de título) roda **dentro** da chamada de leitura
de eventos, e a thread do Dart espera até ele terminar — o framework não pinta
enquanto o menu está aberto. O watchdog só reestaciona a thread principal
quando o run loop dela parou, não dentro de um loop aninhado. O passo do CI
amostra as pilhas se o smoke passar de 90 s, para um travamento novo vir com
diagnóstico.

### Investigação LLDB do lifecycle

O CI interrompe em `CFRunLoopRun` na thread principal, registra todas as
threads e usa `thread step-out` enquanto o isolate solicita o stop. Isso permite
distinguir três resultados: retorno ao frame interrompido, trap durante o
unwind ou run loop que nunca retorna. O teste funcional exige também que o
processo chegue a `NORMAL_SHUTDOWN=PASS` e saia sem chamar `_exit`.

No run arm64 de 2026-08-07 isso foi confirmado: o step-out voltou de
`CFRunLoopRun` para `_sigtramp`, depois para o `pthread_cond_wait` de
`Dart_RunLoop`, e o processo saiu com status 0. O trace e seus limites estão em
[`logs/MACOS_SIGNAL_HIJACK_LLDB_2026-08-07.md`](logs/MACOS_SIGNAL_HIJACK_LLDB_2026-08-07.md).

### Pump e cadeia de responders — resolvidos

O diagnóstico de bloqueio no `nextEventMatchingMask` foi superado. O pump
periódico não bloqueia: na conformidade ele retira 5 `NSEvent` injetados via
`SLEventPostToPid` enquanto um timer testemunha continua disparando
(`PUMP_LIVENESS=PASS`).

O input é medido em duas metades porque só uma pode ser feita sem corrida a
partir de Dart puro:

- **dispatch** — um `NSEvent` criado e retido por nós passa por
  `[NSApp sendEvent:]` e chega em `keyDown:` da janela (`RESPONDER_INPUT=1`);
- **fila** — eventos injetados pelo WindowServer são retirados pelo pump
  (`INPUT_EVENTS=5`).

Reenviar um evento *bombeado* não é seguro: `nextEventMatchingMask:` devolve um
`NSEvent` autoreleased que o pool da iteração do run loop pode drenar antes de o
isolate retê-lo, e Dart não tem como fazer o retain na main thread sem um método
Objective-C próprio.

O teardown tem uma regra descoberta por `sample(1)`: depois que o run loop
sequestrado para, a main queue não tem quem a drene, então nenhuma chamada com
`waitUntilDone:YES` pode acontecer a partir daí. `orderOut:` assíncrono antes do
stop; nunca `[window close]` bloqueante depois.

## Backend 3 — host Objective-C mínimo

### Limite correto

O executável `.m` é o `main()` real. Ele cria `NSApplication`, instala delegate,
abre a janela e entra em `[NSApp run]` normalmente. Carregar uma dylib `.m` por
FFI dentro do executável Dart **não** resolve o problema: o código continuaria
sem possuir a thread 0 desde o início do processo.

O witness inicial está em
[`poc/poc_20_macos_three_backends/native/minimal_appkit_host.m`](https://github.com/insinfo/dart_ui/blob/exploracao-inicial/poc/poc_20_macos_three_backends/native/minimal_appkit_host.m).
O protocolo stdin/stdout está na versão 2 e já transporta os dois sentidos:

| Comando | Direção | Efeito |
|---|---|---|
| `PING` | Dart → host | responde `PONG` |
| `SET_TITLE <texto>` | Dart → host | título alterado na main queue |
| `FRAME <w> <h> <bytes>` | Dart → host | seguido dos octetos BGRA crus; responde `FRAME_OK <n>` |
| `CLOSE` | Dart → host | `[NSApp terminate:]`, teardown ordenado |
| `INPUT=<kind>:<x>:<y>:<key>` | host → Dart | todo `NSEvent` que a aplicação retira da fila |
| `VIEW_INPUT=<kind>:<x>:<y>` | host → Dart | o mesmo evento, visto pela cadeia de responders |

Os octetos crus existem porque base64 estouraria qualquer buffer de linha
razoável para um frame 480x320. O input é reportado duas vezes de propósito: o
monitor local é o gate, e `VIEW_INPUT` prova que o evento foi roteado até uma
view. O Dart injeta em `SLEventPostToPid(pid_do_host)`, o que também demonstra
essa API dirigindo um segundo processo.

### A escolha entre embedder e worker — decidida por medição

O spike está feito. Detalhes e números em
[`logs/DECISAO_EMBEDDER_VS_WORKER_2026-08-08.md`](logs/DECISAO_EMBEDDER_VS_WORKER_2026-08-08.md).

**Embedder no mesmo processo: indisponível com SDK de release.** O SDK
distribui `include/dart_api.h` mas nenhum `libdart` linkável; os 295–298
símbolos `Dart_*` vivem dentro de `dart`/`dartaotruntime`. Um `main()` nativo
que referencia `Dart_Initialize` não linka (`EMBEDDER_FEASIBLE=0`). Os
cabeçalhos servem ao caminho inverso — código nativo carregado *dentro* do
processo Dart. Hospedar a VM exige compilar o SDK do código-fonte.

**Worker com transporte melhor: medido.** Mesmo host, mesma janela, frame
480×320 BGRA, 120 frames:

Mínimos por tamanho de frame (o tamanho é o que separa os transportes):

| tamanho | bytes/frame | `pipe` (µs) | `shm` (µs) | `iosurface` (µs) | ganho |
|---|---|---|---|---|---|
| 480×320 | 614 KB | 975 | 831 | **66** | 14,8× |
| 1920×1080 | 8,3 MB | 14 361 | 10 363 | **107** | 134× |
| 3840×2160 | 33 MB | 56 092 | 45 202 | **130** | 431× |

Três leituras:

1. **`iosurface` é plano.** O frame cresce 54× e o custo sobe 2×: nada no
   caminho de apresentação é por pixel.
2. **`pipe` e `shm` escalam com os bytes** e estouram o orçamento de 60 Hz já em
   1080p (86% e 62% de 16 667 µs). Em 4K, ~16 fps.
3. **`shm` fica 1,2–1,4× à frente do `pipe` em todos os tamanhos.** Se a cópia
   fosse o gargalo essa razão cresceria; como não cresce, o custo dominante é o
   `CGImage` por frame mais o upload do CoreAnimation — por pixel, e intocados
   pelo `shm`.

A fronteira de processo custa 22–59 µs em qualquer resolução, ou **~0,2% de um
frame a 60 Hz**. É tudo o que um embedder poderia recuperar.

No sentido inverso — input — a viagem ponta a ponta mede 824 µs de mediana, dos
quais 95 µs são a fronteira (11,5%); o resto é entrega do WindowServer até a
fila do AppKit, que nenhuma das arquiteturas muda.

**Decisão: Dart como processo worker, `IOSurface` para frames e pipe para
controle.** Reabrir se o alvo for 120 Hz com orçamento apertado, se o SDK já
precisar ser compilado por outro motivo, ou se input exigir latência abaixo de
1 ms ponta a ponta.

## Backend 4 — AppKit embutido (`appkitEmbedded`)

### Decisão

O caminho do iOS (ADR 0010, `RELATORIO_DART_PURO_ANDROID_IOS.md`) aplicado ao
macOS: o executável do `.app` **é** o `dartaotruntime` compilado do código-fonte
do Dart SDK 3.13.5 com um patch, o programa é um snapshot Mach-O em
`Contents/Frameworks/App.framework`, e o Dart é **convidado** do run loop do
aplicativo. Um processo só para todas as janelas: menu e submenu são janelas
filhas (`addChildWindow:ordered:`) da dona, a ordem z e o movimento seguem a
dona, e abrir um menu custa uma janela, não um processo. Sem Flutter em nenhuma
forma; sem sinal; sem SkyLight; sem segundo processo.

Não substitui o default: fora desse runtime o probe falha com o motivo e a
seleção cai no `appkitNativeHost`, como antes.

### Como funciona

O patch (`tool/mobile/dart_sdk_patches/3.13.5-macos.patch`, aplicado por cima
do de iOS; todo bloco sob `DART_HOST_OS_MACOS && !DART_HOST_OS_IOS`):

1. `main.cc`: sem snapshot na linha de comando e com
   `../Frameworks/App.framework/App` ao lado do executável — aberto pelo
   Finder, por `open` ou rodando `Contents/MacOS/X` direto — usa esse
   snapshot, repassa os outros argumentos ao programa (sem o `-psn_` antigo) e
   liga o modo thread principal. `DART_UI_MAIN_THREAD_LOOP=1` liga o modo para
   um snapshot avulso (`dartaotruntime app.dylib`), útil para depurar.
2. `main_impl.cc`: `Dart_SetMessageNotifyCallback` sinaliza uma
   `CFRunLoopSource` do run loop principal, nos *common modes* (mensagens
   continuam durante live resize e tracking de menu); o `perform` dela chama
   `Dart_HandleMessage` com o isolate sempre entrado na thread 0. Não é
   reentrante: um loop aninhado dentro de uma mensagem adia as mensagens para o
   turno de fora, que sinaliza a fonte de novo.
3. Depois do `main()`, o runtime gira o run loop até o programa não ter mais
   portas vivas — a mesma regra de término do `dart` standalone (código de
   saída, `exitCode`, exceção não tratada = 255, tudo igual). Quando o Dart
   chama `Dart_DartUiRunApplication()`, o runtime roda `[NSApp run]` nesse
   loop; quando a última porta fecha, `[NSApp stop:]` e um evento vazio fazem o
   `run` voltar e o processo termina pelo caminho normal.
4. Dois símbolos exportados (o executável só exporta `Dart_*`):
   `Dart_DartUiMainThreadLoop` (1 no modo) e `Dart_DartUiRunApplication`.
5. Em modo app o processo mantém o nome do bundle no Dock e no Monitor de
   Atividade (o runtime padrão o renomearia para `dart:App`).

O lado Dart (`lib/src/backends/macos/embedded/`):

- `embedded_runtime.dart`: detecção pelo símbolo + `pthread_main_np`. O
  resolver põe a entrada `macos-embedded` **antes** de `macos`; o probe só passa
  dentro do runtime, então a escolha é automática lá e nunca em outro lugar.
- `embedded_appkit.dart`: classes registradas em runtime — `DartUiEmbeddedView`
  (`NSView`, eventos de mouse/teclado/scroll, `acceptsFirstMouse:`),
  `DartUiEmbeddedWindow` e `DartUiEmbeddedPanel` (menus: `NSPanel`
  não-ativante que nunca vira key), delegate de janela e de aplicação. Cada
  método é um `NativeCallable.isolateLocal` com `keepIsolateAlive = false`: o
  AppKit chama o Dart sincronamente, na mesma thread.
- `embedded_backend.dart`: `NSApplication` (política regular, menu Hide/Quit e
  Window), `EventLoopWaitingBackend` — o `pumpEvents` nunca bloqueia, o loop da
  aplicação espera com `await`. Depois de cada callback do AppKit o backend
  manda uma mensagem vazia a si mesmo (coalescida): é a solução do problema 2.4
  do relatório (microtasks paradas depois de um callback nativo), a mesma do
  iOS. `ScreenProvider` por `NSScreen`. Cmd+Q pede o fechamento das janelas
  (`applicationShouldTerminate:` responde *Cancel*), e o programa termina
  quando elas fecham.
- `embedded_window.dart`: `NSWindow`/`NSPanel` com a view de conteúdo
  layer-backed. GPU primeiro: os pixels são o mesmo pool de `IOSurface`
  (`surface_pool.dart`) do host nativo, e a janela implementa
  `MacosSurfaceHost` — o caminho `metal` do resolver desenha nas `IOSurface`s e
  o "present" é `layer.contents = IOSurface` do slot de trás (sem cópia, sem
  pipe). Sem Metal, `macos-embedded-iosurface` rasteriza na CPU direto na
  `IOSurface`. Também: `HiddenTitleBarWindow` (botões do sistema, arrastar pela
  área do título), `WindowStateControl`, `ActivatableWindow`, e
  `synthesizeInput` com a gramática `SYNTH_MOUSE`/`SYNTH_KEY`/`SYNTH_POINTER`
  do host, postando `NSEvent`s na fila do próprio AppKit (sem permissão de
  acessibilidade). `DART_UI_EMBEDDED_TRACE=1` imprime cada evento.

Código compartilhado, extraído em vez de copiado: `apple/cocoa_ffi.dart`
(structs CG, sends com struct, `NSString`, `CGImage`; o iOS reexporta) e
`appkit_event_decoding.dart` (`decodeNSEvent`, antes no `appkit_signal`).

### Como gerar

```
dart run tool/macos/build_app.dart examples/file_explorer/bin/file_explorer.dart \
    -o build/FileExplorer.app [--name "File Explorer"] [--icon icon.png] [--run]
```

O script acha o checkout (`--checkout`, `DART_UI_DART_SDK_SRC` ou um
`dart-sdk-src` ao lado da pasta do repositório), compila o runtime se faltar ou
estiver velho (`tool/mobile/build_dart_runtime.dart --target macos-arm64`; ~7
min na primeira vez num M4, com `DEVELOPER_DIR` apontado para o Xcode que achar),
compila o kernel com o Dart 3.13.5 do host (`--dart`, `DART_UI_MACOS_DART`,
`DART_UI_IOS_DART` ou `DartSDKs/3.13.5-macos` ao lado do checkout), gera o
snapshot com o `gen_snapshot` do mesmo build, monta o bundle e assina ad hoc. O
mesmo pelo CLI, com o toolchain no ambiente:
`dart run dart_ui build <entry> --macos-backend=embedded`.

```
X.app/Contents/Info.plist                        sem LSUIElement
X.app/Contents/MacOS/X                           o dartaotruntime com patch
X.app/Contents/Frameworks/App.framework/App      -> Versions/Current/App (snapshot)
```

### Verificado em 13/10/2026 (Mac mini M4, macOS 27.2)

Com `tool/macos/embedded_demo.dart` (`DART_UI_EMBEDDED_PROBE=<pasta>`, que se
dirige sozinho) e `examples/file_explorer/tool/macos_embedded_popup_probe.dart`:

- backend `macos-embedded`, apresentação `metal`; janela capturada por
  `screencapture -l` e listada por `CGWindowListCopyWindowInfo` com o nome do
  bundle como dono;
- clique sintético no botão: contador 0 → 1, quadros novos apresentados;
- botão direito: menu aberto em 6–10 ms (host nativo: 243 ms frio, 65 ms com
  processo reserva), `parentWindow` do menu = janela principal; hover em
  "Exibir": submenu em 5–9 ms, `parentWindow` = menu, colado à direita do menu
  (`gap x=0`) e alinhado à linha; `CGWindowList`: submenu > menu > principal,
  contíguos, nível normal — a ordem z segue a dona;
- explorer: título oculto com os botões do sistema no lugar, menu de contexto
  e submenu "Exibir" como janelas filhas, transparentes e com sombra;
- `performClose:` (botão vermelho) e Quit pelo AppleScript fecham a janela e
  o processo termina com código 0, aberto por `open` ou direto;
- partida até o primeiro quadro (mediana de 7, mesmo demo, `Contents/MacOS/X`
  direto): **275 ms** embutido contra **406 ms** com o host nativo
  (`dart compile exe` + host `.m`).

### Limitações

- só macOS arm64 (os sends que devolvem `CGRect` contam com o ABI de arm64);
- sem IME (`NSTextInputClient`), área de transferência, arrastar e soltar,
  acessibilidade e barra de menu nativa da aplicação — o texto digitado chega
  pelos caracteres do `keyDown:`; esses recursos vivem hoje no host `.m` e
  precisam ser portados para cá;
- sem `LiveResizeWindow`: durante o live resize as mensagens continuam
  fluindo (common modes) e o quadro novo chega no turno seguinte, mas não é
  desenhado de dentro do `windowDidResize:`; não medido com arrasto real;
- sem pacing por vsync (`CVDisplayLink`/`CADisplayLink`) no present;
- a versão do runtime, do `gen_snapshot` e do kernel é amarrada (3.13.5);
- um callback do AppKit que entre num loop modal aninhado *de dentro* de Dart
  adia as mensagens Dart até o loop sair (por desenho, para não reentrar).

### Estado em 13/10/2026 e pendências

Existe e foi provado: patch do runtime, `tool/macos/build_app.dart` e
`dart_ui build --macos-backend=embedded`, o backend em
`lib/src/backends/macos/embedded/`, seleção automática só dentro do runtime,
Metal e CPU em `IOSurface`, menus/submenus como janelas filhas, fechamento e
término do processo. Testes: `test/backends/macos/macos_embedded_test.dart` e
`test/tooling/macos_embedded_bundle_test.dart` (rodam sem o checkout do SDK).

Pendente, em ordem:

1. IME (`NSTextInputClient` na `DartUiEmbeddedView`), área de transferência
   (`NSPasteboard`), arrastar e soltar e acessibilidade — portar do host `.m`;
2. barra de menu nativa da aplicação (`NativeMenuBarWindow`);
3. `LiveResizeWindow` e pacing por vsync; medir live resize com arrasto real;
4. CI: compilar o runtime (ou baixar um artefato) e rodar
   `tool/macos/embedded_demo.dart` com `DART_UI_EMBEDDED_PROBE`;
5. hardened runtime + notarização com o framework do snapshot (só ad hoc foi
   testado).

Achado de passagem, que não é deste backend: um clique num item de
**submenu** fecha a cadeia sem chamar `onPressed` — igual no host nativo
(mesmo probe nos dois). Suspeita: `MenuItemButton` lê `widget.onPressed`
depois de `closeChain()` desmontar o próprio item (`menu_anchor.dart`).

## Seleção e fallback

Ordem recomendada inicialmente:

0. `appkitEmbedded`, automaticamente e só dentro do runtime embutido (`.app`
   gerado por `tool/macos/build_app.dart`);
1. `appkitNativeHost`, quando o aplicativo aceitar artefato nativo;
2. `skylight`, quando for exigido executável Dart standalone e a versão tiver
   ABI validado;
3. `appkitSignal` somente com flag de laboratório.

Fallback não pode ser silencioso. O relatório deve registrar backend pedido,
backend escolhido, versão/build do macOS, símbolos encontrados, resultado do
registro de processo, permissões relevantes e motivo exato da rejeição.

## Critérios comparáveis

### Suíte comum — já executando no CI

Os três backends respondem às mesmas seis linhas, e as quatro etapas que as
verificam são gates (nenhuma é `continue-on-error`):

```text
WINDOW_ID=<n>                     o WindowServer possui uma janela
PRESENT=PASS                      um framebuffer BGRA de CPU chegou nela
PIXEL_WITNESS=PASS centre=r,g,b   outro processo fotografou o frame
INPUT_EVENTS=<n>                  input chegou pela rota real de eventos
TEARDOWN=PASS                     todo handle liberado, sem _exit
CONFORMANCE=PASS                  tudo acima, com main() retornando 0
```

O `PIXEL_WITNESS` é a única linha que nenhum backend consegue auto-reportar:
`screencapture -l<CGSWindowID>` só devolve pixels se o WindowServer realmente
tiver aquela janela. Cada backend pinta uma cor distinta, então uma captura
antiga não passa por frame novo.

Medição de 2026-08-08, run `31244960783`, macos-14 arm64
([log completo](logs/CONFORMANCE_TRES_BACKENDS_2026-08-08.md)):

| backend | janela | present | pixel central (esperado) | input | teardown | exit |
|---|---|---|---|---|---|---|
| `skylight` | 38 | PASS | `19,120,220` (`20,120,220`) | 4 | PASS | 0 |
| `appkitSignal` | 47 | PASS | `120,220,20` (`120,220,20`) | 5 | PASS | 0 |
| `appkitNativeHost` | 39 | PASS | `220,120,20` (`220,120,20`) | 3 | PASS | 0 |

O backend 2 também comprova a cadeia de responders (`RESPONDER_INPUT=1`) e o
backend 3 comprova o roteamento até a view (`VIEW_INPUT_EVENTS=3`).

### Ainda fora da suíte

- criar, redimensionar e fechar **duas** janelas;
- Metal além do framebuffer de CPU;
- scroll, foco e captura;
- timer/frame pacing e latência input→frame;
- fullscreen/Spaces, dois monitores e mudança de escala;
- sleep/wake e restart do processo auxiliar, quando existir.

## Sequência de implementação

1. ~~CI do witness `.m` e captura de `MAIN_THREAD=1`/`WINDOW_ID`~~;
2. ~~interface Dart e capability report sem selecionar backend automaticamente~~;
3. ~~extração do SkyLight funcional para código reutilizável~~
   ([`skylight_backend.dart`](https://github.com/insinfo/dart_ui/blob/exploracao-inicial/poc/poc_20_macos_three_backends/lib/src/skylight_backend.dart));
4. ~~suíte comum de janela, present, pixels, input e teardown nos três~~;
5. encapsulamento do signal hijack com opt-in e watchdog;
6. spike embedder-vs-IPC do host `.m`;
7. counter comum nos três backends;
8. matriz de robustez restante e decisão do default.
