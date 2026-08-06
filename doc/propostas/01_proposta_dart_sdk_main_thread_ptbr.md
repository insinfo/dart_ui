# Proposta de evolução do Dart SDK  
## Acesso suportado à **process main thread** e integração com event loops nativos

**Data:** 6 de agosto de 2026  
**Escopo inicial:** Dart standalone no macOS  
**Caso de uso de referência:** AppKit por `dart:ffi`, sem código-fonte C, C++, Objective-C ou Swift no projeto consumidor  
**Evidência experimental:** `insinfo/dart_ui`, workflow `macOS main-thread spike`, run `31078303894`  
**SHA executado pelo run:** `20d3e3aa4f9f158a52918902f77c4cc3fd3dc8d9`

---

## 1. Resumo executivo

O Dart standalone não oferece hoje uma API suportada para executar código na **primeira thread nativa do processo**. No macOS, essa thread é especial: `pthread_main_np()` só retorna `1` nela, e o AppKit depende dessa identidade para operações como a criação de `NSWindow` e a execução do loop principal de eventos.

A limitação já é acompanhada oficialmente em `dart-lang/sdk#38315`, aberta desde 2019. Também há trabalho ativo no SDK para aproximar threads nativas e isolates, principalmente em `dart-lang/sdk#56841`, na proposta de *shared native memory multithreading*. Partes importantes já existem no branch `main`, incluindo `NativeCallable.isolateGroupBound` e APIs experimentais de criação, entrada síncrona e fixação de isolates em threads. Entretanto, ainda falta a peça que entrega ao código Dart a **process main thread** do launcher standalone.

A proposta deste documento é adicionar ao SDK uma primitiva de baixo nível que permita ao launcher executar um ponto de entrada ABI diretamente na primeira thread do processo, fora de um callback de `CFRunLoop`, `NSTimer`, `dispatch` ou de outro event loop. Em termos conceituais:

```dart
typedef ProcessMainThreadEntryNative =
    IntPtr Function(Pointer<Void> context);

abstract final class ProcessMainThread {
  static external bool get isSupported;
  static external bool get isCurrent;

  static external Future<int> runNative(
    Pointer<NativeFunction<ProcessMainThreadEntryNative>> entryPoint,
    Pointer<Void> context,
  );
}
```

Essa operação permitiria que um pacote escrito em Dart:

1. criasse um `NativeCallable.isolateGroupBound`;
2. entregasse o ponteiro ao launcher;
3. inicializasse o AppKit na thread correta;
4. entrasse em `[NSApplication run]`;
5. mantivesse o isolate principal ativo em threads gerenciadas pela VM;
6. recebesse callbacks de UI por `NativeCallable.listener` ou `isolateGroupBound`.

A implementação é tecnicamente possível e se encaixa na arquitetura atual: o `main()` nativo já está na primeira thread; `Dart_RunLoop()` sai do isolate, agenda o message handler no thread pool da VM e deixa a thread chamadora esperando em um `Monitor`. Portanto, a thread desejada já está viva, desocupada de código Dart e em um ponto nativo controlado pelo SDK.

---

## 2. Problema

### 2.1 “Main isolate” não é “process main thread”

Um programa Dart possui um isolate principal, mas isso não implica que seu código execute na primeira thread criada pelo sistema operacional.

No macOS:

```c
pthread_main_np() == 1
```

somente na primeira thread da aplicação.

Nos probes executados em `macos-14`, arm64, com Dart 3.6.0:

```text
dart run                  -> pthread_main_np() = 0
dartaotruntime snapshot   -> pthread_main_np() = 0
executável AOT            -> pthread_main_np() = 0
```

Trocar JIT por AOT não altera a situação.

### 2.2 O AppKit possui duas exigências distintas

Para uma aplicação gráfica completa, não basta apenas chamar uma função na thread correta. É necessário resolver:

1. **identidade da thread:** executar na primeira thread do processo;
2. **loop de plataforma:** permitir que `[NSApplication run]` opere nessa thread;
3. **progresso do Dart:** manter timers, I/O, isolates e mensagens funcionando;
4. **comunicação bidirecional:** Dart → UI e UI → Dart;
5. **shutdown:** retornar ao launcher e finalizar a VM normalmente.

Uma API parecida com:

```dart
@Native<...>(runOnMainThread: true)
```

resolveria somente chamadas pontuais. Ela não define como iniciar o loop, como manter o processo vivo, como evitar deadlocks nem como integrar eventos Dart.

---

## 3. Evidência experimental

O spike já mediu os seguintes pontos:

| Probe | Hipótese | Resultado |
|---|---|---|
| A | Algum modo de execução entrega a thread 0 ao Dart | ❌ Refutada |
| B | `[NSApp run]` na thread do isolate transfere a titularidade | ❌ Refutada |
| C | WindowServer é alcançável sem AppKit | ✅ Confirmada |
| D | Um sinal consegue colocar a thread 0 em `CFRunLoopRun` | ✅ Confirmada |
| E | `NSInvocation` cria uma `NSWindow` na thread sequestrada | ✅ Confirmada |
| F | `nextEventMatchingMask:` bombeia eventos nessa configuração | ⛔ Trava |
| G | `[NSApp run]` funciona quando chamado de dentro do loop sequestrado | ❌ `SIGTRAP`/abort |
| H | `SLSNewWindow` cria uma janela WindowServer fora da main thread | ✅ Confirmada |
| I | Timers, I/O e isolates sobrevivem à perda da thread 0 | ✅ Confirmada |
| J | Uma chamada na thread de UI alcança o isolate | ✅ Confirmada |
| K | Um `NSTimer` elimina a causa observada em F | ⚠️ Inconclusivo |

### 3.1 O que foi provado

O probe I mostrou:

```text
timer fired after 253ms -> true
async file I/O round trip -> true
Isolate.run -> 42
```

Portanto, a VM não precisa da thread 0 para manter o isolate principal saudável.

O probe E mostrou que, quando a thread 0 está processando um `CFRunLoop`, uma chamada AppKit encaminhada até ela consegue criar uma `NSWindow`.

O probe J mostrou o caminho inverso: uma chamada realizada na thread 0 pode chegar ao isolate por um `NativeCallable.listener` instalado como IMP Objective-C.

### 3.2 O que ainda não foi provado

A entrega real de mouse e teclado ainda não foi demonstrada.

O probe K retornou `nil`, mas sua instrumentação não distingue claramente:

- timer que não disparou;
- timer que disparou e entrou em um pump bloqueado;
- pump que terminou com `nil`;
- primeira execução que recebeu o evento e execução repetida posterior que sobrescreveu o retorno com `nil`.

A proposta para o SDK não deve depender do resultado de K. A API precisa fornecer uma chamada **top-level** na primeira thread, permitindo que o AppKit instale seu próprio loop pela sequência normal.

---

## 4. Recursos e propostas já existentes no Dart SDK

### 4.1 `dart-lang/sdk#38315`

Issue aberta: **“os dialogs fail when called via dart:ffi on macOS (thread pinning Dart standalone)”**.

A discussão já considerou:

- um equivalente a `-XstartOnFirstThread`;
- uma flag `--start-on-main-thread-like-python`;
- expor a main thread ao FFI;
- um parâmetro conceitual `runOnMainThread: true`;
- integração com o event loop da plataforma;
- uso de embedder próprio como solução atual.

Ela continua aberta e é o destino mais natural para esta proposta ou para um comentário de design apontando para uma issue nova.

### 4.2 `dart-lang/sdk#52106`

A discussão mencionou explicitamente uma ideia de um isolate separado, sempre fixado à main thread, para receber mensagens e invocar APIs Apple.

Essa ideia antecipou parte da arquitetura agora possível com as APIs experimentais recentes.

### 4.3 `dart-lang/sdk#46943`

