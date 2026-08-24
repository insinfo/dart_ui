#  Vector Editor (100% Pure Dart)

Um  funcional e moderno da arquitetura do editor vetorial profissional inspirado em **sK1-wx** e **UniConvertor**, implementado em **100% Puro Dart** sobre o framework gráfico multiplataforma `dart_ui`.

---

## 🚀 Destaques da Implementação

- **Zero dependências externas nativas**: Sem Cairo, sem wxWidgets, sem C/C++ FFI.
- **Formato Nativo CorelDRAW (.cdr)**: Leitor e escritor de contêineres binários RIFF (CDR v3 a v13) e arquivos ZIP estruturados (CDR X4 a 2024).
- **Importação e Exportação**:
  - **CorelDRAW (.cdr)**: Leitura e escrita nativa completa.
  - **SVG 1.1 / Tiny**: Importação e exportação de nós, caminhos e estilos.
  - **PDF (ISO 32000)**: Exportação de alta resolução vetorial para impressão e distribuição.
- **Geometria de Alta Precisão**:
  - Algoritmo de De Casteljau para avaliação e subdivisão de curvas cúbicas/quadráticas de Bézier.
  - Extremos exatos (raízes analíticas) para Bounding Boxes justas (*tight bounds*).
  - Operações booleanas 2D (União, Interseção, Diferença, Exclusão).
  - Offset de caminhos, junções (miter, round, bevel) e terminais de linha (butt, round, square).
- **Interface completa, no layout do sK1** (de cima para baixo):
  1. **Barra de menus** — File, Edit, View, Layout, Arrange, Paths, Bitmaps, Text, Help, com
     menus suspensos reais, atalhos exibidos à direita e itens desabilitados que declaram o
     motivo (`MenuItem.disabledReason`) em vez de simplesmente não reagir.
  2. **Barra de ferramentas padrão** — novo/abrir/salvar | imprimir/exportar | desfazer/refazer |
     recortar/copiar/excluir | grupo de zoom, com divisores entre grupos.
  3. **Barra de propriedades contextual** — troca de conteúdo conforme ferramenta e seleção,
     seguindo a decisão de `ctxpanel.py`: sem seleção mostra formato de página e unidades;
     com seleção mostra posição, tamanho, rotação, espelhamento e ordem; um objeto único
     acrescenta o plugin do seu tipo (arredondamento do retângulo, arco/corda/fatia da elipse,
     número de lados do polígono, conteúdo e corpo do texto).
  4. **Abas de documento** com o marcador `*` de não salvo e botão de fechar.
  5. **Caixa de ferramentas vertical** com estado ativo visível, tooltip e indicador de
     preenchimento/contorno no rodapé.
  6. **Réguas** horizontal e vertical acompanhando zoom e pan, com rastreador de cursor, e o
     botão de canto que cicla as unidades do documento.
  7. **Painéis acopláveis à direita** (`Docking`) com **faixa de abas verticais recolhidas** na
     borda: Transformations, Align and Distribute e Fill and Outline. Clicar na aba aberta
     recolhe a área inteira e devolve a largura ao canvas.
  8. **Paleta de cores** na base — clique esquerdo preenche, clique direito contorna.
  9. **Barra de status** — coordenadas, zoom, snapping, página, dimensões da seleção, mensagem
     de estado e monitor de preenchimento/contorno.
- Grade magnética e linhas guias com *snapping*.
- Histórico transacional completo de Undo / Redo.

---

## 📦 Estrutura dos Módulos

