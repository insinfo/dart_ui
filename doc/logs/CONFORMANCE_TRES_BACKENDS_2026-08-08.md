# Conformidade dos três backends macOS — medição de 2026-08-08

**Run:** [`31244960783`](https://github.com/insinfo/dart_ui/actions/runs/31244960783)
— `macos-14` arm64, Dart 3.6.0. A mesma matriz saiu verde em runs consecutivas
(`31243508746`, `31243936738`, `31244470676`, `31244738786`).
**Workflow:** `.github/workflows/macos_mainthread_spike.yml`
**Suíte:** `poc/poc_20_macos_three_backends/bin/conformance.dart` e
`poc/poc_03_appkit_window/bin/probe.dart conformance-signal`

## A suíte

Os três backends respondem às mesmas seis linhas, e cada uma é um gate do CI —
não há passo `continue-on-error` nesses quatro steps:

| Linha | O que prova |
|---|---|
| `WINDOW_ID=<n>` | o WindowServer possui uma janela |
| `PRESENT=PASS` | um framebuffer BGRA de CPU chegou nessa janela |
| `PIXEL_WITNESS=PASS centre=r,g,b` | **outro processo** fotografou o frame |
| `INPUT_EVENTS=<n>` | input chegou pela rota real de eventos |
| `TEARDOWN=PASS` | todo handle liberado, sem `_exit` |
| `CONFORMANCE=PASS` | tudo acima, e `main()` retornou com status 0 |

O `PIXEL_WITNESS` é a única linha que nenhum backend consegue auto-reportar:
`screencapture -l<CGSWindowID>` só produz pixels se o WindowServer realmente
tiver aquela janela. `sips` converte a captura para BMP e o pixel central é
lido sem depender de um decodificador PNG. Cada backend pinta uma cor
diferente, então uma captura deixada por outro backend não passa por frame
novo.

## Resultado

| backend | janela | present | pixel central (esperado) | input | teardown | exit |
|---|---|---|---|---|---|---|
| `skylight` | 38 | PASS | `19,120,220` (`20,120,220`) | 4 | PASS | 0 |
| `appkitSignal` | 47 | PASS | `120,220,20` (`120,220,20`) | 5 | PASS | 0 |
| `appkitNativeHost` | 39 | PASS | `220,120,20` (`220,120,20`) | 3 | PASS | 0 |

O desvio de 1 unidade no azul do backend 1 é o único erro de cor em toda a
matriz; a tolerância do witness é 24 por canal.

## Backend 1 — `skylight`

```text
SLPSRegisterWithServer(3) attempt 1 -> 0
REGISTRATION_ATTEMPTS=1
WINDOW_ID=38
PRESENT=PASS
PIXEL_WITNESS=PASS centre=19,120,220 size=480x320
INPUT_EVENTS=4
INPUT_EVENT_TYPES=[10, 11, 5, 10]
MACH_MESSAGES=2 extraReads=2
POINTER_INPUT=1
INPUT_EVENTS_DECODED=[keyDown, keyUp, pointerMove, keyDown]
TEARDOWN_STEPS=[CGContextRelease, SLSReleaseWindow=0, CGSReleaseRegion=0,
                CFRunLoopRemoveSource, CFRelease(source),
                CFMachPortInvalidate+CFRelease, NativeCallable.close]
MISSING_SYMBOLS=[]
TEARDOWN=PASS
CONFORMANCE=PASS
```

O framebuffer entra por `CGImageCreate` + `CGContextDrawImage` no contexto de
`SLWindowContextCreate`. O teardown libera em ordem inversa de aquisição e
`SLSReleaseWindow`/`CGSReleaseRegion` existem e retornam 0 — nenhum símbolo
faltou. O processo retorna de `main()`; `_exit` não aparece nesse caminho.

### O `pointerMove` que faltava era coalescência, não máscara

Por várias medições o backend recebia só `[10, 11]`. Três hipóteses foram
testadas e descartadas no CI: `SLSSetWindowEventMask(0xFFFFFFFF)` (a máscara
mudou de `0` para `ffffffff` e nada mudou), variar a posição do ponteiro entre
injeções, e tirar o `screencapture` de entre o present e a injeção.

O que estava errado era a regra de drenagem. `MACH_MESSAGES=2` para três
eventos postados: o WindowServer agrupa, e uma leitura por mensagem deixava o
terceiro evento na fila para sempre. Com uma leitura extra limitada **fora** do
callback, executada apenas depois de uma fatia que entregou algo, o backend
passou a receber `[10, 11, 5, 10]` sem bloquear. O bloqueio histórico dos
probes Z2–Z15 era drenagem ilimitada **dentro** do callback.

## Backend 2 — `appkitSignal`

```text
WINDOW_ID=47
PRESENT=PASS
PIXEL_WITNESS=PASS centre=120,220,20 size=480x348
RESPONDER_INPUT=1
INPUT_EVENTS=5
PUMP_LIVENESS=PASS (+13 witness ticks)
TEARDOWN=PASS
CONFORMANCE=PASS
```

A apresentação usa `CGImage` no layer da content view — o backing store é da
AppKit, então não há contexto CGS para pintar.

O input é medido em duas metades, porque elas respondem a perguntas diferentes
e só uma pode ser feita sem corrida a partir de Dart puro:

- **Dispatch** (`RESPONDER_INPUT`): um `NSEvent` criado e retido por nós passa
  por `[NSApp sendEvent:]` e chega em `keyDown:` da janela. Prova que a cadeia
  de responders continua íntegra numa main thread entrada por signal handler.
- **Fila** (`INPUT_EVENTS`): eventos injetados via `SLEventPostToPid` são
  retirados pelo pump periódico enquanto um timer testemunha mostra que o run
  loop continua entregando.

Reenviar um evento *bombeado* não é possível com segurança: `nextEventMatching
Mask:` devolve um `NSEvent` autoreleased que o pool da iteração do run loop
pode drenar antes de o isolate conseguir retê-lo, e Dart não tem como fazer o
retain na main thread sem um método Objective-C próprio.

### O teardown que travava

Na run [`31242939984`](https://github.com/insinfo/dart_ui/actions/runs/31242939984)
o passo parou em `PHASE=teardown` e o `sample(1)` mostrou a thread 0 já de volta
em `Dart_RunLoop → _pthread_cond_wait`. Depois que o run loop sequestrado para,
a main queue não tem quem a drene, e o `[window close]` com
`waitUntilDone:YES` nunca retornava. A ordem correta é: `orderOut:` assíncrono,
uma folga para a main thread executá-lo, e só então recuperar o loop.

## Backend 3 — `appkitNativeHost`

```text
WINDOW_ID=39
PRESENT=PASS
PIXEL_WITNESS=PASS centre=220,120,20 size=480x348
INPUT_EVENTS=3
INPUT_EVENT_KINDS=[keyDown:-190:870:0, keyUp:-190:870:0, pointerMove:400:680:0]
VIEW_INPUT_EVENTS=3 [keyDown:-190:870, keyUp:-190:870, pointerMove:200:480]
TEARDOWN=PASS
CONFORMANCE=PASS
```

Protocolo 2 do host: `FRAME <w> <h> <bytes>` seguido dos octetos BGRA crus —
base64 estouraria qualquer buffer de linha razoável para 480x320 — e linhas
`INPUT=` de volta para o Dart.

O input é reportado duas vezes de propósito: o `NSEvent` local monitor vê tudo
que a aplicação retira da fila e é o gate; `VIEW_INPUT=` vem da cadeia de
responders e prova que o mesmo evento foi roteado até uma view. Os três eventos
aparecem nas duas listas.

Isso também demonstra `SLEventPostToPid` dirigindo um **segundo processo**: o
Dart injeta no pid do host, não no próprio.

## `SLPSRegisterWithServer` — o `-50` explicado

A documentação anterior registrava uma alternância inexplicada entre `0` e
`paramErr (-50)`. O disassembly capturado pelo step LLDB fecha a questão
(macOS 14, arm64):

```text
SLPSRegisterWithServer:
  mov  x19, x0                      ; um único argumento: o flavor
  bl   primary_connection_exists
  cbz  w0, <erro>
  ldp  w9, w8, [gOurPSN]            ; já registrado? retorna cedo
  bl   getpid
  bl   _LSASNCreateWithPid
  cbz  x0, <erro>
  bl   _LSCopyApplicationInformationItem
  cbz  x0, <erro>
  ...
  bl   _SLPSRegisterWithServer      ; (flavor, ASN*, pid)
```

Ou seja: a ABI de um argumento estava certa e a chamada estava cedo demais. A
função pergunta ao LaunchServices quem é este processo, e para um binário de
linha de comando sem bundle essa resposta nem sempre está pronta na primeira
chamada. A correção é retry limitado (12 tentativas, 150 ms), não outra
assinatura. Na medição acima bastou uma tentativa.

A variante interna `_SLPSRegisterWithServer` é chamada por
`HIServices _RegisterApplication` com `x0=3` (flavor), `x1=&sOurASN`,
`x2=<pid>`.

## Robustez tardia no job

O backend 1 registra na primeira tentativa mesmo quando roda no fim do job,
onde o probe Z17 falha. A suíte roda duas vezes por isso: uma cedo e uma
depois de todos os outros probes, ambas como gate.

O probe Z17 continua com uma falha em aberto e virou diagnóstico: quando a
primeira chamada a `SLPSRegisterWithServer` devolve `-50`, o retry devolve `0`
mas o WindowServer não entrega mais nada. Três runs concordam com essa
correlação. O backend nunca caiu nesse estado.

## O que ainda falta

- Duas janelas, resize, segundo frame e pacing na mesma suíte.
- Metal além do framebuffer de CPU.
- Fullscreen/Spaces, dois monitores, mudança de escala, sleep/wake.
- Transporte de frames do backend 3 com memória compartilhada em vez de pipe.
