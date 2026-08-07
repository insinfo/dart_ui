# Investigação técnica  
## Acesso à main thread do macOS a partir de Dart puro

**Data:** 6 de agosto de 2026  
**Repositório experimental:** `insinfo/dart_ui`  
**Documento do repositório:** `doc/SPIKE_MACOS_MAIN_THREAD.md`  
**Workflow analisado:** `macOS main-thread spike`  
**Run:** `31078303894`  
**SHA executado:** `20d3e3aa4f9f158a52918902f77c4cc3fd3dc8d9`  
**Runner:** macOS 14.8.7, arm64  
**Dart usado pelo workflow:** 3.6.0

**Atualização de 7 de agosto de 2026:** os runs Z16/Z17 fecharam a rota
SkyLight/CGS com janela, pixels e input sintético `[10, 11, 5]`; a limitação de
produção descrita abaixo agora se refere à rota AppKit suportada e à robustez
multiversão, não à capacidade de receber qualquer input.

---

## 1. O que significa “Dart puro” nesta investigação

“Dart puro” significa:

- nenhum arquivo-fonte C, C++, Objective-C ou Swift no projeto consumidor;
- nenhuma DLL/dylib própria usada como wrapper;
- chamadas às APIs existentes do sistema por `dart:ffi`;
- uso do runtime Objective-C por `objc_msgSend`;
- uso de bibliotecas nativas já fornecidas pelo macOS.

Isso não significa que o processo não possua código nativo: a VM do Dart e o
sistema operacional são nativos. A restrição é não exigir uma camada nativa
mantida pelo desenvolvedor do framework.

---

## 2. Resposta atual

### Tecnicamente possível?

**Sim**, uma aplicação Dart standalone consegue:

- falar com o runtime Objective-C;
- abrir AppKit;
- alcançar a primeira thread do processo experimentalmente;
- criar uma `NSWindow` na thread correta;
- criar uma janela diretamente no WindowServer;
- manter a VM saudável;
- trocar mensagens nos dois sentidos entre isolate e UI.

### Produção 100% Dart hoje?

**Ainda não de forma suportada e completa.**

Faltam:

- um acesso oficial à primeira thread do processo;
- inicialização segura e top-level do event loop AppKit;
- input AppKit, IME e acessibilidade validados numa rota suportada;
- shutdown normal;
- ausência de comportamento indefinido.

A rota experimental por sinal prova viabilidade, mas não deve ser publicada como
arquitetura de produção.

---

## 3. Por que o Dart não executa na process main thread

O launcher possui um `main()` nativo normal:

```cpp
int main(int argc, char** argv) {
  dart::bin::main(argc, argv);
  UNREACHABLE();
}
```

O isolate principal é criado e `RunMainIsolate` chama:

```cpp
Dart_RunLoop();
```

A implementação de `Dart_RunLoop` faz algo decisivo:

```cpp
Dart_ExitIsolate();

message_handler->Run(thread_pool, RunLoopDone, &data);

while (!data.done) {
  monitor.Wait();
}

Dart_EnterIsolate(isolate);
```

Portanto:

```text
process main thread
└─ código nativo do launcher
   └─ espera em Dart_RunLoop/Monitor

thread do pool da VM
└─ executa eventos do main isolate
   └─ main() Dart
```

Isso não é um acidente de JIT ou AOT. É a arquitetura do standalone embedder.

---

## 4. Exigências do macOS

### 4.1 Identidade da primeira thread

No macOS:

```c
pthread_main_np()
```

indica se a thread atual é a primeira thread nativa do processo.

Criar outra `pthread` não resolve.

### 4.2 AppKit e eventos

A arquitetura normal é:

```text
main thread
└─ NSApplication
   └─ run
      ├─ obtém NSEvent
      ├─ envia o evento
      ├─ processa redraw
      └─ volta ao loop
```

O `NSApplication` estabelece conexão com o WindowServer e mantém uma fila FIFO
de eventos. O loop principal retira eventos com
`nextEventMatchingMask:untilDate:inMode:dequeue:` e os envia com `sendEvent:`.

### 4.3 CFRunLoop não é o loop AppKit completo

`CFRunLoopRun()` drena sources e timers do Core Foundation e integra a main
dispatch queue. Entretanto, isso não equivale automaticamente ao comportamento
completo de `[NSApplication run]`.

