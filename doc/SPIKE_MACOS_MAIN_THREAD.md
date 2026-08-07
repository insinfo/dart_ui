# Spike — propriedade da main thread no macOS (risco R02)

**Pergunta:** existe rota **100% Dart** — sem fonte C/C++/Objective-C, sem
shellcode, sem entitlement — para criar e operar uma janela no macOS?

**Resposta curta:** sim, duas rotas estão abertas e uma delas já criou uma
`NSWindow` de verdade. Ambas têm ressalvas sérias, documentadas abaixo.

**Prioridade deste spike:** funcionamento correto e recuperável nas versões de
macOS suportadas.

> Este documento registra **o que foi medido**, probe por probe. Para **como
> fazer** — as etapas da técnica, o código e as armadilhas catalogadas — veja
> [TECNICA_MAIN_THREAD_DART_FFI.md](TECNICA_MAIN_THREAD_DART_FFI.md).

## Contexto

O AppKit exige que `NSWindow` seja instanciada na **main thread do processo**, e
verifica isso com `pthread_main_np()`. O problema é que "main isolate" do Dart e
"main thread do processo" são coisas diferentes: a VM do Dart não entrega a
thread 0 ao código Dart.

## Ambiente medido

| Item | Valor |
| --- | --- |
| Runner | `macos-14`, arm64 |
| Dart SDK | 3.6.0 |
| Probes | [`poc/poc_03_appkit_window/bin/probe.dart`](../poc/poc_03_appkit_window/bin/probe.dart) |
| Workflow | [`.github/workflows/macos_mainthread_spike.yml`](../.github/workflows/macos_mainthread_spike.yml) (disparo manual) |

Reproduzir: `gh workflow run "macOS main-thread spike"`.

## Resumo dos resultados

| Probe | Hipótese | Resultado |
| --- | --- | --- |
| A | Algum modo de execução dá a thread 0 ao Dart | ❌ Refutada |
| B | `[NSApp run]` transfere a titularidade da main thread | ❌ Refutada |
| C | O WindowServer é alcançável sem AppKit (SkyLight/CGS) | ✅ Confirmada |
| D | Um sinal força a main thread a rodar um `CFRunLoop` | ✅ **Confirmada** |
| E | Com D, `NSInvocation` cria uma `NSWindow` legalmente | ✅ **Confirmada** |
| F | `nextEventMatchingMask:` bombeia a fila de eventos | ⛔ Trava |
| G | `[NSApp run]` aceita a main thread sequestrada | ❌ **Crash** |
| H | `SLSNewWindow` cria janela de verdade, sem AppKit | ✅ **Confirmada** |
| I | O runtime do Dart sobrevive a perder a thread 0 | ✅ **Confirmada** |
| J | Uma chamada feita na main thread alcança o isolate | ✅ **Confirmada** |
| K | O run loop estacionado serve `NSTimer` | ❌ **Refutada** |
| M | A rota C desenha pixels (`SLWindowContextCreate`) | ✅ **Confirmada** |
| N | A janela da rota C é fotografável de fora | ✅ **Confirmada** |
| O | A janela AppKit sobrevive com pump por timer | ❌ **Crash** |
| Z | A porta SkyLight registrada entrega input à rota C | ✅ **32 eventos** |

**Resumo em uma linha:** a rota C tem janela visível, desenho, prova externa e
input medido; a rota D+E chama AppKit, mas seu pump de `NSEvent` ainda bloqueia.

## A — nenhum modo de execução dá a thread 0

Os três modos foram medidos com o mesmo binário de probe:

```
----- JIT: dart run -----
pthread_main_np() = 0
----- dartaotruntime snapshot -----
pthread_main_np() = 0
----- AOT exe -----
pthread_main_np() = 0
```

Nos três, `pthread_main_thread_np()` devolve o mesmo handle (`8508018880`) — ou
seja, a main thread existe e está viva, apenas não é a nossa. **Não adianta
escolher modo de execução.**

## B — `[NSApp run]` não resolve

```
before run: pthread_main_np() = 0
sharedApplication = 5359317232
after sharedApplication: pthread_main_np() = 0
calling [NSApp run] ...
##[error]timed out after 2 minutes
```

`[NSApplication sharedApplication]` **funciona** fora da main thread (devolve
objeto válido), mas `run` não muda quem é a main thread: ele apenas consome a
thread do Dart para sempre, matando o event loop do isolate sem legalizar a
`NSWindow`. Entrar no loop do AppKit não confere titularidade de thread.

Pelo mesmo motivo não servem:

- `dispatch_sync_f(dispatch_get_main_queue(), ...)` — trava para sempre enquanto
  ninguém drena a main queue;
- `NativeCallable.isolateLocal` — aborta o processo se invocado por outra thread
  que não a do isolate que o criou;
- `NativeCallable.listener` — aceita chamada de qualquer thread justamente porque
  **devolve** o callback ao isolate do Dart, ou seja, as chamadas AppKit voltam
  para a thread errada.

## C — WindowServer direto, ignorando o AppKit ✅

`SkyLight.framework` (privado) carrega e responde de fora da main thread:

```
SkyLight.framework loaded.
  found   SLSMainConnectionID @ 6861799204
  found   SLSNewWindow @ 6859660788
  found   SLSOrderWindow @ 6859666908
  found   SLSSetWindowLevel @ 6859668192
  found   SLSFlushWindowContentRegion @ 6859667628
  found   CGSMainConnectionID @ 6861799204
  found   CGSNewWindow @ 6859660788
  missing SLSNewRegionWithRect
SLSMainConnectionID() = 39171 (pthread_main_np() = 0)
```

Detalhe útil: `CGSMainConnectionID` e `SLSMainConnectionID` têm o **mesmo
endereço**, assim como `CGSNewWindow`/`SLSNewWindow` — os nomes `CGS*` são
apenas aliases legados dos `SLS*`. Documentação e código antigos podem ser lidos
indistintamente.

Uma connection id não-zero significa que o processo fala com o WindowServer por
IPC, sem AppKit e **sem regra de main thread**.

### H — a janela foi criada de verdade ✅

A ABI dos headers `CGSInternal` estava correta, inclusive o `float` de 32 bits
em `x`/`y`:

```
CGSNewRegionWithRect -> CGError 0, region 105553158064720
SLSNewWindow         -> CGError 0, CGSWindowID 25
SLSSetWindowLevel    -> 0
SLSOrderWindow       -> CGError 0
```

Duas descobertas de nome que só a medição daria:

- o construtor de região é **`CGSNewRegionWithRect`**, com prefixo CGS mesmo —
  não existe versão `SLS`;
- ele **não aparece** na tabela de exports do SkyLight (`dyld_info -exports`),
  mas o `dlsym` no handle do SkyLight o encontra pela cadeia de dependências:
  o símbolo mora no CoreGraphics. Nem o `dyld_info` sozinho bastava.

