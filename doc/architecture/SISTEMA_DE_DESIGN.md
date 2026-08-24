# O sistema de design do dart_ui

Este documento é o **contrato visual** do framework: a escala de espaçamento, a
escala tipográfica, os passos de densidade, os tokens de cor, os raios, o anel
de foco e o tamanho dos ícones. Um controle novo que siga estas regras entra na
tela sem desalinhar nada; um que invente um número próprio produz exatamente o
sintoma que motivou este documento — uma janela que parece montada por três
pessoas que nunca conversaram.

Tudo aqui vive em código, em `lib/src/widgets/theme.dart`. O documento explica
**por quê**; a fonte da verdade é `ThemeData`, `ThemeDensity`, `Spacing` e
`TextTheme`. Nenhum controle do framework pode conter um número visual literal
que não venha de um destes.

O contrato é verificado por `test/widgets/theme_contrast_test.dart`, que mede
contraste WCAG par a par em todos os temas embutidos e checa que toda métrica
resolvida cai na grade de 4 px.

---

## 1. Espaçamento: a grade de 4 px

```dart
abstract final class Spacing {
  static const double hair = 2;   // correção óptica, nunca "espaço"
  static const double xs   = 4;
  static const double sm   = 8;
  static const double md   = 12;
  static const double lg   = 16;
  static const double xl   = 24;
  static const double xxl  = 32;
}
```

Uma escala, e não números livres, porque o olho lê ritmo: oito espaços de 6, 7 e
9 px parecem acidente; três de 4, 8 e 16 px parecem decisão, mesmo que o leitor
não saiba dizer por quê. `hair` é o único meio-passo e existe para correção
óptica — os 2 px que um separador recua da borda —, nunca para o espaço entre
dois controles.

**Regra dura:** toda métrica *resolvida* do tema é múltipla de 4. Isso não é
esperança: `ThemeData._onGrid` arredonda para a grade depois de aplicar a
densidade, porque densidade é uma *razão* e um tema que declarasse 34 px
resolveria 29,75 px no passo compacto — e um número fora da grade basta para
desalinhar uma barra inteira em relação à barra de cima.

## 2. Densidade: três passos, e a aplicação escolhe

`ThemeDensity` carrega métricas absolutas em vez de um multiplicador, porque os
números de que um controle precisa não são um número escalado: uma linha de
lista é mais baixa que um botão em toda densidade, e a razão entre eles não é
constante.

| passo | `controlHeight` | `rowHeight` | `controlPadding` | `gap` | para quê |
|---|---|---|---|---|---|
| `compact` | 28 | 24 | 8 | 4 | ferramenta profissional: editor vetorial, IDE, mesa de operações |
| `standard` | 32 | 28 | 12 | 8 | **padrão** — formulários, CRUD, configurações |
| `comfortable` | 40 | 36 | 16 | 12 | superfícies de apresentação, ponteiro que pode ser um dedo |

A aplicação escolhe com `ThemeData.copyWith(density: ...)`, e um tema pode já
vir com a sua: `ThemeData.fluentLight` é compacto por definição, porque é o tema
que uma ferramenta desktop escolhe.

`controlHeight` e `controlPadding` no `ThemeData` são a **base na densidade
padrão**; os getters `effective*` reaplicam a densidade e voltam para a grade:

```dart
double get effectiveControlHeight => _onGrid(controlHeight * density.scale);
double get effectiveControlPadding => _onGrid(controlPadding * density.controlPadding / 12);
double get effectiveRowHeight     => _onGrid(density.rowHeight * controlHeight / 32);
double get effectiveGap           => density.gap;
```

**Tipo não escala com densidade.** Compacto significa cromo mais apertado; se o
texto encolher junto, um tema denso vira um tema ilegível.

### Onde cada altura é usada

| altura | controles |
|---|---|
| `effectiveControlHeight` | botão, campo de texto, combo, spin box, aba, cabeçalho de grade, célula de calendário, botão de ícone (quadrado), altura de barra menos o ar |
| `effectiveRowHeight` | linha de lista, linha de árvore, linha de grade, item de menu, linha de pop-up de combo |
| `effectiveControlPadding` | recuo horizontal do conteúdo dentro de qualquer um dos acima |
| `effectiveGap` | espaço entre dois controles vizinhos numa barra ou linha de formulário |

O idioma "metade do padding" (`effectiveControlPadding / 2`), que existia em
quatro arquivos, foi eliminado: era um quarto valor de espaçamento que nenhum
token nomeava, e era por isso que a célula de uma grade tinha menos ar em volta
do texto que qualquer outro controle da janela.

## 3. Tipografia: sete papéis derivados de um número