Run loops do Core Foundation podem ser executados recursivamente. Logo, a
hipótese de que qualquer loop aninhado seja proibido é forte demais. O problema
pode ser específico do estado AppKit, da origem do callout, do signal handler ou
da sessão headless.

---

## 5. Placar dos probes

| Probe | Questão | Resultado |
|---|---|---|
| A | Algum modo de execução entrega a thread 0? | ❌ |
| B | `[NSApp run]` na thread Dart muda a identidade? | ❌ |
| C | O WindowServer responde sem AppKit? | ✅ |
| D | A thread 0 pode ser acordada por sinal? | ✅ |
| E | Uma `NSWindow` pode ser criada nela? | ✅ |
| F | O pump manual retorna o evento? | ⛔ trava |
| G | `[NSApp run]` funciona no loop sequestrado? | ❌ crash |
| H | `SLSNewWindow` realmente cria uma janela? | ✅ |
| I | A VM continua saudável? | ✅ |
| J | UI → Dart funciona? | ✅ |
| K | `NSTimer` elimina o problema de F? | ⚠️ inconclusivo |

---

## 6. Probe A — JIT, snapshot e AOT

Resultado do run:

```text
----- JIT: dart run -----
pthread_main_np()        = 0

----- dartaotruntime snapshot -----
pthread_main_np()        = 0

----- AOT exe -----
pthread_main_np()        = 0
```

O mesmo handle da main thread foi encontrado em todos os processos, mas o código
Dart não estava executando nela.

Conclusão:

```text
modo de compilação != propriedade da process main thread
```

---

## 7. Probe B — chamar `[NSApp run]` no isolate

`sharedApplication` pode devolver um objeto fora da thread 0, mas:

```text
calling [NSApp run] ...
```

bloqueia a thread do isolate.

Isso não muda:

```text
pthread_main_np() = 0
```

e não torna `NSWindow` legal.

O problema é que entrar em um método chamado `run` não altera a identidade
nativa da thread.

---

## 8. Probe C/H — WindowServer direto

### 8.1 Símbolos encontrados

O SkyLight forneceu:

```text
SLSMainConnectionID
SLSNewWindow
SLSOrderWindow
SLSSetWindowLevel
SLSFlushWindowContentRegion
```

Os nomes CGS antigos são aliases de alguns símbolos SLS.

### 8.2 Região

A função correta é:

```text
CGSNewRegionWithRect
```

Ela não aparece na tabela de exports do SkyLight, mas `dlsym` no handle encontra
o símbolo pela cadeia de dependências, no CoreGraphics.

### 8.3 Janela

O probe H obteve:

```text
CGSNewRegionWithRect -> CGError 0
SLSNewWindow         -> CGError 0
SLSSetWindowLevel    -> 0
SLSOrderWindow       -> CGError 0
```

Uma janela WindowServer foi criada e ordenada fora da main thread.

### 8.4 Contexto de desenho

O dump mostrou:

```text
SLWindowContextCreate
SLWindowContextCreateImage
```

Isso abre caminho para superfície de desenho.

### 8.5 Limitações

- API privada;
- ABI instável;
- incompatível com App Store;
- sem fila `NSEvent`;
- sem menu, IME e acessibilidade;
- input alternativo por `CGEventTap` pode exigir permissão de acessibilidade.

Essa rota é útil para pesquisa de compositor/superfície, não como base principal
de um framework desktop distribuível.

---

## 9. Probe D — sequestro por sinal

### 9.1 Mecanismo

O teste instalou o endereço de:

```text
CFRunLoopRun
```

como handler de `SIGUSR2` e enviou o sinal especificamente para:

```text
pthread_main_thread_np()
```

Como o sinal é entregue na thread alvo, a thread 0 entrou em `CFRunLoopRun`.

A verificação usou uma tarefa inteiramente nativa:

```text
dispatch_async_f(mainQueue, semaphore, dispatch_semaphore_signal)
```

e comprovou que a fila principal passou a ser drenada.

### 9.2 Valor científico

O probe prova:

- a thread 0 continua viva;
- ela não é usada pelo isolate;
- o processo consegue fazê-la executar código;
- um run loop nela torna a main queue operacional.

### 9.3 Por que não é seguro

Um signal handler possui assinatura:

