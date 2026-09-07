# Proposta de evolução do Dart SDK
## Servir o laço de eventos do Dart de dentro de uma moldura nativa aninhada

**Data:** 7 de setembro de 2026
**Escopo:** Dart standalone em Windows e macOS; parcialmente Linux
**Caso de uso de referência:** framework de UI 100% Dart sobre `dart:ffi`, sem código C, C++, Objective-C ou Swift no projeto consumidor
**Evidência experimental:** `tool/nested_callback_probe.dart`, `tool/modal_offthread_probe.dart`, `tool/dart313_nested_drain_probe.dart`, `tool/sdk313/`, `test/backends/win32/win32_live_resize_test.dart`
**SDKs medidos:** 3.6.2 stable (o que este pacote declara) e 3.13.3 stable (o que tem a API)
**Propostas irmãs:** [`01`](01_proposta_dart_sdk_main_thread_ptbr.md) (qual thread), [`04`](04_proposta_dart_sdk_event_loop_nativo_ptbr.md) (duas filas na mesma thread)

---

## 1. Resumo executivo

As propostas 01 e 04 tratam de **quem é dono da thread** e de **como dois laços
de eventos se revezam nela**. Este documento trata do problema seguinte, que
sobrevive intacto às duas: **o que acontece quando o sistema operacional roda um
laço de mensagens dele, na nossa thread, e chama o nosso código de dentro dele.**

Nesse momento o Dart está executando — o callback é código Dart, na thread do
isolate — mas o laço de eventos do isolate está inalcançável, porque a pilha
abaixo do callback é uma moldura estrangeira que não vai retornar tão cedo.
Nenhum `Timer` dispara, nenhuma microtask roda, nenhum `Future` completa,
nenhuma mensagem de `ReceivePort` é entregue. Medido hoje, com o programa
mínimo em [`tool/nested_callback_probe.dart`](../../tool/nested_callback_probe.dart):

```
a Dart callback invoked from inside EnumWindows, blocking for 1500 ms
  callback reached      : true
  wall time in the call : 1519 ms
  ticks a live loop would see : about 30
  ticks that got through      : 0
```

Trinta esperados, **zero**. E o callback foi comprovadamente alcançado, então
não é uma chamada que nunca chegou ao Dart: é código Dart rodando com o laço de
eventos do próprio isolate desligado.

O pedido é uma primitiva que toda pilha de UI madura tem e o Dart não tem:
**servir a fila do isolate, de forma reentrante, na thread corrente, com
orçamento e com uma forma suportada de recusar a reentrância.** No WPF isso é
`Dispatcher.PushFrame` mais `Dispatcher.DisableProcessing`; no WinForms,
`Application.DoEvents`; no Qt, `QCoreApplication::processEvents`; no Cocoa,
`[NSRunLoop runMode:beforeDate:]`; no GLib, `g_main_context_iteration`. O Dart é
a exceção.

**E há uma segunda descoberta, medida em 3.13.3 stable no dia em que este
documento foi escrito, que muda o pedido.** As três APIs que a proposta 04 pediu
— `Isolate.create`, `Isolate.onEvent`, `Isolate.handleEvent` — **existem,
compilam e estão documentadas no 3.13.3**, e continuam **inalcançáveis a partir
de Dart**: as duas últimas lançam `UnsupportedError`, e a primeira lança
`StateError: Should be invoked outside of an isolate`. §5.2 traz a tabela
medida e a leitura do fonte da VM que explica cada recusa.

Isso reposiciona este documento. Ele deixa de ser só "acrescentem uma
primitiva" e passa a ser, na ordem: **(a)** tornar alcançável de Dart o que já
foi declarado e enviado, e **(b)** decidir o contrato de reentrância a favor do
caso aninhado, sem o qual nem (a) resolve o congelamento do arrasto.

Este documento **não pede** que o SDK conheça Win32, e **não** substitui a
proposta 04: as duas são ortogonais e a 04 continua sendo o pedido principal.

---

## 2. Delimitação: o que esta proposta **não** é

| Problema | Onde é tratado |
|---|---|
| Obter a primeira thread do processo (macOS/AppKit) | Proposta 01 |
| Fazer o laço do Dart e um laço nativo **que nós escrevemos** se revezarem | Proposta 04 |
| Compartilhar memória mutável entre isolates | `dart-lang/sdk#56841` |
| **Servir a fila do Dart de dentro de um laço nativo que o sistema começou e do qual não podemos sair** | **Este documento** |

A distinção entre a linha 2 e a linha 4 é a razão de este documento existir, e
vale enunciá-la sem rodeio.

A proposta 04 assume que **nós** somos donos do laço externo: o código Dart
chama `MsgWaitForMultipleObjectsEx`, ele retorna, drenamos as mensagens,
chamamos `Isolate.handleEvent`, repetimos. Com `onEvent`/`handleEvent`
implementados, esse caso fica resolvido, e resolvido bem.

Aqui o laço externo **não é nosso**. Quando o usuário segura a barra de título,
o Windows entra num laço de mensagens dele entre `WM_ENTERSIZEMOVE` e
`WM_EXITSIZEMOVE`, e a chamada a `DispatchMessageW` que fizemos não retorna até
o botão do mouse ser solto. Não existe ponto no nosso código onde inserir um
`handleEvent`, porque não voltamos ao nosso código: é o laço do sistema que
chama a nossa `WndProc`, e ele a chama **por dentro**.

