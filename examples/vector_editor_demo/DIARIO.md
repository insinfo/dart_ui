# Diário de sessões

Uma entrada por sessão, a mais recente no fim. Data, o que mudou, o que ficou
pela metade e o próximo passo. Ver `AGENTS.md`.

## 13/10/2026

**Mudou**
- O editor virou um projeto Dart completo (`pubspec`, `bin/`, `lib/src/engine`,
  `lib/src/ui`, `test/`, `tool/`). Nenhum teste da raiz depende dele.
- Tudo é um comando: cerca de 80 comandos no `CommandRegistry` do framework,
  com parâmetros declarados. Menus, menus de contexto, barra padrão, caixa de
  ferramentas, paleta, abas e painel Objetos agem por ele.
- Canal de controle (`--control <porta>`) com `package:dart_ui/automation.dart`;
  `tool/control_probe.dart` desenha, inspeciona, captura e salva só por ele.
- Paridade medida: `tool/parity.dart` gera `doc/paridade.md`. Primeira medida:
  23% no total, 52% das P0.
- Converter em curvas, inclusive texto (contornos dos glifos).

**Ficou pela metade**
- Os painéis de propriedades (Transform, Align, Fill & Outline) e a barra de
  propriedades ainda chamam o modelo direto, e não `registry.execute`.
- Auditoria de sala limpa do código que cita o sK1.

**Próximo passo**
- P0 que faltam, em ordem: edição de nós (F10), Combine/Break apart,
  booleanos (Weld/Trim/Intersect), teclas de alinhamento (L R T B C E P),
  Esc para desselecionar, Mão livre (F5), Propriedades (Alt+Enter).

### Mais tarde, no mesmo dia

**Mudou**
- Teclas de alinhamento do CorelDRAW (L R T B C E P), Esc para desselecionar,
  `object.distribute`. Quando dois comandos dividem uma tecla, o habilitado
  vence (B: alinhar embaixo com seleção, Caneta sem).
- Combinar (Ctrl+L) e Separar (Ctrl+K).
- Framework: `FillRule` único (em `geometry`); o do modelo vetorial era
  escondido do público, e nenhum app conseguia escolher a regra de um objeto.
- P0 em 65% (27% no total).

**Próximo passo**
- Edição de nós (F10) é a maior P0 que falta: adicionar, apagar, mover nós e
  segmentos, linha/curva, tipos de nó, juntar/quebrar.
- Booleanos (Soldar, Aparar, Interseção), Mão livre (F5), Propriedades
  (Alt+Enter), e os painéis de propriedades passando pelo registro.


## 13/10/2026

**Mudou**
- Ferramenta Forma (F10) e edição de nós. No framework, `NodeEditing`
  trabalha nas coordenadas locais da curva: mover nós e alavancas (suave e
  simétrico mantêm a restrição), inserir (de Casteljau), apagar, linha/curva,
  tipo do nó, quebrar, unir, inverter, fechar. `ShapeToolController` cuida dos
  gestos: clicar e arrastar nós, Shift para somar, banda, duplo clique no
  segmento para adicionar e no nó para remover.
- Módulo `node_commands`: `path.*` no menu Paths, um passo de desfazer por
  comando. Delete apaga os nós escolhidos sob a Forma e o objeto fora dela.
- `MenuBar.f10Activates: false`: o F10 fica com a aplicação, e Alt continua
  abrindo a barra.
- P0 em 76% (33% no total).

**Ficou pela metade**
- Arrastar um segmento (sem passar pelos nós) e mover nós com as setas.
- Barra de propriedades da Forma (os comandos existem, mas não há botões).

**Próximo passo**
- Booleanos (Soldar, Aparar, Interseção), Mão livre (F5), Propriedades
  (Alt+Enter), arrastar segmento e mover nós com as setas.

### Mais tarde, no mesmo dia

**Mudou**
- Arrastar segmento (pesos do Inkscape: o ponto agarrado fica sob o cursor)
  e setas movendo os nós escolhidos sob a Forma.
- Framework: `PathBoolean`, booleanas que mantêm as Béziers (paper.js):
  intersecções por subdivisão, trechos coincidentes tratados à parte,
  classificação por winding exato um fio de cada lado de cada pedaço. Teste
  de propriedade com 12 mil pontos em formas aleatórias, sem divergência.
- Soldar, Aparar e Interseção (`shaping_commands`), com o alvo sendo o último
  selecionado, como no CorelDRAW.
- Framework: `CurveFitting` (Schneider) e `FreehandToolController`; Mão
  livre (F5) com suavização.
- Framework: `CommandIconButton`. A barra de propriedades passou a usar
  comandos nos botões de nós, de modelagem e de agrupar; o plugin antigo de
  Combinar ainda dizia "not implemented".
- P0 em 87% (36% no total).

**Ficou pela metade**
- Os campos numéricos da barra (posição, tamanho, rotação) ainda chamam o
  modelo direto.
- A barra de curvas não tem setas nem estilo de linha.

**Próximo passo**
- Propriedades (Alt+Enter), barras de Texto e de Zoom, alças de canto de
  formas paramétricas, guias arrastadas da régua.

### 13/10/2026, à noite

**Mudou**
- Barra da ferramenta Zoom: níveis, aproximar, afastar, seleção, página, e
  os novos `view.zoomPageWidth` e `view.zoomPageHeight`.
- Ctrl (Cmd no Mac) gira em passos de 15°, como no CorelDRAW; o movimento
  com Ctrl num eixo só ganhou o teste que faltava.
- Framework: `ParametricHandles`. A Forma (F10) num retângulo mostra um nó
  por canto, onde o arredondamento começa; arrastar arredonda todos, e com
  Ctrl só aquele. Numa elipse, arrastar o nó para dentro faz pizza e para
  fora faz arco. Um passo de desfazer por arraste.
- Cenário `corners` na captura headless.
- P0 em 93%: nenhuma falta por inteiro (54 feitas, 9 parciais).

**Próximo passo**
- Pontas, junções e tracejado do contorno no canvas (precisa do formato de
  pintura), guias arrastadas da régua, barra de Texto (fonte, estilo,
  alinhamento) e texto de parágrafo.

### 13/10/2026, madrugada

**Mudou**
- Contorno desenhado com pontas, junções e tracejado (framework: o traço
  completo na DisplayList, CPU, GPU e D2D); pontas de seta (ArrowHead) e a
  barra de linha da curva.
- Guias: arrastadas das réguas, movidas pela Seleção, apagadas soltando na
  régua; guide.add/move/delete/clear.
- Texto: fonte, negrito, itálico e alinhamento, desenhados e medidos com a
  mesma face; VectorTextAlign deixou de ser escondido dos barris.
- Preenchimento gradiente (linear e radial) por comando e no painel.
- Selecionar tudo por tipo, Localizar e substituir texto (o primeiro
  diálogo do editor, pelo showDialog do framework), frente e fundo da
  página, shape.curve.
- P0 em 96%.

**Ficou pela metade**
- Texto de parágrafo (moldura com quebra de linha), pena caligráfica,
  preenchimentos de padrão e textura, Limpar transformações, Colar especial.

**Próximo passo**
- Texto de parágrafo é a maior P0 que resta.