```c
void handler(int signal);
```

`CFRunLoopRun` possui outra ABI.

Além disso:

- Core Foundation não é async-signal-safe;
- o sinal pode interromper alocador ou runtime;
- o handler não retorna;
- o frame interrompido fica retido;
- shutdown normal deixa de existir;
- sinais da VM podem colidir;
- profiler e crash handling ficam sem contrato confiável.

O resultado deve ser tratado como prova de possibilidade, não como solução.

---

## 10. Probe E — `NSWindow` real

Depois de estacionar a thread 0:

1. `NSWindow alloc`;
2. obter `NSMethodSignature`;
3. construir `NSInvocation`;
4. configurar `initWithContentRect:styleMask:backing:defer:`;
5. `performSelectorOnMainThread:@selector(invoke)`;
6. obter o retorno.

Resultado:

```text
NSWindow CREATED AND ORDERED FRONT
```

Todo o caminho entre o isolate e a thread 0 permaneceu no runtime Objective-C.
Nenhum callback Dart foi chamado na thread estrangeira.

Isso prova Dart → UI.

---

## 11. Probe I — saúde da VM

Com a thread 0 ocupada:

```text
Timer                 -> funciona
File I/O assíncrono   -> funciona
Isolate.run           -> funciona
canal AppKit          -> responde
```

Conclusão:

A thread 0 estava sendo usada como thread de espera do launcher, não como
mutator thread indispensável.

Esse resultado apoia diretamente uma mudança no standalone embedder.

---

## 12. Probe J — UI → Dart

Foi criada uma classe Objective-C dinamicamente:

```text
objc_allocateClassPair
class_addMethod
objc_registerClassPair
```

Um `NativeCallable.listener` foi usado como IMP.

Uma invocation disparada na thread 0 enviou:

```text
0xC0FFEE
```

e o isolate recebeu o valor.

### Limitação

`listener` somente suporta retorno `void`.

Para resposta síncrona é necessário:

- `NativeCallable.isolateGroupBound`;
- estado compartilhável;
- ou lógica nativa mínima.

---

## 13. Probe G — `[NSApp run]` no loop sequestrado

Resultado:

```text
sending -run to the main thread...
Trace/BPT trap
Abort trap: 6
```

O dado importante é que o método foi chamado na thread correta, mas de dentro de
uma configuração anormal:

```text
signal handler
└─ CFRunLoopRun
   └─ run-loop callback
      └─ [NSApp run]
```

Ainda falta o backtrace do `SIGTRAP`.

### Próximo diagnóstico

Executar sob LLDB:

```bash
lldb --batch \
  -o run \
  -o "thread backtrace all" \
  -- ./build/probe nsapp-run-main
```

Sem o backtrace não é possível separar:

- assert de reentrância AppKit;
- assert de lifecycle;
- ausência de sessão gráfica;
- efeito do signal handler;
- estado inválido de `NSApplication`.

---

## 14. Probe F — pump manual

A instrumentação mostrou:

```text
finishLaunching returned
isRunning = 0
postEvent works
nextEventMatchingMask never returns
```

Mesmo usando:

```text
untilDate = [NSDate distantPast]
```

a chamada não voltou.

O comportamento esperado pela API seria retorno imediato com evento ou `nil`.
O travamento indica estado interno ou modo de loop incompatível.

---

## 15. Probe K — resultado e limitação da instrumentação

### 15.1 Resultado do run 31078303894

```text
[NSApp finishLaunching] returned.
timer scheduled on the main run loop.
posted event ...; letting the timer run...
last value returned by the timed pump: 0
```

### 15.2 Por que é inconclusivo

O timer foi criado com:

```text
repeats = YES
```

Portanto, mesmo que:

```text
primeiro fire -> retorna o evento
segundo fire  -> retorna nil
```

o return buffer final será `nil`.

Além disso, o return buffer começa zerado. Logo `0` também pode significar que a
invocation nunca terminou.

### 15.3 O que K realmente removeu

Ele removeu `performSelectorOnMainThread:` do caminho do pump.

Porém, o pump ainda é chamado de dentro de um callout do run loop, agora um
`NSTimer`.

Portanto, K não descarta toda forma de reentrância/callout.

---

## 16. Probe L recomendado — diagnóstico sem ambiguidade

### 16.1 Alterações

