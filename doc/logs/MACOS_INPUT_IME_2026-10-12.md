# macOS: input, clipboard and IME through the AppKit host

Data: 2026-10-12
Máquina: Mac mini, Apple M4, macOS 27.2, layout Brazilian-ABNT2
Runner: `macos-14` (Apple Silicon, layout US)

Até esta data o backend macOS anunciava `keyboardInput`, `pointerInput` e
`scrollInput`, e nenhum evento de entrada chegava ao framework. Este documento
registra o que foi construído, e principalmente o que foi **medido** no
caminho, porque várias respostas não são as que a documentação da Apple
sugere.

## 1. O que existe agora, e onde está a prova

| Peça | Código | Prova |
|---|---|---|
| Input (ponteiro, teclas, rolagem, cruzamento da borda) | `macos_input.dart`, `INPUT=` estendido | `tool/macos_input_smoke.dart`, `INPUT_EVENT_*` |
| Teclas → VK do Windows | `macosLogicalKey` | `macos_input_test.dart` |
| Clipboard de texto | `macos_clipboard.dart` | `tool/macos_clipboard_smoke.dart`, com `pbpaste`/`pbcopy` |
| Teclas mortas | `interpretKeyEvents:` na view do host | `INPUT_APP_DEAD_KEYS`: "éã" no ABNT2 e no US |
| Pré-edição de IME e candidatos no cursor | `macos_text_input.dart`, `COMPOSE`/`COMMIT`/`IME_CARET` | `INPUT_APP_IME`, `macos_text_input_test.dart` |
| Atalhos do Mac no `TextField` | `EditingConvention` | `text_field_mac_shortcuts_test.dart`, `INPUT_APP_COMMAND_SHORTCUTS` |

Os três smokes rodam no workflow `macos_popup_probe.yml`.

## 2. Como provar input sem permissão de acessibilidade

Um `CGEventPost` vindo de outro processo não chega nesta máquina: o processo
não tem permissão de acessibilidade. O host aceita comandos `SYNTH_*` que
montam um `NSEvent` e o postam **na própria fila** (`[NSApp postEvent:]`).
Daí em diante o evento percorre o caminho de um evento real: é retirado da
fila, passa pelo monitor local, vira linha `INPUT=`, é traduzido e entregue.
O que não fica provado é o trecho antes da fila (o WindowServer roteando um
clique físico para o processo certo), que é do AppKit.

Dois cuidados que custaram uma volta cada:

- `mouseEventWithType:` não tem argumento de botão e deixa `buttonNumber` em
  0 mesmo para um evento de botão direito. O número vai pelo Quartz
  (`kCGMouseEventButtonNumber`).
- Um evento sem janela (`event.window == nil`, caso de uma rolagem montada
  pelo Quartz) traz `locationInWindow` em coordenadas de **tela**. O host
  zerava a posição; agora converte. A correção vale para eventos reais também.

## 3. Teclas mortas só existem dentro do sistema de entrada

A primeira versão tirava o texto de `event.characters` no monitor de eventos.
No ABNT2, `´` seguido de `e` dava `e`. Um protótipo isolado (app AppKit mínima
com uma `NSView` `NSTextInputClient` e eventos postados) separou as hipóteses:

| Variante | Resultado de `´` + `e` |
|---|---|
| view chama `interpretKeyEvents:` | `é` |
| view lê `event.characters`, sem `interpretKeyEvents:` | `e` |
| com `keyUp` entre as teclas | igual ao caso acima |
| com um monitor lendo `charactersIgnoringModifiers` | igual ao caso acima |

O estado de tecla morta é criado pelo sistema de entrada enquanto ele processa
a **primeira** tecla, e só então o `characters` da segunda sai composto. Não há
leitura de `NSEvent` que o reproduza fora dele.

Um detalhe que torna o teste confiável: com `characters` vazio, o AppKit
**retraduz** o evento sintético a partir do `keyCode` e dos modificadores com o
layout selecionado. Option+E sem caracteres deu `€`, que é o Option+E do ABNT2.
Por isso o smoke manda as teclas mortas sem caracteres e escolhe a sequência
pelo layout (`com.apple.HIToolbox AppleCurrentKeyboardLayoutInputSourceID`):
ABNT2 aqui, US no runner. No US, Option+E **marca** o `´` (`setMarkedText:`),
então o runner exercita o caminho de composição com o IME do próprio sistema.

## 4. O AppKit só despacha teclas para uma janela na tela

Com o texto saindo da view, a metade do smoke que usa `Application` parou de
receber texto: o monitor via todas as teclas e a view nenhuma. A janela da
aplicação estava com `isVisible == NO`, porque o smoke bombeia à mão e nunca
chama `Application.run`, que é quem mostra a janela primária. Um evento de
teclado vai para a janela-chave da aplicação, e uma janela fora da tela não
recebe nenhum. Não é defeito do backend; o smoke passou a mostrar a janela.

## 5. A ativação é recusada conforme quem lançou o processo

No macOS 14 e posteriores, um processo iniciado por outro processo em segundo
plano (terminal, editor, a ferramenta deste repositório) tem a ativação
recusada. A janela do host não vira key nem quando criada visível com
`activateIgnoringOtherApps:`. O `INSPECT_WINDOW` mostra `isKeyWindow=0`. O
`popup_window_smoke` passou a ler o estado da dona **antes** de abrir o popup
e, se o sistema nunca a ativou, prova só a metade que é do popup
(`ownerActiveBefore=false` na linha).

## 6. Um host que morre entre duas escritas

No runner, a etapa do popup caiu duas vezes com `SocketException: Broken pipe`
não tratada. Escrever no stdin de um filho que acabou de morrer falha de forma
**assíncrona**, no `done` do sink, que ninguém escutava. Reproduzido aqui
matando a reserva de popup de forma síncrona e abrindo o popup sem volta do
laço de eventos no meio: três falhas em três antes da correção, três
aberturas em três depois. `host_process_broken_pipe_test.dart` faz o mesmo
com um host de mentira em `sh` e roda também na perna Linux.

## 7. O que continua aberto

- Texto ao redor para o IME (`attributedSubstringForProposedRange:` devolve
  nil): o método converte sem contexto do documento, como no Win32.
- O primeiro menu no runner: 58 ms sem reserva de popup, 180 a 310 ms com ela,
  em seis execuções, sem que o atraso do lançamento da reserva mudasse isso.
  Aqui o primeiro menu fica em ~70 ms com ou sem. O workflow agora roda o
  smoke de popup com e sem a reserva (`DART_UI_MACOS_SPARE_HOST=0`) para
  separar a causa.
- Drag-and-drop no macOS não existe.
