# macOS 27 — três backends lado a lado: diagnóstico e correções

Data: 2026-10-12
Máquina: Mac mini (Apple Silicon), macOS 27.2 (26B5101f), tela 1920×1080
Dart: 3.6.2 (`dart compile exe`)
Depuradores: `/usr/bin/lldb` (lldb-2103, Apple) e LLVM 22.1.8 em
`/Volumes/SSD Dock/llvm/LLVM-22.1.8-macOS-ARM64/bin/lldb`

Até esta data, a suíte comum dos três backends tinha sido medida só no CI
(`macos-14`). Rodar os três ao mesmo tempo numa máquina real com macOS 27
expôs cinco problemas. Três são bugs nossos, e dois são mudanças do sistema
que deixavam o backend 1 invisível e surdo a cliques. Este documento registra
cada um com a evidência e a correção.

**Estado final, medido nesta máquina:** `CONFORMANCE=PASS` nos três backends
(janela, present, pixel visto por fora, input e teardown sem `_exit`).

| # | Sintoma | Causa | Correção |
|---|---|---|---|
| 1 | Não dava para saber qual janela era de qual backend | Mesma cor (SkyLight e host nativo pintavam azul), janelas sobrepostas e sem título | Showcase: cor, número, nome, PID e id da janela pintados no frame, uma coluna por backend |
| 2 | O host nativo (backend 3) crashava ao fechar a janela | `NSWindow` sob ARC com `releasedWhenClosed = YES` | `releasedWhenClosed = NO` |
| 3 | O backend 2 travava e ignorava cliques | O run loop sequestrado era parado por uma animação do AppKit, e os eventos eram descartados | Re-estacionar a thread 0 e despachar eventos com `sendEvent:` |
| 4 | A janela SkyLight (backend 1) ficava transparente | macOS 27: conteúdo de janela via Core Animation, atualizado só pela main queue | Janela tipo 5 com `CAContext` próprio (`SLSSetWindowLayerContext`) |
| 5 | Cliques físicos não chegavam à janela SkyLight | O processo não tinha PSN (sem check-in no LaunchServices) | `GetCurrentProcess()` antes de `SLPSRegisterWithServer` e um X pintado no frame que fecha a janela |

Como reproduzir tudo:

```bash
poc/poc_20_macos_three_backends/tool/run_showcase.sh      # Ctrl+C fecha os três
poc/poc_20_macos_three_backends/tool/run_showcase.sh 30   # fecha em 30 s
```

## 1. Identificação das janelas

As três janelas abriam em posições fixas que se sobrepunham. A janela SkyLight
(sem moldura, em 400,400) ficava inteira atrás da janela 800×600 do
`hold-appkit`. Além disso, o host nativo e o SkyLight usavam praticamente o
mesmo azul.

Correção em
[`showcase.dart`](../../poc/poc_20_macos_three_backends/lib/src/showcase.dart):

- **Identidade:** um `ShowcaseSpec` por backend, com número, nome, título,
  linhas de descrição, a cor da suíte de conformidade (azul `20,120,220`,
  verde `120,220,20`, laranja `220,120,20`) e a coluna (`left = 40 + 520·(n−1)`,
  `top = 120`).
- **Rótulo no frame:** o texto é desenhado no próprio frame BGRA, com uma fonte
  bitmap 5×7. É o único lugar onde os três conseguem mostrar texto, já que a
  janela SkyLight não tem barra de título. O rodapé mostra `PID` e `JANELA`.

Posicionamento medido pelo `CGWindowListCopyWindowInfo`:

| Backend | Bounds (top-left global) |
|---|---|
| 1 SkyLight | `40,120 480x320` |
| 2 AppKit signal | `560,92 480x348` (conteúdo em y=120 abaixo da barra de título) |
| 3 Host nativo | `1080,88 480x352` |

Dois detalhes medidos no caminho:

- **Argumentos de origem do `SLSNewWindow` não posicionam a janela.** Com
  região em 200,200 e origem 200,200, a janela ia para 400,400. Com região em 0
  e origem 40,120, ia para 0,0. A posição explícita agora é dada por
  `SLSMoveWindow`, que é uma exportação estável.