```
lib/
├── dart_ui.dart                                # Exportação pública unificada
└── src/
    ├── graphics/vector/                        # Modelo de Documento Vetorial (DOM)
    │   ├── document_object.dart                # Árvore base DocumentObject
    │   ├── document.dart                       # VectorDocument e Pages
    │   ├── structural_objects.dart             # Page, Layer, GuideLayer, Guide
    │   ├── selectable_objects.dart             # SelectableObject, Group, TPGroup
    │   ├── primitives.dart                     # Rectangle, Circle, Polygon, Curve, Text
    │   ├── pixmap.dart                         # Imagens raster embutidas
    │   ├── style.dart                          # FillStyle, StrokeStyle, TextStyle
    │   ├── doc_methods.dart                    # Operações de alto nível (CRUD, z-order)
    │   └── serialization/
    │       ├── vector_pdf_exporter.dart        # Compilação para PDF
    │       └── vector_svg_codec.dart           # Importação/Exportação SVG
    ├── geometry/
    │   ├── bezier.dart                         # Avaliação, raízes, divisão e conversão
    │   ├── contour.dart                        # Offset e contorno de traço
    │   └── shaping.dart                        # Operações booleanas (União, Dif, etc.)
    ├── cdr/                                    # Engine CorelDRAW
    │   ├── container/
    │   │   ├── riff_reader.dart                # Parser RIFF binário
    │   │   ├── riff_writer.dart                # Serializador RIFF binário
    │   │   └── zip_cdr_archive.dart            # Parser ZIP CDR moderno
    │   ├── document/
    │   │   ├── cdr_document.dart               # Modelo CDR interno
    │   │   └── cdr_translator.dart             # Conversão bidirecional CDR ↔ VectorDocument
    │   └── styles/
    │       └── cdr_color_parser.dart           # Parser de cores CMYK/RGB/Pantone
    └── widgets/vector_editor/                  # Widgets Especializados do Editor
        ├── vector_canvas.dart                  # Viewport do Canvas
        ├── vector_renderer.dart                # Compilador DisplayList
        ├── selection.dart                      # Gerenciador de seleção e alças
        ├── snap_manager.dart                   # Motor de alinhamento magnético
        ├── ruler.dart                          # Réguas graduadas
        ├── tool_controller.dart                # Controladores de ferramentas
        ├── text_edit_controller.dart           # Caret e seleção de texto dentro do canvas
        ├── text_metrics.dart                   # Medição do texto artístico (bbox e caret)
        ├── color_controls.dart                 # Barra de paleta de cores
        ├── fill_controls.dart                  # Painel de preenchimento
        └── stroke_controls.dart                # Painel de traço

examples/vector_editor_demo/                    # Aplicação Desktop do Editor
├── main.dart                                   # Ponto de entrada executável
├── app.dart                                    # Directionality + Theme + janela
├── main_window.dart                            # Montagem do layout sK1 inteiro
├── metrics.dart                                # TODAS as métricas do chrome (alturas, larguras)
├── editor_model.dart                           # Estado do editor e todas as mutações de documento
├── commands.dart                               # Catálogo de comandos (menus, barras, atalhos)
├── menu_bar.dart                               # Barra de menus + popup do menu aberto
├── standard_toolbar.dart                       # Barra de ferramentas padrão
├── context_panel.dart                          # Barra de propriedades contextual (ctxpanel.py)
├── toolbox.dart                                # Caixa de ferramentas vertical (tools.py)
├── doc_tabs.dart                               # Abas de documento (doctabs.py)
├── canvas_area.dart                            # Réguas + canto de unidades + canvas (mdiarea.py)
├── plugin_area.dart                            # Docking + faixa de abas recolhidas (plgarea.py)
├── panels.dart                                 # Transformations, Align and Distribute, Fill/Outline
├── status_bar.dart                             # Barra de status (statusbar.py)
├── document_api.dart                           # Comandos transacionais com Undo/Redo
└── tool/headless_shot.dart                     # Renderiza a janela para PNG sem abrir janela
```

---

## 🏃 Como Executar

```bash
# Executar o editor com documento padrão
dart run examples/vector_editor_demo/main.dart

# Abrir um arquivo CorelDRAW existente
dart run examples/vector_editor_demo/main.dart meu_arquivo.cdr

# Abrir um arquivo SVG existente
dart run examples/vector_editor_demo/main.dart meu_desenho.svg
```

### Verificação sem abrir janela

O backend headless renderiza a janela inteira para PNG, que é o laço em que este editor foi
construído: montar, rasterizar, olhar a imagem, corrigir.

```bash
dart run examples/vector_editor_demo/tool/headless_shot.dart saida.png 1400 880
dart run examples/vector_editor_demo/tool/headless_shot.dart saida.png 1400 880 menu:0
dart run examples/vector_editor_demo/tool/headless_shot.dart saida.png 1400 880 select
dart run examples/vector_editor_demo/tool/headless_shot.dart saida.png 1400 880 collapsed
```

Os cenários de **interação** dirigem a janela com eventos de ponteiro e teclado reais, porque
marquee, alça agarrada e cursor de texto só existem enquanto o gesto está em curso:

```bash
dart run .../headless_shot.dart saida.png 1400 880 drag-star   # objeto arrastado
dart run .../headless_shot.dart saida.png 1400 880 handle      # alça agarrada, redimensionando
dart run .../headless_shot.dart saida.png 1400 880 marquee     # retângulo elástico em curso
dart run .../headless_shot.dart saida.png 1400 880 text-edit   # texto em edição, com caret
dart run .../headless_shot.dart saida.png 1400 880 multi       # três objetos com Shift
dart run .../headless_shot.dart saida.png 1400 880 zoomed      # três passos de roda no cursor
dart run .../headless_shot.dart saida.png 1400 880 rotate     # a moldura de rotação, em repouso
dart run .../headless_shot.dart saida.png 1400 880 rotating   # um canto agarrado, girando
```

Os testes de regressão correspondentes:

```bash
dart test test/examples/vector_editor_shell_test.dart        # o chrome existe e é visível
dart test test/examples/vector_editor_interaction_test.dart  # os gestos fazem o que dizem
```

`vector_editor_shell_test.dart` afirma que cada peça do chrome existe com tamanho não-nulo **e**
que ela continua visível depois de rasterizada — as duas coisas, porque a primeira sozinha
passava enquanto a janela estava em branco.

`vector_editor_interaction_test.dart` fixa cada um dos sete defeitos de interação relatados na
janela real: a estrela que sumia ao ser arrastada, a alça que não se pegava, o duplo clique no
texto que não fazia nada, o arrasto no vazio que não selecionava, o Shift que não somava, o botão
do meio que não deslocava e a roda que não dava zoom.

---

## 🖱️ Modelo de interação (e onde ele diverge das referências)

A referência primária é o **sK1** (`referencias/sk1-wx-main/src/sk1/document/controllers/`), que
por sua vez imita o CorelDRAW. Onde a divergência foi deliberada, está dita aqui.

| Gesto | Comportamento | Origem |
| --- | --- | --- |
| Clique num objeto | Seleciona (substitui a seleção) | sK1 `select_at_point` |
| **Segundo clique** no que já está selecionado | Troca a moldura de escala pela de **rotação**: cantos giram, arestas inclinam | CorelDRAW / sK1 `trafo_ctrl.py` |
| Arrastar um canto na moldura de rotação | Gira em torno do pivô | idem |
| **Shift** ao girar | Trava em passos de 15° | CorelDRAW |
| Arrastar uma aresta na moldura de rotação | Inclina, ancorado na aresta oposta | idem |
| Arrastar o **pivô** | Move o ponto em torno do qual se gira; não é passo de undo | idem |
| **Alt** + clique | Alcança o objeto de baixo, ciclando pela pilha a cada clique | CorelDRAW / Inkscape |
| **Shift** + clique | Alterna: fora entra, dentro sai | sK1 `add(objs, xor=True)` |
| Arrastar sobre a seleção | Move em espaço de documento, a partir do estado do *press* | sK1 `MoveController` |
| **Ctrl** ao mover | Trava num eixo | sK1 `MoveController.mouse_move` |
| Arrastar uma alça | Escala ancorada no canto oposto | sK1 `TransformController` |
| **Shift** ao redimensionar | Mantém a proporção | **CorelDRAW / Inkscape** — o sK1 usa Ctrl |
| **Ctrl** ao redimensionar | Escala a partir do centro | **trocado** — é o Shift do sK1 |
| Mover ou redimensionar com Snap ligado | Encaixa as **arestas da bbox**, não o ponteiro | sK1 `MoveController._snap` |
| Duplo clique no ícone da ferramenta de seleção | Seleciona tudo | CorelDRAW / sK1 |
| Arrastar no vazio | Retângulo elástico | sK1 `SELECT_MODE` |
| Elástico solto | Seleciona o que estiver **inteiramente dentro** | sK1 `is_bbox_in_rect` |
| **Ctrl/Alt** + elástico | Seleciona o que ele **tocar** | sK1 `overlap_flag` |
| **Shift** + elástico | Soma à seleção em vez de substituir | sK1 `add_flag` |
| Duplo clique num texto | Entra em edição no canvas, caret onde se clicou | sK1 `TEXT_EDIT_MODE` |
| **Escape** editando | Abandona a alteração | sK1 `escape_pressed` |
| **Enter** ou clique fora | Confirma, como um passo de undo | — |
| **Botão do meio** arrastando | Desloca a viewport, em qualquer ferramenta | sK1 `mouse_middle_down` → `TEMP_FLEUR_MODE` |
| **Espaço** segurado + arrastar | Idem | convenção universal |
| Roda vertical | **Zoom centrado no cursor** | **CorelDRAW** — ver abaixo |
| Roda horizontal / Shift+roda | Desloca lateralmente | sK1 `Ctrl+wheel` |