Issue sobre thread pinning e threads dedicadas.

Uma sugestão recente foi adicionar:

```dart
Isolate.spawn(..., dedicatedThread: true)
```

Isso resolve afinidade com **uma thread dedicada**, mas não resolve o macOS, porque uma nova thread nunca passa a ser a primeira thread do processo.

### 4.4 `dart-lang/sdk#56841`

Tracker de **shared native memory multithreading**.

O trabalho inclui ou evoluiu para:

- `NativeCallable.isolateGroupBound`;
- campos compartilháveis;
- primitivas de sincronização;
- entrada síncrona em isolates;
- fixação de isolate em thread;
- integração com event loops externos.

Em julho de 2025, os mantenedores informaram que grandes partes já haviam pousado, ainda protegidas por flag, sem ETA prometido. Os testes atuais usam:

```text
--experimental-shared-data
```

### 4.5 APIs presentes no branch `main`

O arquivo `sdk/lib/isolate/isolate.dart` já declara, marcadas como `@Since("3.13")`:

```dart
Isolate.create
Isolate.runSync
Isolate.shutdownSync
Isolate.pinToCurrentThread
Isolate.isPinnedToCurrentThread
Isolate.runEventLoopSync
Isolate.onEvent
Isolate.handleEvent
```

No estado atual do branch `main`:

- `create`, `runSync`, shutdown, pinning e `runEventLoopSync` possuem implementação;
- `onEvent` e `handleEvent` ainda lançam `UnsupportedError` na patch library da VM.

A documentação pública estável reflete Dart 3.12.2; portanto, essas APIs ainda não fazem parte do SDK estável documentado.

### 4.6 `NativeCallable.isolateGroupBound`

Já está documentado como callback invocável por qualquer thread nativa.

Restrições:

- executa no isolate group, não necessariamente dentro de um isolate normal;
- callback e retorno excepcional devem ser trivialmente compartilháveis;
- acesso a globals/statics não compartilhados produz erro;
- o recurso é experimental.

Isso é suficiente para servir como ponto de entrada inicial da process main thread.

### 4.7 Dart Engine / custom embedder

O SDK contém um `Dart Engine` em desenvolvimento:

```text
runtime/engine/include/dart_engine.h
samples/embedder/
```

Ele já permite:

- criar isolates;
- adquirir e liberar isolates;
- definir schedulers;
- tratar mensagens;
- drenar microtasks.

É uma rota válida para um custom embedder, mas ainda não faz parte do SDK publicado e obriga o usuário a manter um launcher nativo. A proposta deste documento leva a mesma capacidade ao launcher standalone oficial.

---

## 5. Por que a implementação é viável

### 5.1 A primeira thread já pertence ao launcher do SDK

O entry point nativo é:

```cpp
int main(int argc, char** argv) {
  dart::bin::main(argc, argv);
  UNREACHABLE();
}
```

Portanto, o SDK controla a thread que o macOS reconhece como principal.

### 5.2 `Dart_RunLoop()` não executa o isolate nessa thread

A implementação atual:

1. obtém o isolate corrente;
2. chama `Dart_ExitIsolate()`;
3. agenda o message handler no thread pool do isolate group;
4. espera em um `Monitor`;
5. volta a entrar no isolate apenas depois que o loop termina.

Trecho conceitual equivalente:

```cpp
Dart_ExitIsolate();

result = isolate->message_handler()->Run(
  isolate->group()->thread_pool(),
  RunLoopDone,
  &data,
);

while (!data.done) {
  monitor.Wait();
}

Dart_EnterIsolate(isolate);
```

Isso explica simultaneamente:

- por que o código Dart mede `pthread_main_np() == 0`;
- por que a thread 0 continua viva;
- por que o probe I não prejudica a VM;
- por que o SDK possui um ponto natural para processar uma solicitação de takeover.

### 5.3 Mudança mínima conceitual

O monitor usado por `Dart_RunLoop()` pode passar a acordar por dois motivos:

```text
A. isolate terminou;
B. chegou uma solicitação para executar na process main thread.
```

No caso B:

1. a thread 0 sai temporariamente da espera;
2. não existe isolate corrente nela;
3. o launcher invoca diretamente o ponteiro ABI;
4. o callback pode iniciar o event loop da plataforma;
5. quando ele retorna, o resultado é enviado ao isolate solicitante;
6. a thread volta a aguardar o término do programa ou uma nova tarefa.

Não é necessário migrar o isolate principal para a thread 0.

---

## 6. Objetivos

1. Permitir que Dart standalone use APIs que exigem a primeira thread do processo.
2. Manter o isolate principal em threads gerenciadas pela VM.
3. Permitir um loop de plataforma bloqueante na thread 0.
4. Funcionar em JIT, snapshot AOT e executável AOT.
5. Ser opt-in e não alterar programas CLI comuns.
6. Permitir implementação por embedders customizados.
7. Evitar APIs privadas, shellcode, sinais sequestrados e comportamento indefinido.
8. Compor com `NativeCallable.isolateGroupBound` e com as novas APIs de isolate.

---

## 7. Não objetivos

A primeira versão não precisa:

- carregar AppKit, Win32, GTK ou qualquer toolkit;
- fornecer widgets;
- escolher automaticamente o loop correto;
- tornar objetos Dart mutáveis compartilháveis;
- permitir que `NativeCallable.isolateLocal` seja chamado por outra thread;
- fornecer marshalling genérico de closures Dart arbitrárias;
- garantir que todo embedder possua uma process main thread utilizável;
- substituir Flutter.

O SDK entrega a thread. O pacote Dart continua responsável pelo toolkit via FFI.

---

## 8. API sugerida

### 8.1 API mínima

Localização em aberto: `dart:ffi`, `dart:isolate` ou uma futura biblioteca nativa de concorrência.

```dart
import 'dart:ffi';

typedef ProcessMainThreadEntryNative =
    IntPtr Function(Pointer<Void> context);

abstract final class ProcessMainThread {
  /// Indica se o embedder atual implementa esta capacidade.
  static external bool get isSupported;

  /// Verdadeiro somente na primeira thread nativa do processo.
  static external bool get isCurrent;

  /// Executa [entryPoint] diretamente na process main thread.
  ///
  /// A chamada é feita pelo launcher, fora de callbacks de CFRunLoop,
  /// libdispatch, NSTimer ou event loops equivalentes.
  ///
  /// Somente uma execução pode estar ativa. O Future termina quando o
  /// entry point retorna.
  static external Future<int> runNative(
    Pointer<NativeFunction<ProcessMainThreadEntryNative>> entryPoint,
    Pointer<Void> context,
  );
}
```

### 8.2 Semântica

- `isSupported == false` em embedders que não registraram implementação.
- `isCurrent` não significa “mutator thread”; significa a primeira thread nativa.
- `runNative` é assíncrono para o isolate solicitante.
- o callback é síncrono e pode permanecer bloqueado em um loop de plataforma;
- chamadas concorrentes são rejeitadas ou enfileiradas de forma definida;
- uma chamada aninhada a partir da própria thread é rejeitada ou executada diretamente;
- o callback deve retornar para permitir shutdown normal;
- enquanto ativo, o request mantém o processo/VM vivos;
- erros do callback usam o `exceptionalReturn` do `NativeCallable` ou um código de saída;
- após retorno, o Future recebe o código.

### 8.3 Uso com `isolateGroupBound`

```dart
typedef MainEntryNative =
    IntPtr Function(Pointer<Void> context);

int appKitMain(Pointer<Void> context) {
  if (!ProcessMainThread.isCurrent) {
    return -1;
  }

  initializeNSApplication(context);
  createInitialWindow(context);

  // Chamada top-level real na process main thread.
  runNSApplication();

  return 0;
}

Future<void> startUi(Pointer<Void> context) async {
  final entry =
      NativeCallable<MainEntryNative>.isolateGroupBound(
        appKitMain,
        exceptionalReturn: -2,
      );

  try {
    final result = await ProcessMainThread.runNative(
      entry.nativeFunction,
      context,
    );

    if (result != 0) {
      throw StateError('AppKit finalizou com código $result');
    }
  } finally {
    entry.close();
  }
}
```