- **AppKit mede a partir da base da tela.** O host `.m` (`--top-left X,Y`) e o
  backend 2 convertem com a altura da tela principal (`NSScreen` ou
  `CGDisplayBounds`).

## 2. Backend 3 — crash ao fechar a janela

O relatório `~/Library/Logs/DiagnosticReports/backend3_native_host-…ips` mostrou:

```
EXC_BAD_ACCESS (SIGSEGV) KERN_INVALID_ADDRESS
libobjc.A.dylib  objc_retain + 16
backend3_native_host  -[DartUiMinimalAppDelegate applicationWillTerminate:] + 492
AppKit  -[NSApplication terminate:]
AppKit  __79-[NSApplication(NSWindowCache) _scheduleCheckForTerminateAfterLastWindowClosed]_block_invoke
```

Pelo disassembly, o offset +492 vem logo depois de
`objc_retainAutoreleasedReturnValue` sobre `self.window`, ou seja, na linha
`[self.window orderOut:nil]`. A janela já tinha sido desalocada, embora
`self.window` seja uma propriedade `strong`. `NSWindow` usa
`releasedWhenClosed = YES` por padrão, e isso é uma liberação a mais sob ARC.

A correção é `self.window.releasedWhenClosed = NO;` em
[`minimal_appkit_host.m`](../../poc/poc_20_macos_three_backends/native/minimal_appkit_host.m).

Limite da evidência: o crash dependia de quando a memória era reaproveitada.
Nem `performClose:` nem `performClick:` com `NSZombieEnabled` o reproduziram, e
o clique sintético não chega nesta máquina (seção 5). A correção vem do crash
report e do disassembly. Ela é a prática documentada para janelas criadas
programaticamente sob ARC.

O host também ganhou:

- **Cor própria:** fundo laranja, igual à da conformidade.
- **Argumentos novos:** `--title` e `--top-left`.
- **Build:** o comando no README passou a exigir `-framework QuartzCore
  -framework IOSurface`, porque o `.m` usa `CATransaction`, `kCAFilterNearest`
  e `IOSurfaceLookup`.

## 3. Backend 2 — run loop parado por fora e eventos descartados

### 3.1 O `hold-appkit` jogava fora todos os eventos

O pump chamava `nextEventMatchingMask:…dequeue:YES` e nunca `sendEvent:`.
Cliques, arrastes e o botão de fechar eram retirados da fila e descartados. A
janela também não tinha título.

### 3.2 Travamento: `CFRunLoopStop` vindo de uma animação do AppKit

O novo modo `probe showcase-signal` travava logo depois de abrir a janela.
`sample(1)` mostrou a thread 0 de volta ao `Dart_RunLoop`
(`_pthread_cond_wait`), enquanto o isolate esperava um
`performSelectorOnMainThread:…waitUntilDone:YES`. Com breakpoint em
`CFRunLoopStop`, o lldb mostrou:

```
CoreFoundation`CFRunLoopStop
CoreFoundation`__CFRUNLOOP_IS_CALLING_OUT_TO_A_BLOCK__
CoreFoundation`__CFRunLoopDoBlocks
CoreFoundation`__CFRunLoopRun
HIToolbox`RunCurrentEventLoopInMode
…
AppKit`-[NSApplication(NSEventRouting) nextEventMatchingMask:untilDate:inMode:dequeue:]
```

O bloco vem de `-[NSAnimation _runBlocking]`, numa thread do libdispatch. Ele
roda dentro do loop aninhado do `nextEventMatchingMask:` com `distantPast`.
Esse loop termina por timeout antes de consumir a flag de parada, e a flag
sobra para o `CFRunLoopRun` externo, que é o que o `SIGUSR2` iniciou. A thread
0 volta para o launcher, e qualquer espera síncrona trava para sempre.

O handler de sinal é o próprio `CFRunLoopRun`, então não dá para fazê-lo
rodar em loop. A correção fica em `_invokeOnMainReparking` em
[`probe.dart`](../../poc/poc_03_appkit_window/bin/probe.dart):

