# Técnica: operar a process main thread do macOS a partir de Dart FFI puro

Referência das etapas descobertas no spike do POC-03. Nenhuma delas está
documentada pela Apple ou pelo Dart; todas foram medidas em CI
(`macos-14` arm64, Dart 3.6.0). Os resultados brutos estão em
[SPIKE_MACOS_MAIN_THREAD.md](SPIKE_MACOS_MAIN_THREAD.md); aqui está o **como**.

> **Aviso de estabilidade.** Isto depende de detalhes internos do runtime do
> Dart e do AppKit que podem mudar sem aviso. A solução limpa é a primitiva de
> takeover proposta em [propostas/](propostas/). Este documento existe porque a
> técnica funciona hoje e porque cada armadilha aqui custou horas de CI.

## O problema em uma frase

O AppKit exige que `NSWindow` seja instanciada na **thread 0 do processo** e
verifica isso com `pthread_main_np()` — mas a VM do Dart nunca entrega a thread
0 ao código Dart, em nenhum modo de execução (JIT, `dartaotruntime`,
`dart compile exe`).

O que a thread 0 está fazendo, medido com `sample(1)`:

```
Dart_RunLoop + 352
  _pthread_cond_wait
    __psynch_cvwait
```

Ela está **ociosa**, esperando num monitor. É exatamente por isso que dá para
tomá-la emprestada.

---

## Etapa 0 — descobrir símbolos que não têm header

Frameworks do sistema vivem no dyld shared cache: **não existe arquivo para
passar no `nm`**. Use `dyld_info`:

```bash
dyld_info -exports \
  /System/Library/PrivateFrameworks/SkyLight.framework/SkyLight \
  | grep -i region
```

**Armadilha:** `dyld_info` lista só o que aquele binário exporta. O
`CGSNewRegionWithRect` **não aparece** na tabela do SkyLight, mas o
`dlsym` no handle do SkyLight o encontra — ele mora no CoreGraphics e vem pela
cadeia de dependências. Use as duas ferramentas: `dyld_info` para achar nomes,
`dlsym` para confirmar alcance.

E `dyld_info` dá o **nome**, nunca os **tipos**. Toda assinatura é chute.

---

## Etapa 1 — `dispatch_get_main_queue` não é um símbolo

É `static inline` no header, nunca emitida. `dlsym` sempre falha. O que existe
é o objeto global `_dispatch_main_q`, e a fila é o **endereço** dele:

```dart
Pointer<Void> dispatch_get_main_queue() =>
    libSystem.lookup<Void>('_dispatch_main_q');
```

---

## Etapa 2 — sequestrar a thread 0 com um sinal

Um sinal é entregue **na thread alvo**. Como o handler é apenas um endereço de
código, qualquer função exportada de aridade compatível serve — inclusive a
própria `CFRunLoopRun`. **Não é preciso emitir shellcode.**

```dart
signal(SIGUSR2, cfRunLoopRunPtr);              // handler = &CFRunLoopRun
pthread_kill(pthread_main_thread_np(), SIGUSR2);
```

A thread 0 passa a executar `CFRunLoopRun` por cima do frame do
`pthread_cond_wait` interrompido:

```
Dart_RunLoop -> _pthread_cond_wait -> _sigtramp -> CFRunLoopRun
```

**Consequência permanente:** `SIGUSR2` fica bloqueado nessa thread e o handler
nunca retorna. O shutdown normal do processo deixa de existir (ver etapa 7).

---

## Etapa 3 — a keep-alive source (a etapa que ninguém conta)

**Sem esta etapa a técnica parece funcionar por alguns milissegundos e depois
falha de formas incompreensíveis.**

`CFRunLoopRun` retorna assim que o loop fica sem *nenhuma* source ou timer. Ele
drena o que estava pendente, devolve `kCFRunLoopRunFinished`, e a VM retoma a
thread. Tudo que chegar depois disso trava para sempre — sem erro, sem log.

A correção é anexar uma source versão 0 **nunca sinalizada**, só para o loop não
poder terminar. `CFRunLoopAddSource` é thread-safe, então dá para fazer da
thread do Dart antes do sinal:

