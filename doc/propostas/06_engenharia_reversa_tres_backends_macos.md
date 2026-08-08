# Engenharia reversa — três backends macOS
## Resultados consolidados e ABIs descobertos

**Data:** 7 de agosto de 2026
**Repositório:** `insinfo/dart_ui`
**Documento de arquitetura:** [`MACOS_TRES_BACKENDS.md`](../MACOS_TRES_BACKENDS.md)
**Spike original:** [`SPIKE_MACOS_MAIN_THREAD.md`](../SPIKE_MACOS_MAIN_THREAD.md)
**Runner:** macOS 14.8.7, arm64
**Dart SDK:** 3.6.0
**CI confirmado:** runs `31159720697` (SkyLight Z17), `31162204180` (três backends), `31162694435` (LLDB backend 2), `31243508746` (conformidade dos três)
**Commits:** `5a30841`, `c7da356`, `f2fb875`, `a474dc9`

**Atualização de 8 de agosto de 2026:** os três backends passam a mesma suíte de
conformidade no CI — janela, framebuffer de CPU, testemunha externa de pixels,
input pela rota real e teardown sem `_exit`. Medições em
[`logs/CONFORMANCE_TRES_BACKENDS_2026-08-08.md`](../logs/CONFORMANCE_TRES_BACKENDS_2026-08-08.md).

---

## 1. Objetivo

Este documento consolida toda a engenharia reversa realizada sobre as APIs
privadas do macOS necessárias para os três backends de janela. Ele serve como
referência de ABI — assinaturas descobertas, métodos de validação, erros
encontrados e regras de consumo medidas — para que o código de produção não
precise repetir os probes individuais.

Os documentos de proposta 01–05 tratam do **que pedir ao Dart SDK**. O spike
trata dos **resultados experimentais brutos**. A arquitetura dos três backends
está em `MACOS_TRES_BACKENDS.md`. Este documento trata do **como funciona por
dentro** — a engenharia reversa propriamente dita.

---

## 2. Visão geral dos três backends

| Backend | API principal | Thread 0 | Estado de maturidade |
|---|---|---|---|
| `skylight` | SkyLight/CGS (API privada) | não exige | conformidade completa, incluindo `pointerMove` |
| `appkitSignal` | AppKit via ObjC runtime | sequestrada por `SIGUSR2` | conformidade completa, incluindo cadeia de responders |
| `appkitNativeHost` | AppKit normal via `.m` | possuída desde `main()` | conformidade completa; caminho recomendado |

---

## 3. Backend 1 — SkyLight/CGS: ABIs descobertos

### 3.1 Processo de descoberta

A engenharia reversa do SkyLight seguiu um processo iterativo de 17 probes
(Z1–Z17), cada um testando uma hipótese de ABI no CI macOS arm64. O método:

1. Declarar a assinatura candidata em Dart FFI.
2. Chamar e observar: retorno, crash, ou bloqueio.
3. Em caso de SEGV/crash, analisar `si_addr` para inferir o argumento lido.
4. Quando necessário, usar LLDB para desassemblar e ler `x0...x7`.
5. Comparar com consumidores conhecidos (JankyBorders, edges/Rust, Cua).

### 3.2 Tabela de ABIs confirmados