1. cada chamada é agendada sem esperar (`waitUntilDone:NO`), seguida de um
   marcador (`+[NSNull null]`) cujo valor de retorno prova que a fila chegou
   até ele;
2. se o marcador atrasa mais de 20 ms **e**
   `CFRunLoopCopyCurrentMode(main)` é `NULL`, ou seja, o loop não está
   rodando, e não apenas ocupado com um arraste, a thread 0 é sequestrada de
   novo com outro `SIGUSR2`;
3. as chamadas que estavam na fila sobrevivem e rodam quando o loop volta.

O guarda só fica ativo no `showcase-signal`. Os probes históricos continuam
como estavam.

Resultado medido: `reparks=22` em 8 s sem travar, `TEARDOWN=PASS`, exit 0.

### 3.3 Despacho de eventos sem a corrida do autorelease pool

Primeira tentativa: espiar o próximo evento (`dequeue:NO`), retê-lo, retirá-lo
da fila e despachar. Não funciona, porque o AppKit cria um `NSEvent` novo a
cada consulta: em 126 de 126 casos, o evento espiado era um objeto diferente
do retirado.

O que funciona: depois de `retainArguments`, o `NSInvocation` também retém o
valor de retorno. O evento retirado continua vivo até a próxima chamada do
invocation, então pode ir direto para `sendEvent:`. Validado com
`NSZombieEnabled=YES MallocScribble=1`, sem nenhum zumbi.

## 4. Backend 1 — SkyLight transparente no macOS 27

### 4.1 Sintoma

A janela é criada (`rc=0`), posicionada e ordenada na frente do VS Code
(`CGWindowList`: `onScreen=1 alpha=1`), mas só mostra o que está por trás.
`screencapture -l<wid>` devolve um retângulo transparente, e a conformidade do
backend 1 falhou com `PIXEL_WITNESS=FAIL centre=0,0,0`, também **sem** nenhuma
mudança deste trabalho. No CI (`macos-14`), a mesma rota passa.

### 4.2 O que não resolveu

Experimento isolado em Dart FFI, oito variantes, todas `0,0,0`:

- `SLPSRegisterWithServer(3)` antes;
- criar o contexto depois de `SLSOrderWindow`;
- `SLSSetWindowOpacity(false)`;
- `SLSSetWindowResolution(1.0)`;
- `SLSFlushWindowContentRegion` depois de `CGContextFlush`, como o JankyBorders
  faz;
- as combinações dessas opções.

### 4.3 A variável decisiva: a thread principal

Reproduzindo em C a sequência exata do JankyBorders 1.9.0
(`src/misc/window.h`, `src/border.c`):

| Variante (C) | Centro da captura |
|---|---|
| desenha e `sleep(3)` | `0,0,0` |
| desenha e `CFRunLoopRunInMode` na thread principal | `40,120,220` ✅ |
| desenha numa thread secundária; principal em `dispatch_main()` | `40,120,220` ✅ |
| desenha numa thread secundária; principal em `CFRunLoopRun` | `40,120,220` ✅ |
| desenha numa thread secundária; principal bloqueada | `0,0,0` |
| conexão própria (`SLSNewConnection`) e principal bloqueada | `0,0,0` |

(O vermelho 40 em vez de 20 é gerenciamento de cor da captura.)

O conteúdo só chega quando a **main dispatch queue** é drenada. Num processo
Dart standalone, a thread 0 fica em `Dart_RunLoop` e nunca a drena. O pump do
backend roda o run loop da thread do isolate, que não é a principal.

### 4.4 O que a SkyLight coloca na main queue

Com breakpoint em `_dispatch_call_block_and_release` (lldb, `memory read -fA`
no bloco):

```
SkyLight`__CGSWindowUpdateBackingStoreData_block_invoke
SkyLight`__CGSWindowReloadCABackingStoreLayer_block_invoke
```