A proposta 04 chega perto disso em §6.5, ao pedir que o contrato de reentrância
seja explícito, e sugere que `handleEvent` chamado durante outro `handleEvent`
"rejeite a reentrada de modo definido ou a enfileire". **Para este caso, rejeitar
é exatamente a resposta errada**, e é por isso que este documento é separado e
não uma emenda àquele parágrafo.

---

## 3. O problema

### 3.1 A forma

Três molduras na mesma thread, de baixo para cima:

```
  D1  código Dart (o nosso laço de mensagens)
   └─ N1  chamada FFI (DispatchMessageW) ─── não retorna por segundos
       └─ D2  callback Dart (a WndProc), chamado pelo laço modal do sistema
```

`D2` roda. Pode ler estado, pode pintar, pode chamar FFI. O que não pode é
**ceder ao escalonador do Dart**, porque o escalonador do Dart só roda quando
`D1` retorna ao message handler do isolate, e `D1` está bloqueado em `N1`.

Consequências, todas observadas neste projeto:

- `await` dentro de `D2` é ilegal na prática. A função tem de devolver um
  `int` para o sistema; torná-la `async` devolve um `Future` que o chamador
  nativo não sabe usar, e tudo depois do primeiro ponto de suspensão vira
  **código morto pela duração do arrasto**;
- `scheduleMicrotask` e `Timer.run` enfileiram e nada drena;
- `sleep` de `dart:io` bloqueia igual à chamada nativa.

Não há quarta opção. **Essa ausência é a proposta.**

### 3.2 A forma não é exótica

`EnumWindows`, `EnumFontFamiliesEx`, `SetWindowsHookEx`, um *event sink* COM,
`qsort`, um comparador passado a uma biblioteca C, e — o caso que motivou este
documento — a `WndProc` durante o laço modal do sistema. Todos têm a mesma
forma: Dart chamado de volta com uma moldura estrangeira embaixo.

O que muda entre eles é só quanto tempo a moldura de baixo dura. Um comparador
de `qsort` dura microssegundos e ninguém repara. Um arrasto de janela dura o
tempo que o usuário quiser.

### 3.3 Os dois casos deste projeto, e por que só um tem contorno

**Caso 1 — o diálogo de arquivo.** `IFileDialog::Show` roda um laço modal
próprio. Enquanto ele está aberto, todo o lado Dart congela: o vídeo para de
renderizar e o áudio continua, porque o áudio está num thread do sistema que
não sabe nada do Dart. **Tem contorno**, porque `IFileDialog::Show` aceita
rodar em outra thread desde que se lhe passe a `HWND` dona; a chamada foi para
`Isolate.run` e o laço de eventos principal ficou livre. Custa um *spawn* de
isolate por diálogo, e obriga a desabilitar a janela dona manualmente para
recuperar a modalidade que o sistema teria dado de graça.

**Caso 2 — arrastar ou redimensionar a própria janela.** **Não tem contorno.**
O laço modal é da *nossa* janela, na *nossa* thread, e no Windows uma janela
pertence à thread que a criou: não existe outra thread para onde mover isso.
Mandar o laço inteiro para um isolate dedicado só muda qual thread fica presa.

Essa assimetria é o argumento central deste documento. O caso 1 mostra que a
falta dói; o caso 2 mostra que **nenhuma quantidade de engenharia do lado do
pacote a remove.**

### 3.4 Onde dói, por plataforma

Ao contrário da proposta 04, que atinge as três plataformas por igual, esta é
assimétrica:

| Plataforma | Severidade |
|---|---|
| **Windows** | Grave. `WM_ENTERSIZEMOVE`/`WM_EXITSIZEMOVE`, menus nativos, `SendMessage` entre threads, `IFileDialog`, drag-and-drop OLE, IME. |
| **macOS** | Presente. Sessões modais do `NSApplication` e o laço de rastreamento do mouse durante um arrasto de janela têm a mesma forma. **Não medido:** este projeto não tem um Mac, e a disciplina do repositório é não afirmar o que não rodou. |
| **X11 / Wayland** | Em grande parte ausente **para o arrasto**: o gerenciador de janelas move a janela e o cliente não fica bloqueado. Continua valendo para qualquer callback FFI de longa duração. |

---

## 4. Evidência experimental

### 4.1 A moldura aninhada, isolada de qualquer UI

[`tool/nested_callback_probe.dart`](../../tool/nested_callback_probe.dart), 150
linhas, sem janela e sem framework. Arma um `Timer.periodic` de 50 ms, chama
`EnumWindows` com um callback Dart que bloqueia 1500 ms, e conta os tiques.

```
  callback reached      : true
  wall time in the call : 1519 ms
  ticks a live loop would see : about 30
  ticks that got through      : 0
  ticks observed from *inside* the callback : 2 (a contagem na entrada;
                                                nada foi somado enquanto ele rodou)
PROBE=PASS the event loop is unreachable under a native frame
```

