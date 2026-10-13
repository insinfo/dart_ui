# Catálogo de referência: CorelDRAW e editores vetoriais

Documento de referência para priorizar funcionalidades e decidir a UI do editor vetorial em Dart puro.
Pesquisa feita em 12/10/2026. As fontes estão no fim do arquivo.

**Legenda de prioridade**
- **P0**: núcleo. Todo editor vetorial precisa ter.
- **P1**: importante. Faz o editor ser produtivo.
- **P2**: avançado ou opcional.

**Convenções de atalho**
- Os atalhos são os padrões do CorelDRAW para Windows (X7 a 2024).
- No macOS, `Ctrl` vira `Cmd` e `Alt` vira `Option`. O app nativo do Mac (2019+) segue o mesmo mapa.
- "—" significa que não há atalho padrão: o comando fica só no menu, na flyout ou na barra.
- Atalhos marcados com (*) mudaram entre versões ou têm significado diferente conforme o contexto. Ver a seção 1.12.

---

## 1. Catálogo de funcionalidades do CorelDRAW

### 1.1 Caixa de ferramentas (Toolbox)

A caixa de ferramentas fica na vertical, à esquerda. As ferramentas são agrupadas em **flyouts**: um botão com um triângulo no canto inferior direito abre o grupo. A flyout pode ser destacada e virar uma barra flutuante, e a última ferramenta usada passa a ser o ícone do grupo. Pelo botão "Quick customize" você mostra ou esconde ferramentas.

#### Seleção e transformação
| Ferramenta | Descrição | Atalho | Prio |
|---|---|---|---|
| Pick (Seleção) | Seleciona, move, dimensiona, inclina e gira objetos. Um segundo clique no objeto alterna para as alças de rotação e inclinação. | `Space` alterna entre a ferramenta atual e o Pick | P0 |
| Freehand pick | Seleção por laço à mão livre. | — (`Alt`+arrastar com o Pick) | P2 |
| Free transform | Rotação, reflexão em ângulo livre, escala e inclinação feitas interativamente. | — | P2 |

#### Edição de forma (flyout Shape edit)
| Ferramenta | Descrição | Atalho | Prio |
|---|---|---|---|
| Shape (Forma) | Edita nós e segmentos: move nós e alças e muda o tipo do nó. Em retângulos e elipses, edita cantos e ângulos. | `F10` | P0 |
| Smooth | Suaviza a curva e reduz nós ao pincelar sobre ela. | — | P2 |
| Smear | Puxa extensões ou cria reentrâncias no contorno. | — | P2 |
| Twirl | Cria redemoinhos ao arrastar na borda. | — | P2 |
| Attract / Repel | Atrai ou repele nós em relação ao cursor. | — | P2 |
| Smudge / Roughen | Distorce o contorno: borra ou deixa áspero. | — | P2 |

#### Corte (flyout Crop)
| Ferramenta | Descrição | Atalho | Prio |
|---|---|---|---|
| Crop | Recorta objetos e bitmaps a um retângulo. | — | P2 |
| Knife (Faca) | Fatia objetos, grupos e bitmaps ao longo de um traço. | — | P1 |
| Virtual segment delete | Apaga trechos entre interseções. | — | P2 |
| Eraser (Borracha) | Remove áreas do desenho. | `X` | P2 |

#### Navegação
| Ferramenta | Descrição | Atalho | Prio |
|---|---|---|---|
| Zoom | Clique aproxima e clique direito afasta. Arrastar cria um retângulo de zoom. | `Z` | P0 |
| Pan (Mão) | Move a vista. | `H` (e a roda do meio) | P0 |

#### Curvas (flyout Curve)
| Ferramenta | Descrição | Atalho | Prio |
|---|---|---|---|
| Freehand (Mão livre) | Traço à mão livre. Clique e clique faz uma reta. | `F5` | P0 |
| 2-point line | Reta de dois pontos, com modos perpendicular e tangente. | — | P1 |
| Bézier | Curva segmento a segmento: clique cria canto, arrastar cria nó suave. | — | P0 |
| Pen (Caneta) | Igual ao Bézier, com prévia do próximo segmento (rubber band). | — | P0 |
| B-spline | Curva contínua definida por pontos de controle, sem quebras. | — | P2 |
| Polyline | Mistura retas e trechos à mão livre num só objeto, com prévia. | — | P1 |
| 3-point curve | Curva definida por início, fim e um ponto central. | — | P2 |
| Smart drawing | Reconhece o traço livre e o converte em forma básica. | `Shift+S` | P2 |
| LiveSketch | Esboço com ajuste inteligente dos traços. | `S` | P2 |
| Artistic media | Pincéis vetoriais: Preset, Brush, Sprayer, Calligraphic, Expression/Pressure. | `I` | P2 |

#### Formas
| Ferramenta | Descrição | Atalho | Prio |
|---|---|---|---|
| Rectangle | Retângulo. `Ctrl` faz um quadrado e `Shift` desenha a partir do centro. Duplo clique na ferramenta cria um retângulo do tamanho da página. | `F6` | P0 |
| 3-point rectangle | Retângulo inclinado, definido pela base e pela altura. | — | P2 |
| Ellipse | Elipse. `Ctrl` faz um círculo. Modos elipse, pizza (pie) e arco. | `F7` | P0 |
| 3-point ellipse | Elipse inclinada. | — | P2 |
| Polygon | Polígono regular com N lados. | `Y` | P1 |
| Star | Estrela perfeita (pontas e nitidez). | — | P1 |
| Complex star | Estrela de lados que se cruzam. | — | P2 |
| Graph paper | Grade de retângulos agrupados (linhas × colunas). | `D` | P2 |
| Spiral | Espiral simétrica ou logarítmica. | `A` | P2 |
| Basic / Arrow / Flowchart / Banner / Callout shapes | Formas prontas ("Perfect Shapes") com um glifo de controle para ajuste. | — | P2 |
| Impact (2020+) | Efeitos de linhas radiais ou paralelas em estilo quadrinhos. | — | P2 |

#### Texto, tabela, cotas e conectores
| Ferramenta | Descrição | Atalho | Prio |
|---|---|---|---|
| Text | Clique cria **texto artístico** (uma linha livre) e arrastar cria **texto de parágrafo** (dentro de uma moldura). | `F8` | P0 |
| Table | Desenha e edita tabelas. | — | P2 |
| Parallel dimension | Cota inclinada, alinhada aos dois pontos. | — | P2 |
| Horizontal/vertical dimension | Cota horizontal ou vertical. | — | P2 |
| Angular dimension | Cota de ângulo. | — | P2 |
| Segment dimension | Distância entre nós de um ou mais segmentos. | — | P2 |
| 3-point callout | Chamada com linha de chamada de dois segmentos. | — | P2 |
| Straight / Right-angle / Rounded right-angle connector | Conectores que seguem os objetos quando eles são movidos. | — | P2 |
| Edit anchor | Edita os pontos de ancoragem dos conectores. | — | P2 |