Os stubs do shared cache foram resolvidos com o script da seção 6.
`CGSWindowReloadCABackingStoreLayer(impl)` lê a camada em
`*(*(impl+0x40)+0xd0)` e o id da janela em `*(impl+0x10)`, e faz
`dispatch_async(&_dispatch_main_q, bloco)`. O bloco faz:

```
objc_autoreleasePoolPush()
impl = CGSWindowGetMappedImpl(SLSMainConnection(), wid, 1)
[CATransaction begin]; [CATransaction setDisableActions:YES]
[layer reloadValueForKeyPath:@"contents"]
[CATransaction commit]
SLSFlushWindowContentRegion(cid, wid, região do tamanho da janela)
objc_autoreleasePoolPop()
```

`__CGSWindowUpdateBackingStoreData_block_invoke` aplica a máscara de recorte
(`CAShapeLayer` com `setPath:`, `setFillColor:` e `setFillRule:`) numa
`CATransaction`.

Drenar a main queue de outra thread não é opção. A libdispatch derruba o
processo ("`_dispatch_main_queue_callback_4CF called from the wrong thread`").

### 4.5 A chave do sistema: `CAWindowContent`

`SLSGetWindowLayerContext` consulta:

```
_os_feature_enabled_impl("WindowServer", "CAWindowContent")
```

Neste macOS 27 a flag vale `1`. É ela que faz o backing store de toda janela
passar pelo Core Animation, e é a diferença em relação ao `macos-14` do CI.

### 4.6 Como o AppKit cria janelas nesse modo

Com breakpoints em `SLSNewWindow*`, `SLSCreateLayerContext` e
`SLSSetWindowLayerContext` dentro do host nativo:

```
SLSNewWindowWithOpaqueShape(cid, 5, emptyRegion, emptyRegion, 0x10000, tags, 0x40, …)
  ← -[NSCGSWindow initWithConnectionID:flags:]
SLSCreateLayerContext  ← -[CAContext initWithCGSConnection:options:]
SLSSetWindowLayerContext
```

O segundo argumento, que o projeto tratava como "backing store buffered"
(`2`), vale **5**. `SLSSetWindowLayerContext(cid, wid, caContext)` recusa
(`1000`) qualquer janela cujo tipo interno (`impl+0x80`) não seja 5. Ele envia
o `contextId` ao WindowServer por `mach_msg`, sem passar pela main queue.

### 4.7 A correção

Validado primeiro em Objective-C, com a thread principal bloqueada (o caso do
Dart):

| Criação | `SLSSetWindowLayerContext` | Centro |
|---|---|---|
| `SLSNewWindow(cid, 2, …)` com `CAContext` próprio | `1000` | `0,0,0` |
| `SLSNewWindowWithOpaqueShapeAndContext(cid, 2, …)` | `1000` | `0,0,0` |
| `SLSNewWindowWithOpaqueShapeAndContext(cid, 5, …)` | `0` | `40,120,220` ✅ |
| `SLSNewWindow(cid, 5, …)`, opções `nil` | `0` | `40,120,220` ✅ |

Implementação em
[`skylight_backend.dart`](../../poc/poc_20_macos_three_backends/lib/src/skylight_backend.dart):

- **Escolha do caminho:** `report.presentation` vale `ca-layer` quando
  `CAWindowContent` está ativa e `cg-context` quando não está. O caminho CG
  antigo, provado no CI, continua intacto.
- **Caminho CA, na criação:**
  1. `SLSNewWindow(cid, 5, …)`;
  2. `+[CAContext contextWithCGSConnection:cid options:nil]` e `[CALayer layer]`,
     com o frame do tamanho da janela e filtros `kCAFilterNearest`;
  3. `context.layer = layer` dentro de uma `CATransaction`;
  4. `SLSSetWindowLayerContext(cid, wid, context)`.
- **Caminho CA, no `present`:** dentro de uma `CATransaction` com ações
  desligadas, `layer.contents = CGImage`, depois `commit` e `flush`, tudo na
  thread do isolate. Não sobra nenhum bloco na main queue.
- **Dados do frame:** a imagem passa a usar um `CFData` próprio, porque o
  servidor de renderização pode ler os pixels depois do retorno.