| Símbolo | ABI observado (macOS 14 arm64) | Como confirmado |
|---|---|---|
| `SLSMainConnectionID` | `int SLSMainConnectionID(void)` | Retorno não-zero fora da thread 0; aliases com `CGSMainConnectionID` |
| `SLSNewWindow` | `CGError SLSNewWindow(int cid, int type, float x, float y, CGSRegionRef region, uint32_t *wid)` | Probe H: `CGError 0`, wid 25 |
| `SLSOrderWindow` | `CGError SLSOrderWindow(int cid, uint32_t wid, int place, uint32_t relativeToWid)` | Probe H: `CGError 0` |
| `SLSSetWindowLevel` | `CGError SLSSetWindowLevel(int cid, uint32_t wid, int level)` | Probe H: retorno 0 |
| `SLSFlushWindowContentRegion` | `CGError SLSFlushWindowContentRegion(int cid, uint32_t wid, CGSRegionRef region)` | Probe M: pixels visíveis |
| `CGSNewRegionWithRect` | `CGError CGSNewRegionWithRect(const CGRect *rect, CGSRegionRef *outRegion)` | Probe H: `CGError 0`; não exportado pelo SkyLight, encontrado via `dlsym` na cadeia CoreGraphics |
| `SLWindowContextCreate` | `CGContextRef SLWindowContextCreate(int cid, uint32_t wid, void *options)` | Probe M: contexto não-null, pixels pintados |
| `SLSGetEventPort` | `CGError SLSGetEventPort(int cid, mach_port_t *port_out)` | Probe Y/Z1: retorno 0, porta Mach válida; ABI com ponteiro-de-saída, não retorno-por-valor |
| `SLEventCreateNextEvent` | `CGEventRef SLEventCreateNextEvent(int cid)` | Probe Z1: um argumento (cid), sem `CFAllocatorRef`; ABI corrigido comparando com JankyBorders |
| `SLPSRegisterWithServer` | `CGError SLPSRegisterWithServer(int flavor)` | Probe Z6/Z7 + disassembly completo (§3.3.1): `mov x19, x0`, um argumento; AppKit usa flavor `3` via HIServices |
| `_SLPSRegisterWithServer` | `CGError _SLPSRegisterWithServer(int flavor, LSASN *asn, pid_t pid)` | LLDB no chamador: `HIServices _RegisterApplication` passa `x0=3`, `x1=&sOurASN`, `x2=<pid>` |
| `SLPSSetMainApplicationConnection` | `CGError SLPSSetMainApplicationConnection(int cid)` | Probe Z12: consome apenas `x0`; LLDB confirmou |
| `SLEventPostToPid` | `void SLEventPostToPid(pid_t pid, CGEventRef event)` | Probe Z14–Z16: assinatura do Cua confirmada; entrega eventos diretamente ao PID |
| `SLSRegisterNotifyProc` | `void SLSRegisterNotifyProc(SLSNotifyProcPtr proc, uint32_t event, void *userData)` | JankyBorders: 13 registros retornaram 0 no probe Z8 |

### 3.3 ABIs que falharam ou são inconclusivos

| Tentativa | O que aconteceu | Lição |
|---|---|---|
| `SLEventCreateNextEvent(allocator, cid)` com dois args | `x0` recebeu `nullptr`, `x1` recebeu cid; função de 1 arg leu `x0=0` → conexão 0 → nenhum evento | No arm64, argumentos extras são silenciosamente ignorados; a ausência de crash não prova que a assinatura está correta |
| `SLSGetEventPort(cid)` retorno-por-valor | SEGV com `si_addr == cid` — o cid foi desreferenciado como ponteiro | ABI é `out-pointer`, não retorno direto |
| `SLPSRegisterWithServer(eventPort)` isolado | Retornou `-50`; o sucesso de Y era artefato de estado residual | Argumentos residuais em registradores arm64 podem mascarar ABIs errados |
| `SLPSRegisterWithServer(void)` (stub Darling) | Primeira chamada com `x0` indefinido retornou `-50`; segunda retornou 0 mas sem efeito | Stubs open-source são pontos de partida, não contratos |

### 3.3.1 O `-50` alternante, explicado

A alternância entre `0` e `paramErr (-50)` estava registrada como inexplicada.
O disassembly de `SLPSRegisterWithServer` (macOS 14, arm64) fecha a questão:

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

A ABI de um argumento estava certa; a chamada é que podia ser cedo demais. A
função pergunta ao LaunchServices quem é este processo, e para um binário de
linha de comando sem bundle essa resposta nem sempre está pronta na primeira
chamada — na run `31243093662` um processo recebeu `0` e outro, no mesmo job,
recebeu `-50`.

**Correção:** retry limitado (12 tentativas, 150 ms), não outra assinatura.
Backend e probe registram cada tentativa; na medição verde bastou uma.

### 3.4 Regra de consumo da porta de eventos

No cliente CGS mínimo, a regra medida é:

```text
cada mensagem Mach → exatamente uma leitura de SLEventCreateNextEvent(cid)
```

A leitura adicional de exaustão (loop até `NULL`, como faz JankyBorders) causou
bloqueio no probe Z2–Z15. O JankyBorders é um consumidor passivo de notificações
do WindowServer; o probe é um processo auto-injetor que publica e consome seus
próprios eventos. A diferença:

| Cenário | Padrão de drenagem | Resultado |
|---|---|---|
| JankyBorders (eventos externos contínuos) | `while (SLEventCreateNextEvent(cid) != NULL)` | funciona |
| Probe Z16 (eventos auto-injetados, finitos) | uma leitura por mensagem Mach | funciona |
| Probe Z2–Z15 (auto-injetados + exaustão) | loop até NULL após cada mensagem | bloqueia |

**Regra para o framework (corrigida em 8 de agosto de 2026):** uma leitura por
mensagem **perde eventos**. O WindowServer agrupa: três eventos postados
(`keyDown`, `keyUp`, `mouseMoved`) chegaram como **duas** mensagens Mach, e a
regra estrita deixou o terceiro na fila para sempre. Era exatamente por isso
que o backend 1 recebia `[10, 11]` e nunca o `pointerMove`, enquanto uma janela
AppKit normal recebia os três.

A regra correta é a segunda metade do que este documento já dizia, e que não
estava implementada:

```text
dentro do callback:  exatamente uma leitura por mensagem
fora do callback:    leituras extras limitadas, apenas depois de uma fatia
                     do run loop que entregou algo
```

Com isso o backend passou a receber `[10, 11, 5, 10]` — `keyDown`, `keyUp`,
`pointerMove`, `keyDown` — com `MACH_MESSAGES=2` e `extraReads=2`, sem bloquear.
O bloqueio medido nos probes Z2–Z15 acontecia **dentro** do callback e sem
limite; fora dele e limitado, não acontece.

### 3.5 Ordem de inicialização obrigatória

Medida pela regressão entre Z16 (registro tardio → 0 eventos) e Z17 (registro
antes da janela → 3 eventos):

```text
1. SLSMainConnectionID()           → cid
2. SLPSRegisterWithServer(3)       → registra o processo no WindowServer
3. SLSGetEventPort(cid, &port)     → porta Mach para eventos
4. CFMachPortCreateWithPort(...)   → monitor da porta
5. CFRunLoopSource / CFRunLoopAdd  → integração com o loop
6. SLSNewWindow(...)               → primeira janela
7. SLSOrderWindow(...)             → torna visível
```

AppKit/HIServices segue essa ordem: registra o processo **durante a inicialização
de `NSApplication`**, antes da primeira janela. Inverter causa retorno `-50` do
registro ou fila de eventos vazia.

### 3.6 Pool de autorelease obrigatório