#### Efeitos interativos (flyout Interactive)
| Ferramenta | Descrição | Atalho | Prio |
|---|---|---|---|
| Drop shadow | Sombra projetada: deslocamento, opacidade, difusão (feather) e cor. | — | P1 |
| Block shadow | Sombra sólida vetorial. | — | P2 |
| Contour | Cópias concêntricas (para dentro, para fora ou até o centro). | — (docker `Ctrl+F9`) | P2 |
| Blend | Interpola N passos entre dois objetos, opcionalmente ao longo de um caminho. | — | P2 |
| Distort | Distorções Push/Pull, Zipper e Twister. | — | P2 |
| Envelope | Deforma o objeto pelos nós de um envelope. | — (docker `Ctrl+F7`) | P2 |
| Extrude | Extrusão 3D com ponto de fuga, iluminação e bisel. | — | P2 |
| Transparency | Transparência uniforme, gradiente ou padrão, com modo de mesclagem. | — | P1 |

#### Cor e preenchimento
| Ferramenta | Descrição | Atalho | Prio |
|---|---|---|---|
| Color eyedropper | Copia uma cor do desenho ou da área de trabalho. | — | P1 |
| Attributes eyedropper | Copia contorno, preenchimento, tamanho e efeitos de um objeto para outro. | — | P1 |
| Interactive fill | Edita o preenchimento no canvas: arrasta os nós do gradiente e solta cores neles. | `G` | P1 |
| Mesh fill | Malha de cores com nós e cores por nó. | `M` | P2 |
| Smart fill | Cria um objeto a partir da área fechada clicada e o preenche (como o balde de tinta). | — | P2 |
| Outline (flyout) | Atalhos para o diálogo Outline Pen e a cor do contorno. | `F12` caneta, `Shift+F12` cor | P0 |
| Fill / Edit fill | Diálogo de preenchimento: Uniform, Fountain, Pattern, Texture, PostScript. | `F11` (fountain), `Shift+F11` (uniform) | P0 |

### 1.2 Interações universais no canvas (Pick)