- **Teardown:** `SLSReleaseWindow` → `CAContext.layer = nil` e liberações →
  `CGSReleaseRegion` → …

Resultado no macOS 27, em Dart puro, sem a thread principal:

```
presentation -> ca-layer
SLSSetWindowLayerContext -> 0
PRESENT=PASS
PIXEL_WITNESS=PASS centre=40,120,220 size=480x320
TEARDOWN_STEPS=[SLSReleaseWindow=0, CAContext+CALayer release, CGSReleaseRegion=0, …]
TEARDOWN=PASS
```

Nessa medição, a única linha que falhava era `INPUT_EVENTS=0`. A seção 5
resolve o input, e a seção 6 explica o input sintético.

## 5. Backend 1 — cliques físicos e botão de fechar

A janela SkyLight não tem moldura, então ganhou um X pintado no frame
(`ShowcaseSpec.closeButton`, `showcaseCloseBox`). O showcase fecha a janela
quando o mouse é pressionado e solto dentro do X.

### 5.1 Sintoma

Nenhum evento chegava: `INPUT_EVENT_TYPES` vazio, nem mesmo o primeiro
`pointerDown`. Mesmo assim, `SLSFindWindowAndOwner(cid, 0, 1, 0, &ponto, …)`
apontava a janela 811, do nosso PID, como alvo de um clique no X. O WindowServer
sabia que o clique era nosso. E a porta não era o problema: o AppKit também
recebe eventos por `SLSGetEventPort`, via `HIToolbox CreateEventLoopSource`.

### 5.2 Medição com cliques de hardware

Os cliques foram postados pelo `ClickHelper.app` (seção 6) com
`CGEventPost(kCGHIDEventTap)`, a mesma rota do mouse físico. Teste em
Objective-C (`TYPE` = tipo da janela, `THREAD` = tudo numa thread secundária
com a principal bloqueada):

| Variante | Eventos recebidos depois de 2 cliques |
|---|---|
| `TYPE=5` | só `13` (evento interno da criação) |
| `TYPE=5`, `SLPSRegisterWithServer(3)` | só `13` |
| `TYPE=2`, `SLPSRegisterWithServer(3)` | só `13` |
| drenagem até `NULL` | só `13` |
| `SLPSSetFrontProcessWithOptions` | `SLPSGetCurrentProcess` = **-600** (`procNotFound`) |
| **`GetCurrentProcess()` (HIServices)** | `13, 1, 2, 1, 2` ✅ |
| `GetCurrentProcess()` + `TransformProcessType` | `13, 13, 1` (pior) |
| **`GetCurrentProcess()`, `THREAD=1`** | `13, 1, 2, 1, 2` ✅ |

`SLPSRegisterWithServer` retorna 0, mas não dá um PSN ao processo. Já o
`GetCurrentProcess`, público e obsoleto mas exportado, faz o check-in no
LaunchServices (`_RegisterApplication`), o mesmo que o AppKit faz
implicitamente. Só depois disso o WindowServer entrega botões de mouse à
janela. Movimento de mouse (`5`) continua sem chegar a um processo que não
está ativo, e o botão não depende dele.

### 5.3 Correção e resultado

`SkylightBackend._checkInWithLaunchServices()` chama `GetCurrentProcess` antes
de `SLPSRegisterWithServer` e guarda o resultado em
`report.launchServicesCheckIn`. No showcase, com cliques de hardware:

```
INPUT pointerDown at window 160.0,130.0            ← corpo: continua aberta
INPUT pointerDown at window 452.0,28.0 (close button)
closed by the painted close button
INPUT_EVENT_TYPES=[13, 1, 2, 1, 2]
TEARDOWN=PASS [SLSReleaseWindow=0, CAContext+CALayer release, …]
exit=0
```

A conformidade do backend 1 também passou a receber o input sintético
(`INPUT_EVENTS=5`, `CONFORMANCE=PASS`).

## 6. O ambiente local (macOS 27)

