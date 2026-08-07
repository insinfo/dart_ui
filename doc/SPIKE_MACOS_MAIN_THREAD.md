# Spike — propriedade da main thread no macOS (risco R02)

**Pergunta:** existe rota **100% Dart** — sem fonte C/C++/Objective-C, sem
shellcode, sem entitlement — para criar e operar uma janela no macOS?

**Resposta curta:** sim, duas rotas estão abertas e uma delas já criou uma
`NSWindow` de verdade. Ambas têm ressalvas sérias, documentadas abaixo.

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

**Resumo em uma linha:** a rota C tem janela visível, desenho e prova externa;
a rota D+E **chama** AppKit mas não consegue **rodar** AppKit.

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

### PSN/`-600` (probe Y, run `31150990449`)

```
SLSGetEventPort -> rc=0 port=12295          (porta real, só que ninguém a lê)
SLPSRegisterWithServer(psn) -> 0
SLPSSetMainApplicationConnection(cid, 0) -> -600   procNotFoundErr
```

O `-600` é exatamente `procNotFoundErr`: no ecossistema SLPS/CPS (CGSInternal,
yabai) **todas** as funções pegam `ProcessSerialNumber*`, então o `cid` que
passamos antes foi **reinterpretado como ponteiro de PSN inválido**. O ABI real
é `SLPSRegisterWithServer(ProcessSerialNumber*)` e
`SLPSSetMainApplicationConnection(ProcessSerialNumber*, cid)`. A próxima rodada
da probe Y passa o PSN obtido via `SLPSGetCurrentProcess` como ponteiro — se o
`-600` virar 0, a rota C está a uma entrega (`SLEventCreateNextEvent`) de
completar o handshake de eventos.

## Próximos passos

1. **Probe Y v3** no CI com o ABI PSN-pointer
   (`SLPSRegisterWithServer(psn)`/`SLPSSetMainApplicationConnection(psn, cid)`).
   Se mainParar de dar `-600`, a rota C tem o handshake de eventos completo e
   podemos medir se `SLEventCreateNextEvent` começa a entregar.
2. Se ainda 0 eventos: app bundle (.app) + registro LaunchServices, ou
   `SLEventModifyConnection`/`SLEventPackets` do dump.
3. Avaliar `CGEventTap` como plano B para input (exige permissão de
   acessibilidade concedida pelo usuário).
4. Decorações, menus, IME e acessibilidade: o que a rota C perde ao abrir mão do
   AppKit, e que disso o o framework precisa reimplementar.
