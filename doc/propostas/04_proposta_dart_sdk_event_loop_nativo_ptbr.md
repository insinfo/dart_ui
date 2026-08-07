# Proposta de evolução do Dart SDK
## Integração suportada entre o event loop do Dart e event loops nativos

**Data:** 7 de agosto de 2026
**Escopo:** Dart standalone em Windows, Linux e macOS
**Caso de uso de referência:** framework de UI 100% Dart sobre `dart:ffi`, sem código C, C++, Objective-C ou Swift no projeto consumidor
**Evidência experimental:** `insinfo/dart_ui`, POCs 01, 02, 03, 09, 10 e 19 (medição quantitativa)
**Proposta irmã:** [`01_proposta_dart_sdk_main_thread_ptbr.md`](01_proposta_dart_sdk_main_thread_ptbr.md)

---

## 1. Resumo executivo

A proposta 01 trata de **qual thread** executa o código de UI. Este documento trata do problema seguinte, e independente: **como duas filas de eventos coexistem na mesma thread**.

Todo toolkit de janela nativo é construído em torno de um loop que **bloqueia** esperando input: `GetMessage`/`MsgWaitForMultipleObjectsEx` no Win32, `poll`/`epoll` sobre o file descriptor da conexão no X11 e Wayland, `CFRunLoopRun` e `[NSApp run]` no macOS. O Dart também tem um loop bloqueante — o message handler do isolate, que serve `Timer`, `Future`, microtasks, `ReceivePort` e I/O assíncrono.

Os dois querem a mesma thread e não se conhecem. Hoje o SDK não oferece nenhuma primitiva suportada para reconciliá-los. O que resta ao código Dart é **polling cooperativo**: nunca bloquear de verdade no loop nativo, acordar em intervalos arbitrários e ceder ao Dart com uma fronteira assíncrona artificial. Este padrão está implementado e funcionando em [`poc_10_event_loop`](../../poc/poc_10_event_loop/lib/src/win32_event_loop.dart), e o custo é estrutural, não um defeito de implementação.

Diferente do problema da proposta 01, **este afeta as três plataformas por igual**. Windows e Linux não precisam da process main thread — os POCs 01 e 02 já criam janelas na própria thread do isolate — mas precisam exatamente da mesma integração de loop.

A auditoria do `dart-lang/sdk` em 7 de agosto de 2026 encontrou a superfície
necessária já declarada em `dart:isolate`, marcada `@Since("3.13")`:
`Isolate.onEvent` notifica um loop externo e `Isolate.handleEvent` processa no
máximo um evento. Na VM, porém, ambas ainda lançam `UnsupportedError`.

O pedido mínimo desta proposta é **implementar essas duas APIs existentes**, em
vez de criar uma segunda abstração concorrente. Uma consulta de deadline pode
ser avaliada depois como otimização, mas não é pré-requisito: `onEvent` deve
acordar o loop externo inclusive quando um timer se torna pronto.

```dart
final isolate = Isolate.create(debugName: 'native-ui');
isolate.onEvent = wakeNativeLoop; // callback em thread arbitrária
```

O loop nativo mantém uma contagem das notificações recebidas e, em sua thread,
chama uma vez para cada notificação:

```dart
while (running) {
  nativeWaitForInputOrDartWake();          // pode bloquear de verdade
  drainNativeEvents();
  while (dartWakeCount > 0) {
    dartWakeCount--;
    isolate.handleEvent();                 // no máximo um evento
  }
}
```

Sem timeout arbitrário, sem acordar a CPU à toa, sem `Future.delayed(Duration.zero)` como muleta.

---

## 2. Delimitação: o que esta proposta **não** é

Para evitar duplicação com a proposta 01 e com `#56841`:

| Problema | Onde é tratado |
|---|---|
| Obter a primeira thread do processo (macOS/AppKit) | Proposta 01 — `ProcessMainThread.runNative` |
| Compartilhar memória mutável entre isolates | `dart-lang/sdk#56841` |
| Fixar um isolate a uma thread | `Isolate.pinToCurrentThread` (já existe em `main`) |
| **Fazer o loop do Dart e um loop nativo coexistirem** | **Implementar `onEvent`/`handleEvent`; este documento** |