**Por que a roda não segue o sK1.** O sK1 rola na roda pura e dá zoom em **Shift+roda**
(`AbstractController.wheel`). Shift+roda não é observável aqui: o backend Win32 converte
Shift+roda-vertical em uma rolagem **horizontal** antes de qualquer widget ver o evento — a
substituição convencional para mouses sem roda de inclinação — e `PointerScrollEvent` não carrega
conjunto de modificadores para desfazer isso. É uma limitação de framework, registrada em vez de
contornada. Então a roda vertical dá zoom, que é o padrão do CorelDRAW e o que foi pedido.

O zoom da roda é aplicado como `1.2 ^ -delta`, não como um passo fixo por evento: dez relatos de
0,1 de um trackpad compõem exatamente o mesmo zoom que um relato de 1,0. Um passo fixo daria dez
vezes mais zoom no trackpad que no mouse.

**Clique versus arrasto** é decidido por **5 pixels de tela** de deslocamento total, que é a regra
do sK1 (`change_x < 5 and change_y < 5`). Pixels de tela e não unidades de documento: o limiar tem
de ser a mesma distância física em qualquer zoom. Pela mesma razão, a tolerância das alças é
`7 px / zoom` em unidades de documento — o sK1 dimensiona os seus marcadores assim
(`config.sel_marker_size / (2.0 * canvas.zoom)`).

### As duas molduras

A primeira seleção dá uma moldura de **escala**: oito quadradinhos brancos,
ancorados no canto oposto. Clicar de novo no mesmo objeto troca-a pela moldura de
**rotação** — cantos viram losangos, arestas viram barras deitadas na direção em
que deslizam, e no meio aparece o **pivô**, um anel com uma cruz. Um terceiro
clique volta para a de escala; selecionar outra coisa também.

A moldura tem de *parecer* diferente ou o modo é invisível, e um modo invisível é
um relatório de bug. O pivô é lido uma vez, no `press`, e mantido pelo gesto
inteiro: lê-lo a cada evento leria o centro de uma caixa que o evento anterior já
girou, e o centro da caixa de uma forma assimétrica em rotação passeia — a volta
passaria a depender de quantos eventos de ponteiro a plataforma resolveu
entregar.

### Snapping: a caixa, não o ponteiro

`SnapManager` tem dois encaixes, e a distinção é a correção que faltava:

- `snapPoint` encaixa o **ponteiro**. É o certo para uma ferramenta que desenha
  uma forma a partir do nada — o canto de um retângulo novo *é* onde o ponteiro
  está. Os criadores de forma continuam usando este;
- `correctionFor` encaixa as **arestas da caixa transformada** e devolve o
  empurrãozinho a somar ao delta. Num arrasto o ponteiro não é canto de nada: é
  onde por acaso se pegou na forma, e encaixá-lo desloca o objeto pelo tamanho
  dessa pegada sem alinhar aresta nenhuma. É o `MoveController._snap` do sK1.

Um mover oferece as três linhas de cada eixo (as duas arestas e o centro); um
redimensionar oferece só as arestas que a alça arrasta, porque encaixar a aresta
ancorada seria mover a âncora — a única coisa que um redimensionamento promete
não fazer. A tolerância é `6 px / zoom`, pela mesma razão que a das alças.

### Hit test por contorno

Um clique acerta o objeto onde o preenchimento seria pintado (winding não-zero
sobre os contornos achatados), e uma forma sem preenchimento — ou aberta — dentro
da tolerância do seu traço. O vão entre as pontas da estrela deixou de selecionar
a estrela. Objetos sem geometria (texto) caem de volta na caixa, que para um
texto *é* a forma.

**Pendências nomeadas** (decididas, não implementadas):

- a moldura desenhada em volta de um objeto girado continua sendo a **caixa
  alinhada aos eixos**, não o retângulo girado que o sK1 desenha. O modelo de
  documento guarda a matriz certa e o objeto gira certo; é o desenho da moldura
  que ainda não gira;
- **inclinar continua sem entrada numérica** — o painel Transformations diz isso
  na cara (`Shearing is not implemented in the Dart demo yet`); o gesto existe,
  o campo não;
- redimensionar um objeto **com traço** move a aresta ancorada da sua *caixa* por
  uma fração de ponto, porque a caixa inclui metade da espessura do traço e o
  traço não escala com a geometria. É pequeno, é real, e é anterior a tudo isto.