1. publicar o evento antes do timer;
2. usar `repeats: NO`;
3. inicializar o retorno da invocation com sentinela;
4. agendar um timer marcador antes do pump;
5. usar o objeto global real `NSDefaultRunLoopMode`;
6. coletar sample da stack da process main thread.

### 16.2 Sentinela

```dart
final sentinel = calloc<Pointer<ObjCObject>>()
  ..value = Pointer<ObjCObject>.fromAddress(1);

msgSendVoidPointer(
  pumpInvocation,
  sel('setReturnValue:'),
  sentinel.cast(),
);
```

Interpretação:

```text
0x1       -> invocation não terminou
0x0       -> terminou com nil
event ptr -> sucesso
outro ptr -> outro evento
```

### 16.3 Timer marcador

Agendar antes:

```text
20 ms  -> invocation inofensiva, por exemplo +[NSDate date]
100 ms -> invocation do pump
```

Se o marcador não mudar, o problema está no timer/mode.

### 16.4 Stack sample

Workflow:

```bash
./build/probe pump-timer-diagnostic \
  > build/probe-l.log 2>&1 &
pid=$!

sleep 1
sample "$pid" 1 1 \
  -file build/probe-l.sample || true

cat build/probe-l.sample || true
wait "$pid" || true
cat build/probe-l.log
```

### 16.5 Matriz

| Marcador | Pump | Stack | Interpretação |
|---|---|---|---|
| sentinela | sentinela | `CFRunLoopRun` aguardando | timer não entregue |
| alterado | sentinela | dentro de `_DPSNextEvent`/`mach_msg` | pump bloqueou |
| alterado | `nil` | voltou ao loop externo | fila vazia/evento rejeitado |
| alterado | evento | voltou ao loop externo | evento sintético provado |
| alterado | outro | voltou ao loop externo | fila ativa, outro evento primeiro |

---

## 17. Teste obrigatório em Mac com sessão gráfica

**Correção medida:** o runner macOS do GitHub Actions **não é headless**. O
probe N capturou a tela em 1920x1080 mostrando um desktop completo — Finder,
Dock, barra de menus — com a janela da rota C visível e pintada, além do diálogo
"probe quit unexpectedly" do holder AppKit. O `screencapture -l<CGSWindowID>`
fotografou a janela pelo id, o que só funciona se o WindowServer realmente a
tiver.

Isso é relevante para a proposta: significa que o crash de `[NSApp run]` e a
trava de `nextEventMatchingMask:` são falhas **da técnica**, não do ambiente de
CI — o que fortalece o argumento em vez de enfraquecê-lo. Um revisor do Dart SDK
que percebesse a afirmação incorreta descartaria o resto.

O que de fato falta no CI não é sessão gráfica, e sim **registro de processo**:
o probe P recebeu zero eventos porque o WindowServer roteia input para o
processo em foco identificado por PSN, e o nosso nunca se registrou como
aplicação (daí a relevância de `SLPS*`, `SLEventTapCreateForPSN` e
`SLEventTapCreateForPid` no dump de exports).

Teste recomendado:

```bash
git clone https://github.com/insinfo/dart_ui
cd dart_ui/poc/poc_03_appkit_window
dart pub get
dart compile exe bin/probe.dart -o build/probe
./build/probe pump-timer-diagnostic
```

Também deve ser criado um app bundle para aproximar o lifecycle normal:

```text
DartMainThreadProbe.app/
└─ Contents/
   ├─ Info.plist
   └─ MacOS/
      └─ probe
```

Executar tanto pelo Finder quanto pelo Terminal dentro de uma sessão logada.

---

## 18. Testar com Dart atual e branch `main`

O workflow usa Dart 3.6.0, de dezembro de 2024.

A investigação deve manter duas linhas:

```yaml
strategy:
  matrix:
    dart:
      - stable
      - main
```

Para recursos experimentais recentes:

```text
--experimental-shared-data
```

Objetivos:

- confirmar que `NativeCallable.isolateGroupBound` mantém o mesmo comportamento;
- testar `Isolate.create`;
- testar `runSync`;
- testar `pinToCurrentThread`;
- testar `runEventLoopSync`;
- acompanhar quando `onEvent`/`handleEvent` deixarem de lançar `UnsupportedError`.

---

## 19. Arquitetura segura futura