As três guardas do probe importam: ele falha como `INCONCLUSIVE` se o callback
não for alcançado (seria "a chamada nunca chegou ao Dart", outro defeito) ou se
a chamada retornar antes do bloqueio terminar, e reporta `CHANGED` se algum dia
os tiques passarem — de modo que ele continua sendo um teste útil depois de a
API existir.

### 4.2 O contorno do caso 1, medido

[`tool/modal_offthread_probe.dart`](../../tool/modal_offthread_probe.dart), com
`Sleep` de `kernel32` no lugar do diálogo (um humano não pode ser automatizado):

```
blocking FFI call of 1500 ms, 50 ms periodic timer, so a live event loop should see about 30 ticks
  on the main isolate : 0 ticks
  through Isolate.run : 30 ticks
```

O contorno funciona, e funciona perfeitamente. É por isso que ele está em
produção neste repositório. E é por isso que a sua **inaplicabilidade ao caso 2**
é a evidência mais forte aqui.

### 4.3 O que sobrou de fora depois de esgotar o lado do pacote

O caso 2 foi atacado com tudo o que existe hoje, e o resultado está fixado em
[`test/backends/win32/win32_live_resize_test.dart`](../../test/backends/win32/win32_live_resize_test.dart),
que dirige a `WndProc` real de uma `HWND` real **sem uma volta do laço de
eventos em lugar nenhum da sequência** — que é a forma obrigatória, porque num
arrasto de verdade não existe essa volta.

**Primeira camada: `SetTimer`.** `WM_TIMER` é a única mensagem que se consegue
fazer o sistema entregar a si mesmo de dentro de um laço modal que não foi ele
quem começou. Armado em `WM_ENTERSIZEMOVE`, morto em `WM_EXITSIZEMOVE`, e cada
tique produz um quadro síncrono. Com o `SetTimer` removido, o arrasto parado cai
de 4 quadros para 0 e o arrasto pela barra de título de 1 para 0.

**Segunda camada, e é a que interessa a esta proposta: o temporizador devolve o
desenho, não o relógio.** O relógio do escalonador de quadros deste framework é
virtual e só anda quando um `Timer` **real** do Dart dispara para adiantá-lo.
Dentro do laço modal nenhum `Timer` real dispara, então cada quadro que o
temporizador pede redesenha *o mesmo instante*: a janela repinta ocupadíssima e
a animação fica exatamente onde estava. Foi preciso escrever um caminho paralelo
(`ApplicationWindow._advanceModalAnimation`) que mede o tempo real com um
`Stopwatch` e adianta o tempo virtual à mão. Sem ele, o tempo virtual avança
`0:00:00.000000` no arrasto inteiro.

**O que continua quebrado depois das duas camadas:** o vídeo. A decodificação é
`await`, e nenhum `await` roda ali dentro. A imagem congela e o áudio continua —
que é exatamente o sintoma que o usuário relatou, e a comparação que ele deu
fecha o diagnóstico: **no VLC dá para mover e redimensionar a janela sem o vídeo
parar**, porque o VLC tem decodificação e saída de vídeo em threads próprias.

Esse resíduo — animação recuperada à mão, `await` ainda morto — é precisamente o
que só o SDK pode remover.

### 4.4 Por que "mover tudo para outro isolate" não é a resposta

Este projeto mediu as duas metades dessa ideia, e as duas passam:

- **os dados atravessam barato.** Entrega de quadro de vídeo por memória nativa
  compartilhada custa **+0,095 ms (1,10×)** contra o caminho local; por cópia em
  porta, 3,47×; por `TransferableTypedData`, 4,82×;
- **o decodificador roda mesmo numa isolate.** Media Foundation com
  `COINIT_MULTITHREADED` não tem afinidade de apartamento: 400 quadros,
  6,74 ms/quadro, 148,3 fps, zero fora de ordem.

E mesmo assim isso não resolve o caso 2, porque o problema **não é onde o
trabalho roda; é qual thread fica presa**. A janela pertence à thread que a
criou, e é essa que o sistema sequestra.

---

## 5. O que o SDK oferece hoje

### 5.1 O quadro geral

| API | Situação |
|---|---|
| `Isolate.run` | Existe e funciona. Resolve o caso 1; inaplicável ao caso 2. Custa um isolate por chamada. |
| `NativeCallable.isolateLocal` | Existe e é o que torna o callback aninhado possível. Não diz nada sobre o que é legal fazer lá dentro. |
| A família `@Since("3.13")` | Existe no 3.13.3 stable e não é chamável de Dart. Ver §5.2. |

### 5.2 O que a API de 3.13 faz de verdade — medido, não deduzido

A proposta 04 auditou o `dart-lang/sdk` em 7/8/2026 e encontrou
`onEvent`/`handleEvent` declaradas e lançando `UnsupportedError`. Um ano depois,
com o **3.13.3 stable instalado nesta máquina**, o estado é o mesmo — e o
detalhe novo é *por que*.

`tool/sdk313/api_surface_probe.dart` chama cada membro a partir de um `main`
comum e imprime o que voltou:

```
SDK reported by the running VM: 3.13.3 (stable) (Tue Sep 1 01:07:17 2026 -0700) on "windows_x64"
called from an ordinary main(), which always runs inside an isolate:
  Isolate.pinToCurrentThread()            : OK (returned true)
  Isolate.current.isPinnedToCurrentThread : OK
  Isolate.create(...)                     : StateError: Should be invoked outside of an isolate
  Isolate.current.runSync(noop)           : OK
  Isolate.current.onEvent = ...           : UnsupportedError: Unsupported operation: Isolate.onEvent
  Isolate.current.handleEvent()           : UnsupportedError: Unsupported operation: Isolate.handleEvent
  Isolate.current.runEventLoopSync()      : não chamado de propósito (não retornaria)
```

Lido com cuidado, isso diz três coisas:

1. **`pinToCurrentThread` e `runSync` funcionam.** As partes de *controle de
   thread* estão vivas — o que é a proposta 01, não esta.
2. **`onEvent` e `handleEvent` são declaradas e não implementadas** para o
   isolate corrente. Exatamente o que a proposta 04 pede, ainda pendente.
3. **`Isolate.create` recusa por ser chamada de dentro de um isolate.**

### 5.3 O que o fonte da VM diz, e o que ele não diz

Com o fonte de `dart-sdk` main em mãos, as duas recusas têm causas de naturezas
bem diferentes, e a distinção muda o pedido.

**`onEvent` e `handleEvent` não estão implementadas.** Não é uma recusa
condicional, não é "não suportado nesta configuração": em
`sdk/lib/_internal/vm/lib/isolate_patch.dart` as duas são literalmente

```dart
void set onEvent(void Function(Isolate) callback) {
  throw UnsupportedError("Isolate.onEvent");
}

void handleEvent() {
  throw UnsupportedError("Isolate.handleEvent");
}
```

Ou seja, o que a proposta 04 pediu em agosto de 2026 continua **inteiramente em
aberto**, e a medição em 3.13.3 stable bate com o `main`. Isto é o bloqueio
decisivo, e nenhum arranjo de threads o contorna.

**`Isolate.create` é implementada, e a guarda é sobre o estado da thread.** Em
`runtime/lib/isolate.cc`, `Isolate_create_` — e também `shutdownSync_` e
`runEventLoopSync_` — começam com

```cpp
if (thread->isolate() != nullptr) {
  ... "Should be invoked outside of an isolate" ...
}
```

e depois trabalham sobre `thread->isolate_group()`. Ou seja, o que se exige é
uma thread **dentro do grupo e fora de qualquer isolate**. Num `main` isso nunca
vale, e por isso a chamada sempre recusa lá.

**E existe um estado alcançável de Dart que satisfaz essa guarda**, o que
enfraquece a leitura fácil de "é só para embedder em C": um callback
[`NativeCallable.isolateGroupBound`](../../tool/sdk313/group_bound_create_probe.dart)
roda, por definição, dentro do grupo e fora de um isolate — é a própria
documentação de `onEvent` que aponta para ele. `tool/sdk313/group_bound_create_probe.dart`
tenta exatamente isso, criando uma thread do sistema com `CreateThread` e
chamando `Isolate.create` de dentro dela.

**Esse teste travou** — nenhuma saída, processo vivo depois de dois minutos,
teve de ser morto — e por isso **não é evidência em nenhuma direção**. A
hipótese, que é hipótese e não medida, é que o callback ligado ao grupo precise
entrar no grupo como mutator enquanto a thread principal o segura bloqueada num
`WaitForSingleObject`, e cada uma espere a outra. Se for isso, é um defeito
próprio e vale relato separado.

O que fica dito com segurança, então, é mais estreito e mais útil do que
"embedder-only": **`Isolate.create` recusa em toda chamada que um programa Dart
comum consegue fazer**, e a única brecha teórica é uma que não foi possível
demonstrar funcionando. E, sobretudo, **ela não importa enquanto `handleEvent`
for um stub**, porque criar um isolate que não se pode drenar não resolve nada.

A proposta 04 pedia que `onEvent`/`handleEvent` fossem implementadas; este
documento acrescenta que, se `Isolate.create` continuar exigindo uma thread
sem isolate corrente, é preciso dizer **explicitamente** por qual caminho um
pacote 100% Dart chega a essa thread — e que esse caminho seja testado.

### 5.4 Um defeito encontrado de passagem: `pinToCurrentThread` derruba a VM na saída

Reproduzível, e atribuído com a variável isolada — `--no-pin` no mesmo probe não
derruba nada:

```
../../runtime/vm/dart_api_impl.cc: 1508: error: Isolate main is owned by
os thread 0x3d9c, failed to schedule from os thread 0x34e8
```

Um programa comum que chama uma API pública documentada e aborta ao sair é, no
mínimo, uma lacuna de documentação: se há uma pré-condição — desafixar antes de
sair, ou não usar em `main` — ela não está escrita. Merece issue própria,
separada desta proposta, e interessa diretamente à proposta 01.

### 5.5 A conclusão de §5

Mesmo com a proposta 04 **inteiramente implementada**, o caso 2 continua
quebrado, a menos que `handleEvent` seja explicitamente reentrante. É esse "a
menos que" que este documento pede que seja decidido a favor — e §5.2 mostra que
há um segundo bloqueio antes dele.

---

### 5.6 Dá para usar a API nova mantendo `sdk: ^3.6.0`?

Pergunta prática, porque um pacote de UI não quer excluir todo mundo que ainda
está em 3.6 só para experimentar. A resposta, medida:

**Hoje, não — e a razão é anterior à compatibilidade.** Não há o que usar:
§5.2 e §5.3 mostram que os membros necessários lançam também no 3.13.3, e que
`handleEvent` sequer tem implementação no `main` do SDK.

**No dia em que houver, parcialmente.** Vale registrar o mecanismo, porque ele
foi verificado e delimita o que será possível:

- **membros de instância** são alcançáveis por `dynamic`, que adia a resolução
  para a execução. `tool/dart313_nested_drain_probe.dart` faz
  `(Isolate.current as dynamic).handleEvent()` e **analisa limpo sob `^3.6.0`**,
  rodando nos dois SDKs e reportando `NoSuchMethodError` em 3.6.2 contra
  `UnsupportedError` em 3.13.3 — isto é, o mesmo binário se adapta;
- **membros estáticos não têm essa saída.** `Isolate.create` e
  `Isolate.pinToCurrentThread` são estáticos, e não existe despacho dinâmico
  para um membro estático de classe. Nem importação condicional resolve: ela
  chaveia por `dart.library.*`, e `dart:isolate` existe nas duas versões;
- e a arquitetura da §5.2 **precisa** de `Isolate.create`, que é estática.

Ou seja, o `dynamic` compra a metade errada. A conclusão honesta é que a adoção
vai custar subir o mínimo do pacote, e que o custo disso é um argumento a mais
para que a API seja alcançável de Dart cedo — não um problema que o pacote possa
contornar sozinho.

Enquanto isso, os dois probes ficam no repositório como **detectores de
regressão ao contrário**: `nested_callback_probe` imprime `PROBE=CHANGED` se o
laço de eventos algum dia rodar sob moldura estrangeira, e
`dart313_nested_drain_probe` imprime `PROBE=WORKS` se `handleEvent` passar a
funcionar. Nenhum dos dois precisa ser reescrito para dar a notícia.

---

## 6. Proposta A — servir a fila de forma reentrante

### 6.1 Superfície mínima

```dart
// dart:isolate

/// Que classes de trabalho um serviço reentrante da fila pode executar.
enum EventLoopScope {
  /// Só timers já vencidos e as microtasks que eles criarem.
  ///
  /// O mínimo que faz uma animação continuar andando, e o único nível em que
  /// nenhuma entrega vinda de fora do isolate pode acontecer.
  timersAndMicrotasks,

  /// Tudo: o acima, mais mensagens de `ReceivePort` e conclusões de I/O.
  all,
}

abstract final class Isolate {
  /// Executa até [maxEvents] itens da fila deste isolate, nesta thread,
  /// **mesmo havendo molduras Dart e estrangeiras na pilha**.
  ///
  /// Retorna quantos itens foram executados. Retorna 0 imediatamente se não
  /// houver nada pronto — nunca bloqueia esperando trabalho aparecer.
  static int drainEventLoop({
    int maxEvents = 1,
    Duration? budget,
    EventLoopScope scope = EventLoopScope.timersAndMicrotasks,
  });

  /// Quantos [drainEventLoop] estão na pilha. 0 num turno comum.
  static int get eventLoopDepth;

  /// Recusa serviços reentrantes enquanto o token estiver vivo.
  ///
  /// [drainEventLoop] chamado sob um destes retorna 0 sem executar nada.
  static EventLoopLock lockEventLoop();

  /// Se o embedder implementa o mecanismo.
  static bool get isEventLoopDrainSupported;
}

abstract interface class EventLoopLock {
  void release();
}
```

### 6.2 Semântica

- **não bloqueia.** `drainEventLoop` serve o que já está pronto e volta. Esperar
  é trabalho do laço nativo, que é quem sabe esperar por input;
- **`budget` e `maxEvents` limitam juntos**, e a chamada para no primeiro dos
  dois. Um quadro de 60 Hz pede `budget: Duration(milliseconds: 4)`; um `while`
  de um laço externo pede `maxEvents: 1`, que é a forma da proposta 04;
- **o escopo padrão é o estreito.** `timersAndMicrotasks` é o padrão porque é o
  que não pode surpreender: nada que venha de fora do isolate entra, então
  nenhuma mensagem de outro isolate é entregue no meio de uma `WndProc`. Quem
  quer o resto pede `all` explicitamente e assume o que isso significa;
- **exceções não capturadas** de um item servido vão para o mesmo lugar que
  iriam num turno comum, e **não** propagam para o chamador de
  `drainEventLoop` — que é código nativo e não sabe o que fazer com elas;
- **`isEventLoopDrainSupported`** permite ao pacote escolher o caminho degradado
  em vez de morrer, como a proposta 01 já faz com o seu próprio `isSupported`.

### 6.3 O contrato de reentrância é o coração da proposta

Servir a fila com molduras na pilha é perigoso, e a proposta seria desonesta se
não dissesse isso na cara. Um `Future` que completa dentro da `WndProc` pode
executar uma continuação que chama `DestroyWindow` na própria janela cujo
manipulador está na pilha, e o retorno vai para uma janela que não existe mais.

A resposta **não** é proibir. Toda pilha de UI madura encara exatamente este
risco e envia a primitiva assim mesmo, porque a alternativa é uma aplicação
congelada. O WPF é o precedente mais próximo e está aqui neste repositório de
referências, então dá para citar linha:

- `Dispatcher.PushFrame(DispatcherFrame)`
  (`WindowsBase/System/Windows/Threading/Dispatcher.cs:297`) empurra uma
  moldura de execução aninhada — é literalmente o que o WPF faz para rodar um
  diálogo modal;
- `DispatcherFrame.Continue`
  (`.../DispatcherFrame.cs:47`) é a condição de saída, e o comentário do
  construtor separa as molduras em duas categorias, recomendando **timeout**
  para as de critério próprio — a mesma ideia do `budget` acima;
- `Dispatcher.DisableProcessing()` (`Dispatcher.cs:1409`) incrementa
  `_disableProcessingCount`, e `PushFrame` **lança** quando esse contador é
  maior que zero. Ou seja: o WPF envia a reentrância *e* a forma suportada de
  recusá-la, e as duas na mesma classe.

`lockEventLoop` é o `DisableProcessing`; `eventLoopDepth` é o `_frameDepth`. Não
há invenção nenhuma aqui — há um desenho de trinta anos que funciona, portado
para a superfície do Dart.

Sem `lockEventLoop` a API seria uma armadilha, porque um framework tem seções
críticas — o meio de uma passada de layout, uma árvore semiconstruída — em que
um serviço reentrante é catastrófico. **Enviar as duas juntas, ou nenhuma.**

### 6.4 Uso no caso 2, que hoje não tem solução

```dart
int wndProc(int hwnd, int msg, int wParam, int lParam) {
  switch (msg) {
    case wmTimer:
      if (wParam == _sizeMoveTimerId) {
        // O que hoje precisa de um Stopwatch e de um caminho paralelo para
        // adiantar o relógio à mão: os timers do próprio framework vencem e
        // disparam, e a animação anda porque andou de verdade.
        Isolate.drainEventLoop(
          budget: const Duration(milliseconds: 4),
          scope: EventLoopScope.all, // inclusive o decodificador de vídeo
        );
        _drawFrameSynchronously();
        return 0;
      }
  }
  // ...
}
```

E, do outro lado, a seção crítica:

```dart
void flushLayout() {
  final EventLoopLock lock = Isolate.lockEventLoop();
  try {
    // Uma árvore semiconstruída não pode ser observada por nada.
    _layout();
  } finally {
    lock.release();
  }
}
```

Com `scope: all`, o vídeo volta a decodificar durante o arrasto — que é o
comportamento que o usuário já tem no VLC e não tem aqui.

### 6.5 Uso nas outras plataformas

- **macOS** — dentro de uma sessão modal do `NSApplication` ou do laço de
  rastreamento de um arrasto, a mesma chamada, a partir do callback que o
  AppKit invoca. Combina com a proposta 01, que é quem entrega a thread;
- **X11/Wayland** — pouco necessário para o arrasto, útil para qualquer callback
  FFI longo;
- **laço externo escrito por nós** — `drainEventLoop(maxEvents: 1)` é
  exatamente `handleEvent` da proposta 04. Se as duas propostas forem aceitas,
  vale unificá-las numa só chamada com um parâmetro a mais, em vez de duas APIs
  que fazem quase a mesma coisa.

---

## 7. Proposta B — a variante mínima, se A for grande demais

Se `scope: all` for considerado arriscado ou caro demais para uma primeira
versão, existe um subconjunto estritamente menor que já apagaria a maior parte
da dor:

```dart
/// Dispara os timers já vencidos e drena as microtasks que eles criarem.
/// Nada mais: nenhuma entrega de porta, nenhuma conclusão de I/O.
static int runDueTimers({Duration? budget});
```

É a `EventLoopScope.timersAndMicrotasks` sozinha. Não entrega nada vindo de
fora do isolate, então a superfície de surpresa é muito menor, e ainda assim:

- a animação anda sozinha, e `_advanceModalAnimation` deixa de existir;
- o relógio virtual do escalonador para de precisar de um `Stopwatch` paralelo;
- o vídeo **continua parado**, porque a decodificação é `await` sobre I/O.

Vale como Fase 1. Não vale como resposta final, e este documento não gostaria de
ser lido como se valesse.

---

## 8. Proposta C — saber que se está aninhado

Independente de A e B, e barata:

```dart
static int get eventLoopDepth;      // já em §6.1
static bool get isUnderNativeFrame; // molduras FFI abaixo da atual
```

Hoje a regra "nunca use `await` num callback chamado de código nativo" é
folclore que cada projeto reaprende pagando. Este repositório a escreve em
prosa, em três lugares, porque não há como afirmá-la em código. Com um desses
getters ela vira um `assert`, e um erro de programação que hoje se manifesta
como "a animação some durante o arrasto" passa a se manifestar onde foi
cometido.

---

## 9. Não objetivos

- que o SDK conheça Win32, AppKit, X11 ou Wayland;
- que o SDK decida **quando** é seguro servir a fila — isso é política, e a
  política é do pacote, exatamente como a proposta 04 estabelece em §8;
- reentrância automática ou implícita em qualquer lugar: nada muda para quem não
  chamar as novas funções;
