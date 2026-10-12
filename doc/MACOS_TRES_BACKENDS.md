# macOS — estratégia de três backends

## Decisão

O projeto manterá três implementações macOS atrás do mesmo contrato de janela,
input, apresentação e lifecycle. Elas não são três nomes para a mesma técnica:
cada uma tem ownership de thread, risco e finalidade diferentes.

| Backend | Processo principal | API de janela | Main thread | Uso pretendido |
|---|---|---|---|---|
| `skylight` | Dart standalone | SkyLight/CGS privada | não exige thread 0 no caminho medido | laboratório avançado e fallback controlado |
| `appkitSignal` | Dart standalone | AppKit por ObjC runtime | sequestrada por sinal | pesquisa e comparação; nunca default |
| `appkitNativeHost` | executável `.m` | AppKit normal | possuída desde `main()` | caminho recomendado para robustez |

Distribuição pela App Store não decide esta matriz. Os critérios são correção,
recuperação após falha, compatibilidade por versão e capacidade de teardown.

## Contrato comum

O código de widgets não pode conhecer qual estratégia está ativa. O adaptador
macOS deverá fornecer, no mínimo:

```dart
enum MacosBackendKind { skylight, appkitSignal, appkitNativeHost }

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
[`poc/poc_20_macos_three_backends/lib`](../poc/poc_20_macos_three_backends/lib).
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
  [`skylight_backend.dart`](../poc/poc_20_macos_three_backends/lib/src/skylight_backend.dart);
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
[`poc/poc_20_macos_three_backends/native/minimal_appkit_host.m`](../poc/poc_20_macos_three_backends/native/minimal_appkit_host.m).
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

## Seleção e fallback

Ordem recomendada inicialmente:

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
   ([`skylight_backend.dart`](../poc/poc_20_macos_three_backends/lib/src/skylight_backend.dart));
4. ~~suíte comum de janela, present, pixels, input e teardown nos três~~;
5. encapsulamento do signal hijack com opt-in e watchdog;
6. spike embedder-vs-IPC do host `.m`;
7. counter comum nos três backends;
8. matriz de robustez restante e decisão do default.