O dump de exports também entregou **`SLWindowContextCreate`**, que é o criador
de contexto de desenho — a peça que faltava para essa rota ter janela *e*
superfície.

**Riscos:** é API privada — quebra entre versões do macOS e inviabiliza App
Store. E o problema maior não é criar a superfície, é **input**: sem
`NSApplication` não existe fila de `NSEvent`; a alternativa (`CGEventTap`) exige
permissão de acessibilidade concedida pelo usuário. Também se perde menus, IME e
acessibilidade "de graça".

**Veredito:** viável como superfície de renderização, insuficiente sozinha para
um framework de UI geral.

## D — sequestro da main thread por sinal ✅

Esta é a descoberta central.

**Mecanismo:** um sinal é entregue **na thread alvo**. Então basta instalar como
handler de `SIGUSR2` o **endereço da própria `CFRunLoopRun`** — uma função já
exportada, o que dispensa emitir código de máquina — e mandar `pthread_kill` na
main thread. Ela entra num `CFRunLoop`, que é exatamente o que drena a main
queue do libdispatch.

```
pthread_main_np() = 0
main pthread_t = 8508018880
CFRunLoopRun @ 6768354044
signal(SIGUSR2, CFRunLoopRun) -> previous handler 0
pthread_kill(main, SIGUSR2) -> 0
RESULT: main queue IS DRAINING
```

A verificação não usa nenhum callback Dart (que abortaria vindo de thread
estranha): enfileira-se `dispatch_semaphore_signal` como a **própria work
function** de `dispatch_async_f`, e espera-se o semáforo com timeout.

## E — `NSWindow` criada de Dart puro ✅

Com a main thread estacionada, a chamada proibida é empacotada como
`NSInvocation` e enviada com `performSelectorOnMainThread:`. Tudo permanece
dentro do runtime Objective-C: nenhum callback Dart e nenhum código de máquina
nosso roda em thread estranha.

```
pthread_main_np() = 0
main thread parked in CFRunLoop, main queue draining.
sharedApplication = 4829791552
[NSWindow alloc]  = 4561355920
NSMethodSignature = 105553126834432
NSInvocation      = 105553148856768
sending -invoke to the main thread...
-invoke returned without aborting.
NSWindow = 4561355920
RESULT: NSWindow CREATED AND ORDERED FRONT from pure Dart FFI
```

O ponteiro devolvido é o mesmo do `alloc` (`init` devolve `self`, como esperado)
e o `-[NSWindow _initContent:...]` que antes abortava o processo executou sem
reclamar.

Receita, em ordem:

1. `signal(SIGUSR2, &CFRunLoopRun)` e `pthread_kill(pthread_main_thread_np(), SIGUSR2)`;
2. confirmar a drenagem com `dispatch_async_f` + `dispatch_semaphore_signal`;
3. `[NSWindow alloc]` pode ser feito fora da main thread — só a inicialização é
   restrita;
4. `instanceMethodSignatureForSelector:` → `invocationWithMethodSignature:` →
   `setTarget:` / `setSelector:` / `setArgument:atIndex:` (argumentos declarados
   começam no índice 2) → `retainArguments`;
5. `performSelectorOnMainThread:@selector(invoke) withObject:nil waitUntilDone:YES`;
6. `getReturnValue:` para recuperar o objeto;
7. seletores com zero ou um argumento objeto (`makeKeyAndOrderFront:`) dispensam
   `NSInvocation` — vão diretos por `performSelectorOnMainThread:`.

## M/N — prova visual externa: a janela da rota C é real ✅

Todo resultado anterior era autodeclarado — o probe dizia ter criado a janela e
o mesmo probe confirmava. `screencapture(1)` fotografando **pelo CGSWindowID**
é uma testemunha que o probe não tem como falsificar:

```
=== probe: skylight-draw ===
SLSNewWindow          -> CGError 0, CGSWindowID 26
SLWindowContextCreate -> 105553150182336 (pthread_main_np() = 0)
filled 480x320 and flushed the context.

=== probe: hold-skylight ===
WINDOW_ID=27
skylight-window.png   pixelWidth: 480   pixelHeight: 320
skylight-screen.png   pixelWidth: 1920  pixelHeight: 1080
```

A captura de tela cheia mostra o retângulo azul (`0.1, 0.5, 0.9`) desenhado na
posição pedida, num desktop macOS completo com Finder, Dock e barra de menus —
e, ao lado, o diálogo *"probe quit unexpectedly"* do holder AppKit morrendo.

Duas consequências importantes:

1. **A rota C funciona de verdade**: janela visível, com pixels, criada e
   pintada inteiramente fora da main thread, sem AppKit em lugar nenhum.
2. **A hipótese "sessão headless" está morta.** O runner tem sessão gráfica
   completa a 1920x1080. Logo a trava do probe F e os crashes de G e O são
   problemas **reais da técnica**, não artefato do CI.

## K — o run loop estacionado não é um run loop completo ❌

O primeiro resultado de K (nil) era ambíguo: "timer nunca disparou" e "fila
vazia" liam idêntico, porque o buffer de retorno nasce zerado. Com um segundo
timer-testemunha chamando de volta no Dart:

```
pump timer scheduled on the main run loop.
witness timer scheduled on the main run loop.
witness timer fired 0 times
RESULT: the parked run loop never serviced a timer
```

Ou seja, `CFRunLoopRun` dentro de um handler de sinal **drena a main queue e
atende `performSelector`, mas não serve `NSTimer`**. É meio run loop.

## O — a janela AppKit crasha sob bombeamento ❌

Segurar a `NSWindow` viva com o pump por timer termina no mesmo trap do probe G:

```
NSWindow = 5553307568
WINDOW_ID=29
pump timer running; holding for 20s...
===== CRASH =====
si_signo=Trace/BPT trap: 5(5), si_addr=0x18ff61d08
```

Somado a G, o padrão fica claro: **é possível chamar APIs do AppKit na thread
sequestrada, mas não rodar a máquina de eventos dele ali**. Sem event loop não
há input, redesenho nem menus.

## I — o runtime do Dart sobrevive ao sequestro ✅

Com a thread 0 já entregue ao AppKit:

```
timer fired after 253ms -> true
async file I/O round trip -> true
Isolate.run -> 42 (true)
RESULT: the VM is unharmed by the hijack
```

Confirma a intuição por trás do desenho: roubamos uma thread que o Dart não
usava. Timers, I/O assíncrono e isolates novos seguem funcionando.

## J — o canal de volta (UI → Dart) ✅

`NativeCallable.isolateLocal` aborta quando invocado por thread estranha, mas
`.listener` existe exatamente para isso. Registrando uma classe Objective-C a
partir do Dart e instalando um `.listener` como IMP de um método dela
(`class_addMethod` com encoding `"v@:q"`), uma chamada feita **na main thread
sequestrada** chega ao isolate:

```
class registered, class_addMethod -> 1
invocation dispatched to the main thread (waitUntilDone: NO)
Dart received 12648430   (0xC0FFEE)
```

Armadilha registrada no código: o `waitUntilDone` **tem** que ser `NO`. O
`listener` entrega pelo event loop do isolate, então bloquear a thread do Dart
esperando a main thread trava o próprio mecanismo sob teste.

Com isso, delegates e handlers de evento podem ser escritos em Dart. Limitação:
`.listener` não retorna valor, então delegates que exigem resposta síncrona
(`windowShouldClose:` devolvendo `BOOL`) não cabem nele.

## G — `[NSApp run]` na thread sequestrada: crash ❌

```
sending -run to the main thread (waitUntilDone: NO)...
===== CRASH =====
si_signo=Trace/BPT trap: 5(5), si_addr=0x18b635d08
Abort trap: 6
```

O loop padrão do AppKit **rejeita** a thread nesse estado. Isso elimina o
desenho mais confortável e obriga o bombeamento manual de eventos.

## F — `nextEventMatchingMask:` trava ⛔

O ponto exato foi isolado por instrumentação:

```
[NSApp finishLaunching] returned.
channel alive after finishLaunching: [NSApp isRunning] = 0
event posted on the main thread.
<trava>
```

Ou seja: `finishLaunching` retorna, o canal de invocação continua vivo depois
dele, `postEvent:atStart:` funciona — e só o `nextEventMatchingMask:` nunca
volta, mesmo com `[NSDate distantPast]`.

Duas hipóteses ainda abertas, nesta ordem de suspeita:

1. **Reentrância** — `performSelectorOnMainThread:` entrega por uma source do
   run loop, então o pump estaria rodando um run loop aninhado de dentro de um
   callback de run loop. É o que o probe K testa, disparando a `NSInvocation`
   por um `NSTimer` (que a executa direto na main thread, sem `performSelector`
   no caminho).
2. **Sessão headless** — o runner de CI pode não ter sessão gráfica que entregue
   eventos. `SLSMainConnectionID` responde, mas a conexão de *eventos* é outra.
   Esta hipótese não é testável no CI: ela **é** o ambiente do CI.

Enquanto F não fechar, **input continua não provado nas duas rotas**.

### Ressalvas antes de adotar como arquitetura

- A main thread fica presa **dentro de um handler de sinal**, para sempre. O
  `SIGUSR2` permanece bloqueado nela.
- O shutdown normal do processo deixa de existir: é preciso sair por `_exit()`.
  Handlers de `atexit` e finalização da VM não rodam.
- A VM do Dart não sabe que perdeu a main thread. Não foi medido o efeito sobre
  profiler, service protocol e sinais que a VM usa.
- **Falta o input.** `CFRunLoopRun` puro não distribui `NSEvent`; isso é
  trabalho de `[NSApp run]`, que crasha nessa thread (probe G), e o bombeamento
  manual trava (probe F). Este é o item que decide se a rota vira arquitetura.
- Não foi verificado se a janela é realmente **visível** num display real; o
  runner de CI é headless.

## Por que shellcode não entra nesta conta

Emitir código de máquina resolveria "não ter compilador no build", **não** "quem
é a thread 0" — o valor de um host nativo está em *ser* o `main()`, e código
gerado em runtime pelo Dart já nasce depois da VM, na thread errada. Além disso,
no Apple Silicon há W^X: memória anônima só vira executável com `MAP_JIT` +
`pthread_jit_write_protect_np()`, o que exige o entitlement
`com.apple.security.cs.allow-jit` e, portanto, assinatura de código — uma etapa
de toolchain nativa, justamente o que se queria evitar.

A rota D dispensa tudo isso porque o handler é o endereço de uma função **já
exportada** e o resto é `NSInvocation`.

## Arquitetura que os resultados sustentam

```
thread 0 (sequestrada)          isolate principal            isolate de bombeamento
├─ CFRunLoopRun                 ├─ lógica, estado, layout    └─ (se necessário) bloqueia
├─ objetos AppKit               ├─ I/O, timers ✅ (probe I)      no pump sem travar
└─ executa NSInvocation ✅      └─ SendPort ↔ pump               o isolate principal
        ▲                                 │
        └── Dart → UI: performSelectorOnMainThread: ✅ (probe E)
        └── UI → Dart: NativeCallable.listener como IMP ✅ (probe J)
```

Tudo nesse diagrama está medido, **exceto** a origem dos eventos.

## P — input pela conexão do WindowServer (em andamento)

O dump de exports entregou a API de eventos inteira. As mais promissoras:

```
_SLEventCreateNextEvent   _SLEventCopyNextEvent    _SLSGetNextEventRecord
_SLSGetEventPort          _SLEventTapCreate        _SLEventTapPostEvent
_SLEventGetType  _SLEventGetLocation  _SLEventGetFlags
_SLEventKeyboardGetUnicodeString
```

O padrão de nomes confirma que `SLEvent*` espelha `CGEvent*` (existe
`SLEventCreateKeyboardEvent` ao lado do público `CGEventCreateKeyboardEvent`),
então o objeto devolvido deve ser um `CGEventRef` inspecionável.

Primeira tentativa crashou, e o endereço da falha diz exatamente o quê:

```
SLSMainConnectionID() = 182931
===== CRASH ===== Segmentation fault: SEGV_ACCERR, si_addr=0x2ca93
```

`0x2ca93` é 182931 — o próprio connection id, desreferenciado como ponteiro por
`SLSGetEventPort(cid)`. Assinatura errada, não conceito errado.

**Custo registrado desta rota:** cada assinatura de API privada é um chute que
se paga com um crash. Não há header, e o `dyld_info` dá o nome mas não os tipos.
Isso é fricção permanente da rota C, não um obstáculo pontual.

## L — a stack sample explica todas as anomalias de uma vez 🔑

`sample(1)` na process main thread durante o probe, 612 amostras em 1 segundo:

```
612 Thread_11491   DispatchQueue_1: com.apple.main-thread  (serial)
+ 612 start (in dyld)
+   ...
+     612 Dart_RunLoop (in probe) + 352
+       612 _pthread_cond_wait (in libsystem_pthread.dylib)
+         612 __psynch_cvwait (in libsystem_kernel.dylib)
```

**612 de 612 dentro de `Dart_RunLoop` → `pthread_cond_wait`.** A main thread
nunca ficou estacionada no `CFRunLoopRun`. O que aconteceu foi: o handler
chamou `CFRunLoopRun`, ele drenou o que estava pendente, não encontrou nenhuma
source persistente, retornou `kCFRunLoopRunFinished`, e a VM retomou a thread.