O exemplo é conceitual. Dentro de `appKitMain`, estado não compartilhado do isolate não pode ser acessado diretamente.

---

## 9. Por que a chamada deve ser top-level

Uma primeira versão baseada apenas em:

```text
CFRunLoopSource
dispatch_async
NSTimer
performSelectorOnMainThread
```

não oferece o contrato necessário para inicializar qualquer toolkit.

Os probes mostraram:

- `NSWindow` funciona por `NSInvocation`;
- `[NSApp run]`, chamado de dentro do `CFRunLoop` sequestrado, aborta com `SIGTRAP`;
- o pump manual ainda não está funcional.

Uma chamada direta pelo launcher produz a pilha esperada:

```text
main()
  dart::bin::main()
    ProcessMainThread.runNative entry
      [NSApplication run]
```

em vez de:

```text
signal handler / CFRunLoop callback / NSTimer
  NSInvocation
    [NSApplication run]
```

O SDK não deve prometer somente “executar em algum momento na thread”. Deve prometer “executar diretamente pelo owner nativo da thread, em um ponto de takeover”.

---

## 10. Implementação proposta no standalone

### 10.1 Coordenador

```cpp
enum class MainThreadRequestState {
  kIdle,
  kPending,
  kRunning,
  kCompleted,
  kShuttingDown,
};

struct MainThreadRequest {
  intptr_t (*entry)(void* context);
  void* context;
  Dart_Port completion_port;
  intptr_t result;
};
```

### 10.2 Loop de espera

Pseudocódigo:

```cpp
while (!isolate_done) {
  monitor.WaitUntil([&] {
    return isolate_done || coordinator.HasPendingRequest();
  });

  if (coordinator.HasPendingRequest()) {
    MainThreadRequest request = coordinator.Take();

    monitor.Exit();
    const intptr_t result = request.entry(request.context);
    monitor.Enter();

    coordinator.Complete(request, result);
  }
}
```

Na implementação real, o monitor e o lifetime do `RunLoopData` precisam ser reorganizados para que a fila seja segura e para que o callback possa permanecer ativo por toda a vida da aplicação gráfica.

### 10.3 Hook de embedder

Para respeitar a separação entre VM e embedder, pode ser necessário um hook:

```c
typedef bool (*Dart_ProcessMainThreadRunner)(
    Dart_ProcessMainThreadEntry entry,
    void* context,
    Dart_Port completion_port);

DART_EXPORT void Dart_SetProcessMainThreadRunner(
    Dart_ProcessMainThreadRunner runner);
```

O standalone instala sua implementação. Flutter ou outros embedders podem:

- fornecer implementação equivalente;
- mapear para sua platform thread quando semanticamente correto;
- ou declarar `isSupported == false`.

### 10.4 Completion

A thread 0 pode postar o resultado por uma API thread-safe de ports, sem entrar no isolate solicitante.

O Future é completado no isolate normal.

---

## 11. Integração futura com isolate de UI

Quando `Isolate.onEvent` e `Isolate.handleEvent` forem implementados:

```text
process main thread
└─ AppKit event loop
   ├─ UI nativa
   └─ chama uiIsolate.handleEvent() quando notificada

ui isolate
├─ criado por Isolate.create()
├─ inicializado por runSync()
├─ fixado com pinToCurrentThread()
└─ onEvent apenas acorda o loop externo
```

A documentação proposta para `onEvent` já estabelece a regra correta:

- o callback pode ocorrer em thread arbitrária;
- ele somente notifica o loop externo;
- não deve chamar `handleEvent` diretamente;
- o loop externo chama `handleEvent` depois.