- garantias de tempo real;
- que `dart:io` mude de comportamento;
- que todo embedder implemente — daí `isEventLoopDrainSupported`. O Flutter tem
  o próprio escalonador e pode declarar não suportado.

---

## 10. Alternativas consideradas

**10.1 `Isolate.run` por chamada bloqueante.** É o contorno do caso 1, está em
produção aqui e vai continuar. Não alcança o caso 2, e custa um isolate por
chamada.

**10.2 Todo o laço de janelas num isolate dedicado.** Muda qual thread fica
presa, não o fato de ficar. E no Windows a janela pertence à thread que a criou,
então todo acesso passa a atravessar fronteira de isolate — o limite que a
proposta 04 já registra em §9.2. As medições de §4.4 mostram que o *dado*
atravessa barato; o problema nunca foi o dado.

**10.3 `SetTimer` e um quadro síncrono, que é o que este projeto faz hoje.**
Funciona para desenhar, e está bem testado. Não devolve o relógio nem os
`await`, como §4.3 mede. É mitigação, não solução, e ela própria só existe
porque o Windows tem `WM_TIMER`; em outra plataforma sem uma mensagem
equivalente não haveria sequer isso.

**10.4 Recusar a reentrância e enfileirar, como a proposta 04 §6.5 admite.**
Correto e seguro para o caso da 04. Deixa o caso 2 exatamente como está hoje.

**10.5 Embedder customizado.** Resolve tudo e é a rota suportável hoje. Anula a
premissa de "pacote 100% Dart, instalável por `dart pub get`", pelas razões que
a proposta 04 §9.4 já detalha.

---

## 11. Perguntas em aberto para o time da VM

Este documento seria leviano se apresentasse a implementação como trivial. As
dificuldades que um implementador vai encontrar, na medida em que um consumidor
do SDK consegue enxergá-las de fora:

1. **reentrar no message handler** com uma moldura Dart ativa — estado de
   `Thread`, escopos de safepoint, e o que acontece se um GC for necessário no
   meio;
2. **profundidade máxima.** Um `drainEventLoop` que serve um evento que chama
   FFI que chama de volta que serve de novo é recursão sem fundo. Um limite,
   ou pelo menos um erro diagnosticável em vez de estouro de pilha;
3. **desligamento do isolate** enquanto há drenagens aninhadas na pilha;
4. **zonas.** Em que zona roda um item servido de dentro da moldura estrangeira:
   na sua própria, presume-se, mas a especificação precisa dizer;
5. **`Isolate.exit` e portas de erro** durante uma drenagem aninhada;
6. se `EventLoopScope.timersAndMicrotasks` é **implementável separadamente** ou
   se a fila do isolate não distingue as classes barato o bastante — do que
   depende a proposta B ser mesmo mais barata que a A.

Nenhuma delas é nova para quem já implementou `PushFrame` ou `processEvents`.
Todas precisam de resposta antes de a API ser especificada.

---

## 12. Compatibilidade

- **Opt-in total.** Nada muda para quem não chamar as funções novas;
- **zero impacto em CLI e servidores.** O caminho quente do message handler não
  muda; o que passa a existir é um modo alternativo de entrada nele;
- **JIT, snapshot AOT e executável AOT** devem se comportar igual;
- **`isEventLoopDrainSupported`** dá a embedders — Flutter incluído — a saída de
  declarar não suportado sem quebrar quem consulta antes de usar.

---

## 13. Plano incremental

**Fase 1 — `runDueTimers` (proposta B).** O subconjunto mais estreito, com
`budget`. Já apaga `_advanceModalAnimation` deste repositório.

**Fase 2 — `eventLoopDepth` e `lockEventLoop`.** Sem custo de escalonamento e
transformam folclore em `assert`. Podem vir antes da Fase 1 se for mais fácil.

**Fase 3 — `drainEventLoop` com `EventLoopScope.all`.** O pedido cheio, com o
contrato de reentrância de §6.3 escrito na especificação, não só no código.

**Fase 4 — unificação com a proposta 04.** Se `onEvent`/`handleEvent` forem
implementados, `handleEvent()` deve ser `drainEventLoop(maxEvents: 1)` e não uma
segunda API paralela.

**Fase 5 — validação em plataforma real.** Windows e macOS, com janela de
verdade e arrasto de verdade. Um teste headless não pega isto: a moldura
aninhada é a coisa sob teste.

---

## 14. Critérios de aceitação

**O probe mínimo.** `tool/nested_callback_probe.dart`, alterado para chamar
`drainEventLoop` de dentro do callback, deve reportar próximo de 30 tiques em
vez de 0. Ele já imprime `PROBE=CHANGED` nesse caso, de propósito.

**Timers.** Um `Timer` vencido durante uma moldura estrangeira dispara na
primeira drenagem, com o `Duration` que já vencia — sem avançar o relógio
artificialmente e sem disparar duas vezes ao voltar do laço.

**Microtasks.** Uma microtask criada por um item servido roda dentro da mesma
drenagem, antes de ela retornar.

**Escopo.** Com `timersAndMicrotasks`, nenhuma mensagem de `ReceivePort` é
entregue. Verificável mandando uma de outro isolate durante o bloqueio.

**Recusa.** Sob `lockEventLoop`, `drainEventLoop` retorna 0 e nada roda. Aninhar
dois locks exige duas liberações.

