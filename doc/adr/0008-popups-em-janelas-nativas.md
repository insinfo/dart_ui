# ADR 0008 — Popups em janelas nativas: o seam, a ativação e quem decide o descarte

**Status:** aceito
**Data:** 6 de setembro de 2026
**Relacionados:** §29.6 e §68.3 do roteiro, §8.1.1 (GPU primeiro),
`doc/PLANO_POPUPS_EM_JANELAS_NATIVAS.md`

## Contexto

Um menu, um dropdown de combo box, um submenu e um tooltip têm duas metades
que mudam por razões diferentes: **o que mostram** (itens, teclado, semântica
— um widget, igual em toda plataforma) e **onde os pixels caem** (compostos na
superfície da janela dona, ou numa janela override-redirect que pode passar
das bordas dela).

Este framework tinha a primeira metade e não a segunda. `WindowKind.popup` e
`WindowKind.tooltip` existiam com dono, sem ativação e com descarte por foco;
`Application` abria e fechava N janelas; o Win32 já criava o popup com
`WS_POPUP | WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW` e o Wayland já criava um
`xdg_popup` de verdade com `xdg_positioner`. **Nenhum widget abria uma dessas
janelas.** O menu de contexto tinha uma costura (`ContextMenuPresentation`)
com uma implementação só, o combo box desenhava num overlay da própria árvore,
e `Tooltip.build` devolvia o filho.

A consequência é visível e é a mesma que o trabalho de multijanela do Flutter
desktop existiu para corrigir: **um menu perto da borda da janela é cortado em
vez de virar de lado**, porque um overlay não pode sair da superfície em que é
desenhado.

## Decisão

### 1. Uma costura, duas implementações, escolhidas por capacidade e política

`PopupHost` (em `widgets/`) responde `escapesOwnerWindow` e abre um popup a
partir de um `PopupSpec`. Duas implementações:

- **`InTreePopupHost`** compõe na superfície da dona. É barato, é portátil, e
  é a **única** coisa que funciona num backend sem janelas — headless e web
  nunca ganham popup nativo, e todo widget precisa continuar funcionando lá.
  Por isso é o recuo, não um resto;
- **`WindowPopupHost`** (em `app/`) abre uma `WindowKind.popup`. Mora acima
  porque precisa de `Application`, e a §8.2 proíbe `widgets` de nomear a camada
  de aplicação. A costura é o que torna essa regra barata.

`PopupPolicy.auto | inTree | window` deixa a aplicação decidir, e
`PopupPolicy.window` num backend sem janelas **falha por nome**
(`PopupWindowUnavailableError`) em vez de cair para o overlay em silêncio:
quem pediu janela pediu porque ser cortado não serve.

É o desenho do Avalonia (`Popup.ShouldUseOverlayLayer` + `IPopupImpl`, com
`OverlayPopupHost` como recuo) e a forma pública do Flutter da Canonical
(`PopupWindowController` + o conteúdo como subtree). Foi copiado de propósito:
os dois chegaram nele resolvendo este problema.

### 2. O popup **não** ativa; o teclado é redirecionado

Um popup nativo é mostrado sem ativação (`SW_SHOWNOACTIVATE`,
`WM_MOUSEACTIVATE → MA_NOACTIVATE`, override-redirect no X11). O foco do
**sistema** fica na janela dona; o foco do **framework** pode estar dentro do
popup, e `Application` entrega as teclas ao popup vivo mais interno da janela
focada, com a dona recebendo o que ele recusar.

A alternativa — deixar o popup pegar foco de verdade, que é o que o Flutter da
Canonical permite — foi recusada pela razão que o próprio `WindowKind` já
tinha escrito: no Win32, ativar o popup manda `WM_ACTIVATE(WA_INACTIVE)` para
a dona, e todo anel de foco dela fica cinza enquanto o usuário apenas lê um
menu. O custo desta escolha é o redirecionamento em `Application`; o ganho é o
caret continuar piscando atrás.

### 3. O descarte é do framework, não do sistema — e **sem grab**

Nem `XGrabPointer` no X11 nem `xdg_popup.grab` por padrão no Wayland. As
razões, nesta ordem:

- no Wayland o grab exige um **serial de input recente**, e um grab sem ele é
  erro de protocolo — que mata a conexão e leva junto **todas** as janelas do
  processo. Um menu abrindo derrubaria a aplicação. O serial virou parte do
  tipo (`WaylandPopupGrab`), então esse estado é irrepresentável em vez de ser
  um erro em tempo de execução;
- no X11 um grab que vaza porque o processo travou **congela o desktop
  inteiro**;
- e o descarte já tem cinco entradas no framework, todas nomeadas: clique na
  dona fora do popup, clique na área não-cliente, dona movida ou
  redimensionada, `popup_done` do compositor, e Escape.

O Avalonia decidiu igual, pelos mesmos motivos, e escreve isso no comentário
de classe do `Avalonia.Wayland/PopupImpl`. O que se perde: um clique numa
**outra aplicação** chega nela antes de fechar o nosso menu. O GTK faz grab e
engole; nós preferimos não poder congelar a sessão do usuário.

### 4. "O clique que fecha um menu não pressiona o que está atrás" mora no hit test

Esta é a parte que parece um detalhe e é a decisão de desenho.

O roteador entrega o caminho de hit **do mais profundo para a raiz**. Um botão
deixado no caminho já foi pressionado quando o evento sobe até a camada de
popup — não existe valor de retorno que desfaça isso. Então a decisão tem de
ser tomada **antes**, no hit test:

- um **menu** tira o conteúdo do caminho (`hitTestChildren` para nos popups e
  nunca alcança o filho 0). É a mesma coisa que `RenderContextMenuLayer` já
  fazia, chegando lá pela mesma razão;
- um **dropdown** e um **tooltip** não tiram, porque para eles o pass-through
  *é* o comportamento certo: fechar uma lista de combo clicando num botão deve
  pressionar esse botão, que é o que todo desktop faz.

`PopupKind.dismissalPassesThrough` é onde essa diferença está escrita, e as
duas implementações do host leem a mesma propriedade — um usuário não pode
receber comportamentos diferentes do mesmo clique dependendo de qual host foi
escolhido.

### 5. O popup renderiza pelo caminho da dona

Sem exceção de renderização: se a dona está no Direct3D 11, o menu está no
Direct3D 11. O popup adota o **dispositivo** da dona em vez de criar o seu, o
que também preserva o atlas de glifos — o texto do menu já está rasterizado,
porque a mesma fonte no mesmo tamanho já foi desenhada na janela de trás.

A razão de peso não é desempenho: é que um menu rasterizado na CPU sobre uma
janela na GPU exibe lado a lado, na mesma tela, os desvios que a §68.4 lista
por nome. Ver §8.1.1 do roteiro para os três casos em que a CPU é a resposta
certa.

## Consequências

**Ganhas:**

- um menu perto da borda vira de lado em vez de ser cortado, que é o defeito
  que motivou tudo;
- o mesmo widget funciona nos dois hosts, e o teste do host in-tree
  (`test/widgets/popup_host_test.dart`) é o contrato que o host de janela tem
  de satisfazer;
- headless e web continuam funcionando sem saber que janelas existem;
- `PopupStack` e `PopupEntry`, escritos e sem consumidor desde sempre, passam
  a ser o que ordena a cadeia e decide o descarte.

**Pagas:**

- `Application` ganha roteamento de teclado e cinco entradas de descarte que
  antes não existiam. É código no arquivo mais sensível do repositório;
- um popup é uma `ApplicationWindow` com seu `BuildOwner` — os
  `InheritedWidget`s da dona **não** atravessam, e o host reembrulha tema,
  direção de leitura e `MediaQuery` explicitamente;
- auto-dimensionar exige medir com constraints frouxas numa janela oculta
  antes de mostrar. Uma janela que aparecesse no tamanho provisório e depois
  redimensionasse seria um salto visível;
- um clique em outra aplicação não fecha nosso menu imediatamente (item 3).

**Não decididas aqui:** acessibilidade do popup como fragmento UIA filho da
dona, e o macOS, que não pode ser verificado nesta máquina — escrever às cegas
produz confiança falsa, que é o que a §68.1 existe para evitar.