Essa é a segunda camada da solução. `ProcessMainThread.runNative` fornece a primeira.

---

## 12. Comunicação durante o loop AppKit

### 12.1 Dart → UI

Depois que `[NSApp run]` está ativo:

- `performSelectorOnMainThread:`;
- main dispatch queue;
- `NSInvocation`;
- uma source própria do run loop.

O probe E já provou esse sentido.

### 12.2 UI → Dart assíncrono

`NativeCallable.listener`:

- pode ser chamado por qualquer thread;
- retorna `void`;
- entrega a chamada futuramente ao isolate criador.

O probe J já provou esse sentido.

### 12.3 UI → Dart síncrono

Para delegates com retorno imediato:

- `NativeCallable.isolateGroupBound`;
- estado em memória nativa;
- campos compartilháveis quando estabilizados;
- ou decisões pequenas mantidas no lado nativo.

`listener` não serve para métodos como:

```objc
- (BOOL)windowShouldClose:(id)sender;
```

porque o chamador precisa do retorno antes de continuar.

---

## 13. Alternativas consideradas

### 13.1 `--start-on-main-thread`

É uma alternativa possível e deve continuar em discussão.

Benefícios:

- `main()` Dart começa diretamente na thread 0;
- chamadas FFI iniciais ao AppKit ficam naturais.

Problemas:

- o isolate precisa ser permanentemente fixado;
- `[NSApp run]` bloqueia o event loop Dart;
- timers, Futures e ReceivePorts do mesmo isolate não progridem sem integração;
- callbacks reentrantes e microtasks precisam de contrato;
- altera mais profundamente o comportamento do runtime.

Pode ser oferecido futuramente, mas não substitui uma primitiva de takeover.

### 13.2 `dedicatedThread: true`

Resolve afinidade e TLS, mas cria uma nova thread. No macOS, ela não é a process main thread.

### 13.3 `@Native(runOnMainThread: true)`

Bom açúcar sintático para chamadas curtas, mas depende de uma infraestrutura anterior e não resolve loops bloqueantes.

### 13.4 `dispatch_sync_f`

Trava quando a main queue não está sendo drenada e cria riscos de deadlock mesmo quando está.

### 13.5 Sequestro por sinal

Útil como prova experimental, inadequado para produção:

- assinatura de signal handler incompatível;
- `CFRunLoopRun` não é async-signal-safe;
- interrupção de código não reentrante;
- handler que não retorna;
- shutdown e tratamento de sinais comprometidos.

### 13.6 SkyLight/CGS

Cria janela sem AppKit, mas:

- é API privada;
- quebra compatibilidade e App Store;
- não fornece input, menu, IME e acessibilidade;
- exige descobrir ABIs não públicas.

### 13.7 Custom embedder

É a solução suportável atual, mas transfere para cada pacote o custo de distribuir e manter código nativo. O launcher oficial pode resolver isso uma única vez.

---

## 14. Segurança e deadlocks

A especificação deve declarar:

1. não chamar `runNative` síncrona e bloqueantemente a partir de uma thread que o callback precisa;
2. não permitir dois loops de plataforma simultâneos;
3. rejeitar callback `nullptr`;
4. evitar callbacks leaf de longa duração;
5. manter o contexto válido até o retorno;
6. definir comportamento se o isolate solicitante terminar;
7. impedir cleanup da VM enquanto o callback estiver ativo;
8. documentar que código `isolateGroupBound` não possui estado normal de isolate;
9. proibir uso de `NativeCallable.isolateLocal` como entry;
10. preservar tratamento de `SIGINT`, `SIGTERM`, profiler e VM Service.

---

## 15. Compatibilidade entre plataformas

### macOS

Implementação prioritária. A primeira thread é exigência real de AppKit/Cocoa.

### Windows

Muitas APIs de janela exigem consistência de thread, mas não necessariamente a primeira thread do processo. Ainda assim, o callback pode criar uma janela e executar `GetMessage`/`DispatchMessage`.