Isso reinterpreta **todos** os resultados anteriores de forma coerente:

| Observação | Explicação |
| --- | --- |
| D drenou a main queue | dentro da janela curta em que o loop rodou |
| E criou a `NSWindow` | aconteceu cedo, na mesma janela |
| F trava | o `performSelector` chegou depois que o loop saiu |
| K não vê timer | não há loop rodando para servi-los |
| L trava no marcador | idem, e o log para exatamente ali |

Ou seja, a conclusão anterior ("o run loop estacionado é meio run loop") estava
errada no mecanismo: **não há run loop estacionado nenhum**. Foi a stack sample
sugerida em `doc/propostas/03` que revelou isso — nenhum probe anterior
conseguiria, porque todos observavam de fora.

**Correção candidata (probe R):** `CFRunLoopRun` só retorna quando o loop não
tem *nenhuma* source ou timer. Anexar uma source versão 0 nunca sinalizada
antes do sinal deve impedir o loop de terminar. `CFRunLoopAddSource` é
thread-safe, então dá para fazer isso da thread do Dart.

## Q — registro de processo não bastou

```
SLPSGetCurrentProcess         -> 0   psn=(0, 237626)
SLPSEnableForegroundOperation -> 0
SLPSSetFrontProcess           -> 0
SLPSStealKeyFocus             -> 0
events received: 0
```

Todas as quatro chamadas retornaram sucesso — as assinaturas estão certas — e
ainda assim nenhum evento em 12s. Falta mais do handshake PSN
(`SLPSRegisterWithServer`, `SLPSSetMainApplicationConnection`) ou a entrega
depende de algo que só um app bundle registrado no LaunchServices tem.

## Veredito atual

**A rota C passou à frente.** Ela não tem AppKit no caminho, logo não tem
assertion de thread para violar — e é a única com prova visual externa. Falta
input.

**A rota D+E está severamente comprometida como arquitetura.** Ela cria janela e
o canal bidirecional com o Dart funciona, mas tudo que tenta *rodar* o AppKit na
thread sequestrada morre: `[NSApp run]` crasha (G), o bombeamento por
`performSelector` trava (F), o bombeamento por timer nem dispara (K) e o
processo crasha ao segurar a janela (O). Serve para chamadas pontuais de AppKit,
não para operar uma aplicação.

**O host nativo mínimo volta a ser a alternativa mais robusta** para quem quiser
AppKit de verdade — com a ressalva, agora medida, de que a rota C entrega janela
e pixels sem ele.

## Atualização pós keep-alive (probe R/T, run `31082398267`)

A keep-alive source **funciona**: sample mostra
`_sigtramp -> CFRunLoopRun -> mach_msg`, e um timer repetiu 39 vezes em 3s.
O bisect T mostrou que `sharedApplication`, `setActivationPolicy:` e
`finishLaunching` **não matam** o loop (+12 ticks depois de cada um).

Isso reabre F/K/O como testes genuínos (antes mediam um loop que já tinha
saído). Resultados ainda abertos depois do keep-alive:

| Probe | Depois do keep-alive |
| --- | --- |
| R keepalive | ✅ loop real, timers disparam |
| T appkit-bisect | ✅ init AppKit não mata o loop |
| K pump-timer | witness 0 ticks (suspeito: pump agendado *antes* do witness e `nextEvent` trava a main) |
| F event-pump | ⛔ ainda trava em `nextEventMatchingMask:` via `waitUntilDone:YES` |
| O hold-appkit | ❌ mesmo Trace/BPT de G logo após o pump timer |
| Q/P skylight input | 0 eventos mesmo com SLPS* |

**Medido depois disso:**

- **U** ✅ NSWindow sobrevive 8s sem pump (110 ticks). Crash O = o pump.
- **K/F** ✅/⛔ timers disparam; `nextEventMatchingMask:` **bloqueia** mesmo com
  `distantPast` (sentinel permanece). Rota D cria janela mas não bombeia.
- **X** TransformProcessType=0, Front=0, ainda **0 eventos**.
- Dump SkyLight 2016 (`referencias/skylight.txt` = gist erica) ainda casa:
  `SLPSRegisterWithServer` e `SLPSSetMainApplicationConnection` são **T**
  exportados — o meio do handshake que Q/X pularam → probe **Y**.
- **lldb no hold-appkit (O):** o Trace/BPT é
  `NSAssertMainEventQueueIsCurrentEventQueue` — não é `pthread_main_np`.
  A thread 0 está certa; a **event queue** do AppKit não. Por isso U (sem
  pump) vive e O/G (com `nextEvent` / `-run`) morrem.
- **Y v1:** `SLSGetEventPort(c)` como retorno-por-valor ainda SEGV com
  `si_addr==cid`. Próximo chute: `CGError SLSGetEventPort(cid, mach_port_t*)`.

## Atualização pós `finishLaunching` na main (run `31150976455`) 🔑

Foi implantada a hipótese da seção lldb: **`sharedApplication` + `finishLaunching`
passaram a ser criados SEMPRE na main thread estacionada** (`_sharedAppOnMain` /
`_finishLaunchingOnMain`), nunca na thread do Dart. O crash O **sumiu**:

- **lldb hold-appkit (O):** rodou até o cap de 30s **sem parar** — antes morria
  em `NSAssertMainEventQueueIsCurrentEventQueue`/
  `NSCrashOnBackgroundThreadMainEventQueue`. A criatura da event queue era o
  `sharedApplication` criado fora da main, não o pump em si.
- **K/F:** agora travas legais e mensuráveis. witness dispara 9x, o pump
  **bloqueia** em `nextEventMatchingMask:` com o sentinel intacto — a main thread
  ficou esperando eventos que nunca chegam, em vez de crashar.
- **O (CI):** 20s seguros, `distinct events pumped: 0` — sem Trace/BPT.

Ou seja: **a rota D+E ganhou o direito de *rodar* o AppKit** (sem crash), mas
ainda **não tem o que *rodar* — a fila de eventos continua vazia**. A entrega
de eventos continua sendo o gargalo único, agora isolado do crash.

### A porta entregou eventos (probe Y, run `31154591354`) 🔑

```
SLSGetEventPort -> rc=0 port=15367
SLPSRegisterWithServer(psn) -> -50
SLPSSetMainApplicationConnection(psn, cid) -> 1003
SLPSSetMainApplicationConnection(cid, 0) -> -600
SLPSRegisterWithServer(eventPort=15367) -> 0
event-port summary: callbacks=12 events=32
sampledTypes=[13, 21, 10, 11, 5, 10, 11, 5, ...]
```