`TextTheme` tem uma `base` e deriva os sete papéis dela. Derivar em vez de
listar é o que mantém a relação verdadeira quando o tema muda de tamanho: uma
legenda continua dois passos abaixo do corpo a 13 px e a 15 px, onde dois
literais teriam divergido.

| papel | tamanho | peso | entrelinha | para quê |
|---|---|---|---|---|
| `labelSmall` | base − 2 | 500 | 1,30 | legendas, barra de status, metadados |
| `bodySmall` | base − 1 | 400 | 1,40 | texto secundário denso |
| `bodyMedium` | base | 400 | 1,45 | **padrão** de prosa |
| `labelLarge` | base | 500 | 1,20 | rótulo de controle, botão |
| `titleSmall` | base + 1 | 600 | 1,30 | cabeçalho de painel/grupo |
| `titleMedium` | base + 2 | 600 | 1,30 | título de diálogo/seção |
| `titleLarge` | base + 8 | 600 | 1,20 | título de página |

Bases: **13 px** nos temas de desktop (`neutralLight`, `neutralDark`,
`fluentLight`, `highContrastDark`) e **14 px** nos temas `material*`.

`TextStyle.height` é multiplicador, não pixels: 20 px de entrelinha é generoso
sob 13 px e apertado sob 22 px, enquanto 1,45 é a mesma relação nos dois.

### Uma única fonte de verdade para o tamanho

`ThemeData.fontSize` é um **getter** sobre `textTheme.base`. Antes eram dois
números independentes, e o framework tinha exatamente esse bug: controles
desenhavam rótulos em `fontSize` (12) enquanto `Text` desenhava em
`textTheme.bodyMedium` (14), de modo que um botão ao lado de um rótulo
renderizava dois tamanhos de tipo na mesma linha.

### Alinhamento vertical

Rótulo dentro de controle é centrado pela **caixa tipográfica** (ascent +
descent), não pela caixa de linha. A diferença é o *line gap* da fonte, que na
maioria das famílias fica inteiramente acima do ascent: centrar a caixa de linha
empurra todo rótulo um ou dois pixels para baixo — e um ou dois pixels é
precisamente o erro que faz uma interface parecer amadora. O cálculo está em
`ControlBehavior.labelTopIn`, e o resultado é arredondado para pixel inteiro,
porque a máscara de um glifo é cacheada por *bucket* de subpixel e um rótulo em
y = 7,5 rasteriza a própria cópia de cada glifo.

## 4. Cor: superfícies, bordas, estados, acento

Hierarquia carregada pelo **degrau de superfície** primeiro; borda só onde duas
superfícies realmente se encontram. Uma linha cinza de 1 px em volta de cada
barra é o visual "Windows 95" em uma linha de código: barras empilhadas mostram
uma régua dupla de dois pixels onde se tocam, e a janela vira uma pilha de
caixas em vez de um conjunto de superfícies.

| token | papel |
|---|---|
| `surfaceBase` | a janela, e o vão entre painéis |
| `surface` | o fundo de um painel |
| `surfaceAlternate` | conteúdo sobre o painel: campo, lista, cartão, barra |
| `surfaceRaised` | o que flutua: menu, pop-up, diálogo, dica |
| `borderSubtle` | divisória *dentro* de uma superfície (entre linhas, entre grupos) |
| `border` | a aresta onde duas superfícies se encontram |
| `borderStrong` | contorno de algo em que se mira: campo, combo, botão sem preenchimento |
| `foreground` / `foregroundSecondary` | texto primário / secundário |
| `hoverSurface` / `pressedSurface` | tinta de um controle **neutro** sob o ponteiro / pressionado |
| `accent` / `accentHovered` / `accentPressed` | ênfase preenchida, com `colorScheme.onPrimary` por cima |
| `accentSubtle` | banho do acento para o que está **selecionado**, não *acionado* |
| `selection` / `onSelection` | linha selecionada, e o texto sobre ela |
| `disabledSurface` / `disabledForeground` | o que não pode ser usado |
| `focusRing` | o anel de foco |

Duas distinções que carregam quase toda a diferença de aparência:

* **acento preenchido vs. banho de acento.** Um botão de barra de ferramentas
  *selecionado* está marcado, não é primário. Preenchê-lo com `accent` faz uma
  paleta de ferramentas virar uma fileira de botões primários; `accentSubtle`
  atrás de um glifo na cor do acento é como toda ferramenta atual desenha
  "esta ferramenta está ativa".
* **rampa neutra vs. rampa de acento.** `ControlBehavior.neutralSurfaceColor`
  devolve `null` em repouso, e `null` significa *não pinte nada*. É o ponto da
  rampa neutra: uma barra com vinte botões precisa ser vinte pedaços de
  superfície contínua até o ponteiro chegar, não vinte retângulos cinza.

### Contraste (acessibilidade, não decoração)

Verificado aritmeticamente para **todos** os temas embutidos:

* **4,5:1** para texto sobre a superfície em que se apoia (WCAG 2.2 SC 1.4.3,
  AA, texto normal) — inclusive rótulo sobre acento, sobre seleção, sobre o
  banho de acento e sobre estados de hover/pressed;
* **3:1** para o contorno de um controle e para marcas gráficas com significado
  (SC 1.4.11) — `borderStrong`, `focusRing`, preenchimento de acento contra o
  painel, glifo de acento sobre `accentSubtle`;
* texto **desabilitado** é isento por norma, e é medido contra um piso próprio:
  legível, porém sempre mais fraco que o habilitado.

Três consequências reais dessa checagem, todas corrigidas aqui e nenhuma
visível "no olho":

1. `borderStrong` clareado demais dava 1,85:1 — um contorno de campo que
   desaparecia contra branco. Hoje é `#888E98` nos temas claros e `#6B7280` /
   `#6B7A8D` nos escuros;
2. tema escuro com acento saturado e texto branco dá 3,7:1. Temas escuros usam
   **acento claro com texto escuro** (`onPrimary` = azul-marinho), que é a forma
   para a qual todo tema escuro converge;
3. alto contraste selecionava com ciano e escrevia em branco: 1,4:1. Daí o token
   `onSelection`, que por padrão é `foreground` e no tema de alto contraste é
   preto.

### Paletas

**neutral-light** (base dos goldens) — `surfaceBase #EEF0F4`, `surface #F6F7F9`,
`surfaceAlternate/Raised #FFFFFF`, `borderSubtle #E7E9ED`, `border #D5D9E0`,
`borderStrong #888E98`, `foreground #14181F`, `foregroundSecondary #5A6472`,
`hoverSurface #EBEDF1`, `pressedSurface #DFE3E9`, `accent #2563EB` →
`#1D4ED8` → `#1E40AF`, `accentSubtle #E3ECFD`, `selection #D8E5FE`,
`focusRing #2563EB`, raio 6, controle 32, padding 12, base tipográfica 13.

**neutral-dark** — `surfaceBase #15181C`, `surface #1D2126`,
`surfaceAlternate #24282F`, `surfaceRaised #2A2F37`, `borderSubtle #2B3037`,
`border #383E47`, `borderStrong #6B7280`, `foreground #EDEFF2`,
`foregroundSecondary #A7AFBB`, `hoverSurface #2C313A`,
`pressedSurface #353B45`, `accent #5C97FF` → `#7DAEFF` → `#9CC0FF` (a rampa
*clareia* sob o ponteiro, porque o rótulo sobre ela é azul-marinho e um
preenchimento mais escuro levaria o rótulo junto), `accentSubtle #1F3559`,
`selection #2A4A78`, `focusRing #8AB8FF`.

**fluent-light** — o tema que uma ferramenta desktop escolhe: densidade
compacta, raio 4, base 13. `accent #0F6CBD` → `#115EA3` → `#0C4C86`,
`surface #F7F8FA`, `border #DCE0E6`, `borderStrong #888E98`,
`selection #CFE4FA`, `accentSubtle #DCEAF9`.

**material-light / material-dark** — padrões modernos: raio 8, controle 36,
padding 16, base 14. O escuro usa acento claro (`#8AB4FF`) com
`onPrimary #0A2A5E`.

**high-contrast-dark** — extremos puros, bordas sempre visíveis, anel de foco de
3 px, `onSelection` preto.

## 5. Raio de canto

Um número no tema, dois derivados dele:

```dart
cornerRadius                                   // controle comum
cornerRadiusSmall => cornerRadius - 2          // check box, chip, swatch, botão de ícone
cornerRadiusLarge => cornerRadius + 2          // cartão, diálogo, pop-up, painel
```

Derivar em vez de declarar três números é o que faz os cantos concordarem: o que
faz uma tela parecer projetada é que os cantos combinam, e três números
independentes são três chances de não combinarem. Formas cuja definição *é* a
forma não leem o tema: um switch e um slider são pílulas (`altura / 2`), um
radio e um dia de calendário são círculos, um chip é pílula.

## 6. Foco e estados

**Anel de foco** (`ControlBehavior.paintFocusRing`): dois anéis, não um. O
externo é `focusRing` com `focusRingWidth` (2 px; 3 no alto contraste); o
interno é uma linha de 1 px da própria superfície do controle, para que o anel
não encoste na borda e continue visível sobre um fundo da mesma cor do anel. É a
forma para a qual todo desktop convergiu, exatamente por esse motivo. O anel é
desenhado *fora* da caixa do controle — não come um pixel do que marca — e
segue o raio do controle, de modo que um botão arredondado não ganha um halo
quadrado.

Aparece somente em `:focus-visible`: anel após cada clique é ruído, e nenhum
anel após Tab torna o teclado inutilizável.