### Linux

X11, Wayland e toolkits possuem regras próprias. A API não precisa criar dependência obrigatória de GLib. O callback pode iniciar o loop escolhido pelo pacote.

### Embedders

A capacidade é opt-in. `isSupported` evita promessas falsas.

---

## 16. Plano incremental

### Fase 1 — diagnóstico e API experimental

- nova issue ou design comment em `#38315`;
- API escondida por flag;
- implementação macOS standalone;
- callback ABI somente;
- testes de identidade de thread e lifecycle.

### Fase 2 — AppKit de ponta a ponta

- exemplo oficial ou teste interno;
- `[NSApplication run]`;
- `NSWindow`;
- input real em bot com sessão gráfica;
- shutdown normal.

### Fase 3 — integração de isolate externo

- concluir `Isolate.onEvent`;
- concluir `Isolate.handleEvent`;
- exemplo de isolate de UI fixado à thread 0.

### Fase 4 — outros sistemas

- Windows;
- Linux;
- contrato para custom embedders.

---

## 17. Critérios de aceitação

### Thread

- `pthread_main_np() == 1` dentro do callback;
- JIT, snapshot AOT e executable AOT;
- macOS x64 e arm64;
- sem shellcode;
- sem sinais sequestrados.

### AppKit

- `NSApplication` inicia;
- `[NSApp run]` não aborta;
- `NSWindow` abre e recebe foco;
- mouse e teclado chegam;
- menu, IME e ativação funcionam;
- janela fecha e o callback retorna.

### Dart

- timers e I/O continuam;
- isolates continuam;
- VM Service e profiler continuam;
- UI → Dart e Dart → UI funcionam;
- GC continua sob carga.

### Shutdown

- sem `_exit()`;
- `main()` finaliza normalmente;
- cleanup da VM executa;
- signals permanecem funcionais.

### Compatibilidade

- zero mudança quando a API não é usada;
- `isSupported == false` em embedder sem implementação;
- testes de corrida e chamadas concorrentes.

---

## 18. Destino recomendado

### Opção A — comentário técnico em `#38315`

É a opção com menor risco de duplicação.

### Opção B — nova issue de design

Título sugerido:

```text
[vm/standalone][ffi] Expose a supported process-main-thread takeover API
```

Referenciar:

- `dart-lang/sdk#38315`;
- `dart-lang/sdk#52106`;
- `dart-lang/sdk#46943`;
- `dart-lang/sdk#56841`;
- `dart-lang/language/working/333`.

---

## 19. Referências

- https://github.com/dart-lang/sdk/issues/38315
- https://github.com/dart-lang/sdk/issues/52106
- https://github.com/dart-lang/sdk/issues/46943
- https://github.com/dart-lang/sdk/issues/56841
- https://github.com/dart-lang/language/blob/main/working/333%20-%20shared%20memory%20multithreading/shared_native_memory.md
- https://github.com/dart-lang/sdk/blob/main/sdk/lib/isolate/isolate.dart
- https://github.com/dart-lang/sdk/blob/main/sdk/lib/_internal/vm/lib/isolate_patch.dart
- https://github.com/dart-lang/sdk/blob/main/runtime/bin/main.cc
- https://github.com/dart-lang/sdk/blob/main/runtime/bin/main_impl.cc
- https://github.com/dart-lang/sdk/blob/main/runtime/vm/dart_api_impl.cc
- https://github.com/dart-lang/sdk/blob/main/runtime/engine/include/dart_engine.h
- https://api.dart.dev/dart-ffi/NativeCallable/NativeCallable.isolateGroupBound.html
- https://api.dart.dev/dart-ffi/NativeCallable/NativeCallable.isolateLocal.html
- https://developer.apple.com/documentation/corefoundation/cfrunloop
- https://developer.apple.com/library/archive/documentation/General/Conceptual/MOSXAppProgrammingGuide/CoreAppDesign/CoreAppDesign.html