| Interação | Comportamento | Prio |
|---|---|---|
| Clique | Seleciona. `Shift`+clique adiciona ou remove da seleção. | P0 |
| Arrastar no vazio | Seleção por marquee (retângulo). `Alt` seleciona o que o retângulo toca. | P0 |
| `Ctrl`+clique | Seleciona um objeto dentro de um grupo sem desagrupar. | P1 |
| `Alt`+clique | Seleciona o objeto que está por baixo (ciclo em profundidade). | P1 |
| `Tab` / `Shift+Tab` | Seleciona o próximo ou o anterior na ordem. | P2 |
| `Esc` | Limpa a seleção. | P0 |
| Alças | 8 alças de escala em quadrados pretos pequenos e um "X" no centro. No 2º clique, as alças viram setas curvas de rotação nos cantos e setas de inclinação nos lados, e o centro vira um alvo móvel. | P0 |
| Arrastar com o botão direito (ou `Space` durante o arrasto) | Solta uma cópia. O botão direito abre o menu Copy/Move/PowerClip. | P1 |
| `+` do teclado numérico | Duplica no mesmo lugar. | P1 |
| Setas | Nudge (padrão 0,1"). `Shift`+setas faz o super nudge (×) e `Ctrl`+setas o micro nudge. | P0 |
| `Ctrl` arrastando | Restringe o movimento ao eixo. Na rotação, restringe a incrementos de 15°. | P0 |
| `Shift` dimensionando | Escala a partir do centro. | P0 |
| `Delete` | Apaga. | P0 |

### 1.3 Barra de propriedades (Property bar) por ferramenta

A barra de propriedades fica abaixo da barra padrão e mostra os controles da ferramenta ativa e do que está selecionado. **É o principal padrão de UI a copiar.**

| Contexto | Controles típicos | Prio |
|---|---|---|
| Pick, sem seleção | Tamanho da página (presets A4/Letter…), largura e altura, retrato ou paisagem, unidades, distância de nudge, distância de duplicação, "todas as páginas / página atual". | P0 |
| Pick, com seleção | X, Y, L, A, escala %, cadeado de proporção, ângulo de rotação, espelhar H e V, espessura do contorno. Com vários objetos: agrupar, desagrupar, combinar e os botões de modelagem (Weld, Trim, Intersect…). Também alinhar e quebra de texto. | P0 |
| Shape (nós) | Modo de seleção de nós (retângulo ou mão livre), adicionar, apagar, juntar e quebrar nós, converter para linha ou curva, nó cusp, smooth ou simétrico, inverter direção, estender para fechar, extrair subcaminho, fechar curva automaticamente, esticar, girar e inclinar nós, alinhar e refletir nós, modo elástico, selecionar todos, **Reduce nodes** (deslizante de suavidade). | P0 |
| Rectangle | Tipo de canto (redondo, chanfro, escalonado), raio por canto com cadeado, escala relativa dos cantos, contorno. | P0 |
| Ellipse | Elipse, pizza ou arco, ângulos inicial e final, direção. | P1 |
| Polygon / Star | Nº de pontas ou lados, nitidez. | P1 |
| Freehand, Bézier, Pen | Suavização (freehand), pontas de seta inicial e final, estilo de linha (tracejado), espessura, fechar curva. | P0 |
| Text | Fonte, tamanho, negrito, itálico, sublinhado, alinhamento, marcadores, capitular, docker de propriedades do texto, direção horizontal ou vertical. | P0 |
| Interactive fill | Tipo de preenchimento (nenhum, uniforme, gradiente linear, elíptico, cônico ou retangular, padrão vetorial, padrão bitmap, padrão de 2 cores, textura, PostScript), cor do nó, opacidade do nó, espelhar ou repetir, transformar com o objeto. | P1 |
| Transparency | Os mesmos tipos, mais modo de mesclagem, alvo (preenchimento, contorno ou tudo) e congelar. | P1 |
| Blend | Passos ou espaçamento, rotação, laço, direção da cor (direta, horária, anti-horária), aceleração de objeto e de cor, caminho. | P2 |
| Contour | Para o centro, dentro ou fora, nº de passos, deslocamento, tipo de canto, cores de contorno e preenchimento. | P2 |
| Drop shadow | Predefinições, deslocamento, ângulo, opacidade, feather e direção do feather, cor, modo de mesclagem. | P1 |
| Envelope | Modos reta, arco simples, arco duplo e livre. Mapeamento horizontal, original, putty ou vertical. | P2 |
| Extrude | Tipo, ponto de fuga, profundidade, rotação 3D, iluminação, bisel, cor. | P2 |
| Zoom | Níveis de zoom, ajustar à seleção, à página, à largura e à altura. | P0 |

### 1.4 Dockers (painéis encaixáveis)

Dockers ficam à direita, empilhados em abas verticais. Podem ficar encaixados, flutuar ou ser recolhidos. Abrem por **Window > Dockers**.

| Docker | Descrição | Atalho | Prio |
|---|---|---|---|
| Objects (antes Object Manager) | Árvore Página > Camadas > Objetos. Cada camada tem olho (visível), impressora (imprimível) e cadeado (travado), além de uma cor de camada. Tem a Página mestre (camadas de guias, desktop e grade). Arrastar reordena. Em versões recentes, cada objeto tem miniatura. | — (Window > Dockers) | P0 |
| Properties (Object Properties) | Abas Fill, Outline e Transparency do objeto, editadas sem diálogo modal. | `Alt+Enter` | P0 |
| Transform | Abas Position, Rotate, Scale & Mirror, Size e Skew. Tem uma grade 3×3 de ponto de referência, valores relativos ou absolutos e "Copies" para aplicar com duplicação. | `Alt+F7`, `Alt+F8`, `Alt+F9`, `Alt+F10` | P1 |
| Align and Distribute | Alinha à esquerda, centro, direita, topo, meio e base. Referência: seleção, último selecionado, página, grade ou ponto. Distribui por bordas, centros ou espaçamento. | `Ctrl+Shift+A` | P0 |
| Shaping | Weld, Trim, Intersect, Simplify, Front minus back, Back minus front e Boundary, com "manter origem/alvo". | — | P0 (as 3 primeiras) |
| Color Styles / Color harmonies | Cores nomeadas e globais: editar a cor atualiza todos os objetos que a usam. | `Ctrl+F6` | P2 |
| Object Styles | Estilos reutilizáveis de contorno, preenchimento e texto. | `Ctrl+F5` | P2 |
| Pages (2021+) | Miniaturas das páginas. Reordena, renomeia e duplica. Multipage view. | — | P1 |
| Text (Character / Paragraph / Frame) | Formatação completa de texto. | `Ctrl+T` | P1 |
| Glyphs | Mapa de caracteres da fonte. | `Ctrl+F11` | P2 |
| Symbols | Biblioteca de símbolos com instâncias ligadas. | `Ctrl+F3` | P2 |
| Contour / Envelope / Lens | Versões em docker dos efeitos. | `Ctrl+F9`, `Ctrl+F7`, `Alt+F3` | P2 |
| Undo (History) | Lista de ações. Clicar em uma volta até ela. | — | P1 |
| Export (2021+) | Exporta várias páginas e objetos de uma vez (assets). | — | P2 |
| Effects (2024) | Pilha de efeitos não destrutivos. | — | P2 |
| Hints / Learn | Ajuda contextual da ferramenta ativa. | — | P2 |

### 1.5 Operações de objeto (menu Object, antes Arrange)

| Comando | Descrição | Atalho | Prio |
|---|---|---|---|
| Group / Ungroup | Agrupa ou desagrupa (Ungroup all desfaz todos os níveis). | `Ctrl+G` / `Ctrl+U` | P0 |
| Combine | Junta vários objetos num só caminho composto: os furos aparecem pela regra par-ímpar e o objeto fica com os atributos do último. | `Ctrl+L` (*) | P0 |
| Break apart | Separa os subcaminhos de um caminho composto. | `Ctrl+K` | P0 |
| Convert to curves | Transforma retângulo, elipse, texto etc. em caminho editável. | `Ctrl+Q` | P0 |
| Convert outline to object | Transforma o contorno num objeto preenchido. | `Ctrl+Shift+Q` | P1 |
| Order: To front of page / To back of page | Leva ao topo ou ao fundo da página. | `Ctrl+Home` / `Ctrl+End` | P0 |
| Order: To front of layer / To back of layer | Leva ao topo ou ao fundo da camada. | `Shift+PgUp` / `Shift+PgDn` | P0 |
| Order: Forward one / Back one | Sobe ou desce uma posição. | `Ctrl+PgUp` / `Ctrl+PgDn` | P0 |
| Order: In front of… / Behind… / Reverse order | Ordem relativa a um objeto escolhido. | — | P2 |
| Lock / Unlock / Unlock all | Trava o objeto contra seleção. | — | P1 |
| Weld | União booleana. | — | P0 |
| Trim | Subtrai o objeto de origem do alvo. | — | P0 |
| Intersect | Cria a interseção como objeto novo. | — | P0 |
| Simplify | Remove as áreas sobrepostas escondidas. | — | P2 |
| Front minus back / Back minus front | Subtração por ordem de empilhamento. | — | P1 |
| Boundary | Cria o contorno externo de todos os selecionados. | — | P2 |
| Join curves / Close path | Une extremidades próximas (com tolerância) e fecha caminhos. | — | P1 |
| PowerClip | Coloca um objeto dentro de outro, que funciona como máscara de recorte. Também extrai, edita e trava o conteúdo. | — | P1 |
| Transformations: Mirror H/V, Rotate, Clear transformations | Espelha, gira e limpa as transformações. | — (botões na barra) | P0 |
| Align & distribute | Ver 1.6. | — | P0 |
| Insert: barcode, QR code | Insere código de barras ou QR code. | — | P2 |
| Symmetry (2018+) | Desenho simétrico ao vivo. | `Alt+S` (*) | P2 |

### 1.6 Alinhar e distribuir (teclas de uma letra, com o Pick)

O alinhamento é relativo ao **último objeto selecionado**. Se a seleção for feita por marquee, a referência é o de baixo.

| Tecla | Ação | Prio |
|---|---|---|
| `L` / `R` | Alinha as bordas esquerdas ou direitas. | P0 |
| `T` / `B` | Alinha os topos ou as bases. | P0 |
| `C` | Alinha os centros num eixo vertical (centraliza na horizontal). | P0 |
| `E` | Alinha os centros num eixo horizontal (centraliza na vertical). | P0 |
| `P` | Centraliza na página (H e V). | P0 |
| `Shift+L`, `Shift+R`, `Shift+T`, `Shift+B` | Distribui pelas bordas esquerda, direita, topo e base. | P1 |
| `Shift+C` / `Shift+E` | Distribui pelos centros. | P1 |
| `Shift+P` / `Shift+A` | Distribui o espaçamento horizontal ou vertical. | P1 |

### 1.7 Menus

| Menu | Conteúdo principal (atalho) | Prio |
|---|---|---|
| **File** | New (`Ctrl+N`), New from template, Open (`Ctrl+O`), Open recent, Close (`Ctrl+F4`), Close all, Save (`Ctrl+S`), Save as (`Ctrl+Shift+S`), Save as template, Revert, Import (`Ctrl+I`), Export (`Ctrl+E`), Export for Web/Office, Publish to PDF, Print (`Ctrl+P`), Print preview, Print merge, Collect for output, Document properties, Exit (`Alt+F4`). | P0 (New/Open/Save/Import/Export) |
| **Edit** | Undo (`Ctrl+Z`, também `Alt+Backspace`), Redo (`Ctrl+Shift+Z`), Repeat (`Ctrl+R`), Cut, Copy, Paste (`Ctrl+X`, `Ctrl+C`, `Ctrl+V`), Paste special, Delete (`Del`), Duplicate (`Ctrl+D`), Clone, Copy properties from, Step and repeat (`Ctrl+Shift+D`), Select all (objetos, texto, guias, nós; `Ctrl+A`), Find and replace, Properties (`Alt+Enter`). | P0 |
| **View** | Modos de exibição: Wireframe, Simple wireframe, Normal, Enhanced, Pixels, Simulate overprints. Alternar os dois últimos modos (`Shift+F9`). Full-screen preview (`F9`). Preview selected only. Page sorter view. Multipage view. Rulers. Grid (documento, pixel, baseline). Guidelines. Show page border, bleed e printable area. Snap to… e Snap off (`Alt+Q`). Dynamic/Alignment guides (`Alt+Shift+A` (*)). | P0 (zoom, rulers, grid, guides, wireframe) |
| **Layout** | Insert page, Delete page, Duplicate page, Rename page, Go to page, Switch page orientation, Page layout (tamanho, sangria, layout de livreto), Page background. Navegar entre páginas com `PgUp` e `PgDn`. | P1 |
| **Object** | Ver 1.5. | P0 |
| **Effects** | Adjust, Transform, Correction, Artistic media, Blend, Contour, Envelope, Extrude, Bevel, Lens, Add perspective, Create boundary, Copy/Clone effect, Clear effect. | P2 |
| **Bitmaps** | Convert to bitmap, Edit bitmap, Crop, **Trace bitmap (PowerTRACE)** (Quick, Centerline, Outline), Resample, Bitmap color mask, efeitos (Blur, Noise, Sharpen, Distort…). | P2 (vetorizar bitmap = P2 importante) |
| **Text** | Text properties (`Ctrl+T`), Tabs, Columns, Bullets, Drop cap, Insert formatting code, **Fit text to path**, Align to baseline (`Alt+F12`), Straighten text, Convert artistic ↔ paragraph (`Ctrl+F8`), Change case (`Shift+F3`), Show non-printing characters (`Ctrl+Shift+C`), Writing tools/Spell check (`Ctrl+F12`), Glyphs (`Ctrl+F11`). | P1 |
| **Table** | Create new table, Convert text ↔ table, Insert, Select, Delete rows/columns, Distribute, Merge cells (`Ctrl+M` (*)), Split. | P2 |
| **Tools** | Options (`Ctrl+J`, `Cmd+,` no Mac), Customization (atalhos, menus, barras), Color management, Color styles, Object styles, Macros/Scripts (`Alt+F11`). | P1 (opções e atalhos) |
| **Window** | New window, Cascade, Tile, Dockers, Toolbars, Color palettes, Workspace (presets de layout: Default, Lite, Illustration, Page layout, Touch, "Adobe Illustrator"), Refresh window (`Ctrl+W`). | P1 |
| **Help** | Product help, Hints, Video tutorials, What's new, Updates, About. | P2 |

### 1.8 Edição de nós (ferramenta Shape, `F10`)

| Item | Comportamento | Atalho | Prio |
|---|---|---|---|
| Tipos de nó | **Cusp** (alças independentes, desenhado como quadrado), **Smooth** (alças colineares, círculo), **Symmetrical** (colineares e de mesmo comprimento, losango). Fonte: ajuda da Corel (Mac). | `C` alterna cusp↔smooth, `S` alterna smooth↔symmetrical | P0 |
| Linha ↔ curva | Converte o segmento. | `L` (*) / botão | P0 |
| Adicionar nó | Duplo clique no segmento, ou `+` do numpad. | `+` | P0 |
| Remover nó | Duplo clique no nó, ou `Delete`/`-` do numpad. | `Del` | P0 |
| Arrastar segmento | Arrastar o meio do segmento curva o segmento. | — | P0 |
| Nudge de nós | Setas, com `Shift` e `Ctrl` para outros passos. | setas | P0 |
| Selecionar todos os nós | — | `Ctrl+Shift+A` (*) | P1 |
| Join / Break | Junta dois nós extremos ou quebra o caminho no nó. | — | P0 |
| Reverse direction | Inverte o sentido do caminho (início e fim). | — | P1 |
| Extract subpath | Separa um subcaminho. | — | P1 |
| Reduce nodes | Simplifica a curva com uma tolerância. | — | P1 |
| Stretch, rotate, skew, align e reflect de nós | Transforma o conjunto de nós selecionados. | — | P2 |
| Elastic mode | Os nós selecionados se movem proporcionalmente à distância. | — | P2 |
| Em formas paramétricas | Arrastar um nó do retângulo arredonda os cantos. Na elipse, gera pizza ou arco. No polígono, o nó intermediário vira estrela. | — | P0 |

### 1.9 Encaixe (snapping), guias, réguas e grade

| Item | Descrição | Atalho | Prio |
|---|---|---|---|
| Snap to objects | Modos: **Node, Intersection, Midpoint, Quadrant, Tangent, Perpendicular, Edge, Center, Text baseline**. O raio de encaixe é em pixels de tela. | `Alt+Z` (*) | P0 (node, center, edge, midpoint), P1 (resto) |
| Snap to document grid | Encaixa na grade do documento. | `Ctrl+Y` (*) | P0 |
| Snap to guidelines / page / pixels / baseline grid | Encaixa em guias, na página, em pixels ou na grade de linha base. | — | P0 (guias e página) |
| Snap off (desliga tudo) | Desliga o encaixe por completo. | `Alt+Q` | P1 |
| Dynamic guides / Alignment guides | Guias temporárias que aparecem ao alinhar com bordas e centros de outros objetos (como as smart guides do Illustrator). | `Alt+Shift+A` (*) | P1 |
| Réguas | Ficam no topo e à esquerda, mostram as unidades do documento e marcam a posição do cursor. A origem é movida arrastando o canto entre as réguas. Arrastar a partir da régua cria uma guia. | — | P0 |
| Guias | Horizontais, verticais e inclinadas. Têm cor própria, podem ser travadas, são editadas por docker e há presets de margem. | — | P0 |
| Grade | Documento (por espaçamento ou frequência), pixel e baseline. Exibida em linhas ou pontos. | — | P1 |
| Página mestre | As camadas de guias, desktop e grade valem para todas as páginas. | — | P2 |

### 1.10 Página e documento

| Item | Descrição | Prio |
|---|---|---|
| Tamanho da página | Presets (A0–A6, Letter, Legal, Tabloid, cartão, web) ou personalizado, em mm, pol, px, pt ou pica. | P0 |
| Orientação | Retrato ou paisagem. | P0 |
| Unidades e escala do desenho | Escala de mundo, por exemplo 1:100. | P1 / P2 |
| Resolução de renderização | DPI para efeitos e exportação de bitmap. | P1 |
| Sangria (bleed) | Mostrar e exportar a sangria. | P2 |
| Fundo da página | Nenhum, cor sólida ou bitmap. | P1 |
| Várias páginas | Inserir, duplicar, renomear e reordenar páginas. Multipage view (2021+). | P1 |
| Estilos de layout | Página inteira, livro, livreto, cartão dobrado. Páginas lado a lado. | P2 |
| Área de trabalho (desktop) | Os objetos fora da página continuam no documento, mas não são impressos. | P0 |

### 1.11 Formatos de arquivo (importar e exportar)

Lista da ajuda oficial (CorelDRAW 2021). Nem todos os filtros vêm instalados por padrão.

| Formato | Uso | Prio para nós |
|---|---|---|
| CDR (nativo; ZIP desde o X4), CDT (modelo), CMX, CDX | Formato proprietário, sem especificação pública. O libcdr do LibreOffice faz a leitura. | P2 (só importar, via engenharia reversa) |
| **SVG** | Vetor web. É o formato de intercâmbio padrão. | **P0** (importar e exportar) |
| **PDF** (PDF/X desde 2019) | Impressão e intercâmbio. | P1 (exportar), P2 (importar) |
| **PNG / JPEG** | Exportação raster. | **P0** (exportar PNG) |
| WebP, GIF, TIFF, BMP, TGA | Raster. | P1 / P2 |
| AI, EPS, PS/PRN | Formatos Adobe e PostScript. | P2 |
| DXF / DWG, PLT (HPGL) | CAD, plotter e corte (muito usado em comunicação visual e corte a laser). | P2 (DXF e PLT são diferenciais) |
| PSD, CPT, RAW, JP2 | Bitmaps com camadas. | P2 |
| WMF / EMF, CGM, WPG, VSD, PUB, DOC/DOCX/RTF, WPD | Legados e de escritório. | P2 |
| TTF / PFB | Exporta fontes. | P2 |

### 1.12 Observações sobre atalhos (*)

- `Ctrl+L` combina objetos, mas com texto selecionado alinha o texto à esquerda. O mesmo vale para `Ctrl+E`, `Ctrl+R`, `Ctrl+J` e `Ctrl+H` no modo de texto. `Ctrl+J` fora do texto abre Options.
- Os atalhos de encaixe mudaram com as versões. Em X4/X5 eram `Alt+Z` (snap a objetos), `Ctrl+Y` (grade) e `Alt+Shift+D` (guias dinâmicas). No 2017+ vieram `Alt+Q` (snap off), `Alt+Y` (grade), `Alt+Shift+A` (alignment guides) e `Ctrl+Shift+H` (smart snapping).
- `Ctrl+M` é marcadores no texto e mesclar células na tabela.
- Teclas de uma letra (`L R T B C E P`, `X`, `Y`, `D`, `A`, `G`, `M`, `I`, `S`, `Z`, `H`) só funcionam fora da edição de texto. **Nosso editor precisa do mesmo cuidado**: atalhos de uma tecla ficam desativados quando um campo de texto ou o texto no canvas tem o foco.
- Grupos numerados: `Ctrl+0..9` define o grupo, `Alt+0..9` adiciona a ele e `0..9` o seleciona.
- Zoom: `F4` ajusta a todos os objetos, `Shift+F4` à página, `Shift+F2` à seleção. `Ctrl+=` aproxima e `Ctrl+-` afasta. `F2` e `F3` (zoom in e out) são antigos e variam.

---

## 2. Referências de UI/UX

### 2.1 Graphite (graphite.art)

Editor vetorial e raster procedural, em Rust com WebAssembly e WebGPU, ainda em alfa. **É a referência de acabamento visual.** Os valores abaixo vêm do código-fonte (`frontend/src/components/*.svelte`, `editor/src/consts.rs`) e da documentação "Learn > Interface".

**Layout da janela, de cima para baixo**
1. **Barra de título** com o menu (File, Edit, Layer, Select, View, Help) à esquerda e os botões da janela à direita.
2. **Workspace** dividido em painéis com divisores arrastáveis:
   - **Document**, que ocupa a maior parte da janela. Tem abas de documento, e um `*` marca o arquivo não salvo.
   - À direita, empilhados: **Properties/Inspector** em cima e **Layers** embaixo.
3. Dentro do painel Document:
   - **Control bar** de 32 px de altura. À esquerda ficam as opções da ferramenta ativa. Para o Select, isso inclui o modo de seleção, o ponto central do gizmo, alinhar, distribuir, espelhar e os booleanos. À direita ficam os controles da vista: Overlays, Snapping com um popover de opções finas, Grid, Render Mode (Normal ou Outline), Zoom −/+, o botão "100%", um campo numérico de zoom e o toggle do Node Graph (`Ctrl+Space`).
   - **Tool shelf** vertical à esquerda, com botões de 32 px. As colunas se adaptam: se a altura não cabe, a coluna vira 2 ou 3. Os ícones são coloridos por categoria: ferramentas gerais em cinza, vetoriais em azul `#65bbe5` e raster em laranja `#e4bb72`. Separadores dividem os grupos. Embaixo ficam as **cores de trabalho**, com primária e secundária em círculos sobrepostos e os botões Swap e Reset.
   - **Viewport** com réguas no topo e à esquerda e barras de rolagem embaixo e à direita.
4. **Barra de status** de 24 px, só com **dicas de entrada** contextuais da ferramenta e do estado atual.

**Barra de status com dicas (o padrão "Select Object · Shift Extend · Ctrl Deepest")**
- As dicas são estruturas (`HintGroup` de `HintInfo`), não texto solto. Cada dica tem um ícone de mouse (LMB, RMB, MMB, clique duplo, arrasto, rolagem) ou rótulos de tecla desenhados como "teclas", seguidos de um texto curto.
- Para o Select em repouso, o código gera: `[LMB] Select Object` `+[Shift] Extend` `+[Ctrl] Deepest` `[LMB×2] Deepen` | `[LMB-drag] Select Area` `+[Shift] Extend` `+[Alt] Subtract` `+[Ctrl] Lasso` | `[LMB-drag] Drag Selected` | `[G][R][S] Grab/Rotate/Scale Selected` | `[setas] Nudge Selected` `+[Shift] 10x` …
- Durante o arrasto, as dicas mudam para `[RMB] / [Esc] Cancel` e `[Shift] Constrain to Axis`. Na rotação aparece `[Shift] 15° Increments`, e na escala `[Alt] From Pivot` e `[Shift] Preserve Aspect Ratio`.
- Convenções: `+` antes de um modificador significa "segure junto para modificar a ação". `/` significa "qualquer um dos dois faz a mesma coisa". Os grupos são separados por 12 px. Os textos ficam a 4 px uns dos outros. O rótulo em negrito tem padding de 0 4px.
- Quando as dicas não cabem, um **degradê de 40 px** as esconde na borda, em vez de cortá-las.
- Os atalhos têm variante para Mac (`add_mac_keys`): Ctrl vira Cmd automaticamente.

**Tema escuro (tokens exatos)**
- A paleta é uma escala de cinzas em 16 passos: `#000 #111 #222 #333 #444 #555 … #eee #fff`, com nomes como `--color-1-nearblack`, `--color-2-mildblack`, `--color-3-darkgray`.
- Fundo da aplicação e do viewport: `#222`. Corpo dos painéis: `#333`. Aba e barra de abas: `#111`. Linha selecionada: `#444`. Hover de botão: `#555`. Texto: `#eee`. Texto desabilitado e números de régua: `#888`.
- Painéis com `border-radius: 6px`, separados por um gutter que mostra o fundo `#111`. A aba ativa tem cantos de 6px e "filetes" côncavos de 8 px que a fundem ao corpo.
- Tipografia: Source Sans Pro a **14px**, com line-height 1. Nas réguas, 12px.
- Botões de ícone com raio de 2px e tamanhos 12, 16, 24 e 32. Um botão "enfatizado" (ferramenta ativa) tem fundo `#eee` e ícone `#222`, invertido.
- Scrollbar fina, em `#444` sobre fundo transparente. O foco por teclado aparece como contorno tracejado de 1px.
- Cores semânticas: erro `#d6536e`, aviso `#d5aa43`. Tipos de dado: vetor `#65bbe5`, gráfico `#68c587`, raster `#e4bb72`, cor `#ce6ea7`, gradiente `#af81eb`, tipografia `#eea7a7`, artboard `#fbf9eb`.
- Checkerboard de transparência em `#ccc` e `#fff`, com células de 8 px (16 px de período), ou 4 px na versão mini. "Nenhuma cor" é desenhada como um traço diagonal vermelho.

**Canvas e overlays**
- O viewport tem fundo `#222`, e a artboard aparece como um retângulo claro sobre ele.
- Réguas de **16 px** de espessura com fundo `#222` e borda `#555`. Os traços têm três tamanhos: principal de 16 px, menor de 6 px e micro de 3 px. Os números ficam em `#888` a 12px. A régua marca a extensão da seleção com uma linha e pontas de 5 px com borda `#00a8ff`. O canto entre as réguas é um quadrado de 16 px.
- Overlays em **azul `#00a8ff`**, também a 50%, 25% e 5% de alfa. Amarelo `#ffc848` marca hover e destaque, verde `#63ce63` e vermelho `#ef5454` marcam medidas e estados.
- Alças de redimensionamento de **6 px**, área de clique de 10 px e zona de rotação a 20 px fora da caixa. O triângulo de inclinação tem 7 px.
- Nós de caminho (manipulator) de 6 px. Tolerância de seleção de 10 px. As alças se escondem quando ficam a menos de 3 px do nó.
- Snap com tolerância de **5 px** de tela. As alças giram em passos de 15°.
- Nudge de 1 unidade, ou 10 com `Shift`. Limiar de arrasto de 1 px. Rotação em passos de 15°.
- Os **níveis de zoom** são uma tabela fixa com 74 passos: … 25%, 33%, 40%, 50%, 66%, 80%, 100%, 125%, 160%, 200%, 250%, 320%, 400% …, de 0,01% a 256000%. "Zoom to fit" usa 95% da área. A vista pode ser inclinada (tilt) em passos de 15°.

**Painel de camadas**
- Linhas de **32 px** com 4 px de margem lateral, uma divisória de 1 px em `#222` e raio de 2px. A linha selecionada fica em `#444`.
- Cada linha tem: a seta de expandir (16 px de largura, com recuo de **16 px por nível**), uma **miniatura de 36×24 px** sobre checkerboard mini, o nome, um cadeado quando o objeto está travado e o **olho** de visibilidade.
- Padrões pontilhados sutis marcam os ancestrais e os descendentes da seleção. É uma pista visual elegante para hierarquias.
- O painel tem uma barra superior de 32 px (modo de mesclagem e opacidade) e uma barra inferior de 24 px (nova pasta, apagar etc.).

### 2.2 Inkscape (inkscape.org)

É o editor livre de referência (GTK). Funcionalmente é o mais próximo do CorelDRAW.

**Layout da janela**
- **Barra de menus** no topo. Logo abaixo fica a **barra de controles da ferramenta**, que é contextual e equivale à Property bar do Corel.
- **Caixa de ferramentas vertical** à esquerda, com ícones simbólicos monocromáticos. As ferramentas de forma ficam agrupadas.
- **Barra de comandos** à direita (ou no topo, em telas largas), com Novo, Abrir, Salvar, Importar e Exportar, e um botão de **snap** que é um ímã com popover. No 1.3 o snap ganhou uma barra persistente opcional.
- **Área de docking** à direita, onde os diálogos abrem como abas: Fill and Stroke, Layers and Objects, Align and Distribute, Transform, Text and Font, XML Editor. Os diálogos podem flutuar ou ser recolhidos em ícones.
- **Paleta de cores** horizontal na base. Clique define o preenchimento e `Shift`+clique define o contorno.
- **Barra de status**, da esquerda para a direita:
  - Indicador de preenchimento e contorno do objeto selecionado (amostras F/S e espessura).
  - Seletor de camada.
  - **Área de mensagens**: descreve a seleção ("Path 4 nodes in layer Layer 1") e mostra dicas de modificadores da ferramenta, como "**Shift**: click to toggle select; **Ctrl**: …".
  - À direita: coordenadas X/Y do cursor, zoom e rotação da vista.
- A barra de status com dicas é um equivalente mais verboso do que o Graphite faz com ícones.

**Canvas**
- A página é um retângulo branco com borda e **sombra** sobre a "mesa" (desk). Desde o 1.2, a cor da mesa é configurável e há opção de **checkerboard**. Objetos fora da página continuam visíveis.
- Desde o 1.2, há **várias páginas** com a ferramenta Page. No 1.3, margens e sangria passaram a funcionar como alvos de snap.
- Réguas no topo e à esquerda. Arrastar a partir da régua cria uma guia. Grades retangular, axonométrica e modular.
- `5` ajusta a página à janela, `3` ajusta o desenho, `1` mostra 100%. A rotação do canvas é feita com `Ctrl+Shift+roda`.

**Seleção (ferramenta Selector, `S`)**
- A caixa delimitadora é **tracejada**. Há 8 alças em forma de **setas duplas** para escala.
- Clicar de novo no objeto troca para o modo de **rotação e inclinação**: setas curvas nos cantos, setas de inclinação nos lados e uma cruz móvel no centro de rotação. É o mesmo comportamento do CorelDRAW e funciona como "duas camadas de alças" sem poluir a tela.
- `Alt`+clique seleciona o objeto de baixo. `Ctrl`+clique entra no grupo. `Alt`+arrastar faz uma seleção "por toque" (desenha um traço e seleciona o que ele cruza).

**Edição de nós (ferramenta Node, `N`)**
- Formas dos nós: **losango** para cusp (canto), **quadrado** para smooth e **círculo** para auto-smooth. As alças terminam em pequenos círculos.
- Nós selecionados ganham destaque de cor e o nó sob o cursor também muda de cor. O Inkscape 1.4 deixa personalizar as cores das alças via CSS.
- A barra de controles tem: inserir nó, apagar, juntar, quebrar, juntar com segmento, apagar segmento, tornar cusp, smooth, simétrico ou auto-smooth, tornar linha ou curva, objeto para caminho e contorno para caminho.
- Atalhos: `Shift+C` cusp, `Shift+S` smooth, `Shift+Y` simétrico, `Shift+A` auto, `Ctrl+Alt+clique` insere ou apaga um nó, arrastar um segmento curva o segmento, `Ins` insere nós no meio dos segmentos.
- No 1.3, `Alt`+arrasto seleciona nós com um traço livre, e apagar um nó **reajusta a curva** para preservar a forma.

**Painel Layers and Objects (1.2+)**
- Uma árvore única de camadas e objetos. Cada linha tem o **olho** e o **cadeado** à esquerda do nome, além de uma cor de destaque por camada.
- No 1.3, **arrastar verticalmente sobre os olhos ou cadeados** liga ou desliga todos os itens tocados. Esse microdetalhe é ótimo para copiar.
- Opacidade e modo de mesclagem ficam num popover por linha. A navegação por teclado usa as setas, e `Shift`+setas reordena.

**Outros pontos que fazem o Inkscape parecer polido**
- Shape Builder (1.3): arrastar sobre as regiões sobrepostas faz a união, e as regiões não tocadas são descartadas. É um booleano visual muito mais intuitivo que Weld e Trim.
- Command Palette (`?`): busca de qualquer comando por nome.
- Tema escuro do GTK e um tema de ícones simbólicos. No Windows, a barra de título segue o tema claro ou escuro.

### 2.3 SVG-Edit (github.com/SVG-Edit/svgedit)

- É um editor SVG em JavaScript que roda no navegador, com cerca de 7,9 mil estrelas. A versão 7 é a recomendada.
- **Arquitetura em dois pacotes**: `@svgedit/svgcanvas` é o motor de edição, sem UI e reutilizável, e o `editor` é a UI (menus e botões). Tem um sistema de **extensões** (`extensions`, `userExtensions`), com exemplo em React.
- **Lição de arquitetura**: manter o "canvas/engine" separado da camada de UI. O VectorCraft faz o mesmo.
- UI observada na demo (não descrita no README): ferramentas à esquerda (seleção, lápis, linha, retângulo e quadrado, elipse e círculo, caminho, texto, imagem, zoom, conta-gotas, biblioteca de formas). Painel contextual no topo com x, y, largura, altura, rotação, desfoque e opacidade. Painel de camadas recolhível à direita. Na base: preenchimento e contorno, espessura, estilo de tracejado e paleta. O **modelo de dados é o próprio DOM SVG**, então o que você vê é o que é exportado.

### 2.4 VectorCraft (github.com/storytold/vectorcraft)

- Editor vetorial em **Rust puro**, com a UI em **egui** num crate separado ("a UI pode ser trocada sem tocar no motor"). Renderização multithread com SIMD, fora da thread de UI. O README afirma que a interface fica a 120 fps com 20 mil formas.
- Copia o **layout, as ferramentas, os menus, os painéis e os atalhos do Illustrator**: Pen, Direct Selection, Pathfinder, Shape Builder, Smart Guides, painéis Appearance, Swatches e Layers, além de várias pranchetas (artboards).
- Os booleanos são calculados de forma exata sobre as curvas, e não em polígonos aproximados.
- Os Blends são "ao vivo", com caminhos-chave editáveis. Há grade de perspectiva.
- **Contextual task bar**: uma barra flutuante abaixo da seleção, durante a edição direta, com as ações mais prováveis.
- O painel Layers mostra **cada objeto como uma linha**.
- Formatos: JSON nativo (`.vectorcraft`), SVG, PDF e `.ai` compatível com PDF (importa e exporta), e PNG, JPEG e WebP (só exporta). Tema claro. Interface em vários idiomas.
- Todo comando pode ser acionado por um canal JSON ou MCP (automação e agentes). **Ideia aplicável**: um registro central de comandos com ID também serve à paleta de comandos, aos atalhos, aos menus e à automação.
- Crates: `geom`, `pathops`, `text`, `render`, `svg`, `pdf`, `mcp`. É uma boa referência de divisão em módulos.

### 2.5 Corel-Draw-Clone (github.com/ravirajawat07/Corel-Draw-Clone)

- Não é um editor. É um **clone da landing page** do site da CorelDRAW em HTML e CSS (`index.html`, `style.css`, imagens de hero e logos de clientes), com um único commit e sem README.
- **Não serve como referência de UX do editor**. No máximo serve para identidade visual de marketing, e copiar a marca da Corel não é desejável.

### 2.6 Síntese: decisões de UI recomendadas para o nosso editor

| Área | Recomendação | Inspiração |
|---|---|---|
| Layout | Menu no topo. Barra de propriedades contextual de 32 px logo abaixo. Toolbox vertical à esquerda, com botões de 32 px e flyouts para agrupar. Viewport central com réguas de 16 px. Docker à direita com Propriedades em cima e Camadas embaixo, redimensionáveis. Barra de status de 24 px. | Corel, Graphite, Inkscape |
| Tema | Escala de cinzas em 16 passos como tokens. App `#222`, painéis `#333`, aba e gutter `#111`, seleção `#444`, hover `#555`, texto `#eee`, desabilitado `#888`. Fonte de 14px na UI e 12px nas réguas. Raio de 6px nos painéis e 2px nos botões. | Graphite |
| Cor de destaque | Uma única cor de overlay, `#00a8ff`, para seleção, alças, guias inteligentes e snap. Amarelo `#ffc848` para hover. | Graphite |
| Canvas | Página branca centralizada sobre fundo neutro escuro, com sombra sutil. "Ajustar à janela" com 95% da área ao abrir. Objetos fora da página continuam visíveis. Checkerboard opcional (8 px, `#ccc`/`#fff`). | Inkscape, Graphite |
| Zoom | Tabela fixa de níveis "redondos" com `Ctrl+=` e `Ctrl+-`. A roda do mouse com `Ctrl` faz zoom no ponto do cursor. Campo numérico na barra. Atalhos de ajuste: `F4` (tudo) e `Shift+F4` (página), ou `5` e `3` como no Inkscape. | Graphite, Corel |
| Seleção | Caixa com 8 alças de 6 px (quadrados brancos com borda azul). Um segundo clique entra no modo rotação e inclinação. Rotação também perto dos cantos, a 20 px fora, com cursor próprio. | Corel, Inkscape, Graphite |
| Nós | Quadrado para cusp, círculo para smooth e losango para simétrico (padrão do Corel), em 6 px. Alças finas com ponta circular. Selecionado = preenchido em azul. Hover = amarelo. | Corel, Graphite |
| Barra de status | Dicas estruturadas por estado: `[ícone do mouse] Ação · +[Shift] Modificador`. Coordenadas do cursor e zoom à direita. Degradê de 40 px quando não cabe. | Graphite |
| Camadas | Linhas de 32 px, miniatura de 36×24 sobre checkerboard, recuo de 16 px por nível, olho e cadeado. Arrastar sobre os olhos alterna vários de uma vez. Arrastar a linha reordena. | Graphite, Inkscape |
| Comandos | Registro central de comandos (ID, rótulo, atalho Win e Mac, habilitado(ctx)) que alimenta menus, barra, atalhos, paleta de comandos e dicas. | VectorCraft, Inkscape |
| Atalhos | Usar o mapa do CorelDRAW (é o diferencial do produto) com `Cmd` no Mac. Teclas de uma letra desativadas enquanto um campo de texto tem o foco. | Corel |

---

## 3. O que um editor mínimo decente precisa (top 25, em ordem)

1. **Modelo de documento e render vetorial**: caminhos Bézier (cúbicos e quadráticos), retângulo, elipse, grupo e texto, com preenchimento sólido e contorno (espessura, junção, terminação). Página com tamanho e unidades. Antialiasing de qualidade na GPU.
2. **Canvas navegável**: pan (`Space` ou botão do meio, `H`), zoom com a roda no ponto do cursor, `Ctrl+=` e `Ctrl+-`, e ajustar à página, à seleção e a tudo (`Shift+F4`, `Shift+F2`, `F4`).
3. **Ferramenta Pick**: clique, `Shift`+clique, marquee, mover, escalar com 8 alças (`Shift` a partir do centro, proporção travada), girar e inclinar no segundo clique, `Esc` e `Delete`.
4. **Desfazer e refazer** robustos para toda operação (`Ctrl+Z` e `Ctrl+Shift+Z`), com arrastos agrupados numa só entrada.
5. **Retângulo (`F6`) e elipse (`F7`)**, com `Ctrl` para quadrado e círculo, `Shift` para desenhar do centro e cantos arredondados no retângulo.
6. **Caneta e Bézier**: clique cria um nó de canto, arrastar cria um nó suave, fechar no primeiro nó, `Enter` ou `Esc` termina.
7. **Ferramenta Shape (`F10`)**: mover nós, alças e segmentos, adicionar e remover nós (duplo clique), tipos cusp, smooth e simétrico (`C`, `S`), linha ↔ curva, quebrar e juntar.
8. **Converter em curvas (`Ctrl+Q`)** para formas paramétricas e texto.
9. **Preenchimento e contorno**: paleta de cores clicável (clique esquerdo = preenchimento, direito = contorno), seletor de cor (HSV, hexadecimal, alfa), espessura, tracejado e "nenhum".
10. **Barra de propriedades contextual**: X, Y, L, A, rotação, cadeado de proporção, espelhar H e V, e as opções da ferramenta ativa, tudo com edição numérica.
11. **Ordem de empilhamento**: `Ctrl+PgUp`, `Ctrl+PgDn`, `Shift+PgUp` e `Shift+PgDn`.
12. **Agrupar e desagrupar** (`Ctrl+G` e `Ctrl+U`), com seleção dentro do grupo por `Ctrl`+clique.
13. **Área de transferência e duplicação**: `Ctrl+C`, `Ctrl+X`, `Ctrl+V`, `Ctrl+D` duplicar com deslocamento, duplicar ao arrastar com o botão direito ou `Space`, e o `+` do numpad.
14. **Salvar e abrir num formato nativo** (sugestão: JSON ou binário versionado) e **exportar e importar SVG**.
15. **Exportar PNG**, com escala ou DPI, só a seleção ou a página, e fundo transparente.
16. **Painel de Objetos e Camadas**: árvore com miniaturas, olho, cadeado, renomear, reordenar arrastando, várias camadas.
17. **Alinhar e distribuir**: teclas `L R T B C E P` e o docker com a referência (seleção, último selecionado ou página).
18. **Booleanos**: Weld (união), Trim (subtração), Intersect. Também Combine e Break apart (`Ctrl+L` e `Ctrl+K`) com regra par-ímpar ou nonzero.
19. **Snapping**: a nós, centros, bordas e pontos médios dos objetos, à página, às guias e à grade. Indicador visual do alvo e liga/desliga rápido (`Alt+Q`).
20. **Réguas e guias**: réguas com unidades, guias arrastadas a partir da régua, grade configurável.
21. **Texto artístico (`F8`)**: fonte, tamanho, negrito, itálico, alinhamento e edição no canvas com cursor. Converter texto em curvas.
22. **Nudge pelo teclado** (setas, com `Shift` e `Ctrl` mudando o passo) e o **docker Transform** (posição, rotação, escala e tamanho exatos, com ponto de referência 3×3 e cópias).
23. **Gradientes linear e radial** editáveis no canvas (Interactive fill, `G`), com nós de cor arrastáveis.
24. **Transparência (opacidade) por objeto** e sombra projetada simples.
25. **Barra de status com dicas contextuais e coordenadas**, mais um registro central de comandos e atalhos (menus completos, atalhos personalizáveis, mapeamento `Cmd` no Mac).

**Logo depois do top 25:** polígono e estrela (`Y`), conta-gotas, texto de parágrafo, texto em caminho, PowerClip (máscara de recorte), várias páginas, exportar PDF, Reduce nodes, Contour, Blend, Shape Builder, Trace bitmap.

---

## Fontes

- Ajuda oficial do CorelDRAW, "Workspace tools": https://product.corel.com/help/CorelDRAW/540240626/Main/EN/Doc/CorelDRAW-CorelDRAW-workspace-tools.html
- Ajuda oficial do CorelDRAW, "Exploring the toolbox": https://product.corel.com/help/CorelDRAW/540227992/Main/EN/Documentation/CorelDRAW-Exploring-the-toolbox.html
- Ajuda oficial do CorelDRAW, "Supported file formats": https://product.corel.com/help/CorelDRAW/540227992/Main/EN/Documentation/CorelDRAW-Supported-file-formats.html
- Ajuda oficial do CorelDRAW, "Snapping objects": https://product.corel.com/help/CorelDRAW/540240626/Main/EN/Doc/CorelDRAW-Snapping-objects.html
- Ajuda oficial do CorelDRAW, "Node types" (Mac): https://product.corel.com/help/CorelDRAW/Documentation-Mac/CorelDRAW-en/CorelDRAW-Node-types.html
- Ajuda oficial do CorelDRAW, "Shaping objects" e "Trim": https://product.corel.com/help/CorelDRAW/540238885/Main/EN/Documentation/CorelDRAW-Shaping-objects.html
- Tutorial da Corel sobre as ferramentas de modelagem: https://learn.corel.com/tutorials/coreldraw-shaping-tools/
- Lista de atalhos (referência compilada): https://lzw.me/x/reference/docs/coreldraw.html
- Comunidade CorelDRAW, lista de atalhos: https://community.coreldraw.com/collaborate/w/howto/8/complete-list-of-keyboard-shortcuts e https://community.coreldraw.com/collaborate/w/howto/336/corel-draw-keyboard-short-cut
- Wikipedia, CorelDRAW: https://en.wikipedia.org/wiki/CorelDRAW
- Graphite, site e documentação: https://graphite.art/ , https://graphite.art/learn/interface/ , https://graphite.art/learn/interface/document-panel/
- Código-fonte do Graphite (tokens, status bar, camadas, réguas e constantes): https://github.com/GraphiteEditor/Graphite (`frontend/src/components/Editor.svelte`, `window/StatusBar.svelte`, `window/Panel.svelte`, `panels/Layers.svelte`, `panels/Document.svelte`, `widgets/inputs/RulerInput.svelte`, `editor/src/consts.rs`, `editor/src/messages/tool/tool_messages/select_tool.rs`)
- Manual do Inkscape, interface: https://inkscape-manuals.readthedocs.io/en/latest/interface.html
- Notas de versão do Inkscape 1.3: https://wiki.inkscape.org/wiki/Release_notes/1.3
- SVG-Edit: https://github.com/SVG-Edit/svgedit
- VectorCraft: https://github.com/storytold/vectorcraft
- Corel-Draw-Clone: https://github.com/ravirajawat07/Corel-Draw-Clone

**Ressalvas**
- Os atalhos marcados com (*) variam entre versões. Os demais conferem entre a ajuda oficial e pelo menos duas listas da comunidade.
- Detalhes do Inkscape sem fonte citada (formas de nó, atalhos `Shift+C/S/Y/A`, zoom `1/3/5`) vêm do comportamento conhecido do 1.x.
- A descrição da UI do SVG-Edit vem da demo, porque o README não a descreve.
