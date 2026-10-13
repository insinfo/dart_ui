# Modo imediato

Estado em 12/10/2026. Código em `lib/src/immediate/`, API pública em
`package:dart_ui/immediate.dart`, demo em `example/immediate_demo.dart`.

## O que é

O dart_ui é de modo **retido**: a interface é uma árvore de widgets que o
framework guarda e atualiza. O modo **imediato** (o de egui e Dear ImGui) é o
contrário: a interface é código que roda a cada quadro, e o retorno de cada
controle diz o que o usuário fez nele naquele quadro.

```dart
import 'package:dart_ui/immediate.dart';

var brilho = 0.0;
var nome = '';

void main() => runImmediateApp((Ui ui) {
      ui.heading('Ajustes');
      brilho = ui.slider('Brilho', brilho, min: -1, max: 1);
      nome = ui.textField(nome, hint: 'Nome');
      if (ui.button('Aplicar')) aplicar(nome, brilho);
    });
```

O estado são as variáveis do programa. Não há `setState`, controller nem árvore
para sincronizar.

## Quando usar cada um

| Modo imediato | Modo retido (widgets) |
|---|---|
| painéis de ferramentas com muitas opções que mudam (filtros, pincéis) | telas de formulário e apps de negócio |
| inspetores e painéis de depuração | acessibilidade completa (árvore estável de nós) |
| protótipos e jogos | layout sofisticado (flex, grid, duas passadas) |
| interfaces que mudam a cada quadro | animações e transições |

Os dois convivem: `ImmediateArea(builder: …)` é um widget, então um painel
imediato entra em qualquer tela retida, e `runImmediateApp` é só
`runApp(ImmediateArea(…))`.

## Como funciona

- **Um render object** (`RenderImmediate`) hospeda a área. A entrada que o
  roteador entrega — ponteiro, roda, teclas, texto — fica numa fila; na pintura,
  o código do usuário roda contra essa entrada e desenha direto na
  `DisplayList` do quadro. Backends, laço de eventos, fontes e temas são os do
  framework.
- **Memória entre quadros** (`ImmediateMemory`): só o que precisa sobreviver —
  o controle sob o ponteiro (*hot*), o pressionado (*active*), o campo com o
  teclado (*focused*), o deslocamento de cada área de rolagem, se uma seção está
  aberta, o tamanho de um painel no quadro anterior. A chave é um id derivado do
  rótulo e do lugar no código (`ui.idFor(key)`); dois controles com o mesmo
  rótulo na mesma região precisam de `key:`.
- **Desenho sob demanda:** um quadro só é desenhado quando chega entrada ou um
  controle pede (`ui.requestRepaint()`, um valor arrastado, um painel que mudou
  de tamanho). Depois de qualquer entrada vem **um** quadro a mais, para os
  controles desenhados antes da mudança a mostrarem. Parado, não desenha nada —
  testado em `test/immediate/immediate_area_test.dart`.
- **Clique como em toda plataforma:** conta ao soltar sobre o controle que foi
  pressionado; arrastar para fora antes de soltar cancela.
- **Mesmas formas dos widgets:** os controles imediatos leem o mesmo
  `ThemeData`, inclusive o `ControlStyle`: com `ThemeData.materialLight` o switch
  é o do Material 3, com `ThemeData.cupertinoLight` é o do iOS.
  `ui.themed(tema, …)` troca o tema de um trecho.

## Controles

`label`, `heading`, `separator`, `button`, `checkbox`, `radio`, `toggle`,
`slider`, `progress`, `textField`; organização com `horizontal`, `vertical`,
`indent`, `space`, `panel`, `collapsing`, `scrollArea`, `themed`; janelas
flutuantes com `window`; e as peças
para controles próprios: `allocate(Size)` reserva espaço, `interact(rect, id)`
devolve hover, pressão, clique e arraste, `canvas` é a `DisplayList`.

## Limites atuais

- **Acessibilidade:** a área inteira é um nó genérico; um quadro imediato não
  guarda nós por controle entre quadros.
- **Texto:** campo de uma linha com cursor (setas, Home, End, clique),
  seleção (Shift, arraste, Command/Control+A), Backspace, Delete e rolagem
  horizontal; ainda sem copiar e colar nem pré-edição de IME.
- **Painéis** desenham o fundo com o tamanho do quadro anterior; a mudança
  aparece no quadro seguinte, que eles mesmos pedem.
- **Janelas flutuantes** (`ui.window`) arrastam pela barra de título, vêm para
  a frente ao serem pressionadas e fecham pelo ×; o que está atrás de uma janela
  não recebe o clique. Redimensionam pela borda direita, pela de baixo e pelo
  canto (com um piso que nunca as faz crescer no outro eixo); redimensionada,
  a janela guarda o tamanho e rola com a roda o conteúdo que não cabe. Sem
  cursor de redimensionar: o modo imediato não troca o cursor.