```text
process main thread
└─ callback top-level fornecido pelo Dart SDK
   └─ [NSApplication run]
      ├─ eventos
      ├─ janelas
      ├─ menus
      └─ callbacks Objective-C

main isolate
├─ estado
├─ I/O
├─ timers
├─ workers
├─ Dart → UI
└─ recebe UI → Dart

UI isolate opcional futuro
├─ Isolate.create
├─ runSync
├─ pinToCurrentThread
├─ onEvent
└─ handleEvent
```

A diferença para o hack atual:

```text
não existe signal handler
não existe CFRunLoop sequestrado
não existe _exit()
não existe API privada
```

---

## 20. Opções práticas hoje

### Produção

1. host mínimo Objective-C/C/Swift;
2. custom embedder;
3. Dart Engine experimental;
4. Flutter engine com threads mescladas, se aceitável.

### Pesquisa

1. continuar probes AppKit;
2. promover a superfície SkyLight já confirmada a testes de teardown,
   múltiplas janelas, Spaces/fullscreen/sleep e versões do macOS;
3. testar `CGEventTap` como fallback público para captura global;
4. estudar callbacks síncronos com `isolateGroupBound`;
5. implementar e medir a integração `Isolate.onEvent`/`handleEvent` proposta no
   documento 04.

### Não recomendado

- publicar o signal hijack;
- depender de SkyLight em aplicação de usuário;
- presumir que K provou ausência de eventos;
- bloquear `dispatch_sync_f` sem loop principal ativo.

---

## 21. Conclusão

O obstáculo não é a capacidade do Dart FFI de chamar AppKit. Isso já foi
demonstrado.

O obstáculo é a política do standalone embedder:

```text
a primeira thread fica estacionada no launcher
enquanto o isolate executa no thread pool
```

Essa arquitetura torna a solução no SDK particularmente plausível: a thread
correta já existe, está sob controle nativo e não é necessária ao progresso
normal da VM.

A evolução mais robusta é uma API de **process-main-thread takeover**, seguida
pela conclusão de `Isolate.onEvent` e `Isolate.handleEvent`.

---

## 22. Referências

### Dart

- https://github.com/dart-lang/sdk/issues/38315
- https://github.com/dart-lang/sdk/issues/52106
- https://github.com/dart-lang/sdk/issues/46943
- https://github.com/dart-lang/sdk/issues/56841
- https://github.com/dart-lang/language/blob/main/working/333%20-%20shared%20memory%20multithreading/shared_native_memory.md
- https://github.com/dart-lang/sdk/blob/main/runtime/bin/main.cc
- https://github.com/dart-lang/sdk/blob/main/runtime/bin/main_impl.cc
- https://github.com/dart-lang/sdk/blob/main/runtime/vm/dart_api_impl.cc
- https://github.com/dart-lang/sdk/blob/main/runtime/engine/include/dart_engine.h
- https://github.com/dart-lang/sdk/blob/main/sdk/lib/isolate/isolate.dart
- https://github.com/dart-lang/sdk/blob/main/sdk/lib/_internal/vm/lib/isolate_patch.dart
- https://api.dart.dev/dart-ffi/NativeCallable/NativeCallable.isolateGroupBound.html
- https://api.dart.dev/dart-ffi/NativeCallable/NativeCallable.listener.html
- https://api.dart.dev/dart-ffi/NativeCallable/NativeCallable.isolateLocal.html

### Apple

- https://developer.apple.com/documentation/corefoundation/cfrunloop
- https://developer.apple.com/documentation/CoreFoundation/CFRunLoopRun%28%29
- https://developer.apple.com/documentation/appkit/nsapplication/isrunning
- https://developer.apple.com/documentation/appkit/nsapplication/1428485-nexteventmatchingmask
- https://developer.apple.com/library/archive/documentation/General/Conceptual/MOSXAppProgrammingGuide/CoreAppDesign/CoreAppDesign.html
- https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/EventOverview/EventArchitecture/EventArchitecture.html
- https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/EventOverview/EventObjectsTypes/EventObjectsTypes.html
- https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/Multithreading/RunLoopManagement/RunLoopManagement.html
- https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/Multithreading/ThreadSafetySummary/ThreadSafetySummary.html
- https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/DistrObjects/Tasks/invocations.html