- **Input sintético exige Acessibilidade em quem posta.** Antes de a sessão
  ter Acessibilidade, `SLEventPostToPid` entregava 0 ou 1 evento, e as três
  conformidades falhavam só em `INPUT_EVENTS`, inclusive com o host do HEAD.
  Depois que o Visual Studio Code, de onde os comandos rodam, passou a ter
  Acessibilidade (`AXIsProcessTrusted=true`), as três passaram. O host
  recebeu os 9 eventos com ou sem check-in de quem posta. O CI funciona porque
  o TCC do runner já vem configurado.
- **`log show` não devolveu nenhuma linha** sem privilégios.
- **`screencapture -l` exige Gravação de Tela** para o processo que o chama.
  Sem ela, o resultado é "could not create image from window".
- **Fechamento com o mouse físico**, conferido pelos logs: o backend 2
  despachou 29 eventos e saiu pelo botão vermelho. O backend 3 recebeu 175 e
  saiu com `HOST_EXIT=0`, sem o crash da seção 2.

## 7. Ferramentas

- **`ClickHelper.app`** (`/Volumes/SSD Dock/tools/ClickHelper`, fonte em
  `src/main.swift`): um app mínimo (`LSUIElement`) que posta movimento e
  clique de hardware via `CGEventPost(kCGHIDEventTap)` e registra cada clique
  em `/tmp/clickhelper.log`. Aberto com
  `open -n -a ClickHelper.app --args click X Y`, o macOS o trata como
  responsável por si mesmo, então a permissão de Acessibilidade fica só com
  ele.
- **`SLSFindWindowAndOwner`:** diz que janela e que conexão receberiam um
  clique num ponto da tela. Separa "o clique não acerta a janela" de "o
  clique não é entregue".
- **lldb:** os passos de 3.2 e 4.3 a 4.6 usam só breakpoints simbólicos
  (`CFRunLoopStop`, `_dispatch_call_block_and_release`, `SLSNewWindow*`,
  `SLSSetWindowLayerContext`) e `memory read -fA`.
- **Stubs do shared cache:** o `disassemble` do lldb mostra os `bl` das
  funções da SkyLight apontando para ilhas de stub sem nome. Há dois formatos:
  - *selector stub*: `adrp x1; add x1; b objc_msgSend`. O seletor é a string
    em `página + offset`;
  - *GOT stub*: `adrp x17; add x17; ldr x16,[x17]; braa`. O alvo é o ponteiro
    no GOT, sem os bits de PAC (`& 0xFFFFFFFFF`).

  Um script Python de lldb com `SBTarget.ReadInstructions` resolve os dois
  formatos.
- **Pixels de fora:** `screencapture -x -o -l<wid>` seguido de
  `sips -s format bmp`, lendo o pixel central. É o mesmo método do
  `WindowPixelWitness`.
- **Referências:** a [`skylight.txt`](../../referencias/skylight.txt), um dump
  `nm` da SkyLight, confirma os símbolos. Para comparar a sequência de
  chamadas, o JankyBorders 1.9.0 foi clonado em
  `/Volumes/SSD Dock/references_re/JankyBorders`.

## 8. Em aberto

- **CI:** rodar a conformidade do backend 1 no CI (`macos-14`) para confirmar
  que o caminho `cg-context` continua passando com a troca do data provider
  para `CFData`. Seria bom também um runner `macos-15`/`26` para medir o
  caminho `ca-layer` no CI.
- **Resolução:** o caminho CA usa `contentsScale` 1. Numa tela Retina, a
  camada vai precisar de `contentsScale = 2` e de um frame em pixels de
  dispositivo.
- **Arraste:** o backend 1 ainda não arrasta; isso precisaria de
  `leftMouseDragged` (tipo 6) e de `SLSMoveWindow`. O arraste do backend 2
  ainda não foi medido por clique de hardware.
- **Compatibilidade por versão:** a tabela de ABI do backend 1 (trabalho
  restante em `MACOS_TRES_BACKENDS.md`) agora precisa registrar
  `CAWindowContent`, o tipo de janela 5 e `SLSSetWindowLayerContext` por
  versão do macOS.