**Orçamento.** Com `budget` de 4 ms e uma fila de 10 000 microtasks triviais, a
chamada retorna perto de 4 ms e informa quantas rodaram.

**Reentrância.** `eventLoopDepth` é 1 dentro de uma drenagem e 2 dentro de uma
aninhada; volta a 0 mesmo quando um item servido lança.

**Alcançável de Dart.** `tool/sdk313/api_surface_probe.dart` deixa de imprimir
`UnsupportedError` e `StateError` — critério que hoje falha em 3.13.3 stable e
que é anterior a todos os outros.

**Sem regressão.** Um programa que nunca chama nada disto tem exatamente o
desempenho de escalonamento de antes, medido.

---

## 15. Destino recomendado

Uma issue nova em `dart-lang/sdk`, **separada** da issue da proposta 04, com o
título na linha de:

> [vm][isolate] Allow the isolate event loop to be serviced re-entrantly from a
> native frame (nested modal loops)

E um comentário de referência cruzada na issue da 04 dizendo que
`Isolate.handleEvent` sozinho não cobre o laço modal aninhado, com o link para
esta. As duas juntas descrevem o problema inteiro; separadas, cada uma é
implementável sem a outra.

Mais duas, menores e independentes, que saíram da medição de §5:

- **`Isolate.create` recusa toda chamada que um programa Dart comum consegue
  fazer**, e o único estado que satisfaz a guarda da VM — um callback
  `NativeCallable.isolateGroupBound` — não foi possível demonstrar funcionando
  (§5.3). Vale como comentário na issue da proposta 04, por ser o mesmo assunto,
  pedindo que o caminho suportado seja nomeado e testado;
- **`Isolate.pinToCurrentThread` derruba a VM na saída** de um programa comum
  (§5.4). Issue própria, e relevante à proposta 01.

---

## 16. Referências

**Do fonte do SDK**

- `sdk/lib/_internal/vm/lib/isolate_patch.dart` — `onEvent` e `handleEvent` como
  `throw UnsupportedError` incondicionais;
- `runtime/lib/isolate.cc` — a guarda `thread->isolate() != nullptr` em
  `Isolate_create_`, `Isolate_shutdownSync_` e `Isolate_runEventLoopSync_`;
- `sdk/lib/ffi/ffi.dart` — `NativeCallable.isolateGroupBound`, marcada como
  experimental, e a regra de que o callback não pode tocar estático não
  compartilhado pelo grupo.

**Deste repositório**

- [`tool/nested_callback_probe.dart`](../../tool/nested_callback_probe.dart) — o
  programa mínimo, sem UI, que mede 0 de 30 tiques;
- [`tool/modal_offthread_probe.dart`](../../tool/modal_offthread_probe.dart) — o
  contorno do caso 1, 0 contra 30;
- [`tool/dart313_nested_drain_probe.dart`](../../tool/dart313_nested_drain_probe.dart)
  — `handleEvent` por `dynamic`, compilando sob `^3.6.0` e rodando nos dois SDKs;
- [`tool/sdk313/api_surface_probe.dart`](../../tool/sdk313/api_surface_probe.dart),
  [`tool/sdk313/created_isolate_drain_probe.dart`](../../tool/sdk313/created_isolate_drain_probe.dart)
  e [`tool/sdk313/group_bound_create_probe.dart`](../../tool/sdk313/group_bound_create_probe.dart)
  — a superfície de 3.13 medida membro a membro; excluídos do analisador porque
  nomeiam o que não existe em 3.6. O terceiro trava e está documentado como
  inconclusivo;
- [`test/backends/win32/win32_live_resize_test.dart`](../../test/backends/win32/win32_live_resize_test.dart)
  — a `WndProc` real sem uma volta do laço de eventos;
- [`doc/ROTEIRO_FRAMEWORK_MULTIPLATAFORMA_100_PURO_DART.md`](../ROTEIRO_FRAMEWORK_MULTIPLATAFORMA_100_PURO_DART.md)
  §68.4.4 — o relato do usuário, o diagnóstico e as duas camadas da mitigação;
- propostas [`01`](01_proposta_dart_sdk_main_thread_ptbr.md) e
  [`04`](04_proposta_dart_sdk_event_loop_nativo_ptbr.md).

**Precedente em outras pilhas**

- WPF — `Dispatcher.PushFrame`, `DispatcherFrame.Continue`,
  `Dispatcher.ExitAllFrames`, `Dispatcher.DisableProcessing`. Lidos no fonte
  (`dotnet/wpf`, `src/Microsoft.DotNet.Wpf/src/WindowsBase/System/Windows/Threading/`);
- WinForms — `Application.DoEvents`;
- Qt — `QCoreApplication::processEvents`, com sinalizadores de exclusão por
  classe de evento, e `QEventLoop::exec` aninhado;
- Cocoa — `[NSRunLoop runMode:beforeDate:]`, `NSApplication` modal sessions;
- GLib — `g_main_context_iteration`;
- libuv — `uv_run(loop, UV_RUN_NOWAIT)`.

As três últimas linhas são citadas de conhecimento das APIs e **não** foram
lidas no fonte para este documento, ao contrário das do WPF.
