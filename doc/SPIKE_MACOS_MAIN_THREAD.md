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

**O que falta:** ABI de `SLSNewWindow` (assinatura não é pública e o tipo de
`x`/`y` variou entre versões), e a região precisa ser construída — o nome
`SLSNewRegionWithRect` não existe nesta versão, então há que descobrir o
equivalente atual.

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

### Ressalvas antes de adotar como arquitetura

- A main thread fica presa **dentro de um handler de sinal**, para sempre. O
  `SIGUSR2` permanece bloqueado nela.
- O shutdown normal do processo deixa de existir: é preciso sair por `_exit()`.
  Handlers de `atexit` e finalização da VM não rodam.
- A VM do Dart não sabe que perdeu a main thread. Não foi medido o efeito sobre
  profiler, service protocol e sinais que a VM usa.
- **Falta o input.** `CFRunLoopRun` puro não distribui `NSEvent` para a
  aplicação — isso é trabalho de `[NSApp run]`. O próximo experimento é enviar
  `run` para a main thread sequestrada com `waitUntilDone:NO` (é seletor sem
  argumento, dispensa `NSInvocation`) e verificar se teclado e mouse chegam.
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

## Próximos passos

1. Probe F — `[NSApp run]` na main thread sequestrada e verificação de entrega
   de eventos de teclado/mouse.
2. Medir estabilidade: a VM sobrevive ao sequestro sob carga (timers, isolates,
   I/O)?
3. Se F passar, comparar honestamente com o host nativo de ~50 linhas: a rota D
   preserva "zero código nativo" ao custo de depender de comportamento não
   documentado do runtime do Dart e do AppKit.
