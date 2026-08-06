# Spike — propriedade da main thread no macOS (risco R02)

**Pergunta:** existe rota **100% Dart** — sem fonte C/C++/Objective-C, sem
shellcode, sem entitlement — para criar e operar uma janela no macOS?

**Resposta curta:** sim, duas rotas estão abertas e uma delas já criou uma
`NSWindow` de verdade. Ambas têm ressalvas sérias, documentadas abaixo.

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

**Resumo em uma linha:** as duas rotas criam janela e o Dart continua saudável;
o que **nenhuma** das duas tem ainda é entrega de input.

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

## Próximos passos

1. Probe K — bombear a fila por `NSTimer` em vez de `performSelectorOnMainThread:`,
   para separar reentrância de sessão headless.
2. Se K falhar, validar num Mac real com sessão gráfica: só isso descarta a
   hipótese 2 do probe F.
3. Rota C — `SLWindowContextCreate` para obter contexto de desenho, e avaliar
   `CGEventTap` como fonte de input.
4. Comparar honestamente com o host nativo de ~50 linhas: as rotas puras
   preservam "zero código nativo" ao custo de depender de comportamento não
   documentado do runtime do Dart e do AppKit.