**Rampa de estados**, uniforme em todos os controles:

| estado | controle preenchido | controle neutro |
|---|---|---|
| repouso | `accent` | nada pintado |
| hover | `accentHovered` | `hoverSurface` |
| pressed | `accentPressed` | `pressedSurface` |
| selecionado | — | `accentSubtle` + glifo em `accent` |
| foco (teclado) | anel duplo | anel duplo |
| foco (campo) | contorno em `accent` com 1,5 px | idem |
| desabilitado | `disabledSurface` + `disabledForeground` | idem |

Pressionado ganha de hover, que ganha de selecionado: o retorno do próprio
ponteiro precisa ser visível num botão que já está marcado.

Campo de texto e spin box **engrossam** o contorno ao focar (1 → 1,5 px) em vez
de apenas recolori-lo: cor sozinha não é sinal de estado acessível.

## 7. Ícones

* Tamanho vem do tema: `ThemeData.iconSize` — **16** nos temas de desktop, **20**
  nos `material*`. Um `IconButton` sem tamanho declarado desenha o ícone do tema
  centrado num quadrado de uma altura de controle, que é o que põe uma fileira
  de botões de ícone no mesmo ritmo dos campos ao lado.
* O contorno de um ícone é desenhado numa grade de 16 ou 24 unidades com hastes
  de 1 unidade: meio pixel de deslocamento transforma uma haste nítida em duas
  cinzas de 50 %. Por isso `RenderIcon` centra a **tinta** do glifo (não a caixa
  em) e **arredonda a caneta para pixel inteiro**. Isso também colapsa os
  *buckets* de subpixel do cache de glifos em um só: todo chevron de 16 px de
  uma barra compartilha uma única máscara rasterizada.
* Com isso, a "correção óptica de +1 px" que o `IconButton` aplicava deixou de
  existir — ela compensava o ícone centrar a caixa em, e depois da correção real
  virou uma fileira de ícones um pixel abaixo do centro.
* Marcas próprias do framework (chevron, tique de check box) **não** dependem de
  fonte: `paintPolyline` desenha polilinha como quads preenchidos, e o widget
  `Chevron` expõe a mesma marca para cromo composto por widgets. O motivo é
  concreto: `U+25B8` não existe na maioria das faces de interface, e o botão de
  mês do calendário saía vazio no Windows.
* Triângulos sólidos foram removidos de todos os controles (combo, expander,
  árvore, spin box, seta de ordenação da grade): um triângulo preenchido é a
  marca mais reconhecível de uma interface de 1995, e a 8 px é um borrão.

## 8. O que o editor vetorial usa

`examples/vector_editor_demo/metrics.dart` é a aplicação deste contrato a uma
janela real. O editor escolhe `ThemeData.fluentLight`, que é compacto: altura de
controle 28, linha 24, padding 8, gap 4. Daí as bandas:

| banda | antes | agora | por quê |
|---|---|---|---|
| barra de menus | 24 | 28 | uma linha + ar; 24 deixava 3 px acima de um rótulo de 12 px |
| barra de ícones | 32 | 36 | botão de 28 + 4 de ar em cima e embaixo |
| barra contextual | 30 | 36 | um controle + ar, para o combo não encostar na aresta |
| abas de documento | 24 | 28 | uma linha |
| caixa de ferramentas | 30 / 26 / 15 | 32 / 28 / 16 | botão de uma altura de controle, ícone do tema |
| réguas | 18 | 20 | grade |
| paleta | 26 / 18 | 28 / 16 | grade |
| barra de status | 22 | 28 | uma linha; 22 era mais baixo que qualquer controle |
| tira de abas recolhida | 24 | 28 | grade |
| painel de plugin | 250 | 260 | grade |
| padding de barra | 6 | 8 | escala de espaçamento |

---

## Como estender

1. **Não invente um número.** Se um controle novo precisa de uma altura, é
   `effectiveControlHeight` ou `effectiveRowHeight`; se precisa de um espaço, é
   `Spacing`; se precisa de um raio, é um dos três; se precisa de uma cor, é um
   token da tabela.
2. **Se nenhum token serve, o token é que está faltando** — acrescente-o ao
   `ThemeData`, com todos os temas embutidos preenchidos, e registre-o aqui.
3. **Meça o contraste.** Todo par novo (texto sobre fundo, marca sobre fundo)
   entra em `theme_contrast_test.dart`. Contraste não é revisável no olho.
4. **Olhe renderizado.** `dart run examples/vector_editor_demo/tool/headless_shot.dart`
   para a janela densa e `example/gallery_headless.dart` (ou as três páginas de
   `lib/src/gallery/gallery.dart`) para os controles isolados. Mudança de design
   que ninguém viu renderizada não é mudança de design; é uma hipótese.