```dart
final class CFRunLoopSourceContext extends Struct {
  @Int64() external int version;
  external Pointer<Void> info, retain, release, copyDescription;
  external Pointer<Void> equal, hash, schedule, cancel, perform;
}

final context = calloc<CFRunLoopSourceContext>();   // tudo zero
final source = CFRunLoopSourceCreate(nullptr, 0, context);
CFRunLoopAddSource(CFRunLoopGetMain(), source, kCFRunLoopDefaultMode);
```

Todos os callbacks podem ser nulos porque a source nunca é sinalizada. Ela
existe apenas para o loop contá-la.

Com ela, a stack vira:

```
_sigtramp -> CFRunLoopRun -> CFRunLoopRunSpecific -> __CFRunLoopRun
  -> __CFRunLoopServiceMachPort -> mach_msg
```

Um run loop de verdade, bloqueado no mach port. Timers passam a disparar.

---

## Etapa 4 — Dart → UI: `NSInvocation`

Chamar AppKit na thread 0 exige empacotar a chamada num objeto, porque um
`NativeCallable` do Dart **aborta** se invocado por outra thread (etapa 5).
`NSInvocation` resolve isso inteiramente dentro do runtime Objective-C:

```dart
final signature = msgSendPointerSel(
    target, sel('methodSignatureForSelector:'), selector);
final invocation = msgSendPointerPointer(getClass('NSInvocation'),
    sel('invocationWithMethodSignature:'), signature);
msgSendVoidPointer(invocation, sel('setTarget:'), target);
msgSendVoidSel(invocation, sel('setSelector:'), selector);
// argumentos declarados começam no índice 2 (0 = self, 1 = _cmd)
msgSendVoidPointerInt(invocation, sel('setArgument:atIndex:'), rect.cast(), 2);
invocation.msgSend('retainArguments');

msgSendPerformOnMain(invocation,
    sel('performSelectorOnMainThread:withObject:waitUntilDone:'),
    sel('invoke'), nullptr, true);

msgSendVoidPointer(invocation, sel('getReturnValue:'), slot.cast());
```

Seletores com zero ou um argumento **objeto** dispensam `NSInvocation` — vão
direto por `performSelectorOnMainThread:` (ex.: `makeKeyAndOrderFront:`).

`[NSWindow alloc]` pode ser feito fora da thread 0; só a **inicialização** é
restrita.

---

## Etapa 5 — UI → Dart: `NativeCallable.listener` como IMP

O caminho de volta (delegates, handlers) precisa de código Dart chamado *pela*
thread 0. Registre uma classe Objective-C do Dart e use um `.listener` como IMP:

```dart
final callable = NativeCallable<Void Function(
    Pointer<ObjCObject>, Pointer<ObjCSel>, Int64)>.listener(meuHandler);

final cls = objc_allocateClassPair(getClass('NSObject'), nome, 0);
class_addMethod(cls, sel('handleValue:'),
    callable.nativeFunction.cast(), 'v@:q'.toNativeUtf8());  // v@:q = void, self, _cmd, long long
objc_registerClassPair(cls);
```

Escolha do tipo de callable, medida:

| Tipo | Comportamento |
| --- | --- |
| `.isolateLocal` | **Aborta o processo** se invocado por outra thread |
| `.listener` | Aceita qualquer thread, enfileira no isolate. **Não retorna valor** |

Ou seja: `.listener` serve para *notificar* o Dart, e não serve para delegates
que exigem resposta síncrona (`windowShouldClose:` devolvendo `BOOL`).

---

## Etapa 6 — a saúde da VM não é afetada

Medido com a thread 0 já sequestrada:

```
timer fired after 253ms          -> ok
async file I/O round trip        -> ok
Isolate.run -> 42                -> ok
```

Faz sentido: roubamos uma thread que o Dart não usava. Isso valida o desenho de
um **isolate dedicado ao bombeamento**, que pode bloquear à vontade sem parar o
isolate principal, conversando por `SendPort`.

---

## Etapa 7 — sair do processo

O handler de sinal nunca retorna, então o shutdown normal não existe. Saia por
`_exit`:

```dart
final _exitProcess = libSystem
    .lookupFunction<Void Function(Int32), void Function(int)>('_exit');
```