As três são ortogonais. A proposta 01 sozinha entrega a thread ao AppKit e o event loop do Dart continua parado enquanto `[NSApp run]` estiver ativo. Esta proposta sozinha resolve Windows e Linux por completo, e resolve o macOS assim que a proposta 01 entregar a thread. Nenhuma substitui a outra.

---

## 3. O problema

### 3.1 As duas filas

Um programa Dart com UI precisa servir simultaneamente:

**Fila nativa** — `WM_PAINT`, `WM_KEYDOWN`, `WM_MOUSEMOVE`, `XCB_EXPOSE`, `wl_callback`, `NSEvent`. Chega do sistema operacional, tipicamente por uma fila em kernel ou um file descriptor, e é servida por uma chamada bloqueante.

**Fila Dart** — microtasks, `Timer`, `Future` de I/O, `ReceivePort`, resultados de `Isolate.run`. É servida pelo message handler do isolate.

Enquanto a thread está dentro de `GetMessage`, nenhum `Timer` do Dart dispara. Enquanto a thread está dentro do message handler do Dart, nenhuma mensagem `WM_PAINT` é despachada. Não existe API para esperar nas duas ao mesmo tempo.

### 3.2 O que o código Dart faz hoje

O padrão real, implementado em [`win32_event_loop.dart:30-42`](../../poc/poc_10_event_loop/lib/src/win32_event_loop.dart#L30-L42):

```dart
Future<void> pump(Duration timeout) async {
  _drainMessages();
  MsgWaitForMultipleObjectsEx(
    0, nullptr, timeout.inMilliseconds,
    QUEUE_STATUS_FLAGS.QS_ALLINPUT,
    MSG_WAIT_FOR_MULTIPLE_OBJECTS_EX_FLAGS.MWMO_INPUTAVAILABLE,
  );
  _drainMessages();
  await Future<void>.delayed(Duration.zero);
}
```

chamado em laço com `idleTimeout = 50ms`:

```dart
while (!shouldStop() && !_disposed) {
  await pump(idleTimeout);
}
```

Funciona — a POC-10 passa, com `Timer.periodic` de 100 ms convivendo com a fila Win32 e `PostThreadMessage(WM_APP+1)` como wakeup. Mas veja o que esse código é obrigado a fazer:

1. **Nunca bloquear indefinidamente.** O timeout de 50 ms não tem relação com nada; é um palpite. Se fosse `INFINITE`, os `Timer` do Dart nunca disparariam.
2. **Adivinhar o deadline.** Como `onEvent` ainda não funciona na VM, o código
   não recebe o wakeup que deveria ocorrer quando um `Timer` vence. Por isso é
   obrigado a escolher um timeout: cedo demais desperdiça CPU; tarde demais
   atrasa o timer. Uma consulta de deadline ajudaria, mas implementar o wakeup
   já elimina essa obrigação.
3. **Criar uma fronteira assíncrona artificial.** `await Future<void>.delayed(Duration.zero)` existe só para devolver o controle ao message handler do isolate. É a única forma de "rodar um turno do Dart" a partir de Dart, e ela não é um turno — é uma volta completa pelo escalonador. Medida na POC-19: ~6 µs em laço apertado, mas ~250 µs quando precedida de uma espera nativa bloqueante, que é o caso real.
4. **Acordar o loop nativo a partir da aplicação.** O `Timer.periodic` chama
   `loop.wake()` para forçar a saída do `MsgWaitForMultipleObjectsEx`. O produtor
   precisa conhecer o pump; `Isolate.onEvent` existe para transferir essa
   responsabilidade ao runtime, mas ainda não está implementado.

### 3.3 O custo, medido

A [POC-19](../../poc/poc_19_event_loop_metrics) mede esse custo diretamente. Ela compara o padrão atual (`polling`, timeout fixo) com um loop que deriva o timeout do próximo deadline do Dart e é acordado por um evento de kernel quando surge trabalho novo — ou seja, com o que a API desta proposta permitiria. Windows 11, Dart 3.6.2, 3 s por configuração:

| Métrica | polling 50 ms (o que existe hoje) | *oracle* (API proposta) | referência |
|---|---|---|---|
| Timer de 60 Hz, taxa efetiva | **16,0 Hz** | **59,2 Hz** | alvo 60,0; Dart puro 61,0 |
| Intervalo entre frames, p95 | 63,81 ms | 31,00 ms | Dart puro 17,38 ms |
| Latência de mensagem entre isolates, p95 | **63,02 ms** | **0,54 ms** | Dart puro 0,23 ms |
| Wakeups ociosos por segundo (app parada) | 14,0 | 0,3 | — |

O primeiro número é o mais grave e o menos intuitivo: **não se trata de atraso, e sim de frequência**. `Timer.periodic` reagenda a partir do instante em que dispara, então um timer faminto não recupera o atraso — ele passa a rodar mais devagar. Um loop de polling de 50 ms transforma uma animação de 60 Hz em uma de 16 Hz.

Reduzir o timeout ajuda a animação e não resolve o resto: com 4 ms, a taxa de frames volta a 62,3 Hz, mas o loop passa a acordar 62 vezes por segundo sem ter o que fazer quando a aplicação está parada. E a alternativa oposta — não bloquear (`spin`) — custa **116% de CPU e 3,1 bilhões de ciclos por segundo sem fazer nada**.

Não existe escolha de timeout que resolva simultaneamente animação, latência e ociosidade, porque a informação necessária para escolhê-lo — quando o Dart tem trabalho — não está exposta.

Além do que foi medido, permanecem dois problemas qualitativos:

| Consequência | Origem |
|---|---|
| Ordenação indefinida | não há contrato sobre input nativo vs. microtask Dart pendente |
| Reentrância não contratada | `SendMessage`, diálogo modal, menu nativo e IME reentram no loop; o estado do escalonador Dart nesse ponto não é especificado |

Isto está catalogado no roteiro do projeto como **risco R04 — "event loop Dart compete com loop nativo", probabilidade alta, impacto crítico** ([ROTEIRO, linha 5160](../ROTEIRO_FRAMEWORK_MULTIPLATAFORMA_100_PURO_DART.md#L5160)).

#### Ressalvas sobre a medição

Quatro, registradas porque afetam como os números devem ser citados:

1. **O Windows arredonda timeouts para a resolução do timer do sistema** (~15,6 ms nesta máquina). A POC reporta lado a lado o timeout pedido e o efetivamente esperado, e oferece `--high-res-timer` para verificação. Que seja preciso chamar `timeBeginPeriod(1)` — uma mudança global de resolução, com custo de energia — para contornar a ausência de uma API de agendamento é argumento adicional, não ruído.
2. **A métrica de ciclos de CPU é do processo inteiro** e não isola o loop na taxa de wakeups do cenário ocioso. A afirmação defensável ali é a contagem de wakeups, não o consumo de ciclos.
3. **Execução única, máquina desktop com CPU híbrida.** As quatro linhas da tabela têm margem larga o bastante para a variância observada; nenhum valor isolado deve ser citado com precisão de décimos.
4. **Reprodução.** Execute `dart run bin/main.dart` dentro de
   `poc/poc_19_event_loop_metrics`. Uma repetição em 7 de agosto de 2026 mediu
   16,3 Hz vs. 58,8 Hz e latência p95 de 62,89 ms vs. 0,56 ms; pequenas diferenças
   em relação à tabela são variância esperada, não uma mudança de conclusão.

### 3.4 A mesma forma nas três plataformas

| Plataforma | Espera bloqueante nativa | Precisa de thread 0? | Precisa de integração de loop? |
|---|---|---|---|
| Windows | `MsgWaitForMultipleObjectsEx`, `GetMessageW` | ❌ Não — afinidade de thread basta | ✅ Sim |
| Linux/X11 | `poll`/`ppoll`/`epoll` no FD do XCB | ❌ Não | ✅ Sim |
| Linux/Wayland | `poll` no FD do `wl_display` | ❌ Não | ✅ Sim |
| macOS | `CFRunLoopRun`, `[NSApp run]` | ✅ Sim (proposta 01) | ✅ Sim |

A coluna que importa aqui é a última: **é a única marcada nas quatro linhas**.

O roteiro já descreve, para o backend X11, o fluxo que a API proposta tornaria implementável ([ROTEIRO §15.4](../ROTEIRO_FRAMEWORK_MULTIPLATAFORMA_100_PURO_DART.md)):

```text
1. drenar eventos já enfileirados;
2. processar tarefas prioritárias;
3. registrar/atualizar a fonte de wakeup do runtime;
4. aguardar FD/timer/wakeup;        <-- `onEvent` ainda é UnsupportedError
5. chamar xcb_poll_for_event;
```

O passo 3 tem API pública declarada, mas ainda não tem implementação na VM.

---

## 4. Evidência experimental

| POC | O que estabelece |
|---|---|
| [`poc_01_win32_window`](../../poc/poc_01_win32_window) | Janela Win32, class registration e `WndProc` via `NativeCallable.isolateLocal`, na própria thread do isolate. Confirma que o Windows **não** precisa da thread 0 |
| [`poc_02_x11_window`](../../poc/poc_02_x11_window) | Conexão XCB, janela mapeada, `XCB_EXPOSE` recebido, `xcb_put_image`. Confirma que o Linux **não** precisa da thread 0 |
| [`poc_09_wayland`](../../poc/poc_09_wayland) | Bindings e probe de Wayland |
| [`poc_10_event_loop`](../../poc/poc_10_event_loop) | Integração cooperativa Win32 + `Timer` funciona, **ao custo dos quatro compromissos da §3.2** |
| [`poc_19_event_loop_metrics`](../../poc/poc_19_event_loop_metrics) | Quantifica esse custo e mede o ganho da API proposta: 16,0 Hz → 59,2 Hz, 63,02 ms → 0,54 ms, 14,0 → 0,3 wakeups ociosos/s (§3.3) |
| [`poc_03_appkit_window`](../../poc/poc_03_appkit_window) | A rota AppKit continua dependente da thread 0; a rota SkyLight/CGS já confirmou janela, pixels e três eventos `[10, 11, 5]` fora da main thread |

O ponto a destacar para os mantenedores: **as plataformas onde o Dart já consegue abrir uma janela hoje são precisamente as que demonstram esta limitação de forma isolada**, sem o ruído do problema de main thread do macOS. Windows e Linux são o caso de teste limpo.

---

## 5. O que já existe no SDK e o que falta

Base da auditoria: `dart-lang/sdk@741e4646241d0d1940ccb67c428a24e06357d4a7`,
HEAD de `main` consultado em 7 de agosto de 2026. Os links da seção 14 apontam
para `main` por conveniência; as conclusões abaixo referem-se a esse commit.

### 5.1 `Isolate.runEventLoopSync`

Presente no branch `main`, marcada `@Since("3.13")`, com implementação na VM.
O contrato é preciso: executa o loop sincronamente na thread corrente e só
retorna quando o isolate **não tem mais receive ports keep-alive**. Também fixa
o isolate à thread corrente.

Isso serve para entregar a thread inteira ao loop do isolate até seu shutdown.
Não serve para intercalar um turno Dart com um turno Win32/X11/AppKit, porque um
isolate de aplicação normalmente mantém portas abertas por toda a vida da UI.

### 5.2 `Isolate.onEvent` / `Isolate.handleEvent`

Declaradas no branch `main`, também `@Since("3.13")`, mas **ainda lançam `UnsupportedError`** na patch library da VM.

O contrato documentado é exatamente o certo:

- `onEvent` pode ser chamado de thread arbitrária;
- ele deve **apenas notificar** o loop externo;
- não deve chamar `handleEvent` diretamente;
- o loop externo chama `handleEvent` depois, na thread correta.

`handleEvent` já é a operação que a versão anterior deste documento chamou de
`runOnce`, com uma diferença importante: o contrato promete **no máximo um
evento**, não drenagem total. `onEvent` já é o registro de wakeup. Criar
Criar novos nomes para essas duas operações duplicaria uma API pública ainda
antes de ela ser implementada. O pedido de Fase 1 é simplesmente implementá-la.

### 5.3 O que continua faltando mesmo com elas prontas

**Deadline é uma otimização a validar, não uma dependência.** Se `onEvent` for
chamado quando um timer se tornar pronto, o loop externo pode dormir
indefinidamente sobre sua fonte de wakeup; não precisa conhecer antecipadamente
o deadline. Uma futura consulta pode ajudar APIs nativas baseadas somente em
timeout e diagnóstico do scheduler, mas deve ser proposta apenas se os testes
da implementação mostrarem uma lacuna real.

**A ordenação.** Não há contrato sobre o que acontece quando o loop nativo reentra (diálogo modal, `SendMessage`, menu) enquanto `handleEvent` está executando.

### 5.4 Resumo da lacuna

| Peça | Estado |
|---|---|
| Notificar loop externo de trabalho Dart pendente | `Isolate.onEvent` — declarada, **não implementada** |
| Executar um turno do loop Dart sob demanda | `Isolate.handleEvent` — declarada, **não implementada** |
| Consultar o próximo deadline do Dart | não existe; opcional se `onEvent` também cobrir timers |
| Contrato de reentrância | **não especificado** |

---

## 6. Proposta A — implementar a API já declarada

### 6.1 Superfície mínima

Nenhum nome público novo é necessário na primeira fase. A superfície já está em
`dart:isolate`:

```dart
@Since("3.13")
external void set Isolate.onEvent(void Function(Isolate) callback);

@Since("3.13")
external void Isolate.handleEvent();
```

### 6.2 Semântica

- `onEvent` é chamado uma vez para cada novo evento e pode executar em thread
  arbitrária, fora de qualquer isolate; seu callback deve ser profundamente
  imutável e apenas sinalizar o loop externo.
- `handleEvent` é chamado depois, pela thread que hospeda o loop, e processa no
  máximo um evento sem esperar por evento novo.
- a implementação deve definir como desregistrar/substituir `onEvent` e quando o
  escalonamento normal da VM deixa de ser dono do isolate;
- a notificação precisa cobrir mensagens, timers prontos e eventos de I/O que o
  isolate precise tratar;
- chamar `handleEvent` de dentro de `onEvent` continua proibido: a documentação
  atual avisa que isso causa deadlock.

### 6.3 Uso em Windows

```dart
void runWin32Loop(Win32Window window) {
  final isolate = Isolate.create(debugName: 'win32-ui');
  var pendingDartEvents = 0; // na implementação real: contador atômico
  isolate.onEvent = (_) {
    incrementSharedCounterAndPostThreadMessage();
  };

  while (!window.closed) {
    MsgWaitForMultipleObjectsEx(
      0, nullptr, INFINITE, QS_ALLINPUT, MWMO_INPUTAVAILABLE,
    );
    _drainMessages();
    pendingDartEvents += takeSharedWakeCount();
    while (pendingDartEvents > 0) {
      pendingDartEvents--;
      isolate.handleEvent();
    }
  }
}
```

O callback conceitual incrementa um contador compartilhado e faz
`PostThreadMessage(threadId, WM_APP+1, 0, 0)`. O contador importa porque a API
promete uma notificação por evento e `handleEvent` trata no máximo um; um bit
booleano poderia perder notificações coalescidas.

Compare com [`win32_event_loop.dart`](../../poc/poc_10_event_loop/lib/src/win32_event_loop.dart) atual: some o timeout mágico de 50 ms, some o `await Future.delayed(Duration.zero)`, some o `Timer` que existe só para acordar o loop, e o método deixa de ser `async`.

### 6.4 Uso em Linux (X11/Wayland) e macOS

**X11** — `onEvent` escreve em um `eventfd`; o `poll` espera indefinidamente nos
dois FDs (conexão XCB e eventfd).

**Wayland** — idêntico, sobre o FD de `wl_display`, respeitando o protocolo
`wl_display_prepare_read`/`wl_display_read_events`.

**macOS** — dentro do callback entregue por `ProcessMainThread.runNative`
(proposta 01), `onEvent` sinaliza uma `CFRunLoopSource` e chama
`CFRunLoopWakeUp`; a source chama `handleEvent` na thread correta. Assim
`[NSApp run]` permanece dono do loop, como o AppKit exige.

Este último ponto é o que fecha a lacuna deixada pela proposta 01: sem esta API, entregar a thread ao AppKit congela o event loop do Dart.

### 6.5 Reentrância

O contrato precisa ser explícito, porque diálogo modal, `SendMessage`, drag-and-drop, menu nativo e IME **reentram** no loop nativo enquanto uma chamada Dart está na pilha.

Proposta de regra:

- `handleEvent` chamado enquanto outro `handleEvent` está ativo deve rejeitar a
  reentrada de modo definido ou enfileirá-la, nunca deadlockar silenciosamente;
- loops nativos aninhados preservam o contador de notificações;
- a especificação deve dizer se microtasks criadas pelo evento pertencem ao
  mesmo turno e como exceções não capturadas são encaminhadas;
- timers e mensagens produzidos durante o turno geram nova notificação, sem
  recursão imediata.

---

## 7. Propostas secundárias

As quatro seguintes são lacunas reais, medidas neste projeto, e **separáveis**. Cada uma deveria virar sua própria issue; estão aqui para dar o quadro completo do que falta ao Dart para sustentar um framework de UI nativo.

### 7.1 B — callback síncrono a partir de thread estrangeira

**Problema.** Um `WndProc` precisa **retornar um valor** ao chamador nativo. `- (BOOL)windowShouldClose:` também. As três variantes de `NativeCallable` cobrem isso mal:

| Variante | Thread estrangeira | Retorno síncrono | Estado do isolate |
|---|---|---|---|
| `isolateLocal` | ❌ aborta o processo | ✅ | ✅ completo |
| `listener` | ✅ | ❌ só `void` | ✅ completo |
| `isolateGroupBound` | ✅ | ✅ | ❌ sem statics não compartilhados |

No Windows não há problema: a janela e o pump vivem na thread do isolate, e `isolateLocal` funciona — é o que [`poc_01`](../../poc/poc_01_win32_window/lib/src/win32_window.dart#L158) faz. No macOS com a proposta 01, os delegates rodam na thread 0, que **não** é a thread do isolate, e só `isolateGroupBound` serve — experimental, e sem acesso a estado normal de isolate.

**Pedido.** Estabilizar `NativeCallable.isolateGroupBound` e, junto com `#56841`, tornar viável manter o estado de uma janela em campos compartilháveis. Alternativamente, uma variante que entre sincronamente em um isolate específico e fixado a outra thread, algo como `NativeCallable.isolateBound(isolate, fn)`, bloqueando o chamador nativo até o retorno.

### 7.2 C — lifetime seguro de `NativeCallable`

**Problema.** Se o sistema operacional invoca um `NativeCallable` depois de `close()`, o resultado é indefinido — na prática, crash do processo. Em UI isso não é hipotético: `WM_NCDESTROY`, `wl_callback` pendente e notificações do WindowServer chegam depois do teardown lógico. Catalogado como **risco R01, probabilidade alta, impacto crítico**.

Hoje a mitigação é toda do lado do usuário: registry de tokens, token geracional, leak tests — infraestrutura que todo pacote FFI reinventa.

**Pedido.** Um modo de close seguro em que invocações posteriores retornam o `exceptionalReturn` em vez de causar comportamento indefinido:

```dart
callable.close(mode: NativeCallableCloseMode.safe);
```

### 7.3 D — cooperação do GC com o ciclo de frame

**Problema.** Um GC major no meio da composição de um frame estoura o orçamento de 16,6 ms. Não existe API pública suportada para informar ao runtime que há uma janela de tempo crítica em andamento, nem para aproveitar o tempo ocioso entre frames. Catalogado como **risco R12**.

A [`poc_12_native_buffers`](../../poc/poc_12_native_buffers) foi construída justamente para medir se o framebuffer deve viver no heap Dart ou em memória nativa — e a resposta tende a "nativa" em boa parte por ausência dessa cooperação, o que empurra o framework para fora do heap gerenciado e desfaz parte do valor de escrever em Dart.

**Pedido.** Hints não vinculantes, no espírito do que engines de jogo e navegadores expõem:

```dart
GcScheduling.beginLatencyCriticalSection();
GcScheduling.endLatencyCriticalSection();
GcScheduling.hintIdle(Duration budget); // "sobrou tempo, use se quiser"
```

Sem garantias fortes — apenas informação que o coletor hoje não tem.

### 7.4 E — diagnóstico de falha em FFI

**Problema.** Um ponteiro errado, uma vtable COM montada incorretamente ou uma struct com layout divergente derrubam o processo sem stack trace Dart útil. Depurar significa reconstruir manualmente qual chamada FFI estava ativa. Catalogado como **risco R13, probabilidade alta**.

**Pedido.** Em modo de debug, manter a última chamada FFI ativa por isolate e incluí-la no relatório de crash da VM; e um hook opcional para o embedder anotar o contexto.

---

## 8. Não objetivos

Esta proposta não pede:

- que o SDK conheça Win32, X11, Wayland ou AppKit;
- que o SDK escolha ou implemente um loop de plataforma;
- integração automática com GLib, `libuv` ou qualquer main context de terceiros;
- que `dart:io` mude de comportamento;
- garantias de tempo real;
- que todo embedder suporte a API — ela é opt-in, e Flutter tem seu próprio scheduler.

O SDK expõe o **mecanismo**. O pacote Dart continua dono da **política**.

---

## 9. Alternativas consideradas

### 9.1 Polling cooperativo (estado atual)

Funciona, é o que a POC-10 faz, e continuará funcionando. Mas a POC-19 mostra que não existe escolha de timeout que atenda ao mesmo tempo animação, latência e ociosidade: 50 ms derruba uma animação de 60 Hz para 16 Hz, 4 ms a recupera mas acorda 62 vezes por segundo com a aplicação parada, e não bloquear custa 116% de CPU. Não é uma base aceitável para um framework de UI de propósito geral.

### 9.2 Isolate dedicado ao pump

Um isolate que só bloqueia no loop nativo e conversa com o isolate de aplicação por portas. É a mitigação recomendada em [TECNICA_MAIN_THREAD_DART_FFI.md](../TECNICA_MAIN_THREAD_DART_FFI.md#L198) e é válida.

Limites: no Windows a janela pertence à thread que a criou, então **todo** acesso à janela precisa atravessar a fronteira de isolate; sem memória compartilhada (`#56841`), o estado da UI fica separado da lógica que o produz; e a latência de porta entra no caminho crítico do input. Resolve o congelamento, não o custo.

### 9.3 `Isolate.runEventLoopSync` como está

Roda até não existirem mais receive ports keep-alive. Um isolate de UI mantém
portas abertas durante toda a aplicação, portanto a chamada não devolve o
controle ao loop nativo a cada turno.

### 9.4 Embedder customizado

É a rota suportável hoje e resolve tudo — o embedder controla o loop. Mas obriga cada pacote a distribuir e manter um binário nativo por plataforma e arquitetura, o que anula a premissa de "pacote 100% Dart, instalável por `dart pub get`". O launcher standalone pode resolver isso uma vez para todos.

### 9.5 Expor o file descriptor do loop do Dart

Uma alternativa elegante em POSIX: dar ao Dart um FD que fica legível quando há
trabalho, e deixar o `poll` do usuário esperar nele. Falha no Windows, onde o
objeto correto é um `HANDLE` ou uma mensagem de thread. O callback já declarado
em `onEvent` é a forma portável do mesmo conceito; FD/HANDLE pode ser um atalho
posterior por plataforma.

---

## 10. Compatibilidade

- **Opt-in total.** A rota externa só existe para isolates criados/parados que
  recebem um callback `onEvent`; isolates normais continuam como hoje.
- **`isSupported`** análogo ao da proposta 01, para embedders que não implementem.
- **Zero impacto em CLI e servidores.** O caminho quente do message handler não muda; o que muda é a existência de um modo alternativo de escalonamento.
- **Flutter** pode declarar não suportado ou mapear para seu próprio scheduler.
- **JIT, snapshot AOT e executável AOT** devem se comportar igual.

---

## 11. Plano incremental

### Fase 1 — implementar o que já está declarado
- Concluir `Isolate.onEvent` e `Isolate.handleEvent` (hoje `UnsupportedError`).
- Testes de identidade de thread e de entrega.

### Fase 2 — timers e necessidade de deadline
- Confirmar que `onEvent` acorda o host quando um timer se torna pronto, mesmo
  sem mensagens ou I/O.
- Medir precisão e wakeups. Só propor `nextEventDeadline` se houver uma classe
  de loop externo que não possa ser acordada pelo callback.

### Fase 3 — contrato de reentrância
- Especificar e testar loop aninhado, diálogo modal, `SendMessage`, IME.

### Fase 4 — validação em plataforma real
- Exemplo Win32 completo (menor custo — não depende da proposta 01).
- Exemplo X11 e Wayland.
- Exemplo macOS, composto com `ProcessMainThread.runNative`.

### Fase 5 — lacunas secundárias
- Estabilizar `isolateGroupBound` (§7.1).
- `close(mode: safe)` (§7.2).
- Hints de GC (§7.3) e diagnóstico FFI (§7.4).

---

## 12. Critérios de aceitação

### Loop
- Um loop nativo bloqueia indefinidamente e é acordado por `onEvent`, sem timeout
  fixo no código de usuário.
- Zero wakeups quando não há input nativo nem trabalho Dart agendado.
- `Timer` de 16 ms mantém desvio comparável ao de um programa Dart normal.

### Input
- Latência de entrega de evento nativo com o loop ocioso limitada pelo wakeup, não pelo timeout.
- Ordenação de input nativo e microtask Dart documentada e testada.

### Dart
- `Timer`, `Future`, I/O assíncrono, `ReceivePort` e `Isolate.run` continuam funcionando sob loop externo.
- VM Service, profiler e hot reload continuam.
- GC continua sob carga.

### Reentrância
- Diálogo modal Win32 não corrompe o escalonador.
- `handleEvent` aninhado tem comportamento definido e testado.

### Plataformas
- Windows, Linux/X11, Linux/Wayland e macOS.
- x64 e arm64.
- JIT, snapshot AOT e executável AOT.

### Compatibilidade
- Zero mudança de comportamento quando a API não é usada.
- Benchmarks de CLI e servidor sem regressão.

---

## 13. Destino recomendado

### Opção A — nova issue de implementação

`onEvent` e `handleEvent` já estão na API pública experimental, mas a checklist
atual de `dart-lang/sdk#56841` não as menciona nominalmente. Uma issue própria
torna o pedido testável e evita misturá-lo à entrega inteira de memória
compartilhada.

```text
[vm][isolate] Implement Isolate.onEvent and Isolate.handleEvent for
external event-loop integration
```

### Opção B — comentário de escopo em `dart-lang/sdk#56841`

Útil para confirmar com os mantenedores se a implementação já faz parte do
trabalho oculto por flags citado em `#46943`, antes de abrir a issue própria.

Referenciar `#38315`, `#46943`, `#56841`, o working doc 333, a POC-19 e a
proposta 01 deste pacote. `#52106` está fechado e serve apenas como histórico.

As lacunas da §7 devem virar issues próprias, e não entrar nesta.

---

## 14. Referências

- https://github.com/dart-lang/sdk/issues/38315
- https://github.com/dart-lang/sdk/issues/46943
- https://github.com/dart-lang/sdk/issues/52106
- https://github.com/dart-lang/sdk/issues/56841
- https://github.com/dart-lang/language/blob/main/working/333%20-%20shared%20memory%20multithreading/shared_native_memory.md
- https://github.com/dart-lang/sdk/blob/main/sdk/lib/isolate/isolate.dart
- https://github.com/dart-lang/sdk/blob/main/sdk/lib/_internal/vm/lib/isolate_patch.dart
- https://api.dart.dev/dart-ffi/NativeCallable-class.html
- https://learn.microsoft.com/windows/win32/api/winuser/nf-winuser-msgwaitformultipleobjectsex
- https://learn.microsoft.com/windows/win32/winmsg/about-messages-and-message-queues
- https://xcb.freedesktop.org/manual/group__XCB__Core__API.html
- https://wayland.freedesktop.org/docs/html/apb.html
- https://developer.apple.com/documentation/corefoundation/cfrunloop

### Documentos deste repositório

- [01 — process main thread no macOS](01_proposta_dart_sdk_main_thread_ptbr.md)
- [SPIKE_MACOS_MAIN_THREAD.md](../SPIKE_MACOS_MAIN_THREAD.md)
- [TECNICA_MAIN_THREAD_DART_FFI.md](../TECNICA_MAIN_THREAD_DART_FFI.md)
- [ROTEIRO_FRAMEWORK_MULTIPLATAFORMA_100_PURO_DART.md](../ROTEIRO_FRAMEWORK_MULTIPLATAFORMA_100_PURO_DART.md) — riscos R01, R04, R12, R13