O resultado corrige a hipótese anterior: o ponteiro PSN certamente não é o
argumento observado. O consumidor sem registro montou `CFMachPort` e
`CFRunLoopSource`, recebeu sinal e então bloqueou ao chamar
`SLEventCreateNextEvent`; o hard cap do workflow o matou e preservou o sample.
No probe Y, uma chamada posterior escrita como
`SLPSRegisterWithServer(eventPort)` retornou 0 e a mesma rotina drenou 32 eventos.
Os tipos `10/11` correspondem ao par de teclado sintético e `5` ao movimento de
mouse postado pelo probe.

O [run 31155012538](https://github.com/insinfo/dart_ui/actions/runs/31155012538)
refutou a leitura literal desse argumento: isolada, a chamada com `eventPort`
retornou `-50`. O sucesso de Y depende da sequência anterior ou de argumentos
adicionais que o typedef de um parâmetro não inicializa. O
[stub do Darling](https://github.com/darlinghq/darling/blob/6efdaf4246ef01da66ebb57f27c5645d6cf95b4c/src/private-frameworks/SkyLight/include/SkyLight/SkyLight.h)
declara `SLPSRegisterWithServer(void)`, insuficiente como prova mas compatível
com argumentos extras simplesmente ignorados. **Z4**
testa o ABI sem argumentos com retry imediato; o workflow também para no símbolo
sob LLDB, registra `x0...x7` e desassembla a implementação do macOS 14.

O [run 31155345682](https://github.com/insinfo/dart_ui/actions/runs/31155345682)
mostrou que o stub público estava incompleto: a implementação faz
`mov x19, x0`, registra no log `flavor=%d` e chama
`_SLPSRegisterWithServer(x0, &gOurPSN, getpid(), processName)`. Portanto o ABI
externo é `CGError SLPSRegisterWithServer(int flavor)`. A primeira chamada de
Z4, com `x0` indefinido, retornou `-50`; a segunda retornou 0 porque a primeira
já havia preenchido `gOurPSN`, mas isso não bastou: `callbacks=0 events=0`.
O próximo breakpoint executa a rota AppKit testemunha e lê o flavor verdadeiro
em `x0` antes de adotá-lo no probe Dart.

No [run 31155621950](https://github.com/insinfo/dart_ui/actions/runs/31155621950),
o wrapper público não foi chamado pela testemunha AppKit; o processo terminou
sem atingir o breakpoint. **Z6** move a interrupção para
`_SLPSRegisterWithServer`, destino interno comprovado pelo desassembly do wrapper.

O [run 31155876163](https://github.com/insinfo/dart_ui/actions/runs/31155876163)
fechou o argumento: AppKit chamou `_SLPSRegisterWithServer` pela cadeia
`NSApplication -> HIServices GetCurrentProcess -> _RegisterApplication` com
`x0=3`, `x1=&sOurASN`, `x2=getpid()` e `x3=appName`. Isso confirma
`SLPSRegisterWithServer(int flavor)` e fornece o valor observado no macOS 14:
**flavor 3**. Z7 passou a fazer uma única chamada tipada com esse valor.

Z7, no [run 31156204562](https://github.com/insinfo/dart_ui/actions/runs/31156204562),
retornou 0 mas bloqueou na primeira drenagem, sem produzir evento. Logo esse
registro pertence ao cadastro do processo feito por HIServices/AppKit, não ao
handshake do consumidor da porta. A comparação linha a linha revelou a etapa
que ainda faltava: JankyBorders executa seus `SLSRegisterNotifyProc` **antes**
de `SLSGetEventPort` e não chama `SLPSRegisterWithServer` nesse caminho.

## Próximos passos

Uma pesquisa externa dirigida em 2026-08-07 encontrou uma implementação atual
do caminho de eventos e mudou a ordem destes experimentos. Veja a seção a
seguir: antes de continuar chutando o ABI de `SLPS*`, é preciso corrigir duas
diferenças objetivas entre o probe e o consumidor conhecido.

1. **Probe Z1 — confirmado no CI:** ABI de
   `SLEventCreateNextEvent` corrigido para
   `CGEventRef SLEventCreateNextEvent(int cid)`, sem `CFAllocatorRef`.
2. **Probe Z2 — confirmado no CI:** envolver o
   `mach_port_t` de `SLSGetEventPort(cid, &port)` em `CFMachPort`, criar uma
   `CFRunLoopSource` e drenar `SLEventCreateNextEvent(cid)` quando a porta
   sinalizar. O callback deve ser mínimo: copiar/reter os dados necessários e
   notificar o isolate, sem criar, destruir ou redesenhar janelas ali dentro.
   O workflow agora impõe um hard cap, coleta `sample` e mata o processo se uma
   chamada privada voltar a bloquear.
3. **Probe Z3 — refutado no CI:** `SLPSRegisterWithServer(eventPort)` isolado
   retornou `-50`; não chamar `SLEventCreateNextEvent` depois dessa falha evita o
   bloqueio observado na rodada anterior.
4. **Probe Z4 — refutado, ABI recuperado:** retry sem argumentos produz estado
   parcial, mas zero callbacks. O desassembly prova um argumento `int flavor`.
5. **Probe Z5 — inconclusivo:** AppKit não chamou o wrapper público.
6. **Probe Z6 — confirmado:** o flavor usado por AppKit no macOS 14 é `3`.
7. **Probe Z7 — refutado:** flavor 3 retorna sucesso, mas não habilita a fila.
8. **Probe Z8 — em CI:** reproduzir `events_register(cid)` com os 13 tipos do
   JankyBorders antes de obter a porta, sem chamar `SLPSRegisterWithServer`.
9. Depois de fechar o ABI, extrair o consumidor para uma classe pequena,
   com ownership explícito de porta/source/callback e fechamento ordenado.
10. Manter `CGEventTap` como plano B público para captura global. Eventos de
   teclado exigem acesso assistivo conforme a documentação da Apple.
11. Decorações, menus, IME e acessibilidade: medir o que a rota C perde ao abrir
   mão do AppKit e o que o framework precisaria reimplementar.
12. Depois de fechar input, promover a prova a um teste de robustez: reconciliação
   após fullscreen/Spaces/sleep, resize contínuo, múltiplos monitores e uma
   segunda ferramenta que também mova janelas. Sucesso pontual não é critério de
   conclusão.

## Pesquisa externa dirigida — 2026-08-07

### Achado principal: existe uma receita executável e atual

O [JankyBorders](https://github.com/FelixKratz/JankyBorders) contém o caminho
completo usado hoje para consumir a porta de eventos do SkyLight. Seus headers
declaram:

```c
CGError   SLSGetEventPort(int cid, mach_port_t *port_out);
CGEventRef SLEventCreateNextEvent(int cid);
```

E o `main` faz, nesta ordem:

```text
SLSMainConnectionID
  -> SLSRegisterNotifyProc(...)
  -> SLSGetEventPort(cid, &port)
  -> CFMachPortCreateWithPort(port, callback)
  -> _CFMachPortSetOptions(machPort, 0x40)
  -> CFMachPortCreateRunLoopSource
  -> CFRunLoopAddSource(..., kCFRunLoopDefaultMode)
  -> CFRunLoopRun

callback da porta:
  repetir SLEventCreateNextEvent(cid) até retornar NULL
```

Cada drenagem agora abre e fecha um pool com
`objc_autoreleasePoolPush/Pop`. A [issue SDL #14256](https://github.com/libsdl-org/SDL/issues/14256)
mostra `_NSCGEventBuffer` e mensagens privadas de autenticação do SkyLight sendo
autoreleased durante input; sem pool na thread consumidora, o processo perde
memória rapidamente mesmo liberando o `CGEventRef`.

Há outra restrição menos óbvia: `SLEventCreateNextEvent` processa datagramas
laterais. Um [backtrace do R-SIG-Mac](https://stat.ethz.ch/pipermail/r-sig-mac/2020-August/013663.html)
mostra essa chamada passando por `CGSSnarfAndDispatchDatagrams`, notificando
mudança do Dock/telas e atingindo uma asserção porque `NSScreen` foi invalidado
fora da main thread. Portanto a rota C não deve inicializar AppKit no isolate
que drena SkyLight; se ambos forem combinados, efeitos AppKit precisam ser
entregues à main thread.

Fontes exatas:

- [declarações de ABI](https://github.com/FelixKratz/JankyBorders/blob/a7297ca7d1933f3a30b12e8f10750e8d84eeee1e/src/misc/extern.h);
- [montagem da porta e da run-loop source](https://github.com/FelixKratz/JankyBorders/blob/a7297ca7d1933f3a30b12e8f10750e8d84eeee1e/src/main.c);
- [registro e tipos das notificações](https://github.com/FelixKratz/JankyBorders/blob/a7297ca7d1933f3a30b12e8f10750e8d84eeee1e/src/events.c).

O projeto Rust [edges](https://github.com/pablopunk/edges/blob/7bc134760b5facdce5e5b5b264d4d9e5b4feb770/src/events.rs)
reproduz a mesma sequência e explicita o encadeamento
`SLSGetEventPort -> CFMachPort -> CFRunLoop -> SLEventCreateNextEvent`. Ele não é
evidência totalmente independente — declara que segue o JankyBorders —, mas é
uma segunda tradução útil para conferir tipos, ownership e callback.

### Consequência para P/Q/X/Y: os resultados de zero eventos são inconclusivos

O probe atual declara:

```dart
Pointer<Void> Function(Pointer<Void> allocator, Int32 cid)
```

e chama `SLEventCreateNextEvent(nullptr, connectionId)`. A assinatura observada
nos consumidores atuais tem **um único argumento**, o `cid`. No ABI arm64, o
probe põe `nullptr` em `x0` e o connection id em `x1`; uma função de um argumento
lê `x0`, portanto recebe conexão `0`. Isso explica o retorno vazio sem precisar
postular falha de registro PSN.

Além disso, Y já provou a assinatura correta de `SLSGetEventPort` e recebeu uma
porta Mach válida, mas apenas registrou seu número. A implementação conhecida
instala essa porta como source do `CFRunLoop` e só chama
`SLEventCreateNextEvent(cid)` dentro do callback disparado por uma mensagem.
Logo, polling com ABI errado **e** sem drenar a porta não testa o mecanismo que
um consumidor funcional usa.

O valor `0x40` passado a `_CFMachPortSetOptions` continua sem semântica pública.
Deve ser reproduzido no primeiro teste por paridade e depois isolado por bisect;
não deve ser transformado em constante arquitetural sem essa medição.

### Issue 62: a porta funciona, mas é uma região crítica

A discussão da
[issue 62 do JankyBorders](https://github.com/FelixKratz/JankyBorders/issues/62?timeline_page=1)
registra a evolução de um consumidor real sob carga. Ela acrescenta quatro
restrições importantes à receita acima:

1. O callback da porta precisa drenar `SLEventCreateNextEvent(cid)` até `NULL`.
   Deixar trabalho pendente altera a ordem observável dos eventos.
2. Trabalho caro dentro do callback permite que um evento do WindowServer
   ultrapasse uma mensagem Mach relacionada. Isso produziu frames errados e
   flicker durante animações interceptadas.
3. Criar uma janela SkyLight de dentro desse caminho reentrante chegou a
   quebrar em `SLSWMBridgePerformTransaction`/
   `SLSWindowManagementFallbackBridge`. O projeto moveu criação para a main
   thread, serializou operações com mutexes e, posteriormente, passou a usar
   conexões SLS separadas para as janelas de borda.
4. Mensagens próprias do yabai foram movidas para **outra porta Mach**, em vez
   de compartilhar a porta de eventos do WindowServer. O desenho atual mantém
   o callback SkyLight apenas como dreno de eventos.

Commits que isolam essas correções:

- [criação da proxy na main thread](https://github.com/FelixKratz/JankyBorders/commit/404cf26426ee);
- [mutex em todas as operações que alcançam o SLSWMBridge](https://github.com/FelixKratz/JankyBorders/commit/745d4816e77d);
- [porta separada para mensagens do yabai](https://github.com/FelixKratz/JankyBorders/commit/6b08d5875160);
- [coalescing e limite da fila da porta própria](https://github.com/FelixKratz/JankyBorders/commit/2c7f0488a80e);
- [conexão SLS dedicada por borda](https://github.com/FelixKratz/JankyBorders/commit/18086e4fe15e).

**Regra para Z2:** o callback de `CFMachPort` é transporte, não lugar para
executar a UI. Com `NativeCallable.listener`, ele pode apenas acordar o isolate;
o isolate drena/copia os `CGEventRef` e agenda qualquer mutação de janela fora
da pilha do callback. Se for preciso mandar IPC próprio, deve existir uma porta
separada.

### Issues atuais: critérios de correção, não documentação de ABI

Os issues abertos do JankyBorders e do yabai são valiosos como telemetria de
regressão. Eles não provam sozinhos a causa descrita pelo autor, mas fornecem
cenários que o backend precisa sobreviver:

| Evidência atual | O que transforma em requisito |
| --- | --- |
| [JankyBorders #199](https://github.com/FelixKratz/JankyBorders/issues/199): borda corrompida durante resize no macOS 26.5; o mantenedor indicou correção na 1.9.0. | Resize contínuo precisa de coalescing, teste visual e verificação após o fim do gesto. |
| [JankyBorders #200](https://github.com/FelixKratz/JankyBorders/issues/200): na 1.9.0, algumas janelas deixam de ser reconhecidas; um comentário suspeita de um filtro de elegibilidade. | Não inferir existência/foco a partir de uma única notificação ou filtro. Reconciliar inventário e foco com consultas periódicas. |
| [JankyBorders #201](https://github.com/FelixKratz/JankyBorders/issues/201): borda às vezes some ao sair de fullscreen no macOS 27 beta. | Fullscreen/Spaces são transições de estado; ao final delas, reconsultar ordem, bounds e transform, recriando a superfície se necessário. |
| [JankyBorders #188](https://github.com/FelixKratz/JankyBorders/issues/188): relatos de custo de GPU atribuído ao WindowServer no Tahoe 26.2, com resultados diferentes por app. | Medir CPU/GPU/WindowServer por cenário e impor limite de redraw; ausência de crash não basta. |
| [yabai #2785](https://github.com/asmvik/yabai/issues/2785): conflito ao abrir Time Machine. | Detectar controladores/transições do sistema e evitar disputar continuamente o mesmo estado. |
| [yabai #2811](https://github.com/asmvik/yabai/issues/2811): relato ainda não confirmado de loop entre yabai e `WindowManager` no macOS 26.3.1. | Toda correção de posição deve ser idempotente, ter tolerância, limite de tentativas e circuit breaker; nunca responder indefinidamente à correção de outro controlador. |

Há outra classe de falha que **não deve ser atribuída à API exportada do
SkyLight**. Em [yabai #2800](https://github.com/asmvik/yabai/issues/2800) e
[yabai #2802](https://github.com/asmvik/yabai/issues/2802), o que quebrou no
macOS 27 foi a scripting addition injetada no Dock: verificação explícita da
versão, padrões de bytes e offsets internos. O relato da #2802 mostra sete
assinaturas de funções do Dock, cinco ainda iguais às do macOS 26 e duas que
precisaram de novos padrões; também registra que os offsets mudam entre betas.
Isso é evidência forte contra importar injeção/pattern scanning para a rota
principal, mas não demonstra que `SLSGetEventPort` ou outro símbolo exportado
tenha mudado de ABI. Já a [yabai #2799](https://github.com/asmvik/yabai/issues/2799)
confirma que até uma atualização 26.6 exigiu correção para operações de Spaces.

#### Contrato operacional proposto para o backend

1. Na inicialização, resolver cada símbolo com `dlsym` e publicar uma tabela de
   capacidades por versão/build. Uma função ausente desabilita apenas a feature
   correspondente; não se chama endereço presumido.
2. Manter conexão/porta de eventos separada das conexões usadas para criar e
   mutar janelas. Serializar operações que chegam ao `SLSWMBridge` e nunca
   executá-las dentro do callback da porta.
3. Tratar eventos como sinais de invalidação, não como estado autoritativo. O
   isolate mantém estado desejado e reconcilia ordem, bounds e transform após
   rajadas e transições do sistema.
4. Coalescer move/resize por janela, limitar a fila e descartar trabalho
   obsoleto. Aplicar mudanças idempotentes, com tolerância geométrica e limite de
   repetição para impedir feedback loops.
5. Ter recuperação explícita: se uma janela ficar ausente, corrompida ou a
   conexão falhar, retirar a surface antiga, reabrir conexão/janela e reaplicar
   o estado desejado. Registrar a causa e o número de recuperações.
6. Só declarar suporte a uma versão/build depois de testes funcionais e soak:
   input, resize, fullscreen, Spaces, sleep/wake, troca de monitor/escala, screen
   sharing, Time Machine e coexistência com outro gerenciador. Medir também
   CPU/GPU do processo e do WindowServer.

Para cumprir esse contrato, o probe deve registrar ao menos: versão e build do
macOS, arquitetura, símbolos encontrados, connection/window ids, profundidade
máxima da fila, eventos coalescidos/descartados, reconciliações, recriações e
latência entre evento e frame. Esses dados distinguem uma regressão de ABI de
uma falha de ordenação ou de desempenho.

A issue também recupera APIs úteis para uma etapa futura de animação e
diagnóstico, mas não necessárias para fechar input:

```c
CGError SLSGetWindowOwner(int cid, uint32_t wid, int *owner_cid);
CGError SLSConnectionGetPID(int cid, pid_t *pid);
CGError SLSCopyConnectionProperty(
    int cid, int target_cid, CFStringRef key, CFTypeRef *value);
CGError SLSGetWindowBounds(int cid, uint32_t wid, CGRect *frame);
CGError SLSGetWindowTransform(
    int cid, uint32_t wid, CGAffineTransform *transform);
```

O yabai marca a relação proxy → janela real por propriedade da conexão; o
JankyBorders lê essa relação, acompanha transformações e usa `SLSTransaction*`
para trocar alpha/transform de várias janelas atomicamente. A solução animada
usou `CVDisplayLink` para sincronizar o polling com frames. Isso é evidência de
viabilidade, não uma recomendação atual: a família `CVDisplayLink` está
deprecada no SDK moderno em favor de display links de `NSView`, `NSWindow` ou
`NSScreen` — alternativas que voltam a depender do AppKit.

### O que essa receita prova — e o que ainda não prova

- Prova o ABI de `SLSGetEventPort` e `SLEventCreateNextEvent` em software
  contemporâneo e fornece o elo que faltava entre a porta Mach e o run loop.
- Prova uma rota para notificações internas do WindowServer
  (`SLSRegisterNotifyProc`: criação, movimento, resize, Spaces e front app).
- Ainda **não prova** que uma janela SkyLight própria receberá mouse/teclado. O
  JankyBorders observa janelas de terceiros; o teste Z precisa inspecionar o
  `CGEventRef` antes de liberá-lo e confirmar eventos dirigidos à nossa janela.
- Não prova os ABIs de `SLPSRegisterWithServer` nem
  `SLPSSetMainApplicationConnection`. Os repositórios encontrados que contêm
  esses nomes são em geral stubs sem tipos ou arquivos `.tbd`, que confirmam
  exportação, não assinatura.

### Pista para a rota AppKit

O [HookCase](https://github.com/steven-michaud/HookCase/blob/896ed6c9fe86862534a2d79b90910e63a9d738e0/Examples/events/hook.mm)
documenta, por instrumentação, o pipeline histórico: uma `NSEventThread` chama
o consumidor de eventos SkyLight, coloca o `CGEvent` numa fila e mais tarde a
main thread converte e publica o evento na fila principal. Embora os nomes
internos tenham mudado entre versões, isso explica por que apenas bombear
`nextEventMatchingMask:` na main thread não substitui necessariamente a etapa
produtora. É uma pista forte para amostrar/backtracear também a
`com.apple.NSEventThread` num app AppKit testemunha.

### Valor dos materiais enviados

| Material | Valor para este spike |
| --- | --- |
| [NUIKit/CGSInternal](https://github.com/NUIKit/CGSInternal) | Melhor catálogo de tipos CGS/SLS para janelas, conexões, regiões e eventos; cada assinatura ainda deve ser validada na versão-alvo. |
| [yabai](https://github.com/asmvik/yabai) e [issue 148](https://github.com/asmvik/yabai/issues/148) | Código real e atual para Spaces/janelas; a issue é especialmente útil para `SLSTransaction*`, transformações e animações, não para input de uma app própria. |
| [JankyBorders](https://github.com/FelixKratz/JankyBorders) | Referência mais diretamente útil encontrada: resolve exatamente a porta de eventos que Y descobriu. |
| [dump de símbolos de Erica Sadun](https://gist.github.com/erica/448a71ae1aa5156ce9703dac747e2cec) | Excelente índice de nomes e relações históricas; não contém tipos e é de 2016. |
| [RET2: WindowServer](https://blog.ret2.io/2018/08/28/pwn2own-2018-sandbox-escape/) | Confirma o bootstrap `dlopen`/`dlsym`, `CGSNewConnection` e IPC Mach; é pesquisa de exploração em 10.13, não contrato de ABI moderno. |
| [Apriorit: API não documentada](https://www.apriorit.com/dev-blog/778-reverse-engineering-undocumented-macos-api) | Bom roteiro de Ghidra/LLDB e de reconstrução de call sites; o caso estudado não é SkyLight. |
| [catálogo de reversing de 0xdevalias](https://gist.github.com/0xdevalias/256a8018473839695e8684e37da92c25) | Índice amplo de ferramentas; útil como caixa de ferramentas, não como fonte de assinatura. |
| [Google/Mandiant: reversing de Cocoa](https://cloud.google.com/blog/topics/threat-intelligence/introduction-to-reve/) | Útil para reconstruir xrefs entre seletores e IMPs e localizar `NSApplicationMain`/delegate. O helper apresentado é x86_64 e Objective-C; não recupera ABIs das funções C do SkyLight. |
| [JankyBorders issue 62](https://github.com/FelixKratz/JankyBorders/issues/62?timeline_page=1) | Muito útil para concorrência, ownership de conexões, `SLSTransaction*`, transformações, IPC Mach separado e falhas reais no `SLSWMBridge`. |
| [SDL issue 14256](https://github.com/libsdl-org/SDL/issues/14256) | Evidência direta de autoreleases privados durante o consumo de input SkyLight; exige pool explícito em threads não gerenciadas pelo AppKit. |
| [R-SIG-Mac: rgl/base graphics](https://stat.ethz.ch/pipermail/r-sig-mac/2020-August/013663.html) | Backtrace causal: o dreno SkyLight despacha notificações de tela/Dock e pode alcançar AppKit fora da main thread. |
| [BetterTouchTool: save/restore layout](https://community.folivora.ai/t/saving-restoring-window-layout/21249) | Confirma a cadeia `CFRunLoop -> SLEventCreateNextEvent -> CGSSnarfAndDispatchDatagrams`, mas o relatório é de excesso de wakeups em AppleScript e não revela novo ABI. |
| Relatos Apple Community, Adobe, ChimeraX e SourceTree enviados | Úteis como casos para a matriz de regressão (sleep/display/IME), mas crashes de terceiros sem call site controlado não são usados para inferir assinatura privada. |
| [historicalsource/supermario](https://github.com/historicalsource/supermario) | Fonte do System 7 clássico, 68k/PPC/Toolbox. Pode ensinar arqueologia e comparação de binários, mas seu Window/Event Manager não é ancestral de ABI compatível com Quartz/SkyLight. O próprio projeto descreve a origem como fontes “passed around”; não deve ser tratado como SDK oficial/licenciado para copiar código. |
| [MacOS9-USB2-EHCI](https://github.com/UnexpectedBomb/MacOS9-USB2-EHCI) | Bom estudo de engenharia de driver clássico e validação em hardware, mas trata ROM, Name Registry, PEF e USB no Mac OS 9; não fornece APIs de janela/evento do macOS moderno. |
| [Macintosh Garden](https://macintoshgarden.org/games/all) | Catálogo de software clássico. Binários 68k/PPC podem servir para estudo histórico, não para descobrir `SkyLight.framework`; baixa prioridade para este spike. |
| `logich/Skylight-swift` | **Falso positivo:** é um cliente Swift para o produto Skylight Calendar, sem relação com `SkyLight.framework` do macOS. |
| Artigos de patch/re-sign e pergunta sobre PluginKit | Contexto geral de Mach-O, Ghidra, LLDB e assinatura; pouca informação específica para o gargalo deste spike. |

### Processo recomendado para descobrir o restante da API

1. **Código consumidor antes de dump de símbolos.** Um `.tbd`, `nm` ou
   `dyld_info` prova que o nome existe; um call site mostra quantidade, ordem e
   largura dos argumentos.
2. **Validar por versão.** Fixar uma matriz macOS 14/15/26 e registrar para cada
   símbolo: encontrado por `dlsym`, ABI inferido, retorno medido e teste de
   fumaça. API privada não deve compartilhar uma única declaração presumida
   entre versões sem guarda.
3. **Extrair o dyld shared cache da versão-alvo.** A ferramenta
   [`ipsw`](https://blacktop.github.io/ipsw/docs/guides/dyld/) consegue extrair
   imagens com símbolos locais/metadados Objective-C e desassemblar por símbolo
   ou importador. Para este spike, procurar call sites de
   `SLEventCreateNextEvent`, `SLSGetEventPort`, `_CFMachPortSetOptions` e
   `SLPS*` em AppKit, HIToolbox, SkyLight e WindowManagement.
4. **Usar LLDB no chamador conhecido.** Breakpoint por símbolo em um app AppKit
   mínimo ou no JankyBorders; no arm64, registrar `x0...x7`, valor de retorno e
   backtrace. Isso é mais confiável que inferir tipos apenas do nome.
5. **Separar C de Objective-C.** O runtime Objective-C e
   `method_getTypeEncoding` recuperam assinaturas de seletores AppKit; não ajudam
   com funções C do SkyLight. Para estas, disassembly dos call sites continua
   indispensável.
6. **Congelar evidência local.** Para cada ABI adotado, salvar no repositório o
   link com commit, versão do macOS, trecho mínimo da declaração e o log do
   probe. Links `main` são úteis para descoberta, mas não são especificação.

O plano B público continua sendo
[`CGEventTapCreate`](https://developer.apple.com/documentation/coregraphics/cgevent/tapcreate%28tap%3Aplace%3Aoptions%3Aeventsofinterest%3Acallback%3Auserinfo%3A%29):
a própria Apple documenta a criação de uma `CFMachPort`/run-loop source e as
restrições para eventos de teclado. Ele permanece no estudo apenas como fallback
funcional e como implementação pública de referência para o encadeamento
`CFMachPort`/`CFRunLoopSource`.