A [issue SDL #14256](https://github.com/libsdl-org/SDL/issues/14256) documenta
que `SLEventCreateNextEvent` causa autoreleases internos (`_NSCGEventBuffer` e
mensagens de autenticação). O probe adotou `objc_autoreleasePoolPush/Pop` em
cada callback; o CI verifica a ausência de `MISSING POOLS` no stderr.

### 3.7 Interação perigosa: datagrams laterais

Um [backtrace do R-SIG-Mac](https://stat.ethz.ch/pipermail/r-sig-mac/2020-August/013663.html)
mostra `SLEventCreateNextEvent` passando por `CGSSnarfAndDispatchDatagrams` e
notificando mudanças do Dock/telas. Isso pode atingir `NSScreen` fora da main
thread. **Regra:** não inicializar AppKit no isolate que drena SkyLight; se
combinados, efeitos AppKit devem ser entregues à thread principal.

### 3.8 Captura de tela como testemunha externa

O probe N fotografou a janela SkyLight pelo `CGSWindowID` com
`screencapture -l<id>`, obtendo pixels reais a 480×320 e uma captura de tela
cheia a 1920×1080 mostrando o retângulo azul no desktop macOS completo. Isso
prova que o CI não é headless e que a janela existe no WindowServer, não apenas
na memória do probe.

---

## 4. Backend 2 — Signal hijack: análise LLDB

### 4.1 Mecanismo

```text
1. signal(SIGUSR2, &CFRunLoopRun)
2. pthread_kill(pthread_main_thread_np(), SIGUSR2)
3. thread 0 entra em CFRunLoopRun dentro do handler
4. main dispatch queue passa a ser drenada
```

A thread do isolate Dart nunca muda de identidade. A thread 0, estacionada em
`Dart_RunLoop → pthread_cond_wait`, é interrompida pelo sinal e entra no run
loop do Core Foundation.

### 4.2 Keep-alive source

O probe L/R descobriu que `CFRunLoopRun` sem sources persistentes retorna
`kCFRunLoopRunFinished` e a VM retoma a thread. A correção:

```dart
// Antes de sinalizar:
CFRunLoopSourceCreate(allocator, 0, &context) → source
CFRunLoopAddSource(mainRunLoop, source, kCFRunLoopDefaultMode)
```

Com o source, `sample(1)` mostrou `_sigtramp → CFRunLoopRun → mach_msg` (612/612
amostras). Sem ele, 612/612 dentro de `pthread_cond_wait`.

### 4.3 Shutdown recuperável — evidência LLDB

**Commit:** `f2fb875`
**Run:** `31162694435`

Procedimento executado pelo LLDB automatizado no CI:

1. Breakpoint em `CFRunLoopRun`.
2. `thread step-out` enquanto o isolate solicita teardown.
3. Observação da pilha de retorno.

Pilha na entrada:

```text
CFRunLoopRun
_sigtramp
_pthread_cond_wait
Dart_RunLoop
dyld start
```

Depois de `CFRunLoopRemoveSource` + `CFRunLoopStop` + `CFRunLoopWakeUp`:

```text
_sigtramp
_pthread_cond_wait
Dart_RunLoop
dyld start
```

O processo terminou com:

```text
NORMAL_SHUTDOWN=PASS
Process exited with status = 0
```

Isso prova que `CFRunLoopRun` retornou ao trampoline do signal, e o controle
voltou ao frame da VM. O `_exit()` não é mais necessário no caminho normal.

### 4.4 Melhorias implementadas após LLDB

| Melhoria | Detalhe |
|---|---|
| Restauração de handler | `sigaction` salva e restaura o handler anterior de `SIGUSR2` |
| Ownership de source | `CFRunLoopSourceCreate` com lifecycle explícito |
| Cleanup ordenado | `CFRunLoopRemoveSource` → `CFRelease` → `CFRunLoopStop` → `CFRunLoopWakeUp` |
| Sem `_exit` | Processo retorna normalmente de `main()` |
| Gate CI | Etapa obrigatória: exige `NORMAL_SHUTDOWN=PASS` e `status = 0` |
| Capability | `hasRecoverableShutdown: true` na política de backends |
| Trace preservado | [`logs/MACOS_SIGNAL_HIJACK_LLDB_2026-08-07.md`](../logs/MACOS_SIGNAL_HIJACK_LLDB_2026-08-07.md) |

### 4.5 O que permanece inseguro

```text
┌────────────────────────────────────────────────────────────┐
│ CFRunLoopRun NÃO É async-signal-safe                      │
│ ─────────────────────────────────────                      │
│ • A entrada é via handler de sinal: void handler(int sig)  │
│ • CFRunLoopRun tem ABI diferente: void CFRunLoopRun(void)  │
│ • O frame interrompido (pthread_cond_wait) não sabe        │
│   que foi sequestrado                                      │
│ • O Dart SDK não garante que o frame estacionado            │
│   permanecerá o mesmo entre versões                        │
│ • Bibliotecas do processo podem disputar SIGUSR2            │
│ • O sinal permanece bloqueado na thread 0                  │
└────────────────────────────────────────────────────────────┘
```

O backend continua classificado como `experimentalUnsafe` e nunca é inserido na
cadeia de fallback automático.

### 4.6 Diagnóstico do pump AppKit

Os traces mais recentes refinam o problema do input:

- Timers continuam ativos depois de `finishLaunching`.
- O `hold-appkit` com pump periódico **recebeu um `NSEvent`**.
- A falha restante é `nextEventMatchingMask:` síncrono/reentrante.
- A assertation que matava o probe era `NSAssertMainEventQueueIsCurrentEventQueue`
  — não `pthread_main_np`. Criar `sharedApplication` na thread errada corrompia
  a event queue, não a identidade da thread.

**Correção medida:** criar `sharedApplication` e chamar `finishLaunching`
sempre na main thread estacionada (`_sharedAppOnMain` / `_finishLaunchingOnMain`).
Resultado: o crash sumiu e a janela sobreviveu 20+ segundos. O pump **bloqueia**
em `nextEventMatchingMask:` com sentinel intacto — a thread fica esperando
eventos que nunca chegam, em vez de crashar.

---

## 5. Backend 3 — Host Objective-C mínimo

### 5.1 Princípio

O executável `.m` é o `main()` real:

```objc
int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        // instala delegate, cria janela
        [app run];
    }
    return 0;
}
```

Isso resolve o problema de thread 0 **por definição**: o código nativo possui a
thread desde o início do processo. Carregar uma dylib `.m` por FFI dentro do
executável Dart **não** resolve: o código continuaria sem possuir a thread 0.

### 5.2 Protocolo IPC validado

O witness em
[`minimal_appkit_host.m`](../../poc/poc_20_macos_three_backends/native/minimal_appkit_host.m)
implementa um protocolo stdin/stdout versão 1:

| Comando | Direção | Efeito |
|---|---|---|
| `PING` | Dart → Host | Host responde `PONG` |
| `SET_TITLE:<texto>` | Dart → Host | Altera o título da janela na main queue |
| `CLOSE` | Dart → Host | Chama `[NSApp terminate:nil]`; shutdown normal |

O teste
[`native_host_protocol_smoke.dart`](../../poc/poc_20_macos_three_backends/bin/native_host_protocol_smoke.dart)
compila o `.m` com `clang`, inicia o processo, envia os três comandos e verifica
respostas. O CI macOS `31162204180` aprovou.

### 5.3 Duas evoluções possíveis

| Evolução | Veredito medido |
|---|---|
| **Embedder no mesmo processo** | Indisponível com SDK de release: sem `libdart` linkável, `Dart_Initialize` não resolve. Exige compilar o SDK do código-fonte |
| **Dart como processo worker** | Escolhido. Com `IOSurface`, 245 µs por frame — 1,5% do orçamento de 60 Hz |

A fronteira de processo custa 124 µs (PING/PONG sem pixels), ou 0,7% de um
frame a 60 Hz — o total que um embedder poderia recuperar. O `shm` melhora
apenas 1,7× sobre o pipe, o que mostra que a cópia nunca foi o gargalo: era o
`CGImage` reconstruído por frame mais o upload do CoreAnimation, que é
exatamente o que o `IOSurface` elimina.

Medições completas em
[`logs/DECISAO_EMBEDDER_VS_WORKER_2026-08-08.md`](../logs/DECISAO_EMBEDDER_VS_WORKER_2026-08-08.md).

---

## 6. Política de seleção

A implementação concreta da política está em
[`backend_policy.dart`](../../poc/poc_20_macos_three_backends/lib/src/backend_policy.dart).

```text
Ordem de fallback automático:
1. appkitNativeHost  (se artefato nativo disponível)
2. skylight          (se API privada autorizada E ABI validado)
── barreira ──
3. appkitSignal      (SOMENTE com opt-in explícito; NUNCA em fallback)
```

O fallback **nunca é silencioso**. O relatório registra:

- backend pedido vs. escolhido;
- versão/build do macOS;
- símbolos encontrados por `dlsym`;
- resultado do registro de processo;
- permissões relevantes;
- motivo exato de cada rejeição.

---

## 7. Contrato comum

O contrato de janela, framebuffer, input e lifecycle implementado em
[`backend_contract.dart`](../../poc/poc_20_macos_three_backends/lib/src/backend_contract.dart)
garante:

- **Interface única:** `MacosWindowBackend` — o código de widgets não conhece
  qual estratégia está ativa.
- **Estados explícitos:** `created → initializing → running → stopping → stopped`
  (ou `failed`).
- **Tokens geracionais:** um `int generation` incrementado em cada transição;
  callbacks nativos com geração diferente são rejeitados silenciosamente.
- **Shutdown idempotente:** `beginShutdown()` retorna `false` quando já está
  `stopping` ou `stopped`, em vez de lançar.
- **Capabilities declaradas:** cada backend declara o que suporta
  (`appKitSemantics`, `cpuPresentation`, `keyboardInput`, `pointerInput`,
  `normalShutdown`).

---

## 8. Ferramentas e processo de engenharia reversa

### 8.1 Cadeia de ferramentas

| Ferramenta | Uso neste spike |
|---|---|
| `dlsym` | Resolver símbolos exportados e seguir cadeia de dependências |
| `dyld_info -exports` | Listar todos os símbolos de SkyLight |
| `nm` / `.tbd` | Confirmar existência de nomes |
| LLDB | Breakpoint por símbolo, leitura de `x0...x7`, desassembly, `thread step-out` |
| `sample(1)` | Stack profiling da thread principal — revelou que CFRunLoopRun saía |
| `screencapture -l<id>` | Prova visual externa da janela |
| JankyBorders/edges/Cua | Referências de call site conhecido |

### 8.2 Processo recomendado (atualizado)

1. **Código consumidor antes de dump.** Um call site mostra quantidade, ordem e
   largura dos argumentos; `nm` só prova o nome.
2. **Validar por versão.** Fixar macOS 14/15/26; cada símbolo tem retorno medido
   e teste de fumaça por versão.
3. **Usar LLDB no chamador.** No arm64, ler `x0...x7` e retorno.
4. **Separar C de ObjC.** `method_getTypeEncoding` recupera seletores; para
   funções C do SkyLight, disassembly continua indispensável.
5. **Congelar evidência.** Para cada ABI, salvar link com commit, versão do
   macOS, declaração mínima e log do probe.

---

## 9. Referências cruzadas

### Fontes de ABI usadas

| Fonte | Valor |
|---|---|
| [JankyBorders `extern.h`](https://github.com/FelixKratz/JankyBorders/blob/a7297ca7d1933f3a30b12e8f10750e8d84eeee1e/src/misc/extern.h) | Declarações de SLSGetEventPort, SLEventCreateNextEvent |
| [JankyBorders `main.c`](https://github.com/FelixKratz/JankyBorders/blob/a7297ca7d1933f3a30b12e8f10750e8d84eeee1e/src/main.c) | Montagem CFMachPort → CFRunLoopSource |
| [JankyBorders issue #62](https://github.com/FelixKratz/JankyBorders/issues/62) | Concorrência, SLSWMBridge, portas separadas |
| [edges (Rust)](https://github.com/pablopunk/edges/blob/7bc134760b5facdce5e5b5b264d4d9e5b4feb770/src/events.rs) | Segunda tradução de SLSGetEventPort → CFMachPort |
| [Cua `skylight.rs`](https://github.com/trycua/cua/blob/main/libs/cua-driver/rust/crates/platform-macos/src/input/skylight.rs) | `SLEventPostToPid`, autenticação macOS 15+ |
| [NUIKit/CGSInternal](https://github.com/NUIKit/CGSInternal) | Catálogo de tipos CGS/SLS |
| [SDL issue #14256](https://github.com/libsdl-org/SDL/issues/14256) | Autorelease obrigatório no consumo de input |
| [Darling SkyLight.h stub](https://github.com/darlinghq/darling) | Ponto de partida para `SLPSRegisterWithServer(void)` — insuficiente |
| [dump de símbolos de Erica Sadun](https://gist.github.com/erica/448a71ae1aa5156ce9703dac747e2cec) | Índice histórico (2016) |

### Documentos deste repositório

- [01 — proposta main thread (pt)](01_proposta_dart_sdk_main_thread_ptbr.md)
- [02 — proposta main thread (en)](02_proposal_dart_sdk_process_main_thread_github_en.md)
- [03 — investigação probes A–K](03_investigacao_main_thread_macos_dart_puro.md)
- [04 — proposta event loop nativo (pt)](04_proposta_dart_sdk_event_loop_nativo_ptbr.md)
- [05 — proposta event loop (en)](05_proposal_dart_sdk_external_event_loop_github_en.md)
- [SPIKE_MACOS_MAIN_THREAD.md](../SPIKE_MACOS_MAIN_THREAD.md) — resultados brutos
- [MACOS_TRES_BACKENDS.md](../MACOS_TRES_BACKENDS.md) — arquitetura
- [LLDB trace](../logs/MACOS_SIGNAL_HIJACK_LLDB_2026-08-07.md) — evidência de shutdown
- [backend_policy.dart](../../poc/poc_20_macos_three_backends/lib/src/backend_policy.dart) — seleção
- [backend_contract.dart](../../poc/poc_20_macos_three_backends/lib/src/backend_contract.dart) — contrato

---

## 10. Trabalho restante

### 10.1 SkyLight (backend 1)

- [x] Extrair o consumidor de `probe.dart` para tipos pequenos com ownership
  explícito de porta, source, callback, região, contexto e janela —
  [`skylight_backend.dart`](../../poc/poc_20_macos_three_backends/lib/src/skylight_backend.dart).
- [x] Invalidar e liberar em ordem inversa — medido no CI, sem símbolo faltando.
- [x] `pointerMove`: era coalescência de mensagens Mach, não máscara de evento
  (§ 3.4). Resolvido com drenagem extra limitada fora do callback.
- [ ] Input físico (não sintético): mouse real, teclado real.
- [ ] IME, acessibilidade, clipboard, cursores, drag-and-drop.
- [ ] Reconciliação após Spaces, fullscreen, monitores, sleep/wake e restart
  do WindowServer.
- [ ] Tabela de símbolos/ABIs por versão do macOS com guarda e falha rápida.
- [ ] `_CFMachPortSetOptions(machPort, 0x40)` — semântica desconhecida; reproduzir
  por paridade e depois isolar por bisect.

### 10.2 Signal hijack (backend 2)

- [x] Resolver o pump síncrono de `nextEventMatchingMask:` — o pump periódico
  retira eventos sem bloquear e a cadeia de responders recebe eventos próprios
  via `[NSApp sendEvent:]`.
- [ ] Reenviar eventos *bombeados* pela cadeia de responders: o `NSEvent`
  devolvido é autoreleased e Dart não consegue retê-lo na main thread sem um
  método Objective-C próprio.
- [ ] Investigar se `NSEventThread` precisa ser criada explicitamente.
- [ ] Repetição start/stop do run loop.
- [ ] Múltiplas janelas.
- [ ] Coexistência com sleep/wake e troca de monitor.
- [ ] Medir custo de CPU do signal handler estacionado.

### 10.3 Host nativo (backend 3)

- [x] Spike embedder-vs-IPC: decidido por medição pelo worker com `IOSurface`.
- [ ] Trocar `IOSurfaceLookup` (deprecado) por mach port via XPC.
- [ ] Medir latência de input isoladamente do frame.
- [x] Transportar frames de CPU pelo protocolo IPC: três transportes medidos
  (`FRAME` por pipe, `SHM`, `SURFACE`/`IOSurface`). Falta Metal.
- [x] Input do host para o Dart: `INPUT=` do monitor local e `VIEW_INPUT=` da
  cadeia de responders.
- [ ] Lifecycle de dois processos: detecção de crash, restart, cleanup.

### 10.4 Comuns

- [x] Suíte de validação comum nos três backends: janela, present, testemunha
  externa de pixels, input e teardown, todos como gate do CI.
- [ ] Counter comum nos três backends.
- [ ] Matriz de robustez: duas janelas, framebuffer CPU + Metal, teclado, mouse,
  scroll, foco, captura, fullscreen/Spaces, dois monitores, sleep/wake,
  teardown limpo.
- [ ] Decisão do default para o framework.

---

## 11. Conclusão

A engenharia reversa avançou de zero a três backends macOS com evidência
verificável:

1. **SkyLight:** 12 ABIs de funções C privadas documentados com assinatura,
   método de validação e erros conhecidos. Janela, pixels e três eventos
   sintéticos `[10, 11, 5]` confirmados no CI obrigatório.

2. **Signal hijack:** shutdown recuperável comprovado com LLDB. O `CFRunLoopRun`
   retorna ao `_sigtramp` e a VM finaliza normalmente. A entrada permanece
   insegura por design — `CFRunLoopRun` não é async-signal-safe.

3. **Host nativo:** protocolo IPC v1 funcional com PING, SET_TITLE e CLOSE.
   Caminho recomendado porque resolve o problema de thread 0 por definição.

O gargalo único de todos os backends agora é **input de usuário real** (não
sintético) e a **integração do event loop Dart** com o loop nativo — tema da
proposta 04/05.