`exit()` da libc roda handlers de `atexit` e pode travar. Finalizadores da VM
não rodam.

---

## Armadilhas catalogadas

Cada uma custou pelo menos um run de CI.

| Sintoma | Causa | Correção |
| --- | --- | --- |
| `dlsym` falha em `dispatch_get_main_queue` | é `static inline`, não existe símbolo | usar `_dispatch_main_q` |
| `dispatch_sync_f` na main queue nunca retorna | ninguém drena a fila | etapas 2 + 3 |
| Funciona por ~1ms e depois trava tudo | `CFRunLoopRun` terminou sozinho | keep-alive source (etapa 3) |
| Processo aborta ao chamar callback | `NativeCallable.isolateLocal` de thread estranha | `.listener` |
| Deadlock ao usar `.listener` | `waitUntilDone: YES` bloqueia o event loop que entregaria o callback | `waitUntilDone: NO` |
| `NSInvocation` devolve nil "às vezes" | com `repeats: YES`, a invocação seguinte sobrescreve o retorno | timer one-shot |
| Não dá para distinguir "não rodou" de "retornou nil" | buffer de retorno nasce zerado | gravar sentinela `0x1` com `setReturnValue:` antes |
| Modo de run loop não bate | `NSString` construída à mão em vez do global | usar o global `NSDefaultRunLoopMode` |
| `SIGSEGV` com `si_addr` = um valor seu | assinatura errada: um inteiro foi desreferenciado como ponteiro | o `si_addr` **identifica o argumento culpado** |
| Trava sem log e sem crash | nada observável de fora | `sample <pid> 1 1 -file out` |

### `sample(1)` é a ferramenta mais valiosa aqui

Foi o único diagnóstico capaz de distinguir "o pump bloqueou" de "o run loop
nem existia". Nenhum probe consegue observar isso de dentro:

```bash
./build/probe <subcomando> > out.log 2>&1 &
pid=$!
sleep 1
sample "$pid" 1 1 -file out.sample
# imprima out.log e out.sample ANTES de esperar o processo:
# se ele travar, o timeout do CI come exatamente a evidência que você queria
```

---

## Rota alternativa: WindowServer direto, sem AppKit

Ignora AppKit por completo — logo não tem regra de main thread nenhuma. Provada
com screenshot externo (janela de 480x320 fotografada pelo `CGSWindowID`).

```dart
final cid = SLSMainConnectionID();
CGSNewRegionWithRect(rect, &region);              // note o prefixo CGS
SLSNewWindow(cid, 2, x, y, region, &windowId);    // x/y são float de 32 bits
final ctx = SLWindowContextCreate(cid, windowId, nullptr);
// desenhe com CGContext* normal, depois:
SLSOrderWindow(cid, windowId, 1, 0);
```

**O que falta:** input. O WindowServer roteia para o processo em foco
identificado por PSN. `SLPSGetCurrentProcess`,
`SLPSEnableForegroundOperation`, `SLPSSetFrontProcess` e `SLPSStealKeyFocus`
retornam 0 (sucesso) e ainda assim nenhum evento chega — falta parte do
handshake (`SLPSRegisterWithServer`, `SLPSSetMainApplicationConnection`) ou um
app bundle registrado no LaunchServices.

**Custo permanente:** é API privada. Sem headers, cada assinatura é um chute
pago com segfault, e nada disso sobrevive à App Store nem tem garantia entre
versões do macOS.

---

## O que isto tudo demonstra

Duas coisas, e elas apontam para a mesma conclusão:

1. **É implementável.** A thread 0 existe, está ociosa e pode ser operada de
   Dart puro. Isso remove a objeção mais comum a uma proposta de SDK — a de que
   seria inviável.
2. **Não deveria ser o usuário fazendo isso.** Sequestro por sinal, uma source
   fantasma só para um loop não terminar, `NSInvocation` para cada chamada,
   `.listener` como IMP, e `sample(1)` para descobrir por que nada funciona.
   Nenhuma etapa é documentada, e a etapa 3 — a que faz tudo funcionar — é
   invisível sem inspecionar a stack da thread.

É exatamente o argumento de [propostas/](propostas/): isto pertence ao runtime.
